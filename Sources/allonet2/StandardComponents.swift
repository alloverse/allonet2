//
//  StandardComponents.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import simd
import SIMDTools // for float4x4 codable
import PotentCodables

// MARK: Rendering/RealityKit related components
// These all have an almost 1-to-1 mapping to a corresponding RealityKit component.
// They are however designed to be implementable in other engines too.

/// A Transform defines the position, rotation and scale of an Entity.
public struct Transform: Component
{
    public var matrix: float4x4 = .init()
    
    public init()
    {
        matrix = float4x4.identity
    }
    
    public init(matrix: float4x4)
    {
        self.matrix = matrix
    }
    
    public init(
        translation: SIMD3<Float> = [0,0,0],
        rotation: simd_quatf = .identity,
        scale: SIMD3<Float> = [1,1,1]
    )
    {
        matrix = float4x4.identity
        matrix.translation = translation
        // TODO: Fix the math in the float4x4 extension
        matrix.rotation = rotation
        //matrix.scale = scale
    }
    
    var translation: SIMD3<Float> { matrix.translation }
    var rotation: simd_quatf { matrix.rotation }
    var scale: SIMD3<Float> { matrix.scale }
}

/// Entities can have a parent and multiple children. `Relationships` is used to establish the child-to-parent relationship, and the inverse is inferred. A child is always positioned relative to its parent (in other words, its Transform is concatenated with its parent and ancestors recursively to deduce where it is and what its rotation and scale is).
public struct Relationships: Component
{
    public var parent: EntityID
    public init(parent: EntityID) {
        self.parent = parent
    }
}

/// Visual aspect of an Entity: a 3D model which defines how to render it.
public struct Model: Component
{
    @MainActor
    public enum Mesh: Equatable, Codable
    {
        case builtin(name: String) // A mesh loaded from a client-provided file. This is a hack and will be replaced by Asset-based meshes
        /// A mesh fetched from the place by content address; the whole file is the visual, and
        /// nothing addresses inside it. One asset per thing that needs its own entity.
        case asset(id: AssetID)
        // The rest or basic geometric meshes
        case box(size: SIMD3<Float>, cornerRadius: Float)
        case plane(width: Float, depth: Float, cornerRadius: Float)
        case cylinder(height: Float, radius: Float)
        case sphere(radius: Float)
    }
    @MainActor
    public enum Material: Equatable, Codable
    {
        case standard // No material for basic geometry; or for builtin/asset: use the material from the loaded file.
        case color(color: Color, metallic: Bool)
        /// Base colour texture is the image asset (any raster format the renderer reads; PNG is safe).
        /// Alpha is respected: a transparent PNG lets the mesh's backdrop through. Applies to the
        /// primitive meshes only — like `.color`, a `.builtin` mesh keeps the material from its own file.
        case image(asset: AssetID)
    }

    public var mesh: Mesh
    public var material: Material

    public init(mesh: Mesh, material: Material = .standard)
    {
        self.mesh = mesh
        self.material = material
    }

    /// What a Model with an unparseable asset id decodes to: the renderer's red placeholder box.
    public static let unrenderable = Model(
        mesh: .box(size: .init(repeating: 0.5), cornerRadius: 0),
        material: .color(color: .rgb(red: 1, green: 0, blue: 0, alpha: 1), metallic: true))

    /// `AnyComponent.decoded()` force-tries, so throwing here would trap every client rendering the
    /// entity. A bad id can never name bytes, so degrade to `unrenderable` instead.
    public init(from decoder: any Decoder) throws
    {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do
        {
            mesh = try c.decode(Mesh.self, forKey: .mesh)
            material = try c.decode(Material.self, forKey: .material)
        }
        catch is AssetError
        {
            self = Self.unrenderable
        }
    }
}

/// A block of text drawn at the Entity, alongside any `Model` on it rather than instead of it: the
/// Model draws the entity's own mesh and the Text is its own geometry, so neither has to give up
/// being a mesh. Both sit at the entity origin, so a Text over a coplanar Model plane z-fights —
/// give the text its own child entity nudged along +Z.
///
/// Layout contract: the text is laid out in a box `width` metres wide, centred on the entity
/// origin; lines stack downwards and `halign` places the block across the box. `fit` decides what
/// `height` means and where `valign` measures from — a line height with the block hung on the
/// origin, or the second side of a box the block is scaled into. The text faces +Z of the entity's
/// transform (readable from +Z, like a RealityKit plane stood up) and has no depth. The font is the
/// renderer's choice; only the metric box is protocol.
///
/// The name is allonet1's and collides with `SwiftUI.Text` wherever both are imported: qualify it
/// as `allonet2.Text` in annotations and metatypes.
public struct Text: Component
{
    @MainActor
    public enum HorizontalAlignment: String, Equatable, Codable
    {
        case left, center, right
    }
    @MainActor
    public enum VerticalAlignment: String, Equatable, Codable
    {
        case top, middle, bottom
    }
    /// How `height` and `width` size the text.
    @MainActor
    public enum Fit: String, Equatable, Codable
    {
        /// `height` is the line height; `width` only bounds `wrap`. The block keeps that size
        /// however big it comes out.
        case lineHeight
        /// `.lineHeight`, but a block wider than `width` is scaled down until it fits.
        case shrinkToWidth
        /// `width` x `height` is a box centred on the origin, and the block is scaled — up as well
        /// as down — to the largest size that fits it, aspect preserved. `height` is then the box,
        /// not a line height: the rendered line height is whatever the fit works out to.
        case box
    }

    /// A renderer tessellates at most this many characters of `string`, and drops the rest. Glyph
    /// meshes are built synchronously on the thread that draws, so without a cap any peer can
    /// publish a megabyte of text and stall every client in the place. 1024 is a few paragraphs —
    /// orders of magnitude past the signs and labels this component is for — so the cap is only
    /// ever reached by something that isn't text to read.
    public static let maxRenderedCharacters = 1024

    public var string: String
    /// Metres. With `fit` `.lineHeight`/`.shrinkToWidth` it's the line height: baseline to baseline
    /// of consecutive lines, not the height of the glyphs you can see — a capital letter measures
    /// about 0.6 of it. With `.box` it's the height of the box the block is fitted into.
    public var height: Float
    /// Width of the layout box in metres. `.lineHeight` only lets `wrap` read it, so a single short
    /// line is laid out the same whatever it says; `.shrinkToWidth` and `.box` also fit to it.
    public var width: Float
    /// Break lines at `width`, before any fitting.
    public var wrap: Bool
    /// Whether `width`/`height` are advisory, a maximum, or a box. See `Fit`.
    public var fit: Fit
    public var halign: HorizontalAlignment
    public var valign: VerticalAlignment
    public var color: Color

    // No insertion marker/caret: YAGNI until there is a text field to edit.

    /// Whether the string has glyphs that exist only as colour bitmaps (emoji), which no outline
    /// font can draw. A renderer that builds text from glyph outlines has to rasterize such a
    /// string instead, and `color` then tints only the letters in it. Emoji-presentation scalars,
    /// and sequences (VS16, ZWJ, keycaps, flags); a bare text-presentation symbol like a sun or a
    /// warning sign has outlines (measured) and stays on the vector path.
    public var hasColorGlyphs: Bool
    {
        string.contains { character in
            guard let first = character.unicodeScalars.first else { return false }
            return first.properties.isEmojiPresentation
                || (first.properties.isEmoji && character.unicodeScalars.count > 1)
        }
    }

    public init(
        string: String,
        height: Float,
        width: Float,
        wrap: Bool = false,
        fit: Fit = .shrinkToWidth,
        halign: HorizontalAlignment = .center,
        valign: VerticalAlignment = .middle,
        color: Color = .white
    )
    {
        self.string = string
        self.height = height
        self.width = width
        self.wrap = wrap
        self.fit = fit
        self.halign = halign
        self.valign = valign
        self.color = color
    }
}

/// Defines the collision shape of the Entity, mainly for defining the InputTarget tap area.
public struct Collision: Component
{
    @MainActor
    public enum Shape: Equatable, Codable
    {
        case box(size: SIMD3<Float>)
    }
    
    public var shapes: [Shape]
    public init(shapes: [Shape])
    {
        self.shapes = shapes
    }
}

/// An Entity with an InputTarget component will be tappable, and can receive the `tap(at:)` Interaction from other users. Note that an InputTarget also requires a `Collision` to define the tappable area.
public struct InputTarget: Component
{
    public init() {}
}

/// This entity may be grabbed and moved by any user, via `Intent.grab` (ported from
/// allonet1's `grabbable`; there is no per-user authorization). The place server applies
/// the grab within these constraints. Requires `Collision` (+ usually `InputTarget`) for
/// the client to have something to hit-test the grab against.
public struct Grabbable: Component
{
    /// Which entity a grab of this entity actually moves: itself, or an ancestor —
    /// for a grab handle that moves the widget it sits on.
    @MainActor
    public enum ActuateOn: Codable, Equatable
    {
        case entity
        case parent
        case ancestor(EntityID)
    }
    public var actuateOn: ActuateOn
    /// Fraction of translation allowed per axis of the actuated entity's local space,
    /// measured from where the grab started. [1,1,0] pins z: a wall sign slides in its
    /// wall plane. 0...1.
    public var translationConstraint: SIMD3<Float>
    /// Fraction of rotation allowed per euler axis, likewise. [0,0,0] = never rotates.
    public var rotationConstraint: SIMD3<Float>

    public init(actuateOn: ActuateOn = .entity,
                translationConstraint: SIMD3<Float> = [1,1,1],
                rotationConstraint: SIMD3<Float> = [1,1,1])
    {
        self.actuateOn = actuateOn
        self.translationConstraint = translationConstraint
        self.rotationConstraint = rotationConstraint
    }
}

/// A client-side effect highlighting an Entity and its children whenever the user's cursor is over it.
public struct HoverEffect: Component
{
    @MainActor
    public enum Style: Equatable, Codable
    {
        case spotlight(color: Color, strength: Float)
    }
    public var style: Style
    public init(style: Style)
    {
        self.style = style
    }
}

/// How transparent this entire entity should be
public struct Opacity: Component
{
    public var opacity: Float
    public init(opacity: Float)
    {
        self.opacity = opacity
    }
}

/// A Billboarded Entity always faces the camera, regardless of perspective.
public struct Billboard: Component
{
    // A blendFactor of 1.0 will make the Entity be entirely rotated towards the camera, and 0.0 not at all.
    public var blendFactor: Float
    public init(blendFactor: Float = 1.0)
    {
        self.blendFactor = blendFactor
    }
}

// MARK: Audio/video related components

/// The LiveMedia component describes an available media stream that can be consumed in real time by other connected agents. For example, it can be attached to the "mouth" of an avatar to correspond to live audio chat for that avatar, where `mediaId` names the stream carrying the user's microphone audio.
public struct LiveMedia: Component
{
    public var mediaId: MediaStreamId
    @MainActor
    public enum AudioCodec: Codable, Equatable
    {
        case opus
    }
    @MainActor
    public enum VideoCodec: Codable, Equatable
    {
        case mjpeg
        case h264
    }
    @MainActor
    public enum Format: Codable, Equatable
    {
        case audio(codec: AudioCodec, sampleRate: Int, channelCount: Int)
        case video(codec: VideoCodec, width: Int, height: Int)
    }
    public var format: Format
    
    public init(mediaId: MediaStreamId, format: Format) {
        self.mediaId = mediaId
        self.format = format
    }
}

// TODO: An equivalent of SpatialAudioComponent, which pairs up with LiveMedia to control how the audio coming out of the entity they're both attached to comes out in the spatial audio field.

/// The LiveMediaListener component tells the AlloPlace which `LiveMedia` streams that the agent that owns this entity wants to receive. Adding a mediaId to this list makes the place forward that stream in on a data channel of its own, arriving as a `MediaStream` with the same id. The receiving agent process can then play that audio back at the spatial location of the entity with the corresponding `LiveMedia` component.
public struct LiveMediaListener: Component
{
    public var mediaIds: Set<MediaStreamId>
    public init(mediaIds: Set<MediaStreamId>)
    {
        self.mediaIds = mediaIds
    }
}

// MARK: - Custom components
// You can implement your own Component subtypes and use them, as long as the compile time types are available to both producers and consumers of the type. If you provide a type that isn't available on the other side, it will be decoded as a CustomComponent that you can still use, but without type safety.

public struct CustomComponent
{
    public var typeId: ComponentTypeID
    public var fields: AnyValue
}

// MARK: - Implementation details
// These are protocol implementation detaults, and should not be used by third parties.

/// VisorInfo is attached to the avatar for a connected UI user to inform other users' what their name and other Identity info is.
public struct VisorInfo: Component
{
    public var displayName: String
    /// The user's chosen color, from their Identity.
    public var color: Color
    /// Asset id of the user's picture, or nil for none. Set this only once the bytes are published
    /// — `AlloClient.publish` returning is the promise that they are. Referencing an id the place
    /// doesn't have gets consumers a 404, and since the component then never changes again, nothing
    /// would make them try a second time.
    public var profileImage: AssetID?
    public init(displayName: String, color: Color = .white, profileImage: AssetID? = nil)
    {
        self.displayName = displayName
        self.color = color
        self.profileImage = profileImage
    }

    /// A component is whatever a peer put there, and `AnyComponent.decoded()` force-tries — so a
    /// throwing decode here would trap in every client that renders this person. An id we can't
    /// parse means they have no picture; their name and colour still arrive.
    public init(from decoder: any Decoder) throws
    {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        color = try c.decode(Color.self, forKey: .color)
        profileImage = try c.decodeIfPresent(String.self, forKey: .profileImage).flatMap(AssetID.init)
    }
}

/// When a new user joins a Place, the Place looks for a random SpawnPoint component'd Entity, and sets the new user's transform to that entity's transform. If none is found, the user is placed at 0,0,0.
public struct SpawnPoint: Component
{
    public init() {}
}

// MARK: - Related types
// Types that are not Components, but used by Components

public enum Color: Equatable, Hashable, Sendable, Codable
{
    case rgb(red: Float, green: Float, blue: Float, alpha: Float)
    case hsv(hue: Float, saturation: Float, value: Float, alpha: Float)
    
    public static var white: Color { .rgb(red: 1, green: 1, blue: 1, alpha: 1) }
    public static var black: Color { .rgb(red: 0, green: 0, blue: 0, alpha: 1) }
    public static var red: Color { .rgb(red: 1, green: 0, blue: 0, alpha: 1) }
    public static var green: Color { .rgb(red: 0, green: 1, blue: 0, alpha: 1) }
    public static var blue: Color { .rgb(red: 0, green: 0, blue: 1, alpha: 1) }
    public static var yellow: Color { .rgb(red: 1, green: 1, blue: 0, alpha: 1) }
    public static var cyan: Color { .rgb(red: 0, green: 1, blue: 1, alpha: 1) }
    public static var magenta: Color { .rgb(red: 1, green: 0, blue: 1, alpha: 1) }
    public static var orange: Color { .rgb(red: 1, green: 0.5, blue: 0, alpha: 1) }
    public static var pink: Color { .rgb(red: 1, green: 0.8, blue: 0.8, alpha: 1) }
}

// MARK: - Component internals

@MainActor
func RegisterStandardComponents()
{
    Transform.register()
    Relationships.register()
    Model.register()
    Text.register()
    VisorInfo.register()
    Collision.register()
    InputTarget.register()
    Grabbable.register()
    HoverEffect.register()
    Opacity.register()
    Billboard.register()
    VisorInfo.register()
    LiveMedia.register()
    LiveMediaListener.register()
    SpawnPoint.register()
}

extension Text
{
    /// Whether `width` and `height` describe a box text can be laid out in at all. They become a
    /// point size and a scale, so a hostile NaN or a zero turns into a NaN transform downstream.
    public var hasLayoutBox: Bool { width.isFinite && width > 0 && height.isFinite && height > 0 }

    /// Where a laid-out block of text has to sit, and how much to scale it, given the size the
    /// renderer's font made it: the box is `width` wide and centred on the entity origin, `halign`
    /// puts the block across it, and `fit` decides the scale and what `valign` measures against —
    /// the origin, or the `height`-tall box the block was fitted into. Renderer-independent by
    /// design: every renderer measures its own glyphs and then needs this same answer.
    ///
    /// Nil means don't render: `width`/`height` come off the wire, and a peer's zero, negative or
    /// non-finite size has no placement — only a NaN scale that would poison a transform.
    public func placement(ofBlockFrom min: SIMD3<Float>, to max: SIMD3<Float>) -> (scale: Float, translation: SIMD3<Float>)?
    {
        guard hasLayoutBox,
              min.x.isFinite, min.y.isFinite, max.x.isFinite, max.y.isFinite else { return nil }

        let blockWidth = max.x - min.x, blockHeight = max.y - min.y
        let scale: Float
        switch fit
        {
        case .lineHeight:
            scale = 1
        case .shrinkToWidth:
            scale = (blockWidth > width && blockWidth > 0) ? width / blockWidth : 1
        case .box:
            scale = (blockWidth > 0 && blockHeight > 0) ? Swift.min(width / blockWidth, height / blockHeight) : 1
        }
        let lo = min * scale, hi = max * scale
        // Only `.box` gives the box a height; otherwise `valign` hangs the block on the origin,
        // which is the same arithmetic against a zero-height box.
        let boxHeight = fit == .box ? height : 0
        var translation = SIMD3<Float>.zero
        switch halign
        {
        case .left:   translation.x = -width/2 - lo.x
        case .center: translation.x = -(lo.x + hi.x)/2
        case .right:  translation.x = width/2 - hi.x
        }
        switch valign
        {
        case .top:    translation.y = boxHeight/2 - hi.y
        case .middle: translation.y = -(lo.y + hi.y)/2
        case .bottom: translation.y = -boxHeight/2 - lo.y
        }
        return (scale, translation)
    }

    public func indentedDescription(_ prefix: String) -> String
    {
        "\(prefix)Text: \"\(string)\" \(height)m in a \(width)m box, \(fit), \(halign)/\(valign)"
    }
}

extension Transform
{
    public func indentedDescription(_ prefix: String) -> String
    {
        let t = self.translation
        let raxis = self.rotation.axis
        let rangle = self.rotation.angle * (180.0/Float.pi)
        let s = self.scale
        
        var desc = """
            \(prefix)Transform:
                translation [\(t.x), \(t.y), \(t.z)]
                rotation \(rangle)° around [\(raxis.x), \(raxis.y), \(raxis.z)]
                scale [\(s.x), \(s.y), \(s.z)]
        """
        
        return desc
    }
}
