//
//  DataChannelMediaStreamTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@Suite("Data channel media stream")
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
