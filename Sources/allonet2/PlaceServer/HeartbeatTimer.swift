//
//  HeartbeatTimer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation

/// A timer manager that fires once every _keepaliveDelay_ whenever nothing has happened, but will fire after only a _coalesceDelay_ if a change has happened. This will coalesce a small number of changes that happen in succession; but still fire a heartbeat now and again to keep connections primed.
actor HeartbeatTimer
{
    private let syncAction: () async -> Void
    private let coalesceDelay: Int //ns
    private let keepaliveDelay: Int //ns

    private let timerQueue = DispatchQueue(label: "HeartbeatTimerQueue")
    private var timer: DispatchSourceTimer?
    private var pendingChanges = false
    
    // This stream must not buffer events; otherwise any awaitNextSync() will trigger immediately based on an outdated heartbeat,
    // not the latest one it's actually waiting for.
    private lazy var syncStream: AsyncStream<Void> = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(0)) { continuation in
        self.syncContinuation = continuation
    }
    private var syncContinuation: AsyncStream<Void>.Continuation?

    public init(coalesceDelay: Int = 20_000_000,
         keepaliveDelay: Int = 1_000_000_000,
         syncAction: @escaping () async -> Void)
    {
        self.syncAction = syncAction
        self.coalesceDelay = coalesceDelay
        self.keepaliveDelay = keepaliveDelay
        
        Task { await setupTimer(delay: keepaliveDelay) }
    }

    public func markChanged()
    {
        // Only schedule a new timer if not already pending.
        if pendingChanges { return }
        pendingChanges = true
        
        setupTimer(delay: coalesceDelay)
    }
    
    public func awaitNextSync() async
    {
        for await _ in syncStream { break }
    }
    
    public func stop()
    {
        timer?.cancel()
        timer = nil
    }
    
    private func setupTimer(delay: Int)
    {
        timer?.cancel()
        
        let newTimer = DispatchSource.makeTimerSource(queue: timerQueue)
        newTimer.setEventHandler { [weak self] in
            // Jump back into the actor's context.
            Task { await self?.timerFired() }
        }
        newTimer.schedule(deadline: .now() + .nanoseconds(delay))
        newTimer.activate()
        timer = newTimer
    }

    private func timerFired() async
    {
        await syncAction()
        pendingChanges = false
        setupTimer(delay: keepaliveDelay)
        syncContinuation?.yield(())
    }
}
