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
    var outstandingPlaceChanges: [PlaceChange] = []
    
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

internal class ConnectedClient
{
    let session: AlloSession
    var announced = false
    
    init(session: AlloSession)
    {
        self.session = session
    }
    
}
