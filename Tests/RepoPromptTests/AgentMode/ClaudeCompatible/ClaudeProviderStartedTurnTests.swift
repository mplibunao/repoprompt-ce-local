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

            var userRowIDs: [UUID] {
                session.items.filter { $0.kind == .user }.map(\.id)
            }

            /// Sends `text`, answers it with `answer` as Claude's final reply, and waits until its
            /// terminal has published.
            func runHostTurn(_ text: String, answer: String) async throws {
                let sentBefore = claude.sentMessages.count
                let ticket = try submit(text)
                try await startupTestJoin(ticket.task)
                try await startupTestEventually { self.claude.sentMessages.count == sentBefore + 1 }
                try await MCPRoutingWaiter.notifyRouted(runID: XCTUnwrap(session.runID))
                let runtime = try XCTUnwrap(claude.runtimes.last)
                let turnID = try XCTUnwrap(claude.sentTurnIDs.last)
                try await awaitNextPublication {
                    await runtime.emit(.stream(AIStreamResult(type: "final_content", text: answer)))
                    await runtime.emit(.turnsCompleted(turnIDs: [turnID], status: .completed))
                }
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

            private func awaitNextPublication(after emit: () async -> Void) async throws {
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
