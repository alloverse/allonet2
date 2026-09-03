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
        let into = DataChannelMediaStream(mediaId: "screen-test", direction: .recvonly, kind: .screen) { _ in true }
        let out = DataChannelMediaStream(mediaId: "screen-test", direction: .sendonly, kind: .screen,
                                         bufferedAmount: { buffered.value })
        { data in into.deliver(data); return true }
        return (out, into)
    }

    @Test func picturesSentByASenderDecodeAtAReceiver() async throws
    {
        let (out, into) = Self.streamPair()
        let source = PatternSource(width: 320, height: 180, fps: 60)
        let sender = ScreenSender(source: source, stream: out)
        let receiver = ScreenReceiver(stream: into)
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
        #expect(got.decoded >= 10, "\(got)")
    }

    /// The only congestion signal a data channel gives is its queue, so a sender that ignores it
    /// buries the share under seconds of stale pictures.
    @Test func backpressureDropsPicturesAndLowersTheBitrate() async throws
    {
        let buffered = Counter()
        let (out, _) = Self.streamPair(buffered: buffered)
        let source = PatternSource(width: 320, height: 180, fps: 60)
        let sender = ScreenSender(source: source, stream: out)
        defer { sender.stop() }

        let running = Task { try await sender.start() }
        try await waitFor("the first picture") { sender.counters.snapshot.sent >= 1 }

        buffered.value = ScreenSender.minimumHighWater * 2
        try await waitFor("dropped pictures") { sender.counters.snapshot.droppedForBackpressure >= 3 }
        #expect(sender.bitrate ?? 0 < ScreenSender.initialBitrate, "bitrate stayed at \(sender.bitrate ?? -1)")

        let droppedWhileFull = sender.counters.snapshot.droppedForBackpressure
        let sentWhileFull = sender.counters.snapshot.sent
        buffered.value = 0
        try await waitFor("sending to resume") { sender.counters.snapshot.sent > sentWhileFull }
        #expect(sender.counters.snapshot.droppedForBackpressure == droppedWhileFull, "kept dropping after the queue drained")
        #expect(sender.bitrate ?? 0 >= ScreenSender.minimumBitrate)

        sender.stop()
        _ = try await running.value
    }

    @Test func aGapInTheSequenceAsksForAKeyframe() async throws
    {
        let (_, into) = Self.streamPair()
        let receiver = ScreenReceiver(stream: into)
        let asked = Counter()
        receiver.needsKeyframe = { asked.value += 1 }
        defer { receiver.stop() }

        let encoder = try H264Encoder(width: 320, height: 180, bitrate: 1_000_000)
        var encoded: [EncodedFrame] = []
        for index in 0..<4
        {
            let picture = CapturedFrame(pixels: PatternSource.picture(frame: index, width: 320, height: 180),
                                        capturedAt: Double(index) / 30)
            if let frame = try await encoder.encode(picture, forceKeyframe: index == 0) { encoded.append(frame) }
        }
        #expect(encoded.count >= 3)

        // Numbered here rather than by the stream, so the wire can lose the second frame.
        for (index, frame) in encoded.enumerated() where index != 1
        {
            let numbered = MediaFrame(kind: frame.kind, sequence: UInt32(index), timestamp: frame.timestamp, payload: frame.annexB)
            into.deliver(numbered.encoded)
        }

        #expect(receiver.counters.snapshot.gaps == 1, "\(receiver.counters.snapshot)")
        #expect(asked.value == 1)
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
