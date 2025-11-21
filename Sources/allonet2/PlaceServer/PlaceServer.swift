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
    internal var requiresAuthenticationProvider = false

    // The scenegraph state of the Place
    let place: PlaceState
    lazy var heartbeat: HeartbeatTimer = {
        return HeartbeatTimer {
            self.applyAndBroadcastState()
        }
    }()
    internal var outstandingPlaceChanges: [PlaceChange] = []
    // This is here to help with some calculations; don't try to modify place through it.
    let placeHelper: Place
    
    static let InteractionTimeout: TimeInterval = 10
    
    public init(
        name: String,
        httpPort: UInt16 = 9080,
        customApp: AppDescription = .alloverse,
        transportClass: Transport.Type,
        options: TransportConnectionOptions,
        alloAppAuthToken: String
    )
    {
        Allonet.Initialize()
        self.place = PlaceState(logger: logger)
        self.placeHelper = Place(state: self.place, client: nil)
        
        self.name = name
        self.httpPort = httpPort
        self.transportClass = transportClass
        self.options = options
        self.alloAppAuthToken = alloAppAuthToken
        self.web = PlaceServerHTTP(server: self, port: httpPort, appDescription: customApp)
        self.sfu = PlaceServerSFU(server: self)
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
        for client in Array(clients.values) + Array(unannouncedClients.values)
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
            } else
            {
                // If it's not in clients, it should be in unacknowledged... just double checking
                if self.unannouncedClients[cid] == nil
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
            guard let client = self.clients[cid] ?? self.unannouncedClients[cid] else { return }
            sfu.handle(lost: stream, from: client)
        }
    }
}
