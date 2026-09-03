//
//  MediaFrameTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@Suite("Media frame wire format")
struct MediaFrameTests
{
    @Test func roundTrips() throws
    {
        let frame = MediaFrame(kind: .opus, sequence: 0xDEADBEEF, timestamp: 960 * 3, payload: Data([1, 2, 3, 4]))
        let decoded = try MediaFrame(decoding: frame.encoded)
        #expect(decoded == frame)
        #expect(frame.encoded.count == MediaFrame.headerSize + 4)
    }

    @Test func carriesAnEmptyPayload() throws
    {
        let frame = MediaFrame(kind: .opus, sequence: 7, timestamp: 0, payload: Data())
        #expect(try MediaFrame(decoding: frame.encoded) == frame)
    }

    /// Data handed over by libdatachannel is often a slice, whose indices do not start at 0.
    @Test func decodesFromASlice() throws
    {
        let frame = MediaFrame(kind: .pcmFloat32, sequence: 42, timestamp: 960, payload: Data([9, 9]))
        var padded = Data([0xFF, 0xFF, 0xFF])
        padded.append(frame.encoded)
        let slice = padded[3...]
        #expect(slice.startIndex == 3)
        #expect(try MediaFrame(decoding: slice) == frame)
    }

    @Test func rejectsShortAndUnknownFrames()
    {
        #expect(throws: MediaFrameError.tooShort(byteCount: 8)) {
            try MediaFrame(decoding: Data(repeating: 0, count: 8))
        }
        var unknown = Data([0x7E])
        unknown.append(Data(repeating: 0, count: 8))
        #expect(throws: MediaFrameError.unknownKind(0x7E)) {
            try MediaFrame(decoding: unknown)
        }
    }

    /// Routing turns a frame away without parsing it, and has to be able to say which byte or
    /// length it turned away on: the same errors the parser raises, off the same check.
    @Test func headerValidationNamesWhatFailed() throws
    {
        #expect(try MediaFrame.validateHeader(Data([1]) + Data(repeating: 0, count: 8)) == .pcmFloat32)

        #expect(throws: MediaFrameError.tooShort(byteCount: 8)) {
            try MediaFrame.validateHeader(Data(repeating: 0, count: 8))
        }
        #expect(throws: MediaFrameError.unknownKind(0x7E)) {
            try MediaFrame.validateHeader(Data([0x7E]) + Data(repeating: 0, count: 8))
        }

        #expect("\(MediaFrameError.tooShort(byteCount: 3))".contains("3 bytes"))
        #expect("\(MediaFrameError.unknownKind(0x7E))".contains("126"))
    }

    /// Video rides the same header as audio, and the payload is an opaque access unit: a place
    /// routing it must be able to read the header without knowing anything about H.264.
    @Test func roundTripsVideoKinds() throws
    {
        for kind in [MediaFrame.Kind.h264Key, .h264Delta]
        {
            let frame = MediaFrame(kind: kind, sequence: 1, timestamp: 48_000, payload: Data([0, 0, 0, 1, 0x65]))
            #expect(try MediaFrame(decoding: frame.encoded) == frame)
            #expect(kind.isVideo)
        }
        #expect(!MediaFrame.Kind.opus.isVideo)
        #expect(MediaFrame.Kind.h264Key.maximumFrameBytes > MediaFrame.Kind.h264Delta.maximumFrameBytes)
        #expect(MediaFrame.Kind.opus.maximumFrameBytes == 3849)
    }

    /// The kind byte is a peer's, and this build's set of kinds is finite: the one past the last
    /// one it knows has to be named, not guessed at.
    @Test func rejectsAKindThisBuildDoesNotKnow()
    {
        #expect(throws: MediaFrameError.unknownKind(4)) {
            try MediaFrame.validateHeader(Data([4]) + Data(repeating: 0, count: 8))
        }
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
