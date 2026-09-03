//
//  VideoSender.swift
//  AlloVideo
//

import Foundation
import CoreVideo
import allonet2

/// Source to encoder to stream, with the loop that keeps a share inside the link it has.
///
/// The link never says "slow down"; the only signal is `DataChannelMediaStream.bufferedBytes`
/// climbing, so the loop reads it before every encode. Above the high water mark it drops the
/// picture and cuts the bitrate by a fifth - dropping is what stops the queue growing, the cut is
/// what stops it happening again - and after three seconds below the low mark it gives a tenth
/// back, between a 500 kbit/s floor and a 4 Mbit/s ceiling.
///
/// ```swift
/// let sender = VideoSender(source: capturer, stream: stream)
/// Task { try await sender.start() }   // returns when the source stops
/// sender.requestKeyframe()            // a viewer joined, or lost its picture
/// ```
public final class VideoSender: @unchecked Sendable
{
    public let counters: VideoCountersBox

    /// Called once every picture has reached the channel, with the timestamp it carries and the
    /// monotonic time it was captured at. For latency measurement; runs on the send loop, so
    /// keep it short. Assign it before `start()`.
    public var onFrameSent: ((_ timestamp: UInt32, _ capturedAt: Double) -> Void)?

    private let source: any VideoSource
    private let stream: DataChannelMediaStream
    private let lock = NSLock()

    private var encoder: H264Encoder?
    private var size: (width: Int, height: Int)?
    private var averageEncodedBytes = 0.0
    private var keyframeRequested = false
    private var lastKeyframeAt = -Double.infinity
    private var belowLowWaterSince: Double?
    private var stopped = false

    /// Bits per second a share starts at, before the loop has learned anything about the link.
    public static let initialBitrate = 2_000_000
    public static let minimumBitrate = 500_000
    public static let maximumBitrate = 4_000_000
    /// The queue a channel is allowed to hold before pictures are dropped: two frames' worth of
    /// what this share actually encodes to, and never less than 300 KB, so a still screen with
    /// tiny deltas does not declare congestion at the first burst.
    public static let minimumHighWater = 300_000
    /// Seconds the queue must stay below half the high water mark before the bitrate climbs.
    public static let recoveryInterval = 3.0
    /// A keyframe costs a full picture; asking for one more often than this cannot help.
    public static let keyframeInterval = 1.0

    public init(source: any VideoSource, stream: DataChannelMediaStream, counters: VideoCountersBox = VideoCountersBox())
    {
        self.source = source
        self.stream = stream
        self.counters = counters
    }

    /// Encode and send until the source finishes - which the system's stop button, `stop()`, or
    /// a closed picker all do.
    ///
    /// - Throws: whatever the encoder throws. An encoder that cannot compress a picture will not
    ///   compress the next one either, so the share ends loudly rather than going black.
    public func start() async throws
    {
        for await frame in source.frames
        {
            counters.update { $0.captured += 1 }
            if lock.withLock({ stopped }) { break }
            try await send(frame)
        }
    }

    /// Stop sending. The source is stopped too, so `start()` returns.
    public func stop()
    {
        lock.lock(); stopped = true; lock.unlock()
        source.stop()
    }

    /// Ask for the next picture to be a keyframe, which is what a viewer that lost its picture
    /// needs. Rate-limited to one per second: a burst of viewers costs one keyframe, not one each.
    public func requestKeyframe()
    {
        lock.lock(); defer { lock.unlock() }
        keyframeRequested = true
    }

    private func send(_ frame: CapturedFrame) async throws
    {
        let (encoder, isNew) = try encoder(width: CVPixelBufferGetWidth(frame.pixels),
                                           height: CVPixelBufferGetHeight(frame.pixels))
        if adaptToBackpressure(now: frame.capturedAt, encoder: encoder)
        {
            counters.update { $0.droppedForBackpressure += 1 }
            return
        }
        let requested = keyframeIsDue(at: frame.capturedAt)

        guard let encoded = try await encoder.encode(frame, forceKeyframe: requested || isNew) else
        {
            counters.update { $0.encoderDropped += 1 }
            return
        }
        // Only a picture that exists answers the request; a dropped one leaves it pending.
        if requested { takeKeyframeRequest(at: frame.capturedAt) }
        // Exponential, over about the last dozen frames: the water mark has to follow a share
        // that goes from a still document to a scrolling one.
        lock.withLock { averageEncodedBytes += (Double(encoded.annexB.count) - averageEncodedBytes) / 12 }

        counters.update { $0.encoded += 1; if encoded.kind == .h264Key { $0.keyframesSent += 1 } }
        guard stream.send(payload: encoded.annexB, kind: encoded.kind, timestamp: encoded.timestamp) != nil else
        {
            counters.update { $0.sendFailed += 1 }
            return
        }
        counters.update { $0.sent += 1; $0.bytesSent += encoded.annexB.count }
        onFrameSent?(encoded.timestamp, frame.capturedAt)
    }

    /// The encoder for this picture size, made if the share resized under us - which is a new
    /// bitstream, so `isNew` says the picture has to be a keyframe.
    private func encoder(width: Int, height: Int) throws -> (encoder: H264Encoder, isNew: Bool)
    {
        let existing = lock.withLock { () -> H264Encoder? in
            if let size, size == (width, height) { return self.encoder }
            self.size = (width, height)
            self.encoder = nil
            return nil
        }
        if let existing { return (existing, false) }
        let made = try H264Encoder(width: width, height: height, bitrate: Self.initialBitrate)
        lock.withLock { self.encoder = made }
        return (made, true)
    }

    /// Whether a pending keyframe request is due. The clock runs from the last *requested*
    /// keyframe: the stream's own first picture is a keyframe too, and letting it start the
    /// second would make the first viewer to ask wait for nothing.
    internal func keyframeIsDue(at now: Double) -> Bool
    {
        lock.withLock { keyframeRequested && now - lastKeyframeAt >= Self.keyframeInterval }
    }

    /// Consume the request the picture just encoded satisfies, and restart the rate limit.
    internal func takeKeyframeRequest(at now: Double)
    {
        lock.withLock { keyframeRequested = false; lastKeyframeAt = now }
    }

    /// - Returns: true when this picture should be dropped rather than encoded.
    private func adaptToBackpressure(now: Double, encoder: H264Encoder) -> Bool
    {
        let buffered = stream.bufferedBytes
        lock.lock()
        let highWater = max(Self.minimumHighWater, Int(2 * averageEncodedBytes))
        lock.unlock()

        if buffered > highWater
        {
            lock.lock(); belowLowWaterSince = nil; lock.unlock()
            encoder.bitrate = max(Self.minimumBitrate, encoder.bitrate * 4 / 5)
            return true
        }
        guard buffered <= highWater / 2 else
        {
            lock.lock(); belowLowWaterSince = nil; lock.unlock()
            return false
        }

        lock.lock()
        let since = belowLowWaterSince ?? now
        if belowLowWaterSince == nil { belowLowWaterSince = now }
        let recovered = now - since >= Self.recoveryInterval
        if recovered { belowLowWaterSince = now }
        lock.unlock()

        if recovered { encoder.bitrate = min(Self.maximumBitrate, encoder.bitrate * 11 / 10) }
        return false
    }

    /// What the encoder is currently asked for, in bits per second. Nil before the first picture,
    /// which is where the encoder is made.
    public var bitrate: Int?
    {
        lock.lock(); let encoder = self.encoder; lock.unlock()
        return encoder?.bitrate
    }
}
