//
//  StandardComponents.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import simd


public struct Transform: Component
{
    public var matrix: float4x4 = .init()
    
    public init()
    {
        matrix = float4x4.identity
    }
    
    public init(
        translation: SIMD3<Float> = [0,0,0],
        rotation: simd_quatf = simd_quatf(),
        scale: SIMD3<Float> = [1,1,1]
    )
    {
        matrix = float4x4.identity
        matrix.translation = translation
        // TODO: Fix the math in the float4x4 extension
        //matrix.rotation = rotation
        //matrix.scale = scale
    }
}

public enum Color: Equatable, Codable
{
    case rgb(red: Float, green: Float, blue: Float, alpha: Float)
    case hsv(hue: Float, saturation: Float, value: Float, alpha: Float)
    
    static var white: Color { .rgb(red: 1, green: 1, blue: 1, alpha: 1) }
    static var black: Color { .rgb(red: 0, green: 0, blue: 0, alpha: 1) }
    static var red: Color { .rgb(red: 1, green: 0, blue: 0, alpha: 1) }
    static var green: Color { .rgb(red: 0, green: 1, blue: 0, alpha: 1) }
    static var blue: Color { .rgb(red: 0, green: 0, blue: 1, alpha: 1) }
    static var yellow: Color { .rgb(red: 1, green: 1, blue: 0, alpha: 1) }
    static var cyan: Color { .rgb(red: 0, green: 1, blue: 1, alpha: 1) }
    static var magenta: Color { .rgb(red: 1, green: 0, blue: 1, alpha: 1) }
    static var orange: Color { .rgb(red: 1, green: 0.5, blue: 0, alpha: 1) }
    static var pink: Color { .rgb(red: 1, green: 0.8, blue: 0.8, alpha: 1) }
}

public struct Model: Component
{
    public enum Mesh: Equatable, Codable
    {
        case asset(id: String)
        case box(size: SIMD3<Float>, cornerRadius: Float)
        case plane(width: Float, depth: Float, cornerRadius: Float)
        case cylinder(height: Float, radius: Float)
        case sphere(radius: Float)
    }
    public enum Material: Equatable, Codable
    {
        case color(color: Color, metallic: Bool)
    }

    public var mesh: Mesh
    public var material: Material
    
    public init(mesh: Mesh, material: Material)
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

public struct VisorInfo: Component
{
    public var displayName: String
    public init(displayName: String)
    {
        self.displayName = displayName
    }
}

// MARK: - Internals

func RegisterStandardComponents()
{
    Transform.register()
    Model.register()
    VisorInfo.register()
    Collision.register()
    InputTarget.register()
}
