//
//  VideoSource.swift
//  AlloVideo
//

import Foundation
import CoreVideo
import Dispatch

/// One picture on its way into the encoder.
///
/// `pixels` is whatever the source produces - IOSurface-backed NV12 from ScreenCaptureKit, a
/// pooled buffer from `PatternSource` - and is only valid for as long as the consumer holds it;
/// a source recycles its buffers. `capturedAt` is seconds on the machine's monotonic clock, the
/// same one every process on the host reads, which is what lets a sender and a viewer on one
/// machine measure latency against each other.
public struct CapturedFrame: @unchecked Sendable
{
    public let pixels: CVPixelBuffer
    public let capturedAt: Double

    public init(pixels: CVPixelBuffer, capturedAt: Double)
    {
        self.pixels = pixels
        self.capturedAt = capturedAt
    }
}

/// Anything that produces pictures: a captured screen, a test pattern, later a camera.
///
/// `frames` keeps only the newest few pictures, so a consumer slower than the source drops old
/// frames rather than falling further behind on a growing queue. The stream finishes when the
/// source stops - including when the *system* stops it, which is how the screen-sharing
/// indicator's stop button reaches the pipeline.
public protocol VideoSource: AnyObject
{
    var frames: AsyncStream<CapturedFrame> { get }
    /// Stop producing and finish `frames`. Idempotent.
    func stop()
}

/// Seconds on the monotonic clock `CapturedFrame.capturedAt` is measured on.
func monotonicNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// A moving gradient with the frame number written into it as a bar of binary blocks, at a
/// fixed size and rate, with no permissions and no hardware. What the tests and
/// `SCREENDEMO_PATTERN` capture instead of a screen.
///
/// The picture is a pure function of (width, height, frame index): the top 16 rows carry the
/// index's low 24 bits as light/dark blocks 8 px wide, and the rest is a diagonal luma ramp
/// that scrolls 4 levels per frame. Chroma is neutral, so it is greyscale. NV12
/// (`420YpCbCr8BiPlanarVideoRange`), the format VideoToolbox and ScreenCaptureKit both want, so
/// nothing converts on the way to the encoder.
public final class PatternSource: VideoSource, @unchecked Sendable
{
    public let frames: AsyncStream<CapturedFrame>

    private let width: Int
    private let height: Int
    private let pool: CVPixelBufferPool
    private let timer: DispatchSourceTimer
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private var index = 0

    /// - Parameters:
    ///   - width: picture width in pixels; rounded down to even, which H.264 chroma requires.
    ///   - height: as `width`.
    ///   - fps: pictures per second, produced off a timer rather than a display clock.
    public init(width: Int, height: Int, fps: Double)
    {
        self.width = width & ~1
        self.height = height & ~1

        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: self.width,
            kCVPixelBufferHeightKey: self.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        // Only fails on attributes it cannot honour, and these are a fixed, valid set.
        precondition(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
                     "cannot allocate a \(self.width)x\(self.height) NV12 pool")
        self.pool = pool!

        var continuation: AsyncStream<CapturedFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation = $0 }
        self.continuation = continuation

        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "allovideo.pattern"))
        timer.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.produce() }
        timer.resume()
    }

    deinit { timer.cancel(); continuation.finish() }

    public func stop()
    {
        timer.cancel()
        continuation.finish()
    }

    private func produce()
    {
        var buffer: CVPixelBuffer?
        let created = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer, created == kCVReturnSuccess else
        {
            // The pool is exhausted only while consumers still hold every buffer; the next tick
            // is 1/fps away and will find one.
            return
        }
        let frame = index
        index += 1
        Self.draw(frame: frame, into: buffer, width: width, height: height)
        continuation.yield(CapturedFrame(pixels: buffer, capturedAt: monotonicNow()))
    }

    /// One picture of the pattern, outside any timer: exactly the bytes a source of this size
    /// produces for that frame index. What to encode when you need to know which picture you
    /// are looking at.
    public static func picture(frame: Int, width: Int, height: Int) -> CVPixelBuffer
    {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        precondition(CVPixelBufferCreate(nil, width & ~1, height & ~1, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                     "cannot allocate a \(width)x\(height) NV12 buffer")
        draw(frame: frame, into: buffer!, width: width & ~1, height: height & ~1)
        return buffer!
    }

    /// The frame index a picture carries, read back out of its luma plane. The counterpart of
    /// `picture`: a test that decodes a picture can name the frame it came from.
    public static func frameIndex(in pixels: CVPixelBuffer) -> Int
    {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let plane = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return -1 }
        let luma = plane.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var index = 0
        for bit in 0..<counterBits
        {
            // Middle of the block, and of the bar, so a rescale or a lossy encode still reads it.
            let sample = luma[8 * stride + bit * blockWidth + blockWidth / 2]
            if sample > (high + low) / 2 { index |= 1 << bit }
        }
        return index
    }

    private static let counterBits = 24
    private static let blockWidth = 8
    private static let barHeight = 16
    private static let low: UInt8 = 16
    private static let high: UInt8 = 235

    private static func draw(frame: Int, into buffer: CVPixelBuffer, width: Int, height: Int)
    {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        {
            let luma = plane.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<height
            {
                let row = luma + y * stride
                for x in 0..<width
                {
                    row[x] = low + UInt8((x &+ y &+ frame &* 4) % 220)
                }
            }
            for bit in 0..<counterBits
            {
                let value = (frame >> bit) & 1 == 1 ? high : low
                for y in 0..<min(barHeight, height)
                {
                    let row = luma + y * stride
                    for x in (bit * blockWidth)..<min((bit + 1) * blockWidth, width) { row[x] = value }
                }
            }
        }
        if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            memset(plane, 128, stride * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
    }
}
