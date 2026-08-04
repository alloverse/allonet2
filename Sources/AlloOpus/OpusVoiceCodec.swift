//
//  OpusVoiceCodec.swift
//  allonet2
//

import Foundation
import COpus
import COpusShim
import allonet2

/// What libwebrtc used to provide for voice, provided directly: Opus with in-band FEC for
/// loss recovery and PLC for what FEC cannot reach. There is no retransmission because a
/// retransmitted voice frame arrives too late to play.
public enum Opus
{
    public static let sampleRate: Int32 = 48000
    public static let channels: Int32 = 1
    /// 20 ms at 48 kHz.
    public static let frameSize: Int32 = 960
    public static let defaultBitrate: Int32 = 32000

    /// Install Opus as the voice codec for this process.
    public static func install()
    {
        VoiceCodecs.makeEncoder = { try OpusVoiceEncoder() }
        VoiceCodecs.makeDecoder = { try OpusVoiceDecoder() }
    }

    public static func version() -> String { String(cString: opus_get_version_string()) }
}

public final class OpusVoiceEncoder: VoiceEncoder
{
    public let kind = VoiceFrame.Kind.opus
    private let encoder: OpaquePointer
    /// Opus never emits more than this for one frame at our bitrate; sized for the worst case.
    private var scratch = [UInt8](repeating: 0, count: 4000)

    public init(bitrate: Int32 = Opus.defaultBitrate) throws
    {
        var error: Int32 = OPUS_OK
        guard let encoder = opus_encoder_create(Opus.sampleRate, Opus.channels, OPUS_APPLICATION_VOIP, &error), error == OPUS_OK
        else { throw VoiceCodecError.failed(operation: "opus_encoder_create", code: error) }
        self.encoder = encoder

        try check(allo_opus_encoder_set_bitrate(encoder, bitrate), "set bitrate")
        try check(allo_opus_encoder_set_vbr(encoder, 1), "set vbr")
        try check(allo_opus_encoder_set_signal_voice(encoder), "set signal")
        // FEC costs bitrate only when the far end reports loss, so it is on from the start.
        try check(allo_opus_encoder_set_inband_fec(encoder, 1), "set fec")
        try check(allo_opus_encoder_set_packet_loss(encoder, 5), "set expected loss")
        // DTX off for now: silence suppression interacts with the jitter buffer's idea of a
        // continuous stream, and that pairing has not been measured yet.
        try check(allo_opus_encoder_set_dtx(encoder, 0), "set dtx")
    }

    deinit { opus_encoder_destroy(encoder) }

    public func setExpectedPacketLoss(percent: Int)
    {
        _ = allo_opus_encoder_set_packet_loss(encoder, Int32(max(0, min(100, percent))))
    }

    public func encode(_ samples: UnsafePointer<Float>, frameCount: Int) throws -> Data
    {
        let written = scratch.withUnsafeMutableBufferPointer { output in
            opus_encode_float(encoder, samples, Int32(frameCount), output.baseAddress!, Int32(output.count))
        }
        guard written > 0 else { throw VoiceCodecError.failed(operation: "opus_encode_float", code: written) }
        return Data(scratch[0..<Int(written)])
    }
}

public final class OpusVoiceDecoder: VoiceDecoder
{
    public let kind = VoiceFrame.Kind.opus
    public let supportsFEC = true
    private let decoder: OpaquePointer

    public init() throws
    {
        var error: Int32 = OPUS_OK
        guard let decoder = opus_decoder_create(Opus.sampleRate, Opus.channels, &error), error == OPUS_OK
        else { throw VoiceCodecError.failed(operation: "opus_decoder_create", code: error) }
        self.decoder = decoder
    }

    deinit { opus_decoder_destroy(decoder) }

    public func decode(_ payload: Data?, fec: Bool, into output: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int
    {
        // Nil payload with fec=0 is Opus's own concealment: it extrapolates from what it has
        // already decoded rather than inserting silence.
        guard let payload else
        {
            let written = opus_decode_float(decoder, nil, 0, output, Int32(capacity), 0)
            guard written > 0 else { throw VoiceCodecError.failed(operation: "opus_decode_float (plc)", code: written) }
            return Int(written)
        }

        let written = payload.withUnsafeBytes { raw -> Int32 in
            opus_decode_float(decoder, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(payload.count),
                              output, Int32(capacity), fec ? 1 : 0)
        }
        guard written > 0 else
        {
            throw VoiceCodecError.failed(operation: fec ? "opus_decode_float (fec)" : "opus_decode_float", code: written)
        }
        return Int(written)
    }
}

private func check(_ result: Int32, _ operation: String) throws
{
    guard result == OPUS_OK else { throw VoiceCodecError.failed(operation: operation, code: result) }
}
