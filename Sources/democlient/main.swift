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

        self.client = AlloClient(url: url, avatarDescription: EntityDescription(components:[
            Model(
                mesh: .sphere(radius: 0.5),
                material: .color(color: .hsv(hue: .random(in: 0...1), saturation: 0.9, value: 1, alpha: 1), metallic: true)
            )
        ], children: [
            EntityDescription(components: [
                Model(
                    mesh: .cylinder(height: 2.0, radius: 0.2),
                    material: .color(color: .hsv(hue: .random(in: 0...1), saturation: 0.9, value: 1, alpha: 1), metallic: true)
                )
            ])
        ]))
        
        Task {
            for await announced in self.client.$isAnnounced.values where announced == true {
                try! await self.setup()
            }
        }

        client.stayConnected()
    }
    
    var timer: Timer?
    func setup() async throws
    {
        print("Demo app connected, setting up...")
        
        // Example of interaction handler
        client.responders["custom"] = {
            request async -> Interaction in
            print("Got custom request!")
            return request.makeResponse(with: .custom(value: [:]))
        }
        
        // Example of modifying entities
        Task {
            let r: Float = 2.0
            var t: Float = 0.0
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 20_000_000)
                t += 0.02
                
                guard let avatarId = self.client.avatarId else { continue }
                
                let tform = Transform(translation: [sinf(t)*r, 0, cosf(t)*r])
                try await self.client.changeEntity(entityId: avatarId, addOrChange: [
                    tform
                ])
            }
        }
        
    }
}

let url = URL(string: CommandLine.arguments[1])!
let app = DemoApp(connectingTo: url)

await parkToRunloop()


