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
        let success = place.applyChangeSet(PlaceChangeSet(changes: outstandingPlaceChanges))
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
            
        let session = AlloSession()
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
    private let coalesceDelay: UInt64
    private let keepaliveDelay: UInt64

    private var pendingChanges = false

    // A stored continuation that we can resume early if needed.
    private var waitContinuation: CheckedContinuation<Void, Never>?

    init(coalesceDelay: UInt64 = 20_000_000,
         keepaliveDelay: UInt64 = 1_000_000_000,
         syncAction: @escaping () async -> Void) {
        self.syncAction = syncAction
        self.coalesceDelay = coalesceDelay
        self.keepaliveDelay = keepaliveDelay

        // Start the continuous heartbeat loop.
        Task { await self.runLoop() }
    }

    /// Call this when a change occurs.
    func markChanged() {
        pendingChanges = true
        // Resume the wait early if it’s in progress.
        waitContinuation?.resume()
        waitContinuation = nil
    }

    /// The continuous heartbeat loop.
    private func runLoop() async {
        while true {
            // Determine the desired delay: a short delay if changes are pending, else the keepalive interval.
            let delay = pendingChanges ? coalesceDelay : keepaliveDelay

            // Wait for either the delay to elapse or an early wake-up via markChanged().
            await wait(delay: delay)
            // After the wait, perform the sync action.
            await syncAction()
            // Clear pending changes.
            pendingChanges = false
        }
    }

    /// Suspends until either the specified delay elapses or until markChanged() resumes the continuation.
    private func wait(delay: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Store the continuation so markChanged() can resume it.
            self.waitContinuation = continuation
            // Launch a task that resumes the continuation after the delay.
            Task {
                try? await Task.sleep(nanoseconds: delay)
                // If the continuation is still pending, resume it.
                if let cont = self.waitContinuation {
                    cont.resume()
                    self.waitContinuation = nil
                }
            }
        }
    }
}
