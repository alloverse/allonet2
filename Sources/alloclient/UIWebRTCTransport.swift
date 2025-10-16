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
import Logging

/// Uses Google's WebRTC implementation meant for client-side UI apps.
// TODO: @MainActor this class, and declare all the delegate methods nonisolated, and fix all the threading issues in here
class UIWebRTCTransport: NSObject, Transport, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate
{
    public var clientId: ClientId?
    private var peer: LKRTCPeerConnection! = nil
    private var channels: [DataChannelLabel: LKRTCDataChannel] = [:]
    
    public weak var delegate: TransportDelegate?
    
    private var localCandidates : [LKRTCIceCandidate] = []
    private var candidatesLocked = false
    private var candidatesContinuation: CheckedContinuation<Void, Never>?
    
    private var connectionStatus: ConnectionStatus
    
    private let offerAnswerConstraints = LKRTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])
    
    private let audioSessionActive = false
    private var logger = Logger(label: "transport.webrtc")
    
    public required init(
        with connectionOptions: TransportConnectionOptions,
        status: ConnectionStatus
    ) {
        self.connectionStatus = status
        super.init()
        self.peer = createPeerConnection(with: connectionOptions)
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
    
    public func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload
    {
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
        logger = logger.forClient(clientId!)
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
    
    var wlogger : LKRTCCallbackLogger? = nil
    private func createPeerConnection(with connectionOptions: TransportConnectionOptions) -> LKRTCPeerConnection
    {
        if wlogger == nil
        {
            // Warning: LKRTCCallbackLoggers are installed globally. If two WebRTC sessions are running in the same process, both will get both's log messages.
            wlogger = LKRTCCallbackLogger()
            wlogger!.severity = .warning
            var innerLogger = Logger(label: "transport.webrtc.wrapped")
            wlogger!.start(messageAndSeverityHandler: { [weak self] (message, severity) in
                guard let self = self else {
                    innerLogger.warning("WebRTC log AFTER deallocation: \(message)")
                    return
                }
                if let cid = self.clientId
                {
                    innerLogger = innerLogger.forClient(cid)
                }
                
                let level: Logger.Level = switch severity {
                case .verbose: .notice
                case .info: .info
                case .warning: .warning
                case .error: .error
                case .none: .info
                }
                innerLogger.log(level: level, "\(message)")
            })
        }
        
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        
        // NOTE: Having both STUN and .gatherOnce forces a 10s connection time as candidates need to be gathered through a remote party.
        config.continualGatheringPolicy = .gatherOnce
        
        switch(connectionOptions.routing)
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
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":kLKRTCMediaConstraintsValueTrue])
        
        guard let peerConnection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            fatalError("Could not create new RTCPeerConnection")
        }
        
        return peerConnection
    }
    
    private static let audioDeviceObserver = PlaybackDisablingAudioDeviceModuleDelegate()
    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        let videoEncoderFactory = LKRTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = LKRTCDefaultVideoDecoderFactory()
        // LKRTCAudioDeviceModuleDelegate is not called unless audioDeviceModuleType is switched from default to to .audioEngine.
        // This took two days of debugging and reading through WebRTC source code. Goddammit.
        let factory = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: false,
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory,
            audioProcessingModule: nil
        )
        // Disable automatic playback of incoming audio streams so allonet's user can play it back spatially
        factory.audioDeviceModule.observer = audioDeviceObserver
        return factory
    }()
    
    private var didFullyConnect = false
    private func maybeConnected()
    {
        if
            !didFullyConnect &&
            (peer.iceConnectionState == .connected || peer.iceConnectionState == .completed) &&
             channels.count > 0 &&
            channels.values.allSatisfy({$0.readyState == .open})
        {
            logger.info("Transport is fully connected")
            didFullyConnect = true
            Task { @MainActor in
                self.delegate?.transport(didConnect: self)
            }
            
            if(renegotiationNeeded)
            {
                logger.notice("Renegotiation became necessary while connecting, so now renegotiating")
                self.renegotiate()
            }

        }
    }
    
    //MARK: - Peer connection delegates
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState)
    {
        logger.info("Session \(clientId?.debugDescription ?? "unknown") signaling state \(stateChanged)")
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream)
    {
        let sender = peerConnection.transceivers.first(where: {
            $0.sender.streamIds.first == stream.streamId
        })
        let receiver = peerConnection.transceivers.first(where: {
            $0.receiver.track == stream.audioTracks.first ||
            $0.receiver.track == stream.videoTracks.first
        })
        stream.wrapper.streamDirection = sender != nil ? .sendonly : .recvonly
        logger.info("Received stream for: \(stream.wrapper.streamDirection) \(stream)")
        Task { @MainActor in
            delegate?.transport(self, didReceiveMediaStream: stream.wrapper)
        }
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream)
    {
        logger.info("Lost stream: \(stream)")
        Task { @MainActor in
            delegate?.transport(self, didRemoveMediaStream: stream.wrapper)
        }
    }
    
    var renegotiationNeeded = false
    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection)
    {
        logger.info("Renegotiation hinted")
        renegotiationNeeded = true
        if didFullyConnect
        {
            self.renegotiate()
        }
    }
    
    func renegotiate()
    {
        Task { @MainActor in
            delegate?.transport(requestsRenegotiation: self)
        }
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState)
    {
        logger.info("Session ICE state \(newState)")
        DispatchQueue.main.async {
            self.connectionStatus.iceConnection = switch newState
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
            Task { @MainActor in
                self.delegate?.transport(didDisconnect: self)
            }
        }
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState)
    {
        logger.info("Session ICE gathering state \(newState)")
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
            logger.error("!! discovered local candidate after response already sent")
            return
        }
        localCandidates.append(candidate)
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate])
    {
        logger.error("!! Lost candidate, shouldn't happen since we're not gathering continuously")
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel)
    {
        logger.info("Data channel \(dataChannel.label) is now open")
        dataChannel.delegate = self
        self.maybeConnected()
    }
    
    //MARK: - Data channel delegate
    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel)
    {
        let readyState = dataChannel.readyState
        logger.info("Data channel \(dataChannel.label) state \(readyState)")
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
        logger.trace("Message on data channel \(dataChannel.label): \(buffer.data.count) bytes")
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
            logger.error("Failed to set audio category and activate audio session: \(error)")
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
            logger.error("Failed to deactivate audio session: \(error)")
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
        
        // TODO: Replace this with some createTrack() in session or something, so that we can also create a LiveMedia component
        
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
    
    public static func forward(mediaStream: MediaStream, from sender: any Transport, to receiver: any Transport) throws -> MediaStreamForwarder
    {
        fatalError("Not implemented")
    }
}

// MARK: - Wrapper classes

private class ClientDataChannel: DataChannel {
    weak var channel: LKRTCDataChannel?
    
    init(channel: LKRTCDataChannel) {
        self.channel = channel
        self.alloLabel = DataChannelLabel(rawValue: channel.label)!
    }
    
    var alloLabel: DataChannelLabel
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

private class ClientMediaStream: MediaStream
{
    // TODO: A stream could contain multiple tracks, so our abstraction of stream=track breaks here :( refactor in transport!
    var mediaId: String {
        let streamId = rtcStream.streamId
        let trackId = (rtcStream.audioTracks.first ?? rtcStream.videoTracks.first)?.trackId
        return "\(streamId)-\(trackId ?? "unknown")"
    }
    
    // TODO: This isn't exposed in Google WebRTC, but also, maybe we don't need it on the client?
    // If I need it, look at RTCRtpTransceiverDirection
    var streamDirection: allonet2.MediaStreamDirection = .unknown
    
    private let rtcStream: LKRTCMediaStream
    
    func render() -> AudioRingBuffer
    {
        // lessee... Caller owns ring buffer owns renderer.
        weak var track = rtcStream.audioTracks.first
        let renderer = AudioRingRenderer()
        // TODO: don't hardcode sample rate
        let ring = AVFAudioRingBuffer(channels: 1, capacityFrames: 48000)
        {
            track?.remove(renderer)
        }
        renderer.ring = ring
        track!.add(renderer)
        return ring
    }

    init(stream: LKRTCMediaStream)
    {
        self.rtcStream = stream
    }
}

fileprivate class AudioRingRenderer : NSObject, LKRTCAudioRenderer
{
    weak var ring: AVFAudioRingBuffer? = nil
    func render(pcmBuffer pcm: AVAudioPCMBuffer)
    {
        //logger.trace("Writing \(pcm.frameLength) frames to \(ring)")
        _ = ring?.write(pcm)
    }
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
    public func desc(for type: LKRTCSdpType) -> LKRTCSessionDescription
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

/// LKRTCAudioDeviceModule delegate whose only purpose is to stop playout/playback of every incoming audio track. This is because we want allonet to only deliver PCM packets up to the app layer to be played back spatially, and not have GoogleWebRTC play it back in stereo. I couldn't find any API to change this behavior without overriding this delegate.
class PlaybackDisablingAudioDeviceModuleDelegate: NSObject, LKRTCAudioDeviceModuleDelegate
{
    var logger = Logger(label: "transport.webrtc.adc")
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent speechActivityEvent: LKRTCSpeechActivityEvent)
    {
    }
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int
    {
        return 0
    }
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int
    {
        return 0
    }
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int
    {
        return 0
    }
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int
    {
        return 0
    }
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int
    {
        return 0
    }
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int
    {
        return 0
    }
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode, format: AVAudioFormat, context: [AnyHashable : Any]) -> Int
    {
        return 0
    }
    
    var mixer: AVAudioMixerNode!
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable : Any]) -> Int
    {
        guard let destination else { fatalError() }
        guard mixer == nil else {
            // already disabled
            return 0
        }
        logger.debug("Disabling AudioEngine output: \(engine) source: \(source) toDestination: \(destination) format: \(format) context: \(context)\n")
    
        mixer = AVAudioMixerNode()
        engine.attach(mixer)
        
        engine.disconnectNodeOutput(source)
        engine.connect(source, to: mixer, format: format)
        
        engine.disconnectNodeInput(destination)
        engine.connect(mixer, to: destination, format: format)
        
        mixer.outputVolume = 0
        
        return 0
    }
    
    func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: LKRTCAudioDeviceModule)
    {
    }
}
