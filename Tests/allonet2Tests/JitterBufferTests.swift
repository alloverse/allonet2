//
//  JitterBufferTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@Suite("Jitter buffer")
struct JitterBufferTests
{
    /// Loss, reordering and duplication are injected here, at the framing layer, rather than
    /// by mangling a real network - which keeps these deterministic.
    static func frame(_ sequence: UInt32) -> VoiceFrame
    {
        VoiceFrame(kind: .opus, sequence: sequence, timestamp: sequence &* 960, payload: Data([UInt8(sequence & 0xFF)]))
    }

    /// Arrival time for a frame sent on a perfect clock, so the jitter estimate stays at 0
    /// and the target depth stays at the minimum.
    static func arrival(_ sequence: UInt32) -> Double { Double(sequence) * 0.02 }

    static func makeBuffer(counters: VoiceCountersBox = VoiceCountersBox()) -> JitterBuffer
    {
        var configuration = JitterBuffer.Configuration()
        configuration.minimumDepth = 2
        return JitterBuffer(configuration: configuration, counters: counters)
    }

    @Test func primesBeforePlayingOut()
    {
        let buffer = Self.makeBuffer()
        #expect(buffer.nextStep(codecSupportsFEC: true) == .priming)

        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .priming, "one frame is below the target depth")

        buffer.insert(Self.frame(1), arrival: Self.arrival(1))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(0)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(1)))
    }

    @Test func playsReorderedFramesInOrder()
    {
        let buffer = Self.makeBuffer()
        for sequence in [UInt32(2), 0, 3, 1]
        {
            buffer.insert(Self.frame(sequence), arrival: Self.arrival(sequence))
        }
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(0)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(1)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(2)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(3)))
    }

    @Test func recoversALostFrameFromTheNextFramesFEC()
    {
        let counters = VoiceCountersBox()
        let buffer = Self.makeBuffer(counters: counters)
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(2), arrival: Self.arrival(2))   // 1 never arrives
        buffer.insert(Self.frame(3), arrival: Self.arrival(3))

        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(0)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .recoverFromFEC(next: Self.frame(2)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(2)), "the FEC carrier still plays in its own slot")
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(3)))
        #expect(counters.snapshot.fecRecovered == 1)
        #expect(counters.snapshot.decoded == 3)
    }

    @Test func concealsWhenTheCodecCannotRecover()
    {
        let counters = VoiceCountersBox()
        let buffer = Self.makeBuffer(counters: counters)
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(2), arrival: Self.arrival(2))

        #expect(buffer.nextStep(codecSupportsFEC: false) == .decode(Self.frame(0)))
        #expect(buffer.nextStep(codecSupportsFEC: false) == .conceal)
        #expect(buffer.nextStep(codecSupportsFEC: false) == .decode(Self.frame(2)))
        #expect(counters.snapshot.concealed == 1)
    }

    /// Two frames lost back to back: FEC only reaches one frame back, so the older slot has
    /// to be concealed.
    @Test func concealsWhenFECCannotReachBackFarEnough()
    {
        let buffer = Self.makeBuffer()
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(3), arrival: Self.arrival(3))   // 1 and 2 lost

        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(0)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .conceal, "frame 2 is missing too, so nothing carries FEC for 1")
        #expect(buffer.nextStep(codecSupportsFEC: true) == .recoverFromFEC(next: Self.frame(3)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(3)))
    }

    @Test func countsDuplicatesAndPlaysThemOnce()
    {
        let counters = VoiceCountersBox()
        let buffer = Self.makeBuffer(counters: counters)
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(1), arrival: Self.arrival(1))

        #expect(counters.snapshot.duplicate == 1)
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(0)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(1)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .conceal)
    }

    @Test func dropsFramesThatArriveAfterTheirSlotHasPlayed()
    {
        let counters = VoiceCountersBox()
        let buffer = Self.makeBuffer(counters: counters)
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(1), arrival: Self.arrival(1))
        _ = buffer.nextStep(codecSupportsFEC: true)   // plays 0
        _ = buffer.nextStep(codecSupportsFEC: true)   // plays 1

        buffer.insert(Self.frame(0), arrival: Self.arrival(9))
        #expect(counters.snapshot.late == 1)
        #expect(buffer.depth == 0)
    }

    @Test func reprimesAfterTheSenderGoesAway()
    {
        let buffer = Self.makeBuffer()
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(1), arrival: Self.arrival(1))
        _ = buffer.nextStep(codecSupportsFEC: true)
        _ = buffer.nextStep(codecSupportsFEC: true)

        #expect(buffer.nextStep(codecSupportsFEC: true) == .conceal, "one slot of concealment covers the gap")
        #expect(buffer.nextStep(codecSupportsFEC: true) == .priming, "then it waits rather than running ahead")

        // A sender that comes back is played from wherever it resumes.
        buffer.insert(Self.frame(500), arrival: Self.arrival(500))
        buffer.insert(Self.frame(501), arrival: Self.arrival(501))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(500)))
    }

    /// Seen live: one side dropped 73% of a lossless stream as "late". Playout had caught up
    /// with arrival once, advanced past the empty slot, and from then on every frame arrived
    /// one slot behind a playhead that kept concealing its way forward.
    @Test func resumesFromTheNextFrameAfterAnUnderrun()
    {
        let counters = VoiceCountersBox()
        let buffer = Self.makeBuffer(counters: counters)
        buffer.insert(Self.frame(0), arrival: Self.arrival(0))
        buffer.insert(Self.frame(1), arrival: Self.arrival(1))
        _ = buffer.nextStep(codecSupportsFEC: true)
        _ = buffer.nextStep(codecSupportsFEC: true)
        #expect(buffer.nextStep(codecSupportsFEC: true) == .conceal, "underrun")

        // The frames the playhead would have run past.
        buffer.insert(Self.frame(2), arrival: Self.arrival(2))
        buffer.insert(Self.frame(3), arrival: Self.arrival(3))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(2)))
        #expect(buffer.nextStep(codecSupportsFEC: true) == .decode(Self.frame(3)))
        #expect(counters.snapshot.late == 0, "nothing that arrived after the underrun is late")
    }

    @Test func growsTheTargetDepthWithObservedJitter()
    {
        let buffer = Self.makeBuffer()
        #expect(buffer.targetDepth == 2)

        // Alternate early and late arrivals, ~60 ms of swing.
        for sequence in UInt32(0)..<40
        {
            let wobble = sequence.isMultiple(of: 2) ? 0.0 : 0.06
            buffer.insert(Self.frame(sequence), arrival: Self.arrival(sequence) + wobble)
        }
        #expect(buffer.targetDepth > 2, "a jittery sender must buffer deeper")
        #expect(buffer.targetDepth <= buffer.configuration.maximumDepth)
    }

    /// Every playout slot must be exactly one decision, decoded frames must come out in
    /// order, and nothing may vanish unaccounted for.
    @Test func accountsForEveryFrameUnderHostileConditions()
    {
        let counters = VoiceCountersBox()
        let buffer = Self.makeBuffer(counters: counters)
        var generator = SystemRandomNumberGenerator()

        let total: UInt32 = 400
        var inserted = 0
        var pending: [(VoiceFrame, Double)] = []

        for sequence in UInt32(0)..<total
        {
            let roll = Int.random(in: 0..<100, using: &generator)
            switch roll
            {
            case 0..<5: break                                    // lost
            case 5..<15:                                          // reordered: hold it back
                pending.append((Self.frame(sequence), Self.arrival(sequence)))
            case 15..<20:                                         // duplicated
                buffer.insert(Self.frame(sequence), arrival: Self.arrival(sequence)); inserted += 1
                buffer.insert(Self.frame(sequence), arrival: Self.arrival(sequence)); inserted += 1
            default:
                buffer.insert(Self.frame(sequence), arrival: Self.arrival(sequence)); inserted += 1
            }
            if !pending.isEmpty, Bool.random(using: &generator)
            {
                let (frame, arrival) = pending.removeFirst()
                buffer.insert(frame, arrival: arrival)
                inserted += 1
            }
        }
        for (frame, arrival) in pending { buffer.insert(frame, arrival: arrival); inserted += 1 }

        var lastPlayed: UInt32?
        var steps = 0
        while steps < Int(total) * 2
        {
            steps += 1
            switch buffer.nextStep(codecSupportsFEC: true)
            {
            case .decode(let frame):
                if let last = lastPlayed
                {
                    #expect(frame.sequence.isNewerSequence(than: last), "playout must not go backwards")
                }
                lastPlayed = frame.sequence
            case .recoverFromFEC, .conceal, .priming:
                break
            }
        }

        let snapshot = counters.snapshot
        let accounted = snapshot.decoded + snapshot.duplicate + snapshot.late + snapshot.overflowed + buffer.depth
        #expect(accounted == inserted, "every inserted frame is decoded, dropped, or still buffered: \(snapshot), depth \(buffer.depth)")
        #expect(snapshot.decoded > 0)
    }
}
