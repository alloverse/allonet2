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
import AVFAudio

// TODO: What actor are peer's combine publishers being signalled on? Where do we need to annotate nonisolated, and/or dispatch to main before calling delegate?
@MainActor
public class HeadlessWebRTCTransport: Transport
{
    public weak var delegate: TransportDelegate?
    public var clientId: ClientId?
    
    private var peer: AlloWebRTCPeer
    private var channels: [String: AlloWebRTCPeer.DataChannel] = [:] // track which channels are created
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
            print("\(self) state changed to \(state)")
            if state == .connected {
                self.delegate?.transport(didConnect: self)
            } else if state == .closed || state == .failed {
                self.delegate?.transport(didDisconnect: self)
            }
        }.store(in: &cancellables)
        peer.$signalingState.sink { [weak self] state in
            guard let self = self else { return }
            print("\(self) signalling state changed to \(state)")
            if state == .stable && self.renegotiationNeeded
            {
                renegotiate()
            }
        }.store(in: &cancellables)
        
        peer.$tracks.sinkChanges(added: { track in
            self.delegate?.transport(self, didReceiveMediaStream: track)
        }, removed: { track in
            self.delegate?.transport(self, didRemoveMediaStream: track)
        }).store(in: &cancellables)
        
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
        print("Generated Offer: \(offerSdp)")
        
        // TODO: await gathering status = complete
        let offerCandidates = peer.candidates.compactMap(\.alloCandidate)
        print("Offer candidates: \(offerCandidates)")
        
        return SignallingPayload(
            sdp: offerSdp,
            candidates: offerCandidates,
            clientId: nil
        )
    }
    
    public func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload
    {
        print("Received Offer: \(offer)")
        
        try peer.set(remote: offer.sdp, type: .offer)
        try peer.lockLocalDescription(type: .answer)
        // TODO: set remote ice candidates in peer from the offer
        let answerSdp = try peer.createAnswer()
        print("Generated Answer: \(answerSdp)")
        
        // TODO: await gathering status = complete
        let answerCandidates = peer.candidates.compactMap(\.alloCandidate)
        print("Answer candidates: \(answerCandidates)")
        
        return SignallingPayload(
            sdp: answerSdp,
            candidates: answerCandidates,
            clientId: clientId
        )
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws
    {
        // Don't override clientId in case of renegotiation
        if clientId == nil
        {
            clientId = answer.clientId!
        }
        print("Received Answer: \(answer)")
        try peer.set(remote: answer.sdp, type: .answer)
        for candidate in answer.candidates
        {
            try peer.add(remote: candidate.adc)
        }
    }
    
    var renegotiationNeeded = false
    public func scheduleRenegotiation()
    {
        renegotiationNeeded = true
        if self.peer.signalingState == .stable
        {
            print("\(self) Renegotiation requested while stable, performing immediately.")
            self.renegotiate()
        }
        else
        {
            print("\(self) Renegotiation requested while unstable, scheduling...")
        }
    }
    
    private func renegotiate()
    {
        renegotiationNeeded = false
        print("\(self) setting local description and renegotiating...")
        // Note: AlloSession will attempt to generateOffer, which will then lockLocalDescription, so we don't need to do that here.
        self.delegate!.transport(requestsRenegotiation: self)
    }
    
    public func disconnect()
    {
        peer.close()
        delegate?.transport(didDisconnect: self) // Apparently libdatachannel doesn't call it when manually closing peer??
        clientId = nil
        cancellables.forEach { $0.cancel() }
    }
    
    public func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel?
    {
        let channel = try! peer.createDataChannel(label: label.rawValue, reliable: reliable, streamId: UInt16(label.channelId), negotiated: true)
        channels[label.rawValue] = channel
        
        channel.$lastMessage.sink { [weak self] message in
            guard let self = self, let message = message else { return }
            self.delegate?.transport(self, didReceiveData: message, on: channel)
        }.store(in: &cancellables)
        
        return channel
    }
    
    public func send(data: Data, on channelLabel: DataChannelLabel)
    {
        let ch = channels[channelLabel.rawValue]!
        do {
            try ch.send(data: data)
        } catch {
            print("ERROR: Failed to send on \(clientId)'s channel \(channelLabel): \(error)")
            // Can't think of more ways to handle this; disconnection will be noticed and handled asynchronously soon.
        }
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
    
    public static func forward(mediaStream: MediaStream, from sender: any Transport, to receiver: any Transport) throws -> MediaStreamForwarder
    {
        print("Forwarding media stream \(mediaStream.mediaId) to \(receiver.clientId)")
        let track = mediaStream as! AlloWebRTCPeer.Track
        let receiverHeadless = (receiver as! HeadlessWebRTCTransport)
        let peer = receiverHeadless.peer
        let shortId = sender.clientId!.uuidString.split(separator: "-").first!
        let sfu = try MediaForwardingUnit(forwarding: track, fromClientId: String(shortId) , to: peer)
        receiverHeadless.scheduleRenegotiation()
        return sfu
    }
}

extension AlloWebRTCPeer.DataChannel : DataChannel
{
    public var alloLabel: DataChannelLabel
    {
        return DataChannelLabel(rawValue: self.label)!
    }
}

extension AlloWebRTCPeer.Track : MediaStream
{
    public func render() -> allonet2.AudioRingBuffer {
        fatalError("Not implemented")
        //return AudioRingBuffer(channels: 1, capacityFrames: 48000, canceller: {})
    }
    
    public var mediaId: String
    {
        "\(self.streamId)-\(self.trackId)"
    }
    
    public var streamDirection: MediaStreamDirection
    {
        MediaStreamDirection(rawValue: direction.rawValue)!
    }
}

extension MediaForwardingUnit : MediaStreamForwarder
{
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
