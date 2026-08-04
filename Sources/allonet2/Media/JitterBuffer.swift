//
//  JitterBuffer.swift
//  allonet2
//

import Foundation

/// Absorbs network jitter and reordering, and tells the decoder what to do for each 20 ms of
/// playout: decode the frame that belongs there, reconstruct it from the *next* frame's
/// in-band FEC, or conceal the gap.
///
/// Holds encoded frames, not samples, because FEC recovery needs the following frame's
/// payload intact. Takes time only as a parameter, so tests drive it without a clock.
public final class JitterBuffer: @unchecked Sendable
{
    public struct Configuration: Sendable
    {
        /// Samples in one frame; 960 is 20 ms at 48 kHz.
        public var frameDuration: Int = 960
        /// Frames to buffer before starting playout, and the bounds the adaptive target
        /// stays within. Two frames is 40 ms, about the smallest that survives a LAN.
        public var minimumDepth: Int = 2
        public var maximumDepth: Int = 20
        /// Give up and re-prime after this many consecutive empty ticks, rather than
        /// concealing forever when a sender goes away.
        public var concealmentLimit: Int = 25   // 500 ms
        /// A frame this far beyond the playhead means the sender restarted; resynchronise
        /// instead of concealing across the whole gap.
        public var resyncDistance: Int32 = 200  // 4 s

        public init() {}
    }

    /// What to do with the next 20 ms of playout.
    public enum Step: Equatable
    {
        /// Decode this frame normally.
        case decode(VoiceFrame)
        /// The frame for this slot never arrived, but the next one did and carries in-band
        /// FEC for it. Decode `next` in FEC mode; it stays buffered for its own slot.
        case recoverFromFEC(next: VoiceFrame)
        /// Nothing to work with. Run packet loss concealment.
        case conceal
        /// Still filling up. Emit silence and do not advance playout.
        case priming
    }

    public let configuration: Configuration
    private let counters: VoiceCountersBox
    private let lock = NSLock()

    private var frames: [UInt32: VoiceFrame] = [:]
    private var playhead: UInt32?
    private var consecutiveConcealments = 0
    private var seenHighestSequence: UInt32?

    // Arrival-time jitter, in seconds, smoothed as in RFC 3550 §6.4.1.
    private var jitter: Double = 0
    private var lastArrival: (transit: Double, timestamp: UInt32)?

    public init(configuration: Configuration = Configuration(), counters: VoiceCountersBox = VoiceCountersBox())
    {
        self.configuration = configuration
        self.counters = counters
    }

    /// Frames currently buffered.
    public var depth: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    /// How many frames playout waits for before starting, derived from observed jitter.
    public var targetDepth: Int
    {
        lock.lock(); defer { lock.unlock() }
        return unsafeTargetDepth
    }

    private var unsafeTargetDepth: Int
    {
        let frameSeconds = Double(configuration.frameDuration) / 48000.0
        // Two frames of headroom over the jitter estimate: one for the frame in flight,
        // one so a single late arrival does not immediately underrun.
        let needed = Int((jitter / frameSeconds).rounded(.up)) + configuration.minimumDepth
        return min(max(needed, configuration.minimumDepth), configuration.maximumDepth)
    }

    /// Take a frame off the network. `arrival` is a monotonic time in seconds.
    public func insert(_ frame: VoiceFrame, arrival: Double)
    {
        lock.lock(); defer { lock.unlock() }

        updateJitter(for: frame, arrival: arrival)

        if let playhead
        {
            let distance = frame.sequence.sequenceDistance(from: playhead)
            if distance < 0
            {
                // Already played past this slot; a late frame is worthless.
                counters.update { $0.late += 1 }
                return
            }
            if distance > configuration.resyncDistance
            {
                // The sender restarted, or we were asleep. Start over from this frame.
                frames.removeAll()
                self.playhead = nil
                seenHighestSequence = nil
            }
        }

        guard frames[frame.sequence] == nil else
        {
            counters.update { $0.duplicate += 1 }
            return
        }

        if let highest = seenHighestSequence, !frame.sequence.isNewerSequence(than: highest)
        {
            counters.update { $0.reordered += 1 }
        }
        else
        {
            seenHighestSequence = frame.sequence
        }

        frames[frame.sequence] = frame

        // Overfull: the consumer is not draining (or stopped). Drop the oldest rather than
        // grow without bound.
        while frames.count > configuration.maximumDepth * 2, let oldest = frames.keys.min(by: { $1.isNewerSequence(than: $0) })
        {
            frames.removeValue(forKey: oldest)
            counters.update { $0.late += 1 }
        }
    }

    /// Decide what the next 20 ms of playout should be, and advance.
    public func nextStep(codecSupportsFEC: Bool) -> Step
    {
        lock.lock(); defer { lock.unlock() }

        guard let current = playhead else
        {
            guard frames.count >= unsafeTargetDepth,
                  let lowest = frames.keys.min(by: { $1.isNewerSequence(than: $0) })
            else { return .priming }
            playhead = lowest
            return advance(from: lowest, codecSupportsFEC: codecSupportsFEC)
        }
        return advance(from: current, codecSupportsFEC: codecSupportsFEC)
    }

    private func advance(from current: UInt32, codecSupportsFEC: Bool) -> Step
    {
        if let frame = frames.removeValue(forKey: current)
        {
            consecutiveConcealments = 0
            playhead = current &+ 1
            counters.update { $0.decoded += 1 }
            return .decode(frame)
        }

        if codecSupportsFEC, let next = frames[current &+ 1]
        {
            consecutiveConcealments = 0
            playhead = current &+ 1
            counters.update { $0.fecRecovered += 1 }
            return .recoverFromFEC(next: next)
        }

        consecutiveConcealments += 1
        counters.update { $0.concealed += 1 }
        if consecutiveConcealments >= configuration.concealmentLimit
        {
            // Nothing has arrived for a long time. Re-prime so playout restarts cleanly
            // rather than concealing indefinitely against a playhead that ran away.
            playhead = nil
            consecutiveConcealments = 0
            frames.removeAll()
            seenHighestSequence = nil
        }
        else
        {
            playhead = current &+ 1
        }
        return .conceal
    }

    private func updateJitter(for frame: VoiceFrame, arrival: Double)
    {
        let frameSeconds = Double(configuration.frameDuration) / 48000.0
        let sent = Double(frame.timestamp) / 48000.0
        let transit = arrival - sent
        if let last = lastArrival
        {
            let difference = abs(transit - last.transit)
            jitter += (difference - jitter) / 16.0
            // A jitter estimate above the resync window is noise, not signal.
            jitter = min(jitter, Double(configuration.maximumDepth) * frameSeconds)
        }
        lastArrival = (transit, frame.timestamp)
    }
}
