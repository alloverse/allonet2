//
//  VoiceCounters.swift
//  allonet2
//

import Foundation

/// Per-hop tallies for one voice stream, as data rather than log lines: a test asserts on
/// them, and the server exposes them over its status endpoint.
///
/// The accounting invariants they satisfy: docs/voice.md, Counters.
public struct VoiceCounters: Equatable, Sendable, Codable, CustomStringConvertible
{
    // Sender
    /// 20 ms blocks the microphone handed over.
    public var captured = 0
    /// Captured blocks the codec turned into a payload.
    public var encoded = 0
    /// Encoded frames the channel accepted.
    public var sent = 0
    /// Frames lost before the wire: no codec, encode threw, or the channel refused them.
    public var sendFailed = 0

    // Server
    /// Frames the SFU took off a sender's channel to route.
    public var forwardedIn = 0
    /// Copies the SFU wrote to a receiver's channel.
    public var forwardedOut = 0
    /// Copies a receiver's channel refused.
    public var forwardDropped = 0

    // Receiver
    /// Messages that arrived on the channel, parsed or not.
    public var received = 0
    /// Received messages that would not decode as a `VoiceFrame`.
    public var malformed = 0
    /// Arrived after their playout slot had already been played.
    public var late = 0
    /// Dropped because the buffer was full - nothing is draining playout, which calls for the
    /// opposite fix from `late`.
    public var overflowed = 0
    /// Arrived for a slot already holding a frame.
    public var duplicate = 0
    /// Arrived out of sequence, but still in time to play.
    public var reordered = 0
    /// Frames the jitter buffer handed to the decoder.
    public var decoded = 0
    /// Slots reconstructed from the following frame's in-band FEC.
    public var fecRecovered = 0
    /// Slots with nothing to decode, filled by the codec's loss concealment.
    public var concealed = 0
    /// 20 ms blocks written into the playout ring buffer.
    public var played = 0

    /// Loudest sample seen since the last reset, 0...1. Zero with frames flowing means the
    /// audio is silent: a muted or unpermitted microphone, or playout that never got samples.
    public var capturedPeak: Float = 0
    public var playedPeak: Float = 0

    public init() {}

    public mutating func resetPeaks() { capturedPeak = 0; playedPeak = 0 }

    public var description: String
    {
        var parts: [String] = []
        func add(_ name: String, _ value: Int) { if value != 0 { parts.append("\(name)=\(value)") } }
        add("captured", captured); add("encoded", encoded); add("sent", sent); add("sendFailed", sendFailed)
        add("in", forwardedIn); add("out", forwardedOut); add("fwdDropped", forwardDropped)
        add("received", received); add("malformed", malformed); add("late", late)
        add("overflowed", overflowed)
        add("dup", duplicate); add("reordered", reordered); add("decoded", decoded)
        add("fec", fecRecovered); add("concealed", concealed); add("played", played)
        if capturedPeak > 0 { parts.append(String(format: "capPeak=%.2f", capturedPeak)) }
        if playedPeak > 0 { parts.append(String(format: "playPeak=%.2f", playedPeak)) }
        return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
    }
}

/// Thread-safe holder. Counters are written from the capture thread, libdatachannel's
/// network threads and the playout pump, and read from anywhere.
public final class VoiceCountersBox: @unchecked Sendable
{
    private let lock = NSLock()
    private var counters = VoiceCounters()

    public init() {}

    public func update(_ change: (inout VoiceCounters) -> Void)
    {
        lock.lock(); defer { lock.unlock() }
        change(&counters)
    }

    public var snapshot: VoiceCounters
    {
        lock.lock(); defer { lock.unlock() }
        return counters
    }
}
