//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-29.
//

import Foundation
import AnyCodable


public struct Interaction : Codable
{
    public typealias RequestID = String
    
    public let type: InteractionType
    public let senderEntityId: EntityID
    public let receiverEntityId: EntityID
    public let requestId: RequestID
    public let body: InteractionBody
    
    public init(type: InteractionType, senderEntityId: String, receiverEntityId: String, requestId: RequestID = UUID().uuidString, body: InteractionBody) {
        self.type = type
        self.senderEntityId = senderEntityId
        self.receiverEntityId = receiverEntityId
        self.requestId = requestId
        self.body = body
    }
    
    public func makeResponse(with body: InteractionBody) -> Interaction
    {
        assert(type == .request)
        return Interaction(type: .response, senderEntityId: receiverEntityId, receiverEntityId: senderEntityId, requestId: requestId, body: body)
    }
    
    /// This is a magical Entity ID that means you're targeting an interaction to the place itself, rather than a specific entity within the place.
    public static let PlaceEntity: EntityID = "place"
}

public enum InteractionType: Codable
{
    case oneway
    case request
    case response
    case publication
}

public enum InteractionBody : Codable
{
    // - Agent to Place
    case announce(version: String, avatar: EntityDescription) // -> .announceResponse
    case announceResponse(avatarId: String, placeName: String)
    
    case createEntity(EntityDescription) // -> .createEntityResponse
    case createEntityResponse(entityId: EntityID)
    case removeEntity(entityId: EntityID, mode: EntityRemovalMode) // -> .success or .error
    case changeEntity(entityId: EntityID, addOrChange: [AnyComponent], remove: [ComponentTypeID]) // -> .success or .error
    
    // - Agent to agent
    case tap(at: SIMD3<Float>) // oneway
    
    // - Other
    case custom(value: [String: AnyCodable])
    
    // - Generic responses
    case error(domain: String, code: Int, description: String)
    case success // generic request-was-successful
    
    // - Internal, do not use
    case internal_renegotiate(SignallingDirection, SignallingPayload)
    
    // - Utilities
    // Get just the name of the interaction, for use as a unique key
    var caseName: String {
        let description = String(describing: self)
        if let parenIndex = description.firstIndex(of: "(") {
            return String(description[..<parenIndex])
        }
        return description
    }
}

public enum EntityRemovalMode: String, Codable
{
    case reparent // Child entities are reparented to root
    case cascade  // Child entities are also removed
}

public struct EntityDescription: Codable
{
    public let components: [AnyComponent]
    public let children: [EntityDescription]
    public init(components: [any Component] = [], children: [EntityDescription] = []) {
        self.components = components.map { AnyComponent($0) }
        self.children = children
    }
}



