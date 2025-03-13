//
//  democlient/main.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-04-03.
//

import Foundation
import Combine
import allonet2

@MainActor
class DemoApp
{
    let client: AlloClient
    init(connectingTo url: URL)
    {
        print("Connecting to alloverse swift place ", url)

        self.client = AlloClient(url: url, avatarDescription: [
        ])
        
        Task { [weak self] in
            guard let vals = self?.client.$isAnnounced.values else { return }
            for await announced in vals where announced == true {
                guard self != nil else { break }
                do {
                    try await self?.setup()
                } catch(let e) {
                    print("Failed setup: \(e)")
                    exit(1)
                }
            }
        }

        client.stayConnected()
    }
    
    func setup() async throws
    {
        print("Demo app connected, setting up...")
        let eid = try await client.createEntity(with: [])
        print("Whee fresh eid: \(eid)")
    }
}


let url = URL(string: CommandLine.arguments[1])!
let app = DemoApp(connectingTo: url)

func park() async -> Never {
    await withUnsafeContinuation { _ in }
}
await park()
