//
//  VoiceEngine.swift
//  allonet2
//

import Foundation
import AVFoundation
import os
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
        Self.neutraliseDistanceAttenuation(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
    }

    private func start() throws
    {
        guard !engine.isRunning else { return }
        do { try engine.start() }
        catch { throw Failure.engineFailed(underlying: error) }
        // A mono output channel count means the spatialiser was flattened downstream, which is
        // the one thing about this graph you cannot hear your way to.
        logger.info("Engine running: environment out \(environment.outputFormat(forBus: 0)), device out \(engine.outputNode.outputFormat(forBus: 0))")
    }

    private func stopIfIdle()
    {
        guard sources.isEmpty, !isCapturing, engine.isRunning else { return }
        engine.stop()
    }

    /// What the graph adds after a stream's render block: the rate node, mixing, conversion and
    /// the hardware. Not part of a render-callback-to-capture measurement, so report it
    /// alongside one rather than pretending it is not there - and it is the number that catches
    /// a rate node with a lookahead window in it.
    public var outputLatency: TimeInterval
    {
        max(sources.values.map(\.node.outputPresentationLatency).max() ?? 0,
            engine.outputNode.presentationLatency)
    }

    // MARK: - Capture

    private var accumulator: FrameAccumulator
    private var converter: AVAudioConverter?
    weak var captureStream: DataChannelMediaStream?
    private var acceptedBuffers = 0

    /// Which tap the audio being accepted came from. A removed tap's buffers can still be
    /// queued as hops to this actor, and must not be sent on the stream that replaced theirs.
    var captureGeneration = 0

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
            let muted = isMuted   // the lock's closure is Sendable and cannot reach the main actor
            mutedAtTap.withLock { $0 = muted }
            accumulator.muted = isMuted
            applyMute()
        }
    }

    /// Whether capture was muted at the moment the tap handed a buffer over. The tap runs on the
    /// audio thread and cannot read the main actor's `isMuted`; reading it after the hop instead
    /// is what let an unmute release audio recorded during the mute.
    private let mutedAtTap = OSAllocatedUnfairLock(initialState: false)

    private func applyMute()
    {
        // Only meaningful while the voice processor owns the input; without it the accumulator
        // is what stops frames.
        guard voiceProcessingEnabled else { return }
        engine.inputNode.isVoiceProcessingInputMuted = isMuted
    }

    /// Open the microphone and send every 20 ms frame on `stream`, until `stopCapture()`.
    /// Throws if the input device has no channels or the engine will not start; playout that
    /// was already running keeps running either way.
    public func startCapture(sending stream: DataChannelMediaStream) throws
    {
        guard !isCapturing else { return }
        prepareGraph()

        let input = engine.inputNode   // first touch: this is what prompts for microphone access
        guard input.outputFormat(forBus: 0).channelCount > 0 else { throw Failure.noInputChannels }

        let hadPlayout = engine.isRunning
        do
        {
            try configureCapture(on: input, sending: stream)
            try start()
        }
        catch
        {
            input.removeTap(onBus: 0)
            captureStream = nil
            converter = nil
            // Enabling voice processing stopped the engine everyone else is playing through.
            if hadPlayout, !engine.isRunning
            {
                do { try start() }
                catch let restartError { logger.error("Playout stopped with the failed capture: \(restartError)") }
            }
            throw error
        }
        isCapturing = true
        applyMute()
    }

    private func configureCapture(on input: AVAudioInputNode, sending stream: DataChannelMediaStream) throws
    {
        // Voice processing can only be toggled on a stopped engine, and it re-creates the
        // input format - so a listener who starts speaking restarts the graph once.
        if voiceProcessing, !voiceProcessingEnabled
        {
            engine.stop()
            do
            {
                try input.setVoiceProcessingEnabled(true)
                // Ducking is system-wide, not graph-wide: one engine stopped it ducking our own
                // playout, but every other app's audio still drops the moment capture starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: true, duckingLevel: .min)
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
            // silence. See docs/voice-implementation.md, One engine.
            if inputFormat.channelCount != voiceFormat.channelCount { converter.channelMap = [0] }
            self.converter = converter
        }
        else { converter = nil }
        logger.info("Capturing from \(inputFormat) (\(inputFormat.channelLayout?.layoutTag.description ?? "no layout")), sending as \(voiceFormat), voice processing: \(voiceProcessingEnabled)")

        captureStream = stream
        captureGeneration &+= 1
        let generation = captureGeneration
        // 20 ms at the *input* rate, which is not the 48 kHz the frame duration counts in.
        let tapFrames = AVAudioFrameCount(inputFormat.sampleRate * 0.02)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat)
        { [weak self] buffer, _ in
            guard let self else { return }
            let capturedAt = Date()   // the hop to the main actor below is not part of capture
            let muted = self.mutedAtTap.withLock { $0 }
            Task { @MainActor in
                self.accept(buffer, capturedAt: capturedAt, generation: generation, capturedWhileMuted: muted)
            }
        }
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
    ///
    /// Two things are decided at capture time rather than here, because both can have changed by
    /// the time this runs: audio from a tap older than the current capture belongs to a stream
    /// that is no longer being sent on, and audio recorded while muted stays unsent even if the
    /// user has unmuted since. Without the voice processor the microphone is live while muted, so
    /// that second one is real microphone audio, not the silence the OS would have handed us.
    func accept(_ buffer: AVAudioPCMBuffer, capturedAt: Date, generation: Int, capturedWhileMuted: Bool)
    {
        guard generation == captureGeneration, !capturedWhileMuted, let stream = captureStream else { return }
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
        let rateNode: AVAudioUnitVarispeed
        let stream: DataChannelMediaStream
        let ring: AudioRingBuffer
        var position: SIMD3<Float> = .zero
        var positioned = false   // gates audible: silent until setPosition first runs for this id
        var occlusion: Float = 0
        var audible = false
        var appliedVolume: Float?   // nil until the first apply, which must reach the node
    }
    private var sources: [String: Source] = [:]
    private var rateTicker: Task<Void, Never>?

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
        // Playing a little fast or slow is how buffered depth shrinks; see PlayoutRateController.
        let rateNode = AVAudioUnitVarispeed()
        engine.attach(source)
        engine.attach(rateNode)
        engine.connect(source, to: rateNode, format: voiceFormat)
        // The environment node spatialises one mono source per input bus.
        engine.connect(rateNode, to: environment, fromBus: 0, toBus: environment.nextAvailableInputBus, format: voiceFormat)
        source.renderingAlgorithm = Self.renderingAlgorithm
        sources[stream.mediaId] = Source(node: source, rateNode: rateNode, stream: stream, ring: ring)
        // Starts silent: a position may not land until the next scene update, and rendering
        // before then would play this source at the listener's spot at full volume.
        applyVolume(to: stream.mediaId)

        do { try start() }
        catch
        {
            sources[stream.mediaId] = nil
            engine.detach(source)
            engine.detach(rateNode)
            ring.cancel()
            throw Failure.playoutFailed(mediaId: stream.mediaId, underlying: error)
        }
        startRateTicker()
        logger.info("Playing \(stream.mediaId), \(String(format: "%.1f", outputLatency * 1000)) ms downstream of its render block")
    }

    public func stop(mediaId: String)
    {
        guard let source = sources.removeValue(forKey: mediaId) else { return }
        source.ring.cancel()   // stops the stream's decode pump
        engine.detach(source.node)
        engine.detach(source.rateNode)
        if sources.isEmpty { rateTicker?.cancel(); rateTicker = nil }
        stopIfIdle()
        logger.info("Stopped \(mediaId)")
    }

    /// Each stream decides its own playout rate from how much it has buffered; this hands the
    /// latest one to its rate node. An AU parameter set is safe off the render thread, and the
    /// controller slews far too slowly for 50 ms to be coarse.
    ///
    /// Cancellation returns rather than falling through to one last pass: by then `stop` has
    /// detached the nodes this would write to, and a replacement ticker may already be running.
    private func startRateTicker()
    {
        guard rateTicker == nil else { return }
        rateTicker = Task { [weak self] in
            while true
            {
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch is CancellationError { return }   // the only way out, and not a failure
                catch
                {
                    self?.logger.error("Playout rate steering stopped: \(error)")
                    return
                }
                guard let self else { return }
                for source in sources.values where source.rateNode.rate != source.stream.playoutRate
                {
                    source.rateNode.rate = source.stream.playoutRate
                }
            }
        }
    }

    /// Stop everything: playout, capture, and the engine itself.
    public func stop()
    {
        for mediaId in sources.keys { stop(mediaId: mediaId) }
        stopCapture()
        stopIfIdle()
    }

    // MARK: - Spatialisation

    /// How a source is rendered to the output. HRTF unconditionally: customers listen on
    /// headphones, and `.auto` never picks HRTF on a stereo device, so it left spatial voice as
    /// flat equal-power panning. Choosing by output device is a carded follow-up.
    static let renderingAlgorithm: AVAudio3DMixingRenderingAlgorithm = .HRTFHQ

    /// Turn the environment node's own distance attenuation off, so `gain(atDistance:)` is the
    /// only falloff and the two cannot multiply. A zero rolloff is unity gain at every distance;
    /// the other two parameters stop meaning anything once it is zero.
    nonisolated static func neutraliseDistanceAttenuation(_ environment: AVAudioEnvironmentNode)
    {
        let attenuation = environment.distanceAttenuationParameters
        attenuation.distanceAttenuationModel = .inverse
        attenuation.referenceDistance = 1
        attenuation.maximumDistance = 100_000
        attenuation.rolloffFactor = 0
    }

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
        guard simd_distance_squared(listenerPosition, position) > 1e-6 else { return }
        listenerPosition = position
        for mediaId in sources.keys { applyVolume(to: mediaId) }   // every source's distance changed
    }

    private var listenerPosition: SIMD3<Float> = .zero

    /// Where the entity speaking `mediaId` is, in the same space as the listener. Called once
    /// per rendered frame per source, so unchanged positions are dropped rather than pushed
    /// through an audio-unit parameter set - except the first call, which always applies and
    /// lifts the source out of the silence it started in.
    public func setPosition(_ position: SIMD3<Float>, for mediaId: String)
    {
        guard let source = sources[mediaId] else { return }
        let firstPosition = !source.positioned
        guard firstPosition || simd_distance_squared(source.position, position) > 1e-6 else { return }
        sources[mediaId]!.position = position
        source.node.position = AVAudio3DPoint(position)
        if firstPosition
        {
            sources[mediaId]!.positioned = true
            setAudible(true, for: mediaId)
        }
        applyVolume(to: mediaId)   // the distance changed, and with it the falloff gain
    }

    // MARK: - Distance falloff

    /// Distance (metres) within which a source is heard at full gain.
    public nonisolated(unsafe) static var referenceDistance: Float = 1.5
    /// Distance (metres) at which a source is silent, and stays silent beyond.
    public nonisolated(unsafe) static var maxDistance: Float = 10
    /// How fast the falloff runs: 1 is the realistic inverse-distance law, 0.5 carries a voice
    /// twice as far, 2 half as far.
    public nonisolated(unsafe) static var rolloff: Float = 2

    /// How loud a source `distance` metres from the listener is, as a linear gain.
    ///
    /// The only place the falloff curve exists, so what is rendered and what is drawn - the app's
    /// earshot ring, say - cannot disagree. Full gain within `referenceDistance`, then
    /// `20 * log10(referenceDistance / distance) * rolloff` decibels, which linearly is
    /// `referenceDistance / distance` raised to `rolloff`. Over the last tenth before
    /// `maxDistance` that is faded to exactly zero, so the cutoff has no audible step.
    ///
    /// ```swift
    /// let ringOpacity = VoiceEngine.gain(atDistance: simd_distance(myHead, speaker))
    /// ```
    ///
    /// - Parameter distance: metres between listener and source, in the space both are given in.
    ///   Anything at or below `referenceDistance`, negative included, is full gain.
    /// - Returns: linear amplitude in 0...1 - a multiplier on the source's samples, not decibels.
    ///   Zero at `maxDistance` and beyond.
    public nonisolated static func gain(atDistance distance: Float) -> Float
    {
        guard distance < maxDistance else { return 0 }
        let curve = distance <= referenceDistance ? 1 : pow(referenceDistance / distance, rolloff)
        let fadeStart = maxDistance * 0.9
        guard distance > fadeStart else { return curve }
        return curve * (maxDistance - distance) / (maxDistance - fadeStart)
    }

    /// Whether a source `distance` metres from the listener is heard at all: where
    /// `gain(atDistance:)` reaches zero, with a 2 % dead band from `wasAudible` so a source
    /// hovering at the edge does not chatter between the two answers.
    ///
    /// ```swift
    /// engine.setAudible(VoiceEngine.isAudible(distance: d, wasAudible: engine.isAudible(mediaId)),
    ///                   for: mediaId)
    /// ```
    public nonisolated static func isAudible(distance: Float, wasAudible: Bool) -> Bool
    {
        distance < (wasAudible ? maxDistance : maxDistance * 0.98)
    }

    /// The occlusion at which a source is silenced outright rather than muffled. The raycast
    /// only ever answers "clear" or "blocked", but the parameter is a dB scale, so the threshold
    /// is a value rather than a flag.
    public static let blockedOcclusion: Float = -100

    /// Whether a source at this range and this much occlusion is heard at all, as a node volume.
    ///
    /// Two independent reasons to fall silent, neither able to clobber the other: out of range
    /// (`isAudible`) and blocked by geometry. The environment node's own occlusion is mostly a
    /// lowpass - at -100 dB it still passes about -25 dB of signal - so a wall would otherwise
    /// muffle voices rather than block them.
    public nonisolated static func volume(audible: Bool, occlusion: Float) -> Float
    {
        audible && occlusion > blockedOcclusion ? 1 : 0
    }

    /// Silence `mediaId`, or let it be heard again, without tearing the source down.
    public func setAudible(_ audible: Bool, for mediaId: String)
    {
        guard let source = sources[mediaId], source.audible != audible else { return }
        sources[mediaId]!.audible = audible
        applyVolume(to: mediaId)
    }

    /// The source's whole gain: the two silencing reasons times our own falloff, since the
    /// environment node's distance attenuation is neutralised and contributes none.
    private func applyVolume(to mediaId: String)
    {
        guard let source = sources[mediaId] else { return }
        let volume = Self.volume(audible: source.audible, occlusion: source.occlusion)
            * Self.gain(atDistance: simd_distance(listenerPosition, source.position))
        guard volume != source.appliedVolume else { return }
        sources[mediaId]!.appliedVolume = volume
        source.node.volume = volume
    }

    /// Whether `mediaId` is currently heard. Unknown streams are not.
    public func isAudible(_ mediaId: String) -> Bool { sources[mediaId]?.audible ?? false }

    /// Attenuation from something between the source and the listener, in dB (0 clear,
    /// `blockedOcclusion` fully blocked). The raycast that decides this belongs to the caller.
    ///
    /// Anything between the two muffles through the environment node's occlusion filter;
    /// `blockedOcclusion` itself also silences, because that filter alone does not.
    public func setOcclusion(_ dB: Float, for mediaId: String)
    {
        guard let source = sources[mediaId], source.occlusion != dB else { return }
        sources[mediaId]!.occlusion = dB
        source.node.occlusion = dB
        applyVolume(to: mediaId)
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

