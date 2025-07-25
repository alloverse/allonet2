//
//  AlloAppClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-07-20.
//

import allonet2
import Combine
import Foundation

public class AlloAppClient : AlloClient
{
    private var userTransport: HeadlessWebRTCTransport!
        
    open override func reset()
    {
        userTransport = HeadlessWebRTCTransport(with: .direct, status: connectionStatus)
        reset(with: userTransport)
    }
}
