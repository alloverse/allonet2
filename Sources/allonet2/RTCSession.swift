//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-07.
//

import Foundation
import WebRTC
import BinaryCodable

public enum RTCSessionChannel {
    case interaction
    case worldstate
}

public protocol RTCSessionDelegate: AnyObject
{
    func session(didConnect: RTCSession)
    func session(didDisconnect: RTCSession)
    func session(_: RTCSession, didReceiveData data: Data, on channel: RTCDataChannel)
}

/// Wrapper of RTCPeerConnection with Alloverse-specific peer semantics
public class RTCSession: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    public private(set) var clientId: UUID?
    public let peer: RTCPeerConnection
    private var channels: [RTCDataChannel] = []
    
    public weak var delegate: RTCSessionDelegate?
    
    private var localCandidates : [RTCIceCandidate] = []
    private var candidatesLocked = false
    private var candidatesContinuation: CheckedContinuation<Void, Never>?
    
    public override init() {
        peer = RTCSession.createPeerConnection()
        
        super.init()
        peer.delegate = self
    }
    
    public func disconnect()
    {
        peer.close()
    }
    
    public func generateOffer() async throws -> String
    {
        return try await withCheckedThrowingContinuation { cont in
            peer.offer(for: mediaConstraints) { (sdp, error) in
                guard let sdp = sdp else {
                    cont.resume(throwing: error!)
                    return
                }
                self.peer.setLocalDescription(sdp) { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: sdp.sdp)
                    }
                }
            }
        }
    }
    
    public func generateAnswer(offer: RTCSessionDescription, remoteCandidates: [RTCIceCandidate]) async throws -> String
    {
        clientId = UUID()
        try await set(remoteSdp: offer)
        for cand in remoteCandidates
        {
            try await set(remoteCandidate: cand)
        }
        return try await withCheckedThrowingContinuation { cont in
            peer.answer(for: mediaConstraints) { (sdp, error) in
                guard let sdp = sdp else {
                    cont.resume(throwing: error!)
                    return
                }
                self.peer.setLocalDescription(sdp) { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: sdp.sdp)
                    }
                }
            }
        }
    }
    
    public func receive(client id: UUID, answer: RTCSessionDescription, candidates: [RTCIceCandidate]) async throws
    {
        clientId = id
        try await set(remoteSdp: answer)
        for cand in candidates
        {
            try await set(remoteCandidate: cand)
        }
    }
    
    private func set(remoteSdp: RTCSessionDescription) async throws
    {
        return try await withCheckedThrowingContinuation() { cont in
            peer.setRemoteDescription(remoteSdp) { err in
                if let err2 = err {
                    cont.resume(throwing: err2)
                    return
                }
                cont.resume()
            }
        }
    }
    public func set(remoteCandidate: RTCIceCandidate) async throws
    {
        return try await withCheckedThrowingContinuation() { cont in
            peer.add(remoteCandidate) { err in
                if let err2 = err {
                    cont.resume(throwing: err2)
                    return
                }
                cont.resume()
            }
        }
    }
    
    
    public func gatherCandidates() async -> [RTCIceCandidate]
    {
        await withCheckedContinuation {
            if candidatesLocked {
                $0.resume()
            } else {
                candidatesContinuation = $0
            }
        }
        return localCandidates
    }
    
    public func createDataChannel(as label: String, configuration: RTCDataChannelConfiguration) -> RTCDataChannel?
    {
        guard let chan = peer.dataChannel(forLabel: label, configuration: configuration)
            else { return nil }
        chan.delegate = self
        self.channels.append(chan)
        return chan
    }
    
    //MARK: - Internals
    

    private static func createPeerConnection() -> RTCPeerConnection
    {
        let config = RTCConfiguration()
        
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        // Define media constraints. DtlsSrtpKeyAgreement is required to be true to be able to connect with web browsers.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":kRTCMediaConstraintsValueTrue])
        
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            fatalError("Could not create new RTCPeerConnection")
        }
        
        return peerConnection
    }
    
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    
    private let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    
    private var didFullyConnect = false
    private func maybeConnected()
    {
        if
            !didFullyConnect &&
            peer.iceConnectionState == .connected &&
             channels.count > 0 &&
            channels.allSatisfy({$0.readyState == .open})
            
        {
            didFullyConnect = true
            self.delegate?.session(didConnect: self)
        }
    }
    
    //MARK: - Peer connection delegates
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState)
    {
        
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream)
    {
        
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream)
    {
        
    }
    
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection)
    {
        
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState)
    {
        print("Session \(clientId?.debugDescription ?? "unknown") ICE state \(newState)")
        if newState == .connected || newState == .completed
        {
            // actually, just checking the data channels is enough?
            self.maybeConnected()
        }
        else if newState == .failed || newState == .disconnected
        {
            // TODO: Disconnected can resolve itself; don't assume it's broken immediately
            self.disconnect() // will invoke this callback again with .closed
        }
        else if newState == .closed
        {
            self.delegate?.session(didDisconnect: self)
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState)
    {
        if newState == .complete {
            candidatesLocked = true
            if let candidatesContinuation = candidatesContinuation {
                candidatesContinuation.resume()
            }
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate)
    {
        if candidatesLocked
        {
            print("!! discovered local candidate after response already sent")
            return
        }
        localCandidates.append(candidate)
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate])
    {
        print("!! Lost candidate, shouldn't happen since we're not gathering continuously")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel)
    {
        if dataChannel.label == "interactions"
        {
            print("Got interaction channel")
        }
        else if dataChannel.label == "worldstate"
        {
            print("Got worldstate channel")
        }
        dataChannel.delegate = self
        self.maybeConnected()
    }
    
    //MARK: - Data channel delegate
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel)
    {
        print("Data channel \(dataChannel.label) state \(dataChannel.readyState)")
        maybeConnected()
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer)
    {
        delegate?.session(self, didReceiveData: buffer.data, on: dataChannel)
    }
}
