//
//  ScreenE2ETests.swift
//  ScreenE2ETests
//
//  A real place between a real sharer and a real viewer, over libdatachannel loopback.
//

import Testing
import Foundation
import E2ESupport
import AlloVideo
@testable import allonet2

@Suite struct ScreenE2ETests
{
    static let width = 320
    static let height = 180
    static let mediaId = "screen-demo"

    /// Everything a screen test needs on the sharer's side: the stream, the pattern feeding it,
    /// and the sender in between.
    struct Sharer
    {
        let client: TestClient
        let stream: DataChannelMediaStream
        let source: PatternSource
        let sender: ScreenSender
        let placeStreamId: MediaStreamId

        func stop() { sender.stop() }
    }

    @MainActor
    static func share(from client: TestClient, fps: Double = 30) async throws -> Sharer
    {
        let stream = try client.transport().createOutgoingMediaStream(mediaId: mediaId, kind: .video)
        let placeStreamId = try await client.advertise(mediaId: mediaId, format: .video(codec: .h264, width: width, height: height))
        let source = PatternSource(width: width, height: height, fps: fps)
        let sender = ScreenSender(source: source, stream: stream)
        Task { try await sender.start() }
        return Sharer(client: client, stream: stream, source: source, sender: sender, placeStreamId: placeStreamId)
    }

    @Test @MainActor func picturesFlowFromSharerThroughThePlaceToAViewerWithoutRenegotiating() async throws
    {
        try await withPlace { place in
        let sharerClient = try await place.connectClient(named: "sharer")
        let viewer = try await place.connectClient(named: "viewer")
        let sharer = try await Self.share(from: sharerClient)
        defer { sharer.stop() }

        try await viewer.listen(to: [sharer.placeStreamId])
        let incoming = try await viewer.awaitStream(sharer.placeStreamId)
        #expect(incoming.kind == .video, "a video stream must arrive as one")

        let renegotiationsBefore = (sharerClient.session.renegotiationCount, viewer.session.renegotiationCount)
        let receiver = ScreenReceiver(stream: incoming)
        display(receiver)
        defer { receiver.stop() }

        try await waitFor("15 decoded pictures", timeout: 15) { receiver.counters.snapshot.decoded >= 15 }

        let got = receiver.counters.snapshot
        #expect(got.keyframes >= 1, "a viewer must get a keyframe to start on: \(got)")
        #expect(got.decoded >= 15, "\(got)")
        #expect(got.malformed == 0, "\(got)")
        #expect(sharer.sender.counters.snapshot.sendFailed == 0, "\(sharer.sender.counters.snapshot)")
        #expect(sharerClient.session.renegotiationCount == renegotiationsBefore.0,
                "opening and using a screen stream must not renegotiate")
        #expect(viewer.session.renegotiationCount == renegotiationsBefore.1,
                "receiving a forwarded screen stream must not renegotiate")
        }
    }

    /// Joining a share already in progress: the deltas until the next periodic keyframe are
    /// unusable, and the picture has to arrive anyway.
    @Test @MainActor func aViewerJoiningMidStreamWaitsForAKeyframeAndThenDecodes() async throws
    {
        try await withPlace { place in
        let sharerClient = try await place.connectClient(named: "sharer")
        let sharer = try await Self.share(from: sharerClient)
        defer { sharer.stop() }
        try await waitFor("the share to get going") { sharer.sender.counters.snapshot.sent >= 10 }

        let viewer = try await place.connectClient(named: "viewer")
        try await viewer.listen(to: [sharer.placeStreamId])
        let incoming = try await viewer.awaitStream(sharer.placeStreamId)
        let receiver = ScreenReceiver(stream: incoming)
        display(receiver)
        defer { receiver.stop() }

        try await waitFor("deltas to be dropped for want of a key") { receiver.counters.snapshot.droppedAwaitingKey > 0 }
        // The encoder's keyframe interval is 2 s, so a late viewer waits at most that.
        try await waitFor("the periodic keyframe", timeout: 3) { receiver.counters.snapshot.decoded > 0 }
        }
    }

    @Test @MainActor func askingForAKeyframeYieldsOneWithinASecond() async throws
    {
        try await withPlace { place in
        let sharerClient = try await place.connectClient(named: "sharer")
        let viewer = try await place.connectClient(named: "viewer")
        let sharer = try await Self.share(from: sharerClient)
        defer { sharer.stop() }

        try await viewer.listen(to: [sharer.placeStreamId])
        let incoming = try await viewer.awaitStream(sharer.placeStreamId)
        let receiver = ScreenReceiver(stream: incoming)
        display(receiver)
        defer { receiver.stop() }
        try await waitFor("the first picture") { receiver.counters.snapshot.decoded > 0 }

        let keyframesBefore = sharer.sender.counters.snapshot.keyframesSent
        let decodedBefore = receiver.counters.snapshot.decoded
        // What the owner does when the receiver says it has lost the picture.
        sharer.sender.requestKeyframe()

        try await waitFor("a keyframe on request", timeout: 1) { sharer.sender.counters.snapshot.keyframesSent > keyframesBefore }
        try await waitFor("the viewer to decode past it", timeout: 1) { receiver.counters.snapshot.decoded > decodedBefore }
        }
    }

    /// The cap is enforced where the bytes arrive, so an oversized frame is dropped by the place
    /// rather than fanned out to every viewer.
    @Test @MainActor func anOversizedFrameIsDroppedByThePlaceAndNeverReachesTheViewer() async throws
    {
        try await withPlace { place in
        let sharerClient = try await place.connectClient(named: "sharer")
        let viewer = try await place.connectClient(named: "viewer")
        let sharer = try await Self.share(from: sharerClient)
        defer { sharer.stop() }

        try await viewer.listen(to: [sharer.placeStreamId])
        let incoming = try await viewer.awaitStream(sharer.placeStreamId)
        let receiver = ScreenReceiver(stream: incoming)
        display(receiver)
        defer { receiver.stop() }
        try await waitFor("the first picture") { receiver.counters.snapshot.decoded > 0 }

        let placeStreamId = PlaceStreamId(shortClientId: sharerClient.client.cid!.shortClientId, incomingMediaId: Self.mediaId)
        let atThePlace = try #require(place.server.sfu.available[placeStreamId]?.stream as? DataChannelMediaStream)
        let malformedBefore = atThePlace.counters.snapshot.malformed
        let receivedBefore = receiver.counters.snapshot.received

        // Past the delta cap but inside the channel's 2 MiB message size, so only the cap can
        // stop it. Written straight to the channel: the stream's own send would refuse it.
        let channel = try #require(sharerClient.transport().channelForTesting(.media(.video, Self.mediaId)))
        let oversized = MediaFrame(kind: .h264Delta, sequence: 9999, timestamp: 0,
                                   payload: Data(repeating: 0, count: MediaFrame.Kind.h264Delta.maximumFrameBytes))
        try channel.send(data: oversized.encoded)

        try await waitFor("the place to count it malformed", timeout: 5) { atThePlace.counters.snapshot.malformed > malformedBefore }
        // Give the forwarder every chance to pass it on before claiming it did not.
        try await Task.sleep(nanoseconds: 500_000_000)
        let got = receiver.counters.snapshot
        #expect(got.malformed == 0, "an oversized frame must not reach a viewer at all: \(got)")
        #expect(got.received > receivedBefore, "the stream must still be flowing: \(got)")
        }
    }
}
