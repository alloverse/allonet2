//
//  AlloServer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import FlyingFox

public struct AppDescription
{
    public let name: String
    public let downloadURL: String
    public let URLProtocol: String
    public init(name: String, downloadURL: String, URLProtocol: String) { self.name = name; self.downloadURL = downloadURL; self.URLProtocol = URLProtocol }
    public static var alloverse: Self { AppDescription(name: "Alloverse", downloadURL: "https://alloverse.com/download", URLProtocol: "alloplace2") }
}

@MainActor
public class PlaceServer : AlloSessionDelegate
{
    var clients : [ClientId: ConnectedClient] = [:]
    var unannouncedClients : [ClientId: ConnectedClient] = [:]
    
    let name: String
    let httpPort:UInt16
    let webrtcPortRange: Range<Int>
    let appDescription: AppDescription
    let transportClass: Transport.Type

    private var authenticationProvider: ConnectedClient?

    let connectionStatus = ConnectionStatus()
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
    
    static let InteractionTimeout: TimeInterval = 10
    
    public init(
        name: String,
        httpPort: UInt16 = 9080,
        webrtcPortRange: Range<Int> = 10000 ..< 11000,
        customApp: AppDescription = .alloverse,
        transportClass: Transport.Type
    )
    {
        Allonet.Initialize()
        self.name = name
        self.httpPort = httpPort
        self.webrtcPortRange = webrtcPortRange
        self.appDescription = customApp
        self.transportClass = transportClass
        self.http = HTTPServer(port: httpPort)
    }
    
    // MARK: - HTTP server
    
    let http: HTTPServer
    public func start() async throws
    {
        print("Serving '\(name)' at http://localhost:\(httpPort)/ and UDP ports \(webrtcPortRange)")

        // On incoming connection, create a WebRTC socket.
        await http.appendRoute("POST /", handler: self.handleIncomingClient)
        await http.appendRoute("GET /", handler: self.landingPage)
            
        try await http.start()
    }
    
    public func stop() async
    {
        await http.stop()
        for client in Array(clients.values) + Array(unannouncedClients.values)
        {
            client.session.disconnect()
        }
    }
    
    @Sendable
    func landingPage(_ request: HTTPRequest) async -> HTTPResponse
    {
        let host = request.headers[.host] ?? "localhost"
        let path = request.path
        var proto = appDescription.URLProtocol
        if !host.contains(":") { proto += "s" } // no custom port = _likely_ https
        
        let body = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>\(name)</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                        padding: 2em;
                        max-width: 600px;
                        margin: auto;
                        line-height: 1.6;
                    }
                    a.button {
                        display: inline-block;
                        padding: 0.75em 1.5em;
                        margin-top: 1em;
                        background: #007aff;
                        color: white;
                        text-decoration: none;
                        border-radius: 8px;
                    }
                </style>
            </head>
            <body>
                <h1>Welcome to \(name).</h1>
                <p>You need to <a href="\(appDescription.downloadURL)">install the \(appDescription.name) app</a> to connect to this virtual place.</p>
                <p>Already have \(appDescription.name)?<br/> <a class="button" href="\(proto)://\(host)\(path)">Open <i>\(name)</i> in \(appDescription.name)</a></p>
            </body>
            </html>
            """
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/html"],
            body: body.data(using: .utf8)!
        )
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
            
        let transport = transportClass.init(with: .direct, status: connectionStatus)
        let session = AlloSession(side: .server, transport: transport)
        session.delegate = self
        let client = ConnectedClient(session: session)
        
        print("Received new client")
        
        let response = try await session.generateAnswer(offer: offer)
        self.unannouncedClients[session.clientId!] = client
        print("Client is \(session.clientId!), shaking hands...")
        
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: try! JSONEncoder().encode(response)
        )
    }
    
    nonisolated public func session(didConnect sess: AlloSession)
    {
        print("Got connection from \(sess.clientId!)")
    }
    
    nonisolated public func session(didDisconnect sess: AlloSession)
    {
        guard let cid = sess.clientId else {
            print("Lost client before a client ID was set - this may be due to an auth failure")
            return
        }
        print("Lost client \(cid)")
        Task { @MainActor in
            if let _ = self.clients.removeValue(forKey: cid)
            {
                await self.removeEntites(ownedBy: cid)
            }
            self.unannouncedClients[cid] = nil
            if authenticationProvider?.cid == cid {
                print("Lost client was our authentication provider")
                authenticationProvider = nil
            }
        }
    }
    
    nonisolated public func session(_ sess: AlloSession, didReceiveInteraction inter: Interaction)
    {
        let cid = sess.clientId!
        //print("Received interaction from \(cid): \(inter)")
        Task { @MainActor in
            let client = (self.clients[cid] ?? self.unannouncedClients[cid])!
            await self.handle(inter, from: client)
        }
    }
    
    nonisolated public func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        assert(false) // should never happen on server
    }
    
    nonisolated public func session(_ sess: AlloSession, didReceiveIntent intent: Intent)
    {
        let cid = sess.clientId!
        Task { @MainActor in
            if let client = self.clients[cid]
            {
                client.ackdRevision = intent.ackStateRev
            } else
            {
                // If it's not in clients, it should be in unacknowledged... just double checking
                assert(self.unannouncedClients[cid] != nil)
                // but we shouldn't even receive an intent before it's acknowledged anyway.
            }
        }
    }
    
    nonisolated public func session(_ sess: AlloSession, didReceiveMediaStream stream: MediaStream)
    {
        Task { @MainActor in
            for (cid, client) in self.clients
            {
                if cid == sess.clientId! { continue }
                // TODO: Stream forwarding!
                //client.session.addOutgoing(stream: stream)
            }
            // TODO: also attach to new clients that connect after this stream comes in
        }
    }

    // MARK: - Interactions
    
    func handle(_ inter: Interaction, from client: ConnectedClient) async
    {
        do throws(AlloverseError)
        {
            let senderEnt = place.current.entities[inter.senderEntityId]
            let isValidAnnounce = inter.body.caseName == "announce" && inter.senderEntityId == ""
            let isValidOtherMessage = (senderEnt != nil) && senderEnt!.ownerAgentId == client.cid.uuidString
            if !(isValidAnnounce || isValidOtherMessage)
            {
                throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.unauthorized.rawValue, description: "You may only send interactions from entities you own")
            }
            if inter.receiverEntityId == Interaction.PlaceEntity
            {
                try await self.handle(placeInteraction: inter, from: client)
            } else {
                try await self.handle(forwardingOfInteraction: inter, from: client)
            }
        
        }
        catch (let e as AlloverseError)
        {
            print("Interaction error for \(client.cid) when handling \(inter): \(e)")
            if inter.type == .request
            {
                client.session.send(interaction: inter.makeResponse(with: e.asBody))
            }
        }
    }
    
    var outstandingClientToClientInteractions: [Interaction.RequestID: ClientId] = [:]
    func handle(forwardingOfInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
        // Go look for the recipient entity, and map it to recipient client.
        guard let receivingEntity = place.current.entities[inter.receiverEntityId],
              let ownerAgentId = UUID(uuidString: receivingEntity.ownerAgentId),
              let recipient = clients[ownerAgentId] else
        {
            throw AlloverseError(
                domain: PlaceErrorCode.domain,
                code: PlaceErrorCode.recipientUnavailable.rawValue,
                description: "No such recipient for entity \(inter.receiverEntityId)"
            )
        }
        
        // If it's a request, save it so we can keep track of mapping the response so the correct client responds.
        // And if it's a response, map it back and check that it's the right one.
        let correctRecipient = outstandingClientToClientInteractions[inter.requestId]
        if inter.type == .request
        {
            outstandingClientToClientInteractions[inter.requestId] = client.session.clientId!
        }
        else if(inter.type == .response)
        {
            guard let correctRecipient else
            {
                throw AlloverseError(
                    domain: PlaceErrorCode.domain,
                    code: PlaceErrorCode.invalidResponse.rawValue,
                    description: "No such request \(inter.requestId) for your response, maybe it timed out before you replied, or you repliced twice?"
                )
            }
            guard ownerAgentId == correctRecipient else
            {
                throw AlloverseError(
                    domain: PlaceErrorCode.domain,
                    code: PlaceErrorCode.invalidResponse.rawValue,
                    description: "That's not your request to respond to."
                )
            }
            
            // We're now sending our response, so clear it out of the outstandings
            outstandingClientToClientInteractions[inter.requestId] = nil
        }
        
        // All checks passed! Send it off!
        recipient.session.send(interaction: inter)
        
        // Now check for timeout, so the requester at _least_ gets a timeout answer if nothing else.
        if inter.type == .request
        {
            try? await Task.sleep(for: .seconds(PlaceServer.InteractionTimeout))
            
            if outstandingClientToClientInteractions[inter.requestId] != nil
            {
                print("Request \(inter.requestId) timed out")
                outstandingClientToClientInteractions[inter.requestId] = nil
                throw AlloverseError(
                    domain: PlaceErrorCode.domain,
                    code: PlaceErrorCode.recipientTimedOut.rawValue,
                    description: "Recipient didn't respond in time."
                )
            }
        }
    }
    
    func handle(placeInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
        switch inter.body
        {

        case .registerAsAuthenticationProvider:
            // Reasons this is bad:
            // - First wins
            // - Only one provider per place server
            // - No verification that the client is actually allowed to authenticate others
            // - A client could authenticate itself
            if authenticationProvider == nil {
                authenticationProvider = client
                client.session.send(interaction: inter.makeResponse(with: .success))
            } else {
                throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.invalidRequest.rawValue,
                                     description: "Place server already has an authentication provider")
            }

        case .announce(let version, let authContext, let avatarDescription):
            // TODO: Since we added authentication, should the version go up?
            guard version == "2.0" else {
                print("Client \(client.cid) has incompatible version, disconnecting.")
                client.session.disconnect()
                return
            }

            if let authenticationProvider, let authenticationId = authenticationProvider.avatar?.id {

                let request = Interaction(type: .request, senderEntityId: Interaction.PlaceEntity,
                                          receiverEntityId: authenticationId,
                                          body: .authenticationRequest(authentication: authContext))

                let answer = await authenticationProvider.session.request(interaction: request)

                switch answer.body {
                case .success: break
                case .error(let domain, let code, let description): fallthrough
                default:
                    // Should we forward the error details back to the client?
                    let error: InteractionBody = .error(domain: PlaceErrorCode.domain,
                                                        code: PlaceErrorCode.unauthorized.rawValue,
                                                        description: "Authentication failed")
                    client.session.send(interaction: inter.makeResponse(with: error))
                    client.session.disconnect()
                    return
                }
            }

            client.announced = true
            // Client is now announced, so move it into the main list of clients so it can get world states etc.
            clients[client.cid] = unannouncedClients.removeValue(forKey: client.cid)!
            let ent = await self.createEntity(from: avatarDescription, for: client)
            client.avatar = ent // TODO: Is this the right thing to do?
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
                throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.invalidRequest.rawValue, description: "Place server does not support this request")
            }
        }
    }
    
    // MARK: - Entity and component management
    
    func createEntity(from description:EntityDescription, for client: ConnectedClient) async -> EntityData
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
            throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.notFound.rawValue, description: "No such entity")
        }
        guard client == nil || ent.ownerAgentId == client!.cid.uuidString else {
            throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.unauthorized.rawValue, description: "That's not your entity to remove")
        }
        
        await appendChanges([
            .entityRemoved(ent)
        ] + place.current.components.componentsForEntity(id).map {
            PlaceChange.componentRemoved(id, $0.value)
        })
                
        // TODO: Handle child entities
    }
    
    func removeEntites(ownedBy cid: ClientId) async
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
            throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.notFound.rawValue, description: "No such entity")
        }
        /*guard client == nil || ent.ownerAgentId == client!.cid.uuidString else {
            throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.unauthorized.rawValue, description: "That's not your entity to modify")
        }*/ // Re-enable this when we have ACLs
        
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
                throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.notFound.rawValue, description: "No such entity")
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
    var cid: ClientId { session.clientId! }
    var avatar: EntityData? // Assigned in the place server upon successful client announce

    init(session: AlloSession)
    {
        self.session = session
    }
}

internal extension EntityDescription
{
    internal func changes(for ownerAgentId: String) -> (EntityData, [PlaceChange])
    {
        let ent = EntityData(id: EntityID.random(), ownerAgentId: ownerAgentId)
        return (
            ent,
            [
                .entityAdded(ent),
                .componentAdded(ent.id, Transform()) // every entity should have Transform
            ]
            + components.map { .componentAdded(ent.id, $0.base) }
            + children.flatMap {
                let (child, changes) = $0.changes(for: ownerAgentId)
                let relationship = PlaceChange.componentAdded(child.id, Relationships(parent: ent.id))
                return changes + [relationship]
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
