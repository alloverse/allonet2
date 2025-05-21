//
//  Error.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-05-07.
//

import Foundation

// Errors raised by the PlaceServer
public enum PlaceErrorCode: Int
{
    public static let domain = "com.alloverse.place.error"
    case invalidRequest = 1 // request is malformed, programmer error
    case unauthorized = 2   // you're not allowed to do that
    case notFound = 3       // The thing you're requesting to modify couldn't be found
    case invalidResponse = 4 // Couldn't pair the response with a previous request
    
    case recipientUnavailable = 100 // no such entity, or agent not found for that entity
    case recipientTimedOut = 101 // agent didn't respond back to Place in a timely fashion. If it replies later, its response will be discarded.
}

// Errors raised by protocol errors
public enum AlloverseErrorCode: Int
{
    public static let domain = "com.alloverse.error"
    case unhandledRequest = 1   // The recipient doesn't know how to respond to this interaction
    case unexpectedResponse = 2 // Interaction received some other response than was expected
    
    case failedSignalling = 100 // Failed to establish signalling
    case failedRenegotiation = 101 // Connection environment changed, but underlying connection failed to adapt
}
public struct AlloverseError: LocalizedError, Codable
{
    public let domain: String
    public let code: Int
    public let description: String
    public var errorDescription: String? {
        return "\(domain) \(code): \(description)"
    }
    
    public init(domain: String, code: Int, description: String) {
        self.domain = domain
        self.code = code
        self.description = description
    }
    public init(with unexpectedBody: InteractionBody)
    {
        switch unexpectedBody
        {
        case .error(let domain, let code, let description):
            self.domain = domain
            self.code = code
            self.description = description
        default:
            self.domain = AlloverseErrorCode.domain
            self.code = AlloverseErrorCode.unexpectedResponse.rawValue
            self.description = "Unexpected body: \(unexpectedBody)"
        }
    }
    
    public var asBody: InteractionBody { .error(domain: domain, code: code, description: description) }
}
