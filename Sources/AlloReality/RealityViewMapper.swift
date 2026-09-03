//
//  RealityViewMapper.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-18.
//

import RealityKit
import OpenCombineShim
import allonet2
import SwiftUI
import GLTFKit2
import ImageIO

/// The RealityViewMapper creates and maintains RealityKit entities and components to perfectly match corresponding entities and components inside an Alloverse connection's PlaceContents.
@MainActor
public class RealityViewMapper
{
    public var builtinAssetsBundle: Bundle?
    /// How to turn an `AssetID` from a component into local bytes on disk; wire it to
    /// `AlloClient.assetURL(_:)`. Without it, `.image` materials can only render as magenta.
    public var assetResolver: (@Sendable (AssetID) async throws -> URL)?
    private var netstate: PlaceState
    private var guiroot: RealityKit.Entity
    private var cancellables = Set<AnyCancellable>()
    
    public func guiForEid(_ eid: EntityID) -> RealityKit.Entity?
    {
        return guiroot.findEntity(named: eid)
    }
    
    /// Create a mapper that maps changes in the given `networkState` (taken from an AlloClient), and maintains corresponding RealityKit entities as children of `guiroot`. By default, it is inert; you need to `startSyncing()` to make it react to changes, and you should do so before connecting the associated AlloClient (so you don't miss any changes).
    public init(networkState netstate: PlaceState, addingEntitiesTo guiroot: RealityKit.Entity) {
        self.netstate = netstate
        self.guiroot = guiroot
    }
    
    /// Start syncing changes from the AlloClient into the associated RealityView Entity. This default implementation creates Entities and most of the Standard Alloverse Components. If you want to also sync any of your own custom components, you must also call `startSyncingOf(networkComponentType:to:using:)`.
    public func startSyncing()
    {
        netstate.observers.entityAddedWithInitial.sink { netent in
            let guient = RealityKit.Entity()
            guient.name = netent.id
            self.guiroot.addChild(guient)
        }.store(in: &cancellables)
        netstate.observers.entityRemoved.sink { netent in
            guard let guient = self.guiForEid(netent.id) else { return }
            // Component removers don't run for an entity that merely goes away.
            guient.components[AlloModelStateComponent.self]?.loadingTask?.cancel()
            guient.components[AlloModelStateComponent.self]?.inlineImageTask?.cancel()
            guient.components[AlloTextStateComponent.self]?.loadingTask?.cancel()
            guient.removeFromParent()
        }.store(in: &cancellables)
        
        startSyncingOf(networkComponentType: allonet2.Transform.self, to: RealityKit.Transform.self)
        { (entity, _, transform) in
            entity.setTransformMatrix(transform.matrix, relativeTo: entity.parent)
        }
        
        startSyncingOf(networkComponentType: Relationships.self) { (entity, _, relationship) in
            guard entity.parent?.name != relationship.parent else { return }
            entity.removeFromParent()
            let newParent = self.guiForEid(relationship.parent)!
            newParent.addChild(entity)
        } remover: { (entity, _, relationship) in
            guard entity.parent != self.guiroot else { return }
            entity.removeFromParent()
            self.guiroot.addChild(entity)
        }
        
        startSyncingOfModel()
        startSyncingOfInlineImage()
        startSyncingOfText()
        
        startSyncingOf(networkComponentType: Collision.self, to: CollisionComponent.self)
        { entity, _, collision in
            entity.components.set(CollisionComponent(shapes: collision.realityShapes))
        }
        
        startSyncingOf(networkComponentType: Opacity.self, to: OpacityComponent.self)
        { entity, _, opacity in
            entity.components.set(OpacityComponent(opacity: opacity.opacity))
        }
        startSyncingOf(networkComponentType: Billboard.self, to: BillboardComponent.self)
        { entity, _, billboard in
            var reality = BillboardComponent()
            reality.blendFactor = billboard.blendFactor
            entity.components.set(reality)
        }
        
        if #available(macOS 15.0, *) {
            startSyncingOf(networkComponentType: InputTarget.self, to: InputTargetComponent.self)
            {
                (entity, _, inputTarget) in
                entity.components.set(InputTargetComponent())
            }
            startSyncingOf(networkComponentType: HoverEffect.self, to: HoverEffectComponent.self)
            {
                (entity, _, hoverEffect) in
                entity.components.set(HoverEffectComponent(hoverEffect.realityEffect))
            }
        }
    }
    
    /// In addition to syncing the Standard Components from `startSyncing()`, also sync other/custom components with this method, called directly after `startSyncing` but before the AlloClient connects.
    public func startSyncingOf<T>(
        networkComponentType: T.Type,
        updater: @escaping @MainActor (RealityKit.Entity, allonet2.EntityData, T) -> Void,
        remover: @escaping @MainActor (RealityKit.Entity, allonet2.EntityData, T) -> Void
    ) where T : allonet2.Component
    {
        netstate.observers[networkComponentType.self].updatedWithInitial.sink { (eid, netcomp) in
            guard let guient = self.guiForEid(eid) else { return }
            guard let netent = self.netstate.current.entities[eid] else { return }
            updater(guient, netent, netcomp)
        }.store(in: &cancellables)
        netstate.observers[networkComponentType.self].removed.sink { (edata, netcomp) in
            guard let guient = self.guiForEid(edata.id) else { return }
            remover(guient, edata, netcomp)
        }.store(in: &cancellables)
    }
    
    /// Convenience alternative to `startSyncingOf:updater:remover` when there's a one-to-one map between an Alloverse entity type and a RealityKit entity type.
    public func startSyncingOf<T, U>(networkComponentType: T.Type, to realityComponentType: U.Type, using updater: @escaping (RealityKit.Entity, allonet2.EntityData, T) -> Void) where T : allonet2.Component, U : RealityKit.Component
    {
        startSyncingOf(networkComponentType: networkComponentType, updater: updater, remover: {  (guient, _, netcomp) in
            guient.components[realityComponentType.self] = nil
        })
    }
    
    private struct AlloModelStateComponent: RealityKit.Component
    {
        var current: Model? = nil
        weak var entity: RealityKit.Entity? = nil
        var loadingTask: Task<Void, Error>?
        /// The `InlineImage` painted over the `Model`'s material, and the texture upload in
        /// flight for it. Kept as intent rather than read back off the ModelComponent: component
        /// order is not guaranteed, and a `Model` update rebuilds that component from scratch.
        var inlineImage: Data? = nil
        var inlineImageTask: Task<Void, Never>?
    }
    
    private func startSyncingOfModel()
    {
        startSyncingOf(networkComponentType: Model.self)
        { (entity, _, model) in
            var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
            guard state.current != model else { return }
            let previous = state.current
            state.current = model
            state.loadingTask?.cancel()
            state.loadingTask = nil
            // A builtin mesh draws through a loaded child entity, every other model through the
            // entity's own ModelComponent. A change of kind has to take the previous one down, or
            // the old model stays on screen next to the new one.
            state.entity?.removeFromParent()
            state.entity = nil

            if case .builtin(name: let name) = model.mesh
            {
                state.loadingTask = self.loadVisual(of: entity, describedAs: "builtin model \(name)")
                {
                    try await Entity(named: name, in: self.builtinAssetsBundle)
                }
            }
            else if case .asset(id: let id) = model.mesh
            {
                state.loadingTask = self.loadVisual(of: entity, describedAs: "mesh asset \(id)")
                {
                    guard let url = try await self.resolvedAssetURL(id, for: entity.name) else { return Self.missingVisual() }
                    return try await Self.visual(ofAssetAt: url)
                }
            }
            else if case .image(let asset) = model.material
            {
                // Shape now, texture when it arrives — a plane that pops in late reads as a bug.
                // Only paint the blank placeholder when there is nothing on screen yet: repainting
                // an already-textured plane would flash it white on every icon change.
                if var existing = entity.components[ModelComponent.self]
                {
                    if previous?.mesh != model.mesh
                    {
                        existing.mesh = model.mesh.realityMesh
                        entity.components.set(existing)
                    }
                }
                else
                {
                    entity.components.set(ModelComponent(mesh: model.mesh.realityMesh, materials: [SimpleMaterial()]))
                }
                state.loadingTask = Task {
                    let material = await self.imageMaterial(asset: asset, for: entity.name)
                    if(Task.isCancelled) { return }
                    entity.components.set(ModelComponent(mesh: model.mesh.realityMesh, materials: [material]))
                    var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
                    state.loadingTask = nil
                    entity.components.set(state)
                    self.applyInlineImage(to: entity)
                }
            }
            else
            {
                var realityModel = ModelComponent(mesh: model.mesh.realityMesh, materials: [])
                if let mat = model.material.realityMaterial
                {
                    realityModel.materials = [mat]
                }
                entity.components.set(realityModel)
            }
            entity.components.set(state)
            // The rebuild above dropped whatever was painted on the old ModelComponent.
            self.applyInlineImage(to: entity)
        }
        remover: { (entity, _, model) in
            let state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
            state.loadingTask?.cancel()
            state.inlineImageTask?.cancel()
            state.entity?.removeFromParent()
            entity.components.remove(ModelComponent.self)
            entity.components.remove(AlloModelStateComponent.self)
        }
    }

    private func startSyncingOfInlineImage()
    {
        startSyncingOf(networkComponentType: InlineImage.self)
        { (entity, _, image) in
            var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
            let wanted = image.png.isEmpty ? nil : image.png
            guard state.inlineImage != wanted else { return }
            state.inlineImage = wanted
            entity.components.set(state)
            self.applyInlineImage(to: entity)
        }
        remover: { (entity, _, _) in
            guard var state = entity.components[AlloModelStateComponent.self], state.inlineImage != nil else { return }
            state.inlineImage = nil
            entity.components.set(state)
            self.applyInlineImage(to: entity)
        }
    }

    /// Paint the entity's `InlineImage` over its `ModelComponent`, or put the `Model`'s own
    /// material back when there is no image left. Idempotent, and safe to call whenever either
    /// component changes — which is what keeps a thumbnail alive across a `Model` update.
    ///
    /// Only the entity's own `ModelComponent` is touched, so a `.builtin` or `.asset` mesh (which
    /// draws through a loaded child) is left as its file authored it.
    private func applyInlineImage(to entity: RealityKit.Entity)
    {
        var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
        state.inlineImageTask?.cancel()
        state.inlineImageTask = nil
        defer { entity.components.set(state) }
        guard entity.components[ModelComponent.self] != nil else { return }

        guard let png = state.inlineImage else
        {
            guard let model = state.current else { return }
            if case .image(let asset) = model.material
            {
                state.inlineImageTask = Task { await self.paint(await self.imageMaterial(asset: asset, for: entity.name), on: entity) }
            }
            else if var realityModel = entity.components[ModelComponent.self]
            {
                realityModel.materials = model.material.realityMaterial.map { [$0] } ?? []
                entity.components.set(realityModel)
            }
            return
        }

        let cgImage: CGImage
        do { cgImage = try Self.decodePNG(png) }
        catch
        {
            complainAboutInlineImage(on: entity.name, error)
            return
        }
        state.inlineImageTask = Task {
            do
            {
                let texture = try await TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
                // As for `imageMaterial`: the base colour texture alone renders transparent
                // texels black, and `.transparent` is what makes RealityKit read its alpha.
                var material = PhysicallyBasedMaterial()
                material.baseColor = .init(texture: .init(texture))
                material.blending = .transparent(opacity: .init(scale: 1))
                // A plane is one-sided; a thumbnail seen from behind should still be a thumbnail.
                material.faceCulling = .none
                material.roughness = 1.0
                material.metallic = 0.0
                await self.paint(material, on: entity)
            }
            catch
            {
                if !Task.isCancelled { print("Failed to upload inline image for entity \(entity.name): \(error)") }
            }
        }
    }

    @MainActor
    private func paint(_ material: RealityKit.Material, on entity: RealityKit.Entity)
    {
        guard !Task.isCancelled, var realityModel = entity.components[ModelComponent.self] else { return }
        realityModel.materials = [material]
        entity.components.set(realityModel)
    }

    /// Entities whose `InlineImage` we've already complained about; a peer can rewrite a
    /// component as fast as it likes, so the log is bounded the way `Text`'s is.
    private var complainedAboutInlineImage: Set<EntityID> = []

    private func complainAboutInlineImage(on eid: EntityID, _ refusal: InlineImageRefusal)
    {
        guard complainedAboutInlineImage.insert(eid).inserted else { return }
        print("Entity \(eid) has an unusable InlineImage: \(refusal); drawing its Model instead")
    }

    /// The widest and tallest an `InlineImage` may be. It is a thumbnail or a glyph by definition,
    /// and the cost of a bigger one is paid in texture memory, not in the 16 KiB it arrived as.
    public static let maximumInlineImagePixels = 512

    /// - Throws: `InlineImageRefusal`, naming what was wrong with these bytes. The size is read
    ///   from the header first: a peer's 16 KiB PNG can declare 30000x30000, and decoding it to
    ///   find that out is exactly the allocation worth avoiding.
    static func decodePNG(_ png: Data) throws(InlineImageRefusal) -> CGImage
    {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw .unreadable(bytes: png.count) }
        guard width <= Self.maximumInlineImagePixels, height <= Self.maximumInlineImagePixels
        else { throw .tooManyPixels(width: width, height: height) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw .unreadable(bytes: png.count) }
        return image
    }

    /// Load `.builtin`/`.asset` meshes, which draw through a child subtree instead of the entity's
    /// own `ModelComponent`. A failed load shows `missingVisual()`, never nothing.
    private func loadVisual(
        of entity: RealityKit.Entity,
        describedAs description: String,
        loading load: @escaping @MainActor () async throws -> RealityKit.Entity
    ) -> Task<Void, Error>
    {
        entity.components.remove(ModelComponent.self)
        return Task {
            var loaded: RealityKit.Entity
            do { loaded = try await load() }
            catch
            {
                // Only our own cancellation means a newer Model replaced us.
                if Task.isCancelled { return }
                print("Failed to load \(description) for entity \(entity.name): \(error)")
                loaded = Self.missingVisual()
            }
            if(Task.isCancelled) { return }
            Self.anonymize(loaded)
            // Re-read: `state` is a copy from before the await.
            var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
            state.loadingTask = nil
            state.entity = loaded
            entity.components.set(state)
            entity.addChild(loaded)
        }
    }

    /// Clear a loaded subtree's names, so a peer's node can't answer to another entity's id in
    /// `guiForEid`. Costs RealityKit's name-based animation binding; see docs/assets-implementation.md.
    static func anonymize(_ entity: RealityKit.Entity)
    {
        entity.name = ""
        for child in entity.children { anonymize(child) }
    }

    /// Stands in for a model that couldn't be loaded: red, so it can't be mistaken for content.
    public static func missingVisual() -> RealityKit.Entity
    {
        ModelEntity(mesh: .generateBox(size: 0.5), materials: [SimpleMaterial(color: .red, isMetallic: true)])
    }

    /// The visual an asset file draws as, dispatched on the extension `AssetStore` derived from its
    /// media type. `.gltf` is deliberately absent; see docs/assets-implementation.md.
    public static func visual(ofAssetAt url: URL) async throws -> RealityKit.Entity
    {
        switch url.pathExtension.lowercased()
        {
        case "glb":
            // Parse off-main, convert on it; the check keeps a cancelled load from paying for the
            // expensive half. Costs in docs/assets-implementation.md.
            let parsed = try await Task.detached(priority: .userInitiated) { try ParsedGLTF(contentsOf: url) }.value
            try Task.checkCancellation()
            guard let scene = parsed.asset.defaultScene ?? parsed.asset.scenes.first else
            {
                throw AssetVisualError.gltfHasNoScene(url)
            }
            try validate(parsed.asset, from: url)
            return GLTFRealityKitLoader.convert(scene: scene, asset: parsed.asset)
        case "usdz", "usda":
            return try await Entity(contentsOf: url)
        default:
            throw AssetVisualError.unloadableFormat(url)
        }
    }

    /// A parsed glTF handed back from the parse task; `@unchecked` because `GLTFAsset` is an
    /// Objective-C class that only ever has the one reference.
    ///
    /// From bytes, never the URL: a URL gives cgltf a base directory to resolve external buffer
    /// URIs against, which is a path traversal. See docs/assets-implementation.md.
    private struct ParsedGLTF: @unchecked Sendable
    {
        let asset: GLTFAsset
        init(contentsOf url: URL) throws { asset = try GLTFAsset(data: Data(contentsOf: url), options: [:]) }
    }

    /// Reject glTF that parses but contradicts itself, because RealityKit asserts below Swift on it
    /// rather than throwing. Scope and gaps in docs/assets-implementation.md.
    private static func validate(_ asset: GLTFAsset, from url: URL) throws
    {
        for mesh in asset.meshes
        {
            for primitive in mesh.primitives
            {
                let counts = Set(primitive.attributes.map { $0.accessor.count })
                guard counts.count <= 1 else
                {
                    throw AssetVisualError.inconsistentGeometry(url, "attributes of one primitive describe \(counts.sorted()) vertices")
                }
                for attribute in primitive.attributes
                {
                    try validate(accessor: attribute.accessor, named: attribute.name ?? "an attribute", from: url)
                }
                if let indices = primitive.indices
                {
                    try validate(accessor: indices, named: "indices", from: url)
                }
            }
        }
    }

    private static func validate(accessor: GLTFAccessor, named name: String, from url: URL) throws
    {
        // A sparse accessor with no buffer view is all zeroes; nothing to overrun.
        guard let view = accessor.bufferView else { return }
        let element = Int(GLTFBytesPerComponentForComponentType(accessor.componentType))
                    * Int(GLTFComponentCountForDimension(accessor.dimension))
        guard element > 0 else
        {
            throw AssetVisualError.inconsistentGeometry(url, "\(name) has no usable component type")
        }
        guard accessor.offset >= 0, accessor.count >= 0, view.offset >= 0, view.length >= 0 else
        {
            throw AssetVisualError.inconsistentGeometry(url, "\(name) has a negative offset, count or length")
        }
        let stride = view.stride > 0 ? view.stride : element
        guard let needed = Self.windowEnd(offset: accessor.offset, count: accessor.count, stride: stride, element: element),
              let viewEnd = ifNoOverflow(view.offset.addingReportingOverflow(view.length))
        else
        {
            throw AssetVisualError.inconsistentGeometry(url, "\(name) describes a byte range too large to measure")
        }
        guard needed <= view.length, viewEnd <= view.buffer.length else
        {
            throw AssetVisualError.inconsistentGeometry(url, "\(name) reads \(needed) bytes from a \(view.length)-byte buffer view")
        }
    }

    /// `offset + (count - 1) * stride + element`, or nil if it overflows — every term is a peer's,
    /// and an `Int` overflow traps as hard as the assertion this exists to avoid.
    private static func windowEnd(offset: Int, count: Int, stride: Int, element: Int) -> Int?
    {
        guard count > 0 else { return offset }
        return ifNoOverflow((count - 1).multipliedReportingOverflow(by: stride))
            .flatMap { ifNoOverflow(offset.addingReportingOverflow($0)) }
            .flatMap { ifNoOverflow($0.addingReportingOverflow(element)) }
    }

    private var warnedAboutMissingAssetResolver = false

    /// Where an asset's bytes are, or nil if nobody wired up `assetResolver` — a deployment mistake,
    /// so it's said once rather than per asset.
    private func resolvedAssetURL(_ asset: AssetID, for entityName: String) async throws -> URL?
    {
        guard let assetResolver else
        {
            if !warnedAboutMissingAssetResolver
            {
                warnedAboutMissingAssetResolver = true
                print("RealityViewMapper.assetResolver is nil, so assets cannot load (first: \(asset) on entity \(entityName))")
            }
            return nil
        }
        return try await assetResolver(asset)
    }

    /// A `.image` material's texture, or magenta if it can't be had: a logo nobody wired up must be
    /// impossible to miss, and one failed fetch must not become a retry loop.
    private func imageMaterial(asset: AssetID, for entityName: String) async -> RealityKit.Material
    {
        do
        {
            guard let url = try await resolvedAssetURL(asset, for: entityName) else
            {
                return SimpleMaterial(color: .magenta, isMetallic: false)
            }
            let texture = try await TextureResource(contentsOf: url, options: .init(semantic: .color))
            // Measured (RealityKit, macOS 26): a base colour texture alone renders its transparent
            // texels black; `.transparent(opacity: .init(scale: 1))` is what makes RealityKit read
            // the texture's own alpha. Do NOT pass the texture as the opacity map — that samples
            // alpha a second time and makes opaque areas semi-transparent.
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(texture: .init(texture))
            material.blending = .transparent(opacity: .init(scale: 1))
            material.roughness = 1.0 // matte: a specular highlight across a logo looks broken
            material.metallic = 0.0
            return material
        }
        catch
        {
            // Cancelled means the caller discards this anyway, so it isn't a failure to report.
            if !Task.isCancelled
            {
                print("Failed to load image asset \(asset) for entity \(entityName): \(error)")
            }
            return SimpleMaterial(color: .magenta, isMetallic: false)
        }
    }

    /// Name of the child entity holding a `Text` component's mesh, so it can be replaced without
    /// touching the entity's own `Model`.
    static let textChildName = "allo.text"

    /// A rasterized `Text` uploads its texture asynchronously; this is the in-flight upload, so a
    /// newer `Text` can cancel it rather than race it.
    private struct AlloTextStateComponent: RealityKit.Component
    {
        var loadingTask: Task<Void, Never>?
    }

    /// Entities whose `Text` we've already complained about. Bounding the text is pointless if an
    /// unbounded log takes its place: a peer can rewrite a component as fast as it likes.
    private var complainedAboutText: Set<EntityID> = []

    private func startSyncingOfText()
    {
        startSyncingOf(networkComponentType: allonet2.Text.self)
        { (entity, _, text) in
            entity.children.first { $0.name == Self.textChildName }?.removeFromParent()
            self.complainAboutText(text, on: entity.name)
            var state = entity.components[AlloTextStateComponent.self] ?? AlloTextStateComponent()
            state.loadingTask?.cancel()
            state.loadingTask = nil
            if text.hasColorGlyphs
            {
                let input = TextRaster.Input(of: text)
                state.loadingTask = Task {
                    guard let child = await Self.rasterizedText(for: text, rendering: input), !Task.isCancelled else { return }
                    entity.children.first { $0.name == Self.textChildName }?.removeFromParent()
                    entity.addChild(child)
                }
            }
            else if let child = Self.realityText(for: text)
            {
                entity.addChild(child)
            }
            entity.components.set(state)
        }
        remover: { (entity, _, _) in
            entity.components[AlloTextStateComponent.self]?.loadingTask?.cancel()
            entity.components.remove(AlloTextStateComponent.self)
            entity.children.first { $0.name == Self.textChildName }?.removeFromParent()
        }
    }

    /// A `Text` with emoji in it: drawn to a texture on a plane, since no outline font has those
    /// glyphs (see docs/realitykit-rendering.md). The plane is the block; `placement` treats its
    /// bounds exactly as it treats a text mesh's, so alignment and fit come out the same.
    static func rasterizedText(for text: allonet2.Text, rendering input: TextRaster.Input) async -> RealityKit.Entity?
    {
        // The input snapshot is already bounded; the CPU work happens detached — layout plus a
        // bitmap must not stall the frame.
        guard text.hasLayoutBox else { return nil }
        guard let raster = await Task.detached(priority: .userInitiated, operation: { TextRaster.render(input) }).value
        else { return nil }
        do
        {
            let texture = try await TextureResource(image: raster.image, withName: nil, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            // As for image materials: this is what makes RealityKit honour the texture's own alpha.
            material.blending = .transparent(opacity: .init(scale: 1))
            let half = SIMD3<Float>(raster.width / 2, raster.height / 2, 0)
            guard let placement = text.placement(ofBlockFrom: -half, to: half) else { return nil }
            let child = ModelEntity(mesh: .generatePlane(width: raster.width, height: raster.height), materials: [material])
            child.name = textChildName
            child.transform.scale = .init(repeating: placement.scale)
            child.transform.translation = placement.translation
            return child
        }
        catch
        {
            if !(Task.isCancelled || error is CancellationError)
            {
                print("Failed to rasterize text \"\(text.string)\": \(error)")
            }
            return nil
        }
    }

    private func complainAboutText(_ text: allonet2.Text, on eid: EntityID)
    {
        let problem: String
        if text.string.count > allonet2.Text.maxRenderedCharacters {
            problem = "\(text.string.count) characters; rendering the first \(allonet2.Text.maxRenderedCharacters)"
        } else if !text.string.isEmpty && !text.hasLayoutBox {
            problem = "a \(text.width) x \(text.height) m box, which is not a size; rendering nothing"
        } else { return }
        guard complainedAboutText.insert(eid).inserted else { return }
        print("Entity \(eid) has a Text with \(problem)")
    }

    /// Build the child entity for a `Text`, or nil if there is nothing to draw. Regenerated from
    /// scratch on every change: text meshes are cheap and diffing glyphs is not.
    static func realityText(for text: allonet2.Text) -> RealityKit.Entity?
    {
        // Everything here comes from a peer. Tessellation is synchronous on the main actor and its
        // cost is per glyph, so cap the string; a size that isn't a size gets no mesh at all,
        // rather than a NaN point size handed to Core Text.
        let string = String(text.string.prefix(allonet2.Text.maxRenderedCharacters))
        guard !string.isEmpty else { return nil } // generateText("") returns infinite bounds
        guard text.hasLayoutBox else { return nil }

        // Measured: RealityKit lays text out at one metre per point, so the font's own line height
        // (ascender - descender + leading, 1.178 x point size for the system font) is what has to
        // equal `Text.height`. In `.box`, `height` is the box rather than a line height, but it
        // still serves as the nominal one: `placement` scales the finished block to the box, so
        // only the ratio of the generated block to the box survives — and generating at the box's
        // own scale keeps that ratio (and hence where `wrap` breaks) the same for a box of any size.
        let unit = MeshResource.Font.systemFont(ofSize: 1)
        let lineHeightPerPoint = Float(unit.ascender - unit.descender + unit.leading)
        let font = MeshResource.Font.systemFont(ofSize: CGFloat(text.height / lineHeightPerPoint))
        // A zero frame means "one line, no wrapping"; a real frame wraps at its width and stacks
        // lines down from its top edge, so put that edge at y=0 and make it tall enough for the
        // worst case of one glyph per line (lines past the frame's bottom are dropped).
        var frame = CGRect.zero
        if text.wrap
        {
            let height = CGFloat(text.height) * CGFloat(string.count + 1)
            frame = CGRect(x: 0, y: -height, width: CGFloat(text.width), height: height)
        }
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: 0, // flat, and already facing +Z
            font: font,
            containerFrame: frame,
            alignment: text.halign.realityAlignment,
            lineBreakMode: .byWordWrapping
        )
        guard let placement = text.placement(ofBlockFrom: mesh.bounds.min, to: mesh.bounds.max) else { return nil }

        let child = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: text.color.realityColor)])
        child.name = textChildName
        child.transform.scale = .init(repeating: placement.scale)
        child.transform.translation = placement.translation
        return child
    }

    /// Stop syncing Alloverse<>RealityKit. Call this to break reference cycles, e g when your RealityView disappears (i e in `onDisappear()`).
    public func stopSyncing()
    {
        cancellables.forEach { $0.cancel() }; cancellables.removeAll()
    }
}


/// The result of an overflow-reporting operation, or nil if it overflowed, so checks chain.
private func ifNoOverflow(_ result: (partialValue: Int, overflow: Bool)) -> Int?
{
    result.overflow ? nil : result.partialValue
}

/// Why an `InlineImage` won't be drawn. A peer wrote these bytes, so both cases are things to
/// expect rather than bugs; the entity falls back to its `Model`'s own material.
public enum InlineImageRefusal: Error, Equatable, CustomStringConvertible
{
    case unreadable(bytes: Int)
    case tooManyPixels(width: Int, height: Int)

    public var description: String
    {
        switch self
        {
        case .unreadable(let bytes): "\(bytes) bytes that are not a readable image"
        case .tooManyPixels(let width, let height):
            "a \(width)x\(height) picture, over the \(RealityViewMapper.maximumInlineImagePixels) px an inline image may be"
        }
    }
}

/// Why a fetched asset couldn't become a visual. The bytes are on disk and hash-checked by now, so
/// what's left is a file this renderer won't open.
public enum AssetVisualError: Error, Equatable, CustomStringConvertible
{
    /// No loader for this extension. `.gltf` included, on purpose; see docs/assets-implementation.md.
    case unloadableFormat(URL)
    /// Valid glTF, but with nothing in it to draw.
    case gltfHasNoScene(URL)
    /// Parseable glTF whose vertex data contradicts itself; the string says which invariant broke.
    case inconsistentGeometry(URL, String)

    public var description: String
    {
        switch self
        {
        case .unloadableFormat(let url): return "No mesh loader for \(url.pathExtension.isEmpty ? "a file without an extension" : "." + url.pathExtension) (\(url.lastPathComponent))"
        case .gltfHasNoScene(let url): return "glTF \(url.lastPathComponent) contains no scene"
        case .inconsistentGeometry(let url, let what): return "glTF \(url.lastPathComponent) is inconsistent: \(what)"
        }
    }
}

extension allonet2.Model.Mesh
{
    var realityMesh: RealityKit.MeshResource
    {
        switch self
        {
        case .builtin(name: let name): fatalError("Must use Model's factory to also load material")
        case .asset: fatalError("Must use Model's factory to also load material")
        case .box(size: let size, cornerRadius: let cornerRadius):
            return .generateBox(size: size, cornerRadius: cornerRadius)
        case .plane(width: let width, depth: let depth, cornerRadius: let cornerRadius):
            return .generatePlane(width: width, depth: depth, cornerRadius: cornerRadius)
        case .sphere(radius: let radius):
            return .generateSphere(radius: radius)
        case .cylinder(height: let height, radius: let radius):
            if #available(macOS 15.0, *) {
                return .generateCylinder(height: height, radius: radius)
            } else {
                return .generateBox(size: .init(x: radius * 2, y: height, z: radius * 2), cornerRadius: radius)
            }
        }
    }
}

extension allonet2.Model.Material
{
    var realityMaterial: RealityKit.Material?
    {
        switch self
        {
        case .color(let color, let metallic):
            return RealityKit.SimpleMaterial(color: color.realityColor, isMetallic: metallic)
        case .standard:
            return nil
        case .image:
            fatalError("Image materials load asynchronously; route them through RealityViewMapper's texture loading instead")
        }
    }
}

extension Collision
{
    var realityShapes: [ShapeResource]
    {
        shapes.map
        {
            switch $0
            {
            case .box(let size):
                return .generateBox(size: size)
            }
        }
    }
}

extension allonet2.Color
{
    var realityColor: RealityKit.Material.Color
    {
        switch self
        {
        case .rgb(red: let red, green: let green, blue: let blue, alpha: let alpha):
            return RealityKit.Material.Color(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        case .hsv(hue: let hue, saturation: let saturation, value: let value, alpha: let alpha):
            return RealityKit.Material.Color(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: CGFloat(value), alpha: CGFloat(alpha))
       }
    }
}

@available(macOS 15.0, *)
extension HoverEffect
{
    var realityEffect: HoverEffectComponent.HoverEffect
    {
        switch style
        {
        case .spotlight(color: let color, strength: let strength):
            return .spotlight(.init(color: color.realityColor, strength: 0.5))
        }
    }
}

extension allonet2.Text.HorizontalAlignment
{
    var realityAlignment: CTTextAlignment
    {
        switch self
        {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}
