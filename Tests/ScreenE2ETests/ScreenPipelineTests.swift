//
//  ScreenPipelineTests.swift
//  ScreenE2ETests
//
//  Sender and receiver against a stream pair, with no network under it.
//

import Testing
import Foundation
import allonet2
@testable import AlloVideo

@Suite struct ScreenPipelineTests
{
    /// Two streams wired mouth to ear: what the sender writes, the receiver is delivered, with
    /// the same bytes and no place in between.
    static func streamPair(buffered: Counter = Counter()) -> (out: DataChannelMediaStream, into: DataChannelMediaStream)
    {
        let into = DataChannelMediaStream(mediaId: "screen-test", direction: .recvonly, kind: .video) { _ in true }
        let out = DataChannelMediaStream(mediaId: "screen-test", direction: .sendonly, kind: .video,
                                         bufferedAmount: { buffered.value })
        { data in into.deliver(data); return true }
        return (out, into)
    }

    @Test func picturesSentByASenderDecodeAtAReceiver() async throws
    {
        let (out, into) = Self.streamPair()
        let source = PatternSource(width: 320, height: 180, fps: 60)
        let sender = VideoSender(source: source, stream: out)
        let receiver = VideoReceiver(stream: into)
        display(receiver)
        defer { sender.stop(); receiver.stop() }

        let running = Task { try await sender.start() }
        try await waitFor("10 decoded pictures") { receiver.counters.snapshot.decoded >= 10 }
        sender.stop()
        _ = try await running.value

        let sent = sender.counters.snapshot
        let got = receiver.counters.snapshot
        #expect(sent.sendFailed == 0, "\(sent)")
        #expect(sent.keyframesSent >= 1, "\(sent)")
        #expect(sent.bytesSent > 0, "\(sent)")
        #expect(got.keyframes >= 1, "\(got)")
        #expect(got.gaps == 0, "a stream with no wire under it cannot lose frames: \(got)")
        #expect(got.malformed == 0, "\(got)")
        #expect(got.evicted == 0, "a viewer that keeps up loses no pictures: \(got)")
        #expect(got.decoded >= 10, "\(got)")
    }

    /// The only congestion signal a data channel gives is its queue, so a sender that ignores it
    /// buries the share under seconds of stale pictures.
    @Test func backpressureDropsPicturesAndLowersTheBitrate() async throws
    {
        let buffered = Counter()
        let (out, _) = Self.streamPair(buffered: buffered)
        let source = PatternSource(width: 320, height: 180, fps: 60)
        let sender = VideoSender(source: source, stream: out)
        defer { sender.stop() }

        let running = Task { try await sender.start() }
        try await waitFor("the first picture") { sender.counters.snapshot.sent >= 1 }

        buffered.value = VideoSender.minimumHighWater * 2
        try await waitFor("dropped pictures") { sender.counters.snapshot.droppedForBackpressure >= 3 }
        #expect(sender.bitrate ?? 0 < VideoSender.initialBitrate, "bitrate stayed at \(sender.bitrate ?? -1)")

        let sentWhileFull = sender.counters.snapshot.sent
        buffered.value = 0
        try await waitFor("sending to resume") { sender.counters.snapshot.sent > sentWhileFull }
        // Counted after the drain, not before it: a picture already in flight may be dropped
        // between reading the counter and clearing the queue.
        let resumed = sender.counters.snapshot.droppedForBackpressure
        try await waitFor("a few more pictures") { sender.counters.snapshot.sent > sentWhileFull + 3 }
        #expect(sender.counters.snapshot.droppedForBackpressure == resumed, "kept dropping after the queue drained")
        #expect(sender.bitrate ?? 0 >= VideoSender.minimumBitrate)

        sender.stop()
        _ = try await running.value
    }

    /// VideoToolbox gives nothing back for some pictures under load. A request answered by one
    /// of those is a viewer left waiting out the periodic keyframe.
    @Test func aPictureTheEncoderDropsDoesNotAnswerAKeyframeRequest()
    {
        let (out, _) = Self.streamPair()
        let sender = VideoSender(source: PatternSource(width: 16, height: 16, fps: 1), stream: out)
        sender.requestKeyframe()

        #expect(sender.keyframeIsDue(at: 100))
        #expect(sender.keyframeIsDue(at: 100.1), "nothing was encoded, so the request still stands")

        sender.takeKeyframeRequest(at: 100.1)
        #expect(!sender.keyframeIsDue(at: 100.2))
        sender.requestKeyframe()
        #expect(!sender.keyframeIsDue(at: 100.2), "the rate limit runs from the picture that answered")
        #expect(sender.keyframeIsDue(at: 101.2))
    }

    @Test func aGapInTheSequenceAsksForAKeyframe() async throws
    {
        let (_, into) = Self.streamPair()
        let receiver = VideoReceiver(stream: into)
        let asked = Counter()
        receiver.needsKeyframe = { asked.value += 1 }
        defer { receiver.stop() }

        let encoded = try await Self.pictures(4)
        #expect(encoded.count >= 3)

        // Numbered here rather than by the stream, so the wire can lose the second frame.
        for (index, frame) in encoded.enumerated() where index != 1
        {
            let numbered = MediaFrame(kind: frame.kind, sequence: UInt32(index), timestamp: frame.timestamp, payload: frame.annexB)
            into.deliver(numbered.encoded)
        }

        let got = receiver.counters.snapshot
        #expect(got.gaps == 1, "\(got)")
        #expect(asked.value == 1)
        // The key decoded; the deltas after the hole predict from a picture nobody has.
        #expect(got.decoded == 1 && got.droppedAwaitingKey == encoded.count - 2, "\(got)")
    }

    /// A viewer that subscribed mid-GOP never sees a hole, so nothing but the undecodable deltas
    /// themselves can tell it to ask - and it must ask once, not once per delta.
    @Test func aViewerThatJoinedMidGopAsksOnceForAKeyframe() async throws
    {
        let (_, into) = Self.streamPair()
        let asked = Counter()
        let receiver = VideoReceiver(stream: into, needsKeyframe: { asked.value += 1 })
        defer { receiver.stop() }

        // The key went out before this receiver existed; only the deltas after it arrive.
        let encoded = try await Self.pictures(6)
        let deltas = encoded.filter { $0.kind == .h264Delta }
        #expect(deltas.count >= 3)
        Self.deliver(deltas, to: into)

        let got = receiver.counters.snapshot
        #expect(got.gaps == 0, "consecutive sequences are not a gap: \(got)")
        #expect(got.droppedAwaitingKey == deltas.count, "\(got)")
        #expect(asked.value == 1, "asked \(asked.value) times")
    }

    /// `samples` keeps only the newest few pictures. One evicted from it is one the display never
    /// got, and every delta after it predicts from exactly that picture.
    @Test func aSampleEvictedFromTheBufferAsksForAKeyframe() async throws
    {
        let (_, into) = Self.streamPair()
        let asked = Counter()
        let receiver = VideoReceiver(stream: into, needsKeyframe: { asked.value += 1 })
        defer { receiver.stop() }

        // Nothing iterates `samples`, so the buffer fills and then overflows.
        Self.deliver(try await Self.pictures(12), to: into)

        let got = receiver.counters.snapshot
        #expect(got.gaps == 0, "\(got)")
        #expect(got.evicted >= 1, "the sample buffer never overflowed: \(got)")
        #expect(asked.value == got.evicted, "asked \(asked.value) times for \(got.evicted) evictions")
    }

    /// A sharer's bitstream: `count` pattern pictures, the first of them a key.
    static func pictures(_ count: Int) async throws -> [EncodedFrame]
    {
        let encoder = try H264Encoder(width: 320, height: 180, bitrate: 1_000_000)
        var encoded: [EncodedFrame] = []
        for index in 0..<count
        {
            let picture = CapturedFrame(pixels: PatternSource.picture(frame: index, width: 320, height: 180),
                                        capturedAt: Double(index) / 30)
            if let frame = try await encoder.encode(picture, forceKeyframe: index == 0) { encoded.append(frame) }
        }
        return encoded
    }

    /// Deliver as an unbroken sequence, so nothing the receiver sees looks like a lost frame.
    static func deliver(_ frames: [EncodedFrame], to stream: DataChannelMediaStream)
    {
        for (index, frame) in frames.enumerated()
        {
            let numbered = MediaFrame(kind: frame.kind, sequence: UInt32(index), timestamp: frame.timestamp, payload: frame.annexB)
            stream.deliver(numbered.encoded)
        }
    }

    @Test func aFrameOverItsKindsCapNeverReachesTheWire() throws
    {
        let (out, into) = Self.streamPair()
        let oversized = Data(repeating: 0, count: MediaFrame.Kind.h264Delta.maximumFrameBytes)
        #expect(out.send(payload: oversized, kind: .h264Delta, timestamp: 0) == nil)
        #expect(out.counters.snapshot.sendFailed == 1)
        #expect(into.counters.snapshot.received == 0, "an oversized frame must not be written at all")
    }
}

/// A number several threads touch: a test's stand-in for a channel's queue, and its tally of
/// callbacks fired on the delivering thread.
final class Counter: @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: Int
    init(_ value: Int = 0) { storage = value }
    var value: Int
    {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// A viewer's display loop without a display. `samples` has to be consumed by someone: a receiver
/// whose buffer overflows counts pictures the display never got and waits for a fresh keyframe.
/// Ends when the receiver stops.
@discardableResult
func display(_ receiver: VideoReceiver) -> Task<Void, Never>
{
    Task { for await _ in receiver.samples { receiver.counters.update { $0.displayed += 1 } } }
}

/// Poll until `condition` holds, or fail naming what never happened.
func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws
{
    let deadline = Date().addingTimeInterval(timeout)
    while !condition()
    {
        guard Date() < deadline else { throw ScreenTestTimeout(waitingFor: what) }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

struct ScreenTestTimeout: Error, CustomStringConvertible
{
    let waitingFor: String
    var description: String { "timed out waiting for \(waitingFor)" }
}
