//
//  DataChannelMediaStream.swift
//  allonet2
//

import Foundation
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
    public static let sampleRate = 48000.0

    private let sendFrame: (Data) -> Bool
    private let monotonicNow: () -> Double
    private let observers = FrameObservers()
    private let lock = NSLock()
    private var logger = Logger(labelSuffix: "media.stream")

    private var encoder: (any VoiceEncoder)?
    private var nextSequence: UInt32 = 0
    private var nextTimestamp: UInt32 = 0

    private var ringBuffer: AudioRingBuffer?
    private var pump: DispatchSourceTimer?

    public init(
        mediaId: MediaStreamId,
        direction: MediaStreamDirection,
        counters: VoiceCountersBox = VoiceCountersBox(),
        jitterBuffer: JitterBuffer? = nil,
        monotonicNow: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate },
        sendFrame: @escaping (Data) -> Bool
    )
    {
        self.mediaId = mediaId
        self.streamDirection = direction
        self.counters = counters
        self.jitterBuffer = jitterBuffer ?? JitterBuffer(counters: counters)
        self.monotonicNow = monotonicNow
        self.sendFrame = sendFrame
        self.logger[metadataKey: "mediaId"] = .string(mediaId)
    }

    // MARK: - Receiving

    /// Hand a message off the channel to this stream. Called on libdatachannel's network
    /// thread.
    public func deliver(_ data: Data)
    {
        counters.update { $0.received += 1 }
        observers.emit(data)

        // The server routes without parsing; only a receiver needs the frame itself.
        guard ringBuffer != nil else { return }
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

    public func removeObserver(_ token: FrameObservers.Token) { observers.remove(token) }

    // MARK: - Sending

    /// Encode and send 20 ms of mono audio. Returns false if the frame could not be sent,
    /// which on an unreliable channel means it is simply gone.
    @discardableResult
    public func send(samples: UnsafePointer<Float>, frameCount: Int) -> Bool
    {
        lock.lock()
        counters.update { $0.captured += 1 }
        if encoder == nil
        {
            guard let make = VoiceCodecs.makeEncoder else
            {
                lock.unlock()
                logger.error("Cannot send voice: \(VoiceCodecError.noCodecInstalled)")
                counters.update { $0.sendFailed += 1 }
                return false
            }
            do { encoder = try make() }
            catch
            {
                lock.unlock()
                logger.error("Cannot create voice encoder: \(error)")
                counters.update { $0.sendFailed += 1 }
                return false
            }
        }
        let encoder = self.encoder!
        let sequence = nextSequence
        let timestamp = nextTimestamp
        nextSequence &+= 1
        nextTimestamp &+= UInt32(frameCount)
        lock.unlock()

        do
        {
            let payload = try encoder.encode(samples, frameCount: frameCount)
            counters.update { $0.encoded += 1 }
            let frame = VoiceFrame(kind: encoder.kind, sequence: sequence, timestamp: timestamp, payload: payload)
            guard sendFrame(frame.encoded) else
            {
                counters.update { $0.sendFailed += 1 }
                return false
            }
            counters.update { $0.sent += 1 }
            return true
        }
        catch
        {
            logger.error("Failed to encode voice frame \(sequence): \(error)")
            counters.update { $0.sendFailed += 1 }
            return false
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

    /// The seam the rest of the app already renders from. Starts decoding on first call.
    public func render() -> AudioRingBuffer
    {
        lock.lock(); defer { lock.unlock() }
        if let ringBuffer { return ringBuffer }

        let ring = AudioRingBuffer(channels: 1, capacityFrames: Int(Self.sampleRate), canceller: { [weak self] in
            self?.stopPump()
        })
        ringBuffer = ring
        startPump(filling: ring)
        return ring
    }

    /// How much decoded audio to keep queued ahead of the audio device. The device drains
    /// at the true hardware rate, so refilling to a level rather than decoding on a fixed
    /// schedule keeps playout locked to that clock instead of drifting against it.
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

    private func stopPump()
    {
        lock.lock(); defer { lock.unlock() }
        pump?.cancel()
        pump = nil
    }

    private func refill(_ ring: AudioRingBuffer, using decoder: any VoiceDecoder)
    {
        let frameCount = Self.frameDuration
        var scratch = [Float](repeating: 0, count: frameCount)

        while ring.availableToRead() < Self.targetBufferedFrames, ring.availableToWrite() >= frameCount
        {
            let step = jitterBuffer.nextStep(codecSupportsFEC: decoder.supportsFEC)
            // Priming: leave the ring empty. Its own underrun path emits silence, and
            // writing silence here would only push the real audio further behind.
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
            scratch.withUnsafeMutableBufferPointer { buffer in
                var channel = buffer.baseAddress!
                withUnsafeMutablePointer(to: &channel) { channels in
                    ring.writeDeinterleaved(source: channels, frames: written)
                }
            }
            counters.update { $0.played += 1 }
        }
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

    public func add(_ observer: @escaping (Data) -> Void) -> Token
    {
        let token = Token(id: UUID())
        lock.lock(); observers[token] = observer; lock.unlock()
        return token
    }

    public func remove(_ token: Token)
    {
        lock.lock(); observers[token] = nil; lock.unlock()
    }

    public func emit(_ data: Data)
    {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        // Outside the lock: an observer that forwards may take other locks, and one that
        // removes itself would deadlock a non-recursive one.
        for observer in current { observer(data) }
    }
}
