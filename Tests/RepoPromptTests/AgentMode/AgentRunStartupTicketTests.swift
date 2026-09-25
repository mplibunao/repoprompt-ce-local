import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Drives accepted Codex starts through the real submission, dispatch gate, run service,
    /// runner, and coordinator, with hydration, MCP epoch preparation, readiness, and controller
    /// startup held at explicit gates.
    @MainActor
    final class AgentRunStartupTicketTests: XCTestCase {
        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentRunStartupTicketTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        // MARK: - Dispatch gate

        func testGateRefusesServingTicketCancelledBeforeItsTaskArrivesAndAdvances() async throws {
            let gate = AgentTabSession.CodexDispatchSerialGate()
            let first = gate.issueTicket()
            let second = gate.issueTicket()

            gate.cancel(first)

            let firstGranted = try await awaitTurn(first, on: gate)
            XCTAssertFalse(firstGranted, "a cancelled ticket must be refused, not left waiting")
            XCTAssertEqual(gate.test_cancellationMarkerCount, 0, "a passed ticket kept its cancellation marker")
            let secondGranted = try await awaitTurn(second, on: gate)
            XCTAssertTrue(secondGranted)
        }

        func testGateSkipsFutureTicketCancelledBeforeItsTaskArrives() async throws {
            let gate = AgentTabSession.CodexDispatchSerialGate()
            let first = gate.issueTicket()
            let cancelled = gate.issueTicket()
            let third = gate.issueTicket()

            gate.cancel(cancelled)
            let firstGranted = try await awaitTurn(first, on: gate)
            XCTAssertTrue(firstGranted)
            let cancelledGranted = try await awaitTurn(cancelled, on: gate)
            XCTAssertFalse(cancelledGranted)

            let thirdResult = GateResult()
            Task { @MainActor in thirdResult.value = await gate.awaitTurn(third) }
            try await eventually { gate.test_hasWaiter(for: third) }
            gate.finish(first)

            try await eventually { thirdResult.value != nil }
            XCTAssertEqual(thirdResult.value, true, "the queue stopped on a cancelled ticket nobody finishes")
            XCTAssertEqual(gate.test_cancellationMarkerCount, 0)
        }

        func testGateCancelledWaiterFinishesAndNextTicketProceeds() async throws {
            let gate = AgentTabSession.CodexDispatchSerialGate()
            let first = gate.issueTicket()
            let cancelled = gate.issueTicket()
            let third = gate.issueTicket()
            let firstGranted = try await awaitTurn(first, on: gate)
            XCTAssertTrue(firstGranted)

            let cancelledResult = GateResult()
            let thirdResult = GateResult()
            Task { @MainActor in cancelledResult.value = await gate.awaitTurn(cancelled) }
            Task { @MainActor in thirdResult.value = await gate.awaitTurn(third) }
            try await eventually { gate.test_hasWaiter(for: cancelled) && gate.test_hasWaiter(for: third) }

            gate.cancel(cancelled)
            try await eventually { cancelledResult.value != nil }
            XCTAssertEqual(cancelledResult.value, false)
            XCTAssertNil(thirdResult.value)

            gate.finish(first)
            try await eventually { thirdResult.value != nil }
            XCTAssertEqual(thirdResult.value, true)
        }

        // MARK: - Accepted starts

        func testAcceptedStartDispatchesOnceUnderItsReservedRunID() async throws {
            let fixture = makeFixture()
            let ticket = try fixture.submit("first")

            try await eventually { fixture.controller.startUserTurnTexts == ["first"] }
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .accepted)
            XCTAssertEqual(ticket.optimisticUserItemID, fixture.session.items.last(where: { $0.kind == .user })?.id)
            XCTAssertNotNil(ticket.ownership)
            XCTAssertEqual(ticket.boundRunID, ticket.reservedRunID)
            XCTAssertEqual(fixture.session.runID, ticket.reservedRunID)
        }

        // MARK: - Cancellation

        func testCancelBeforeQueuedTaskRunsDispatchesNothingAndCannotRestart() async throws {
            let fixture = makeFixture()
            let ticket = try fixture.submit("cancelled before it ran")

            // Awaited inline, the cancellation runs up to its first suspension before any other
            // main-actor job, so the start is invalidated before its dispatch task can run.
            await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.startAgentRunCalls.count, 0)
            XCTAssertEqual(fixture.readiness.callCount, 0)
            XCTAssertEqual(fixture.controller.startOrResumeCount, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.session.runState, .cancelled)
            // The cancellation settled under the start's own run identity.
            XCTAssertEqual(ticket.boundRunID, ticket.reservedRunID)
        }

        func testCancelAfterPriorTerminalRunStillStopsTheNewStart() async throws {
            let fixture = makeFixture()
            let firstTicket = try fixture.submit("first")
            try await eventually { fixture.controller.startUserTurnTexts == ["first"] }
            try await settle { await firstTicket.task?.value }
            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            XCTAssertEqual(fixture.session.runState, .cancelled)
            XCTAssertNotNil(fixture.session.lastTerminalCommitRevision)

            let secondTicket = try fixture.submit("second")
            // A new submission does not inherit the previous run's terminal state.
            XCTAssertEqual(fixture.session.runState, .idle)
            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            try await settle { await secondTicket.task?.value }

            XCTAssertEqual(secondTicket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["first"])
            XCTAssertEqual(fixture.session.runState, .cancelled)
        }

        func testCancelDuringReadinessStopsBeforeNativeSetup() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let ticket = try fixture.submit("cancelled during readiness")
            try await eventually { fixture.readiness.isWaiting(1) }

            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.readiness.release(1, ready: true)
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startOrResumeCount, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.session.runState, .cancelled)
        }

        func testCancelDuringControllerStartupAndRoutingDispatchesNothing() async throws {
            let fixture = makeFixture(gateControllerStartup: true)
            let ticket = try fixture.submit("cancelled during routing")
            try await eventually { fixture.controller.isStartupWaiting }

            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.controller.releaseStartup()
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.session.runState, .cancelled)
        }

        func testLateFailureOfCancelledStartCannotTouchReplacementAttempt() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1, 2])
            let staleTicket = try fixture.submit("stale start")
            try await eventually { fixture.readiness.isWaiting(1) }
            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }

            // A replacement start that is not serialized behind the stale one, as follow-up
            // runs are, raises its own pending-start flag and installs its own task.
            fixture.session.mcpFollowUpRunPending = true
            let replacement = Task {
                await fixture.viewModel.startAgentRun(tabID: fixture.tabID, initialMessage: "replacement")
            }
            try await eventually { fixture.readiness.isWaiting(2) }
            let replacementOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            XCTAssertNotNil(fixture.session.agentTask)

            fixture.readiness.release(1, ready: false)
            try await settle { await staleTicket.task?.value }

            XCTAssertNotNil(fixture.session.agentTask, "the stale runner cleared the replacement's task")
            XCTAssertTrue(fixture.session.mcpFollowUpRunPending, "the stale start cleared the replacement's pending flag")
            XCTAssertEqual(fixture.session.activeRunOwnership, replacementOwnership)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])

            fixture.readiness.release(2, ready: true)
            try await settle { _ = await replacement.value }
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["replacement"])
        }

        func testSecondSubmissionDuringGatedStartQueuesBehindHeadWithoutReplacingIt() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            var dispatchesSeenAtEachReadinessCall: [Int] = []
            fixture.readiness.onCall = { _ in
                dispatchesSeenAtEachReadinessCall.append(fixture.controller.startUserTurnTexts.count)
            }
            let head = try fixture.submit("head")
            try await eventually { fixture.readiness.isWaiting(1) }

            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "follower", tabID: fixture.tabID), .submitted)
            let followerGateTicket = try XCTUnwrap(head.followerDispatchGateTickets.first)
            try await eventually { fixture.session.codexDispatchSerialGate.test_hasWaiter(for: followerGateTicket) }

            XCTAssertTrue(fixture.session.startupTicket === head)
            XCTAssertEqual(head.phase, .dispatching)
            XCTAssertEqual(head.followerDispatchGateTickets.count, 1)
            XCTAssertEqual(fixture.readiness.callCount, 1, "the follower ran ahead of the head start")

            fixture.readiness.release(1, ready: true)
            try await settle { await head.task?.value }
            try await eventually { fixture.readiness.callCount == 2 }
            try await eventually {
                fixture.session.codexFallbackQueue.contains { $0.draftText == "follower" }
                    || fixture.controller.startUserTurnTexts.count == 2
            }

            XCTAssertEqual(head.phase, .accepted)
            XCTAssertEqual(fixture.controller.startUserTurnTexts.first, "head")
            XCTAssertEqual(dispatchesSeenAtEachReadinessCall, [0, 1], "the follower must reach the runner only after the head dispatched")
        }

        func testCancellingGatedHeadWithQueuedFollowerDispatchesNothingAndLaterStartsProceed() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let head = try fixture.submit("head")
            try await eventually { fixture.readiness.isWaiting(1) }
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "follower", tabID: fixture.tabID), .submitted)
            let followers = head.followerTasks
            XCTAssertEqual(followers.count, 1)
            let followerGateTicket = try XCTUnwrap(head.followerDispatchGateTickets.first)
            try await eventually { fixture.session.codexDispatchSerialGate.test_hasWaiter(for: followerGateTicket) }

            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.readiness.release(1, ready: true)
            try await settle { await head.task?.value }
            try await settle(followers)

            XCTAssertEqual(head.phase, .cancelled)
            XCTAssertEqual(fixture.readiness.callCount, 1, "the cancelled follower reached the runner")
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "follower" })

            let later = try fixture.submit("later")
            try await eventually { fixture.controller.startUserTurnTexts == ["later"] }
            try await settle { await later.task?.value }
            XCTAssertEqual(later.phase, .accepted)
        }

        func testCancellingPromotedHeadWithdrawsFollowerStillAwaitingDispatchAuthorization() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1, 2])
            let first = try fixture.submit("rejected head")
            try await eventually { fixture.readiness.isWaiting(1) }
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "promoted", tabID: fixture.tabID), .submitted)
            let promotedTasks = Set(first.followerTasks)
            let tracker = fixture.session.codexSteerAckTracker
            let attemptID = tracker.beginAttempt()
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "unauthorized", tabID: fixture.tabID, codexAttemptID: attemptID),
                .submitted
            )
            let unauthorizedTask = try XCTUnwrap(first.followerTasks.first { !promotedTasks.contains($0) })

            fixture.readiness.release(1, ready: false)
            try await settle { await first.task?.value }
            try await eventually { fixture.readiness.isWaiting(2) }
            XCTAssertNotEqual(first.phase, .cancelled)
            let promoted = try XCTUnwrap(fixture.session.unresolvedStartupTicket)
            fixture.cleanup.submittedTickets.append(promoted)
            XCTAssertFalse(promoted === first)
            XCTAssertNotNil(promoted.task, "the promoted head does not own its dispatch task")

            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            try await settle { await unauthorizedTask.value }

            XCTAssertEqual(promoted.phase, .cancelled)
            let acknowledgement = AttemptStateBox()
            Task { @MainActor in
                acknowledgement.value = await tracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 2)
            }
            try await eventually { acknowledgement.value != nil }
            XCTAssertEqual(acknowledgement.value, .cancelled)
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "unauthorized" })
            XCTAssertEqual(fixture.readiness.callCount, 2, "the unauthorized follower reached the runner")
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
        }

        func testWorkspaceDiscardStopsQueuedStartsOnTheDiscardedSession() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let head = try fixture.submit("head")
            try await eventually { fixture.readiness.isWaiting(1) }
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "follower", tabID: fixture.tabID), .submitted)
            let followers = head.followerTasks
            XCTAssertEqual(followers.count, 1)
            let followerGateTicket = try XCTUnwrap(head.followerDispatchGateTickets.first)
            try await eventually { fixture.session.codexDispatchSerialGate.test_hasWaiter(for: followerGateTicket) }
            XCTAssertEqual(fixture.startAgentRunCalls.count, 1)

            _ = fixture.viewModel.test_prepareWorkspaceSwitchSessionDiscard(fixture.session)
            fixture.readiness.release(1, ready: true)
            try await settle { await head.task?.value }
            try await settle(followers)

            XCTAssertEqual(head.phase, .superseded)
            XCTAssertEqual(fixture.startAgentRunCalls.count, 1, "a queued start called startAgentRun on the discarded session")
            XCTAssertEqual(fixture.readiness.callCount, 1)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
        }

        func testManualHeadReplacedDuringReadinessLeavesReplacementUntouched() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            fixture.session.pendingTaggedFileAttachments = [
                AgentTaggedFileAttachment(relativePath: "stale.swift", displayName: "stale.swift")
            ]
            fixture.session.selectedWorkflow = AgentWorkflow.build.definition
            let head = try fixture.submit("stale head")
            try await eventually { fixture.readiness.isWaiting(1) }

            _ = fixture.viewModel.test_prepareWorkspaceSwitchSessionDiscard(fixture.session)
            let replacement = AgentModeViewModel.TabSession(tabID: fixture.tabID)
            replacement.hasLoadedPersistedState = true
            replacement.selectedAgent = .codexExec
            fixture.viewModel.test_installLiveSession(replacement)
            fixture.viewModel.storeDraftText(for: fixture.tabID, "replacement draft")
            let replacementItemIDs = replacement.items.map(\.id)
            fixture.readiness.release(1, ready: true)
            try await settle { await head.task?.value }

            XCTAssertEqual(head.phase, .superseded)
            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "replacement draft")
            XCTAssertEqual(replacement.pendingImageAttachments, [])
            XCTAssertEqual(replacement.pendingTaggedFileAttachments, [])
            XCTAssertNil(replacement.selectedWorkflow)
            XCTAssertEqual(replacement.items.map(\.id), replacementItemIDs)
            XCTAssertNil(replacement.startupTicket)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
        }

        func testDiscardAcknowledgesGateQueuedMCPFollowerAsStale() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let head = try fixture.submit("head")
            try await eventually { fixture.readiness.isWaiting(1) }
            let tracker = fixture.session.codexSteerAckTracker
            let attemptID = tracker.beginAttempt()
            tracker.authorizeDispatch(attemptID: attemptID)
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "mcp follower", tabID: fixture.tabID, codexAttemptID: attemptID),
                .submitted
            )
            let followers = head.followerTasks
            XCTAssertEqual(followers.count, 1)
            let followerGateTicket = try XCTUnwrap(head.followerDispatchGateTickets.first)
            try await eventually { fixture.session.codexDispatchSerialGate.test_hasWaiter(for: followerGateTicket) }

            _ = fixture.viewModel.test_prepareWorkspaceSwitchSessionDiscard(fixture.session)
            let replacement = AgentModeViewModel.TabSession(tabID: fixture.tabID)
            replacement.hasLoadedPersistedState = true
            replacement.selectedAgent = .codexExec
            fixture.viewModel.test_installLiveSession(replacement)
            try await settle(followers)

            let acknowledgement = AttemptStateBox()
            Task { @MainActor in
                acknowledgement.value = await tracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 2)
            }
            try await eventually { acknowledgement.value != nil }
            guard case .stale? = acknowledgement.value else {
                return XCTFail("expected a stale acknowledgement, got \(String(describing: acknowledgement.value))")
            }
            XCTAssertNil(replacement.startupTicket)
            XCTAssertFalse(replacement.items.contains { $0.kind == .user })
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
        }

        // MARK: - Hydration-deferred submissions

        func testSubmissionDeferredForHydrationNeverMovesToAReplacementSession() async throws {
            let fixture = makeFixture(gatedHydration: true)
            let ticket = try fixture.submit("stale session message")
            try await eventually { fixture.hydration.isWaiting }

            let replacement = AgentModeViewModel.TabSession(tabID: fixture.tabID)
            replacement.hasLoadedPersistedState = true
            replacement.selectedAgent = .codexExec
            fixture.viewModel.test_installLiveSession(replacement)
            fixture.hydration.release()
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .superseded)
            XCTAssertNil(replacement.startupTicket)
            XCTAssertFalse(replacement.items.contains { $0.kind == .user })
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
            XCTAssertEqual(fixture.startAgentRunCalls.count, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
        }

        func testReplacedSessionResolvesDeferredMCPAttemptAsStale() async throws {
            let fixture = makeFixture(gatedHydration: true)
            let attemptID = fixture.session.codexSteerAckTracker.beginAttempt()
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "mcp message", tabID: fixture.tabID, codexAttemptID: attemptID),
                .submitted
            )
            let ticket = try XCTUnwrap(fixture.session.unresolvedStartupTicket)
            try await eventually { fixture.hydration.isWaiting }

            let replacement = AgentModeViewModel.TabSession(tabID: fixture.tabID)
            replacement.hasLoadedPersistedState = true
            replacement.selectedAgent = .codexExec
            fixture.viewModel.test_installLiveSession(replacement)
            fixture.hydration.release()
            try await settle { await ticket.task?.value }

            let acknowledgement = AttemptStateBox()
            Task { @MainActor in
                acknowledgement.value = await fixture.session.codexSteerAckTracker.awaitTerminalState(
                    attemptID: attemptID,
                    timeoutSeconds: 2
                )
            }
            try await eventually { acknowledgement.value != nil }
            guard case .stale? = acknowledgement.value else {
                return XCTFail("expected a stale acknowledgement, got \(String(describing: acknowledgement.value))")
            }
            XCTAssertEqual(ticket.phase, .superseded)
            XCTAssertNil(replacement.startupTicket)
            XCTAssertFalse(replacement.items.contains { $0.kind == .user })
            XCTAssertEqual(fixture.startAgentRunCalls.count, 0)
        }

        func testCancelDuringHydrationLeavesTranscriptAndCancelledStateUntouched() async throws {
            let fixture = makeFixture(gatedHydration: true)
            let ticket = try fixture.submit("cancelled during hydration")
            try await eventually { fixture.hydration.isWaiting }

            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            XCTAssertEqual(fixture.session.runState, .cancelled)
            fixture.hydration.release()
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.session.runState, .cancelled, "the cancelled start reset the session to idle")
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
            XCTAssertEqual(fixture.startAgentRunCalls.count, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
        }

        func testCancellingHeadWithdrawsFollowerStillAwaitingHydration() async throws {
            let fixture = makeFixture(gatedHydration: true)
            let head = try fixture.submit("head")
            try await eventually { fixture.hydration.isWaiting }
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "follower", tabID: fixture.tabID), .submitted)
            XCTAssertTrue(fixture.session.startupTicket === head)
            let followers = head.followerTasks
            XCTAssertEqual(followers.count, 1)

            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.hydration.release()
            try await settle { await head.task?.value }
            try await settle(followers)

            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
            XCTAssertEqual(fixture.startAgentRunCalls.count, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])

            let later = try fixture.submit("later")
            try await eventually { fixture.controller.startUserTurnTexts == ["later"] }
            try await settle { await later.task?.value }
            XCTAssertEqual(later.phase, .accepted)
        }

        // MARK: - MCP epoch preparation

        func testEpochAcceptedAfterCancellationIsSettledAndNeverReportsRunning() async throws {
            let fixture = makeFixture()
            let sessionID = UUID()
            _ = try await activateMCPControl(fixture: fixture, sessionID: sessionID)
            let epochGate = HeldGate()
            fixture.cleanup.heldGates.append(epochGate)
            fixture.viewModel.test_setAfterMCPStoreEpochBegan { await epochGate.wait() }
            XCTAssertTrue(fixture.session.mcpFollowUpRunPending)

            let ticket = try fixture.submit("mcp start")
            try await eventually { epochGate.isWaiting }
            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            epochGate.release()
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertFalse(fixture.session.mcpFollowUpRunPending, "MCP keeps reporting the cancelled start as queued")
            let context = try XCTUnwrap(fixture.session.mcpControlContext)
            XCTAssertNil(context.preparedEpoch, "the cancelled start handed its epoch to the next run")
            let storeEpoch = await AgentRunSessionStore.currentEpoch(for: context.registration)
            XCTAssertNotNil(context.currentEpoch)
            XCTAssertEqual(context.currentEpoch, storeEpoch)
            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: sessionID)?.status, .cancelled)
            let storedSnapshot = await AgentRunSessionStore.snapshot(for: context.registration)
            XCTAssertEqual(storedSnapshot?.status, .cancelled, "the late epoch was left open with no run behind it")
        }

        func testCancellingQueuedNonCodexStartClearsMCPPendingStart() async throws {
            let fixture = makeFixture()
            fixture.session.selectedAgent = .claudeCode
            let sessionID = UUID()
            _ = try await activateMCPControl(fixture: fixture, sessionID: sessionID)

            let ticket = try fixture.submit("claude start")
            // Awaited inline so the start is invalidated before its task runs.
            await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
            try await settle { await ticket.task?.value }

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertFalse(fixture.session.mcpFollowUpRunPending, "MCP keeps reporting the cancelled start as queued")
            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: sessionID)?.status, .cancelled)
        }

        func testSuccessorStartWaitsForStaleEpochPreparationAndAgreesWithStore() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let sessionID = UUID()
            let registration = try await activateMCPControl(fixture: fixture, sessionID: sessionID)
            // A prior run's epoch, already consumed, so no epoch below compares against nil.
            await fixture.viewModel.prepareMCPWaitTrackingForRunStart(session: fixture.session)
            var consumedContext = try XCTUnwrap(fixture.session.mcpControlContext)
            let priorEpoch = try XCTUnwrap(consumedContext.currentEpoch)
            consumedContext.preparedEpoch = nil
            fixture.session.mcpControlContext = consumedContext
            fixture.viewModel.setMCPFollowUpRunPending(sessionID: sessionID, false)

            // Only the cancelled start's epoch preparation is held; the successor's passes.
            let epochGate = HeldGate()
            fixture.cleanup.heldGates.append(epochGate)
            let heldFirstPreparation = CompletionFlag()
            fixture.viewModel.test_setAfterMCPStoreEpochBegan {
                guard !heldFirstPreparation.value else { return }
                heldFirstPreparation.value = true
                await epochGate.wait()
            }

            let staleTicket = try fixture.submit("cancelled start")
            try await eventually { epochGate.isWaiting }
            let storeEpochAtHold = await AgentRunSessionStore.currentEpoch(for: registration)
            let staleEpoch = try XCTUnwrap(storeEpochAtHold)
            XCTAssertNotEqual(staleEpoch, priorEpoch)
            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }

            let successor = try fixture.submit("successor")
            // The successor either parks behind the held preparation or, if nothing orders them,
            // races ahead to readiness bound to an outdated epoch.
            try await eventually {
                fixture.session.test_mcpEpochPreparationWaiterCount > 0 || fixture.readiness.isWaiting(1)
            }
            XCTAssertEqual(fixture.readiness.callCount, 0, "the successor ran ahead of the pending epoch preparation")

            epochGate.release()
            try await settle { await staleTicket.task?.value }
            try await eventually { fixture.readiness.isWaiting(1) }

            let successorOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            XCTAssertTrue(successor.ownership == successorOwnership)
            let successorEpoch = try XCTUnwrap(successorOwnership.turnEpoch)
            XCTAssertNotEqual(successorEpoch, priorEpoch)
            XCTAssertNotEqual(successorEpoch, staleEpoch)
            XCTAssertEqual(fixture.session.mcpControlContext?.currentEpoch, successorEpoch)
            let storeEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
            XCTAssertEqual(storeEpoch, successorEpoch, "the successor's epoch disagrees with the store")

            try await settle { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.readiness.release(1, ready: true)
            try await settle { await successor.task?.value }

            let terminal = await AgentRunSessionStore.snapshot(
                for: AgentRunSessionStore.WaitCursor(registration: registration, epoch: successorEpoch)
            )
            XCTAssertEqual(terminal?.status, .cancelled, "the successor's cancellation did not settle its epoch")
            let finalStoreEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
            XCTAssertEqual(finalStoreEpoch, successorEpoch)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
        }

        func testInvalidatingOlderStartKeepsNewerActivationPendingStart() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let sessionID = UUID()
            _ = try await activateMCPControl(fixture: fixture, sessionID: sessionID)
            let olderTicket = try fixture.submit("older start")
            try await eventually { fixture.readiness.isWaiting(1) }

            try await fixture.viewModel.mcpActivateControlContext(
                forTabID: fixture.tabID,
                sessionID: sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                markSessionAsMCPOriginated: true
            )
            XCTAssertTrue(fixture.session.mcpFollowUpRunPending)
            XCTAssertTrue(olderTicket.isUnresolved)

            fixture.session.invalidatePendingStartup(.cancelled)

            XCTAssertEqual(olderTicket.phase, .cancelled)
            XCTAssertTrue(fixture.session.mcpFollowUpRunPending, "the newer activation's pending start was cleared")
        }

        /// Puts the fixture session under MCP control with a pending start, as `agent_run start`
        /// does, and deactivates it at teardown once the fixture's starts have settled.
        private func activateMCPControl(
            fixture: Fixture,
            sessionID: UUID
        ) async throws -> AgentRunSessionStore.Registration {
            fixture.session.testInstallPersistentSessionBinding(sessionID: sessionID)
            let context = try await fixture.viewModel.mcpActivateControlContext(
                forTabID: fixture.tabID,
                sessionID: sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                markSessionAsMCPOriginated: true,
                requireInactiveRunState: true
            )
            fixture.cleanup.afterStartsSettle.append {
                await fixture.viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
            return context.registration
        }

        // MARK: - Fixture

        private struct Fixture {
            let viewModel: AgentModeViewModel
            let session: AgentModeViewModel.TabSession
            let tabID: UUID
            let readiness: GatedReadiness
            let controller: StartupRecordingCodexController
            let hydration: HeldGate
            let startAgentRunCalls: StartAgentRunLog
            let cleanup: FixtureCleanup

            /// Submits a manual turn into the inactive session and returns the startup ticket the
            /// submission installed; teardown waits for its start to finish.
            @MainActor
            func submit(_ text: String) throws -> AgentRunStartupTicket {
                XCTAssertEqual(viewModel.submitUserTurn(text: text, tabID: tabID), .submitted)
                let ticket = try XCTUnwrap(session.unresolvedStartupTicket)
                cleanup.submittedTickets.append(ticket)
                return ticket
            }

            /// Every gate is released and cancellation requested before any start is awaited, so a
            /// test that fails while a start is held cannot turn teardown into a second timeout.
            @MainActor
            func tearDown() async {
                readiness.releaseAll(ready: false)
                controller.releaseStartup()
                hydration.release()
                cleanup.heldGates.forEach { $0.release() }
                let liveSession = viewModel.session(for: tabID)
                if liveSession.runState.isActive || liveSession.unresolvedStartupTicket != nil {
                    await Self.awaitBounded("fixture teardown cancellation did not finish") {
                        await viewModel.cancelAgentRun(tabID: tabID)
                    }
                }
                for ticket in cleanup.submittedTickets {
                    guard let task = ticket.task else { continue }
                    await Self.awaitBounded("a held start did not finish during teardown") { await task.value }
                }
                for step in cleanup.afterStartsSettle {
                    await step()
                }
            }

            @MainActor
            private static func awaitBounded(
                _ failureMessage: String,
                _ operation: @escaping @MainActor () async -> Void
            ) async {
                let finished = runTracked(operation)
                let didFinish = await waitBounded { finished.value }
                XCTAssertTrue(didFinish, failureMessage)
            }
        }

        /// State a test hands to fixture teardown: gates it holds, the starts it submitted, and
        /// cleanup that must wait until those starts have settled.
        @MainActor
        private final class FixtureCleanup {
            var heldGates: [HeldGate] = []
            var submittedTickets: [AgentRunStartupTicket] = []
            var afterStartsSettle: [@MainActor () async -> Void] = []
        }

        /// Builds the fixture and registers its teardown before any test step can throw.
        private func makeFixture(
            gatedReadinessCalls: Set<Int> = [],
            gateControllerStartup: Bool = false,
            gatedHydration: Bool = false
        ) -> Fixture {
            let readiness = GatedReadiness(gatedCalls: gatedReadinessCalls)
            let controller = StartupRecordingCodexController(gatesStartup: gateControllerStartup)
            let viewModel = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                testWorkspaceDirectory: storageRoot,
                codexControllerFactory: { _, _, _, _, _, _ in controller },
                mcpServerEnabler: { await readiness.enter() }
            )
            let startAgentRunCalls = StartAgentRunLog()
            viewModel.test_startAgentRunObserver = { startAgentRunCalls.sessions.append(ObjectIdentifier($0)) }
            let tabID = UUID()
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            session.hasLoadedPersistedState = true
            session.selectedAgent = .codexExec
            let hydration = HeldGate()
            if gatedHydration {
                // An in-flight persisted load is joined by every hydration-deferred submission,
                // so holding it holds their hydration.
                session.testInstallPersistentSessionBinding(sessionID: UUID())
                session.hasLoadedPersistedState = false
                session.persistedLoadTask = Task { @MainActor in
                    await hydration.wait()
                    session.hasLoadedPersistedState = true
                }
            }
            viewModel.test_installLiveSession(session)
            let fixture = Fixture(
                viewModel: viewModel,
                session: session,
                tabID: tabID,
                readiness: readiness,
                controller: controller,
                hydration: hydration,
                startAgentRunCalls: startAgentRunCalls,
                cleanup: FixtureCleanup()
            )
            addTeardownBlock { @MainActor in await fixture.tearDown() }
            return fixture
        }

        private func awaitTurn(
            _ ticket: UInt64,
            on gate: AgentTabSession.CodexDispatchSerialGate,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> Bool {
            let result = GateResult()
            Task { @MainActor in result.value = await gate.awaitTurn(ticket) }
            try await eventually(file: file, line: line) { result.value != nil }
            return try XCTUnwrap(result.value)
        }

        private func settle(
            _ tasks: [Task<Void, Never>],
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            for task in tasks {
                try await settle(file: file, line: line) { await task.value }
            }
        }

        /// Awaits `operation` with a deadline, so a start that never settles fails at the calling
        /// line instead of hanging the suite.
        private func settle(
            seconds: TimeInterval = 5,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ operation: @escaping @MainActor () async -> Void
        ) async throws {
            let finished = runTracked(operation)
            try await eventually(seconds: seconds, file: file, line: line) { finished.value }
        }

        private func eventually(
            seconds: TimeInterval = 5,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ condition: @MainActor () -> Bool
        ) async throws {
            struct ConditionTimeout: Error {}
            if await waitBounded(seconds: seconds, until: condition) { return }
            XCTFail("Timed out waiting for condition", file: file, line: line)
            throw ConditionTimeout()
        }
    }

    /// Polls `condition` until it holds or `seconds` elapse and reports whether it held. Every
    /// bounded wait in these tests goes through here, so a start that never settles fails the test
    /// instead of hanging the suite.
    @MainActor
    private func waitBounded(seconds: TimeInterval = 5, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    /// Runs `operation` in its own task and returns a flag set when it finishes, so the caller can
    /// bound its wait for work that may never finish.
    @MainActor
    private func runTracked(_ operation: @escaping @MainActor () async -> Void) -> CompletionFlag {
        let finished = CompletionFlag()
        Task { @MainActor in
            await operation()
            finished.value = true
        }
        return finished
    }

    @MainActor
    private final class CompletionFlag {
        var value = false
    }

    @MainActor
    private final class GateResult {
        var value: Bool?
    }

    @MainActor
    private final class AttemptStateBox {
        var value: CodexSteerAckTracker.TerminalState?
    }

    @MainActor
    private final class StartAgentRunLog {
        var sessions: [ObjectIdentifier] = []

        var count: Int {
            sessions.count
        }
    }

    /// Holds every caller of `wait()` until `release()`; later callers pass straight through.
    @MainActor
    private final class HeldGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isWaiting: Bool {
            !waiters.isEmpty
        }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// Readiness enabler whose selected calls (1-based) suspend until the test releases them.
    @MainActor
    private final class GatedReadiness {
        private(set) var callCount = 0
        var onCall: ((Int) -> Void)?
        private let gatedCalls: Set<Int>
        private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

        init(gatedCalls: Set<Int>) {
            self.gatedCalls = gatedCalls
        }

        func enter() async -> Bool {
            callCount += 1
            let call = callCount
            onCall?(call)
            guard gatedCalls.contains(call) else { return true }
            return await withCheckedContinuation { continuation in
                waiters[call] = continuation
            }
        }

        func isWaiting(_ call: Int) -> Bool {
            waiters[call] != nil
        }

        func release(_ call: Int, ready: Bool) {
            waiters.removeValue(forKey: call)?.resume(returning: ready)
        }

        func releaseAll(ready: Bool) {
            let pending = waiters
            waiters.removeAll()
            for continuation in pending.values {
                continuation.resume(returning: ready)
            }
        }
    }

    /// Codex controller that records native startup and first-turn dispatch, optionally holding
    /// startup (which stands in for native start plus routing) until the test releases it.
    @MainActor
    private final class StartupRecordingCodexController: @preconcurrency CodexSessionControlling {
        private(set) var hasActiveThread = false
        private(set) var startOrResumeCount = 0
        private(set) var startUserTurnTexts: [String] = []
        private var gatesStartup: Bool
        private var startupWaiters: [CheckedContinuation<Void, Never>] = []

        init(gatesStartup: Bool) {
            self.gatesStartup = gatesStartup
        }

        var isStartupWaiting: Bool {
            !startupWaiters.isEmpty
        }

        func releaseStartup() {
            gatesStartup = false
            let waiters = startupWaiters
            startupWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { _ in }
        }

        func ensureEventsStreamReady() {}

        func startOrResume(
            existing: CodexNativeSessionController.SessionRef?,
            baseInstructions: String
        ) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(
                existing: existing,
                baseInstructions: baseInstructions,
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
        }

        func startOrResume(
            existing: CodexNativeSessionController.SessionRef?,
            baseInstructions: String,
            model: String?,
            reasoningEffort: String?
        ) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(
                existing: existing,
                baseInstructions: baseInstructions,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: nil
            )
        }

        func startOrResume(
            existing _: CodexNativeSessionController.SessionRef?,
            baseInstructions _: String,
            model: String?,
            reasoningEffort: String?,
            serviceTier _: String?
        ) async throws -> CodexNativeSessionController.SessionRef {
            startOrResumeCount += 1
            if gatesStartup {
                await withCheckedContinuation { continuation in
                    startupWaiters.append(continuation)
                }
            }
            hasActiveThread = true
            return CodexNativeSessionController.SessionRef(
                conversationID: "startup-ticket-test",
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        }

        func readThreadSnapshot(
            includeTurns _: Bool,
            timeout _: TimeInterval?
        ) async throws -> CodexNativeSessionController.ThreadSnapshot {
            CodexNativeSessionController.ThreadSnapshot(
                conversationID: "startup-ticket-test",
                rolloutPath: nil,
                model: nil,
                reasoningEffort: nil,
                runtimeStatus: .idle,
                currentTurnID: nil,
                activeTurnIDs: [],
                latestTurnStatus: nil
            )
        }

        func setThreadName(_: String, threadID _: String?) async throws {}

        /// An empty inventory lets the first turn pass the project-hooks gate without a review.
        func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
            try CodexHookInventory(executionCWD: FileManager.default.temporaryDirectory.path, hooks: [])
        }

        func startUserTurn(
            text: String,
            images _: [AgentImageAttachment],
            model _: String?,
            reasoningEffort _: String?,
            serviceTier _: String?
        ) async throws -> CodexTurnStartReceipt {
            startUserTurnTexts.append(text)
            return CodexTurnStartReceipt(provisionalSubmissionID: "startup-ticket-test-\(startUserTurnTexts.count)")
        }

        func steerUserTurn(
            text _: String,
            images _: [AgentImageAttachment],
            expectedTurnID: String
        ) async throws -> CodexTurnSteerReceipt {
            CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
        }

        func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
            expectedCurrentTurnID _: String,
            acceptedDispatchTurnID _: String
        ) async -> Bool {
            true
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
        }

        func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
            CodexTurnInterruptReceipt(interruptedTurnID: "startup-ticket-test")
        }

        func compactThread() async throws {}

        func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
            nil
        }

        func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func setThreadGoalStatus(
            _: CodexNativeSessionController.ThreadGoalStatus
        ) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func clearThreadGoal() async throws -> Bool {
            false
        }

        func pendingTurnFailure(
            turnID _: String?
        ) async -> CodexNativeSessionController.TurnFailure? {
            nil
        }

        func acknowledgePendingTurnFailure(
            turnID _: String?,
            failure _: CodexNativeSessionController.TurnFailure
        ) async {}

        func cancelCurrentTurn() async {}
        func shutdown() async {}
        func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
    }
#endif
