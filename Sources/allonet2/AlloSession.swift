//
//  File.swift
//
//
//  Created by Nevyn Bengtsson on 2024-06-04.
//

import Foundation
import BinaryCodable

public protocol AlloSessionDelegate: AnyObject
{
    func session(didConnect sess: AlloSession)
    func session(didDisconnect sess: AlloSession)
    
    /// This client has received an interaction from the place itself or another agent for you to react or respond to. Note: responses to send(request:) are not included here.
    func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    
    func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    func session(_: AlloSession, didReceiveIntent intent: Intent)
    
    func session(_: AlloSession, didReceiveMediaStream: MediaStream)
}

/// Wrapper of Transport, adding Alloverse-specific channels and data types
public class AlloSession : NSObject, TransportDelegate
{
    public weak var delegate: AlloSessionDelegate?

    internal let transport: Transport
    
    private var interactionChannel: DataChannel!
    private var worldstateChannel: DataChannel!
    
    private var incomingStreams: [String/*StreamID*/: MediaStream] = [:]
    
    private var outstandingInteractions: [Interaction.RequestID: CheckedContinuation<Interaction, Never>] = [:]
    
    public enum Side { case client, server }
    private let side: Side
    
    public init(side: Side, transport: Transport)
    {
        self.side = side
        self.transport = transport
        super.init()
        transport.delegate = self
        
        setupDataChannels()
    }
    
    public var clientId: ClientId? { transport.clientId }
    
    let encoder = BinaryEncoder()
    
    public func send(interaction: Interaction)
    {
        let data = try! encoder.encode(interaction)
        transport.send(data: data, on: .interactions)
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
        transport.send(data: data, on: .intentWorldState)
    }
    
    public func send(_ intent: Intent)
    {
        let data = try! encoder.encode(intent)
        transport.send(data: data, on: .intentWorldState)
    }
    
    public func generateOffer() async throws -> SignallingPayload {
        return try await transport.generateOffer()
    }
    
    public func generateAnswer(offer: SignallingPayload) async throws -> SignallingPayload {
        return try await transport.generateAnswer(for: offer)
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws {
        try await transport.acceptAnswer(answer)
    }
    
    public func disconnect() {
        transport.disconnect()
    }
    
    private func setupDataChannels()
    {
        interactionChannel = transport.createDataChannel(label: .interactions, reliable: true)
        worldstateChannel = transport.createDataChannel(label: .intentWorldState, reliable: false)
    }
    
    //MARK: - Transport delegates
    public func transport(didConnect transport: Transport)
    {
        self.delegate?.session(didConnect: self)
    }
    
    public func transport(didDisconnect transport: Transport)
    {
        self.delegate?.session(didDisconnect: self)
    }
    
    let decoder = BinaryDecoder()
    public func transport(_ transport: Transport, didReceiveData data: Data, on channel: DataChannel)
    {
        switch channel.label
        {
        case  .interactions:
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
        case .intentWorldState:
            switch side {
            case .client:
                do {
                    let worldstate = try decoder.decode(PlaceChangeSet.self, from: data)
                    self.delegate?.session(self, didReceivePlaceChangeSet: worldstate)
                }
                catch (let e)
                {
                    print("Warning, dropped unparseable worldstate: \(e)")
                }
            case .server:
                guard let intent = try? decoder.decode(Intent.self, from: data) else
                {
                    print("Warning, \(transport.clientId!.uuidString) dropped unparseable intent")
                    return
                }
                self.delegate?.session(self, didReceiveIntent: intent)
            }
        default:
            fatalError("Unexpected message")
        }
    }
    
    public func transport(requestsRenegotiation transport: Transport)
    {
        Task
        {
            do
            {
                try await renegotiateInner()
            }
            catch (let e)
            {
                // TODO: store the error, mark as temporary, and force upper level to reconnect
                print("Failed to renegotiate offer for \(transport.clientId!): \(e)")
                transport.disconnect()
            }
        }
    }

    private func renegotiateInner() async throws
    {
        let offer = try await transport.generateOffer()
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
        
        try await transport.acceptAnswer(answer)
        
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
                print("Failed to renegotiate answer for \(transport.clientId!): \(e)")
                transport.disconnect()

            }
        }
    }
    
    func respondToRenegotiationInner(offer: SignallingPayload, request: Interaction) async throws
    {
        let answer = try await transport.generateAnswer(for: offer)
        
        let response = request.makeResponse(with: .internal_renegotiate(.answer, answer))
        self.send(interaction: response)
        
        print("RTC renegotiation complete on the answering side")
    }
    
    // MARK: - Audio
    public func transport(_ transport: Transport, didReceiveMediaStream stream: MediaStream)
    {
        incomingStreams[stream.streamId] = stream
        delegate?.session(self, didReceiveMediaStream: stream)
    }
}
