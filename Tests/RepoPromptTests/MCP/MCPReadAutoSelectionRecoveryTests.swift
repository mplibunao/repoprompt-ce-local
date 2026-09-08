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
    func enqueue(intent: Intent, for key: ContextKey) -> Bool {
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
        return enqueue(intent: intent, authority: authority, for: key)
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
