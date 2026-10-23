import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPCodeStructureSettlementRegistryNoticeTests: XCTestCase {
    func testReleasedProviderLimitBlockageClearsWhenBlockingSiblingSettles() {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 71
        let firstInvocationID = UUID()
        let secondInvocationID = UUID()

        let firstSlot = admittedSlot(
            registry,
            windowID: windowID,
            invocationID: firstInvocationID,
            now: .zero
        )
        XCTAssertEqual(firstSlot.resolveGraceExpiry(now: .zero), .detach)
        XCTAssertEqual(firstSlot.activateDetach(), .activated)
        XCTAssertFalse(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        // The recovery horizon releases the first cancellation-ignoring provider
        // so one new call may run, but preserves that provider's exact lease.
        let secondSlot = admittedSlot(
            registry,
            windowID: windowID,
            invocationID: secondInvocationID,
            now: MCPCodeStructureSettlementRegistry.recoveryHorizon
        )
        XCTAssertFalse(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        XCTAssertEqual(
            secondSlot.resolveGraceExpiry(now: MCPCodeStructureSettlementRegistry.recoveryHorizon),
            .detach
        )
        XCTAssertEqual(secondSlot.activateDetach(), .activated)
        XCTAssertTrue(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        // Completing the sibling frees the cap even though the released first
        // provider remains tracked. The UI may clear its released-limit notice.
        XCTAssertEqual(secondSlot.recordCompletion(.success), .settleDetached)
        XCTAssertFalse(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        // The original lease still owns and records its own eventual completion.
        XCTAssertEqual(firstSlot.recordCompletion(.success), .settleDetached)
        XCTAssertEqual(registry.snapshot(windowID: windowID).activeCount, 0)
    }

    /// When a capped window can't recover, the busy reply and the DEBUG snapshot must name the population
    /// that caused it: which lease still blocks, which was released, and the await each one last reached.
    func testCappedWindowDiagnosticsNameEachLeaseAndItsLatestPhase() throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 72
        let otherWindowsQuarantined = try fillAppWideQuarantine(registry)
        let clock = ManualClock()
        let releasedRecorder = MCPToolExecutionHandlerPhaseRecorder(origin: .zero, now: { clock.now })
        let blockingRecorder = MCPToolExecutionHandlerPhaseRecorder(
            origin: .seconds(65),
            now: { clock.now }
        )

        let released = admittedSlot(
            registry,
            windowID: windowID,
            invocationID: UUID(),
            now: .zero,
            handlerPhaseRecorder: releasedRecorder
        )
        clock.now = .seconds(1)
        releasedRecorder.report(.readFileContentRead, transition: .started)
        XCTAssertEqual(released.resolveGraceExpiry(now: .seconds(35)), .detach)
        XCTAssertEqual(released.activateDetach(), .activated)

        // Admission after the recovery horizon releases the first lease.
        let blocking = admittedSlot(
            registry,
            windowID: windowID,
            invocationID: UUID(),
            now: .seconds(65),
            handlerPhaseRecorder: blockingRecorder
        )
        clock.now = .seconds(66)
        blockingRecorder.report(.readFileContentReadFreshness, transition: .started)
        XCTAssertEqual(blocking.resolveGraceExpiry(now: .seconds(100)), .detach)
        XCTAssertEqual(blocking.activateDetach(), .activated)

        let busy: MCPCodeStructureSettlementRegistry.BusyContext
        switch registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "read_file",
            now: .seconds(101)
        ) {
        case let .busy(context):
            busy = context
        case let .admitted(slot):
            XCTFail("expected the capped window to reject admission")
            // An unclosed slot trips the registry's leak assertion, which would hide this failure.
            _ = slot.closeBeforeExecutionExit()
            return
        }
        XCTAssertEqual(busy.reason, .releasedProviderLimitReached)
        XCTAssertEqual(busy.originInvocationID, blocking.invocationID)
        XCTAssertEqual(busy.handlerPhase, "read_file.content_read.freshness")
        XCTAssertEqual(busy.blockingProviderCount, 1)
        XCTAssertEqual(busy.releasedProviderCount, 1)
        XCTAssertEqual(busy.quarantine, .init(windowQuarantinedCount: 0, windowOutstandingRecoveryCount: 0, appQuarantinedCount: 8))

        let diagnostics = registry.diagnostics(windowID: windowID, now: .seconds(101))
        XCTAssertEqual(diagnostics.counts, .init(activeCount: 2, detachedCount: 2, releasedCount: 1))
        XCTAssertEqual(diagnostics.blockingCount, 1)
        XCTAssertEqual(diagnostics.leases.map(\.invocationID), [released.invocationID, blocking.invocationID])
        XCTAssertEqual(diagnostics.leases.map(\.state), ["detached", "detached"])
        XCTAssertEqual(diagnostics.leases.map(\.isReleased), [true, false])
        XCTAssertEqual(diagnostics.leases.map(\.admissionAge), [.seconds(101), .seconds(36)])
        XCTAssertEqual(diagnostics.leases.map(\.blockingAge), [.seconds(66), .seconds(1)])
        XCTAssertEqual(
            diagnostics.leases.map { $0.handlerPhase?.phase },
            [.readFileContentRead, .readFileContentReadFreshness]
        )
        XCTAssertEqual(diagnostics.leases.map(\.handlerPhaseAge), [.seconds(100), .seconds(35)])
        XCTAssertEqual(diagnostics.leases.map(\.providerCompleted), [false, false])

        XCTAssertEqual(blocking.recordCompletion(.success), .settleDetached)
        XCTAssertEqual(released.recordCompletion(.success), .settleDetached)
        XCTAssertEqual(registry.diagnostics(windowID: windowID, now: .seconds(102)).leases, [])
        for slot in otherWindowsQuarantined {
            _ = slot.recordCompletion(.success)
        }
    }

    /// A call that reaches a capped window recovers it: the calls that outlived their callers are
    /// quarantined and revoked, a live sibling is untouched, and the quarantined leases stay tracked
    /// until their own completion refunds the recovery.
    func testCappedWindowRecoveryQuarantinesOnlyEscapedCallsUntilEachCompletes() throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 81
        let detachedReadFence = MCPDomainInvocationFence()
        let liveReadFence = MCPDomainInvocationFence()
        let promptCommit = DomainMutationCommitState()

        let detachedRead = admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .zero, fence: detachedReadFence)
        let liveRead = admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .seconds(1), fence: liveReadFence)
        escape(detachedRead, at: .seconds(35))
        let stuckPrompt = admittedSlot(
            registry,
            windowID: windowID,
            invocationID: UUID(),
            now: .seconds(65),
            commitState: promptCommit
        )
        escape(stuckPrompt, at: .seconds(100))
        XCTAssertTrue(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        let recovering = admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .seconds(101))
        let recovery = try XCTUnwrap(recovering.recovery)
        XCTAssertEqual(
            recovery.quarantinedCalls.map(\.invocationID),
            [detachedRead.invocationID, stuckPrompt.invocationID]
        )
        XCTAssertEqual(recovery.quarantine, .init(windowQuarantinedCount: 2, windowOutstandingRecoveryCount: 1, appQuarantinedCount: 2))
        XCTAssertEqual(detachedReadFence.revocationOrigin, .windowRecovery)
        XCTAssertEqual(promptCommit.currentPhase, .revoked(.windowRecovery))
        XCTAssertFalse(liveReadFence.isRevoked)

        // Quarantined calls no longer fence the window but stay tracked.
        XCTAssertFalse(registry.hasReleasedProviderLimitBlockage(windowID: windowID))
        XCTAssertEqual(
            registry.snapshot(windowID: windowID),
            .init(activeCount: 4, detachedCount: 2, releasedCount: 0, quarantinedCount: 2)
        )
        let next = admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .seconds(102))
        XCTAssertNil(next.recovery)
        XCTAssertEqual(next.closeBeforeExecutionExit(), .released)
        XCTAssertEqual(recovering.closeBeforeExecutionExit(), .released)

        // The recovery stays outstanding until every call it quarantined has completed.
        XCTAssertEqual(detachedRead.recordCompletion(.success), .settleDetached)
        XCTAssertEqual(registry.diagnostics(windowID: windowID, now: .seconds(103)).quarantine.windowOutstandingRecoveryCount, 1)
        XCTAssertEqual(stuckPrompt.recordCompletion(.cancellation), .settleDetached)
        XCTAssertEqual(
            registry.diagnostics(windowID: windowID, now: .seconds(104)).quarantine,
            .init(windowQuarantinedCount: 0, windowOutstandingRecoveryCount: 0, appQuarantinedCount: 0)
        )
        XCTAssertEqual(liveRead.recordCompletion(.success), .deliver)
        XCTAssertEqual(registry.snapshot(windowID: windowID).activeCount, 0)
    }

    /// Recovery stops at two outstanding recoveries in a window and eight quarantined calls in the app.
    /// Past either limit the cap rejects calls with the usage, closing a window refunds nothing, and only
    /// completions do.
    func testRecoveryIsRefusedPastItsPerWindowOrAppWideLimit() throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let first = 91
        let second = 92
        var escaped: [MCPCodeStructureSettlementRegistry.Slot] = []

        // Three calls admitted together escape at once; one recovery quarantines all three.
        let together = (0 ..< 3).map { _ in admittedSlot(registry, windowID: first, invocationID: UUID(), now: .zero) }
        XCTAssertEqual(together[0].resolveGraceExpiry(now: .seconds(35)), .detach)
        XCTAssertEqual(together[0].activateDetach(), .activated)
        XCTAssertEqual(together[1].resolveGraceExpiry(now: .seconds(35)), .forceDisconnect)
        XCTAssertEqual(together[2].resolveGraceExpiry(now: .seconds(35)), .forceDisconnect)
        let firstRecovery = try recover(registry, windowID: first, at: .seconds(36))
        XCTAssertEqual(firstRecovery.quarantinedCalls.count, 3)
        escaped += together

        let firstWindowSecondCap = capWindow(registry, windowID: first, from: .seconds(100))
        escaped += firstWindowSecondCap
        XCTAssertEqual(
            try recover(registry, windowID: first, at: .seconds(201)).quarantine,
            .init(windowQuarantinedCount: 5, windowOutstandingRecoveryCount: 2, appQuarantinedCount: 5)
        )
        let firstWindowThirdCap = capWindow(registry, windowID: first, from: .seconds(300))
        escaped += firstWindowThirdCap
        assertCapRejected(
            registry,
            windowID: first,
            at: .seconds(401),
            quarantine: .init(windowQuarantinedCount: 5, windowOutstandingRecoveryCount: 2, appQuarantinedCount: 5)
        )

        escaped += capWindow(registry, windowID: second, from: .zero)
        XCTAssertEqual(try recover(registry, windowID: second, at: .seconds(101)).quarantine.appQuarantinedCount, 7)
        let secondWindowCap = capWindow(registry, windowID: second, from: .seconds(200))
        escaped += secondWindowCap
        assertCapRejected(
            registry,
            windowID: second,
            at: .seconds(301),
            quarantine: .init(windowQuarantinedCount: 2, windowOutstandingRecoveryCount: 1, appQuarantinedCount: 7)
        )

        // Closing a window revokes its calls and refunds nothing.
        registry.revokeWindow(windowID: second)
        XCTAssertEqual(registry.diagnostics(windowID: second, now: .seconds(302)).quarantine.appQuarantinedCount, 7)

        // Completing the first recovery's calls frees its slot in the first window and three app-wide.
        for slot in together {
            _ = slot.recordCompletion(.success)
        }
        XCTAssertEqual(
            try recover(registry, windowID: first, at: .seconds(402)).quarantine,
            .init(windowQuarantinedCount: 4, windowOutstandingRecoveryCount: 2, appQuarantinedCount: 6)
        )
        XCTAssertEqual(try recover(registry, windowID: second, at: .seconds(303)).quarantine.appQuarantinedCount, 8)

        for slot in escaped {
            _ = slot.recordCompletion(.success)
        }
        XCTAssertEqual(registry.snapshot(windowID: first).activeCount, 0)
        XCTAssertEqual(registry.snapshot(windowID: second).activeCount, 0)
        XCTAssertEqual(registry.diagnostics(windowID: first, now: .seconds(500)).quarantine.appQuarantinedCount, 0)
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Duration = .zero

        var now: Duration {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Lets the call's deadline and grace pass while it ignores cancellation, so it detaches.
    private func escape(
        _ slot: MCPCodeStructureSettlementRegistry.Slot,
        at now: Duration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(slot.resolveGraceExpiry(now: now), .detach, file: file, line: line)
        XCTAssertEqual(slot.activateDetach(), .activated, file: file, line: line)
    }

    /// Caps the window the way an idle wedge does: one call detaches, the recovery horizon releases it so
    /// a second call runs, and that call detaches too. Returns the two escaped calls.
    private func capWindow(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        from start: Duration
    ) -> [MCPCodeStructureSettlementRegistry.Slot] {
        let released = admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: start)
        escape(released, at: start + .seconds(35))
        let blocking = admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: start + .seconds(65))
        escape(blocking, at: start + .seconds(100))
        XCTAssertTrue(registry.hasReleasedProviderLimitBlockage(windowID: windowID))
        return [released, blocking]
    }

    /// Quarantines eight calls from two other windows, which uses up the app-wide limit, so a capped
    /// window's next call is rejected instead of recovering it. Returns the quarantined calls.
    private func fillAppWideQuarantine(
        _ registry: MCPCodeStructureSettlementRegistry
    ) throws -> [MCPCodeStructureSettlementRegistry.Slot] {
        var quarantined: [MCPCodeStructureSettlementRegistry.Slot] = []
        for windowID in [1001, 1002] {
            quarantined += capWindow(registry, windowID: windowID, from: .zero)
            _ = try recover(registry, windowID: windowID, at: .seconds(101))
            quarantined += capWindow(registry, windowID: windowID, from: .seconds(200))
            _ = try recover(registry, windowID: windowID, at: .seconds(301))
        }
        return quarantined
    }

    /// Admits a call into the capped window and returns the recovery it triggered. The call itself completes.
    private func recover(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        at now: Duration
    ) throws -> MCPCodeStructureSettlementRegistry.Recovery {
        let slot = admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: now)
        defer { _ = slot.closeBeforeExecutionExit() }
        return try XCTUnwrap(slot.recovery)
    }

    private func assertCapRejected(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        at now: Duration,
        quarantine: MCPCodeStructureSettlementRegistry.QuarantineUsage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "read_file",
            now: now
        ) {
        case let .busy(busy):
            XCTAssertEqual(busy.reason, .releasedProviderLimitReached, file: file, line: line)
            XCTAssertEqual(busy.quarantine, quarantine, file: file, line: line)
        case let .admitted(slot):
            XCTFail("expected the cap to reject the call", file: file, line: line)
            // An unclosed slot trips the registry's leak assertion, which would hide this failure.
            _ = slot.closeBeforeExecutionExit()
        }
    }

    private func admittedSlot(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        invocationID: UUID,
        now: Duration,
        handlerPhaseRecorder: MCPToolExecutionHandlerPhaseRecorder? = nil,
        commitState: DomainMutationCommitState? = nil,
        fence: MCPDomainInvocationFence? = nil
    ) -> MCPCodeStructureSettlementRegistry.Slot {
        switch registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: invocationID,
            toolName: "get_code_structure",
            now: now,
            handlerPhaseRecorder: handlerPhaseRecorder,
            commitState: commitState,
            fence: fence
        ) {
        case let .admitted(slot):
            return slot
        case .busy:
            XCTFail("expected registry admission")
            fatalError("unreachable after XCTFail")
        }
    }
}
