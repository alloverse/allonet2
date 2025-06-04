//
//  HeadlessWebRTCTransport.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation

// Temporary stub for server - you'll replace this with your chosen server WebRTC implementation
public class HeadlessWebRTCTransport: Transport {
    public weak var delegate: TransportDelegate?
    public private(set) var clientId: ClientId?
    
    private var channels: [DataChannelLabel: ServerDataChannel] = [:]
    
    public init() {
        // TODO: Initialize your server-side WebRTC implementation
    }
    
    public func generateOffer() async throws -> SignallingPayload {
        // TODO: Implement with server WebRTC library
        throw TransportError.notImplemented
    }
    
    public func generateAnswer(for: SignallingPayload) async throws -> SignallingPayload
    {
        clientId = UUID()
        // TODO: Implement with server WebRTC library
        throw TransportError.notImplemented
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws {
        clientId = answer.clientId
        // TODO: Implement with server WebRTC library
        throw TransportError.notImplemented
    }
    
    public func disconnect() {
        // TODO: Implement cleanup
    }
    
    public func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel? {
        let channel = ServerDataChannel(label: label)
        channels[label] = channel
        return channel
    }
    
    public func send(data: Data, on channelLabel: DataChannelLabel) {
        // TODO: Implement with server WebRTC library
    }
    
    // Media operations not supported on server
    public func createMicrophoneTrack() throws -> AudioTrack {
        throw TransportError.mediaNotSupported
    }
    
    public func setMicrophoneEnabled(_ enabled: Bool) {
        // No-op on server
    }
    
    public func addOutgoingStream(_ stream: MediaStream) {
        // TODO: Implement stream forwarding when you have server WebRTC library
    }
}

public enum TransportError: Error {
    case notImplemented
    case mediaNotSupported
}

private class ServerDataChannel: DataChannel {
    let label: DataChannelLabel
    var isOpen: Bool = false
    
    init(label: DataChannelLabel) {
        self.label = label
    }
}
