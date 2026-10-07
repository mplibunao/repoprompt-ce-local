import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunMCPToolServiceSteerResumeTests: XCTestCase {
    func testSteerCompletedUserOwnedSessionWithoutControlContextReactivatesAndStartsFollowUp() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed

        var service = makeService(window: window)
        var observedText: String?
        service.testDispatchSteerInstruction = { dispatchedSessionID, text, _, agentModeVM in
            observedText = text
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertFalse(controlledSession.isMCPOriginated)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("continue this user-owned session")
        ])

        XCTAssertEqual(observedText, "continue this user-owned session")
        XCTAssertEqual(value.objectValue?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertFalse(session.isMCPOriginated)
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        XCTAssertEqual(epoch.transitionKind, .steering)
        XCTAssertEqual(epoch.ordinal, 1)
        XCTAssertNil(context.pendingEpochTransition)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, context.registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerWaitForInactiveControlPlaneCommandDoesNotPrepareRunEpoch() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: UUID(),
            startPending: true,
            markSessionAsMCPOriginated: true,
            requireInactiveRunState: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        // The pending-start flag drops once a runner has taken the run, so the run is already
        // running; dropping it on an idle session would publish that no result was recorded.
        session.runState = .running
        viewModel.setMCPFollowUpRunPending(sessionID: sessionID, false)
        var completedContext = try XCTUnwrap(session.mcpControlContext)
        completedContext.preparedEpoch = nil
        session.mcpControlContext = completedContext
        session.runState = .completed

        let priorContext = try XCTUnwrap(session.mcpControlContext)
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, text, _, _ in
            XCTAssertEqual(text, "/compact")
            return .submittedControlPlaneCommand
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("/compact"),
            "wait": .bool(true),
            "timeout_seconds": .double(1)
        ])

        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
        XCTAssertEqual(
            value.objectValue?["_meta"]?.objectValue?["delivery"]?.stringValue,
            AgentModeViewModel.MCPInstructionDispatch.submittedControlPlaneCommand.rawValue
        )
        let currentContext = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(currentContext.registration, priorContext.registration)
        XCTAssertEqual(currentContext.currentEpoch, priorContext.currentEpoch)
        XCTAssertNil(currentContext.preparedEpoch)
        XCTAssertNil(currentContext.pendingEpochTransition)
        XCTAssertFalse(session.mcpFollowUpRunPending)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerWaitReplacesExpiredPriorRunHandleBeforeWaiting() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: UUID(),
            startPending: true,
            markSessionAsMCPOriginated: true,
            requireInactiveRunState: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        viewModel.setMCPFollowUpRunPending(sessionID: sessionID, false)
        // Completed attempts consume their prepared epoch before terminal snapshot retention begins.
        var completedContext = try XCTUnwrap(session.mcpControlContext)
        completedContext.preparedEpoch = nil
        session.mcpControlContext = completedContext
        session.runState = .completed

        let expiredContext = try XCTUnwrap(session.mcpControlContext)
        let expiredCursor = AgentRunSessionStore.WaitCursor(
            registration: expiredContext.registration,
            epoch: expiredContext.currentEpoch
        )
        await AgentRunSessionStore.testExpire(cursor: expiredCursor)
        let priorRegistrationIsActive = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(priorRegistrationIsActive)

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in .startedRun }
        let completionTask = Task { @MainActor in
            while !Task.isCancelled {
                if let registration = await AgentRunSessionStore.currentRegistration(for: sessionID),
                   registration != expiredContext.registration,
                   let cursor = await AgentRunSessionStore.currentCursor(for: registration)
                {
                    viewModel.setMCPFollowUpRunPending(sessionID: sessionID, false)
                    session.runState = .completed
                    guard let snapshot = viewModel.mcpSnapshot(sessionID: sessionID) else { return }
                    await AgentRunSessionStore.signalSnapshot(snapshot, cursor: cursor)
                    return
                }
                await Task.yield()
            }
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("wait for this follow-up"),
            "wait": .bool(true),
            "timeout_seconds": .double(1)
        ])
        completionTask.cancel()
        await completionTask.value

        XCTAssertEqual(value.objectValue?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
        XCTAssertNotEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.expired.rawValue)
        let currentContext = try XCTUnwrap(session.mcpControlContext)
        XCTAssertNotEqual(currentContext.registration, expiredContext.registration)
        XCTAssertEqual(currentContext.currentEpoch?.transitionKind, .steering)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testReconstructedSteerAcceptsBeforeLaterBookkeepingFailure() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        viewModel.upsertSessionIndex(
            sessionID: sessionID,
            tabID: UUID(),
            name: "Persisted reconstructed steer",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastRunStateRaw: AgentSessionRunState.completed.rawValue,
            itemCount: 2,
            agentKindRaw: "codex",
            agentModelRaw: "test-model",
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false
        )
        var providerDispatchCount = 0
        var reconstructedTarget: AgentModeViewModel.MCPSessionTarget?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            providerDispatchCount += 1
            let session = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            session.runState = .running
            agentModeVM.publishMCPStateChange(for: session)
            return .startedRun
        }
        service.testAfterSteerDispatchBeforeBookkeeping = { target in
            reconstructedTarget = target
            throw MCPError.internalError("synthetic post-dispatch bookkeeping failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("dispatch exactly once before bookkeeping fails")
            ])
            XCTFail("Expected synthetic post-dispatch bookkeeping failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic post-dispatch bookkeeping failure"),
                String(describing: error)
            )
        }

        let target = try XCTUnwrap(reconstructedTarget)
        XCTAssertEqual(target.origin, .createdForSessionResume)
        XCTAssertEqual(try XCTUnwrap(target.recoveryClaim).state, .accepted)
        XCTAssertEqual(providerDispatchCount, 1)
        let discardResult = await viewModel.mcpDiscardSessionTarget(target)
        XCTAssertEqual(discardResult, .complete)
        XCTAssertNotNil(viewModel.session(for: target.tabID, createIfNeeded: false))
        XCTAssertNotNil(window.workspaceManager.composeTab(with: target.tabID))
        XCTAssertEqual(providerDispatchCount, 1)
    }

    func testSteerReactivationDispatchFailureCleansControlContext() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            throw MCPError.internalError("synthetic steer dispatch failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("synthetic steer dispatch failure"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerReactivationDispatchFailurePreservesReplacementControlContextButClearsPendingMask() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed

        var replacementActivationID: UUID?
        var replacementRegistration: AgentRunSessionStore.Registration?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            let originalContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)

            try await agentModeVM.mcpActivateControlContext(
                forTabID: controlledSession.tabID,
                sessionID: sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                markSessionAsMCPOriginated: false,
                requireInactiveRunState: true
            )
            let replacementContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertNotEqual(replacementContext.activationID, originalContext.activationID)
            replacementActivationID = replacementContext.activationID
            replacementRegistration = replacementContext.registration
            throw MCPError.internalError("synthetic steer dispatch failure after replacement")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails after replacement")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic steer dispatch failure after replacement"),
                String(describing: error)
            )
        }

        let activationID = try XCTUnwrap(replacementActivationID)
        let registration = try XCTUnwrap(replacementRegistration)
        let context = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(context.activationID, activationID)
        XCTAssertEqual(context.registration, registration)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerUnknownSessionIDStillFailsWithoutCreatingRegistration() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let unknownSessionID = UUID()
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Unknown sessions must not reach dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(unknownSessionID.uuidString),
                "message": .string("unknown session")
            ])
            XCTFail("Expected unknown session failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("was not found"), String(describing: error))
        }

        XCTAssertNil(viewModel.mcpControlledSession(sessionID: unknownSessionID))
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: unknownSessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testReconstructedSteerRejectsWorkspaceDriftWhenSessionBecomesActiveDuringControlActivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed
        let driftWorkspace = window.workspaceManager.createWorkspace(
            name: "Steer Activation Drift \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        var switchSucceeded = false
        viewModel.test_afterMCPControlActivation = { activatedSession in
            XCTAssertIdentical(activatedSession, session)
            activatedSession.runState = .running
            window.workspaceManager.activeWorkspace = driftWorkspace
            switchSucceeded = window.workspaceManager.activeWorkspace?.id == driftWorkspace.id
        }
        defer { viewModel.test_afterMCPControlActivation = nil }
        var dispatchCount = 0
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            dispatchCount += 1
            return .queuedClaudeInterrupt
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("must reject before the active dispatch branch")
            ])
            XCTFail("Expected workspace drift after reconstructed control activation to reject")
        } catch {
            guard let mcpError = error as? MCPError,
                  case let .invalidParams(message) = mcpError
            else {
                return XCTFail("Expected typed invalidParams workspace rejection, got: \(error)")
            }
            XCTAssertTrue(message?.contains("active workspace") == true, message ?? "missing message")
        }

        XCTAssertTrue(switchSucceeded)
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertNil(session.mcpControlContext)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerActiveUncontrolledSessionIsRejected() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .running

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Active uncontrolled sessions must be rejected before dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("active uncontrolled session")
            ])
            XCTFail("Expected active uncontrolled session rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("active but is not controlled"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    // MARK: - Steering during a queued start

    func testSteerDuringQueuedCodexStartIsRejectedAndTheStartCompletes() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        // Codex keeps its start pending until the first native dispatch is accepted; the
        // readiness gate holds it inside the runner, short of that dispatch.
        let fixture = try makeQueuedStartFixture(gatedReadinessCalls: [1])
        try await fixture.activateMCPControl()
        let ticket = try fixture.submit("original start")
        try await queuedStartEventually { fixture.readiness.isWaiting(1) }
        let before = await QueuedStartObservation(fixture)

        let service = makeQueuedStartSteerService(window: window, fixture: fixture)
        try await assertSteerRejectedAsStartupPending(service, fixture: fixture)
        // Cancelling a steer request cannot reach the start either.
        let cancelledSteer = Task { @MainActor in
            try await service.execute(args: Self.steerArgs(sessionID: fixture.sessionID))
        }
        cancelledSteer.cancel()
        _ = await cancelledSteer.result

        let after = await QueuedStartObservation(fixture)
        XCTAssertEqual(after, before)
        XCTAssertTrue(fixture.session.startupTicket === ticket)
        XCTAssertTrue(ticket.isUnresolved)

        fixture.readiness.release(1, ready: true)
        try await startupTestJoin(ticket.task)
        XCTAssertEqual(ticket.phase, .accepted)
        XCTAssertEqual(fixture.controller.startOrResumeCount, 1)
        XCTAssertEqual(fixture.controller.startUserTurnTexts, ["original start"])
        XCTAssertEqual(fixture.controller.steerUserTurnTexts, [])
        try await fixture.completeActiveTurn(turnID: "queued-start-turn")
        try await queuedStartEventually {
            fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status == .completed
        }
    }

    func testSteerDuringQueuedClaudeStartIsRejectedAndTheStartReachesItsProvider() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let claude = StartupTestClaudeRecorder()
        let fixture = try makeQueuedStartFixture(claude: claude)
        fixture.session.selectedAgent = .claudeCode
        try await fixture.activateMCPControl()
        // Claude's runner takes the run on entry, so the start is held earlier, while it prepares
        // its MCP epoch.
        let epochGate = StartupTestHeldGate()
        fixture.cleanup.heldGates.append(epochGate)
        let heldFirstPreparation = StartupTestCompletionFlag()
        fixture.viewModel.test_setAfterMCPStoreEpochBegan {
            guard !heldFirstPreparation.value else { return }
            heldFirstPreparation.value = true
            await epochGate.wait()
        }
        let ticket = try fixture.submit("original start")
        try await queuedStartEventually { epochGate.isWaiting }
        XCTAssertEqual(ticket.phase, .preparing)
        let before = await QueuedStartObservation(fixture)

        let service = makeQueuedStartSteerService(window: window, fixture: fixture)
        try await assertSteerRejectedAsStartupPending(service, fixture: fixture)

        let after = await QueuedStartObservation(fixture)
        XCTAssertEqual(after, before)
        XCTAssertTrue(fixture.session.startupTicket === ticket)
        XCTAssertEqual(claude.runtimesCreated, 0)

        epochGate.release()
        try await startupTestJoin(ticket.task)
        XCTAssertEqual(ticket.phase, .accepted)
        try await queuedStartEventually { claude.sentMessages.count == 1 }
        XCTAssertEqual(claude.runtimesCreated, 1)
        XCTAssertEqual(claude.sessionStarts, 1)
        let sent = try XCTUnwrap(claude.sentMessages.first)
        XCTAssertTrue(sent.contains("original start"), sent)
        XCTAssertFalse(sent.contains(Self.steerText), sent)
        XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .running)
    }

    func testSteerAfterTheRunnerOwnsTheRunUsesTheExistingSteeringPath() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        for agent in [AgentProviderKind.codexExec, .claudeCode] {
            let claude = StartupTestClaudeRecorder()
            let fixture = try makeQueuedStartFixture(claude: claude)
            fixture.session.selectedAgent = agent
            try await fixture.activateMCPControl()
            let ticket = try fixture.submit("established start")
            try await startupTestJoin(ticket.task)
            XCTAssertEqual(ticket.phase, .accepted, agent.rawValue)
            XCTAssertTrue(fixture.session.runState.isActive, agent.rawValue)

            var service = makeQueuedStartSteerService(window: window, fixture: fixture)
            var dispatchedTexts: [String] = []
            service.testDispatchSteerInstruction = { _, text, _, _ in
                dispatchedTexts.append(text)
                return agent == .codexExec ? .dispatchedCodexTurn : .queuedClaudeInterrupt
            }
            _ = try await service.execute(args: Self.steerArgs(sessionID: fixture.sessionID))

            XCTAssertEqual(dispatchedTexts, [Self.steerText], agent.rawValue)
        }
    }

    func testSteerDuringPendingStartFlagBeforeSubmissionIsRejectedUntilTheFlagIsStale() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let fixture = try makeQueuedStartFixture()
        try await fixture.activateMCPControl(startPending: true)
        XCTAssertNil(fixture.session.unresolvedStartupTicket)

        var service = makeQueuedStartSteerService(window: window, fixture: fixture)
        var dispatchCount = 0
        service.testDispatchSteerInstruction = { _, _, _, _ in
            dispatchCount += 1
            return .startedRun
        }
        try await assertSteerRejectedAsStartupPending(service, fixture: fixture)
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertTrue(fixture.session.mcpFollowUpRunPending)

        // A flag that expired with no run work behind it is the stale mask snapshots drop, so it
        // cannot keep refusing steers.
        fixture.releasePendingStartOwnership()
        fixture.session.mcpFollowUpRunPendingUpdatedAt = Date().addingTimeInterval(-60)
        do {
            _ = try await service.execute(args: Self.steerArgs(sessionID: fixture.sessionID))
        } catch {
            XCTFail("A stale pending-start flag refused the steer: \(error)")
        }
        XCTAssertEqual(dispatchCount, 1)
    }

    func testSteerOnUncontrolledSessionWithPendingStartIsRejectedBeforeReactivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        let ticket = try XCTUnwrap(session.installStartupTicketIfAbsent())
        defer { session.invalidatePendingStartup(.cancelled) }

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("A steer during a pending start must not reach dispatch")
            return .startedRun
        }
        do {
            _ = try await service.execute(args: Self.steerArgs(sessionID: sessionID))
            XCTFail("Expected a startup_pending rejection")
        } catch {
            guard let mcpError = error as? MCPError,
                  case let .invalidParams(message) = mcpError
            else {
                return XCTFail("Expected a startup_pending rejection, got \(error)")
            }
            XCTAssertEqual(message, AgentRunMCPToolService.startupPendingSteerRejectionMessage)
        }

        XCTAssertNil(session.mcpControlContext, "the rejected steer left its reactivated control behind")
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertTrue(session.startupTicket === ticket)
        XCTAssertTrue(ticket.isUnresolved)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testManualStartAcceptedWhileSteerActivationIsSuspendedRefusesTheActivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.selectedAgent = .codexExec
        viewModel.test_agentAvailabilityForRunOverride = { _ in true }
        // A held dispatch-gate turn keeps the manual start queued short of any provider.
        let heldGateTicket = session.codexDispatchSerialGate.issueTicket()
        let heldGateGranted = await session.codexDispatchSerialGate.awaitTurn(heldGateTicket)
        XCTAssertTrue(heldGateGranted)
        let permissionProfileBefore = session.permissionProfile
        let autoEditBefore = session.autoEditEnabled
        var manualStart: AgentRunStartupTicket?
        viewModel.test_afterMCPControlRegistration = { _ in
            XCTAssertEqual(viewModel.submitUserTurn(text: "manual start", tabID: session.tabID), .submitted)
            manualStart = session.unresolvedStartupTicket
        }
        defer {
            viewModel.test_afterMCPControlRegistration = nil
            viewModel.test_agentAvailabilityForRunOverride = nil
        }

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("A steer refused during its activation must not reach dispatch")
            return .startedRun
        }
        do {
            _ = try await service.execute(args: Self.steerArgs(sessionID: sessionID))
            XCTFail("Expected a startup_pending rejection")
        } catch {
            guard let mcpError = error as? MCPError,
                  case let .invalidParams(message) = mcpError
            else {
                return XCTFail("Expected a startup_pending rejection, got \(error)")
            }
            XCTAssertEqual(message, AgentRunMCPToolService.startupPendingSteerRejectionMessage)
        }

        let ticket = try XCTUnwrap(manualStart, "the manual start was not accepted during activation")
        XCTAssertNil(session.mcpControlContext, "the refused activation installed MCP control")
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertNil(session.mcpPendingStartOwner)
        XCTAssertEqual(session.permissionProfile, permissionProfileBefore)
        XCTAssertEqual(session.autoEditEnabled, autoEditBefore)
        XCTAssertTrue(session.startupTicket === ticket)
        XCTAssertTrue(ticket.isUnresolved)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)

        session.invalidatePendingStartup(.cancelled)
        session.codexDispatchSerialGate.finish(heldGateTicket)
        try await startupTestJoin(ticket.task)
    }

    func testSlowExternalStartKeepsItsPendingFlagPastTheMaskExpiry() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let fixture = try makeQueuedStartFixture()
        let start = try await beginHeldExternalStart(on: fixture, message: "slow external start")
        let viewModel = fixture.viewModel

        // The start is still preparing well past the mask's expiry.
        fixture.session.mcpFollowUpRunPendingUpdatedAt = Date().addingTimeInterval(-60)
        XCTAssertEqual(viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .running)
        XCTAssertTrue(fixture.session.mcpFollowUpRunPending, "a snapshot dropped the flag of a start still preparing")
        let service = makeQueuedStartSteerService(window: window, fixture: fixture)
        try await assertSteerRejectedAsStartupPending(service, fixture: fixture)
        XCTAssertEqual(
            viewModel.submitUserTurn(text: "manual message", tabID: fixture.tabID),
            .blocked(message: AgentModeViewModel.manualSubmissionDuringStartupMessage)
        )

        try await finishHeldExternalStart(start, on: fixture)
        XCTAssertEqual(fixture.controller.startUserTurnTexts, ["slow external start"])
    }

    func testExpiredSupersedingMaskLeavesAPreparingStartsFlagAndOwner() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let fixture = try makeQueuedStartFixture()
        let start = try await beginHeldExternalStart(on: fixture, message: "start behind an expired mask")
        let owner = try XCTUnwrap(fixture.session.mcpPendingStartOwner)
        fixture.session.pendingSupersedingTurnCompletions = 1
        fixture.session.pendingSupersedingTurnCompletionsUpdatedAt = Date().addingTimeInterval(-60)

        XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .running)

        XCTAssertEqual(fixture.session.pendingSupersedingTurnCompletions, 0, "the expired superseding mask was kept")
        XCTAssertTrue(fixture.session.mcpFollowUpRunPending, "the expired superseding mask took the live start's flag")
        XCTAssertEqual(fixture.session.mcpPendingStartOwner, owner)
        let service = makeQueuedStartSteerService(window: window, fixture: fixture)
        try await assertSteerRejectedAsStartupPending(service, fixture: fixture)
        XCTAssertEqual(
            fixture.viewModel.submitUserTurn(text: "manual message", tabID: fixture.tabID),
            .blocked(message: AgentModeViewModel.manualSubmissionDuringStartupMessage)
        )

        try await finishHeldExternalStart(start, on: fixture)
        XCTAssertEqual(fixture.controller.startUserTurnTexts, ["start behind an expired mask"])
    }

    /// An `agent_run start` through the real external starter, held after activation and
    /// configuration, just before it dispatches its first instruction.
    private struct HeldExternalStart {
        let dispatchGate: StartupTestHeldGate
        let finished: StartupTestCompletionFlag
    }

    private func beginHeldExternalStart(
        on fixture: StartupTestSessionFixture,
        message: String
    ) async throws -> HeldExternalStart {
        fixture.session.testInstallPersistentSessionBinding(sessionID: fixture.sessionID)
        let viewModel = fixture.viewModel
        let sessionID = fixture.sessionID
        fixture.cleanup.afterStartsSettle.append {
            await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
        }
        let dispatchGate = StartupTestHeldGate()
        fixture.cleanup.heldGates.append(dispatchGate)
        let finished = StartupTestCompletionFlag()
        let starter = Task { @MainActor in
            _ = try? await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                target: AgentModeViewModel.MCPSessionTarget(
                    tabID: fixture.tabID,
                    sessionID: sessionID,
                    origin: .existingTab
                ),
                message: message,
                metadata: MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "agent-run-steer-resume-tests",
                    windowID: nil
                ),
                agentModeVM: viewModel,
                agentRaw: nil,
                modelRaw: nil,
                reasoningEffortRaw: nil,
                dispatchInstruction: { sessionID, _, message, workflow, agentModeVM in
                    await dispatchGate.wait()
                    return try await agentModeVM.mcpDispatchInstruction(
                        sessionID: sessionID,
                        text: message,
                        allowStartingRun: true,
                        workflow: workflow
                    )
                }
            )
            finished.value = true
        }
        fixture.cleanup.join(starter)
        try await queuedStartEventually { dispatchGate.isWaiting }
        XCTAssertTrue(fixture.session.mcpFollowUpRunPending)
        XCTAssertNotNil(fixture.session.mcpPendingStartOwner)
        XCTAssertNil(fixture.session.unresolvedStartupTicket)
        return HeldExternalStart(dispatchGate: dispatchGate, finished: finished)
    }

    /// Lets the held start dispatch and requires it to be accepted, handing its pending-start
    /// ownership to the ticket.
    private func finishHeldExternalStart(
        _ start: HeldExternalStart,
        on fixture: StartupTestSessionFixture
    ) async throws {
        start.dispatchGate.release()
        try await queuedStartEventually { start.finished.value }
        let ticket = try XCTUnwrap(fixture.session.startupTicket)
        fixture.cleanup.tickets.append(ticket)
        try await startupTestJoin(ticket.task)
        XCTAssertEqual(ticket.phase, .accepted)
        XCTAssertNil(fixture.session.mcpPendingStartOwner)
    }

    private static let steerText = "steer sent while the start is queued"

    private static func steerArgs(sessionID: UUID) -> [String: Value] {
        [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string(steerText)
        ]
    }

    /// Everything a rejected steer must leave as it found it: the session's identity and MCP
    /// activation, its epochs in the context and the store, the transcript, the startup ticket and
    /// its task, the run attempt, and how far provider startup got.
    private struct QueuedStartObservation: Equatable {
        let agentSessionID: UUID?
        let activationID: UUID?
        let activationGeneration: UInt64
        let registration: AgentRunSessionStore.Registration?
        let currentEpoch: AgentRunTurnEpoch?
        let preparedEpoch: AgentRunTurnEpoch?
        let hasPendingEpochTransition: Bool
        let storeEpoch: AgentRunTurnEpoch?
        let followUpRunPending: Bool
        let itemIDs: [UUID]
        let ticket: ObjectIdentifier?
        let ticketPhase: AgentRunStartupTicket.Phase?
        let ticketTaskIsCancelled: Bool?
        let runID: UUID?
        let runAttemptID: UUID?
        let runState: AgentSessionRunState
        let readinessCalls: Int
        let codexStarts: Int

        @MainActor
        init(_ fixture: StartupTestSessionFixture) async {
            let session = fixture.session
            let context = session.mcpControlContext
            agentSessionID = session.activeAgentSessionID
            activationID = context?.activationID
            activationGeneration = session.mcpControlActivationGeneration
            registration = context?.registration
            currentEpoch = context?.currentEpoch
            preparedEpoch = context?.preparedEpoch
            hasPendingEpochTransition = context?.pendingEpochTransition != nil
            storeEpoch = if let registration = context?.registration {
                await AgentRunSessionStore.currentEpoch(for: registration)
            } else {
                nil
            }
            followUpRunPending = session.mcpFollowUpRunPending
            itemIDs = session.items.map(\.id)
            ticket = session.startupTicket.map(ObjectIdentifier.init)
            ticketPhase = session.startupTicket?.phase
            ticketTaskIsCancelled = session.startupTicket?.task?.isCancelled
            runID = session.runID
            runAttemptID = session.activeRunAttemptID
            runState = session.runState
            readinessCalls = fixture.readiness.callCount
            codexStarts = fixture.controller.startOrResumeCount
        }
    }

    private func makeQueuedStartFixture(
        gatedReadinessCalls: Set<Int> = [],
        claude: StartupTestClaudeRecorder? = nil
    ) throws -> StartupTestSessionFixture {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunQueuedStartSteer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let readiness = StartupTestGatedReadiness(gatedCalls: gatedReadinessCalls)
        let controller = StartupTestCodexController(gatesStartup: false)
        let fixture = StartupTestSessionFixture(
            viewModel: startupTestMakeViewModel(
                storageRoot: storageRoot,
                readiness: readiness,
                controller: controller,
                claude: claude
            ),
            session: startupTestCodexSession(),
            readiness: readiness,
            controller: controller
        )
        addTeardownBlock { @MainActor in
            await fixture.tearDown()
            try? FileManager.default.removeItem(at: storageRoot)
        }
        return fixture
    }

    private func makeQueuedStartSteerService(
        window: WindowState,
        fixture: StartupTestSessionFixture
    ) -> AgentRunMCPToolService {
        var service = makeService(window: window)
        service.testAgentModeViewModel = fixture.viewModel
        return service
    }

    /// Steers the fixture's session and requires the retryable `startup_pending` rejection. The
    /// steer runs in a tracked task with a deadline, so a steer that is wrongly accepted and then
    /// waits on the held start fails here instead of hanging the suite.
    private func assertSteerRejectedAsStartupPending(
        _ service: AgentRunMCPToolService,
        fixture: StartupTestSessionFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let outcome = QueuedStartSteerOutcome()
        let sessionID = fixture.sessionID
        try await startupTestSettle(on: fixture, file: file, line: line) {
            do {
                _ = try await service.execute(args: Self.steerArgs(sessionID: sessionID))
                outcome.error = nil
            } catch {
                outcome.error = error
            }
        }
        guard let mcpError = outcome.error as? MCPError,
              case let .invalidParams(message) = mcpError
        else {
            return XCTFail(
                "Expected a startup_pending rejection, got \(String(describing: outcome.error))",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(message, AgentRunMCPToolService.startupPendingSteerRejectionMessage, file: file, line: line)
    }

    private func queuedStartEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        struct ConditionTimeout: Error {}
        if await startupTestWaitBounded(until: condition) { return }
        XCTFail("Timed out waiting for condition", file: file, line: line)
        throw ConditionTimeout()
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Steer Resume \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentRunSteerResumeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeWorkspaceOwnedSession(
        in window: WindowState,
        sessionID: UUID
    ) async throws -> AgentModeViewModel.TabSession {
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
        let binding = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            compareAndSetInWorkspaceID: workspace.id
        )
        XCTAssertNotNil(binding)
        return session
    }

    private func makeService(window: WindowState) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "agent-run-steer-resume-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by steer resume tests")
            }
        )
    }
}

@MainActor
private final class QueuedStartSteerOutcome {
    var error: Error?
}
