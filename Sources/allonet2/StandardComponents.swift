//
//  StandardComponents.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import simd


struct Transform: Component
{
    let entityID: EntityID
    
    public var matrix: float4x4 = .init()
}


// MARK: - Internals

private let _registerStandardComponents: Void = {
    Transform.register()
}()
