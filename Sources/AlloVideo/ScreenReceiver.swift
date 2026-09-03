//
//  ScreenReceiver.swift
//  AlloVideo
//

import Foundation
import CoreMedia
import allonet2

/// Stream to decoder to samples: the viewer's half of a screen share.
///
/// Frames are taken on the thread that delivered them - hopping first would drop the frames that
/// arrive while a channel is being adopted - decoded there, and yielded into `samples`. The
/// samples are compressed, for `AVSampleBufferDisplayLayer` to decode as it shows them.
///
/// ```swift
/// let receiver = ScreenReceiver(stream: stream)
/// receiver.needsKeyframe = { client.requestKeyframe(from: sharer) }
/// for await sample in receiver.samples { layer.enqueue(sample) }
/// ```
public final class ScreenReceiver: @unchecked Sendable
{
    public let counters: ScreenCountersBox
    public let samples: AsyncStream<CMSampleBuffer>

    /// Fires when the picture cannot continue from here: a gap in the sequence, or an access unit
    /// the decoder refused. The owner turns it into a keyframe request to the sharer, which is
    /// rate-limited there. Called on the delivering thread, so hop before touching isolated
    /// state, and assign it before frames flow - it is read without synchronisation.
    public var needsKeyframe: (() -> Void)?

    private let stream: any MediaStream
    private let decoder = H264Decoder()
    private let continuation: AsyncStream<CMSampleBuffer>.Continuation
    private let lock = NSLock()
    private var token: FrameObservers.Token?
    private var lastSequence: UInt32?

    public init(stream: any MediaStream, counters: ScreenCountersBox = ScreenCountersBox())
    {
        self.stream = stream
        self.counters = counters
        var continuation: AsyncStream<CMSampleBuffer>.Continuation!
        // A viewer that falls behind should skip to the newest picture rather than replay old
        // ones: a screen share has no value in a frame nobody could show in time.
        samples = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
        self.continuation = continuation
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
            needsKeyframe?()
        }
        if frame.kind == .h264Key { counters.update { $0.keyframes += 1 } }

        do
        {
            guard let sample = try decoder.decode(frame) else
            {
                counters.update { $0.droppedAwaitingKey += 1 }
                return
            }
            counters.update { $0.decoded += 1 }
            continuation.yield(sample)
        }
        catch
        {
            counters.update { $0.malformed += 1 }
            needsKeyframe?()
        }
    }
}
