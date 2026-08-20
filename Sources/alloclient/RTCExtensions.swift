//
//  RTCExtensions.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-09.
//

import Foundation
import LiveKitWebRTC

extension LKRTCSignalingState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states : [String] = ["stable", "haveLocalOffer", "haveLocalPrAnswer", "haveRemoteOffer", "haveRemotePrAnswer", "closed"]
        return states[self.rawValue]
    }
}

extension LKRTCIceConnectionState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states: [String] = ["New", "Checking", "Connected", "Completed", "Failed", "Disconnected", "Closed"]
        return states[self.rawValue]
    }
}

extension LKRTCIceGatheringState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states: [String] = ["New", "Gathering", "Complete"]
        return states[self.rawValue]
    }
}

extension LKRTCDataChannelState: CustomDebugStringConvertible
{
    public var debugDescription: String
    {
        let states: [String] = ["Connecting", "Open", "Closing", "Closed"]
        return states[self.rawValue]
    }
}
