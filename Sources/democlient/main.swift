//
//  democlient/main.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-04-03.
//

import Foundation
import allonet2


let url = URL(string: CommandLine.arguments[1])!

print("Connecting to alloverse swift place ", url)

let client = AlloClient(url: url)

try await client.connect()


// once connected, send announce

// when received response, hand over to worldclient to receive world state

func park() async -> Never {
    await withUnsafeContinuation { _ in }
}
await park()
