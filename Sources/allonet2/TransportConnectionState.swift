//
//  TransportConnectionState.swift
//  allonet2
//
//  Explicit state machine for WebRTC transport connection lifecycle.
//

import Foundation

/// Tracks the lifecycle of a WebRTC transport connection.
///
/// Replaces `didFullyConnect` boolean and implicit state tracking in both
/// UIWebRTCTransport and HeadlessWebRTCTransport.
public enum TransportConnectionState: StateMachineState
{
    /// Transport created but no offer/answer generated yet.
    case idle
    /// SDP generated, waiting for ICE connection + all data channels to open.
    case connecting
    /// ICE connected and all data channels open. Transport is fully usable.
    case connected
    /// Peer connection closed (intentionally or due to failure). Terminal state per transport instance.
    case disconnected

    public var description: String
    {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        }
    }

    public static func canTransition(from current: TransportConnectionState, to next: TransportConnectionState) -> Bool
    {
        switch (current, next) {
        case (.idle, .connecting):
            return true
        case (.connecting, .connected):
            return true
        case (.connected, .connecting):
            return true // renegotiation: new offer while already connected
        case (.idle, .disconnected),
             (.connecting, .disconnected),
             (.connected, .disconnected):
            return true
        default:
            return false
        }
    }
}
