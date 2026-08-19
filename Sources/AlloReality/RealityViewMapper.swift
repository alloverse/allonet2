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
                entity.components.remove(ModelComponent.self)
                state.loadingTask = Task {
                    var loaded: RealityKit.Entity!
                    do {
                        loaded = try await Entity(named: name, in: self.builtinAssetsBundle)
                    } catch (let e) {
                        print("Failed to load builtin model \(name) for entity \(entity.id): \(e)")
                        loaded = ModelEntity(mesh: .generateBox(size: 0.5), materials: [SimpleMaterial(color: .red, isMetallic: true)])
                    }
                    if(Task.isCancelled) { return }
                    // Re-read: `state` is a value copy from before the await, and a newer Model may
                    // have landed in the meantime.
                    var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
                    state.loadingTask = nil
                    state.entity = loaded
                    entity.components.set(state)
                    entity.addChild(loaded)
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
        }
        remover: { (entity, _, model) in
            var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
            state.loadingTask?.cancel()
            state.entity?.removeFromParent()
            entity.components.remove(AlloModelStateComponent.self)
        }
    }

    private static var warnedAboutMissingAssetResolver = false

    /// A `.image` material's texture, or magenta if it can't be had: a logo nobody wired up must be
    /// impossible to miss, and one failed fetch must not become a retry loop.
    private func imageMaterial(asset: AssetID, for entityName: String) async -> RealityKit.Material
    {
        guard let assetResolver else
        {
            if !Self.warnedAboutMissingAssetResolver
            {
                Self.warnedAboutMissingAssetResolver = true
                print("RealityViewMapper.assetResolver is nil, so image materials cannot load (first: \(asset) on entity \(entityName))")
            }
            return SimpleMaterial(color: .magenta, isMetallic: false)
        }
        do
        {
            let url = try await assetResolver(asset)
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
            // A newer Model landed and cancelled us: the caller throws away whatever we return, so
            // this is not a failure to report.
            if !(Task.isCancelled || error is CancellationError)
            {
                print("Failed to load image asset \(asset) for entity \(entityName): \(error)")
            }
            return SimpleMaterial(color: .magenta, isMetallic: false)
        }
    }

    /// Name of the child entity holding a `Text` component's mesh, so it can be replaced without
    /// touching the entity's own `Model`.
    static let textChildName = "allo.text"

    private func startSyncingOfText()
    {
        startSyncingOf(networkComponentType: allonet2.Text.self)
        { (entity, _, text) in
            entity.children.first { $0.name == Self.textChildName }?.removeFromParent()
            guard let child = Self.realityText(for: text) else { return }
            entity.addChild(child)
        }
        remover: { (entity, _, _) in
            entity.children.first { $0.name == Self.textChildName }?.removeFromParent()
        }
    }

    /// Build the child entity for a `Text`, or nil if there is nothing to draw. Regenerated from
    /// scratch on every change: text meshes are cheap and diffing glyphs is not.
    static func realityText(for text: allonet2.Text) -> RealityKit.Entity?
    {
        guard !text.string.isEmpty else { return nil } // generateText("") returns infinite bounds

        // Measured: RealityKit lays text out at one metre per point, so the font's own line height
        // (ascender - descender + leading, 1.178 x point size for the system font) is what has to
        // equal `Text.height`.
        let unit = MeshResource.Font.systemFont(ofSize: 1)
        let lineHeightPerPoint = Float(unit.ascender - unit.descender + unit.leading)
        let font = MeshResource.Font.systemFont(ofSize: CGFloat(text.height / lineHeightPerPoint))
        // A zero frame means "one line, no wrapping"; a real frame wraps at its width and stacks
        // lines down from its top edge, so put that edge at y=0 and make it tall enough for the
        // worst case of one glyph per line (lines past the frame's bottom are dropped).
        var frame = CGRect.zero
        if text.wrap
        {
            let height = CGFloat(text.height) * CGFloat(text.string.count + 1)
            frame = CGRect(x: 0, y: -height, width: CGFloat(text.width), height: height)
        }
        let mesh = MeshResource.generateText(
            text.string,
            extrusionDepth: 0, // flat, and already facing +Z
            font: font,
            containerFrame: frame,
            alignment: text.halign.realityAlignment,
            lineBreakMode: .byWordWrapping
        )
        let placement = text.placement(ofBlockFrom: mesh.bounds.min, to: mesh.bounds.max)

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


extension allonet2.Model.Mesh
{
    var realityMesh: RealityKit.MeshResource
    {
        switch self
        {
        case .builtin(name: let name): fatalError("Must use Model's factory to also load material")
        case .asset(id: let id): fatalError("not implemented")
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
