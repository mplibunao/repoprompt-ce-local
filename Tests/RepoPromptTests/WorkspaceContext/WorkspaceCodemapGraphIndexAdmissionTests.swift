import Foundation
@testable import RepoPromptApp
import XCTest

/// Real-engine lifecycle coverage for graph-index admission ownership. Each scenario drives the
/// production scheduler, worker restart, revocation, and shutdown paths; DEBUG seams only park
/// asynchronous deliveries so an interleaving can be established deterministically.
final class WorkspaceCodemapGraphIndexAdmissionTests: XCTestCase {
    func testDelayedCancellationFromRestartedWorkerDoesNotSettleReplacementWait() async throws {
        let harness = try await AdmissionHarness.make(name: #function)
        addTeardownBlock { await harness.tearDown() }
        let engine = harness.engine
        let rootEpoch = harness.rootEpoch

        try await harness.queueFreshWorkerUnderHold()
        let eventBaseline = await harness.eventOrdinalBaseline()

        // A queued worker in `.suspendedBusy` takes the prioritize-restart path, which settles the
        // worker's wait and cancels its task while it is still inside the cancellation handler.
        let delivery = await harness.armDeliveryGate()
        await engine.debugSetGraphIndexRetryForTesting(rootEpoch: rootEpoch, attempt: 1)
        let disposition = await engine.prioritizeGraphIndexNow(rootEpoch: rootEpoch)
        XCTAssertEqual(disposition, .restarted)

        try await harness.waitForParkedDelivery(since: delivery, "worker A's cancellation delivery")
        try await harness.waitUntil("replacement worker B is queued") {
            let recovery = await engine.debugGraphIndexWorkerRecoveryStateForTesting(rootEpoch: rootEpoch)
            let accounting = await engine.accounting()
            let root = accounting.graphIndexRoots.first { $0.rootEpoch == rootEpoch }
            return recovery?.count == 1 &&
                recovery?.workerPresent == true &&
                accounting.queuedGraphIndexBatchCount == 1 &&
                root?.isQueuedForAdmission == true
        }

        try await harness.releaseDeliveryGate(since: delivery, "worker A's delayed cancellation")

        let afterDelivery = await engine.accounting()
        let queuedRoot = try XCTUnwrap(afterDelivery.graphIndexRoots.first { $0.rootEpoch == rootEpoch })
        XCTAssertEqual(
            afterDelivery.queuedGraphIndexBatchCount,
            1,
            "Worker A's delayed cancellation must not remove worker B's queued wait"
        )
        XCTAssertTrue(queuedRoot.isQueuedForAdmission)
        let recoveryAfterDelivery = await engine.debugGraphIndexWorkerRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        XCTAssertEqual(
            recoveryAfterDelivery?.count,
            1,
            "Only the requested restart may consume worker recovery budget"
        )

        await harness.releaseHold()
        _ = try await harness.waitForPhase(.complete)
        let events = await harness.events(since: eventBaseline)
        XCTAssertFalse(
            events.contains { $0.reason == .workerAdmissionUnavailable },
            "Worker B must not finish with a cancellation-induced admission failure"
        )
    }

    func testRootEpochSupersededWhileQueuedSettlesOldWaitOnceAndReplacementCompletes() async throws {
        let harness = try await AdmissionHarness.make(name: #function)
        addTeardownBlock { await harness.tearDown() }
        let engine = harness.engine
        let oldEpoch = harness.rootEpoch

        try await harness.queueFreshWorkerUnderHold()
        let queued = try await harness.ownership(oldEpoch)
        let oldToken = try XCTUnwrap(queued.queuedAdmissionToken)

        // Root unload and reload is the worktree-churn path: the store revokes the old epoch and
        // registers a new one for the same checkout.
        let newEpoch = try await harness.reloadRoot()
        XCTAssertNotEqual(newEpoch, oldEpoch)
        let replacement = try await harness.waitForPhase(.complete, rootEpoch: newEpoch)
        XCTAssertEqual(replacement.progress.counts.processedCandidateCount, 2)

        let oldSettlements = await harness.settlements(forJob: oldToken.jobID)
        XCTAssertEqual(oldSettlements, [.init(token: oldToken, reason: .jobCancelled)])
        let accounting = await engine.accounting()
        XCTAssertFalse(accounting.graphIndexRoots.contains { $0.rootEpoch == oldEpoch })
        XCTAssertEqual(accounting.queuedGraphIndexBatchCount, 0)
        XCTAssertEqual(accounting.activeGraphIndexBatchCount, 0)
        XCTAssertEqual(accounting.drainingGraphIndexTaskCount, 0)
        let oldGraph = await engine.selectionGraph(rootEpoch: oldEpoch)
        XCTAssertNil(oldGraph, "No old-epoch publication surface survives revocation")
        let events = await engine.debugGraphIndexEvents(rootID: oldEpoch.rootID, sinceOrdinal: nil, limit: 512)
        XCTAssertFalse(
            events.events.contains { $0.jobID == oldToken.jobID && $0.kind == .graphIndexPageAccepted },
            "The revoked queued worker never reads or publishes a page"
        )
    }

    func testRevocationAfterAdmissionDrainsAdmittedWorkerWithoutReleasingSuccessor() async throws {
        let harness = try await AdmissionHarness.make(name: #function)
        addTeardownBlock { await harness.tearDown() }
        let engine = harness.engine
        let rootEpoch = harness.rootEpoch

        try await harness.queueFreshWorkerUnderHold()
        await harness.catalogGate.arm(1)
        await harness.releaseHold()
        try await harness.waitUntil("worker A is admitted and parked in its batch") {
            await harness.catalogGate.enteredCount >= 1
        }
        let admitted = try await harness.ownership(rootEpoch)
        XCTAssertTrue(admitted.isActiveBatch)
        let workerA = try XCTUnwrap(admitted.workerID)
        let counters = await engine.accounting().counters

        // Revocation removes publication authority without preempting the admitted batch; the
        // replacement job must wait for the old batch to drain before it can be admitted.
        await engine.cancelGraphIndex(rootEpoch: rootEpoch)
        let launch = await engine.scheduleGraphIndex(rootEpoch: rootEpoch)
        XCTAssertEqual(launch, .handedOff)
        try await harness.waitUntil("successor worker B is queued behind the draining batch") {
            let ownership = await engine.debugGraphIndexAdmissionOwnershipForTesting(rootEpoch: rootEpoch)
            return ownership?.queuedTokens.count == 1 && ownership?.jobID != admitted.jobID
        }
        let draining = await engine.accounting()
        XCTAssertEqual(draining.activeGraphIndexBatchCount, 1)
        XCTAssertEqual(draining.drainingGraphIndexTaskCount, 1)
        let successor = try await harness.ownership(rootEpoch)
        XCTAssertNotEqual(successor.workerID, workerA)

        await harness.catalogGate.releaseAll()
        let completed = try await harness.waitForPhase(.complete)
        XCTAssertEqual(completed.jobID, successor.jobID)
        XCTAssertEqual(completed.workerRecoveryCount, 0)

        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.activeGraphIndexBatchCount, 0)
        XCTAssertEqual(accounting.drainingGraphIndexTaskCount, 0)
        XCTAssertEqual(accounting.queuedGraphIndexBatchCount, 0)
        XCTAssertEqual(
            accounting.counters.graphIndexCancelledBatches,
            counters.graphIndexCancelledBatches + 1
        )
        let oldSettlements = await harness.settlements(forJob: admitted.jobID)
        XCTAssertEqual(oldSettlements.map(\.reason), [.admitted])
        let successorSettlements = await harness.settlements(forJob: successor.jobID)
        XCTAssertTrue(successorSettlements.allSatisfy { $0.reason == .admitted })
        XCTAssertEqual(Set(successorSettlements.map(\.token.waitID)).count, successorSettlements.count)
        let events = await engine.debugGraphIndexEvents(rootID: rootEpoch.rootID, sinceOrdinal: nil, limit: 512)
        XCTAssertFalse(
            events.events.contains { $0.jobID == admitted.jobID && $0.kind == .graphIndexPageAccepted },
            "The revoked admitted worker must not accept or publish its in-flight page"
        )
    }

    func testCancellationBeforeRegistrationLeavesNoWaiter() async throws {
        let harness = try await AdmissionHarness.make(name: #function)
        addTeardownBlock { await harness.tearDown() }
        let engine = harness.engine
        let rootEpoch = harness.rootEpoch

        // A parked non-cooperative worker gives the job a current incarnation that is neither queued
        // nor in a batch, so every registration check except task cancellation passes.
        let installed = await engine.debugInstallNonCooperativeGraphIndexWorkerForTesting(
            rootEpoch: rootEpoch,
            completionReason: .cancelled
        )
        XCTAssertTrue(installed)
        // Engine shutdown does not release this gate, so an early failure must still drain the
        // parked worker. Teardown blocks run in reverse order, so this runs before engine teardown.
        addTeardownBlock {
            _ = await engine.debugDrainNonCooperativeGraphIndexWorkerForTesting(rootEpoch: rootEpoch)
        }
        let before = try await harness.ownership(rootEpoch)
        let workerID = try XCTUnwrap(before.workerID)
        XCTAssertNil(before.queuedAdmissionToken)
        XCTAssertFalse(before.isActiveBatch)
        let batchesQueued = await engine.accounting().counters.graphIndexBatchesQueued
        let delivery = await harness.deliveryBaseline()

        // Swift runs the cancellation handler immediately for an already-cancelled task, before the
        // operation registers anything.
        let admitted = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.debugAwaitGraphIndexAdmissionForTesting(rootEpoch: rootEpoch)
        }.value
        XCTAssertFalse(admitted)
        try await harness.waitForDelivery(since: delivery, "the pre-registration cancellation")

        let after = try await harness.ownership(rootEpoch)
        XCTAssertEqual(after.queuedTokens, [])
        XCTAssertNil(after.queuedAdmissionToken)
        let batchesQueuedAfter = await engine.accounting().counters.graphIndexBatchesQueued
        XCTAssertEqual(batchesQueuedAfter, batchesQueued, "The cancelled caller must not register a wait")
        let settlements = await harness.settlements(forJob: before.jobID).filter { $0.token.workerID == workerID }
        XCTAssertEqual(settlements, [], "A never-stored wait has nothing to settle")

        // Control: the identical registration from a live task does queue, so cancellation alone
        // explains the rejection above.
        try await harness.acquireHold()
        let control = Task {
            await engine.debugAwaitGraphIndexAdmissionForTesting(rootEpoch: rootEpoch)
        }
        try await harness.waitUntil("the uncancelled control wait is queued") {
            let ownership = await engine.debugGraphIndexAdmissionOwnershipForTesting(rootEpoch: rootEpoch)
            return ownership?.queuedTokens.count == 1 && ownership?.queuedAdmissionToken?.workerID == workerID
        }
        let controlOwnership = try await harness.ownership(rootEpoch)
        let controlToken = try XCTUnwrap(controlOwnership.queuedAdmissionToken)
        control.cancel()
        let controlAdmitted = await control.value
        XCTAssertFalse(controlAdmitted)
        let controlSettlements = await harness.settlements(forJob: before.jobID)
            .filter { $0.token.workerID == workerID }
        XCTAssertEqual(controlSettlements, [.init(token: controlToken, reason: .taskCancelled)])
        let afterControl = try await harness.ownership(rootEpoch)
        XCTAssertNil(afterControl.queuedAdmissionToken)
        XCTAssertEqual(afterControl.queuedTokens, [])

        let drained = await engine.debugDrainNonCooperativeGraphIndexWorkerForTesting(rootEpoch: rootEpoch)
        XCTAssertTrue(drained)
        try await harness.waitUntil("the parked worker finishes") {
            await engine.debugGraphIndexWorkerFinishesForTesting().contains {
                $0.workerID == workerID && $0.ownedJob
            }
        }
    }

    func testCancellationAfterAdmissionLeavesAdmittedBatchOwnedByWorker() async throws {
        let harness = try await AdmissionHarness.make(name: #function)
        addTeardownBlock { await harness.tearDown() }
        let engine = harness.engine
        let rootEpoch = harness.rootEpoch

        try await harness.queueFreshWorkerUnderHold()
        let queued = try await harness.ownership(rootEpoch)
        let token = try XCTUnwrap(queued.queuedAdmissionToken)
        let delivery = await harness.armDeliveryGate()
        await harness.catalogGate.arm(1)

        let cancelled = await engine.debugCancelGraphIndexWorkerTaskForTesting(rootEpoch: rootEpoch)
        XCTAssertTrue(cancelled)
        try await harness.waitForParkedDelivery(since: delivery, "the queued worker's cancellation delivery")
        await harness.releaseHold()
        try await harness.waitUntil("the cancelled worker is admitted and parked in its batch") {
            await harness.catalogGate.enteredCount >= 1
        }
        let batchesCompleted = await engine.accounting().counters.graphIndexBatchesCompleted

        try await harness.releaseDeliveryGate(since: delivery, "the late cancellation")
        let admitted = try await harness.ownership(rootEpoch)
        XCTAssertTrue(admitted.isActiveBatch)
        XCTAssertEqual(admitted.workerID, token.workerID)
        let activeCount = await engine.accounting().activeGraphIndexBatchCount
        XCTAssertEqual(activeCount, 1)
        let settlements = await harness.settlements(forJob: token.jobID)
        XCTAssertEqual(settlements, [.init(token: token, reason: .admitted)])

        await harness.catalogGate.releaseAll()
        try await harness.waitUntil("the admitted worker releases its own batch") {
            let accounting = await engine.accounting()
            let ownership = await engine.debugGraphIndexAdmissionOwnershipForTesting(rootEpoch: rootEpoch)
            return accounting.activeGraphIndexBatchCount == 0 && ownership?.workerID == nil
        }
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.counters.graphIndexBatchesCompleted, batchesCompleted + 1)
        XCTAssertEqual(accounting.queuedGraphIndexBatchCount, 0)
        let finalSettlements = await harness.settlements(forJob: token.jobID)
        XCTAssertEqual(finalSettlements, [.init(token: token, reason: .admitted)])
    }

    func testShutdownSettlesQueuedWaitsAndRejectsLaterAdmission() async throws {
        let harness = try await AdmissionHarness.make(name: #function)
        addTeardownBlock { await harness.tearDown() }
        let engine = harness.engine
        let rootEpoch = harness.rootEpoch

        try await harness.queueFreshWorkerUnderHold()
        let queued = try await harness.ownership(rootEpoch)
        let token = try XCTUnwrap(queued.queuedAdmissionToken)

        let shutdownFinished = AdmissionFlag()
        let shutdown = Task {
            await engine.shutdown()
            shutdownFinished.set()
        }
        try await harness.waitUntil("engine shutdown completes") { shutdownFinished.isSet }
        await shutdown.value

        let settlements = await harness.settlements(forJob: token.jobID)
        XCTAssertEqual(settlements, [.init(token: token, reason: .jobCancelled)])
        let allSettlements = await engine.debugGraphIndexAdmissionSettlementsForTesting()
        XCTAssertFalse(
            allSettlements.contains { $0.reason == .shutdown },
            "Root revocation settles every queued wait before the shutdown tail"
        )
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.graphIndexJobCount, 0)
        XCTAssertEqual(accounting.queuedGraphIndexBatchCount, 0)
        XCTAssertEqual(accounting.activeGraphIndexBatchCount, 0)
        XCTAssertEqual(accounting.drainingGraphIndexTaskCount, 0)

        let launch = await engine.scheduleGraphIndex(rootEpoch: rootEpoch)
        XCTAssertEqual(launch, .cancelled)
        let lateAdmission = await engine.debugAwaitGraphIndexAdmissionForTesting(rootEpoch: rootEpoch)
        XCTAssertFalse(lateAdmission)
        let finalQueued = await engine.accounting().queuedGraphIndexBatchCount
        XCTAssertEqual(finalQueued, 0)
    }

    func testDuplicateCancellationAndObsoleteWorkerFinishDoNotTouchReplacement() async throws {
        let harness = try await AdmissionHarness.make(name: #function)
        addTeardownBlock { await harness.tearDown() }
        let engine = harness.engine
        let rootEpoch = harness.rootEpoch

        try await harness.queueFreshWorkerUnderHold()
        let queued = try await harness.ownership(rootEpoch)
        let tokenA = try XCTUnwrap(queued.queuedAdmissionToken)

        // Worker exit settles A's wait and cancels A's task inside its cancellation handler, so A's
        // own delivery becomes a duplicate. A itself then finishes as an obsolete incarnation.
        let delivery = await harness.armDeliveryGate()
        await engine.debugSimulateGraphIndexWorkerExitForTesting(
            rootEpoch: rootEpoch,
            reason: .admissionUnavailable
        )
        try await harness.waitForParkedDelivery(since: delivery, "worker A's duplicate cancellation")
        let disposition = await engine.prioritizeGraphIndexNow(rootEpoch: rootEpoch)
        XCTAssertEqual(disposition, .restarted)
        try await harness.waitUntil("replacement worker B is queued") {
            let ownership = await engine.debugGraphIndexAdmissionOwnershipForTesting(rootEpoch: rootEpoch)
            guard let token = ownership?.queuedAdmissionToken else { return false }
            return token.workerID != tokenA.workerID && ownership?.queuedTokens == [token]
        }
        let replacement = try await harness.ownership(rootEpoch)
        let tokenB = try XCTUnwrap(replacement.queuedAdmissionToken)

        try await harness.releaseDeliveryGate(since: delivery, "worker A's duplicate cancellation")
        try await harness.waitUntil("worker A finishes as an obsolete incarnation") {
            await engine.debugGraphIndexWorkerFinishesForTesting().contains {
                $0.workerID == tokenA.workerID && !$0.ownedJob
            }
        }
        let afterDuplicate = try await harness.ownership(rootEpoch)
        XCTAssertEqual(afterDuplicate.queuedAdmissionToken, tokenB)
        XCTAssertEqual(afterDuplicate.queuedTokens, [tokenB])
        XCTAssertEqual(afterDuplicate.workerID, tokenB.workerID)

        await harness.releaseHold()
        let completed = try await harness.waitForPhase(.complete)
        XCTAssertEqual(completed.jobID, tokenA.jobID)
        let settlements = await harness.settlements(forJob: tokenA.jobID)
        XCTAssertEqual(settlements.filter { $0.token == tokenA }, [.init(token: tokenA, reason: .workerFinished)])
        XCTAssertEqual(settlements.filter { $0.token == tokenB }, [.init(token: tokenB, reason: .admitted)])
        XCTAssertFalse(settlements.contains { $0.reason == .taskCancelled })
    }
}

// MARK: - Harness

private typealias AdmissionSettlement = WorkspaceCodemapBindingEngine.DebugGraphIndexAdmissionSettlement

private final class AdmissionHarness: @unchecked Sendable {
    let engine: WorkspaceCodemapBindingEngine
    let catalogGate: CatalogReadGate

    private let repository: ReviewGitRepositoryFixture
    private let fixture: CodemapStoreFixture
    private let store: WorkspaceFileContextStore
    private let rootPath: String
    private let lock = NSLock()
    private var loadedRootIDs: [UUID]
    private var currentRootEpoch: WorkspaceCodemapRootEpoch
    private var hold: (id: UUID, rootEpoch: WorkspaceCodemapRootEpoch)?

    var rootEpoch: WorkspaceCodemapRootEpoch {
        lock.withLock { currentRootEpoch }
    }

    private init(
        repository: ReviewGitRepositoryFixture,
        fixture: CodemapStoreFixture,
        store: WorkspaceFileContextStore,
        catalogGate: CatalogReadGate,
        rootPath: String,
        rootID: UUID,
        engine: WorkspaceCodemapBindingEngine,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        self.repository = repository
        self.fixture = fixture
        self.store = store
        self.catalogGate = catalogGate
        self.rootPath = rootPath
        loadedRootIDs = [rootID]
        self.engine = engine
        currentRootEpoch = rootEpoch
    }

    /// Loads a small Git root and waits for its initial graph index, so every scenario starts from a
    /// quiescent engine with a known root epoch.
    static func make(name: String) async throws -> AdmissionHarness {
        let repository = try ReviewGitRepositoryFixture(name: name)
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let catalogGate = CatalogReadGate()
        let fixture = try CodemapStoreFixture(name: name) { _ in
            await catalogGate.pass()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        let engine = try fixture.runtime().bindingEngine()
        let root = try await waitForValue("the initial graph index", timeout: .seconds(20)) {
            await engine.accounting().graphIndexRoots.first {
                $0.rootEpoch.rootID == loaded.id && $0.phase == .complete
            }
        }
        return AdmissionHarness(
            repository: repository,
            fixture: fixture,
            store: store,
            catalogGate: catalogGate,
            rootPath: rootURL.path,
            rootID: loaded.id,
            engine: engine,
            rootEpoch: root.rootEpoch
        )
    }

    func tearDown() async {
        await engine.debugGraphIndexCancellationDeliveryGate.release()
        await catalogGate.releaseAll()
        await releaseHold()
        for rootID in lock.withLock({ loadedRootIDs }) {
            await store.unloadRoot(id: rootID)
        }
        await fixture.shutdown()
        repository.cleanup()
    }

    /// Replaces the completed job with a fresh one whose first worker is parked in the admission
    /// queue behind a DEBUG admission hold.
    func queueFreshWorkerUnderHold() async throws {
        let rootEpoch = rootEpoch
        await engine.cancelGraphIndex(rootEpoch: rootEpoch)
        try await acquireHold()
        let launch = await engine.scheduleGraphIndex(rootEpoch: rootEpoch)
        XCTAssertEqual(launch, .handedOff)
        try await waitUntil("worker A is queued behind the admission hold") { [engine] in
            let accounting = await engine.accounting()
            return accounting.queuedGraphIndexBatchCount == 1 &&
                accounting.graphIndexRoots.first { $0.rootEpoch == rootEpoch }?.isQueuedForAdmission == true
        }
    }

    func acquireHold() async throws {
        let rootEpoch = rootEpoch
        let maybeHold = await engine.debugAcquireGraphIndexAdmissionHold(
            rootEpoch: rootEpoch,
            expiresAfterMilliseconds: 60000
        )
        let acquired = try XCTUnwrap(maybeHold)
        lock.withLock { hold = (acquired.holdID, rootEpoch) }
    }

    /// Delivery-gate counters are engine-lifetime totals; waits compare against a baseline taken
    /// after setup.
    func deliveryBaseline() async -> DeliveryBaseline {
        let gate = await engine.debugGraphIndexCancellationDeliveryGate
        return await DeliveryBaseline(entered: gate.enteredCount, delivered: gate.deliveredCount)
    }

    /// Takes a baseline, then arms the gate so the next cancellation delivery parks.
    func armDeliveryGate() async -> DeliveryBaseline {
        let baseline = await deliveryBaseline()
        await engine.debugGraphIndexCancellationDeliveryGate.arm()
        return baseline
    }

    func waitForParkedDelivery(since baseline: DeliveryBaseline, _ what: String) async throws {
        let engine = engine
        try await waitUntil("\(what) to park") {
            await engine.debugGraphIndexCancellationDeliveryGate.enteredCount > baseline.entered
        }
    }

    func waitForDelivery(since baseline: DeliveryBaseline, _ what: String) async throws {
        let engine = engine
        try await waitUntil("\(what) to be delivered") {
            await engine.debugGraphIndexCancellationDeliveryGate.deliveredCount > baseline.delivered
        }
    }

    func releaseDeliveryGate(since baseline: DeliveryBaseline, _ what: String) async throws {
        await engine.debugGraphIndexCancellationDeliveryGate.release()
        try await waitForDelivery(since: baseline, what)
    }

    func eventOrdinalBaseline() async -> UInt64 {
        await engine.debugGraphIndexEvents(rootID: rootEpoch.rootID, sinceOrdinal: nil, limit: 0).lastOrdinal
    }

    /// Every retained event for the root after `baseline`, paged to exhaustion. The ring is bounded,
    /// so the scan also asserts nothing after the baseline was evicted.
    func events(since baseline: UInt64) async -> [WorkspaceCodemapGraphIndexDebugEvent] {
        var collected: [WorkspaceCodemapGraphIndexDebugEvent] = []
        var cursor = baseline
        var isFirstPage = true
        while true {
            let page = await engine.debugGraphIndexEvents(
                rootID: rootEpoch.rootID,
                sinceOrdinal: cursor,
                limit: 256
            )
            if isFirstPage {
                XCTAssertLessThanOrEqual(page.firstOrdinal, baseline, "Events after the baseline were evicted")
                isFirstPage = false
            }
            guard let next = page.nextOrdinal else { return collected }
            collected += page.events
            cursor = next
        }
    }

    func releaseHold() async {
        let taken = lock.withLock { () -> (id: UUID, rootEpoch: WorkspaceCodemapRootEpoch)? in
            defer { hold = nil }
            return hold
        }
        guard let taken else { return }
        _ = await engine.debugReleaseGraphIndexAdmissionHold(taken.id, rootEpoch: taken.rootEpoch)
    }

    /// Unloads the current root and loads the same checkout again, which registers a new root epoch.
    func reloadRoot() async throws -> WorkspaceCodemapRootEpoch {
        let previous = lock.withLock { loadedRootIDs.removeLast() }
        await store.unloadRoot(id: previous)
        let loaded = try await store.loadRoot(path: rootPath)
        lock.withLock { loadedRootIDs.append(loaded.id) }
        let engine = engine
        let root = try await waitForValue("the reloaded root's graph index", timeout: .seconds(20)) {
            await engine.accounting().graphIndexRoots.first { $0.rootEpoch.rootID == loaded.id }
        }
        lock.withLock { currentRootEpoch = root.rootEpoch }
        return root.rootEpoch
    }

    func ownership(
        _ rootEpoch: WorkspaceCodemapRootEpoch
    ) async throws -> WorkspaceCodemapBindingEngine.DebugGraphIndexAdmissionOwnership {
        let ownership = await engine.debugGraphIndexAdmissionOwnershipForTesting(rootEpoch: rootEpoch)
        return try XCTUnwrap(ownership)
    }

    func settlements(forJob jobID: UUID) async -> [AdmissionSettlement] {
        await engine.debugGraphIndexAdmissionSettlementsForTesting().filter { $0.token.jobID == jobID }
    }

    func waitForPhase(
        _ phase: WorkspaceCodemapGraphIndexPhase,
        rootEpoch: WorkspaceCodemapRootEpoch? = nil
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let rootEpoch = rootEpoch ?? self.rootEpoch
        let engine = engine
        return try await waitForValue("graph index phase \(phase)", timeout: .seconds(20)) {
            await engine.accounting().graphIndexRoots.first { $0.rootEpoch == rootEpoch && $0.phase == phase }
        }
    }

    func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(10),
        _ condition: () async -> Bool
    ) async throws {
        try await waitForValue(description, timeout: timeout) { await condition() ? () : nil }
    }
}

private struct DeliveryBaseline {
    let entered: Int
    let delivered: Int
}

/// Bounded polling for a value; a missed interleaving fails the test with its description instead
/// of hanging on a suspended continuation.
@discardableResult
private func waitForValue<Value>(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ produce: () async -> Value?
) async throws -> Value {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let value = await produce() { return value }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AdmissionWaitError.timedOut(description)
}

/// Parks a configured number of catalog page reads, which happen inside an admitted batch.
private actor CatalogReadGate {
    private var remainingParks = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    func arm(_ count: Int) {
        remainingParks += count
    }

    func pass() async {
        guard remainingParks > 0 else { return }
        remainingParks -= 1
        enteredCount += 1
        await withCheckedContinuation { continuation in
            parked.append(continuation)
        }
    }

    func releaseAll() {
        remainingParks = 0
        let continuations = parked
        parked.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class AdmissionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

private enum AdmissionWaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case let .timedOut(what): "Timed out waiting for \(what)"
        }
    }
}
