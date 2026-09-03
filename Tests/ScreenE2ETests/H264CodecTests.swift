//
//  H264CodecTests.swift
//  ScreenE2ETests
//
//  The bitstream half: pattern in, Annex B out, pictures back.
//

import Testing
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import allonet2
@testable import AlloVideo

@Suite struct H264CodecTests
{
    static let width = 640
    static let height = 360

    /// One picture of the pattern, at 30 fps of made-up capture time.
    static func pattern(frame: Int) -> CapturedFrame
    {
        CapturedFrame(pixels: PatternSource.picture(frame: frame, width: width, height: height),
                      capturedAt: Double(frame) / 30)
    }

    @Test func patternPicturesCarryTheirFrameIndex() throws
    {
        for frame in [0, 1, 4095, 1 << 23 - 1]
        {
            let picture = PatternSource.picture(frame: frame, width: Self.width, height: Self.height)
            #expect(PatternSource.frameIndex(in: picture) == frame)
        }
    }

    /// The live path: a running source hands out pictures, newest first when the consumer is
    /// slow, but never out of order.
    @Test func aRunningSourceYieldsFramesInOrder() async throws
    {
        let source = PatternSource(width: Self.width, height: Self.height, fps: 120)
        defer { source.stop() }
        var seen: [Int] = []
        for await frame in source.frames
        {
            seen.append(PatternSource.frameIndex(in: frame.pixels))
            if seen.count == 5 { break }
        }
        #expect(seen == seen.sorted() && Set(seen).count == 5, "got \(seen)")
    }

    @Test func theFirstPictureIsAKeyframeAndTheRestAreDeltas() async throws
    {
        let encoder = try H264Encoder(width: Self.width, height: Self.height, bitrate: 2_000_000)
        var kinds: [MediaFrame.Kind] = []
        for index in 0..<8
        {
            guard let encoded = try await encoder.encode(Self.pattern(frame: index), forceKeyframe: false) else { continue }
            #expect(encoded.annexB.starts(with: [0, 0, 0, 1]), "an access unit must start with a start code")
            kinds.append(encoded.kind)
        }
        #expect(kinds.first == .h264Key)
        #expect(kinds.dropFirst().allSatisfy { $0 == .h264Delta }, "got \(kinds)")
    }

    @Test func aKeyframeCarriesItsOwnParameterSets() async throws
    {
        let encoder = try H264Encoder(width: Self.width, height: Self.height, bitrate: 2_000_000)
        let encoded = try #require(try await encoder.encode(Self.pattern(frame: 0), forceKeyframe: true))
        let types = H264Decoder.nalUnits(in: encoded.annexB).map { $0[0] & 0x1f }
        #expect(types.contains(7), "no SPS: \(types)")
        #expect(types.contains(8), "no PPS: \(types)")
        #expect(types.contains(5), "no IDR: \(types)")
    }

    @Test func forcingAKeyframeMakesOne() async throws
    {
        let encoder = try H264Encoder(width: Self.width, height: Self.height, bitrate: 2_000_000)
        _ = try await encoder.encode(Self.pattern(frame: 0), forceKeyframe: false)
        let forced = try #require(try await encoder.encode(Self.pattern(frame: 1), forceKeyframe: true))
        #expect(forced.kind == .h264Key)
    }

    /// The whole bitstream contract in one case: what the encoder emits, wrapped as a media
    /// frame and unwrapped again, is a picture the hardware decoder accepts and shows the frame
    /// index that went in. A sample that merely *builds* proves nothing.
    @Test func anEncodedPictureDecodesBackToTheFrameThatWasDrawn() async throws
    {
        let encoder = try H264Encoder(width: Self.width, height: Self.height, bitrate: 4_000_000)
        let decoder = H264Decoder()
        let display = PixelDecoder()
        var decodedIndices: [Int] = []

        for index in 0..<6
        {
            guard let encoded = try await encoder.encode(Self.pattern(frame: index), forceKeyframe: false) else { continue }
            let onTheWire = MediaFrame(kind: encoded.kind, sequence: UInt32(index), timestamp: encoded.timestamp, payload: encoded.annexB).encoded
            let received = try MediaFrame(decoding: onTheWire)
            let sample = try #require(try decoder.decode(received))
            #expect(CMSampleBufferGetPresentationTimeStamp(sample).timescale == 48000)
            decodedIndices.append(PatternSource.frameIndex(in: try display.pixels(from: sample)))
        }

        #expect(decoder.hasKeyframe)
        #expect(decodedIndices == Array(0..<decodedIndices.count), "got \(decodedIndices)")
        #expect(decodedIndices.count >= 5)
    }

    @Test func deltasBeforeTheFirstKeyframeDecodeToNothing() async throws
    {
        let encoder = try H264Encoder(width: Self.width, height: Self.height, bitrate: 2_000_000)
        let decoder = H264Decoder()
        _ = try await encoder.encode(Self.pattern(frame: 0), forceKeyframe: false)
        let delta = try #require(try await encoder.encode(Self.pattern(frame: 1), forceKeyframe: false))
        #expect(delta.kind == .h264Delta)

        let frame = MediaFrame(kind: .h264Delta, sequence: 1, timestamp: delta.timestamp, payload: delta.annexB)
        #expect(try decoder.decode(frame) == nil)
        #expect(decoder.hasKeyframe == false)
    }

    @Test func anAudioFrameIsRefusedRatherThanDecoded() throws
    {
        let decoder = H264Decoder()
        let audio = MediaFrame(kind: .opus, sequence: 0, timestamp: 0, payload: Data([1, 2, 3]))
        #expect(throws: VideoDecodeError.self) { try decoder.decode(audio) }
    }

    @Test func anAccessUnitWithoutAStartCodeIsRefused() throws
    {
        let decoder = H264Decoder()
        let garbage = MediaFrame(kind: .h264Key, sequence: 0, timestamp: 0, payload: Data(repeating: 0xff, count: 64))
        #expect(throws: VideoDecodeError.self) { try decoder.decode(garbage) }
    }

    @Test func captureIsScaledToFitKeepingItsAspect() throws
    {
        let limit = CGSize(width: 1920, height: 1200)
        #expect(ScreenCapturer.fit(CGSize(width: 1440, height: 900), scale: 2, into: limit) == (1920, 1200))
        #expect(ScreenCapturer.fit(CGSize(width: 800, height: 600), scale: 1, into: limit) == (800, 600))
        // Odd sizes would break chroma subsampling.
        #expect(ScreenCapturer.fit(CGSize(width: 801, height: 601), scale: 1, into: limit) == (800, 600))
    }
}

enum CodecTestError: Error { case decodeFailed(OSStatus) }

/// A `VTDecompressionSession` the tests use to look at pictures. The product decodes through
/// `AVSampleBufferDisplayLayer` instead, which takes the same compressed samples.
final class PixelDecoder: @unchecked Sendable
{
    private var session: VTDecompressionSession?

    func pixels(from sample: CMSampleBuffer) throws -> CVPixelBuffer
    {
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        if session == nil
        {
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: nil, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: nil,
                outputCallback: nil, decompressionSessionOut: &created)
            guard status == noErr else { throw CodecTestError.decodeFailed(status) }
            session = created
        }
        var out: CVPixelBuffer?
        var thrown: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample, flags: [], infoFlagsOut: nil)
        { status, _, image, _, _ in
            if status != noErr { thrown = status } else { out = image }
        }
        guard status == noErr else { throw CodecTestError.decodeFailed(status) }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        guard thrown == noErr, let out else { throw CodecTestError.decodeFailed(thrown) }
        return out
    }
}
