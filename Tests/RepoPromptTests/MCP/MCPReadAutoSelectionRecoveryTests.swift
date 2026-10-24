import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class MCPReadAutoSelectionRecoveryTests: XCTestCase {
    func testCanonicalInvalidationSettlesWaiterSkipsStaleApplyAndReclaimsLane() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let waiterRegistered = RecoveryMainActorSignal()
        let key = contextKey()
        var current: MCPReadFileAutoSelectionCoordinator.ContextKey? = key
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == current },
            applyCanonical: { _, _ in
                await recorder.recordCanonical()
                return .unchanged
            },
            applyMirror: { _ in .converged },
            diagnosticObserver: { probe.record($0) }
        )
        coordinator.setCanonicalApplyGateForTesting { await gate.enter() }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilEntered()
        let drain = Task { @MainActor in
            await coordinator.drain(
                .canonicalSelection,
                for: key,
                onCanonicalWaiterRegistered: { waiterRegistered.signal() }
            )
        }
        await waiterRegistered.wait()

        current = nil
        coordinator.invalidate(context: key)
        let drainResult = await drain.value
        let countBeforeRelease = await recorder.canonicalCount()
        XCTAssertEqual(drainResult, .invalidated)
        XCTAssertEqual(countBeforeRelease, 0)
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/stale.swift"]), for: key))

        await gate.release()
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical)
        let countAfterRelease = await recorder.canonicalCount()
        XCTAssertEqual(countAfterRelease, 0)
        assertFullyReclaimed(coordinator)
    }

    /// A read revoked after its intent joined a batch must not publish, and the reads it shares the batch
    /// with still do, including a slice the revoked read's full-file intent had absorbed.
    func testRevokedReadIsDroppedFromItsBatchWhileLiveReadsInTheSameBatchApply() async {
        let recorder = RecoveryBatchRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = batchRecordingCoordinator(for: key, recorder: recorder, probe: probe)
        let revokedRead = MCPDomainInvocationFence()
        let liveSliceRead = MCPDomainInvocationFence()
        let liveFullRead = MCPDomainInvocationFence()

        // The worker can't run until this test suspends, so the three intents share one batch.
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Shared.swift"]), fence: revokedRead, for: key))
        XCTAssertTrue(coordinator.enqueue(
            intent: .slices(entries: [WorkspaceSelectionSliceInput(path: "/tmp/Shared.swift", ranges: [LineRange(start: 2, end: 4)])]),
            fence: liveSliceRead,
            for: key
        ))
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Live.swift"]), fence: liveFullRead, for: key))
        revokedRead.revoke(origin: .watchdogDeadline)
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/Late.swift"]), fence: revokedRead, for: key))

        let drained = await coordinator.drain(.canonicalSelection, for: key)
        XCTAssertEqual(drained, .completed)
        let batches = await recorder.batches()
        XCTAssertEqual(batches, [RecoveryBatchRecorder.Batch(fullPaths: ["/tmp/Live.swift"], slicePaths: ["/tmp/Shared.swift"])])
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    /// Once every read in a connection's stuck batch is revoked, the next read on that connection no longer waits
    /// for the batch: its selection applies, the revoked read's own wait returns, and the stuck batch never
    /// publishes. The stuck worker keeps running, uncancelled, until the apply it is stuck in ends.
    func testAStuckBatchWhoseReadsWereAllRevokedStopsHoldingUpItsConnection() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryBatchRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let revokedReadWaiterRegistered = RecoveryMainActorSignal()
        let key = contextKey()
        let coordinator = batchRecordingCoordinator(for: key, recorder: recorder, probe: probe)
        var applyCount = 0
        var stuckWorkerSawCancellation = false
        coordinator.setCanonicalApplyGateForTesting {
            applyCount += 1
            guard applyCount == 1 else { return }
            await gate.enter()
            stuckWorkerSawCancellation = Task.isCancelled
        }

        let revokedRead = MCPDomainInvocationFence()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Stuck.swift"]), fence: revokedRead, for: key))
        await gate.waitUntilEntered()
        let revokedReadReturned = expectation(description: "the revoked read's wait returned")
        let revokedReadDrain = Task { @MainActor in
            defer { revokedReadReturned.fulfill() }
            return await coordinator.drain(
                .canonicalSelection,
                for: key,
                onCanonicalWaiterRegistered: { revokedReadWaiterRegistered.signal() }
            )
        }
        await revokedReadWaiterRegistered.wait()
        revokedRead.revoke(origin: .watchdogDeadline)

        XCTAssertTrue(coordinator.enqueue(
            intent: .full(paths: ["/tmp/Next.swift"]),
            fence: MCPDomainInvocationFence(),
            for: key
        ))
        let nextReadReturned = expectation(description: "the next read's wait returned")
        let nextReadDrain = Task { @MainActor in
            defer { nextReadReturned.fulfill() }
            return await coordinator.drain(.canonicalSelection, for: key)
        }
        await fulfillment(of: [revokedReadReturned, nextReadReturned], timeout: 5)
        let appliedWhileStuck = await recorder.batches()

        // Releasing the stuck apply only now lets a lane that still waits for it finish the test.
        await gate.release()
        let revokedReadResult = await revokedReadDrain.value
        let nextReadResult = await nextReadDrain.value
        let workerStarts = probe.snapshot().count(where: { $0.kind == .workerStarted && $0.lane == .canonical })
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical, occurrence: workerStarts)
        let appliedAfterRelease = await recorder.batches()
        XCTAssertEqual(revokedReadResult, .completed)
        XCTAssertEqual(nextReadResult, .completed)
        let nextBatch = RecoveryBatchRecorder.Batch(fullPaths: ["/tmp/Next.swift"], slicePaths: [])
        XCTAssertEqual(appliedWhileStuck, [nextBatch])
        XCTAssertEqual(appliedAfterRelease, [nextBatch], "the stuck batch published after its apply ended")
        XCTAssertFalse(stuckWorkerSawCancellation)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    /// A stuck batch that still carries a live read keeps its place: its live read applies before the reads
    /// queued behind it.
    func testAStuckBatchThatStillCarriesALiveReadKeepsLaterReadsBehindIt() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryBatchRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = batchRecordingCoordinator(for: key, recorder: recorder, probe: probe)
        var applyCount = 0
        coordinator.setCanonicalApplyGateForTesting {
            applyCount += 1
            guard applyCount == 1 else { return }
            await gate.enter()
        }

        // The worker can't run until this test suspends, so both reads share the batch it gets stuck on.
        let revokedRead = MCPDomainInvocationFence()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Revoked.swift"]), fence: revokedRead, for: key))
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Live.swift"]), fence: MCPDomainInvocationFence(), for: key))
        await gate.waitUntilEntered()
        revokedRead.revoke(origin: .watchdogDeadline)
        XCTAssertTrue(coordinator.enqueue(
            intent: .full(paths: ["/tmp/Next.swift"]),
            fence: MCPDomainInvocationFence(),
            for: key
        ))
        // Passing over the stuck batch would start a second worker inside that enqueue.
        let workerStarts = probe.snapshot().count(where: { $0.kind == .workerStarted && $0.lane == .canonical })
        XCTAssertEqual(workerStarts, 1)

        await gate.release()
        let drained = await coordinator.drain(.canonicalSelection, for: key)
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical)
        let applied = await recorder.batches()
        XCTAssertEqual(drained, .completed)
        XCTAssertEqual(applied, [
            RecoveryBatchRecorder.Batch(fullPaths: ["/tmp/Live.swift"], slicePaths: []),
            RecoveryBatchRecorder.Batch(fullPaths: ["/tmp/Next.swift"], slicePaths: [])
        ])
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    /// Closing a connection drains its queue, and that drain passes over a stuck batch whose reads were all
    /// revoked even when no later read arrives: the reads queued behind the batch apply, and the drain returns.
    func testClosingAConnectionPassesOverItsRevokedStuckBatchAndAppliesTheReadsBehindIt() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryBatchRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = batchRecordingCoordinator(for: key, recorder: recorder, probe: probe)
        var applyCount = 0
        coordinator.setCanonicalApplyGateForTesting {
            applyCount += 1
            guard applyCount == 1 else { return }
            await gate.enter()
        }

        let revokedRead = MCPDomainInvocationFence()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Stuck.swift"]), fence: revokedRead, for: key))
        await gate.waitUntilEntered()
        XCTAssertTrue(coordinator.enqueue(
            intent: .full(paths: ["/tmp/Queued.swift"]),
            fence: MCPDomainInvocationFence(),
            for: key
        ))
        revokedRead.revoke(origin: .watchdogDeadline)

        let closingDrainReturned = expectation(description: "the closing drain returned")
        let closingDrain = Task { @MainActor in
            defer { closingDrainReturned.fulfill() }
            return await coordinator.finish(context: key)
        }
        await fulfillment(of: [closingDrainReturned], timeout: 5)
        let appliedWhileStuck = await recorder.batches()

        // Invalidating ends a drain that still waits for the stuck batch, so a lane that never passes over it fails
        // this test instead of hanging it.
        coordinator.invalidate(context: key)
        await gate.release()
        let closingDrainResult = await closingDrain.value
        let workerStarts = probe.snapshot().count(where: { $0.kind == .workerStarted && $0.lane == .canonical })
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical, occurrence: workerStarts)
        XCTAssertEqual(closingDrainResult, .completed)
        XCTAssertEqual(appliedWhileStuck, [RecoveryBatchRecorder.Batch(fullPaths: ["/tmp/Queued.swift"], slicePaths: [])])
        assertFullyReclaimed(coordinator)
    }

    /// A passed-over worker that resumes leaves the worker that replaced it alone: a later read still waits behind
    /// the replacement's batch, and once that batch's reads are revoked too, it can be passed over in turn.
    func testAPassedOverWorkerThatResumesDoesNotDisturbTheWorkerThatReplacedIt() async {
        let firstGate = RecoveryCancellationIgnoringGate()
        let secondGate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryBatchRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = batchRecordingCoordinator(for: key, recorder: recorder, probe: probe)
        var applyCount = 0
        coordinator.setCanonicalApplyGateForTesting {
            applyCount += 1
            switch applyCount {
            case 1: await firstGate.enter()
            case 2: await secondGate.enter()
            default: break
            }
        }

        let firstRead = MCPDomainInvocationFence()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/First.swift"]), fence: firstRead, for: key))
        await firstGate.waitUntilEntered()
        firstRead.revoke(origin: .watchdogDeadline)
        let secondRead = MCPDomainInvocationFence()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Second.swift"]), fence: secondRead, for: key))
        // The enqueue passes over the stuck batch and starts the replacement before it returns. Without that, nothing
        // ever enters the second gate, and the test stops here instead of waiting for it.
        let workerStartsAfterPassOver = probe.snapshot().count(where: { $0.kind == .workerStarted && $0.lane == .canonical })
        XCTAssertEqual(workerStartsAfterPassOver, 2, "the second read's enqueue didn't pass over the stuck batch")
        guard workerStartsAfterPassOver == 2 else {
            await firstGate.release()
            await secondGate.release()
            return
        }
        await secondGate.waitUntilEntered()

        // The passed-over worker resumes, finds every read in its batch revoked, and stops.
        await firstGate.release()
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical)
        XCTAssertTrue(coordinator.enqueue(
            intent: .full(paths: ["/tmp/Third.swift"]),
            fence: MCPDomainInvocationFence(),
            for: key
        ))
        let workerStartsBehindLiveBatch = probe.snapshot().count(where: { $0.kind == .workerStarted && $0.lane == .canonical })
        XCTAssertEqual(workerStartsBehindLiveBatch, 2, "the third read got a worker of its own beside the second read's")

        secondRead.revoke(origin: .watchdogDeadline)
        let thirdReadReturned = expectation(description: "the third read's wait returned")
        let thirdReadDrain = Task { @MainActor in
            defer { thirdReadReturned.fulfill() }
            return await coordinator.drain(.canonicalSelection, for: key)
        }
        await fulfillment(of: [thirdReadReturned], timeout: 5)
        let appliedWhileSecondIsStuck = await recorder.batches()

        // Invalidating ends a drain that still waits for the second batch, so a regression fails instead of hanging.
        coordinator.invalidate(context: key)
        await secondGate.release()
        let thirdReadResult = await thirdReadDrain.value
        let workerStarts = probe.snapshot().count(where: { $0.kind == .workerStarted && $0.lane == .canonical })
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical, occurrence: workerStarts)
        XCTAssertEqual(thirdReadResult, .completed)
        XCTAssertEqual(appliedWhileSecondIsStuck, [RecoveryBatchRecorder.Batch(fullPaths: ["/tmp/Third.swift"], slicePaths: [])])
        assertFullyReclaimed(coordinator)
    }

    /// A read whose provider completes at its deadline gets the timeout reply, and its queued selection never
    /// applies afterwards, whichever of the completion and the deadline the watchdog handles first.
    func testAReadThatCompletesAtItsDeadlineTimesOutWithoutSelectingItsFileLater() async throws {
        for order in LateCompletionOrder.allCases {
            try await assertReadCompletingAtItsDeadlineNeverSelectsItsFile(order)
        }
    }

    func testCancellingCanonicalDrainReleasesWaiterWhilePhysicalWorkerContinues() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let waiterRegistered = RecoveryMainActorSignal()
        let key = contextKey()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == key },
            applyCanonical: { _, _ in
                await recorder.recordCanonical()
                return .unchanged
            },
            applyMirror: { _ in .converged },
            diagnosticObserver: { probe.record($0) }
        )
        coordinator.setCanonicalApplyGateForTesting { await gate.enter() }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilEntered()
        let drain = Task { @MainActor in
            await coordinator.drain(
                .canonicalSelection,
                for: key,
                onCanonicalWaiterRegistered: { waiterRegistered.signal() }
            )
        }
        await waiterRegistered.wait()

        drain.cancel()
        let cancelledResult = await drain.value
        XCTAssertEqual(cancelledResult, .cancelled)
        XCTAssertEqual(coordinator.debugSnapshot().canonicalWaiterCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().canonicalWorkerCount, 1)

        await gate.release()
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical)
        let canonicalCount = await recorder.canonicalCount()
        let settledResult = await coordinator.drain(.canonicalSelection, for: key)
        XCTAssertEqual(canonicalCount, 1)
        XCTAssertEqual(settledResult, .completed)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    func testCancellingMirrorDrainReleasesWaiterAndDeadlineWhilePhysicalWorkerContinues() async {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == key },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { mirrorKey in
                _ = await recorder.recordMirror(mirrorKey)
                await gate.enter()
                return .converged
            },
            diagnosticObserver: { probe.record($0) }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilEntered()
        let drain = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        }
        _ = await probe.waitFor(kind: .waiterRegistered, lane: .mirror, target: 1)

        drain.cancel()
        let cancelledResult = await drain.value
        XCTAssertEqual(cancelledResult, .cancelled)
        let cancelled = coordinator.debugSnapshot()
        XCTAssertEqual(cancelled.mirrorWaiterCount, 0)
        XCTAssertEqual(cancelled.liveMirrorDeadlineCount, 0)
        XCTAssertEqual(cancelled.mirrorWorkerCount, 1)

        await gate.release()
        _ = await probe.waitFor(kind: .workerStopped, lane: .mirror)
        let settledResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        let mirrorCount = await recorder.mirrorCount()
        XCTAssertEqual(settledResult, .completed)
        XCTAssertEqual(mirrorCount, 1)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    func testFinishDeadlineReturnsDeferredRejectsNewWorkAndReclaimsAfterPhysicalExit() async {
        let gate = RecoveryCancellationIgnoringGate()
        let probe = RecoveryDiagnosticEventProbe()
        let key = contextKey()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == key },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { _ in
                await gate.enter()
                return .converged
            },
            diagnosticObserver: { probe.record($0) },
            mirrorWaitTimeout: .zero
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilEntered()
        let finishResult = await coordinator.finish(context: key)
        XCTAssertEqual(finishResult, .deferred)
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/later.swift"]), for: key))
        let deferred = coordinator.debugSnapshot()
        XCTAssertEqual(deferred.mirrorWaiterCount, 0)
        XCTAssertEqual(deferred.liveMirrorDeadlineCount, 0)
        XCTAssertEqual(deferred.mirrorWorkerCount, 1)

        coordinator.invalidate(context: key)
        XCTAssertEqual(coordinator.debugSnapshot().retiredMirrorWorkerCount, 1)
        await gate.release()
        _ = await probe.waitFor(kind: .workerStopped, lane: .mirror)
        assertFullyReclaimed(coordinator)

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/reopened.swift"]), for: key))
        _ = await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 2)
        let reopenedResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        XCTAssertEqual(reopenedResult, .completed)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator)
    }

    func testInvalidatingParkedMirrorOwnerPreservesSameTabSurvivorAndFencesLateExit() async {
        let oldGate = RecoveryCancellationIgnoringGate()
        let replacementGate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let tabID = UUID()
        let workspaceID = UUID()
        let old = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 1)
        let replacement = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 2)
        var current: Set<MCPReadFileAutoSelectionCoordinator.ContextKey> = [old, replacement]
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { current.contains($0) },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { mirrorKey in
                let invocation = await recorder.recordMirror(mirrorKey)
                if invocation == 1 {
                    await oldGate.enter()
                } else if invocation == 2 {
                    await replacementGate.enter()
                }
                return .converged
            },
            diagnosticObserver: { probe.record($0) }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/old.swift"]), for: old))
        await oldGate.waitUntilEntered()
        let oldDrain = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: old)
        }
        _ = await probe.waitFor(kind: .waiterRegistered, lane: .mirror, target: 1)

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/replacement.swift"]), for: replacement))
        let replacementDrain = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: replacement)
        }
        _ = await probe.waitFor(kind: .waiterRegistered, lane: .mirror, target: 2)

        current.remove(old)
        coordinator.invalidate(context: old)
        let oldResult = await oldDrain.value
        XCTAssertEqual(oldResult, .invalidated)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 1)
        await replacementGate.waitUntilEntered()

        let workerStarts = probe.snapshot().filter { $0.kind == .workerStarted && $0.lane == .mirror }
        XCTAssertEqual(workerStarts.count, 2)
        XCTAssertNotEqual(workerStarts[0].workerID, workerStarts[1].workerID)

        await replacementGate.release()
        let replacementResult = await replacementDrain.value
        let countBeforeOldExit = await recorder.mirrorCount()
        XCTAssertEqual(replacementResult, .completed)
        XCTAssertEqual(countBeforeOldExit, 2)

        // The retired callback ignores cancellation deliberately, proving its late exit is fenced by worker identity.
        await oldGate.release()
        _ = await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 2)
        let countAfterOldExit = await recorder.mirrorCount()
        XCTAssertEqual(countAfterOldExit, 2)
        current.remove(replacement)
        coordinator.invalidate(context: replacement)
        assertFullyReclaimed(coordinator)
    }

    func testLateMirrorDrainReceivesExactTerminalOutcome() async {
        let cases: [(WorkspaceSelectionCoordinator.SelectionMirrorOutcome, MCPReadFileAutoSelectionCoordinator.DrainResult)] = [
            (.converged, .completed),
            (.deferred, .deferred),
            (.invalidated, .invalidated),
            (.cancelled, .cancelled)
        ]

        for (mirrorOutcome, expectedDrain) in cases {
            let probe = RecoveryDiagnosticEventProbe()
            let key = contextKey()
            let coordinator = MCPReadFileAutoSelectionCoordinator(
                isContextCurrent: { $0 == key },
                applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
                applyMirror: { _ in mirrorOutcome },
                diagnosticObserver: { probe.record($0) }
            )

            XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
            _ = await probe.waitFor(kind: .workerStopped, lane: .mirror)
            let drainResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
            XCTAssertEqual(drainResult, expectedDrain)
            coordinator.invalidate(context: key)
            assertFullyReclaimed(coordinator)
        }
    }

    func testLaterSameTabConvergenceUpgradesDeferredTicketAndPrunesObsoleteSettlement() async {
        let recorder = RecoveryInvocationRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let tabID = UUID()
        let workspaceID = UUID()
        let earlier = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 1)
        let later = contextKey(tabID: tabID, workspaceID: workspaceID, bindingGeneration: 2)
        var current: Set<MCPReadFileAutoSelectionCoordinator.ContextKey> = [earlier, later]
        let scripted: [WorkspaceSelectionCoordinator.SelectionMirrorOutcome] = [.deferred, .converged, .deferred]
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { current.contains($0) },
            applyCanonical: { key, _ in .init(mirrorKey: key.mirrorKey) },
            applyMirror: { mirrorKey in
                let invocation = await recorder.recordMirror(mirrorKey)
                return scripted[invocation - 1]
            },
            diagnosticObserver: { probe.record($0) }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/earlier.swift"]), for: earlier))
        _ = await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 1)
        let initialEarlierResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: earlier)
        XCTAssertEqual(initialEarlierResult, .deferred)

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/later.swift"]), for: later))
        _ = await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 2)
        let laterResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: later)
        let upgradedEarlierResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: earlier)
        XCTAssertEqual(laterResult, .completed)
        XCTAssertEqual(upgradedEarlierResult, .completed)

        // Once convergence upgrades the earlier ticket, retiring that owner makes its deferred range obsolete.
        current.remove(earlier)
        coordinator.invalidate(context: earlier)
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/newer.swift"]), for: later))
        _ = await probe.waitFor(kind: .workerStopped, lane: .mirror, occurrence: 3)
        let newerResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: later)
        let mirrorCount = await recorder.mirrorCount()
        XCTAssertEqual(newerResult, .deferred)
        XCTAssertEqual(mirrorCount, 3)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorSettlementRangeCount, 1)

        current.remove(later)
        coordinator.invalidate(context: earlier)
        coordinator.invalidate(context: later)
        assertFullyReclaimed(coordinator)
    }

    func testSelectionPrerequisiteTypesUnsatisfiedDrainsAndKeepsCancellation() async {
        enum Outcome: Equatable {
            case completes, cancellation, prerequisite(MCPSelectionPrerequisiteError), other(String)
        }
        let cases: [(MCPReadFileAutoSelectionCoordinator.DrainResult, Outcome)] = [
            (.completed, .completes),
            (.cancelled, .cancellation),
            (.deferred, .prerequisite(.deferred)),
            (.invalidated, .prerequisite(.invalidated))
        ]
        for (result, expected) in cases {
            let observed: Outcome
            do {
                try await MCPServerViewModel.requireReadFileAutoSelectionPrerequisite { result }
                observed = .completes
            } catch let error as MCPSelectionPrerequisiteError {
                observed = .prerequisite(error)
            } catch is CancellationError {
                observed = .cancellation
            } catch {
                observed = .other(String(describing: error))
            }
            XCTAssertEqual(observed, expected, "\(result)")
        }

        struct DrainFailure: Error, Equatable {}
        do {
            try await MCPServerViewModel.requireReadFileAutoSelectionPrerequisite { throw DrainFailure() }
            XCTFail("A throwing drain must not complete")
        } catch {
            XCTAssertEqual(error as? DrainFailure, DrainFailure(), "A drain error must reach the caller unchanged: \(error)")
        }
    }

    func testSelectionPrerequisiteReportsTaskCancellationOverEveryDrainResult() async {
        // The task is cancelled before its body starts, so the check after the drain sees it.
        for result: MCPReadFileAutoSelectionCoordinator.DrainResult in [.completed, .deferred, .invalidated] {
            let task = Task { @MainActor () -> (drained: Bool, error: Error?) in
                var drained = false
                do {
                    try await MCPServerViewModel.requireReadFileAutoSelectionPrerequisite {
                        drained = true
                        return result
                    }
                    return (drained, nil)
                } catch {
                    return (drained, error)
                }
            }
            task.cancel()
            let outcome = await task.value
            XCTAssertTrue(outcome.drained, "\(result): the drain must run before the cancellation check")
            XCTAssertTrue(outcome.error is CancellationError, "\(result): \(String(describing: outcome.error))")
        }
    }

    private enum LateCompletionOrder: CaseIterable {
        /// The watchdog handles the completion before its deadline event.
        case completionFirst
        /// The watchdog handles its deadline event after the completion was delivered but before handling it.
        case deadlineFirst
    }

    private func assertReadCompletingAtItsDeadlineNeverSelectsItsFile(
        _ order: LateCompletionOrder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let gate = RecoveryCancellationIgnoringGate()
        let recorder = RecoveryBatchRecorder()
        let probe = RecoveryDiagnosticEventProbe()
        let completionDelivered = RecoveryEventSignal()
        let deadlineHandled = RecoveryEventSignal()
        let key = contextKey()
        let coordinator = batchRecordingCoordinator(for: key, recorder: recorder, probe: probe)
        coordinator.setCanonicalApplyGateForTesting { await gate.enter() }
        let fence = MCPDomainInvocationFence()
        let deadline = Duration.seconds(30)
        let environment = MCPToolExecutionWatchdogEnvironment(
            now: { .zero },
            sleep: { _ in
                switch order {
                case .completionFirst:
                    // Handling the completion cancels this sleep, so the deadline event never comes.
                    try await Task.sleep(for: .seconds(3600))
                case .deadlineFirst:
                    await completionDelivered.wait()
                }
            },
            eventDidProduce: { point in
                guard order == .deadlineFirst, point == .operationCompleted else { return }
                completionDelivered.signal()
                await deadlineHandled.wait()
            },
            beforeEventConsumption: { point in
                if point == .deadlineExpired { deadlineHandled.signal() }
            }
        )

        var watchdogError: Error?
        do {
            _ = try await MCPToolExecutionWatchdog.execute(
                deadline: deadline,
                cancellationGrace: .seconds(5),
                environment: environment,
                operationCompletionInstant: { deadline },
                revokeBeforeCancellation: { origin in fence.revoke(origin: origin) },
                operation: {
                    // An eligible Agent Mode read queues its selection and returns without waiting for it.
                    await MainActor.run {
                        _ = coordinator.enqueue(intent: .full(paths: ["/tmp/Late.swift"]), fence: fence, for: key)
                    }
                    return "read reply"
                }
            )
        } catch {
            watchdogError = error
        }
        XCTAssertEqual(
            watchdogError as? MCPToolExecutionWatchdogError,
            .executionTimedOut(settlement: .success),
            "\(order)",
            file: file,
            line: line
        )

        await gate.release()
        let drained = await coordinator.drain(.canonicalSelection, for: key)
        _ = await probe.waitFor(kind: .workerStopped, lane: .canonical)
        let applied = await recorder.batches()
        XCTAssertEqual(drained, .completed, "\(order)", file: file, line: line)
        XCTAssertEqual(applied, [], "\(order): the timed-out read's selection applied after its timeout", file: file, line: line)
        coordinator.invalidate(context: key)
        assertFullyReclaimed(coordinator, file: file, line: line)
    }

    /// A coordinator for `key` that records each batch it applies and reports its diagnostics to `probe`.
    private func batchRecordingCoordinator(
        for key: MCPReadFileAutoSelectionCoordinator.ContextKey,
        recorder: RecoveryBatchRecorder,
        probe: RecoveryDiagnosticEventProbe
    ) -> MCPReadFileAutoSelectionCoordinator {
        MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == key },
            applyCanonical: { _, batch in
                await recorder.record(.init(fullPaths: batch.fullPaths, slicePaths: batch.sliceEntries.map(\.path)))
                return .unchanged
            },
            applyMirror: { _ in .converged },
            diagnosticObserver: { probe.record($0) }
        )
    }

    private func contextKey(
        tabID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        bindingGeneration: UInt64 = 1
    ) -> MCPReadFileAutoSelectionCoordinator.ContextKey {
        MCPReadFileAutoSelectionCoordinator.ContextKey(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            route: .bound(connectionID: UUID(), runID: UUID()),
            bindingGeneration: bindingGeneration
        )
    }

    private func assertFullyReclaimed(
        _ coordinator: MCPReadFileAutoSelectionCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = coordinator.debugSnapshot()
        XCTAssertEqual(snapshot.canonicalLaneCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.canonicalWorkerCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorLaneCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorWorkerCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.closingContextCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.pendingCanonicalBatchCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.pendingMirrorBatchCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.canonicalWaiterCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorWaiterCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.inFlightMirrorBatchCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.retiredMirrorWorkerCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.liveMirrorDeadlineCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.mirrorSettlementRangeCount, 0, file: file, line: line)
    }
}

private extension MCPReadFileAutoSelectionCoordinator {
    @discardableResult
    func enqueue(intent: Intent, fence: MCPDomainInvocationFence? = nil, for key: ContextKey) -> Bool {
        let workspaceID = key.workspaceID ?? key.tabID
        let authority = MCPServerViewModel.FrozenFileToolAuthority(
            lookupContext: .visibleWorkspace,
            rootCatalogSnapshot: WorkspaceRootCatalogSnapshot(
                ticket: WorkspaceSearchReadinessTicket(
                    workspaceID: workspaceID,
                    generation: key.bindingGeneration
                ),
                workspaceID: workspaceID,
                configuredRootPaths: [],
                primaryRoots: []
            ),
            sessionRootLifetimeSnapshot: nil,
            sourceIdentity: nil
        )
        return enqueue(intent: intent, authority: authority, fence: fence, for: key)
    }
}

private actor RecoveryBatchRecorder {
    struct Batch: Equatable {
        let fullPaths: [String]
        let slicePaths: [String]
    }

    private var recorded: [Batch] = []

    func record(_ batch: Batch) {
        recorded.append(batch)
    }

    func batches() -> [Batch] {
        recorded
    }
}

private actor RecoveryCancellationIgnoringGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        // A checked continuation intentionally ignores task cancellation so tests observe physical worker lifetime.
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

/// A one-shot signal that closures running off the main actor can raise and await.
private final class RecoveryEventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            signalled = true
            defer { waiters.removeAll() }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if signalled { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

@MainActor
private final class RecoveryMainActorSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RecoveryInvocationRecorder {
    private var canonicalInvocations = 0
    private var mirrorKeys: [MCPReadFileAutoSelectionCoordinator.TabMirrorKey] = []

    func recordCanonical() {
        canonicalInvocations += 1
    }

    func canonicalCount() -> Int {
        canonicalInvocations
    }

    func recordMirror(_ key: MCPReadFileAutoSelectionCoordinator.TabMirrorKey) -> Int {
        mirrorKeys.append(key)
        return mirrorKeys.count
    }

    func mirrorCount() -> Int {
        mirrorKeys.count
    }
}

private final class RecoveryDiagnosticEventProbe: @unchecked Sendable {
    private struct Waiter {
        let kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind
        let lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane
        let target: UInt64?
        let occurrence: Int
        let continuation: CheckedContinuation<MCPReadFileAutoSelectionDiagnosticEvent, Never>
    }

    private let lock = NSLock()
    private var events: [MCPReadFileAutoSelectionDiagnosticEvent] = []
    private var waiters: [Waiter] = []

    func record(_ event: MCPReadFileAutoSelectionDiagnosticEvent) {
        lock.lock()
        events.append(event)
        var remaining: [Waiter] = []
        var resumptions: [(CheckedContinuation<MCPReadFileAutoSelectionDiagnosticEvent, Never>, MCPReadFileAutoSelectionDiagnosticEvent)] = []
        for waiter in waiters {
            if let match = matchingEvent(
                kind: waiter.kind,
                lane: waiter.lane,
                target: waiter.target,
                occurrence: waiter.occurrence
            ) {
                resumptions.append((waiter.continuation, match))
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        lock.unlock()

        // Resume outside the lock so awakened tasks can safely re-enter the probe.
        for (continuation, match) in resumptions {
            continuation.resume(returning: match)
        }
    }

    func snapshot() -> [MCPReadFileAutoSelectionDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func waitFor(
        kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
        lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane,
        target: UInt64? = nil,
        occurrence: Int = 1
    ) async -> MCPReadFileAutoSelectionDiagnosticEvent {
        precondition(occurrence > 0)
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let match = matchingEvent(kind: kind, lane: lane, target: target, occurrence: occurrence) {
                lock.unlock()
                continuation.resume(returning: match)
            } else {
                waiters.append(Waiter(
                    kind: kind,
                    lane: lane,
                    target: target,
                    occurrence: occurrence,
                    continuation: continuation
                ))
                lock.unlock()
            }
        }
    }

    private func matchingEvent(
        kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
        lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane,
        target: UInt64?,
        occurrence: Int
    ) -> MCPReadFileAutoSelectionDiagnosticEvent? {
        var matchingCount = 0
        for event in events where event.kind == kind && event.lane == lane && (target == nil || event.target == target) {
            matchingCount += 1
            if matchingCount == occurrence {
                return event
            }
        }
        return nil
    }
}
