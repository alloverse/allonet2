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
    public let type: InteractionType
    public let senderEntityId: String
    public let receiverEntityId: String
    public let requestId: String
    public let body: InteractionBody
    
    public init(type: InteractionType, senderEntityId: String, receiverEntityId: String, requestId: String = UUID().uuidString, body: InteractionBody) {
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
    case announce(version: String, avatarComponents: [AnyComponent])
    case announceResponse(avatarId: String, placeName: String)
    
    case createEntity(initialComponents: [AnyComponent])
    case createEntityResponse(entityId: EntityID)
    case removeEntity(entityId: EntityID, mode: EntityRemovalMode) // -> .success or .error
    case changeEntity(entityId: EntityID, addOrChange: [AnyComponent], remove: [ComponentTypeID]) // -> .success or .error
    
    case error(domain: String, code: Int, description: String)
    case success // generic request-was-successful
    case custom(value: [String: AnyCodable])
}

public enum EntityRemovalMode: String, Codable
{
    case reparent // Child entities are reparented to root
    case cascade  // Child entities are also removed
}


public let PlaceErrorDomain = "com.alloverse.place.error"
public enum PlaceErrorCode: Int
{
    case invalidRequest = 1 // request is malformed, programmer error
    case unauthorized = 2   // you're not allowed to do that
    case notFound = 3       // The thing you're requesting to modify couldn't be found
    
    case recipientUnavailable = 100 // no such entity, or agent not found for that entity
    case recipientTimedOut = 101 // agent didn't respond back to Place in a timely fashion. If it replies later, its response will be discarded.
}
struct AlloverseError: Error, Codable
{
    public let domain: String
    public let code: Int
    public let description: String
}

