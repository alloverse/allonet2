//
//  AlloServer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
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
    
    var outstandingClientToClientInteractions: [Interaction.RequestID: ClientId] = [:]
    internal var sfus: [SFUIdentifier: MediaStreamForwarder] = [:]
    internal var authenticationProvider: ConnectedClient?

    let connectionStatus = ConnectionStatus()
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
    
    nonisolated public func session(didConnect sess: AlloSession)
    {
        print("Client \(sess.clientId!) connected its session")
    }
    
    nonisolated public func session(didDisconnect sess: AlloSession)
    {
        guard let cid = sess.clientId else
        {
            print("Lost client before a client ID was set - this may be due to an auth failure")
            return
        }
        print("Lost session for client \(cid)")
        Task { @MainActor in
            if let client = self.clients.removeValue(forKey: cid)
            {
                self.stop(forwarding: client)
                await self.removeEntites(ownedBy: cid)
            }
            self.unannouncedClients[cid] = nil
            if authenticationProvider?.cid == cid
            {
                print("Lost client was our authentication provider, removing it")
                authenticationProvider = nil
            }
            
            
        }
    }
    
    nonisolated public func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        fatalError() // should never happen on server
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
    
    nonisolated public func session(_ sess: AlloSession, didReceiveMediaStream stream: any MediaStream)
    {
        let cid = sess.clientId!
        Task { @MainActor in
            guard let client = self.clients[cid] else { return }
            self.handle(incoming: stream, from: client)
        }
    }
    
    nonisolated public func session(_: AlloSession, didRemoveMediaStream stream: any MediaStream)
    {
        Task { @MainActor in
            self.stop(forwarding: stream)
        }
    }
}
