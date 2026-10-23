import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPCodeStructureSettlementRegistryNoticeTests: XCTestCase {
    func testReleasedProviderLimitBlockageClearsWhenBlockingSiblingSettles() throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 71
        let firstInvocationID = UUID()
        let secondInvocationID = UUID()

        let firstSlot = try admittedSlot(
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
        let secondSlot = try admittedSlot(
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

        let released = try admittedSlot(
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
        let blocking = try admittedSlot(
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

        let detachedRead = try admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .zero, fence: detachedReadFence)
        let liveRead = try admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .seconds(1), fence: liveReadFence)
        escape(detachedRead, at: .seconds(35))
        let stuckPrompt = try admittedSlot(
            registry,
            windowID: windowID,
            invocationID: UUID(),
            now: .seconds(65),
            commitState: promptCommit
        )
        escape(stuckPrompt, at: .seconds(100))
        XCTAssertTrue(registry.hasReleasedProviderLimitBlockage(windowID: windowID))

        let recovering = try admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .seconds(101))
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
        let next = try admittedSlot(registry, windowID: windowID, invocationID: UUID(), now: .seconds(102))
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

    /// One recovery quarantines every escaped call in the window, and a window has at most two recoveries
    /// whose calls haven't all finished. A refused recovery quarantines nothing, and completing a recovery's
    /// calls makes room for the next one.
    func testAWindowRecoversEveryEscapedCallAtOnceAndAtMostTwiceUntilTheyFinish() throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 91

        let together = try escapeTogether(registry, windowID: windowID, count: 3, at: .zero)
        XCTAssertEqual(try recover(registry, windowID: windowID, at: .seconds(36)).quarantinedCalls.count, 3)
        let secondCap = try capWindow(registry, windowID: windowID, from: .seconds(100))
        XCTAssertEqual(
            try recover(registry, windowID: windowID, at: .seconds(201)).quarantine,
            .init(windowQuarantinedCount: 5, windowOutstandingRecoveryCount: 2, appQuarantinedCount: 5)
        )
        let thirdCap = try capWindow(registry, windowID: windowID, from: .seconds(300))
        assertCapRejected(
            registry,
            windowID: windowID,
            at: .seconds(401),
            quarantine: .init(windowQuarantinedCount: 5, windowOutstandingRecoveryCount: 2, appQuarantinedCount: 5)
        )
        XCTAssertEqual(registry.snapshot(windowID: windowID).quarantinedCount, 5)

        for slot in together {
            _ = slot.recordCompletion(.success)
        }
        XCTAssertEqual(
            try recover(registry, windowID: windowID, at: .seconds(402)).quarantine,
            .init(windowQuarantinedCount: 4, windowOutstandingRecoveryCount: 2, appQuarantinedCount: 4)
        )

        for slot in secondCap + thirdCap {
            _ = slot.recordCompletion(.success)
        }
        XCTAssertEqual(registry.snapshot(windowID: windowID).activeCount, 0)
        XCTAssertEqual(registry.diagnostics(windowID: windowID, now: .seconds(500)).quarantine.appQuarantinedCount, 0)
    }

    /// A recovery that would pass eight quarantined calls app-wide quarantines none of the window's calls.
    /// Closing another window's calls frees nothing; only their completions make room.
    func testARecoveryPastTheAppWideLimitQuarantinesNothingUntilCompletionsMakeRoom() throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 92
        let otherWindowID = 93
        let closingWindowID = 94

        let closing = try escapeTogether(registry, windowID: closingWindowID, count: 3, at: .zero)
        _ = try recover(registry, windowID: closingWindowID, at: .seconds(36))
        let other = try escapeTogether(registry, windowID: otherWindowID, count: 4, at: .zero)
        XCTAssertEqual(try recover(registry, windowID: otherWindowID, at: .seconds(36)).quarantine.appQuarantinedCount, 7)

        let capped = try capWindow(registry, windowID: windowID, from: .zero)
        let refused = MCPCodeStructureSettlementRegistry.QuarantineUsage(
            windowQuarantinedCount: 0,
            windowOutstandingRecoveryCount: 0,
            appQuarantinedCount: 7
        )
        assertCapRejected(registry, windowID: windowID, at: .seconds(101), quarantine: refused)
        XCTAssertEqual(registry.snapshot(windowID: windowID).quarantinedCount, 0)

        registry.revokeWindow(windowID: closingWindowID)
        assertCapRejected(registry, windowID: windowID, at: .seconds(102), quarantine: refused)

        for slot in closing {
            _ = slot.recordCompletion(.success)
        }
        XCTAssertEqual(
            try recover(registry, windowID: windowID, at: .seconds(103)).quarantine,
            .init(windowQuarantinedCount: 2, windowOutstandingRecoveryCount: 1, appQuarantinedCount: 6)
        )

        for slot in other + capped {
            _ = slot.recordCompletion(.success)
        }
        XCTAssertEqual(registry.diagnostics(windowID: windowID, now: .seconds(200)).quarantine.appQuarantinedCount, 0)
    }

    /// Closing a connection revokes that connection's calls in every window, and closing a window revokes
    /// that window's calls. Each revocation keeps the origin that came first, and every lease stays tracked
    /// until its call completes.
    func testClosingAWindowOrAConnectionRevokesOnlyItsOwnCalls() throws {
        let registry = MCPCodeStructureSettlementRegistry()
        let connectionA = UUID()
        let connectionB = UUID()
        let firstWindowID = 111
        let secondWindowID = 112
        let readOnAInFirst = MCPDomainInvocationFence()
        let promptOnAInFirst = DomainMutationCommitState()
        let readOnBInFirst = MCPDomainInvocationFence()
        let readOnAInSecond = MCPDomainInvocationFence()
        let promptOnBInSecond = DomainMutationCommitState()
        let slots = try [
            admittedSlot(registry, windowID: firstWindowID, connectionID: connectionA, now: .zero, fence: readOnAInFirst),
            admittedSlot(registry, windowID: firstWindowID, connectionID: connectionA, now: .zero, commitState: promptOnAInFirst),
            admittedSlot(registry, windowID: firstWindowID, connectionID: connectionB, now: .zero, fence: readOnBInFirst),
            admittedSlot(registry, windowID: secondWindowID, connectionID: connectionA, now: .zero, fence: readOnAInSecond),
            admittedSlot(registry, windowID: secondWindowID, connectionID: connectionB, now: .zero, commitState: promptOnBInSecond)
        ]

        registry.revokeConnection(connectionA)
        XCTAssertEqual(readOnAInFirst.revocationOrigin, .connectionClosed)
        XCTAssertEqual(promptOnAInFirst.currentPhase, .revoked(.connectionClosed))
        XCTAssertEqual(readOnAInSecond.revocationOrigin, .connectionClosed)
        XCTAssertFalse(readOnBInFirst.isRevoked)
        XCTAssertEqual(promptOnBInSecond.currentPhase, .preCommit)

        registry.revokeWindow(windowID: secondWindowID)
        XCTAssertEqual(promptOnBInSecond.currentPhase, .revoked(.windowClosed))
        XCTAssertEqual(readOnAInSecond.revocationOrigin, .connectionClosed)
        XCTAssertFalse(readOnBInFirst.isRevoked)

        XCTAssertEqual(registry.snapshot(windowID: firstWindowID).activeCount, 3)
        XCTAssertEqual(registry.snapshot(windowID: secondWindowID).activeCount, 2)
        for slot in slots {
            XCTAssertEqual(slot.recordCompletion(.success), .deliver)
        }
        XCTAssertEqual(registry.snapshot(windowID: firstWindowID).activeCount, 0)
        XCTAssertEqual(registry.snapshot(windowID: secondWindowID).activeCount, 0)
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
    ) throws -> [MCPCodeStructureSettlementRegistry.Slot] {
        let released = try admittedSlot(registry, windowID: windowID, now: start)
        escape(released, at: start + .seconds(35))
        let blocking = try admittedSlot(registry, windowID: windowID, now: start + .seconds(65))
        escape(blocking, at: start + .seconds(100))
        XCTAssertTrue(registry.hasReleasedProviderLimitBlockage(windowID: windowID))
        return [released, blocking]
    }

    /// Admits `count` calls at once and lets their deadline pass: the first detaches and the rest are
    /// force-disconnected, so they all escape together and cap the window.
    private func escapeTogether(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        count: Int,
        at start: Duration
    ) throws -> [MCPCodeStructureSettlementRegistry.Slot] {
        let slots = try (0 ..< count).map { _ in try admittedSlot(registry, windowID: windowID, now: start) }
        XCTAssertEqual(slots[0].resolveGraceExpiry(now: start + .seconds(35)), .detach)
        XCTAssertEqual(slots[0].activateDetach(), .activated)
        for slot in slots.dropFirst() {
            XCTAssertEqual(slot.resolveGraceExpiry(now: start + .seconds(35)), .forceDisconnect)
        }
        XCTAssertTrue(registry.hasReleasedProviderLimitBlockage(windowID: windowID))
        return slots
    }

    /// Quarantines eight calls from two other windows, which uses up the app-wide limit, so a capped
    /// window's next call is rejected instead of recovering it. Returns the quarantined calls.
    private func fillAppWideQuarantine(
        _ registry: MCPCodeStructureSettlementRegistry
    ) throws -> [MCPCodeStructureSettlementRegistry.Slot] {
        var quarantined: [MCPCodeStructureSettlementRegistry.Slot] = []
        for windowID in [1001, 1002] {
            quarantined += try capWindow(registry, windowID: windowID, from: .zero)
            _ = try recover(registry, windowID: windowID, at: .seconds(101))
            quarantined += try capWindow(registry, windowID: windowID, from: .seconds(200))
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
        let slot = try admittedSlot(registry, windowID: windowID, now: now)
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

    private struct AdmissionRefused: Error, CustomStringConvertible {
        let reason: MCPCodeStructureSettlementRegistry.BusyReason

        var description: String {
            "expected registry admission, but the registry refused the call: \(reason)"
        }
    }

    /// Admits a call, or throws if the registry refuses it. The slot is held until teardown, after the
    /// test's registry is released, so a test that stops early reports its failure instead of tripping the
    /// registry's leak assertion when its locals go away.
    private func admittedSlot(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        invocationID: UUID = UUID(),
        connectionID: UUID = UUID(),
        now: Duration,
        handlerPhaseRecorder: MCPToolExecutionHandlerPhaseRecorder? = nil,
        commitState: DomainMutationCommitState? = nil,
        fence: MCPDomainInvocationFence? = nil
    ) throws -> MCPCodeStructureSettlementRegistry.Slot {
        switch registry.admit(
            windowID: windowID,
            connectionID: connectionID,
            invocationID: invocationID,
            toolName: "get_code_structure",
            now: now,
            handlerPhaseRecorder: handlerPhaseRecorder,
            commitState: commitState,
            fence: fence
        ) {
        case let .admitted(slot):
            addTeardownBlock { _ = slot.recordCompletion(.success) }
            return slot
        case let .busy(busy):
            throw AdmissionRefused(reason: busy.reason)
        }
    }
}
