//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-07.
//

import Foundation
import LiveKitWebRTC
import Combine

public protocol RTCSessionDelegate: AnyObject
{
    func session(didConnect: RTCSession)
    func session(didDisconnect: RTCSession)
    func session(_: RTCSession, didReceiveData data: Data, on channel: LKRTCDataChannel)
    func session(_: RTCSession, didReceiveMediaStream: LKRTCMediaStream)
    
    func session(requestsRenegotiation session: RTCSession)
}

public typealias RTCClientId = UUID

/// Wrapper of RTCPeerConnection with Alloverse-specific peer semantics, but no business logic
public class RTCSession: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate
{
    public private(set) var clientId: RTCClientId?
    private let peer: LKRTCPeerConnection
    private var channels: [LKRTCDataChannel] = []
    
    public weak var delegate: RTCSessionDelegate?
    
    private var localCandidates : [LKRTCIceCandidate] = []
    private var candidatesLocked = false
    private var candidatesContinuation: CheckedContinuation<Void, Never>?
    
    private var connectionStatus: ConnectionStatus
    
    private let offerAnswerConstraints = LKRTCMediaConstraints(mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue
    ], optionalConstraints: [:])
    
    private let audioSessionActive = false
    
    public enum ConnectionOptions
    {
        case direct // no STUN nor TURN
        // STUN allows NAT hole punching using a third party
        case standardSTUN // Google, Twilio and some other free options
        case STUN(servers: [String])
    }
    
    public init(with connectionOptions: ConnectionOptions = .direct, status: ConnectionStatus) {
        peer = RTCSession.createPeerConnection(with: connectionOptions)
        connectionStatus = status
        super.init()
        peer.delegate = self
    }
    
    public func disconnect()
    {
        peer.close()
        if audioSessionActive
        {
            endAudioSession()
        }
    }
    
    public func generateOffer() async throws -> String
    {
        Task { @MainActor in self.connectionStatus.signalling = .connecting }
        return try await withCheckedThrowingContinuation { cont in
            renegotiationNeeded = false
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
    }
    
    public func generateAnswer(offer: LKRTCSessionDescription, remoteCandidates: [LKRTCIceCandidate]) async throws -> String
    {
        clientId = UUID()
        try await set(remoteSdp: offer)
        for cand in remoteCandidates
        {
            try await set(remoteCandidate: cand)
        }
        return try await withCheckedThrowingContinuation { cont in
            renegotiationNeeded = false
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
    }
    
    public func receive(client id: UUID, answer: LKRTCSessionDescription, candidates: [LKRTCIceCandidate]) async throws
    {
        clientId = id
        try await set(remoteSdp: answer)
        for cand in candidates
        {
            try await set(remoteCandidate: cand)
        }
    }
    
    private func set(remoteSdp: LKRTCSessionDescription) async throws
    {
        return try await withCheckedThrowingContinuation() { cont in
            peer.setRemoteDescription(remoteSdp) { err in
                if let err2 = err {
                    cont.resume(throwing: err2)
                    return
                }
                cont.resume()
            }
        }
    }
    public func set(remoteCandidate: LKRTCIceCandidate) async throws
    {
        return try await withCheckedThrowingContinuation() { cont in
            peer.add(remoteCandidate) { err in
                if let err2 = err {
                    cont.resume(throwing: err2)
                    return
                }
                cont.resume()
            }
        }
    }
    
    
    public func gatherCandidates() async -> [LKRTCIceCandidate]
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
    
    public func createDataChannel(as label: String, configuration: LKRTCDataChannelConfiguration) -> LKRTCDataChannel?
    {
        guard let chan = peer.dataChannel(forLabel: label, configuration: configuration)
            else { return nil }
        chan.delegate = self
        self.channels.append(chan)
        return chan
    }
    
    //MARK: - Internals
    

    private static func createPeerConnection(with connectionOptions: ConnectionOptions) -> LKRTCPeerConnection
    {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        
        // NOTE: Having both STUN and .gatherOnce forces a 10s connection time as candidates need to be gathered through a remote party.
        config.continualGatheringPolicy = .gatherOnce
        
        switch(connectionOptions)
        {
            case .standardSTUN:
                config.iceServers = [LKRTCIceServer(urlStrings: [
                    "stun:stun.l.google.com:19302",
                    "stun:global.stun.twilio.com:3478",
                    "stun:freestun.net:3478"
                ])]
            case .STUN(servers: let servers):
                config.iceServers = [LKRTCIceServer(urlStrings: servers)]
            default: break
        }

        // Define media constraints. DtlsSrtpKeyAgreement is required to be true to be able to connect with web browsers.
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":kRTCMediaConstraintsValueTrue])
        
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            fatalError("Could not create new RTCPeerConnection")
        }
        
        return peerConnection
    }
    
    private static let factory: LKRTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = LKRTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = LKRTCDefaultVideoDecoderFactory()
        return LKRTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    
    private var didFullyConnect = false
    private func maybeConnected()
    {
        if
            !didFullyConnect &&
            peer.iceConnectionState == .connected &&
             channels.count > 0 &&
            channels.allSatisfy({$0.readyState == .open})
            
        {
            didFullyConnect = true
            self.delegate?.session(didConnect: self)
            
            if(renegotiationNeeded)
            {
                print("Renegotiation became necessary while connecting, so now renegotiating")
                self.renegotiate()
            }

        }
    }
    
    //MARK: - Peer connection delegates
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: RTCSignalingState)
    {
        print("Session \(clientId?.debugDescription ?? "unknown") signaling state \(stateChanged)")
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream)
    {
        print("Received stream: \(clientId!): \(stream)")
        delegate?.session(self, didReceiveMediaStream: stream)
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream)
    {
        
    }
    
    var renegotiationNeeded = false
    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection)
    {
        print("Renegotiation hinted")
        renegotiationNeeded = true
        if didFullyConnect
        {
            self.renegotiate()
        }
    }
    
    func renegotiate()
    {
        delegate?.session(requestsRenegotiation: self)
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceConnectionState)
    {
        print("Session \(clientId?.debugDescription ?? "unknown") ICE state \(newState)")
        DispatchQueue.main.async {
            self.connectionStatus.iceGathering = switch newState
            {
                case .new: .idle
                case .checking: .connecting
                case .connected, .completed: .connected
                case .failed, .disconnected, .closed: .failed
                case .count: .idle
            }
        }
        if newState == .connected || newState == .completed
        {
            // actually, just checking the data channels is enough?
            self.maybeConnected()
        }
        else if newState == .failed || newState == .disconnected
        {
            // TODO: Disconnected can resolve itself; don't assume it's broken immediately
            self.disconnect() // will invoke this callback again with .closed
        }
        else if newState == .closed
        {
            self.delegate?.session(didDisconnect: self)
        }
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceGatheringState)
    {
        DispatchQueue.main.async {
            self.connectionStatus.iceGathering = switch newState
            {
                case .new: .idle
                case .gathering: .connecting
                case .complete: .connected
            }
        }
        if newState == .complete
        {
            candidatesLocked = true
            if let candidatesContinuation = candidatesContinuation
            {
                candidatesContinuation.resume()
            }
        }
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
        print("!! Lost candidate, shouldn't happen since we're not gathering continuously")
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel)
    {
        if dataChannel.label == "interactions"
        {
            print("Got interaction channel")
        }
        else if dataChannel.label == "worldstate"
        {
            print("Got worldstate channel")
        }
        dataChannel.delegate = self
        self.maybeConnected()
    }
    
    //MARK: - Data channel delegate
    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel)
    {
        let readyState = dataChannel.readyState
        print("Data channel \(dataChannel.label) state \(readyState)")
        DispatchQueue.main.async {
            self.connectionStatus.data = switch readyState
            {
                case .closed, .closing: .idle
                case .connecting: .connecting
                case .open: .connected
            }
        }
        maybeConnected()
    }
    
    public func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer)
    {
        delegate?.session(self, didReceiveData: buffer.data, on: dataChannel)
    }
    
    // MARK: - Audio
    private func beginAudioSession()
    {
#if os(macOS)
        let arbiter = AVAudioRoutingArbiter.shared
        arbiter.begin(category: .playAndRecordVoice)
        { _, _ in
            // ...
        }
#else
        let sess = AVAudioSession.sharedInstance()
        do {
            try sess.setCategory(.playAndRecord, mode: .voiceChat)
            try sess.setActive(true)
        } catch let error {
            print("Failed to set audio category and activate audio session: \(error)")
        }
#endif
    }
    
    private func endAudioSession()
    {
#if os(macOS)
        let arbiter = AVAudioRoutingArbiter.shared
        arbiter.leave()
#else
        let sess = AVAudioSession.sharedInstance()
        do {
            try sess.setActive(false)
        } catch let error {
            print("Failed to deactivate audio session: \(error)")
        }
#endif
    }
    
    let micTrackName = "mic"
    // Start capturing audio from microphone
    public func createMicrophoneTrack() -> LKRTCAudioTrack
    {
        if !audioSessionActive
        {
            beginAudioSession()
        }
        let audioConstraints = LKRTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])
        let audioSource = RTCSession.factory.audioSource(with: audioConstraints)
        let audioTrack = RTCSession.factory.audioTrack(with: audioSource, trackId: micTrackName)
        peer.add(audioTrack, streamIds: ["voice"])
        return audioTrack
    }
    
    public var microphoneEnabled: Bool
    {
        get
        {
            let micTrack = peer.transceivers.first { $0.sender.track?.trackId == micTrackName }?.sender.track as? LKRTCAudioTrack
            return micTrack?.isEnabled ?? false
        }
        set
        {
            let micTrack = peer.transceivers.first { $0.sender.track?.trackId == micTrackName }?.sender.track as? LKRTCAudioTrack
            micTrack?.isEnabled = newValue
        }
    }
    
    var outgoingStreamSender: LKRTCRtpSender?
    public func addOutgoing(stream: LKRTCMediaStream)
    {
        outgoingStreamSender = peer.add(stream.audioTracks[0], streamIds: [stream.streamId])
        print("Forwarding audio stream with sender \(outgoingStreamSender!)")
    }
}
