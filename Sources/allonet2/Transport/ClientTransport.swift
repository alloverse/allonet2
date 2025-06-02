//
//  ClientTransport.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import LiveKitWebRTC

// Wrapper for Google's WebRTC for client use
public class ClientTransport: NSObject, Transport
{
    public weak var delegate: TransportDelegate?
    public private(set) var clientId: ClientId?
    
    private let peer: LKRTCPeerConnection
    private var channels: [String: LKRTCDataChannel] = [:]
    private var micTrack: LKRTCAudioTrack?
    
    private var localCandidates : [LKRTCIceCandidate] = []
    private var candidatesLocked = false
    private var candidatesContinuation: CheckedContinuation<Void, Never>?
    
    private let offerAnswerConstraints = LKRTCMediaConstraints(mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue
    ], optionalConstraints: [:])
    
    public override init() {
        self.peer = ClientTransport.createPeerConnection()
        super.init()
        peer.delegate = self
    }
    
    public func generateOffer() async throws -> SignallingPayload {
        let sdp: String = try await withCheckedThrowingContinuation { cont in
            peer.offer(for: offerAnswerConstraints) { (sdp, error) in
                guard let sdp = sdp else {
                    cont.resume(throwing: error!)
                    return
                }
                self.peer.setLocalDescription(sdp) { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: sdp.sdp)
                    }
                }
            }
        }
        
        let candidates = await gatherCandidates()
        return SignallingPayload(
            sdp: sdp,
            candidates: candidates.map { SignallingIceCandidate(candidate: $0) },
            clientId: nil
        )
    }
    
    public func generateAnswer(offer: SignallingPayload) async throws -> SignallingPayload {
        clientId = UUID()
        try await setRemoteDescription(offer.desc(for: .offer))
        for candidate in offer.rtcCandidates() {
            try await addRemoteCandidate(candidate)
        }
        
        let sdp: String = try await withCheckedThrowingContinuation { cont in
            peer.answer(for: offerAnswerConstraints) { (sdp, error) in
                guard let sdp = sdp else {
                    cont.resume(throwing: error!)
                    return
                }
                self.peer.setLocalDescription(sdp) { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: sdp.sdp)
                    }
                }
            }
        }
        
        let candidates = await gatherCandidates()
        return SignallingPayload(
            sdp: sdp,
            candidates: candidates.map { SignallingIceCandidate(candidate: $0) },
            clientId: clientId
        )
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws {
        clientId = answer.clientId
        try await setRemoteDescription(answer.desc(for: .answer))
        for candidate in answer.rtcCandidates() {
            try await addRemoteCandidate(candidate)
        }
    }
    
    public func disconnect() {
        peer.close()
    }
    
    public func createDataChannel(label: String, reliable: Bool) -> DataChannel? {
        let config = LKRTCDataChannelConfiguration()
        config.isOrdered = reliable
        config.maxRetransmits = reliable ? -1 : 0
        
        guard let channel = peer.dataChannel(forLabel: label, configuration: config) else {
            return nil
        }
        
        channel.delegate = self
        channels[label] = channel
        return ClientDataChannel(channel: channel)
    }
    
    public func send(data: Data, on channelLabel: String) {
        guard let channel = channels[channelLabel] else { return }
        channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }
    
    public func createMicrophoneTrack() throws -> AudioTrack {
        let audioConstraints = LKRTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])
        let audioSource = ClientTransport.factory.audioSource(with: audioConstraints)
        let audioTrack = ClientTransport.factory.audioTrack(with: audioSource, trackId: "mic")
        peer.add(audioTrack, streamIds: ["voice"])
        micTrack = audioTrack
        return ClientAudioTrack(track: audioTrack)
    }
    
    public func setMicrophoneEnabled(_ enabled: Bool) {
        micTrack?.isEnabled = enabled
    }
    
    public func addOutgoingStream(_ stream: MediaStream) {
        guard let clientStream = stream as? ClientMediaStream else { return }
        if let audioTrack = clientStream.stream.audioTracks.first {
            peer.add(audioTrack, streamIds: [clientStream.streamId])
        }
    }
    
    // MARK: - Private helpers
    
    private func setRemoteDescription(_ desc: LKRTCSessionDescription) async throws {
        return try await withCheckedThrowingContinuation { cont in
            peer.setRemoteDescription(desc) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }
    
    private func addRemoteCandidate(_ candidate: LKRTCIceCandidate) async throws {
        return try await withCheckedThrowingContinuation { cont in
            peer.add(candidate) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }
    
    private func gatherCandidates() async -> [LKRTCIceCandidate]
    {
        await withCheckedContinuation {
            if candidatesLocked {
                $0.resume()
            } else {
                candidatesContinuation = $0
            }
        }
        return localCandidates
    }
    
    private static func createPeerConnection() -> LKRTCPeerConnection {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )
        
        return factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
    }
    
    private static let factory: LKRTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = LKRTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = LKRTCDefaultVideoDecoderFactory()
        return LKRTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
}

// MARK: - WebRTC Delegates

extension ClientTransport: LKRTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        // Handle state changes
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        delegate?.transport(self, didReceiveMediaStream: ClientMediaStream(stream: stream))
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {
        // Handle stream removal
    }
    
    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        delegate?.transport(requestsRenegotiation: self)
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed {
            delegate?.transport(didConnect: self)
        } else if newState == .closed {
            delegate?.transport(didDisconnect: self)
        }
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // Handle ICE gathering
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate)
    {
        if candidatesLocked
        {
            print("!! discovered local candidate after response already sent")
            return
        }
        localCandidates.append(candidate)
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate])
    {
        assert(false)
        print("!! Lost candidate, shouldn't happen since we're not gathering continuously")
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        dataChannel.delegate = self
        channels[dataChannel.label] = dataChannel
    }
}

extension ClientTransport: LKRTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        // Handle state changes
    }
    
    public func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        delegate?.transport(self, didReceiveData: buffer.data, on: dataChannel.label)
    }
}

// MARK: - Wrapper classes

private class ClientDataChannel: DataChannel {
    let channel: LKRTCDataChannel
    
    init(channel: LKRTCDataChannel) {
        self.channel = channel
    }
    
    var label: String { channel.label }
    var isOpen: Bool { channel.readyState == .open }
}

private class ClientMediaStream: MediaStream {
    let stream: LKRTCMediaStream
    
    init(stream: LKRTCMediaStream) {
        self.stream = stream
    }
    
    var streamId: String { stream.streamId }
}

private class ClientAudioTrack: AudioTrack {
    let track: LKRTCAudioTrack
    
    init(track: LKRTCAudioTrack) {
        self.track = track
    }
    
    var isEnabled: Bool {
        get { track.isEnabled }
        set { track.isEnabled = newValue }
    }
}
