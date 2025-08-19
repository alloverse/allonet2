//
//  TransportProtocol.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation

public typealias ClientId = UUID

public protocol TransportDelegate: AnyObject {
    func transport(didConnect transport: Transport)
    func transport(didDisconnect transport: Transport)
    func transport(_ transport: Transport, didReceiveData data: Data, on channel: DataChannel)
    func transport(_ transport: Transport, didReceiveMediaStream stream: MediaStream)
    func transport(requestsRenegotiation transport: Transport)
}

// A Transport wraps a WebRTC peer connection with Alloverse specific peer semantics, but no business logic
public protocol Transport: AnyObject
{
    init(with connectionOptions: TransportConnectionOptions, status: ConnectionStatus)
    
    var clientId: ClientId? { get }
    var delegate: TransportDelegate? { get set }
    
    // Connection lifecycle
    func generateOffer() async throws -> SignallingPayload
    func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload
    func acceptAnswer(_ answer: SignallingPayload) async throws
    func disconnect()
    
    // Data channels
    func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel?
    func send(data: Data, on channel: DataChannelLabel)
}

public struct TransportConnectionOptions: Sendable
{
    public let routing: TransportRouting
    public let ipOverride: IPOverride?
    public let portRange: Range<Int>?
    
    public init(routing: TransportRouting = .direct, ipOverride: IPOverride? = nil, portRange: Range<Int>? = nil)
    {
        self.routing = routing
        self.ipOverride = ipOverride
        self.portRange = portRange
    }
}

public enum TransportRouting
{
    case direct // no STUN nor TURN
    // STUN allows NAT hole punching using a third party
    case standardSTUN // Google, Twilio and some other free options
    case STUN(servers: [String])
}

public struct IPOverride
{
    public let from: String
    public let to: String
    
    public init(from: String, to: String)
    {
        self.from = from
        self.to = to
    }
}

public enum DataChannelLabel: String
{
    case interactions = "interactions"
    case intentWorldState = "worldstate"
}

extension DataChannelLabel
{
    public var channelId: Int32 { get {
        switch self {
        case .interactions: 1
        case .intentWorldState: 2
        }
    } }
}

public protocol DataChannel {
    var label: DataChannelLabel { get }
    var isOpen: Bool { get }
}

public protocol MediaStream {
    var streamId: String { get }
}

public protocol AudioTrack {
    var isEnabled: Bool { get set }
}
