//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-29.
//

import Foundation

public struct Interaction : Codable
{
    public let type: InteractionType
    public let senderEntityId: String
    public let receiverEntityId: String
    public let requestId: String
    public let body: CodableValue
    
    public init(type: InteractionType, senderEntityId: String, receiverEntityId: String, requestId: String, body: CodableValue) {
        self.type = type
        self.senderEntityId = senderEntityId
        self.receiverEntityId = receiverEntityId
        self.requestId = requestId
        self.body = body
    }
}

public enum InteractionType: Codable
{
    case oneway
    case request
    case response
    case publication
}

public enum CodableValue: Codable, CustomDebugStringConvertible {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case list([CodableValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode([CodableValue].self) {
            self = .list(value)
        } else {
            throw DecodingError.typeMismatch(CodableValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .list(let value):
            try container.encode(value)
        }
    }
    
    public var debugDescription: String {
        switch self {
        case .string(let value):
            return "\"\(value)\""
        case .number(let value):
            return "\(value)"
        case .boolean(let value):
            return "\(value)"
        case .list(let values):
            return "[\(values.map { $0.debugDescription }.joined(separator: ", "))]"
        }
    }
}

extension CodableValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}
extension CodableValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}
extension CodableValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}
extension CodableValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}
extension CodableValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: CodableValue...) {
        self = .list(elements)
    }
}
