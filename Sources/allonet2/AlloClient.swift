//
//  AlloClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import Combine

@MainActor
public class AlloClient : AlloSessionDelegate, ObservableObject, Identifiable
{
    /// Convenient access to the contents of the connected Place.
    public private(set) lazy var place = Place(state: placeState, client: self)
    /// Access to the more complicated underlying data model for the connected Place.
    public let placeState = PlaceState()
    
    let url: URL
    let avatarDesc: EntityDescription
    @Published public private(set) var avatarId: EntityID? { didSet { isAnnounced = avatarId != nil } }
    public var avatar: Entity? {
        guard let aeid = self.avatarId else { return nil }
        return place.entities[aeid]
    }
    @Published public private(set) var isAnnounced: Bool = false
    public private(set) var placeName: String?
    public let session = AlloSession(side: .client)
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
    
    @Published public var state = ConnectionState.idle
    // What was the last connection error?
    // If state is now .idle, it was a permanent error and we're wholly disconnected.
    // If state is now .waitingToReconnect, it was a temporary error and we're about to reconnect.
    @Published public var lastError: Error?
    @Published public private(set) var willReconnectAt: Date?
    
    private var connectTask: Task<Void, Never>? = nil
    private var reconnectionAttempts = 0
    
    public var id: String? {
        get
        {
            session.rtc.clientId?.uuidString
        }
    }
    
    public init(url: URL, avatarDescription: EntityDescription)
    {
        InitializeAllonet()
        self.url = url
        self.avatarDesc = avatarDescription
        session.delegate = self
    }
    
    private var connectionLoopCancellable: AnyCancellable?
    /// Connect, and stay connected until a permanent connection error happens, or user disconnects.
    public func stayConnected()
    {
        guard connectionLoopCancellable == nil else { return }
        
        // Move out of the idle state since we've been asked to get going.
        if state == .idle {
            print("Going from .idle to .waitingForReconnect")
            state = .waitingForReconnect
        }
        
        connectionLoopCancellable = $state.receive(on: DispatchQueue.main).sink
        { [weak self] nextState in
            guard let self = self else { return }
            print("state: \(nextState), error: \(String(describing: self.lastError)), willReconnectAt: \(String(describing: self.willReconnectAt))")
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
        let delaySeconds = min(60, pow(2.0, Double(reconnectionAttempts)))
        willReconnectAt = delaySeconds > 0 ? Date().addingTimeInterval(delaySeconds) : nil
        reconnectionAttempts += 1
        print("connection attempt \(reconnectionAttempts) in \(delaySeconds) seconds")
        
        // Schedule connect() to be called at willReconnectAt.
        connectTask = Task { [weak self] in
            guard let self = self else { return }
            
            let delay = self.willReconnectAt?.timeIntervalSinceNow ?? 0
            print(String(format: "waiting for reconnect in %.1f seconds", delay))
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // Clear the task and reconnectDate before connecting.
            await MainActor.run {
                self.connectTask = nil
                self.willReconnectAt = nil
            }
            print("connecting...")
            await self.connect()
        }
    }

    
    /// Disconnect from peers and remain disconnected until asked to connect again by user
    public func disconnect()
    {
        connectTask?.cancel()
        connectTask = nil
        connectionLoopCancellable?.cancel()
        connectionLoopCancellable = nil
        willReconnectAt = nil
        reconnectionAttempts = 0
        session.rtc.disconnect()
    }
    
    private func connect() async
    {
        precondition(state == .waitingForReconnect, "Trying to connect while \(state)")
        DispatchQueue.main.async {
            self.state = .connecting
        }
        
        do {
            print("Trying to connect...")
            let offer = SignallingPayload(
                sdp: try await session.rtc.generateOffer(),
                candidates: (await session.rtc.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
                clientId: nil
            )
            
            // Original schema is alloplace2://. We call this with HTTP(S) to establish a WebRTC connection, which means we need to rewrite the
            // schema to be http(s).
            guard var httpcomps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            guard let scheme = url.scheme else { throw URLError(.badURL) }
            httpcomps.scheme = scheme.last == "s" ? "https" : "http"
            guard let httpUrl = httpcomps.url else { throw URLError(.badURL) }
            
            let request = NSMutableURLRequest(url: httpUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(offer)
            let (data, _) = try await URLSession.shared.data(for: request as URLRequest)
            let answer = try JSONDecoder().decode(SignallingPayload.self, from: data)
            
            try await session.rtc.receive(
                client: answer.clientId!,
                answer: answer.desc(for: .answer),
                candidates: answer.rtcCandidates()
            )
            print("All the RTC stuff should be done now")
        } catch (let e) {
            print("failed to connect: \(e)")
            DispatchQueue.main.async {
                self.lastError = e
                self.state = .idle
            }
        }
    }
    
    nonisolated public func session(didConnect sess: AlloSession)
    {
        Task
        { @MainActor in
            self.reconnectionAttempts = 0
            self.state = .connected
            
            print("Connected as \(sess.rtc.clientId!)")

            let response = await sess.request(interaction: Interaction(
                type: .request,
                senderEntityId: "",
                receiverEntityId: PlaceEntity,
                body: .announce(version: "2.0", avatar: avatarDesc)
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
            if(false)
            {
                // TODO: Propagate disconnection reason, and notice if it's permanent
                // state = .error ...
            }
            else if(self.connectionLoopCancellable != nil)
            {
                self.state = .waitingForReconnect
            }
            else
            {
                self.state = .idle
            }
        }
    }
    
    // MARK: - Interactions, intent and place state
    
    public struct InteractionHandler<T>
    {
        private var handlers: [String: (Interaction) async -> T] = [:]
        
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
                throw AlloverseError(domain: AlloverseErrorDomain, code: AlloverseErrorCode.unhandledRequest.rawValue, description: "No handler for \(inter.body.caseName)")
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
    
    func request(receiverEntityId: EntityID, body: InteractionBody) async -> Interaction
    {
        precondition(avatarId != nil, "Must be connected and announced to send a request")
        return await session.request(interaction: Interaction(type: .request, senderEntityId: avatarId!, receiverEntityId: receiverEntityId, body: body))
    }
    
    public func createEntity(from description: EntityDescription) async throws(AlloverseError) -> EntityID
    {
        let resp = await request(receiverEntityId: PlaceEntity, body: .createEntity(description))
        guard case .createEntityResponse(let entityId) = resp.body else {
            throw AlloverseError(with: resp.body)
        }
        return entityId
    }
    
    public func removeEntity(entityId: EntityID, mode: EntityRemovalMode) async throws(AlloverseError)
    {
        let resp = await request(receiverEntityId: PlaceEntity, body: .removeEntity(entityId: entityId, mode: mode))
        guard case .success = resp.body else {
            throw AlloverseError(with: resp.body)
        }
    }
    
    public func changeEntity(entityId: EntityID, addOrChange: [any Component] = [], remove: [ComponentTypeID] = []) async throws(AlloverseError)
    {
        let resp = await request(receiverEntityId: PlaceEntity, body: .changeEntity(entityId: entityId, addOrChange: addOrChange.map { AnyComponent($0) }, remove: remove))
        guard case .success = resp.body else {
            throw AlloverseError(with: resp.body)
        }
    }
}

public enum ConnectionState : Equatable
{
    case idle
    case waitingForReconnect
    
    case connecting
    case connected
}
