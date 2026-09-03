//
//  H264Decoder.swift
//  AlloVideo
//

import Foundation
import CoreMedia
import allonet2

public enum VideoDecodeError: Error, CustomStringConvertible
{
    /// An audio frame reached a video decoder; the caller routed it wrong.
    case notVideo(MediaFrame.Kind)
    /// The payload holds no Annex B start code, so it is not an access unit at all.
    case noStartCode(byteCount: Int)
    /// A keyframe arrived without the SPS and PPS every one of them must carry.
    case keyframeWithoutParameterSets(byteCount: Int)
    case formatDescriptionFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)

    public var description: String
    {
        switch self
        {
        case .notVideo(let kind): "media frame kind \(kind) is audio, not a picture"
        case .noStartCode(let byteCount): "\(byteCount) byte access unit has no Annex B start code"
        case .keyframeWithoutParameterSets(let byteCount): "\(byteCount) byte keyframe carries no SPS/PPS"
        case .formatDescriptionFailed(let status): "cannot build a format description from SPS/PPS: OSStatus \(status)"
        case .blockBufferFailed(let status): "cannot wrap an access unit in a block buffer: OSStatus \(status)"
        case .sampleBufferFailed(let status): "cannot build a sample buffer: OSStatus \(status)"
        }
    }
}

/// Media frames in, displayable samples out.
///
/// The samples carry **compressed** data plus the format description built from the stream's
/// own SPS/PPS: `AVSampleBufferDisplayLayer` decodes them itself, which is one hardware path
/// fewer to own and the shortest route to glass. Feed them to a layer with
/// `enqueue(_:)`; nothing here touches a `VTDecompressionSession`.
///
/// Deltas before the first keyframe decode to nothing - there is no picture to predict from -
/// so `hasKeyframe` is what a receiver reports as "waiting for a key" rather than "broken".
public final class H264Decoder: @unchecked Sendable
{
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    public init() {}

    /// True once a keyframe has been fed in, which is when `decode` starts returning samples.
    public var hasKeyframe: Bool { lock.lock(); defer { lock.unlock() }; return format != nil }

    /// Forget the current picture: `decode` returns nil for deltas until the next keyframe.
    /// For after a lost frame, when every delta would predict from a picture this decoder
    /// never saw and smear the screen until the next key anyway.
    public func awaitKeyframe()
    {
        lock.lock(); format = nil; parameterSets = []; lock.unlock()
    }

    /// Turn one media frame into a sample a display layer can show.
    ///
    /// - Returns: the sample, or nil for a delta frame arriving before the first keyframe.
    /// - Throws: `VideoDecodeError`, naming the frame's kind or its size - a corrupt access unit
    ///   must be countable as such, not silently dropped.
    public func decode(_ frame: MediaFrame) throws -> CMSampleBuffer?
    {
        guard frame.kind.isVideo else { throw VideoDecodeError.notVideo(frame.kind) }
        let units = Self.nalUnits(in: frame.payload)
        guard !units.isEmpty else { throw VideoDecodeError.noStartCode(byteCount: frame.payload.count) }

        if frame.kind == .h264Key
        {
            let sets = units.filter { ($0.first.map { $0 & 0x1f } ?? 0) == 7 || ($0.first.map { $0 & 0x1f } ?? 0) == 8 }
            guard sets.count >= 2 else { throw VideoDecodeError.keyframeWithoutParameterSets(byteCount: frame.payload.count) }
            try updateFormat(with: sets)
        }

        lock.lock(); let format = self.format; lock.unlock()
        guard let format else { return nil }

        // Parameter sets live in the format description, not in the sample.
        let pictures = units.filter { unit in
            let type = unit.first.map { $0 & 0x1f } ?? 0
            return type != 7 && type != 8 && type != 9
        }
        guard !pictures.isEmpty else { return nil }

        var avcc = Data()
        for unit in pictures
        {
            let size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: size) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }

        var block: CMBlockBuffer?
        var storage = [UInt8](avcc)
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: storage.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: storage.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw VideoDecodeError.blockBufferFailed(status) }
        status = CMBlockBufferReplaceDataBytes(with: &storage, blockBuffer: block, offsetIntoDestination: 0, dataLength: storage.count)
        guard status == noErr else { throw VideoDecodeError.blockBufferFailed(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(frame.timestamp), timescale: 48000),
            decodeTimeStamp: .invalid)
        var size = storage.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoDecodeError.sampleBufferFailed(status) }

        // The stream carries no timebase, so the layer shows each picture as it arrives rather
        // than scheduling it against a clock nobody sets.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0
        {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Rebuild the format description when the parameter sets change - which is what a sharer
    /// resizing the shared window looks like from here.
    private func updateFormat(with sets: [Data]) throws
    {
        lock.lock(); defer { lock.unlock() }
        guard sets != parameterSets else { return }

        var format: CMVideoFormatDescription?
        let sizes = sets.map(\.count)
        let status = sets.withUnsafeBufferPointer { _ -> OSStatus in
            var pointers: [UnsafePointer<UInt8>] = []
            var bases: [UnsafeMutableRawPointer] = []
            defer { for base in bases { base.deallocate() } }
            for set in sets
            {
                let base = UnsafeMutableRawPointer.allocate(byteCount: set.count, alignment: 1)
                set.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: set.count)
                bases.append(base)
                pointers.append(UnsafePointer(base.assumingMemoryBound(to: UInt8.self)))
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw VideoDecodeError.formatDescriptionFailed(status) }
        self.format = format
        parameterSets = sets
    }

    /// Split an Annex B access unit into its NAL units, dropping the start codes. Handles both
    /// the three- and four-byte start code, which encoders mix within one access unit.
    static func nalUnits(in data: Data) -> [Data]
    {
        let bytes = [UInt8](data)
        var starts: [(index: Int, length: Int)] = []
        var i = 0
        while i + 3 <= bytes.count
        {
            if bytes[i] == 0, bytes[i + 1] == 0
            {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        return starts.enumerated().compactMap { offset, start in
            let from = start.index + start.length
            let to = offset + 1 < starts.count ? starts[offset + 1].index : bytes.count
            guard to > from else { return nil }
            return Data(bytes[from..<to])
        }
    }
}
