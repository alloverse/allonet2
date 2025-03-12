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

extension EntityID
{
    static func random() -> EntityID
    {
        return UUID().uuidString
    }
}
