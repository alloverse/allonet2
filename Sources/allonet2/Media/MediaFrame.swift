//
//  MediaFrame.swift
//  allonet2
//

import Foundation

/// One media frame as it travels over a media data channel.
///
/// Wire format, big-endian, 9 byte header:
///
///     0        kind
///     1..<5    sequence
///     5..<9    timestamp, 48 kHz ticks: audio samples, and the same ticks for video
///     9...     payload
///
/// The stream identity is the channel, not the header: one stream is one data channel, so
/// there is nothing to demultiplex and no stream id to carry. `kind` says what the payload is
/// and how large it may get, and leaves room for a later control message (a keyframe request,
/// say) to share the channel without a format change.
public struct MediaFrame: Equatable, Sendable
{
    public enum Kind: UInt8, Sendable
    {
        /// Opus, 48 kHz mono, 20 ms frames. Timestamp in samples.
        case opus = 0
        /// Interleaved Float32 PCM. Only used by tests, which need to assert on samples
        /// without depending on a codec. Timestamp in samples.
        case pcmFloat32 = 1
        /// One H.264 Annex B access unit holding exactly one IDR picture, with SPS and PPS
        /// prepended to every one of them so a viewer can start on any keyframe. Timestamp in
        /// 48 kHz ticks.
        case h264Key = 2
        /// One H.264 Annex B access unit holding one P picture; no B frames, so decode order
        /// is display order and a decoder needs no reordering delay. Timestamp in 48 kHz ticks.
        case h264Delta = 3

        /// Largest message a stream will take off the wire for this kind, header included.
        /// Enforced on the place and on every receiver, before the fan-out: an oversized frame
        /// would otherwise be re-emitted by every forwarder and held by every jitter buffer
        /// downstream.
        public var maximumFrameBytes: Int
        {
            switch self
            {
            // One frame of the most verbose audio kind, uncompressed Float32. Opus at its
            // maximum bitrate is a third of it.
            case .opus, .pcmFloat32: DataChannelMediaStream.frameDuration * MemoryLayout<Float>.size + MediaFrame.headerSize
            // A full-screen keyframe with its parameter sets; a delta frame is a fraction of it,
            // and a stream whose deltas approach this is misconfigured rather than detailed.
            case .h264Key: 1 << 20
            case .h264Delta: 256 << 10
            }
        }

        /// Whether this payload is a picture rather than audio. An audio playout path skips
        /// what this says yes to: it passed the cap and was forwarded, but there is no decoder
        /// for it here.
        public var isVideo: Bool
        {
            switch self
            {
            case .opus, .pcmFloat32: false
            case .h264Key, .h264Delta: true
            }
        }
    }

    public let kind: Kind
    public let sequence: UInt32
    /// Where this frame plays, in 48 kHz ticks since the stream started. For audio those ticks
    /// are its own samples, so 20 ms frames advance it by 960; video uses the same unit so that
    /// a picture and a voice can be placed on one timeline.
    public let timestamp: UInt32
    public let payload: Data

    public static let headerSize = 9

    public init(kind: Kind, sequence: UInt32, timestamp: UInt32, payload: Data)
    {
        self.kind = kind
        self.sequence = sequence
        self.timestamp = timestamp
        self.payload = payload
    }

    public var encoded: Data
    {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(kind.rawValue)
        data.append(bigEndian: sequence)
        data.append(bigEndian: timestamp)
        data.append(payload)
        return data
    }

    /// The `kind` a well-formed header names: `data` is long enough, and starts with a `kind`
    /// this build knows. The same check `init(decoding:)` makes, for callers that route frames
    /// without parsing them - it reads one byte and allocates nothing on the path that succeeds.
    ///
    /// Throws `MediaFrameError.tooShort` or `.unknownKind`, either of which names the byte or
    /// the length that failed, so a router turning a frame away can say which.
    public static func validateHeader(_ data: Data) throws -> Kind
    {
        guard data.count >= headerSize else
        {
            throw MediaFrameError.tooShort(byteCount: data.count)
        }
        // `data` may be a slice; index from its own start.
        guard let kind = Kind(rawValue: data[data.startIndex]) else
        {
            throw MediaFrameError.unknownKind(data[data.startIndex])
        }
        return kind
    }

    /// Parse a frame off the wire; `data` may be a slice. Throws `MediaFrameError.tooShort`
    /// or `.unknownKind`. The payload aliases `data` rather than copying it.
    public init(decoding data: Data) throws
    {
        self.kind = try Self.validateHeader(data)
        let base = data.startIndex
        self.sequence = data.bigEndianUInt32(at: base + 1)
        self.timestamp = data.bigEndianUInt32(at: base + 5)
        self.payload = data[(base + Self.headerSize)...]
    }
}

public enum MediaFrameError: Error, CustomStringConvertible, Equatable
{
    case tooShort(byteCount: Int)
    case unknownKind(UInt8)

    public var description: String
    {
        switch self
        {
        case .tooShort(let byteCount):
            "media frame is \(byteCount) bytes, needs at least \(MediaFrame.headerSize)"
        case .unknownKind(let kind):
            "media frame has unknown kind \(kind)"
        }
    }
}

extension Data
{
    fileprivate mutating func append(bigEndian value: UInt32)
    {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    fileprivate func bigEndianUInt32(at index: Index) -> UInt32
    {
        (UInt32(self[index]) << 24) | (UInt32(self[index + 1]) << 16)
            | (UInt32(self[index + 2]) << 8) | UInt32(self[index + 3])
    }
}

/// Sequence comparison that survives wraparound; plain `<` does not.
extension UInt32
{
    /// True when `self` is newer than `other`, tolerating wraparound (RFC 1982 §3.2).
    public func isNewerSequence(than other: UInt32) -> Bool
    {
        Int32(bitPattern: self &- other) > 0
    }

    /// Frames between `self` and `other`, signed, wraparound-tolerant.
    public func sequenceDistance(from other: UInt32) -> Int32
    {
        Int32(bitPattern: self &- other)
    }
}
