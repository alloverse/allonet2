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

@MainActor
open class AlloClient : AlloSessionDelegate, ObservableObject, Identifiable
{
    /// Convenient access to the contents of the connected Place.
    public private(set) lazy var place = Place(state: placeState, client: self)
    /// Access to the more complicated underlying data model for the connected Place.
    public let placeState = PlaceState()
    
    let url: URL
    let identity: Identity
    let avatarDesc: EntityDescription
    @Published public private(set) var avatarId: EntityID? { didSet { isAnnounced = avatarId != nil } }
    public var avatar: Entity? {
        guard let aeid = self.avatarId else { return nil }
        return place.entities[aeid]
    }
    @Published public private(set) var isAnnounced: Bool = false
    public private(set) var placeName: String?
    open var transport: Transport! = nil
    public let connectionOptions: TransportConnectionOptions
    public var session: AlloSession! = nil
    
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
    
    // MARK: - Connection state related
    
    public private(set) var connectionStatus = ConnectionStatus()
    
    private var connectTask: Task<Void, Never>? = nil
    private var reconnectionAttempts = 0
    
    public var cid: UUID? { session.clientId }
    public var id: String? { cid?.uuidString }
    
    public init(url: URL, identity: Identity, avatarDescription: EntityDescription, connectionOptions: TransportConnectionOptions = TransportConnectionOptions(routing: .direct))
    {
        Allonet.Initialize()
        self.url = url
        self.identity = identity
        self.avatarDesc = avatarDescription
        self.connectionOptions = connectionOptions
        self.reset()
    }
    
    private var connectionLoopCancellable: AnyCancellable?
    /// Connect, and stay connected until a permanent connection error happens, or user disconnects.
    public func stayConnected()
    {
        guard connectionLoopCancellable == nil else { return }
        
        // Move out of the idle state since we've been asked to get going.
        if connectionStatus.reconnection == .idle {
            print("Going from .idle to .waitingForReconnect")
            connectionStatus.reconnection = .waitingForReconnect
        }
        
        connectionLoopCancellable = connectionStatus.$reconnection.receive(on: DispatchQueue.main).sink
        { [weak self] nextState in
            guard let self = self else { return }
            print("\(connectionStatus)")
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
        print("connection attempt \(reconnectionAttempts) in \(delaySeconds) seconds")
        
        // Schedule connect() to be called at willReconnectAt.
        connectTask = Task { [weak self] in
            guard let self = self else { return }
            
            let delay = connectionStatus.willReconnectAt?.timeIntervalSinceNow ?? 0
            print(String(format: "waiting for reconnect in %.1f seconds", delay))
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // Clear the task and reconnectDate before connecting.
            await MainActor.run {
                self.connectTask = nil
                connectionStatus.willReconnectAt = nil
            }
            print("connecting...")
            await self.connect()
        }
    }
    
    open func reset()
    {
        preconditionFailure("This method must be overridden by a concrete subclass, and it must call reset(with:)")
    }
    
    open func reset(with transport: Transport)
    {
        print("Resetting AlloSession within client")
        self.transport = transport
        session = AlloSession(side: .client, transport: transport)
        session.delegate = self
        avatarId = nil
        isAnnounced = false
    }

    
    /// Disconnect from peers and remain disconnected until asked to connect again by user
    public func disconnect()
    {
        print("Disconnecting...")
        connectTask?.cancel()
        connectTask = nil
        connectionLoopCancellable?.cancel()
        connectionLoopCancellable = nil
        connectionStatus.willReconnectAt = nil
        reconnectionAttempts = 0
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
            print("Trying to connect to \(url)...")
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
            print("AlloClient RTC initial signalling complete")
        } catch (let e) {
            print("failed to connect: \(e)")
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
            
            print("Connected as \(sess.clientId!)")

            let response = await sess.request(interaction: Interaction(
                type: .request,
                senderEntityId: "",
                receiverEntityId: Interaction.PlaceEntity,
                body: .announce(version: Allonet.version().description, identity: identity, avatar: avatarDesc)
            ))
            guard case .announceResponse(let avatarId, let placeName) = response.body else
            {
                print("Announce failed: \(response)")
                // TODO: Fill in lastError and make it a permanent disconnect
                self.disconnect()
                return
            }
            print("Received announce response: \(response.body)")
            self.avatarId = avatarId
            self.placeName = placeName
            await heartbeat.markChanged()
        }
    }
    
    nonisolated public func session(didDisconnect sess: AlloSession)
    {
        print("Disconnected")
        Task { @MainActor in
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
    }
    
    nonisolated public func session(_: AlloSession, didReceiveMediaStream: MediaStream)
    {
        // Playback is handled in SpatialAudioPlayer
        // TODO: If I expose incomingTracks through Combine, why even have this callback?
    }
    
    nonisolated public func session(_: AlloSession, didRemoveMediaStream: MediaStream)
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
    
    nonisolated public func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    {
        Task { @MainActor in
            do
            {
                try await self.handle(interaction: inter)
            }
            catch (let e as AlloverseError)
            {
                print("Error handling interaction: \(e)")
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
                throw AlloverseError(domain: AlloverseErrorCode.domain, code: AlloverseErrorCode.unhandledRequest.rawValue, description: "No handler for \(inter.body.caseName)")
            }
            let response = try await handler(inter)
            session.send(interaction: response)
        }
        else
        {
            guard let handler = handlers[inter.body.caseName] else
            {
                print("No handler registered for interaction: \(inter)")
                return
            }
            await handler(inter)
        }
    }
    
    nonisolated public func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        //print("Received place change for revision \(changeset.fromRevision) -> \(changeset.toRevision)")
        Task
        { @MainActor in
            guard placeState.applyChangeSet(changeset) else
            {
                print("Failed to apply change set, asking for a full diff")
                currentIntent = Intent(ackStateRev: 0)
                return
            }
            currentIntent = Intent(ackStateRev: changeset.toRevision)
        }
    }
    
    nonisolated public func session(_: AlloSession, didReceiveIntent intent: Intent)
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
