import Testing
import Foundation
@testable import allonet2

struct HeartbeatTimerTests
{
    /// A change marked while syncAction is still running used to hit the pendingChanges early
    /// return and never schedule a beat, so whatever queued it was never broadcast.
    @Test func schedulesASyncForChangesMarkedDuringASync() async throws
    {
        let syncs = Syncs()
        let timer = HeartbeatTimer(coalesceDelay: 5_000_000, keepaliveDelay: 10_000_000_000)
        {
            await syncs.record()
        }
        // init schedules its keepalive from a Task; marking before that lands would get our
        // coalesce timer cancelled by it.
        try await Task.sleep(for: .milliseconds(50))

        await timer.markChanged()
        try await syncs.waitForCount(1, within: .seconds(2))

        // Mark from inside the first sync: the second one is what regressed.
        await syncs.markDuringNextSync(timer)
        await timer.markChanged()
        try await syncs.waitForCount(3, within: .seconds(2))

        await timer.stop()
    }
}

/// Counts syncAction invocations, and can re-enter markChanged from inside one.
private actor Syncs
{
    private var count = 0
    private var markNext: HeartbeatTimer?

    func record() async
    {
        count += 1
        if let timer = markNext
        {
            markNext = nil
            await timer.markChanged()
        }
    }

    func markDuringNextSync(_ timer: HeartbeatTimer) { markNext = timer }

    func waitForCount(_ target: Int, within duration: Duration) async throws
    {
        let deadline = ContinuousClock.now + duration
        while count < target
        {
            guard ContinuousClock.now < deadline else
            {
                Issue.record("Timed out waiting for \(target) syncs; got \(count)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
