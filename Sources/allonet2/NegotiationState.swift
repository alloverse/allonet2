//
//  NegotiationState.swift
//  allonet2
//
//  Explicit state machine for WebRTC offer/answer negotiation.
//

import Foundation

/// Whether we initiated the negotiation (offering) or are responding (answering).
public enum NegotiationRole: CustomStringConvertible
{
    case offering
    case answering

    public var description: String
    {
        switch self {
        case .offering: return "offering"
        case .answering: return "answering"
        }
    }
}

/// Tracks the current state of SDP negotiation within an AlloSession.
///
/// Replaces the old `hasOutstandingNegotiationOffer` and `needsRenegotiationWhenStable` booleans
/// with a single source of truth.
public enum NegotiationState: StateMachineState
{
    /// No negotiation in progress. Ready for a new offer or answer.
    case stable
    /// Actively negotiating. If `deferredRenegotiation` is true, another round is needed after this one completes.
    case negotiating(role: NegotiationRole, deferredRenegotiation: Bool)

    public var description: String
    {
        switch self {
        case .stable:
            return "stable"
        case .negotiating(let role, let deferred):
            return "negotiating(\(role)\(deferred ? ", deferred" : ""))"
        }
    }

    public static func canTransition(from current: NegotiationState, to next: NegotiationState) -> Bool
    {
        switch (current, next) {
        case (.stable, .negotiating):
            return true
        case (.negotiating, .stable):
            return true
        // Update within negotiating: flag deferred, or polite rollback (offering→answering)
        case (.negotiating, .negotiating):
            return true
        default:
            return false
        }
    }

    // MARK: - Convenience accessors

    public var isNegotiating: Bool
    {
        if case .negotiating = self { return true }
        return false
    }

    public var hasDeferredRenegotiation: Bool
    {
        if case .negotiating(_, deferredRenegotiation: true) = self { return true }
        return false
    }

    public var role: NegotiationRole?
    {
        if case .negotiating(let role, _) = self { return role }
        return nil
    }
}
