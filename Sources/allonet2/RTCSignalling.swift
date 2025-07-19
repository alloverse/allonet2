//
//  Transport.swift
//  
//
//  Created by nevyn Bengtsson on 2023-11-20.
//

import Foundation

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
}

public struct SignallingIceCandidate: Codable
{
    public let sdpMid: String
    public let sdpMLineIndex: Int32
    public let sdp: String
    public let serverUrl: String?
    
    public init(sdpMid: String, sdpMLineIndex: Int32, sdp: String, serverUrl: String?)
    {
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.sdp = sdp
        self.serverUrl = serverUrl
    }
}
