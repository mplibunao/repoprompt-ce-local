@testable import RepoPromptApp
import XCTest

final class AgentSessionColdRestoreRunStateTests: XCTestCase {
    /// Recovery attributes a persisted `completed` run to the dispatch that minted its session, which
    /// only holds while a crash cannot leave a session looking completed: every active state is
    /// rewritten to `idle` on the cold-restore read, and terminal states pass through untouched.
    func testColdRestoredLastRunStateRawRewritesOnlyActiveStates() {
        for active in [
            AgentSessionRunState.running,
            .waitingForUser,
            .waitingForQuestion,
            .waitingForApproval
        ] {
            XCTAssertEqual(
                AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(active.rawValue),
                AgentSessionRunState.idle.rawValue,
                active.rawValue
            )
        }
        for terminal in [
            AgentSessionRunState.idle,
            .completed,
            .cancelled,
            .failed
        ] {
            XCTAssertEqual(
                AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(terminal.rawValue),
                terminal.rawValue,
                terminal.rawValue
            )
        }
        XCTAssertNil(AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(nil))
        XCTAssertEqual(
            AgentSessionRestoreSupport.coldRestoredLastRunStateRaw("futureRunState"),
            "futureRunState"
        )
    }

    #if DEBUG
        /// A run saved while active has no recorded outcome: after the cold-restore rewrite to
        /// `idle`, MCP reports it failed with the unrecorded-terminal diagnostic, never completed.
        @MainActor
        func testColdRestoredActiveRunReportsUnrecordedTerminalFailure() async throws {
            for active in [
                AgentSessionRunState.running,
                .waitingForUser,
                .waitingForQuestion,
                .waitingForApproval
            ] {
                let snapshot = try await restoredSnapshot(
                    items: [.user("prompt saved mid-run", sequenceIndex: 0)],
                    persistedRunState: active
                )
                XCTAssertEqual(snapshot.status, .failed, active.rawValue)
                XCTAssertEqual(snapshot.statusText, AgentModeViewModel.mcpUnrecordedTerminalStatusText, active.rawValue)
                XCTAssertEqual(snapshot.failureReason, .agentError, active.rawValue)
            }
        }

        /// Explicit saved terminal states keep their meaning, including user-only `completed`
        /// records, which the saved evidence cannot tell apart from genuine completions.
        @MainActor
        func testColdRestoredTerminalRunsKeepTheirMeaning() async throws {
            let completed = try await restoredSnapshot(
                items: [.user("task", sequenceIndex: 0), .assistant("done", sequenceIndex: 1)],
                persistedRunState: .completed
            )
            XCTAssertEqual(completed.status, .completed)

            let userOnlyCompleted = try await restoredSnapshot(
                items: [.user("task", sequenceIndex: 0)],
                persistedRunState: .completed
            )
            XCTAssertEqual(userOnlyCompleted.status, .completed)

            let failed = try await restoredSnapshot(
                items: [.user("task", sequenceIndex: 0), .error("provider exploded", sequenceIndex: 1)],
                persistedRunState: .failed
            )
            XCTAssertEqual(failed.status, .failed)
            XCTAssertEqual(failed.statusText, "provider exploded")

            let cancelled = try await restoredSnapshot(
                items: [.user("task", sequenceIndex: 0)],
                persistedRunState: .cancelled
            )
            XCTAssertEqual(cancelled.status, .cancelled)
        }

        @MainActor
        private func restoredSnapshot(
            items: [AgentChatItem],
            persistedRunState: AgentSessionRunState
        ) async throws -> AgentRunMCPSnapshot {
            let viewModel = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in
                StartupTestCodexController(gatesStartup: false)
            })
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            viewModel.test_installLiveSession(session)
            startupTestInstallRestoredState(on: session, items: items, persistedRunState: persistedRunState)
            let sessionID = UUID()
            try await startupTestActivateMCPControl(
                viewModel: viewModel,
                session: session,
                sessionID: sessionID,
                startPending: false
            )
            let snapshot = viewModel.mcpSnapshot(sessionID: sessionID)
            await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            return try XCTUnwrap(snapshot, persistedRunState.rawValue)
        }
    #endif
}
