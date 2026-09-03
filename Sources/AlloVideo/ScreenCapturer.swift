//
//  ScreenCapturer.swift
//  AlloVideo
//

#if os(macOS)

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Atomics

public enum ScreenCaptureError: Error, CustomStringConvertible
{
    /// The user dismissed the picker without choosing anything.
    case cancelled
    /// The picker itself refused to open; the OS says why.
    case pickerFailed(underlying: Error)
    /// `SCStream` stopped, either by failing or because the user pressed the system's stop
    /// button. Nil means a clean stop.
    case captureStopped(underlying: Error?)

    public var description: String
    {
        switch self
        {
        case .cancelled: "the user cancelled the screen sharing picker"
        case .pickerFailed(let underlying): "the screen sharing picker failed to open: \(underlying)"
        case .captureStopped(let underlying): "screen capture stopped: \(underlying.map(String.init(describing:)) ?? "by request")"
        }
    }
}

/// The user's own picker, then a live `SCStream` of whatever they picked.
///
/// The picture is NV12 (`420YpCbCr8BiPlanarVideoRange`) and IOSurface-backed, which is what the
/// hardware encoder wants, so nothing is converted between the window server and the bitstream.
/// Frames arrive on the stream's own queue and are yielded straight into `frames`, keeping only
/// the newest two: an encoder that falls behind drops pictures rather than lagging further.
///
/// ```swift
/// let capturer = ScreenCapturer()
/// try await capturer.pickAndStart()      // shows the system picker; returns on the first frame
/// for await frame in capturer.frames { … }
/// ```
///
/// Sharing ends when the user presses the system's stop button, which finishes `frames`.
@MainActor
public final class ScreenCapturer: NSObject, VideoSource
{
    public struct Configuration: Sendable
    {
        /// The picture is scaled to fit inside this, keeping the content's aspect ratio; a
        /// retina display is therefore shared at a sane bitrate rather than at 5K.
        public var maxPixelSize: CGSize
        /// Seconds between pictures - 1/30 by default. The system never sends more than this,
        /// and sends fewer when nothing changes.
        public var frameInterval: Double
        public var showsCursor: Bool

        public init(maxPixelSize: CGSize = CGSize(width: 1920, height: 1200),
                    frameInterval: Double = 1.0 / 30,
                    showsCursor: Bool = true)
        {
            self.maxPixelSize = maxPixelSize
            self.frameInterval = frameInterval
            self.showsCursor = showsCursor
        }
    }

    public nonisolated let frames: AsyncStream<CapturedFrame>

    private let configuration: Configuration
    private let output: Output
    private let queue = DispatchQueue(label: "allovideo.capture")
    private var stream: SCStream?
    private var streamConfiguration = SCStreamConfiguration()
    private var picking: CheckedContinuation<Void, Error>?
    private var stopped = false

    public init(configuration: Configuration = .init())
    {
        self.configuration = configuration
        var continuation: AsyncStream<CapturedFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation = $0 }
        output = Output(continuation: continuation)
        super.init()
        output.owner = self
    }

    /// Show `SCContentSharingPicker` and start capturing what the user picks.
    ///
    /// - Returns: once the first frame has been captured, so a caller that returns from this
    ///   has a stream that is actually producing pictures.
    /// - Throws: `ScreenCaptureError.cancelled` when the user dismisses the picker or `stop()`
    ///   interrupts it - a stopped capturer is spent and throws that at once - `.pickerFailed`
    ///   when it cannot open, and whatever `SCStream` throws when starting the capture fails: a
    ///   missing screen-recording permission comes out here.
    public func pickAndStart() async throws
    {
        guard !stopped else { throw ScreenCaptureError.cancelled }
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
        defer { picker.remove(self); picker.isActive = false }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            picking = continuation
        }
    }

    /// Change the frame rate of a running capture. Takes effect on the next picture; a failure
    /// leaves the previous rate in force and is logged, since the capture itself is unharmed.
    public func setFrameInterval(_ seconds: Double)
    {
        streamConfiguration.minimumFrameInterval = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let stream else { return }
        let configuration = streamConfiguration
        Task
        {
            do { try await stream.updateConfiguration(configuration) }
            catch { print("ScreenCapturer: cannot set frame interval to \(seconds)s: \(error)") }
        }
    }

    /// Stop capturing and finish `frames`. A `pickAndStart()` still waiting on the picker throws
    /// `ScreenCaptureError.cancelled`, and anything the user picks after this is ignored.
    public nonisolated func stop()
    {
        Task { @MainActor in
            stopped = true
            finishPicking(with: ScreenCaptureError.cancelled)
            guard let stream else { return output.finish() }
            self.stream = nil
            do { try await stream.stopCapture() }
            catch { print("ScreenCapturer: the capture did not stop cleanly: \(error)") }
            output.finish()
        }
    }

    private func start(with filter: SCContentFilter) async
    {
        guard !stopped else { return }
        do
        {
            let size = Self.fit(filter.contentRect.size, scale: CGFloat(filter.pointPixelScale), into: configuration.maxPixelSize)
            streamConfiguration.width = size.width
            streamConfiguration.height = size.height
            streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            streamConfiguration.showsCursor = configuration.showsCursor
            streamConfiguration.minimumFrameInterval = CMTime(seconds: configuration.frameInterval, preferredTimescale: 600)
            streamConfiguration.queueDepth = 3

            // The picker can pick again while a capture is running; that means "share this
            // instead", so the running stream changes what it points at. A second SCStream would
            // leave the first one capturing the window the user just stopped sharing.
            if let stream
            {
                try await stream.updateContentFilter(filter)
                try await stream.updateConfiguration(streamConfiguration)
                return
            }

            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // `stop()` can land in the middle of this; the capture it could not see must not
            // outlive it.
            guard !stopped else { return try await stream.stopCapture() }
            self.stream = stream
        }
        catch
        {
            finishPicking(with: error)
        }
    }

    fileprivate func finishPicking(with error: Error?)
    {
        guard let picking else { return }
        self.picking = nil
        if let error { picking.resume(throwing: error) } else { picking.resume() }
    }

    /// Even numbers, because H.264 chroma is subsampled by two in both directions.
    nonisolated static func fit(_ size: CGSize, scale: CGFloat, into limit: CGSize) -> (width: Int, height: Int)
    {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixels.width > 0, pixels.height > 0 else { return (2, 2) }
        let factor = min(1, min(limit.width / pixels.width, limit.height / pixels.height))
        return (max(2, Int(pixels.width * factor) & ~1), max(2, Int(pixels.height * factor) & ~1))
    }
}

extension ScreenCapturer: SCContentSharingPickerObserver
{
    public nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?)
    {
        Task { @MainActor in await start(with: filter) }
    }

    public nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?)
    {
        Task { @MainActor in finishPicking(with: ScreenCaptureError.cancelled) }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error)
    {
        Task { @MainActor in finishPicking(with: ScreenCaptureError.pickerFailed(underlying: error)) }
    }
}

/// The stream's frame sink, kept off `ScreenCapturer` itself: ScreenCaptureKit delivers on its
/// own queue, and this touches nothing main-actor.
private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable
{
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let flowing = ManagedAtomic<Bool>(false)
    weak var owner: ScreenCapturer?

    init(continuation: AsyncStream<CapturedFrame>.Continuation)
    {
        self.continuation = continuation
    }

    func finish() { continuation.finish() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
    {
        guard type == .screen, Self.isComplete(sampleBuffer), let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        continuation.yield(CapturedFrame(pixels: pixels, capturedAt: monotonicNow()))
        // Only the first picture resolves `pickAndStart`; hopping to the main actor per frame
        // for a continuation that is already gone would cost a task at the frame rate.
        guard !flowing.exchange(true, ordering: .relaxed) else { return }
        Task { @MainActor [owner] in owner?.finishPicking(with: nil) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error)
    {
        continuation.finish()
        Task { @MainActor [owner] in owner?.finishPicking(with: ScreenCaptureError.captureStopped(underlying: error)) }
    }

    /// The system also sends idle and blank frames; only a complete one carries a new picture.
    private static func isComplete(_ sample: CMSampleBuffer) -> Bool
    {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else { return false }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as? [SCStreamFrameInfo: Any]
        guard let raw = first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}

#endif
