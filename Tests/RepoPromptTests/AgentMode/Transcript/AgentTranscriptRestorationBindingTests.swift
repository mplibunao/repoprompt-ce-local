#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    /// A workspace switch can activate a tab with a saved Agent session while the prompt shows no
    /// tab, which starts the session's persisted load. These tests cover the later real selection of
    /// that tab: it must publish the saved rows whether the load already finished or is still running.
    @MainActor
    final class AgentTranscriptRestorationBindingTests: XCTestCase {
        private static let waitTimeout: TimeInterval = 5

        func testSameTabSelectionAfterCompletedHydrationReappliesBindings() async throws {
            try await withSavedTabFixture { fixture in
                let viewModel = fixture.viewModel
                let held = try await activateTabFromWorkspaceSwitchAndHoldPreparation(fixture)

                fixture.gate.open()
                await held.producer.value
                // The creating activation clears the load task and runs its post-load check in one
                // main-actor slice, so a cleared task means that check has run.
                try await waitUntil("the creating activation finishes its persisted load") {
                    held.session.persistedLoadTask == nil
                }

                XCTAssertTrue(held.session.hasLoadedPersistedState, "Precondition: hydration completed.")
                XCTAssertNil(fixture.prompt.activeComposeTabID, "Precondition: no tab was selected during hydration.")
                XCTAssertEqual(held.session.items.map(\.id), [fixture.savedRowID], "Precondition: hydration loaded the saved row.")
                XCTAssertEqual(viewModel.activeTranscriptPresentation.workingRows.map(\.id), [], "Precondition: nothing published rows.")
                XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.map(\.id), [], "Precondition: nothing published rows.")
                XCTAssertEqual(viewModel.activeSessionLoadInProgressTabID, fixture.tabID, "Precondition: the tab is still marked loading.")
                XCTAssertEqual(fixture.gate.entryCount, 1, "Precondition: one persisted load started.")

                await fixture.prompt.switchComposeTab(fixture.tabID)

                assertSavedTranscriptPublished(fixture, held)
            }
        }

        func testSameTabSelectionDuringHydrationJoinsLoadAndPublishesBindings() async throws {
            try await withSavedTabFixture { fixture in
                let viewModel = fixture.viewModel
                let held = try await activateTabFromWorkspaceSwitchAndHoldPreparation(fixture)

                await fixture.prompt.switchComposeTab(fixture.tabID)

                XCTAssertEqual(fixture.prompt.activeComposeTabID, fixture.tabID, "Precondition: the prompt selected the tab.")
                XCTAssertEqual(viewModel.currentTabID, fixture.tabID, "Precondition: the prompt selected the tab.")
                XCTAssertTrue(viewModel.sessions[fixture.tabID] === held.session, "Precondition: the selection kept the session.")
                XCTAssertEqual(held.session.persistentSessionBindingIdentity, held.binding, "Precondition: the selection kept the binding.")
                XCTAssertEqual(held.session.persistedLoadTask, held.producer, "Precondition: the held load is still the session's load.")
                XCTAssertEqual(fixture.gate.entryCount, 1, "Precondition: the selection started no second load.")
                XCTAssertFalse(viewModel.activeTranscriptPresentation.bindingsHydrated, "Precondition: the transcript shows loading.")
                XCTAssertEqual(viewModel.activeTranscriptPresentation.workingRows.map(\.id), [], "Precondition: the transcript shows loading.")
                XCTAssertEqual(viewModel.activeTranscriptPresentation.visibleRows.map(\.id), [], "Precondition: the transcript shows loading.")

                let bothActivationsFinished = fixture.recorder.expectation(
                    forCompletions: 2,
                    description: "the workspace-switch activation and the selection's activation of the tab both finish"
                )
                fixture.gate.open()
                await held.producer.value
                // A joining activation can publish before the creating one clears the load task, so
                // the load-task assertion below waits for both activations.
                await fulfillment(of: [bothActivationsFinished], timeout: Self.waitTimeout)

                let generations = fixture.recorder.generations
                XCTAssertEqual(generations.count, 2, "Finished activations of the tab, by generation: \(generations)")
                XCTAssertEqual(Set(generations).count, generations.count, "Finished activations of the tab, by generation: \(generations)")
                assertSavedTranscriptPublished(fixture, held)
            }
        }

        // MARK: - Scenario steps

        private struct HeldActivation {
            let session: AgentModeViewModel.TabSession
            let binding: AgentPersistentSessionBindingIdentity
            let producer: Task<Void, Never>
        }

        /// Activates the saved tab the way the workspace-switch handler does while the prompt shows no
        /// tab, then returns with that activation's persisted load held before preparation and the
        /// empty sidebar index refresh finished, so the refresh can't activate the tab again.
        private func activateTabFromWorkspaceSwitchAndHoldPreparation(
            _ fixture: SavedTabFixture
        ) async throws -> HeldActivation {
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            XCTAssertNil(fixture.prompt.activeComposeTabID, "Precondition: showing Agent Mode selected no tab.")

            let owner = viewModel.test_receiveWorkspaceSwitchNotification(fixture.workspace)
            await viewModel.test_handleWorkspaceSwitch(fixture.workspace, owner: owner)
            await fulfillment(of: [fixture.gate.firstEntry], timeout: Self.waitTimeout)

            let session = try XCTUnwrap(viewModel.sessions[fixture.tabID], "Precondition: the switch created the tab's session.")
            let binding = try XCTUnwrap(session.persistentSessionBindingIdentity, "Precondition: the session is bound.")
            let producer = try XCTUnwrap(session.persistedLoadTask, "Precondition: the session's persisted load is running.")
            fixture.capturedProducer = producer
            await viewModel.test_waitForSessionListCacheRefresh()
            return HeldActivation(session: session, binding: binding, producer: producer)
        }

        private func assertSavedTranscriptPublished(
            _ fixture: SavedTabFixture,
            _ held: HeldActivation,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let viewModel = fixture.viewModel
            let tabID = fixture.tabID
            let savedRowIDs = [fixture.savedRowID]

            XCTAssertEqual(fixture.prompt.activeComposeTabID, tabID, file: file, line: line)
            XCTAssertEqual(viewModel.currentTabID, tabID, file: file, line: line)
            XCTAssertTrue(viewModel.sessions[tabID] === held.session, "The selection replaced the session.", file: file, line: line)
            XCTAssertEqual(held.session.persistentSessionBindingIdentity, held.binding, file: file, line: line)

            let presentation = viewModel.activeTranscriptPresentation
            XCTAssertEqual(presentation.workingRows.map(\.id), savedRowIDs, file: file, line: line)
            XCTAssertEqual(presentation.visibleRows.map(\.id), savedRowIDs, file: file, line: line)
            XCTAssertEqual(presentation.tabID, tabID, file: file, line: line)
            XCTAssertTrue(presentation.bindingsHydrated, file: file, line: line)
            XCTAssertEqual(presentation.hydratedPersistentBinding, held.binding, file: file, line: line)
            XCTAssertNil(viewModel.activeSessionLoadInProgressTabID, file: file, line: line)
            XCTAssertFalse(viewModel.workspaceSwitchInFlight, file: file, line: line)

            let transcriptUI = viewModel.ui.transcript.snapshot
            XCTAssertTrue(transcriptUI.isHydrated, file: file, line: line)
            XCTAssertEqual(transcriptUI.currentTabID, tabID, file: file, line: line)
            XCTAssertEqual(transcriptUI.presentation.workingRows.map(\.id), savedRowIDs, file: file, line: line)
            XCTAssertEqual(transcriptUI.presentation.visibleRows.map(\.id), savedRowIDs, file: file, line: line)
            XCTAssertNil(transcriptUI.activeSessionLoadInProgressTabID, file: file, line: line)

            XCTAssertEqual(fixture.gate.entryCount, 1, "The saved session was loaded from disk more than once.", file: file, line: line)
            XCTAssertNil(held.session.persistedLoadTask, file: file, line: line)
        }

        // MARK: - Fixture

        private func withSavedTabFixture(_ body: (SavedTabFixture) async throws -> Void) async throws {
            let fixture = try await makeSavedTabFixture()
            var bodyError: Error?
            do {
                try await body(fixture)
            } catch {
                bodyError = error
            }
            await tearDownSavedTabFixture(fixture)
            if let bodyError {
                throw bodyError
            }
        }

        /// Builds a real window whose workspace has one compose tab bound to a saved Agent session,
        /// with Agent Mode hidden, the prompt showing no tab, and both DEBUG hooks installed.
        private func makeSavedTabFixture() async throws -> SavedTabFixture {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentTranscriptRestorationBindingTests-\(UUID().uuidString)", isDirectory: true)
            let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
            let agentWorkspacesURL = rootURL.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: agentWorkspacesURL, withIntermediateDirectories: true)
            } catch {
                try? FileManager.default.removeItem(at: rootURL)
                throw error
            }

            let dataService = AgentSessionDataService.shared
            let displacedWorkspaceRootOverride = await dataService.test_workspaceRootOverride()
            await dataService.test_setWorkspaceRootOverride(agentWorkspacesURL)

            let previousMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousMCPAutoStart, commit: false)

            do {
                let manager = window.workspaceManager
                let viewModel = window.agentModeViewModel
                await manager.awaitInitialized()

                let created = manager.createWorkspace(
                    name: "Restoration Bindings",
                    repoPaths: [repoURL.path],
                    ephemeral: true
                )
                await manager.switchWorkspace(to: created, saveState: false, reason: "agentTranscriptRestorationBindingTests")
                try await waitUntil("Agent Mode handles the fixture's workspace switch") {
                    !viewModel.hasPendingWorkspaceSwitchDiscard
                }
                await viewModel.test_waitForSessionListCacheRefresh()

                let tabID = UUID()
                let sessionID = UUID()
                let index = try XCTUnwrap(manager.workspaces.firstIndex(where: { $0.id == created.id }))
                manager.workspaces[index].composeTabs = [
                    ComposeTabState(id: tabID, name: "Saved", activeAgentSessionID: sessionID)
                ]
                manager.workspaces[index].activeComposeTabID = tabID
                // The switch handler activates the tab named by the workspace value it receives, so
                // the fixture keeps the value that contains the saved tab.
                let workspace = manager.workspaces[index]
                window.promptManager.setCurrentComposeTabsForAgentAdmissionRecoveryTesting(
                    workspace.composeTabs,
                    activeComposeTabID: nil
                )
                viewModel.test_setSidebarIndexBuilders(
                    prioritized: { _ in
                        AgentSessionSidebarBuildResult(entriesBySessionID: [:], preferredSessionIDByTabID: [:])
                    },
                    stream: { _, _ in
                        AsyncThrowingStream { $0.finish() }
                    }
                )

                let savedRow = AgentChatItem(
                    id: UUID(),
                    timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                    kind: .user,
                    text: "RP1526 saved transcript"
                )
                let savedSession = AgentSession(
                    id: sessionID,
                    workspaceID: workspace.id,
                    composeTabID: tabID,
                    name: "Saved session",
                    lastRunState: AgentSessionRunState.completed.rawValue,
                    autoEditEnabled: false
                ).withItems([savedRow])
                let savedFileURL = try await dataService.saveAgentSession(savedSession, for: workspace)

                let fixture = SavedTabFixture(
                    window: window,
                    rootURL: rootURL,
                    displacedWorkspaceRootOverride: displacedWorkspaceRootOverride,
                    workspace: workspace,
                    tabID: tabID,
                    savedRowID: savedRow.id,
                    savedFileURL: savedFileURL
                )
                let gate = fixture.gate
                let recorder = fixture.recorder
                viewModel.test_beforePersistedHydrationPrepare = { _ in
                    await gate.enterAndWait()
                }
                viewModel.test_afterTabActivationContinuation = { tabID, generation in
                    recorder.record(tabID: tabID, generation: generation)
                }
                return fixture
            } catch {
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                await dataService.test_setWorkspaceRootOverride(displacedWorkspaceRootOverride)
                try? FileManager.default.removeItem(at: rootURL)
                throw error
            }
        }

        /// Runs after success, a failed assertion, a thrown error, or cancellation. Each step reports
        /// its own failure with `XCTFail`, so cleanup never replaces the test's first failure.
        private func tearDownSavedTabFixture(_ fixture: SavedTabFixture) async {
            let viewModel = fixture.viewModel
            let tabID = fixture.tabID
            let dataService = AgentSessionDataService.shared

            // A held caller ignores cancellation, so opening the gate is what releases a held load.
            fixture.gate.open()
            if let producer = fixture.capturedProducer ?? viewModel.sessions[tabID]?.persistedLoadTask {
                producer.cancel()
                await producer.value
            }
            await cleanupStep("the tab's persisted load task clears") {
                try await self.waitUntil("the tab's persisted load task clears") {
                    viewModel.sessions[tabID]?.persistedLoadTask == nil
                }
            }
            if fixture.gate.entryCount > 0 {
                await cleanupStep("the activation that started the load finishes") {
                    try await self.waitUntil("the activation that started the load finishes") {
                        !fixture.recorder.generations.isEmpty
                    }
                }
            }
            await viewModel.test_waitForSessionListCacheRefresh()
            await cleanupStep("workspace-switch background cleanup drains") {
                try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup()
            }
            viewModel.test_beforePersistedHydrationPrepare = nil
            viewModel.test_afterTabActivationContinuation = nil

            fixture.window.beginClose()
            await fixture.window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(fixture.window)
            await dataService.test_clearMetadataIndexCache(
                forAgentSessionsFolder: fixture.savedFileURL.deletingLastPathComponent()
            )
            await dataService.test_setWorkspaceRootOverride(fixture.displacedWorkspaceRootOverride)
            await cleanupStep("the temporary directory is removed") {
                try FileManager.default.removeItem(at: fixture.rootURL)
            }
        }

        private func cleanupStep(_ description: String, _ work: () async throws -> Void) async {
            do {
                try await work()
            } catch {
                XCTFail("Cleanup failed: \(description): \(error)")
            }
        }

        private func waitUntil(_ description: String, condition: () -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(Self.waitTimeout))
            while !condition() {
                guard clock.now < deadline else {
                    throw WaitTimeout(description: description)
                }
                await Task.yield()
            }
        }

        private struct WaitTimeout: Error, CustomStringConvertible {
            let description: String
        }
    }

    @MainActor
    private final class SavedTabFixture {
        let window: WindowState
        let rootURL: URL
        let displacedWorkspaceRootOverride: URL?
        let workspace: WorkspaceModel
        let tabID: UUID
        let savedRowID: UUID
        let savedFileURL: URL
        let gate = PreparationGate()
        let recorder: ActivationCompletionRecorder
        var capturedProducer: Task<Void, Never>?

        var prompt: PromptViewModel {
            window.promptManager
        }

        var viewModel: AgentModeViewModel {
            window.agentModeViewModel
        }

        init(
            window: WindowState,
            rootURL: URL,
            displacedWorkspaceRootOverride: URL?,
            workspace: WorkspaceModel,
            tabID: UUID,
            savedRowID: UUID,
            savedFileURL: URL
        ) {
            self.window = window
            self.rootURL = rootURL
            self.displacedWorkspaceRootOverride = displacedWorkspaceRootOverride
            self.workspace = workspace
            self.tabID = tabID
            recorder = ActivationCompletionRecorder(tabID: tabID)
            self.savedRowID = savedRowID
            self.savedFileURL = savedFileURL
        }
    }

    /// Holds persisted-load preparation until the test opens it and counts every preparation that
    /// starts. Once opened it stays open and releases every held caller.
    @MainActor
    private final class PreparationGate {
        let firstEntry: XCTestExpectation
        private(set) var entryCount = 0
        private var isOpen = false
        private var heldCallers: [CheckedContinuation<Void, Never>] = []

        init() {
            firstEntry = XCTestExpectation(description: "a persisted session load reaches preparation")
            firstEntry.assertForOverFulfill = false
        }

        func enterAndWait() async {
            entryCount += 1
            firstEntry.fulfill()
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                heldCallers.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let callers = heldCallers
            heldCallers.removeAll()
            callers.forEach { $0.resume() }
        }
    }

    /// Records finished activations of the fixture tab and supports one pending count expectation.
    /// It never starts an activation.
    @MainActor
    private final class ActivationCompletionRecorder {
        private let tabID: UUID
        private(set) var generations: [Int] = []
        private var pending: (count: Int, expectation: XCTestExpectation)?

        init(tabID: UUID) {
            self.tabID = tabID
        }

        func record(tabID: UUID, generation: Int) {
            guard tabID == self.tabID else { return }
            generations.append(generation)
            if let pending, generations.count >= pending.count {
                self.pending = nil
                pending.expectation.fulfill()
            }
        }

        func expectation(forCompletions count: Int, description: String) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: description)
            if generations.count >= count {
                expectation.fulfill()
            } else {
                pending = (count: count, expectation: expectation)
            }
            return expectation
        }
    }
#endif
