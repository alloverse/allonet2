//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-07.
//

import Foundation
import WebRTC

public protocol RTCSessionDelegate: AnyObject
{
    func session(didConnect: RTCSession)
    func session(didDisconnect: RTCSession)
    func session(_: RTCSession, didReceiveData: Data)
}

public class RTCSession: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    public private(set) var clientId: UUID?
    private let peer: RTCPeerConnection
    private let ingress: RTCDataChannel
    private var egress: RTCDataChannel?
    
    public weak var delegate: RTCSessionDelegate?
    
    private var localCandidates : [RTCIceCandidate] = []
    private var candidatesLocked = false
    private var candidatesContinuation: CheckedContinuation<Void, Never>?
    
    public override init() {
        peer = RTCSession.createPeerConnection()
        ingress = peer.dataChannel(forLabel: "WebRTCData", configuration: RTCDataChannelConfiguration())!
        
        super.init()
        peer.delegate = self
        ingress.delegate = self
    }
    
    public func write(data: Data)
    {
        egress!.sendData(RTCDataBuffer(data: data, isBinary: true))
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
        if newState == .connected
        {
            self.delegate?.session(didConnect: self)
        } else if newState == .failed || newState == .disconnected || newState == .closed {
            // TODO: Disconnected can resolve itself; don't assume it's broken immediately
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
        egress = dataChannel
    }
    
    //MARK: - Data channel delegate
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel)
    {
        
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer)
    {
        delegate?.session(self, didReceiveData: buffer.data)
    }
}
