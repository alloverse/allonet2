//
//  DataChannelMediaStream.swift
//  allonet2
//

import Foundation
import Atomics
import Logging

/// A voice stream carried by one unreliable data channel.
///
/// The same implementation serves every role, because all three only ever touch frames:
/// a sending client encodes and writes, the server routes the bytes without decoding them,
/// and a receiving client feeds them through a jitter buffer into a ring buffer. No SDP, no
/// m-line, no renegotiation - the channel *is* the stream.
public final class DataChannelMediaStream: MediaStream, @unchecked Sendable
{
    public let mediaId: MediaStreamId
    public let streamDirection: MediaStreamDirection
    public let counters: VoiceCountersBox
    public let jitterBuffer: JitterBuffer

    /// Samples per frame. 20 ms at 48 kHz.
    public static let frameDuration = 960
    /// The one sample rate this path runs at, capture through playout.
    public static let sampleRate = 48000.0
    /// Largest message this stream will take off the wire: one frame of the most verbose kind
    /// the format has, uncompressed Float32. Opus at its maximum bitrate is a third of it.
    public static let maximumFrameBytes = frameDuration * MemoryLayout<Float>.size + VoiceFrame.headerSize

    private let sendFrame: (Data) -> Bool
    private let closeChannel: () -> Void
    private let monotonicNow: () -> Double
    private let observers = FrameObservers()
    private let lock = NSLock()
    private var logger = Logger(labelSuffix: "media.stream")

    private var encoder: (any VoiceEncoder)?
    private var nextSequence: UInt32 = 0
    private var nextTimestamp: UInt32 = 0

    private var ringBuffer: AudioRingBuffer?
    private var pump: DispatchSourceTimer?

    /// - Parameter sendFrame: writes one encoded frame to the underlying channel, returning
    ///   false when the channel is gone - which on an unreliable channel simply means the
    ///   frame is lost.
    /// - Parameter monotonicNow: seconds on a clock that only moves forward, used to measure
    ///   arrival jitter. Override it to drive the jitter buffer from a test's own clock.
    public init(
        mediaId: MediaStreamId,
        direction: MediaStreamDirection,
        counters: VoiceCountersBox = VoiceCountersBox(),
        jitterBuffer: JitterBuffer? = nil,
        monotonicNow: @escaping () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
        closeChannel: @escaping () -> Void = {},
        sendFrame: @escaping (Data) -> Bool
    )
    {
        self.mediaId = mediaId
        self.streamDirection = direction
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
        // Before the fan-out: every forwarder would re-emit an oversized frame, and every
        // jitter buffer downstream would hold on to it.
        guard data.count <= Self.maximumFrameBytes else
        {
            counters.update { $0.malformed += 1 }
            logger.debug("Dropped oversized voice frame: \(data.count) bytes")
            return
        }
        observers.emit(data)

        // The server routes without parsing; only a receiver needs the frame itself.
        lock.lock(); let receiving = ringBuffer != nil; lock.unlock()
        guard receiving else { return }
        do
        {
            let frame = try VoiceFrame(decoding: data)
            jitterBuffer.insert(frame, arrival: monotonicNow())
        }
        catch
        {
            counters.update { $0.malformed += 1 }
            logger.debug("Dropped unparseable voice frame: \(error)")
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
            let frame = VoiceFrame(kind: encoder.kind, sequence: sequence, timestamp: timestamp, payload: payload)
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
            logger.error("Failed to encode voice frame \(sequence): \(error)")
            counters.update { $0.sendFailed += 1 }
            return nil
        }
    }

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

        let ring = AudioRingBuffer(channels: 1, capacityFrames: Int(Self.sampleRate), canceller: { [weak self] in
            self?.stopPlayout()
        })
        ringBuffer = ring
        startPump(filling: ring)
        return ring
    }

    /// Decoded audio kept queued ahead of the device; refilling to a level self-clocks.
    /// See docs/voice-implementation.md, Playout is self-clocking.
    private static let targetBufferedFrames = frameDuration * 3

    private func startPump(filling ring: AudioRingBuffer)
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
            self.refill(ring, using: decoder)
        }
        pump = timer
        timer.resume()
    }

    /// Stop decoding and let go of the ring, so `render()` builds a new one rather than handing
    /// out the dead one. Arrived-at by cancelling the ring, which is how a player stops playout.
    private func stopPlayout()
    {
        lock.lock(); defer { lock.unlock() }
        pump?.cancel()
        pump = nil
        ringBuffer = nil
    }

    private func refill(_ ring: AudioRingBuffer, using decoder: any VoiceDecoder)
    {
        let frameCount = Self.frameDuration
        var scratch = [Float](repeating: 0, count: frameCount)

        while ring.availableToRead() < Self.targetBufferedFrames, ring.availableToWrite() >= frameCount
        {
            let step = jitterBuffer.nextStep(codecSupportsFEC: decoder.supportsFEC)
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
                logger.error("Failed to decode voice frame: \(error)")
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
