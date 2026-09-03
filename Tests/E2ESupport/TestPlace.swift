//
//  TestPlace.swift
//  E2ESupport
//
//  A real PlaceServer and real clients over libdatachannel loopback, shared by every
//  end-to-end suite.
//

import XCTest
import Foundation
@testable import allonet2

/// Wraps the accounting a test needs: a place, its clients, and cleanup.
@MainActor
public final class TestPlace
{
    public let server: PlaceServer
    public let port: UInt16
    private var clients: [TestClient] = []

    public init() async throws
    {
        // A fixed range per process would collide between test cases; ask the OS instead.
        port = try Self.freePort()
        server = PlaceServer(
            name: "Voice E2E",
            httpPort: port,
            // Loopback only: this host gathers no candidates otherwise.
            options: TransportConnectionOptions(routing: .direct, bindAddress: "127.0.0.1"),
            alloAppAuthToken: ""
        )
        Task { try await server.start() }
        try await waitUntil(timeout: 10) { Self.isListening(on: self.port) }
    }

    public func connectClient(named name: String) async throws -> TestClient
    {
        let client = try await TestClient(name: name, port: port)
        clients.append(client)
        return client
    }

    /// Awaited, not fired off - see docs/voice-implementation.md, Tests.
    public func stop() async
    {
        for client in clients { client.client.disconnect() }
        clients.removeAll()
        await server.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func freePort() throws -> UInt16
    {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(handle) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, length) }
        }
        guard bound == 0 else { throw TestPlaceError.noFreePort }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &length) }
        }
        guard named == 0 else { throw TestPlaceError.noFreePort }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func isListening(on port: UInt16) -> Bool
    {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(handle) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}

public enum TestPlaceError: Error, CustomStringConvertible
{
    case noFreePort
    case noAvatar
    case streamNeverArrived(MediaStreamId)

    public var description: String
    {
        switch self
        {
        case .noFreePort: "could not reserve a port for the test place"
        case .noAvatar: "client announced without an avatar"
        case .streamNeverArrived(let mediaId): "stream \(mediaId) never arrived at the listener"
        }
    }
}

/// A connected client plus the bits a voice test needs to reach.
@MainActor
public final class TestClient
{
    public let client: StreamCapturingClient
    public var session: AlloSession { client.session }

    public init(name: String, port: UInt16) async throws
    {
        client = StreamCapturingClient(
            url: URL(string: "alloplace2://localhost:\(port)")!,
            identity: Identity(expectation: .none, displayName: name, emailAddress: "", authenticationToken: ""),
            avatarDescription: EntityDescription(),
            connectionOptions: TransportConnectionOptions(routing: .direct, bindAddress: "127.0.0.1")
        )
        client.stayConnected()
        try await waitUntil(timeout: 20) { self.client.avatarId != nil }
    }

    /// Open an outgoing voice channel. Uncompressed PCM, so assertions are about the
    /// transport, not a codec.
    public func startSpeaking(mediaId: MediaStreamId) throws -> DataChannelMediaStream
    {
        VoiceCodecs.makeEncoder = { RawPCMVoiceCodec() }
        return try transport().createOutgoingMediaStream(mediaId: mediaId)
    }

    public func transport() throws -> DataChannelTransport
    {
        guard let transport = client.transportForTesting else { throw TestPlaceError.noAvatar }
        return transport
    }

    /// Publish the LiveMedia component that makes the stream visible to other clients.
    public func advertise(mediaId: MediaStreamId, format: LiveMedia.Format = .audio(codec: .opus, sampleRate: 48000, channelCount: 1)) async throws -> MediaStreamId
    {
        guard let avatarId = client.avatarId else { throw TestPlaceError.noAvatar }
        let placeStreamId = PlaceStreamId(shortClientId: client.cid!.shortClientId, incomingMediaId: mediaId)
        try await client.changeEntity(entityId: avatarId, addOrChange: [
            LiveMedia(mediaId: placeStreamId.outgoingMediaId, format: format)
        ])
        return placeStreamId.outgoingMediaId
    }

    /// Ask the place to forward these streams to us.
    public func listen(to mediaIds: [MediaStreamId]) async throws
    {
        guard let avatarId = client.avatarId else { throw TestPlaceError.noAvatar }
        try await client.changeEntity(entityId: avatarId, addOrChange: [
            LiveMediaListener(mediaIds: Set(mediaIds))
        ])
    }

    public func awaitStream(_ mediaId: MediaStreamId, timeout: TimeInterval = 15) async throws -> DataChannelMediaStream
    {
        try await waitUntil(timeout: timeout) { self.client.streams[mediaId] != nil }
        guard let stream = client.streams[mediaId] else { throw TestPlaceError.streamNeverArrived(mediaId) }
        return stream
    }
}

/// Captures incoming streams, which the app would otherwise pick up in SpatialAudioPlayer or a
/// screen viewer.
@MainActor
public final class StreamCapturingClient: AlloAppClient
{
    public private(set) var streams: [MediaStreamId: DataChannelMediaStream] = [:]
    public private(set) var transportForTesting: DataChannelTransport!

    public override func reset()
    {
        let transport = DataChannelTransport(with: self.connectionOptions, status: connectionStatus)
        transportForTesting = transport
        reset(with: transport)
    }

    public override func session(_ session: AlloSession, didReceiveMediaStream stream: MediaStream)
    {
        guard let stream = stream as? DataChannelMediaStream else { return }
        streams[stream.mediaId] = stream
    }

    public override func session(_ session: AlloSession, didRemoveMediaStream stream: MediaStream)
    {
        streams[stream.mediaId] = nil
    }
}

/// Frames arrive on libdatachannel's thread; collecting them needs a lock.
public final class FrameLog: @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [Data] = []
    public init() {}
    public func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    public var frames: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
}

/// Runs `body` against a fresh place and always tears it down, awaited.
@MainActor
public func withPlace(_ body: (TestPlace) async throws -> Void) async throws
{
    let place = try await TestPlace()
    do { try await body(place) }
    catch { await place.stop(); throw error }
    await place.stop()
}

public func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () async -> Bool) async throws
{
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition()
    {
        guard Date() < deadline else { throw PublisherTimeout() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

public struct PublisherTimeout: Error, CustomStringConvertible { public init() {}; public var description: String { "timed out" } }
