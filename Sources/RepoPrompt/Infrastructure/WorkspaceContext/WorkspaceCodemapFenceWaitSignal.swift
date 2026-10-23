import Foundation

/// One waiter on a codemap fence. The store wakes it when the fence lifts; the waiting task's
/// cancellation and its deadline resolve it directly, without first running on the store actor,
/// so a long store job cannot delay them. The first resolution wins. The waiter removes its own
/// registration by ID once it is back on the store actor.
final class WorkspaceCodemapFenceWaitSignal: @unchecked Sendable {
    enum Outcome: Equatable {
        case woken
        case cancelled
        case timedOut
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var outcome: Outcome?

    func resolve(_ outcome: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>? = lock.withLock {
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: outcome)
    }

    /// Waits until the signal resolves or `deadline` passes. Call once per signal.
    func wait(until deadline: ContinuousClock.Instant?) async -> Outcome {
        let timeoutTask: Task<Void, Never>? = deadline.map { deadline in
            Task { [weak self] in
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self?.resolve(.timedOut)
            }
        }
        defer { timeoutTask?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resolved: Outcome? = lock.withLock {
                    if let outcome { return outcome }
                    self.continuation = continuation
                    return nil
                }
                if let resolved {
                    continuation.resume(returning: resolved)
                }
            }
        } onCancel: {
            resolve(.cancelled)
        }
    }
}
