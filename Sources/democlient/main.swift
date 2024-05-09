//
//  democlient/main.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-04-03.
//

import Foundation
import allonet2

class AlloClient : RTCSessionDelegate
{
    let session = RTCSession()
    
    init()
    {
        session.delegate = self
    }
    
    func connect(to url: URL) async throws
    {
        let offer = SignallingPayload(
        	sdp: try await session.generateOffer(),
        	candidates: (await session.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
            clientId: nil
        )
        let request = NSMutableURLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(offer)
        let (data, _) = try await URLSession.shared.data(for: request as URLRequest)
        print("Received handshake")
        let answer = try JSONDecoder().decode(SignallingPayload.self, from: data)
        
        try await session.receive(
            client: answer.clientId!,
            answer: answer.desc(for: .answer),
            candidates: answer.rtcCandidates()
        )
    }
    
    func session(didConnect sess: allonet2.RTCSession)
    {
        print("Connected as \(sess.clientId!)")
    }
    
    func session(didDisconnect sess: allonet2.RTCSession)
    {
        print("Disconnected")
        exit(0)
    }
    
    func session(_ sess: allonet2.RTCSession, didReceiveData data: Data) {
        print("Received data: \(String(data: data, encoding: .utf8)!)")
    }
}


let url = URL(string: CommandLine.arguments[1])!

print("Connecting to alloverse swift place ", url)

let client = AlloClient()

try await client.connect(to: url)


// once connected, send announce

// when received response, hand over to worldclient to receive world state

func park() async -> Never {
    await withUnsafeContinuation { _ in }
}
await park()
