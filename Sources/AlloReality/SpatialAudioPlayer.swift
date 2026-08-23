//
//  SpatialAudioPlayer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-09-12.
//

import allonet2
import AlloAudio
import alloclient
import RealityKit
import OpenCombineShim
import Logging

/// Syncs `LiveMedia` components from entities surrounding the local avatar and plays them back
/// spatially through the client's `VoiceEngine`.
@MainActor
public class SpatialAudioPlayer
{
    let mapper: RealityViewMapper
    let client: AlloUserClient
    let listenerEid: EntityID? = nil
    let addon: ListenerAddon?
    fileprivate var state: [MediaStreamId: SpatialAudioPlaybackState] = [:]
    var streamCancellables: Set<AnyCancellable> = []
    var listenerCancellables: Set<AnyCancellable> = []
    var logger: Logger! = Logger(labelSuffix: "spatialaudioplayer")
    
    /// Construct a SpatialAudioPlayer which uses `mapper` to create audio related components and `client` to react to network events. Note: announce must have completed and avatar exist before instantiating this class.
    public init(mapper: RealityViewMapper, client: AlloUserClient, addon: ListenerAddon? = nil)
    {
        self.mapper = mapper
        self.client = client
        self.addon = addon
        self.logger = Logger(labelSuffix: "spatialaudioplayer", metadataProvider: Logger.MetadataProvider { [weak self] in
            guard let self, let cid = self.client.cid else { return [:] }
            return ["clientId": .stringConvertible(cid)]
        })
        start()
    }
    
    // Guaranteed to be called _after_ avatar and initial state is loaded
    func start()
    {
        // The client replaces its session on every reconnection, so the stream subscription has to
        // follow it. Bound once, as this was, a visor goes permanently silent the first time it
        // reconnects — it keeps listening to the streams of a connection that no longer exists.
        client.$isAnnounced.sink { [weak self] announced in
            guard let self else { return }
            announced ? bindToCurrentSession() : unbindFromSession()
        }.store(in: &streamCancellables)
        bindToCurrentSession()

        client.$speakerEnabled.sink { [weak self] enabled in
            self?.updateListener(speakerEnabled: enabled)
        }.store(in: &streamCancellables)
    }

    /// Subscriptions that belong to one connection, dropped and remade as it is replaced.
    private var sessionCancellables: Set<AnyCancellable> = []

    private func bindToCurrentSession()
    {
        unbindFromSession()
        client.session.$incomingStreams.sinkChanges(added: { [weak self] (key, value) in
            self?.play(stream: value)
        }, removed: { [weak self] (key, value) in
            self?.stop(streamId: key)
        }).store(in: &sessionCancellables)
    }

    private func unbindFromSession()
    {
        sessionCancellables.forEach { $0.cancel() }; sessionCancellables.removeAll()
        // Whatever was playing came over the connection we just lost; the place will send the
        // streams that still exist again once we are announced on the new one.
        for streamId in state.keys { stop(streamId: streamId) }
    }

    private var listener: allonet2.Entity? = nil
    private var streamIds = Set<MediaStreamId>()
    /// Ask the place to forward the streams we want to hear — none while deafened.
    /// `speakerEnabled` is passed in because a $speakerEnabled sink fires on willSet.
    private func updateListener(speakerEnabled: Bool)
    {
        guard let listener else { return }
        let mediaIds = speakerEnabled ? streamIds : []
        Task { @MainActor in
            logger.info("Updating listener to forward \(mediaIds)")
            do { try await listener.components.set(LiveMediaListener(mediaIds: mediaIds)) }
            catch { logger.error("Couldn't update listener \(listener.id): \(error)") }
        }
    }
    
    public func useAsListener(_ listenerEid: EntityID)
    {
        listenerCancellables.forEach { $0.cancel() }; listenerCancellables.removeAll()
        if let old = self.listener, old.id != listenerEid
        {
            // The position system follows the first entity it finds with this component, which
            // with two of them may well be the one we just stopped listening from.
            mapper.guiForEid(old.id)?.components.remove(AudioListenerComponent.self)

            // Withdraw the old listener's forward requests, or the SFU keeps streaming to it.
            // (After a reconnect the old entity is already gone, and there's nothing to clear.)
            if client.place.entities[old.id] != nil
            {
                Task { @MainActor in
                    do { try await old.components.set(LiveMediaListener(mediaIds: [])) }
                    catch { logger.error("Couldn't clear old listener \(old.id): \(error)") }
                }
            }
        }

        let listener = client.place.entities[listenerEid]!
        let guient = self.mapper.guiForEid(listenerEid)!
        logger.info("Using \(listenerEid) as RealityKit listener")

        // TODO: When non-immersive, set it to be an "ears" sub-entity which is always pointed "forwards" in the camera perspective
        // The position system reads the listener pose off this entity every frame.
        guient.components.set(AudioListenerComponent())
        
        // Setup listeners to get incoming tracks. Just ask to get everything (except our own audio) forwarded.
        self.listener = listener
        streamIds.removeAll()
        client.placeState.observers[LiveMedia.self].addedWithInitial.sink { eid, liveMedia in
            guard let edata = self.client.placeState.current.entities[eid] else { return }
            guard edata.ownerClientId != self.client.cid else { return }
            self.streamIds.insert(liveMedia.mediaId)
            let callback = self.addon?.mediaAdded(eid, liveMedia)
            self.state[liveMedia.mediaId] = SpatialAudioPlaybackState(streamId: liveMedia.mediaId, eid: eid, callback: callback)
            self.updateListener(speakerEnabled: self.client.speakerEnabled)
        }.store(in: &listenerCancellables)
        client.placeState.observers[LiveMedia.self].removed.sink { edata, liveMedia in
            self.streamIds.remove(liveMedia.mediaId)
            self.updateListener(speakerEnabled: self.client.speakerEnabled)
            self.stop(streamId: liveMedia.mediaId)
            self.addon?.mediaRemoved(edata.id, liveMedia)
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
        guard let stream = stream as? DataChannelMediaStream else
        {
            streamLogger.error("Voice is carried on data channels; cannot play \(type(of: stream))")
            return
        }

        do { try client.voiceEngine.play(stream, pcm: playState.pcmCallback) }
        catch
        {
            streamLogger.error("Failed to play voice from entity \(netent.id): \(error)")
            stop(streamId: playState.streamId)
            return
        }
        // Which entity the position system should follow for this stream.
        guient.components.set(VoiceSourceComponent(mediaId: stream.mediaId, engine: client.voiceEngine))
        streamLogger.info("Successfully set up audio renderer \(netent.id)")
    }

    func stop(streamId: MediaStreamId)
    {
        guard let playState = state[streamId] else { return }
        var streamLogger = logger!
        streamLogger[metadataKey: "mediaId"] = .string(streamId)
        streamLogger.info("Stopping \(playState.streamId); tearing down LiveMedia renderer")

        client.voiceEngine.stop(mediaId: streamId)
        state[streamId] = nil
        mapper.guiForEid(playState.eid)?.components.remove(VoiceSourceComponent.self)
    }
    
    /// Stop playing, and let go of everything this player set up. The engine itself keeps
    /// running: it is the client's, and the microphone is on it.
    public func stop()
    {
        streamCancellables.forEach { $0.cancel() }; streamCancellables.removeAll()
        listenerCancellables.forEach { $0.cancel() }; listenerCancellables.removeAll()
        sessionCancellables.forEach { $0.cancel() }; sessionCancellables.removeAll()
        for streamId in state.keys { stop(streamId: streamId) }
    }
    
    public typealias PCMCallback = VoiceEngine.PCMCallback
    public struct ListenerAddon
    {
        public let mediaAdded: (EntityID, LiveMedia) -> PCMCallback?
        public let mediaRemoved: (EntityID, LiveMedia) -> Void
        public init(mediaAdded: @escaping (EntityID, LiveMedia) -> PCMCallback?, mediaRemoved: @escaping (EntityID, LiveMedia) -> Void)
        {
            self.mediaAdded = mediaAdded
            self.mediaRemoved = mediaRemoved
        }
    }
}

@MainActor
fileprivate class SpatialAudioPlaybackState
{
    let streamId: MediaStreamId
    let eid: EntityID
    let pcmCallback: SpatialAudioPlayer.PCMCallback?

    fileprivate init(streamId: MediaStreamId, eid: EntityID, callback: SpatialAudioPlayer.PCMCallback? = nil)
    {
        self.streamId = streamId
        self.eid = eid
        self.pcmCallback = callback
    }
}

