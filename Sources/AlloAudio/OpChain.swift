//
//  OpChain.swift
//  allonet2
//

import Foundation
import Logging

/// A FIFO of exclusive async operations on the main actor, for a resource whose mutations
/// must never interleave but whose blocking calls must not run on the main thread - an
/// `AVAudioEngine` and its seconds-long HAL opens, say. Ops run strictly in submission
/// order, each to completion even across its suspension points, and `offMain` is where an
/// op puts the calls that would stall the main thread.
///
/// ```swift
/// let ops = OpChain(label: "AlloAudio.VoiceEngine", logger: logger)
/// try await ops.run { try await ops.offMain { try engine.start() } }.value
/// ops.launch("teardown") { await ops.offMain { engine.stop() } }
/// ```
@MainActor
final class OpChain
{
    /// Called on the main actor when a `launch`ed op fails - a failure nobody was left to
    /// catch. Logged regardless; the host sets this to tell the user, because a silently
    /// broken resource is indistinguishable from a working one. The string names the op.
    var onFailure: ((String, Error) -> Void)?

    private var lastOp: Task<Void, Never>?
    private let logger: Logging.Logger
    private nonisolated let queue: DispatchQueue

    init(label: String, logger: Logging.Logger)
    {
        self.logger = logger
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Run `op` after every previously submitted op has finished, exclusively. Submission
    /// is synchronous: two calls in the same main-actor stretch run in call order.
    @discardableResult
    func run<T>(_ op: @escaping @MainActor () async throws -> T) -> Task<T, Error>
    {
        let previous = lastOp
        let task = Task { @MainActor in
            await previous?.value
            return try await op()
        }
        lastOp = Task { _ = try? await task.value }
        return task
    }

    /// `run`, for sync entry points with nobody left to throw to: a failure is logged and
    /// handed to `onFailure`.
    func launch(_ label: String, _ op: @escaping @MainActor () async throws -> Void)
    {
        let task = run(op)
        Task { [logger] in
            do { try await task.value }
            catch
            {
                logger.error("\(label): \(error)")
                self.onFailure?(label, error)
            }
        }
    }

    /// Run `work` off the main thread, from inside an op only - the chain is what keeps two
    /// of these from touching the shared resource at once.
    nonisolated func offMain<T>(_ work: @escaping () throws -> T) async throws -> T
    {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    nonisolated func offMain<T>(_ work: @escaping () -> T) async -> T
    {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
