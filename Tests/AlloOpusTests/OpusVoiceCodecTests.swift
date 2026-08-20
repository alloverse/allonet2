//
//  OpusVoiceCodecTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2
@testable import AlloOpus

@Suite("Opus voice codec")
struct OpusVoiceCodecTests
{
    /// A 440 Hz tone: a real signal, so the encoder produces a realistic payload rather
    /// than the degenerate output silence would give.
    static func tone(frame: Int, count: Int = Int(Opus.frameSize)) -> [Float]
    {
        (0..<count).map { sample in
            let t = Double(frame * count + sample) / Double(Opus.sampleRate)
            return Float(0.5 * sin(2 * .pi * 440 * t))
        }
    }

    static func encodeFrames(_ count: Int, encoder: OpusVoiceEncoder) throws -> [Data]
    {
        try (0..<count).map { frame in
            var samples = tone(frame: frame)
            return try samples.withUnsafeMutableBufferPointer { buffer in
                try encoder.encode(buffer.baseAddress!, frameCount: buffer.count)
            }
        }
    }

    @Test func encodesAndDecodesATone() throws
    {
        let encoder = try OpusVoiceEncoder()
        let decoder = try OpusVoiceDecoder()

        let payloads = try Self.encodeFrames(10, encoder: encoder)
        for payload in payloads
        {
            #expect(!payload.isEmpty)
            #expect(payload.count < 200, "20 ms at 32 kbit/s should be well under 200 bytes, got \(payload.count)")
        }

        var output = [Float](repeating: 0, count: Int(Opus.frameSize))
        var decodedEnergy = 0.0
        for payload in payloads
        {
            let written = try output.withUnsafeMutableBufferPointer { buffer in
                try decoder.decode(payload, fec: false, into: buffer.baseAddress!, capacity: buffer.count)
            }
            #expect(written == Int(Opus.frameSize))
            decodedEnergy += output.reduce(0) { $0 + Double($1 * $1) }
        }
        // The codec has latency, so the first frames are quiet; the tone must still be there.
        #expect(decodedEnergy > 1.0, "decoded audio is silent, energy \(decodedEnergy)")
    }

    @Test func concealsAGapWithoutAPayload() throws
    {
        let encoder = try OpusVoiceEncoder()
        let decoder = try OpusVoiceDecoder()
        let payloads = try Self.encodeFrames(5, encoder: encoder)

        var output = [Float](repeating: 0, count: Int(Opus.frameSize))
        for payload in payloads
        {
            _ = try output.withUnsafeMutableBufferPointer { buffer in
                try decoder.decode(payload, fec: false, into: buffer.baseAddress!, capacity: buffer.count)
            }
        }
        // PLC extrapolates from what came before rather than inserting silence.
        let written = try output.withUnsafeMutableBufferPointer { buffer in
            try decoder.decode(nil, fec: false, into: buffer.baseAddress!, capacity: buffer.count)
        }
        #expect(written == Int(Opus.frameSize))
        let energy = output.reduce(0) { $0 + Double($1 * $1) }
        #expect(energy > 0, "packet loss concealment produced pure silence")
    }

    /// The recovery path the jitter buffer relies on: decode frame N's audio out of frame
    /// N+1's payload, which is what makes dropping a frame survivable without retransmits.
    @Test func recoversALostFrameFromTheNextPayload() throws
    {
        let encoder = try OpusVoiceEncoder()
        encoder.setExpectedPacketLoss(percent: 30)   // spend bitrate on FEC
        let payloads = try Self.encodeFrames(12, encoder: encoder)

        let decoder = try OpusVoiceDecoder()
        var output = [Float](repeating: 0, count: Int(Opus.frameSize))
        // Prime with the first frames so the decoder has state.
        for payload in payloads[0..<10]
        {
            _ = try output.withUnsafeMutableBufferPointer { buffer in
                try decoder.decode(payload, fec: false, into: buffer.baseAddress!, capacity: buffer.count)
            }
        }
        // Frame 10 is "lost": reconstruct it from frame 11.
        let written = try output.withUnsafeMutableBufferPointer { buffer in
            try decoder.decode(payloads[11], fec: true, into: buffer.baseAddress!, capacity: buffer.count)
        }
        #expect(written == Int(Opus.frameSize))
        let energy = output.reduce(0) { $0 + Double($1 * $1) }
        #expect(energy > 0, "FEC recovery produced silence")
    }

    @Test func installsItselfAsTheProcessCodec() throws
    {
        Opus.install()
        // Bound separately on purpose: `#require(x)()` crashes the Swift 6.3.2 type checker
        // (assertion in ConstraintSystem::recordArgumentList).
        let makeEncoder = try #require(VoiceCodecs.makeEncoder)
        let makeDecoder = try #require(VoiceCodecs.makeDecoder)
        let encoder = try makeEncoder()
        let decoder = try makeDecoder()
        #expect(encoder.kind == .opus)
        #expect(decoder.supportsFEC)
        #expect(!Opus.version().isEmpty)
    }
}
