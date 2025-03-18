//
//  StandardComponents.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import simd


public struct Transform: Component
{
    public let entityID: EntityID
    
    public var matrix: float4x4 = .init()
    
    public init(position: SIMD3<Float>)
    {
        matrix = float4x4()
        matrix.translation = position
        entityID = ""
    }
}


// MARK: - Internals

func RegisterStandardComponents()
{
    Transform.register()
}
