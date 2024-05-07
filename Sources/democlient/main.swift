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
}


let url = URL(string: CommandLine.arguments[1])!

print("Connecting to alloverse swift place ", url)

// Create a webrtc socket
// Connect to url using URLConnection, and attach offer
// as POST body

// Use response body as answer

// connect webrtc

// once connected, send announce

// when received response, hand over to worldclient to receive world state

