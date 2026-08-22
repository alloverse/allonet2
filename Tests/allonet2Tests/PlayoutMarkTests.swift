//
//  PlayoutMarkTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@Suite("Playout mark")
struct PlayoutMarkTests
{
    let frame = 960

    @Test("every sample of the newest frame resolves to it, and a drained ring to nothing")
    func newestFrame()
    {
        let mark = PlayoutMark(framesWritten: 9600, sequence: 10)
        #expect(mark.sequence(atReadHead: 8640, frameDuration: frame) == 10)   // its first sample
        #expect(mark.sequence(atReadHead: 9599, frameDuration: frame) == 10)   // its last sample
        #expect(mark.sequence(atReadHead: 9600, frameDuration: frame) == nil)  // nothing left to play
    }

    @Test("older samples count back one frame per frame duration")
    func olderFrames()
    {
        let mark = PlayoutMark(framesWritten: 9600, sequence: 10)
        #expect(mark.sequence(atReadHead: 8639, frameDuration: frame) == 9)
        #expect(mark.sequence(atReadHead: 7680, frameDuration: frame) == 9)
        #expect(mark.sequence(atReadHead: 7679, frameDuration: frame) == 8)
        #expect(mark.sequence(atReadHead: 0, frameDuration: frame) == 1)       // nine frames back
    }

    @Test("sequence and ring position both wrap")
    func wraparound()
    {
        #expect(PlayoutMark(framesWritten: 9600, sequence: 0).sequence(atReadHead: 7680, frameDuration: frame) == .max)
        // 960 frames written since the position counter wrapped past UInt32.max.
        let wrapped = PlayoutMark(framesWritten: 480, sequence: 5)
        #expect(wrapped.sequence(atReadHead: Int(UInt32.max) - 479, frameDuration: frame) == 5)
    }

    @Test("round-trips through the one atomic word the audio thread reads")
    func packing()
    {
        let mark = PlayoutMark(framesWritten: 4_000_000_000, sequence: 3_000_000_000)
        #expect(PlayoutMark(bits: mark.bits) == mark)
        #expect(PlayoutMark(bits: 0) == nil)
    }
}
