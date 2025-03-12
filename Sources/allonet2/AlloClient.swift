//
//  AlloClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-02-11.
//

import Foundation
import Combine

public class AlloClient : AlloSessionDelegate, ObservableObject, Identifiable
{
    public let place = PlaceState()
    
    let url: URL
    let avatarDesc: [AnyComponent]
    let session = AlloSession(side: .client)
    var currentIntent = Intent(ackStateRev: 0) {
        didSet {
            Task { await heartbeat.markChanged() }
        }
    }
    lazy var heartbeat: HeartbeatTimer = {
        /// Keep a shorter coalesce than server so we ack before the next change; longer keepalive so we don't send an unnecessary keepalive juust before the server's keepalive.
        return HeartbeatTimer(coalesceDelay: 5_000_000, keepaliveDelay: 1_100_000_000) {
            self.sendIntent()
        }
    }()
    
    @Published public var state = ConnectionState.idle
    // What was the last connection error?
    // If state is now .idle, it was a permanent error and we're wholly disconnected.
    // If state is now .waitingToReconnect, it was a temporary error and we're about to reconnect.
    @Published public var lastError: Error?
    @Published public private(set) var willReconnectAt: Date?
    
    private var connectTask: Task<Void, Never>? = nil
    private var reconnectionAttempts = 0

    
    public var id: String? {
        get
        {
            session.rtc.clientId?.uuidString
        }
    }
    
    public init(url: URL, avatarDescription: [AnyComponent])
    {
        self.url = url
        self.avatarDesc = avatarDescription
        session.delegate = self
    }
    
    private var connectionLoopCancellable: AnyCancellable?
    /// Connect, and stay connected until a permanent connection error happens, or user disconnects.
    public func stayConnected()
    {
        guard connectionLoopCancellable == nil else { return }
        
        // Move out of the idle state since we've been asked to get going.
        if state == .idle {
            print("Going from .idle to .waitingForReconnect")
            state = .waitingForReconnect
        }
        
        connectionLoopCancellable = $state.receive(on: DispatchQueue.main).sink
        { [weak self] nextState in
            guard let self = self else { return }
            print("state: \(nextState), error: \(String(describing: self.lastError)), willReconnectAt: \(String(describing: self.willReconnectAt))")
            switch nextState {
            case .waitingForReconnect:
                self.handleWaitingForReconnect()
            case .idle:
                disconnect()
            default:
                break
            }
        }
    }
    
    private func handleWaitingForReconnect()
    {
        // Prevent concurrent connection attempts.
        guard connectTask == nil else { return }
        
        // Reconnection backoff with exponential delay and a cap at 1m/try
        let delaySeconds = min(60, pow(2.0, Double(reconnectionAttempts)))
        willReconnectAt = delaySeconds > 0 ? Date().addingTimeInterval(delaySeconds) : nil
        reconnectionAttempts += 1
        print("connection attempt \(reconnectionAttempts) in \(delaySeconds) seconds")
        
        // Schedule connect() to be called at willReconnectAt.
        connectTask = Task { [weak self] in
            guard let self = self else { return }
            
            let delay = self.willReconnectAt?.timeIntervalSinceNow ?? 0
            print(String(format: "waiting for reconnect in %.1f seconds", delay))
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // Clear the task and reconnectDate before connecting.
            await MainActor.run {
                self.connectTask = nil
                self.willReconnectAt = nil
            }
            print("connecting...")
            await self.connect()
        }
    }

    
    /// Disconnect from peers and remain disconnected until asked to connect again by user
    public func disconnect()
    {
        connectTask?.cancel()
        connectTask = nil
        connectionLoopCancellable?.cancel()
        connectionLoopCancellable = nil
        willReconnectAt = nil
        reconnectionAttempts = 0
        session.rtc.disconnect()
    }
    
    private func connect() async
    {
        precondition(state == .waitingForReconnect, "Trying to connect while \(state)")
        DispatchQueue.main.async {
            self.state = .connecting
        }
        
        do {
            print("Trying to connect...")
            let offer = SignallingPayload(
                sdp: try await session.rtc.generateOffer(),
                candidates: (await session.rtc.gatherCandidates()).map { SignallingIceCandidate(candidate: $0) },
                clientId: nil
            )
            
            // Original schema is alloplace2://. We call this with HTTP(S) to establish a WebRTC connection, which means we need to rewrite the
            // schema to be http(s).
            guard var httpcomps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            guard let scheme = url.scheme else { throw URLError(.badURL) }
            httpcomps.scheme = scheme.last == "s" ? "https" : "http"
            guard let httpUrl = httpcomps.url else { throw URLError(.badURL) }
            
            let request = NSMutableURLRequest(url: httpUrl)
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
            print("All the RTC stuff should be done now")
        } catch (let e) {
            print("failed to connect: \(e)")
            DispatchQueue.main.async {
                self.lastError = e
                self.state = .idle
            }
        }
    }
    
    public func session(didConnect sess: AlloSession)
    {
        DispatchQueue.main.async {
            self.reconnectionAttempts = 0
            self.state = .connected
            
            print("Connected as \(sess.rtc.clientId!)")
        }
        sess.send(interaction: Interaction(
            type: .request,
            senderEntityId: "",
            receiverEntityId: "place",
            body: .announce(version: "2.0", avatarComponents: avatarDesc)
        ))
    }
    
    public func session(didDisconnect sess: AlloSession)
    {
        print("Disconnected")
        DispatchQueue.main.async {
            if(false)
            {
                // TODO: Propagate disconnection reason, and notice if it's permanent
                // state = .error ...
            }
            else if(self.connectionLoopCancellable != nil)
            {
                self.state = .waitingForReconnect
            }
            else
            {
                self.state = .idle
            }
        }
    }
    
    public func session(_: AlloSession, didReceiveInteraction inter: Interaction)
    {
        print("Received interaction: \(inter)")
    }
    
    public func session(_: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        print("Received place change for revision \(changeset.fromRevision) -> \(changeset.toRevision)")
        guard place.applyChangeSet(changeset) else
        {
            print("Failed to apply change set, asking for a full diff")
            currentIntent = Intent(ackStateRev: 0)
            return
        }
        currentIntent = Intent(ackStateRev: changeset.toRevision)
    }
    
    public func session(_: AlloSession, didReceiveIntent intent: Intent)
    {
        assert(false) // should never happen on client
    }
    
    func sendIntent()
    {
        session.send(currentIntent)
    }
}

public enum ConnectionState : Equatable
{
    case idle
    case waitingForReconnect
    
    case connecting
    case connected
}
