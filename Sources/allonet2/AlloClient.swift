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
    
    public var logger = Logger(label: "client")
    
    // MARK: - Connection state related
    
    public private(set) var connectionStatus = ConnectionStatus()
    
    private var connectTask: Task<Void, Never>? = nil
    private var reconnectionAttempts = 0
    
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
    
    private var connectionLoopCancellable: AnyCancellable?
    /// Connect, and stay connected until a permanent connection error happens, or user disconnects.
    public func stayConnected()
    {
        guard connectionLoopCancellable == nil else { return }
        
        // Move out of the idle state since we've been asked to get going.
        if connectionStatus.reconnection == .idle {
            logger.info("Going from .idle to .waitingForReconnect")
            connectionStatus.reconnection = .waitingForReconnect
        }
        
        connectionLoopCancellable = connectionStatus.$reconnection.receive(on: DispatchQueue.main).sink
        { [weak self] nextState in
            guard let self = self else { return }
            logger.info("Reconnection state: \(connectionStatus.reconnection)")
            switch nextState {
            case .waitingForReconnect:
                self.handleWaitingForReconnect()
            case .idle:
                disconnect()
            default:
                break
            }
        }
    }
    
    private func handleWaitingForReconnect()
    {
        // Prevent concurrent connection attempts.
        guard connectTask == nil else { return }
        
        // Reconnection backoff with exponential delay and a cap at 1m/try
        let delaySeconds = reconnectionAttempts == 0 ? 0 : min(60, pow(2.0, Double(reconnectionAttempts)))
        connectionStatus.willReconnectAt = delaySeconds > 0 ? Date().addingTimeInterval(delaySeconds) : nil
        reconnectionAttempts += 1
        logger.info("connection attempt \(reconnectionAttempts) in \(delaySeconds) seconds")
        
        // Schedule connect() to be called at willReconnectAt.
        connectTask = Task { [weak self] in
            guard let self = self else { return }
            
            let delay = connectionStatus.willReconnectAt?.timeIntervalSinceNow ?? 0
            logger.info("waiting for reconnect in \(String(format: " %.1f seconds", delay))")
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // Clear the task and reconnectDate before connecting.
            await MainActor.run {
                self.connectTask = nil
                connectionStatus.willReconnectAt = nil
            }
            logger.info("connecting...")
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
    }

    
    /// Disconnect from peers and remain disconnected until asked to connect again by user
    public func disconnect()
    {
        logger.info("Disconnecting...")
        connectTask?.cancel()
        connectTask = nil
        connectionLoopCancellable?.cancel()
        connectionLoopCancellable = nil
        connectionStatus.willReconnectAt = nil
        reconnectionAttempts = 0
        avatarId = nil
        session.disconnect()
        reset()
    }
    
    private func connect() async
    {
        connectionStatus.signalling = .connecting
        precondition(connectionStatus.reconnection == .waitingForReconnect, "Trying to connect while \(connectionStatus.reconnection)")
        DispatchQueue.main.async {
            self.connectionStatus.reconnection = .connecting
        }
        
        do {
            logger.info("Trying to connect to \(url)...")
            let offer = try await session.generateOffer()
            
            // Original schema is alloplace2://. We call this with HTTP(S) to establish a WebRTC connection, which means we need to rewrite the
            // schema to be http(s).
            guard var httpcomps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            guard let scheme = url.scheme else { throw URLError(.badURL) }
            httpcomps.scheme = scheme.last == "s" ? "https" : "http"
            guard let httpUrl = httpcomps.url else { throw URLError(.badURL) }
            
            var request = URLRequest(url: httpUrl)
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
            connectionStatus.signalling = .connected
            let answer = try JSONDecoder().decode(SignallingPayload.self, from: data)
            
            // Use session's transport methods
            try await session.acceptAnswer(answer)
            logger.info("AlloClient RTC initial signalling complete")
        } catch (let e) {
            logger.error("failed to connect: \(e)")
            DispatchQueue.main.async {
                self.connectionStatus.lastError = e
                self.connectionStatus.reconnection = .idle
                self.connectionStatus.signalling = .failed
            }
        }
    }
    
    nonisolated public func session(didConnect sess: AlloSession)
    {
        Task
        { @MainActor in
            self.reconnectionAttempts = 0
            self.connectionStatus.reconnection = .connected
            
            logger = logger.forClient(sess.clientId!)
            logger.info("Connected as \(sess.clientId!)")

            let response = await sess.request(interaction: Interaction(
                type: .request,
                senderEntityId: "",
                receiverEntityId: Interaction.PlaceEntity,
                body: .announce(version: Allonet.version().description, identity: identity, avatar: avatarDesc)
            ))
            guard case .announceResponse(let avatarId, let placeName) = response.body else
            {
                logger.error("Announce failed: \(response)")
                self.connectionStatus.lastError = AlloverseError(with: response.body)
                self.connectionStatus.reconnection = .idle
                self.disconnect()
                return
            }
            logger.info("Received announce response: \(response.body)")
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
        self.connectionStatus.signalling = .failed
        if(false)
        {
            // TODO: Propagate disconnection reason, and notice if it's permanent
            // state = .error ...
        }
        else if(self.connectionLoopCancellable != nil)
        {
            self.connectionStatus.reconnection = .waitingForReconnect
        }
        else
        {
            self.connectionStatus.reconnection = .idle
        }
    }
    
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
    
    public func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    {
        Task { @MainActor in
            do
            {
                try await self.handle(interaction: inter)
            }
            catch (let e as AlloverseError)
            {
                logger.error("Error handling interaction: \(e)")
                session.send(interaction: inter.makeResponse(with: e.asBody))
            }
        }
    }
    
    func handle(interaction inter: Interaction) async throws(AlloverseError)
    {
        if inter.type == .request
        {
            guard let handler = responders[inter.body.caseName] else
            {
                throw AlloverseError(code: AlloverseErrorCode.unhandledRequest, description: "No handler for \(inter.body.caseName)")
            }
            let response = try await handler(inter)
            session.send(interaction: response)
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
        guard placeState.applyChangeSet(changeset) else
        {
            logger.warning("Failed to apply change set, asking for a full diff")
            currentIntent = Intent(ackStateRev: 0)
            return
        }
        currentIntent = Intent(ackStateRev: changeset.toRevision)
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
    
    // MARK: - Convenience API
    
    public func request(receiverEntityId: EntityID, body: InteractionBody) async -> Interaction
    {
        precondition(avatarId != nil, "Must be connected and announced to send a request")
        return await session.request(interaction: Interaction(type: .request, senderEntityId: avatarId!, receiverEntityId: receiverEntityId, body: body))
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
