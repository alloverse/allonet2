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
        
        await appendChanges([
            .entityAdded(Entity(id: "test", ownerAgentId: "")),
        ])
            
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
            if case .announce(let version) = inter.body
            {
                guard version == "2.0" else {
                    print("Client \(cid) has incompatible version, disconnecting.")
                    sess.rtc.disconnect()
                    return
                }
                client.announced = true
            }
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
    
}

// MARK: -

internal class ConnectedClient
{
    let session: AlloSession
    var announced = false
    var ackdRevision : StateRevision? // Last ack'd place contents revision, or nil if none
    
    init(session: AlloSession)
    {
        self.session = session
    }
    
}

/// A timer manager that fires once every _keepaliveDelay_ whenever nothing has happened, but will fire after only a _coalesceDelay_ if a change has happened. This will coalesce a small number of changes that happen in succession; but still fire a heartbeat now and again to keep connections primed.
actor HeartbeatTimer {
    private let syncAction: () async -> Void
    private let coalesceDelay: Int //ns
    private let keepaliveDelay: Int //ns

    private let timerQueue = DispatchQueue(label: "HeartbeatTimerQueue")
    private var timer: DispatchSourceTimer?
    private var pendingChanges = false

    init(coalesceDelay: Int = 20_000_000,
         keepaliveDelay: Int = 1_000_000_000,
         syncAction: @escaping () async -> Void) {
        self.syncAction = syncAction
        self.coalesceDelay = coalesceDelay
        self.keepaliveDelay = keepaliveDelay
        Task { await setupTimer(delay: keepaliveDelay) }
    }

    func markChanged() {
        // Only schedule a new timer if not already pending.
        if pendingChanges { return }
        pendingChanges = true
        
        setupTimer(delay: coalesceDelay)
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
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
