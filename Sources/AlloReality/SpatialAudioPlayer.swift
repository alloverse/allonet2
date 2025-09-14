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
    fileprivate var state: [MediaStreamId: SpatialAudioPlaybackState] = [:]
    var cancellables: Set<AnyCancellable> = []
    
    // TODO: Maybe take which entity to attach Listeners to instead of assuming avatar?
    // TODO: And then also tell RealityKit that we're listening through this entity?
    
    public init(mapper: RealityViewMapper, client: AlloUserClient)
    {
        self.mapper = mapper
        self.client = client
        start()
    }
    
    func start()
    {
        // 1. Setup listeners to get incoming tracks. Just ask to get everything (except our own audio) forwarded.
        var streamIds = Set<String>()
        func updateListener()
        {
            Task { @MainActor in
                print("SpatialAudioPlayer Updating listener to forward \(streamIds)")
                try? await self.client.avatar?.components.set(LiveMediaListener(mediaIds: streamIds))
            }
        }
        client.placeState.observers[LiveMedia.self].added.sink { eid, liveMedia in
            guard let edata = self.client.placeState.current.entities[eid] else { return }
            guard edata.ownerClientId != self.client.cid else { return }
            streamIds.insert(liveMedia.mediaId)
            self.state[liveMedia.mediaId] = SpatialAudioPlaybackState(streamId: liveMedia.mediaId, eid: eid)
            updateListener()
        }.store(in: &cancellables)
        client.placeState.observers[LiveMedia.self].removed.sink { _eid, liveMedia in
            streamIds.remove(liveMedia.mediaId)
            updateListener()
            self.stop(streamId: liveMedia.mediaId)
        }.store(in: &cancellables)
        
        client.session.$incomingStreams.sinkChanges(added: { (key, value) in
            self.play(stream: value)
        }, removed: { (key, value) in
            self.stop(streamId: key)
        }).store(in: &cancellables)
    }
    
    func play(stream: MediaStream)
    {
        guard stream.streamDirection.isRecv else { return }
    
        guard
            let playState = state[stream.mediaId],
            let netent = client.placeState.current.entities[playState.eid],
            let guient = mapper.guiForEid(playState.eid)
        else { fatalError("Should not be possible to get a stream without corresponding state and entities") }
        
        assert(playState.controller == nil, "Playing the same stream twice?")
        
        print("SpatialAudioPlayer setting up LiveMedia \(netent.id) <-- \(stream.mediaId)")
        
        // TODO: Pick these up as settings from an Alloverse component
        let spatial = SpatialAudioComponent(
            gain: .zero,
            directLevel: .zero,
            reverbLevel: .zero,
            directivity: .beam(focus: 0.8),
            distanceAttenuation: .rolloff(factor: 18.0)
        )
        guient.components.set(spatial)
        
        let config = AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono)
        
        stream.audioBuffers.sink { [weak self] buffer in
            print("SpatialAudioPlayer Incoming buffer \(buffer)")
            // buffer is AVAudioPCMBuffer
            // TODO: Start storing audio data in a ring buffer or something
        }.store(in: &playState.cancellables)
        
        let handler: Audio.GeneratorRenderHandler = { (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            // TODO: Pluck data from the ring buffer instead of generating tone
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
        do {
            playState.controller = try guient.playAudio(handler)
        } catch {
            print("SpatialAudioPlayer !!! Failed to start audio generator for entity \(netent.id) stream \(playState.streamId): \(error)")
            stop(streamId: playState.streamId)
            return
        }
        print("SpatialAudioPlayer Successfully set up audio renderer \(netent.id) <-- \(stream.mediaId)")
    }
    
    func stop(streamId: MediaStreamId)
    {
        print("SpatialAudioPlayer Tearing down LiveMedia renderer for stream \(streamId)")
        guard let playState = state[streamId] else { return }
        let guient = mapper.guiForEid(playState.eid)
        
        print("SpatialAudioPlayer LiveMedia \(streamId) was attached to \(playState.eid), disabling it...")
        playState.stop()
        state[streamId] = nil
        
        guient?.components.remove(SpatialAudioComponent.self)
    }
    
    public func stop()
    {
        cancellables.forEach { $0.cancel() }; cancellables.removeAll()
    }
}

@MainActor
fileprivate class SpatialAudioPlaybackState
{
    let streamId: MediaStreamId
    let eid: EntityID
    
    var cancellables: Set<AnyCancellable> = []
    var controller: AudioGeneratorController? = nil
    
    fileprivate func stop()
    {
        cancellables.forEach {$0.cancel()}
        controller?.stop()
    }
    
    fileprivate init(streamId: MediaStreamId, eid: EntityID)
    {
        self.streamId = streamId
        self.eid = eid
    }
}
