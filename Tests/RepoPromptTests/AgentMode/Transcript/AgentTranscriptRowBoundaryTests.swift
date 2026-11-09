#if DEBUG
    import AppKit
    import Combine
    @testable import RepoPromptApp
    import RepoPromptDomainRuntime
    import SwiftUI
    import XCTest

    /// Contracts of the equatable transcript row boundary, `AgentTranscriptRow`.
    ///
    /// The hosted tests render the production Agent Mode detail view in a window that's never ordered
    /// on screen, and observe rows through `AgentTranscriptTailRenderProbe`.
    @MainActor
    final class AgentTranscriptRowBoundaryTests: XCTestCase {
        private var fixture: TranscriptFixture?
        private var previousStoragePath: String?
        private var previousAutoStart = false
        private var previousFont: FontScalePreset = .normal
        private var previousPerfOverride: Bool?
        private var storageRoot: URL?

        override func setUp() async throws {
            try await super.setUp()
            _ = NSApplication.shared
            previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            previousFont = FontScaleManager.shared.preset
            previousPerfOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
            previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentTranscriptRowBoundaryTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            storageRoot = root
            UserDefaults.standard.set(
                root.appendingPathComponent("state/Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
        }

        override func tearDown() async throws {
            AgentTranscriptTailRenderProbe.sink = nil
            await fixture?.close()
            fixture = nil
            AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousPerfOverride)
            if FontScaleManager.shared.preset != previousFont {
                FontScaleManager.shared.setPreset(previousFont)
            }
            if let previousStoragePath {
                UserDefaults.standard.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            try await super.tearDown()
        }

        // MARK: - Hosted contracts

        /// A provider delta that changes only the streaming tail re-renders only the tail. No settled
        /// bubble is evaluated, and the settled user row's native text view isn't updated and keeps its
        /// identity, storage, and selection.
        func testTailDeltaKeepsSettledRowsUnchanged() async throws {
            let fixture = try await makeFixture(hosted: true)
            let userView = try await fixture.settledUserView()
            let renderedAtSetup = Set(fixture.recorder.bodies.keys)
            XCTAssertTrue(
                renderedAtSetup.isSuperset(of: [Row.user0, Row.opener0, Row.ordinaryError, Row.loginError, Row.opener2]),
                "settled rows must render before the delta, or zero re-renders proves nothing"
            )
            let selection = NSRange(location: 8, length: 12)
            userView.setSelectedRange(selection)
            let storage = userView.attributedString()
            try await fixture.waitForQuiet()
            fixture.recorder.resetCounts()
            let publications = PublicationCounter(fixture.store)

            // The Codex coordinator's delta path: buffering, mutation, admission, and publication.
            let expectedText = fixture.streamTailDelta(" TAILDELTA")
            try await fixture.waitUntil("the delta reaches the tail's native text view") {
                fixture.rowText(Row.tail, contains: "TAILDELTA")
            }
            try await fixture.waitForQuiet()

            XCTAssertEqual(publications.count, 1)
            XCTAssertEqual(fixture.session.items.last?.text, expectedText)
            XCTAssertEqual(fixture.store.snapshot.presentation.visibleRows.last?.text, expectedText)
            XCTAssertEqual(Set(fixture.recorder.bodies.keys), [Row.tail], "only the tail may re-render")
            XCTAssertEqual(fixture.recorder.nativeUpdates[Row.user0, default: 0], 0)
            XCTAssertTrue(fixture.attachedViews(Row.user0).contains { $0 === userView })
            XCTAssertEqual(userView.selectedRange(), selection)
            XCTAssertTrue(userView.attributedString().isEqual(to: storage))
        }

        /// A change to one row's text, runtime footer, live Bash execution, or recent-assistant
        /// membership updates that row and no other.
        func testChangedRowInputsReachTheirConsumers() async throws {
            let fixture = try await makeFixture(hosted: true)
            _ = try await fixture.settledUserView()
            try await fixture.waitUntil("the Bash card reports its completed result") {
                fixture.toolCards.states[Row.bashResult]?.bashPhase == .completed
            }
            try await fixture.waitForQuiet()

            // Own text, through source mutation and the derived refresh.
            try await fixture.expectReRenderedRows([Row.opener2], "own text") {
                fixture.mutateSource(Row.opener2) { $0.text = "Opener CHANGEDTEXT" }
            } until: {
                fixture.rowText(Row.opener2, contains: "CHANGEDTEXT")
            }

            // Runtime footer: the row shows its own footer's status.
            try await fixture.expectReRenderedRows([Row.opener2], "runtime footer") {
                fixture.setRuntimeFooter(Row.opener2, statusText: "FOOTERSTATUS")
            } until: {
                fixture.recorder.footerTexts[Row.opener2] == "FOOTERSTATUS"
            }

            // Live Bash execution: the card shows the live state, then its stored result once the
            // execution entry is gone.
            try await fixture.expectReRenderedRows([Row.bashResult], "live Bash execution") {
                fixture.publish { snapshot in
                    snapshot.activeBashLiveExecutionByItemID[Row.bashResult] = Fixture.liveBashExecution
                }
            } until: {
                fixture.toolCards.states[Row.bashResult]?.bashPhase == .live
            }
            try await fixture.expectReRenderedRows([Row.bashResult], "Bash execution removed") {
                fixture.publish { snapshot in
                    snapshot.activeBashLiveExecutionByItemID[Row.bashResult] = nil
                }
            } until: {
                fixture.toolCards.states[Row.bashResult]?.bashPhase == .completed
            }

            // Recent-assistant membership: a long settled answer renders collapsed until it's recent.
            XCTAssertFalse(fixture.rowText(Row.longConclusion0, contains: "COLLAPSEMARK"))
            try await fixture.expectReRenderedRows([Row.longConclusion0], "recent membership") {
                fixture.publish { snapshot in
                    snapshot.presentation = snapshot.presentation.addingRecentAssistant(Row.longConclusion0)
                    snapshot.presentationRevision += 1
                }
            } until: {
                fixture.rowText(Row.longConclusion0, contains: "COLLAPSEMARK")
            }
        }

        /// Theme, font, and window focus still update mounted rows behind the boundary, without
        /// replacing the settled row's native text view.
        func testThemeFontAndFocusStillUpdateMountedRows() async throws {
            AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
            if FontScaleManager.shared.preset != .normal {
                FontScaleManager.shared.setPreset(.normal)
            }
            let fixture = try await makeFixture(hosted: true)
            let userView = try await fixture.settledUserView()
            fixture.setRuntimeFooter(Row.opener2, statusText: "Working")
            try await fixture.waitUntil("the settled row's live footer renders unfocused") {
                fixture.recorder.footerTexts[Row.opener2] == "Working"
            }
            try await fixture.waitForQuiet()

            // Theme: every mounted bubble reads the color scheme.
            fixture.recorder.resetCounts()
            fixture.window.appearance = NSAppearance(named: .darkAqua)
            try await fixture.waitUntil("a settled row re-renders for the dark appearance") {
                fixture.recorder.bodies[Row.ordinaryError, default: 0] > 0
            }
            XCTAssertTrue(fixture.attachedViews(Row.user0).contains { $0 === userView })

            // Font: the settled user row's native text takes the new size.
            let normalSize = try XCTUnwrap(userView.firstFontSize)
            FontScaleManager.shared.setPreset(.large)
            try await fixture.waitUntil("the settled user row's native text grows") {
                (userView.firstFontSize ?? 0) > normalSize
            }
            XCTAssertTrue(fixture.attachedViews(Row.user0).contains { $0 === userView })

            // Focus: the settled row's live footer switches to its ticking timer.
            let liveTimerMounts = Self.perfCounter("timeline.messageFooter.liveMount")
            fixture.focus.isFocused = true
            try await fixture.waitUntil("the focused footer mounts its live timer") {
                Self.perfCounter("timeline.messageFooter.liveMount") > liveTimerMounts
            }
            XCTAssertTrue(fixture.attachedViews(Row.user0).contains { $0 === userView })
        }

        // MARK: - Row actions

        /// The header cancel action stops the run captured when its row was built, even after a later
        /// row targets another run. A row without an eligible run has no cancel action.
        func testCancelActionTargetsCapturedRun() async throws {
            let fixture = try await makeFixture(hosted: false)
            let cancellations = CallLog()
            let actionOwner = AgentModeViewModel(
                testWindowID: 10960,
                codexControllerFactory: { _, _, _, _, _, _ in
                    StartupTestCodexController(gatesStartup: false)
                },
                mcpRunToolCanceller: { runID, reason in
                    MainActor.assumeIsolated {
                        cancellations.record("\(runID.uuidString) \(reason ?? "")")
                    }
                    return 1
                }
            )
            let runA = UUID()
            let runB = UUID()
            let call = fixture.item(Row.bashCall)
            let rowForRunA = fixture.row(for: call, cancelRunID: runA, agentModeVM: actionOwner)
            let rowForRunB = fixture.row(for: call, cancelRunID: runB, agentModeVM: actionOwner)

            try XCTUnwrap(rowForRunA.cancelAction)()
            try XCTUnwrap(rowForRunB.cancelAction)()

            XCTAssertEqual(cancellations.entries, [
                "\(runA.uuidString) tool_card_header_cancel",
                "\(runB.uuidString) tool_card_header_cancel"
            ])
            XCTAssertNil(fixture.row(for: call, cancelRunID: nil, agentModeVM: actionOwner).cancelAction)
        }

        /// The row's handoff copies the transcript up to its own item and starts from the compared agent
        /// settings. Performing it hands off with the agent, model, and effort the user submits.
        func testHandoffPreservesCutoffDefaultsAndSubmittedSelection() async throws {
            let fixture = try await makeFixture(hosted: false)
            let cutoff = fixture.item(Row.conclusion1)
            var run = AgentRunInteractionUISnapshot.empty
            run.canForkCurrentSession = true
            run.selectedAgent = .codexExec
            run.selectedModelRaw = "default-model"
            run.selectedReasoningEffortRaw = "medium"
            let config = try XCTUnwrap(fixture.row(for: cutoff, runInteraction: run).handoffConfig)

            let clipboard = await config.buildPayloadForClipboard()
            XCTAssertTrue(clipboard.contains("Run the tests"), "the payload covers the rows up to the cutoff")
            XCTAssertFalse(clipboard.contains("LATERMARK"), "the payload stops at the row's item")
            XCTAssertEqual(config.itemID, Row.conclusion1)
            XCTAssertEqual(config.defaultModelRaw, "default-model")

            var changed = run
            changed.selectedModelRaw = "changed-model"
            changed.selectedReasoningEffortRaw = "low"
            let changedConfig = try XCTUnwrap(fixture.row(for: cutoff, runInteraction: changed).handoffConfig)
            XCTAssertEqual(changedConfig.defaultModelRaw, "changed-model")
            XCTAssertEqual(changedConfig.defaultReasoningEffortRaw, "low")

            var unforkable = run
            unforkable.canForkCurrentSession = false
            XCTAssertNil(fixture.row(for: cutoff, runInteraction: unforkable).handoffConfig)

            try await config.performHandoff(AgentHandoffSelection(
                agent: .claudeCode,
                modelRaw: "submitted-model",
                reasoningEffortRaw: "high"
            ))
            let destination = try XCTUnwrap(
                fixture.vm.sessions.values.first { $0.pendingHandoff.sourceItemID == Row.conclusion1 },
                "the handoff creates a session whose cutoff is the row's item"
            )
            XCTAssertEqual(destination.selectedAgent, .claudeCode)
            XCTAssertEqual(destination.selectedModelRaw, "submitted-model")
            XCTAssertEqual(destination.selectedReasoningEffortRaw, "high")
            XCTAssertTrue(destination.items.contains { $0.text.contains("Run the tests") })
            XCTAssertFalse(destination.items.contains { $0.text.contains("LATERMARK") })
        }

        /// Login callbacks take part in row equality only through their owner and revision: re-created
        /// callbacks keep the row equal, and a new owner or revision delivers the replacement.
        func testLoginCallbackReplacementRequiresOwnerOrRevisionChange() async throws {
            let fixture = try await makeFixture(hosted: false)
            let calls = CallLog()
            let owner = NSObject()
            let otherOwner = NSObject()
            func action(_ owner: NSObject, revision: UInt64, _ label: String) -> CodexManagedLoginAction {
                CodexManagedLoginAction(
                    ownerID: ObjectIdentifier(owner),
                    revision: revision,
                    browser: { @MainActor _ in
                        calls.record("\(label) browser")
                        return true
                    },
                    deviceCode: { @MainActor _ in
                        calls.record("\(label) device code")
                        return true
                    }
                )
            }
            let loginError = fixture.item(Row.loginError)
            let original = fixture.row(for: loginError, login: action(owner, revision: 0, "original"))

            XCTAssertEqual(original, fixture.row(for: loginError, login: action(owner, revision: 0, "recreated")))
            let revised = fixture.row(for: loginError, login: action(owner, revision: 1, "revised"))
            XCTAssertNotEqual(original, revised)
            XCTAssertNotEqual(original, fixture.row(for: loginError, login: action(otherOwner, revision: 0, "other owner")))

            let authenticated = try await XCTUnwrap(revised.codexManagedLoginAction).browser { _ in }
            XCTAssertTrue(authenticated)
            XCTAssertEqual(calls.entries, ["revised browser"])

            XCTAssertTrue(AgentMessageBubble.offersCodexManagedLogin(for: loginError))
            XCTAssertFalse(AgentMessageBubble.offersCodexManagedLogin(for: fixture.item(Row.ordinaryError)))
        }

        // MARK: - Helpers

        private func makeFixture(hosted: Bool) async throws -> TranscriptFixture {
            let made = try await TranscriptFixture.make(hosted: hosted)
            fixture = made
            return made
        }

        private static func perfCounter(_ key: String) -> Int {
            let counters = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 1)["counters"] as? [String: Int]
            return counters?[key] ?? 0
        }
    }

    // MARK: - Rows

    /// The fixture transcript, in order. Turn 0 is history, turn 1 is the previous turn, and turn 2 is
    /// the running turn whose last row streams.
    private enum Row {
        /// A settled user message with a URL, so it renders a native text view.
        static let user0 = id(1)
        static let opener0 = id(2)
        /// Longer than ten lines and not recent, so it renders as a collapsed preview.
        static let longConclusion0 = id(3)
        static let user1 = id(4)
        static let bashCall = id(5)
        static let bashResult = id(6)
        static let ordinaryError = id(7)
        static let loginError = id(8)
        /// The previous turn's conclusion, recent while the run is active.
        static let conclusion1 = id(9)
        static let user2 = id(10)
        static let opener2 = id(11)
        static let tail = id(12)

        private static func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }
    }

    private enum Fixture {
        static let date = Date(timeIntervalSince1970: 1_800_000_000)
        static let bashInvocationID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        static var items: [AgentChatItem] {
            let longAnswer = "Older conclusion\n\n" + (1 ... 14).map { "Line \($0) of the older answer." }
                .joined(separator: "\n") + "\nCOLLAPSEMARK"
            let completedBash = BashToolResultParser.resultJSON(
                statusWord: "completed",
                command: "swift test",
                processID: nil,
                output: "initial output",
                exitCode: 0,
                summaryOnly: false
            )
            let rows: [(UUID, AgentChatItemKind, String)] = [
                (Row.user0, .user, "Review https://example.com/spec before changing the parser."),
                (Row.opener0, .assistant, "Reading the parser."),
                (Row.longConclusion0, .assistant, longAnswer),
                (Row.user1, .user, "Run the tests"),
                (Row.bashCall, .toolCall, ""),
                (Row.bashResult, .toolResult, ""),
                (Row.ordinaryError, .error, "Ordinary settled error"),
                (Row.loginError, .error, CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage),
                (Row.conclusion1, .assistant, "The tests ran."),
                (Row.user2, .user, "Now fix the parser LATERMARK"),
                (Row.opener2, .assistant, "Fixing the parser."),
                (Row.tail, .assistant, "Working on it")
            ]
            return rows.enumerated().map { index, row in
                let (id, kind, text) = row
                switch kind {
                case .toolCall:
                    return AgentChatItem(
                        id: id, timestamp: date, kind: .toolCall, text: "", toolName: "bash",
                        toolInvocationID: bashInvocationID, toolArgsJSON: "{\"command\":\"swift test\"}",
                        sequenceIndex: index
                    )
                case .toolResult:
                    return AgentChatItem(
                        id: id, timestamp: date, kind: .toolResult, text: "", toolName: "bash",
                        toolInvocationID: bashInvocationID, toolResultJSON: completedBash, toolIsError: false,
                        sequenceIndex: index
                    )
                default:
                    return AgentChatItem(
                        id: id, timestamp: date, kind: kind, text: text, sequenceIndex: index,
                        isStreaming: id == Row.tail
                    )
                }
            }
        }

        static var liveBashExecution: AgentModeViewModel.BashLiveExecutionState {
            AgentModeViewModel.BashLiveExecutionState(
                executionKey: "row-boundary-bash",
                transcriptItemID: Row.bashResult,
                toolName: "bash",
                invocationID: bashInvocationID,
                fallbackSignature: "row-boundary",
                processID: nil,
                command: "swift test",
                statusWord: "running",
                exitCode: nil,
                output: "live output",
                isSummaryOnly: false,
                lastSignalAt: date
            )
        }
    }

    // MARK: - Fixture

    /// A window state over an isolated runtime, with a running, hydrated session holding `Fixture.items`.
    /// When hosted, the production Agent Mode detail view renders in an unordered window with the probe
    /// recording and a test-controlled window focus.
    @MainActor
    private final class TranscriptFixture {
        let recorder = RenderRecorder()
        let toolCards = ToolCardStates()
        let focus = FocusFlag()
        let state: WindowState
        let session: AgentModeViewModel.TabSession
        let tabID: UUID
        private let runtime: MCPDomainRuntime
        private var hostedWindow: NSWindow?
        private var host: NSView?
        private var isClosed = false

        var vm: AgentModeViewModel {
            state.agentModeViewModel
        }

        var store: AgentTranscriptUIStore {
            vm.ui.transcript
        }

        var window: NSWindow {
            hostedWindow!
        }

        private init(runtime: MCPDomainRuntime, state: WindowState, session: AgentModeViewModel.TabSession, tabID: UUID) {
            self.runtime = runtime
            self.state = state
            self.session = session
            self.tabID = tabID
        }

        static func make(hosted: Bool) async throws -> TranscriptFixture {
            let storage = try XCTUnwrap(UserDefaults.standard.string(forKey: "GlobalCustomStorageURL"))
            let authorityRoot = URL(fileURLWithPath: storage).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: true)
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "transcript-row-boundary",
                storageDirectory: authorityRoot,
                eventDirectory: authorityRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: authorityRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            let state = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(state)
            let manager = state.workspaceManager
            await manager.awaitInitialized()
            let workspace = manager.createWorkspace(name: "Row boundary \(UUID().uuidString.prefix(8))", repoPaths: [], ephemeral: true)
            let switched = await manager.switchWorkspace(to: workspace, saveState: false, reason: "transcriptRowBoundaryTests")
            guard switched.didSwitch, let active = manager.activeWorkspace, let tabID = active.activeComposeTabID else {
                await shutDown(state, runtime: runtime)
                throw FixtureFailure("the fixture workspace did not activate")
            }
            state.promptManager.loadComposeTabsFromWorkspace(active, syncPromptText: true)
            let vm = state.agentModeViewModel
            vm.test_setCurrentTabIDOverride(tabID)
            let session = await vm.ensureSessionReady(tabID: tabID)
            let fixture = TranscriptFixture(runtime: runtime, state: state, session: session, tabID: tabID)
            guard vm.test_installPersistentSessionBinding(
                sessionID: UUID(),
                on: session,
                compareAndSetInWorkspaceID: active.id
            ) != nil else {
                await fixture.close()
                throw FixtureFailure("the fixture's persistent binding did not install")
            }
            session.markCurrentBindingHydrated()
            session.isTranscriptWindowExpanded = true
            session.runState = .running
            let items = Fixture.items
            session.replaceItems(items)
            session.nextSequenceIndex = items.count
            vm.refreshDerivedTranscriptState(for: session, reason: .liveMutation)
            vm.updateBindingsFromSession(session)
            if hosted {
                fixture.mountDetailView()
            }
            return fixture
        }

        private static func shutDown(_ state: WindowState, runtime: MCPDomainRuntime) async {
            state.beginClose()
            await state.tearDown()
            WindowStatesManager.shared.unregisterWindowState(state)
            _ = await runtime.shutdown()
        }

        private func mountDetailView() {
            let windowID = state.windowID
            let recorder = recorder
            AgentTranscriptTailRenderProbe.sink = { recorder.receive($0) }
            let detail = AgentModeDetailWithSidebarView(
                agentModeVM: vm,
                runtimeMetricsUI: vm.ui.runtimeMetrics,
                statusPillsUI: vm.ui.statusPills,
                contextBuilderAgentVM: state.contextBuilderAgentViewModel,
                oracleViewModel: state.oracleViewModel,
                promptManager: state.promptManager,
                workspaceSearchService: state.workspaceSearchService,
                selectionCoordinator: state.selectionCoordinator,
                stressHarness: nil,
                windowID: windowID,
                currentTabID: tabID,
                codexManagedLoginAction: CodexManagedLoginAction(
                    ownerID: ObjectIdentifier(self),
                    browser: { _ in false },
                    deviceCode: { _ in false }
                )
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let host = NSHostingView(rootView: HostRoot(detail: detail, focus: focus, toolCards: toolCards, windowID: windowID))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            hostedWindow = window
            self.host = host
        }

        func close() async {
            guard !isClosed else { return }
            isClosed = true
            AgentTranscriptTailRenderProbe.sink = nil
            session.assistantDeltaFlushTask?.cancel()
            session.assistantDeltaFlushTask = nil
            session.pendingAssistantDelta = ""
            vm.removePendingUIRefresh(for: tabID)
            hostedWindow?.contentView = nil
            hostedWindow?.close()
            hostedWindow = nil
            host = nil
            await Self.shutDown(state, runtime: runtime)
        }

        // MARK: Rows

        func item(_ id: UUID) -> AgentChatItem {
            session.items.first { $0.id == id }!
        }

        func row(
            for item: AgentChatItem,
            cancelRunID: UUID? = nil,
            runInteraction: AgentRunInteractionUISnapshot = .empty,
            login: CodexManagedLoginAction? = nil,
            agentModeVM: AgentModeViewModel? = nil
        ) -> AgentTranscriptRow {
            AgentTranscriptRow(
                inputs: AgentTranscriptRowInputs(
                    item: item,
                    isMostRecentEditBubble: false,
                    windowID: state.windowID,
                    workspaceID: state.workspaceManager.activeWorkspaceID,
                    tabID: tabID,
                    suppressAskUserTranscriptUI: false,
                    activeContextBuilderCallID: nil,
                    activeContextBuilderResultID: nil,
                    rawToolResultPayload: nil,
                    rawToolResultPayloadRenderRevision: 0,
                    cancelRunID: cancelRunID,
                    runInteraction: runInteraction,
                    runtimeFooter: nil,
                    autoExpandEnabled: true,
                    liveBashExecution: nil,
                    isRecentAssistant: false,
                    approvalVisible: false
                ),
                agentModeVM: agentModeVM ?? vm,
                promptManager: state.promptManager,
                contextBuilderAgentVM: state.contextBuilderAgentViewModel,
                codexManagedLoginAction: login
            )
        }

        func attachedViews(_ rowID: UUID) -> [CodeBlockTextView] {
            recorder.attachedViews(for: rowID, in: window)
        }

        func rowText(_ rowID: UUID, contains marker: String) -> Bool {
            attachedViews(rowID).contains { $0.string.contains(marker) }
        }

        /// The settled user row's native text view, once it's attached and laid out.
        func settledUserView() async throws -> CodeBlockTextView {
            try await waitUntil("the settled user row renders a native text view") {
                attachedViews(Row.user0).contains { $0.string.contains("example.com") && $0.frame.width > 1 }
            }
            return try XCTUnwrap(attachedViews(Row.user0).first { $0.string.contains("example.com") })
        }

        // MARK: Changes

        /// Sends one delta through the Codex coordinator and returns the tail text it should produce.
        func streamTailDelta(_ delta: String) -> String {
            let existing = session.items.last?.text ?? ""
            let coordinator = vm.test_codexCoordinator
            coordinator.test_enqueueAssistantDelta(delta, session: session)
            coordinator.test_flushPendingAssistantDelta(session)
            return existing + CodexProviderHelpers.normalizedAssistantDeltaForAppend(existingText: existing, delta: delta)
        }

        func mutateSource(_ rowID: UUID, _ change: (inout AgentChatItem) -> Void) {
            guard let index = session.items.firstIndex(where: { $0.id == rowID }) else { return }
            session.mutateItem(at: index, change)
            vm.refreshDerivedTranscriptState(for: session, reason: .liveMutation)
            vm.updateBindingsFromSession(session)
        }

        /// Gives a row a live runtime footer through the session, so view-model publications keep it.
        func setRuntimeFooter(_ rowID: UUID, statusText: String) {
            session.agentMessageRuntimeFootersByItemID[rowID] = AgentMessageRuntimeFooter(
                itemID: rowID,
                anchorDate: Fixture.date,
                completedDate: nil,
                statusText: statusText
            )
            vm.updateBindingsFromSession(session)
        }

        func publish(_ change: (inout AgentTranscriptUISnapshot) -> Void) {
            var snapshot = store.snapshot
            change(&snapshot)
            store.update(snapshot)
        }

        // MARK: Waiting

        func waitUntil(_ gate: String, seconds: Double = 10, _ ready: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                host?.layoutSubtreeIfNeeded()
                if ready() {
                    return
                }
                // Services the run loop between readiness checks; only a passing check ends the wait.
                try await Task.sleep(for: .milliseconds(20))
            }
            throw FixtureFailure("timed out waiting until \(gate)")
        }

        /// Waits until the probe has been silent for two turns and 0.22 seconds.
        func waitForQuiet() async throws {
            var serial = recorder.serial
            var lastChange = ProcessInfo.processInfo.systemUptime
            var quietTurns = 0
            try await waitUntil("render quiet window") {
                let now = ProcessInfo.processInfo.systemUptime
                if recorder.serial != serial {
                    serial = recorder.serial
                    lastChange = now
                    quietTurns = 0
                    return false
                }
                quietTurns += 1
                return quietTurns >= 2 && now - lastChange >= 0.22
            }
        }

        /// Applies one change and checks that the given rows re-render to reach the expected state, and
        /// that no other row re-renders unless the change re-projected its item. (A derived refresh can
        /// re-project the streaming tail as no longer streaming.)
        func expectReRenderedRows(
            _ rows: Set<UUID>,
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            change: () -> Void,
            until reached: () -> Bool
        ) async throws {
            let itemsBefore = Dictionary(uniqueKeysWithValues: store.snapshot.presentation.visibleRows.map { ($0.id, $0) })
            recorder.resetCounts()
            change()
            try await waitUntil(label, reached)
            try await waitForQuiet()
            let reprojected = Set(store.snapshot.presentation.visibleRows.filter { item in
                itemsBefore[item.id].map { $0 != item } ?? true
            }.map(\.id))
            let reRendered = Set(recorder.bodies.keys)
            XCTAssertTrue(rows.isSubset(of: reRendered), "\(label): the changed rows must re-render", file: file, line: line)
            XCTAssertEqual(
                reRendered.subtracting(reprojected).union(rows),
                rows,
                "\(label): unchanged rows re-rendered",
                file: file,
                line: line
            )
        }
    }

    private struct FixtureFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// The hosted root. The window starts unfocused, so footer timers stay out of the counts until a
    /// test focuses it.
    private struct HostRoot: View {
        let detail: AgentModeDetailWithSidebarView
        @ObservedObject var focus: FocusFlag
        let toolCards: ToolCardStates
        let windowID: Int

        var body: some View {
            detail
                .environment(\.agentWindowIsFocused, focus.isFocused)
                .environment(\.agentTranscriptProbeWindowID, windowID)
                .onPreferenceChange(AgentToolCardRenderStatePreferenceKey.self) { states in
                    MainActor.assumeIsolated { toolCards.states = states }
                }
        }
    }

    @MainActor
    private final class FocusFlag: ObservableObject {
        @Published var isFocused = false
    }

    @MainActor
    private final class ToolCardStates {
        var states: [UUID: AgentToolCardRenderState] = [:]
    }

    @MainActor
    private final class CallLog {
        private(set) var entries: [String] = []

        func record(_ entry: String) {
            entries.append(entry)
        }
    }

    @MainActor
    private final class PublicationCounter {
        private(set) var count = 0
        private var cancellable: AnyCancellable?

        init(_ store: AgentTranscriptUIStore) {
            cancellable = store.$snapshot.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.count += 1 }
            }
        }
    }

    /// Counts bubble bodies and native text-view updates per row, and remembers each row's latest
    /// runtime-footer status. Native views are attributed to rows when they first report with a row scope.
    @MainActor
    private final class RenderRecorder {
        private final class Witness {
            weak var view: CodeBlockTextView?
            let rowID: UUID

            init(view: CodeBlockTextView, rowID: UUID) {
                self.view = view
                self.rowID = rowID
            }
        }

        private(set) var serial = 0
        private(set) var bodies: [UUID: Int] = [:]
        private(set) var nativeUpdates: [UUID: Int] = [:]
        private(set) var footerTexts: [UUID: String] = [:]
        private var witnesses: [ObjectIdentifier: Witness] = [:]

        func receive(_ event: AgentTranscriptTailRenderProbe.Event) {
            serial &+= 1
            switch event {
            case let .body(id, _):
                bodies[id, default: 0] += 1
            case let .footer(id?, text):
                footerTexts[id] = text
            case let .native(boundary, scope, view):
                let key = ObjectIdentifier(view)
                if let scope {
                    witnesses[key] = Witness(view: view, rowID: scope)
                }
                if boundary == .update, let witness = witnesses[key], witness.view === view {
                    nativeUpdates[witness.rowID, default: 0] += 1
                }
            case .block, .footer(nil, _), .markdownCompile:
                break
            }
        }

        func resetCounts() {
            bodies = [:]
            nativeUpdates = [:]
        }

        func attachedViews(for rowID: UUID, in window: NSWindow) -> [CodeBlockTextView] {
            witnesses.values.compactMap { witness in
                guard witness.rowID == rowID, let view = witness.view, view.window === window else { return nil }
                return view
            }
        }
    }

    private extension CodeBlockTextView {
        var firstFontSize: CGFloat? {
            guard let storage = textStorage, storage.length > 0 else { return nil }
            return (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        }
    }

    private extension AgentTranscriptPresentationSnapshot {
        /// A copy at the next revision whose metadata also marks `itemID` as a recent assistant row.
        func addingRecentAssistant(_ itemID: UUID) -> AgentTranscriptPresentationSnapshot {
            AgentTranscriptPresentationSnapshot(
                tabID: tabID,
                revision: revision + 1,
                visibleBlocks: visibleBlocks,
                workingBlocks: workingBlocks,
                visibleRows: visibleRows,
                workingRows: workingRows,
                rowAnchorIndex: rowAnchorIndex,
                anchorBlockIndex: anchorBlockIndex,
                archivedHistoryState: archivedHistoryState,
                isCompressedHistoryRevealed: isCompressedHistoryRevealed,
                isTranscriptWindowExpanded: isTranscriptWindowExpanded,
                isWindowCappedWhileActive: isWindowCappedWhileActive,
                bindingsHydrated: bindingsHydrated,
                hydratedPersistentBinding: hydratedPersistentBinding,
                hydratedBindingTransitionGeneration: hydratedBindingTransitionGeneration,
                performanceSnapshot: performanceSnapshot,
                metadata: AgentTranscriptPresentationMetadata(
                    latestUserMessageID: metadata.latestUserMessageID,
                    latestTurnID: metadata.latestTurnID,
                    dynamicSummaryLockTargetTurnID: metadata.dynamicSummaryLockTargetTurnID,
                    recentAssistantItemIDs: metadata.recentAssistantItemIDs.union([itemID]),
                    activeContextBuilderCallItemID: metadata.activeContextBuilderCallItemID,
                    activeContextBuilderResultItemID: metadata.activeContextBuilderResultItemID,
                    mostRecentEditItemID: metadata.mostRecentEditItemID
                ),
                rawToolResultPayloadRenderRevisionByItemID: rawToolResultPayloadRenderRevisionByItemID
            )
        }
    }
#endif
