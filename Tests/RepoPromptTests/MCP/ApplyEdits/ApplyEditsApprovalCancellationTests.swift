@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class ApplyEditsApprovalCancellationTests: XCTestCase {
        func testCancellingAReplacedRequestLeavesTheNewerReviewPending() async throws {
            let hopHeld = MCPExecutionIgnoringCancellationGate()
            let hopFinished = MCPExecutionIgnoringCancellationGate()
            await hopFinished.release()
            let store = ApplyEditsApprovalStore(requestCancellationHopForTesting: { resolve in
                await hopHeld.enterAndWait()
                await resolve()
                await hopFinished.enterAndWait()
            })
            let scope = ApplyEditsApprovalScope(windowID: 1, tabID: UUID())
            let subscription = await store.subscribe(scope: scope)
            addTeardownBlock { await store.unsubscribe(scope: scope, id: subscription.id) }
            var snapshots = subscription.stream.makeAsyncIterator()

            let first = Task {
                await store.requestReview(scope: scope, path: "Target.swift", unifiedDiff: "first", timeoutSeconds: 300)
            }
            addTeardownBlock {
                await hopHeld.release()
                first.cancel()
                _ = await first.value
            }
            let firstReviewID = try await Self.nextPendingReviewID(from: &snapshots, excluding: nil)

            // The first request's cancellation is in flight but has not reached the store yet.
            first.cancel()
            try await hopHeld.waitUntilEntered(count: 1)

            let second = Task {
                await store.requestReview(scope: scope, path: "Target.swift", unifiedDiff: "second", timeoutSeconds: 300)
            }
            addTeardownBlock {
                await hopHeld.release()
                second.cancel()
                _ = await second.value
            }
            let secondReviewID = try await Self.nextPendingReviewID(from: &snapshots, excluding: firstReviewID)
            let firstDecision = await first.value
            XCTAssertEqual(firstDecision, .cancelled(reason: "Replaced by newer apply_edits preview"))

            await hopHeld.release()
            try await hopFinished.waitUntilEntered(count: 1)

            await store.resolveReview(scope: scope, reviewID: secondReviewID, decision: .accept)
            let secondDecision = await second.value
            XCTAssertEqual(secondDecision, .accept, "The late cancellation of the replaced request must not cancel the newer review")
        }

        private static func nextPendingReviewID(
            from snapshots: inout AsyncStream<ApplyEditsApprovalSnapshot>.Iterator,
            excluding excludedID: UUID?
        ) async throws -> UUID {
            while let snapshot = await snapshots.next() {
                if let review = snapshot.pendingReview, review.id != excludedID {
                    return review.id
                }
            }
            throw SnapshotStreamEnded()
        }

        private struct SnapshotStreamEnded: Error {}
    }
#endif
