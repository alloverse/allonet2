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


// MARK: - Internals

func RegisterStandardComponents()
{
    Transform.register()
}
