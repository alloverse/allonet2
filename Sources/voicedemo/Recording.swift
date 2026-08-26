//
//  Recording.swift
//  allonet2
//
//  A sound file as an endless source of voice frames; see VOICEDEMO_WAV in VoiceDemo.swift.
//

import AVFoundation
import Foundation
import allonet2

/// A sound file decoded on demand into voice frames: 20 ms of 48 kHz mono Float32, the shape
/// `DataChannelMediaStream.send(samples:frameCount:)` takes. The end of the file wraps to its
/// start inside the same conversion pass, so the loop is sample-continuous at the seam.
///
/// Not thread-safe: hand it to one queue and pull frames only from there.
final class Recording
{
    enum Failure: Error, CustomStringConvertible
    {
        case cannotOpen(String, Error)
        case empty(String)
        case cannotConvert(String, AVAudioFormat)
        case decodeFailed(String, Error?)

        var description: String
        {
            switch self
            {
            case .cannotOpen(let path, let underlying):
                return "Cannot read \(path) as audio: \(underlying)"
            case .empty(let path):
                return "\(path) decodes to no audio"
            case .cannotConvert(let path, let format):
                return "Cannot convert \(path) (\(format)) to 48 kHz mono"
            case .decodeFailed(let path, let underlying):
                return "Decoding \(path) failed: \(underlying.map { "\($0)" } ?? "converter gave no reason")"
            }
        }
    }

    /// The file's own length, before looping.
    let duration: TimeInterval

    private let path: String
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    /// - Parameter path: anything AVAudioFile reads - wav, m4a, aiff, caf.
    /// - Throws: `Failure` naming `path`; CoreAudio's own errors say only what went wrong,
    ///   never with which file.
    init(path: String) throws
    {
        self.path = path
        do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) }
        catch { throw Failure.cannotOpen(path, error) }
        let source = file.processingFormat
        guard file.length > 0 else { throw Failure.empty(path) }
        duration = Double(file.length) / source.sampleRate

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: DataChannelMediaStream.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(DataChannelMediaStream.frameDuration))
        else { throw Failure.cannotConvert(path, source) }
        // Discrete channel layout has no downmix rule; without a map the converter emits
        // silence. See docs/voice-implementation.md, One engine.
        if source.channelCount != target.channelCount { converter.channelMap = [0] }
        self.converter = converter
        self.input = input
        self.output = output
    }

    /// Decode the next 20 ms, wrapping to the start of the file when it runs out.
    /// - Returns: `DataChannelMediaStream.frameDuration` mono samples in the recording's own
    ///   buffer, valid until the next call.
    /// - Throws: `Failure` naming the file. Nothing recovers a decode failure mid-file; the
    ///   caller should stop pulling.
    func nextFrame() throws -> UnsafeBufferPointer<Float>
    {
        var readFailure: Error?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] _, outStatus in
            do { try fillInput() }
            catch { readFailure = error; outStatus.pointee = .endOfStream; return nil }
            outStatus.pointee = .haveData
            return input
        }
        if let readFailure { throw Failure.decodeFailed(path, readFailure) }
        guard status == .haveData,
              output.frameLength == AVAudioFrameCount(DataChannelMediaStream.frameDuration)
        else { throw Failure.decodeFailed(path, conversionError) }
        return UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
    }

    /// Restarting the file here rather than between conversions keeps the converter from ever
    /// seeing an end of stream, so the resampler carries its state across the seam.
    private func fillInput() throws
    {
        if file.framePosition >= file.length { file.framePosition = 0 }
        if try readSome() { return }
        file.framePosition = 0
        guard try readSome() else { throw Failure.empty(path) }
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
