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
            try await startupTestJoin(ticket.task)

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
            try await startupTestJoin(ticket.task)

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
            try await startupTestJoin(firstTicket.task)
            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            XCTAssertEqual(fixture.session.runState, .cancelled)
            XCTAssertNotNil(fixture.session.lastTerminalCommitRevision)

            let secondTicket = try fixture.submit("second")
            // A new submission does not inherit the previous run's terminal state.
            XCTAssertEqual(fixture.session.runState, .idle)
            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            try await startupTestJoin(secondTicket.task)

            XCTAssertEqual(secondTicket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["first"])
            XCTAssertEqual(fixture.session.runState, .cancelled)
        }

        func testCancelDuringReadinessStopsBeforeNativeSetup() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let ticket = try fixture.submit("cancelled during readiness")
            try await eventually { fixture.readiness.isWaiting(1) }

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.readiness.release(1, ready: true)
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startOrResumeCount, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.session.runState, .cancelled)
        }

        func testCancelDuringControllerStartupAndRoutingDispatchesNothing() async throws {
            let fixture = makeFixture(gateControllerStartup: true)
            let ticket = try fixture.submit("cancelled during routing")
            try await eventually { fixture.controller.isStartupWaiting }

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.controller.releaseStartup()
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.session.runState, .cancelled)
        }

        func testLateFailureOfCancelledStartCannotTouchReplacementAttempt() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1, 2])
            let staleTicket = try fixture.submit("stale start")
            try await eventually { fixture.readiness.isWaiting(1) }
            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }

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
            try await startupTestJoin(staleTicket.task)

            XCTAssertNotNil(fixture.session.agentTask, "the stale runner cleared the replacement's task")
            XCTAssertTrue(fixture.session.mcpFollowUpRunPending, "the stale start cleared the replacement's pending flag")
            XCTAssertEqual(fixture.session.activeRunOwnership, replacementOwnership)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])

            fixture.readiness.release(2, ready: true)
            try await startupTestJoin(replacement)
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

            XCTAssertEqual(fixture.submitAsMCPDispatch("follower"), .submitted)
            let followerGateTicket = try XCTUnwrap(head.followerDispatchGateTickets.first)
            try await eventually { fixture.session.codexDispatchSerialGate.test_hasWaiter(for: followerGateTicket) }

            XCTAssertTrue(fixture.session.startupTicket === head)
            XCTAssertEqual(head.phase, .dispatching)
            XCTAssertEqual(head.followerDispatchGateTickets.count, 1)
            XCTAssertEqual(fixture.readiness.callCount, 1, "the follower ran ahead of the head start")

            fixture.readiness.release(1, ready: true)
            try await startupTestJoin(head.task)
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
            XCTAssertEqual(fixture.submitAsMCPDispatch("follower"), .submitted)
            let followers = head.followerTasks
            XCTAssertEqual(followers.count, 1)
            let followerGateTicket = try XCTUnwrap(head.followerDispatchGateTickets.first)
            try await eventually { fixture.session.codexDispatchSerialGate.test_hasWaiter(for: followerGateTicket) }

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.readiness.release(1, ready: true)
            try await startupTestJoin(head.task)
            try await settle(followers)

            XCTAssertEqual(head.phase, .cancelled)
            XCTAssertEqual(fixture.readiness.callCount, 1, "the cancelled follower reached the runner")
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "follower" })

            let later = try fixture.submit("later")
            try await eventually { fixture.controller.startUserTurnTexts == ["later"] }
            try await startupTestJoin(later.task)
            XCTAssertEqual(later.phase, .accepted)
        }

        func testManualSubmissionDuringPendingStartIsRefusedBeforeComposerOrTranscriptChange() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1])
            let head = try fixture.submit("head")
            try await eventually { fixture.readiness.isWaiting(1) }
            let attachment = AgentTaggedFileAttachment(relativePath: "kept.swift", displayName: "kept.swift")
            fixture.session.pendingTaggedFileAttachments = [attachment]
            fixture.session.selectedWorkflow = AgentWorkflow.build.definition
            let itemIDs = fixture.session.items.map(\.id)

            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "second manual message", tabID: fixture.tabID),
                .blocked(message: AgentModeViewModel.manualSubmissionDuringStartupMessage)
            )

            XCTAssertEqual(fixture.session.items.map(\.id), itemIDs)
            XCTAssertEqual(fixture.session.pendingTaggedFileAttachments, [attachment])
            XCTAssertEqual(fixture.session.selectedWorkflow?.id, AgentWorkflow.build.definition.id)
            XCTAssertTrue(fixture.session.startupTicket === head)
            XCTAssertEqual(head.followerTasks.count, 0)
            XCTAssertEqual(head.followerDispatchGateTickets, [])

            fixture.readiness.release(1, ready: true)
            try await startupTestJoin(head.task)
            XCTAssertEqual(head.phase, .accepted)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["head"])
        }

        func testQueuedFollowUpOfARunWhosePublicationWasRejectedReturnsToTheComposer() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            // A follow-up queues while the run waits on an approval.
            let runtime = try await startClaudeRunWaitingOnApproval(fixture: fixture, claude: claude)
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "queued follow-up", tabID: fixture.tabID), .submitted)
            let followUpItemID = try XCTUnwrap(fixture.session.items.last { $0.kind == .user }?.id)
            XCTAssertEqual(fixture.session.pendingInstructions.map(\.submissionID), [followUpItemID])
            XCTAssertEqual(fixture.session.pendingNonCodexUserInputTokenQueue.map(\.submissionID), [followUpItemID])

            // Control is re-activated mid-run, so the run's terminal publication is refused.
            _ = try await fixture.viewModel.mcpActivateControlContext(
                forTabID: fixture.tabID,
                sessionID: fixture.sessionID,
                originatingConnectionID: UUID(),
                markSessionAsMCPOriginated: true
            )
            await runtime.emit(.approvalCancelled(requestID: "approval"))
            try await eventually { fixture.session.runState == .running }
            let headTurnID = try XCTUnwrap(claude.sentTurnIDs.first)
            await runtime.emit(.turnCompleted(turnID: headTurnID, status: .completed))
            try await eventually(seconds: 15) { fixture.session.runState == .completed }
            // The replaced activation's envelope is dropped before publication, so the refusal
            // arrives as a rejected publication.
            guard case .rejected? = fixture.session.runLifecycle.lastTerminalPublicationResult else {
                return XCTFail("unexpected publication \(String(describing: fixture.session.runLifecycle.lastTerminalPublicationResult))")
            }
            try await eventually { fixture.session.pendingInstructions.isEmpty }

            XCTAssertFalse(fixture.session.mcpFollowUpRunPending, "the refused follow-up left the pending-start flag up")
            XCTAssertNil(fixture.session.mcpPendingStartOwner)
            XCTAssertEqual(fixture.session.pendingNonCodexUserInputTokenQueue, [])
            XCTAssertTrue(
                fixture.viewModel.retrieveDraftText(for: fixture.tabID).contains("queued follow-up"),
                fixture.viewModel.retrieveDraftText(for: fixture.tabID)
            )
            XCTAssertFalse(
                fixture.session.items.contains { $0.id == followUpItemID },
                "the returned follow-up still looks sent"
            )
            XCTAssertEqual(claude.sentMessages.count, 1)
            XCTAssertFalse(
                fixture.viewModel.isStartupPendingBeforeProviderOwnership(fixture.session, exemptingActivationID: nil),
                "a steer would be refused as startup_pending"
            )
            XCTAssertNotEqual(fixture.viewModel.mcpSnapshot(sessionID: fixture.sessionID)?.status, .running)
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "next message", tabID: fixture.tabID),
                .submitted,
                "a manual send was refused"
            )
        }

        func testQueuedFollowUpOfARunWhosePublicationWentStaleReturnsToTheComposer() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            let runtime = try await startClaudeRunWaitingOnApproval(fixture: fixture, claude: claude)
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "queued follow-up", tabID: fixture.tabID), .submitted)
            let followUpItemID = try XCTUnwrap(fixture.session.items.last { $0.kind == .user }?.id)

            _ = try await finishClaudeRunWithStalePublication(fixture: fixture, claude: claude, runtime: runtime)

            XCTAssertTrue(
                fixture.viewModel.retrieveDraftText(for: fixture.tabID).contains("queued follow-up"),
                "the stale publication dropped the queued follow-up"
            )
            XCTAssertFalse(fixture.session.items.contains { $0.id == followUpItemID })
            XCTAssertEqual(fixture.session.pendingNonCodexUserInputTokenQueue, [])
            XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
            XCTAssertNil(fixture.session.unresolvedStartupTicket)
            XCTAssertEqual(claude.sentMessages.count, 1)
        }

        func testQueuedFollowUpReturnedToTheComposerBringsBackItsAttachments() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            let session = fixture.session
            let runtime = try await startClaudeRunWaitingOnApproval(fixture: fixture, claude: claude)

            // The follow-up queues with an image and a tagged file, which leave the composer with it.
            let queuedImage = AgentImageAttachment(source: .url("https://example.invalid/queued.png"))
            let queuedFile = AgentTaggedFileAttachment(relativePath: "Sources/Queued.swift", displayName: "Queued.swift")
            session.pendingImageAttachments = [queuedImage]
            session.pendingTaggedFileAttachments = [queuedFile]
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "queued follow-up", tabID: fixture.tabID), .submitted)
            let followUpItem = try XCTUnwrap(session.items.last { $0.kind == .user })
            XCTAssertEqual(followUpItem.attachments, [queuedImage])
            XCTAssertEqual(followUpItem.taggedFileAttachments, [queuedFile])
            XCTAssertEqual(session.pendingInstructions.map(\.submissionID), [followUpItem.id])
            XCTAssertEqual(session.pendingImageAttachments, [])
            XCTAssertEqual(session.pendingTaggedFileAttachments, [])

            // The user stages more attachments while it waits.
            let stagedImage = AgentImageAttachment(source: .url("https://example.invalid/staged.png"))
            let stagedFile = AgentTaggedFileAttachment(relativePath: "Sources/Staged.swift", displayName: "Staged.swift")
            session.pendingImageAttachments = [stagedImage]
            session.pendingTaggedFileAttachments = [stagedFile]

            let followUpAdmission = try await finishClaudeRunWithStalePublication(
                fixture: fixture,
                claude: claude,
                runtime: runtime
            )

            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "queued follow-up")
            XCTAssertEqual(session.pendingImageAttachments, [queuedImage, stagedImage])
            XCTAssertEqual(session.pendingTaggedFileAttachments, [queuedFile, stagedFile])
            XCTAssertFalse(session.items.contains { $0.id == followUpItem.id }, "the returned follow-up still looks sent")
            let admission = try XCTUnwrap(followUpAdmission, "the follow-up was not admitted before its run's result published")
            XCTAssertEqual(admission.phase, .rejected)
            XCTAssertNil(session.unresolvedStartupTicket)
            XCTAssertEqual(claude.sentMessages.count, 1)
        }

        func testQueuedFollowUpReturnedToTheComposerRestoresWhatTheUserTypedNotItsWorkflowWrapping() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            let session = fixture.session
            let runtime = try await startClaudeRunWaitingOnApproval(fixture: fixture, claude: claude)

            session.selectedWorkflow = AgentWorkflowDefinition(
                customID: UUID(),
                displayName: "Careful review",
                template: "Review carefully before answering.\n$ARGUMENTS\nList every risk."
            )
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "check the diff", tabID: fixture.tabID), .submitted)
            let followUpItem = try XCTUnwrap(session.items.last { $0.kind == .user })
            XCTAssertEqual(
                session.pendingInstructions.map(\.text),
                ["Review carefully before answering.\ncheck the diff\nList every risk."],
                "the queued provider text was not wrapped by the workflow"
            )

            _ = try await finishClaudeRunWithStalePublication(fixture: fixture, claude: claude, runtime: runtime)

            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "check the diff")
            XCTAssertFalse(session.items.contains { $0.id == followUpItem.id })
            XCTAssertEqual(claude.sentMessages.count, 1)
        }

        func testQueuedWorkflowFollowUpRestoredByAnExecutionLocationChangeReturnsWhatTheUserTyped() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            let session = fixture.session
            _ = try await startClaudeRunWaitingOnApproval(fixture: fixture, claude: claude)
            session.selectedWorkflow = AgentWorkflowDefinition(
                customID: UUID(),
                displayName: "Careful review",
                template: "Review carefully before answering.\n$ARGUMENTS\nList every risk."
            )
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "check the diff", tabID: fixture.tabID), .submitted)
            XCTAssertEqual(session.pendingInstructions.map(\.text), ["Review carefully before answering.\ncheck the diff\nList every risk."])

            await fixture.viewModel.test_cancelAgentRunForExecutionLocationChange(tabID: fixture.tabID)

            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "check the diff")
            XCTAssertEqual(session.pendingInstructions, [])
        }

        /// A slash-skill message's bubble drops the command, and an attachment-only message's
        /// bubble is a placeholder; neither is what the user typed.
        func testQueuedSlashSkillAndAttachmentOnlyFollowUpsReturnWhatTheUserTyped() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            let session = fixture.session
            let runtime = try await startClaudeRunWaitingOnApproval(fixture: fixture, claude: claude)

            session.selectedWorkflow = AgentWorkflowDefinition(
                customID: UUID(),
                displayName: "/careful-review",
                template: "Review carefully.\n$ARGUMENTS"
            )
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "/careful-review check the diff", tabID: fixture.tabID),
                .submitted
            )
            let slashItem = try XCTUnwrap(session.items.last { $0.kind == .user })
            XCTAssertEqual(slashItem.text, "check the diff")

            session.selectedWorkflow = nil
            let image = AgentImageAttachment(source: .url("https://example.invalid/only.png"))
            session.pendingImageAttachments = [image]
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "", tabID: fixture.tabID), .submitted)
            let attachmentOnlyItem = try XCTUnwrap(session.items.last { $0.kind == .user })
            XCTAssertNotEqual(attachmentOnlyItem.id, slashItem.id)
            XCTAssertEqual(attachmentOnlyItem.text, "Sent 1 image")
            XCTAssertEqual(session.pendingInstructions.count, 2)

            _ = try await finishClaudeRunWithStalePublication(fixture: fixture, claude: claude, runtime: runtime)

            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "/careful-review check the diff")
            XCTAssertEqual(session.pendingImageAttachments, [image])
            XCTAssertFalse(session.items.contains { $0.id == slashItem.id || $0.id == attachmentOnlyItem.id })
            XCTAssertEqual(claude.sentMessages.count, 1)
        }

        /// ACP steering messages requeued together become one follow-up, filed under the first
        /// message's submission, that stands for all of them.
        func testCoalescedACPFollowUpReturnsEveryMessageItStandsFor() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            let session = fixture.session
            let runtime = try await startClaudeRunWaitingOnApproval(fixture: fixture, claude: claude)

            // B and C were steered at the run and are sent back as the steering path leaves them:
            // an optimistic item each, carrying its tagged file.
            let fileB = AgentTaggedFileAttachment(relativePath: "Sources/B.swift", displayName: "B.swift")
            let fileC = AgentTaggedFileAttachment(relativePath: "Sources/C.swift", displayName: "C.swift")
            let steerings = [("B typed", fileB), ("C typed", fileC)].map { text, file in
                let item = AgentChatItem.user(text, taggedFileAttachments: [file], sequenceIndex: session.nextSequenceIndex)
                session.appendItem(item)
                return AgentModeViewModel.TabSession.ACPSteeringInstruction(
                    id: UUID(),
                    targetRunID: session.runID,
                    targetRunAttemptID: session.activeRunAttemptID,
                    providerText: "<wrapped>\(text)</wrapped>",
                    interruptedPromptProviderText: nil,
                    attachments: [],
                    taggedFileAttachments: [file],
                    draftText: text,
                    optimisticUserItemID: item.id,
                    createdAt: Date()
                )
            }
            let itemIDs = steerings.compactMap(\.optimisticUserItemID)
            session.pendingACPSteeringInstructions = steerings
            fixture.viewModel.test_requeueAllQueuedACPSteeringAsFollowUp(session: session)
            XCTAssertEqual(session.pendingInstructions.map(\.submissionID), [itemIDs[0]])
            XCTAssertEqual(session.pendingInstructions.map(\.constituentSubmissionIDs), [itemIDs])

            _ = try await finishClaudeRunWithStalePublication(fixture: fixture, claude: claude, runtime: runtime)

            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "B typed\nC typed")
            XCTAssertEqual(session.pendingTaggedFileAttachments, [fileB, fileC])
            XCTAssertFalse(session.items.contains { itemIDs.contains($0.id) }, "a returned message still looks sent")
            XCTAssertEqual(claude.sentMessages.count, 1)
        }

        /// Starts a Claude run under MCP control and leaves it waiting on an approval, where turns
        /// the user sends queue as follow-ups.
        private func startClaudeRunWaitingOnApproval(
            fixture: Fixture,
            claude: StartupTestClaudeRecorder
        ) async throws -> StartupTestClaudeRuntime {
            fixture.session.selectedAgent = .claudeCode
            _ = try await activateMCPControl(fixture: fixture, sessionID: fixture.sessionID)
            let head = try fixture.submit("head")
            try await startupTestJoin(head.task)
            try await eventually { claude.sentMessages.count == 1 }
            try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
            let runtime = try XCTUnwrap(claude.runtimes.last)
            await runtime.emit(.approvalRequest(Self.claudeApprovalRequest(id: "approval")))
            try await eventually(seconds: 15) { fixture.session.runState == .waitingForApproval }
            return runtime
        }

        /// Answers the approval and completes the run, whose terminal publication goes stale, then
        /// waits for its queued follow-ups to leave the queue. Returns the admission the follow-up
        /// held while the result published.
        private func finishClaudeRunWithStalePublication(
            fixture: Fixture,
            claude: StartupTestClaudeRecorder,
            runtime: StartupTestClaudeRuntime
        ) async throws -> AgentRunStartupTicket? {
            let session = fixture.session
            var followUpAdmission: AgentRunStartupTicket?
            fixture.viewModel.test_setTerminalPublicationOverride { _, _, session in
                followUpAdmission = session.unresolvedStartupTicket
                return .stale
            }
            fixture.cleanup.releases.append { fixture.viewModel.test_setTerminalPublicationOverride(nil) }
            await runtime.emit(.approvalCancelled(requestID: "approval"))
            try await eventually { session.runState == .running }
            let headTurnID = try XCTUnwrap(claude.sentTurnIDs.first)
            await runtime.emit(.turnCompleted(turnID: headTurnID, status: .completed))
            try await eventually(seconds: 15) { session.runState == .completed }
            try await eventually { session.pendingInstructions.isEmpty }
            return followUpAdmission
        }

        func testManualSubmissionIsRefusedWhileAnUnrelatedMCPDispatchIsStillInFlight() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            fixture.session.selectedAgent = .claudeCode
            _ = try await activateMCPControl(fixture: fixture, sessionID: fixture.sessionID)
            let first = try fixture.submit("first")
            try await startupTestJoin(first.task)
            try await eventually { claude.sentMessages.count == 1 && fixture.session.runState == .running }

            // Steer S has made its submission and is held in its delivery bookkeeping.
            let bookkeepingGate = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(bookkeepingGate)
            var dispatches = 0
            fixture.viewModel.test_afterMCPDispatchSubmission = {
                dispatches += 1
                if dispatches == 1 { await bookkeepingGate.wait() }
            }
            let viewModel = fixture.viewModel
            let sessionID = fixture.sessionID
            let steer = Task { @MainActor in
                _ = try? await viewModel.mcpDispatchInstruction(sessionID: sessionID, text: "steer", allowStartingRun: false)
            }
            fixture.cleanup.join(steer)
            try await eventually { bookkeepingGate.isWaiting }

            // The run ends and manual H starts while S is still in flight.
            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            XCTAssertFalse(fixture.session.runState.isActive)
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "H manual", tabID: fixture.tabID), .submitted)
            let head = try XCTUnwrap(fixture.session.unresolvedStartupTicket)
            fixture.cleanup.tickets.append(head)

            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "F manual", tabID: fixture.tabID),
                .blocked(message: AgentModeViewModel.manualSubmissionDuringStartupMessage),
                "an unrelated in-flight dispatch let a competing start through"
            )
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "F manual" })
            XCTAssertEqual(head.followerTasks, [])

            bookkeepingGate.release()
            try await startupTestJoin(head.task)
            XCTAssertEqual(head.phase, .accepted)
            try await eventually { claude.sentMessages.contains { $0.contains("H manual") } }
            XCTAssertFalse(claude.sentMessages.contains { $0.contains("F manual") })
        }

        func testHydrationDeferredSubmissionFindingAnotherStartIsRefusedToTheComposer() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(gatedHydration: true, claude: claude)
            fixture.session.selectedAgent = .claudeCode
            // Accepted while a run is active, so it takes no start of its own before hydrating.
            fixture.session.runState = .running
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "deferred message", tabID: fixture.tabID), .submitted)
            XCTAssertNil(fixture.session.unresolvedStartupTicket)
            try await eventually { fixture.hydration.isWaiting }

            // While it hydrates, the run ends and another start is admitted.
            fixture.session.runState = .completed
            let head = try XCTUnwrap(fixture.session.installStartupTicketIfAbsent())
            defer { head.resolve(.cancelled) }
            fixture.hydration.release()

            try await eventually {
                fixture.viewModel.retrieveDraftText(for: fixture.tabID).contains("deferred message")
            }
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user }, "the refused submission reached the transcript")
            XCTAssertTrue(fixture.session.unresolvedStartupTicket === head)
            XCTAssertEqual(head.followerTasks, [])
            XCTAssertEqual(fixture.startAgentRunCalls.count, 0)
            XCTAssertEqual(claude.runtimesCreated, 0)
        }

        func testExternalStartsOwnDispatchPassesItsPendingStartAndNoOtherDispatchDoes() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            fixture.session.selectedAgent = .claudeCode
            fixture.session.testInstallPersistentSessionBinding(sessionID: fixture.sessionID)
            let startOwner = UUID()
            _ = try await fixture.viewModel.mcpActivateControlContext(
                forTabID: fixture.tabID,
                sessionID: fixture.sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                pendingStartOwner: startOwner,
                markSessionAsMCPOriginated: true,
                requireInactiveRunState: true
            )
            let sessionID = fixture.sessionID
            let viewModel = fixture.viewModel
            fixture.cleanup.afterStartsSettle.append {
                await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }

            do {
                _ = try await fixture.viewModel.mcpDispatchInstruction(
                    sessionID: sessionID,
                    text: "intruder",
                    allowStartingRun: true
                )
                XCTFail("a dispatch that does not own the pending start was accepted")
            } catch {
                XCTAssertTrue("\(error)".contains("startup_pending"), "\(error)")
            }
            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
            XCTAssertEqual(fixture.session.mcpPendingStartOwner, startOwner)

            let delivery = try await fixture.viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "own start",
                allowStartingRun: true,
                pendingStartOwner: startOwner
            )
            XCTAssertEqual(delivery, .startedRun)
            let started = try XCTUnwrap(fixture.session.startupTicket)
            fixture.cleanup.tickets.append(started)
            try await startupTestJoin(started.task)
            XCTAssertEqual(started.phase, .accepted)
            try await eventually { claude.sentMessages.count == 1 }
            XCTAssertTrue(claude.sentMessages[0].contains("own start"), claude.sentMessages[0])
        }

        func testSubmissionsSteerARunWhoseRunnerOwnsTheStart() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            fixture.session.selectedAgent = .claudeCode
            let first = try fixture.submit("first")
            try await startupTestJoin(first.task)
            try await eventually { claude.sentMessages.count == 1 && fixture.session.runState == .running }
            let attemptID = try XCTUnwrap(fixture.session.activeRunAttemptID)

            // Between the runner beginning its attempt and the start resolving, nothing suspends, so
            // that state is set up directly: a start in dispatch over the run its runner now owns.
            let dispatching = try XCTUnwrap(fixture.session.installStartupTicketIfAbsent())
            dispatching.markDispatching()
            defer { dispatching.resolve(.accepted) }

            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "manual steer", tabID: fixture.tabID), .submitted)
            XCTAssertEqual(fixture.submitAsMCPDispatch("dispatched steer"), .submitted)
            XCTAssertTrue(fixture.session.items.contains { $0.kind == .user && $0.text == "manual steer" })
            XCTAssertTrue(fixture.session.items.contains { $0.kind == .user && $0.text == "dispatched steer" })
            XCTAssertTrue(fixture.session.startupTicket === dispatching, "a steering submission started a run of its own")
            XCTAssertEqual(fixture.session.activeRunAttemptID, attemptID)
            XCTAssertEqual(claude.runtimesCreated, 1)
        }

        func testQueuedFollowUpIsAdmittedBeforeItsRunsResultPublishes() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            fixture.session.selectedAgent = .claudeCode
            let registration = try await activateMCPControl(fixture: fixture, sessionID: fixture.sessionID)
            let head = try fixture.submit("head")
            try await startupTestJoin(head.task)
            try await eventually { claude.sentMessages.count == 1 }
            let headEpoch = try XCTUnwrap(fixture.session.activeRunOwnership?.turnEpoch)
            try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(fixture.session.runID))

            let runtime = try XCTUnwrap(claude.runtimes.last)
            await runtime.emit(.approvalRequest(Self.claudeApprovalRequest(id: "approval")))
            try await eventually(seconds: 15) { fixture.session.runState == .waitingForApproval }
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "queued", tabID: fixture.tabID), .submitted)
            let followUpItemID = try XCTUnwrap(fixture.session.items.last { $0.kind == .user }?.id)
            try pinQueuedEstimate(of: followUpItemID, to: 4_000_004, in: fixture.session)
            await runtime.emit(.approvalCancelled(requestID: "approval"))
            try await eventually { fixture.session.runState == .running }

            // H's result is held before it reaches the store.
            let publicationGate = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(publicationGate)
            var publications = 0
            fixture.viewModel.test_beforeTerminalPublication = {
                publications += 1
                if publications == 1 { await publicationGate.wait() }
            }
            let headTurnID = try XCTUnwrap(claude.sentTurnIDs.first)
            await runtime.emit(.turnCompleted(turnID: headTurnID, status: .completed))
            try await eventually(seconds: 15) { publicationGate.isWaiting }
            XCTAssertTrue(fixture.session.runLifecycle.terminalCommitInProgress)
            XCTAssertFalse(fixture.session.runState.isActive)
            let followUpTicket = try XCTUnwrap(
                fixture.session.unresolvedStartupTicket,
                "the follow-up was not admitted before its run's result published"
            )
            XCTAssertEqual(followUpTicket.optimisticUserItemID, followUpItemID)

            // Starts arriving in the gap are refused rather than started beside the follow-up.
            do {
                _ = try await fixture.viewModel.mcpDispatchInstruction(
                    sessionID: fixture.sessionID,
                    text: "dispatched intruder",
                    allowStartingRun: true
                )
                XCTFail("a dispatch started a run in the publication gap")
            } catch {
                XCTAssertTrue("\(error)".contains("startup_pending"), "\(error)")
            }
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "manual intruder", tabID: fixture.tabID),
                .blocked(message: AgentModeViewModel.manualSubmissionDuringStartupMessage)
            )
            XCTAssertNil(fixture.session.activeRunAttemptID, "an attempt began while the result was publishing")
            let storeEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
            XCTAssertEqual(storeEpoch, headEpoch, "the store advanced before the result published")

            publicationGate.release()
            try await eventually(seconds: 15) { followUpTicket.phase == .accepted }
            try await eventually { claude.sentMessages.count == 2 }
            XCTAssertTrue(claude.sentMessages[1].contains("queued"), claude.sentMessages[1])
            let followUpEpoch = try XCTUnwrap(fixture.session.activeRunOwnership?.turnEpoch)
            XCTAssertNotEqual(followUpEpoch.id, headEpoch.id)
            XCTAssertEqual(fixture.session.activeNonCodexTurnTokenAccumulator?.estimatedUserInputTokens, 4_000_004)
            let headResult = await AgentRunSessionStore.snapshot(for: .init(registration: registration, epoch: headEpoch))
            XCTAssertEqual(headResult?.status, .completed)
            XCTAssertFalse(claude.sentMessages.contains { $0.contains("intruder") })
            XCTAssertEqual(fixture.session.pendingInstructions, [])
            XCTAssertEqual(fixture.session.pendingNonCodexUserInputTokenQueue, [])
        }

        func testStartAcceptedWhileTheResultPublishesWaitsForThePublication() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            fixture.session.selectedAgent = .claudeCode
            let registration = try await activateMCPControl(fixture: fixture, sessionID: fixture.sessionID)
            let head = try fixture.submit("head")
            try await startupTestJoin(head.task)
            try await eventually { claude.sentMessages.count == 1 }
            let headEpoch = try XCTUnwrap(fixture.session.activeRunOwnership?.turnEpoch)
            try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(fixture.session.runID))

            let publicationGate = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(publicationGate)
            var publications = 0
            fixture.viewModel.test_beforeTerminalPublication = {
                publications += 1
                if publications == 1 { await publicationGate.wait() }
            }
            let runtime = try XCTUnwrap(claude.runtimes.last)
            let headTurnID = try XCTUnwrap(claude.sentTurnIDs.first)
            await runtime.emit(.turnCompleted(turnID: headTurnID, status: .completed))
            try await eventually(seconds: 15) { publicationGate.isWaiting }
            XCTAssertNil(fixture.session.unresolvedStartupTicket)

            // With nothing queued, a new start is admitted in the gap and waits for the publication.
            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "next", tabID: fixture.tabID), .submitted)
            let next = try XCTUnwrap(fixture.session.unresolvedStartupTicket)
            fixture.cleanup.tickets.append(next)
            try await eventually { fixture.session.runLifecycle.test_terminalCommitCompletionWaiterCount == 1 }
            XCTAssertEqual(next.phase, .queued)
            XCTAssertNil(fixture.session.activeRunAttemptID, "an attempt began while the result was publishing")
            let storeEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
            XCTAssertEqual(storeEpoch, headEpoch, "the store advanced before the result published")

            publicationGate.release()
            try await startupTestJoin(next.task)
            XCTAssertEqual(next.phase, .accepted)
            try await eventually { claude.sentMessages.count == 2 }
            XCTAssertTrue(claude.sentMessages[1].contains("next"), claude.sentMessages[1])
            let headResult = await AgentRunSessionStore.snapshot(for: .init(registration: registration, epoch: headEpoch))
            XCTAssertEqual(headResult?.status, .completed)
            let nextEpoch = try XCTUnwrap(fixture.session.activeRunOwnership?.turnEpoch)
            XCTAssertNotEqual(nextEpoch.id, headEpoch.id)
        }

        func testRejectedStartLeavesALiveRunWithoutATicketRunning() async throws {
            let claude = StartupTestClaudeRecorder()
            let fixture = makeFixture(claude: claude)
            fixture.session.selectedAgent = .claudeCode
            // Bound up front, so the follow-up start installs no binding that would already make
            // H's ticket stale.
            fixture.session.testInstallPersistentSessionBinding(sessionID: fixture.sessionID)
            var rejectRunStarts = false
            fixture.viewModel.test_agentAvailabilityForRunOverride = { _ in !rejectRunStarts }
            let settlementGate = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(settlementGate)
            fixture.viewModel.test_beforeStartRejectedSettlement = {
                await settlementGate.wait()
            }
            let head = try fixture.submit("head")
            rejectRunStarts = true
            try await eventually { settlementGate.isWaiting }
            rejectRunStarts = false

            // Every run start takes a startup ticket first, so no path starts a run beside H's
            // unresolved one; the live run is set up directly to hold the settlement to never
            // failing a run it does not own.
            let liveOwnership = fixture.session.beginRunAttempt(source: "test.liveRunWithoutTicket")
            fixture.session.runState = .running
            let liveAttemptID = liveOwnership.attemptID

            XCTAssertTrue(fixture.session.startupTicket === head && head.isUnresolved && head.ownership == nil)
            settlementGate.release()
            try await startupTestJoin(head.task)
            XCTAssertEqual(head.phase, .rejected)
            XCTAssertTrue(fixture.session.runState.isActive, "the rejected start failed the live run")
            XCTAssertEqual(fixture.session.activeRunAttemptID, liveAttemptID)
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

        private func pinQueuedEstimate(
            of submissionID: UUID,
            to tokens: Int,
            in session: AgentModeViewModel.TabSession,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let index = try XCTUnwrap(
                session.pendingNonCodexUserInputTokenQueue.firstIndex { $0.submissionID == submissionID },
                "no estimate is queued for the submission",
                file: file,
                line: line
            )
            session.pendingNonCodexUserInputTokenQueue[index].tokens = tokens
        }

        func testCancellingPromotedHeadWithdrawsFollowerStillAwaitingDispatchAuthorization() async throws {
            let fixture = makeFixture(gatedReadinessCalls: [1, 2])
            let first = try fixture.submit("rejected head")
            try await eventually { fixture.readiness.isWaiting(1) }
            XCTAssertEqual(fixture.submitAsMCPDispatch("promoted"), .submitted)
            let promotedTasks = Set(first.followerTasks)
            let tracker = fixture.session.codexSteerAckTracker
            let attemptID = tracker.beginAttempt()
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "unauthorized", tabID: fixture.tabID, codexAttemptID: attemptID),
                .submitted
            )
            let unauthorizedTask = try XCTUnwrap(first.followerTasks.first { !promotedTasks.contains($0) })

            fixture.readiness.release(1, ready: false)
            try await startupTestJoin(first.task)
            try await eventually { fixture.readiness.isWaiting(2) }
            XCTAssertNotEqual(first.phase, .cancelled)
            let promoted = try XCTUnwrap(fixture.session.unresolvedStartupTicket)
            fixture.cleanup.tickets.append(promoted)
            XCTAssertFalse(promoted === first)
            XCTAssertNotNil(promoted.task, "the promoted head does not own its dispatch task")

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            try await startupTestJoin(unauthorizedTask)

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
            XCTAssertEqual(fixture.submitAsMCPDispatch("follower"), .submitted)
            let followers = head.followerTasks
            XCTAssertEqual(followers.count, 1)
            let followerGateTicket = try XCTUnwrap(head.followerDispatchGateTickets.first)
            try await eventually { fixture.session.codexDispatchSerialGate.test_hasWaiter(for: followerGateTicket) }
            XCTAssertEqual(fixture.startAgentRunCalls.count, 1)

            _ = fixture.viewModel.test_prepareWorkspaceSwitchSessionDiscard(fixture.session)
            fixture.readiness.release(1, ready: true)
            try await startupTestJoin(head.task)
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
            try await startupTestJoin(head.task)

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
            try await startupTestJoin(ticket.task)

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
            try await startupTestJoin(ticket.task)

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

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            XCTAssertEqual(fixture.session.runState, .cancelled)
            fixture.hydration.release()
            try await startupTestJoin(ticket.task)

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
            XCTAssertEqual(fixture.submitAsMCPDispatch("follower"), .submitted)
            XCTAssertTrue(fixture.session.startupTicket === head)
            let followers = head.followerTasks
            XCTAssertEqual(followers.count, 1)

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.hydration.release()
            try await startupTestJoin(head.task)
            try await settle(followers)

            XCTAssertFalse(fixture.session.items.contains { $0.kind == .user })
            XCTAssertEqual(fixture.startAgentRunCalls.count, 0)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])

            let later = try fixture.submit("later")
            try await eventually { fixture.controller.startUserTurnTexts == ["later"] }
            try await startupTestJoin(later.task)
            XCTAssertEqual(later.phase, .accepted)
        }

        // MARK: - MCP epoch preparation

        func testEpochAcceptedAfterCancellationIsSettledAndNeverReportsRunning() async throws {
            let fixture = makeFixture()
            let sessionID = UUID()
            _ = try await activateMCPControl(fixture: fixture, sessionID: sessionID)
            let epochGate = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(epochGate)
            fixture.viewModel.test_setAfterMCPStoreEpochBegan { await epochGate.wait() }
            XCTAssertTrue(fixture.session.mcpFollowUpRunPending)

            let ticket = try fixture.submit("mcp start")
            try await eventually { epochGate.isWaiting }
            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            epochGate.release()
            try await startupTestJoin(ticket.task)

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
            try await startupTestJoin(ticket.task)

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
            let epochGate = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(epochGate)
            let heldFirstPreparation = StartupTestCompletionFlag()
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
            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }

            let successor = try fixture.submit("successor")
            // The successor either parks behind the held preparation or, if nothing orders them,
            // races ahead to readiness bound to an outdated epoch.
            try await eventually {
                fixture.session.test_mcpEpochPreparationWaiterCount > 0 || fixture.readiness.isWaiting(1)
            }
            XCTAssertEqual(fixture.readiness.callCount, 0, "the successor ran ahead of the pending epoch preparation")

            epochGate.release()
            try await startupTestJoin(staleTicket.task)
            try await eventually { fixture.readiness.isWaiting(1) }

            let successorOwnership = try XCTUnwrap(fixture.session.activeRunOwnership)
            XCTAssertTrue(successor.ownership == successorOwnership)
            let successorEpoch = try XCTUnwrap(successorOwnership.turnEpoch)
            XCTAssertNotEqual(successorEpoch, priorEpoch)
            XCTAssertNotEqual(successorEpoch, staleEpoch)
            XCTAssertEqual(fixture.session.mcpControlContext?.currentEpoch, successorEpoch)
            let storeEpoch = await AgentRunSessionStore.currentEpoch(for: registration)
            XCTAssertEqual(storeEpoch, successorEpoch, "the successor's epoch disagrees with the store")

            try await settle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.readiness.release(1, ready: true)
            try await startupTestJoin(successor.task)

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
                pendingStartOwner: UUID(),
                markSessionAsMCPOriginated: true,
                requireInactiveRunState: true
            )
            fixture.cleanup.afterStartsSettle.append {
                await fixture.viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
            return context.registration
        }

        // MARK: - Fixture

        /// Adds held hydration and a log of `startAgentRun` calls to the shared fixture.
        @MainActor
        private final class Fixture: StartupTestSessionFixture {
            let hydration: StartupTestHeldGate
            let startAgentRunCalls = StartAgentRunLog()

            init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController,
                hydration: StartupTestHeldGate
            ) {
                self.hydration = hydration
                super.init(viewModel: viewModel, session: session, readiness: readiness, controller: controller)
                let startAgentRunCalls = startAgentRunCalls
                viewModel.test_startAgentRunObserver = { startAgentRunCalls.sessions.append(ObjectIdentifier($0)) }
                cleanup.releases.append { hydration.release() }
            }
        }

        /// Builds the fixture and registers its teardown before any test step can throw.
        private func makeFixture(
            gatedReadinessCalls: Set<Int> = [],
            gateControllerStartup: Bool = false,
            gatedHydration: Bool = false,
            claude: StartupTestClaudeRecorder? = nil
        ) -> Fixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: gatedReadinessCalls)
            let controller = StartupTestCodexController(gatesStartup: gateControllerStartup)
            let viewModel = startupTestMakeViewModel(
                storageRoot: storageRoot,
                readiness: readiness,
                controller: controller,
                claude: claude
            )
            let session = startupTestCodexSession()
            let hydration = StartupTestHeldGate()
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
            let fixture = Fixture(
                viewModel: viewModel,
                session: session,
                readiness: readiness,
                controller: controller,
                hydration: hydration
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
                try await startupTestJoin(task, file: file, line: line)
            }
        }

        /// Awaits `operation` with a deadline, so a start that never settles fails at the calling
        /// line instead of hanging the suite.
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
#endif
