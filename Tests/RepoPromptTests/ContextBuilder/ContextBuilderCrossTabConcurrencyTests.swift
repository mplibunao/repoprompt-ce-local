import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Context Builder runs on different compose tabs of one window, routed through production
    /// pending-policy admission, run-to-connection mapping, nested tool calls, and the final-context
    /// commit by ``ContextBuilderRunFixture``.
    @MainActor
    final class ContextBuilderCrossTabConcurrencyTests: XCTestCase {
        /// Start state: the window's MCP tools are disabled and neither tab has a run, so both runs
        /// reach window-tool readiness cold and share one enable transition. The runs enter through
        /// the view model's MCP entry directly; a caller's `context_builder` request reaches that
        /// entry only on a window whose tools are already enabled.
        ///
        /// The run whose pending policy is older is then held before its child connects, so the
        /// other run's child is admitted, mutates its tab, and commits past that older policy.
        func testColdDifferentTabsCompleteWithReversedChildConnections() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let server = fixture.window.mcpServer
                fixture.holdsChildConnections = true

                XCTAssertFalse(server.windowToolsEnabled)
                let enableGeneration = server.windowToolRegistrationIntentGenerationForTesting() + 1
                let registrationGate = ContextBuilderTestGate()
                server.setBeforeWindowToolRegistrationForTesting { await registrationGate.wait() }
                cleanup.add {
                    server.setBeforeWindowToolRegistrationForTesting(nil)
                    await registrationGate.open()
                }

                let runs = fixture.slots.map { fixture.startMCPRun(on: $0) }
                try await fixture.waitFor("both cold starts to share one enable transition") {
                    await registrationGate.entered
                        && server.windowToolTransitionJoinsByGenerationForTesting()[enableGeneration] == 1
                }
                XCTAssertFalse(server.windowToolsEnabled)
                await registrationGate.open()

                try await fixture.waitFor("both providers to register a process before connecting") {
                    fixture.children.count == 2 && fixture.children.allSatisfy { $0.registeredProviderPID != nil }
                }
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), enableGeneration)
                XCTAssertEqual(server.windowToolTransitionStartsByGenerationForTesting()[enableGeneration], 1)

                let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingRunIDs.count, 2)
                let held = try XCTUnwrap(fixture.child(forRunID: pendingRunIDs.first))
                let early = try XCTUnwrap(fixture.children.first { $0 !== held })
                let heldRunID = try XCTUnwrap(held.runID)
                let heldSlot = try fixture.slot(forRunID: heldRunID)
                let earlySlot = try fixture.slot(forRunID: XCTUnwrap(early.runID))
                let heldRun = try XCTUnwrap(runs.first { $0.slot == heldSlot })
                let earlyRun = try XCTUnwrap(runs.first { $0.slot == earlySlot })

                await early.allowConnection()
                let earlyCompletion = try await fixture.completion(of: earlyRun)
                try fixture.assertCommitted(earlyCompletion, by: early)

                // The older policy still waits for its own child: nothing the early run did
                // consumed it, observed it, or reached its tab.
                XCTAssertEqual(fixture.activeRunID(heldSlot), heldRunID)
                XCTAssertNil(held.admission)
                let heldWasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: heldRunID)
                XCTAssertFalse(heldWasObserved)
                let stillPendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(stillPendingRunIDs, [heldRunID])
                XCTAssertEqual(fixture.storedTab(heldSlot)?.promptText, "")
                XCTAssertEqual(fixture.storedTab(heldSlot)?.selection.selectedPaths, [])

                await held.allowConnection()
                let heldCompletion = try await fixture.completion(of: heldRun)
                try fixture.assertCommitted(heldCompletion, by: held)
                fixture.assertStoredTabMatchesSlot(earlySlot)

                try await fixture.waitFor("both runs to finish teardown") {
                    fixture.children.allSatisfy { child in
                        child.disposeCount > 0
                            && child.runID.map { !fixture.viewModel.isRunTeardownPendingForTesting(runID: $0) } == true
                    }
                }
                XCTAssertEqual(fixture.children.map(\.disposeCount), [1, 1])
                let leftoverPendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(leftoverPendingRunIDs, [])
                XCTAssertEqual(fixture.slots.map { fixture.operationToken($0) }, [nil, nil])
            }
        }
    }
#endif
