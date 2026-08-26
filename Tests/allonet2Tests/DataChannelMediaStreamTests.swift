//
//  DataChannelMediaStreamTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

// Serialized: these tests install their decoder in the process-wide `VoiceCodecs` registry.
@Suite("Data channel media stream", .serialized)
struct DataChannelMediaStreamTests
{
    private func receiver() -> DataChannelMediaStream
    {
        DataChannelMediaStream(mediaId: "voice-mic", direction: .recvonly) { _ in true }
    }

    /// Uncompressed frames, so what comes out of the ring is what went in.
    private func deliver(_ count: Int, from first: UInt32, to stream: DataChannelMediaStream)
    {
        let frameDuration = DataChannelMediaStream.frameDuration
        for sequence in first..<(first + UInt32(count))
        {
            let samples = [Float](repeating: Float(sequence), count: frameDuration)
            let payload = samples.withUnsafeBytes { Data($0) }
            stream.deliver(VoiceFrame(kind: .pcmFloat32,
                                      sequence: sequence,
                                      timestamp: sequence &* UInt32(frameDuration),
                                      payload: payload).encoded)
        }
    }

    /// The pump decodes on its own queue every 10 ms, so poll rather than sleep a fixed time.
    private func audioArrives(in ring: AudioRingBuffer, timeout: TimeInterval = 5) async throws -> Bool
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline
        {
            if ring.availableToRead() >= DataChannelMediaStream.frameDuration { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// A player stops playout by cancelling the ring, which stops the decode pump. Playing the
    /// same stream again handed back that dead ring, and nothing ever filled it.
    @Test func playsAgainAfterItsRingWasCancelled() async throws
    {
        VoiceCodecs.makeDecoder = { RawPCMVoiceCodec() }
        let stream = receiver()

        let ring = stream.render()
        deliver(5, from: 0, to: stream)
        #expect(try await audioArrives(in: ring))
        stream.notePlayout(of: ring)
        #expect(stream.lastPlayed != nil)

        ring.cancel()

        let restarted = stream.render()
        #expect(restarted !== ring)
        #expect(stream.lastPlayed == nil, "a stale mark from the cancelled ring must not survive the restart")

        // Drain what is buffered, so what arrives next can only come from a running pump.
        var sink = [Float](repeating: 0, count: DataChannelMediaStream.frameDuration)
        while restarted.availableToRead() > 0
        {
            sink.withUnsafeMutableBufferPointer { _ = restarted.read(into: [$0.baseAddress!], frames: $0.count) }
        }
        deliver(5, from: 5, to: stream)
        #expect(try await audioArrives(in: restarted), "playing the stream a second time is silent")
    }

    /// Whoever held the old ring lets go of it on its own schedule, which can be after playout
    /// has already been restarted. Cancelling a ring playout has moved on from must not stop the
    /// one it moved on to.
    @Test func cancellingAReplacedRingLeavesTheCurrentOneRunning() async throws
    {
        VoiceCodecs.makeDecoder = { RawPCMVoiceCodec() }
        let stream = receiver()

        let first = stream.render()
        deliver(5, from: 0, to: stream)
        #expect(try await audioArrives(in: first))
        first.cancel()

        let second = stream.render()
        #expect(second !== first)

        // The straggler: the old player finally drops its reference, after the restart.
        first.cancel()
        #expect(stream.render() === second, "a stale ring's cancellation threw the current one away")

        var sink = [Float](repeating: 0, count: DataChannelMediaStream.frameDuration)
        while second.availableToRead() > 0
        {
            sink.withUnsafeMutableBufferPointer { _ = second.read(into: [$0.baseAddress!], frames: $0.count) }
        }
        deliver(5, from: 5, to: stream)
        #expect(try await audioArrives(in: second), "a stale ring's cancellation stopped the current pump")
    }

    /// Frames buffered when playout stopped are as old as the pause. Replaying them ahead of what
    /// arrives next repeats audio the listener already missed, and leaves the playhead behind the
    /// sender for the rest of the stream.
    @Test func replayDoesNotStartOnFramesBufferedBeforeTheStop() async throws
    {
        VoiceCodecs.makeDecoder = { RawPCMVoiceCodec() }
        let stream = receiver()

        // More than the pump queues ahead of the ring, so the rest strands in the jitter buffer.
        let ring = stream.render()
        deliver(20, from: 0, to: stream)
        #expect(try await audioArrives(in: ring))
        #expect(stream.jitterBuffer.depth > 0, "nothing was left buffered, so the stop is untested")

        ring.cancel()
        #expect(stream.jitterBuffer.depth == 0, "the stop left stale frames buffered")

        // A gap the sender's silence would leave, short enough not to trip the resync distance.
        let restarted = stream.render()
        deliver(5, from: 60, to: stream)
        #expect(try await audioArrives(in: restarted))

        var samples = [Float](repeating: 0, count: DataChannelMediaStream.frameDuration)
        let read = samples.withUnsafeMutableBufferPointer { restarted.read(into: [$0.baseAddress!], frames: $0.count) }
        // deliver() writes each frame's own sequence into its samples.
        let oldest = samples.prefix(read).min() ?? 0
        #expect(oldest >= 60, "replay rendered frame \(oldest), buffered before the stop")
    }

    /// Cancelling a pump does not drain its queue. A tick already inside the decoder outlives the
    /// stop, and must not go on taking frames the pump that replaced it is priming from.
    @Test func aTickThatOutlivesItsPumpTakesNothingFromTheNextOne() async throws
    {
        let gate = GatedPCMVoiceCodec(holdAt: .decode)
        let stream = receiver()
        // Only this render() gets the gated decoder; the pump that replaces it decodes freely.
        VoiceCodecs.makeDecoder = { gate }
        let stopped = stream.render()
        VoiceCodecs.makeDecoder = { RawPCMVoiceCodec() }

        deliver(5, from: 0, to: stream)
        #expect(gate.entered.wait(timeout: .now() + 5) == .success, "the pump never reached the decoder")

        stopped.cancel()
        let restarted = stream.render()
        deliver(5, from: 60, to: stream)
        gate.release.signal()

        let played = try await firstRenderedFrame(of: restarted)
        #expect(played == "frame 60", "replay started on \(played); the stale tick took 60 into the ring nobody reads")
    }

    /// The same tick, suspended one step earlier: past the generation check but not yet at the
    /// dequeue. A check it can be suspended after is no check at all.
    @Test func aTickSuspendedBeforeItsDequeueTakesNothingFromTheNextPlayout() async throws
    {
        let gate = GatedPCMVoiceCodec(holdAt: .supportsFEC)
        let stream = receiver()
        VoiceCodecs.makeDecoder = { gate }
        let stopped = stream.render()
        VoiceCodecs.makeDecoder = { RawPCMVoiceCodec() }

        // The pump's first tick reaches the decoder on an empty buffer, before any frame exists.
        #expect(gate.entered.wait(timeout: .now() + 5) == .success, "the pump never reached the decoder")

        stopped.cancel()
        let restarted = stream.render()
        deliver(5, from: 60, to: stream)
        gate.release.signal()

        let played = try await firstRenderedFrame(of: restarted)
        #expect(played == "frame 60", "replay started on \(played); the stale tick dequeued 60 into the ring nobody reads")
    }

    /// `deliver` decides whether to buffer a frame before it has parsed one. A frame still in
    /// flight when playout stops belongs to the era the stop ended: the reset left nothing to
    /// judge it by, so buffering it now primes the replacement on pre-stop audio.
    @Test func aFrameInFlightAcrossTheStopIsNotBuffered() async throws
    {
        VoiceCodecs.makeDecoder = { RawPCMVoiceCodec() }
        let clock = GatedClock()
        let stream = DataChannelMediaStream(mediaId: "voice-mic", direction: .recvonly,
                                            monotonicNow: { clock.now() }) { _ in true }

        let stopped = stream.render()
        let preStop = VoiceFrame(kind: .pcmFloat32, sequence: 5, timestamp: 5 * 960,
                                 payload: [Float](repeating: 5, count: 960).withUnsafeBytes { Data($0) }).encoded
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { stream.deliver(preStop); delivered.signal() }
        #expect(clock.entered.wait(timeout: .now() + 5) == .success, "deliver never reached the clock")

        stopped.cancel()
        let restarted = stream.render()
        clock.release.signal()
        #expect(delivered.wait(timeout: .now() + 5) == .success, "the in-flight frame never landed")
        #expect(stream.counters.snapshot.late == 1, "the in-flight pre-stop frame was buffered anyway")

        deliver(5, from: 60, to: stream)
        let played = try await firstRenderedFrame(of: restarted)
        #expect(played == "frame 60", "replay primed on \(played), not on what arrived after the stop")
    }

    /// Names the first whole frame the pump writes, waiting for it. deliver() writes each frame's
    /// own sequence into its samples, so the value read back is the frame's number.
    private func firstRenderedFrame(of ring: AudioRingBuffer) async throws -> String
    {
        guard try await audioArrives(in: ring) else { return "silence" }
        var samples = [Float](repeating: 0, count: DataChannelMediaStream.frameDuration)
        let read = samples.withUnsafeMutableBufferPointer { ring.read(into: [$0.baseAddress!], frames: $0.count) }
        guard read > 0 else { return "silence" }
        guard samples.prefix(read).allSatisfy({ $0 == samples[0] }) else { return "a block of mixed frames" }
        return "frame \(Int(samples[0]))"
    }

    @Test func rejectsOversizedMessagesBeforeFanningThemOut()
    {
        let stream = receiver()
        let seen = FrameLog()
        stream.observeFrames { seen.append($0) }

        stream.deliver(Data(repeating: 0, count: 1_000_000))

        let counters = stream.counters.snapshot
        #expect(counters.received == 1)
        #expect(counters.malformed == 1, "an oversized message is malformed, not a frame")
        #expect(seen.count == 0, "an oversized message must not reach forwarders")
    }

    @Test func deliversAFrameAtTheSizeLimit() throws
    {
        let stream = receiver()
        let seen = FrameLog()
        stream.observeFrames { seen.append($0) }

        let payload = Data(repeating: 7, count: DataChannelMediaStream.maximumFrameBytes - VoiceFrame.headerSize)
        stream.deliver(VoiceFrame(kind: .opus, sequence: 0, timestamp: 0, payload: payload).encoded)

        #expect(stream.counters.snapshot.malformed == 0)
        #expect(seen.count == 1)
    }

    /// The RTP path is gone, so a stream that isn't a data channel is a caller error and has to
    /// name itself; silently returning no forwarder would leave a listener waiting for audio.
    @MainActor
    @Test func refusesToForwardAStreamThatIsNotADataChannel() throws
    {
        let options = TransportConnectionOptions(routing: .direct, bindAddress: "127.0.0.1")
        let sender = MockTransport(with: options, status: ConnectionStatus())
        let receiver = DataChannelTransport(with: options, status: ConnectionStatus())
        defer { receiver.disconnect() }

        #expect(throws: ForwardingError.notADataChannelStream("mic"))
        {
            try receiver.forward(mediaStream: MockMediaStream(mediaId: "mic"), from: sender)
        }
    }
}

/// Frames are emitted on whatever thread delivered them.
private final class FrameLog: @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
}

/// Parks whichever thread first reaches `entered`, until `release` is signalled. The seam a test
/// needs to suspend one thread at a chosen point and drive the rest of the race by hand.
private final class OneShotGate: @unchecked Sendable
{
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var passed = false

    func hold()
    {
        lock.lock(); let first = !passed; passed = true; lock.unlock()
        guard first else { return }
        entered.signal()
        release.wait()
    }
}

/// Uncompressed Float32, holding the pump at one step of its cycle. `.supportsFEC` parks it
/// before it dequeues from the jitter buffer, `.decode` after.
private final class GatedPCMVoiceCodec: VoiceDecoder, @unchecked Sendable
{
    enum Step { case supportsFEC, decode }

    var entered: DispatchSemaphore { gate.entered }
    var release: DispatchSemaphore { gate.release }

    let kind = VoiceFrame.Kind.pcmFloat32
    var supportsFEC: Bool { if step == .supportsFEC { gate.hold() }; return false }

    private let step: Step
    private let gate = OneShotGate()
    private let inner = RawPCMVoiceCodec()

    init(holdAt step: Step) { self.step = step }

    func decode(_ payload: Data?, fec: Bool, into output: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int
    {
        if step == .decode { gate.hold() }
        return try inner.decode(payload, fec: fec, into: output, capacity: capacity)
    }
}

/// A monotonic clock whose first reading parks the caller: the seam that holds a frame in the
/// gap between `deliver`'s receive check and its insert.
private final class GatedClock: @unchecked Sendable
{
    var entered: DispatchSemaphore { gate.entered }
    var release: DispatchSemaphore { gate.release }

    private let gate = OneShotGate()
    private let lock = NSLock()
    private var seconds = 0.0

    /// One frame duration per reading, so arrivals stay evenly spaced and the jitter estimate flat.
    func now() -> Double
    {
        lock.lock(); seconds += 0.02; let arrival = seconds; lock.unlock()
        gate.hold()
        return arrival
    }
}
