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

    /// At the cap, the busy reply and the DEBUG snapshot must name the population that caused it:
    /// which lease still blocks, which was released, and the await each one last reached.
    func testCappedWindowDiagnosticsNameEachLeaseAndItsLatestPhase() {
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 72
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

        guard case let .busy(busy) = registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: "read_file",
            now: .seconds(101)
        ) else {
            return XCTFail("expected the capped window to reject admission")
        }
        XCTAssertEqual(busy.reason, .releasedProviderLimitReached)
        XCTAssertEqual(busy.originInvocationID, blocking.invocationID)
        XCTAssertEqual(busy.handlerPhase, "read_file.content_read.freshness")
        XCTAssertEqual(busy.blockingProviderCount, 1)
        XCTAssertEqual(busy.releasedProviderCount, 1)

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
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Duration = .zero

        var now: Duration {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func admittedSlot(
        _ registry: MCPCodeStructureSettlementRegistry,
        windowID: Int,
        invocationID: UUID,
        now: Duration,
        handlerPhaseRecorder: MCPToolExecutionHandlerPhaseRecorder? = nil
    ) -> MCPCodeStructureSettlementRegistry.Slot {
        switch registry.admit(
            windowID: windowID,
            connectionID: UUID(),
            invocationID: invocationID,
            toolName: "get_code_structure",
            now: now,
            handlerPhaseRecorder: handlerPhaseRecorder
        ) {
        case let .admitted(slot):
            return slot
        case .busy:
            XCTFail("expected registry admission")
            fatalError("unreachable after XCTFail")
        }
    }
}
