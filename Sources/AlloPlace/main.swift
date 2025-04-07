//
//  democlient/main.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-04-03.
//

import Foundation
import allonet2
import FlyingFox

let name = CommandLine.arguments[safe: 1] ?? "Unnamed Alloverse Place"
let server = PlaceServer(name: name)
try await server.start()

