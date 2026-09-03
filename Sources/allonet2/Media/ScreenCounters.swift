//
//  ScreenCounters.swift
//  allonet2
//

import Foundation

/// Per-hop tallies for one screen stream, as data rather than log lines: a test asserts on them,
/// and a demo or a status page prints them. The audio counterpart is `VoiceCounters`.
///
/// On a sender every `captured` picture ends up exactly one of `encoded` (then `sent` or
/// `sendFailed`) or `droppedForBackpressure`. On a receiver every `received` message ends up
/// exactly one of `decoded`, `malformed` or `droppedAwaitingKey`.
///
/// Platform-neutral so the place can count video without linking a codec.
public struct ScreenCounters: Equatable, Sendable, Codable, CustomStringConvertible
{
    // Sender
    /// Pictures the source handed over.
    public var captured = 0
    /// Pictures the encoder turned into an access unit; it drops some under load.
    public var encoded = 0
    /// Access units the channel accepted.
    public var sent = 0
    /// Access units lost before the wire: over their kind's cap, or the channel refused them.
    public var sendFailed = 0
    /// Payload bytes handed to the channel, header excluded. Differenced over time, this is the
    /// stream's actual bitrate.
    public var bytesSent = 0
    /// Pictures skipped without encoding because the channel was still draining the last ones.
    public var droppedForBackpressure = 0
    /// Keyframes sent, whether periodic or asked for.
    public var keyframesSent = 0

    // Receiver
    /// Messages that arrived on the channel, parsed or not.
    public var received = 0
    /// Messages that would not parse, were not video, or that the decoder refused.
    public var malformed = 0
    /// Keyframes received.
    public var keyframes = 0
    /// Deltas dropped because no keyframe has arrived yet, so there is nothing to predict from.
    public var droppedAwaitingKey = 0
    /// Jumps in the sequence: frames the wire lost or the sender dropped.
    public var gaps = 0
    /// Frames turned into a displayable sample.
    public var decoded = 0
    /// Samples the owner put on screen. Counted by whoever owns the display, not by the receiver.
    public var displayed = 0

    public init() {}

    public var description: String
    {
        var parts: [String] = []
        func add(_ name: String, _ value: Int) { if value != 0 { parts.append("\(name)=\(value)") } }
        add("captured", captured); add("encoded", encoded); add("sent", sent)
        add("sendFailed", sendFailed); add("bytesSent", bytesSent)
        add("backpressureDropped", droppedForBackpressure); add("keyframesSent", keyframesSent)
        add("received", received); add("malformed", malformed); add("keyframes", keyframes)
        add("awaitingKey", droppedAwaitingKey); add("gaps", gaps)
        add("decoded", decoded); add("displayed", displayed)
        return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
    }
}

/// Thread-safe holder, the same shape as `VoiceCountersBox`: counters are written from the
/// capture source, the encoder's queue and libdatachannel's network threads, and read anywhere.
public final class ScreenCountersBox: @unchecked Sendable
{
    private let lock = NSLock()
    private var counters = ScreenCounters()

    public init() {}

    public func update(_ change: (inout ScreenCounters) -> Void)
    {
        lock.lock(); defer { lock.unlock() }
        change(&counters)
    }

    public var snapshot: ScreenCounters
    {
        lock.lock(); defer { lock.unlock() }
        return counters
    }
}
