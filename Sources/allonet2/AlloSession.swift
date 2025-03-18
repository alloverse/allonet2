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
    
    /// This client has received an interaction from the place itself or another agent for you to react or respond to. Note: responses to send(request:) are not included here.
    func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    
    func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    func session(_: AlloSession, didReceiveIntent intent: Intent)
}

/// Wrapper of RTCSession, adding Alloverse-specific channels and data types
public class AlloSession : NSObject, RTCSessionDelegate
{
    public weak var delegate: AlloSessionDelegate?

    public let rtc = RTCSession()
    private var interactionChannel: RTCDataChannel!
    private var worldstateChannel: RTCDataChannel!
    
    private var outstandingInteractions: [Interaction.RequestID: CheckedContinuation<Interaction, Never>] = [:]
    
    public enum Side { case client, server }
    private let side: Side
    
    public init(side: Side)
    {
        self.side = side
        super.init()
        rtc.delegate = self
        setupDataChannels()
    }
    
    private convenience override init()
    {
        self.init(side: .client)
    }
    
    let encoder = BinaryEncoder()
    
    public func send(interaction: Interaction)
    {
        let data = try! encoder.encode(interaction)
        interactionChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    
    public func request(interaction: Interaction) async -> Interaction
    {
        assert(interaction.type == .request)
        return await withCheckedContinuation {
            outstandingInteractions[interaction.requestId] = $0
            send(interaction: interaction)
        }
    }
    
    public func send(placeChangeSet: PlaceChangeSet)
    {
        let data = try! encoder.encode(placeChangeSet)
        worldstateChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    
    public func send(_ intent: Intent)
    {
        let data = try! encoder.encode(intent)
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
            do {
                let inter = try decoder.decode(Interaction.self, from: data)
                if let continuation = outstandingInteractions[inter.requestId]
                {
                    assert(inter.type == .response)
                    continuation.resume(with: .success(inter))
                }
                else
                {
                    self.delegate?.session(self, didReceiveInteraction: inter)
                }
            }
            catch(let e)
            {
                print("Warning, dropped unparseable interaction: \(e)")
            }
        }
        else if channel == worldstateChannel && side == .client
        {
            do {
                let worldstate = try decoder.decode(PlaceChangeSet.self, from: data)
                self.delegate?.session(self, didReceivePlaceChangeSet: worldstate)
            }
            catch (let e)
            {
                print("Warning, dropped unparseable worldstate: \(e)")
            }
        }
        else if channel == worldstateChannel && side == .server
        {
            guard let intent = try? decoder.decode(Intent.self, from: data) else
            {
                print("Warning, \(rtc.clientId!.uuidString) dropped unparseable intent")
                return
            }
            self.delegate?.session(self, didReceiveIntent: intent)
        }
    }
}
