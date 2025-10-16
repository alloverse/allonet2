//
//  AudioRingBuffer+AVFoundation.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-10-16.
//

import Foundation
import allonet2
import AVFoundation

public class AVFAudioRingBuffer: AudioRingBuffer
{
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
    
    /// Read up to `frames` frames into an AudioBufferList (expects non-interleaved Float32).
    /// Returns frames actually read (<= requested and <= available).
    @discardableResult
    public func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int
    {
        var buffers = [UnsafeMutablePointer<Float32>]()
        for dst in abl {
            guard dst.mNumberChannels == 1 else { return 0; } // we don't support interleaved
            guard dst.mDataByteSize >= UInt32(frames * MemoryLayout<Float32>.stride) else { return 0 }
            guard let dstPtr = dst.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            buffers.append(dstPtr)
        }
        
        return read(into: buffers, frames: frames)
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
}
