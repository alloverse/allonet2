//
//  Transport.swift
//  
//
//  Created by nevyn Bengtsson on 2023-11-20.
//

import Foundation
import WebRTC

public struct SignallingPayload: Codable
{
    let sdp: String
    let candidates: [SignallingIceCandidate]
    public let clientId: UUID?
    public init(sdp: String, candidates: [SignallingIceCandidate], clientId: UUID?)
    {
        self.sdp = sdp
        self.candidates = candidates
        self.clientId = clientId
    }
    
    public func desc(for type: RTCSdpType) -> RTCSessionDescription
    {
        return RTCSessionDescription(type: type, sdp: self.sdp)
    }
    public func rtcCandidates() -> [RTCIceCandidate]
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
    public init(candidate: RTCIceCandidate)
    {
        sdpMid = candidate.sdpMid!
        sdpMLineIndex = candidate.sdpMLineIndex
        sdp = candidate.sdp
        serverUrl = candidate.serverUrl
    }
    
    public func candidate() -> RTCIceCandidate
    {
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}
