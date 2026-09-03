//
//  H264Encoder.swift
//  AlloVideo
//

import Foundation
import VideoToolbox
import CoreMedia
import allonet2

/// One compressed picture, ready to be sent as a `MediaFrame` payload.
public struct EncodedFrame: Sendable
{
    /// `.h264Key` or `.h264Delta`, which is also what tells a receiver whether it may start here.
    public let kind: MediaFrame.Kind
    /// One Annex B access unit: start-code-delimited NAL units, SPS and PPS first on a keyframe.
    public let annexB: Data
    /// 48 kHz ticks since the encoder's first frame - the unit voice uses, so a picture and a
    /// voice sit on one timeline.
    public let timestamp: UInt32

    public init(kind: MediaFrame.Kind, annexB: Data, timestamp: UInt32)
    {
        self.kind = kind
        self.annexB = annexB
        self.timestamp = timestamp
    }
}

public enum VideoEncodeError: Error, CustomStringConvertible
{
    case sessionCreationFailed(OSStatus, width: Int, height: Int)
    case propertyFailed(OSStatus, name: String)
    case encodeFailed(OSStatus)
    /// The encoder produced a sample with no block buffer, or one this build cannot read.
    case unreadableSample(OSStatus)
    /// A keyframe came back without SPS/PPS, so no receiver could start on it.
    case missingParameterSets(OSStatus)

    public var description: String
    {
        switch self
        {
        case .sessionCreationFailed(let status, let width, let height):
            "cannot create an H.264 encoder for \(width)x\(height): OSStatus \(status)"
        case .propertyFailed(let status, let name): "encoder rejected \(name): OSStatus \(status)"
        case .encodeFailed(let status): "encoding a frame failed: OSStatus \(status)"
        case .unreadableSample(let status): "encoded sample has no readable data: OSStatus \(status)"
        case .missingParameterSets(let status): "keyframe carries no SPS/PPS: OSStatus \(status)"
        }
    }
}

/// Pictures in, H.264 Annex B access units out, on the hardware encoder.
///
/// Real-time, no frame reordering and no B pictures, so decode order is display order and the
/// decoder needs no reordering delay; every keyframe carries its own SPS and PPS so a viewer can
/// join on any of them. One instance encodes one size: a source that changes resolution needs a
/// new encoder.
///
/// ```swift
/// let encoder = try H264Encoder(width: 1280, height: 720, bitrate: 2_000_000)
/// if let out = try await encoder.encode(frame, forceKeyframe: false) { send(out) }
/// encoder.bitrate = 1_600_000   // takes effect on the next picture
/// ```
public final class H264Encoder: @unchecked Sendable
{
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var origin: Double?
    private var currentBitrate: Int

    /// - Parameters:
    ///   - width: picture width in pixels. Must match every `CapturedFrame` handed to `encode`.
    ///   - height: as `width`.
    ///   - bitrate: target average bits per second; the encoder is additionally capped at 1.5x
    ///     that over any one second, so a scene change cannot burst the channel.
    ///   - keyframeInterval: seconds between keyframes, which is how long a viewer joining
    ///     mid-stream waits for its first picture.
    /// - Throws: `VideoEncodeError.sessionCreationFailed` or `.propertyFailed`, both naming the
    ///   `OSStatus` VideoToolbox returned.
    public init(width: Int, height: Int, bitrate: Int, keyframeInterval: Double = 2) throws
    {
        currentBitrate = bitrate
        var session: VTCompressionSession?
        // No EnableLowLatencyRateControl: on macOS 26 that path builds a VideoProcessing
        // reaction observer, which enumerates capture devices over CoreMediaIO and can block
        // forever in a process with no camera access. RealTime plus DataRateLimits is the same
        // pacing without the camera dependency. See docs/gotchas.md.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else
        {
            throw VideoEncodeError.sessionCreationFailed(status, width: width, height: height)
        }
        self.session = session

        try Self.set(session, kVTCompressionPropertyKey_RealTime, true as CFBoolean, "RealTime")
        try Self.set(session, kVTCompressionPropertyKey_AllowFrameReordering, false as CFBoolean, "AllowFrameReordering")
        try Self.set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel, "ProfileLevel")
        try Self.set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeInterval as CFNumber, "MaxKeyFrameIntervalDuration")
        try Self.applyBitrate(session, bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit
    {
        VTCompressionSessionInvalidate(session)
    }

    /// Target average bits per second. Setting it takes effect on the next picture; the 1.5x
    /// one-second cap moves with it. A sender's adaptation loop owns the policy, this owns none.
    public var bitrate: Int
    {
        get { lock.lock(); defer { lock.unlock() }; return currentBitrate }
        set
        {
            lock.lock(); defer { lock.unlock() }
            guard newValue != currentBitrate else { return }
            currentBitrate = newValue
            // A rejected bitrate leaves the previous one in force, which is a working encoder;
            // it is loud rather than fatal for that reason.
            do { try Self.applyBitrate(session, newValue) }
            catch { print("H264Encoder: \(error)") }
        }
    }

    /// Compress one picture.
    ///
    /// - Parameter forceKeyframe: make this picture an IDR whatever the keyframe interval says.
    /// - Returns: the access unit, or nil when the encoder dropped the picture (it does that
    ///   under load, and the next one is a complete replacement).
    /// - Throws: `VideoEncodeError.encodeFailed`, `.unreadableSample` or `.missingParameterSets`.
    public func encode(_ frame: CapturedFrame, forceKeyframe: Bool) async throws -> EncodedFrame?
    {
        let ticks = lock.withLock
        {
            if origin == nil { origin = frame.capturedAt }
            return UInt32(truncatingIfNeeded: Int64(((frame.capturedAt - origin!) * 48000).rounded()))
        }

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        return try await withCheckedThrowingContinuation { continuation in
            // VideoToolbox calls the handler exactly once per accepted frame, on its own thread,
            // and not at all when the call itself fails - so the two paths never both resume.
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: frame.pixels,
                presentationTimeStamp: CMTime(value: Int64(ticks), timescale: 48000),
                duration: .invalid,
                frameProperties: properties,
                infoFlagsOut: nil
            ) { status, flags, sampleBuffer in
                guard status == noErr else
                {
                    return continuation.resume(throwing: VideoEncodeError.encodeFailed(status))
                }
                guard !flags.contains(.frameDropped), let sampleBuffer else
                {
                    return continuation.resume(returning: nil)
                }
                do { continuation.resume(returning: try Self.annexB(from: sampleBuffer, timestamp: ticks)) }
                catch { continuation.resume(throwing: error) }
            }
            if status != noErr { continuation.resume(throwing: VideoEncodeError.encodeFailed(status)) }
        }
    }

    private static func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef, _ name: String) throws
    {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw VideoEncodeError.propertyFailed(status, name: name) }
    }

    private static func applyBitrate(_ session: VTCompressionSession, _ bitrate: Int) throws
    {
        try set(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber, "AverageBitRate")
        // Bytes per second, then the window in seconds: a hard ceiling the average alone has not.
        let limits = [bitrate * 3 / 16, 1] as CFArray
        try set(session, kVTCompressionPropertyKey_DataRateLimits, limits, "DataRateLimits")
    }

    /// AVCC (length-prefixed) to Annex B (start-code-delimited), prepending SPS and PPS to every
    /// keyframe so a viewer can start on any of them without side-band parameter sets.
    private static func annexB(from sample: CMSampleBuffer, timestamp: UInt32) throws -> EncodedFrame
    {
        let isKeyframe = Self.isKeyframe(sample)
        var out = Data()

        if isKeyframe
        {
            guard let format = CMSampleBufferGetFormatDescription(sample) else
            {
                throw VideoEncodeError.missingParameterSets(noErr)
            }
            var count = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            guard status == noErr, count > 0 else { throw VideoEncodeError.missingParameterSets(status) }
            for index in 0..<count
            {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard status == noErr, let pointer else { throw VideoEncodeError.missingParameterSets(status) }
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else
        {
            throw VideoEncodeError.unreadableSample(noErr)
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard status == noErr, let pointer else { throw VideoEncodeError.unreadableSample(status) }

        // AVCC out of VideoToolbox is always 4-byte lengths, big-endian, back to back.
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length
        {
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard size > 0, offset + 4 + size <= length else { throw VideoEncodeError.unreadableSample(noErr) }
            out.append(contentsOf: startCode)
            out.append(bytes + offset + 4, count: size)
            offset += 4 + size
        }

        return EncodedFrame(kind: isKeyframe ? .h264Key : .h264Delta, annexB: out, timestamp: timestamp)
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Sync sample unless the attachment says otherwise; a sample with no attachments at all is
    /// a sync sample by definition.
    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool
    {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else { return true }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        guard let notSync = (first as? [CFString: Any])?[kCMSampleAttachmentKey_NotSync] as? Bool else { return true }
        return !notSync
    }
}
