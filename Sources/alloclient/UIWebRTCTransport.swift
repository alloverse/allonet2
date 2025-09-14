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
// TODO: @MainActor this class, and declare all the delegate methods nonisolated, and fix all the threading issues in here
class UIWebRTCTransport: NSObject, Transport, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate
{
    public var clientId: ClientId?
    private let peer: LKRTCPeerConnection
    private var channels: [DataChannelLabel: LKRTCDataChannel] = [:]
    
    public weak var delegate: TransportDelegate?
    
    private var localCandidates : [LKRTCIceCandidate] = []
    private var candidatesLocked = false
    private var candidatesContinuation: CheckedContinuation<Void, Never>?
    
    private var connectionStatus: ConnectionStatus
    
    private let offerAnswerConstraints = LKRTCMediaConstraints(mandatoryConstraints: [
        kLKRTCMediaConstraintsOfferToReceiveAudio: kLKRTCMediaConstraintsValueTrue
    ], optionalConstraints: [:])
    
    private let audioSessionActive = false
    
    public required init(
        with connectionOptions: TransportConnectionOptions,
        status: ConnectionStatus
    ) {
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
    
    static var logger : LKRTCCallbackLogger? = nil
    private static func createPeerConnection(with connectionOptions: TransportConnectionOptions) -> LKRTCPeerConnection
    {
        if logger == nil
        {
            print("Starting RTC callback logger")
            logger = LKRTCCallbackLogger()
            logger!.severity = .warning
            logger!.start(messageAndSeverityHandler: { (message, severity) in
                let sevM = switch severity {
                case .verbose: "v"
                case .info: "i"
                case .warning: "!! W"
                case .error: "!!! E"
                case .none: "?"
                }
                print("RTC[\(sevM)]: \(message)")
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
        
        guard let peerConnection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
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
            print("Transport is fully connected")
            didFullyConnect = true
            Task { @MainActor in
                self.delegate?.transport(didConnect: self)
            }
            
            if(renegotiationNeeded)
            {
                print("Renegotiation became necessary while connecting, so now renegotiating")
                self.renegotiate()
            }

        }
    }
    
    //MARK: - Peer connection delegates
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState)
    {
        print("Session \(clientId?.debugDescription ?? "unknown") signaling state \(stateChanged)")
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream)
    {
        print("Received stream for client \(clientId!): \(stream)")
        delegate?.transport(self, didReceiveMediaStream: stream.wrapper)
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream)
    {
        print("Lost stream for client \(clientId!): \(stream)")
        Task { @MainActor in
            delegate?.transport(self, didRemoveMediaStream: stream.wrapper)
        }
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
        Task { @MainActor in
            delegate?.transport(requestsRenegotiation: self)
        }
    }
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState)
    {
        print("Session \(clientId?.debugDescription ?? "unknown") ICE state \(newState)")
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
        print("Session \(clientId?.debugDescription ?? "unknown") ICE gathering state \(newState)")
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
    // !! This should be "streamId-trackId", but we're mixing up streams and track :S 
    var mediaId: String { rtcStream.streamId }
    
    var streamDirection: allonet2.MediaStreamDirection
    {
        // TODO: This isn't exposed in Google WebRTC, but also, maybe we don't need it on the client?
        // If I need it, look at RTCRtpTransceiverDirection
        .unknown
    }
    
    private let rtcStream: LKRTCMediaStream

    // Keep renderer only while someone is listening
    private var renderer: Renderer?
    private var subscriberCount = 0
    private let sync = DispatchQueue(label: "ClientMediaStream.audio")

    // Public publisher with ref-counted attach/detach
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    lazy var audioBuffers: AnyPublisher<AVAudioPCMBuffer, Never> = {
        subject
            .handleEvents(
                receiveSubscription: { [weak self] _ in self?.refCount(+1) },
                receiveCancel:       { [weak self]    in self?.refCount(-1) }
            )
            // Do NOT force a scheduler here; let callers choose.
            .eraseToAnyPublisher()
    }()

    init(stream: LKRTCMediaStream)
    {
        self.rtcStream = stream
    }

    deinit {
        // Be explicit on teardown
        detachRenderer()
        subject.send(completion: .finished)
    }

    private func refCount(_ delta: Int) {
        sync.async {
            let was = self.subscriberCount
            self.subscriberCount += delta
            let now = self.subscriberCount
            if was == 0, now == 1 { self.attachRenderer() }
            if was == 1, now == 0 { self.detachRenderer() }
            precondition(self.subscriberCount >= 0, "Negative subscriber count")
        }
    }

    private func attachRenderer() {
        guard renderer == nil else { return }
        let r = Renderer(owner: self)
        renderer = r
        rtcStream.audioTracks.first?.add(r)
    }

    private func detachRenderer() {
        guard let r = renderer else { return }
        rtcStream.audioTracks.first?.remove(r)
        renderer = nil
    }

    // Bridge from WebRTC into Combine
    private final class Renderer: NSObject, LKRTCAudioRenderer {
        weak var owner: ClientMediaStream?
        init(owner: ClientMediaStream) { self.owner = owner }
        func render(pcmBuffer buffer: AVAudioPCMBuffer) {
            owner?.subject.send(buffer)
        }
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
    
    func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable : Any]) -> Int
    {
        print("!!\nDISABLING OUTPUT engine: \(engine) source: \(source) toDestination: \(destination) format: \(format) context: \(context)\n!!")
        destination!.auAudioUnit.isOutputEnabled = false
        return 0
    }
    
    func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: LKRTCAudioDeviceModule)
    {
    }
}
