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
import Logging

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
    var logger: Logger! = Logger(label: "spatialaudioplayer")
    
    /// Construct a SpatialAudioPlayer which uses `mapper` to create audio related components and `client` to react to network events. Note: announce must have completed and avatar exist before instantiating this class.
    public init(mapper: RealityViewMapper, client: AlloUserClient, content: RealityViewContentProtocol)
    {
        self.mapper = mapper
        self.client = client
        self.content = content
        self.logger = Logger(label: "spatialaudioplayer", metadataProvider: Logger.MetadataProvider { [weak self] in
            guard let self, let cid = self.client.cid else { return [:] }
            return ["clientId": .stringConvertible(cid)]
        })
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
        logger.info("Using \(listenerEid) as RealityKit listener")

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
                logger.info("Updating listener to forward \(streamIds)")
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
        var streamLogger = logger!
        streamLogger[metadataKey: "mediaId"] = .string(stream.mediaId)
        streamLogger.info("Playing \(stream)")
    
        guard
            let playState = state[stream.mediaId],
            let netent = client.placeState.current.entities[playState.eid],
            let guient = mapper.guiForEid(playState.eid)
        else
        {
            streamLogger.error("Should not be possible to get a stream without corresponding state and entities")
            return
        }
        
        assert(playState.controller == nil, "Playing the same stream twice?")
        
        streamLogger.info("Setting up LiveMedia on \(netent.id)")
        
        // TODO: Pick these up as settings from an Alloverse component
        let spatial = SpatialAudioComponent(
            gain: -1000, // Overridden by `SpatialAudioAttenuationSystem`
            directLevel: .zero,
            reverbLevel: .zero,
            directivity: .beam(focus: 0.3),
            distanceAttenuation: .rolloff(factor: 0.0) // Don't do attenuation here, but in `SpatialAudioAttenuationSystem` instead.
        )
        guient.components.set(spatial)
        
        let ringBuffer = stream.render() as! AVFAudioRingBuffer
        ringBuffer.store(in: &playState.cancellables)
        
        // TODO: Adjust playback speed to keep the buffered amount stable at ~50ms latency?
        let config = AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono)
        let handler: Audio.GeneratorRenderHandler = { (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            let requested = Int(frameCount)
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            streamLogger.trace("Rendering \(requested) rendering from \(ringBuffer)")
            ringBuffer.readOrSilence(into: ablPointer, frames: requested)
            return noErr
        }
        do {
            playState.controller = try guient.playAudio(handler)
        } catch {
            streamLogger.error("Failed to start audio generator on entity \(netent.id): \(error)")
            stop(streamId: playState.streamId)
            return
        }
        streamLogger.info("Successfully set up audio renderer \(netent.id)")
    }
    
    func stop(streamId: MediaStreamId)
    {
        guard let playState = state[streamId] else { return }
        var streamLogger = logger!
        streamLogger[metadataKey: "mediaId"] = .string(streamId)
        streamLogger.info("Stopping \(playState.streamId); tearing down LiveMedia renderer")
        
        let guient = mapper.guiForEid(playState.eid)
        
        streamLogger.info("Was attached to \(playState.eid), disabling it...")
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

