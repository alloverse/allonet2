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

class PlaceServer {
    var sessions : [RTCSession] = []

    // Start a web server
    
    let http = HTTPServer(port: port)
    func start() async throws
    {
        print("alloserver swift gateway: http://localhost:\(port)/")

        // On incoming connection, create a WebRTC socket.
        await http.appendRoute("/") { request in
            let session = RTCSession()
            
            self.sessions.append(session)
            // TODO: rescind offer if not taken within some timeout.
            // TODO: This should be an answer, picking up the offer from the request!!!
            let response = OfferResponse(
            	sdp: await session.generateOffer(),
                candidates: (await session.gatherCandidates()).map { OfferResponseIceCandidate(candidate: $0) },
                clientId: session.clientId!
            )
            return HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "application/json"],
                body: try! JSONEncoder().encode(response)
            )
        }
        
        try await http.start()
    }
}

// once webrtc is established, handshake

// once handshaken, hand the socket over to a worldmanager that will be its delegate
// and send it world updates etc.
let server = PlaceServer()
try await server.start()

