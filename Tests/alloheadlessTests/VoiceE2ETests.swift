//
//  VoiceE2ETests.swift
//  allonet2
//
//  A real PlaceServer and real clients over libdatachannel loopback: proves the pieces meet.
//

import XCTest
import Foundation
@testable import allonet2
@testable import alloheadless

@MainActor
final class VoiceE2ETests: XCTestCase
{
    /// Marker audio: every sample of frame N is N, so a receiver can name the frame it holds.
    static func markerSamples(frame: Int, count: Int = DataChannelMediaStream.frameDuration) -> [Float]
    {
        [Float](repeating: Float(frame), count: count)
    }

    func testVoiceFlowsBetweenTwoClientsWithoutRenegotiating() async throws
    {
        try await withPlace { place in
        let speaker = try await place.connectClient(named: "speaker")
        let listener = try await place.connectClient(named: "listener")

        // The speaker opens a voice channel and advertises it, exactly as the app does.
        let outgoing = try speaker.startSpeaking(mediaId: "voice-mic")
        let placeStreamId = try await speaker.advertise(mediaId: "voice-mic")

        // The listener asks for it; the server's reconciler starts a forwarder.
        try await listener.listen(to: [placeStreamId])
        let incoming = try await listener.awaitStream(placeStreamId)

        let renegotiationsBefore = (speaker.session.renegotiationCount, listener.session.renegotiationCount)

        // Speak 100 frames, paced like real capture so the SFU sees a stream, not a burst.
        let frameCount = 100
        for frame in 0..<frameCount
        {
            var samples = Self.markerSamples(frame: frame)
            samples.withUnsafeBufferPointer { buffer in
                outgoing.send(samples: buffer.baseAddress!, frameCount: buffer.count)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        try await waitUntil(timeout: 5) { incoming.counters.snapshot.received >= frameCount - 2 }

        let sent = outgoing.counters.snapshot
        let got = incoming.counters.snapshot
        XCTAssertEqual(sent.captured, frameCount)
        XCTAssertEqual(sent.encoded, frameCount)
        XCTAssertEqual(sent.sent, frameCount, "every captured frame must reach the channel")
        XCTAssertEqual(sent.sendFailed, 0)
        XCTAssertGreaterThanOrEqual(got.received, frameCount - 2, "counters: \(got)")
        XCTAssertEqual(got.malformed, 0, "every frame must parse: \(got)")

        XCTAssertEqual(speaker.session.renegotiationCount, renegotiationsBefore.0,
                       "opening and using a voice stream must not renegotiate")
        XCTAssertEqual(listener.session.renegotiationCount, renegotiationsBefore.1,
                       "receiving a forwarded voice stream must not renegotiate")
        }
    }

    /// Frames must arrive intact and in order, carrying the samples that were sent.
    func testFramesArriveIntactAndInOrder() async throws
    {
        try await withPlace { place in
        let speaker = try await place.connectClient(named: "speaker")
        let listener = try await place.connectClient(named: "listener")

        let outgoing = try speaker.startSpeaking(mediaId: "voice-mic")
        let placeStreamId = try await speaker.advertise(mediaId: "voice-mic")
        try await listener.listen(to: [placeStreamId])
        let incoming = try await listener.awaitStream(placeStreamId)

        // Collect frames as bytes, before any jitter buffering, so this asserts on the wire.
        let collected = FrameLog()
        incoming.observeFrames { collected.append($0) }

        let frameCount = 60
        for frame in 0..<frameCount
        {
            var samples = Self.markerSamples(frame: frame)
            samples.withUnsafeBufferPointer { buffer in
                outgoing.send(samples: buffer.baseAddress!, frameCount: buffer.count)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await waitUntil(timeout: 5) { collected.count >= frameCount - 2 }

        var previousSequence: UInt32?
        for data in collected.frames
        {
            let frame = try VoiceFrame(decoding: data)
            XCTAssertEqual(frame.kind, .pcmFloat32)
            if let previous = previousSequence
            {
                XCTAssertTrue(frame.sequence.isNewerSequence(than: previous), "loopback must not reorder")
            }
            previousSequence = frame.sequence

            // The marker survives the whole path byte for byte.
            let samples = frame.payload.withUnsafeBytes { raw in
                Array(UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: Float.self),
                                          count: raw.count / MemoryLayout<Float>.size))
            }
            XCTAssertEqual(samples.count, DataChannelMediaStream.frameDuration)
            XCTAssertEqual(samples.first, Float(frame.sequence))
            XCTAssertEqual(samples.last, Float(frame.sequence))
        }
        XCTAssertGreaterThanOrEqual(collected.count, frameCount - 2)
        }
    }

    /// Closes the loop: sent samples come back out of `render()`; every other test here
    /// stops at the wire.
    func testDecodedAudioComesOutOfTheRenderSeam() async throws
    {
        try await withPlace { place in
        VoiceCodecs.makeDecoder = { RawPCMVoiceCodec() }

        let speaker = try await place.connectClient(named: "speaker")
        let listener = try await place.connectClient(named: "listener")

        let outgoing = try speaker.startSpeaking(mediaId: "voice-mic")
        let placeStreamId = try await speaker.advertise(mediaId: "voice-mic")
        try await listener.listen(to: [placeStreamId])
        let incoming = try await listener.awaitStream(placeStreamId)

        // Starts the decode pump. This is the same call SpatialAudioPlayer makes.
        let ring = incoming.render()

        for frame in 0..<60
        {
            var samples = Self.markerSamples(frame: frame)
            samples.withUnsafeBufferPointer { buffer in
                outgoing.send(samples: buffer.baseAddress!, frameCount: buffer.count)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        let frameSize = DataChannelMediaStream.frameDuration
        try await waitUntil(timeout: 10) { ring.availableToRead() >= frameSize }

        var decoded = [Float](repeating: -1, count: frameSize)
        let read = decoded.withUnsafeMutableBufferPointer { buffer -> Int in
            ring.read(into: [buffer.baseAddress!], frames: buffer.count)
        }
        XCTAssertEqual(read, frameSize)

        // A whole frame of one value means nothing was torn, shifted or interleaved.
        XCTAssertEqual(Set(decoded).count, 1, "a decoded frame must hold one marker value, got \(Set(decoded).sorted().prefix(4))")
        XCTAssertGreaterThanOrEqual(decoded[0], 0, "decoded silence rather than audio")
        XCTAssertLessThan(decoded[0], 60)

        let counters = incoming.counters.snapshot
        XCTAssertGreaterThan(counters.decoded, 0, "counters: \(counters)")
        XCTAssertEqual(counters.malformed, 0, "counters: \(counters)")
        print("PLAYOUT COUNTERS \(counters); ring underruns \(ring.underruns)")
        }
    }

    /// Listeners joining and leaving must cost no renegotiation, and must not disturb the speaker.
    func testJoinLeaveChurnCostsNoRenegotiation() async throws
    {
        try await withPlace { place in
        let speaker = try await place.connectClient(named: "speaker")
        let outgoing = try speaker.startSpeaking(mediaId: "voice-mic")
        let placeStreamId = try await speaker.advertise(mediaId: "voice-mic")

        let speakerRenegotiationsBefore = speaker.session.renegotiationCount

        for round in 0..<3
        {
            let listener = try await place.connectClient(named: "listener-\(round)")
            try await listener.listen(to: [placeStreamId])
            let incoming = try await listener.awaitStream(placeStreamId)

            let before = incoming.counters.snapshot.received
            for frame in 0..<20
            {
                var samples = Self.markerSamples(frame: frame)
                samples.withUnsafeBufferPointer { buffer in
                    outgoing.send(samples: buffer.baseAddress!, frameCount: buffer.count)
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try await waitUntil(timeout: 5) { incoming.counters.snapshot.received > before }
            XCTAssertEqual(listener.session.renegotiationCount, 0, "round \(round): listener renegotiated")

            listener.client.disconnect()
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        XCTAssertEqual(speaker.session.renegotiationCount, speakerRenegotiationsBefore,
                       "listeners coming and going must not renegotiate the speaker")
        XCTAssertEqual(outgoing.counters.snapshot.sendFailed, 0, "speaker's channel survived the churn")
        }
    }

    /// Seen live: a listener that joined while a dead speaker's media was still advertised kept
    /// playing that stream - silence, forever - after the server had stopped forwarding it.
    /// Stopping a forwarder must close its channel, and the listener must notice.
    func testStoppingAForwarderRemovesTheStreamFromTheListener() async throws
    {
        try await withPlace { place in
        let speaker = try await place.connectClient(named: "speaker")
        _ = try speaker.startSpeaking(mediaId: "voice-mic")
        let placeStreamId = try await speaker.advertise(mediaId: "voice-mic")

        let listener = try await place.connectClient(named: "listener")
        try await listener.listen(to: [placeStreamId])
        _ = try await listener.awaitStream(placeStreamId)

        try await listener.listen(to: [])
        try await waitUntil(timeout: 10) { listener.client.streams[placeStreamId] == nil }
        }
    }

    /// A peer opens voice channels in-band, before it has announced anything: without a cap it
    /// can make the place hold as many streams, subscriptions and channels as it likes.
    func testAPeerCannotOpenUnboundedMediaStreams() async throws
    {
        try await withPlace { place in
        let cap = HeadlessWebRTCTransport.maximumMediaStreams
        let speaker = try await place.connectClient(named: "speaker")
        for i in 0..<(cap + 3) { _ = try speaker.startSpeaking(mediaId: "voice-\(i)") }

        try await waitUntil(timeout: 15) { place.server.sfu.available.count >= cap }
        // The channels past the cap are refused, not merely slow; give them time to prove it.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(place.server.sfu.available.count, cap, "place adopted past its cap")
        }
    }

    /// A period would land inside the place's "<shortClientId>.<mediaId>", which parses into
    /// two components: listeners would ignore the stream and never say why.
    @MainActor
    func testAMediaIdWithAPeriodIsRefused() throws
    {
        let transport = HeadlessWebRTCTransport(
            with: TransportConnectionOptions(routing: .direct, portRange: 21400..<21500),
            status: ConnectionStatus())
        defer { transport.disconnect() }

        XCTAssertThrowsError(try transport.createOutgoingMediaStream(mediaId: "voice.mic")) { error in
            XCTAssertEqual(error as? MediaStreamIdError, .containsPeriod("voice.mic"))
        }
        XCTAssertNoThrow(try transport.createOutgoingMediaStream(mediaId: "voice-mic"))
    }
}

// MARK: - Harness

/// Wraps the accounting a test needs: a place, its clients, and cleanup.
@MainActor
final class TestPlace
{
    let server: PlaceServer
    let port: UInt16
    private var clients: [TestClient] = []

    init() async throws
    {
        // A fixed range per process would collide between test cases; ask the OS instead.
        port = try Self.freePort()
        server = PlaceServer(
            name: "Voice E2E",
            httpPort: port,
            transportClass: HeadlessWebRTCTransport.self,
            // Loopback only: this host gathers no candidates otherwise.
            options: TransportConnectionOptions(routing: .direct, bindAddress: "127.0.0.1"),
            alloAppAuthToken: ""
        )
        Task { try await server.start() }
        try await waitUntil(timeout: 10) { Self.isListening(on: self.port) }
    }

    func connectClient(named name: String) async throws -> TestClient
    {
        let client = try await TestClient(name: name, port: port)
        clients.append(client)
        return client
    }

    /// Awaited, not fired off - see docs/voice-implementation.md, Tests.
    func stop() async
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

enum TestPlaceError: Error, CustomStringConvertible
{
    case noFreePort
    case noAvatar
    case streamNeverArrived(MediaStreamId)

    var description: String
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
final class TestClient
{
    let client: VoiceCapturingClient
    var session: AlloSession { client.session }

    init(name: String, port: UInt16) async throws
    {
        client = VoiceCapturingClient(
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
    func startSpeaking(mediaId: MediaStreamId) throws -> DataChannelMediaStream
    {
        VoiceCodecs.makeEncoder = { RawPCMVoiceCodec() }
        guard let transport = client.transportForTesting else { throw TestPlaceError.noAvatar }
        return try transport.createOutgoingMediaStream(mediaId: mediaId)
    }

    /// Publish the LiveMedia component that makes the stream visible to other clients.
    func advertise(mediaId: MediaStreamId) async throws -> MediaStreamId
    {
        guard let avatarId = client.avatarId else { throw TestPlaceError.noAvatar }
        let placeStreamId = PlaceStreamId(shortClientId: client.cid!.shortClientId, incomingMediaId: mediaId)
        try await client.changeEntity(entityId: avatarId, addOrChange: [
            LiveMedia(mediaId: placeStreamId.outgoingMediaId, format: .audio(codec: .opus, sampleRate: 48000, channelCount: 1))
        ])
        return placeStreamId.outgoingMediaId
    }

    /// Ask the place to forward these streams to us.
    func listen(to mediaIds: [MediaStreamId]) async throws
    {
        guard let avatarId = client.avatarId else { throw TestPlaceError.noAvatar }
        try await client.changeEntity(entityId: avatarId, addOrChange: [
            LiveMediaListener(mediaIds: Set(mediaIds))
        ])
    }

    func awaitStream(_ mediaId: MediaStreamId, timeout: TimeInterval = 15) async throws -> DataChannelMediaStream
    {
        try await waitUntil(timeout: timeout) { self.client.streams[mediaId] != nil }
        guard let stream = client.streams[mediaId] else { throw TestPlaceError.streamNeverArrived(mediaId) }
        return stream
    }
}

/// Captures incoming streams, which the app would otherwise pick up in SpatialAudioPlayer.
@MainActor
final class VoiceCapturingClient: AlloAppClient
{
    private(set) var streams: [MediaStreamId: DataChannelMediaStream] = [:]
    private(set) var transportForTesting: HeadlessWebRTCTransport!

    override func reset()
    {
        let transport = HeadlessWebRTCTransport(with: self.connectionOptions, status: connectionStatus)
        transportForTesting = transport
        reset(with: transport)
    }

    override func session(_ session: AlloSession, didReceiveMediaStream stream: MediaStream)
    {
        guard let stream = stream as? DataChannelMediaStream else { return }
        streams[stream.mediaId] = stream
    }

    override func session(_ session: AlloSession, didRemoveMediaStream stream: MediaStream)
    {
        streams[stream.mediaId] = nil
    }
}

/// Frames arrive on libdatachannel's thread; collecting them needs a lock.
final class FrameLog: @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
}

/// Runs `body` against a fresh place and always tears it down, awaited.
@MainActor
func withPlace(_ body: (TestPlace) async throws -> Void) async throws
{
    let place = try await TestPlace()
    do { try await body(place) }
    catch { await place.stop(); throw error }
    await place.stop()
}

func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () async -> Bool) async throws
{
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition()
    {
        guard Date() < deadline else { throw PublisherTimeout() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

struct PublisherTimeout: Error, CustomStringConvertible { var description: String { "timed out" } }
