import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Drives `agent_manage stop_session` through the tool service against a view model whose
    /// providers are fakes: recording Claude and Codex runtimes, and a scripted ACP agent that runs as
    /// a real process. Turns go through the real submission, runners and terminal barrier. The reply
    /// wait runs on a manual clock.
    @MainActor
    final class AgentManageStopSessionTests: XCTestCase {
        private var window: WindowState!

        override func setUp() async throws {
            try await super.setUp()
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
            window = ACPModelParameterTestSupport.makeWindowWithoutLiveProviderCatalogs()
            await window.workspaceManager.awaitInitialized()
        }

        override func tearDown() async throws {
            window = nil
            try await super.tearDown()
        }

        /// A stop on a session whose run completed releases its process and keeps the transcript,
        /// the stored conversation and the terminal result.
        func testCompletedSessionReleasesProviderAndKeepsConversation() async throws {
            for agent in [AgentProviderKind.claudeCode, .codexExec, .cursor] {
                let label = agent.rawValue
                let fixture = try makeFixture(agent: agent)
                try await fixture.runCompletedTurn("first message")
                let listedBefore = try await fixture.listedSession()
                XCTAssertEqual(listedBefore["runtime_attached"], .bool(true), label)
                let items = fixture.session.items
                let conversationID = fixture.storedConversationID
                XCTAssertNotNil(conversationID, label)
                let revision = try XCTUnwrap(fixture.session.lastTerminalCommitRevision, label)

                let reply = try await fixture.stop()

                XCTAssertEqual(reply["stop_requested"], .bool(false), label)
                XCTAssertEqual(reply["provider_process"]?.objectValue?["status"], .string("released"), label)
                XCTAssertEqual(reply["is_live"], .bool(true), label)
                XCTAssertEqual(reply["runtime_attached"], .bool(false), label)
                XCTAssertEqual(fixture.shutdownsFinished, 1, label)
                XCTAssertFalse(fixture.session.hasAttachedProviderRuntime, label)
                XCTAssertEqual(fixture.session.items, items, label)
                XCTAssertEqual(fixture.storedConversationID, conversationID, label)
                XCTAssertEqual(fixture.session.lastTerminalCommitRevision, revision, label)
                XCTAssertEqual(fixture.session.runState, .completed, label)
                let listedAfter = try await fixture.listedSession()
                XCTAssertEqual(listedAfter["runtime_attached"], .bool(false), label)
            }
        }

        /// A stop on a running session cancels its run, as before, and reports no process status.
        func testRunningStopKeepsCancellation() async throws {
            let fixture = try makeFixture(agent: .claudeCode)
            try await fixture.startTurn("long task")
            XCTAssertTrue(fixture.session.runState.isActive)

            let reply = try await fixture.stop()

            XCTAssertEqual(reply["stop_requested"], .bool(true))
            XCTAssertNil(reply["provider_process"])
            XCTAssertEqual(fixture.session.runState, .cancelled)
            try await startupTestEventually { fixture.shutdownsFinished == 1 }
        }

        /// A stop finds work in flight before anything is shut down, and changes nothing.
        func testBusySessionStopIsBlocked() async throws {
            do {
                let label = "pending approval"
                let fixture = try makeFixture(agent: .claudeCode)
                try await fixture.runCompletedTurn("turn")
                let controller = try XCTUnwrap(fixture.session.claudeController)
                fixture.session.pendingApproval = Self.approvalRequest()

                let reply = try await fixture.stop()

                XCTAssertEqual(
                    reply["provider_process"],
                    .object(["status": .string("blocked"), "blocker": .string("interaction")]),
                    label
                )
                XCTAssertEqual(reply["runtime_attached"], .bool(true), label)
                XCTAssertEqual(fixture.claude.shutdownsStarted, 0, label)
                XCTAssertTrue(fixture.session.claudeController === controller, label)
                XCTAssertNotNil(fixture.session.pendingApproval, label)
            }
            do {
                let label = "Codex turn pending"
                let fixture = try makeFixture(agent: .codexExec)
                try await fixture.runCompletedTurn("turn")
                let controller = try XCTUnwrap(fixture.session.codexController)
                fixture.session.codexPendingTurnKind = .user

                let reply = try await fixture.stop()

                XCTAssertEqual(
                    reply["provider_process"],
                    .object(["status": .string("blocked"), "blocker": .string("provider_busy")]),
                    label
                )
                XCTAssertEqual(fixture.shutdownsFinished, 0, label)
                XCTAssertTrue(fixture.session.codexController === controller, label)
                XCTAssertEqual(fixture.session.codexPendingTurnKind, .user, label)
            }
        }

        /// A message admitted while the stop waits on the provider's probe keeps the process: the
        /// original runtime serves it and the stop reports the run that blocked it.
        func testSubmissionDuringProbeWins() async throws {
            let fixture = try makeFixture(agent: .claudeCode)
            try await fixture.runCompletedTurn("first message")
            let probeHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(probeHold)
            fixture.claude.probeHold = probeHold

            let stopping = fixture.stopInBackground()
            try await startupTestEventually { probeHold.isWaiting }
            let ticket = try fixture.submit("admitted during the probe")
            try await startupTestJoin(ticket.task)
            try await startupTestEventually { fixture.claude.sentMessages.count == 2 }
            probeHold.release()
            let reply = try await stopping.reply()

            XCTAssertEqual(reply["stop_requested"], .bool(false))
            XCTAssertEqual(
                reply["provider_process"],
                .object(["status": .string("blocked"), "blocker": .string("active_run")])
            )
            XCTAssertEqual(fixture.claude.shutdownsStarted, 0)
            XCTAssertEqual(fixture.claude.runtimesCreated, 1, "the admitted message started a new process")
            XCTAssertNotNil(fixture.session.claudeController)
            XCTAssertTrue(fixture.session.runState.isActive)
        }

        /// A running mask that MCP snapshots treat as stale, unchanged for over 15 s with no owner
        /// or run work behind it, doesn't block a stop. A fresh one does.
        func testStaleRunningMaskDoesNotBlockStop() async throws {
            let rows: [(label: String, ageSeconds: TimeInterval, raise: @MainActor (AgentModeViewModel.TabSession) -> Void, blocker: String?)] = [
                ("fresh follow-up mask", 0, { $0.mcpFollowUpRunPending = true }, "pending_start"),
                ("stale follow-up mask", 20, { $0.mcpFollowUpRunPending = true }, nil),
                ("stale superseding mask", 20, { $0.pendingSupersedingTurnCompletions = 1 }, nil)
            ]
            for (label, ageSeconds, raise, blocker) in rows {
                let fixture = try makeFixture(agent: .claudeCode)
                try await fixture.runCompletedTurn("turn")
                raise(fixture.session)
                let changedAt = Date().addingTimeInterval(-ageSeconds)
                fixture.session.mcpFollowUpRunPendingUpdatedAt = changedAt
                fixture.session.pendingSupersedingTurnCompletionsUpdatedAt = changedAt

                let reply = try await fixture.stop()

                if let blocker {
                    XCTAssertEqual(Self.blockedReason(reply), blocker, label)
                    XCTAssertEqual(fixture.claude.shutdownsStarted, 0, label)
                } else {
                    XCTAssertEqual(reply["provider_process"]?.objectValue?["status"], .string("released"), label)
                    XCTAssertFalse(fixture.session.mcpFollowUpRunPending, label)
                    XCTAssertEqual(fixture.session.pendingSupersedingTurnCompletions, 0, label)
                }
            }
        }

        /// A released Codex app-server still exiting when the reply is due reports `shutting_down`.
        /// The next message waits for it, then resumes the same thread in a new app-server that the
        /// old retirement leaves alone.
        func testCodexSuccessorWaitsForRetirementAndKeepsConversation() async throws {
            let fixture = try makeFixture(agent: .codexExec)
            try await fixture.runCompletedTurn("first message")
            let conversationID = try XCTUnwrap(fixture.session.codexConversationID)
            let shutdownHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(shutdownHold)
            fixture.codex.shutdownHold = shutdownHold

            let stopping = fixture.stopInBackground()
            try await startupTestEventually { shutdownHold.isWaiting && fixture.clock.pendingDeadlines.count == 1 }
            fixture.clock.advance(by: AgentModeViewModel.providerRetirementReplyWait)
            let reply = try await stopping.reply()
            XCTAssertEqual(reply["provider_process"]?.objectValue?["status"], .string("shutting_down"))
            XCTAssertEqual(reply["runtime_attached"], .bool(false))

            let preparationsWaiting = StartupTestCounter()
            fixture.viewModel.test_codexCoordinator.test_controllerPreparationWillAwaitRetirement = { _ in
                preparationsWaiting.value += 1
            }
            let ticket = try fixture.submit("second message")
            // A start that skipped the wait shows up as a second app-server.
            try await startupTestEventually { preparationsWaiting.value == 1 || fixture.codex.controllers.count > 1 }
            XCTAssertEqual(fixture.codex.controllers.count, 1, "a new app-server started while the old one was shutting down")

            shutdownHold.release()
            try await startupTestEventually { fixture.codex.controllers.last?.startUserTurnTexts == ["second message"] }
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(fixture.codex.events, [
                .created(controller: 0),
                .shutdownFinished(controller: 0),
                .created(controller: 1)
            ])
            let successor = try XCTUnwrap(fixture.codex.controllers.last)
            XCTAssertEqual(successor.startOrResumeTargets.map { $0?.conversationID }, [conversationID])
            XCTAssertEqual(fixture.session.codexConversationID, conversationID)
            XCTAssertTrue(fixture.session.codexController === successor, "the old retirement detached the successor")
            XCTAssertEqual(fixture.session.runID, fixture.codex.runIDs.last)
            XCTAssertNotEqual(fixture.codex.runIDs.first, fixture.codex.runIDs.last)
            XCTAssertNil(fixture.viewModel.test_codexCoordinator.pendingCodexRetirementTask(for: fixture.tabID))
        }

        // MARK: - Fixture

        /// A live session bound to an Agent session ID that the window's workspace lists, in a view
        /// model whose providers are fakes, and the `agent_manage` service that stops it.
        @MainActor
        private final class Fixture: StartupTestSessionFixture {
            let claude: StartupTestClaudeRecorder
            let codex: StartupTestCodexControllerRecorder
            let peer: StartupTestACPPeer
            let clock: StartupTestManualClock
            private(set) var service: AgentManageMCPToolService!

            init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController,
                claude: StartupTestClaudeRecorder,
                codex: StartupTestCodexControllerRecorder,
                peer: StartupTestACPPeer,
                clock: StartupTestManualClock
            ) {
                self.claude = claude
                self.codex = codex
                self.peer = peer
                self.clock = clock
                super.init(viewModel: viewModel, session: session, readiness: readiness, controller: controller)
            }

            /// Binds the session and lists it in `window`'s workspace, so `stop_session` resolves it.
            /// Binding drops a terminal result, so it runs before any turn.
            func attach(to window: WindowState, workspaceRoot: URL) {
                session.testInstallPersistentSessionBinding(sessionID: sessionID)
                let tab = ComposeTabState(id: tabID, name: "Stop session", activeAgentSessionID: sessionID)
                let workspace = WorkspaceModel(
                    name: "Stop session tests",
                    repoPaths: [workspaceRoot.path],
                    composeTabs: [tab],
                    activeComposeTabID: tab.id
                )
                window.workspaceManager.workspaces = [workspace]
                window.workspaceManager.activeWorkspace = workspace
                var service = AgentManageMCPToolService(
                    toolName: MCPWindowToolName.agentManage,
                    captureRequestMetadata: {
                        MCPServerViewModel.RequestMetadata(
                            connectionID: UUID(),
                            clientName: "agent-manage-stop-session-tests",
                            windowID: window.windowID
                        )
                    },
                    requireTargetWindow: { window },
                    resolveSpawnSourceTabID: { _ in nil },
                    resolveSpawnParentSessionID: { _, _ in nil },
                    bindCurrentRequestToTab: { _, _ in },
                    restrictDiscoveryToRoleLabels: { _ in false }
                )
                service.test_agentModeViewModel = viewModel
                self.service = service
            }

            func stop() async throws -> [String: Value] {
                let reply = try await service.execute(args: [
                    "op": .string("stop_session"),
                    "session_id": .string(sessionID.uuidString)
                ])
                return try XCTUnwrap(reply.objectValue)
            }

            /// Starts a stop whose reply the test collects later; teardown cancels it if it never ends.
            func stopInBackground() -> PendingStop {
                let pending = PendingStop()
                pending.finished = startupTestRunTracked({ [weak self] in
                    guard let self else { return }
                    do {
                        pending.result = try await .success(stop())
                    } catch {
                        pending.result = .failure(error)
                    }
                }, in: cleanup.trackedOperations)
                return pending
            }

            /// The session's entry in `list_sessions`.
            func listedSession() async throws -> [String: Value] {
                let listed = try await service.execute(args: ["op": .string("list_sessions")])
                let sessions = try XCTUnwrap(listed.objectValue?["sessions"]?.arrayValue)
                return try XCTUnwrap(sessions.compactMap(\.objectValue).first {
                    $0["session_id"] == .string(sessionID.uuidString)
                })
            }

            var storedConversationID: String? {
                session.selectedAgent == .codexExec ? session.codexConversationID : session.providerSessionID
            }

            /// Shutdowns of the session's provider runtimes that have finished.
            var shutdownsFinished: Int {
                switch session.selectedAgent {
                case .codexExec:
                    codex.events.count { if case .shutdownFinished = $0 { true } else { false } }
                case .cursor:
                    peer.records.count { $0.event == "exit" }
                default:
                    claude.shutdownObservations.count
                }
            }

            /// Sends `text` and waits until the provider has it and its run is under way.
            func startTurn(_ text: String) async throws {
                let ticket = try submit(text)
                switch session.selectedAgent {
                case .codexExec:
                    try await startupTestEventually { self.codex.controllers.last?.startUserTurnTexts.last == text }
                    try await startupTestJoin(ticket.task)
                case .cursor:
                    try await startupTestJoin(ticket.task)
                default:
                    let sentBefore = claude.sentMessages.count
                    try await startupTestJoin(ticket.task)
                    try await startupTestEventually { self.claude.sentMessages.count == sentBefore + 1 }
                    try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(session.runID))
                }
            }

            /// Sends `text`, completes its turn, and waits until its terminal has committed.
            func runCompletedTurn(_ text: String) async throws {
                try await startTurn(text)
                switch session.selectedAgent {
                case .codexExec:
                    let controller = try XCTUnwrap(codex.controllers.last)
                    let coordinator = viewModel.test_codexCoordinator
                    let turnID = "turn-\(codex.controllers.count)-\(UUID().uuidString)"
                    await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: turnID), session: session, sourceController: controller)
                    // A transcript with no reply starts a new thread rather than resuming one.
                    await coordinator.test_handleCodexNativeEvent(.assistantDelta("reply to \(text)"), session: session, sourceController: controller)
                    await coordinator.test_handleCodexNativeEvent(
                        .turnCompleted(turnID: turnID, status: .completed),
                        session: session,
                        sourceController: controller
                    )
                case .cursor:
                    break
                default:
                    let runtime = try XCTUnwrap(claude.runtimes.last)
                    let turnID = try XCTUnwrap(claude.sentTurnIDs.last)
                    await runtime.emit(.turnCompleted(turnID: turnID, status: .completed))
                }
                try await startupTestEventually(seconds: 15) {
                    !self.session.runState.isActive
                        && self.session.activeRunOwnership == nil
                        && !self.session.terminalCommitInProgress
                }
                XCTAssertEqual(session.runState, .completed, "errors: \(errorTexts)")
            }
        }

        /// A stop running in the background, and its reply once it ends.
        @MainActor
        private final class PendingStop {
            var finished: StartupTestCompletionFlag?
            var result: Result<[String: Value], Error>?

            func reply(file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Value] {
                try await startupTestEventually(file: file, line: line) { self.finished?.value == true }
                return try XCTUnwrap(result, file: file, line: line).get()
            }
        }

        /// Builds a fixture for `agent` with the idle setting at 0, so no idle timer retires anything,
        /// and registers its teardown, which also ends every ACP agent process the test started,
        /// before any test step can throw.
        private func makeFixture(agent: AgentProviderKind) throws -> Fixture {
            let directory = try makeTestDirectory()
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: false)
            let claude = StartupTestClaudeRecorder()
            let codex = StartupTestCodexControllerRecorder()
            let idle = StartupTestClaudeIdleEnvironment()
            idle.idleMinutes = 0
            let peer = try StartupTestACPPeer(directory: directory)
            let viewModel = startupTestMakeViewModel(
                storageRoot: directory,
                readiness: readiness,
                controller: controller,
                codexControllers: codex,
                claude: claude,
                claudeIdle: idle,
                acpProvider: peer.provider()
            )
            viewModel.test_setProviderRetirementClock(idle.clock.cancellableClock)
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.hasLoadedPersistedState = true
            session.selectedAgent = agent
            let fixture = Fixture(
                viewModel: viewModel,
                session: session,
                readiness: readiness,
                controller: controller,
                claude: claude,
                codex: codex,
                peer: peer,
                clock: idle.clock
            )
            fixture.attach(to: window, workspaceRoot: directory)
            addTeardownBlock { @MainActor in
                await fixture.tearDown()
                idle.clock.cancelSleepers()
                await session.acpController?.shutdown()
                peer.killUnexitedProcesses()
            }
            return fixture
        }

        /// The `blocker` of a reply whose `provider_process.status` is `blocked`, or nil otherwise.
        private static func blockedReason(_ reply: [String: Value]) -> String? {
            guard let process = reply["provider_process"]?.objectValue,
                  process["status"] == .string("blocked")
            else { return nil }
            return process["blocker"]?.stringValue
        }

        private static func approvalRequest() -> AgentApprovalRequest {
            AgentApprovalRequest(
                requestID: .claudeControl("approval"),
                method: "can_use_tool",
                kind: .commandExecution,
                threadID: "thread",
                turnID: "turn",
                itemID: "item",
                reason: nil,
                command: nil,
                cwd: nil,
                grantRoot: nil,
                proposedExecpolicyAmendmentJSON: nil,
                details: []
            )
        }
    }
#endif
