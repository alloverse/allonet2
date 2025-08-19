//
//  HeadlessWebRTCTransport.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import allonet2
import Foundation
import AlloDataChannel
import OpenCombineShim

public class HeadlessWebRTCTransport: Transport
{
    public weak var delegate: TransportDelegate?
    public private(set) var clientId: ClientId?
    
    private var peer: AlloWebRTCPeer
    private var channels: [String: ServerDataChannel] = [:] // track which channels are created
    private var connectionStatus: ConnectionStatus
    private var cancellables = Set<AnyCancellable>()
    
    public required init(with connectionOptions: allonet2.TransportConnectionOptions, status: ConnectionStatus)
    {
        self.connectionStatus = status
        AlloWebRTCPeer.enableLogging(at: .debug)
        peer = AlloWebRTCPeer(portRange: connectionOptions.portRange, ipOverride: connectionOptions.ipOverride?.adc)
        
        peer.$state.sink { [weak self] state in
            // TODO: replicate UIWebRTCTransport's behavior and only signal connected when data channels are connected?
            guard let self = self else { return }
            if state == .connected {
                self.delegate?.transport(didConnect: self)
            } else if state == .closed || state == .failed {
                self.delegate?.transport(didDisconnect: self)
            }
        }.store(in: &cancellables)
        
        // TODO: subscribe to more callbacks and match UIWebRTCTransport's behavior
        // TODO: Populate connectionStatus
        // TODO: Manage renegotiation
        
        /*webrtcPeer?.onMediaStreamAdded = { [weak self] streamId in
            guard let self = self else { return }
            let stream = ServerMediaStream(streamId: streamId)
            self.delegate?.transport(self, didReceiveMediaStream: stream)
        }*/
    }
    
    public func generateOffer() async throws -> SignallingPayload
    {
        Task { @MainActor in self.connectionStatus.signalling = .connecting }
        
        try peer.lockLocalDescription(type: .offer)
        let offerSdp = try peer.createOffer()
        
        // TODO: await gathering status = complete
        let offerCandidates = peer.candidates.compactMap(\.alloCandidate)
        
        return SignallingPayload(
            sdp: offerSdp,
            candidates: offerCandidates,
            clientId: nil
        )
    }
    
    public func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload
    {
        clientId = UUID()
        
        try peer.set(remote: offer.sdp, type: .offer)
        try peer.lockLocalDescription(type: .answer)
        // TODO: set remote ice candidates in peer from the offer
        let answerSdp = try peer.createAnswer()
        
        // TODO: await gathering status = complete
        let answerCandidates = peer.candidates.compactMap(\.alloCandidate)
        
        return SignallingPayload(
            sdp: answerSdp,
            candidates: answerCandidates,
            clientId: clientId
        )
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws
    {
        clientId = answer.clientId!
        try peer.set(remote: answer.sdp, type: .answer)
        for candidate in answer.candidates
        {
            try peer.add(remote: candidate.adc)
        }
    }
    
    public func disconnect()
    {
        peer.close()
        clientId = nil
    }
    
    public func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel?
    {
        let achannel = try! peer.createDataChannel(label: label.rawValue, reliable: reliable, streamId: UInt16(label.channelId), negotiated: true)
        let channel = ServerDataChannel(label: label, channel: achannel)
        channels[label.rawValue] = channel
        
        achannel.$lastMessage.sink { [weak self] message in
            guard let self = self, let message = message else { return }
            self.delegate?.transport(self, didReceiveData: message, on: channel)
        }.store(in: &cancellables)
            
        return channel
    }
    
    public func send(data: Data, on channelLabel: DataChannelLabel)
    {
        let ch = channels[channelLabel.rawValue]!
        try! ch.channel.send(data: data)
    }
    
    // Media operations - server can forward but not create
    public func createMicrophoneTrack() throws -> AudioTrack
    {
        fatalError("Not available server-side")
    }
    
    public func setMicrophoneEnabled(_ enabled: Bool)
    {
        fatalError("Not available server-side")
    }
    
    public func addOutgoingStream(_ stream: MediaStream)
    {
        // TODO: Implement stream forwarding when you have multiple clients
        // This would involve forwarding streams between HeadlessWebRTCTransport instances
    }
    
    public func forwardStream(from otherTransport: HeadlessWebRTCTransport, streamId: String) -> Bool
    {
        return false
    }
}

private class ServerDataChannel: DataChannel
{
    let label: DataChannelLabel
    let channel: AlloWebRTCPeer.Channel
    var isOpen: Bool { return channel.open }
    
    init(label: DataChannelLabel, channel: AlloWebRTCPeer.Channel)
    {
        self.label = label
        self.channel = channel
    }
}

private class ServerMediaStream: MediaStream
{
    let streamId: String
    
    init(streamId: String) {
        self.streamId = streamId
    }
}

extension SignallingPayload
{
    public func adcCandidates() -> [AlloWebRTCPeer.ICECandidate]
    {
        return candidates.map { $0.adc }
    }
}

extension SignallingIceCandidate
{
    public init(candidate: AlloWebRTCPeer.ICECandidate)
    {
        self.init(
            sdpMid: candidate.mid,
            sdpMLineIndex: 0,
            sdp: candidate.candidate,
            serverUrl: nil
        )
    }
    
    public var adc : AlloWebRTCPeer.ICECandidate
    {
        return AlloWebRTCPeer.ICECandidate(candidate: sdp, mid: sdpMid)
    }
}

extension AlloWebRTCPeer.ICECandidate
{
    var alloCandidate: SignallingIceCandidate {
        get {
            return SignallingIceCandidate(candidate: self)
        }
    }
}

extension allonet2.IPOverride
{
    var adc: AlloWebRTCPeer.IPOverride
    {
        return AlloWebRTCPeer.IPOverride(from: self.from, to: self.to)
    }
}
