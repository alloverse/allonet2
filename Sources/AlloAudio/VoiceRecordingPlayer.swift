//
//  VoiceRecordingPlayer.swift
//  AlloAudio
//

import Foundation
import Logging
import allonet2

/// Sends recordings into voice streams from one 20 ms clock, so that several recordings stay in
/// step with each other for as long as the player runs.
///
/// Each tick works out how many frames are due since `start()` from elapsed monotonic time, and
/// sends every recording the frames it still owes, in that same tick. A late tick therefore
/// catches up instead of slowing the room down, and a tick later than `maximumCatchUp` frames
/// drops the excess rather than bursting it at a receiver whose jitter buffer would discard it.
///
/// Thread-safe. The player owns the recordings it is given and pulls frames on its own queue,
/// which is the one queue a `VoiceRecording` may be used from.
///
/// A voice codec must be installed before `start()` (`Opus.install()` from AlloOpus, which a
/// `VoiceEngine` also does); without one every frame is refused and the stream logs why.
public final class VoiceRecordingPlayer
{
    /// Frames one tick may send per recording. Past this the backlog is dropped: it is audio
    /// whose moment has gone, and a burst is discarded at the far end regardless.
    public static let maximumCatchUp = 5

    /// Called on the player's own queue for every frame that reached the wire, with the sequence
    /// `DataChannelMediaStream.send(samples:frameCount:)` gave it. For measuring latency; leave
    /// it nil otherwise. Set it before `start()`, and do not call `start()` or `stop()` from it:
    /// both wait for the queue the callback runs on.
    public var onFrameSent: ((DataChannelMediaStream, UInt32, Date) -> Void)?

    private static let frameInterval = Double(VoiceRecording.frameCount) / DataChannelMediaStream.sampleRate

    private let queue = DispatchQueue(label: "allonet2.voicerecordingplayer")
    private let monotonicNow: () -> Double
    private var voices: [(recording: VoiceRecording, stream: DataChannelMediaStream)] = []
    private var timer: DispatchSourceTimer?
    private var startedAt: Double?
    private var framesSent = 0
    private let logger = Logger(labelSuffix: "voice.recordings")

    /// - Parameter monotonicNow: seconds on a clock that only moves forward. Override it to drive
    ///   the player from a test's own clock.
    public init(monotonicNow: @escaping () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 })
    {
        self.monotonicNow = monotonicNow
    }

    deinit { timer?.cancel() }

    /// Play `recording` into `stream` until the player stops or the recording fails to decode.
    /// The player takes the recording over: do not pull frames from it anywhere else.
    ///
    /// Added before `start()`, a recording begins at its first frame together with every other.
    /// Added while the player runs, it joins on the next tick and is in step from there.
    public func add(_ recording: VoiceRecording, to stream: DataChannelMediaStream)
    {
        queue.async { self.voices.append((recording, stream)) }
    }

    /// Start the clock and send frames until `stop()`. The first frame of every recording goes
    /// out before this returns, so playback begins on the caller's word rather than up to 20 ms
    /// later. Starting a running player does nothing; starting a stopped one restarts the clock,
    /// and each recording carries on from the frame it had reached.
    public func start()
    {
        queue.sync {
            guard timer == nil else { return }
            startedAt = monotonicNow()
            framesSent = 0
            pump()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stop sending. Idempotent, and safe from any thread; a frame already on its way out of the
    /// player's queue finishes first.
    public func stop()
    {
        queue.sync {
            timer?.cancel()
            timer = nil
            startedAt = nil
        }
    }

    /// One pass of the clock, from the caller's thread. Internal so a test can pump the player
    /// on its own clock rather than waiting out real time.
    func tick() { queue.sync { pump() } }

    private func pump()
    {
        guard let startedAt else { return }
        // +1 so the first tick, at zero elapsed, sends the frame that plays now.
        let due = Int((monotonicNow() - startedAt) / Self.frameInterval) + 1
        guard due > framesSent else { return }
        let sending = min(due - framesSent, Self.maximumCatchUp)
        framesSent = due
        for _ in 0..<sending
        {
            // A recording that stops decoding is dropped, once and loudly, rather than failing
            // again on every later tick.
            voices.removeAll { !send(from: $0.recording, to: $0.stream) }
        }
    }

    /// - Returns: false when the recording failed and must be dropped.
    private func send(from recording: VoiceRecording, to stream: DataChannelMediaStream) -> Bool
    {
        do
        {
            let frame = try recording.nextFrame()
            let at = Date()
            if let sequence = stream.send(samples: frame.baseAddress!, frameCount: frame.count)
            {
                onFrameSent?(stream, sequence, at)
            }
            return true
        }
        catch
        {
            logger.error("Stopped playing \(recording.url.path) into \(stream.mediaId): \(error)")
            return false
        }
    }
}
