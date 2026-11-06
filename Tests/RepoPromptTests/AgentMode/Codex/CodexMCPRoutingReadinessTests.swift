import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

#if DEBUG
    /// The pre-first-turn MCP routing boundary for a Codex child. A child whose RepoPrompt MCP
    /// routing confirms dispatches its first turn exactly once; one whose routing never confirms
    /// fails closed with one precise failed publication, no first turn, and no leftover bootstrap
    /// gate, routing waiter, or pending connection policy; a start cancelled during the routing wait
    /// dispatches nothing and reports no readiness failure. A started thread replaces the tab's
    /// saved thread only once its route is confirmed, and no other caller uses it before then.
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
        private let routingUnavailableMessage = "Codex startup failed: MCP routing was not confirmed for this run."
        private let savedThreadID = "saved-thread"
        private let savedRolloutPath = "/tmp/codex-routing-readiness-saved-rollout.jsonl"
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

            // Cancelled after routing confirmed, while the route owner is still being checked.
            let ownerCheck = StartupTestHeldGate()
            try await withRoutingFixture(
                routesOnPolicyInstall: true,
                routingTimeoutMs: 60000,
                routeOwnerValidator: { _, _, _, _ in
                    await ownerCheck.wait()
                    return true
                }
            ) { fixture in
                let label = "cancelled during the route-owner check"
                fixture.cleanup.heldGates.append(ownerCheck)
                installSavedThread(on: fixture.session)
                let ticket = try fixture.submit("first")
                try await startupTestEventually { ownerCheck.isWaiting }
                let runID = try XCTUnwrap(fixture.policies.runIDs.first)

                let cancellation = startupTestRunTracked(
                    { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) },
                    in: fixture.cleanup.trackedOperations
                )
                try await startupTestEventually { ticket.task?.isCancelled == true }
                ownerCheck.release()
                try await startupTestJoin(ticket.task)
                try await startupTestEventually { cancellation.value }

                await assertSavedThreadKept(fixture, label)
                XCTAssertNil(fixture.session.codexController, "\(label): the unpublished controller was kept")
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [], label)
                XCTAssertEqual(fixture.errorTexts, [], "\(label): cancellation was reported as a readiness failure")
                XCTAssertEqual(fixture.publishedStates, [.cancelled], label)
                try await assertNoBootstrapStateRemains(for: runID)
            }
        }

        /// A resumed thread whose route never confirms replaces nothing: what a save would write
        /// still names the saved thread, and the run fails once without a first turn. A caller
        /// outside startup that already installed a policy for its run, as the event-stream restart
        /// does, still stages its start behind one routing wait of its own.
        func testUnroutedResumePublishesNothing() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: false) { fixture in
                installSavedThread(on: fixture.session)

                let ticket = try fixture.submit("next")
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.controller.startOrResumeTargets.map { $0?.conversationID }, [savedThreadID])
                await assertSavedThreadKept(fixture)
                XCTAssertNil(fixture.session.codexNativeStartupDisposition)
                XCTAssertNil(fixture.session.codexController)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
                XCTAssertEqual(fixture.errorTexts, [routingTimeoutMessage])
                XCTAssertEqual(fixture.publishedStates, [.failed])
                XCTAssertEqual(fixture.session.runState, .failed)
            }

            try await withRoutingFixture(routesOnPolicyInstall: false, routingTimeoutMs: 60000) { fixture in
                let label = "policy already installed"
                installSavedThread(on: fixture.session)
                fixture.session.runState = .running
                fixture.session.beginRunAttempt(source: "codex-routing-readiness-restart")
                let coordinator = fixture.viewModel.test_codexCoordinator
                let restart = Task {
                    await coordinator.ensureCodexNativeSession(
                        session: fixture.session,
                        policyAlreadyInstalled: true,
                        preserveExistingRunID: true
                    )
                }
                fixture.cleanup.join(restart)
                try await startupTestEventually { coordinator.test_hasPendingCodexStart(for: fixture.session) }
                let runID = try await awaitRoutingWait(fixture)
                let pendingPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: codexClientName)
                XCTAssertEqual(pendingPolicies.count(where: { $0.runID == runID }), 1, "\(label): pending policies for the run")
                await assertSavedThreadKept(fixture, "\(label) while routing is pending")

                await MCPRoutingWaiter.notifyFailed(runID: runID)
                guard await startupTestJoinBounded(restart, "\(label): the restart did not finish") else { return }
                guard case .failed = await restart.value else {
                    return XCTFail("\(label): an unrouted restart did not fail")
                }
                await assertSavedThreadKept(fixture, label)
                XCTAssertNil(fixture.session.codexController, label)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [], label)
                fixture.session.runState = .idle
            }
        }

        /// A resume whose rollout is missing falls back to a fresh thread, but an unrouted fallback
        /// neither replaces the saved thread nor announces itself.
        func testUnroutedFreshFallbackKeepsTheSavedConversation() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: false) { fixture in
                installSavedThread(on: fixture.session)
                fixture.controller.scriptedStarts = [
                    .missingRollout(rolloutPath: savedRolloutPath),
                    .succeed(threadID: "unrouted-fresh-thread")
                ]

                let ticket = try fixture.submit("next")
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.controller.startOrResumeTargets.map { $0?.conversationID }, [savedThreadID, nil])
                await assertSavedThreadKept(fixture)
                XCTAssertNil(fixture.session.codexNativeStartupDisposition)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
                XCTAssertEqual(fixture.errorTexts, [routingTimeoutMessage])
                XCTAssertEqual(fixture.publishedStates, [.failed])
                XCTAssertEqual(freshThreadNoticeCount(fixture), 0, "an unpublished fallback was announced")
            }
        }

        /// Routing confirmation is when a fresh fallback becomes the tab's thread: it is published
        /// once, with its notice and a reset resume-timeout count, and a later idle start reuses it.
        func testRoutedFreshFallbackCommitsTheNewIdentityOnce() async throws {
            try await withRoutingFixture(routesOnPolicyInstall: false, routingTimeoutMs: 60000) { fixture in
                installSavedThread(on: fixture.session)
                fixture.session.codexResumeTimeoutState = .init(
                    conversationID: savedThreadID,
                    rolloutPath: savedRolloutPath,
                    consecutiveTimeouts: 1
                )
                fixture.controller.scriptedStarts = [
                    .missingRollout(rolloutPath: savedRolloutPath),
                    .succeed(threadID: "routed-fresh-thread")
                ]
                let coordinator = fixture.viewModel.test_codexCoordinator
                let ticket = try fixture.submit("next")
                try await startupTestEventually { coordinator.test_hasPendingCodexStart(for: fixture.session) }
                let runID = try await awaitRoutingWait(fixture)
                await assertSavedThreadKept(fixture, "while routing is pending")
                XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 1)
                XCTAssertEqual(freshThreadNoticeCount(fixture), 0)

                await MCPRoutingWaiter.notifyRouted(runID: runID)
                try await startupTestJoin(ticket.task)

                XCTAssertEqual(fixture.session.codexConversationID, "routed-fresh-thread")
                XCTAssertNil(fixture.session.codexRolloutPath, "a fresh thread has no rollout before its first turn")
                XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, "routed-fresh-thread")
                XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumeFellBackToFresh)
                XCTAssertFalse(fixture.session.codexNeedsReconnect)
                XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
                XCTAssertEqual(freshThreadNoticeCount(fixture), 1)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, ["next"])
                XCTAssertFalse(coordinator.test_hasPendingCodexStart(for: fixture.session))

                try await fixture.completeActiveTurn(turnID: "routed-fresh-turn")
                try await fixture.awaitCompletedTurn()
                _ = await coordinator.ensureCodexNativeSession(session: fixture.session)
                XCTAssertEqual(fixture.controller.startOrResumeCount, 2, "a later idle start restarted the committed thread")
                XCTAssertEqual(freshThreadNoticeCount(fixture), 1)
                await assertSavedThreadPublished(fixture, threadID: "routed-fresh-thread")
            }
        }

        /// Two resume timeouts make the next start fresh; when that fresh start never routes, the
        /// saved thread and the timeout count both stay, so the send after it starts fresh again
        /// instead of resuming either the timed-out thread or the unrouted one.
        func testRoutingFailureAfterResumeTimeoutsKeepsTheSavedTupleAndLaterSendStartsFresh() async throws {
            let controllers = StartupTestCodexControllerRecorder()
            controllers.scriptedStartsByController = [
                [.resumeTimeout],
                [.resumeTimeout],
                [.succeed(threadID: "unrouted-fresh-thread")],
                [.succeed(threadID: "later-fresh-thread")]
            ]
            try await withRoutingFixture(routesOnPolicyInstall: false, controllers: controllers) { fixture in
                installSavedThread(on: fixture.session)
                let first = try fixture.submit("first")
                try await startupTestJoin(first.task)
                XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 1)

                let second = try fixture.submit("second")
                try await startupTestJoin(second.task)

                XCTAssertEqual(
                    controllers.controllers.map { $0.startOrResumeTargets.map { $0?.conversationID } },
                    [[savedThreadID], [savedThreadID], [nil]]
                )
                await assertSavedThreadKept(fixture)
                XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 2)
                XCTAssertFalse(fixture.session.codexNeedsReconnect)
                XCTAssertEqual(fixture.errorTexts.last, routingTimeoutMessage)
                XCTAssertEqual(freshThreadNoticeCount(fixture), 0)

                let later = try fixture.submit("later")
                try await startupTestJoin(later.task)

                XCTAssertEqual(controllers.controllers.count, 4)
                XCTAssertEqual(
                    controllers.controllers.last?.startOrResumeTargets.map { $0?.conversationID },
                    [nil],
                    "the later send resumed a thread"
                )
                await assertSavedThreadKept(fixture, "after the later send")
                XCTAssertEqual(controllers.controllers.flatMap(\.startUserTurnTexts), [])
            }
        }

        /// While a start waits for its route, every other caller is turned away before it changes
        /// anything; the start then publishes its thread once and sends its own first turn.
        func testCompetingCallersCannotUseAnUnpublishedStart() async throws {
            let authRecovery = CountingAuthRecovery()
            try await withRoutingFixture(routesOnPolicyInstall: true, authRecovery: authRecovery) { fixture in
                installSavedThread(on: fixture.session)
                let heldStart = StartupTestHeldGate()
                fixture.cleanup.heldGates.append(heldStart)
                fixture.controller.startupHook = { _ in await heldStart.wait() }
                fixture.controller.scriptedStarts = [.succeed(threadID: "claimed-thread")]
                let session = fixture.session
                let coordinator = fixture.viewModel.test_codexCoordinator
                let ticket = try fixture.submit("first")
                try await startupTestEventually { heldStart.isWaiting }

                let ensure = Task { await coordinator.ensureCodexNativeSession(session: session) }
                fixture.cleanup.join(ensure)
                guard await startupTestJoinBounded(ensure, "a second ensure waited on the held start") else { return }
                if case .startupInProgress = await ensure.value {} else {
                    await XCTFail("a second ensure was not turned away: \(ensure.value)")
                }

                let waitDrainCalls = StartupTestCounter()
                coordinator.setActiveAgentRunWaitDrain { _, _, _, _ in
                    waitDrainCalls.value += 1
                    return true
                }
                let send = Task { await coordinator.sendCodexNativeMessage(session: session, text: "duplicate", attachments: []) }
                fixture.cleanup.join(send)
                guard await startupTestJoinBounded(send, "a send waited on the held start") else { return }
                let sendOutcome = await send.value
                XCTAssertEqual(
                    sendOutcome,
                    .preDispatchRejected(message: "Codex did not send because thread routing is still being confirmed.")
                )
                XCTAssertEqual(waitDrainCalls.value, 0, "a rejected send woke child agent_run.wait scopes")

                let routingMessage = "Wait for Codex routing confirmation before using a native command."
                for command in [CodexAgentModeCoordinator.NativeSlashCommand.compact, .goal] {
                    let execution = Task { await coordinator.executeNativeSlashCommand(command, argumentsText: "", session: session) }
                    fixture.cleanup.join(execution)
                    guard await startupTestJoinBounded(execution, "/\(command.rawValue) waited on the held start") else { return }
                    let result = await execution.value
                    XCTAssertEqual(result, .failed(routingMessage), "/\(command.rawValue)")
                }

                let recovery = Task { await coordinator.test_attemptCodexStallRecovery(session: session) }
                fixture.cleanup.join(recovery)
                guard await startupTestJoinBounded(recovery, "stall recovery waited on the held start") else { return }
                let recoveryFailed = await recovery.value
                XCTAssertFalse(recoveryFailed, "stall recovery reported the held start unrecoverable")
                XCTAssertEqual(fixture.controller.snapshotReadCount, 0, "stall recovery probed the held start's thread")

                let authIssue = CodexNativeSessionController.ServerRequestIssue(
                    requestID: .int(1),
                    method: "account/chatgptAuthTokens/refresh",
                    kind: .authTokensRefreshFailed,
                    message: "token refresh failed"
                )
                await coordinator.test_handleCodexNativeEvent(
                    .serverRequestIssue(authIssue),
                    session: session,
                    sourceController: fixture.controller
                )
                XCTAssertEqual(authRecovery.refreshCount, 0, "auth recovery refreshed during the held start")

                XCTAssertEqual(fixture.controller.startOrResumeTargets.map { $0?.conversationID }, [savedThreadID])
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
                await assertSavedThreadKept(fixture, "while the start is held")

                heldStart.release()
                try await startupTestJoin(ticket.task)
                XCTAssertEqual(session.codexConversationID, "claimed-thread")
                XCTAssertEqual(fixture.controller.startOrResumeCount, 1)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, ["first"])
            }
        }

        /// A recovered auth retry that loses the startup claim fails visibly instead of treating
        /// the pending turn as handled or publishing the competing start's thread.
        func testManagedAuthRetryFailsWhenCompetingStartupClaimsBeforeReplay() async throws {
            let refreshGate = StartupTestHeldGate()
            let authRecovery = CountingAuthRecovery(gate: refreshGate)
            let controllers = StartupTestCodexControllerRecorder()
            controllers.scriptedStartsByController = [
                [],
                [.succeed(threadID: "competing-start-thread")]
            ]
            let message = "auth retry turn"
            let replayBlockedMessage = "Codex authentication was refreshed, but the message was not resent because another Codex startup was still confirming thread routing. Send it again."

            try await withRoutingFixture(
                routesOnPolicyInstall: false,
                routingTimeoutMs: 60000,
                controllers: controllers,
                authRecovery: authRecovery
            ) { fixture in
                fixture.cleanup.heldGates.append(refreshGate)
                let first = try fixture.submit(message)
                let runID = try await awaitRoutingWait(fixture)
                await MCPRoutingWaiter.notifyRouted(runID: runID)
                try await startupTestJoin(first.task)

                XCTAssertEqual(controllers.controllers.flatMap(\.startUserTurnTexts), [message])
                XCTAssertEqual(fixture.session.codexPendingAuthRetryTurn?.text, message)
                await MCPRoutingWaiter.cleanup(runID: runID)

                let coordinator = fixture.viewModel.test_codexCoordinator
                let authIssue = CodexNativeSessionController.ServerRequestIssue(
                    requestID: .int(2),
                    method: "account/chatgptAuthTokens/refresh",
                    kind: .authTokensRefreshFailed,
                    message: "token refresh failed"
                )
                let recovery = Task {
                    await coordinator.test_handleCodexNativeEvent(
                        .serverRequestIssue(authIssue),
                        session: fixture.session,
                        sourceController: fixture.controller
                    )
                }
                fixture.cleanup.join(recovery)
                try await startupTestEventually { refreshGate.isWaiting }
                XCTAssertEqual(authRecovery.refreshCount, 1)

                // A reconnecting caller takes the startup claim and holds it at route confirmation.
                fixture.session.codexNeedsReconnect = true
                let competingStart = Task {
                    await coordinator.ensureCodexNativeSession(session: fixture.session)
                }
                fixture.cleanup.join(competingStart)
                try await startupTestEventually {
                    controllers.controllers.count == 2
                        && coordinator.test_hasPendingCodexStart(for: fixture.session)
                }
                let competingRunID = try XCTUnwrap(fixture.policies.runIDs.last)
                _ = try await awaitRoutingWait(fixture, runID: competingRunID)

                XCTAssertEqual(fixture.session.codexConversationID, "startup-ticket-test")
                XCTAssertEqual(controllers.controllers[1].startUserTurnTexts, [])

                refreshGate.release()
                guard await startupTestJoinBounded(
                    recovery,
                    "managed-auth recovery did not settle while the competing startup held its claim"
                ) else { return }

                XCTAssertEqual(fixture.session.runState, .failed)
                XCTAssertEqual(fixture.errorTexts, [replayBlockedMessage])
                XCTAssertEqual(controllers.controllers.flatMap(\.startUserTurnTexts), [message])
                XCTAssertEqual(
                    fixture.session.codexConversationID,
                    "startup-ticket-test",
                    "managed-auth recovery published the competing startup's thread"
                )

                await MCPRoutingWaiter.notifyFailed(runID: competingRunID)
                guard await startupTestJoinBounded(
                    competingStart,
                    "the competing startup did not finish after its routing gate was released"
                ) else { return }

                XCTAssertEqual(fixture.session.runState, .failed)
                XCTAssertEqual(fixture.errorTexts, [replayBlockedMessage])
                XCTAssertEqual(fixture.session.codexConversationID, "startup-ticket-test")
                XCTAssertNotEqual(fixture.session.codexConversationID, "competing-start-thread")
            }
        }

        /// A warm readiness check that resumes while a replacement start is still waiting for routing
        /// must not report the replacement controller as ready.
        func testWarmReadinessDoesNotAdoptReplacementWhileItsRouteIsPending() async throws {
            let controllers = StartupTestCodexControllerRecorder()
            controllers.scriptedStartsByController = [
                [.succeed(threadID: "initial-thread")],
                [.succeed(threadID: "replacement-thread")]
            ]
            try await withRoutingFixture(
                routesOnPolicyInstall: false,
                routingTimeoutMs: 60000,
                controllers: controllers
            ) { fixture in
                let initial = try fixture.submit("initial")
                let initialRunID = try await awaitRoutingWait(fixture)
                await MCPRoutingWaiter.notifyRouted(runID: initialRunID)
                try await startupTestJoin(initial.task)
                XCTAssertEqual(fixture.session.runState, .running)

                let readyGate = StartupTestHeldGate()
                fixture.cleanup.heldGates.append(readyGate)
                let coordinator = fixture.viewModel.test_codexCoordinator
                coordinator.test_setReadySessionToolTrackingGate {
                    await readyGate.wait()
                }
                let warmReadiness = Task {
                    await coordinator.ensureCodexNativeSession(
                        session: fixture.session,
                        semanticRunState: .idle
                    )
                }
                fixture.cleanup.join(warmReadiness)
                try await startupTestEventually { readyGate.isWaiting }

                let replacement = Task {
                    await coordinator.ensureCodexNativeSession(session: fixture.session)
                }
                fixture.cleanup.join(replacement)
                try await startupTestEventually {
                    coordinator.test_hasPendingCodexStart(for: fixture.session)
                }
                let replacementRunID = try XCTUnwrap(fixture.policies.runIDs.last)
                _ = try await awaitRoutingWait(fixture, runID: replacementRunID)

                readyGate.release()
                guard await startupTestJoinBounded(
                    warmReadiness,
                    "the warm readiness check did not finish"
                ) else { return }
                let warmResult = await warmReadiness.value
                await MCPRoutingWaiter.notifyRouted(runID: replacementRunID)
                guard await startupTestJoinBounded(replacement, "the replacement did not finish") else { return }
                let replacementResult = await replacement.value

                if case .startupInProgress = warmResult {} else {
                    XCTFail("warm readiness adopted an unrouted replacement: \(warmResult)")
                }
                if case let .ready(ready) = replacementResult {
                    XCTAssertEqual(ready.threadID, "replacement-thread")
                    XCTAssertEqual(fixture.session.codexConversationID, "replacement-thread")
                } else {
                    XCTFail("the routed replacement did not become ready: \(replacementResult)")
                }
            }
        }

        /// A `.routed` signal is not enough to publish a start: a route the current controller's
        /// process does not own is revoked, and the start fails without replacing the saved thread.
        func testRoutedSignalWithoutCurrentControllerAuthorityCannotCommit() async throws {
            try await withRoutingFixture(
                routesOnPolicyInstall: true,
                routeOwnerValidator: { _, _, _, _ in false }
            ) { fixture in
                installSavedThread(on: fixture.session)
                let ticket = try fixture.submit("next")
                try await startupTestJoin(ticket.task)

                let runID = try XCTUnwrap(fixture.policies.runIDs.first)
                await assertSavedThreadKept(fixture)
                XCTAssertNil(fixture.session.codexController)
                XCTAssertFalse(fixture.session.codexNeedsReconnect)
                XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
                XCTAssertEqual(fixture.errorTexts, [routingUnavailableMessage])
                XCTAssertEqual(fixture.publishedStates, [.failed])
                try await assertNoBootstrapStateRemains(for: runID)
            }
        }

        /// A start whose run, attempt, or controller changed while it waited for routing publishes
        /// nothing, retires only the controller it started, and leaves a successor's alone.
        func testLateStartupCannotPublishOrRetireASuccessor() async throws {
            try await withStagedStart { fixture, controllers, start, runID in
                let label = "run replaced"
                fixture.session.installRunID(UUID())
                await MCPRoutingWaiter.notifyRouted(runID: runID)
                guard case .superseded = await start.value else {
                    return XCTFail("\(label): the start was not superseded")
                }
                await assertSavedThreadKept(fixture, label)
                XCTAssertEqual(freshThreadNoticeCount(fixture), 0, label)
                XCTAssertEqual(controllers.controllers.flatMap(\.startUserTurnTexts), [], label)
            }

            try await withStagedStart { fixture, controllers, start, runID in
                let label = "same-run attempt drift"
                let coordinator = fixture.viewModel.test_codexCoordinator
                fixture.session.beginRunAttempt(source: "codex-routing-readiness-successor")
                XCTAssertEqual(fixture.session.runID, runID, label)
                await MCPRoutingWaiter.notifyRouted(runID: runID)
                guard case .superseded = await start.value else {
                    return XCTFail("\(label): the start was not superseded")
                }
                await assertSavedThreadKept(fixture, label)
                XCTAssertNil(fixture.session.codexController, "\(label): the unpublished controller was kept")
                XCTAssertFalse(fixture.session.codexNeedsReconnect, label)
                try await startupTestEventually { controllers.controllers[0].shutdownCount == 1 }

                fixture.session.runState = .idle
                fixture.session.beginRunAttempt(source: "codex-routing-readiness-later-send")
                let later = Task {
                    await coordinator.sendCodexNativeMessage(session: fixture.session, text: "later", attachments: [])
                }
                fixture.cleanup.join(later)
                try await startupTestEventually { controllers.controllers.count == 2 && coordinator.test_hasPendingCodexStart(for: fixture.session) }
                XCTAssertEqual(
                    controllers.controllers[1].startOrResumeTargets.map { $0?.conversationID },
                    [savedThreadID],
                    "\(label): the later send did not resume the saved thread"
                )
                try await MCPRoutingWaiter.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
                guard await startupTestJoinBounded(later, "\(label): the later send did not finish") else { return }
                await assertSavedThreadKept(fixture, "\(label), after the later send")
                XCTAssertEqual(controllers.controllers.flatMap(\.startUserTurnTexts), [], label)
            }

            try await withStagedStart { fixture, controllers, start, runID in
                let label = "successor controller installed"
                fixture.session.beginRunAttempt(source: "codex-routing-readiness-successor-controller")
                let successor = StartupTestCodexController(gatesStartup: false)
                fixture.session.codexController = successor
                await MCPRoutingWaiter.notifyRouted(runID: runID)
                guard case .superseded = await start.value else {
                    return XCTFail("\(label): the start was not superseded")
                }
                await assertSavedThreadKept(fixture, label)
                XCTAssertTrue(fixture.session.codexController === successor, "\(label): the successor was replaced")
                XCTAssertEqual(successor.shutdownCount, 0, "\(label): the successor was shut down")
                XCTAssertEqual(controllers.controllers.flatMap(\.startUserTurnTexts), [], label)
                fixture.session.codexController = nil
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
        private final class SavedSessionRecorder {
            var sessions: [AgentSession] = []
        }

        private final class CountingAuthRecovery: CodexManagedAuthRecovering, @unchecked Sendable {
            let gate: StartupTestHeldGate?
            private let lock = NSLock()
            private var refreshes = 0

            @MainActor
            init(gate: StartupTestHeldGate? = nil) {
                self.gate = gate
            }

            var refreshCount: Int {
                lock.withLock { refreshes }
            }

            func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
                lock.withLock { refreshes += 1 }
                await gate?.wait()
                return .recovered(account: nil)
            }

            func managedAccountSnapshot() async -> CodexManagedAccount? {
                nil
            }

            func startManagedChatgptLogin(
                openURL _: @MainActor @escaping @Sendable (URL) -> Void
            ) async -> CodexManagedChatgptLoginResult {
                .failed(message: "unused")
            }

            func startManagedChatgptDeviceCodeLogin(
                presentDeviceCode _: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
            ) async -> CodexManagedChatgptLoginResult {
                .failed(message: "unused")
            }

            func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
                .signedOut
            }
        }

        @MainActor
        private final class RoutingFixture: StartupTestSessionFixture {
            let policies: PolicyInstallRecorder
            let saves: SavedSessionRecorder
            private let publications = StartupTestPublicationRecorder()

            var publishedStates: [AgentSessionRunState] {
                publications.revisions.map(\.terminalState)
            }

            init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController,
                policies: PolicyInstallRecorder,
                saves: SavedSessionRecorder
            ) {
                self.policies = policies
                self.saves = saves
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
            controllers: StartupTestCodexControllerRecorder? = nil,
            authRecovery: (any CodexManagedAuthRecovering)? = nil,
            routeOwnerValidator: @escaping CodexAgentModeCoordinator.CodexRouteOwnerValidator = { _, _, _, _ in true },
            _ body: @MainActor (RoutingFixture) async throws -> Void
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let fixture = makeFixture(
                    routesOnPolicyInstall: routesOnPolicyInstall,
                    routingTimeoutMs: routingTimeoutMs,
                    shouldManageCodexTooling: shouldManageCodexTooling,
                    controllers: controllers,
                    authRecovery: authRecovery,
                    routeOwnerValidator: routeOwnerValidator
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
            shouldManageCodexTooling: Bool,
            controllers: StartupTestCodexControllerRecorder?,
            authRecovery: (any CodexManagedAuthRecovering)?,
            routeOwnerValidator: @escaping CodexAgentModeCoordinator.CodexRouteOwnerValidator
        ) -> RoutingFixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: false)
            let policies = PolicyInstallRecorder()
            let saves = SavedSessionRecorder()
            func makeController(runID: UUID) -> StartupTestCodexController {
                guard let controllers else { return controller }
                return controllers.makeController(
                    runID: runID,
                    using: controllers.controllers.isEmpty ? controller : nil
                )
            }
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
                codexControllerFactory: { runID, _, _, _, _, _ in makeController(runID: runID) },
                codexControllerFactoryWithComputerUse: { runID, _, _, _, _, _, _, _ in makeController(runID: runID) },
                connectionPolicyInstaller: policyInstaller,
                mcpServerReadinessRequirement: { try await readiness.require() },
                testCodexManagedAuthRecovery: authRecovery,
                testCodexLeaseRoutingTimeoutMs: routingTimeoutMs,
                testCodexRouteOwnerValidator: routeOwnerValidator
            )
            let fixture = RoutingFixture(
                viewModel: viewModel,
                session: startupTestCodexSession(),
                readiness: readiness,
                controller: controller,
                policies: policies,
                saves: saves
            )
            viewModel.test_setPersistenceWorkspace(WorkspaceModel(name: "Codex routing readiness", repoPaths: []))
            viewModel.test_setAgentSessionSaver { agentSession, _, _ in
                saves.sessions.append(agentSession)
                return self.storageRoot.appendingPathComponent("\(agentSession.id.uuidString).json")
            }
            return fixture
        }

        private func installSavedThread(on session: AgentModeViewModel.TabSession) {
            startupTestInstallSavedCodexHistory(
                on: session,
                conversationID: savedThreadID,
                rolloutPath: savedRolloutPath
            )
            session.providerCleanupHandle = ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: savedThreadID,
                rolloutPath: savedRolloutPath
            )
        }

        private func assertSavedThreadKept(
            _ fixture: RoutingFixture,
            _ label: String = "saved thread"
        ) async {
            let expectedHandle = ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: savedThreadID,
                rolloutPath: savedRolloutPath
            )
            XCTAssertEqual(fixture.session.codexConversationID, savedThreadID, "\(label): thread ID changed")
            XCTAssertEqual(fixture.session.codexRolloutPath, savedRolloutPath, "\(label): rollout path changed")
            XCTAssertEqual(fixture.session.providerCleanupHandle, expectedHandle, "\(label): cleanup handle changed")

            fixture.session.isDirty = true
            fixture.viewModel.scheduleSave(for: fixture.session)
            await fixture.viewModel.flushSave(for: fixture.tabID)
            XCTAssertFalse(fixture.saves.sessions.isEmpty, "\(label): no persisted session snapshot was captured")
            for savedSession in fixture.saves.sessions {
                XCTAssertEqual(savedSession.codexConversationID, savedThreadID, "\(label): a save published a new thread ID")
                XCTAssertEqual(savedSession.codexRolloutPath, savedRolloutPath, "\(label): a save published a new rollout path")
                XCTAssertEqual(savedSession.providerCleanupHandle, expectedHandle, "\(label): a save published a new cleanup handle")
            }
        }

        private func assertSavedThreadPublished(
            _ fixture: RoutingFixture,
            threadID: String
        ) async {
            fixture.session.isDirty = true
            fixture.viewModel.scheduleSave(for: fixture.session)
            await fixture.viewModel.flushSave(for: fixture.tabID)
            let savedSession = fixture.saves.sessions.last
            XCTAssertEqual(savedSession?.codexConversationID, threadID)
            XCTAssertNil(savedSession?.codexRolloutPath)
            XCTAssertEqual(savedSession?.providerCleanupHandle?.conversationID, threadID)
            XCTAssertNil(savedSession?.providerCleanupHandle?.rolloutPath)
        }

        private func freshThreadNoticeCount(_ fixture: RoutingFixture) -> Int {
            fixture.session.items.filter {
                $0.kind == .system && $0.text.contains("Started a fresh thread.")
            }.count
        }

        private func withStagedStart(
            _ body: @MainActor (
                RoutingFixture,
                StartupTestCodexControllerRecorder,
                Task<CodexAgentModeCoordinator.CodexNativeReadinessOutcome, Never>,
                UUID
            ) async throws -> Void
        ) async throws {
            let controllers = StartupTestCodexControllerRecorder()
            controllers.scriptedStartsByController = [[.succeed(threadID: "staged-thread")]]
            try await withRoutingFixture(
                routesOnPolicyInstall: false,
                routingTimeoutMs: 60000,
                controllers: controllers
            ) { fixture in
                installSavedThread(on: fixture.session)
                fixture.session.runState = .running
                fixture.session.beginRunAttempt(source: "codex-routing-readiness-staged-start")
                let coordinator = fixture.viewModel.test_codexCoordinator
                let start = Task {
                    await coordinator.ensureCodexNativeSession(session: fixture.session)
                }
                fixture.cleanup.join(start)
                try await startupTestEventually { coordinator.test_hasPendingCodexStart(for: fixture.session) }
                let runID = try await awaitRoutingWait(fixture)
                try await body(fixture, controllers, start, runID)
            }
        }

        /// Waits until the start's routing wait is suspended on its routing waiter and returns the
        /// start's run.
        private func awaitRoutingWait(
            _ fixture: RoutingFixture,
            runID expectedRunID: UUID? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> UUID {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let runID = expectedRunID ?? fixture.policies.runIDs.first,
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
