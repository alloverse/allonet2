//
//  File.swift
//
//
//  Created by Nevyn Bengtsson on 2024-06-04.
//

import Foundation
import PotentCodables
import PotentCBOR
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
    func session(_: AlloSession, didReceiveLog message: StoredLogMessage)
    
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
    nonisolated(unsafe) private var logger = Logger(labelSuffix: "session")

    internal let transport: Transport
    
    private var interactionChannel: DataChannel!
    private var worldstateChannel: DataChannel!
    private var logsChannel: DataChannel!
    
    // TODO: This should be called streams, because it includes both incoming and outgoing
    @Published
    public private(set) var incomingStreams: [MediaStreamId: MediaStream] = [:]
    
    private var outstandingInteractions: [Interaction.RequestID: CheckedContinuation<Interaction, Never>] = [:]
    
    public enum Side { case client, server }
    private let side: Side
    
    // --- Negotiation
    private let negotiation = StateMachine<NegotiationState>(.stable, label: "Negotiation")

    /// What to do if we receive an offer while we already have an outstanding offer?
    /// Client is polite (rolls back own offer, accepts theirs).
    /// Server is impolite (rejects incoming, keeps own).
    private enum RenegotiationConflictBehavior { case polite, impolite }
    private var renegotiationConflictBehavior: RenegotiationConflictBehavior
    {
        switch side {
            case .client: return .polite
            case .server: return .impolite
        }
    }

    /// Transition negotiation back to stable, and auto-trigger renegotiation if one was deferred.
    private func negotiationTransitionToStable()
    {
        let hadDeferred = negotiation.current.hasDeferredRenegotiation
        negotiation.transition(to: .stable)
        if hadDeferred
        {
            logger.info("Deferred renegotiation pending; kicking it off now.")
            self.transport(requestsRenegotiation: transport)
        }
    }
    
    
    public init(side: Side, transport: Transport)
    {
        self.side = side
        self.transport = transport
        super.init()
        self.logger = Logger(labelSuffix: "session", metadataProvider: Logger.MetadataProvider {
            guard let cid = self.clientId else { return [:] }
            return ["clientId": .stringConvertible(cid)]
        })
        transport.delegate = self
        
        setupDataChannels()
    }
    
    // TODO: this unsafe is going to bite me... store it threadsafely so logging can use it?
    nonisolated(unsafe) public var clientId: ClientId? { transport.clientId }
    
    let encoder = CBOREncoder()
    
    public func send(interaction: Interaction)
    {
        dispatchPrecondition(condition: .onQueue(.main))
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
        dispatchPrecondition(condition: .onQueue(.main))
        let data = try! encoder.encode(placeChangeSet)
        transport.send(data: data, on: .intentWorldState)
    }
    
    public func send(_ intent: Intent)
    {
        dispatchPrecondition(condition: .onQueue(.main))
        let data = try! encoder.encode(intent)
        transport.send(data: data, on: .intentWorldState)
    }
    
    public func send(_ logLine: StoredLogMessage)
    {
        dispatchPrecondition(condition: .onQueue(.main))
        let data = try! encoder.encode(logLine)
        transport.send(data: data, on: .logs)
    }
    
    public func generateOffer() async throws -> SignallingPayload
    {
        logger.debug("Generating offer...")
        negotiation.transition(to: .negotiating(role: .offering, deferredRenegotiation: false))
        do {
            return try await transport.generateOffer()
        } catch {
            negotiation.transition(to: .stable)
            throw error
        }
    }
    
    public func generateAnswer(offer: SignallingPayload) async throws -> SignallingPayload
    {
        logger.debug("Generating answer...")
        negotiation.transition(to: .negotiating(role: .answering, deferredRenegotiation: false))
        do {
            return try await transport.generateAnswer(for: offer)
        } catch {
            negotiation.transition(to: .stable)
            throw error
        }
    }
    
    public func acceptAnswer(_ answer: SignallingPayload) async throws
    {
        logger.debug("Accepting answer...")
        defer { negotiationTransitionToStable() }
        try await transport.acceptAnswer(answer)
    }
    
    private func rollbackOffer() async throws
    {
        try await transport.rollbackOffer()
        negotiationTransitionToStable()
    }
    
    public func disconnect()
    {
        dispatchPrecondition(condition: .onQueue(.main))
        transport.disconnect()
    }
    
    private func setupDataChannels()
    {
        interactionChannel = transport.createDataChannel(label: .interactions, reliable: true)
        worldstateChannel = transport.createDataChannel(label: .intentWorldState, reliable: false)
        logsChannel = transport.createDataChannel(label: .logs, reliable: true)
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
        if state == .stable && negotiation.current.hasDeferredRenegotiation
        {
            negotiationTransitionToStable()
        }
    }
    
    let decoder = CBORDecoder()
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
        case .logs:
            let logLine: StoredLogMessage
            do {
                logLine = try decoder.decode(StoredLogMessage.self, from: data)
            } catch {
                logger.warning("Dropped unparseable log line: \(error)")
                return
            }
            Task { @MainActor in self.delegate?.session(self, didReceiveLog: logLine) }
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
        if case .negotiating(let role, _) = negotiation.current
        {
            logger.info("Renegotiation requested while negotiating; postponing it...")
            negotiation.transition(to: .negotiating(role: role, deferredRenegotiation: true))
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
        if negotiation.current.isNegotiating
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
            // TODO: store the error, mark as temporary, and force upper level to reconnect
            logger.info("Failed to renegotiate answer: \(e)")
            transport.disconnect()
        }
    }
    
    func respondToRenegotiationInner(offer: SignallingPayload, request: Interaction) async throws
    {
        let answer = try await generateAnswer(offer: offer)

        let response = request.makeResponse(with: .internal_renegotiate(.answer, answer))
        self.send(interaction: response)

        negotiationTransitionToStable()
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
