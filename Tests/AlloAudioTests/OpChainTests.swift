import Testing
import Logging
@testable import AlloAudio

@Suite @MainActor struct OpChainTests
{
    private let ops = OpChain(label: "test", logger: Logger(label: "test"))

    /// The chain is what keeps device opens, graph mutations and teardowns from interleaving:
    /// ops run strictly in submission order, even when an earlier one suspends for longer
    /// than a later one takes.
    @Test func opsRunInSubmissionOrderAcrossSuspensions() async throws
    {
        var order: [Int] = []
        ops.run { try await Task.sleep(nanoseconds: 50_000_000); order.append(1) }
        ops.run { order.append(2) }
        let last = ops.run { order.append(3) }
        _ = try await last.value
        #expect(order == [1, 2, 3])
    }

    /// A launched op has nobody left to throw to; its failure must reach the host's hook
    /// rather than vanish into a log line.
    @Test func aLaunchedFailureReachesTheHook() async throws
    {
        struct Boom: Error {}
        var reported: (label: String, error: Error)?
        ops.onFailure = { reported = (label: $0, error: $1) }

        ops.launch("doomed") { throw Boom() }
        // The reporting task runs just after the op itself; yield until it lands.
        for _ in 0..<1000 where reported == nil { await Task.yield() }

        #expect(reported?.label == "doomed")
        #expect(reported?.error is Boom)
    }

    /// One failed op must not dam the chain: everything behind it still runs.
    @Test func aFailureDoesNotStopTheChain() async throws
    {
        struct Boom: Error {}
        ops.launch("doomed") { throw Boom() }
        let after = ops.run { true }
        #expect(try await after.value)
    }
}
