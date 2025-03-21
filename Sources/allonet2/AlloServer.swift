//
//  AlloServer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import FlyingFox

let port:UInt16 = 9080

let InteractionTimeout: TimeInterval = 10

@MainActor
public class PlaceServer : AlloSessionDelegate
{
    var clients : [RTCClientId: ConnectedClient] = [:]
    var unannouncedClients : [RTCClientId: ConnectedClient] = [:]
    let name: String
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
    
    public init(name: String)
    {
        InitializeAllonet()
        self.name = name
    }
    
    let http = HTTPServer(port: port)
    public func start() async throws
    {
        print("Serving '\(name)' at http://localhost:\(port)/")

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
        self.unannouncedClients[session.rtc.clientId!] = client
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
        Task { @MainActor in
            if let _ = self.clients.removeValue(forKey: cid)
            {
                await self.removeEntites(ownedBy: cid)
            }
            self.unannouncedClients[cid] = nil
            
        }
    }
    
    nonisolated public func session(_ sess: AlloSession, didReceiveInteraction inter: Interaction)
    {
        let cid = sess.rtc.clientId!
        //print("Received interaction from \(cid): \(inter)")
        Task { @MainActor in
            let client = (clients[cid] ?? unannouncedClients[cid])!
            await self.handle(inter, from: client)
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
            if let client = clients[cid]
            {
                client.ackdRevision = intent.ackStateRev
            } else
            {
                // If it's not in clients, it should be in unacknowledged... just double checking
                assert(unannouncedClients[cid] != nil)
                // but we shouldn't even receive an intent before it's acknowledged anyway.
            }
        }
    }

    // MARK: - Interactions
    
    func handle(_ inter: Interaction, from client: ConnectedClient) async
    {
        do
        {
            if inter.receiverEntityId == PlaceEntity
            {
                try await self.handle(placeInteraction: inter, from: client)
            } else {
                try await self.handle(forwardingOfInteraction: inter, from: client)
            }
        
        }
        catch (let e as AlloverseError)
        {
            print("Interaction error for \(client.cid): \(e)")
            client.session.send(interaction: inter.makeResponse(with: e.asBody))
        }
    }
    
    var outstandingClientToClientInteractions: [Interaction.RequestID: RTCClientId] = [:]
    func handle(forwardingOfInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
        // Go look for the recipient entity, and map it to recipient client.
        guard let receivingEntity = place.current.entities[inter.receiverEntityId],
              let ownerAgentId = UUID(uuidString: receivingEntity.ownerAgentId),
              let recipient = clients[ownerAgentId] else
        {
            throw AlloverseError(
                domain: PlaceErrorDomain,
                code: PlaceErrorCode.recipientUnavailable.rawValue,
                description: "No such recipient for entity \(inter.receiverEntityId)"
            )
        }
        
        // If it's a request, save it so we can keep track of mapping the response so the correct client responds.
        // And if it's a response, map it back and check that it's the right one.
        let correctRecipient = outstandingClientToClientInteractions[inter.requestId]
        if inter.type == .request
        {
            print("Hello incoming request \(inter.requestId), storing you")
            outstandingClientToClientInteractions[inter.requestId] = client.session.rtc.clientId!
        }
        else if(inter.type == .response)
        {
            guard let correctRecipient else
            {
                throw AlloverseError(
                    domain: PlaceErrorDomain,
                    code: PlaceErrorCode.invalidResponse.rawValue,
                    description: "No such request \(inter.requestId) for your response, maybe it timed out before you replied, or you repliced twice?"
                )
            }
            guard ownerAgentId == correctRecipient else
            {
                throw AlloverseError(
                    domain: PlaceErrorDomain,
                    code: PlaceErrorCode.invalidResponse.rawValue,
                    description: "That's not your request to respond to."
                )
            }
            
            // We're now sending our response, so clear it out of the outstandings
            print("Hello incoming response \(inter.requestId), now clearing the matching requestID")
            outstandingClientToClientInteractions[inter.requestId] = nil
        }
        
        // All checks passed! Send it off!
        recipient.session.send(interaction: inter)
        
        // Now check for timeout, so the requester at _least_ gets a timeout answer if nothing else.
        if inter.type == .request
        {
            print("Hello incoming request \(inter.requestId), now waiting until timeout")
            try? await Task.sleep(for: .seconds(InteractionTimeout))
            
            if outstandingClientToClientInteractions[inter.requestId] != nil
            {
                print("Hello incoming request \(inter.requestId), you will now timeout")
                throw AlloverseError(
                    domain: PlaceErrorDomain,
                    code: PlaceErrorCode.recipientTimedOut.rawValue,
                    description: "Recipient didn't respond in time."
                )
                outstandingClientToClientInteractions[inter.requestId] = nil
            }
            print("Hello incoming request \(inter.requestId), you didnt exist anymore")
        }
    }
    
    func handle(placeInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
        switch inter.body
        {
        case .announce(let version, let avatarDescription):
            guard version == "2.0" else {
                print("Client \(client.cid) has incompatible version, disconnecting.")
                client.session.rtc.disconnect()
                return
            }
            client.announced = true
            // Client is now announced, so move it into the main list of clients so it can get world states etc.
            clients[client.cid] = unannouncedClients.removeValue(forKey: client.cid)!
            let ent = await self.createEntity(from: avatarDescription, for: client)
            print("Accepted client \(client.cid) with avatar id \(ent.id)")
            await heartbeat.awaitNextSync() // make it exist before we tell client about it
            
            client.session.send(interaction: inter.makeResponse(with: .announceResponse(avatarId: ent.id, placeName: name)))
        case .createEntity(let description):
            let ent = await self.createEntity(from: description, for: client)
            print("Spawned entity for \(client.cid) with id \(ent.id)")
            client.session.send(interaction: inter.makeResponse(with: .createEntityResponse(entityId: ent.id)))
        case .removeEntity(let eid, let mode):
            try await self.removeEntity(with: eid, mode: mode, for: client)
            client.session.send(interaction: inter.makeResponse(with: .success))
        case .changeEntity(let entityId, let addOrChange, let remove):
            try await self.changeEntity(eid: entityId, addOrChange: addOrChange, remove: remove, for: client)
            client.session.send(interaction: inter.makeResponse(with: .success))
        default:
            if inter.type == .request {
                throw AlloverseError(domain: PlaceErrorDomain, code: PlaceErrorCode.invalidRequest.rawValue, description: "Place server does not support this request")
            }
        }
    }
    
    // MARK: - Entity and component management
    
    func createEntity(from description:EntityDescription, for client: ConnectedClient) async -> Entity
    {
        let (ent, changes) = description.changes(for: client.cid.uuidString)
        print("For \(client.cid), creating entity \(ent.id) with \(description.components.count) components and \(description.children.count) children")
        await appendChanges(changes)
        
        return ent
    }
    
    func removeEntity(with id: EntityID, mode: EntityRemovalMode, for client: ConnectedClient?) async throws(AlloverseError)
    {
        print("For \(client?.cid.uuidString ?? "internal"), removing entity \(id)")
        let ent = place.current.entities[id]

        guard let ent = ent else {
            throw AlloverseError(domain: PlaceErrorDomain, code: PlaceErrorCode.notFound.rawValue, description: "No such entity")
        }
        guard client == nil || ent.ownerAgentId == client!.cid.uuidString else {
            throw AlloverseError(domain: PlaceErrorDomain, code: PlaceErrorCode.unauthorized.rawValue, description: "That's not your entity to remove")
        }
        
        await appendChanges([
            .entityRemoved(ent)
        ] + place.current.components.componentsForEntity(id).map {
            PlaceChange.componentRemoved(id, $0.value)
        })
                
        // TODO: Handle child entities
    }
    
    func removeEntites(ownedBy cid: RTCClientId) async
    {
        for (eid, ent) in place.current.entities
        {
            if ent.ownerAgentId == cid.uuidString
            {
                try? await removeEntity(with: eid, mode: .reparent, for: nil)
            }
        }
    }

    
    func changeEntity(eid: EntityID, addOrChange: [AnyComponent], remove: [ComponentTypeID], for client: ConnectedClient?) async throws(AlloverseError)
    {
        //print("For \(client?.cid.uuidString ?? "internal"), changing entity \(eid)")
        let ent = place.current.entities[eid]
        
        guard let ent = ent else {
            throw AlloverseError(domain: PlaceErrorDomain, code: PlaceErrorCode.notFound.rawValue, description: "No such entity")
        }
        guard client == nil || ent.ownerAgentId == client!.cid.uuidString else {
            throw AlloverseError(domain: PlaceErrorDomain, code: PlaceErrorCode.unauthorized.rawValue, description: "That's not your entity to modify")
        }
        
        let addOrChanges = addOrChange.map
        {
            if let _ = place.current.components[$0.componentTypeId]?[eid]
            {
                return PlaceChange.componentAdded(eid, $0.base)
            }
            else
            {
                return PlaceChange.componentUpdated(eid, $0.base)
            }
        }
        let removals = try remove.map
        { (ctid: ComponentTypeID) throws(AlloverseError) -> PlaceChange in
            guard let existing = place.current.components[ctid]?[eid] else {
                throw AlloverseError(domain: PlaceErrorDomain, code: PlaceErrorCode.notFound.rawValue, description: "No such entity")
            }
            return PlaceChange.componentRemoved(eid, existing)
        }
        
        await appendChanges(addOrChanges + removals)
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

internal extension EntityDescription
{
    internal func changes(for ownerAgentId: String) -> (Entity, [PlaceChange])
    {
        let ent = Entity(id: EntityID.random(), ownerAgentId: ownerAgentId)
        return (
            ent,
            [
                .entityAdded(ent),
                .componentAdded(ent.id, Transform()) // every entity should have Transform
            ]
            + components.map { .componentAdded(ent.id, $0.base) }
            + children.flatMap {
                let (child, changes) = $0.changes(for: ownerAgentId)
                return changes
            }
        )
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
    
    // This stream must not buffer events; otherwise any awaitNextSync() will trigger immediately based on an outdated heartbeat,
    // not the latest one it's actually waiting for.
    private lazy var syncStream: AsyncStream<Void> = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(0)) { continuation in
        self.syncContinuation = continuation
    }
    private var syncContinuation: AsyncStream<Void>.Continuation?

    public init(coalesceDelay: Int = 20_000_000,
         keepaliveDelay: Int = 1_000_000_000,
         syncAction: @escaping () async -> Void)
    {
        self.syncAction = syncAction
        self.coalesceDelay = coalesceDelay
        self.keepaliveDelay = keepaliveDelay
        
        Task { await setupTimer(delay: keepaliveDelay) }
    }

    public func markChanged()
    {
        // Only schedule a new timer if not already pending.
        if pendingChanges { return }
        pendingChanges = true
        
        setupTimer(delay: coalesceDelay)
    }
    
    public func awaitNextSync() async
    {
        for await _ in syncStream { break }
    }
    
    public func stop()
    {
        timer?.cancel()
        timer = nil
    }
    
    private func setupTimer(delay: Int)
    {
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

    private func timerFired() async
    {
        await syncAction()
        pendingChanges = false
        setupTimer(delay: keepaliveDelay)
        syncContinuation?.yield(())
    }
}
