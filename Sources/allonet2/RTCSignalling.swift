//
//  Transport.swift
//  
//
//  Created by nevyn Bengtsson on 2023-11-20.
//

import Foundation
import LiveKitWebRTC

public enum SignallingDirection: Codable
{
    case offer
    case answer
}

public struct SignallingPayload: Codable
{
    public let sdp: String
    public let candidates: [SignallingIceCandidate]
    public let clientId: UUID?
    public init(sdp: String, candidates: [SignallingIceCandidate], clientId: UUID?)
    {
        self.sdp = sdp
        self.candidates = candidates
        self.clientId = clientId
    }
    
    public func desc(for type: RTCSdpType) -> LKRTCSessionDescription
    {
        return LKRTCSessionDescription(type: type, sdp: self.sdp)
    }
    public func rtcCandidates() -> [LKRTCIceCandidate]
    {
        return candidates.map { $0.candidate() }
    }
}

public struct SignallingIceCandidate: Codable
{
    let sdpMid: String
    let sdpMLineIndex: Int32
    let sdp: String
    let serverUrl: String?
    public init(candidate: LKRTCIceCandidate)
    {
        sdpMid = candidate.sdpMid!
        sdpMLineIndex = candidate.sdpMLineIndex
        sdp = candidate.sdp
        serverUrl = candidate.serverUrl
    }
    
    public func candidate() -> LKRTCIceCandidate
    {
        return LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}
