//
//  File.swift
//
//
//  Created by Nevyn Bengtsson on 2024-06-04.
//

import Foundation
import BinaryCodable
import OpenCombineShim
import Logging

@MainActor
public protocol AlloSessionDelegate: AnyObject
{
    func session(didConnect sess: AlloSession)
    func session(didDisconnect sess: AlloSession)
    
    /// This client has received an interaction from the place itself or another agent for you to react or respond to. Note: responses to send(request:) are not included here.
    func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    
    func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    func session(_: AlloSession, didReceiveIntent intent: Intent)
    
    /// New audio or video track connected.
    func session(_: AlloSession, didReceiveMediaStream: MediaStream)
    /// The audio or video track disconnected. In contrast to the Transport delegate, this layer will also call didRemove... for all connected streams right before the session disconnects, so you can clean up.
    func session(_: AlloSession, didRemoveMediaStream: MediaStream)
}

/// Wrapper of Transport, adding Alloverse-specific channels and data types
@MainActor
public class AlloSession : NSObject, TransportDelegate
{
    public weak var delegate: AlloSessionDelegate?
    nonisolated(unsafe) private var logger = Logger(label: "session")

    internal let transport: Transport
    
    private var interactionChannel: DataChannel!
    private var worldstateChannel: DataChannel!
    
    // TODO: This should be called streams, because it includes both incoming and outgoing
    @Published
    public private(set) var incomingStreams: [MediaStreamId: MediaStream] = [:]
    
    private var outstandingInteractions: [Interaction.RequestID: CheckedContinuation<Interaction, Never>] = [:]
    
    public enum Side { case client, server }
    private let side: Side
    
    // --- Negotiation
    // We've kicked off renegotiation and we are waiting for a response. TODO: This should be exactly equivalent to peer.signalingState==.hasLocalOffer. Remove the bool and query the transport for its signalingState instead?
    private var hasOutstandingNegotiationOffer = false
    // Our state dirtied _while_ connecting or renegotiating, so as soon as we're stable, kick off another negotation round
    private var needsRenegotiationWhenStable = false
    
    /// What to do if we receive an offer while we already have an outstanding offer? In other words, if we get a renegotiation request _while_ we're already renegotiating?
    private enum RenegotiationConflictBehavior
    {
        // This side will throw away their request and rollback their offer; apply the other side's offer, and when we create an answer we'll get to apply our changes anyway.
        case polite
        // This side will discard the incoming request and await an answer to their outstanding offer.
        case impolite
    }
    private var renegotiationConflictBehavior: RenegotiationConflictBehavior
    {
        switch side {
            case .client: return .polite
            case .server: return .impolite
        }
    }
    
    
    public init(side: Side, transport: Transport)
    {
        self.side = side
        self.transport = transport
        super.init()
        self.logger = Logger(label: "session", metadataProvider: Logger.MetadataProvider {
            guard let cid = self.clientId else { return [:] }
            return ["clientId": .stringConvertible(cid)]
        })
        transport.delegate = self
        
        setupDataChannels()
    }
    
    // TODO: this unsafe is going to bite me... store it threadsafely so logging can use it?
    nonisolated(unsafe) public var clientId: ClientId? { transport.clientId }
    
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
    
    public func generateOffer() async throws -> SignallingPayload
    {
        logger.debug("Generating offer...")
        assert(hasOutstandingNegotiationOffer == false)
        hasOutstandingNegotiationOffer = true
        do {
            return try await transport.generateOffer()
        } catch {
            hasOutstandingNegotiationOffer = false
            throw error
        }
    }
    
    public func generateAnswer(offer: SignallingPayload) async throws -> SignallingPayload
    {
        logger.debug("Generating answer...")
        assert(hasOutstandingNegotiationOffer == false)
        return try await transport.generateAnswer(for: offer)
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws
    {
        logger.debug("Accepting answer...")
        defer { hasOutstandingNegotiationOffer = false }
        try await transport.acceptAnswer(answer)
    }
    
    private func rollbackOffer() async throws
    {
        try await transport.rollbackOffer()
        hasOutstandingNegotiationOffer = false
    }
    
    public func disconnect()
    {
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
        for (_mid, stream) in incomingStreams
        {
            self.delegate?.session(self, didRemoveMediaStream: stream)
        }
        incomingStreams.removeAll()
        self.delegate?.session(didDisconnect: self)
    }
    
    public func transport(_ transport: any Transport, didChangeSignallingState state: TransportSignallingState)
    {
        if state == .stable && needsRenegotiationWhenStable
        {
            // xxx: we're setting this to false both in the end of negotiation methods, and here... not sure I like that
            hasOutstandingNegotiationOffer = false
            
            logger.info("Signalling is now stable, we can now kick off the pending renegotiation.")
            needsRenegotiationWhenStable = false
            self.transport(requestsRenegotiation: transport)
        }
    }
    
    let decoder = BinaryDecoder()
    nonisolated public func transport(_ transport: Transport, didReceiveData data: Data, on channel: DataChannel)
    {
        switch channel.alloLabel {
        case .interactions:
            let inter: Interaction
            do { inter = try decoder.decode(Interaction.self, from: data) }
            catch {
                logger.warning("Dropped unparseable interaction: \(error)")
                return
            }
            Task { @MainActor in
                if case .internal_renegotiate(.offer, let payload) = inter.body {
                    await respondToRenegotiation(offer: payload, request: inter)
                } else if let continuation = outstandingInteractions[inter.requestId] {
                    continuation.resume(with: .success(inter))
                } else {
                    self.delegate?.session(self, didReceiveInteraction: inter)
                }
            }
        case .intentWorldState where side == .client:
            let worldstate: PlaceChangeSet
            do {
                worldstate = try decoder.decode(PlaceChangeSet.self, from: data)
            } catch {
                logger.warning("Dropped unparseable worldstate: \(error)")
                return
            }
            Task { @MainActor in self.delegate?.session(self, didReceivePlaceChangeSet: worldstate) }
        case .intentWorldState where side == .server:
            let intent: Intent
            do {
                intent = try decoder.decode(Intent.self, from: data)
            } catch {
                logger.warning("Dropped unparseable intent: \(error)")
                return
            }
            Task { @MainActor in self.delegate?.session(self, didReceiveIntent: intent) }
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
                logger.error("Failed to renegotiate offer, disconnecting: \(e)")
                transport.disconnect()
            }
        }
    }

    private func renegotiateInner() async throws
    {
        if hasOutstandingNegotiationOffer
        {
            logger.info("Renegotiation requested while negotiating; postponing it...")
            needsRenegotiationWhenStable = true
            return
        }
        
        let offer = try await generateOffer()
        logger.info("Sending renegotiation offer over RPC")
        let response = await request(interaction: Interaction(type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity, body: .internal_renegotiate(.offer, offer)))
        switch response.body
        {
            case .internal_renegotiate(.answer, let answer):
                try await acceptAnswer(answer)
                logger.info("RTC renegotiation complete on the offering side")
            case .error(domain: AlloverseErrorCode.domain, code: AlloverseErrorCode.discardedRenegotiation.rawValue, description: let _):
                logger.info("Offer was discarded, let's roll back if needed")
                try? await rollbackOffer()
            default:
                throw AlloverseError(
                    domain: AlloverseErrorCode.domain,
                    code: AlloverseErrorCode.failedRenegotiation.rawValue,
                    description: "unexpected renegotiation answer: \(response.body)"
                )
        }
    }
    
    private func respondToRenegotiation(offer: SignallingPayload, request: Interaction) async
    {
        logger.info("Received renegotiation offer over RPC")
        if hasOutstandingNegotiationOffer
        {
            switch renegotiationConflictBehavior {
            case .polite:
                logger.info("Politely discarding my pending offer and accepting the incoming offer instead.")
                try? await rollbackOffer()
            case .impolite:
                logger.info("Impolitely rejecting incoming renegotiation offer over RPC because we already have an outstanding offer.")
                let response = request.makeResponse(with: .error(
                    domain: AlloverseErrorCode.domain,
                    code: AlloverseErrorCode.discardedRenegotiation.rawValue,
                    description: "Please roll back your offer and accept my offer instead.")
                )
                self.send(interaction: response)
                return
            }
        }
        
        do
        {
            try await respondToRenegotiationInner(offer: offer, request: request)
        }
        catch(let e)
        {
            // TODO: store the error, mark as temporary, and force upper lever to reconnect
            logger.info("Failed to renegotiate answer: \(e)")
            transport.disconnect()
        }
    }
    
    func respondToRenegotiationInner(offer: SignallingPayload, request: Interaction) async throws
    {
        let answer = try await generateAnswer(offer: offer)
        
        let response = request.makeResponse(with: .internal_renegotiate(.answer, answer))
        self.send(interaction: response)
        
        logger.info("RTC renegotiation complete on the answering side")
    }
    
    // MARK: - Audio
    public func transport(_ transport: Transport, didReceiveMediaStream stream: MediaStream)
    {
        logger.info("Adding stream \(stream.mediaId)")
        incomingStreams[stream.mediaId] = stream
        delegate?.session(self, didReceiveMediaStream: stream)
    }
    
    public func transport(_ transport: Transport, didRemoveMediaStream stream: MediaStream)
    {
        logger.info("Removing stream \(stream.mediaId)")
        incomingStreams[stream.mediaId] = nil
        delegate?.session(self, didRemoveMediaStream: stream)
    }
    
}
