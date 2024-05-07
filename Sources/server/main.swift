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

class ClientSession {
    let rtc: WebRTCClient
    
    init() {
        self.rtc = WebRTCClient(iceServers: [])
    }
    
    func generateOffer() async -> String
    {
        await withCheckedContinuation { cont in
            rtc.offer { sdp in
                cont.resume(returning: sdp.sdp)
            }
        }
    }
}

let port:UInt16 = 9080

class PlaceServer {
    var sessions : [ClientSession] = []

    // Start a web server
    
    let http = HTTPServer(port: port)
    func start() async throws
    {
        print("alloserver swift gateway: http://localhost:\(port)/")

        // On incoming connection, create a WebRTC socket.
        await http.appendRoute("/") { request in
            let session = ClientSession()
            
            self.sessions.append(session)
            // TODO: rescind offer if not taken within 30s.
            let sdp = await session.generateOffer()
            return HTTPResponse(statusCode: .ok, body: sdp.data(using: .utf8)!)
        }
        
        try await http.start()
    }
}

// Feed it the offer
// Respond with answer

// once webrtc is established, handshake

// once handshaken, hand the socket over to a worldmanager that will be its delegate
// and send it world updates etc.
let server = PlaceServer()
try await server.start()

