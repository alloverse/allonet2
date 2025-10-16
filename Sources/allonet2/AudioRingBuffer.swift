//
//  AudioRingBuffer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-09-16.
//  ... mostly written by ChatGPT though.

import Foundation
import Atomics
import OpenCombineShim

/// Lock-free SPSC ring buffer for deinterleaved Float32 audio.
///
/// - One writer thread (producer), one reader thread (consumer), no blocking.
/// - Format: Float32, non-interleaved; `channels` in [1, 8].
/// - Capacity is in frames; per-channel storage has that many samples per channel.
open class AudioRingBuffer: Cancellable, CustomStringConvertible
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
    
    // read is in the alloclient extension
    /// Read up to `frames` frames into non-interleaved Float32 spans, one per channel read
    /// Returns frames actually read (<= requested and <= available).
    @discardableResult
    public func read(into buffers: [UnsafeMutablePointer<Float32>], frames: Int) -> Int
    {
        let requestedChannels = buffers.count
        if frames == 0 { return 0 }
        let readable = availableToRead()
        if readable == 0 { return 0 }

        let toRead = min(frames, readable)
        var r = readIndex.load(ordering: .relaxed)

        let first = min(toRead, capacityFrames - r)
        let second = toRead - first

        for c in 0..<channels {
            let srcCh = channelPtrs[c]
            let dstPtr = buffers[c]

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

    
    var canceller: () -> ()
    public func cancel() { canceller() }
}
