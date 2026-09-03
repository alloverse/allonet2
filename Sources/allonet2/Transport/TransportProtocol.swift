//
//  TransportProtocol.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import OpenCombineShim

public typealias ClientId = UUID
extension ClientId
{
    // Used when describing media IDs, because a full UUID is too long
    public var shortClientId: String {
        return String(uuidString.split(separator: "-").first!)
    }
}

@MainActor
public protocol TransportDelegate: AnyObject {
    func transport(didConnect transport: Transport)
    func transport(didDisconnect transport: Transport)
    func transport(_ transport: Transport, didChangeSignallingState state: TransportSignallingState)
    nonisolated func transport(_ transport: Transport, didReceiveData data: Data, on channel: DataChannel)
    func transport(_ transport: Transport, didReceiveMediaStream stream: MediaStream)
    func transport(_ transport: Transport, didRemoveMediaStream stream: MediaStream)
    func transport(requestsRenegotiation transport: Transport)
}

/// A Transport wraps a WebRTC peer connection with Alloverse specific peer semantics, but no
/// business logic.
///
/// `DataChannelTransport` is the only implementation that speaks to a real peer. The protocol
/// survives as the seam the unit tests substitute a mock through, so a session, a client or a
/// whole place can be driven without ICE, timing or a network. Production code names the
/// concrete type.
public protocol Transport: AnyObject
{
    var clientId: ClientId? { get set }
    var delegate: TransportDelegate? { get set }
    
    // Connection lifecycle
    func generateOffer() async throws -> SignallingPayload
    func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload
    func acceptAnswer(_ answer: SignallingPayload) async throws
    func rollbackOffer() async throws
    func disconnect()
    
    // Data channels
    func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel?
    func send(data: Data, on channel: DataChannelLabel)
    
    /// Open a copy of an incoming stream on *this* transport and start copying frames into it.
    ///
    /// - Parameters:
    ///   - mediaStream: a stream that arrived on `sender`.
    ///   - sender: the transport it arrived on; its client id names the outgoing stream.
    /// - Returns: a running forwarder; `stop()` it to close the outgoing stream.
    func forward(mediaStream: MediaStream, from sender: any Transport) throws -> MediaStreamForwarder
}

public struct TransportConnectionOptions: Sendable
{
    public let routing: TransportRouting
    public let ipOverride: IPOverride?
    public let portRange: Range<Int>?
    /// Gather candidates on this interface only. "127.0.0.1" keeps a connection inside the
    /// machine, which is what the in-process tests need.
    public let bindAddress: String?

    public init(routing: TransportRouting = .direct, ipOverride: IPOverride? = nil, portRange: Range<Int>? = nil, bindAddress: String? = nil)
    {
        self.routing = routing
        self.ipOverride = ipOverride
        self.portRange = portRange
        self.bindAddress = bindAddress
    }
}

public enum TransportRouting
{
    case direct // no STUN nor TURN
    // STUN allows NAT hole punching using a third party
    case standardSTUN // Google, Twilio and some other free options
    case STUN(servers: [String])
}

public struct IPOverride
{
    public let from: String
    public let to: String
    
    public init(from: String, to: String)
    {
        self.from = from
        self.to = to
    }
}

public enum TransportSignallingState: UInt32
{
    case stable = 0
    case haveLocalOffer = 1
    case haveRemoteOffer = 2
    case haveLocalPRAnswer = 3
    case haveRemotePRAnswer = 4
}

/// What a media stream carries, and therefore how its data channel is opened.
///
/// The kind is the label's prefix, so it travels in the DCEP OPEN message: a peer knows what it
/// has adopted before a single frame arrives, and the place forwards a stream with the
/// reliability its own kind asks for.
public enum MediaStreamKind: String, Sendable, CaseIterable
{
    /// Real-time audio. A frame that arrives after its play slot is worthless and a
    /// retransmission only delays the frames behind it, so its channel does neither.
    case voice
    /// A shared screen. An H.264 access unit needs every byte, and in order, or the decoder
    /// loses the pictures after it too - but a frame nobody could render within a second is
    /// not worth blocking the ones behind it either.
    case screen

    /// The prefix every one of this kind's channel labels starts with: `"voice/"`, `"screen/"`.
    public var labelPrefix: String { rawValue + "/" }
}

public enum DataChannelLabel: RawRepresentable, Hashable, Sendable
{
    case interactions
    case intentWorldState
    case logs
    /// One media stream, of one kind. Channel-per-stream is what lets the SFU route frames
    /// without looking inside them, and removes the stream id from the frame header.
    case media(MediaStreamKind, MediaStreamId)

    public var rawValue: String {
        switch self {
        case .interactions: "interactions"
        case .intentWorldState: "worldstate"
        case .logs: "logs"
        case .media(let kind, let mediaId): kind.labelPrefix + mediaId
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "interactions": self = .interactions
        case "worldstate": self = .intentWorldState
        case "logs": self = .logs
        default:
            // A peer picks the label, so only the prefixes this build knows are media at all.
            guard let kind = MediaStreamKind.allCases.first(where: { rawValue.hasPrefix($0.labelPrefix) }) else { return nil }
            let mediaId = String(rawValue.dropFirst(kind.labelPrefix.count))
            guard !mediaId.isEmpty else { return nil }
            self = .media(kind, mediaId)
        }
    }

    /// Pre-agreed SCTP stream for the control channels, which both sides create up front.
    /// Media channels are opened in-band and SCTP assigns their stream, so they have none.
    public var channelId: Int32? { get {
        switch self {
        case .interactions: 1
        case .intentWorldState: 2
        case .logs: 3
        case .media: nil
        }
    } }

    public var isMedia: Bool { if case .media = self { return true }; return false }
}

public protocol DataChannel {
    var alloLabel: DataChannelLabel { get }
    var isOpen: Bool { get }
}

public enum MediaStreamDirection: UInt32
{
    case unknown = 0
    case sendonly = 1
    case recvonly = 2
    case sendrecv = 3
    
    public var isRecv: Bool { self == .recvonly || self == .sendrecv }
    public var isSend: Bool { self == .sendonly || self == .sendrecv }
}

/// Names one media stream, and is the suffix of its data channel's label - `voice/<id>` or
/// `screen/<id>`, depending on the stream's `MediaStreamKind`.
///
/// It has two shapes, and which one a value carries depends on where it is read:
///
/// - **In the sender's own namespace** - what a peer passes to
///   `DataChannelTransport.createOutgoingMediaStream`, and what the place sees on an incoming
///   stream - it is a single component and must contain no period, e.g. `"voice-mic"`. An id
///   with a period is refused with `MediaStreamIdError.containsPeriod`, because the place
///   builds the id below by joining on one.
/// - **Everywhere else** - the place's outgoing streams, listeners, `LiveMedia.mediaId`,
///   `LiveMediaListener.mediaIds` - it is a `PlaceStreamId` as a string, two components
///   separated by a period: `"<shortClientId>.<mediaId>"`, e.g. `"3F2504E0.voice-mic"`. That
///   is what `PlaceStreamId.outgoingMediaId` writes and `String.psi` parses back.
///
/// An alias, not a wrapper: it enforces nothing at compile time, and exists so a `String` in a
/// signature or a dictionary key says which of the two it is. See docs/voice.md.
public typealias MediaStreamId = String

/// One media stream, flowing one way: today, one data channel carrying one mono voice stream.
///
/// There is no track layer under this and no bundle over it - a stream is not a set of
/// anything, and nothing is multiplexed inside one. `DataChannelMediaStream` is the only
/// implementation, and the same object serves all three roles: a sender writes frames to it,
/// the place copies its bytes onward, a receiver decodes them. See docs/voice.md.
public protocol MediaStream: CustomStringConvertible
{
    /// Which stream this is; see `MediaStreamId` for the two shapes it takes.
    ///
    /// Single-component, in the sending client's own namespace, on the place's incoming side.
    /// The two-component `PlaceStreamId` string everywhere else - the place's outgoing streams,
    /// and every stream a client holds.
    var mediaId: MediaStreamId { get }

    /// Which way frames move on this peer's end of the stream: `.sendonly` for one this peer
    /// opened, `.recvonly` for one it adopted from a peer.
    var streamDirection: MediaStreamDirection { get }

    /// This stream's decoded audio, and the act of starting to decode it.
    ///
    /// The first call starts a decode pump that drains the jitter buffer into a ring buffer at
    /// playout rate; every later call hands back that same buffer, so several renderers share
    /// one decode. The caller drains it - typically from an audio device's render callback -
    /// and `cancel()`s it to stop the pump. Until someone calls this, nothing is decoded, which
    /// is how the place forwards a stream while linking no codec at all.
    func render() -> AudioRingBuffer
}

/// A local audio source the user can mute without disturbing the stream it feeds.
///
/// `AlloUserClient.createMicrophoneTrackIfNeeded()` hands one out for the microphone. Setting
/// `isEnabled` starts and stops capture; the stream, its data channel and its listeners are
/// untouched, so unmuting is silent-to-audible with no renegotiation and no rejoin.
public protocol AudioTrack
{
    var isEnabled: Bool { get set }
}

public protocol MediaStreamForwarder
{
    func stop()

    // debugging info
    var forwardedMessageCount: Int { get }
    var lastError: Error? { get }
    var lastErrorAt: Date? { get }
}

// Identifies a single `MediaStream` in the namespace of the entire place. Used as key for hash lookups of `PlaceStream`s
public struct PlaceStreamId: Equatable, Hashable, Codable, CustomStringConvertible
{
    // Shortened version of the sending client's ID, to keep the id readable
    public let shortClientId: String
    // A single MediaStream ID in the namespace of the sending client. Should not contain a period.
    public let incomingMediaId: MediaStreamId
    // String version of the place stream ID, which is the media id every listener sees. Contains a period separating the shortened client ID and the mediaId.
    public var outgoingMediaId: MediaStreamId {
        return "\(shortClientId).\(incomingMediaId)"
    }
    public var description: String { return outgoingMediaId }

    public init(shortClientId: String, incomingMediaId: MediaStreamId) {
        self.shortClientId = shortClientId
        self.incomingMediaId = incomingMediaId
    }
    
    // TODO: Just have the server allocate stream IDs, so we don't need to have per-client stream namespaces
}

/// A media id in a client's own namespace broke `PlaceStreamId`'s encoding. The place joins it
/// to the sender's short client id with a period, so a period inside it makes the result
/// unparseable and every listener silently ignores the stream.
public enum MediaStreamIdError: Error, Equatable, CustomStringConvertible
{
    case containsPeriod(MediaStreamId)

    public var description: String
    {
        switch self
        {
        case .containsPeriod(let mediaId): "media id '\(mediaId)' contains a period, which separates a PlaceStreamId's two components"
        }
    }
}

extension MediaStream
{
    public var description: String
    {
        return "<MediaStream '\(mediaId)' (\(streamDirection))>"
    }
}
