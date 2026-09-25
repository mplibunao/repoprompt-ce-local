import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Rejected first dispatches of accepted Codex starts, driven through the real submission,
    /// dispatch gate, run service, runner, coordinator, and terminal barrier with injected
    /// readiness outcomes. Each rejected start must settle exactly once, as failed, with the
    /// cause of the phase that failed.
    @MainActor
    final class CodexStartupSettlementTests: XCTestCase {
        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexStartupSettlementTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        func testOuterReadinessFailureSettlesOnceWithoutAFirstTurn() async throws {
            let fixture = makeFixture()
            fixture.readiness.failures[1] = MCPBootstrapReadinessError.windowCatalogRegistrationFailed(
                diagnostic: "window catalog unavailable"
            )
            let registration = try await fixture.activateMCPControl()

            let ticket = try fixture.submit("first")
            try await startupTestJoin(ticket.task)

            let expected = "Codex startup failed during MCP window catalog registration: window catalog unavailable"
            XCTAssertEqual(fixture.controller.startOrResumeCount, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.errorTexts, [expected])
            XCTAssertEqual(ticket.phase, .rejected)
            XCTAssertEqual(fixture.session.runState, .failed)

            let revision = try XCTUnwrap(fixture.session.lastTerminalCommitRevision)
            XCTAssertEqual(revision.terminalState, .failed)
            XCTAssertEqual(revision.failureReason, .agentError)
            XCTAssertTrue(revision.ownership == ticket.ownership, "the failure settled someone else's attempt")
            XCTAssertEqual(revision.expectedRunID, ticket.reservedRunID)
            XCTAssertEqual(fixture.terminalPublicationAttempts, 1)

            // Live and stored observations agree on the failed status and the precise cause.
            let live = try XCTUnwrap(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID))
            XCTAssertEqual(live.status, .failed)
            XCTAssertEqual(live.statusText, expected)
            let stored = await AgentRunSessionStore.snapshot(for: registration)
            XCTAssertEqual(stored?.status, .failed)
            XCTAssertEqual(stored?.statusText, expected)
            XCTAssertEqual(stored?.failureReason, .agentError)
        }

        func testLeaseReadinessFailureKeepsTheLeasePhaseCause() async throws {
            let fixture = makeFixture(shouldManageCodexTooling: true)
            // The runner's check passes; the lease's own readiness check is the one that fails.
            fixture.readiness.failures[2] = MCPBootstrapReadinessError.supersededByExplicitWindowTransition

            let ticket = try fixture.submit("first")
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(fixture.readiness.callCount, 2)
            XCTAssertEqual(fixture.controller.startOrResumeCount, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.errorTexts, [
                "Codex startup failed during MCP bootstrap lease acquisition: "
                    + "RepoPrompt MCP readiness was superseded by an explicit change to this window's tools."
            ])
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.failureReason, .agentError)
            XCTAssertEqual(fixture.terminalPublicationAttempts, 1)
        }

        func testNativeStartFailureReportsItsPhaseOnce() async throws {
            let fixture = makeFixture()
            fixture.controller.startupError = NSError(
                domain: "CodexStartupSettlementTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "app-server exited"]
            )

            let ticket = try fixture.submit("first")
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(fixture.controller.startOrResumeCount, 1)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.errorTexts, ["Codex native start failed: app-server exited"])
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertEqual(fixture.terminalPublicationAttempts, 1)
        }

        func testRejectedStartReturnsAttachmentsAndKeepsPendingHandoff() async throws {
            let fixture = makeFixture()
            fixture.readiness.failures[1] = MCPBootstrapReadinessError.readinessHostUnavailable
            let attachment = AgentImageAttachment(source: .url("https://example.invalid/diagram.png"))
            fixture.session.pendingImageAttachments = [attachment]
            let handoffPayload = "<forked_session>prior work</forked_session>"
            fixture.session.pendingHandoff = .init(payload: handoffPayload, createdAt: Date())

            let ticket = try fixture.submit("first")
            XCTAssertEqual(fixture.session.pendingImageAttachments, [], "the submission did not take its attachment")
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(fixture.session.pendingImageAttachments, [attachment])
            XCTAssertEqual(fixture.session.attachmentTurnState, .idle)
            XCTAssertEqual(fixture.session.pendingHandoff.payload, handoffPayload, "the unsent handoff was consumed")
            XCTAssertFalse(fixture.session.pendingHandoff.isStagedForSend)
            XCTAssertEqual(fixture.errorTexts.count, 1)
        }

        func testReadinessRejectionIntoAnActiveRunLeavesThatRunAlone() async throws {
            let fixture = makeFixture()
            let head = try fixture.submit("head")
            try await eventually { fixture.controller.startUserTurnTexts == ["head"] }
            try await startupTestJoin(head.task)
            let activeOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            XCTAssertEqual(fixture.session.runState, .running)

            fixture.readiness.failures[2] = MCPBootstrapReadinessError.readinessHostUnavailable
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "follower", tabID: fixture.tabID), .submitted)
            try await eventually { fixture.readiness.callCount == 2 && !fixture.errorTexts.isEmpty }

            XCTAssertEqual(fixture.session.runState, .running)
            XCTAssertEqual(fixture.session.activeRunOwnership, activeOwnership)
            XCTAssertNil(fixture.session.lastTerminalCommitRevision)
            XCTAssertEqual(fixture.errorTexts.count, 1)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["head"])
        }

        /// A submission into an active run waits at readiness while that run finishes and a
        /// successor takes the session; its late readiness failure belongs to neither.
        func testLateReadinessFailureOfASubmissionIntoAFinishedRunLeavesTheSuccessorAlone() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [2, 3])
            let head = try fixture.submit("head")
            try await eventually { fixture.controller.startUserTurnTexts == ["head"] }
            try await startupTestJoin(head.task)
            XCTAssertEqual(fixture.session.runState, .running)

            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "follower", tabID: fixture.tabID), .submitted)
            try await eventually { fixture.readiness.isWaiting(2) }
            let followerTask = try XCTUnwrap(fixture.session.agentTask, "the follower installed no send task")

            try await fixture.completeActiveTurn(turnID: "head-turn")
            try await eventually { fixture.session.runState == .completed }
            let commitsBeforeSuccessor = fixture.terminalPublicationAttempts
            let errorsBeforeSuccessor = fixture.errorTexts

            let successor = Task { await fixture.viewModel.startAgentRun(tabID: fixture.tabID, initialMessage: "successor") }
            fixture.cleanup.join(successor)
            try await eventually { fixture.readiness.isWaiting(3) }
            let successorOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            let successorRunState = fixture.session.runState

            fixture.readiness.release(2, failingWith: MCPBootstrapReadinessError.readinessHostUnavailable)
            try await startupTestJoin(followerTask)

            XCTAssertEqual(fixture.errorTexts, errorsBeforeSuccessor, "the late failure was reported on the successor")
            XCTAssertEqual(fixture.session.activeRunOwnership, successorOwnership)
            XCTAssertEqual(fixture.session.runState, successorRunState)
            XCTAssertEqual(fixture.terminalPublicationAttempts, commitsBeforeSuccessor, "the late failure settled the successor")

            fixture.readiness.release(3, ready: true)
            try await eventually { fixture.controller.startUserTurnTexts == ["head", "successor"] }
        }

        /// A submission into an active run held inside native readiness while that run completes
        /// and a successor starts must not take the successor's native session as its own.
        func testSubmissionHeldInNativeReadinessDispatchesNothingAgainstASuccessor() async throws {
            let fixture = makeFixture()
            let head = try fixture.submit("head")
            try await eventually { fixture.controller.startUserTurnTexts == ["head"] }
            try await startupTestJoin(head.task)
            XCTAssertEqual(fixture.session.runState, .running)

            let readinessHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(readinessHold)
            fixture.viewModel.test_codexCoordinator.test_setReadySessionToolTrackingGate {
                await readinessHold.wait()
            }
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "follower", tabID: fixture.tabID), .submitted)
            try await eventually { readinessHold.isWaiting }
            let followerTask = try XCTUnwrap(fixture.session.agentTask, "the follower installed no send task")

            try await fixture.completeActiveTurn(turnID: "head-turn")
            try await eventually { fixture.session.runState == .completed }
            fixture.viewModel.test_codexCoordinator.test_setReadySessionToolTrackingGate(nil)
            let successor = Task { await fixture.viewModel.startAgentRun(tabID: fixture.tabID, initialMessage: "successor") }
            fixture.cleanup.join(successor)
            try await eventually { fixture.controller.startUserTurnTexts == ["head", "successor"] }
            let successorOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            let errorsBeforeRelease = fixture.errorTexts

            readinessHold.release()
            try await startupTestJoin(followerTask)

            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["head", "successor"])
            XCTAssertEqual(fixture.controller.steerUserTurnTexts, [], "the old submission steered the successor's turn")
            XCTAssertTrue(fixture.session.codexFallbackQueue.isEmpty, "the old submission was queued against the successor")
            XCTAssertNotEqual(fixture.session.codexPendingAuthRetryTurn?.text, "follower")
            XCTAssertEqual(fixture.session.activeRunOwnership, successorOwnership)
            XCTAssertEqual(fixture.errorTexts, errorsBeforeRelease)
        }

        func testLateReadinessFailureAfterCancellationAddsNoError() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let ticket = try fixture.submit("cancelled")
            try await eventually { fixture.readiness.isWaiting(1) }

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.readiness.release(1, failingWith: MCPBootstrapReadinessError.windowDisabledDuringReadiness)
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.session.runState, .cancelled)
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.terminalState, .cancelled)
            XCTAssertEqual(fixture.errorTexts, [])
            XCTAssertEqual(fixture.terminalPublicationAttempts, 1)
        }

        /// A startup failure its own path already settled must not be settled again. That path
        /// suspends while publishing, and a successor that owns the session by the time the send
        /// path resumes must keep its attempt, its transcript, and its result.
        func testSettledStartupFailureLeavesASuccessorStartedDuringItsPublicationUntouched() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1, 2])
            let original = try fixture.submit("original")
            try await eventually { fixture.readiness.isWaiting(1) }

            // The run service has resolved the workspace; the coordinator resolves it again after
            // readiness and now finds the worktree gone, which it settles itself.
            fixture.session.worktreeBindings = [AgentSessionWorktreeBinding(
                id: "missing-binding",
                repositoryID: "repo",
                repoKey: "repo",
                logicalRootPath: storageRoot.path,
                worktreeID: "missing-worktree",
                worktreeRootPath: storageRoot.appendingPathComponent("missing-worktree").path,
                source: "test"
            )]
            let publicationHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(publicationHold)
            fixture.viewModel.test_codexCoordinator.test_setWorkspaceResolutionFailurePublicationGate {
                await publicationHold.wait()
            }
            fixture.readiness.release(1, ready: true)
            try await eventually { publicationHold.isWaiting }
            XCTAssertEqual(fixture.terminalPublicationAttempts, 1)
            XCTAssertEqual(fixture.session.runState, .failed)
            let originalErrors = fixture.errorTexts
            XCTAssertEqual(originalErrors.count, 1)

            // A successor that is not serialized behind the original, as follow-up runs are.
            fixture.session.worktreeBindings = []
            fixture.viewModel.test_codexCoordinator.test_setWorkspaceResolutionFailurePublicationGate(nil)
            let successor = Task { await fixture.viewModel.startAgentRun(tabID: fixture.tabID, initialMessage: "successor") }
            fixture.cleanup.join(successor)
            try await eventually { fixture.readiness.isWaiting(2) }
            let successorOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            let successorRunState = fixture.session.runState

            publicationHold.release()
            try await startupTestJoin(original.task)

            XCTAssertEqual(fixture.session.activeRunOwnership, successorOwnership, "the original's failure settled its successor")
            XCTAssertEqual(fixture.errorTexts, originalErrors, "the original's error was repeated into the successor")
            XCTAssertEqual(fixture.terminalPublicationAttempts, 1)
            XCTAssertEqual(fixture.session.runState, successorRunState)

            fixture.readiness.release(2, ready: true)
            try await eventually { fixture.controller.startUserTurnTexts == ["successor"] }
        }

        /// Reconnecting an active run's native session reports a failure on that run without
        /// inventing or settling one.
        func testReconnectFailureOfAnActiveRunIsShownWithoutSettlingIt() async {
            let fixture = makeFixture()
            fixture.controller.startupError = NSError(
                domain: "CodexStartupSettlementTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "app-server exited during reconnect"]
            )
            fixture.session.runState = .running

            _ = await fixture.viewModel.ensureSessionReady(tabID: fixture.tabID, reconnectActiveProviders: true)

            XCTAssertEqual(fixture.controller.startOrResumeCount, 1)
            XCTAssertEqual(fixture.errorTexts, ["Codex native start failed: app-server exited during reconnect"])
            XCTAssertEqual(fixture.session.runState, .running)
            XCTAssertNil(fixture.session.activeRunOwnership, "the reconnect invented a run attempt")
            XCTAssertNil(fixture.session.lastTerminalCommitRevision)
            XCTAssertEqual(fixture.terminalPublicationAttempts, 0)
        }

        // MARK: - Fixture

        /// Adds publication recording and the coordinator's startup gates to the shared fixture.
        @MainActor
        private final class Fixture: StartupTestSessionFixture {
            let publishedRevisions = StartupTestPublicationRecorder()

            /// Terminal revisions handed to publication, whatever each publication's result.
            var terminalPublicationAttempts: Int {
                publishedRevisions.revisions.count
            }

            override init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController
            ) {
                super.init(viewModel: viewModel, session: session, readiness: readiness, controller: controller)
                publishedRevisions.install(on: viewModel)
                let coordinator = viewModel.test_codexCoordinator
                cleanup.releases.append {
                    coordinator.test_setWorkspaceResolutionFailurePublicationGate(nil)
                    coordinator.test_setReadySessionToolTrackingGate(nil)
                }
            }
        }

        private func makeFixture(
            gatedReadinessCalls: Set<Int> = [],
            shouldManageCodexTooling: Bool = false
        ) -> Fixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: gatedReadinessCalls)
            let controller = StartupTestCodexController(gatesStartup: false)
            let viewModel = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                testWorkspaceDirectory: storageRoot,
                shouldManageCodexTooling: shouldManageCodexTooling,
                codexControllerFactory: { _, _, _, _, _, _ in controller },
                mcpServerReadinessRequirement: { try await readiness.require() }
            )
            let fixture = Fixture(
                viewModel: viewModel,
                session: startupTestCodexSession(),
                readiness: readiness,
                controller: controller
            )
            addTeardownBlock { @MainActor in await fixture.tearDown() }
            return fixture
        }

        private func settle(
            on fixture: StartupTestSessionFixture,
            seconds: TimeInterval = 5,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ operation: @escaping @MainActor () async -> Void
        ) async throws {
            try await startupTestSettle(on: fixture, seconds: seconds, file: file, line: line, operation)
        }

        private func eventually(
            seconds: TimeInterval = 5,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ condition: @MainActor () -> Bool
        ) async throws {
            struct ConditionTimeout: Error {}
            if await startupTestWaitBounded(seconds: seconds, until: condition) { return }
            XCTFail("Timed out waiting for condition", file: file, line: line)
            throw ConditionTimeout()
        }
    }
#endif
