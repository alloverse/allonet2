import Testing
import Foundation
import AVFoundation
import simd
@testable import AlloAudio

/// The tap hands us buffers of whatever size the device likes; frames on the wire are exactly
/// 960 samples. Everything in between - continuity, the backlog offset, and what muting does to
/// audio already queued - lives here rather than in the engine, which needs a device.
@Suite struct FrameAccumulatorTests
{
    private let frameSize = 960
    private let sampleRate = 48000.0

    /// Feed `count` samples counting up from `first`, and collect whatever frames come out.
    @discardableResult
    private func feed(_ accumulator: inout FrameAccumulator, _ count: Int, from first: Float) -> [(frame: [Float], offset: TimeInterval)]
    {
        var got: [(frame: [Float], offset: TimeInterval)] = []
        let samples = (0..<count).map { first + Float($0) }
        samples.withUnsafeBufferPointer { buffer in
            accumulator.accept(buffer) { frame, offset in got.append((Array(frame), offset)) }
        }
        return got
    }

    @Test func cutsWholeFramesOutOfArbitraryTapSizes() throws
    {
        var accumulator = FrameAccumulator(frameSize: frameSize, sampleRate: sampleRate)
        let tapSizes = [100, 700, 512, 1000, 33, 4096, 1]
        var emitted: [Float] = []
        var next: Float = 0
        for size in tapSizes
        {
            for (frame, _) in feed(&accumulator, size, from: next)
            {
                #expect(frame.count == frameSize)
                emitted += frame
            }
            next += Float(size)
        }

        let total = tapSizes.reduce(0, +)
        #expect(emitted.count == (total / frameSize) * frameSize)
        #expect(accumulator.pendingCount == total % frameSize)
        // Every sample, in order, exactly once: no gaps at a buffer seam and no repeats.
        #expect(emitted == (0..<emitted.count).map(Float.init))
    }

    @Test func datesAFrameBackToWhenItsOldestSampleWasCaptured() throws
    {
        var accumulator = FrameAccumulator(frameSize: frameSize, sampleRate: sampleRate)

        // A buffer that is exactly one frame starts where it was captured.
        let aligned = feed(&accumulator, frameSize, from: 0)
        #expect(aligned.count == 1)
        #expect(aligned[0].offset == 0)

        // Half a frame held back, then half a frame more: the frame started 480 samples ago.
        feed(&accumulator, frameSize / 2, from: 0)
        let straddling = feed(&accumulator, frameSize / 2, from: 0)
        #expect(straddling.count == 1)
        #expect(straddling[0].offset == -Double(frameSize / 2) / sampleRate)

        // Two frames in one buffer: the second one starts a frame later than the first.
        let pair = feed(&accumulator, frameSize * 2, from: 0)
        #expect(pair.count == 2)
        #expect(pair[1].offset - pair[0].offset == Double(frameSize) / sampleRate)
    }

    @Test func unmutingDoesNotFlushWhatWasCapturedWhileMuted() throws
    {
        var accumulator = FrameAccumulator(frameSize: frameSize, sampleRate: sampleRate)

        feed(&accumulator, frameSize / 2, from: 0)
        #expect(accumulator.pendingCount == frameSize / 2)

        accumulator.muted = true
        #expect(accumulator.pendingCount == 0, "muting drops what is already queued")
        #expect(feed(&accumulator, frameSize * 2, from: 0).isEmpty, "nothing is sent while muted")

        accumulator.muted = false
        // Half a frame short of a frame: had the muted audio survived, this would emit one.
        #expect(feed(&accumulator, frameSize / 2, from: 0).isEmpty)
        #expect(feed(&accumulator, frameSize / 2, from: 0).count == 1)
    }
}

@Suite @MainActor struct VoiceEngineTests
{
    /// Constructing an engine, or muting one, must not open a device: tone-mode voicedemo and a
    /// listener who never speaks both depend on the microphone staying untouched.
    @Test func doesNotCaptureUntilAskedTo()
    {
        let engine = VoiceEngine()
        #expect(engine.isCapturing == false)
        #expect(engine.voiceProcessingEnabled == false)

        engine.isMuted = true
        #expect(engine.isCapturing == false)

        engine.stopCapture()
        engine.stop()
        #expect(engine.isCapturing == false)
    }
}

@Suite struct SpatialMappingTests
{
    @Test func positionsMapStraightAcross()
    {
        let point = AVAudio3DPoint(SIMD3<Float>(1, -2, 3.5))
        #expect(point.x == 1)
        #expect(point.y == -2)
        #expect(point.z == 3.5)
    }

    @Test func listenerAxesComeFromTheTransform()
    {
        let identity = VoiceEngine.listenerAxes(of: matrix_identity_float4x4)
        #expect(identity.forward == SIMD3<Float>(0, 0, -1))
        #expect(identity.up == SIMD3<Float>(0, 1, 0))

        // A quarter turn to the left about +Y faces -X.
        let yaw = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        let turned = VoiceEngine.listenerAxes(of: yaw)
        #expect(abs(turned.forward.x - -1) < 1e-6)
        #expect(abs(turned.forward.z) < 1e-6)
        #expect(abs(turned.up.y - 1) < 1e-6)

        // Scale is a diorama's business, not the listener's: the axes stay unit length.
        var scaled = matrix_identity_float4x4
        scaled.columns.1 *= 100
        scaled.columns.2 *= 100
        let big = VoiceEngine.listenerAxes(of: scaled)
        #expect(abs(simd_length(big.forward) - 1) < 1e-6)
        #expect(abs(simd_length(big.up) - 1) < 1e-6)
    }
}
