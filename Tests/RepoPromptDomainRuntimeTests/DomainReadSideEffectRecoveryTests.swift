import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainReadSideEffectRecoveryTests: XCTestCase {
    /// A read whose fence is revoked and whose wait is cancelled retires its effect: the next effect in the
    /// lane runs while the retired one is still stuck, and the retired one keeps running, uncancelled, until
    /// it ends.
    func testARevokedReadThatStopsWaitingNoLongerHoldsUpItsLane() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let stuck = HeldEffect()
        let events = EventLog()
        let fence = MCPDomainInvocationFence()
        let firstFinished = expectation(description: "the retired effect finished")

        let first = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "first",
            fence: fence,
            onFinished: {
                events.append("first finished")
                firstFinished.fulfill()
            }
        ) {
            await stuck.enterAndWait()
            events.append(Task.isCancelled ? "first ended cancelled" : "first ended")
        }
        await stuck.waitUntilEntered()
        let firstWait = Task { try await coordinator.wait(handle: handle, receipt: first) }
        fence.revoke(origin: .watchdogDeadline)
        firstWait.cancel()
        await assertCancelled(firstWait)

        let secondRan = expectation(description: "the next effect ran")
        let second = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "second"
        ) {
            events.append("second ran")
            secondRan.fulfill()
        }
        await fulfillment(of: [secondRan], timeout: 5)
        guard events.snapshot() == ["second ran"] else {
            XCTFail("the next effect didn't run while the retired one was stuck: \(events.snapshot())")
            await stuck.release()
            return
        }
        try await coordinator.wait(handle: handle, receipt: second)

        await stuck.release()
        await fulfillment(of: [firstFinished], timeout: 5)
        XCTAssertEqual(events.snapshot(), ["second ran", "first ended", "first finished"])
    }

    #if DEBUG
        /// Cancelling a read's wait without revoking its fence leaves its effect in the lane, so the next effect
        /// still runs after it.
        func testACancelledWaitWithoutRevocationKeepsTheLaneInOrder() async throws {
            let identity = makeIdentity()
            let handle = makeHandle(identity: identity)
            let coordinator = DomainReadSideEffectCoordinator(identity: identity)
            let stuck = HeldEffect()
            let events = EventLog()
            let fence = MCPDomainInvocationFence()

            let first = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: UUID(),
                fingerprint: "first",
                fence: fence
            ) {
                await stuck.enterAndWait()
                events.append("first end")
            }
            await stuck.waitUntilEntered()
            let firstWait = Task { try await coordinator.wait(handle: handle, receipt: first) }
            firstWait.cancel()
            await assertCancelled(firstWait)

            let second = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: UUID(),
                fingerprint: "second"
            ) {
                events.append("second ran")
            }
            await waitUntilParkedOrRecorded(coordinator, handle: handle, target: first.revision, events: events)
            XCTAssertEqual(events.snapshot(), [], "the next effect ran while the first was still running")
            await stuck.release()
            try await coordinator.wait(handle: handle, receipt: second)
            XCTAssertEqual(events.snapshot(), ["first end", "second ran"])
        }

        /// Retiring a later effect doesn't let a drain through it pass an earlier effect that is still running.
        func testADrainPastARetiredEffectStillWaitsForAnEarlierRunningOne() async throws {
            let identity = makeIdentity()
            let handle = makeHandle(identity: identity)
            let coordinator = DomainReadSideEffectCoordinator(identity: identity)
            let stuck = HeldEffect()
            let events = EventLog()
            let fence = MCPDomainInvocationFence()

            _ = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: UUID(),
                fingerprint: "running"
            ) {
                await stuck.enterAndWait()
                events.append("first end")
            }
            await stuck.waitUntilEntered()
            let retired = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: UUID(),
                fingerprint: "retired",
                fence: fence
            ) {}
            let retiredWait = Task { try await coordinator.wait(handle: handle, receipt: retired) }
            fence.revoke(origin: .watchdogDeadline)
            retiredWait.cancel()
            await assertCancelled(retiredWait)

            let drain = Task {
                try await coordinator.drain(handle: handle, effectClass: .selection, through: retired.revision)
                events.append("drained")
            }
            await waitUntilParkedOrRecorded(coordinator, handle: handle, target: retired.revision, events: events)
            XCTAssertEqual(events.snapshot(), [], "the drain returned while the earlier effect was still running")
            await stuck.release()
            try await drain.value
            XCTAssertEqual(events.snapshot(), ["first end", "drained"])
        }
    #endif

    /// A retired effect that never started finishes at its retirement, releasing whatever its submitter
    /// claimed, instead of waiting for an earlier effect that has no fence and may never end.
    func testARetiredEffectThatNeverStartedFinishesWithoutWaitingForItsPredecessor() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let stuck = HeldEffect()
        let events = EventLog()
        let fence = MCPDomainInvocationFence()

        _ = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "unfenced"
        ) {
            await stuck.enterAndWait()
        }
        await stuck.waitUntilEntered()
        let retired = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "retired",
            fence: fence,
            onFinished: { events.append("retired finished") }
        ) {
            events.append("retired ran")
        }
        let retiredWait = Task { try await coordinator.wait(handle: handle, receipt: retired) }
        fence.revoke(origin: .watchdogDeadline)
        retiredWait.cancel()
        await assertCancelled(retiredWait)

        XCTAssertEqual(events.snapshot(), ["retired finished"])
        await stuck.release()
    }

    #if DEBUG
        /// Yields until a waiter for `target` is parked in the lane or `events` records something, so the test
        /// knows which of the two happened without timing it.
        private func waitUntilParkedOrRecorded(
            _ coordinator: DomainReadSideEffectCoordinator,
            handle: DomainReadContextHandle,
            target: UInt64,
            events: EventLog
        ) async {
            while events.snapshot().isEmpty,
                  await !coordinator.debugTerminalWaitTargets(handle: handle, effectClass: .selection).contains(target)
            {
                await Task.yield()
            }
        }
    #endif

    private func assertCancelled(
        _ task: Task<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("expected the wait to end with cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    private func makeIdentity() -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42,
            mode: .app,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeHandle(identity: DomainRuntimeIdentity) -> DomainReadContextHandle {
        DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: UUID(),
            connectionGeneration: 1,
            context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 1,
            contextRevision: 1,
            routingRevision: 1,
            bindingKind: .explicit
        )
    }
}

/// An effect that stays stuck, ignoring cancellation, until the test releases it.
private actor HeldEffect {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}
