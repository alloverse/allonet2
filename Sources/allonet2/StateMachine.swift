//
//  StateMachine.swift
//  allonet2
//
//  Generic state machine wrapper with validated transitions and logging.
//

import Foundation
import OpenCombineShim
import Logging

/// Conform your state enum to this protocol to enable validated transitions.
public protocol StateMachineState: CustomStringConvertible {
    /// Return true if transitioning from `current` to `next` is a valid transition.
    static func canTransition(from current: Self, to next: Self) -> Bool
}

/// A wrapper that enforces valid state transitions, logs them, and publishes changes via Combine.
///
/// Invalid transitions crash immediately — they represent programmer errors (per fail-fast philosophy).
@MainActor
public final class StateMachine<State: StateMachineState>
{
    @Published public private(set) var current: State

    private let label: String
    private var logger: Logger

    public init(_ initial: State, label: String, logger: Logger = Logger(labelSuffix: "statemachine"))
    {
        self.current = initial
        self.label = label
        self.logger = logger
    }

    /// Transition to a new state. Crashes on invalid transitions (programmer error).
    /// Returns the previous state.
    @discardableResult
    public func transition(to next: State) -> State
    {
        let prev = current
        guard State.canTransition(from: prev, to: next) else {
            preconditionFailure("[\(label)] Invalid state transition: \(prev) → \(next)")
        }
        logger.info("[\(label)] \(prev) → \(next)")
        current = next
        return prev
    }

    /// Transition only if the current state satisfies the predicate.
    /// Returns true if the transition happened, false if the predicate didn't match.
    @discardableResult
    public func transitionIf(to next: State, where predicate: (State) -> Bool) -> Bool
    {
        guard predicate(current) else { return false }
        transition(to: next)
        return true
    }
}
