import Testing
import Foundation
import AVFoundation
@testable import AlloAudio
import allonet2

/// Writes `samples` of a sine to a temp file and opens it as a recording. The length is
/// deliberately not a multiple of a frame, so looping has to stitch frames across the seam.
private func makeRecording(samples: Int, hz: Double = 440) throws -> VoiceRecording
{
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    do
    {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))!
        buffer.frameLength = AVAudioFrameCount(samples)
        for i in 0..<samples
        {
            buffer.floatChannelData![0][i] = Float(sin(2 * .pi * hz * Double(i) / 48000)) * 0.5
        }
        try file.write(from: buffer)
    }   // the writer has to be gone before the reader opens the file
    return try VoiceRecording(url: url)
}

@Suite struct VoiceRecordingTests
{
    @Test func loopsPastTheEndWithoutEverGivingAShortFrame() throws
    {
        let recording = try makeRecording(samples: 1000)   // one frame and a bit
        #expect(abs(recording.duration - 1000.0 / 48000.0) < 0.001)
        for _ in 0..<5
        {
            #expect(try recording.nextFrame().count == VoiceRecording.frameCount)
        }
    }

    @Test func aFileThatIsNotThereFailsByName() throws
    {
        let url = URL(fileURLWithPath: "/tmp/allonet2-no-such-recording.wav")
        do
        {
            _ = try VoiceRecording(url: url)
            Issue.record("opening a file that is not there should fail")
        }
        catch let failure as VoiceRecording.Failure
        {
            #expect("\(failure)".contains(url.path))
        }
    }
}

@Suite struct VoiceRecordingPlayerTests
{
    /// The player's queue writes these; the test thread reads them.
    private final class FrameCount: @unchecked Sendable
    {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A clock the test moves, read from the player's queue.
    private final class TestClock: @unchecked Sendable
    {
        private let lock = NSLock()
        private var seconds = 1000.0
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return seconds }
        func advance(by delta: Double) { lock.lock(); seconds += delta; lock.unlock() }
    }

    private func makeStream(_ counted: FrameCount) -> DataChannelMediaStream
    {
        DataChannelMediaStream(mediaId: UUID().uuidString, direction: .sendonly) { _ in
            counted.increment()
            return true
        }
    }

    /// Frames are due by elapsed time, not by tick count, so both recordings owe the same number
    /// of frames on every tick however the ticks fall.
    @Test func oneClockKeepsTwoRecordingsInStep() throws
    {
        VoiceCodecs.makeEncoder = { RawPCMVoiceCodec() }
        let clock = TestClock()
        let player = VoiceRecordingPlayer(monotonicNow: clock.now)
        let first = FrameCount(), second = FrameCount()
        player.add(try makeRecording(samples: 1000), to: makeStream(first))
        player.add(try makeRecording(samples: 7000), to: makeStream(second))

        player.start()          // sends frame one before it returns
        defer { player.stop() }
        clock.advance(by: 0.01) // half a frame, so no tick lands on a boundary and rounds the wrong way
        for _ in 0..<9 { clock.advance(by: 0.02); player.tick() }

        #expect(first.count == 10)
        #expect(second.count == 10)
    }

    /// A tick that arrives very late sends what it can and drops the rest, rather than bursting
    /// a backlog the receiver's jitter buffer would discard anyway.
    @Test func aLateTickCatchesUpOnlySoFar() throws
    {
        VoiceCodecs.makeEncoder = { RawPCMVoiceCodec() }
        let clock = TestClock()
        let player = VoiceRecordingPlayer(monotonicNow: clock.now)
        let counted = FrameCount()
        player.add(try makeRecording(samples: 1000), to: makeStream(counted))

        player.start()
        defer { player.stop() }
        clock.advance(by: 0.01) // half a frame, so no tick lands on a boundary and rounds the wrong way
        clock.advance(by: 0.2)  // ten frames' worth of stall
        player.tick()
        #expect(counted.count == 1 + VoiceRecordingPlayer.maximumCatchUp)

        clock.advance(by: 0.02)
        player.tick()
        #expect(counted.count == 2 + VoiceRecordingPlayer.maximumCatchUp)   // the backlog is gone, not queued
    }
}
