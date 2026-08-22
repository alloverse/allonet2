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

/// libdatachannel signals its callbacks from its own thread pool — several worker threads, none
/// of them the one that asked for the operation, and for a peer that reaches Closed it calls back
/// synchronously on whichever network thread noticed (`PeerConnection::changeState`). Everything
/// on this side of the boundary is main-actor state: this class, the connection state machine, and
/// the delegate chain up into AlloSession and AlloClient. So nothing a peer publisher hands us is
/// acted on before it has been marshalled with `onMain`.
///
/// Doing that also settles the `@Published` willSet problem, which is the same bug wearing a
/// different hat: read inside the sink, the property that fired it still holds its old value.
private func onMain(_ work: @escaping @Sendable @MainActor () -> Void)
{
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

@MainActor
public class HeadlessWebRTCTransport: Transport
{
    public weak var delegate: TransportDelegate? {
        didSet { dataDelegate = delegate }
    }
    /// The same delegate, reachable from libdatachannel's threads. Incoming data is the one path
    /// deliberately left off the main actor — `didReceiveData` is nonisolated so that decoding a
    /// busy wire can't queue behind the main thread — and reading the isolated `delegate` from
    /// there would be exactly the violation the rest of this class now avoids.
    private nonisolated(unsafe) weak var dataDelegate: TransportDelegate?
    public var clientId: ClientId? {
        didSet {
            if let clientId {
                logger = logger.forClient(clientId)
            } else {
                logger[metadataKey: "clientId"] = nil
            }
        }
    }
    var logger = Logger(labelSuffix: "transport.headless")
    
    private var peer: AlloWebRTCPeer
    private var channels: [String: AlloWebRTCPeer.DataChannel] = [:]
    private var mediaStreams: [MediaStreamId: DataChannelMediaStream] = [:]
    private var connectionStatus: ConnectionStatus
    private var cancellables = Set<AnyCancellable>()
    let connectionState = StateMachine<TransportConnectionState>(.idle, label: "HeadlessTransport")
    
    private static var datachannelLogger = Logger(labelSuffix: "transport.headless.libdatachannel")
    private static var initialized: Bool = false
    private static func initialize()
    {
        // Global, and re-registering it per transport stacked another logging callback each time.
        initialized = true
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
    public static var version: String { LibdatachannelVersion() }
    
    public required init(with connectionOptions: allonet2.TransportConnectionOptions, status: ConnectionStatus)
    {
        if(!Self.initialized) { Self.initialize() }
        
        self.connectionStatus = status
        peer = AlloWebRTCPeer(portRange: connectionOptions.portRange, ipOverride: connectionOptions.ipOverride?.adc, bindAddress: connectionOptions.bindAddress)
        
        // Both capture lists are load-bearing. An inner `[weak self]` alone leaves the closure
        // Combine stores holding self strongly, and its publisher lives in `peer`, which this
        // class owns: that cycle kept every transport, peer connection and ICE agent alive for
        // the rest of the process, one per connection attempt.
        peer.$state.sink { [weak self] state in
            onMain { [weak self] in
                guard let self else { return }
                logger.info("peer state changed to \(state)")
                if state == .connected
                {
                    maybeConnected()
                }
                else if state == .closed || state == .failed
                {
                    let didTransition = connectionState.transitionIf(to: .disconnected) { $0 != .disconnected }
                    if didTransition
                    {
                        delegate?.transport(didDisconnect: self)
                    }
                }
            }
        }.store(in: &cancellables)
        peer.$signalingState.sink { [weak self] state in
            onMain { [weak self] in
                guard let self else { return }
                logger.info("signalling state changed to \(state)")
                delegate?.transport(self, didChangeSignallingState: TransportSignallingState(rawValue: state.rawValue)!)
            }
        }.store(in: &cancellables)

        peer.$gatheringState.sink { [weak self] gathering in
            onMain { [weak self] in
                self?.connectionStatus.iceGathering = switch gathering
                {
                    case .new: .idle
                    case .inProgress: .connecting
                    case .complete: .connected
                }
            }
        }.store(in: &cancellables)
        peer.$iceState.sink { [weak self] ice in
            onMain { [weak self] in
                self?.connectionStatus.iceConnection = switch ice
                {
                    case .closed, .new, .disconnected: .idle
                    case .checking, .connected: .connecting
                    case .completed: .connected
                    case .failed: .failed
                }
            }
        }.store(in: &cancellables)


        peer.$tracks.sinkChanges(added: { [weak self] track in
            onMain { [weak self] in
                guard let self else { return }
                delegate?.transport(self, didReceiveMediaStream: track)
            }
        }, removed: { [weak self] track in
            onMain { [weak self] in
                guard let self else { return }
                delegate?.transport(self, didRemoveMediaStream: track)
            }
        }).store(in: &cancellables)

        peer.$dataChannels.sinkChanges(added: { [weak self] channel in
            // Deliberately not marshalled: see `adopt`.
            self?.adopt(remote: channel)
        }, removed: { [weak self] channel in
            onMain { [weak self] in self?.forget(remote: channel) }
        }).store(in: &cancellables)
    }

    /// Wait for ICE gathering to finish, or give up on it.
    ///
    /// Signalling here is a single POST, so the description we send has to carry every candidate;
    /// there is no channel to trickle later ones over. Reading `peer.candidates` straight after
    /// createOffer() therefore both raced the worker threads still appending to that array and,
    /// on anything slower than loopback, shipped an offer with only the candidates that happened
    /// to have arrived.
    private func awaitGatheringComplete() async
    {
        guard peer.gatheringState != .complete else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [peer] in
                for await state in peer.$gatheringState.values where state == .complete { return }
            }
            group.addTask {
                // An interface that never finishes gathering must not wedge the handshake; going
                // ahead with a partial candidate list is how this behaved before, and it connects
                // often enough to be a better failure than not connecting at all.
                try? await Task.sleep(for: .seconds(Self.gatheringTimeout))
            }
            await group.next()
            group.cancelAll()
        }
        if peer.gatheringState != .complete
        {
            logger.warning("ICE gathering didn't complete within \(Self.gatheringTimeout)s; signalling \(peer.candidates.count) candidate(s) anyway")
        }
    }
    static let gatheringTimeout: TimeInterval = 5

    /// Check if both ICE and data channels are ready; transition to .connected if so.
    private func maybeConnected()
    {
        let peerConnected = (peer.state == .connected)
        let allChannelsOpen = !channels.isEmpty && channels.values.allSatisfy({ $0.isOpen })
        guard peerConnected && allChannelsOpen else { return }

        let didTransition = connectionState.transitionIf(to: .connected) { state in
            if case .connecting = state { return true }
            return false
        }
        if didTransition
        {
            logger.info("Transport is fully connected (ICE + data channels)")
            delegate?.transport(didConnect: self)
        }
    }
    
    public func generateOffer() async throws -> SignallingPayload
    {
        connectionState.transition(to: .connecting)
        self.connectionStatus.signalling = .connecting

        try peer.lockLocalDescription(type: .offer)
        let offerSdp = try peer.createOffer()
        logger.info("Generated my offer: \(offerSdp)")

        await awaitGatheringComplete()
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
        connectionState.transition(to: .connecting)
        self.connectionStatus.signalling = .connecting
        logger.info("Received offer from remote: \(offer)")
        
        try peer.set(remote: offer.sdp, type: .offer)
        try peer.lockLocalDescription(type: .answer)
        // TODO: set remote ice candidates in peer from the offer
        let answerSdp = try peer.createAnswer()
        logger.info("Generated my answer: \(answerSdp)")

        await awaitGatheringComplete()
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
    
    public func rollbackOffer() async throws
    {
        try peer.set(remote: "", type: .rollback)
    }
    
    public func scheduleRenegotiation()
    {
        logger.info("Transport requests renegotiation from session...")
        self.delegate!.transport(requestsRenegotiation: self)
    }
    
    public func disconnect()
    {
        self.connectionStatus.signalling = .idle
        let didTransition = connectionState.transitionIf(to: .disconnected) { $0 != .disconnected }
        peer.close()
        // libdatachannel doesn't always fire the closed callback on manual close,
        // so we handle it via the state machine transition above.
        if didTransition
        {
            delegate?.transport(didDisconnect: self)
        }
        clientId = nil
        logger[metadataKey: "clientId"] = nil
        cancellables.forEach { $0.cancel() }
    }
    
    public func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel?
    {
        guard let channelId = label.channelId else
        {
            // Media: in-band (no offer/answer), unreliable - a retransmitted voice frame is too late.
            return createMediaChannel(label: label)
        }

        let channel = try! peer.createDataChannel(label: label.rawValue, reliability: reliable ? .reliable : .unreliable, streamId: UInt16(channelId), negotiated: true)
        channels[label.rawValue] = channel
        
        channel.$lastMessage.sink { [weak self, weak channel] message in
            guard let self, let channel, let message else { return }
            self.dataDelegate?.transport(self, didReceiveData: message, on: channel)
        }.store(in: &cancellables)
        channel.$isOpen.sink { [weak self, weak channel] isOpen in
            onMain { [weak self, weak channel] in
                guard let self, let channel else { return }
                connectionStatus.data = isOpen ? .connected : (channel.lastError != nil) ? .failed : .idle
                if isOpen { maybeConnected() }
            }
        }.store(in: &cancellables)

        return channel
    }

    private func createMediaChannel(label: DataChannelLabel) -> DataChannel?
    {
        do
        {
            let channel = try peer.createDataChannel(label: label.rawValue, reliability: .unreliable)
            channels[label.rawValue] = channel
            return channel
        }
        catch
        {
            logger.error("Failed to open media channel \(label.rawValue): \(error)")
            return nil
        }
    }

    /// Open an outgoing voice stream. No m-line, no offer/answer: the channel is the stream,
    /// and the far side learns about it in-band.
    ///
    /// - Parameter mediaId: names the stream inside this client's own namespace, and must
    ///   contain no period; the place prefixes it with the sender's short client id to build
    ///   the id listeners see.
    /// - Throws: `MediaStreamIdError.containsPeriod` for an id the place could not encode.
    public func createOutgoingMediaStream(mediaId: MediaStreamId) throws -> DataChannelMediaStream
    {
        guard !mediaId.contains(".") else { throw MediaStreamIdError.containsPeriod(mediaId) }
        return try openOutgoingMediaStream(mediaId: mediaId)
    }

    /// The place's own outgoing ids are already two-component, so forwarding skips the check
    /// the client-facing API makes.
    private func openOutgoingMediaStream(mediaId: MediaStreamId) throws -> DataChannelMediaStream
    {
        let label = DataChannelLabel.media(mediaId)
        guard let channel = createMediaChannel(label: label) as? AlloWebRTCPeer.DataChannel else
        {
            throw AlloverseError(code: AlloverseErrorCode.internalServerError, description: "Could not open media channel for \(mediaId)")
        }
        let stream = DataChannelMediaStream(mediaId: mediaId, direction: .sendonly, closeChannel: { [weak channel] in channel?.close() }) { [weak channel] data in
            guard let channel, channel.isOpen else { return false }
            do { try channel.send(data: data); return true }
            catch { return false }
        }
        mediaStreams[mediaId] = stream
        return stream
    }

    /// How many voice channels a remote peer may open on one transport. A peer can open them
    /// in-band before it has announced, so nothing else bounds what it costs us to keep.
    static let maximumMediaStreams = 8
    private var adoptedMediaStreams: Int { mediaStreams.values.count { $0.streamDirection == .recvonly } }

    /// Adopt a media channel the far side opened in-band. Subscribes on libdatachannel's
    /// thread - see docs/voice-implementation.md, Threads.
    private nonisolated func adopt(remote channel: AlloWebRTCPeer.DataChannel)
    {
        guard let label = DataChannelLabel(rawValue: channel.label), case .media(let mediaId) = label else { return }

        let stream = DataChannelMediaStream(mediaId: mediaId, direction: .recvonly) { [weak channel] data in
            guard let channel, channel.isOpen else { return false }
            do { try channel.send(data: data); return true }
            catch { return false }
        }
        let subscription = channel.$lastMessage.sink { [weak stream] message in
            guard let stream, let message else { return }
            stream.deliver(message)
        }

        onMain { [weak self] in
            guard let self else { return subscription.cancel() }
            guard mediaStreams[mediaId] == nil else { return subscription.cancel() }
            guard adoptedMediaStreams < Self.maximumMediaStreams else
            {
                logger.warning("Refusing media stream \(mediaId): already carrying \(Self.maximumMediaStreams) incoming streams")
                subscription.cancel()
                channel.close()
                return
            }
            mediaStreams[mediaId] = stream
            channels[channel.label] = channel
            cancellables.insert(subscription)
            logger.info("Adopted incoming media stream \(mediaId)")
            delegate?.transport(self, didReceiveMediaStream: stream)
        }
    }

    private func forget(remote channel: AlloWebRTCPeer.DataChannel)
    {
        guard let label = DataChannelLabel(rawValue: channel.label), case .media(let mediaId) = label,
              let stream = mediaStreams.removeValue(forKey: mediaId) else { return }
        channels[channel.label] = nil
        // Outgoing channels close through here too; only incoming ones were streams to the session.
        guard stream.streamDirection != .sendonly else { return }
        logger.info("Lost media stream \(mediaId)")
        delegate?.transport(self, didRemoveMediaStream: stream)
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
        var logger = Logger(labelSuffix: "transport.libdatachannel").forClient(receiver.clientId!)
        logger.info("Forwarding media stream \(mediaStream.mediaId) from \(sender.clientId) to \(receiver.clientId)")

        if let source = mediaStream as? DataChannelMediaStream
        {
            // The sender named this one, so it is checked here rather than trusted.
            guard !source.mediaId.contains(".") else { throw MediaStreamIdError.containsPeriod(source.mediaId) }
            let receiverHeadless = (receiver as! HeadlessWebRTCTransport)
            let placeStreamId = PlaceStreamId(shortClientId: sender.clientId!.shortClientId, incomingMediaId: source.mediaId)
            let destination = try receiverHeadless.openOutgoingMediaStream(mediaId: placeStreamId.outgoingMediaId)
            // No scheduleRenegotiation(): an in-band data channel needs no offer/answer.
            return DataChannelForwarder(from: source, to: destination)
        }

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
