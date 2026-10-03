@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class ACPIntegratedAgentModeRunnerExecutionTests: XCTestCase {
    func testCompletedTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .completed,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.completed(assistantText: nil))
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.completed)]
        )
    }

    func testCancelledTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .cancelled,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.cancelled())
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.cancelled)]
        )
    }

    func testFailedTerminalPreservesProviderErrorText() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: "ACP provider refused the turn."
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.failed(assistantText: "ACP provider refused the turn."))
        )
        XCTAssertEqual(classification.errorText, "ACP provider refused the turn.")
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testFailedTerminalPreservesAbsentProviderErrorTextForSettlement() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: nil
        )

        guard case let .terminal(outcome) = classification.result else {
            return XCTFail("Expected terminal classification")
        }
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testSupersededExecutionRemainsNonterminal() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientSupersession()

        XCTAssertEqual(classification.result, .superseded)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .executionSuperseded]
        )
    }

    func testConfigurationSequenceStopsAfterOwnershipChangesDuringAwaitedStep() async throws {
        var isCurrent = true
        var providerMutations: [String] = []

        let completed = try await ACPIntegratedAgentModeRunner.testPerformConfigurationSequenceIfCurrent(
            isCurrent: { isCurrent },
            operations: [
                {
                    providerMutations.append("model")
                    await Task.yield()
                    isCurrent = false
                },
                {
                    providerMutations.append("parameters")
                }
            ]
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(providerMutations, ["model"])
    }

    func testModelParameterApplicationAcceptsAppliedAndAlreadyCurrentSelections() throws {
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "high"
        )

        XCTAssertNoThrow(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [selection],
            alreadyCurrent: [],
            skipped: []
        )))
        XCTAssertNoThrow(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [],
            alreadyCurrent: [selection],
            skipped: []
        )))
    }

    func testModelParameterApplicationRejectsStaleUnsupportedSelectionBeforePrompt() {
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .speed,
            configID: "fast",
            valueRaw: "true"
        )

        XCTAssertThrowsError(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [],
            alreadyCurrent: [],
            skipped: [selection]
        ))) { error in
            XCTAssertTrue(error.localizedDescription.contains("stale or unsupported"))
            XCTAssertTrue(error.localizedDescription.contains("fast=true"))
        }
    }

    func testCursorKnownModelPassesReleaseCatalogValidationBeforePrompt() throws {
        let model = try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: "grok-4.6"
        )

        XCTAssertEqual(model, "grok-4.6")
    }

    func testCursorAutoAliasPassesReleaseCatalogValidationBeforePrompt() throws {
        let model = try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: AgentModel.cursorAuto.rawValue
        )

        XCTAssertEqual(model, AgentModel.cursorAuto.rawValue)
    }

    func testCursorUnknownConcreteModelFailsClosedBeforePrompt() {
        XCTAssertThrowsError(try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: "cursor-future-model"
        )) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Expected invalid Cursor model configuration, got \(error)")
            }
            XCTAssertTrue(detail.contains("cursor-future-model"))
            XCTAssertTrue(detail.contains("supported model catalog"))
        }
    }

    #if DEBUG

        // MARK: - Follow-up respawn admission

        // A reused OpenCode session's helper stays connected and routed across turns. Each follow-up
        // turn arms one run-owned policy that admits a helper respawning during the turn; settling
        // the turn removes that policy and keeps the run's route.

        func testOnlyPrePromptRoutedProvidersArmOneFollowUpPolicy() async throws {
            try await withFollowUpRun { run, turns in
                XCTAssertNil(turns.begin(agentKind: .cursor))
                XCTAssertNil(turns.begin(agentKind: .grokBuild))
                XCTAssertEqual(turns.leaseCount, 0, "Prompt-deferred providers route each turn through their own deferred lease.")

                let turn = try XCTUnwrap(turns.begin())
                XCTAssertEqual(turns.leaseCount, 1)
                let armed = await turn.arm()
                XCTAssertTrue(armed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 1)
                await run.assertOwner(run.c1)
            }
        }

        func testRespawnedHelperConsumesFollowUpPolicyAndIsAdmitted() async throws {
            try await withFollowUpRun { run, turns in
                let turn = try XCTUnwrap(turns.begin())
                let armed = await turn.arm()
                XCTAssertTrue(armed)

                let respawn = try await run.handshake(run.c4, sessionToken: run.c4Token)
                XCTAssertNil(respawn.error)
                await run.assertOwner(run.c4)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0, "The respawned helper consumes the turn's one-shot policy.")

                await turn.settle(.completed)
                await run.assertOwner(run.c4)
            }
        }

        func testRepeatedFollowUpTurnsKeepEstablishedRouteAndToolTracking() async throws {
            try await withFollowUpRun { run, turns in
                for terminalState in [AgentSessionRunState.completed, .failed, .completed] {
                    let turn = try XCTUnwrap(turns.begin())
                    let armed = await turn.arm()
                    XCTAssertTrue(armed)
                    await turn.settle(terminalState)

                    let pending = await run.pendingPolicyCount()
                    XCTAssertEqual(pending, 0, "A \(terminalState) turn removes its unused policy.")
                    await run.assertOwner(run.c1)
                    let trackedRunID = await run.manager.runIDForConnection(run.c1)
                    XCTAssertEqual(trackedRunID, run.runID, "Tool tracking attributes the helper's calls to its run.")
                }
            }
        }

        func testSettledTurnsUnusedPolicyDoesNotBlockPeerSameTokenReconnect() async throws {
            try await withFollowUpRun { run, turns in
                let peer = try await run.establishPeerRun()
                let turn = try XCTUnwrap(turns.begin())
                _ = await turn.arm()
                await turn.settle(.completed)

                let reconnect = await Self.reconnect(peer, in: run)
                XCTAssertEqual(reconnect, "fallback")
                let peerRunID = await run.manager.runIDForConnection(peer.reconnectID)
                XCTAssertEqual(peerRunID, peer.runID)
                await run.assertOwner(run.c1)
            }
        }

        func testPeerSameTokenReconnectDuringFollowUpTurnKeepsItsOwnRun() async throws {
            try await withFollowUpRun { run, turns in
                let peer = try await run.establishPeerRun()
                let turn = try XCTUnwrap(turns.begin())
                _ = await turn.arm()

                let reconnect = await Self.reconnect(peer, in: run)
                XCTAssertEqual(
                    reconnect,
                    "fallback",
                    "The peer's session ticket routes it to its own run; this run's policy is not its to wait on."
                )
                let peerRunID = await run.manager.runIDForConnection(peer.reconnectID)
                XCTAssertEqual(peerRunID, peer.runID)
            }
        }

        func testLateFailedSettlementLeavesNewerTurnsPolicy() async throws {
            try await withFollowUpRun { run, turns in
                let earlier = try XCTUnwrap(turns.begin())
                _ = await earlier.arm()
                let later = try XCTUnwrap(turns.begin())
                let armed = await later.arm()
                XCTAssertTrue(armed)

                // The terminal barrier starts a queued follow-up before the earlier turn's teardown runs.
                await earlier.settle(.failed)

                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 1, "Only the newer turn's policy remains.")
                await run.assertOwner(run.c1)
                let respawn = await run.apply(run.c4, sessionKey: run.c4Token)
                XCTAssertEqual(respawn.outcome, "applied", "The newer turn still admits a respawned helper.")
            }
        }

        func testLateCancelledSettlementLeavesNewerTurnsRouteAndPolicy() async throws {
            try await withFollowUpRun { run, turns in
                let earlier = try XCTUnwrap(turns.begin())
                _ = await earlier.arm()
                let later = try XCTUnwrap(turns.begin())
                _ = await later.arm()

                await earlier.settle(.cancelled)

                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 1, "Only the newer turn's policy remains.")
                await run.assertOwner(run.c1)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertEqual(trackedRunID, run.runID)
            }
        }

        func testCancelledTurnEndsOnlyItsOwnRunsRouting() async throws {
            try await withFollowUpRun { run, turns in
                let peer = try await run.establishPeerRun()
                let turn = try XCTUnwrap(turns.begin())
                _ = await turn.arm()

                await turn.settle(.cancelled)

                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertNil(trackedRunID, "A cancelled turn ends its run's routing, as a cancelled fresh start does.")
                let peerRunID = await run.manager.runIDForConnection(peer.ownerID)
                XCTAssertEqual(peerRunID, peer.runID)
            }
        }

        // MARK: Follow-up turns through the runner

        // These turns go through the view model's submission into the runner's reuse branch and
        // `continueRun`, on a real ACP controller whose open session is on a fake OpenCode agent.

        func testFollowUpTurnInstallsItsPolicyBeforeThePromptAndTeardownRemovesIt() async throws {
            try await withReusedOpenCodeSession { run, reused in
                for turn in 1 ... 2 {
                    try await reused.submit("Follow-up turn \(turn)")
                    XCTAssertEqual(
                        reused.events.entries.suffix(2),
                        [.policyInstalled, .promptSubmitted],
                        "Turn \(turn) installs its policy before its prompt is submitted."
                    )
                    let pending = await run.pendingPolicyCount()
                    XCTAssertEqual(pending, 1, "Turn \(turn)'s policy waits for a respawned helper while its prompt runs.")
                    XCTAssertTrue(ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: run.runID))

                    try await reused.finishPrompt()

                    let remaining = await run.pendingPolicyCount()
                    XCTAssertEqual(remaining, 0, "Turn \(turn)'s terminal teardown removes its unused policy.")
                    XCTAssertFalse(ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: run.runID))
                    await run.assertOwner(run.c1)
                }
                XCTAssertEqual(
                    reused.events.entries,
                    [.policyInstalled, .promptSubmitted, .policyInstalled, .promptSubmitted]
                )
            }
        }

        /// No later turn settles this turn's admission as its predecessor, so only the turn's own
        /// teardown can release the issuer's record of it.
        func testSessionEndingAfterItsFirstTurnRetainsNoFollowUpBookkeeping() async throws {
            try await withReusedOpenCodeSession { run, reused in
                try await reused.submit("The session's only turn")
                try await reused.finishPrompt()
                await reused.end()

                XCTAssertFalse(ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: run.runID))
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                XCTAssertEqual(reused.events.entries, [.policyInstalled, .promptSubmitted])
            }
        }

        // MARK: Follow-up fixture

        /// Issues follow-up turn admissions for the fixture's run through the runner's issuer, each
        /// with a real agent-mode lease.
        @MainActor
        private final class FollowUpTurns {
            private let run: ExpectedPIDRunFixture
            private let tabID: UUID
            private let admissions = ACPFollowUpRespawnAdmissions()
            private var issued: [ACPFollowUpRespawnAdmission] = []
            private(set) var leaseCount = 0

            init(run: ExpectedPIDRunFixture, tabID: UUID) {
                self.run = run
                self.tabID = tabID
            }

            func begin(agentKind: AgentProviderKind = .openCode) -> ACPFollowUpRespawnAdmission? {
                let admission = admissions.make(agentKind: agentKind, runID: run.runID) { runID in
                    leaseCount += 1
                    return MCPBootstrapLease(spec: .agentMode(
                        tabID: tabID,
                        runID: runID,
                        gateID: UUID(),
                        windowID: run.window.windowID,
                        agent: agentKind
                    ))
                }
                if let admission {
                    issued.append(admission)
                }
                return admission
            }

            func settleAll() async {
                for admission in issued {
                    await admission.settle(.completed)
                }
            }
        }

        private func withFollowUpRun(_ body: (ExpectedPIDRunFixture, FollowUpTurns) async throws -> Void) async throws {
            try await ExpectedPIDRunFixture.withEstablishedRun(
                sessionName: "OpenCode follow-up fixture session",
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools
            ) { run in
                let turns = try FollowUpTurns(run: run, tabID: XCTUnwrap(run.tabID))
                run.cleanup.add { await turns.settleAll() }
                try await body(run, turns)
            }
        }

        /// The peer session's helper reconnects with its own ticket from a process unrelated to the run.
        private static func reconnect(_ peer: PeerRun, in run: ExpectedPIDRunFixture) async -> String {
            await run.apply(
                peer.reconnectID,
                sessionKey: peer.token,
                clientPid: ExpectedPIDRunFixture.unrelatedHelperPID
            ).outcome
        }

        // MARK: Reused OpenCode session fixture

        /// The fixture's established run serves a reused OpenCode session: its helper is the routed
        /// owner C1, and the tab keeps the run and an open controller between turns.
        private func withReusedOpenCodeSession(
            _ body: (ExpectedPIDRunFixture, ReusedOpenCodeSession) async throws -> Void
        ) async throws {
            let workspace = try makeTestDirectory()
            let agentDirectory = try makeTestDirectory(name: "\(#function)-agent")
            let scriptURL = agentDirectory.appendingPathComponent("fake_opencode_acp_agent.py")
            try Self.writeFakeOpenCodeAgent(to: scriptURL)
            try await ExpectedPIDRunFixture.withEstablishedRun(
                sessionName: "OpenCode reused session",
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools
            ) { run in
                let reused = try await ReusedOpenCodeSession.open(
                    on: run,
                    workspace: workspace,
                    scriptURL: scriptURL,
                    releaseDirectory: agentDirectory
                )
                run.cleanup.add { await reused.tearDown() }
                try await body(run, reused)
            }
        }

        /// A live view-model tab whose reused OpenCode session is a real ACP controller on a fake
        /// agent. The agent holds each prompt's reply until the test finishes that prompt.
        @MainActor
        private final class ReusedOpenCodeSession {
            enum Failure: Error {
                case promptNotSubmitted
                case turnDidNotFinish
            }

            let viewModel: AgentModeViewModel
            let session: AgentModeViewModel.TabSession
            let controller: ACPAgentSessionController
            let events: FollowUpTurnEventLog
            private let runID: UUID
            private let releaseDirectory: URL
            private var submittedPrompts = 0
            private var finishedPrompts = 0

            private init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                controller: ACPAgentSessionController,
                events: FollowUpTurnEventLog,
                runID: UUID,
                releaseDirectory: URL
            ) {
                self.viewModel = viewModel
                self.session = session
                self.controller = controller
                self.events = events
                self.runID = runID
                self.releaseDirectory = releaseDirectory
            }

            /// Policies go through the view model's installer to the shared MCP manager, recording
            /// each installation. A turn that misses the reuse branch fails at provider creation.
            static func open(
                on run: ExpectedPIDRunFixture,
                workspace: URL,
                scriptURL: URL,
                releaseDirectory: URL
            ) async throws -> ReusedOpenCodeSession {
                let tabID = try XCTUnwrap(run.tabID)
                let events = FollowUpTurnEventLog()
                let provider = FakeOpenCodeProvider(
                    scriptPath: scriptURL.path,
                    releaseDirectory: releaseDirectory.path,
                    events: events
                )
                let controller = try ACPAgentSessionController(
                    provider: provider,
                    runRequest: ACPRunRequest(
                        agentKind: .openCode,
                        modelString: nil,
                        workspacePath: workspace.path,
                        resumeSessionID: nil,
                        attachments: [],
                        taskLabelKind: nil
                    )
                )
                do {
                    _ = try await controller.bootstrap()
                } catch {
                    await controller.shutdown()
                    throw error
                }
                let codex = StartupTestCodexController(gatesStartup: false)
                let viewModel = AgentModeViewModel(
                    testWindowID: run.window.windowID,
                    testWorkspacePath: workspace.path,
                    testWorkspaceDirectory: workspace,
                    codexControllerFactory: { _, _, _, _, _, _ in codex },
                    acpProviderFactory: { _, _ in nil },
                    connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
                        events.record(.policyInstalled)
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
                    },
                    testOpenCodeModelParameterStreamProvider: { _, _ in AsyncStream { $0.finish() } }
                )
                viewModel.test_agentAvailabilityForRunOverride = { _ in true }
                let session = AgentModeViewModel.TabSession(tabID: tabID)
                session.hasLoadedPersistedState = true
                session.selectedAgent = .openCode
                session.acpController = controller
                session.installRunID(run.runID)
                viewModel.test_installLiveSession(session)
                return ReusedOpenCodeSession(
                    viewModel: viewModel,
                    session: session,
                    controller: controller,
                    events: events,
                    runID: run.runID,
                    releaseDirectory: releaseDirectory
                )
            }

            /// Submits a turn and returns once its prompt is submitted; the agent holds the reply.
            func submit(_ text: String, file: StaticString = #filePath, line: UInt = #line) async throws {
                XCTAssertEqual(session.runID, runID, "The tab keeps the run its reused session serves.", file: file, line: line)
                let reusable = await controller.hasReusableSession
                XCTAssertTrue(reusable, "The tab's controller still has an open session.", file: file, line: line)
                XCTAssertEqual(viewModel.submitUserTurn(text: text, tabID: session.tabID), .submitted, file: file, line: line)
                submittedPrompts += 1
                let prompt = submittedPrompts
                let events = events
                guard await startupTestWaitBounded(seconds: 10, until: { events.promptCount >= prompt }) else {
                    XCTFail("Prompt \(prompt) was not submitted; errors: \(errorTexts)", file: file, line: line)
                    throw Failure.promptNotSubmitted
                }
            }

            /// Lets the agent answer the held prompt, then waits for the turn to complete and for its
            /// terminal teardown to finish.
            func finishPrompt(file: StaticString = #filePath, line: UInt = #line) async throws {
                let turn = try XCTUnwrap(session.agentTask, "The submitted turn is running.", file: file, line: line)
                finishedPrompts += 1
                try release(finishedPrompts)
                guard await startupTestJoinBounded(
                    turn,
                    "The turn did not finish after its prompt was answered.",
                    seconds: 10,
                    file: file,
                    line: line
                ) else {
                    throw Failure.turnDidNotFinish
                }
                // Cancelling a terminal run only waits for its publication and teardown.
                guard session.runState.isTerminalForCommit else {
                    XCTFail("The turn ended in \(session.runState); errors: \(errorTexts)", file: file, line: line)
                    throw Failure.turnDidNotFinish
                }
                XCTAssertEqual(session.runState, .completed, "errors: \(errorTexts)", file: file, line: line)
                let viewModel = viewModel
                let tabID = session.tabID
                await startupTestAwaitBounded(
                    "The turn's terminal teardown did not finish.",
                    seconds: 10,
                    file: file,
                    line: line
                ) {
                    await viewModel.cancelAgentRun(tabID: tabID, completion: .terminalTeardownCompleted)
                }
            }

            /// Ends the session as closing its tab ends the provider: the agent process exits.
            func end(file: StaticString = #filePath, line: UInt = #line) async {
                await controller.shutdown()
                let reusable = await controller.hasReusableSession
                XCTAssertFalse(reusable, file: file, line: line)
            }

            /// Answers every held prompt so no turn stays parked, then stops anything still running.
            func tearDown() async {
                if submittedPrompts > finishedPrompts {
                    for prompt in (finishedPrompts + 1) ... submittedPrompts {
                        try? release(prompt)
                    }
                }
                if session.runState.isActive {
                    let viewModel = viewModel
                    let tabID = session.tabID
                    await startupTestAwaitBounded("The reused session's run did not stop.", seconds: 10) {
                        await viewModel.cancelAgentRun(tabID: tabID, completion: .terminalTeardownCompleted)
                    }
                }
                await controller.shutdown()
            }

            private var errorTexts: [String] {
                session.items.filter { $0.kind == .error }.map(\.text)
            }

            private func release(_ prompt: Int) throws {
                try Data().write(to: releaseDirectory.appendingPathComponent("release-\(prompt)"))
            }
        }

        /// What the runner did for each turn, in order: a policy installation through the view
        /// model's installer, and a prompt the controller built for submission.
        final class FollowUpTurnEventLog: @unchecked Sendable {
            enum Entry: Equatable {
                case policyInstalled
                case promptSubmitted
            }

            private let lock = NSLock()
            private var recorded: [Entry] = []

            var entries: [Entry] {
                lock.withLock { recorded }
            }

            var promptCount: Int {
                lock.withLock { recorded.count { $0 == .promptSubmitted } }
            }

            func record(_ entry: Entry) {
                lock.withLock { recorded.append(entry) }
            }
        }

        /// OpenCode's provider identity over the fake agent; records each prompt it builds.
        private struct FakeOpenCodeProvider: ACPAgentProvider {
            let providerID: ACPProviderID = .openCode
            let scriptPath: String
            let releaseDirectory: String
            let events: FollowUpTurnEventLog

            func support(for _: ACPRunRequest) async -> ACPSupportResult {
                .supported
            }

            func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
                ACPLaunchConfiguration(
                    providerID: providerID,
                    command: scriptPath,
                    arguments: [],
                    environment: ["ACP_RELEASE_DIR": releaseDirectory],
                    workingDirectory: request.workspacePath,
                    additionalPathHints: [],
                    enableDebugLogging: false
                )
            }

            func makeSessionConfiguration(
                for request: ACPRunRequest,
                mcpServer _: RepoPromptMCPServerConfiguration
            ) throws -> ACPSessionConfiguration {
                ACPSessionConfiguration(
                    mode: .new,
                    workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
                    mcpServers: []
                )
            }

            func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
                events.record(.promptSubmitted)
                return [["type": "text", "text": message.userMessage]]
            }

            func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
                []
            }

            func normalizeError(_ error: Error) -> Error {
                error
            }
        }

        /// An ACP agent advertising OpenCode's managed session modes. It answers prompt N only once
        /// `release-N` exists in `ACP_RELEASE_DIR`, and on its own after 30 seconds.
        private static func writeFakeOpenCodeAgent(to url: URL) throws {
            let script = #"""
            #!/usr/bin/env python3
            import json
            import os
            import sys
            import time
            release_dir = os.environ["ACP_RELEASE_DIR"]
            modes = ["repoprompt_acp", "repoprompt_acp_full_access"]
            current_mode = modes[0]
            prompts = 0
            def config_options():
                return [{
                    "id": "mode",
                    "name": "Mode",
                    "category": "mode",
                    "type": "select",
                    "currentValue": current_mode,
                    "options": [{"value": mode, "name": mode} for mode in modes],
                }]
            def respond(request_id, result):
                print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
            for line in sys.stdin:
                try:
                    request = json.loads(line)
                except Exception:
                    continue
                if "id" not in request or "method" not in request:
                    continue
                method = request["method"]
                params = request.get("params") or {}
                if method == "initialize":
                    respond(request["id"], {"agentCapabilities": {"loadSession": True}, "authMethods": []})
                elif method == "session/new":
                    respond(request["id"], {"sessionId": "opencode-reused-session", "configOptions": config_options()})
                elif method == "session/set_config_option":
                    if params.get("configId") == "mode":
                        current_mode = params.get("value")
                    respond(request["id"], {"configOptions": config_options()})
                elif method == "session/prompt":
                    prompts += 1
                    release = os.path.join(release_dir, "release-%d" % prompts)
                    deadline = time.time() + 30
                    while not os.path.exists(release) and time.time() < deadline:
                        time.sleep(0.01)
                    respond(request["id"], {"stopReason": "end_turn"})
                else:
                    respond(request["id"], {})
            """#
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    #endif
}
