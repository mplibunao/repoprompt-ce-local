import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainReadSideEffectRecoveryTests: XCTestCase {
    /// A read whose fence is revoked and whose wait is cancelled retires its effect: the next effect in the
    /// lane runs while the retired one is still stuck, and the retired one keeps running until it ends.
    func testARevokedReadThatStopsWaitingNoLongerHoldsUpItsLane() async throws {
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
            fence: fence,
            onFinished: { events.append("first finished") }
        ) {
            await stuck.enterAndWait()
        }
        await stuck.waitUntilEntered()
        let firstWait = Task { try await coordinator.wait(handle: handle, receipt: first) }
        fence.revoke(origin: .watchdogDeadline)
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
        let secondRan = await events.waitFor("second ran")
        XCTAssertTrue(secondRan)
        guard secondRan else {
            await stuck.release()
            return
        }
        try await coordinator.wait(handle: handle, receipt: second)
        XCTAssertEqual(events.snapshot(), ["second ran"])

        await stuck.release()
        let firstFinished = await events.waitFor("first finished")
        XCTAssertTrue(firstFinished)
    }

    /// Cancelling a read's wait without revoking its fence leaves its effect in the lane, so the next effect
    /// still runs after it.
    func testACancelledWaitWithoutRevocationKeepsTheLaneInOrder() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let stuck = HeldEffect()
        let fence = MCPDomainInvocationFence()

        let first = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "first",
            fence: fence
        ) {
            await stuck.enterAndWait()
        }
        await stuck.waitUntilEntered()
        let firstWait = Task { try await coordinator.wait(handle: handle, receipt: first) }
        firstWait.cancel()
        await assertCancelled(firstWait)

        let events = EventLog()
        _ = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "second"
        ) {
            events.append("second ran")
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(events.snapshot(), [], "the second effect ran while the first was still running")

        await stuck.release()
        let secondRan = await events.waitFor("second ran")
        XCTAssertTrue(secondRan)
    }

    /// Retiring a later effect doesn't let a drain through it pass an earlier effect that is still running.
    func testADrainPastARetiredEffectStillWaitsForAnEarlierRunningOne() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let stuck = HeldEffect()
        let fence = MCPDomainInvocationFence()

        _ = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "running"
        ) {
            await stuck.enterAndWait()
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

        let events = EventLog()
        let drain = Task {
            try await coordinator.drain(handle: handle, effectClass: .selection, through: retired.revision)
            events.append("drained")
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(events.snapshot(), [], "the drain returned while the earlier effect was still running")

        await stuck.release()
        try await drain.value
        XCTAssertEqual(events.snapshot(), ["drained"])
    }

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

    /// Polls for an event that another task records, for up to five seconds.
    func waitFor(_ event: String) async -> Bool {
        for _ in 0 ..< 500 {
            if snapshot().contains(event) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot().contains(event)
    }
}
