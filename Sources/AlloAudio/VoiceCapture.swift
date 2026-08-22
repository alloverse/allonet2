//
//  VoiceCapture.swift
//  allonet2
//

import Foundation
import AVFoundation
import allonet2
import Logging

/// Microphone capture for one outgoing voice stream, with the OS voice processor's echo
/// cancellation, noise suppression and automatic gain.
///
/// AEC only cancels what this unit renders; see docs/voice.md, Known limitations.
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
            // Voice processing ducks audio it didn't render - i.e. the voices we're playing back.
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
            // Discrete channel layout has no downmix rule; without a map the converter emits
            // silence. See docs/voice-implementation.md, Capture.
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

    private var acceptedBuffers = 0
    /// Accumulate captured audio into whole frames; the tap's buffer size is a hint, not a promise.
    private func accept(_ buffer: AVAudioPCMBuffer, capturedAt: Date)
    {
        guard let stream else { return }
        acceptedBuffers += 1
        if acceptedBuffers % 250 == 1, let channels = buffer.floatChannelData
        {
            // Raw tap peaks: separates a silent mic from a conversion that drops the signal.
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
