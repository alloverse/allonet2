//
//  VoiceCapture.swift
//  allonet2
//

import Foundation
import AVFoundation
import allonet2
import Logging

/// Microphone capture for one outgoing voice stream.
///
/// Apple's voice-processing I/O unit replaces what libwebrtc's audio device module used to
/// provide: echo cancellation, noise suppression and automatic gain, done by the OS.
///
/// Caveat worth knowing before trusting the echo canceller: it can only cancel audio it
/// renders itself. Voice played back through some other graph - RealityKit's spatial audio,
/// say - is not part of its reference signal, so speaker-to-mic echo will survive. Verify
/// with speakers before assuming otherwise.
@MainActor
public final class VoiceCapture
{
    public enum Failure: Error, CustomStringConvertible
    {
        case noInputChannels
        case cannotConvert(from: AVAudioFormat, to: AVAudioFormat)
        case engineFailed(underlying: Error)

        public var description: String
        {
            switch self
            {
            case .noInputChannels: "the input device reports no channels"
            case .cannotConvert(let from, let to): "cannot convert microphone audio from \(from) to \(to)"
            case .engineFailed(let underlying): "audio engine failed to start: \(underlying)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var logger = Logger(labelSuffix: "audio.capture")
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private weak var stream: DataChannelMediaStream?
    private(set) public var isRunning = false

    /// Sequence and capture time of every frame sent, for latency correlation.
    public var onFrameSent: ((UInt32, Date) -> Void)?

    /// Whether the OS voice-processing unit was actually enabled. False means capture still
    /// works, but with no echo cancellation.
    public private(set) var voiceProcessingEnabled = false

    public init()
    {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: DataChannelMediaStream.sampleRate,
                                     channels: 1,
                                     interleaved: false)!
    }

    /// Start capturing and send every 20 ms frame on `stream`. `voiceProcessing: false` skips
    /// the OS echo canceller and captures the device's native format - for telling a silent
    /// microphone apart from a voice-processing format the conversion can't read.
    public func start(sending stream: DataChannelMediaStream, voiceProcessing: Bool = true) throws
    {
        guard !isRunning else { return }
        self.stream = stream

        let input = engine.inputNode
        // Must be set before the engine starts, and it re-creates the input format.
        do
        {
            try input.setVoiceProcessingEnabled(voiceProcessing)
            voiceProcessingEnabled = voiceProcessing
            // Voice processing ducks every sound it did not render itself, and playout runs
            // on a separate engine, so by default it ducks the very voices we're listening to.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        catch
        {
            logger.warning("Voice processing unavailable, continuing without echo cancellation: \(error)")
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else { throw Failure.noInputChannels }
        if inputFormat != outputFormat
        {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else
            {
                throw Failure.cannotConvert(from: inputFormat, to: outputFormat)
            }
            // The voice processor hands out a DiscreteInOrder layout (four identical copies on
            // this machine), and the converter has no downmix rule for discrete channels: left
            // to itself it maps none of them and emits silence. Take the first.
            if inputFormat.channelCount != outputFormat.channelCount { converter.channelMap = [0] }
            self.converter = converter
        }
        logger.info("Capturing from \(inputFormat) (\(inputFormat.channelLayout?.layoutTag.description ?? "no layout")), sending as \(outputFormat), voice processing: \(voiceProcessingEnabled)")

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(DataChannelMediaStream.frameDuration), format: inputFormat)
        { [weak self] buffer, _ in
            guard let self else { return }
            let capturedAt = Date()   // the hop to the main actor below is not part of capture
            Task { @MainActor in self.accept(buffer, capturedAt: capturedAt) }
        }

        do { try engine.start() }
        catch
        {
            input.removeTap(onBus: 0)
            throw Failure.engineFailed(underlying: error)
        }
        isRunning = true
    }

    public func stop()
    {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pending.removeAll()
        isRunning = false
    }

    /// Accumulate captured audio and emit whole frames. The tap's buffer size is a hint, not
    /// a promise, so frames are cut here rather than assumed.
    private var acceptedBuffers = 0
    private func accept(_ buffer: AVAudioPCMBuffer, capturedAt: Date)
    {
        guard let stream else { return }
        acceptedBuffers += 1
        if acceptedBuffers % 250 == 1, let channels = buffer.floatChannelData
        {
            // Per-channel peak of the raw tap, before any conversion: a silent microphone
            // reads zero on every channel; a conversion dropping the signal does not.
            let peaks = (0..<Int(buffer.format.channelCount)).map { c -> String in
                var peak: Float = 0
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[c][i])) }
                return String(format: "%.3f", peak)
            }
            logger.info("raw input peaks per channel: \(peaks.joined(separator: " "))")
        }
        guard let mono = convert(buffer), let samples = mono.floatChannelData?[0] else { return }

        // Whatever was already queued was captured before this buffer arrived, so a frame's
        // audio starts that far back from `capturedAt`.
        let backlog = pending.count
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(mono.frameLength)))

        let frameSize = DataChannelMediaStream.frameDuration
        var frameIndex = 0
        while pending.count >= frameSize
        {
            let sequence = pending.withUnsafeBufferPointer { buffer in
                stream.send(samples: buffer.baseAddress!, frameCount: frameSize)
            }
            if let sequence, let onFrameSent
            {
                let offset = Double(frameIndex * frameSize - backlog) / DataChannelMediaStream.sampleRate
                onFrameSent(sequence, capturedAt.addingTimeInterval(offset))
            }
            pending.removeFirst(frameSize)
            frameIndex += 1
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer?
    {
        guard let converter else { return buffer }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

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
}
