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
        case asset(id: String) // A mesh loaded by requesting it over the network from the agent that publishes it
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
    }

    public var mesh: Mesh
    public var material: Material
    
    public init(mesh: Mesh, material: Material = .standard)
    {
        self.mesh = mesh
        self.material = material
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

/// The LiveMedia component describes an available media stream that can be consumed in real time by other connected agents. For example, it can be attached to the "mouth" of an avatar to correspond to live audio chat for that avatar, with the corresponding mediaId track broadcasting the user's microphone audio.
public struct LiveMedia: Component
{
    public var mediaId: String // PlaceStreamId
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
    
    public init(mediaId: String, format: Format) {
        self.mediaId = mediaId
        self.format = format
    }
}

// TODO: An equivalent of SpatialAudioComponent, which pairs up with LiveMedia to control how the audio coming out of the entity they're both attached to comes out in the spatial audio field.

/// The LiveMediaListener component tells the AlloPlace which `LiveMedia` streams that the agent that owns this entity wants to receive. By adding a mediaId to this list, a corresponding WebRTC audio track will come in with that ID as `mid`. The receiving agent process can then play that audio back at the spatial location of the entity with the corresponding `LiveMedia` component.
public struct LiveMediaListener: Component
{
    public var mediaIds: Set<String>
    public init(mediaIds: Set<String>)
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
    public init(displayName: String)
    {
        self.displayName = displayName
    }
}

/// When a new user joins a Place, the Place looks for a random SpawnPoint component'd Entity, and sets the new user's transform to that entity's transform. If none is found, the user is placed at 0,0,0.
public struct SpawnPoint: Component
{
    public init() {}
}

// MARK: - Related types
// Types that are not Components, but used by Components

public enum Color: Equatable, Codable
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
    VisorInfo.register()
    Collision.register()
    InputTarget.register()
    HoverEffect.register()
    Opacity.register()
    Billboard.register()
    VisorInfo.register()
    LiveMedia.register()
    LiveMediaListener.register()
    SpawnPoint.register()
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
