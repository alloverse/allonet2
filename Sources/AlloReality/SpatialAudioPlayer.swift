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
import SwiftUI
import CoreAudio

/// Syncs `LiveMedia` components from entities surrounding the local avatar and plays them back spatially.
@MainActor
public class SpatialAudioPlayer
{
    let mapper: RealityViewMapper
    let client: AlloUserClient
    let content: RealityViewContentProtocol
    let listenerEid: EntityID? = nil
    fileprivate var state: [MediaStreamId: SpatialAudioPlaybackState] = [:]
    var streamCancellables: Set<AnyCancellable> = []
    var listenerCancellables: Set<AnyCancellable> = []
    
    /// Construct a SpatialAudioPlayer which uses `mapper` to create audio related components and `client` to react to network events. Note: announce must have completed and avatar exist before instantiating this class.
    public init(mapper: RealityViewMapper, client: AlloUserClient, content: RealityViewContentProtocol)
    {
        self.mapper = mapper
        self.client = client
        self.content = content
        start()
    }
    
    // Guaranteed to be called _after_ avatar and initial state is loaded
    func start()
    {
        client.session.$incomingStreams.sinkChanges(added: { (key, value) in
            self.play(stream: value)
        }, removed: { (key, value) in
            self.stop(streamId: key)
        }).store(in: &streamCancellables)
    }
    
    public func useAsListener(_ listenerEid: EntityID)
    {
        listenerCancellables.forEach { $0.cancel() }; listenerCancellables.removeAll()
        // TODO: In case we change listener for some other reason than a new avatar from reconnection, we should remove listening requests from the old listener.
        
        let listener = client.place.entities[listenerEid]!
        let guient = self.mapper.guiForEid(listenerEid)!
        print("SpatialAudioPlayer using \(listenerEid) as RealityKit listener")

        // TODO: When non-immersive, set it to be an "ears" sub-entity which is always pointed "forwards" in the camera perspective
        var cameraContent = content as! RealityViewCameraContent
        cameraContent.audioListener = guient
        
        // Make sure our custom attenuation system knows who the listener is
        guient.components.set(AudioListenerComponent())
        
        // Setup listeners to get incoming tracks. Just ask to get everything (except our own audio) forwarded.
        var streamIds = Set<String>()
        func updateListener()
        {
            Task { @MainActor in
                print("SpatialAudioPlayer Updating listener to forward \(streamIds)")
                try? await listener.components.set(LiveMediaListener(mediaIds: streamIds))
            }
        }
        client.placeState.observers[LiveMedia.self].addedWithInitial.sink { eid, liveMedia in
            guard let edata = self.client.placeState.current.entities[eid] else { return }
            guard edata.ownerClientId != self.client.cid else { return }
            streamIds.insert(liveMedia.mediaId)
            self.state[liveMedia.mediaId] = SpatialAudioPlaybackState(streamId: liveMedia.mediaId, eid: eid)
            updateListener()
        }.store(in: &listenerCancellables)
        client.placeState.observers[LiveMedia.self].removed.sink { _eid, liveMedia in
            streamIds.remove(liveMedia.mediaId)
            updateListener()
            self.stop(streamId: liveMedia.mediaId)
        }.store(in: &listenerCancellables)
    }
    
    func play(stream: MediaStream)
    {
        guard stream.streamDirection.isRecv else { return }
        print("SpatialAudioPlayer[\(stream.mediaId)] playing \(stream)")
    
        guard
            let playState = state[stream.mediaId],
            let netent = client.placeState.current.entities[playState.eid],
            let guient = mapper.guiForEid(playState.eid)
        else { fatalError("Should not be possible to get a stream without corresponding state and entities") }
        
        assert(playState.controller == nil, "Playing the same stream twice?")
        
        print("SpatialAudioPlayer[\(playState.streamId)] setting up LiveMedia \(netent.id)")
        
        // TODO: Pick these up as settings from an Alloverse component
        let spatial = SpatialAudioComponent(
            gain: 0, // Overridden by `SpatialAudioAttenuationSystem`
            directLevel: .zero,
            reverbLevel: .zero,
            directivity: .beam(focus: 0.3),
            distanceAttenuation: .rolloff(factor: 0.0) // Don't do attenuation here, but in `SpatialAudioAttenuationSystem` instead.
        )
        guient.components.set(spatial)
        
        let ringBuffer = stream.render()
        ringBuffer.store(in: &playState.cancellables)
        
        // TODO: Adjust playback speed to keep the buffered amount stable at ~50ms latency?
        let config = AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono)
        let handler: Audio.GeneratorRenderHandler = { (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            let requested = Int(frameCount)
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            //print("SpatialAudioPlayer[\(playState.streamId)] rendering \(requested) rendering from \(ringBuffer)")
            ringBuffer.readOrSilence(into: ablPointer, frames: requested)
            return noErr
        }
        do {
            playState.controller = try guient.playAudio(handler)
        } catch {
            print("SpatialAudioPlayer[\(playState.streamId)] !!! Failed to start audio generator for entity \(netent.id): \(error)")
            stop(streamId: playState.streamId)
            return
        }
        print("SpatialAudioPlayer[\(playState.streamId)] Successfully set up audio renderer \(netent.id)")
    }
    
    func stop(streamId: MediaStreamId)
    {
        guard let playState = state[streamId] else { return }
        print("SpatialAudioPlayer[\(streamId)] Stopping \(playState.streamId); tearing down LiveMedia renderer")
        
        let guient = mapper.guiForEid(playState.eid)
        
        print("SpatialAudioPlayer[\(streamId)] was attached to \(playState.eid), disabling it...")
        playState.stop()
        state[streamId] = nil
        
        guient?.components.remove(SpatialAudioComponent.self)
    }
    
    public func stop()
    {
        streamCancellables.forEach { $0.cancel() }; streamCancellables.removeAll()
        listenerCancellables.forEach { $0.cancel() }; listenerCancellables.removeAll()
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

