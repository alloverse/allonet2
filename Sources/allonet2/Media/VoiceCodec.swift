//
//  VoiceCodec.swift
//  allonet2
//

import Foundation

/// Turns 20 ms of mono Float32 into a payload small enough to send every frame.
public protocol VoiceEncoder: AnyObject
{
    var kind: VoiceFrame.Kind { get }
    /// Tell the encoder what fraction of frames the far end is losing, so in-band FEC can be
    /// spent where it helps. Ignored by codecs without FEC.
    func setExpectedPacketLoss(percent: Int)
    func encode(_ samples: UnsafePointer<Float>, frameCount: Int) throws -> Data
}

/// The receiving half. Loss handling lives here rather than in the jitter buffer, because
/// only the codec knows how to reconstruct or conceal.
public protocol VoiceDecoder: AnyObject
{
    var kind: VoiceFrame.Kind { get }
    /// Whether a payload carries recovery data for the frame *before* it.
    var supportsFEC: Bool { get }
    /// Decode into `output`, returning samples written.
    ///
    /// - `payload` nil: conceal a gap of `frameCount` samples (PLC).
    /// - `fec` true: `payload` is the *next* frame; reconstruct the one that was lost.
    func decode(_ payload: Data?, fec: Bool, into output: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int
}

/// Codec registry. Whichever module links a codec installs it here; the server links none
/// and never decodes, which is what keeps libopus off the Linux server build.
public enum VoiceCodecs
{
    nonisolated(unsafe) public static var makeEncoder: (@Sendable () throws -> any VoiceEncoder)?
    nonisolated(unsafe) public static var makeDecoder: (@Sendable () throws -> any VoiceDecoder)?
}

public enum VoiceCodecError: Error, CustomStringConvertible
{
    case noCodecInstalled
    case outputTooSmall(needed: Int, capacity: Int)
    case failed(operation: String, code: Int32)

    public var description: String
    {
        switch self
        {
        case .noCodecInstalled:
            "no voice codec installed; a module that links one must set VoiceCodecs.makeEncoder/makeDecoder"
        case .outputTooSmall(let needed, let capacity):
            "decode needs room for \(needed) samples, got \(capacity)"
        case .failed(let operation, let code):
            "voice codec \(operation) failed with \(code)"
        }
    }
}

/// Uncompressed Float32, for tests that need to assert on the samples that came out without
/// depending on a codec being linked. Concealment repeats nothing - it emits silence.
public final class RawPCMVoiceCodec: VoiceEncoder, VoiceDecoder
{
    public let kind = VoiceFrame.Kind.pcmFloat32
    public let supportsFEC = false

    public init() {}
    public func setExpectedPacketLoss(percent: Int) {}

    public func encode(_ samples: UnsafePointer<Float>, frameCount: Int) throws -> Data
    {
        Data(bytes: samples, count: frameCount * MemoryLayout<Float>.size)
    }

    public func decode(_ payload: Data?, fec: Bool, into output: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int
    {
        guard let payload, !fec else
        {
            output.update(repeating: 0, count: capacity)
            return capacity
        }
        let frameCount = payload.count / MemoryLayout<Float>.size
        guard frameCount <= capacity else
        {
            throw VoiceCodecError.outputTooSmall(needed: frameCount, capacity: capacity)
        }
        payload.withUnsafeBytes { raw in
            output.update(from: raw.baseAddress!.assumingMemoryBound(to: Float.self), count: frameCount)
        }
        return frameCount
    }
}
