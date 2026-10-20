import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Drives Claude idle provider shutdown through the real submission, runner, terminal barrier,
    /// and coordinator. The provider process is a recording fake. The idle timer runs on a manual
    /// clock: a deadline passes only when a test advances it.
    @MainActor
    final class ClaudeIdleShutdownTests: XCTestCase {
        private typealias Outcome = ClaudeAgentModeCoordinator.IdleTimerOutcome

        /// The default setting of 5 minutes, which every fixture starts with.
        private static let interval: Duration = .seconds(GlobalSettingsStore.defaultIdleProviderShutdownMinutes * 60)

        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeIdleShutdownTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        func testIdleRetirementResumesWithFreshProcessRunIdentity() async throws {
            let fixture = makeFixture()
            let session = fixture.session
            let clock = fixture.idle.clock

            // The process is attached when the first message is sent, and its run ends 3 minutes later.
            try await fixture.sendTurn("first message")
            clock.advance(by: .seconds(3 * 60))
            try await fixture.completeSentTurn()
            let terminalDeadline = clock.now + Self.interval
            let firstRunID = try XCTUnwrap(session.runID)
            let providerSessionID = try XCTUnwrap(session.providerSessionID)
            let itemsBefore = session.items
            let revisionBefore = session.lastTerminalCommitRevision
            let publicationBefore = session.lastTerminalPublicationResult

            // The deadline armed at attach passes, but the terminal restarted the timer.
            clock.advance(by: .seconds(2 * 60))
            try await expectIdleOutcomes([.stale], on: fixture, countingStale: true)
            XCTAssertEqual(clock.pendingDeadlines, [terminalDeadline])
            XCTAssertEqual(fixture.claude.shutdownsStarted, 0)

            clock.advance(by: .seconds(3 * 60 - 1))
            XCTAssertEqual(clock.pendingDeadlines, [terminalDeadline], "a deadline before the terminal's came due")
            XCTAssertEqual(fixture.claude.shutdownsStarted, 0)

            clock.advance(by: .seconds(1))
            try await expectIdleOutcomes([.stale, .retired], on: fixture, countingStale: true)
            try await startupTestEventually {
                fixture.claude.shutdownObservations.count == 1
                    && !fixture.coordinator.hasPendingResumeTransfer(for: session)
            }
            XCTAssertNil(session.claudeController)
            XCTAssertNil(session.runID, "the retired process kept its run ID")
            XCTAssertEqual(session.providerSessionID, providerSessionID)
            XCTAssertEqual(session.items, itemsBefore)
            XCTAssertEqual(session.runState, .completed)
            XCTAssertEqual(session.lastTerminalCommitRevision, revisionBefore)
            XCTAssertEqual(session.lastTerminalPublicationResult, publicationBefore)

            try await fixture.sendTurn("second message")
            let secondRunID = try XCTUnwrap(session.runID)
            XCTAssertNotEqual(secondRunID, firstRunID)
            XCTAssertEqual(fixture.claude.runtimeRunIDs, [firstRunID, secondRunID])
            XCTAssertEqual(fixture.claude.sessionStartTargets, [nil, providerSessionID])
        }

        func testBusySessionKeepsProcessUntilWorkClears() async throws {
            let protections: [Protection] = [
                Protection("pending interaction") { fixture in
                    fixture.session.pendingApproval = Self.claudeApprovalRequest(id: "approval")
                    return { fixture.session.pendingApproval = nil }
                },
                Protection("pending instruction") { fixture in
                    fixture.session.pendingInstructions = [AgentQueuedInstruction(
                        text: "queued",
                        submissionID: nil,
                        constituentSubmissionIDs: [],
                        restorationDraftText: "queued"
                    )]
                    return { fixture.session.pendingInstructions = [] }
                },
                Protection("follow-up pending") { fixture in
                    fixture.session.mcpFollowUpRunPending = true
                    return { fixture.session.mcpFollowUpRunPending = false }
                },
                Protection("unresolved startup ticket") { fixture in
                    let ticket = try XCTUnwrap(fixture.session.installStartupTicketIfAbsent())
                    return { ticket.resolve(.cancelled) }
                },
                Protection("MCP pending start") { fixture in
                    fixture.session.mcpPendingStartOwner = UUID()
                    return { fixture.session.mcpPendingStartOwner = nil }
                },
                Protection("binding transition") { fixture in
                    let generation = fixture.session.beginPersistentBindingTransition()
                    return { fixture.session.finishPersistentBindingTransition(generation: generation) }
                },
                Protection("MCP tool on the run ID") { fixture in
                    let runID = try XCTUnwrap(fixture.session.runID)
                    fixture.idle.runIDsWithActiveMCPTools.insert(runID)
                    return { fixture.idle.runIDsWithActiveMCPTools.remove(runID) }
                },
                Protection("child wait on the run ID") { fixture in
                    let runID = try XCTUnwrap(fixture.session.runID)
                    fixture.idle.runIDsWithActiveChildWaits.insert(runID)
                    return { fixture.idle.runIDsWithActiveChildWaits.remove(runID) }
                },
                Protection("turn in flight") { fixture in
                    fixture.claude.probeReportsTurnInFlight = true
                    return { fixture.claude.probeReportsTurnInFlight = false }
                },
                Protection("missing provider ID") { fixture in
                    let providerSessionID = fixture.session.providerSessionID
                    fixture.session.providerSessionID = nil
                    return { fixture.session.providerSessionID = providerSessionID }
                }
            ]
            for protection in protections {
                // A case that throws has already recorded its failure. The loop goes on to the next case.
                try? await expectProtectionKeepsProcess(protection)
            }

            // A message admitted while the probe is out keeps the process, and its run uses it.
            do {
                let fixture = makeFixture()
                try await fixture.runTurn("turn")
                let probeHold = StartupTestHeldGate()
                fixture.cleanup.heldGates.append(probeHold)
                fixture.claude.probeHold = probeHold
                fixture.idle.clock.advance(by: Self.interval)
                try await startupTestEventually { probeHold.isWaiting }
                let ticket = try fixture.submit("admitted during the probe")
                probeHold.release()
                try await expectIdleOutcomes([.rearmed], on: fixture, "submission admitted during the probe")
                XCTAssertEqual(fixture.claude.shutdownsStarted, 0)

                try await startupTestJoin(ticket.task)
                try await startupTestEventually { fixture.claude.sentMessages.count == 2 }
                XCTAssertEqual(fixture.claude.runtimesCreated, 1, "the admitted message started a new process")
                try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
                try await fixture.completeSentTurn()
                fixture.idle.clock.advance(by: Self.interval)
                try await expectIdleOutcomes([.rearmed, .retired], on: fixture, "submission admitted during the probe")
            }

            // Another session waiting on this one reads its run state, not its process.
            do {
                let fixture = makeFixture()
                try await fixture.runTurn("turn")
                fixture.idle.runIDsWithActiveChildWaits.insert(UUID())
                fixture.idle.clock.advance(by: Self.interval)
                try await expectIdleOutcomes([.retired], on: fixture, "outside waiter")
            }
        }

        func testTimerEndsWithoutShutdownWhenControllerReplacedOrSettingOff() async throws {
            do {
                let fixture = makeFixture()
                try await fixture.runTurn("turn")
                let replacement = fixture.claude.makeRuntime(runID: UUID())
                fixture.session.claudeController = replacement
                fixture.idle.clock.advance(by: Self.interval)
                try await expectIdleOutcomes([.ended], on: fixture, "controller replaced")
                XCTAssertEqual(fixture.claude.shutdownsStarted, 0)
                XCTAssertTrue(fixture.session.claudeController === replacement)
            }
            do {
                let fixture = makeFixture()
                try await fixture.runTurn("turn")
                fixture.idle.idleMinutes = 0
                fixture.idle.clock.advance(by: Self.interval)
                try await expectIdleOutcomes([.ended], on: fixture, "setting 0 at the deadline")
                XCTAssertEqual(fixture.claude.shutdownsStarted, 0)
                XCTAssertNotNil(fixture.session.claudeController)
            }
        }

        func testMessageDuringRetirementWaitsForOldProcess() async throws {
            // A conversation reset can move the retirement's transfer to the retired list before
            // the retirement's own wait on that transfer starts.
            for resetsBeforeTheWaitStarts in [false, true] {
                let label = resetsBeforeTheWaitStarts ? "reset before the wait starts" : "no reset"
                let fixture = makeFixture()
                try await fixture.runTurn("first message")
                let providerSessionID = try XCTUnwrap(fixture.session.providerSessionID)
                let shutdownHold = StartupTestHeldGate()
                fixture.cleanup.heldGates.append(shutdownHold)
                fixture.claude.shutdownHold = shutdownHold
                if resetsBeforeTheWaitStarts {
                    // `.retired` is reported in the retirement's main-actor slice, before its wait
                    // task can run.
                    fixture.onIdleOutcome = { [weak fixture] outcome in
                        guard outcome == .retired, let fixture else { return }
                        fixture.coordinator.prepareForConversationResetSync(fixture.session)
                    }
                }

                fixture.idle.clock.advance(by: Self.interval)
                try await expectIdleOutcomes([.retired], on: fixture, label)
                try await startupTestEventually { fixture.claude.shutdownsStarted == 1 }

                let transferWaitsBefore = fixture.runAttemptTransferWaits
                let ticket = try fixture.submit("sent while the old process exits")
                try await startupTestJoin(ticket.task)
                try await startupTestEventually { fixture.runAttemptTransferWaits == transferWaitsBefore + 1 }
                XCTAssertEqual(fixture.claude.runtimesCreated, 1, label)
                XCTAssertEqual(fixture.claude.sessionStarts, 1, label)
                XCTAssertEqual(fixture.claude.sentMessages.count, 1, label)

                shutdownHold.release()
                try await startupTestEventually { fixture.claude.sentMessages.count == 2 }
                XCTAssertEqual(fixture.claude.events, [
                    .created(runtime: 0),
                    .sessionStarted(runtime: 0),
                    .messageSent(runtime: 0),
                    .shutdownFinished(runtime: 0),
                    .created(runtime: 1),
                    .sessionStarted(runtime: 1),
                    .messageSent(runtime: 1)
                ], label)
                XCTAssertEqual(fixture.claude.sessionStartTargets, [nil, providerSessionID], label)
            }
        }

        func testRetirementSurvivesTimerReplacementAndStop() async throws {
            let fixture = makeFixture()
            let viewModel = fixture.viewModel
            let tabID = fixture.tabID
            try await fixture.runTurn("first message")
            let providerSessionID = try XCTUnwrap(fixture.session.providerSessionID)
            let shutdownHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(shutdownHold)
            fixture.claude.shutdownHold = shutdownHold

            fixture.idle.clock.advance(by: Self.interval)
            try await expectIdleOutcomes([.retired], on: fixture)
            try await startupTestEventually { fixture.claude.shutdownsStarted == 1 }

            // While the old process exits, arm the tab's timer. With no controller attached, arming
            // cancels whatever task the tab's timer slot holds, so this step fails if the timer task
            // awaited the shutdown itself and kept its entry meanwhile. Then hide Agent Mode, and
            // send and cancel a message.
            fixture.coordinator.armClaudeIdleTimer(for: fixture.session)
            fixture.coordinator.stop()
            let transferWaitsBefore = fixture.runAttemptTransferWaits
            let cancelled = try fixture.submit("cancelled message")
            try await startupTestJoin(cancelled.task)
            try await startupTestEventually { fixture.runAttemptTransferWaits == transferWaitsBefore + 1 }
            try await startupTestSettle(on: fixture) { await viewModel.cancelAgentRun(tabID: tabID) }
            try await startupTestEventually { !fixture.session.runState.isActive && fixture.session.agentTask == nil }

            let second = try fixture.submit("second message")
            try await startupTestJoin(second.task)
            try await startupTestEventually { fixture.runAttemptTransferWaits == transferWaitsBefore + 2 }
            XCTAssertEqual(fixture.claude.runtimesCreated, 1)

            shutdownHold.release()
            try await startupTestEventually { fixture.claude.sentMessages.count == 2 }
            XCTAssertEqual(fixture.claude.shutdownObservations, [
                .init(runtime: 0, cancelledAtStart: false, cancelledAtFinish: false)
            ])
            XCTAssertEqual(fixture.claude.runtimesCreated, 2)
            XCTAssertEqual(
                fixture.claude.events.firstIndex(of: .shutdownFinished(runtime: 0)).map { $0 + 1 },
                fixture.claude.events.firstIndex(of: .created(runtime: 1)),
                "the next process started before the old one exited"
            )
            XCTAssertTrue(fixture.claude.sentMessages[1].contains("second message"), fixture.claude.sentMessages[1])
            XCTAssertFalse(fixture.claude.sentMessages.contains { $0.contains("cancelled message") })
            XCTAssertEqual(fixture.claude.sessionStartTargets, [nil, providerSessionID])
        }

        /// The session keeps its process past a deadline while `protection` holds, and retires a
        /// full interval later once it is released.
        private func expectProtectionKeepsProcess(_ protection: Protection) async throws {
            let label = protection.label
            let fixture = makeFixture()
            try await fixture.runTurn("turn")
            let release = try protection.apply(fixture)

            fixture.idle.clock.advance(by: Self.interval)
            try await expectIdleOutcomes([.rearmed], on: fixture, label)
            XCTAssertEqual(fixture.claude.shutdownsStarted, 0, label)
            XCTAssertNotNil(fixture.session.claudeController, label)

            release()
            fixture.idle.clock.advance(by: Self.interval)
            try await expectIdleOutcomes([.rearmed, .retired], on: fixture, label)
            try await startupTestEventually { fixture.claude.shutdownObservations.count == 1 }
        }

        // MARK: - Fixture

        /// Work that keeps an idle session's process. `apply` installs it and returns its release.
        private struct Protection {
            let label: String
            let apply: @MainActor (Fixture) throws -> @MainActor () -> Void

            init(_ label: String, apply: @escaping @MainActor (Fixture) throws -> @MainActor () -> Void) {
                self.label = label
                self.apply = apply
            }
        }

        /// A Claude session in a view model whose idle timer runs on a manual clock, recording the
        /// decisions its deadlines make and the run attempts that wait for its resume transfer.
        @MainActor
        private final class Fixture: StartupTestSessionFixture {
            let claude: StartupTestClaudeRecorder
            let idle: StartupTestClaudeIdleEnvironment
            /// What each of this tab's idle-timer deadlines decided, in order.
            private(set) var idleOutcomes: [Outcome] = []
            /// Called with each decision as the coordinator reports it, in the same main-actor slice.
            var onIdleOutcome: (@MainActor (Outcome) -> Void)?
            /// Run attempts that reached the wait for this tab's resume transfer.
            private(set) var runAttemptTransferWaits = 0

            var coordinator: ClaudeAgentModeCoordinator {
                viewModel.claudeCoordinator
            }

            init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController,
                claude: StartupTestClaudeRecorder,
                idle: StartupTestClaudeIdleEnvironment
            ) {
                self.claude = claude
                self.idle = idle
                super.init(viewModel: viewModel, session: session, readiness: readiness, controller: controller)
                let tabID = session.tabID
                viewModel.claudeCoordinator.test_idleTimerOutcomeObserver = { [weak self] observedTabID, outcome in
                    guard observedTabID == tabID, let self else { return }
                    idleOutcomes.append(outcome)
                    onIdleOutcome?(outcome)
                }
                viewModel.claudeCoordinator.test_runAttemptWillAwaitResumeTransfer = { [weak self] waitingSession in
                    guard waitingSession.tabID == tabID else { return }
                    self?.runAttemptTransferWaits += 1
                }
            }

            /// Sends `text` as a manual turn and waits until the provider has it and its run is routed.
            func sendTurn(_ text: String) async throws {
                let sentBefore = claude.sentMessages.count
                let ticket = try submit(text)
                try await startupTestJoin(ticket.task)
                let sent = await startupTestWaitBounded { self.claude.sentMessages.count == sentBefore + 1 }
                XCTAssertTrue(sent, "the provider never received \(text)")
                try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(session.runID))
            }

            /// Completes the turn sent last and waits until its terminal has committed, which
            /// restarts the idle timer.
            func completeSentTurn() async throws {
                let runtime = try XCTUnwrap(claude.runtimes.last)
                let turnID = try XCTUnwrap(claude.sentTurnIDs.last)
                await runtime.emit(.turnCompleted(turnID: turnID, status: .completed))
                let committed = await startupTestWaitBounded(seconds: 15) {
                    self.session.runState == .completed && !self.session.terminalCommitInProgress
                }
                XCTAssertTrue(committed, "the turn's terminal never committed")
            }

            func runTurn(_ text: String) async throws {
                try await sendTurn(text)
                try await completeSentTurn()
            }
        }

        /// Builds a Claude fixture at the default setting and registers its teardown before any
        /// test step can throw.
        private func makeFixture() -> Fixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: false)
            let claude = StartupTestClaudeRecorder()
            let idle = StartupTestClaudeIdleEnvironment()
            let viewModel = startupTestMakeViewModel(
                storageRoot: storageRoot,
                readiness: readiness,
                controller: controller,
                claude: claude,
                claudeIdle: idle
            )
            let session = startupTestCodexSession()
            session.selectedAgent = .claudeCode
            let fixture = Fixture(
                viewModel: viewModel,
                session: session,
                readiness: readiness,
                controller: controller,
                claude: claude,
                idle: idle
            )
            addTeardownBlock { @MainActor in
                await fixture.tearDown()
                idle.clock.cancelSleepers()
            }
            return fixture
        }

        /// Waits until this tab's deadlines have made `expected.count` decisions and checks them.
        /// Decisions of replaced timers are left out unless `countingStale` is set.
        private func expectIdleOutcomes(
            _ expected: [Outcome],
            on fixture: Fixture,
            countingStale: Bool = false,
            _ label: String = "",
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            func outcomes() -> [Outcome] {
                countingStale ? fixture.idleOutcomes : fixture.idleOutcomes.filter { $0 != .stale }
            }
            try await startupTestEventually(file: file, line: line) { outcomes().count >= expected.count }
            XCTAssertEqual(outcomes(), expected, label, file: file, line: line)
        }

        private static func claudeApprovalRequest(id: String) -> AgentApprovalRequest {
            AgentApprovalRequest(
                requestID: .claudeControl(id),
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
