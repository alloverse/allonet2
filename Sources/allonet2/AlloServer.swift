//
//  AlloServer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import FlyingFox

let port:UInt16 = 9080

@MainActor
public class PlaceServer : AlloSessionDelegate
{
    var clients : [RTCClientId: ConnectedClient] = [:]
    let place = PlaceState()
    lazy var heartbeat: HeartbeatTimer = {
        return HeartbeatTimer {
            self.applyAndBroadcastState()
        }
    }()
    private var outstandingPlaceChanges: [PlaceChange] = []
    private func appendChanges(_ changes: [PlaceChange]) async
    {
        outstandingPlaceChanges.append(contentsOf: changes)
        await heartbeat.markChanged()
    }
    
    public init()
    {
    }
    
    let http = HTTPServer(port: port)
    public func start() async throws
    {
        print("alloserver swift gateway: http://localhost:\(port)/")

        // On incoming connection, create a WebRTC socket.
        await http.appendRoute("/", handler: self.handleIncomingClient)
            
        try await http.start()
    }
    
    // MARK: - Place content management
    func applyAndBroadcastState()
    {
        let success = place.applyChangeSet(PlaceChangeSet(changes: outstandingPlaceChanges, fromRevision: place.current.revision, toRevision: place.current.revision + 1))
        assert(success) // bug if this doesn't succeed
        outstandingPlaceChanges.removeAll()
        print("revision \(place.current.revision)")
        for client in clients.values {
            let lastContents = client.ackdRevision.flatMap { place.getHistory(at: $0) } ?? PlaceContents()
            let changeSet = place.current.changeSet(from: lastContents)
            
            client.session.send(placeChangeSet: changeSet)
        }
    }
    
    // MARK: - Session management
    @Sendable
    func handleIncomingClient(_ request: HTTPRequest) async throws -> HTTPResponse
    {
        let offer = try await JSONDecoder().decode(SignallingPayload.self, from: request.bodyData)
            
        let session = AlloSession(side: .server)
        session.delegate = self
        let client = ConnectedClient(session: session)
        
        print("Received new client")
        
        let response = SignallingPayload(
            sdp: try await session.rtc.generateAnswer(offer: offer.desc(for: .offer), remoteCandidates: offer.rtcCandidates()),
            candidates: (await session.rtc.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
            clientId: session.rtc.clientId!
        )
        self.clients[session.rtc.clientId!] = client
        print("Client is \(session.rtc.clientId!), shaking hands...")
        
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: try! JSONEncoder().encode(response)
        )
    }
    
    nonisolated public func session(didConnect sess: AlloSession)
    {
        print("Got connection from \(sess.rtc.clientId!)")
    }
    
    nonisolated public func session(didDisconnect sess: AlloSession)
    {
        let cid = sess.rtc.clientId!
        print("Lost client \(cid)")
        DispatchQueue.main.async {
            self.clients[cid] = nil
        }
    }
    
    nonisolated public func session(_ sess: AlloSession, didReceiveInteraction inter: Interaction)
    {
        let cid = sess.rtc.clientId!
        print("Received interaction from \(cid): \(inter)")
        Task { @MainActor in
            let client = clients[cid]!
            self.handle(inter, from: client)
        }
    }
    
    nonisolated public func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        assert(false) // should never happen on server
    }
    
    nonisolated public func session(_ sess: AlloSession, didReceiveIntent intent: Intent)
    {
        let cid = sess.rtc.clientId!
        Task { @MainActor in
            let client = clients[cid]!
            print("Client \(cid) acked revision \(intent.ackStateRev)")
            client.ackdRevision = intent.ackStateRev
        }
    }
    
    // MARK: - Interactions
    
    func handle(_ inter: Interaction, from client: ConnectedClient)
    {
        if inter.receiverEntityId == "place"
        {
            self.handle(placeInteraction: inter, from: client)
        } else {
            // TODO: Forward to correct client
            // TODO: reply with timeout if client doesn't respond if needed
        }
    }
    
    func handle(placeInteraction inter: Interaction, from client: ConnectedClient)
    {
        switch inter.body
        {
        case .announce(let version, let avatarComponents):
            guard version == "2.0" else {
                print("Client \(client.cid) has incompatible version, disconnecting.")
                client.session.rtc.disconnect()
                return
            }
            client.announced = true
            Task {
                let ent = await self.createEntity(with: avatarComponents, for: client)
                print("Accepted client \(client.cid) with avatar id \(ent.id)")
                // TODO: reply with correct place name
                client.session.send(interaction: inter.makeResponse(with: .announceResponse(avatarId: ent.id, placeName: "Unnamed Alloverse place")))
            }
        default:
            print("Unhandled place interaction from \(client.session.rtc.clientId!): \(inter)")
            if inter.type == .request {
                client.session.send(interaction: inter.makeResponse(with: .error(domain: PlaceErrorDomain, code: PlaceErrorCode.invalidRequest.rawValue, description: "Place server does not support this request")))
            }
        }
    }
    
    // MARK: - Entity and component management
    
    func createEntity(with components:[AnyComponent], for client: ConnectedClient) async -> Entity
    {
        let ent = Entity(id: EntityID.random(), ownerAgentId: client.cid.uuidString)
        print("Creating entity \(ent.id) with \(components.count) components")
        await appendChanges([.entityAdded(ent)] + components.map {
            .componentAdded(ent.id, $0)
        })
        
        await heartbeat.awaitNextSync()
        
        return ent
    }
    
}

// MARK: -

internal class ConnectedClient
{
    let session: AlloSession
    var announced = false
    var ackdRevision : StateRevision? // Last ack'd place contents revision, or nil if none
    var cid: RTCClientId { session.rtc.clientId! }
    
    init(session: AlloSession)
    {
        self.session = session
    }
    
}

/// A timer manager that fires once every _keepaliveDelay_ whenever nothing has happened, but will fire after only a _coalesceDelay_ if a change has happened. This will coalesce a small number of changes that happen in succession; but still fire a heartbeat now and again to keep connections primed.
actor HeartbeatTimer
{
    private let syncAction: () async -> Void
    private let coalesceDelay: Int //ns
    private let keepaliveDelay: Int //ns

    private let timerQueue = DispatchQueue(label: "HeartbeatTimerQueue")
    private var timer: DispatchSourceTimer?
    private var pendingChanges = false
    private lazy var syncStream: AsyncStream<Void> = AsyncStream<Void> { continuation in
        self.syncContinuation = continuation
    }
    private var syncContinuation: AsyncStream<Void>.Continuation?

    public init(coalesceDelay: Int = 20_000_000,
         keepaliveDelay: Int = 1_000_000_000,
         syncAction: @escaping () async -> Void) {
        self.syncAction = syncAction
        self.coalesceDelay = coalesceDelay
        self.keepaliveDelay = keepaliveDelay
        
        Task { await setupTimer(delay: keepaliveDelay) }
    }

    public func markChanged() {
        // Only schedule a new timer if not already pending.
        if pendingChanges { return }
        pendingChanges = true
        
        setupTimer(delay: coalesceDelay)
    }
    
    public func awaitNextSync() async
    {
        for await _ in syncStream { break }
    }
    
    public func stop() {
        timer?.cancel()
        timer = nil
    }
    

    /// Schedules a new timer on the shared timerQueue.
    private func setupTimer(delay: Int) {
        timer?.cancel()
        
        let newTimer = DispatchSource.makeTimerSource(queue: timerQueue)
        newTimer.setEventHandler { [weak self] in
            // Jump back into the actor's context.
            Task { await self?.timerFired() }
        }
        newTimer.schedule(deadline: .now() + .nanoseconds(delay))
        newTimer.activate()
        timer = newTimer
    }

    private func timerFired() async {
        await syncAction()
        pendingChanges = false
        setupTimer(delay: keepaliveDelay)
        syncContinuation?.yield(())
    }
}
