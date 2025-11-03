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
import Logging

// TODO: What actor are peer's combine publishers being signalled on? Where do we need to annotate nonisolated, and/or dispatch to main before calling delegate?
@MainActor
public class HeadlessWebRTCTransport: Transport
{
    public weak var delegate: TransportDelegate?
    public var clientId: ClientId? {
        didSet {
            if let clientId {
                logger = logger.forClient(clientId)
            } else {
                logger[metadataKey: "clientId"] = nil
            }
        }
    }
    var logger = Logger(label: "transport.headless")
    
    private var peer: AlloWebRTCPeer
    private var channels: [String: AlloWebRTCPeer.DataChannel] = [:] // track which channels are created
    private var connectionStatus: ConnectionStatus
    private var cancellables = Set<AnyCancellable>()
    
    private static var datachannelLogger = Logger(label: "transport.headless.libdatachannel")
    private static var initialized: Bool = false
    private static func initialize()
    {
        AlloWebRTCPeer.enableLogging(at: .debug) { sev, msg in
            let level : Logger.Level = switch sev {
            case .verbose: .trace
            case .debug: .debug
            case .info: .info
            case .warning: .warning
            case .error: .error
            case .fatal: .critical
            case .none: .info
            }
            datachannelLogger.log(level: level, "\(msg)")
        }
    }
    
    public required init(with connectionOptions: allonet2.TransportConnectionOptions, status: ConnectionStatus)
    {
        if(!Self.initialized) { Self.initialize() }
        
        self.connectionStatus = status
        peer = AlloWebRTCPeer(portRange: connectionOptions.portRange, ipOverride: connectionOptions.ipOverride?.adc)
        
        peer.$state.sink { [weak self] state in
            // TODO: replicate UIWebRTCTransport's behavior and only signal connected when data channels are connected?
            guard let self = self else { return }
            logger.info("state changed to \(state)")
            if state == .connected {
                self.delegate?.transport(didConnect: self)
            } else if state == .closed || state == .failed {
                self.delegate?.transport(didDisconnect: self)
            }
        }.store(in: &cancellables)
        peer.$signalingState.sink { [weak self] state in
            guard let self = self else { return }
            logger.info("signalling state changed to \(state)")
            if state == .stable && self.renegotiationNeeded
            {
                renegotiate()
            }
        }.store(in: &cancellables)
        
        peer.$gatheringState.sink { [weak self] gathering in
            guard let self else { return }
            self.connectionStatus.iceGathering = switch gathering
            {
                case .new: .idle
                case .inProgress: .connecting
                case .complete: .connected
            }
        }.store(in: &cancellables)
        peer.$iceState.sink { [weak self] ice in
            guard let self else { return }
            self.connectionStatus.iceConnection = switch ice
            {
                case .closed, .new, .disconnected: .idle
                case .checking, .connected: .connecting
                case .completed: .connected
                case .failed: .failed
            }
        }.store(in: &cancellables)
        
        
        peer.$tracks.sinkChanges(added: { track in
            self.delegate?.transport(self, didReceiveMediaStream: track)
        }, removed: { track in
            self.delegate?.transport(self, didRemoveMediaStream: track)
        }).store(in: &cancellables)
        
        // TODO: subscribe to more callbacks and match UIWebRTCTransport's behavior
        // TODO: Populate connectionStatus
        
        /*webrtcPeer?.onMediaStreamAdded = { [weak self] streamId in
            guard let self = self else { return }
            let stream = ServerMediaStream(streamId: streamId)
            self.delegate?.transport(self, didReceiveMediaStream: stream)
        }*/
    }
    
    public func generateOffer() async throws -> SignallingPayload
    {
        self.connectionStatus.signalling = .connecting
        
        try peer.lockLocalDescription(type: .offer)
        let offerSdp = try peer.createOffer()
        logger.info("Generated my offer: \(offerSdp)")
        
        // TODO: await gathering status = complete
        let offerCandidates = peer.candidates.compactMap(\.alloCandidate)
        logger.info("My offer candidates: \(offerCandidates)")
        
        return SignallingPayload(
            sdp: offerSdp,
            candidates: offerCandidates,
            clientId: nil
        )
    }
    
    public func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload
    {
        self.connectionStatus.signalling = .connecting
        logger.info("Received offer from remote: \(offer)")
        
        try peer.set(remote: offer.sdp, type: .offer)
        try peer.lockLocalDescription(type: .answer)
        // TODO: set remote ice candidates in peer from the offer
        let answerSdp = try peer.createAnswer()
        logger.info("Generated my answer: \(answerSdp)")
        
        // TODO: await gathering status = complete
        let answerCandidates = peer.candidates.compactMap(\.alloCandidate)
        logger.info("My answer candidates: \(answerCandidates)")
        
        self.connectionStatus.signalling = .connected
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
        logger.info("Received their answer: \(answer)")
        try peer.set(remote: answer.sdp, type: .answer)
        for candidate in answer.candidates
        {
            try peer.add(remote: candidate.adc)
        }
        self.connectionStatus.signalling = .connected
    }
    
    var renegotiationNeeded = false
    public func scheduleRenegotiation()
    {
        renegotiationNeeded = true
        if self.peer.signalingState == .stable
        {
            logger.info("Renegotiation requested while stable, performing immediately.")
            self.renegotiate()
        }
        else
        {
            logger.info("Renegotiation requested while unstable, scheduling...")
        }
    }
    
    private func renegotiate()
    {
        renegotiationNeeded = false
        logger.info("Setting local description and renegotiating...")
        // Note: AlloSession will attempt to generateOffer, which will then lockLocalDescription, so we don't need to do that here.
        self.delegate!.transport(requestsRenegotiation: self)
    }
    
    public func disconnect()
    {
        self.connectionStatus.signalling = .idle
        peer.close()
        delegate?.transport(didDisconnect: self) // Apparently libdatachannel doesn't call it when manually closing peer??
        clientId = nil
        logger[metadataKey: "clientId"] = nil
        cancellables.forEach { $0.cancel() }
    }
    
    public func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel?
    {
        let channel = try! peer.createDataChannel(label: label.rawValue, reliable: reliable, streamId: UInt16(label.channelId), negotiated: true)
        channels[label.rawValue] = channel
        
        channel.$lastMessage.sink { [weak self, weak channel] message in
            guard let self, let channel, let message else { return }
            self.delegate?.transport(self, didReceiveData: message, on: channel)
        }.store(in: &cancellables)
        channel.$isOpen.sink { [weak self, weak channel] isOpen in
            guard let self, let channel else { return }
            self.connectionStatus.data = isOpen ? .connected : (channel.lastError != nil) ? .failed : .idle;
        }.store(in: &cancellables)
        
        return channel
    }
    
    public func send(data: Data, on channelLabel: DataChannelLabel)
    {
        let ch = channels[channelLabel.rawValue]!
        do {
            try ch.send(data: data)
        } catch {
            logger.error("Failed to send on channel \(channelLabel): \(error)")
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
        var logger = Logger(label: "transport.libdatachannel").forClient(receiver.clientId!)
        logger.info("Forwarding media stream \(mediaStream.mediaId) from \(sender.clientId) to \(receiver.clientId)")
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
