//
//  VoiceRecording.swift
//  AlloAudio
//

import AVFoundation
import Foundation
import allonet2

/// A sound file decoded on demand into voice frames: 20 ms of 48 kHz mono Float32, the shape
/// `DataChannelMediaStream.send(samples:frameCount:)` takes. The end of the file wraps to its
/// start inside the same conversion pass, so the loop is sample-continuous at the seam and no
/// frame is ever short.
///
/// Use it to speak a file into a place - a test that needs speech to localise, or a demo avatar
/// with something to say. `VoiceRecordingPlayer` drives one or more of them on a shared clock.
///
/// Not thread-safe: hand it to one queue and pull frames only from there.
public final class VoiceRecording
{
    /// Samples in one frame, the same 20 ms the wire carries.
    public static let frameCount = DataChannelMediaStream.frameDuration

    /// Why a recording could not be opened, or could not go on being decoded. Every case names
    /// the file, because CoreAudio's own errors say only what went wrong.
    public enum Failure: Error, CustomStringConvertible
    {
        /// `AVAudioFile` refused the URL: missing, unreadable, or not audio it decodes.
        case cannotOpen(URL, Error)
        /// The file opened but holds no audio, or ran dry mid-loop.
        case empty(URL)
        /// No conversion exists from the file's format to 48 kHz mono Float32.
        case cannotConvert(URL, AVAudioFormat)
        /// Decoding failed after the file had already opened; nothing recovers it.
        case decodeFailed(URL, Error?)

        public var description: String
        {
            switch self
            {
            case .cannotOpen(let url, let underlying):
                return "Cannot read \(url.path) as audio: \(underlying)"
            case .empty(let url):
                return "\(url.path) decodes to no audio"
            case .cannotConvert(let url, let format):
                return "Cannot convert \(url.path) (\(format)) to 48 kHz mono"
            case .decodeFailed(let url, let underlying):
                return "Decoding \(url.path) failed: \(underlying.map { "\($0)" } ?? "converter gave no reason")"
            }
        }
    }

    /// The file's own length in seconds, before looping.
    public let duration: TimeInterval

    /// The file this reads, as given.
    public let url: URL

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    /// Open a file and prepare it for conversion; nothing is decoded until `nextFrame()`.
    /// - Parameter url: a file URL to anything `AVAudioFile` reads - wav, m4a, aiff, caf - at any
    ///   sample rate. A multi-channel file is not downmixed; its first channel is what plays.
    /// - Throws: `Failure` naming `url`.
    public init(url: URL) throws
    {
        self.url = url
        do { file = try AVAudioFile(forReading: url) }
        catch { throw Failure.cannotOpen(url, error) }
        let source = file.processingFormat
        guard file.length > 0 else { throw Failure.empty(url) }
        duration = Double(file.length) / source.sampleRate

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: DataChannelMediaStream.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(Self.frameCount))
        else { throw Failure.cannotConvert(url, source) }
        // Discrete channel layout has no downmix rule; without a map the converter emits
        // silence. See docs/voice-implementation.md, One engine.
        if source.channelCount != target.channelCount { converter.channelMap = [0] }
        self.converter = converter
        self.input = input
        self.output = output
    }

    /// Decode the next 20 ms, wrapping to the start of the file when it runs out.
    /// - Returns: exactly `frameCount` mono samples in the recording's own buffer, valid until
    ///   the next call. Pass it straight to `DataChannelMediaStream.send(samples:frameCount:)`.
    /// - Throws: `Failure` naming the file. Nothing recovers a decode failure mid-file; the
    ///   caller should stop pulling.
    public func nextFrame() throws -> UnsafeBufferPointer<Float>
    {
        var readFailure: Error?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] _, outStatus in
            do { try fillInput() }
            catch { readFailure = error; outStatus.pointee = .endOfStream; return nil }
            outStatus.pointee = .haveData
            return input
        }
        if let readFailure { throw Failure.decodeFailed(url, readFailure) }
        guard status == .haveData, output.frameLength == AVAudioFrameCount(Self.frameCount)
        else { throw Failure.decodeFailed(url, conversionError) }
        return UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
    }

    /// Restarting the file here rather than between conversions keeps the converter from ever
    /// seeing an end of stream, so the resampler carries its state across the seam.
    private func fillInput() throws
    {
        if file.framePosition >= file.length { file.framePosition = 0 }
        if try readSome() { return }
        file.framePosition = 0
        guard try readSome() else { throw Failure.empty(url) }
    }

    /// - Returns: false when the file gave nothing because it has ended - which a compressed
    ///   file can do before the length it claims, and which it reports by throwing rather than
    ///   by reading no frames. A failure anywhere but the end is a real one and is thrown.
    private func readSome() throws -> Bool
    {
        do { try file.read(into: input) }
        catch
        {
            guard file.framePosition > 0 else { throw error }
            return false
        }
        return input.frameLength > 0
    }
}
