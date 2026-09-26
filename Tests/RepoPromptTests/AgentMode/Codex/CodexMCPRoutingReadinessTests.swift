import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

#if DEBUG
    /// The pre-first-turn MCP routing boundary for a Codex child. A child whose RepoPrompt MCP
    /// routing confirms dispatches its first turn exactly once; one whose routing never confirms
    /// fails closed with one precise failed publication, no first turn, and no leftover bootstrap
    /// gate, routing waiter, or pending connection policy; a start cancelled during the routing wait
    /// dispatches nothing and reports no readiness failure.
    ///
    /// Starts go through the real submission path, run service, runner, coordinator, terminal
    /// barrier, `MCPBootstrapLease`, `HeadlessAgentConnectionGate`, and `ServerNetworkManager`
    /// policy machinery, with a fake Codex controller whose child never connects MCP. That machinery
    /// is process-global, so each test holds `MCPSharedServerTestLease` through its cleanup, uses a
    /// window no other suite uses, and cleans up only the run policies it installed.
    @MainActor
    final class CodexMCPRoutingReadinessTests: XCTestCase {
        private let testWindowID = 5_140_514
        private let codexClientName = AgentProviderKind.codexExec.mcpClientNameHint ?? "RepoPromptCE"
        private let routingTimeoutMessage = "Codex startup failed: MCP routing timed out before a child connection was observed."
        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexMCPRoutingReadinessTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        func testRoutedStartupDispatchesTheFirstTurnOnce() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: true) { fixture in
                let ticket = try fixture.submit("first")
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.controller.startUserTurnTexts, ["first"])
                XCTAssertEqual(ticket.phase, .accepted)
                XCTAssertEqual(fixture.errorTexts, [])
                XCTAssertEqual(fixture.session.runState, .running)
                XCTAssertEqual(fixture.publishedStates, [], "an in-flight routed turn published a terminal state")
                let runID = try XCTUnwrap(fixture.policies.runIDs.first)
                XCTAssertEqual(fixture.policies.runIDs, [runID], "the start installed more than one run policy")
                XCTAssertEqual(fixture.session.runID, runID)
            }
        }

        func testUnroutedStartupFailsOnceWithoutLeakingBootstrapState() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: false) { fixture in
                let ticket = try fixture.submit("first")
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.controller.startOrResumeCount, 1)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [], "the first turn fired without routing")
                XCTAssertEqual(ticket.phase, .rejected)
                XCTAssertEqual(fixture.errorTexts, [routingTimeoutMessage])
                XCTAssertEqual(fixture.publishedStates, [.failed])
                XCTAssertEqual(fixture.session.runState, .failed)
                XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.failureReason, .timeout)
                XCTAssertNil(fixture.session.codexController, "the unrouted controller was kept")

                let runID = try XCTUnwrap(fixture.policies.runIDs.first)
                try await assertNoBootstrapStateRemains(for: runID)
            }
        }

        func testCancellingTheRoutingWaitDispatchesNothingAndReportsNoFailure() async throws {
            // A routing timeout far beyond the test, so cancellation rather than the timeout ends
            // the wait.
            try await withRoutingFixture(routesOnPolicyInstall: false, routingTimeoutMs: 60000) { fixture in
                let ticket = try fixture.submit("first")
                let runID = try await awaitRoutingWait(fixture)

                await startupTestAwaitBounded("cancellation did not finish") {
                    await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
                }
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.controller.startUserTurnTexts, [], "a cancelled routing wait reached the first turn")
                XCTAssertEqual(ticket.phase, .cancelled)
                XCTAssertEqual(fixture.errorTexts, [], "cancellation was reported as a readiness failure")
                XCTAssertEqual(fixture.publishedStates, [.cancelled])
                XCTAssertEqual(fixture.session.runState, .cancelled)
                try await assertNoBootstrapStateRemains(for: runID)
            }
        }

        func testUnroutedResumeFailsOnceAsAResumedStart() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: false) { fixture in
                startupTestInstallSavedCodexHistory(on: fixture.session, conversationID: "resume-thread", rolloutPath: nil)

                let ticket = try fixture.submit("next")
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.controller.startOrResumeTargets.map { $0?.conversationID }, ["resume-thread"])
                XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumed)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
                XCTAssertEqual(fixture.errorTexts, [routingTimeoutMessage])
                XCTAssertEqual(fixture.publishedStates, [.failed])
                XCTAssertEqual(fixture.session.runState, .failed)
            }
        }

        func testUnroutedResumeThatFellBackToAFreshThreadFailsOnceAsAFallback() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: false) { fixture in
                startupTestInstallSavedCodexHistory(
                    on: fixture.session,
                    conversationID: "missing-rollout-thread",
                    rolloutPath: "/missing/rollout.jsonl"
                )
                fixture.controller.startupHook = { target in
                    guard target != nil else { return }
                    throw NSError(
                        domain: "CodexMCPRoutingReadinessTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "failed to load rollout: no such file"]
                    )
                }

                let ticket = try fixture.submit("next")
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(
                    fixture.controller.startOrResumeTargets.map { $0?.conversationID },
                    ["missing-rollout-thread", nil]
                )
                XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumeFellBackToFresh)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
                XCTAssertEqual(fixture.errorTexts, [routingTimeoutMessage])
                XCTAssertEqual(fixture.publishedStates, [.failed])
                XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .system }), 1, "the fallback was not announced once")
            }
        }

        /// Without managed tooling there is no lease and no routing wait; a native start failure
        /// still reports its own phase.
        func testUnmanagedToolingNativeStartFailureKeepsItsPhase() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: false, shouldManageCodexTooling: false) { fixture in
                fixture.controller.startupError = NSError(
                    domain: "CodexMCPRoutingReadinessTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "app-server exited"]
                )

                let ticket = try fixture.submit("first")
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.policies.runIDs, [], "unmanaged tooling installed a run policy")
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
                XCTAssertEqual(fixture.errorTexts, ["Codex native start failed: app-server exited"])
                XCTAssertEqual(fixture.publishedStates, [.failed])
                XCTAssertEqual(fixture.session.runState, .failed)
            }
        }

        // MARK: - Harness

        /// Records the run of every connection policy the lease installs, so cleanup revokes only
        /// this test's policies.
        private final class PolicyInstallRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var installedRunIDs: [UUID] = []

            func record(_ runID: UUID) {
                lock.withLock { installedRunIDs.append(runID) }
            }

            var runIDs: [UUID] {
                lock.withLock { installedRunIDs }
            }
        }

        @MainActor
        private final class RoutingFixture: StartupTestSessionFixture {
            let policies: PolicyInstallRecorder
            private let publications = StartupTestPublicationRecorder()

            var publishedStates: [AgentSessionRunState] {
                publications.revisions.map(\.terminalState)
            }

            init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController,
                policies: PolicyInstallRecorder
            ) {
                self.policies = policies
                super.init(viewModel: viewModel, session: session, readiness: readiness, controller: controller)
                publications.install(on: viewModel)
            }
        }

        /// Runs `body` against a fresh fixture and tears it down, all inside the shared-MCP lease.
        /// The fixture keeps the hosting view model alive for the whole test, since the lease reaches
        /// readiness through a weak reference to it.
        private func withRoutingFixture(
            routesOnPolicyInstall: Bool,
            routingTimeoutMs: Int = 300,
            shouldManageCodexTooling: Bool = true,
            _ body: @MainActor (RoutingFixture) async throws -> Void
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let fixture = makeFixture(
                    routesOnPolicyInstall: routesOnPolicyInstall,
                    routingTimeoutMs: routingTimeoutMs,
                    shouldManageCodexTooling: shouldManageCodexTooling
                )
                var bodyError: Error?
                do {
                    try await body(fixture)
                } catch {
                    bodyError = error
                }
                await fixture.tearDown()
                for runID in fixture.policies.runIDs {
                    await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                        for: codexClientName,
                        windowID: testWindowID,
                        runID: runID
                    )
                    await MCPRoutingWaiter.cleanup(runID: runID)
                }
                if let bodyError {
                    throw bodyError
                }
            }
        }

        private func makeFixture(
            routesOnPolicyInstall: Bool,
            routingTimeoutMs: Int,
            shouldManageCodexTooling: Bool
        ) -> RoutingFixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: false)
            let policies = PolicyInstallRecorder()
            // The real per-run policy lets the expected-PID policy arm. The routing waiter is
            // registered before the policy is installed, so signalling here resolves the later
            // routing wait as a routed child connection would.
            let policyInstaller: AgentModeViewModel.ConnectionPolicyInstaller = { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
                if let runID {
                    policies.record(runID)
                }
                await ServerNetworkManager.shared.installClientConnectionPolicy(
                    for: clientName,
                    windowID: windowID,
                    restrictedTools: restrictedTools,
                    oneShot: oneShot,
                    reason: reason,
                    ttl: ttl,
                    tabID: tabID,
                    runID: runID,
                    additionalTools: additionalTools,
                    purpose: purpose,
                    taskLabelKind: taskLabelKind,
                    allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                    requiresExpectedAgentPID: requiresExpectedAgentPID
                )
                if routesOnPolicyInstall, let runID {
                    await MCPRoutingWaiter.notifyRouted(runID: runID)
                }
            }
            let viewModel = AgentModeViewModel(
                testWindowID: testWindowID,
                testWorkspacePath: storageRoot.path,
                testWorkspaceDirectory: storageRoot,
                shouldManageCodexTooling: shouldManageCodexTooling,
                codexControllerFactory: { _, _, _, _, _, _ in controller },
                codexControllerFactoryWithComputerUse: { _, _, _, _, _, _, _, _ in controller },
                connectionPolicyInstaller: policyInstaller,
                mcpServerReadinessRequirement: { try await readiness.require() },
                testCodexLeaseRoutingTimeoutMs: routingTimeoutMs
            )
            return RoutingFixture(
                viewModel: viewModel,
                session: startupTestCodexSession(),
                readiness: readiness,
                controller: controller,
                policies: policies
            )
        }

        /// Waits until the start's routing wait is suspended on its routing waiter and returns the
        /// start's run.
        private func awaitRoutingWait(
            _ fixture: RoutingFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> UUID {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let runID = fixture.policies.runIDs.first,
                   await MCPRoutingWaiter.debugContinuationCount(runID: runID) >= 1
                {
                    return runID
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTFail("the start never suspended on its routing wait", file: file, line: line)
            throw StartupTestJoinTimeout()
        }

        private func assertNoBootstrapStateRemains(
            for runID: UUID,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertNil(activeGate, "the bootstrap gate is still owned", file: file, line: line)
            let gateWaiters = await HeadlessAgentConnectionGate.shared.debugWaitingCount()
            XCTAssertEqual(gateWaiters, 0, "bootstrap gate waiters remain", file: file, line: line)
            let routingWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(routingWaiters, 0, "routing waiters remain for the run", file: file, line: line)
            let pendingPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: codexClientName)
            XCTAssertFalse(
                pendingPolicies.contains { $0.runID == runID },
                "the run's one-shot connection policy is still pending",
                file: file,
                line: line
            )
        }
    }
#endif
