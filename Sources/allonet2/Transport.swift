//
//  Transport.swift
//  
//
//  Created by nevyn Bengtsson on 2023-11-20.
//

import Foundation
import WebRTC

public struct OfferResponse: Codable
{
    let sdp: String
    let candidates: [OfferResponseIceCandidate]
    let clientId: UUID
    public init(sdp: String, candidates: [OfferResponseIceCandidate], clientId: UUID) {
        self.sdp = sdp
        self.candidates = candidates
        self.clientId = clientId
    }
}

public struct OfferResponseIceCandidate: Codable
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
}
