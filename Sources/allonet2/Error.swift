//
//  Error.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-05-07.
//

import Foundation

public protocol ErrorDomainProviding {
    static var domain: String { get }
}

// Errors raised by the PlaceServer
public enum PlaceErrorCode: Int, ErrorDomainProviding
{
    public static let domain = "com.alloverse.place.error"
    case invalidRequest = 1 // request is malformed, programmer error
    case unauthorized = 2   // you're not allowed to do that
    case notFound = 3       // The thing you're requesting to modify couldn't be found
    case invalidResponse = 4 // Couldn't pair the response with a previous request
    
    case recipientUnavailable = 100 // no such entity, or agent not found for that entity
    case recipientTimedOut = 101 // agent didn't respond back to Place in a timely fashion. If it replies later, its response will be discarded.
    
    static public let fatalErrorCodes: [Self] = [.unauthorized]
    // If true, the client should be disconnected immediately after response is sent
    public var isFatal: Bool { Self.fatalErrorCodes.contains(self) }
}

// Errors raised by protocol errors
public enum AlloverseErrorCode: Int, ErrorDomainProviding
{
    public static let domain = "com.alloverse.error"
    // Interaction related errors
    case unhandledRequest = 1   // The recipient doesn't know how to respond to this interaction
    case unexpectedResponse = 2 // Interaction received some other response than was expected
    
    // Low level protocol errors
    case incompatibleProtocolVersion = 10 // Client's allonet is too old or too new
    
    // WebRTC related errors
    case failedSignalling = 100 // Failed to establish signalling
    case failedRenegotiation = 101 // Connection environment changed, but underlying connection failed to adapt
    case discardedRenegotiation = 102 // Renegotiation request is politely declined. Please roll back your offer and wait for other side to send _its_ offer.
    case disconnected = 103 // The session went away before the response to your request arrived. Raised locally; never sent.
    
    // Internal errors
    case internalServerError = 500
    
    static public let fatalErrorCodes: [Self] = [.incompatibleProtocolVersion]
    // If true, the client should be disconnected immediately after response is sent
    public var isFatal: Bool { Self.fatalErrorCodes.contains(self) }
}
public struct AlloverseError: LocalizedError, Codable
{
    public let domain: String
    public let code: Int
    public let description: String
    /// What the raiser said about permanence, or nil if it didn't say. Distinct from `isFatal`,
    /// which falls back to the code tables when nobody did.
    private let statedIsFatal: Bool?
    public var errorDescription: String? {
        return "\(domain) \(code): \(description)"
    }

    public init(domain: String, code: Int, description: String, overrideIsFatal: Bool = false)
    {
        self.domain = domain
        self.code = code
        self.description = description
        self.statedIsFatal = overrideIsFatal ? true : nil
    }
    public init<E>(code: E, description: String, overrideIsFatal: Bool = false) where E: RawRepresentable, E.RawValue == Int, E: ErrorDomainProviding
    {
        self.init(domain: E.domain, code: code.rawValue, description: description, overrideIsFatal: overrideIsFatal)
    }
    public init(with unexpectedBody: InteractionBody, overrideIsFatal: Bool = false)
    {
        switch unexpectedBody
        {
        case .error(let domain, let code, let description, let isFatal):
            self.domain = domain
            self.code = code
            self.description = description
            // Otherwise the peer's word, since it owns the domain and our tables can't classify a
            // code that isn't ours. Overriding still wins: a place refusing a login knows that's
            // permanent even when the app that rejected it didn't say so.
            self.statedIsFatal = overrideIsFatal ? true : isFatal
            return
        default:
            self.domain = AlloverseErrorCode.domain
            self.code = AlloverseErrorCode.unexpectedResponse.rawValue
            self.description = "Unexpected body: \(unexpectedBody)"
            self.statedIsFatal = overrideIsFatal ? true : nil
        }
    }

    /// Carries `isFatal` resolved rather than as stated, so a code the receiver has no table for —
    /// which is every error raised by an app rather than by allonet — still says whether it's worth
    /// retrying. Without it a rejected login reads as a hiccup, and the visor retries it forever.
    public var asBody: InteractionBody { .error(domain: domain, code: code, description: description, isFatal: isFatal) }

    // If true, the client should be disconnected immediately after response is sent.
    // Codes arrive off the wire, so an unknown one is a peer we don't fully understand rather
    // than a programmer error: treat it as non-fatal instead of trapping on the unwrap.
    public var isFatal: Bool {
        if let statedIsFatal { return statedIsFatal }
        return switch domain {
            case AlloverseErrorCode.domain: AlloverseErrorCode(rawValue: code)?.isFatal ?? false
            case PlaceErrorCode.domain: PlaceErrorCode(rawValue: code)?.isFatal ?? false
            default: false
        }
    }
}
