//
//  democlient/main.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-04-03.
//

import Foundation
import allonet2
import Swifter
import WebRTC

class ClientSession {
    let rtc: WebRTCClient
    
    init() {
        self.rtc = WebRTCClient(iceServers: [])
    }
}
var sessions : [ClientSession] = []

// Start a web server
let server = HttpServer()
try server.start(9080, forceIPv4: true)
print("alloserver swift gateway: http://localhost:\(try server.port())/")

// On incoming connection, create a WebRTC socket.
server["/"] = { req in
    
    return .ok(.text("hello"))
}

// Feed it the offer
// Respond with answer

// once webrtc is established, handshake

// once handshaken, hand the socket over to a worldmanager that will be its delegate
// and send it world updates etc.

RunLoop.current.run()


