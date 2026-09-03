//
//  VoiceE2ETests.swift
//  allonet2
//
//  A real PlaceServer and real clients over libdatachannel loopback: proves the pieces meet.
//

import XCTest
import Foundation
import E2ESupport
@testable import allonet2

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
            let frame = try MediaFrame(decoding: data)
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
        let cap = DataChannelTransport.maximumMediaStreams
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
        let transport = DataChannelTransport(
            with: TransportConnectionOptions(routing: .direct, portRange: 21400..<21500),
            status: ConnectionStatus())
        defer { transport.disconnect() }

        XCTAssertThrowsError(try transport.createOutgoingMediaStream(mediaId: "voice.mic")) { error in
            XCTAssertEqual(error as? MediaStreamIdError, .containsPeriod("voice.mic"))
        }
        XCTAssertNoThrow(try transport.createOutgoingMediaStream(mediaId: "voice-mic"))
    }

    /// A stream's kind rides in its channel label, so the place adopts it knowing what it is and
    /// the channel underneath is opened the way that kind needs. Asserted on the *adopted* side,
    /// which is what the DCEP OPEN message actually carried across.
    func testAStreamsKindDecidesTheReliabilityTheFarSideSees() async throws
    {
        try await withPlace { place in
        let sharer = try await place.connectClient(named: "sharer")
        _ = try sharer.startSpeaking(mediaId: "voice-mic")
        _ = try sharer.transport().createOutgoingMediaStream(mediaId: "screen-0", kind: .video)

        let cid = sharer.client.cid!
        let voiceId = PlaceStreamId(shortClientId: cid.shortClientId, incomingMediaId: "voice-mic")
        let screenId = PlaceStreamId(shortClientId: cid.shortClientId, incomingMediaId: "screen-0")
        try await waitUntil(timeout: 15) { place.server.sfu.available[screenId] != nil && place.server.sfu.available[voiceId] != nil }

        let voice = place.server.sfu.available[voiceId]!.stream as! DataChannelMediaStream
        let screen = place.server.sfu.available[screenId]!.stream as! DataChannelMediaStream
        XCTAssertEqual(voice.kind, .voice)
        XCTAssertEqual(screen.kind, .video)

        let placeTransport = place.server.clients[cid]!.session.transport as! DataChannelTransport
        XCTAssertEqual(placeTransport.channelForTesting(.media(.voice, "voice-mic"))?.reliability,
                       .init(loss: .maxRetransmits(0), ordered: false))
        XCTAssertEqual(placeTransport.channelForTesting(.media(.video, "screen-0"))?.reliability,
                       .init(loss: .maxPacketLifeTime(ms: 1000), ordered: true))
        }
    }
}
