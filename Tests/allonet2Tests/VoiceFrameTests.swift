//
//  VoiceFrameTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@Suite("Voice frame wire format")
struct VoiceFrameTests
{
    @Test func roundTrips() throws
    {
        let frame = VoiceFrame(kind: .opus, sequence: 0xDEADBEEF, timestamp: 960 * 3, payload: Data([1, 2, 3, 4]))
        let decoded = try VoiceFrame(decoding: frame.encoded)
        #expect(decoded == frame)
        #expect(frame.encoded.count == VoiceFrame.headerSize + 4)
    }

    @Test func carriesAnEmptyPayload() throws
    {
        let frame = VoiceFrame(kind: .opus, sequence: 7, timestamp: 0, payload: Data())
        #expect(try VoiceFrame(decoding: frame.encoded) == frame)
    }

    /// Data handed over by libdatachannel is often a slice, whose indices do not start at 0.
    @Test func decodesFromASlice() throws
    {
        let frame = VoiceFrame(kind: .pcmFloat32, sequence: 42, timestamp: 960, payload: Data([9, 9]))
        var padded = Data([0xFF, 0xFF, 0xFF])
        padded.append(frame.encoded)
        let slice = padded[3...]
        #expect(slice.startIndex == 3)
        #expect(try VoiceFrame(decoding: slice) == frame)
    }

    @Test func rejectsShortAndUnknownFrames()
    {
        #expect(throws: VoiceFrameError.tooShort(byteCount: 8)) {
            try VoiceFrame(decoding: Data(repeating: 0, count: 8))
        }
        var unknown = Data([0x7E])
        unknown.append(Data(repeating: 0, count: 8))
        #expect(throws: VoiceFrameError.unknownKind(0x7E)) {
            try VoiceFrame(decoding: unknown)
        }
    }

    /// Routing turns a frame away without parsing it, and has to be able to say which byte or
    /// length it turned away on: the same errors the parser raises, off the same check.
    @Test func headerValidationNamesWhatFailed() throws
    {
        #expect(try VoiceFrame.validateHeader(Data([1]) + Data(repeating: 0, count: 8)) == .pcmFloat32)

        #expect(throws: VoiceFrameError.tooShort(byteCount: 8)) {
            try VoiceFrame.validateHeader(Data(repeating: 0, count: 8))
        }
        #expect(throws: VoiceFrameError.unknownKind(0x7E)) {
            try VoiceFrame.validateHeader(Data([0x7E]) + Data(repeating: 0, count: 8))
        }

        #expect("\(VoiceFrameError.tooShort(byteCount: 3))".contains("3 bytes"))
        #expect("\(VoiceFrameError.unknownKind(0x7E))".contains("126"))
    }

    @Test func comparesSequencesAcrossWraparound()
    {
        #expect(UInt32(5).isNewerSequence(than: 4))
        #expect(!UInt32(4).isNewerSequence(than: 5))
        #expect(UInt32(0).isNewerSequence(than: .max), "0 follows UInt32.max")
        #expect(!UInt32.max.isNewerSequence(than: 0))
        #expect(UInt32(2).sequenceDistance(from: .max) == 3)
    }
}
