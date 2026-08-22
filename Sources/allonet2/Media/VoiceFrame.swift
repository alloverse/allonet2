//
//  VoiceFrame.swift
//  allonet2
//

import Foundation

/// One encoded audio frame as it travels over a media data channel.
///
/// Wire format, big-endian, 9 byte header:
///
///     0        kind
///     1..<5    sequence
///     5..<9    timestamp, in samples
///     9...     payload
///
/// The stream identity is the channel, not the header: one stream is one data channel, so
/// there is nothing to demultiplex and no stream id to carry. `kind` exists so a later
/// control message (a video keyframe request, say) can share the channel without a format
/// change.
public struct VoiceFrame: Equatable, Sendable
{
    public enum Kind: UInt8, Sendable
    {
        /// Opus, 48 kHz mono, 20 ms frames.
        case opus = 0
        /// Interleaved Float32 PCM. Only used by tests, which need to assert on samples
        /// without depending on a codec.
        case pcmFloat32 = 1
    }

    public let kind: Kind
    public let sequence: UInt32
    /// Playout position of the frame's first sample, counted in samples since the stream
    /// started. At 48 kHz with 20 ms frames this advances by 960 per frame.
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

    /// Parse a frame off the wire; `data` may be a slice. Throws `VoiceFrameError.tooShort`
    /// or `.unknownKind`. The payload aliases `data` rather than copying it.
    public init(decoding data: Data) throws
    {
        guard data.count >= Self.headerSize else
        {
            throw VoiceFrameError.tooShort(byteCount: data.count)
        }
        // `data` may be a slice; index from its own start.
        let base = data.startIndex
        guard let kind = Kind(rawValue: data[base]) else
        {
            throw VoiceFrameError.unknownKind(data[base])
        }
        self.kind = kind
        self.sequence = data.bigEndianUInt32(at: base + 1)
        self.timestamp = data.bigEndianUInt32(at: base + 5)
        self.payload = data[(base + Self.headerSize)...]
    }
}

public enum VoiceFrameError: Error, CustomStringConvertible, Equatable
{
    case tooShort(byteCount: Int)
    case unknownKind(UInt8)

    public var description: String
    {
        switch self
        {
        case .tooShort(let byteCount):
            "voice frame is \(byteCount) bytes, needs at least \(VoiceFrame.headerSize)"
        case .unknownKind(let kind):
            "voice frame has unknown kind \(kind)"
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
