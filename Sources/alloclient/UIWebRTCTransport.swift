//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-07.
//

import Foundation
import LiveKitWebRTC
import OpenCombineShim
import allonet2

/// Uses Google's WebRTC implementation meant for client-side UI apps.
class UIWebRTCTransport: NSObject, Transport, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate
{
    public private(set) var clientId: ClientId?
    private let peer: LKRTCPeerConnection
    private var channels: [DataChannelLabel: LKRTCDataChannel] = [:]
    
    public weak var delegate: TransportDelegate?
    
    private var localCandidates : [LKRTCIceCandidate] = []
    private var candidatesLocked = false
    private var candidatesContinuation: CheckedContinuation<Void, Never>?
    
    private var connectionStatus: ConnectionStatus
    
    private let offerAnswerConstraints = LKRTCMediaConstraints(mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue
    ], optionalConstraints: [:])
    
    private let audioSessionActive = false
    
    public required init(with connectionOptions: TransportConnectionOptions = .direct, status: ConnectionStatus)
    {
        peer = Self.createPeerConnection(with: connectionOptions)
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
    
    public func generateOffer() async throws -> SignallingPayload
    {
        Task { @MainActor in self.connectionStatus.signalling = .connecting }
        let sdp: String = try await withCheckedThrowingContinuation { cont in
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
        
        let candidates = await gatherCandidates()
        return SignallingPayload(
            sdp: sdp,
            candidates: candidates.map { SignallingIceCandidate(candidate: $0) },
            clientId: nil
        )
    }
    
    public func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload {
        clientId = UUID()
        try await set(remoteDescription: offer.desc(for: .offer))
        for candidate in offer.rtcCandidates() {
            try await add(remoteCandidate: candidate)
        }
        
        let sdp: String = try await withCheckedThrowingContinuation { cont in
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
        
        let candidates = await gatherCandidates()
        return SignallingPayload(
            sdp: sdp,
            candidates: candidates.map { SignallingIceCandidate(candidate: $0) },
            clientId: clientId
        )
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws
    {
        clientId = answer.clientId!
        try await set(remoteDescription: answer.desc(for: .answer))
        for candidate in answer.candidates
        {
            try await add(remoteCandidate: candidate.candidate())
        }
    }
    
    private func set(remoteDescription: LKRTCSessionDescription) async throws
    {
        return try await withCheckedThrowingContinuation() { cont in
            peer.setRemoteDescription(remoteDescription) { err in
                if let err2 = err {
                    cont.resume(throwing: err2)
                    return
                }
                cont.resume()
            }
        }
    }
    public func add(remoteCandidate: LKRTCIceCandidate) async throws
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

    public func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel?
    {
        let config = LKRTCDataChannelConfiguration()
        config.isNegotiated = true
        config.isOrdered = reliable
        config.maxRetransmits = reliable ? -1 : 0
        config.channelId = label.channelId
        
        guard let channel = peer.dataChannel(forLabel: label.rawValue, configuration: config) else {
            return nil
        }
        
        channel.delegate = self
        self.channels[label] = channel
        return channel.wrapper
    }
    
    public func send(data: Data, on channelLabel: DataChannelLabel)
    {
        guard let channel = channels[channelLabel] else {
            fatalError("Missing channel for label \(channelLabel)");
            return
        }
        channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }
    
    
    //MARK: - Internals
    
    private static func createPeerConnection(with connectionOptions: TransportConnectionOptions) -> LKRTCPeerConnection
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
        
        guard let peerConnection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
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
            channels.values.allSatisfy({$0.readyState == .open})
        {
            didFullyConnect = true
            self.delegate?.transport(didConnect: self)
            
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
        delegate?.transport(self, didReceiveMediaStream: stream.wrapper)
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
        delegate?.transport(requestsRenegotiation: self)
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
            self.delegate?.transport(didDisconnect: self)
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
        print("Data channel \(dataChannel.label) is now open")
        dataChannel.delegate = self
        self.maybeConnected()
    }
    
    //MARK: - Data channel delegate
    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel)
    {
        let readyState = dataChannel.readyState
        print("Data channel \(dataChannel.label) state \(readyState)")
        DispatchQueue.main.async {
            // TODO: There are more than one data channel. Track them separately.
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
        //print("Message on data channel \(dataChannel.label): \(buffer.data.count) bytes")
        delegate?.transport(self, didReceiveData: buffer.data, on: dataChannel.wrapper)
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
    public func createMicrophoneTrack() -> AudioTrack
    {
        if !audioSessionActive
        {
            beginAudioSession()
        }
        let audioConstraints = LKRTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])
        let audioSource = Self.factory.audioSource(with: audioConstraints)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: micTrackName)
        peer.add(audioTrack, streamIds: ["voice"])
        return audioTrack.wrapper
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

// MARK: - Wrapper classes

private class ClientDataChannel: DataChannel {
    weak var channel: LKRTCDataChannel?
    
    init(channel: LKRTCDataChannel) {
        self.channel = channel
        self.label = DataChannelLabel(rawValue: channel.label)!
    }
    
    var label: DataChannelLabel
    var isOpen: Bool { (channel?.readyState ?? .closed) == .open }
}
extension LKRTCDataChannel {
    static var wrapperKey: Void = ()
    fileprivate var wrapper: ClientDataChannel {
        get {
            var wrapper = objc_getAssociatedObject(self, &Self.wrapperKey) as? ClientDataChannel
            if wrapper == nil {
                wrapper = ClientDataChannel(channel: self)
                objc_setAssociatedObject(self, &Self.wrapperKey, wrapper, .OBJC_ASSOCIATION_RETAIN)
            }
            return wrapper!
        }
    }
}

private class ClientMediaStream: MediaStream {
    let stream: LKRTCMediaStream
    
    init(stream: LKRTCMediaStream) {
        self.stream = stream
    }
    
    var streamId: String { stream.streamId }
}
extension LKRTCMediaStream {
    static var wrapperKey: Void = ()
    fileprivate var wrapper: ClientMediaStream {
        get {
            var wrapper = objc_getAssociatedObject(self, &Self.wrapperKey) as? ClientMediaStream
            if wrapper == nil {
                wrapper = ClientMediaStream(stream: self)
                objc_setAssociatedObject(self, &Self.wrapperKey, wrapper, .OBJC_ASSOCIATION_RETAIN)
            }
            return wrapper!
        }
    }
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
extension LKRTCAudioTrack {
    static var wrapperKey: Void = ()
    fileprivate var wrapper: ClientAudioTrack {
        get {
            var wrapper = objc_getAssociatedObject(self, &Self.wrapperKey) as? ClientAudioTrack
            if wrapper == nil {
                wrapper = ClientAudioTrack(track: self)
                objc_setAssociatedObject(self, &Self.wrapperKey, wrapper, .OBJC_ASSOCIATION_RETAIN)
            }
            return wrapper!
        }
    }
}

extension SignallingPayload
{
    public func desc(for type: RTCSdpType) -> LKRTCSessionDescription
    {
        return LKRTCSessionDescription(type: type, sdp: self.sdp)
    }
    public func rtcCandidates() -> [LKRTCIceCandidate]
    {
        return candidates.map { $0.candidate() }
    }
}

extension SignallingIceCandidate
{
    public init(candidate: LKRTCIceCandidate)
    {
        self.init(
            sdpMid: candidate.sdpMid!,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdp: candidate.sdp,
            serverUrl: candidate.serverUrl
        )
    }
    
    public func candidate() -> LKRTCIceCandidate
    {
        return LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}
