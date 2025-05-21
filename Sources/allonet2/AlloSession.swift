//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-06-04.
//

import Foundation
import LiveKitWebRTC
import BinaryCodable

public protocol AlloSessionDelegate: AnyObject
{
    func session(didConnect sess: AlloSession)
    func session(didDisconnect sess: AlloSession)
    
    /// This client has received an interaction from the place itself or another agent for you to react or respond to. Note: responses to send(request:) are not included here.
    func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    
    func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    func session(_: AlloSession, didReceiveIntent intent: Intent)
    
    func session(_: AlloSession, didReceiveMediaStream: AlloMediaStream)
}

public class AlloMediaStream
{
    internal let stream: LKRTCMediaStream
    
    internal init(stream: LKRTCMediaStream) {
        self.stream = stream
    }
}

/// Wrapper of RTCSession, adding Alloverse-specific channels and data types
public class AlloSession : NSObject, RTCSessionDelegate
{
    public weak var delegate: AlloSessionDelegate?

    internal let rtc: RTCSession
    
    private var interactionChannel: LKRTCDataChannel!
    private var worldstateChannel: LKRTCDataChannel!
    
    private var micTrack: LKRTCAudioTrack!
    private var incomingStreams: [String/*StreamID*/: AlloMediaStream] = [:]
    
    private var outstandingInteractions: [Interaction.RequestID: CheckedContinuation<Interaction, Never>] = [:]
    
    public enum Side { case client, server }
    private let side: Side
    
    public init(side: Side, sendMicrophone: Bool = false, status: ConnectionStatus)
    {
        self.side = side
        self.rtc = RTCSession(status: status)
        super.init()
        rtc.delegate = self
        
        setupDataChannels()
        if sendMicrophone
        {
            micTrack = rtc.createMicrophoneTrack()
        }
    }
    
    let encoder = BinaryEncoder()
    
    public func send(interaction: Interaction)
    {
        let data = try! encoder.encode(interaction)
        interactionChannel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
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
        worldstateChannel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }
    
    public func send(_ intent: Intent)
    {
        let data = try! encoder.encode(intent)
        worldstateChannel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }
    
    private func setupDataChannels()
    {
        interactionChannel = rtc.createDataChannel(as: "interactions", configuration: with(LKRTCDataChannelConfiguration()) {
            $0.isNegotiated = true
            $0.isOrdered = true
            $0.maxRetransmits = -1
            $0.channelId = 1
        })
        worldstateChannel = rtc.createDataChannel(as: "worldstate", configuration: with(LKRTCDataChannelConfiguration()) {
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
    public func session(_: RTCSession, didReceiveData data: Data, on channel: LKRTCDataChannel)
    {
        if channel == interactionChannel
        {
            do {
                let inter = try decoder.decode(Interaction.self, from: data)
                if case .internal_renegotiate(.offer, let payload) = inter.body
                {
                    respondToRenegotiation(offer: payload, request: inter)
                    return
                }
                
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
    
    public func session(requestsRenegotiation session: RTCSession)
    {
        Task
        {
            do
            {
                try await renegotiateInner()
            }
            catch (let e)
            {
                // TODO: store the error, mark as temporary, and force upper lever to reconnect
                print("Failed to renegotiate offer for \(rtc.clientId!): \(e)")
                rtc.disconnect()
            }
        }
    }

    private func renegotiateInner() async throws
    {
        let offer = SignallingPayload(
            sdp: try await rtc.generateOffer(),
            candidates: (await rtc.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
            clientId: rtc.clientId!
        )
        print("Sending renegotiation offer over RPC")
        let response = await request(interaction: Interaction(type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity, body: .internal_renegotiate(.offer, offer)))
        guard case .internal_renegotiate(.answer, let answer) = response.body else
        {
            throw AlloverseError(
                domain: AlloverseErrorCode.domain,
                code: AlloverseErrorCode.failedRenegotiation.rawValue,
                description: "unexpected renegotiation answer: \(response.body)"
            )
        }
        
        try await rtc.receive(
            client: rtc.clientId!,
            answer: answer.desc(for: .answer),
            candidates: answer.rtcCandidates()
        )
        
        print("RTC renegotiation complete on the offering side")
    }
    
    private func respondToRenegotiation(offer: SignallingPayload, request: Interaction)
    {
        print("Received renegotiation offer over RPC")
        Task
        {
            do
            {
                try await respondToRenegotiationInner(offer: offer, request: request)
            }
            catch(let e)
            {
                // TODO: store the error, mark as temporary, and force upper lever to reconnect
                print("Failed to renegotiate answer for \(rtc.clientId!): \(e)")
                rtc.disconnect()

            }
        }
    }
    
    func respondToRenegotiationInner(offer: SignallingPayload, request: Interaction) async throws
    {
        let answer = SignallingPayload(
            sdp: try await rtc.generateAnswer(offer: offer.desc(for: .offer), remoteCandidates: offer.rtcCandidates()),
            candidates: (await rtc.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
            clientId: rtc.clientId!
        )
        
        let response = request.makeResponse(with: .internal_renegotiate(.answer, answer))
        self.send(interaction: response)
        
        print("RTC renegotiation complete on the answering side")
    }
    
    // MARK: - Audio
    public func session(_: RTCSession, didReceiveMediaStream stream: LKRTCMediaStream)
    {
        let allostream = AlloMediaStream(stream: stream)
        incomingStreams[stream.streamId] = allostream
        delegate?.session(self, didReceiveMediaStream: allostream)
    }
    
    public func addOutgoing(stream: AlloMediaStream)
    {
        rtc.addOutgoing(stream: stream.stream)
    }
}
