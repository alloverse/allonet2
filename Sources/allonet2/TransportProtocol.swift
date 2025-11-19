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

// A Transport wraps a WebRTC peer connection with Alloverse specific peer semantics, but no business logic
public protocol Transport: AnyObject
{
    init(with connectionOptions: TransportConnectionOptions, status: ConnectionStatus)
    
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
    
    // Media channels
    static func forward(mediaStream: MediaStream, from sender: any Transport, to receiver: any Transport) throws -> MediaStreamForwarder
}

public struct TransportConnectionOptions: Sendable
{
    public let routing: TransportRouting
    public let ipOverride: IPOverride?
    public let portRange: Range<Int>?
    
    public init(routing: TransportRouting = .direct, ipOverride: IPOverride? = nil, portRange: Range<Int>? = nil)
    {
        self.routing = routing
        self.ipOverride = ipOverride
        self.portRange = portRange
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

public enum DataChannelLabel: String
{
    case interactions = "interactions"
    case intentWorldState = "worldstate"
    case logs = "logs"
}

extension DataChannelLabel
{
    public var channelId: Int32 { get {
        switch self {
        case .interactions: 1
        case .intentWorldState: 2
        case .logs: 3
        }
    } }
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

public typealias MediaStreamId = String
// TODO: XXX, there is confusion whether this represents a 'stream' or a 'track'. In GoogleWebRTC, a Stream is a bundle of tracks. libdatachannel doesn't use this abstraction. This API uses MediaStream interchangeably as both, and mediaID can be either the streamId or streamId+trackId. This is confusing. Fix it!
public protocol MediaStream: CustomStringConvertible
{
    // PlaceServer side for incoming streams: This will be a single-component stream ID in the client's own namespace
    // In all other cases (clients, place outgoing streams): This will be a two-component PlaceStreamId
    var mediaId: MediaStreamId { get }
    var streamDirection: MediaStreamDirection { get }
    
    // XXX: Move to AudioTrack and add an array of audiotracks here
    func render() -> AudioRingBuffer
}

public protocol AudioTrack
{
    var isEnabled: Bool { get set }
}

public protocol MediaStreamForwarder
{
    func stop()
    
    // debugging info
    var ssrc: UInt32? { get }
    var pt: UInt8? { get }
    var forwardedMessageCount: Int { get }
    var lastError: Error? { get }
    var lastErrorAt: Date? { get }
}

// Identifies a single `MediaStream` in the namespace of the entire place. Used as key for hash lookups of `PlaceStream`s
public struct PlaceStreamId: Equatable, Hashable, Codable, CustomStringConvertible
{
    // Shortened version of the sending client's ID (to fit in sdp)
    public let shortClientId: String
    // A single MediaStream ID in the namespace of the sending client. "streamId-trackId". Should not contain a period.
    public let incomingMediaId: MediaStreamId
    // String version of the place stream ID, that is used in WebRTC as the MID sent to receiving clients. Contains a period separating the shortened client ID and the mediaId.
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

extension MediaStream
{
    public var description: String
    {
        return "<MediaStream '\(mediaId)' (\(streamDirection))>"
    }
}
