//
//  AudioRingBuffer+CoreAudio.swift
//  allonet2
//

import Foundation
import AVFoundation
import allonet2

/// Reading into CoreAudio buffers needs no per-instance state, so it works on any ring
/// buffer - including the plain one the data-channel voice path renders into.
extension AudioRingBuffer
{
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
    /// Runs on the audio render thread, so it counts underruns rather than logging them -
    /// and a voice stream that is still priming underruns by design.
    public func readOrSilence(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let got = read(into: abl, frames: frames)
        if got < frames {
            let deficit = frames - got
            noteUnderrun(frames: deficit)
            for c in 0..<channels {
                let dst = abl[c]
                if let ptr = dst.mData?.assumingMemoryBound(to: Float32.self) {
                    ptr.advanced(by: got).initialize(repeating: 0, count: deficit)
                }
            }
        }
    }
}
