//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-06-04.
//

import Foundation
import WebRTC
import BinaryCodable

public protocol AlloSessionDelegate: AnyObject
{
    func session(didConnect sess: AlloSession)
    func session(didDisconnect sess: AlloSession)
    func session(_: AlloSession, didReceiveInteraction inter: Interaction)
}

/// Wrapper of RTCSession, adding Alloverse-specific channels and data types
public class AlloSession : NSObject, RTCSessionDelegate
{
    public weak var delegate: AlloSessionDelegate?

    public let rtc = RTCSession()
    private var interactionChannel: RTCDataChannel!
    private var worldstateChannel: RTCDataChannel!
    
    public override init()
    {
        super.init()
        rtc.delegate = self
        setupDataChannels()
    }
    
    let encoder = BinaryEncoder()
    public func send(interaction: Interaction)
    {
        let data = try! encoder.encode(interaction)
        interactionChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    
    public func send(placeChangeSet: PlaceChangeSet)
    {
        let data = try! encoder.encode(placeChangeSet)
        worldstateChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    
    private func setupDataChannels()
    {
        interactionChannel = rtc.createDataChannel(as: "interactions", configuration: with(RTCDataChannelConfiguration()) {
            $0.isNegotiated = true
            $0.isOrdered = true
            $0.maxRetransmits = -1
            $0.channelId = 1
        })
        worldstateChannel = rtc.createDataChannel(as: "worldstate", configuration: with(RTCDataChannelConfiguration()) {
            $0.isNegotiated = true
            $0.isOrdered = false
            $0.maxRetransmits = 0
            $0.channelId = 2
        })
    }
    
    
    //MARK: - RTC delegates
    public func session(didConnect: RTCSession)
    {
        self.delegate?.session(didConnect: self)
    }
    
    public func session(didDisconnect: RTCSession)
    {
        self.delegate?.session(didDisconnect: self)
    }
    
    let decoder = BinaryDecoder()
    public func session(_: RTCSession, didReceiveData data: Data, on channel: RTCDataChannel)
    {
        if channel == interactionChannel
        {
            if let inter = try? decoder.decode(Interaction.self, from: data)
            {
                self.delegate?.session(self, didReceiveInteraction: inter)
            } else {
                print("Warning, dropped unparseable interaction")
            }
        }
    }
}
