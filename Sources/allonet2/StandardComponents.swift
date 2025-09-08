//
//  StandardComponents.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import simd

// MARK: Rendering/RealityKit related components
// These all have an almost 1-to-1 mapping to a corresponding RealityKit component.
// They are however designed to be implementable in other engines too.

public struct Transform: Component
{
    public var matrix: float4x4 = .init()
    
    public init()
    {
        matrix = float4x4.identity
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
}

public struct Relationships: Component
{
    public var parent: EntityID
    public init(parent: EntityID) {
        self.parent = parent
    }
}

public struct Model: Component
{
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

public struct Collision: Component
{
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

public struct InputTarget: Component
{
    public init() {}
}

public struct HoverEffect: Component
{
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

public struct Opacity: Component
{
    public var opacity: Float
    public init(opacity: Float)
    {
        self.opacity = opacity
    }
}

public struct Billboard: Component
{
    public var blendFactor: Float
    public init(blendFactor: Float = 1.0)
    {
        self.blendFactor = blendFactor
    }
}

/// The LiveMedia component describes an available media stream that can be consumed in real time by other connected agents. For example, it can be attached to the "mouth" of an avatar to correspond to live audio chat for that avatar, with the corresponding mediaId track broadcasting the user's microphone audio.
public struct LiveMedia: Component
{
    public var mediaId: String
    public enum AudioCodec: Codable, Equatable
    {
        case opus
    }
    public enum VideoCodec: Codable, Equatable
    {
        case mjpeg
        case h264
    }
    public enum Format: Codable, Equatable
    {
        case audio(codec: AudioCodec, sampleRate: Int, channelCount: Int)
        case video(codec: VideoCodec, width: Int, height: Int)
    }
    public var format: Format
}

// TODO: An equivalent of SpatialAudioComponent, which pairs up with LiveMedia to control how the audio coming out of the entity they're both attached to comes out in the spatial audio field.

/// The LiveMediaListener component tells the AlloPlace which `LiveMedia` streams that the agent that owns this entity wants to receive. By adding a mediaId to this list, a corresponding WebRTC audio track will come in with that ID as `mid`. The receiving agent process can then play that audio back at the spatial location of the entity with the corresponding `LiveMedia` component.
public struct LiveMediaListener: Component
{
    public var mediaIds: Set<String>
}

// MARK: - Custom components
// These shouldn't be in StandardComponents, but because Alloverse v2 doesn't have support
// for schemas outside of the built-in component types yet, they go in here anyway.

public struct VisorInfo: Component
{
    public var displayName: String
    public init(displayName: String)
    {
        self.displayName = displayName
    }
}

// MARK: - Related types

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

// MARK: - Internals

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
}
