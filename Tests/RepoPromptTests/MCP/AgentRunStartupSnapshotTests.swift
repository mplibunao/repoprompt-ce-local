import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// MCP snapshot status for sessions whose latest submission has no terminal result yet:
    /// neither idleness nor an expired startup mask is evidence of completion, and an accepted
    /// start that still owns its ticket stays running however long it takes.
    @MainActor
    final class AgentRunStartupSnapshotTests: XCTestCase {
        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentRunStartupSnapshotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        func testIdleUserOnlySessionPastTheStartupMaskReportsUnrecordedFailure() async throws {
            let fixture = makeFixture()
            try await fixture.activateMCPControl(startPending: true)
            fixture.session.appendItem(.user("prompt that never ran"))
            fixture.session.mcpFollowUpRunPendingUpdatedAt = Date().addingTimeInterval(-20)

            let snapshot = try XCTUnwrap(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID))

            XCTAssertEqual(snapshot.status, .failed)
            XCTAssertEqual(snapshot.statusText, AgentModeViewModel.mcpUnrecordedTerminalStatusText)
            XCTAssertEqual(snapshot.failureReason, .agentError)
        }

        func testSlowTicketOwnedStartStaysRunningPastTheStartupMask() async throws {
            let fixture = makeFixture()
            try await fixture.activateMCPControl(startPending: true)
            // Holding epoch preparation keeps the start ahead of its runner: idle, no agent task.
            let epochGate = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(epochGate)
            fixture.viewModel.test_setAfterMCPStoreEpochBegan { await epochGate.wait() }
            let ticket = try fixture.submit("slow start")
            try await eventually { epochGate.isWaiting }
            XCTAssertEqual(fixture.session.runState, .idle)
            XCTAssertNil(fixture.session.agentTask)

            fixture.session.mcpFollowUpRunPendingUpdatedAt = Date().addingTimeInterval(-20)
            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .running)
            XCTAssertTrue(fixture.session.mcpFollowUpRunPending, "the expired mask was cleared under a ticket-owned start")

            // A start preparing a successor epoch runs without the pending flag.
            fixture.session.mcpFollowUpRunPending = false
            let snapshot = try XCTUnwrap(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID))
            XCTAssertEqual(snapshot.status, .running)
            XCTAssertEqual(snapshot.statusText, AgentRunMCPSnapshot.startupPendingStatusText)
            XCTAssertTrue(ticket.isUnresolved)
        }

        func testStartWaitingAtReadinessWithoutPendingFlagStaysRunning() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            try await fixture.activateMCPControl(startPending: true)
            _ = try fixture.submit("waiting at readiness")
            try await eventually { fixture.readiness.isWaiting(1) }
            fixture.viewModel.setMCPFollowUpRunPending(sessionID: fixture.sessionID, false)
            XCTAssertEqual(fixture.session.runState, .idle)

            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .running)
        }

        func testNewerUndispatchedSubmissionDoesNotReportThePreviousCompletion() async throws {
            let fixture = makeFixture()
            startupTestInstallRestoredState(
                on: fixture.session,
                items: [.user("earlier", sequenceIndex: 0), .assistant("done", sequenceIndex: 1)],
                persistedRunState: .idle
            )
            fixture.session.transcript.turns[fixture.session.transcript.turns.count - 1].terminalState = .completed
            try await fixture.activateMCPControl(startPending: false)
            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .completed)

            fixture.session.appendItem(.user("newer, never dispatched"))

            let snapshot = try XCTUnwrap(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID))
            XCTAssertNotEqual(snapshot.status, .completed)
            XCTAssertEqual(snapshot.status, .failed)
            XCTAssertEqual(snapshot.statusText, AgentModeViewModel.mcpUnrecordedTerminalStatusText)
        }

        // MARK: - Control-plane commands

        /// A control-plane command is not a run start: it claims no startup ticket, and a
        /// compaction that fails to start leaves the previous run's result in place.
        func testFailedCompactionStartKeepsThePreviousCompletedResult() async throws {
            let fixture = makeFixture()
            fixture.controller.compactError = NSError(
                domain: "AgentRunStartupSnapshotTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "compaction unavailable"]
            )
            startupTestInstallRestoredState(
                on: fixture.session,
                items: [.user("task", sequenceIndex: 0), .assistant("done", sequenceIndex: 1)],
                persistedRunState: .completed
            )
            fixture.session.codexConversationID = "startup-ticket-test"
            try await fixture.activateMCPControl(startPending: false)

            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "/compact", tabID: fixture.tabID),
                .submittedControlPlaneCommand
            )
            XCTAssertNil(fixture.session.unresolvedStartupTicket, "a control-plane command claimed a startup ticket")
            try await eventually { fixture.session.items.contains { $0.kind == .error } }

            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(
                fixture.session.items.filter { $0.kind == .error }.map(\.text),
                ["Codex context compaction failed: compaction unavailable"]
            )
            XCTAssertEqual(fixture.session.runState, .completed, "the failed compaction replaced the previous result")
            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .completed)
        }

        /// A compaction request that fails after the compaction was cancelled leaves the committed
        /// cancellation as the session's result, live and stored.
        func testCompactionFailureAfterCancellationKeepsTheCancellation() async throws {
            let fixture = makeFixture()
            let registration = try await fixture.beginHeldFailingCompaction()

            try await settleWithin(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            XCTAssertEqual(fixture.session.runState, .cancelled)
            let storedAtCancellation = await AgentRunSessionStore.snapshot(for: registration)
            try await fixture.releaseCompactionFailure()

            XCTAssertEqual(fixture.session.runState, .cancelled, "the failed request restored the result before the cancellation")
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.terminalState, .cancelled)
            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .cancelled)
            let stored = await AgentRunSessionStore.snapshot(for: registration)
            XCTAssertEqual(stored?.status, storedAtCancellation?.status, "the failed request changed the stored result")
            XCTAssertNotEqual(stored?.status, .completed)
        }

        /// A compaction request that fails after a successor took the session leaves the
        /// successor's attempt and state alone.
        func testCompactionFailureAfterASuccessorStartedLeavesTheSuccessorAlone() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            _ = try await fixture.beginHeldFailingCompaction()
            try await settleWithin(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }

            let successor = Task { await fixture.viewModel.startAgentRun(tabID: fixture.tabID, initialMessage: "successor") }
            fixture.cleanup.join(successor)
            try await eventually { fixture.readiness.isWaiting(1) }
            let successorOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            let successorRunState = fixture.session.runState
            try await fixture.releaseCompactionFailure()

            XCTAssertEqual(fixture.session.activeRunOwnership, successorOwnership, "the failed request ended the successor's attempt")
            XCTAssertEqual(fixture.session.runState, successorRunState)

            fixture.readiness.release(1, ready: true)
            try await eventually { fixture.controller.startUserTurnTexts == ["successor"] }
        }

        /// The `/goal` objective bubble is a local echo of a control-plane command, not a run
        /// submission, so it does not hide the previous run's recorded result.
        func testControlPlaneEchoDoesNotDisplaceThePreviousCompletion() async throws {
            let fixture = makeFixture()
            startupTestInstallRestoredState(
                on: fixture.session,
                items: [.user("earlier", sequenceIndex: 0), .assistant("done", sequenceIndex: 1)],
                persistedRunState: .idle
            )
            fixture.session.transcript.turns[fixture.session.transcript.turns.count - 1].terminalState = .completed
            try await fixture.activateMCPControl(startPending: false)

            fixture.session.appendItem(.user(
                "ship the release",
                codexGoalMode: AgentCodexGoalModeMetadata(action: .setObjective),
                isLocalControlPlaneEcho: true
            ))

            XCTAssertEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .completed)
        }

        func testNonCodexLiveAndTerminalStatusesAreUnchanged() async throws {
            let fixture = makeFixture()
            fixture.session.selectedAgent = .claudeCode
            startupTestInstallRestoredState(
                on: fixture.session,
                items: [.user("claude task", sequenceIndex: 0), .assistant("done", sequenceIndex: 1)],
                persistedRunState: .completed
            )
            try await fixture.activateMCPControl(startPending: false)

            let cases: [(AgentSessionRunState, AgentRunMCPSnapshot.Status)] = [
                (.completed, .completed),
                (.failed, .failed),
                (.cancelled, .cancelled),
                (.running, .running),
                (.waitingForUser, .waitingForInput),
                (.waitingForQuestion, .waitingForInput),
                (.waitingForApproval, .waitingForInput)
            ]
            for (runState, expected) in cases {
                fixture.session.runState = runState
                XCTAssertEqual(
                    fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status,
                    expected,
                    runState.rawValue
                )
            }
            fixture.session.runState = .completed
        }

        /// Deactivation suspends at the approval store before it removes the control context; while
        /// it is held there the session is still under control with its queued start, so neither
        /// the live nor the stored snapshot reads as a failure nobody recorded.
        func testDeactivatingAPendingStartNeverShowsAnUnrecordedFailure() async throws {
            let fixture = makeFixture()
            let registration = try await fixture.activateMCPControl(startPending: true)
            let session = fixture.session
            let viewModel = fixture.viewModel
            let sessionID = fixture.sessionID
            let approvalRestoreHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(approvalRestoreHold)
            viewModel.test_beforeMCPDeactivationAutoEditRestore = { await approvalRestoreHold.wait() }
            let deactivation = Task { await viewModel.mcpDeactivateControlContext(sessionID: sessionID) }
            fixture.cleanup.join(deactivation)
            try await eventually { approvalRestoreHold.isWaiting }

            XCTAssertNotNil(session.mcpControlContext, "the deactivation removed the context before it suspended")
            XCTAssertEqual(viewModel.mcpSnapshot(sessionID: sessionID)?.status, .running)
            viewModel.publishMCPStateChange(for: session)
            let storedWhileHeld = try await storeSnapshot(for: registration) { $0 != nil }
            XCTAssertEqual(storedWhileHeld?.status, .running)

            approvalRestoreHold.release()
            try await startupTestJoin(deactivation)
            XCTAssertNil(session.mcpControlContext)
            XCTAssertFalse(session.mcpFollowUpRunPending)
        }

        // MARK: - Store-backed waits

        /// A caller waiting through the store sees nothing terminal while a start is held at
        /// readiness, and the completed result once the run finishes.
        func testWaitingCallerSeesOnlyTheCompletedResultOfASuccessfulStart() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let registration = try await fixture.activateMCPControl(startPending: true)
            let cursor = try XCTUnwrap(fixture.viewModel.mcpWaitCursor(sessionID: fixture.sessionID))
            let waiter = StoreWaitOutcome()
            let waitTask = Task { @MainActor in
                waiter.snapshot = await Self.waitForActionableSnapshot(from: cursor)
                waiter.finished = true
            }
            // The waiter would otherwise hold teardown for its full timeout.
            fixture.cleanup.releases.append { waitTask.cancel() }
            fixture.cleanup.join(waitTask)

            _ = try fixture.submit("hello")
            try await eventually { fixture.readiness.isWaiting(1) }
            // Publish an observation of the held start. The store keeps a terminal snapshot against
            // later nonterminal ones, so once it holds this running snapshot, no terminal result
            // reached it or its waiter.
            fixture.viewModel.publishMCPStateChange(for: fixture.session)
            let storedWhileHeld = try await storeSnapshot(for: registration) { $0?.status == .running }
            XCTAssertEqual(storedWhileHeld?.status, .running)
            XCTAssertFalse(waiter.finished, "the waiting caller was woken by \(String(describing: waiter.snapshot?.status))")

            fixture.readiness.release(1, ready: true)
            try await eventually { fixture.controller.startUserTurnTexts == ["hello"] }
            try await fixture.completeActiveTurn(turnID: "hello-turn")

            try await eventually { waiter.finished }
            XCTAssertEqual(waiter.snapshot?.status, .completed)
            let stored = await AgentRunSessionStore.snapshot(for: registration)
            XCTAssertEqual(stored?.status, .completed)
        }

        /// Reads the store until its snapshot for `registration` satisfies `condition`, boundedly.
        private func storeSnapshot(
            for registration: AgentRunSessionStore.Registration,
            file: StaticString = #filePath,
            line: UInt = #line,
            until condition: @escaping (AgentRunMCPSnapshot?) -> Bool
        ) async throws -> AgentRunMCPSnapshot? {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let snapshot = await AgentRunSessionStore.snapshot(for: registration)
                if condition(snapshot) { return snapshot }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTFail("the store never reached the expected snapshot", file: file, line: line)
            return await AgentRunSessionStore.snapshot(for: registration)
        }

        /// The store loop `agent_run wait` runs: follow related epoch advances until a snapshot a
        /// caller acts on arrives, or give up with nil.
        private static func waitForActionableSnapshot(
            from initialCursor: AgentRunSessionStore.WaitCursor
        ) async -> AgentRunMCPSnapshot? {
            var cursor = initialCursor
            while !Task.isCancelled {
                switch await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 30) {
                case let .snapshotReady(snapshot):
                    return snapshot
                case let .noteworthySnapshot(wake):
                    if wake.snapshot.isActionableForMCPWait { return wake.snapshot }
                case let .epochAdvanced(epoch, kind):
                    guard kind != .unrelated else { return nil }
                    cursor = .init(registration: cursor.registration, epoch: epoch)
                case .terminalPublicationRejected, .timedOut, .expired, .cancelled:
                    return nil
                }
            }
            return nil
        }

        @MainActor
        private final class StoreWaitOutcome {
            var snapshot: AgentRunMCPSnapshot?
            var finished = false
        }

        /// A waiting `agent_run wait` caller learns of an idle session with no terminal evidence
        /// through the store, not only through a fresh read of the live snapshot.
        func testWaitingCallerReceivesTheUnrecordedFailureOfAnIdleSession() async throws {
            let waiter = try await makeStoreBackedWaiter()
            waiter.context.session.appendItem(.user("prompt that never ran"))
            await waiter.viewModel.prepareMCPWaitTrackingForRunStart(session: waiter.context.session)
            try await waiter.beginWaiting()

            waiter.viewModel.setMCPFollowUpRunPending(sessionID: waiter.context.sessionID, false)

            let result = try await waiter.result()
            XCTAssertEqual(result?["status"]?.stringValue, AgentRunMCPSnapshot.Status.failed.rawValue)
            XCTAssertEqual(result?["status_text"]?.stringValue, AgentModeViewModel.mcpUnrecordedTerminalStatusText)
            let stored = try await waiter.storedSnapshot()
            XCTAssertEqual(stored?.status, .failed)
        }

        /// An accepted start rejected before any runner exists reaches a caller already waiting on
        /// a freshly activated session, and the store keeps that failure.
        func testStartRejectedBeforeTheRunnerReachesAWaitingCallerOnAFreshActivation() async throws {
            let waiter = try await makeStoreBackedWaiter()
            try await waiter.beginWaiting()

            try waiter.submitRejectedAtTheRunGate("never reaches a runner")

            try await assertRejectedStartFailure(waiter)
        }

        /// The same rejection after a completed run on an earlier activation reports the new
        /// failure, not the earlier completion.
        func testStartRejectedBeforeTheRunnerReplacesACompletedEarlierEpoch() async throws {
            let waiter = try await makeStoreBackedWaiter()
            let viewModel = waiter.viewModel
            let session = waiter.context.session
            session.appendItem(.user("earlier", sequenceIndex: session.nextSequenceIndex))
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
            let registration = try XCTUnwrap(viewModel.mcpRegistration(sessionID: waiter.context.sessionID))
            let epoch = try XCTUnwrap(session.mcpControlContext?.preparedEpoch)
            session.appendItem(.assistant("earlier answer", sequenceIndex: session.nextSequenceIndex))
            session.runState = .completed
            let completed = try XCTUnwrap(viewModel.mcpSnapshot(for: session, canonicalTerminalState: .completed))
            let publication = await AgentRunSessionStore.publishTerminal(
                AgentRunTerminalPublicationEnvelope(epoch: epoch, snapshot: completed),
                registration: registration,
                commitID: UUID(),
                successorKind: nil
            )
            guard case .accepted = publication else {
                return XCTFail("the earlier completion was not published: \(publication)")
            }
            try await viewModel.mcpActivateControlContext(
                forTabID: session.tabID,
                sessionID: waiter.context.sessionID,
                originatingConnectionID: nil,
                startPending: true
            )
            try await waiter.beginWaiting()

            try waiter.submitRejectedAtTheRunGate("follow-up that never reaches a runner")

            try await assertRejectedStartFailure(waiter)
        }

        private func assertRejectedStartFailure(
            _ waiter: StoreBackedWaiter,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let result = try await waiter.result(file: file, line: line)
            let errorText = try XCTUnwrap(
                waiter.context.session.items.last { $0.kind == .error }?.text,
                "the rejection left no visible error",
                file: file,
                line: line
            )
            XCTAssertEqual(result?["status"]?.stringValue, AgentRunMCPSnapshot.Status.failed.rawValue, file: file, line: line)
            XCTAssertEqual(result?["status_text"]?.stringValue, errorText, file: file, line: line)
            let stored = try await waiter.storedSnapshot()
            XCTAssertEqual(stored?.status, .failed, "the store kept no failure", file: file, line: line)
            XCTAssertEqual(stored?.statusText, errorText, file: file, line: line)
        }

        /// A real window's session under MCP control with an `agent_run wait` caller reading
        /// through `AgentRunMCPToolService` and the session store.
        private func makeStoreBackedWaiter() async throws -> StoreBackedWaiter {
            let waiter = try await StoreBackedWaiter.make()
            addTeardownBlock { @MainActor in await waiter.tearDown() }
            return waiter
        }

        /// A real window's session under MCP control with an `agent_run wait` caller reading
        /// through `AgentRunMCPToolService` and the session store.
        @MainActor
        private final class StoreBackedWaiter {
            let context: AgentRunMCPControlledSessionContext
            private let waitBegan = StartupTestCompletionFlag()
            private let outcome = WaitOutcome()
            private var waitTask: Task<Void, Never>?

            var viewModel: AgentModeViewModel {
                context.window.agentModeViewModel
            }

            private init(context: AgentRunMCPControlledSessionContext) {
                self.context = context
            }

            static func make() async throws -> StoreBackedWaiter {
                let context = try await AgentRunMCPControlledSessionContext.make(
                    workspaceNamePrefix: "Startup Snapshot",
                    workspaceSwitchReason: "agentRunStartupSnapshotTests",
                    clientName: "agent-run-startup-snapshot-tests",
                    unusedStartRunMessage: "startRun should not be used by startup snapshot tests",
                    bindWorkspaceComposeTab: true
                )
                context.session.selectedAgent = .codexExec
                return StoreBackedWaiter(context: context)
            }

            func beginWaiting(file: StaticString = #filePath, line: UInt = #line) async throws {
                var service = context.service
                let waitBegan = waitBegan
                service.beginAgentRunWait = { _, _, _ in
                    await MainActor.run { waitBegan.value = true }
                    return nil
                }
                let sessionID = context.sessionID
                let outcome = outcome
                waitTask = Task { @MainActor in
                    do {
                        outcome.value = try await service.execute(args: [
                            "op": .string("wait"),
                            "session_id": .string(sessionID.uuidString),
                            "timeout": .double(30)
                        ]).objectValue
                    } catch {
                        outcome.error = error
                    }
                    outcome.finished = true
                }
                guard await startupTestWaitBounded(until: { waitBegan.value }) else {
                    XCTFail(
                        "the wait never began: \(String(describing: outcome.error)) \(String(describing: outcome.value))",
                        file: file,
                        line: line
                    )
                    throw CancellationError()
                }
            }

            /// Submits while the agent is available, then withdraws availability so the accepted
            /// start is rejected at the run gate, before any runner exists.
            func submitRejectedAtTheRunGate(_ text: String) throws {
                viewModel.test_agentAvailabilityForRunOverride = { _ in true }
                XCTAssertEqual(viewModel.submitUserTurn(text: text, tabID: context.session.tabID), .submitted)
                XCTAssertNotNil(context.session.unresolvedStartupTicket)
                viewModel.test_agentAvailabilityForRunOverride = { _ in false }
            }

            func result(file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Value]? {
                let outcome = outcome
                guard await startupTestWaitBounded(until: { outcome.finished }) else {
                    XCTFail("the waiting caller was never woken", file: file, line: line)
                    return nil
                }
                if let error = outcome.error { throw error }
                return outcome.value
            }

            func storedSnapshot() async throws -> AgentRunMCPSnapshot? {
                let registration = try XCTUnwrap(viewModel.mcpRegistration(sessionID: context.sessionID))
                return await AgentRunSessionStore.snapshot(for: registration)
            }

            func tearDown() async {
                waitTask?.cancel()
                if let waitTask {
                    await startupTestAwaitBounded("the waiting caller did not finish during teardown") {
                        await waitTask.value
                    }
                }
                let viewModel = viewModel
                let tabID = context.session.tabID
                if context.session.runState.isActive || context.session.unresolvedStartupTicket != nil {
                    await startupTestAwaitBounded("the rejected start did not cancel during teardown") {
                        await viewModel.cancelAgentRun(tabID: tabID)
                    }
                }
                let context = context
                await startupTestAwaitBounded("the window did not tear down") { await context.cleanup() }
            }
        }

        @MainActor
        private final class WaitOutcome {
            var value: [String: Value]?
            var error: Error?
            var finished = false
        }

        // MARK: - Fixture

        /// Adds held `/compact` requests to the shared fixture.
        @MainActor
        private final class Fixture: StartupTestSessionFixture {
            /// Starts `/compact` on a completed MCP-controlled session with the request held and
            /// set to fail once released.
            func beginHeldFailingCompaction() async throws -> AgentRunSessionStore.Registration {
                let hold = StartupTestHeldGate()
                cleanup.heldGates.append(hold)
                controller.compactHold = hold
                controller.compactError = NSError(
                    domain: "AgentRunStartupSnapshotTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "compaction request failed"]
                )
                startupTestInstallRestoredState(
                    on: session,
                    items: [.user("task", sequenceIndex: 0), .assistant("done", sequenceIndex: 1)],
                    persistedRunState: .completed
                )
                session.codexConversationID = "startup-ticket-test"
                let registration = try await activateMCPControl(startPending: false)
                XCTAssertEqual(viewModel.submitUserTurn(text: "/compact", tabID: tabID), .submittedControlPlaneCommand)
                guard await startupTestWaitBounded(until: { hold.isWaiting }) else {
                    XCTFail("the compaction request never started")
                    throw CancellationError()
                }
                XCTAssertEqual(session.runState, .running)
                return registration
            }

            /// Releases the held compaction request and waits for its failure to be reported.
            func releaseCompactionFailure() async throws {
                controller.compactHold?.release()
                let session = session
                guard await startupTestWaitBounded(until: {
                    session.items.contains { $0.text == "Codex context compaction failed: compaction request failed" }
                }) else {
                    XCTFail("the failed compaction request was never reported")
                    throw CancellationError()
                }
            }
        }

        private func makeFixture(gatedReadinessCalls: Set<Int> = []) -> Fixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: gatedReadinessCalls)
            let controller = StartupTestCodexController(gatesStartup: false)
            let viewModel = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                testWorkspaceDirectory: storageRoot,
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

        private func settleWithin(
            on fixture: StartupTestSessionFixture,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ operation: @escaping @MainActor () async -> Void
        ) async throws {
            try await startupTestSettle(on: fixture, file: file, line: line, operation)
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
