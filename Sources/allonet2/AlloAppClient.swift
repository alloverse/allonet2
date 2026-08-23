//
//  AlloAppClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-07-20.
//

import OpenCombineShim
import Foundation

public class AlloAppClient : AlloClient
{
    private var userTransport: DataChannelTransport!
        
    open override func reset()
    {
        userTransport = DataChannelTransport(with: self.connectionOptions, status: connectionStatus)
        reset(with: userTransport)
    }
}
