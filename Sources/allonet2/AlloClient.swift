//
//  AlloClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation

public class AlloClient : AlloSessionDelegate, Identifiable
{
    let url: URL
    let session = AlloSession()
    public let world = World()
    public var state = ConnectionState.disconnected
    
    public var id: String? {
        get
        {
            session.rtc.clientId?.uuidString
        }
    }
    
    public init(url: URL)
    {
        self.url = url
        session.delegate = self
    }
    
    public func connect() async throws
    {
        guard state.allowConnecting() else
        {
            throw ConnectionError.alreadyConnected
        }
        state = .connecting
        
        let offer = SignallingPayload(
        	sdp: try await session.rtc.generateOffer(),
        	candidates: (await session.rtc.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
            clientId: nil
        )
        let request = NSMutableURLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(offer)
        let (data, _) = try await URLSession.shared.data(for: request as URLRequest)
        let answer = try JSONDecoder().decode(SignallingPayload.self, from: data)
        
        try await session.rtc.receive(
            client: answer.clientId!,
            answer: answer.desc(for: .answer),
            candidates: answer.rtcCandidates()
        )
    }
    
    public func session(didConnect sess: AlloSession)
    {
        state = .connected
        
        print("Connected as \(sess.rtc.clientId!)")
        sess.send(interaction: Interaction(
            type: .request,
            senderEntityId: "",
            receiverEntityId: "place",
            requestId: "ANN0",
            body: .announce(version: "0.1")
        ))
    }
    
    public func session(didDisconnect sess: AlloSession)
    {
        state = .disconnected
        print("Disconnected")
    }
    
    public func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    {
        print("Received interaction: \(inter)")
    }
}

public enum ConnectionState : Equatable
{
    case disconnected
    case connecting
    case connected
    case error(Bool) // true = permanent, will not reconnect
    
    func allowConnecting() -> Bool
    {
        switch self {
        case .disconnected, .error(let _):
            return true
        default:
            return false
        }
    }
}

public enum ConnectionError : Error
{
    case alreadyConnected
}
