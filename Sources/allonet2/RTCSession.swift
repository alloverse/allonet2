//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-07.
//

import Foundation
import WebRTC

// TODO: Replace WebRTCClient with this instead

public class RTCSession: WebRTCClientDelegate {
    public private(set) var clientId: UUID?
    private let rtc: WebRTCClient
    private var localCandidates : [RTCIceCandidate] = []
    private var candidatesLocked = false
    
    public init() {
        self.rtc = WebRTCClient(iceServers: [])
        rtc.delegate = self
    }
    
    public func generateOffer() async -> String
    {
        clientId = UUID()
        return await withCheckedContinuation { cont in
            rtc.offer { sdp in
                cont.resume(returning: sdp.sdp)
            }
        }
    }
    
    public func generateAnswer(offer: RTCSessionDescription, remoteCandidates: [RTCIceCandidate]) async throws -> String
    {
        
        try await set(remoteSdp: offer)
        for cand in remoteCandidates
        {
            try await set(remoteCandidate: cand)
        }
        return await withCheckedContinuation { cont in
            rtc.answer { sdp in
                cont.resume(returning: sdp.sdp)
            }
        }
    }
    
    private func set(remoteSdp: RTCSessionDescription) async throws
    {
        return try await withCheckedThrowingContinuation() { cont in
            rtc.set(remoteSdp: remoteSdp) { err in
                guard let err = err else {
                    cont.resume(throwing: err!)
                    return
                }
                cont.resume()
            }
        }
    }
    private func set(remoteCandidate: RTCIceCandidate) async throws
    {
        return try await withCheckedThrowingContinuation() { cont in
            rtc.set(remoteCandidate: remoteCandidate) { err in
                guard let err = err else {
                    cont.resume(throwing: err!)
                    return
                }
                cont.resume()
            }
        }
    }
    
    public func gatherCandidates() async -> [RTCIceCandidate]
    {
        // TODO: Is there another callback for "all relevant local candidates found for now" we can use instead of a timer?
        try! await Task.sleep(nanoseconds: 500*1000*1000)
        candidatesLocked = true
        return localCandidates
    }
    
    public func webRTCClient(_ client: allonet2.WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        if candidatesLocked
        {
            print("discovered local candidate after response already sent")
            return
        }
        localCandidates.append(candidate)
    }
    
    public func webRTCClient(_ client: allonet2.WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
        print("RTC state is now \(state)")
    }
    
    public func webRTCClient(_ client: allonet2.WebRTCClient, didReceiveData data: Data) {
        print("RTC got some data \(data)")
    }
}
