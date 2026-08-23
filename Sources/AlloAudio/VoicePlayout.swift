//
//  VoicePlayout.swift
//  allonet2
//

import Foundation
import AVFoundation
import allonet2
import Logging

/// Plays incoming voice streams through the default output device.
///
/// This is the demo/headless counterpart to what `SpatialAudioPlayer` does inside the app:
/// both take the `AudioRingBuffer` from `MediaStream.render()` and pull from it on their own
/// render thread. Keeping that seam identical is what lets the app switch to this transport
/// without touching its audio code.
@MainActor
public final class VoicePlayout
{
    private let engine = AVAudioEngine()
    private var logger = Logger(labelSuffix: "audio.playout")
    private var sources: [String: AVAudioSourceNode] = [:]
    private let format: AVAudioFormat

    public init()
    {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: DataChannelMediaStream.sampleRate,
                               channels: 1,
                               interleaved: false)!
    }

    public func play(_ stream: DataChannelMediaStream) throws
    {
        guard sources[stream.mediaId] == nil else { return }

        // render() starts the decode pump; the ring buffer is the handoff to the audio thread.
        let ring = stream.render()
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            stream.notePlayout(of: ring)   // which frame this is, before the read moves the head
            ring.readOrSilence(into: buffers, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        sources[stream.mediaId] = source

        if !engine.isRunning
        {
            try engine.start()
        }
        logger.info("Playing \(stream.mediaId)")
    }

    /// What the output device adds after the render callback: buffering, conversion and the
    /// hardware itself. Not included in a render-callback-to-capture measurement, so report it
    /// alongside one rather than pretending it is not there.
    public var outputLatency: TimeInterval { engine.outputNode.presentationLatency }

    public func stop(_ mediaId: String)
    {
        guard let source = sources.removeValue(forKey: mediaId) else { return }
        engine.detach(source)
        logger.info("Stopped \(mediaId)")
    }

    public func stop()
    {
        for mediaId in sources.keys { stop(mediaId) }
        engine.stop()
    }
}
