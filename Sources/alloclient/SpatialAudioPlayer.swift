//
//  SpatialAudioPlayer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-09-12.
//

import allonet2
import AlloAudio
import OpenCombineShim
import Logging
import simd

/// Plays the voices of the entities around the local avatar, spatialised through the client's
/// `VoiceEngine`.
///
/// Everything it needs comes from `PlaceState`: which entity carries which `LiveMedia`, where the
/// listener and the speakers are, and what `AudioOccluder` stands between them. Nothing here
/// touches a renderer, so a client drawing the place with RealityKit, with something else, or not
/// at all gets the same spatial voice.
///
/// ```swift
/// let player = SpatialAudioPlayer(client: client)
/// player.useAsListener(headEntityId)   // after announce, once the avatar exists
/// ```
///
/// Positions are place space - the metres the place itself is authored in. A renderer that draws
/// the place at some other scale, as a diorama on a table, does not change how far away a voice
/// sounds.
@MainActor
public class SpatialAudioPlayer
{
    let client: AlloUserClient
    let addon: ListenerAddon?
    /// Which entity each stream we currently play comes out of. Playout resources only:
    /// emptied whenever a stream stops, including while merely deafened.
    private(set) var playing: [MediaStreamId: EntityID] = [:]
    var streamCancellables: Set<AnyCancellable> = []
    var listenerCancellables: Set<AnyCancellable> = []
    var logger: Logger! = Logger(labelSuffix: "spatialaudioplayer")

    /// Construct a player that reacts to `client`'s network events and plays through its
    /// `voiceEngine`. `addon` is offered every media stream as it appears, and may return a
    /// callback that sees the rendered samples - a level meter or a speaking indicator.
    ///
    /// Announce must have completed and the avatar must exist before constructing this.
    public init(client: AlloUserClient, addon: ListenerAddon? = nil)
    {
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

        client.placeState.observers.placeChanged.sink { [weak self] contents in
            self?.updatePoses(in: contents)
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
        for streamId in playing.keys { stop(streamId: streamId) }
    }

    private var listener: allonet2.Entity? = nil
    /// The media around us we want to hear, and what the addon wants done with their samples.
    /// Both follow the `LiveMedia` components, not the streams: the place stops forwarding while
    /// we are deafened, and the very same media ids come back on undeafen.
    private var streamIds = Set<MediaStreamId>()
    private var pcmCallbacks: [MediaStreamId: PCMCallback] = [:]
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

    /// Hear the place from this entity: its world position and orientation become the ears.
    /// Usually the local avatar's head. There is only ever one, and naming a second withdraws the
    /// first one's forwarding requests.
    public func useAsListener(_ listenerEid: EntityID)
    {
        listenerCancellables.forEach { $0.cancel() }; listenerCancellables.removeAll()
        if let old = self.listener, old.id != listenerEid
        {
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
        logger.info("Listening from entity \(listenerEid)")

        // Setup listeners to get incoming tracks. Just ask to get everything (except our own audio) forwarded.
        self.listener = listener
        streamIds.removeAll()
        pcmCallbacks.removeAll()
        client.placeState.observers[LiveMedia.self].addedWithInitial.sink { eid, liveMedia in
            guard let edata = self.client.placeState.current.entities[eid] else { return }
            guard edata.ownerClientId != self.client.cid else { return }
            self.streamIds.insert(liveMedia.mediaId)
            self.pcmCallbacks[liveMedia.mediaId] = self.addon?.mediaAdded(eid, liveMedia)
            self.updateListener(speakerEnabled: self.client.speakerEnabled)
            // The stream can be here before the component explaining it, on a reconnection or
            // when an entity gains LiveMedia while its channel is already open.
            if let stream = self.client.session.incomingStreams[liveMedia.mediaId] { self.play(stream: stream) }
        }.store(in: &listenerCancellables)
        client.placeState.observers[LiveMedia.self].removed.sink { edata, liveMedia in
            self.streamIds.remove(liveMedia.mediaId)
            self.pcmCallbacks[liveMedia.mediaId] = nil
            self.updateListener(speakerEnabled: self.client.speakerEnabled)
            self.stop(streamId: liveMedia.mediaId)
            self.addon?.mediaRemoved(edata.id, liveMedia)
        }.store(in: &listenerCancellables)
        updatePoses(in: client.placeState.current)
    }

    func play(stream: MediaStream)
    {
        guard stream.streamDirection.isRecv else { return }
        var streamLogger = logger!
        streamLogger[metadataKey: "mediaId"] = .string(stream.mediaId)
        streamLogger.info("Playing \(stream)")

        guard let eid = entity(carrying: stream.mediaId) else
        {
            streamLogger.error("No entity around us carries LiveMedia \(stream.mediaId); not playing it")
            return
        }
        guard let stream = stream as? DataChannelMediaStream else
        {
            streamLogger.error("Voice is carried on data channels; cannot play \(type(of: stream))")
            return
        }

        playing[stream.mediaId] = eid
        do { try client.voiceEngine.play(stream, pcm: pcmCallbacks[stream.mediaId]) }
        catch
        {
            streamLogger.error("Failed to play voice from entity \(eid): \(error)")
            stop(streamId: stream.mediaId)
            return
        }
        // A new source starts silent and stays there until it has been placed once.
        updatePoses(in: client.placeState.current)
        streamLogger.info("Successfully set up audio renderer \(eid)")
    }

    /// The entity whose `LiveMedia` names `mediaId`, as the place has it right now. Asked of the
    /// world on every stream rather than remembered from when the component arrived: a stream
    /// outlives no component, but a component outlives many streams.
    private func entity(carrying mediaId: MediaStreamId) -> EntityID?
    {
        client.placeState.current.components[LiveMedia.self].first { $0.value.mediaId == mediaId }?.key
    }

    func stop(streamId: MediaStreamId)
    {
        guard playing.removeValue(forKey: streamId) != nil else { return }
        var streamLogger = logger!
        streamLogger[metadataKey: "mediaId"] = .string(streamId)
        streamLogger.info("Stopping \(streamId); tearing down LiveMedia renderer")

        client.voiceEngine.stop(mediaId: streamId)
    }

    /// Stop playing, and let go of everything this player set up. The engine itself keeps
    /// running: it is the client's, and the microphone is on it.
    public func stop()
    {
        streamCancellables.forEach { $0.cancel() }; streamCancellables.removeAll()
        listenerCancellables.forEach { $0.cancel() }; listenerCancellables.removeAll()
        sessionCancellables.forEach { $0.cancel() }; sessionCancellables.removeAll()
        for streamId in playing.keys { stop(streamId: streamId) }
        streamIds.removeAll()
        pcmCallbacks.removeAll()
    }

    // MARK: - Poses

    /// Whether the listener's pose was usable last time we looked, so a bad one is reported on the
    /// transition rather than at network rate.
    private var listenerIsUsable = true

    /// Tell the engine where the listener and every playing source are, and what stands between
    /// them. Runs once per place changeset - up to 50 Hz while anyone is moving, and not at all
    /// while the place is still - plus once whenever a stream or the listener changes.
    ///
    /// Nothing here interpolates: a voice sounds exactly where the authoritative transform puts
    /// it, which is also where every other client hears it from.
    ///
    /// Poses come off the wire, so a pose that cannot be used is dropped rather than pushed: an
    /// engine fed a NaN compares every distance false and silences the whole place.
    private func updatePoses(in contents: PlaceContents)
    {
        // Nobody to hear: don't compose poses, and don't complain about a listener nothing needs.
        guard let listener, !playing.isEmpty else { return }

        guard let listenerToPlace = contents.transformToWorld(of: listener.id) else
        {
            reportUnusableListener(listener.id, "no finite place-space transform (a Transform is missing, cyclic, or non-finite on it or an ancestor)")
            return
        }
        // Finite, but a transform with no rotation left in it normalises to NaN axes.
        let axes = VoiceEngine.listenerAxes(of: listenerToPlace)
        guard axes.forward.isFinite, axes.up.isFinite else
        {
            reportUnusableListener(listener.id, "a transform with no orientation to point the ears with")
            return
        }
        listenerIsUsable = true

        let engine = client.voiceEngine
        let listenerPosition = listenerToPlace.translation
        engine.setListener(position: listenerPosition, forward: axes.forward, up: axes.up)

        let occluders = AudioOccluders(of: contents)
        for (mediaId, eid) in playing
        {
            // A source the place cannot place keeps the pose it had, rather than jumping to the
            // place origin and shouting in the listener's ear.
            guard let sourceToPlace = contents.transformToWorld(of: eid) else { continue }
            let sourcePosition = sourceToPlace.translation
            engine.setPosition(sourcePosition, for: mediaId)
            engine.setAudible(VoiceEngine.isAudible(distance: simd_distance(listenerPosition, sourcePosition),
                                                    wasAudible: engine.isAudible(mediaId)),
                              for: mediaId)
            let occluded = occluders.isOccluded(from: listenerPosition, to: sourcePosition)
            engine.setOcclusion(occluded ? VoiceEngine.blockedOcclusion : 0, for: mediaId)
        }
    }

    private func reportUnusableListener(_ eid: EntityID, _ problem: String)
    {
        guard listenerIsUsable else { return }
        listenerIsUsable = false
        logger.error("Listener entity \(eid) has \(problem); every voice keeps the pose it already had")
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
