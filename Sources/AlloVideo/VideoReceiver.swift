//
//  VideoReceiver.swift
//  AlloVideo
//

import Foundation
import CoreMedia
import allonet2

/// Stream to decoder to samples: the viewer's half of a video stream.
///
/// Frames are taken on the thread that delivered them - hopping first would drop the frames that
/// arrive while a channel is being adopted - decoded there, and yielded into `samples`. The
/// samples are compressed, for `AVSampleBufferDisplayLayer` to decode as it shows them.
///
/// ```swift
/// let receiver = VideoReceiver(stream: stream)
/// receiver.needsKeyframe = { client.requestKeyframe(from: sharer) }
/// for await sample in receiver.samples { layer.enqueue(sample) }
/// ```
public final class VideoReceiver: @unchecked Sendable
{
    public let counters: VideoCountersBox
    public let samples: AsyncStream<CMSampleBuffer>

    /// Fires when the picture cannot continue from here: a gap in the sequence, an access unit the
    /// decoder refused, a sample `samples` evicted, or a delta arriving before any key. The owner
    /// turns it into a keyframe request to the sharer, which is rate-limited there. Fires once per
    /// episode, not once per frame, so the deltas that follow the hole do not ask again. Called on
    /// the delivering thread, so hop before touching isolated state; pass it to `init` rather than
    /// setting it here if frames can already be arriving.
    public var needsKeyframe: (() -> Void)?
    {
        get { lock.lock(); defer { lock.unlock() }; return _needsKeyframe }
        set { lock.lock(); _needsKeyframe = newValue; lock.unlock() }
    }
    private var _needsKeyframe: (() -> Void)?

    private let stream: any MediaStream
    private let decoder = H264Decoder()
    private let continuation: AsyncStream<CMSampleBuffer>.Continuation
    private let lock = NSLock()
    private var token: FrameObservers.Token?
    private var lastSequence: UInt32?
    private var askedForKeyframe = false

    /// - Parameter needsKeyframe: installed before the first frame is observed, so a stream
    ///   that arrives mid-GOP asks for its key at once rather than after the first gap.
    public init(stream: any MediaStream, needsKeyframe: (() -> Void)? = nil, counters: VideoCountersBox = VideoCountersBox())
    {
        self.stream = stream
        self.counters = counters
        var continuation: AsyncStream<CMSampleBuffer>.Continuation!
        // A viewer that falls behind should skip to the newest picture rather than replay old
        // ones: video has no value in a frame nobody could show in time.
        samples = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
        self.continuation = continuation
        _needsKeyframe = needsKeyframe
        token = stream.observeFrames { [weak self] data in self?.receive(data) }
    }

    deinit { stop() }

    /// Stop decoding and finish `samples`. Idempotent.
    public func stop()
    {
        lock.lock(); let token = self.token; self.token = nil; lock.unlock()
        if let token { stream.removeObserver(token) }
        continuation.finish()
    }

    private func receive(_ data: Data)
    {
        counters.update { $0.received += 1 }
        let frame: MediaFrame
        do { frame = try MediaFrame(decoding: data) }
        catch
        {
            counters.update { $0.malformed += 1 }
            return
        }
        guard frame.kind.isVideo else
        {
            // Well-formed, and the place was right to forward it; there is just no picture in it.
            counters.update { $0.malformed += 1 }
            return
        }

        lock.lock()
        let previous = lastSequence
        // An ordered channel does not reorder, so anything not newer is a duplicate of a frame
        // this decoder has already seen.
        let isNew = previous.map { frame.sequence.isNewerSequence(than: $0) } ?? true
        if isNew { lastSequence = frame.sequence }
        lock.unlock()
        guard isNew else { return }

        if let previous, frame.sequence.sequenceDistance(from: previous) > 1
        {
            counters.update { $0.gaps += 1 }
            decoder.awaitKeyframe()
            askForKeyframe()
        }
        if frame.kind == .h264Key { counters.update { $0.keyframes += 1 } }

        do
        {
            guard let sample = try decoder.decode(frame) else
            {
                // A viewer that joined mid-GOP has no hole to notice; this is the only sign it
                // needs a key of its own.
                counters.update { $0.droppedAwaitingKey += 1 }
                askForKeyframe()
                return
            }
            counters.update { $0.decoded += 1 }
            lock.lock(); askedForKeyframe = false; lock.unlock()
            // `samples` keeps only the newest few, so a viewer that stopped consuming loses a
            // picture the deltas after it predict from - a hole like any other.
            if case .dropped = continuation.yield(sample)
            {
                counters.update { $0.evicted += 1 }
                // What was evicted is older than the key just yielded, and a key predicts from
                // nothing: the picture is whole without asking the sharer for another one.
                guard frame.kind != .h264Key else { return }
                decoder.awaitKeyframe()
                askForKeyframe()
            }
        }
        catch
        {
            counters.update { $0.malformed += 1 }
            decoder.awaitKeyframe()
            askForKeyframe()
        }
    }

    /// One request per episode of waiting for a key: an episode ends when a picture decodes.
    private func askForKeyframe()
    {
        lock.lock()
        let already = askedForKeyframe
        askedForKeyframe = true
        let ask = _needsKeyframe
        lock.unlock()
        if !already { ask?() }
    }
}
