import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Per-subscriber MCP state streams.
    ///
    /// Every window's `MCPServerViewModel` needs every snapshot, including pending approvals.
    /// `AsyncStream` hands each yield to a single waiting iterator, so each subscriber gets its own
    /// stream, and a closed window must give its stream back.
    ///
    /// Each test runs against the process-wide service under `MCPSharedServerTestLease`. Other
    /// windows may already be subscribed and the controller may publish diagnostics, so subscriber
    /// counts are relative to a baseline and streams are compared by approval-identity transitions.
    @MainActor
    final class MCPStateSubscriptionTests: XCTestCase {
        /// Two subscribers each observe every approval change, in order.
        func testEverySubscriberReceivesEverySnapshotInOrder() async throws {
            try await withSharedService { service in
                let (idA, streamA) = await service.subscribeToStateUpdates()
                let (idB, streamB) = await service.subscribeToStateUpdates()

                await service.setPendingApprovalForTesting("state-subscription-m1")
                await service.setPendingApprovalForTesting("state-subscription-m2")
                await service.setPendingApprovalForTesting(nil)

                await service.unsubscribeFromStateUpdates(id: idA)
                await service.unsubscribeFromStateUpdates(id: idB)

                let expected: [String?] = [nil, "state-subscription-m1", "state-subscription-m2", nil]
                let transitionsA = await Self.approvalTransitions(streamA)
                let transitionsB = await Self.approvalTransitions(streamB)
                XCTAssertEqual(transitionsA, expected)
                XCTAssertEqual(transitionsB, expected)
            }
        }

        /// A subscriber that arrives after an approval is already pending starts from that state.
        func testLateSubscriberReceivesCurrentSnapshot() async throws {
            try await withSharedService { service in
                await service.setPendingApprovalForTesting("state-subscription-early")

                let (id, stream) = await service.subscribeToStateUpdates()
                await service.unsubscribeFromStateUpdates(id: id)

                let snapshots = await Self.collectAll(stream)
                XCTAssertEqual(snapshots.first?.pendingClientID, "state-subscription-early")
            }
        }

        /// Unsubscribing finishes only that stream; the other subscriber keeps receiving updates.
        func testUnsubscribeFinishesOnlyThatStream() async throws {
            try await withSharedService { service in
                let baseline = await service.stateSubscriberCountForTesting()
                let (idA, streamA) = await service.subscribeToStateUpdates()
                let (idB, streamB) = await service.subscribeToStateUpdates()
                let subscribedCount = await service.stateSubscriberCountForTesting()
                XCTAssertEqual(subscribedCount, baseline + 2)

                await service.unsubscribeFromStateUpdates(id: idA)
                let remainingCount = await service.stateSubscriberCountForTesting()
                XCTAssertEqual(remainingCount, baseline + 1)
                // Fails unless the removal finished A's stream.
                let snapshotsA = await Self.collectAll(streamA)

                await service.setPendingApprovalForTesting("state-subscription-after-removal")
                await service.unsubscribeFromStateUpdates(id: idB)
                let snapshotsB = await Self.collectAll(streamB)

                XCTAssertFalse(snapshotsA.contains { $0.pendingClientID == "state-subscription-after-removal" })
                XCTAssertEqual(
                    Self.approvalTransitions(of: snapshotsB),
                    [nil, "state-subscription-after-removal"]
                )
                let finalCount = await service.stateSubscriberCountForTesting()
                XCTAssertEqual(finalCount, baseline)
            }
        }

        /// Tearing down a window releases its state subscription even while the window is still alive.
        func testWindowTeardownReleasesItsStateSubscription() async throws {
            try await withSharedService { service in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                let baseline = await service.stateSubscriberCountForTesting()
                let window = MCPWindowTestSupport.makeWindowWithoutAutoStart()
                WindowStatesManager.shared.registerWindowState(window)
                XCTAssertTrue(window.mcpServer.service === service)

                let subscribed = await MCPWindowTestSupport.waitUntil {
                    await service.stateSubscriberCountForTesting() == baseline + 1
                }
                XCTAssertTrue(subscribed, "Constructing a window must subscribe it to MCP state.")

                await MCPWindowTestSupport.tearDown(window)
                let released = await MCPWindowTestSupport.waitUntil {
                    await service.stateSubscriberCountForTesting() == baseline
                }
                XCTAssertTrue(released, "Window teardown must release its MCP state subscription.")
                // Keep the window alive so deinit cannot stand in for teardown releasing the subscription.
                withExtendedLifetime(window) {}
            }
        }

        // MARK: - Fixture

        private func withSharedService(_ body: (MCPService) async throws -> Void) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                try await MCPWindowTestSupport.withSharedServiceState(lease: lease, body)
            }
        }

        /// Collects a stream the test has already unsubscribed, which must therefore finish. A failure is
        /// recorded rather than thrown, so the test still unsubscribes the streams it owns.
        private static func collectAll(
            _ stream: AsyncStream<MCPService.Snapshot>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> [MCPService.Snapshot] {
            guard let snapshots = await MCPWindowTestSupport.readSnapshots(from: stream) else {
                XCTFail("An unsubscribed state stream did not finish within the timeout.", file: file, line: line)
                return []
            }
            return snapshots
        }

        private static func approvalTransitions(
            _ stream: AsyncStream<MCPService.Snapshot>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> [String?] {
            await approvalTransitions(of: collectAll(stream, file: file, line: line))
        }

        /// Pending-approval identities with consecutive repeats removed, so unrelated snapshots such as
        /// diagnostics updates do not change the sequence.
        private static func approvalTransitions(of snapshots: [MCPService.Snapshot]) -> [String?] {
            var transitions: [String?] = []
            for snapshot in snapshots where transitions.last != .some(snapshot.pendingClientID) {
                transitions.append(snapshot.pendingClientID)
            }
            return transitions
        }
    }
#endif
