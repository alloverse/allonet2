//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-28.
//

import Foundation
import simd

func with<T>(_ value: T, using closure: (inout T) -> Void) -> T {
    var copy = value
    closure(&copy)
    return copy
}

extension Dictionary {
    subscript(key: Key, setDefault defaultValue: @autoclosure () -> Value) -> Value {
        mutating get {
            return self[key] ?? {
                let value = defaultValue()
                self[key] = value
                return value
            }()
        }
    }
}

extension float4x4 : Codable
{
    public func encode(to encoder: Encoder) throws
    {
        var container = encoder.unkeyedContainer()
        // Encode in row-major order: for each row, encode all columns.
        for row in 0..<4
        {
            for col in 0..<4
            {
                try container.encode(self[col][row])
            }
        }
    }
    
    public init(from decoder: Decoder) throws
    {
        var container = try decoder.unkeyedContainer()
        var matrix = simd_float4x4()
        // Decode in row-major order.
        for row in 0..<4
        {
            for col in 0..<4
            {
                let value = try container.decode(Float.self)
                matrix[col][row] = value
            }
        }
        self = matrix
    }
}

extension simd_float4x4 {
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

extension EntityID
{
    static func random() -> EntityID
    {
        return UUID().uuidString
    }
}

public extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// Utility for command line AlloApps. Run as last line to keep process running while app is processing requests.
public func parkToRunloop() async -> Never {
    await withUnsafeContinuation { _ in }
}
