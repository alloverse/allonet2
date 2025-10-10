//
//  AlloServer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import OpenCombineShim
import FlyingFox

@MainActor
public class PlaceServer : AlloSessionDelegate
{
    var clients : [ClientId: ConnectedClient] = [:]
    var unannouncedClients : [ClientId: ConnectedClient] = [:]
    
    let name: String
    let http: HTTPServer
    let httpPort:UInt16
    let appDescription: AppDescription
    let transportClass: Transport.Type
    let options: TransportConnectionOptions
    
    var sfu: PlaceServerSFU!
    var status: PlaceServerStatus!
    
    var outstandingClientToClientInteractions: [Interaction.RequestID: ClientId] = [:]
    internal var authenticationProvider: ConnectedClient?

    let place = PlaceState()
    lazy var heartbeat: HeartbeatTimer = {
        return HeartbeatTimer {
            self.applyAndBroadcastState()
        }
    }()
    internal var outstandingPlaceChanges: [PlaceChange] = []
    
    static let InteractionTimeout: TimeInterval = 10
    
    public init(
        name: String,
        httpPort: UInt16 = 9080,
        customApp: AppDescription = .alloverse,
        transportClass: Transport.Type,
        options: TransportConnectionOptions
    )
    {
        Allonet.Initialize()
        self.name = name
        self.httpPort = httpPort
        self.appDescription = customApp
        self.transportClass = transportClass
        self.http = HTTPServer(port: httpPort)
        self.options = options
    }
    func startSubsystems()
    {
        sfu = PlaceServerSFU(server: self)
        status = PlaceServerStatus(server: self)
    }
    
    public func session(didConnect sess: AlloSession)
    {
        print("Client \(sess.clientId!) connected its session")
    }
    
    public func session(didDisconnect sess: AlloSession)
    {
        guard let cid = sess.clientId else
        {
            print("Lost client before a client ID was set - this may be due to an auth failure")
            return
        }
        print("Lost session for client \(cid), removing entities...")
        Task { @MainActor in
            await self.removeEntites(ownedBy: cid)
            await self.heartbeat.awaitNextSync() // trigger callbacks for disappearing entities and their components before removing client
            if let client = self.clients.removeValue(forKey: cid) ?? self.unannouncedClients.removeValue(forKey: cid)
            {
                print("Lost session for client \(cid) (\(client.announced ? "announced" : "unannounced")) was named \(client.identity?.displayName ?? "--")/\(client.identity?.emailAddress ?? "--"), and is now removed.")
            }
            if authenticationProvider?.cid == cid
            {
                print("Lost client was our authentication provider, removing it")
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
                    print("Warning: Received intent from unknown client \(cid)")
                }
                // but we shouldn't even receive an intent before it's acknowledged anyway.
            }
        }
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
