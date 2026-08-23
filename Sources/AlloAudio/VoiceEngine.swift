//
//  VoiceEngine.swift
//  allonet2
//

import Foundation
import AVFoundation
import simd
import allonet2
import AlloOpus
import Logging

/// The one `AVAudioEngine` voice runs through: microphone capture through the OS voice
/// processor, and spatialised playout of every incoming stream.
///
/// Apple's voice processor only cancels audio that its *own* engine rendered, so playout has to
/// share the engine with capture; that is why spatialisation is an `AVAudioEnvironmentNode`
/// here rather than RealityKit's spatial audio. See docs/voice-implementation.md.
///
/// ```swift
/// let engine = VoiceEngine()
/// try engine.startCapture(sending: outgoingStream)   // opens the microphone
/// engine.isMuted = true                              // keeps it open, sends nothing
/// try engine.play(incomingStream)
/// engine.setListener(position: .zero, forward: [0, 0, -1], up: [0, 1, 0])
/// engine.setPosition([1, 0, -2], for: incomingStream.mediaId)
/// ```
///
/// Positions are metres in whatever single space the caller uses for both listener and sources
/// (in KojaApp, the spatial audio field entity's), right-handed with -Z forward.
///
/// The class is `@MainActor`; the render block it installs per stream is not, and stays
/// allocation-, lock- and log-free.
@MainActor
public final class VoiceEngine
{
    public enum Failure: Error, CustomStringConvertible
    {
        case noInputChannels
        case cannotConvert(from: AVAudioFormat, to: AVAudioFormat)
        case engineFailed(underlying: Error)
        case playoutFailed(mediaId: String, underlying: Error)

        public var description: String
        {
            switch self
            {
            case .noInputChannels: "the input device reports no channels"
            case .cannotConvert(let from, let to): "cannot convert microphone audio from \(from) to \(to)"
            case .engineFailed(let underlying): "audio engine failed to start: \(underlying)"
            case .playoutFailed(let mediaId, let underlying): "cannot play \(mediaId): \(underlying)"
            }
        }
    }

    /// Handed the samples a stream just rendered, on the audio thread. Anything it does is
    /// subject to the same real-time rules as the render block itself.
    public typealias PCMCallback = (UnsafeMutableAudioBufferListPointer, Int) -> Void

    /// Voice frames are Opus; installing the codec here means no caller has to remember to.
    private static let codecInstalled: Void = Opus.install()

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let voiceFormat: AVAudioFormat
    private let voiceProcessing: Bool
    private var logger = Logger(labelSuffix: "audio.engine")

    /// `voiceProcessing: false` captures in the device's native format with no echo canceller -
    /// for telling a silent microphone apart from a conversion that drops the signal.
    /// Fixed for the engine's lifetime: it changes the I/O unit, which cannot be swapped under
    /// a running graph.
    public init(voiceProcessing: Bool = true)
    {
        _ = Self.codecInstalled
        self.voiceProcessing = voiceProcessing
        voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: DataChannelMediaStream.sampleRate,
                                    channels: 1,
                                    interleaved: false)!
        accumulator = FrameAccumulator(frameSize: DataChannelMediaStream.frameDuration,
                                       sampleRate: DataChannelMediaStream.sampleRate)
    }

    // MARK: - Graph

    private var graphReady = false

    /// Playout half of the graph. Deliberately does not touch `inputNode`: that is what prompts
    /// for microphone access, and a listener who never speaks should not be asked.
    private func prepareGraph()
    {
        guard !graphReady else { return }
        graphReady = true
        engine.attach(environment)
        let attenuation = environment.distanceAttenuationParameters
        attenuation.distanceAttenuationModel = .inverse
        attenuation.referenceDistance = 1.5
        attenuation.maximumDistance = 10
        attenuation.rolloffFactor = 2
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
    }

    private func start() throws
    {
        guard !engine.isRunning else { return }
        do { try engine.start() }
        catch { throw Failure.engineFailed(underlying: error) }
    }

    private func stopIfIdle()
    {
        guard sources.isEmpty, !isCapturing, engine.isRunning else { return }
        engine.stop()
    }

    /// What the output device adds after the render block: buffering, conversion and the
    /// hardware. Not part of a render-callback-to-capture measurement, so report it alongside
    /// one rather than pretending it is not there.
    public var outputLatency: TimeInterval { engine.outputNode.presentationLatency }

    // MARK: - Capture

    private var accumulator: FrameAccumulator
    private var converter: AVAudioConverter?
    private weak var captureStream: DataChannelMediaStream?
    private var acceptedBuffers = 0

    /// Whether the microphone is open. Muting does not change it; see `isMuted`.
    public private(set) var isCapturing = false

    /// Whether the OS voice-processing unit was actually enabled. False means capture still
    /// works, but with no echo cancellation.
    public private(set) var voiceProcessingEnabled = false

    /// Sequence and capture time of every frame sent, for latency correlation.
    public var onFrameSent: ((UInt32, Date) -> Void)?

    /// Muting keeps the engine, the microphone and the voice processor running - stopping them
    /// would take the echo canceller's reference away from playout - and drops what is captured
    /// instead. The OS microphone indicator therefore stays lit while connected and muted, as
    /// it does in FaceTime.
    public var isMuted = false
    {
        didSet
        {
            accumulator.muted = isMuted
            applyMute()
        }
    }

    private func applyMute()
    {
        // Only meaningful while the voice processor owns the input; without it the accumulator
        // is what stops frames.
        guard voiceProcessingEnabled else { return }
        engine.inputNode.isVoiceProcessingInputMuted = isMuted
    }

    /// Open the microphone and send every 20 ms frame on `stream`, until `stopCapture()`.
    /// Throws if the input device has no channels or the engine will not start.
    public func startCapture(sending stream: DataChannelMediaStream) throws
    {
        guard !isCapturing else { return }
        prepareGraph()

        let input = engine.inputNode   // first touch: this is what prompts for microphone access
        guard input.outputFormat(forBus: 0).channelCount > 0 else { throw Failure.noInputChannels }

        // Voice processing can only be toggled on a stopped engine, and it re-creates the
        // input format - so a listener who starts speaking restarts the graph once.
        if voiceProcessing, !voiceProcessingEnabled
        {
            engine.stop()
            do
            {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
            }
            catch { logger.warning("Voice processing unavailable, continuing without echo cancellation: \(error)") }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else { throw Failure.noInputChannels }
        if inputFormat != voiceFormat
        {
            guard let converter = AVAudioConverter(from: inputFormat, to: voiceFormat) else
            {
                throw Failure.cannotConvert(from: inputFormat, to: voiceFormat)
            }
            // Discrete channel layout has no downmix rule; without a map the converter emits
            // silence. See docs/voice-implementation.md, Capture.
            if inputFormat.channelCount != voiceFormat.channelCount { converter.channelMap = [0] }
            self.converter = converter
        }
        else { converter = nil }
        logger.info("Capturing from \(inputFormat) (\(inputFormat.channelLayout?.layoutTag.description ?? "no layout")), sending as \(voiceFormat), voice processing: \(voiceProcessingEnabled)")

        captureStream = stream
        // 20 ms at the *input* rate, which is not the 48 kHz the frame duration counts in.
        let tapFrames = AVAudioFrameCount(inputFormat.sampleRate * 0.02)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat)
        { [weak self] buffer, _ in
            guard let self else { return }
            let capturedAt = Date()   // the hop to the main actor below is not part of capture
            Task { @MainActor in self.accept(buffer, capturedAt: capturedAt) }
        }

        do { try start() }
        catch
        {
            input.removeTap(onBus: 0)
            captureStream = nil
            throw error
        }
        isCapturing = true
        applyMute()
    }

    public func stopCapture()
    {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        accumulator.reset()
        captureStream = nil
        isCapturing = false
        stopIfIdle()
    }

    /// Accumulate captured audio into whole frames; the tap's buffer size is a hint, not a promise.
    private func accept(_ buffer: AVAudioPCMBuffer, capturedAt: Date)
    {
        guard let stream = captureStream else { return }
        acceptedBuffers += 1
        if acceptedBuffers % 250 == 1, let channels = buffer.floatChannelData
        {
            // Raw tap peaks: separates a silent mic from a conversion that drops the signal.
            let peaks = (0..<Int(buffer.format.channelCount)).map { c -> String in
                var peak: Float = 0
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[c][i])) }
                return String(format: "%.3f", peak)
            }
            logger.trace("raw input peaks per channel: \(peaks.joined(separator: " "))")
        }
        guard let mono = convert(buffer), let samples = mono.floatChannelData?[0] else { return }

        accumulator.accept(UnsafeBufferPointer(start: samples, count: Int(mono.frameLength)))
        { frame, offset in
            guard let sequence = stream.send(samples: frame.baseAddress!, frameCount: frame.count),
                  let onFrameSent
            else { return }
            onFrameSent(sequence, capturedAt.addingTimeInterval(offset))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer?
    {
        guard let converter else { return buffer }

        let ratio = voiceFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error
        {
            logger.error("Failed to convert captured audio: \(error)")
            return nil
        }
        return output
    }

    // MARK: - Playout

    private struct Source
    {
        let node: AVAudioSourceNode
        let ring: AudioRingBuffer
        var position: SIMD3<Float> = .zero
        var occlusion: Float = 0
    }
    private var sources: [String: Source] = [:]

    /// Play `stream` as one spatialised source. `pcm` is handed the rendered samples on the
    /// audio thread, for a level meter or a speaking indicator.
    public func play(_ stream: DataChannelMediaStream, pcm: PCMCallback? = nil) throws
    {
        guard sources[stream.mediaId] == nil else { return }
        prepareGraph()

        // render() starts the decode pump; the ring buffer is the handoff to the audio thread.
        let ring = stream.render()
        let source = AVAudioSourceNode(format: voiceFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            stream.notePlayout(of: ring)   // which frame this is, before the read moves the head
            ring.readOrSilence(into: buffers, frames: Int(frameCount))
            pcm?(buffers, Int(frameCount))
            return noErr
        }
        engine.attach(source)
        // The environment node spatialises one mono source per input bus.
        engine.connect(source, to: environment, fromBus: 0, toBus: environment.nextAvailableInputBus, format: voiceFormat)
        source.renderingAlgorithm = .auto   // HRTF is only right on headphones, which we can't detect
        sources[stream.mediaId] = Source(node: source, ring: ring)

        do { try start() }
        catch
        {
            sources[stream.mediaId] = nil
            engine.detach(source)
            ring.cancel()
            throw Failure.playoutFailed(mediaId: stream.mediaId, underlying: error)
        }
        logger.info("Playing \(stream.mediaId)")
    }

    public func stop(mediaId: String)
    {
        guard let source = sources.removeValue(forKey: mediaId) else { return }
        source.ring.cancel()   // stops the stream's decode pump
        engine.detach(source.node)
        stopIfIdle()
        logger.info("Stopped \(mediaId)")
    }

    /// Stop everything: playout, capture, and the engine itself.
    public func stop()
    {
        for mediaId in sources.keys { stop(mediaId: mediaId) }
        stopCapture()
        stopIfIdle()
    }

    // MARK: - Spatialisation

    /// The head axes a right-handed, -Z-forward transform describes - RealityKit's convention
    /// and the environment node's - ready for `setListener`.
    public nonisolated static func listenerAxes(of transform: simd_float4x4) -> (forward: SIMD3<Float>, up: SIMD3<Float>)
    {
        (forward: simd_normalize(-simd_make_float3(transform.columns.2)),
         up: simd_normalize(simd_make_float3(transform.columns.1)))
    }

    /// Where the listener's head is, in the shared coordinate space. `forward` and `up` are the
    /// head's axes; both are normalised here.
    public func setListener(position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>)
    {
        environment.listenerPosition = AVAudio3DPoint(position)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(forward: AVAudio3DVector(simd_normalize(forward)),
                                                                           up: AVAudio3DVector(simd_normalize(up)))
    }

    /// Where the entity speaking `mediaId` is, in the same space as the listener. Called once
    /// per rendered frame per source, so unchanged positions are dropped rather than pushed
    /// through an audio-unit parameter set.
    public func setPosition(_ position: SIMD3<Float>, for mediaId: String)
    {
        guard let source = sources[mediaId], simd_distance_squared(source.position, position) > 1e-6 else { return }
        sources[mediaId]!.position = position
        source.node.position = AVAudio3DPoint(position)
    }

    /// Attenuation from something between the source and the listener, in dB (0 clear,
    /// -100 fully blocked). The raycast that decides this belongs to the caller.
    public func setOcclusion(_ dB: Float, for mediaId: String)
    {
        guard let source = sources[mediaId], source.occlusion != dB else { return }
        sources[mediaId]!.occlusion = dB
        source.node.occlusion = dB
    }

    /// Distance attenuation, shared by every source. Defaults to referenceDistance 1.5 m,
    /// maximumDistance 10 m, rolloff 2.0, inverse-square.
    public func setAttenuation(referenceDistance: Float, maximumDistance: Float, rolloffFactor: Float)
    {
        prepareGraph()
        let attenuation = environment.distanceAttenuationParameters
        attenuation.referenceDistance = referenceDistance
        attenuation.maximumDistance = maximumDistance
        attenuation.rolloffFactor = rolloffFactor
    }
}

/// Cuts fixed-size frames out of tap buffers of any size, and drops what arrives while muted so
/// unmuting never flushes audio captured behind the user's back.
struct FrameAccumulator
{
    let frameSize: Int
    let sampleRate: Double
    private var pending: [Float] = []

    init(frameSize: Int, sampleRate: Double)
    {
        self.frameSize = frameSize
        self.sampleRate = sampleRate
        pending.reserveCapacity(frameSize * 2)
    }

    var muted = false
    {
        didSet { if muted { pending.removeAll(keepingCapacity: true) } }
    }

    /// Samples held back because they don't fill a frame yet.
    var pendingCount: Int { pending.count }

    /// Append `samples`, then hand `emit` every whole frame that completes, with the offset in
    /// seconds from the capture time of `samples` to the start of that frame - negative for a
    /// frame that begins in audio already queued.
    mutating func accept(_ samples: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>, TimeInterval) -> Void)
    {
        guard !muted else { return }
        let backlog = pending.count
        pending.append(contentsOf: samples)

        var frameIndex = 0
        while pending.count >= frameSize
        {
            let offset = Double(frameIndex * frameSize - backlog) / sampleRate
            pending.withUnsafeBufferPointer { emit(UnsafeBufferPointer(rebasing: $0[0..<frameSize]), offset) }
            pending.removeFirst(frameSize)
            frameIndex += 1
        }
    }

    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

public extension AVAudio3DPoint
{
    /// Metres in the environment node's right-handed, -Z-forward space - the same convention
    /// RealityKit uses, so a place-relative position maps across unchanged.
    init(_ v: SIMD3<Float>) { self.init(x: v.x, y: v.y, z: v.z) }
}

