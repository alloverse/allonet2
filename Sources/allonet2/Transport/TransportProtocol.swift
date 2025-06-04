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
public protocol Transport: AnyObject {
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

public enum DataChannelLabel: String
{
    case intentWorldState = "worldstate"
    case interactions = "interactions"
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
