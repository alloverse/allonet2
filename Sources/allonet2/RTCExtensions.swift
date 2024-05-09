//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-09.
//

import Foundation
import WebRTC

extension RTCSignalingState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states : [String] = ["stable", "haveLocalOffer", "haveLocalPrAnswer", "haveRemoteOffer", "haveRemotePrAnswer", "closed"]
        return states[self.rawValue]
    }
}

extension RTCIceConnectionState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states: [String] = ["New", "Checking", "Connected", "Completed", "Failed", "Disconnected", "Closed"]
        return states[self.rawValue]
    }
}

extension RTCIceGatheringState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states: [String] = ["New", "Gathering", "Complete"]
        return states[self.rawValue]
    }
}

extension RTCDataChannelState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states: [String] = ["Connecting", "Open", "Closing", "Closed"]
        return states[self.rawValue]
    }
}
