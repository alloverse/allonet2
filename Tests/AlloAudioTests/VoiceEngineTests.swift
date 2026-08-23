import Testing
import Foundation
import AVFoundation
import simd
@testable import AlloAudio
import allonet2

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

    /// The environment node's maximumDistance only stops attenuating further, so without this
    /// cutoff a source across the place stays quietly audible forever.
    @Test func silencesSourcesPastMaxDistance()
    {
        #expect(VoiceEngine.isAudible(distance: 0, maxDistance: 10, wasAudible: false))
        #expect(VoiceEngine.isAudible(distance: 9, maxDistance: 10, wasAudible: false))
        #expect(!VoiceEngine.isAudible(distance: 10, maxDistance: 10, wasAudible: true))
        #expect(!VoiceEngine.isAudible(distance: 1000, maxDistance: 10, wasAudible: true))

        // Dead band: a source hovering at the edge keeps whichever answer it had.
        #expect(VoiceEngine.isAudible(distance: 9.9, maxDistance: 10, wasAudible: true))
        #expect(!VoiceEngine.isAudible(distance: 9.9, maxDistance: 10, wasAudible: false))
        #expect(VoiceEngine.isAudible(distance: 9.7, maxDistance: 10, wasAudible: false))
    }

    /// A wall used to take a voice to -inf; the environment node's occlusion filter only takes it
    /// to about -25 dB, which across a place is still an audible conversation through a wall.
    @Test func occludedSourcesAreSilencedRatherThanMuffled()
    {
        #expect(VoiceEngine.volume(audible: true, occlusion: 0) == 1)
        #expect(VoiceEngine.volume(audible: true, occlusion: VoiceEngine.blockedOcclusion) == 0)

        // Partial occlusion still muffles through the filter rather than cutting out.
        #expect(VoiceEngine.volume(audible: true, occlusion: -40) == 1)

        // Range and geometry silence independently; neither answer overrides the other.
        #expect(VoiceEngine.volume(audible: false, occlusion: 0) == 0)
        #expect(VoiceEngine.volume(audible: false, occlusion: VoiceEngine.blockedOcclusion) == 0)
    }

    /// A removed tap's buffers are still queued as hops to this actor; by the time they run,
    /// capture may have restarted on a different stream, which must not be sent that audio.
    @Test func dropsAudioCapturedByAReplacedTap() throws
    {
        let engine = VoiceEngine()
        let stream = DataChannelMediaStream(mediaId: "voice-mic", direction: .sendonly) { _ in true }
        engine.captureStream = stream
        let generation = engine.captureGeneration

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: DataChannelMediaStream.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(DataChannelMediaStream.frameDuration)))
        buffer.frameLength = buffer.frameCapacity

        engine.accept(buffer, capturedAt: Date(), generation: generation)
        #expect(stream.counters.snapshot.captured == 1)

        // What startCapture(sending:) does while a tap callback is still in flight.
        engine.captureGeneration &+= 1
        engine.accept(buffer, capturedAt: Date(), generation: generation)
        #expect(stream.counters.snapshot.captured == 1, "stale audio reached the stream that replaced it")
    }
}

/// What `setAudible` rests on, rendered offline so it needs no audio device. Both facts cost a
/// measurement to learn and neither is in the documentation: a source silenced the wrong way is
/// still quietly audible across the place, and a peak taken too early says the opposite of the
/// truth.
@Suite struct EnvironmentNodeSilencingTests
{
    /// Loudest sample of a 1 kHz tone through one spatialised source, ignoring the blocks where
    /// a changed gain is still ramping.
    private func settledPeak(volume: Float = 1, occlusion: Float = 0) throws -> Float
    {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let engine = AVAudioEngine()
        let environment = AVAudioEnvironmentNode()
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        var phase = 0.0
        let step = 2 * Double.pi * 1000 / 48000
        let source = AVAudioSourceNode(format: mono) { _, _, frameCount, audioBufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList)
            {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(frameCount) { samples[i] = Float(sin(phase)) * 0.5; phase += step }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: environment, fromBus: 0, toBus: environment.nextAvailableInputBus, format: mono)
        source.renderingAlgorithm = .auto
        source.position = AVAudio3DPoint(x: 0, y: 0, z: -1.5)
        source.volume = volume
        source.occlusion = occlusion

        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }

        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var peak: Float = 0
        for block in 0..<8
        {
            _ = try engine.renderOffline(4096, to: output)
            guard block >= 4, let channels = output.floatChannelData else { continue }
            for channel in 0..<Int(output.format.channelCount)
            {
                for i in 0..<Int(output.frameLength) { peak = max(peak, abs(channels[channel][i])) }
            }
        }
        return peak
    }

    /// `AVAudioMixing.volume` does reach an environment node's input, and zero really is silence -
    /// but the gain ramps, so the first block still carries the old level. Measuring there once
    /// produced a confident, wrong report that this whole mechanism was a no-op.
    @Test func volumeZeroSilencesASpatialisedSource() throws
    {
        let audible = try settledPeak(volume: 1)
        #expect(audible > 0.1, "the tone has to be there for silence to mean anything")
        #expect(try settledPeak(volume: 0) == 0)
    }

    /// Occlusion is a lowpass plus a little attenuation, and clamps at -100 dB: even at the value
    /// the raycast uses for "blocked" it leaves a source clearly audible. It is not a way to
    /// silence one, whatever its dB units suggest.
    @Test func occlusionIsNotAWayToSilenceASource() throws
    {
        let audible = try settledPeak()
        let blocked = try settledPeak(occlusion: -100)
        #expect(blocked > audible / 100, "-100 dB of occlusion is about -25 dB of signal, not silence")
        #expect(blocked < audible)
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
