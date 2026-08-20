//
//  VoiceCounters.swift
//  allonet2
//

import Foundation

/// Per-hop tallies for one voice stream, as data rather than log lines: a test asserts on
/// them, and the server exposes them over its status endpoint.
///
/// Every frame that leaves a hop must be accounted for at the next one. On the receiving
/// side, once playout has started, every received frame is eventually `decoded`, or
/// dropped as `late`, `duplicate`, `malformed` or `overflowed` - anything unaccounted for is
/// still sitting in the jitter buffer. Every 20 ms of playout is exactly one of `decoded`,
/// `fecRecovered` or `concealed`.
public struct VoiceCounters: Equatable, Sendable, Codable, CustomStringConvertible
{
    // Sender
    public var captured = 0
    public var encoded = 0
    public var sent = 0
    public var sendFailed = 0

    // Server
    public var forwardedIn = 0
    public var forwardedOut = 0
    public var forwardDropped = 0

    // Receiver
    public var received = 0
    public var malformed = 0
    public var late = 0
    /// Dropped because the buffer was full - the consumer is not draining, which is a
    /// different fault from a frame arriving after its slot played.
    public var overflowed = 0
    public var duplicate = 0
    public var reordered = 0
    public var decoded = 0
    public var fecRecovered = 0
    public var concealed = 0
    public var played = 0

    public init() {}

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
