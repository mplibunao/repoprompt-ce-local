import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentComposerSubmissionAttemptTests: XCTestCase {
    func testComposerProductionEqualityRejectsLiveTabChangeBeforePropsCatchUp() {
        let sourceTabID = UUID()
        let destinationTabID = UUID()

        XCTAssertTrue(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: sourceTabID
            )
        )
        XCTAssertFalse(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: destinationTabID
            )
        )
    }

    func testNewSessionGoalControlPlaneSubmissionClearsSourceDraftAndPendingState() async throws {
        let window = try await makeWindow()

        let viewModel = window.agentModeViewModel
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sourceTabID = try XCTUnwrap(workspace.activeComposeTabID)
        let sourceSession = viewModel.session(for: sourceTabID)
        viewModel.test_setWorkspaceSwitchInFlight(false)
        let workflow = AgentWorkflow.build.definition
        let command = "/goal Keep composer cleanup deterministic"
        sourceSession.selectedAgent = .codexExec
        sourceSession.selectedWorkflow = workflow
        viewModel.storeDraftText(for: sourceTabID, command)

        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))
        XCTAssertEqual(target.route, .createAgentSessionFromSourceTab)
        var destinationTabID: UUID?
        viewModel.test_submitUserTurnResultOverride = { text, tabID, rawDraftText in
            XCTAssertEqual(text, command)
            XCTAssertEqual(rawDraftText, command)
            XCTAssertNotEqual(tabID, sourceTabID)
            XCTAssertEqual(viewModel.session(for: tabID).selectedWorkflow, workflow)
            destinationTabID = tabID
            return .submittedControlPlaneCommand
        }
        defer { viewModel.test_submitUserTurnResultOverride = nil }

        let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
            text: command,
            target: target,
            createAndActivateSessionTab: { await viewModel.createAndActivateSessionTab() }
        )

        XCTAssertEqual(result, .submittedControlPlaneCommand)
        XCTAssertNotNil(destinationTabID)
        XCTAssertEqual(viewModel.retrieveDraftText(for: sourceTabID), "")
        XCTAssertNil(sourceSession.selectedWorkflow)
        XCTAssertNil(sourceSession.activeComposerSubmitAttempt)
    }

    /// A first send from a worktree-scoped tab returns the attachment refusal without opening an
    /// Agent tab or submitting a turn, and keeps the draft and the tab's scope.
    func testWorktreeScopedTabFirstSendRefusesWithoutCreatingAgentTab() async throws {
        let window = try await makeWindow()

        let viewModel = window.agentModeViewModel
        let manager = window.workspaceManager
        let workspace = try XCTUnwrap(manager.activeWorkspace)
        let sourceTabID = try XCTUnwrap(workspace.activeComposeTabID)
        let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspace.id })
        let tabIndex = try XCTUnwrap(
            manager.workspaces[workspaceIndex].composeTabs.firstIndex { $0.id == sourceTabID }
        )
        manager.workspaces[workspaceIndex].composeTabs[tabIndex].worktreeScope = .unavailable
        let sourceSession = viewModel.session(for: sourceTabID)
        viewModel.test_setWorkspaceSwitchInFlight(false)
        let draft = "Start an agent on this worktree"
        viewModel.storeDraftText(for: sourceTabID, draft)

        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))
        XCTAssertEqual(target.route, .createAgentSessionFromSourceTab)
        viewModel.test_submitUserTurnResultOverride = { _, _, _ in
            XCTFail("A scoped tab must not submit a turn.")
            return .submitted
        }
        defer { viewModel.test_submitUserTurnResultOverride = nil }
        var createdTabCount = 0

        let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
            text: draft,
            target: target,
            createAndActivateSessionTab: {
                createdTabCount += 1
                return await viewModel.createAndActivateSessionTab()
            }
        )

        XCTAssertEqual(
            result,
            .blocked(message: ComposeTabWorktreeScopeError.agentAttachmentRefused.localizedDescription)
        )
        XCTAssertEqual(createdTabCount, 0)
        let stored = try XCTUnwrap(manager.workspace(withID: workspace.id))
        XCTAssertEqual(stored.composeTabs.map(\.id), workspace.composeTabs.map(\.id))
        let storedTab = try XCTUnwrap(stored.composeTabs.first { $0.id == sourceTabID })
        XCTAssertEqual(storedTab.worktreeScope, .unavailable)
        XCTAssertNil(storedTab.activeAgentSessionID)
        XCTAssertEqual(viewModel.retrieveDraftText(for: sourceTabID), draft)
        XCTAssertNil(sourceSession.activeComposerSubmitAttempt)
    }

    func testLatchSuppressesRapidSameTabCallbacksButAllowsAnotherTab() throws {
        var latch = AgentComposerSubmissionLatch()
        let firstSession = AgentModeViewModel.TabSession(tabID: UUID())
        let secondSession = AgentModeViewModel.TabSession(tabID: UUID())
        let firstTarget = makeTarget(session: firstSession)
        let secondTarget = makeTarget(session: secondSession)

        let firstAttempt = try XCTUnwrap(latch.begin(target: firstTarget, rawDraftSnapshot: "first"))

        XCTAssertTrue(latch.isLatched(for: firstSession.tabID))
        XCTAssertEqual(latch.activeAttemptID(for: firstSession.tabID), firstAttempt.id)
        XCTAssertNil(latch.begin(target: firstTarget, rawDraftSnapshot: "duplicate"))
        XCTAssertNotNil(latch.begin(target: secondTarget, rawDraftSnapshot: "second"))
    }

    func testMatchingCompletionClearsOnlyUnchangedInput() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertTrue(effects.shouldClearInput)
        XCTAssertNil(effects.blockedMessage)
        XCTAssertFalse(latch.isLatched(for: session.tabID))
    }

    func testNewerTypingAndDraftRestorationSurviveCompletion() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        // A programmatic restoration must advance the same revision even when the
        // resulting text happens to match the submitted text.
        latch.advanceInputRevision()
        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testTabSwitchPreventsOldCompletionFromClearingCurrentDraft() throws {
        var latch = AgentComposerSubmissionLatch()
        let sourceSession = AgentModeViewModel.TabSession(tabID: UUID())
        let currentSession = AgentModeViewModel.TabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: sourceSession), rawDraftSnapshot: "same text")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: currentSession.tabID,
            currentRawDraft: "same text"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testStaleCompletionCannotReleaseNewerAttempt() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let target = makeTarget(session: session)
        let oldAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "old", attemptID: UUID())
        )
        XCTAssertTrue(latch.cancel(oldAttempt))
        let newAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "new", attemptID: UUID())
        )

        let staleEffects = latch.complete(
            oldAttempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "new"
        )

        XCTAssertEqual(staleEffects, .stale)
        XCTAssertEqual(latch.activeAttemptID(for: session.tabID), newAttempt.id)
    }

    func testBlockedCompletionCannotOverwriteNewerNotice() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "draft")
        )
        latch.advanceNoticeRevision()

        let effects = latch.complete(
            attempt,
            result: .blocked(message: "older notice"),
            currentTabID: session.tabID,
            currentRawDraft: "draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertNil(effects.blockedMessage)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        addTeardownBlock { @MainActor in
            window.beginClose()
            // Window teardown suppresses UI root unloading while closing.
            await window.workspaceFilesViewModel.unloadAllRootFolders()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Composer submission \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentComposerSubmissionAttemptTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeTarget(session: AgentModeViewModel.TabSession) -> AgentComposerSubmitTarget {
        AgentComposerSubmitTarget(
            tabID: session.tabID,
            route: .createAgentSessionFromSourceTab,
            expectedSourceTabSessionIdentity: ObjectIdentifier(session),
            expectedSourceAgentSessionID: nil,
            expectedPersistentBindingIdentity: nil,
            expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
            expectedRunState: .idle,
            expectedRunID: nil,
            expectedRunAttemptID: nil,
            expectedSubmissionToken: session.composerSubmissionToken,
            expectedInitialStartLocation: .local
        )
    }
}
