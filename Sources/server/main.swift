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

class ClientSession: WebRTCClientDelegate {
    let clientId = UUID()
    private let rtc: WebRTCClient
    private var localCandidates : [RTCIceCandidate] = []
    private var candidatesLocked = false
    
    init() {
        self.rtc = WebRTCClient(iceServers: [])
        rtc.delegate = self
    }
    
    func generateOffer() async -> String
    {
        await withCheckedContinuation { cont in
            rtc.offer { sdp in
                cont.resume(returning: sdp.sdp)
            }
        }
    }
    
    func gatherCandidates() async -> [RTCIceCandidate]
    {
        // TODO: Is there another callback for "all relevant local candidates found for now" we can use instead of a timer?
        try! await Task.sleep(nanoseconds: 500*1000*1000)
        candidatesLocked = true
        return localCandidates
    }
    
    func webRTCClient(_ client: allonet2.WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        if candidatesLocked
        {
            print("discovered local candidate after response already sent")
            return
        }
        localCandidates.append(candidate)
    }
    
    func webRTCClient(_ client: allonet2.WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
        print("RTC state is now \(state)")
    }
    
    func webRTCClient(_ client: allonet2.WebRTCClient, didReceiveData data: Data) {
        print("RTC got some data \(data)")
    }
}

struct OfferResponse: Codable
{
    let sdp: String
    let candidates: [OfferResponseIceCandidate]
}

struct OfferResponseIceCandidate: Codable
{
    let sdpMid: String
    let sdpMLineIndex: Int32
    let sdp: String
    let serverUrl: String?
    init(candidate: RTCIceCandidate)
    {
        sdpMid = candidate.sdpMid!
        sdpMLineIndex = candidate.sdpMLineIndex
        sdp = candidate.sdp
        serverUrl = candidate.serverUrl
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
            // TODO: rescind offer if not taken within some timeout.
            let response = OfferResponse(
            	sdp: await session.generateOffer(),
                candidates: (await session.gatherCandidates()).map { OfferResponseIceCandidate(candidate: $0) }
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

