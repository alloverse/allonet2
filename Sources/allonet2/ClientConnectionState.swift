//
//  ClientConnectionState.swift
//  allonet2
//
//  Explicit state machine for AlloClient's reconnection lifecycle.
//

import Foundation

/// Tracks the lifecycle of an AlloClient connection, including reconnection with backoff.
///
/// Replaces the old `connectTask`, `reconnectionAttempts`, `connectionLoopCancellable`,
/// and drives `ConnectionStatus` as a derived view rather than source of truth.
public enum ClientConnectionState: StateMachineState
{
    /// Not connected and not trying to connect.
    case disconnected
    /// Waiting before retrying. `attempt` is 0-based (0 = first try, no delay).
    case waitingToRetry(attempt: Int)
    /// Actively performing HTTP signalling and WebRTC handshake.
    case connecting(attempt: Int)
    /// Fully connected and announced (have an avatar in the place).
    case announced(avatarId: EntityID, placeName: String)
    /// Connection attempt failed. May auto-retry if not permanent.
    case failed(error: Error)

    public var description: String
    {
        switch self {
        case .disconnected:
            return "disconnected"
        case .waitingToRetry(let attempt):
            return "waitingToRetry(attempt: \(attempt))"
        case .connecting(let attempt):
            return "connecting(attempt: \(attempt))"
        case .announced(let avatarId, _):
            return "announced(\(avatarId))"
        case .failed(let error):
            return "failed(\(error.localizedDescription))"
        }
    }

    public static func canTransition(from current: ClientConnectionState, to next: ClientConnectionState) -> Bool
    {
        switch (current, next) {
        // Start connecting
        case (.disconnected, .waitingToRetry):
            return true
        // Backoff elapsed, start connecting
        case (.waitingToRetry, .connecting):
            return true
        // Connection + announce succeeded
        case (.connecting, .announced):
            return true
        // Connection attempt failed
        case (.connecting, .failed):
            return true
        // Transport dropped during connection attempt (ICE failure)
        case (.connecting, .waitingToRetry):
            return true
        // Auto-retry after failure
        case (.failed, .waitingToRetry):
            return true
        // Transport dropped while connected
        case (.announced, .waitingToRetry):
            return true
        // User disconnects from any active state
        case (.announced, .disconnected),
             (.connecting, .disconnected),
             (.waitingToRetry, .disconnected),
             (.failed, .disconnected):
            return true
        default:
            return false
        }
    }

    // MARK: - Convenience accessors

    public var avatarId: EntityID?
    {
        if case .announced(let id, _) = self { return id }
        return nil
    }

    public var placeName: String?
    {
        if case .announced(_, let name) = self { return name }
        return nil
    }

    public var attempt: Int
    {
        switch self {
        case .waitingToRetry(let a): return a
        case .connecting(let a): return a
        default: return 0
        }
    }

    public var isStayingConnected: Bool
    {
        switch self {
        case .disconnected: return false
        default: return true
        }
    }
}
