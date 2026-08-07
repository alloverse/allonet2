//
//  AlloServer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import OpenCombineShim
import Logging

@MainActor
public class PlaceServer : AlloSessionDelegate
{
    var clients : [ClientId: ConnectedClient] = [:]
    var unannouncedClients : [ClientId: ConnectedClient] = [:]
    /// Told a fatal error and quarantined: no longer served, synced or simulated, entities torn
    /// down — but the session stays up, so the response saying *why* can reach the client before
    /// the line drops. The client hangs up itself; `condemn(_:)`'s backstop covers one that won't.
    var waitingToDisconnect : [ClientId: ConnectedClient] = [:]
    
    let name: String
    let httpPort:UInt16
    let transportClass: Transport.Type
    let options: TransportConnectionOptions
    let alloAppAuthToken: String
    
    var logger = Logger(labelSuffix: "place.server")
    
    var sfu: PlaceServerSFU!
    var web: PlaceServerHTTP!
    
    var outstandingClientToClientInteractions: [Interaction.RequestID: ClientId] = [:]
    internal var authenticationProvider: ConnectedClient?
    /// Latched by configuration or by the first provider to register. Once true, a place with no
    /// provider connected rejects users instead of admitting them, so a restart or a crashed
    /// provider can't reopen the place to anyone who knows its address.
    internal var requiresAuthenticationProvider: Bool

    // The scenegraph state of the Place
    let place: PlaceState
    lazy var heartbeat: HeartbeatTimer = {
        return HeartbeatTimer {
            self.applyAndBroadcastState()
        }
    }()
    internal var outstandingPlaceChanges: [PlaceChange] = []
    /// Entities with a removal (entity or Transform) queued but not yet applied. The sim tick
    /// must not append updates for them: an update after a removal makes the changeset inapplicable.
    internal var pendingRemovals: Set<EntityID> = []
    internal var movementLoop: Task<Void, Never>? = nil
    // This is here to help with some calculations; don't try to modify place through it.
    let placeHelper: Place
    
    static let InteractionTimeout: TimeInterval = 10
    /// How long a client told about a fatal error gets to hang up itself before we drop it.
    /// Var so tests don't have to wait it out.
    var fatalDisconnectGrace: TimeInterval = 3
    
    public init(
        name: String,
        httpPort: UInt16 = 9080,
        customApp: AppDescription = .alloverse,
        transportClass: Transport.Type,
        options: TransportConnectionOptions,
        alloAppAuthToken: String,
        requiresAuthentication: Bool = false,
        assetsDirectory: URL = PlaceServer.defaultAssetsDirectory
    )
    {
        // An empty token lets every app that announces authenticate, and the first app to ask
        // becomes this place's authentication provider, so the combination would leave a place
        // configured as closed open to whoever connects first. The CLI reports this as a usage
        // error; an embedder gets it as the configuration bug it is.
        precondition(!requiresAuthentication || !alloAppAuthToken.isEmpty,
                     "A place that requires authentication needs a non-empty alloAppAuthToken")

        Allonet.Initialize()
        self.requiresAuthenticationProvider = requiresAuthentication
        self.place = PlaceState(logger: logger)
        self.placeHelper = Place(state: self.place, client: nil)
        
        self.name = name
        self.httpPort = httpPort
        self.transportClass = transportClass
        self.options = options
        self.alloAppAuthToken = alloAppAuthToken
        self.web = PlaceServerHTTP(server: self, port: httpPort, appDescription: customApp, assetsDirectory: assetsDirectory)
        self.sfu = PlaceServerSFU(server: self)
    }

    /// Assets published to this place are kept here until told otherwise. Under the temp directory
    /// rather than a caches directory because on Linux the latter resolves out of
    /// /etc/default/useradd to `/home/.cache`, which in a container is nobody's home. A place that
    /// should keep its assets across restarts gets pointed at a volume instead.
    public nonisolated static var defaultAssetsDirectory: URL
    {
        FileManager.default.temporaryDirectory.appendingPathComponent("alloplace-assets", isDirectory: true)
    }
    
    public func start() async throws
    {
        let myIp = options.ipOverride?.to ?? "localhost"
        logger.notice("Serving '\(name)' at http://\(myIp):\(httpPort)/ and UDP ports \(options.portRange)")

        try await self.web.start()
    }
    public func stop() async
    {
        await web.stop()
        for client in Array(clients.values) + Array(unannouncedClients.values) + Array(waitingToDisconnect.values)
        {
            client.session.disconnect()
        }
        sfu.stop()
    }
    
    public func session(didConnect sess: AlloSession)
    {
        let clogger = logger.forClient(sess.clientId!)
        clogger.info("Client \(sess.clientId!) connected its session")
    }
    
    public func session(didDisconnect sess: AlloSession)
    {
        guard let cid = sess.clientId else
        {
            logger.error("Lost client before a client ID was set - this may be due to an auth failure")
            return
        }
        var clogger = logger.forClient(cid)
        clogger.info("Lost session for client \(cid), removing entities...")
        Task { @MainActor in
            // A condemned client was torn down when it was condemned; this is just it (or the
            // backstop) closing the line, and the roster entry is all that's left to clear.
            if self.waitingToDisconnect.removeValue(forKey: cid) != nil
            {
                clogger.info("Condemned client \(cid) is now gone.")
                return
            }
            // Publishing rights end with the session, so revoke before any of the awaits below —
            // entity removal and the next sync would otherwise leave a window in which a client
            // that is already gone can still POST an asset.
            if let token = (self.clients[cid] ?? self.unannouncedClients[cid])?.assetToken
            {
                await self.web.assets.publishers.revoke(token)
            }
            // The client stays in `clients` until the next sync below, so stop simulating it first:
            // a movement update queued alongside its avatar's removal makes the whole changeset
            // inapplicable, which trips the assert in applyAndBroadcastState.
            self.clients[cid]?.stopMoving()
            await self.removeEntites(ownedBy: cid)
            await self.heartbeat.awaitNextSync() // trigger callbacks for disappearing entities and their components before removing client
            if let client = self.clients.removeValue(forKey: cid) ?? self.unannouncedClients.removeValue(forKey: cid)
            {
                clogger.info("Lost session for client \(cid) (\(client.announced ? "announced" : "unannounced")) was named \(client.identity?.displayName ?? "--")/\(client.identity?.emailAddress ?? "--"), and is now removed.")
            }
            if authenticationProvider?.cid == cid
            {
                clogger.warning("Lost client was our authentication provider, removing it")
                authenticationProvider = nil
            }
            
            
        }
    }
    
    public func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        fatalError() // should never happen on server
    }
    
    public func session(_ sess: AlloSession, didReceiveIntent intent: Intent)
    {
        let cid = sess.clientId!
        Task { @MainActor in
            if let client = self.clients[cid]
            {
                client.ackdRevision = intent.ackStateRev
                client.latestIntent = intent
                if intent.grab == nil
                {
                    // The movement loop may have gone idle mid-grab and won't tick to clear these;
                    // stale, they'd make the next grab of the same entity measure constraints
                    // from this grab's start.
                    client.grabBase = nil
                    client.grabSimulated = nil
                }
                if intent.moveDirection != .zero || intent.grab != nil
                {
                    self.startMovementLoopIfNeeded()
                }
            } else
            {
                // If it's not in clients, it should be in unacknowledged... just double checking.
                // A condemned client's intents are expectedly in flight; not worth a warning.
                if self.unannouncedClients[cid] == nil && self.waitingToDisconnect[cid] == nil
                {
                    logger.forClient(cid).warning("Received intent from unknown client \(cid)")
                }
                // but we shouldn't even receive an intent before it's acknowledged anyway.
            }
        }
    }
    
    public func session(_ sess: AlloSession, didReceiveLog m: StoredLogMessage)
    {
        var metadata = m.metadata ?? [:]
        var message = m.message
        let clogger: Logger
        if
            let cid = sess.clientId,
            let client = self.clients[cid]
        {
            metadata["loggedFromClientId"] = .string(cid.uuidString)
            clogger = client.remoteLoggers[m.label, setDefault: Logger(labelSuffix: "remote:\(m.label)")]
        } else
        {
            metadata["loggedFromClientId"] = .string("unknown")
            clogger = Logger(labelSuffix: "remote:\(m.label)")
        }
        
        clogger.log(
            level: m.level,
            m.message,
            metadata: metadata,
            source: m.source,
            file: m.file,
            function: m.function,
            line: m.line
        )
    }
    
    public func session(_ sess: AlloSession, didReceiveMediaStream stream: any MediaStream)
    {
        let cid = sess.clientId!
        Task { @MainActor in
            guard let client = self.clients[cid] ?? self.unannouncedClients[cid] else { return }
            sfu.handle(incoming: stream, from: client)
        }
    }
    
    public func session(_ sess: AlloSession, didRemoveMediaStream stream: any MediaStream)
    {
        let cid = sess.clientId!
        Task { @MainActor in
            // Condemned clients included: they gain no new streams, but the ones they brought
            // still have to leave `available` when the session finally closes.
            guard let client = self.clients[cid] ?? self.unannouncedClients[cid] ?? self.waitingToDisconnect[cid] else { return }
            sfu.handle(lost: stream, from: client)
        }
    }
}
