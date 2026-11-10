import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Drives turns Claude Code starts by itself through the real view model, run service, terminal
    /// barrier, and coordinator. The Claude process is a recording fake that emits only the events a
    /// test sends it.
    @MainActor
    final class ClaudeProviderStartedTurnTests: XCTestCase {
        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeProviderStartedTurnTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        /// Each turn Claude Code starts while the session is idle becomes its own attempt on the
        /// process run, under a related follow-up epoch, and publishes once. Nothing is sent and no
        /// user row is added.
        func testIdleProviderTurnsBecomeSeparateAttemptsThatPublishOnce() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            try await fixture.activateMCPControl()
            try await fixture.runHostTurn("host message", answer: "host answer")
            let processRunID = try XCTUnwrap(fixture.session.runID)
            let userRowIDs = fixture.userRowIDs

            try await fixture.runProviderTurn(events: [Self.content("first wake-up")])
            try await fixture.runProviderTurn(events: [Self.content("second wake-up")])

            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed, .completed, .completed])
            XCTAssertEqual(Set(publications.revisions.map(\.ownership.attemptID)).count, 3)
            let providerRevisions = Array(publications.revisions.dropFirst())
            XCTAssertEqual(providerRevisions.map(\.expectedRunID), [processRunID, processRunID])
            XCTAssertEqual(providerRevisions.map(\.ownership.turnEpoch?.transitionKind), [.relatedFollowUp, .relatedFollowUp])
            let ordinals = publications.revisions.compactMap(\.ownership.turnEpoch?.ordinal)
            XCTAssertEqual(ordinals, ordinals.sorted())
            XCTAssertEqual(Set(ordinals).count, 3, "\(ordinals)")
            XCTAssertEqual(fixture.session.runID, processRunID)
            XCTAssertEqual(fixture.userRowIDs, userRowIDs)
            XCTAssertEqual(fixture.claude.runtimesCreated, 1)
            XCTAssertEqual(fixture.claude.sentMessages.count, 1)
            XCTAssertEqual(
                fixture.session.items.filter { $0.kind == .assistant }.map(\.text),
                ["host answer", "first wake-up", "second wake-up"]
            )
        }

        /// A turn Claude Code started by itself whose only output is its final reply gets a new
        /// assistant row; the previous run's answer keeps its text and identity.
        func testFinalOnlyProviderReplyAddsARowInsteadOfReplacingThePreviousAnswer() async throws {
            let fixture = makeFixture()
            try await fixture.runHostTurn("host message", answer: "host answer")
            let hostAnswer = try XCTUnwrap(fixture.session.items.last { $0.kind == .assistant })

            try await fixture.runProviderTurn(events: [
                .stream(AIStreamResult(type: "final_content", text: "wake-up answer"))
            ])

            let assistantRows = fixture.session.items.filter { $0.kind == .assistant }
            XCTAssertEqual(assistantRows.map(\.text), ["host answer", "wake-up answer"])
            XCTAssertEqual(assistantRows.first?.id, hostAnswer.id)
        }

        /// The tool calls and usage of a turn Claude Code started by itself are recorded for its
        /// own attempt, which has no user input, and a queued submission keeps its estimate.
        func testProviderTurnToolsAndUsageBelongToItsAttempt() async throws {
            let fixture = makeFixture()
            try await fixture.runHostTurn("host message", answer: "host answer")
            let hostAnswer = try XCTUnwrap(fixture.session.items.last { $0.kind == .assistant })
            let queuedSubmissionID = UUID()
            fixture.session.pendingNonCodexUserInputTokenQueue.append(.init(submissionID: queuedSubmissionID, tokens: 42))
            let usageRowsBefore = fixture.session.providerTokenUsageByTurn.count
            let invocationID = UUID()

            try await fixture.runProviderTurn(events: [
                .stream(AIStreamResult(
                    type: "tool_call",
                    text: nil,
                    toolName: "Bash",
                    toolInvocationID: invocationID,
                    toolArgsJSON: #"{"command":"cat build.log"}"#
                )),
                .stream(AIStreamResult(
                    type: "tool_result",
                    text: nil,
                    toolName: "Bash",
                    toolInvocationID: invocationID,
                    toolResultJSON: #"{"stdout":"build finished without errors"}"#
                )),
                .stream(AIStreamResult(type: "usage", text: nil, contextUsedTokens: 1234))
            ])

            let toolRow = try XCTUnwrap(fixture.session.items.last { $0.toolInvocationID == invocationID })
            XCTAssertEqual(toolRow.kind, .toolResult)
            XCTAssertGreaterThan(toolRow.sequenceIndex, hostAnswer.sequenceIndex)
            XCTAssertEqual(fixture.session.providerTokenUsageByTurn.count, usageRowsBefore + 1)
            let usage = try XCTUnwrap(fixture.session.providerTokenUsageByTurn.last)
            XCTAssertEqual(usage.estimatedUserInputTokens, 0)
            XCTAssertGreaterThan(usage.estimatedToolInputTokens, 0)
            XCTAssertGreaterThan(usage.estimatedToolOutputTokens, 0)
            XCTAssertEqual(usage.contextUsedTokens, 1234)
            XCTAssertEqual(fixture.session.pendingNonCodexUserInputTokenQueue.map(\.submissionID), [queuedSubmissionID])
        }

        // MARK: - Sends and steering

        /// A turn Claude Code started while a host input was being written reaches the attempt
        /// before that input's registration, so it precedes the input: its failure isn't the run's
        /// outcome, and the input's final-only reply doesn't replace the turn's output.
        func testProviderTurnStartedDuringAHostSendPrecedesThatInput() async throws {
            let fixture = makeFixture()
            try await fixture.runHostTurn("first message", answer: "first answer")
            let wakeUp = UUID()
            fixture.claude.eventsDuringNextSend = [.providerTurnStarted(turnID: wakeUp), Self.content("wake-up output")]
            let hostTurn = try await fixture.sendHostTurn("second message")
            let runtime = try fixture.runtime()

            try await fixture.awaitNextPublication {
                await runtime.emit(.turnsCompleted(turnIDs: [wakeUp], status: .failed))
                await fixture.answer(hostTurn, with: "second answer", on: runtime)
            }

            XCTAssertEqual(fixture.assistantTexts, ["first answer", "wake-up output", "second answer"])
        }

        /// A message sent while a provider turn waits for adoption, before the adoption takes
        /// admission, starts a run that takes the turn as its predecessor: no separate attempt is
        /// adopted, and the turn's completion doesn't end the run.
        func testMessageSentBeforeTheAdoptionTakesAdmissionTakesTheProviderTurn() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            let first = try await fixture.sendHostTurn("first message")
            let publicationHold = try await fixture.answerHoldingPublication(first, with: "first answer", publications: publications)
            let wakeUp = try await fixture.startProviderTurn(events: [Self.content("wake-up output")])

            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "second message", tabID: fixture.tabID), .submitted)
            let ticket = try XCTUnwrap(fixture.session.unresolvedStartupTicket)
            fixture.cleanup.tickets.append(ticket)
            publicationHold.release()
            try await startupTestJoin(ticket.task)
            try await startupTestEventually { fixture.claude.sentMessages.count == 2 }
            try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
            let second = try XCTUnwrap(fixture.claude.sentTurnIDs.last)
            let runtime = try fixture.runtime()

            try await fixture.awaitNextPublication {
                await runtime.emit(.turnsCompleted(turnIDs: [wakeUp], status: .completed))
                await fixture.answer(second, with: "second answer", on: runtime)
            }

            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed, .completed])
            XCTAssertEqual(fixture.assistantTexts, ["first answer", "wake-up output", "second answer"])
        }

        /// Once the adoption holds its startup ticket, a message gets the startup refusal instead
        /// of starting a run beside it, and the adoption goes on.
        func testMessageSentWhileTheAdoptionHoldsItsTicketIsRefused() async throws {
            let fixture = makeFixture()
            try await fixture.runHostTurn("first message", answer: "first answer")
            let adoptionHold = fixture.holdAdoptionAfterEpochPreparation()
            let wakeUp = try await fixture.startProviderTurn()
            try await startupTestEventually { adoptionHold.isWaiting }
            let userRows = fixture.userRowIDs

            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "second message", tabID: fixture.tabID),
                .blocked(message: AgentModeViewModel.manualSubmissionDuringStartupMessage)
            )
            XCTAssertEqual(fixture.userRowIDs, userRows)

            adoptionHold.release()
            let runtime = try fixture.runtime()
            try await fixture.awaitNextPublication {
                await runtime.emit(.turnsCompleted(turnIDs: [wakeUp], status: .completed))
            }
            XCTAssertEqual(fixture.claude.sentMessages.count, 1)
        }

        /// A steer into a provider turn whose approval arrived before the interrupt cancels that
        /// approval first: Claude Code gets a cancel decision before the interrupt, and the session
        /// stops showing the request.
        func testSteerCancelsAPendingApprovalBeforeItInterrupts() async throws {
            let fixture = makeFixture()
            try await fixture.runHostTurn("first message", answer: "first answer")
            let runtime = try fixture.runtime()
            await runtime.emit(.providerTurnStarted(turnID: UUID()))
            try await startupTestEventually { fixture.session.runState == .running }
            let turnInFlightHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(turnInFlightHold)
            fixture.claude.turnInFlightHold = turnInFlightHold
            fixture.claude.reportsTurnInFlight = true

            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "steer", tabID: fixture.tabID), .submitted)
            try await startupTestEventually { turnInFlightHold.isWaiting }
            await runtime.emit(.approvalRequest(startupTestClaudeApprovalRequest(id: "wake-up-permission")))
            try await startupTestEventually { fixture.session.runState == .waitingForApproval }
            turnInFlightHold.release()

            try await startupTestEventually { fixture.claude.sentMessages.count == 2 }
            XCTAssertEqual(fixture.claude.controls, [
                .permissionAnswered(requestID: "wake-up-permission", decision: .cancel),
                .interrupt
            ])
            XCTAssertNil(fixture.session.pendingApproval)
            XCTAssertEqual(fixture.session.runState, .running)
        }

        /// A steer whose write failed after it was attempted ends the attempt as failed and stops
        /// the process. Claude Code may have the steer, so the provider turn it protected can't
        /// settle the attempt as completed.
        func testSteerWhoseWriteMayHaveReachedClaudeFailsTheAttempt() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            try await fixture.runHostTurn("first message", answer: "first answer")
            let runtime = try fixture.runtime()
            let wakeUp = UUID()
            await runtime.emit(.providerTurnStarted(turnID: wakeUp))
            try await startupTestEventually { fixture.session.claudeExpectedTurnIDs.contains(wakeUp) }
            let sendHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(sendHold)
            fixture.claude.sendHold = sendHold
            fixture.claude.failingSends = [.inputWriteFailed("broken pipe")]

            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "steer", tabID: fixture.tabID), .submitted)
            try await startupTestEventually { sendHold.isWaiting }
            await runtime.emit(.turnsCompleted(turnIDs: [wakeUp], status: .completed))
            sendHold.release()

            try await startupTestEventually(seconds: 15) {
                publications.revisions.count == 2 && !fixture.session.terminalCommitInProgress
            }
            XCTAssertEqual(publications.revisions.last?.terminalState, .failed)
            try await startupTestEventually { fixture.claude.shutdownObservations.count == 1 }
            XCTAssertNil(fixture.session.claudeController)
        }

        /// A follow-up queued behind a host run starts once that run's result publishes, and takes
        /// a provider turn that started meanwhile as its predecessor. The follow-up is sent once
        /// and spends its estimate once, and no separate attempt is adopted.
        func testQueuedFollowUpOwnsAProviderTurnThatStartsAtItsBoundary() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            let first = try await fixture.sendHostTurn("first message")
            let followUpSubmission = UUID()
            fixture.session.pendingNonCodexUserInputTokenQueue.append(.init(submissionID: followUpSubmission, tokens: 7))
            fixture.session.pendingInstructions = [AgentQueuedInstruction(
                text: "follow-up message",
                submissionID: followUpSubmission,
                constituentSubmissionIDs: [followUpSubmission],
                restorationDraftText: "follow-up message"
            )]
            let runtime = try fixture.runtime()
            let wakeUp = UUID()
            await fixture.answer(first, with: "first answer", on: runtime)
            await runtime.emit(.providerTurnStarted(turnID: wakeUp))
            await runtime.emit(Self.content("wake-up output"))

            try await startupTestEventually(seconds: 15) { fixture.claude.sentMessages.count == 2 }
            try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
            let followUp = try XCTUnwrap(fixture.claude.sentTurnIDs.last)
            try await fixture.awaitNextPublication {
                await runtime.emit(.turnsCompleted(turnIDs: [wakeUp], status: .completed))
                await fixture.answer(followUp, with: "follow-up answer", on: runtime)
            }

            XCTAssertEqual(fixture.claude.sentMessages.filter { $0.contains("follow-up message") }.count, 1)
            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed, .completed])
            XCTAssertEqual(fixture.session.pendingInstructions.count, 0)
            XCTAssertFalse(fixture.session.pendingNonCodexUserInputTokenQueue.contains { $0.submissionID == followUpSubmission })
            XCTAssertEqual(fixture.assistantTexts, ["first answer", "wake-up output", "follow-up answer"])
        }

        /// A provider turn left to a start that held admission and never took it is offered for
        /// adoption again once admission is free.
        func testProviderTurnLeftToAStartThatNeverTookItIsAdoptedOnceAdmissionFrees() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            try await fixture.runHostTurn("first message", answer: "first answer")
            let otherStart = try XCTUnwrap(fixture.session.installStartupTicketIfAbsent())
            let wakeUp = try await fixture.startProviderTurn(events: [Self.content("wake-up output")])
            try await startupTestEventually { !fixture.coordinator.test_providerAdoptionInFlight(for: fixture.session) }
            XCTAssertNil(fixture.session.activeRunOwnership)

            let runtime = try fixture.runtime()
            try await fixture.awaitNextPublication {
                otherStart.resolve(.cancelled)
                await runtime.emit(.turnsCompleted(turnIDs: [wakeUp], status: .completed))
            }

            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed, .completed])
            XCTAssertEqual(fixture.assistantTexts, ["first answer", "wake-up output"])
        }

        // MARK: - Stop and failures

        /// Stop while a provider turn waits for adoption, before the adoption takes admission,
        /// stops the provider process without starting a run: the previous result stays the last
        /// publication, and queued work stays queued.
        func testStopBeforeTheAdoptionTakesAdmissionStopsTheProcessWithoutARun() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            let first = try await fixture.sendHostTurn("first message")
            let publicationHold = try await fixture.answerHoldingPublication(first, with: "first answer", publications: publications)
            _ = try await fixture.startProviderTurn()
            fixture.session.pendingInstructions = [AgentQueuedInstruction(
                text: "queued message",
                submissionID: nil,
                constituentSubmissionIDs: [],
                restorationDraftText: "queued message"
            )]

            let stop = Task { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.cleanup.join(stop)
            try await startupTestEventually { fixture.claude.shutdownObservations.count == 1 }
            publicationHold.release()
            try await startupTestJoin(stop)

            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed])
            XCTAssertFalse(fixture.session.runState.isActive)
            XCTAssertNil(fixture.session.activeRunOwnership)
            XCTAssertNil(fixture.session.claudeController)
            XCTAssertEqual(fixture.session.pendingInstructions.map(\.text), ["queued message"])
        }

        /// Stop while the adoption holds its startup ticket settles that start as cancelled: one
        /// publication under the start's own attempt, and the provider process stops.
        func testStopWhileTheAdoptionHoldsItsTicketPublishesOneCancelledStart() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            try await fixture.runHostTurn("first message", answer: "first answer")
            let adoptionHold = fixture.holdAdoptionAfterEpochPreparation()
            _ = try await fixture.startProviderTurn()
            try await startupTestEventually { adoptionHold.isWaiting }
            let adoption = try XCTUnwrap(fixture.session.unresolvedStartupTicket)

            await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
            adoptionHold.release()

            XCTAssertEqual(adoption.phase, .cancelled)
            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed, .cancelled])
            XCTAssertEqual(publications.revisions.last?.ownership, adoption.ownership)
            XCTAssertNil(fixture.session.claudeController)
            try await startupTestEventually { fixture.claude.shutdownObservations.count == 1 }
            XCTAssertEqual(fixture.claude.sentMessages.count, 1)
        }

        /// A Stop that waits for teardown also waits for a provider process an earlier Stop
        /// withdrew and that is still shutting down, and settles no run of its own.
        func testTeardownStopWaitsForAProcessAnEarlierStopWithdrew() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            let first = try await fixture.sendHostTurn("first message")
            let publicationHold = try await fixture.answerHoldingPublication(first, with: "first answer", publications: publications)
            _ = try await fixture.startProviderTurn()
            let shutdownHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(shutdownHold)
            fixture.claude.shutdownHold = shutdownHold
            let firstStop = Task { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.cleanup.join(firstStop)
            try await startupTestEventually { fixture.claude.shutdownsStarted == 1 }
            publicationHold.release()
            try await startupTestJoin(firstStop)

            let secondStop = startupTestRunTracked({
                await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID, completion: .terminalTeardownCompleted)
            }, in: fixture.cleanup.trackedOperations)
            let returnedDuringShutdown = await startupTestWaitBounded(seconds: 0.3) { secondStop.value }
            XCTAssertFalse(returnedDuringShutdown, "the teardown Stop returned while the withdrawn process was still shutting down")
            shutdownHold.release()
            try await startupTestEventually { secondStop.value }

            XCTAssertEqual(fixture.claude.shutdownObservations.count, 1)
            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed])
        }

        /// Stop during a provider turn that waits for approval denies that permission before it
        /// interrupts and stops the process, and the stopped process's later events change nothing.
        func testStopDuringAProviderTurnApprovalDeniesItAndStopsTheProcess() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            try await fixture.runHostTurn("first message", answer: "first answer")
            let runtime = try fixture.runtime()
            await runtime.emit(.providerTurnStarted(turnID: UUID()))
            await runtime.emit(.approvalRequest(startupTestClaudeApprovalRequest(id: "wake-up-permission")))
            try await startupTestEventually { fixture.session.runState == .waitingForApproval }
            XCTAssertEqual(fixture.session.pendingApproval?.requestID, .claudeControl("wake-up-permission"))

            await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID, completion: .terminalTeardownCompleted)

            XCTAssertEqual(fixture.claude.controls, [
                .permissionAnswered(requestID: "wake-up-permission", decision: .cancel),
                .interrupt
            ])
            XCTAssertEqual(fixture.claude.shutdownObservations.count, 1)
            XCTAssertEqual(publications.revisions.map(\.terminalState), [.completed, .cancelled])
            XCTAssertNil(fixture.session.claudeController)
            try await fixture.expectNoChange(after: runtime, emits: Self.content("late output"))
        }

        /// When the process ends while an MCP adoption holds an epoch it prepared, that epoch gets
        /// one failed result carrying the process failure, shown once, and the process stops.
        func testProcessEndDuringAPreparedAdoptionPublishesOneFailureForItsEpoch() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            try await fixture.activateMCPControl()
            try await fixture.runHostTurn("first message", answer: "first answer")
            let adoptionHold = fixture.holdAdoptionAfterEpochPreparation()
            _ = try await fixture.startProviderTurn()
            try await startupTestEventually { adoptionHold.isWaiting }
            XCTAssertNotNil(fixture.session.mcpControlContext?.preparedEpoch)

            try await fixture.runtime().finishEventStream()
            try await startupTestEventually { fixture.coordinator.test_providerRuntimeFailure(for: fixture.session) != nil }
            adoptionHold.release()
            try await startupTestEventually(seconds: 15) {
                publications.revisions.count == 2 && !fixture.session.terminalCommitInProgress
            }

            let failure = try XCTUnwrap(publications.revisions.last)
            XCTAssertEqual(failure.terminalState, .failed)
            XCTAssertEqual(failure.ownership.turnEpoch?.transitionKind, .relatedFollowUp)
            XCTAssertEqual(fixture.errorTexts, [ClaudeAgentModeCoordinator.unexpectedStreamEndMessage])
            XCTAssertNil(fixture.session.claudeController)
        }

        /// Rebinding the tab to another session stops the Claude process of the binding it
        /// replaces, with the provider turn it was adopting, and that process's later events change
        /// nothing.
        func testRebindStopsTheProcessAndTheProviderTurnItWasAdopting() async throws {
            let fixture = makeFixture()
            try await fixture.runHostTurn("first message", answer: "first answer")
            XCTAssertNotNil(fixture.session.activeAgentSessionID)
            let adoptionHold = fixture.holdAdoptionAfterEpochPreparation()
            _ = try await fixture.startProviderTurn()
            try await startupTestEventually { adoptionHold.isWaiting }
            let runtime = try fixture.runtime()

            XCTAssertNotNil(fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session))
            adoptionHold.release()

            try await startupTestEventually { fixture.claude.shutdownObservations.count == 1 }
            XCTAssertNil(fixture.session.claudeController)
            XCTAssertNil(fixture.session.activeRunOwnership)
            try await fixture.expectNoChange(after: runtime, emits: Self.content("late output"))
        }

        /// A binding transition that ends without replacing the binding keeps the listener. A
        /// provider turn that started during the transition waits it out as provider work, so the
        /// idle gate keeps the process until the turn is routed after the transition, and then it
        /// becomes a run.
        func testProviderTurnDuringATransitionThatKeepsTheBindingBecomesARunAfterIt() async throws {
            let fixture = makeFixture()
            try await fixture.runHostTurn("first message", answer: "first answer")
            let transition = fixture.session.beginPersistentBindingTransition()
            let runtime = try fixture.runtime()
            let wakeUp = UUID()
            await runtime.emit(.providerTurnStarted(turnID: wakeUp))
            await runtime.emit(Self.content("wake-up output"))
            try await startupTestEventually { fixture.coordinator.hasPendingProviderWork(for: fixture.session) }
            let routedDuringTransition = await startupTestWaitBounded(seconds: 0.2) {
                fixture.session.mcpFollowUpRunPending || fixture.session.activeRunOwnership != nil
            }
            XCTAssertFalse(routedDuringTransition, "provider work was routed during the binding transition")

            // No further event arrives, so only the transition's end can release the held turn. The
            // turn counts as provider work until it is routed.
            fixture.session.finishPersistentBindingTransition(generation: transition)
            XCTAssertTrue(fixture.coordinator.hasPendingProviderWork(for: fixture.session))
            try await startupTestEventually { fixture.session.runState == .running }
            try await fixture.awaitNextPublication {
                await runtime.emit(.turnsCompleted(turnIDs: [wakeUp], status: .completed))
            }
            XCTAssertEqual(fixture.assistantTexts, ["first answer", "wake-up output"])
        }

        /// A process failure that waits for the previous run's publication and finds a binding
        /// transition when it ends is reported once the transition ends without replacing the
        /// binding: the session shows it and the process stops.
        func testIdleFailureThatFindsATransitionIsReportedWhenTheTransitionEnds() async throws {
            let fixture = makeFixture()
            let publications = StartupTestPublicationRecorder()
            publications.install(on: fixture.viewModel)
            let first = try await fixture.sendHostTurn("first message")
            let publicationHold = try await fixture.answerHoldingPublication(first, with: "first answer", publications: publications)
            let runtime = try fixture.runtime()
            await runtime.emit(.error("process failed"))
            try await startupTestEventually { fixture.coordinator.test_providerRuntimeFailure(for: fixture.session) != nil }

            let transition = fixture.session.beginPersistentBindingTransition()
            publicationHold.release()
            let reportedDuringTransition = await startupTestWaitBounded(seconds: 0.3) { !fixture.errorTexts.isEmpty }
            XCTAssertFalse(reportedDuringTransition, "the failure was reported during the binding transition")

            fixture.session.finishPersistentBindingTransition(generation: transition)
            try await startupTestEventually { fixture.session.claudeController == nil }
            XCTAssertEqual(fixture.errorTexts, ["process failed"])
        }

        // MARK: - Fixture

        private static func content(_ text: String) -> NativeAgentRuntimeEvent {
            .stream(AIStreamResult(type: "content", text: text))
        }

        /// A Claude session in a view model whose Claude processes are recording fakes.
        @MainActor
        private final class Fixture: StartupTestSessionFixture {
            let claude: StartupTestClaudeRecorder

            init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController,
                claude: StartupTestClaudeRecorder
            ) {
                self.claude = claude
                super.init(viewModel: viewModel, session: session, readiness: readiness, controller: controller)
            }

            var coordinator: ClaudeAgentModeCoordinator {
                viewModel.claudeCoordinator
            }

            var userRowIDs: [UUID] {
                session.items.filter { $0.kind == .user }.map(\.id)
            }

            var assistantTexts: [String] {
                session.items.filter { $0.kind == .assistant }.map(\.text)
            }

            /// The Claude process the session runs now.
            func runtime() throws -> StartupTestClaudeRuntime {
                try XCTUnwrap(claude.runtimes.last)
            }

            /// Sends `text` and waits until the process has it and its run is routed. Returns the
            /// input's turn ID.
            func sendHostTurn(_ text: String) async throws -> UUID {
                let sentBefore = claude.sentMessages.count
                let ticket = try submit(text)
                try await startupTestJoin(ticket.task)
                try await startupTestEventually { self.claude.sentMessages.count == sentBefore + 1 }
                try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(session.runID))
                return try XCTUnwrap(claude.sentTurnIDs.last)
            }

            /// Answers `turnID` with `text` as Claude's final reply.
            func answer(_ turnID: UUID, with text: String, on runtime: StartupTestClaudeRuntime) async {
                await runtime.emit(.stream(AIStreamResult(type: "final_content", text: text)))
                await runtime.emit(.turnsCompleted(turnIDs: [turnID], status: .completed))
            }

            /// Sends `text`, answers it with `answer` as Claude's final reply, and waits until its
            /// terminal has published.
            func runHostTurn(_ text: String, answer: String) async throws {
                let turnID = try await sendHostTurn(text)
                let runtime = try runtime()
                try await awaitNextPublication {
                    await self.answer(turnID, with: answer, on: runtime)
                }
            }

            /// Answers `turnID` and holds that answer's publication until the returned gate opens.
            func answerHoldingPublication(
                _ turnID: UUID,
                with text: String,
                publications: StartupTestPublicationRecorder
            ) async throws -> StartupTestHeldGate {
                let hold = StartupTestHeldGate()
                cleanup.heldGates.append(hold)
                publications.hold = hold
                let publishedBefore = publications.revisions.count
                try await answer(turnID, with: text, on: runtime())
                try await startupTestEventually { publications.revisions.count == publishedBefore + 1 && hold.isWaiting }
                return hold
            }

            /// Emits a turn Claude Code starts by itself, then `events`, and waits until the session
            /// counts it as provider work. Returns the turn's ID.
            func startProviderTurn(events: [NativeAgentRuntimeEvent] = []) async throws -> UUID {
                let runtime = try runtime()
                let turnID = UUID()
                await runtime.emit(.providerTurnStarted(turnID: turnID))
                for event in events {
                    await runtime.emit(event)
                }
                try await startupTestEventually { self.coordinator.hasPendingProviderWork(for: self.session) }
                return turnID
            }

            /// Holds every adoption, once it has taken its startup ticket and prepared its epoch,
            /// until the returned gate opens.
            func holdAdoptionAfterEpochPreparation() -> StartupTestHeldGate {
                let hold = StartupTestHeldGate()
                cleanup.heldGates.append(hold)
                viewModel.test_afterClaudeProviderEpochPreparation = { await hold.wait() }
                return hold
            }

            /// Emits `event` on a process the session no longer runs and checks that the transcript
            /// and run state don't change.
            func expectNoChange(
                after runtime: StartupTestClaudeRuntime,
                emits event: NativeAgentRuntimeEvent,
                file: StaticString = #filePath,
                line: UInt = #line
            ) async throws {
                let items = session.items
                let runState = session.runState
                await runtime.emit(event)
                let changed = await startupTestWaitBounded(seconds: 0.3) {
                    self.session.items != items || self.session.runState != runState
                }
                XCTAssertFalse(changed, "a stopped process's event changed the session", file: file, line: line)
            }

            /// Emits a turn Claude Code starts by itself, then `events` and its completion, and
            /// waits until the attempt that adopted it has published.
            func runProviderTurn(events: [NativeAgentRuntimeEvent]) async throws {
                let runtime = try XCTUnwrap(claude.runtimes.last)
                let turnID = UUID()
                try await awaitNextPublication {
                    await runtime.emit(.providerTurnStarted(turnID: turnID))
                    for event in events {
                        await runtime.emit(event)
                    }
                    await runtime.emit(.turnsCompleted(turnIDs: [turnID], status: .completed))
                }
            }

            /// Runs `emit` and waits until the next terminal has published, which must be completed.
            func awaitNextPublication(after emit: () async -> Void) async throws {
                let previousCommitID = session.lastTerminalCommitRevision?.commitID
                await emit()
                try await startupTestEventually(seconds: 15) {
                    self.session.lastTerminalCommitRevision?.commitID != previousCommitID
                        && self.session.lastTerminalPublicationResult != nil
                        && !self.session.terminalCommitInProgress
                        && !self.session.runState.isActive
                }
                XCTAssertEqual(session.runState, .completed, "errors: \(errorTexts)")
            }
        }

        private func makeFixture() -> Fixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: false)
            let claude = StartupTestClaudeRecorder()
            let viewModel = startupTestMakeViewModel(
                storageRoot: storageRoot,
                readiness: readiness,
                controller: controller,
                claude: claude
            )
            let session = startupTestCodexSession()
            session.selectedAgent = .claudeCode
            let fixture = Fixture(
                viewModel: viewModel,
                session: session,
                readiness: readiness,
                controller: controller,
                claude: claude
            )
            addTeardownBlock { @MainActor in
                await fixture.tearDown()
            }
            return fixture
        }
    }
#endif
