import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Deterministic lifecycle suite for the demand-scoped OpenCode discovery actor: FIFO job
/// serialization, per-key coalescing, waiter cancellation, ownership eviction, shutdown, and
/// the 30-second bounded-job adaptation (exercised here with a small deadline).
///
/// Orchestration is fully gated: a scripted client actor records arrivals, completions,
/// cancellations, and a strict event log, and holds calls until the test releases them.
/// Every wait is bounded and fails loudly on timeout; teardown releases gates and shuts the
/// service down so no test can leave a suspended waiter or a wedged job behind.
final class OpenCodeACPModelPollingLifecycleTests: XCTestCase {
    private var services: [OpenCodeACPModelPollingService] = []
    private var clients: [GatedDiscoveryClient] = []

    override func tearDown() async throws {
        for client in clients {
            await client.releaseStalledCall()
        }
        for service in services {
            await service.shutdown()
        }
        services.removeAll()
        clients.removeAll()
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
    }

    private func makeService(
        client: GatedDiscoveryClient,
        intervalNanos: UInt64 = 60_000_000_000,
        deadlineNanos: UInt64 = 5_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> OpenCodeACPModelPollingService {
        let service = OpenCodeACPModelPollingService(
            client: client,
            intervalNanos: intervalNanos,
            jobDeadlineNanos: deadlineNanos
        )
        services.append(service)
        clients.append(client)
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        return service
    }

    // MARK: - Waiter registration and cancellation

    /// A caller cancelled before its waiter registers must throw immediately, without
    /// launching a probe or retaining any job ownership.
    func testCancelledBeforeRegistrationDoesNotRetainWaiter() async {
        let client = GatedDiscoveryClient()
        let service = makeService(client: client)
        // The start gate guarantees the task body begins only after cancel() has returned,
        // so cancellation is observed strictly before any registration could happen.
        let startGate = StartGate()
        let waiter = Task { () -> OpenCodeACPModelParameterSnapshot in
            await startGate.wait()
            return try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        waiter.cancel()
        await startGate.open()

        let outcome = await awaitOutcome(waiter)
        XCTAssertEqual(outcome, .cancelled)
        let state = await client.stateSnapshot()
        XCTAssertEqual(state.arrivals, 0, "a cancelled-before-registration caller must not launch a probe")
    }

    /// Cancellation delivered while the waiter is registered against an in-flight job settles
    /// that caller exactly once; the shared job completes normally afterwards without touching
    /// the removed waiter again (a second resume would trap the process).
    func testCancellationAtRegistrationSettlesExactlyOnce() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let waiter = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }

        waiter.cancel()
        let outcome = await awaitOutcome(waiter)
        XCTAssertEqual(outcome, .cancelled)

        // The shared job is not the caller's: releasing it completes normally, and its late
        // outcome must not resume the already-settled waiter a second time.
        await client.release()
        let state = await client.waitFor { $0.completions == 1 }
        XCTAssertEqual(state.arrivals, 1)

        // Nothing was retained for the unowned key: a fresh one-shot starts a new probe
        // instead of receiving a stale outcome.
        let second = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 2 }
        await client.release()
        let secondOutcome = await awaitOutcome(second)
        guard case let .snapshot(snapshot) = secondOutcome, case .available = snapshot.state else {
            return XCTFail("Expected a fresh .available observation, got \(secondOutcome)")
        }
    }

    /// Cancelling one of two coalesced waiters throws only for that caller; the survivor still
    /// receives the terminal outcome of the single shared acquisition.
    func testCancelOneOfTwoCoalescedWaitersPreservesOther() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let waiterA = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        let waiterB = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }

        waiterA.cancel()
        let outcomeA = await awaitOutcome(waiterA)
        XCTAssertEqual(outcomeA, .cancelled)

        await client.release()
        let outcomeB = await awaitOutcome(waiterB)
        guard case let .snapshot(snapshot) = outcomeB, case .available = snapshot.state else {
            return XCTFail("Survivor must receive the terminal outcome, got \(outcomeB)")
        }
        let state = await client.waitFor { $0.completions == 1 }
        XCTAssertEqual(state.arrivals, 1, "cancelling one owner must not restart the shared job")
    }

    /// The last owner of a QUEUED key abandons it before the single slot reaches it: the job
    /// is pruned and no disposable client/controller is ever launched for that key.
    func testCancelLastQueuedOwnerPrunesJob() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        // Occupy the single slot with a gated job for another key.
        let blocker = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }

        // `subscribeModelParameters` returns only after the observation and its queued job are
        // registered, so the abandonment below is deterministic — the job is queued, not started.
        let stream = await service.subscribeModelParameters(workspacePath: "/ws", modelRaw: "m2")
        var state = await client.stateSnapshot()
        XCTAssertEqual(state.arrivals, 1, "the queued key must wait for the active slot")
        let consumer = Task { for await _ in stream {} }
        consumer.cancel()
        await yieldTimes(50) // let the termination-driven removal and prune land on the actor

        await client.release()
        _ = await awaitOutcome(blocker)
        state = await client.waitFor { $0.completions == 1 }
        XCTAssertEqual(state.arrivals, 1, "no client/controller launch for the abandoned queued key")
        XCTAssertFalse(state.calls.contains { $0.modelRaw == "m2" })
        consumer.cancel()
    }

    /// The last owner of an ACTIVE job cancels: the running job is allowed to finish (its
    /// client cleanup completes), its outcome is dropped rather than written into an unowned
    /// observation, and no observation is resurrected by that late completion.
    func testCancelLastActiveOwnerAllowsCleanupAndDropsOutcome() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let waiter = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }
        waiter.cancel()
        let outcome = await awaitOutcome(waiter)
        XCTAssertEqual(outcome, .cancelled)

        // Active cleanup completes even though nobody is waiting for the result.
        await client.release()
        let state = await client.waitFor { $0.completions == 1 }
        XCTAssertEqual(state.arrivals, 1)

        // The dropped outcome was not retained: a new owner gets a fresh probe, not the
        // evicted observation's result.
        let second = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 2 }
        await client.release()
        let secondOutcome = await awaitOutcome(second)
        guard case let .snapshot(snapshot) = secondOutcome, case .available = snapshot.state else {
            return XCTFail("Expected a fresh probe result, got \(secondOutcome)")
        }
    }

    /// A key recreated while its original job is still in flight joins that job instead of
    /// starting a duplicate probe — the demand-scoped coalescing policy.
    func testRecreatedSameKeyJoinsExistingActiveJob() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let first = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }
        first.cancel()
        _ = await awaitOutcome(first)

        // Recreate the same key while the original job is still active: it must join.
        let recreated = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        await yieldTimes(50) // registration lands while the original job is still in flight
        await client.release()

        let outcome = await awaitOutcome(recreated)
        guard case let .snapshot(snapshot) = outcome, case .available = snapshot.state else {
            return XCTFail("Recreated key must receive the in-flight job's outcome, got \(outcome)")
        }
        let state = await client.waitFor { $0.completions == 1 }
        XCTAssertEqual(state.arrivals, 1, "recreating the key must not start a duplicate probe")
    }

    // MARK: - Shutdown

    /// Shutdown settles every active and queued waiter exactly once; a late completion that
    /// ignores cancellation neither republishes the catalog nor resumes anyone again.
    func testShutdownSettlesActiveAndQueuedWaitersExactlyOnce() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        await client.setIgnoresCancellation(true) // model an RPC that completes after cancel
        let service = makeService(client: client)

        let active = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }
        let queued = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m2")
        }
        await yieldTimes(50) // let the queued waiter register

        await service.shutdown()
        let activeOutcome = await awaitOutcome(active)
        XCTAssertEqual(activeOutcome, .cancelled)
        let queuedOutcome = await awaitOutcome(queued)
        XCTAssertEqual(queuedOutcome, .cancelled)

        // The late success must not republish (a fresh registry stays empty) and must not
        // resume either settled waiter a second time (that would trap).
        await client.release()
        _ = await client.waitFor { $0.completions == 1 }
        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))
    }

    // MARK: - Shared failures and keying

    /// A client-side cancellation is the shared job's failure, not any surviving caller's:
    /// surviving owners settle by value with a terminal `.failed` observation.
    func testClientCancellationFailsSurvivingParameterOwnersByValue() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let waiterA = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        let waiterB = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }

        await client.setOutcome(.clientCancelled)
        await client.release()

        for outcome in await [awaitOutcome(waiterA), awaitOutcome(waiterB)] {
            guard case let .snapshot(snapshot) = outcome, case .failed = snapshot.state else {
                return XCTFail("Surviving owner must settle by value with .failed, got \(outcome)")
            }
        }
        let state = await client.stateSnapshot()
        XCTAssertEqual(state.arrivals, 1)
    }

    /// Different workspaces and different models are different keys: their jobs do not
    /// coalesce and each owner receives the result fabricated for its own key.
    func testDifferentWorkspaceOrModelDoesNotCoalesce() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let first = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws-a", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }
        let second = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws-a", modelRaw: "m2")
        }
        let third = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws-b", modelRaw: "m1")
        }
        await yieldTimes(50) // let both queued waiters register

        await client.release()
        let outcomes = await [awaitOutcome(first), awaitOutcome(second), awaitOutcome(third)]
        let baseModels = outcomes.map { outcome -> String in
            guard case let .snapshot(snapshot) = outcome,
                  case let .available(set) = snapshot.state
            else {
                XCTFail("Expected .available for every key, got \(outcome)")
                return "unexpected"
            }
            return set.baseModelRaw
        }
        XCTAssertEqual(baseModels, ["m1", "m2", "m1"], "each key receives its own result")

        let state = await client.waitFor { $0.completions == 3 }
        XCTAssertEqual(state.arrivals, 3, "distinct keys must not coalesce")
        XCTAssertEqual(
            Set(state.calls.map { "\($0.workspacePath ?? "nil")|\($0.modelRaw ?? "nil")" }),
            ["/ws-a|m1", "/ws-a|m2", "/ws-b|m1"]
        )
    }

    /// A forced one-shot refresh joins an identical in-flight job rather than launching a
    /// second probe: one disposable controller at a time is the invariant, not freshness.
    func testForcedRefreshJoinsIdenticalInFlightJob() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let plain = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }
        let forced = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1", forceRefresh: true)
        }
        await yieldTimes(50) // the forced waiter registers against the in-flight job

        await client.release()
        let forcedOutcome = await awaitOutcome(forced)
        guard case let .snapshot(snapshot) = forcedOutcome, case .available = snapshot.state else {
            return XCTFail("Forced refresh must receive the in-flight job's outcome, got \(forcedOutcome)")
        }
        _ = await awaitOutcome(plain)
        let state = await client.waitFor { $0.completions == 1 }
        XCTAssertEqual(state.arrivals, 1, "no duplicate forced probe while an identical job is in flight")
    }

    // MARK: - Serialization and periodic refresh

    /// The runner hands the single disposable-client slot to the next job only after the
    /// previous client call fully completed: at most one active call, ever, in call order.
    func testRunnerWaitsForClientCleanupBeforeNextJob() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.succeed)
        let service = makeService(client: client)

        let first = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        _ = await client.waitFor { $0.arrivals == 1 }
        let second = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m2")
        }
        await yieldTimes(50) // the second job queues behind the active one

        await client.release()
        let state = await client.waitFor { $0.completions == 2 }
        XCTAssertEqual(state.maxActive, 1, "maximum active disposable clients must be one")
        guard
            let completeFirst = state.events.firstIndex(of: "complete:m1"),
            let arriveSecond = state.events.firstIndex(of: "arrive:m2")
        else {
            return XCTFail("Expected ordered events, got \(state.events)")
        }
        XCTAssertLessThan(completeFirst, arriveSecond, "the next job starts only after the previous client completed")
        _ = await awaitOutcome(first)
        _ = await awaitOutcome(second)
    }

    /// Catalog ticks refresh only the catalog: an owned `.available` parameter observation is
    /// never replaced with `.loading` again while ticks run.
    func testPeriodicRefreshDoesNotReloadOwnedParameterControls() async {
        let client = GatedDiscoveryClient(automaticallyReleases: true)
        await client.setOutcome(.succeed)
        // A short interval drives several catalog ticks within the bounded wait below.
        let service = makeService(client: client, intervalNanos: 40_000_000)

        let catalogStream = await service.subscribe(workspacePath: "/ws")
        let catalogConsumer = Task {
            for await _ in catalogStream {}
        }
        let parameterStream = await service.subscribeModelParameters(workspacePath: "/ws", modelRaw: "m1")
        let collector = SnapshotCollector()
        let parameterConsumer = Task {
            for await snapshot in parameterStream {
                await collector.append(snapshot)
            }
        }

        // Wait for the probe to finish and at least two catalog ticks (initial + periodic)
        // to run; ticks must not re-probe parameters.
        _ = await client.waitFor { $0.catalogArrivals >= 3 }
        await yieldTimes(50)
        let values = await collector.values()
        XCTAssertEqual(
            values.map(\.state),
            [.loading, parameterStateForModel("m1")],
            "catalog ticks must not replace owned controls with .loading"
        )
        let state = await client.stateSnapshot()
        XCTAssertEqual(state.parameterArrivals, 1, "ticks must not re-probe owned parameter observations")

        catalogConsumer.cancel()
        parameterConsumer.cancel()
    }

    // MARK: - Bounded jobs (the 30 s adaptation, exercised with a 150 ms deadline)

    /// A stalled discovery job (a forced model RPC that never answers) times out at its
    /// deadline: owners settle `.failed` by value, the client call is cancelled and reaped
    /// (controller shutdown completes), the single slot is released, and the next queued job
    /// runs.
    func testStalledDiscoveryJobTimesOutAndReleasesSlot() async {
        let client = GatedDiscoveryClient()
        await client.setOutcome(.stall)
        let service = makeService(client: client, deadlineNanos: 150_000_000)

        let stalled = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m1")
        }
        let queued = Task {
            try await service.discoverModelParametersOnce(workspacePath: "/ws", modelRaw: "m2")
        }
        _ = await client.waitFor { $0.arrivals == 1 }
        await yieldTimes(50) // the queued waiter registers behind the stalled job

        let stalledOutcome = await awaitOutcome(stalled)
        guard case let .snapshot(snapshot) = stalledOutcome, case .failed = snapshot.state else {
            return XCTFail("A stalled job must settle its owners .failed by value, got \(stalledOutcome)")
        }

        let state = await client.waitFor { $0.arrivals == 2 }
        XCTAssertEqual(state.cleanups, 1, "the stalled client call must be cancelled and reaped")
        guard
            let arriveFirst = state.events.firstIndex(of: "arrive:m1"),
            let cleanupFirst = state.events.firstIndex(of: "cleanup:m1"),
            let arriveSecond = state.events.firstIndex(of: "arrive:m2")
        else {
            return XCTFail("Expected ordered deadline events, got \(state.events)")
        }
        XCTAssertLessThan(arriveFirst, cleanupFirst, "cleanup happens after the stall is detected")
        XCTAssertLessThan(cleanupFirst, arriveSecond, "the slot is released only after client cleanup")

        // The queued job proceeds normally once the slot is free.
        await client.setOutcome(.succeed)
        await client.release()
        let queuedOutcome = await awaitOutcome(queued)
        guard case let .snapshot(queuedSnapshot) = queuedOutcome, case .available = queuedSnapshot.state else {
            return XCTFail("The next queued job must run after the deadline, got \(queuedOutcome)")
        }
    }
}

// MARK: - Test doubles

/// The terminal outcome of a one-shot waiter, recorded by awaiting its task.
private enum WaiterOutcome: Equatable {
    case snapshot(OpenCodeACPModelParameterSnapshot)
    case cancelled
    case failed(String)
}

private func awaitOutcome(
    _ task: Task<OpenCodeACPModelParameterSnapshot, Error>
) async -> WaiterOutcome {
    do {
        return try await .snapshot(task.value)
    } catch is CancellationError {
        return .cancelled
    } catch {
        return .failed(error.localizedDescription)
    }
}

private actor SnapshotCollector {
    private var collected: [OpenCodeACPModelParameterSnapshot] = []

    func append(_ snapshot: OpenCodeACPModelParameterSnapshot) {
        collected.append(snapshot)
    }

    func values() -> [OpenCodeACPModelParameterSnapshot] {
        collected
    }
}

/// A start gate that guarantees a task body begins only after the test has signalled it.
private actor StartGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        opened = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private func yieldTimes(_ count: Int) async {
    for _ in 0 ..< count {
        await Task.yield()
    }
}

private func parameterStateForModel(_ modelRaw: String) -> OpenCodeACPModelParameterState {
    .available(
        ACPModelParameterSet(
            baseModelRaw: modelRaw,
            parameters: [
                .init(
                    kind: .thinking,
                    configID: "effort",
                    displayName: "Effort",
                    choices: [
                        .init(rawValue: "low", displayName: "Low"),
                        .init(rawValue: "high", displayName: "High")
                    ],
                    currentValueRaw: "low"
                )
            ]
        )
    )
}

/// A gated `OpenCodeACPModelDiscoveryClient` double: every call records its arrival and holds
/// until the test releases it (or until cancellation, which models the real client's
/// disposable-controller shutdown and is recorded as a cleanup event). A strict event log
/// gives the tests a total order over arrivals, completions, and cleanups.
///
/// All waits in this double and its barrier helpers are bounded: holds end on release or
/// cancellation, `waitFor` fails loudly at its deadline, and the 10 s hold cap keeps a
/// forgotten release from wedging a test forever.
private actor GatedDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    enum ScriptedOutcome {
        case succeed
        case clientCancelled
        case stall
    }

    struct State {
        var arrivals = 0
        var completions = 0
        var cleanups = 0
        var activeNow = 0
        var maxActive = 0
        var catalogArrivals = 0
        var parameterArrivals = 0
        var events: [String] = []
        var calls: [(workspacePath: String?, modelRaw: String?)] = []
    }

    private var state = State()
    private var outcome: ScriptedOutcome = .succeed
    private var released: Bool
    private var ignoresCancellation = false

    init(automaticallyReleases: Bool = false) {
        released = automaticallyReleases
    }

    func setOutcome(_ outcome: ScriptedOutcome) {
        self.outcome = outcome
    }

    func setIgnoresCancellation(_ ignores: Bool) {
        ignoresCancellation = ignores
    }

    /// Release every held call. `setOutcome(.succeed)` first to also un-stall held calls.
    func release() {
        released = true
    }

    /// Teardown helper: un-stall and release, without changing the scripted outcome.
    func releaseStalledCall() {
        if outcome == .stall {
            outcome = .succeed
        }
        released = true
    }

    func stateSnapshot() -> State {
        state
    }

    /// Bounded condition wait: polls observable state until the condition holds, failing
    /// loudly at the deadline instead of hanging the suite.
    func waitFor(
        _ condition: @Sendable (State) -> Bool,
        timeoutNanos: UInt64 = 2_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> State {
        let deadline = Date().addingTimeInterval(Double(timeoutNanos) / 1_000_000_000)
        while true {
            if condition(state) {
                return state
            }
            if Date() > deadline {
                XCTFail("Timed out waiting for gated client condition", file: file, line: line)
                return state
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func discoverModels(
        workspacePath: String?,
        modelRaw: String?
    ) async throws -> OpenCodeACPModelDiscoveryResult? {
        let label = modelRaw ?? "catalog"
        state.arrivals += 1
        state.activeNow += 1
        state.maxActive = max(state.maxActive, state.activeNow)
        state.events.append("arrive:\(label)")
        state.calls.append((workspacePath: workspacePath, modelRaw: modelRaw))
        if modelRaw == nil {
            state.catalogArrivals += 1
        } else {
            state.parameterArrivals += 1
        }

        // Hold the call until released (or the 10 s cap). Cancellation models the real
        // client's controller shutdown: recorded as a cleanup event, then rethrows so the
        // bounded job can reap this call before releasing the slot.
        let holdDeadline = Date().addingTimeInterval(10)
        while !(released && outcome != .stall) {
            if !ignoresCancellation, Task.isCancelled {
                state.events.append("cleanup:\(label)")
                state.cleanups += 1
                state.activeNow -= 1
                throw CancellationError()
            }
            if Date() > holdDeadline {
                state.events.append("cleanup:\(label)")
                state.cleanups += 1
                state.activeNow -= 1
                throw NSError(
                    domain: "GatedDiscoveryClient",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "gated hold exceeded its cap"]
                )
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        state.activeNow -= 1
        switch outcome {
        case .succeed:
            state.events.append("complete:\(label)")
            state.completions += 1
            if let modelRaw {
                return OpenCodeACPModelDiscoveryResult(
                    catalog: catalog(for: modelRaw),
                    parameterState: parameterStateForModel(modelRaw)
                )
            }
            return OpenCodeACPModelDiscoveryResult(
                catalog: catalog(for: "ollama-cloud/kimi-k3"),
                parameterState: nil
            )
        case .clientCancelled:
            state.events.append("client-cancel:\(label)")
            throw CancellationError()
        case .stall:
            state.events.append("cleanup:\(label)")
            state.cleanups += 1
            throw NSError(
                domain: "GatedDiscoveryClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "stall outcome released without a script change"]
            )
        }
    }

    private func catalog(for currentModel: String) -> ACPDiscoveredSessionModels {
        ACPDiscoveredSessionModels(
            options: [
                .init(
                    rawValue: currentModel,
                    displayName: currentModel,
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )
            ],
            currentModelRaw: currentModel,
            modelParameterSets: []
        )
    }
}
