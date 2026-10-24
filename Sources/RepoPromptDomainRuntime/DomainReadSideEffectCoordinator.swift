import Foundation

package enum DomainReadSideEffectError: Error, Equatable, Sendable {
    case runtimeMismatch
    case operationCollision
    case receiptUnavailable
    case stopped
}

/// Independent ordering domains for read-derived effects. Selection publication must not be
/// head-of-line blocked by Git artifact work (or vice versa), while effects in one class and
/// context retain strict revision order.
package enum DomainReadSideEffectClass: String, Hashable, Sendable {
    case selection
    case gitArtifacts
}

package struct DomainReadSideEffectReceipt: Equatable, Sendable {
    package let operationID: UUID
    package let context: DomainContextIdentity
    package let effectClass: DomainReadSideEffectClass
    package let revision: UInt64

    package init(
        operationID: UUID,
        context: DomainContextIdentity,
        effectClass: DomainReadSideEffectClass,
        revision: UInt64
    ) {
        self.operationID = operationID
        self.context = context
        self.effectClass = effectClass
        self.revision = revision
    }
}

/// Context- and effect-class-keyed revision authority for read-derived effects.
///
/// Accepted operations are strictly ordered within a lane. A terminal failure is observable by
/// the submitting caller but is not inherited by later operations or future high-water drains.
///
/// An operation whose read was revoked and stopped waiting is retired: it counts as terminal, so later
/// operations and drains stop waiting for it, but its task keeps running and stays tracked until it ends.
/// The revoked read's fence keeps a retired effect from publishing, so running it out of order is safe.
package actor DomainReadSideEffectCoordinator {
    private struct LaneKey: Hashable, Sendable {
        let context: DomainContextIdentity
        let effectClass: DomainReadSideEffectClass
    }

    private struct RecordedOperation: Sendable {
        let fingerprint: String
        let receipt: DomainReadSideEffectReceipt
    }

    private struct TerminalWaiter: Sendable {
        let target: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct LaneState: Sendable {
        var acceptedRevision: UInt64 = 0
        /// Every revision at or below this one is terminal: its task ended or it was retired.
        var terminalRevision: UInt64 = 0
        /// Terminal revisions above `terminalRevision`, which wait for an earlier revision to become terminal.
        var terminalRevisionsAboveContiguous: Set<UInt64> = []
        var tasks: [UInt64: Task<Void, Error>] = [:]
        /// Revisions whose task hasn't ended, retired ones included.
        var runningRevisions: Set<UInt64> = []
        var retiredRevisions: Set<UInt64> = []
        var fences: [UInt64: MCPDomainInvocationFence] = [:]
        /// The finish of each revision whose operation hasn't started. Retiring such a revision runs its
        /// finish at once: its task may wait on an earlier operation that never ends, and nothing will run
        /// under the finish's claim.
        var unstartedFinishes: [UInt64: FinishOnce] = [:]
        var operations: [UUID: RecordedOperation] = [:]
        var expiredOperationIDs: [UUID] = []
        var terminalWaiters: [UUID: TerminalWaiter] = [:]
    }

    private let identity: DomainRuntimeIdentity
    private var states: [LaneKey: LaneState] = [:]
    private var stopped = false

    package init(identity: DomainRuntimeIdentity) {
        self.identity = identity
    }

    package func highWaterRevision(
        for handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass
    ) throws -> UInt64 {
        try validate(handle)
        return states[LaneKey(context: handle.context, effectClass: effectClass)]?.acceptedRevision ?? 0
    }

    /// `fence` belongs to the read that submits the operation; once it's revoked, the read's cancelled
    /// wait retires the operation. `onFinished` runs once: when the operation's task ends, before any
    /// waiter sees the result; at retirement, when the operation hasn't started; or right away when this
    /// call doesn't start a task.
    package func submit(
        handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass,
        operationID: UUID,
        fingerprint: String,
        fence: MCPDomainInvocationFence? = nil,
        onFinished: (@Sendable () -> Void)? = nil,
        operation: @Sendable @escaping () async throws -> Void
    ) throws -> DomainReadSideEffectReceipt {
        let finish = FinishOnce(onFinished)
        var startedTask = false
        defer {
            if !startedTask { finish.run() }
        }
        try validate(handle)
        guard !stopped else { throw DomainReadSideEffectError.stopped }
        let key = LaneKey(context: handle.context, effectClass: effectClass)
        var state = states[key] ?? LaneState()
        if let recorded = state.operations[operationID] {
            guard recorded.fingerprint == fingerprint else {
                throw DomainReadSideEffectError.operationCollision
            }
            return recorded.receipt
        }
        guard !state.expiredOperationIDs.contains(operationID) else {
            throw DomainReadSideEffectError.receiptUnavailable
        }

        let revision = state.acceptedRevision &+ 1
        let task = Task { [weak self] in
            defer { finish.run() }
            // Waiting for terminal revisions, not results: a previous terminal error belongs to its
            // submitter and must never poison this lane.
            await self?.awaitTerminal(key: key, through: revision - 1)
            try Task.checkCancellation()
            guard await self?.beginOperation(key: key, revision: revision) == true else { return }
            try await operation()
        }
        let receipt = DomainReadSideEffectReceipt(
            operationID: operationID,
            context: handle.context,
            effectClass: effectClass,
            revision: revision
        )
        state.acceptedRevision = revision
        state.tasks[revision] = task
        state.runningRevisions.insert(revision)
        state.fences[revision] = fence
        state.unstartedFinishes[revision] = finish
        state.operations[operationID] = RecordedOperation(
            fingerprint: fingerprint,
            receipt: receipt
        )
        states[key] = state
        startedTask = true

        Task { [weak self] in
            _ = await task.result
            await self?.taskEnded(key: key, revision: revision)
        }
        return receipt
    }

    /// Waits for the exact submitted operation and preserves its success/failure/cancellation.
    /// Cancellation of the waiter does not cancel the coordinator-owned shared effect. When the
    /// operation's read has been revoked, the cancelled wait retires the operation.
    package func wait(
        handle: DomainReadContextHandle,
        receipt: DomainReadSideEffectReceipt
    ) async throws {
        try validate(handle)
        let key = LaneKey(context: handle.context, effectClass: receipt.effectClass)
        guard receipt.context == handle.context,
              let state = states[key],
              state.operations[receipt.operationID]?.receipt == receipt,
              let task = state.tasks[receipt.revision]
        else { throw DomainReadSideEffectError.receiptUnavailable }
        do {
            try await awaitCompletion(of: task, cancelUnderlyingOnCancellation: false)
        } catch where Task.isCancelled {
            retireIfRevoked(key: key, revision: receipt.revision)
            throw error
        }
    }

    /// Waits until the lane has reached a revision. Historical effect failures are terminal and
    /// intentionally do not fail an unrelated later read; cancellation of this request still does.
    package func drain(
        handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass,
        through revision: UInt64
    ) async throws {
        try validate(handle)
        try Task.checkCancellation()
        guard revision > 0 else { return }
        let key = LaneKey(context: handle.context, effectClass: effectClass)
        guard let state = states[key] else { return }
        if state.terminalRevision >= revision { return }
        guard revision <= state.acceptedRevision else {
            throw DomainReadSideEffectError.receiptUnavailable
        }
        // A drain observes ordering, not the earlier submitters' failures, which belong only to them.
        // It must still be promptly cancellable without canceling shared work owned by another request.
        await awaitTerminal(key: key, through: revision)
        try Task.checkCancellation()
    }

    #if DEBUG
        /// The revisions that a lane's parked operations and drains wait to see become terminal, so a test
        /// can tell a waiter that is parked from one that hasn't run yet.
        package func debugTerminalWaitTargets(
            handle: DomainReadContextHandle,
            effectClass: DomainReadSideEffectClass
        ) -> [UInt64] {
            let key = LaneKey(context: handle.context, effectClass: effectClass)
            return states[key]?.terminalWaiters.values.map(\.target).sorted() ?? []
        }
    #endif

    package func shutdown() {
        stopped = true
        for state in states.values {
            for task in state.tasks.values { task.cancel() }
        }
    }

    private func awaitCompletion(
        of task: Task<Void, Error>,
        cancelUnderlyingOnCancellation: Bool
    ) async throws {
        let stream = AsyncThrowingStream<Void, Error> { continuation in
            let observer = Task {
                switch await task.result {
                case .success:
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                observer.cancel()
                if cancelUnderlyingOnCancellation,
                   case .cancelled = termination
                {
                    task.cancel()
                }
            }
        }
        for try await _ in stream {}
        try Task.checkCancellation()
    }

    private func validate(_ handle: DomainReadContextHandle) throws {
        guard handle.runtimeID == identity.runtimeID,
              handle.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw DomainReadSideEffectError.runtimeMismatch
        }
    }

    /// Returns once every revision through `target` is terminal, or when the calling task is cancelled.
    private func awaitTerminal(key: LaneKey, through target: UInt64) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      let terminalRevision = states[key]?.terminalRevision,
                      terminalRevision < target
                else {
                    continuation.resume()
                    return
                }
                states[key]?.terminalWaiters[waiterID] = TerminalWaiter(target: target, continuation: continuation)
            }
        } onCancel: {
            Task { await self.resumeTerminalWaiter(key: key, waiterID: waiterID) }
        }
    }

    private func resumeTerminalWaiter(key: LaneKey, waiterID: UUID) {
        states[key]?.terminalWaiters.removeValue(forKey: waiterID)?.continuation.resume()
    }

    /// Starts a revision's operation unless it was retired first. Retirement also runs on the actor, so a
    /// revision's finish runs at its retirement exactly when its operation never starts.
    private func beginOperation(key: LaneKey, revision: UInt64) -> Bool {
        guard states[key]?.retiredRevisions.contains(revision) == false else { return false }
        states[key]?.unstartedFinishes.removeValue(forKey: revision)
        return true
    }

    private func retireIfRevoked(key: LaneKey, revision: UInt64) {
        guard var state = states[key],
              state.fences[revision]?.isRevoked == true,
              state.runningRevisions.contains(revision),
              !state.retiredRevisions.contains(revision)
        else { return }
        state.retiredRevisions.insert(revision)
        let unstartedFinish = state.unstartedFinishes.removeValue(forKey: revision)
        states[key] = state
        markTerminal(key: key, revision: revision)
        unstartedFinish?.run()
    }

    private func taskEnded(key: LaneKey, revision: UInt64) {
        guard var state = states[key] else { return }
        state.runningRevisions.remove(revision)
        state.unstartedFinishes.removeValue(forKey: revision)
        let wasRetired = state.retiredRevisions.remove(revision) != nil
        states[key] = state
        if wasRetired {
            pruneExpiredRevisions(key: key)
        } else {
            markTerminal(key: key, revision: revision)
        }
    }

    /// Revisions become terminal out of order once one is retired, so the terminal revision advances only
    /// over a contiguous run. A drain or a later operation never passes an earlier revision still running.
    private func markTerminal(key: LaneKey, revision: UInt64) {
        guard var state = states[key], revision > state.terminalRevision else { return }
        state.terminalRevisionsAboveContiguous.insert(revision)
        while state.terminalRevisionsAboveContiguous.remove(state.terminalRevision &+ 1) != nil {
            state.terminalRevision &+= 1
        }
        let terminalRevision = state.terminalRevision
        let resumed = state.terminalWaiters.filter { $0.value.target <= terminalRevision }
        for waiterID in resumed.keys {
            state.terminalWaiters.removeValue(forKey: waiterID)
        }
        states[key] = state
        pruneExpiredRevisions(key: key)
        for waiter in resumed.values {
            waiter.continuation.resume()
        }
    }

    /// Forgets receipts more than 32 revisions behind the terminal revision. A retired operation's task
    /// is kept while it runs, so shutdown still cancels it.
    private func pruneExpiredRevisions(key: LaneKey) {
        guard var state = states[key], state.terminalRevision > 32 else { return }
        let floor = state.terminalRevision - 32
        let running = state.runningRevisions
        state.tasks = state.tasks.filter { $0.key >= floor || running.contains($0.key) }
        state.fences = state.fences.filter { $0.key >= floor || running.contains($0.key) }
        let expired = state.operations.filter { $0.value.receipt.revision < floor }.map(\.key)
        state.operations = state.operations.filter { $0.value.receipt.revision >= floor }
        state.expiredOperationIDs.append(contentsOf: expired)
        if state.expiredOperationIDs.count > 32 {
            state.expiredOperationIDs.removeFirst(state.expiredOperationIDs.count - 32)
        }
        states[key] = state
    }
}

/// An operation's finish callback, run at most once by whichever of its task's end or its retirement
/// comes first. The task runs it synchronously, so it has run before any waiter sees the task's result.
private final class FinishOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: (@Sendable () -> Void)?) {
        self.action = action
    }

    func run() {
        let action = lock.withLock {
            defer { self.action = nil }
            return self.action
        }
        action?()
    }
}
