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
        
        Task {
            for await announced in self.client.$isAnnounced.values where announced == true {
                try! await self.setup()
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

await parkToRunloop()


