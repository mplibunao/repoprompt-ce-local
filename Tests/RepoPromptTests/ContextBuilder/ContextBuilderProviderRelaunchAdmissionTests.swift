import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// A provider that starts its CLI again inside one Context Builder run, routed through the
    /// run's own lease and one-shot policy, production pending-policy admission, and expected-PID
    /// run affinity by ``ContextBuilderRunFixture``.
    ///
    /// The Codex tests run the real ``CodexExecAgentProvider``: its attempt loop, its process
    /// runner, and its expected-PID registration. ``CodexCLIStandIn`` is the executable it
    /// launches, and a fixture child opens the MCP connection that process's helper would.
    @MainActor
    final class ContextBuilderProviderRelaunchAdmissionTests: XCTestCase {
        private typealias Admission = ContextBuilderProviderChild.Admission
        private typealias Writes = ContextBuilderProviderChild.Writes

        /// Start state: a Codex run on the first tab, whose first process connected on the run's
        /// one-shot policy and then died reporting that its model does not exist. The arming of
        /// the next policy is held, and the window now shows the second tab.
        ///
        /// The provider starts no second process while that arming is held, and starts one once
        /// it is released, with the policy pending. The second process's helper is another process
        /// family that connects with a session token of its own. It is admitted to the run, reads
        /// the first tab's inputs as the run froze them, and its writes are what the run commits
        /// to the first tab. The second tab is untouched.
        func testCodexExecRelaunchIsAdmittedToItsRunAndCommitsItsFrozenTab() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let first = await scenario.connectFirstHelper()

                let armingHold = await PolicyArmingHold.begin(cleanup: cleanup)
                try await scenario.endProcess(1, of: first, stderr: CodexCLIStandIn.modelNotFound)
                try await scenario.waitForPolicyArming(2)
                let pendingWhileArmingIsHeld = try await scenario.pendingPolicyRunIDs()
                XCTAssertEqual(pendingWhileArmingIsHeld, [])
                await scenario.assertNoLaunch(2, within: .milliseconds(300))

                await armingHold.release()
                let relaunch = try await scenario.cli.waitForLaunch(2, in: fixture)
                let pendingAtLaunch = try await scenario.pendingPolicyRunIDs()
                XCTAssertEqual(pendingAtLaunch, [scenario.runID], "The policy must be pending when its process is first seen.")
                XCTAssertNotEqual(relaunch.processID, scenario.firstLaunch.processID)
                XCTAssertNotEqual(relaunch.helperProcessID, scenario.firstLaunch.helperProcessID)
                XCTAssertEqual(fixture.activeRunID(scenario.runSlot), scenario.runID)

                // A connection that fell back to the tab the window shows would land on this one.
                await scenario.showOtherTab()
                let (relaunched, connectionError) = await scenario.connectHelper(
                    of: relaunch,
                    writes: Writes(readsTabFirst: true)
                )
                XCTAssertNotEqual(relaunched.sessionToken, first.sessionToken)
                let refusalReasons = await fixture.connectionRefusalReasons(forRunID: scenario.runID)
                XCTAssertEqual(refusalReasons, [], "The relaunched process's connection must be admitted to its run.")
                XCTAssertNil(connectionError)
                XCTAssertEqual(relaunched.admission, scenario.boundAdmission(of: relaunched))
                scenario.assertReadFrozenInputs(relaunched)
                scenario.assertOtherTabHoldsSeededInputs()

                try await scenario.endProcess(
                    2,
                    of: relaunched,
                    stdout: CodexCLIStandIn.reply(scenario.runSlot.agentOutput),
                    exitStatus: 0
                )
                let completion = try await fixture.completion(of: scenario.run)
                try fixture.assertCommitted(completion, by: relaunched)
                scenario.assertOtherTabHoldsSeededInputs()

                let events = await fixture.routingEventNames(forRunID: scenario.runID)
                let policyInstallations = events.indices.filter { events[$0] == "policy_installed" }
                let processRegistrations = events.indices.filter { events[$0] == "expected_pid_registered" }
                XCTAssertEqual(policyInstallations.count, 2, "One policy for the run's start and one for its relaunch.")
                XCTAssertEqual(processRegistrations.count, 2)
                if policyInstallations.count == 2, processRegistrations.count == 2 {
                    XCTAssertLessThan(policyInstallations[1], processRegistrations[1], "\(events)")
                }
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process died on a missing model and whose second,
        /// admitted on its own relaunch policy, died naming a broken MCP server. The provider starts
        /// a third process.
        ///
        /// The second process's policy is settled before the third's is armed, and the third's is
        /// armed before the third process is registered. The third process's helper is admitted
        /// to the run on the run's frozen tab, and the run commits what it wrote.
        func testCodexExecSettlesEachRelaunchPolicyBeforeItStartsTheNextProcess() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let first = await scenario.connectFirstHelper()
                try await scenario.endProcess(1, of: first, stderr: CodexCLIStandIn.modelNotFound)

                let secondLaunch = try await scenario.cli.waitForLaunch(2, in: fixture)
                await scenario.showOtherTab()
                let (second, secondConnectionError) = await scenario.connectHelper(
                    of: secondLaunch,
                    writes: CodexRunScenario.connectsOnly
                )
                XCTAssertNil(secondConnectionError)
                XCTAssertEqual(second.admission, scenario.boundAdmission(of: second))
                try await scenario.endProcess(
                    2,
                    of: second,
                    stderr: CodexCLIStandIn.brokenServer(named: "relaunch-fixture-\(UUID().uuidString)")
                )

                let thirdLaunch = try await scenario.cli.waitForLaunch(3, in: fixture)
                XCTAssertEqual(
                    Set([scenario.firstLaunch.processID, secondLaunch.processID, thirdLaunch.processID]).count,
                    3
                )
                let (third, thirdConnectionError) = await scenario.connectHelper(
                    of: thirdLaunch,
                    writes: Writes(readsTabFirst: true)
                )
                let refusalReasons = await fixture.connectionRefusalReasons(forRunID: scenario.runID)
                XCTAssertEqual(refusalReasons, [])
                XCTAssertNil(thirdConnectionError)
                XCTAssertEqual(third.admission, scenario.boundAdmission(of: third))
                scenario.assertReadFrozenInputs(third)

                try await scenario.endProcess(
                    3,
                    of: third,
                    stdout: CodexCLIStandIn.reply(scenario.runSlot.agentOutput),
                    exitStatus: 0
                )
                let completion = try await fixture.completion(of: scenario.run)
                try fixture.assertCommitted(completion, by: third)
                scenario.assertOtherTabHoldsSeededInputs()

                let events = await fixture.routingEventNames(forRunID: scenario.runID)
                let policyInstallations = events.indices.filter { events[$0] == "policy_installed" }
                let processRegistrations = events.indices.filter { events[$0] == "expected_pid_registered" }
                XCTAssertEqual(policyInstallations.count, 3, "One policy for the run's start and one for each relaunch.")
                XCTAssertEqual(processRegistrations.count, 3)
                if policyInstallations.count == 3, processRegistrations.count == 3 {
                    let settledBetween = events.indices.contains { index in
                        events[index] == "policy_cleared"
                            && index > processRegistrations[1]
                            && index < policyInstallations[2]
                    }
                    XCTAssertTrue(
                        settledBetween,
                        "The second process's policy must be settled before the third's is armed: \(events)"
                    )
                    XCTAssertLessThan(policyInstallations[1], processRegistrations[1])
                    XCTAssertLessThan(policyInstallations[2], processRegistrations[2])
                }
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process died on a missing model before it opened any
        /// connection. The provider starts a second process.
        ///
        /// The run's own one-shot policy and frozen tab context are still pending, so they admit
        /// and bind the second process's helper, and no policy is armed for the relaunch.
        func testCodexExecRelaunchBeforeTheFirstConnectionUsesTheRunsOwnPolicy() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                try scenario.cli.end(1, stdout: "", stderr: CodexCLIStandIn.modelNotFound, exitStatus: 1)

                let relaunch = try await scenario.cli.waitForLaunch(2, in: fixture)
                XCTAssertNotEqual(relaunch.processID, scenario.firstLaunch.processID)
                await scenario.showOtherTab()
                let (relaunched, connectionError) = await scenario.connectHelper(
                    of: relaunch,
                    writes: Writes(readsTabFirst: true)
                )
                XCTAssertNil(connectionError)
                XCTAssertEqual(relaunched.admission, scenario.boundAdmission(of: relaunched))
                scenario.assertReadFrozenInputs(relaunched)

                try await scenario.endProcess(
                    2,
                    of: relaunched,
                    stdout: CodexCLIStandIn.reply(scenario.runSlot.agentOutput),
                    exitStatus: 0
                )
                let completion = try await fixture.completion(of: scenario.run)
                try fixture.assertCommitted(completion, by: relaunched)
                scenario.assertOtherTabHoldsSeededInputs()

                let events = await fixture.routingEventNames(forRunID: scenario.runID)
                XCTAssertEqual(events.count(where: { $0 == "policy_installed" }), 1, "\(events)")
                let refusalReasons = await fixture.connectionRefusalReasons(forRunID: scenario.runID)
                XCTAssertEqual(refusalReasons, [])
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process connected and then died on a missing model,
        /// while two more pending policies for the run make the next policy's expected-PID arming
        /// ambiguous, so that arming fails. One alone would itself admit the next process.
        ///
        /// The provider starts no second process. The run fails with the relaunch error, and no
        /// policy, admission, or queued tab context is left for a later connection.
        func testCodexExecStartsNoProcessWhenItsRelaunchPolicyCannotBeArmed() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let first = await scenario.connectFirstHelper()
                for _ in 1 ... 2 {
                    await fixture.manager.installClientConnectionPolicy(
                        for: scenario.clientName,
                        windowID: fixture.window.windowID,
                        restrictedTools: DiscoverMCPToolPolicy.restrictedTools,
                        oneShot: true,
                        reason: "Relaunch arming fault",
                        ttl: 60,
                        runID: scenario.runID,
                        purpose: .discoverRun,
                        requiresExpectedAgentPID: true
                    )
                }

                try await scenario.endProcess(1, of: first, stderr: CodexCLIStandIn.modelNotFound)
                try await fixture.waitFor("the run to return", allowingRunErrors: true) {
                    scenario.run.result != nil
                }

                let disposition = try XCTUnwrap(scenario.run.result).get().terminalDisposition
                guard case let .failed(message) = disposition else {
                    return XCTFail("Expected the run to fail with the relaunch error, got \(disposition)")
                }
                let relaunchError = try XCTUnwrap(HeadlessAgentRelaunchError.admissionUnavailable.errorDescription)
                XCTAssertTrue(message.contains(relaunchError), message)
                try await scenario.assertNoRelaunchWasStarted()
                scenario.assertRunTabHoldsSeededInputs()
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process's helper is being admitted. It has reserved
        /// the run's one-shot policy and mapped the run's route, and is held before it consumes the
        /// policy. The first process then dies on a missing model.
        ///
        /// The reserved policy admits no other connection, and a policy armed beside it cannot be
        /// tied to one process, so that arming fails. The provider starts no second process and
        /// the run fails. Once the held admission is released, no connection was refused for
        /// descending from the run without a policy, and nothing is left pending.
        func testCodexExecStartsNoProcessWhileItsFirstConnectionHoldsTheRunsPolicyReserved() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let heldAdmission = try await scenario.holdFirstHelperAdmission(at: .policyReserved, cleanup: cleanup)
                let pendingWhileReserved = try await scenario.pendingPolicyRunIDs()
                XCTAssertEqual(pendingWhileReserved, [scenario.runID])

                try scenario.cli.end(1, stdout: "", stderr: CodexCLIStandIn.modelNotFound, exitStatus: 1)
                try await fixture.waitFor("the run to return or a second process to start", allowingRunErrors: true) {
                    scenario.run.result != nil || scenario.cli.launch(2) != nil
                }
                guard scenario.cli.launch(2) == nil else {
                    return XCTFail("The provider started a second process on a policy its first connection holds reserved.")
                }
                let events = await fixture.routingEventNames(forRunID: scenario.runID)
                XCTAssertEqual(
                    events.count(where: { $0 == "policy_installed" }),
                    2,
                    "The provider must arm a policy instead of relying on the reserved one: \(events)"
                )

                let disposition = try XCTUnwrap(scenario.run.result).get().terminalDisposition
                guard case let .failed(message) = disposition else {
                    return XCTFail("Expected the run to fail, got \(disposition)")
                }
                // The failed arming also ends the run's wait for its first route, and either
                // failure can be the one the run reports.
                let relaunchError = try XCTUnwrap(HeadlessAgentRelaunchError.admissionUnavailable.errorDescription)
                XCTAssertTrue(message.contains(relaunchError) || message.contains("mcp_routing_failed"), message)

                _ = await heldAdmission.release()
                let refusalReasons = await fixture.connectionRefusalReasons(forRunID: scenario.runID)
                XCTAssertFalse(
                    refusalReasons.contains(BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason),
                    "\(refusalReasons)"
                )
                try await scenario.assertNoRelaunchWasStarted()
                scenario.assertRunTabHoldsSeededInputs()
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process's helper has consumed the run's one-shot
        /// policy and committed its route, and is held before the run is told it was routed. The
        /// first process then dies on a missing model.
        ///
        /// The consumed policy admits no other connection, so the provider arms a fresh one before
        /// it starts the second process, while the run still has no routing outcome. The second
        /// process's helper is admitted to the run on the run's frozen tab, and the run commits what
        /// it wrote.
        func testCodexExecRelaunchIsArmedOnceTheRunsPolicyIsConsumedBeforeTheRunIsToldItWasRouted() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let heldAdmission = try await scenario.holdFirstHelperAdmission(at: .routeCommitted, cleanup: cleanup)
                let pendingOnceConsumed = try await scenario.pendingPolicyRunIDs()
                XCTAssertEqual(pendingOnceConsumed, [])

                try scenario.cli.end(1, stdout: "", stderr: CodexCLIStandIn.modelNotFound, exitStatus: 1)
                let relaunch = try await scenario.cli.waitForLaunch(2, in: fixture)
                let pendingAtLaunch = try await scenario.pendingPolicyRunIDs()
                XCTAssertEqual(pendingAtLaunch, [scenario.runID], "The policy must be pending when its process is first seen.")
                let routingOutcomeAtLaunch = await MCPRoutingWaiter.currentTerminalOutcome(runID: scenario.runID)
                XCTAssertNil(routingOutcomeAtLaunch, "The run must not have been told it was routed.")
                let isHeldAtLaunch = await heldAdmission.isHeld()
                XCTAssertTrue(isHeldAtLaunch)

                let (first, firstConnectionError) = await heldAdmission.release()
                XCTAssertNil(firstConnectionError)
                XCTAssertEqual(first.admission, scenario.boundAdmission(of: first))
                try await scenario.dropConnection(of: first)

                // A connection that fell back to the tab the window shows would land on this one.
                await scenario.showOtherTab()
                let (relaunched, connectionError) = await scenario.connectHelper(
                    of: relaunch,
                    writes: Writes(readsTabFirst: true)
                )
                let refusalReasons = await fixture.connectionRefusalReasons(forRunID: scenario.runID)
                XCTAssertEqual(refusalReasons, [], "The relaunched process's connection must be admitted to its run.")
                XCTAssertNil(connectionError)
                XCTAssertEqual(relaunched.admission, scenario.boundAdmission(of: relaunched))
                scenario.assertReadFrozenInputs(relaunched)

                try await scenario.endProcess(
                    2,
                    of: relaunched,
                    stdout: CodexCLIStandIn.reply(scenario.runSlot.agentOutput),
                    exitStatus: 0
                )
                let completion = try await fixture.completion(of: scenario.run)
                try fixture.assertCommitted(completion, by: relaunched)
                scenario.assertOtherTabHoldsSeededInputs()

                let events = await fixture.routingEventNames(forRunID: scenario.runID)
                let policyInstallations = events.indices.filter { events[$0] == "policy_installed" }
                let processRegistrations = events.indices.filter { events[$0] == "expected_pid_registered" }
                XCTAssertEqual(policyInstallations.count, 2, "One policy for the run's start and one for its relaunch.")
                XCTAssertEqual(processRegistrations.count, 2)
                if policyInstallations.count == 2, processRegistrations.count == 2 {
                    XCTAssertLessThan(policyInstallations[1], processRegistrations[1], "\(events)")
                }
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process connected and then died on a missing model.
        /// The arming of the next policy is held, and the run is cancelled while it waits.
        ///
        /// The run ends as cancelled. The provider starts no second process, also once the arming
        /// is released, and no policy, admission, or queued tab context is left behind.
        func testCodexExecStartsNoProcessWhenItsRunIsCancelledWhileItsRelaunchPolicyIsArming() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let first = await scenario.connectFirstHelper()

                let armingHold = await PolicyArmingHold.begin(cleanup: cleanup)
                try await scenario.endProcess(1, of: first, stderr: CodexCLIStandIn.modelNotFound)
                try await scenario.waitForPolicyArming(2)
                XCTAssertTrue(ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: scenario.runID))

                await fixture.viewModel.cancelMCPContextBuilderRun(forTabID: scenario.runSlot.tabID)
                try await fixture.waitFor("the cancelled run to return", allowingRunErrors: true) {
                    scenario.run.result != nil
                }
                XCTAssertThrowsError(try XCTUnwrap(scenario.run.result).get()) { error in
                    XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
                }
                try await fixture.waitFor("the held arming to be settled", allowingRunErrors: true) {
                    !ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: scenario.runID)
                }

                await armingHold.release()
                await scenario.assertNoLaunch(2, within: .milliseconds(300))
                try await scenario.assertNoRelaunchWasStarted()
                scenario.assertRunTabHoldsSeededInputs()
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process died on a missing model while the app still
        /// holds that process's connection. The second process's helper has been admitted to the run,
        /// bound to its tab, and has written there.
        ///
        /// The app then drops the first process's connection. The second stays the run's
        /// connection on the run's tab, and the run commits what the second wrote.
        func testFirstConnectionDroppedAfterTheRelaunchedOneIsBoundLeavesItsContext() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let first = await scenario.connectFirstHelper()
                try scenario.cli.end(1, stdout: "", stderr: CodexCLIStandIn.modelNotFound, exitStatus: 1)

                let relaunch = try await scenario.cli.waitForLaunch(2, in: fixture)
                await scenario.showOtherTab()
                let (relaunched, connectionError) = await scenario.connectHelper(
                    of: relaunch,
                    writes: Writes(readsTabFirst: true)
                )
                XCTAssertNil(connectionError)
                XCTAssertEqual(relaunched.admission, scenario.boundAdmission(of: relaunched))
                scenario.assertReadFrozenInputs(relaunched)

                try await scenario.dropConnection(of: first)
                XCTAssertEqual(fixture.window.mcpServer.connectionID(forRunID: scenario.runID), relaunched.connectionID)
                XCTAssertEqual(
                    fixture.window.mcpServer.tabContextByConnectionID[relaunched.connectionID]?.tabID,
                    scenario.runSlot.tabID
                )

                try await scenario.endProcess(
                    2,
                    of: relaunched,
                    stdout: CodexCLIStandIn.reply(scenario.runSlot.agentOutput),
                    exitStatus: 0
                )
                let completion = try await fixture.completion(of: scenario.run)
                try fixture.assertCommitted(completion, by: relaunched)
                scenario.assertOtherTabHoldsSeededInputs()
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a Codex run whose first process died on a missing model while the app still
        /// holds that process's connection. The second process's helper has been admitted to the
        /// run, has written the run's context on its tab, and has then disconnected while its
        /// process is still running, which leaves the app holding its snapshot of that context
        /// detached for the run.
        ///
        /// The app then drops the first helper's connection. The detached snapshot is still the
        /// second helper's, and it is what the run commits once the second process has ended.
        func testFirstConnectionDroppedAfterTheRelaunchedOneDetachedLeavesItsContext() async throws {
            try await ContextBuilderRunFixture.withFixture(seedsTabs: true) { fixture, cleanup in
                let scenario = try await CodexRunScenario.start(in: fixture, cleanup: cleanup)
                let first = await scenario.connectFirstHelper()
                try scenario.cli.end(1, stdout: "", stderr: CodexCLIStandIn.modelNotFound, exitStatus: 1)

                let relaunch = try await scenario.cli.waitForLaunch(2, in: fixture)
                await scenario.showOtherTab()
                let (relaunched, connectionError) = await scenario.connectHelper(
                    of: relaunch,
                    writes: Writes(readsTabFirst: true)
                )
                XCTAssertNil(connectionError)
                XCTAssertEqual(relaunched.admission, scenario.boundAdmission(of: relaunched))

                try await scenario.dropConnection(of: relaunched)
                XCTAssertTrue(
                    fixture.window.mcpServer.isDetachedContextBuilderConnection(
                        connectionID: relaunched.connectionID,
                        runID: scenario.runID
                    )
                )
                try await scenario.dropConnection(of: first)
                XCTAssertTrue(
                    fixture.window.mcpServer.isDetachedContextBuilderConnection(
                        connectionID: relaunched.connectionID,
                        runID: scenario.runID
                    )
                )

                try scenario.cli.end(
                    2,
                    stdout: CodexCLIStandIn.reply(scenario.runSlot.agentOutput),
                    stderr: "",
                    exitStatus: 0
                )
                let completion = try await fixture.completion(of: scenario.run)
                try fixture.assertCommitted(completion, by: relaunched)
                scenario.assertOtherTabHoldsSeededInputs()
                try await scenario.assertNothingLeftPending()
            }
        }

        /// Start state: a run whose provider's first process connected on the run's one-shot policy
        /// and exited, and whose provider then starts a second process without arming anything for
        /// it.
        ///
        /// That process's connection is refused although it descends from a process registered for
        /// the run, the refusal installs no policy that would admit it or a later one, and the run
        /// fails with the refusal.
        func testRelaunchThatArmsNoPolicyIsRefusedAndInstallsNone() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let slot = fixture.slots[0]
                let clientName = try XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint)
                var relaunchingProvider: ContextBuilderRelaunchingProvider?
                fixture.providerScript = { [unowned fixture] request in
                    let provider = fixture.makeRelaunchingProvider(for: request)
                    relaunchingProvider = provider
                    return provider
                }

                let run = fixture.startMCPRun(on: slot, agentKind: .codexExec)
                try await fixture.waitFor("the first process to connect") {
                    relaunchingProvider?.firstProcess.admission != nil
                }
                let provider = try XCTUnwrap(relaunchingProvider)
                let first = provider.firstProcess
                let relaunched = provider.relaunchedProcess
                let runID = try XCTUnwrap(fixture.activeRunID(slot))
                XCTAssertEqual(
                    first.admission,
                    Admission(routedRunID: runID, runConnectionID: first.connectionID, boundTabID: slot.tabID)
                )

                await provider.exitFirstProcess()
                try await fixture.waitFor("the app to drop the exited process's connection") {
                    await fixture.manager.runIDForConnection(first.connectionID) == nil
                        && fixture.window.mcpServer.connectionID(forRunID: runID) == nil
                }
                try await fixture.waitFor("the relaunched process to be registered for the run") {
                    relaunched.registeredProviderPID != nil
                }
                XCTAssertNotEqual(relaunched.registeredProviderPID, first.registeredProviderPID)
                XCTAssertNotEqual(relaunched.sessionToken, first.sessionToken)
                let pendingBeforeRelaunchConnects = try await fixture.pendingPolicyRunIDs(clientName: clientName)
                XCTAssertEqual(pendingBeforeRelaunchConnects, [])

                await relaunched.allowConnection()
                try await fixture.waitFor("the run to return", allowingRunErrors: true) {
                    run.result != nil
                }

                let refusalReasons = await fixture.connectionRefusalReasons(forRunID: runID)
                XCTAssertEqual(refusalReasons, [BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason])
                XCTAssertNil(relaunched.admission)
                let pendingAfterRefusal = try await fixture.pendingPolicyRunIDs(clientName: clientName)
                XCTAssertEqual(pendingAfterRefusal, [], "A refused connection must not arm a policy.")
                let disposition = try XCTUnwrap(run.result).get().terminalDisposition
                guard case let .failed(message) = disposition else {
                    return XCTFail("Expected the run to fail with the refusal, got \(disposition)")
                }
                XCTAssertTrue(
                    message.contains(BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason),
                    message
                )
                XCTAssertEqual(fixture.storedTab(slot)?.promptText, "")
                XCTAssertNil(fixture.operationToken(slot))
            }
        }

        /// Start state: a run whose provider's first process connected and exited, with the app
        /// part-way through removing that process's connection: the connection manager has let
        /// go of the connection's run, and the window still maps the run to the connection.
        ///
        /// Looking up the connection's run at that point leaves nothing behind. Once the removal
        /// completes, the connection manager maps the connection to no run.
        func testRunLookupWhileTheExitedProcesssConnectionIsBeingRemovedLeavesItUnmapped() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let slot = fixture.slots[0]
                var relaunchingProvider: ContextBuilderRelaunchingProvider?
                fixture.providerScript = { [unowned fixture] request in
                    let provider = fixture.makeRelaunchingProvider(for: request)
                    relaunchingProvider = provider
                    return provider
                }

                _ = fixture.startMCPRun(on: slot, agentKind: .codexExec)
                try await fixture.waitFor("the first process to connect") {
                    relaunchingProvider?.firstProcess.admission != nil
                }
                let provider = try XCTUnwrap(relaunchingProvider)
                let firstConnectionID = provider.firstProcess.connectionID
                let runID = try XCTUnwrap(fixture.activeRunID(slot))

                // A removal scans for the connection's active tools right after the connection
                // manager lets go of the connection's run and before the window is asked to.
                let removal = ContextBuilderTestGate()
                cleanup.add { await fixture.manager.debugSetBeforeActiveToolCancellationScanForTesting(nil) }
                await fixture.manager.debugSetBeforeActiveToolCancellationScanForTesting { connectionID, _ in
                    guard connectionID == firstConnectionID else { return }
                    await removal.wait()
                }
                fixture.releaseOnSettle { await removal.open() }
                cleanup.add { await removal.open() }

                await provider.exitFirstProcess()
                try await fixture.waitFor("the removal of the exited process's connection to be held") {
                    await removal.entered
                }
                XCTAssertEqual(fixture.window.mcpServer.connectionID(forRunID: runID), firstConnectionID)
                _ = await fixture.manager.runIDForConnection(firstConnectionID)

                await removal.open()
                try await fixture.waitFor("the removal to complete") {
                    await fixture.routingEventNames(forRunID: runID)
                        .contains("context_builder.tab_context_detach_published")
                }
                XCTAssertNil(fixture.window.mcpServer.connectionID(forRunID: runID))
                let mappedRunID = await fixture.manager.runIDForConnection(firstConnectionID)
                XCTAssertNil(mappedRunID)
            }
        }
    }

    /// A Codex run on the fixture's first tab whose provider is the real one, started and brought
    /// to the point where its first process is running.
    @MainActor
    private struct CodexRunScenario {
        typealias Admission = ContextBuilderProviderChild.Admission
        typealias Writes = ContextBuilderProviderChild.Writes

        static let connectsOnly = Writes(setsPrompt: false, setsSelection: false, repliesWithOutput: false)

        let fixture: ContextBuilderRunFixture
        let cli: CodexCLIStandIn
        let clientName: String
        let run: ContextBuilderRunFixture.MCPRun
        let runID: UUID
        let firstLaunch: CodexCLIStandIn.Launch

        var runSlot: ContextBuilderRunFixture.TabSlot {
            fixture.slots[0]
        }

        /// The tab the window shows once ``showOtherTab()`` has run.
        var otherSlot: ContextBuilderRunFixture.TabSlot {
            fixture.slots[1]
        }

        static func start(
            in fixture: ContextBuilderRunFixture,
            cleanup: FixtureCleanup
        ) async throws -> CodexRunScenario {
            let cli = try CodexCLIStandIn.install(cleanup: cleanup)
            // The provider starts no process while the MCP server is not running.
            await fixture.manager.debugEnsureRunningLifecycleForSocketFixture()
            fixture.providerScript = { _ in cli.makeProvider() }
            let run = fixture.startMCPRun(on: fixture.slots[0], agentKind: .codexExec)
            let firstLaunch = try await cli.waitForLaunch(1, in: fixture)
            return try CodexRunScenario(
                fixture: fixture,
                cli: cli,
                clientName: XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint),
                run: run,
                runID: XCTUnwrap(fixture.activeRunID(fixture.slots[0])),
                firstLaunch: firstLaunch
            )
        }

        // MARK: Steps

        /// Opens the connection the helper of `launch` would. A refusal is returned beside what
        /// the app recorded for it instead of ending the scenario.
        func connectHelper(
            of launch: CodexCLIStandIn.Launch,
            writes: Writes
        ) async -> (helper: ContextBuilderProviderChild, error: String?) {
            let helper = fixture.makeHelperChild(for: .codexExec, writes: writes)
            do {
                try await helper.serve(runID: runID, asHelperPID: launch.helperProcessID)
                return (helper, nil)
            } catch {
                return (helper, error.localizedDescription)
            }
        }

        /// Starts the first process's helper connecting on the run's own policy, and returns once
        /// the app holds that connection's admission at `point`.
        func holdFirstHelperAdmission(
            at point: HeldAdmission.Point,
            cleanup: FixtureCleanup,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> HeldAdmission {
            let held = await HeldAdmission.begin(at: point, manager: fixture.manager) {
                await connectHelper(of: firstLaunch, writes: Self.connectsOnly)
            }
            cleanup.add { _ = await held.release() }
            try await fixture.waitFor("the first connection's admission to be held", file: file, line: line) {
                await held.isHeld()
            }
            return held
        }

        /// Connects the first process's helper on the run's own policy. It makes no tool call.
        func connectFirstHelper(file: StaticString = #filePath, line: UInt = #line) async -> ContextBuilderProviderChild {
            let (helper, error) = await connectHelper(of: firstLaunch, writes: Self.connectsOnly)
            XCTAssertNil(error, file: file, line: line)
            XCTAssertEqual(helper.admission, boundAdmission(of: helper), file: file, line: line)
            return helper
        }

        /// `helper` is the run's connection, bound to the run's tab.
        func boundAdmission(of helper: ContextBuilderProviderChild) -> Admission {
            Admission(routedRunID: runID, runConnectionID: helper.connectionID, boundTabID: runSlot.tabID)
        }

        /// Closes `helper`'s socket, as the death of its process does, and waits until the app has
        /// finished removing that connection.
        func dropConnection(
            of helper: ContextBuilderProviderChild,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            helper.closeAsProcessExit()
            let manager = fixture.manager
            let connectionID = helper.connectionID
            try await fixture.waitFor("the app to drop a Codex process's connection", file: file, line: line) {
                let mappedRunID = await manager.runIDForConnection(connectionID)
                let processIdentity = await manager.debugBootstrapProcessIdentityForTesting(connectionID: connectionID)
                return mappedRunID == nil
                    && processIdentity == nil
                    && fixture.window.mcpServer.connectionID(forRunID: runID) != connectionID
            }
        }

        /// Ends a Codex process as its exit does: the app drops its helper's connection, and the
        /// process prints its last output and exits.
        func endProcess(
            _ number: Int,
            of helper: ContextBuilderProviderChild,
            stdout: String = "",
            stderr: String = "",
            exitStatus: Int32 = 1,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            try await dropConnection(of: helper, file: file, line: line)
            try cli.end(number, stdout: stdout, stderr: stderr, exitStatus: exitStatus)
        }

        func showOtherTab() async {
            await fixture.window.promptManager.switchComposeTab(otherSlot.tabID)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, otherSlot.tabID)
        }

        /// Waits until the run's `count`th policy has begun arming.
        func waitForPolicyArming(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
            try await fixture.waitFor("policy \(count) of the run to begin arming", file: file, line: line) {
                await fixture.routingEventNames(forRunID: runID).count(where: { $0 == "lease_gate_wait_started" }) == count
            }
        }

        func pendingPolicyRunIDs() async throws -> [UUID] {
            try await fixture.pendingPolicyRunIDs(clientName: clientName)
        }

        // MARK: Assertions

        /// The provider starts no `number`th Codex process for as long as `window` lasts.
        func assertNoLaunch(
            _ number: Int,
            within window: Duration,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: window)
            while clock.now < deadline {
                guard cli.launch(number) == nil else {
                    return XCTFail("The provider started Codex process \(number).", file: file, line: line)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// The first process is the only one the provider started and registered for the run.
        func assertNoRelaunchWasStarted(file: StaticString = #filePath, line: UInt = #line) async throws {
            XCTAssertNil(cli.launch(2), file: file, line: line)
            let events = await fixture.routingEventNames(forRunID: runID)
            XCTAssertEqual(events.count(where: { $0 == "expected_pid_registered" }), 1, "\(events)", file: file, line: line)
        }

        /// `helper` read the run tab's prompt and selection as they were when the run started,
        /// and nothing of the other tab's.
        func assertReadFrozenInputs(
            _ helper: ContextBuilderProviderChild,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard let read = helper.tabReadBeforeWriting else {
                return XCTFail("The helper read nothing from its tab.", file: file, line: line)
            }
            XCTAssertTrue(read.prompt.contains(runSlot.seededPromptText), read.prompt, file: file, line: line)
            XCTAssertFalse(read.prompt.contains(otherSlot.seededPromptText), read.prompt, file: file, line: line)
            XCTAssertTrue(
                read.selection.contains(runSlot.seededFileURL.lastPathComponent),
                read.selection,
                file: file,
                line: line
            )
            XCTAssertFalse(
                read.selection.contains(otherSlot.seededFileURL.lastPathComponent),
                read.selection,
                file: file,
                line: line
            )
        }

        func assertOtherTabHoldsSeededInputs(file: StaticString = #filePath, line: UInt = #line) {
            assertHoldsSeededInputs(otherSlot, file: file, line: line)
        }

        func assertRunTabHoldsSeededInputs(file: StaticString = #filePath, line: UInt = #line) {
            assertHoldsSeededInputs(runSlot, file: file, line: line)
        }

        private func assertHoldsSeededInputs(
            _ slot: ContextBuilderRunFixture.TabSlot,
            file: StaticString,
            line: UInt
        ) {
            let stored = fixture.storedTab(slot)
            XCTAssertEqual(stored?.promptText, slot.seededPromptText, file: file, line: line)
            XCTAssertEqual(stored?.selection.selectedPaths, [slot.seededFileURL.path], file: file, line: line)
        }

        /// The run left no pending policy, unsettled relaunch admission, queued tab context, or
        /// claim on its tab.
        func assertNothingLeftPending(file: StaticString = #filePath, line: UInt = #line) async throws {
            let leftoverPendingRunIDs = try await pendingPolicyRunIDs()
            XCTAssertEqual(leftoverPendingRunIDs, [], file: file, line: line)
            XCTAssertFalse(
                ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: runID),
                file: file,
                line: line
            )
            XCTAssertFalse(
                fixture.window.mcpServer.pendingRunScopedTabContexts.contains(clientName: clientName, runID: runID),
                file: file,
                line: line
            )
            XCTAssertNil(fixture.operationToken(runSlot), file: file, line: line)
        }
    }

    /// A helper's connection whose admission the app holds partway, with its `initialize` still
    /// unanswered.
    @MainActor
    private struct HeldAdmission {
        typealias Connection = (helper: ContextBuilderProviderChild, error: String?)

        enum Point {
            /// The connection has reserved the run's one-shot policy and mapped the run's route, and
            /// has not consumed the policy.
            case policyReserved
            /// The connection has consumed the policy and committed its route, and the run's
            /// routing waiters have not been told.
            case routeCommitted
        }

        private let point: Point
        private let manager: ServerNetworkManager
        private let connecting: Task<Connection, Never>

        static func begin(
            at point: Point,
            manager: ServerNetworkManager,
            connect: @escaping @MainActor () async -> Connection
        ) async -> HeldAdmission {
            switch point {
            case .policyReserved: await manager.debugSuspendNextPendingPolicyCommit()
            case .routeCommitted: await manager.debugSuspendNextPendingPolicyRoutedNotification()
            }
            return HeldAdmission(point: point, manager: manager, connecting: Task { await connect() })
        }

        func isHeld() async -> Bool {
            switch point {
            case .policyReserved: await manager.debugIsPendingPolicyCommitSuspended()
            case .routeCommitted: await manager.debugIsPendingPolicyRoutedNotificationSuspended()
            }
        }

        /// Lets the admission run to its end, and returns the helper with the error its connection
        /// ended in, if any.
        func release() async -> Connection {
            switch point {
            case .policyReserved: await manager.debugResumePendingPolicyCommit()
            case .routeCommitted: await manager.debugResumePendingPolicyRoutedNotification()
            }
            return await connecting.value
        }
    }

    /// Holds the gate every policy installation passes through, so the arming of a policy stops
    /// before it installs anything until the hold is released.
    @MainActor
    private struct PolicyArmingHold {
        private let gateID = UUID()

        static func begin(cleanup: FixtureCleanup) async -> PolicyArmingHold {
            let hold = PolicyArmingHold()
            let acquired = await HeadlessAgentConnectionGate.acquire(hold.gateID)
            XCTAssertTrue(acquired)
            cleanup.add { await hold.release() }
            return hold
        }

        func release() async {
            _ = await HeadlessAgentConnectionGate.completeIfActive(gateID)
        }
    }

    /// A stand-in for the `codex` executable, launched by the real ``CodexExecAgentProvider``
    /// through its own process runner. Each launch records its PID and the PID of a child that
    /// stands in for the MCP helper Codex starts, then waits for the test to say how it ends.
    @MainActor
    private struct CodexCLIStandIn {
        struct Launch: Equatable {
            let processID: pid_t
            let helperProcessID: pid_t
        }

        /// A model the provider replaces after Codex reports it missing.
        static let unavailableModel = "gpt-5.3-codex"
        static let modelNotFound = "stream error: unexpected status 404 Not Found: model_not_found\n"

        let directory: URL

        var executableURL: URL {
            directory.appendingPathComponent("codex")
        }

        static func install(cleanup: FixtureCleanup) throws -> CodexCLIStandIn {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexCLIStandIn-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Removing the directory also ends a launch that is still waiting.
            cleanup.add { try? FileManager.default.removeItem(at: directory) }
            let standIn = CodexCLIStandIn(directory: directory)
            try script.write(to: standIn.executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: standIn.executableURL.path
            )
            return standIn
        }

        static func brokenServer(named name: String) -> String {
            "MCP client for `\(name)` failed to start: request timed out\n"
        }

        /// What `codex exec --json` prints for a turn that replied with `text`.
        static func reply(_ text: String) throws -> String {
            let message: [String: Any] = ["type": "item.completed", "item": ["type": "agent_message", "text": text]]
            let line = try String(decoding: JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            return line + "\n{\"type\":\"turn.completed\"}\n"
        }

        /// The isolated-state preparer is skipped: it projects the user's own Codex instructions.
        func makeProvider() -> CodexExecAgentProvider {
            CodexExecAgentProvider(
                config: CodexExecAgentConfig(
                    commandName: executableURL.path,
                    additionalPathHints: [],
                    modelString: Self.unavailableModel
                ),
                runtimeStatePreparer: { _ in }
            )
        }

        func launch(_ number: Int) -> Launch? {
            guard let text = try? String(contentsOf: file("launch", number), encoding: .utf8) else { return nil }
            let processIDs = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            return processIDs.count == 2 ? Launch(processID: processIDs[0], helperProcessID: processIDs[1]) : nil
        }

        func waitForLaunch(
            _ number: Int,
            in fixture: ContextBuilderRunFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> Launch {
            try await fixture.waitFor("the provider to start Codex process \(number)", file: file, line: line) {
                launch(number) != nil
            }
            return try XCTUnwrap(launch(number), file: file, line: line)
        }

        /// Lets the `number`th launch print `stdout` and `stderr` and exit with `exitStatus`.
        func end(_ number: Int, stdout: String, stderr: String, exitStatus: Int32) throws {
            try stdout.write(to: file("stdout", number), atomically: true, encoding: .utf8)
            try stderr.write(to: file("stderr", number), atomically: true, encoding: .utf8)
            try String(exitStatus).write(to: file("exit", number), atomically: true, encoding: .utf8)
        }

        private func file(_ name: String, _ number: Int) -> URL {
            directory.appendingPathComponent("\(name)-\(number)")
        }

        private static let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            echo "codex-cli 0.159.0"
            exit 0
        fi
        dir=$(/usr/bin/dirname "$0")
        /bin/cat > /dev/null
        number=1
        while [ -e "$dir/launch-$number" ]; do number=$((number + 1)); done
        /bin/sleep 120 < /dev/null > /dev/null 2>&1 &
        helper=$!
        trap 'kill "$helper" 2>/dev/null' EXIT
        trap 'exit 1' TERM INT
        echo "$$ $helper" > "$dir/launch-$number.partial"
        /bin/mv "$dir/launch-$number.partial" "$dir/launch-$number"
        until [ -e "$dir/exit-$number" ]; do
            [ -d "$dir" ] || exit 1
            /bin/sleep 0.05
        done
        /bin/cat "$dir/stdout-$number"
        /bin/cat "$dir/stderr-$number" >&2
        exit "$(/bin/cat "$dir/exit-$number")"

        """
    }
#endif
