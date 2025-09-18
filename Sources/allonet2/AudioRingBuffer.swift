//
//  AudioRingBuffer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-09-16.
//  ... mostly written by ChatGPT though.

import Foundation
import AVFoundation
import Atomics
import AudioToolbox
import OpenCombineShim

/// Lock-free SPSC ring buffer for deinterleaved Float32 audio.
///
/// - One writer thread (producer), one reader thread (consumer), no blocking.
/// - Format: Float32, non-interleaved; `channels` in [1, 8].
/// - Capacity is in frames; per-channel storage has that many samples per channel.
public final class AudioRingBuffer: Cancellable, CustomStringConvertible
{
    public let channels: Int
    public let capacityFrames: Int

    // Per-channel storage (contiguous) to simplify wrap logic.
    private var channelPtrs: [UnsafeMutablePointer<Float32>]
    private let deallocator: () -> Void

    // Lock-free indices (SPSC).
    // `writeIndex` is advanced by producer; `readIndex` by consumer.
    private let writeIndex: ManagedAtomic<Int>
    private let readIndex: ManagedAtomic<Int>

    public init(channels: Int, capacityFrames: Int, canceller: @escaping () -> ()) {
        precondition(channels > 0 && channels <= 8, "1...8 channels supported")
        precondition(capacityFrames > 0)

        self.channels = channels
        // Use power-of-two capacity for cheap modulo if you like; we keep general case.
        self.capacityFrames = capacityFrames

        let bytesPerChannel = capacityFrames * MemoryLayout<Float32>.stride

        var pointers: [UnsafeMutablePointer<Float32>] = []
        pointers.reserveCapacity(channels)

        // Allocate one contiguous block for all channels to be cache-friendly.
        let totalBytes = bytesPerChannel * channels
        let base = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: MemoryLayout<Float32>.alignment) as! UnsafeMutableRawPointer

        // Zero out once.
        base.initializeMemory(as: UInt8.self, repeating: 0, count: totalBytes)

        for ch in 0..<channels {
            let ptr = base.advanced(by: ch * bytesPerChannel).bindMemory(to: Float32.self, capacity: capacityFrames)
            pointers.append(ptr)
        }

        self.channelPtrs = pointers
        self.deallocator = {
            base.deallocate()
        }

        self.writeIndex = ManagedAtomic(0)
        self.readIndex = ManagedAtomic(0)
        self.canceller = canceller
    }

    deinit {
        deallocator()
    }
    
    public var description: String {
        "<AudioRingBuffer@{\(Unmanaged.passUnretained(self).toOpaque())} buffered frames: \(availableToRead()), write capacity \(availableToWrite())>"
    }

    /// Frames available to read.
    @inline(__always)
    public func availableToRead() -> Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        let diff = w - r
        return diff >= 0 ? diff : diff + capacityFrames
    }

    /// Free space for writing.
    @inline(__always)
    public func availableToWrite() -> Int {
        // We leave one frame empty to disambiguate full vs empty.
        return capacityFrames - 1 - availableToRead()
    }

    /// Write up to `pcm.frameLength` frames from a non-interleaved Float32 AVAudioPCMBuffer.
    /// Returns frames accepted (may be less than requested if full).
    @discardableResult
    public func write(_ pcm: AVAudioPCMBuffer) -> Int
    {
        guard pcm.format.channelCount == channels, pcm.frameLength > 0 else { return 0 }
        var src : UnsafePointer<UnsafeMutablePointer<Float>>! = pcm.floatChannelData
        if src == nil {
            if pcm.int16ChannelData != nil {
                src = convertInt16ToFloat(pcm)
            }
            if src == nil {
                return 0
            }
        }
        let frames = Int(pcm.frameLength)
        return writeDeinterleaved(source: src!, frames: frames)
    }
    
    private var rawScratch: UnsafeMutableRawPointer?
    private var channelScratch: [UnsafeMutablePointer<Float32>] = []
    private var conversionScratch: UnsafePointer<UnsafeMutablePointer<Float>>?
    private func convertInt16ToFloat(_ pcm: AVAudioPCMBuffer) -> UnsafePointer<UnsafeMutablePointer<Float>>?
    {
        let intSrc = pcm.int16ChannelData!
        let frames = Int(pcm.frameLength)
        // TODO: code assumes single writer, so we can safely reuse the same buffer. Codify this assumption in the type system?
        // TODO: code assumes incoming buffer has the same length every time. Add checks and assert if that's not true.
        // TODO: If there are any bugs at all here, honestly just switch to AudioConverter.
        if conversionScratch == nil
        {
            let bytesPerChannel = frames * MemoryLayout<Float32>.stride
            rawScratch = UnsafeMutableRawPointer.allocate(byteCount: bytesPerChannel * channels, alignment: MemoryLayout<Float32>.alignment)

            channelScratch.reserveCapacity(channels)
            for c in 0..<channels {
                let ptr = rawScratch!.advanced(by: c * bytesPerChannel).bindMemory(to: Float32.self, capacity: frames)
                channelScratch.append(ptr)
            }
            conversionScratch = UnsafePointer(channelScratch)
        }
        let scale: Float = 1.0 / 32768.0
        for c in 0..<channels {
            let srcCh = intSrc[c]
            let dstCh = channelScratch[c]
            for i in 0..<frames {
                dstCh[i] = Float(srcCh[i]) * scale
            }
        }
        return conversionScratch
    }

    /// Write from deinterleaved channel pointers.
    /// `source` is an array-like pointer set (Float32* per channel).
    @discardableResult
    public func writeDeinterleaved(source: UnsafePointer<UnsafeMutablePointer<Float32>>, frames: Int) -> Int {
        if frames == 0 { return 0 }
        let writable = availableToWrite()
        if writable == 0 { return 0 }

        let toWrite = min(frames, writable)
        var w = writeIndex.load(ordering: .relaxed)

        // First segment: up to ring end.
        let first = min(toWrite, capacityFrames - w)
        let second = toWrite - first

        for c in 0..<channels {
            let srcCh = source[c]
            let dstCh = channelPtrs[c]

            // segment 1
            dstCh.advanced(by: w).assign(from: srcCh, count: first)
            // segment 2 (wrap)
            if second > 0 {
                dstCh.assign(from: srcCh.advanced(by: first), count: second)
            }
        }

        // Publish new write index with release ordering.
        w = (w + toWrite) % capacityFrames
        writeIndex.store(w, ordering: .releasing)
        return toWrite
    }

    /// Read up to `frames` frames into an AudioBufferList (expects non-interleaved Float32).
    /// Returns frames actually read (<= requested and <= available).
    @discardableResult
    public func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int {
        if frames == 0 { return 0 }
        let readable = availableToRead()
        if readable == 0 { return 0 }

        let toRead = min(frames, readable)
        var r = readIndex.load(ordering: .relaxed)

        let first = min(toRead, capacityFrames - r)
        let second = toRead - first

        // Validate abl matches our channel count and format.
        guard abl.count >= channels else { return 0 }
        for c in 0..<channels {
            let dst = abl[c]
            guard dst.mNumberChannels == 1 else { return 0 } // non-interleaved
            guard dst.mDataByteSize >= UInt32(toRead * MemoryLayout<Float32>.stride) else { return 0 }
        }

        for c in 0..<channels {
            let srcCh = channelPtrs[c]
            let dstBuf = abl[c]
            guard let dstPtr = dstBuf.mData?.assumingMemoryBound(to: Float32.self) else { continue }

            // segment 1
            dstPtr.assign(from: srcCh.advanced(by: r), count: first)
            // segment 2 (wrap)
            if second > 0 {
                dstPtr.advanced(by: first).assign(from: srcCh, count: second)
            }
        }

        // Publish new read index.
        r = (r + toRead) % capacityFrames
        readIndex.store(r, ordering: .releasing)
        return toRead
    }

    /// Convenience: zero-fill ABL for frames where ring underflowed.
    public func readOrSilence(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let got = read(into: abl, frames: frames)
        if got < frames {
            let deficit = frames - got
            print("!!! RING BUFFER UNDERFLOW, writing \(deficit) zeros")
            for c in 0..<channels {
                let dst = abl[c]
                if let ptr = dst.mData?.assumingMemoryBound(to: Float32.self) {
                    ptr.advanced(by: got).initialize(repeating: 0, count: deficit)
                }
            }
        }
    }
    
    var canceller: () -> ()
    public func cancel() { canceller() }
}
