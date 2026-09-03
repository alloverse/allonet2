//
//  DataChannelMediaStream.swift
//  allonet2
//

import Foundation
import Atomics
import Logging

/// One media stream carried by one data channel.
///
/// The same implementation serves every role, because all three only ever touch frames:
/// a sending client encodes and writes, the server routes the bytes without decoding them,
/// and a receiving client feeds them through a jitter buffer into a ring buffer. No SDP, no
/// m-line, no renegotiation - the channel *is* the stream.
public final class DataChannelMediaStream: MediaStream, @unchecked Sendable
{
    public let mediaId: MediaStreamId
    public let streamDirection: MediaStreamDirection
    public let kind: MediaStreamKind
    public let counters: VoiceCountersBox
    public let jitterBuffer: JitterBuffer

    /// Samples per frame. 20 ms at 48 kHz.
    public static let frameDuration = 960
    /// The one sample rate this path runs at, capture through playout.
    public static let sampleRate = 48000.0

    private let sendFrame: (Data) -> Bool
    private let closeChannel: () -> Void
    private let bufferedAmount: () -> Int
    private let monotonicNow: () -> Double
    private let observers = FrameObservers()
    private let lock = NSLock()
    private var logger = Logger(labelSuffix: "media.stream")

    private var encoder: (any VoiceEncoder)?
    private var nextSequence: UInt32 = 0
    private var nextTimestamp: UInt32 = 0

    private var ringBuffer: AudioRingBuffer?
    private var pump: DispatchSourceTimer?

    /// - Parameter kind: what the stream carries. Must match the kind in the underlying
    ///   channel's label, which is where every peer reads it from.
    /// - Parameter sendFrame: writes one encoded frame to the underlying channel, returning
    ///   false when the channel is gone - which on an unreliable channel simply means the
    ///   frame is lost.
    /// - Parameter monotonicNow: seconds on a clock that only moves forward, used to measure
    ///   arrival jitter. Override it to drive the jitter buffer from a test's own clock.
    /// - Parameter bufferedAmount: bytes `sendFrame` has taken but the transport has not yet put
    ///   on the wire; see `bufferedBytes`. The default reports a stream with nothing behind it.
    public init(
        mediaId: MediaStreamId,
        direction: MediaStreamDirection,
        kind: MediaStreamKind = .voice,
        counters: VoiceCountersBox = VoiceCountersBox(),
        jitterBuffer: JitterBuffer? = nil,
        monotonicNow: @escaping () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
        closeChannel: @escaping () -> Void = {},
        bufferedAmount: @escaping () -> Int = { 0 },
        sendFrame: @escaping (Data) -> Bool
    )
    {
        self.bufferedAmount = bufferedAmount
        self.mediaId = mediaId
        self.streamDirection = direction
        self.kind = kind
        self.counters = counters
        self.jitterBuffer = jitterBuffer ?? JitterBuffer(counters: counters)
        self.monotonicNow = monotonicNow
        self.closeChannel = closeChannel
        self.sendFrame = sendFrame
        self.logger[metadataKey: "mediaId"] = .string(mediaId)
    }

    deinit { pump?.cancel() }

    /// Close the channel under this stream. The far side sees the channel go, which is how
    /// a receiver learns that a stream has ended.
    public func close()
    {
        stopPlayout()
        closeChannel()
    }

    // MARK: - Receiving

    /// Hand a message off the channel to this stream. Called on libdatachannel's network
    /// thread.
    public func deliver(_ data: Data)
    {
        counters.update { $0.received += 1 }
        // Header only, so this costs no allocation on the SFU's path, which never parses the
        // payload at all. Both checks precede the fan-out: every forwarder would re-emit a frame
        // that failed them, and every jitter buffer downstream would hold on to it.
        let kind: MediaFrame.Kind
        do { kind = try MediaFrame.validateHeader(data) }
        catch
        {
            counters.update { $0.malformed += 1 }
            logger.debug("Dropped media frame with invalid header: \(error)")
            return
        }
        guard data.count <= kind.maximumFrameBytes else
        {
            counters.update { $0.malformed += 1 }
            logger.debug("Dropped oversized \(kind) frame: \(data.count) bytes, cap \(kind.maximumFrameBytes)")
            return
        }
        observers.emit(data)

        // The server routes without parsing; only a receiver needs the frame itself.
        lock.lock(); let playout = ringBuffer != nil ? playoutGeneration : nil; lock.unlock()
        guard let playout else { return }
        // A video frame on a stream someone is rendering as audio is well-formed and was
        // forwarded; there is simply no decoder for it on this path.
        guard !kind.isVideo else
        {
            counters.update { $0.skippedForeignKind += 1 }
            return
        }
        do
        {
            let frame = try MediaFrame(decoding: data)
            let arrival = monotonicNow()
            lock.lock(); defer { lock.unlock() }
            // Playout stopped while this frame was in flight, so its slot went with it. The
            // reset left nothing to judge it by, and inserting it now would prime the
            // replacement on pre-stop audio.
            guard ringBuffer != nil, playout == playoutGeneration else
            {
                counters.update { $0.late += 1 }
                return
            }
            jitterBuffer.insert(frame, arrival: arrival)
        }
        catch
        {
            counters.update { $0.malformed += 1 }
            logger.debug("Dropped unparseable media frame: \(error)")
        }
    }

    /// Observe raw frames as they arrive, without decoding them. This is how the server
    /// forwards: one observer per receiving client.
    @discardableResult
    public func observeFrames(_ observer: @escaping (Data) -> Void) -> FrameObservers.Token
    {
        observers.add(observer)
    }

    /// Stop delivering frames to the observer behind `token`. Safe from any thread,
    /// including from inside an observer.
    public func removeObserver(_ token: FrameObservers.Token) { observers.remove(token) }

    // MARK: - Sending

    /// Encode and send 20 ms of mono audio. Returns the sequence the frame went out as, or
    /// nil if it could not be sent - which on an unreliable channel means it is simply gone.
    @discardableResult
    public func send(samples: UnsafePointer<Float>, frameCount: Int) -> UInt32?
    {
        let peak = Self.peak(of: samples, count: frameCount)
        // One Opus encoder and one sequence, so the whole frame is one critical section:
        // two callers interleaving would corrupt the codec's state, not just the numbering.
        lock.lock(); defer { lock.unlock() }
        counters.update { $0.captured += 1; $0.capturedPeak = max($0.capturedPeak, peak) }
        if encoder == nil
        {
            guard let make = VoiceCodecs.makeEncoder else
            {
                logger.error("Cannot send voice: \(VoiceCodecError.noCodecInstalled)")
                counters.update { $0.sendFailed += 1 }
                return nil
            }
            do { encoder = try make() }
            catch
            {
                logger.error("Cannot create voice encoder: \(error)")
                counters.update { $0.sendFailed += 1 }
                return nil
            }
        }
        let encoder = self.encoder!
        let sequence = nextSequence
        let timestamp = nextTimestamp
        nextSequence &+= 1
        nextTimestamp &+= UInt32(frameCount)

        do
        {
            let payload = try encoder.encode(samples, frameCount: frameCount)
            counters.update { $0.encoded += 1 }
            let frame = MediaFrame(kind: encoder.kind, sequence: sequence, timestamp: timestamp, payload: payload)
            guard sendFrame(frame.encoded) else
            {
                counters.update { $0.sendFailed += 1 }
                return nil
            }
            counters.update { $0.sent += 1 }
            return sequence
        }
        catch
        {
            logger.error("Failed to encode media frame \(sequence): \(error)")
            counters.update { $0.sendFailed += 1 }
            return nil
        }
    }

    /// Bytes this stream has handed to its channel that are still queued for the wire. `send` and
    /// `forward` never block and never report congestion, so this is the only sign that a sender
    /// is outrunning the link: a video sender reads it before every encode and spends less
    /// bitrate when it climbs. Zero on a stream with no channel under it.
    public var bufferedBytes: Int { bufferedAmount() }

    /// Send an already-encoded frame verbatim. The server's forwarding path: the bytes are
    /// opaque, so nothing is decoded, re-encoded or renumbered.
    @discardableResult
    public func forward(_ frame: Data) -> Bool
    {
        guard sendFrame(frame) else
        {
            counters.update { $0.forwardDropped += 1 }
            return false
        }
        counters.update { $0.forwardedOut += 1 }
        return true
    }

    // MARK: - Playout

    /// The seam the rest of the app already renders from. Starts decoding on first call, and
    /// again after the ring it handed out was cancelled: a stream can be played, stopped and
    /// played again.
    public func render() -> AudioRingBuffer
    {
        lock.lock(); defer { lock.unlock() }
        if let ringBuffer { return ringBuffer }

        playoutGeneration &+= 1
        let generation = playoutGeneration
        let ring = AudioRingBuffer(channels: 1, capacityFrames: Int(Self.sampleRate), canceller: { [weak self] in
            self?.stopPlayout(generation: generation)
        })
        // Both describe the old ring; left stale, notePlayout can report a frame this ring
        // never wrote as freshly played before its pump has decoded anything.
        playoutMark.store(0, ordering: .relaxed)
        lastPlayedFrame.store(0, ordering: .relaxed)
        ringBuffer = ring
        startPump(filling: ring, generation: generation)
        return ring
    }

    /// Which playout a ring belongs to. Whoever held a ring cancels it whenever they get round
    /// to it, which can be after playout has been restarted on a new one.
    private var playoutGeneration = 0

    /// Decoded audio kept queued ahead of the device, in frames: refilling to a level
    /// self-clocks, and now that the pump waits rather than concealing over it, it is jitter
    /// tolerance too. See docs/voice-implementation.md, Playout is self-clocking.
    public static let ringCushionFrames = 2
    private static let ringCushionSamples = frameDuration * ringCushionFrames

    private func startPump(filling ring: AudioRingBuffer, generation: Int)
    {
        guard let makeDecoder = VoiceCodecs.makeDecoder else
        {
            logger.error("Cannot play voice: \(VoiceCodecError.noCodecInstalled)")
            return
        }
        let decoder: any VoiceDecoder
        do { decoder = try makeDecoder() }
        catch
        {
            logger.error("Cannot create voice decoder: \(error)")
            return
        }

        let queue = DispatchQueue(label: "allonet2.voice.playout.\(mediaId)", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Half a frame: often enough that the ring never runs dry between refills.
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak ring] in
            guard let self, let ring else { return }
            self.refill(ring, using: decoder, generation: generation)
        }
        pump = timer
        timer.resume()
    }

    /// Stop decoding and let go of the ring, so `render()` builds a new one rather than handing
    /// out the dead one. Arrived-at by cancelling the ring, which is how a player stops playout.
    ///
    /// - Parameter generation: the playout being stopped, or nil to stop whatever is running.
    ///   A ring cancelled after playout already restarted names the generation that is over, and
    ///   must leave its replacement alone.
    private func stopPlayout(generation: Int? = nil)
    {
        lock.lock(); defer { lock.unlock() }
        if let generation, generation != playoutGeneration { return }
        pump?.cancel()
        pump = nil
        ringBuffer = nil
        // Nothing arrives while stopped, so whatever is left is as stale as the pause is long.
        jitterBuffer.reset()
    }

    /// One pump tick: move whole frames from the jitter buffer into the ring until the ring is
    /// back at its cushion. Internal so a test can step it without a timer.
    ///
    /// - Parameter generation: the playout this pump belongs to, or nil when no pump drives it.
    ///   `cancel()` does not drain the queue, so a tick already running when its pump was stopped
    ///   would go on taking frames the replacement pump is priming from, into a ring nobody reads.
    func refill(_ ring: AudioRingBuffer, using decoder: any VoiceDecoder, generation: Int? = nil)
    {
        steerPlayoutRate(ring, generation: generation)
        let frameCount = Self.frameDuration
        // Read before the critical section below; nothing the decoder does belongs under the lock.
        let supportsFEC = decoder.supportsFEC
        var scratch = [Float](repeating: 0, count: frameCount)

        while ring.availableToRead() < Self.ringCushionSamples, ring.availableToWrite() >= frameCount
        {
            let ringCanCoverTheSlot = ring.availableToRead() >= frameCount

            // One critical section: a check this tick could be suspended after is no check at
            // all, because the frame it then takes belongs to the playout that replaced it.
            lock.lock()
            if let generation, generation != playoutGeneration { lock.unlock(); return }
            // Concealment is for an imminent underrun, not for a slot the ring can still cover:
            // waiting a tick lets a merely late frame arrive and play in its own slot.
            if ringCanCoverTheSlot, jitterBuffer.wouldConceal(codecSupportsFEC: supportsFEC)
            {
                lock.unlock()
                return
            }
            let step = jitterBuffer.nextStep(codecSupportsFEC: supportsFEC)
            lock.unlock()

            // Priming: leave the ring empty; its underrun path already emits silence.
            if step == .priming { return }

            let written: Int
            do
            {
                written = try scratch.withUnsafeMutableBufferPointer { output -> Int in
                    switch step
                    {
                    case .decode(let frame):
                        return try decoder.decode(frame.payload, fec: false, into: output.baseAddress!, capacity: frameCount)
                    case .recoverFromFEC(let next):
                        return try decoder.decode(next.payload, fec: true, into: output.baseAddress!, capacity: frameCount)
                    case .conceal:
                        return try decoder.decode(nil, fec: false, into: output.baseAddress!, capacity: frameCount)
                    case .priming:
                        return 0
                    }
                }
            }
            catch
            {
                logger.error("Failed to decode media frame: \(error)")
                return
            }

            guard written > 0 else { return }
            let peak = scratch.withUnsafeBufferPointer { Self.peak(of: $0.baseAddress!, count: written) }
            scratch.withUnsafeMutableBufferPointer { buffer in
                var channel = buffer.baseAddress!
                withUnsafeMutablePointer(to: &channel) { channels in
                    ring.writeDeinterleaved(source: channels, frames: written)
                }
            }
            counters.update { $0.played += 1; $0.playedPeak = max($0.playedPeak, peak) }

            let playedSequence: UInt32? = switch step
            {
            case .decode(let frame): frame.sequence
            case .recoverFromFEC(let next): next.sequence &- 1   // FEC fills the slot before it
            case .conceal, .priming: nil                         // no frame to name; see PlayoutMark
            }
            if let playedSequence
            {
                playoutMark.store(PlayoutMark(framesWritten: UInt32(truncatingIfNeeded: ring.framesWritten),
                                              sequence: playedSequence).bits, ordering: .relaxed)
            }
        }
    }

    // MARK: - Depth

    private let playoutRateBits = ManagedAtomic<UInt32>(Float(1).bitPattern)
    private var rateController = PlayoutRateController()
    private var lastRateUpdate: Double?

    /// Everything queued for this stream, in 20 ms frames: the jitter buffer's frames plus the
    /// ring buffer's samples. One number, because with the pump waiting instead of concealing
    /// the two are one queue, and the whole queue is what absorbs jitter - and what is latency.
    public var bufferedFrames: Float
    {
        lock.lock(); let ring = ringBuffer; lock.unlock()
        return depth(with: ring)
    }

    /// The depth `bufferedFrames` is steered to: what observed jitter says playout needs
    /// queued, wherever in the queue it happens to sit.
    public var targetFrames: Float { Float(jitterBuffer.targetDepth) }

    /// How fast playout should run to reach `targetFrames`: 1 is the sender's clock, 1.02 plays
    /// 2 % fast. `VoiceEngine` feeds it to the rate node in front of the spatialiser. Lock-free,
    /// so the caller applying it need not be on any particular thread.
    public var playoutRate: Float { Float(bitPattern: playoutRateBits.load(ordering: .relaxed)) }

    private func depth(with ring: AudioRingBuffer?) -> Float
    {
        Float(jitterBuffer.depth) + Float(ring?.availableToRead() ?? 0) / Float(Self.frameDuration)
    }

    /// Update the rate from the depth this tick sees. A stream that was stopped and played again
    /// has a new pump while the old one may still have a tick in flight, so the controller is
    /// locked rather than owned by one queue; the depths and the clock are read outside it.
    ///
    /// - Parameter generation: as `refill`. A tick the stop left behind measures the depth of a
    ///   ring nobody reads, and the controller it would move belongs to the playout that
    ///   replaced it, so it must not steer any more than it may dequeue.
    private func steerPlayoutRate(_ ring: AudioRingBuffer, generation: Int?)
    {
        let error = depth(with: ring) - targetFrames
        let now = monotonicNow()
        lock.lock()
        if let generation, generation != playoutGeneration { lock.unlock(); return }
        let dt = lastRateUpdate.map { now - $0 } ?? 0
        lastRateUpdate = now
        let rate = rateController.update(error: error, dt: dt)
        lock.unlock()
        playoutRateBits.store(rate.bitPattern, ordering: .relaxed)
        if rate != 1 { counters.update { $0.rateAdjusted += 1 } }
    }

    // MARK: - Latency

    private let playoutMark = ManagedAtomic<UInt64>(0)
    private let lastPlayedFrame = ManagedAtomic<UInt64>(0)

    /// Record which frame's samples are about to reach the audio device. Call from the render
    /// callback *before* reading the ring: two atomic loads and a store, no lock, no allocation.
    public func notePlayout(of ring: AudioRingBuffer)
    {
        guard let mark = PlayoutMark(bits: playoutMark.load(ordering: .relaxed)),
              let sequence = mark.sequence(atReadHead: ring.framesRead, frameDuration: Self.frameDuration)
        else { return }
        lastPlayedFrame.store(UInt64(sequence) << 32 | UInt64(Self.uptimeMilliseconds), ordering: .relaxed)
    }

    /// The last frame handed to the audio device, and when: the far end of a mouth-to-speaker
    /// measurement. Nil until playout has rendered a frame it can name.
    public var lastPlayed: (sequence: UInt32, at: Date)?
    {
        let bits = lastPlayedFrame.load(ordering: .relaxed)
        guard bits != 0 else { return nil }
        let age = Double(Self.uptimeMilliseconds &- UInt32(truncatingIfNeeded: bits)) / 1000
        return (UInt32(truncatingIfNeeded: bits >> 32), Date(timeIntervalSinceNow: -age))
    }

    /// Milliseconds since boot, in 32 bits so a timestamp and a sequence share one atomic
    /// word. Wraps after 49 days; only differences of a few hundred ms are ever taken.
    private static var uptimeMilliseconds: UInt32
    {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private static func peak(of samples: UnsafePointer<Float>, count: Int) -> Float
    {
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(samples[i])) }
        return peak
    }
}

/// Where playout has got to in the ring buffer: the frame whose last sample sits at
/// `framesWritten`.
///
/// Every playout step writes exactly one frame duration - decode, FEC recovery and
/// concealment alike - so one anchor resolves the frame at any read position by arithmetic,
/// including across concealed slots that have no frame to name. The whole map is therefore a
/// single atomic word, which is what lets the audio render thread read it.
struct PlayoutMark: Equatable
{
    let framesWritten: UInt32
    let sequence: UInt32

    init(framesWritten: UInt32, sequence: UInt32)
    {
        self.framesWritten = framesWritten
        self.sequence = sequence
    }

    init?(bits: UInt64)
    {
        guard bits != 0 else { return nil }   // nothing written yet
        self.init(framesWritten: UInt32(truncatingIfNeeded: bits >> 32), sequence: UInt32(truncatingIfNeeded: bits))
    }

    var bits: UInt64 { UInt64(framesWritten) << 32 | UInt64(sequence) }

    /// The frame whose samples sit at absolute read position `framesRead`, or nil once the
    /// consumer has drained past the mark and there is nothing left to play.
    func sequence(atReadHead framesRead: Int, frameDuration: Int) -> UInt32?
    {
        let behind = framesWritten &- UInt32(truncatingIfNeeded: framesRead)
        guard behind > 0, behind < UInt32.max / 2 else { return nil }
        return sequence &- (behind - 1) / UInt32(frameDuration)
    }
}

/// Locked multicast for raw frames. `@Published` is not usable here: subscribing races
/// libdatachannel delivering on its own thread, and a lost first frame is a lost stream.
public final class FrameObservers: @unchecked Sendable
{
    public struct Token: Hashable, Sendable { fileprivate let id: UUID }

    private let lock = NSLock()
    private var observers: [Token: (Data) -> Void] = [:]

    public init() {}

    /// Start delivering every emitted frame to `observer`, until the returned token is removed.
    public func add(_ observer: @escaping (Data) -> Void) -> Token
    {
        let token = Token(id: UUID())
        lock.lock(); observers[token] = observer; lock.unlock()
        return token
    }

    /// Stop delivering to the observer behind `token`. Safe from inside an observer.
    public func remove(_ token: Token)
    {
        lock.lock(); observers[token] = nil; lock.unlock()
    }

    /// Deliver `data` to every current observer. Observers are called outside the lock, so
    /// one may remove itself or take other locks.
    public func emit(_ data: Data)
    {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        // Emit outside the lock: observers take other locks, or remove themselves.
        for observer in current { observer(data) }
    }
}
