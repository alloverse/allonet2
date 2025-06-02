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
    func transport(_ transport: Transport, didReceiveData data: Data, on channel: String)
    func transport(_ transport: Transport, didReceiveMediaStream stream: MediaStream)
    func transport(requestsRenegotiation transport: Transport)
}

public protocol Transport: AnyObject {
    var clientId: ClientId? { get }
    var delegate: TransportDelegate? { get set }
    
    // Connection lifecycle
    func generateOffer() async throws -> SignallingPayload
    func generateAnswer(offer: SignallingPayload) async throws -> SignallingPayload
    func acceptAnswer(_ answer: SignallingPayload) async throws
    func disconnect()
    
    // Data channels
    func createDataChannel(label: String, reliable: Bool) -> DataChannel?
    func send(data: Data, on channel: String)
    
    // Media (client-only methods, server implements as no-ops or throws)
    func createMicrophoneTrack() throws -> AudioTrack
    func setMicrophoneEnabled(_ enabled: Bool)
    func addOutgoingStream(_ stream: MediaStream)
}

public protocol DataChannel {
    var label: String { get }
    var isOpen: Bool { get }
}

public protocol MediaStream {
    var streamId: String { get }
}

public protocol AudioTrack {
    var isEnabled: Bool { get set }
}