//
//  democlient/main.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-04-03.
//

import Foundation
import allonet2

class AlloClient
{
    let session = RTCSession()
    
    init()
    {
    }
    
    func connect(to url: URL) async throws
    {
        let offer = SignallingPayload(
        	sdp: await session.generateOffer(),
        	candidates: (await session.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
            clientId: nil
        )
        let request = NSMutableURLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(offer)
        let (data, _) = try await URLSession.shared.data(for: request as URLRequest)
        let answer = try JSONDecoder().decode(SignallingPayload.self, from: data)
        
        session.clientId = answer.clientId!
        // TODO: do I need to set remote candidates?
        // await connection state 'connected'
        // send or receive hello world
        
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
