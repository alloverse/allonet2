//
//  SpatialAudioPlayer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-09-12.
//

import allonet2
import alloclient
import RealityKit
import OpenCombineShim
import SwiftUICore
import CoreAudio

/// Syncs `LiveMedia` components from entities surrounding the local avatar and plays them back spatially.
@MainActor
public class SpatialAudioPlayer
{
    let mapper: RealityViewMapper
    let client: AlloUserClient
    fileprivate var state: [EntityID: SpatialAudioPlaybackState] = [:]
    
    public init(mapper: RealityViewMapper, client: AlloUserClient)
    {
        self.mapper = mapper
        self.client = client
        start()
    }
    
    func start()
    {
        mapper.startSyncingOf(networkComponentType: LiveMedia.self, updater: { guient, netent, liveMedia in
            // Don't try to play our own streams
            if netent.ownerClientId == self.client.cid { return }
            
            // already configured for some other LiveMedia? Tear it down.
            // TODO: If we're just adjusting a setting, reconfigure instead of tearing down
            self.state[netent.id]?.stop()
            
            print("SpatialAudioPlayer setting up LiveMedia \(netent.id) <-- \(liveMedia.mediaId)")
            
            // TODO: Pick these up as settings from an Alloverse component
            let spatial = SpatialAudioComponent(
                gain: .zero,
                directLevel: .zero,
                reverbLevel: .zero,
                directivity: .beam(focus: 0.8),
                distanceAttenuation: .rolloff(factor: 1.0)
            )
            guient.components.set(spatial)
            let config = AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono)
            
            // TODO: Add LiveMediaListener here (or here-adjacent) instead of in AllUserClient
            
            // TODO: this might come in asynchronously. Rendezvous the component with the stream instead.
            let stream = self.client.session.incomingStreams[liveMedia.mediaId]
            var cancellables = Set<AnyCancellable>()
            stream?.audioBuffers.sink { [weak self] buffer in
                print("XX Incoming buffer \(buffer)")
                // buffer is AVAudioPCMBuffer
            }.store(in: &cancellables)
            
            let handler: Audio.GeneratorRenderHandler = { (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
                isSilence.pointee = false

                let freq: Double = 440
                let sampleRate: Double = 48000

                // Phase from absolute sample time (keeps continuity across calls).
                var phase = freq * timestamp.pointee.mSampleTime * (1.0 / sampleRate)
                let phaseIncrement = freq / sampleRate

                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard let buf0 = abl.first, let mData = buf0.mData else { return 0 }

                let out = mData.bindMemory(to: Float32.self, capacity: Int(frameCount))

                for i in 0..<Int(frameCount) {
                    out[i] = Float32(sin(phase * 2.0 * .pi) * 0.5)
                    phase += phaseIncrement
                }

                return 0
            }
            let controller: AudioGeneratorController
            do {
                controller = try guient.playAudio(handler)
            } catch {
                print("!!! Failed to start audio generator for entity \(netent.id) stream \(liveMedia.mediaId): \(error)")
                return
            }
            print("Successfully set up audio renderer")
            self.state[netent.id] = SpatialAudioPlaybackState(controller: controller, cancellables: cancellables)
        }, remover: { guient, netent, liveMedia in
            print("Tearing down LiveMedia renderer for entity \(netent.id) <-- \(liveMedia.mediaId)")
            guard let state = self.state[netent.id] else { return }
            state.stop()
            self.state[netent.id] = nil
            
            guient.components.remove(SpatialAudioComponent.self)
        })
    }
}

@MainActor
fileprivate class SpatialAudioPlaybackState
{
    let controller: AudioGeneratorController
    let cancellables: Set<AnyCancellable>
    init(controller: AudioGeneratorController, cancellables: Set<AnyCancellable>)
    {
        self.controller = controller
        self.cancellables = cancellables
    }
    func stop()
    {
        cancellables.forEach {$0.cancel()}
        controller.stop()
    }
}
