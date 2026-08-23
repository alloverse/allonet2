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

    /// The falloff reaches zero at maxDistance, but a source is also stopped outright there, so
    /// nothing past it can be dragged back by a rounding error or a changed curve.
    @Test func silencesSourcesPastMaxDistance()
    {
        #expect(VoiceEngine.isAudible(distance: 0, wasAudible: false))
        #expect(VoiceEngine.isAudible(distance: 9, wasAudible: false))
        #expect(!VoiceEngine.isAudible(distance: 10, wasAudible: true))
        #expect(!VoiceEngine.isAudible(distance: 1000, wasAudible: true))

        // Dead band: a source hovering at the edge keeps whichever answer it had.
        #expect(VoiceEngine.isAudible(distance: 9.9, wasAudible: true))
        #expect(!VoiceEngine.isAudible(distance: 9.9, wasAudible: false))
        #expect(VoiceEngine.isAudible(distance: 9.7, wasAudible: false))
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

    /// A source with no position yet starts `audible == false`, so it takes this same silent
    /// path - otherwise it would render at the listener's spot at full volume for a frame or two.
    @Test func aSourceWithNoPositionYetIsSilent()
    {
        #expect(VoiceEngine.volume(audible: false, occlusion: 0) == 0)
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

        engine.accept(buffer, capturedAt: Date(), generation: generation, capturedWhileMuted: false)
        #expect(stream.counters.snapshot.captured == 1)

        // What startCapture(sending:) does while a tap callback is still in flight.
        engine.captureGeneration &+= 1
        engine.accept(buffer, capturedAt: Date(), generation: generation, capturedWhileMuted: false)
        #expect(stream.counters.snapshot.captured == 1, "stale audio reached the stream that replaced it")
    }

    /// Without the voice processor nothing mutes the microphone itself, so a tap buffer recorded
    /// during a mute is real speech. Muting drops what the accumulator holds, but a buffer still
    /// in flight is decided by the mute state *now* - and a quick unmute would let it through.
    @Test func neverSendsAudioRecordedWhileMuted() throws
    {
        let engine = VoiceEngine(voiceProcessing: false)
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

        // Recorded while muted, delivered after the user unmuted again.
        engine.isMuted = true
        engine.isMuted = false
        engine.accept(buffer, capturedAt: Date(), generation: generation, capturedWhileMuted: true)
        #expect(stream.counters.snapshot.captured == 0, "audio recorded while muted was transmitted")

        // The next buffer, recorded after the unmute, goes as normal.
        engine.accept(buffer, capturedAt: Date(), generation: generation, capturedWhileMuted: false)
        #expect(stream.counters.snapshot.captured == 1)
    }
}

/// The falloff every voice is heard through. Its shape is a tuning decision that took ears to
/// settle - the environment node's own inverse model attenuated hard early, plateaued mid-room and
/// then cut off - so it is pinned here rather than left to whatever the audio unit does.
@Suite struct FalloffCurveTests
{
    private let reference = VoiceEngine.referenceDistance
    private let maxDistance = VoiceEngine.maxDistance

    /// The curve as the ruling states it, in dB, computed the long way round: what
    /// `gain(atDistance:)` claims in its documentation has to be what it returns.
    private func decibelCurve(at distance: Float) -> Float
    {
        pow(10, 20 * log10(reference / distance) * VoiceEngine.rolloff / 20)
    }

    /// The two paths through dB and through the exponent are not bit-identical in Float, so
    /// agreement is a fraction, not equality.
    private func expectGain(_ gain: Float, isWithin fraction: Float, of expected: Float, _ what: String)
    {
        #expect(abs(gain - expected) <= abs(expected) * fraction, "\(what): \(gain) is not \(expected)")
    }

    @Test func isFullGainWithinTheReferenceDistance()
    {
        #expect(VoiceEngine.gain(atDistance: 0) == 1)
        #expect(VoiceEngine.gain(atDistance: -1) == 1, "a negative distance is not a boost")
        #expect(VoiceEngine.gain(atDistance: reference / 2) == 1)
        #expect(VoiceEngine.gain(atDistance: reference) == 1)
    }

    @Test func followsTheDecibelFormulaBeyondIt()
    {
        for distance: Float in [2, 3, 4.5, 6, 8, 8.9]
        {
            expectGain(VoiceEngine.gain(atDistance: distance), isWithin: 1e-5, of: decibelCurve(at: distance),
                   "gain at \(distance) m is off the 20*log10(reference/distance)*rolloff curve")
        }
        // The shipping tuning, spelled out: rolloff 2 from 1.5 m is a quarter of the amplitude at
        // twice the reference distance, a sixteenth at four times.
        expectGain(VoiceEngine.gain(atDistance: 3), isWithin: 1e-5, of: 0.25, "gain at 3 m")
        expectGain(VoiceEngine.gain(atDistance: 6), isWithin: 1e-5, of: 0.0625, "gain at 6 m")
    }

    @Test func neverGetsLouderWithDistance()
    {
        var previous = VoiceEngine.gain(atDistance: 0)
        for step in 1...2000
        {
            let distance = Float(step) * maxDistance / 1000   // out to twice maxDistance
            let gain = VoiceEngine.gain(atDistance: distance)
            #expect(gain <= previous, "gain rose at \(distance) m")
            previous = gain
        }
    }

    @Test func isSilentAtMaxDistanceAndBeyond()
    {
        #expect(VoiceEngine.gain(atDistance: maxDistance) == 0)
        #expect(VoiceEngine.gain(atDistance: maxDistance + 0.001) == 0)
        #expect(VoiceEngine.gain(atDistance: 1000) == 0)
        #expect(VoiceEngine.gain(atDistance: .infinity) == 0)
    }

    /// The fade to silence is what the old cutoff lacked: a source walking out of earshot has to
    /// thin out, not stop. It starts a tenth before maxDistance, and up to there the raw curve is
    /// untouched - so there is no step where the fade begins either.
    @Test func fadesToZeroWithNoStepAtTheCutoff()
    {
        let fadeStart = maxDistance * 0.9
        expectGain(VoiceEngine.gain(atDistance: fadeStart), isWithin: 1e-5, of: decibelCurve(at: fadeStart),
               "the fade start is a step off the raw curve")
        expectGain(VoiceEngine.gain(atDistance: fadeStart.nextDown), isWithin: 1e-5, of: decibelCurve(at: fadeStart.nextDown),
               "the sample just before the fade is a step off the raw curve")

        // Halfway through the fade, half the curve is left; at the very end, essentially nothing.
        let middle = (fadeStart + maxDistance) / 2
        expectGain(VoiceEngine.gain(atDistance: middle), isWithin: 1e-4, of: decibelCurve(at: middle) / 2,
               "gain halfway through the fade")
        #expect(VoiceEngine.gain(atDistance: maxDistance.nextDown) < decibelCurve(at: maxDistance) / 1000)
    }

    /// The cutoff and the curve are two answers to the same question, and a source that
    /// `isAudible` says is heard must not be rendered at zero, nor the other way round.
    @Test func audibilityAgreesWithTheCurve()
    {
        for step in 0...200
        {
            let distance = Float(step) * maxDistance / 100
            #expect(VoiceEngine.isAudible(distance: distance, wasAudible: true) == (VoiceEngine.gain(atDistance: distance) > 0),
                    "audibility and gain disagree at \(distance) m")
        }
    }
}

/// What silencing and the falloff actually do to the signal, rendered offline so it needs no
/// audio device. None of it is in the documentation and all of it cost a measurement to learn: a
/// source silenced the wrong way is still quietly audible across the place, a peak taken too
/// early says the opposite of the truth, and an environment node left to attenuate distance
/// itself multiplies its own curve onto ours.
@Suite struct EnvironmentNodeRenderingTests
{
    /// What "silent" can mean here: the HRTF path has a gain floor, so a source at volume 0 comes
    /// out at exactly -120 dB of full scale on every block rather than at true digital zero.
    /// Inaudible under anything, but not something an equality can be written against.
    private let silenceFloor: Float = 2e-6

    /// Loudest sample of a 1 kHz tone through one spatialised source, configured the way playout
    /// configures its own, and ignoring the blocks where a changed gain is still ramping.
    private func settledPeak(distance: Float = 1.5, volume: Float = 1, occlusion: Float = 0,
                             throughRateNode: Bool = false) throws -> Float
    {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let engine = AVAudioEngine()
        let environment = AVAudioEnvironmentNode()
        engine.attach(environment)
        VoiceEngine.neutraliseDistanceAttenuation(environment)
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
        if throughRateNode
        {
            let rateNode = AVAudioUnitVarispeed()
            engine.attach(rateNode)
            engine.connect(source, to: rateNode, format: mono)
            engine.connect(rateNode, to: environment, fromBus: 0, toBus: environment.nextAvailableInputBus, format: mono)
        }
        else
        {
            engine.connect(source, to: environment, fromBus: 0, toBus: environment.nextAvailableInputBus, format: mono)
        }
        source.renderingAlgorithm = VoiceEngine.renderingAlgorithm
        source.position = AVAudio3DPoint(x: 0, y: 0, z: -distance)
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

    /// `AVAudioMixing.volume` does reach an environment node's input, and zero is silence in every
    /// sense that matters - but the gain ramps, so the first block still carries the old level.
    /// Measuring there once produced a confident, wrong report that this whole mechanism was a
    /// no-op.
    @Test func volumeZeroSilencesASpatialisedSource() throws
    {
        let audible = try settledPeak(volume: 1)
        #expect(audible > 0.1, "the tone has to be there for silence to mean anything")
        let silenced = try settledPeak(volume: 0)
        #expect(silenced <= audible * silenceFloor, "a silenced source rendered at \(silenced), against \(audible)")
    }

    /// Playout puts a rate node between the source and the environment node, and the mixing
    /// properties are set on the source - the head of the chain, not the node the mixer sees.
    /// If that stopped carrying them, distant voices would come back without a sound to say so.
    @Test func volumeStillSilencesThroughTheRateNode() throws
    {
        let audible = try settledPeak(volume: 1, throughRateNode: true)
        #expect(audible > 0.1)
        let silenced = try settledPeak(volume: 0, throughRateNode: true)
        #expect(silenced <= audible * silenceFloor, "a silenced source rendered at \(silenced), against \(audible)")
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

    /// Distance is ours to attenuate, and the environment node must contribute none of it - two
    /// falloffs multiplied is what made the old curve dive early and then plateau.
    @Test func aNeutralisedEnvironmentNodeAttenuatesNothing() throws
    {
        let near = try settledPeak(distance: VoiceEngine.referenceDistance)
        #expect(near > 0.1, "the tone has to be there for the comparison to mean anything")
        for distance: Float in [3, 6, 9, 12, 40]
        {
            let far = try settledPeak(distance: distance)
            #expect(abs(far - near) <= near * 0.01, "the environment node still attenuates at \(distance) m: \(far) vs \(near)")
        }
    }

    /// The curve as heard rather than as computed: `gain(atDistance:)` applied as the source's
    /// volume comes out of the render at exactly that fraction of full gain.
    @Test(arguments: [Float(3), 4.5, 6, 9, 9.5]) func aSourceRendersAtTheCurvesGain(distance: Float) throws
    {
        let full = try settledPeak(distance: VoiceEngine.referenceDistance)
        let expected = full * VoiceEngine.gain(atDistance: distance)
        let measured = try settledPeak(distance: distance, volume: VoiceEngine.gain(atDistance: distance))
        #expect(abs(measured - expected) <= expected * 0.02,
                "a source at \(distance) m rendered at \(measured), not the curve's \(expected)")
    }

    @Test func aSourcePastMaxDistanceRendersSilence() throws
    {
        let distance = VoiceEngine.maxDistance + 1
        let full = try settledPeak(distance: VoiceEngine.referenceDistance)
        let measured = try settledPeak(distance: distance, volume: VoiceEngine.gain(atDistance: distance))
        #expect(measured <= full * silenceFloor, "a source \(distance) m away rendered at \(measured), against \(full)")
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
