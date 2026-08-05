//
//  AlloClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenCombineShim
import Logging
import simd

/// A persistent connection as a client to an AlloPlace. If disconnected by temporary network issues, it will try to reconnect automatically.
@MainActor
open class AlloClient : AlloSessionDelegate, ObservableObject, Identifiable, EntityMutator, Equatable
{
    /// Convenient access to the contents of the connected Place.
    public private(set) lazy var place = Place(state: placeState, client: self)
    /// Access to the more complicated underlying data model for the connected Place.
    public let placeState: PlaceState
    
    /// URL of the place we're trying to always stay connected to
    let url: URL
    /// The identity we'll authenticate as when connecting
    let identity: Identity
    /// The avatar we will ask to spawn as when connecting
    let avatarDesc: EntityDescription
    /// The EntityID of the avatar we have _when connected_. Note that this might change if our avatar was respawned when reconnecting! So this can change multiple times during the lifetime of the AlloClient.
    @Published public private(set) var avatarId: EntityID? { didSet { isAnnounced = avatarId != nil } }
    public var avatar: Entity? {
        guard let aeid = self.avatarId else { return nil }
        return place.entities[aeid]
    }
    /// Fetch the convenience accessor for our own avatar Entity, so that we can modify it. This will only throw in case of task cancellation.
    public func findAvatar() async throws -> Entity
    {
        var avatarId: EntityID? = self.avatarId
        var iter = self.$avatarId.values.compactMap({ $0 }).makeAsyncIterator()
        while let maybeId = await iter.next()
        {
            try Task.checkCancellation()
            if maybeId != nil { avatarId = maybeId; break }
        }
        try Task.checkCancellation()
        return try await place.findEntity(id: avatarId!)
    }
    /// Being announced means to have successfully connected and authenticated.
    @Published public private(set) var isAnnounced: Bool = false
    public private(set) var placeName: String?
    open var transport: Transport! = nil
    public let connectionOptions: TransportConnectionOptions
    /// The underlying network connection to the AlloPlace. This will change for each connection try.
    // TODO: oof don't make it nonisolated! this will race!
    public nonisolated(unsafe) var session: AlloSession! = nil
    
    var currentIntent = Intent(ackStateRev: 0) {
        didSet {
            Task { await heartbeat.markChanged() }
        }
    }
    private var movementIntentRepeat: Task<Void, Never>? = nil
    lazy var heartbeat: HeartbeatTimer = {
        /// Keep a shorter coalesce than server so we ack before the next change; longer keepalive so we don't send an unnecessary keepalive juust before the server's keepalive.
        return HeartbeatTimer(coalesceDelay: 5_000_000, keepaliveDelay: 1_100_000_000) {
            self.sendIntent()
        }
    }()
    
    public static func == (lhs: AlloClient, rhs: AlloClient) -> Bool
    {
        // .id is `nil` until the connection is established, so we can't really use that.
        return lhs.url == rhs.url && lhs.identity == rhs.identity
    }
    
    public var logger = Logger(labelSuffix: "client")

    // MARK: - Assets

    /// Where assets fetched from the place are kept. Keyed by content address, so an entry can
    /// never go stale and nothing ever needs invalidating. Replace it before connecting to put the
    /// cache somewhere else.
    public var assetCache = AssetStore(directory: AssetStore.defaultCacheDirectory)
    /// Fetches in flight, so a room referencing one mesh from five entities does one GET.
    var assetFetches: [AssetID: Task<AssetStore.Entry, any Error>] = [:]

    // MARK: - Connection state related

    public private(set) var connectionStatus = ConnectionStatus()
    public let state = StateMachine<ClientConnectionState>(.disconnected, label: "Client")
    private var connectTask: Task<Void, Never>? = nil
    
    public nonisolated(unsafe) var cid: UUID? { session.clientId }
    public var id: String? { cid?.uuidString }
    
    public init(url: URL, identity: Identity, avatarDescription: EntityDescription, connectionOptions: TransportConnectionOptions = TransportConnectionOptions(routing: .direct))
    {
        Allonet.Initialize()
        self.url = url
        self.identity = identity
        self.avatarDesc = avatarDescription
        self.connectionOptions = connectionOptions
        self.placeState = PlaceState(logger: logger)
        self.reset()
    }
    
    /// Connect, and stay connected until a permanent connection error happens, or user disconnects.
    public func stayConnected()
    {
        guard !state.current.isStayingConnected else { return }
        logger.info("Going from .disconnected to .waitingToRetry")
        state.transition(to: .waitingToRetry(attempt: 0))
        connectionStatus.reconnection = .waitingForReconnect
        scheduleConnect(attempt: 0)
    }

    private func scheduleConnect(attempt: Int)
    {
        // Reconnection backoff with exponential delay, capped at 1 minute
        let delaySeconds = attempt == 0 ? 0.0 : min(60.0, pow(2.0, Double(attempt)))
        connectionStatus.willReconnectAt = delaySeconds > 0 ? Date().addingTimeInterval(delaySeconds) : nil
        logger.info("Connection attempt \(attempt) in \(delaySeconds) seconds")

        connectTask = Task { [weak self] in
            guard let self else { return }

            if delaySeconds > 0 {
                logger.info("Waiting for reconnect in \(String(format: "%.1f seconds", delaySeconds))")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            state.transition(to: .connecting(attempt: attempt))
            connectionStatus.reconnection = .connecting
            connectionStatus.willReconnectAt = nil
            connectionStatus.signalling = .connecting

            await self.connect()
        }
    }
    
    open func reset()
    {
        preconditionFailure("This method must be overridden by a concrete subclass, and it must call reset(with:)")
    }
    
    open func reset(with transport: Transport)
    {
        logger.info("Resetting AlloSession within client")
        self.transport = transport
        session = AlloSession(side: .client, transport: transport)
        session.delegate = self
        avatarId = nil
        isAnnounced = false
        // Anyone awaiting an entity was waiting on the connection we just threw away.
        placeState.failOutstandingEntityWaits()
    }

    
    /// Drop the current connection and connect again *immediately*, staying connected afterwards.
    /// For when the connection came up but is unusable — an app that couldn't finish its setup
    /// against a place that's still restarting, say. There is no backoff here, because only the
    /// caller knows whether its reason to give up recurs; pace the calls if it can.
    ///
    /// Only meaningful once announced: any earlier and the reconnection machinery already owns
    /// the connection, and dropping it under itself is an invalid state transition.
    public func reconnect()
    {
        guard case .announced = state.current else { return }
        logger.info("Reconnecting on request")
        reconnectWasRequested = true
        session.disconnect()
    }

    /// Disconnect from peers and remain disconnected until asked to connect again by user
    public func disconnect()
    {
        guard state.current.isStayingConnected else { return }
        logger.info("Disconnecting...")
        connectTask?.cancel()
        connectTask = nil
        state.transition(to: .disconnected)
        connectionStatus.reconnection = .idle
        connectionStatus.willReconnectAt = nil
        avatarId = nil
        // Scoring belongs to the run of connections we just ended; a later stayConnected() starts
        // fresh rather than inheriting how badly the previous one was going.
        announcedAt = nil
        shortLivedConnections = 0
        reconnectWasRequested = false
        session.disconnect()
        reset()
    }
    
    /// The place's own HTTP(S) URL. The original schema is alloplace2://; signalling and asset
    /// transfer both speak to it over http(s), so the schema is rewritten here once. Throws rather
    /// than trapping because the URL comes from the user, not from us.
    public var httpURL: URL
    {
        get throws
        {
            guard var httpcomps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            guard let scheme = url.scheme else { throw URLError(.badURL) }
            httpcomps.scheme = scheme.last == "s" ? "https" : "http"
            guard let httpUrl = httpcomps.url else { throw URLError(.badURL) }
            return httpUrl
        }
    }

    open func performHTTPSignalling(offer: SignallingPayload) async throws -> SignallingPayload
    {
        var request = URLRequest(url: try httpURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(offer)
        let (data, response) = try await URLSession.shared.data(for: request as URLRequest)
        let http = response as! HTTPURLResponse
        guard http.statusCode >= 200 && http.statusCode < 300 else {
            throw AlloverseError(
                domain: AlloverseErrorCode.domain,
                code: AlloverseErrorCode.failedSignalling.rawValue,
                description: "HTTP error \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "(no data)")"
            )
        }
        return try JSONDecoder().decode(SignallingPayload.self, from: data)
    }

    private func connect() async
    {
        // Bound once. `session` is a var that reset() swaps, and every step below suspends, so
        // re-reading it would let a late attempt hand its answer to the connection that replaced
        // it — negotiating one session's offer onto another's peer.
        let session = self.session!
        do {
            logger.info("Trying to connect to \(url)...")
            let offer = try await session.generateOffer()
            let answer = try await performHTTPSignalling(offer: offer)
            guard isCurrent(session) else { return }
            connectionStatus.signalling = .connected
            try await session.acceptAnswer(answer)
            // Guard: if we disconnected between awaits, bail out
            guard isCurrent(session), case .connecting = state.current else { return }
            logger.info("AlloClient RTC initial signalling complete")
        } catch {
            guard isCurrent(session) else { return }
            failConnectionAttempt(error)
        }
    }

    /// Whether `session` is still the connection this client is running on. Anything that suspends
    /// and then wants to act on the session it started with has to ask: `reset()` replaces it on
    /// every reconnection, and the state machine alone can't tell two attempts apart.
    private func isCurrent(_ session: AlloSession) -> Bool { session === self.session }

    /// End a failed connection attempt. A place that is restarting refuses signalling, and admits
    /// nobody until its authentication provider is back; both clear up on their own, so only a
    /// fatal error — rejected credentials, incompatible protocol — ends the stay-connected loop.
    /// Anything else re-arms the backoff, or a single blip would leave us disconnected for good.
    private func failConnectionAttempt(_ error: Error)
    {
        // Cancelled or disconnected during the awaits that led here: not ours to fail.
        guard case .connecting(let attempt) = state.current else { return }
        connectionStatus.signalling = .failed
        connectionStatus.lastError = error
        state.transition(to: .failed(error: error))

        guard (error as? AlloverseError)?.isFatal != true else
        {
            logger.error("Permanent connection failure, giving up: \(error)")
            disconnect()
            return
        }

        logger.error("Connection attempt \(attempt) failed, will retry: \(error)")
        // Detach before tearing the half-open session down: the transport calls session(didDisconnect:)
        // synchronously from disconnect(), which would schedule a second, competing attempt.
        session.delegate = nil
        session.disconnect()
        reset()
        let next = attempt + 1
        state.transition(to: .waitingToRetry(attempt: next))
        connectionStatus.reconnection = .waitingForReconnect
        scheduleConnect(attempt: next)
    }

    nonisolated public func session(didConnect sess: AlloSession)
    {
        Task
        { @MainActor in
            // Guard: if we disconnected between transport connect and this callback, bail
            guard case .connecting = state.current else { return }
            self.connectionStatus.reconnection = .connected

            logger = logger.forClient(sess.clientId!)
            logger.info("Connected as \(sess.clientId!)")

            // Bounded: a place that accepts the connection and then never answers would otherwise
            // leave us here for the lifetime of the process, connected and unannounced, with no
            // retry pending — the same dead end as giving up, just quieter.
            let response = await sess.request(interaction: Interaction(
                type: .request,
                senderEntityId: "",
                receiverEntityId: Interaction.PlaceEntity,
                body: .announce(version: Allonet.version().description, identity: identity, avatar: avatarDesc)
            ), timeout: announceTimeout)
            // Guard again: disconnect may have happened during announce, or this may be a stale
            // attempt answering after reset() already moved us to a different session.
            guard isCurrent(sess), case .connecting = state.current else { return }
            guard let response else
            {
                logger.error("Place didn't answer our announce within \(announceTimeout)s")
                failConnectionAttempt(AlloverseError(code: AlloverseErrorCode.disconnected,
                                                     description: "Place didn't answer our announce"))
                return
            }
            guard case .announceResponse(let avatarId, let placeName) = response.body else
            {
                logger.error("Announce failed: \(response)")
                failConnectionAttempt(AlloverseError(with: response.body))
                return
            }
            logger.info("Received announce response: \(response.body)")
            state.transition(to: .announced(avatarId: avatarId, placeName: placeName))
            announcedAt = Date()
            self.avatarId = avatarId
            self.placeName = placeName
            self.connectionStatus.hasReceivedAnnounceResponse = true
            await heartbeat.markChanged()
        }
    }
    
    public func session(didDisconnect sess: AlloSession)
    {
        logger.info("Disconnected")
        avatarId = nil
        connectionStatus.signalling = .failed

        // If already disconnected (user-initiated via disconnect()), nothing more to do
        guard state.current.isStayingConnected else { return }

        // Transport-initiated disconnect: auto-reconnect
        let attempt = nextAttemptAfterDrop()
        reset()
        state.transition(to: .waitingToRetry(attempt: attempt))
        connectionStatus.reconnection = .waitingForReconnect
        scheduleConnect(attempt: attempt)
    }

    /// How hard to back off after losing a connection that had been established.
    ///
    /// A connection that stood up for a while and then dropped is a blip: come straight back, which
    /// is what makes recovery from a place restart quick. One that died moments after announcing is
    /// a flap, and coming straight back to it just spins — two backends sharing an app token evict
    /// each other for as long as both live, at the rate of a handshake. So an unstable connection
    /// escalates, and a stable one resets the escalation.
    ///
    /// `reconnect()` is exempt: the caller asked for this drop and owns the pacing of its own
    /// reasons for asking.
    private func nextAttemptAfterDrop() -> Int
    {
        defer { announcedAt = nil }
        if reconnectWasRequested
        {
            // Skipped, not reset: how badly involuntary drops have been going isn't news the app
            // asking for a reconnect gets to erase.
            reconnectWasRequested = false
            return 0
        }
        let stableFor = announcedAt.map { Date().timeIntervalSince($0) } ?? 0
        shortLivedConnections = stableFor >= Self.stableConnectionThreshold ? 0 : shortLivedConnections + 1
        // Still 0 for the first drop of a healthy connection, so that one retries immediately.
        return max(state.current.attempt, shortLivedConnections - 1)
    }
    /// How long a connection has to last to count as having worked.
    static let stableConnectionThreshold: TimeInterval = 30
    /// Generous: the place may be waiting on its own authentication provider before it can answer.
    var announceTimeout: TimeInterval = 30
    private var announcedAt: Date?
    private var shortLivedConnections = 0
    private var reconnectWasRequested = false
    
    public func session(_: AlloSession, didReceiveMediaStream: MediaStream)
    {
        // Playback is handled in SpatialAudioPlayer
        // TODO: If I expose incomingTracks through Combine, why even have this callback?
    }
    
    public func session(_: AlloSession, didRemoveMediaStream: MediaStream)
    {}
    
    // MARK: - Interactions, intent and place state
    
    public struct InteractionHandler<T>
    {
        private var handlers: [String: @MainActor (Interaction) async -> T] = [:]
        
        // Store a handler for a specific request type, returning a response. Example:
        // client.responders["custom"] = { // 'custom' is taken from the first part of the enum case name
        //    request async -> Interaction in
        //    return request.makeResponse(with: .custom(value: [:]))
        //}
        public subscript(caseName: String) -> ((Interaction) async -> T)? {
            get { handlers[caseName] }
            set { handlers[caseName] = newValue }
        }
        
        // TODO: register handlers for specific entities?
    }
    
    /// Use this to register handlers for Interactions of specific request types
    public var responders = InteractionHandler<Interaction>()
    /// Use this to register handlers for all other kinds of Interactions.
    public var handlers = InteractionHandler<Void>()
    
    public func session(_ sess: AlloSession, didReceiveInteraction inter: Interaction)
    {
        Task { @MainActor in
            do
            {
                try await self.handle(interaction: inter, on: sess)
            }
            catch (let e as AlloverseError)
            {
                logger.error("Error handling interaction: \(e)")
                sess.send(interaction: inter.makeResponse(with: e.asBody))
            }
        }
    }

    /// Answers go back to `sess`, the session the request came in on, not to whichever session is
    /// current when the responder finishes: app responders await, and a reconnection in that window
    /// would otherwise address the reply to a place that never asked.
    func handle(interaction inter: Interaction, on sess: AlloSession) async throws(AlloverseError)
    {
        if inter.type == .request
        {
            guard let handler = responders[inter.body.caseName] else
            {
                throw AlloverseError(code: AlloverseErrorCode.unhandledRequest, description: "No handler for \(inter.body.caseName)")
            }
            let response = try await handler(inter)
            sess.send(interaction: response)
        }
        else
        {
            guard let handler = handlers[inter.body.caseName] else
            {
                logger.error("No handler registered for interaction: \(inter)")
                return
            }
            await handler(inter)
        }
    }
    
    public func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        //logger.trace("Received place change for revision \(changeset.fromRevision) -> \(changeset.toRevision)")
        // The ack path owns only ackStateRev; other intent fields (movement etc) belong to app
        // code and must survive, or e.g. held-key movement halts. Cf. allonet1 _alloclient_set_intent.
        guard placeState.applyChangeSet(changeset) else
        {
            logger.warning("Failed to apply change set, asking for a full diff")
            currentIntent.ackStateRev = 0
            return
        }
        currentIntent.ackStateRev = changeset.toRevision
    }
    
    public func session(_: AlloSession, didReceiveIntent intent: Intent)
    {
        assert(false) // should never happen on client
    }
    public func session(_: AlloSession, didReceiveLog message: StoredLogMessage)
    {
        assert(false) // should never happen on client
    }
    
    private func sendIntent()
    {
        guard isAnnounced else { return }
        session.send(currentIntent)
    }
    
    // MARK: - Movement

    /// Set the desired movement direction in place space. Normalized -1..1 per axis;
    /// x is +X and y is -Z, so a camera-relative UI rotates the vector before setting it.
    /// Set to .zero to stop. The server applies speed and delta time.
    public var moveDirection: SIMD2<Float>
    {
        get { currentIntent.moveDirection }
        set {
            // Key-repeat and rollover resend the same vector; only a change is worth an intent.
            guard newValue != currentIntent.moveDirection else { return }
            currentIntent.moveDirection = newValue
            startMovementIntentRepeatIfNeeded()
        }
    }

    /// Intents ride an unreliable channel, and the idle keepalive is ~1.1s: losing the packet that
    /// stops movement (or releases a grab) would let the server keep going for that long. So while
    /// active - and briefly after stopping, since the final zero/release is the packet that must not
    /// be lost - repeat the intent at a fixed rate, as allonet1 did unconditionally.
    private func startMovementIntentRepeatIfNeeded()
    {
        guard movementIntentRepeat == nil else { return }
        movementIntentRepeat = Task { [weak self] in
            var idleRepeats = 0
            while !Task.isCancelled, idleRepeats < 10
            {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
                guard let self else { break }
                // Same dead zone the simulation uses, or drift below it would repeat forever.
                let active = simd_length(self.currentIntent.moveDirection) >= MovementSimulation.inputDeadZone
                    || self.currentIntent.grab != nil
                idleRepeats = active ? 0 : idleRepeats + 1
                self.sendIntent()
            }
            self?.movementIntentRepeat = nil
        }
    }

    // MARK: - Grabbing

    /// Grab a Grabbable entity with your avatar, keeping its current pose relative to you:
    /// it follows as you move, until releaseGrab(). For pointer-style dragging, follow up
    /// with moveGrabbed(toWorldTransform:) instead.
    public func grab(entityId: EntityID)
    {
        guard let avatarId, let avatar = place.entities[avatarId], let target = place.entities[entityId] else {
            logger.warning("Can't grab \(entityId): not announced, or no such entity")
            return
        }
        let offset = avatar.transformToWorld.inverse * target.transformToWorld
        currentIntent.grab = GrabIntent(entity: entityId, grabber: avatarId, grabberFromEntity: offset)
        startMovementIntentRepeatIfNeeded()
    }

    /// While grabbing, steer the grabbed entity toward this world transform. The place
    /// server still applies the entity's Grabbable constraints.
    public func moveGrabbed(toWorldTransform target: simd_float4x4)
    {
        guard var grab = currentIntent.grab, let grabber = place.entities[grab.grabber] else { return }
        grab.grabberFromEntity = grabber.transformToWorld.inverse * target
        currentIntent.grab = grab
    }

    public func releaseGrab()
    {
        // The repeat task keeps sending briefly, so the release survives packet loss.
        currentIntent.grab = nil
    }

    // MARK: - Convenience API
    
    public func request(receiverEntityId: EntityID, body: InteractionBody) async -> Interaction
    {
        let interaction = Interaction(type: .request, senderEntityId: avatarId ?? "", receiverEntityId: receiverEntityId, body: body)
        // Losing the connection between two of a caller's requests is ordinary, not a bug on its
        // part, so answer with the same error a request in flight would get rather than trapping.
        guard avatarId != nil else
        {
            return interaction.makeResponse(with: AlloverseError(
                code: AlloverseErrorCode.disconnected,
                description: "Not announced to a place; can't send \(body.caseName)").asBody)
        }
        return await session.request(interaction: interaction)
    }
    
    public func createEntity(from description: EntityDescription) async throws(AlloverseError) -> EntityID
    {
        let resp = await request(receiverEntityId: Interaction.PlaceEntity, body: .createEntity(description))
        guard case .createEntityResponse(let entityId) = resp.body else {
            throw AlloverseError(with: resp.body)
        }
        return entityId
    }
    
    public func removeEntity(entityId: EntityID, mode: EntityRemovalMode) async throws(AlloverseError)
    {
        let resp = await request(receiverEntityId: Interaction.PlaceEntity, body: .removeEntity(entityId: entityId, mode: mode))
        guard case .success = resp.body else {
            throw AlloverseError(with: resp.body)
        }
    }
    
    public func changeEntity(entityId: EntityID, addOrChange: [any Component] = [], remove: [ComponentTypeID] = []) async throws(AlloverseError)
    {
        let resp = await request(receiverEntityId: Interaction.PlaceEntity, body: .changeEntity(entityId: entityId, addOrChange: addOrChange.map { AnyComponent($0) }, remove: remove))
        guard case .success = resp.body else {
            throw AlloverseError(with: resp.body)
        }
    }
}

protocol EntityMutator: AnyObject
{
    func changeEntity(entityId: EntityID, addOrChange: [any Component], remove: [ComponentTypeID]) async throws(AlloverseError)
}
