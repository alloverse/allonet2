//
//  democlient/main.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-04-03.
//

import Foundation
import allonet2
import FlyingFox
import WebRTC

let port:UInt16 = 9080

@MainActor
class PlaceServer {
    var sessions : [RTCSession] = []

    // Start a web server
    
    let http = HTTPServer(port: port)
    func start() async throws
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
            
        let session = RTCSession()
        self.sessions.append(session)
        
        let response = SignallingPayload(
            sdp: try await session.generateAnswer(offer: offer.desc(for: .offer), remoteCandidates: offer.rtcCandidates()),
            candidates: (await session.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
            clientId: session.clientId!
        )
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: try! JSONEncoder().encode(response)
        )
    }
}

// once webrtc is established, handshake

// once handshaken, hand the socket over to a worldmanager that will be its delegate
// and send it world updates etc.
let server = PlaceServer()
try await server.start()

