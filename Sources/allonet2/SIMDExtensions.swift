//
//  SIMD.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-11-20.
//

import simd

public extension simd_float3x3 {
    static func * (lhs: simd_float3x3, rhs: SIMD2<Float>) -> SIMD2<Float> {
        let vec3 = SIMD3<Float>(rhs, 1)
        let transformed = lhs * vec3
        return transformed.xy
    }
}

extension simd_float4x4 {
    public static var identity: simd_float4x4 {
        return matrix_identity_float4x4
    }
    public var translation: SIMD3<Float> {
        get {
            return SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
        }
        set {
            columns.3 = SIMD4<Float>(newValue.x, newValue.y, newValue.z, columns.3.w)
        }
    }
    
    public var scale: SIMD3<Float> {
        get {
            // The scale is the length of each column vector (ignoring the homogeneous component).
            let scaleX = length(SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z))
            let scaleY = length(SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z))
            let scaleZ = length(SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z))
            return SIMD3<Float>(scaleX, scaleY, scaleZ)
        }
        set {
            // Update the rotation part to apply the new scale while preserving the current rotation.
            let currentRotation = self.rotation
            let rotationMatrix = float3x3(currentRotation)
            columns.0 = SIMD4<Float>(rotationMatrix.columns.0 * newValue.x, 0)
            columns.1 = SIMD4<Float>(rotationMatrix.columns.1 * newValue.y, 0)
            columns.2 = SIMD4<Float>(rotationMatrix.columns.2 * newValue.z, 0)
        }
    }
    
    /// The rotation component as a quaternion.
    public var rotation: simd_quatf {
        get {
            // Remove the scaling from the upper-left 3x3 part.
            let currentScale = self.scale
            let col0 = SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z) / (currentScale.x != 0 ? currentScale.x : 1)
            let col1 = SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z) / (currentScale.y != 0 ? currentScale.y : 1)
            let col2 = SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z) / (currentScale.z != 0 ? currentScale.z : 1)
            let rotationMatrix = float3x3(col0, col1, col2)
            return simd_quatf(rotationMatrix)
        }
        set {
            // Preserve the current scale while setting a new rotation.
            let currentScale = self.scale
            let rotationMatrix = float3x3(newValue)
            columns.0 = SIMD4<Float>(rotationMatrix.columns.0 * currentScale.x, 0)
            columns.1 = SIMD4<Float>(rotationMatrix.columns.1 * currentScale.y, 0)
            columns.2 = SIMD4<Float>(rotationMatrix.columns.2 * currentScale.z, 0)
        }
    }
}

public extension simd_float4x4
{
    static func * (lhs: simd_float4x4, rhs: SIMD3<Float>) -> SIMD3<Float> {
        let vec4 = SIMD4<Float>(rhs, 1)
        let transformed = lhs * vec4
        return transformed.xyz
    }
}

public extension simd_quatf
{
    public static var identity: simd_quatf
    {
        simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
}

public extension SIMD3
{
    var xy: SIMD2<Scalar>
    {
        SIMD2<Scalar>(self.x, self.y)
    }
}

public extension SIMD4
{
    var xyz: SIMD3<Scalar>
    {
        SIMD3<Scalar>(self.x, self.y, self.z)
    }
}
