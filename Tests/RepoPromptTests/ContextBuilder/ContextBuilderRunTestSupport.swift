import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// One window with a multi-tab workspace whose own Context Builder view model gets its providers
    /// from the fixture. The window is built on the domain runtime, as production windows are,
    /// because a child's prompt and selection writes are only authorized against a published domain
    /// routing binding.
    ///
    /// By default every run gets a ``ContextBuilderProviderChild``, which opens the run's child MCP
    /// connection from its own process family, so pending-policy admission, run-to-connection
    /// mapping, nested tool calls, and the final-context commit all go through production routing.
    @MainActor
    final class ContextBuilderRunFixture {
        typealias Completion = ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion
        typealias OperationToken = ContextBuilderAgentViewModel.TabSession.OperationToken

        struct TabSlot: Equatable {
            let name: String
            let tabID: UUID
            let fileURL: URL

            var promptText: String {
                "Instructions written by the \(name) tab's child"
            }

            var agentOutput: String {
                "Discovery output for the \(name) tab"
            }

            /// What the tab holds before any run, in a fixture made with seeded tabs.
            var seededPromptText: String {
                "Instructions the \(name) tab held before any run"
            }

            var seededFileURL: URL {
                fileURL.deletingLastPathComponent().appendingPathComponent("\(name.capitalized)Seeded.swift")
            }
        }

        /// What the window asked its provider factory for.
        struct ProviderRequest: Equatable {
            let agentKind: AgentProviderKind
            let modelString: String?
            let workspacePath: String?
            let modelParameterSelections: [ACPModelParameterSelection]
        }

        /// A run started on the view model the way the `context_builder` tool starts one: claim the
        /// tab, run discovery, release the claim.
        @MainActor
        final class MCPRun {
            let slot: TabSlot
            fileprivate(set) var result: Result<Completion, Error>?
            /// How discovery ended, set before the claim's release begins. `result` is set only
            /// once that release has returned.
            fileprivate(set) var discoveryResult: Result<Completion, Error>?
            /// How the follow-up the run was started with ended, once it has.
            fileprivate(set) var followUpResult: Result<ChatSendReply, Error>?
            fileprivate var task: Task<Void, Never>?

            fileprivate init(slot: TabSlot) {
                self.slot = slot
            }
        }

        /// Ends the scenario after its cause was recorded as a test failure.
        struct ScenarioAborted: Error {}

        /// A model the Oracle treats as available whatever providers the machine has configured.
        static let followUpModel = AIModel.openaiCustom(name: "context-builder-run-fixture")

        let manager = ServerNetworkManager.shared
        let window: WindowState
        let workspaceID: UUID
        let rootURL: URL
        let slots: [TabSlot]
        /// What the window's Oracle gets back for the prompts it sends to a provider.
        let oracleReplies: ContextBuilderOracleReplies

        /// Supplies the provider for a request. Returning nil gives the run a routed child.
        var providerScript: ((ProviderRequest) -> HeadlessAgentProvider?)?
        /// Whether a new child waits for ``ContextBuilderProviderChild/allowConnection()`` before
        /// it connects.
        var holdsChildConnections = false
        /// Whether a new child's disposal waits for ``ContextBuilderProviderChild/allowDisposal()``
        /// before its process family ends.
        var holdsChildDisposal = false
        /// Whether a new child, once connected, waits for ``ContextBuilderProviderChild/allowTurn()``
        /// before it makes its turn's tool calls.
        var holdsChildTurns = false
        /// What a new child does on its run's tab once connected.
        var childWrites = ContextBuilderProviderChild.Writes()
        /// When set, an MCP-origin run the fixture starts lets its child ask clarifying questions,
        /// each of which times out after this long.
        var clarifyingQuestionTimeoutSeconds: TimeInterval?

        private(set) var providerRequests: [ProviderRequest] = []
        private(set) var children: [ContextBuilderProviderChild] = []
        private(set) var runIDsByTabID: [UUID: UUID] = [:]
        private var mcpRuns: [MCPRun] = []
        private var holdReleases: [@MainActor () async -> Void] = []
        private let chatStorage: ChatStorageRedirect

        var viewModel: ContextBuilderAgentViewModel {
            window.contextBuilderAgentViewModel
        }

        private init(
            window: WindowState,
            workspaceID: UUID,
            rootURL: URL,
            slots: [TabSlot],
            oracleReplies: ContextBuilderOracleReplies,
            chatStorage: ChatStorageRedirect
        ) {
            self.window = window
            self.workspaceID = workspaceID
            self.rootURL = rootURL
            self.slots = slots
            self.oracleReplies = oracleReplies
            self.chatStorage = chatStorage
        }

        /// Runs `scenario` on a fresh fixture inside the shared MCP server lease. The fixture
        /// registers its cleanup first, so every cleanup the scenario adds runs before it.
        /// With `seedsTabs`, every tab starts with its slot's seeded prompt and selection instead of
        /// empty.
        ///
        /// Nothing may hold the fixture once its cleanup has run: a fixture that stays alive keeps
        /// its window, and the services that window owns, for the rest of the test process. A
        /// closure stored on the fixture has to capture it unowned.
        static func withFixture(
            tabNames: [String] = ["first", "second"],
            seedsTabs: Bool = false,
            _ scenario: @MainActor (ContextBuilderRunFixture, FixtureCleanup) async throws -> Void
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let cleanup = FixtureCleanup()
                weak var settledFixture: ContextBuilderRunFixture?
                try await cleanup.perform(operation: {
                    let fixture = try await make(cleanup: cleanup, tabNames: tabNames, seedsTabs: seedsTabs)
                    settledFixture = fixture
                    try await scenario(fixture, cleanup)
                }, afterCleanup: {
                    XCTAssertNil(settledFixture, "The fixture is still held after its cleanup")
                })
            }
        }

        static func make(
            cleanup: FixtureCleanup,
            tabNames: [String] = ["first", "second"],
            seedsTabs: Bool = false
        ) async throws -> ContextBuilderRunFixture {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()

            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderRunFixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            cleanup.add { try? FileManager.default.removeItem(at: rootURL) }
            // Registered ahead of every window's cleanup, so chat storage is put back only once
            // each window that could save a chat has been torn down.
            let chatStorage = ChatStorageRedirect()
            cleanup.add { await chatStorage.restore() }
            let slots = try tabNames.map { name in
                let fileURL = rootURL.appendingPathComponent("\(name.capitalized).swift")
                try "// \(name)\n".write(to: fileURL, atomically: true, encoding: .utf8)
                return TabSlot(name: name, tabID: UUID(), fileURL: fileURL)
            }

            if seedsTabs {
                for slot in slots {
                    try "// \(slot.name), seeded\n".write(to: slot.seededFileURL, atomically: true, encoding: .utf8)
                }
            }

            var workspace = WorkspaceModel(name: "Context Builder runs", repoPaths: [rootURL.path])
            workspace.isEphemeral = true
            workspace.composeTabs = slots.map { slot in
                guard seedsTabs else { return ComposeTabState(id: slot.tabID, name: slot.name) }
                return ComposeTabState(
                    id: slot.tabID,
                    name: slot.name,
                    selection: StoredSelection(selectedPaths: [slot.seededFileURL.path]),
                    promptText: slot.seededPromptText
                )
            }
            workspace.activeComposeTabID = slots[0].tabID
            let fixture = try await open(
                workspace,
                rootURL: rootURL,
                slots: slots,
                chatStorage: chatStorage,
                cleanup: cleanup
            )

            let manager = ServerNetworkManager.shared
            let previousApproval = await manager.debugReplaceConnectionApprovalHandlerForTesting { _, _ in true }
            cleanup.add {
                _ = await manager.debugReplaceConnectionApprovalHandlerForTesting(previousApproval)
            }
            cleanup.add { await fixture.settleRuns() }
            return fixture
        }

        /// Opens the fixture's workspace in a second window, as a second app window on an open
        /// workspace does: the window loads the same stored tabs under the same IDs into a workspace
        /// manager, a Context Builder view model, and an MCP server of its own, and is registered
        /// with the window manager beside the first.
        func openPeerWindow(cleanup: FixtureCleanup) async throws -> ContextBuilderRunFixture {
            let workspace = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == workspaceID })
            let peer = try await Self.open(
                workspace,
                rootURL: rootURL,
                slots: slots,
                chatStorage: chatStorage,
                cleanup: cleanup
            )
            cleanup.add { await peer.settleRuns() }
            return peer
        }

        /// A registered window showing `workspace`, whose providers come from the fixture returned
        /// for it.
        private static func open(
            _ workspace: WorkspaceModel,
            rootURL: URL,
            slots: [TabSlot],
            chatStorage: ChatStorageRedirect,
            cleanup: FixtureCleanup
        ) async throws -> ContextBuilderRunFixture {
            let providers = ProviderSource()
            let oracleReplies = ContextBuilderOracleReplies()
            let domainRuntime = AppDomainRuntimeComposition.shared.runtime
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState(
                domainRuntime: domainRuntime,
                contextBuilderProviderFactory: { agentKind, modelString, workspacePath, modelParameterSelections in
                    providers.makeProvider(ProviderRequest(
                        agentKind: agentKind,
                        modelString: modelString,
                        workspacePath: workspacePath,
                        modelParameterSelections: modelParameterSelections
                    ))
                },
                aiQueriesServiceFactory: { keyManager in
                    AIQueriesService(keyManager: keyManager, sendPromptOverride: { message, _ in
                        await oracleReplies.open(
                            userPrompt: message.conversationMessages.last { $0.role == .user }?.content ?? "",
                            fileBlocks: message.fileBlocks
                        )
                    })
                }
            )
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            let workspaceID = workspace.id
            var loadedRootID: UUID?
            cleanup.add {
                _ = await window.mcpServer.setWindowToolsEnabled(false)
                window.beginClose()
                await window.tearDown()
                if let loadedRootID {
                    await window.workspaceFileContextStore.unloadRoot(id: loadedRootID)
                }
                window.workspaceManager.workspaces.removeAll { $0.id == workspaceID }
                // The window's Oracle saves a chat only for a workspace its manager holds, so it
                // starts no save from here on, and the saves drained here are its last.
                await window.oracleViewModel.drainTrackedAutosaves(for: workspaceID)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            WindowStatesManager.shared.registerWindowState(window)
            await window.workspaceManager.awaitInitialized()
            window.workspaceManager.workspaces.append(workspace)
            loadedRootID = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: rootURL.path
            ).id
            _ = try await DomainWorkspaceAuthorityClient(store: domainRuntime.workspaceStore, windowID: window.windowID)
                .registerForRead(workspace, fileURL: rootURL.appendingPathComponent("fixture.repoprompt-workspace"))
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderRunFixture"
            )
            window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)

            let fixture = ContextBuilderRunFixture(
                window: window,
                workspaceID: workspaceID,
                rootURL: rootURL,
                slots: slots,
                oracleReplies: oracleReplies,
                chatStorage: chatStorage
            )
            providers.fixture = fixture
            chatStorage.windows.append(fixture)
            cleanup.add { await oracleReplies.finishAll() }
            return fixture
        }

        // MARK: Starting runs

        /// The frozen inputs the `context_builder` tool resolves for a run on `slot`.
        func mcpAuthority(
            for slot: TabSlot,
            agentKind: AgentProviderKind = .claudeCode,
            modelParameterSelections: [ACPModelParameterSelection] = [],
            providerWorkspacePath: String? = nil
        ) throws -> ContextBuilderResolvedRunAuthority {
            let identity = identity(of: slot)
            let tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
            var nested = MCPServerViewModel.TabContextSnapshot(
                tabID: slot.tabID,
                windowID: window.windowID,
                workspaceID: workspaceID,
                promptText: tab.promptText,
                selection: tab.selection,
                selectionRevision: window.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspaceID,
                    tabID: slot.tabID
                ),
                selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
                selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
                tabName: tab.name,
                runID: nil,
                explicitlyBound: true
            )
            nested.frozenLookupContext = .visibleWorkspace
            return ContextBuilderResolvedRunAuthority(
                configuration: ContextBuilderMCPRunConfiguration(
                    identity: identity,
                    nestedTabContext: nested,
                    providerWorkspacePath: providerWorkspacePath ?? rootURL.path,
                    runBehavior: ContextBuilderRunBehavior(
                        tokenBudget: 1000,
                        enhancementMode: .preserve,
                        questionTimeoutSeconds: clarifyingQuestionTimeoutSeconds ?? 1,
                        allowClarifyingQuestions: clarifyingQuestionTimeoutSeconds != nil,
                        automaticFollowUp: nil
                    ),
                    responseType: nil,
                    planningModelRaw: nil,
                    isSystemWorkspace: false
                ),
                agentKind: agentKind,
                modelRaw: AgentModel.defaultModel.rawValue,
                modelParameterSelections: modelParameterSelections
            )
        }

        /// Starts an MCP-origin run on `slot` without waiting for it. With `followUp`, a run that
        /// completes goes on, still under its claim, to generate that follow-up from the tab it
        /// committed, as the `context_builder` tool does for a response type.
        @discardableResult
        func startMCPRun(
            on slot: TabSlot,
            agentKind: AgentProviderKind = .claudeCode,
            modelParameterSelections: [ACPModelParameterSelection] = [],
            providerWorkspacePath: String? = nil,
            followUp: HeadlessMode? = nil,
            progressReporter: ContextBuilderMCPProgressReporter? = nil
        ) -> MCPRun {
            let run = MCPRun(slot: slot)
            mcpRuns.append(run)
            run.task = Task { @MainActor in
                do {
                    let viewModel = self.viewModel
                    let authority = try self.mcpAuthority(
                        for: slot,
                        agentKind: agentKind,
                        modelParameterSelections: modelParameterSelections,
                        providerWorkspacePath: providerWorkspacePath
                    )
                    let token = try viewModel.beginMCPControlledRun(
                        forTabID: slot.tabID,
                        workspaceID: self.workspaceID,
                        responseType: nil,
                        planModelName: nil
                    )
                    run.result = try await .success(AsyncScope.withCleanup({}, cleanup: {
                        await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: token)
                    }) {
                        let completion: Completion
                        do {
                            completion = try await viewModel.runContextBuilderForMCP(
                                authority: authority,
                                mcpControlToken: token,
                                progressReporter: progressReporter
                            )
                            run.discoveryResult = .success(completion)
                        } catch {
                            run.discoveryResult = .failure(error)
                            throw error
                        }
                        if let followUp,
                           completion.terminalDisposition == .completed,
                           let committed = completion.committedTab
                        {
                            do {
                                run.followUpResult = try await .success(viewModel.runMCPPlanOrQuestion(
                                    for: committed.identity,
                                    oracleViewModel: self.window.oracleViewModel,
                                    mode: followUp,
                                    prompt: committed.tab.promptText,
                                    selection: committed.tab.selection,
                                    reviewGitContext: .automaticOnly()
                                ))
                            } catch {
                                run.followUpResult = .failure(error)
                            }
                        }
                        return completion
                    })
                } catch {
                    run.result = .failure(error)
                }
            }
            return run
        }

        // MARK: Calling the tool

        /// Starts the window's MCP server, so that caller connections can reach its tools.
        func startWindowServer() async {
            await window.mcpServer.startServer()
            XCTAssertTrue(window.mcpServer.windowToolsEnabled)
            await manager.setEnabled(true)
        }

        /// An external client connection, admitted for protected calls as this process.
        func connectCaller(_ label: String, cleanup: FixtureCleanup) async throws -> PersistentMCPTestEndpoint {
            let manager = manager
            let server = window.mcpServer
            let caller = try await PersistentMCPTestEndpoint.make(
                label: label,
                networkManager: manager,
                clientName: "context-builder-caller-\(label)-\(UUID().uuidString)",
                requiredToolNames: [MCPWindowToolName.contextBuilder, MCPWindowToolName.readFile, "bind_context"]
            )
            cleanup.add {
                await manager.debugSetDomainPeerIdentityForTesting(connectionID: caller.connectionID, identity: nil)
                caller.client.close()
                await caller.connectionManager.stop()
                await manager.debugRemoveConnection(caller.connectionID)
                await manager.clearClientConnectionPolicy(for: caller.clientName)
                await manager.debugClearPersistedRoutingState(for: caller.clientName)
                server.removeTabContext(
                    forConnectionID: caller.connectionID,
                    clientName: caller.clientName,
                    windowID: nil,
                    runID: nil
                )
            }
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: caller.connectionID,
                identity: .verified(
                    processID: Int(getpid()),
                    fingerprint: "test:verified:context-builder-caller"
                )
            )
            return caller
        }

        /// Makes a completed UI run start its automatic follow-up.
        func enableAutomaticFollowUp(cleanup: FixtureCleanup) {
            let store = GlobalSettingsStore.shared
            let previous = store.contextBuilderBehaviorSettings()
            cleanup.add { store.setContextBuilderBehaviorSettings(previous, commit: false) }
            var settings = previous
            settings.followUpAnalysisEnabled = true
            store.setContextBuilderBehaviorSettings(settings, commit: false)
        }

        /// Makes ``followUpModel`` the model a UI follow-up sends with, for this window only and
        /// without writing it to settings.
        func useFollowUpModelForUIFollowUps(cleanup: FixtureCleanup) {
            let promptManager = window.promptManager
            cleanup.add { promptManager.restorePreferredModelForSession(nil) }
            promptManager.restorePreferredModelForSession(Self.followUpModel.rawValue)
        }

        /// Keeps the chats a scenario saves in a directory of its own. The fixture puts chat
        /// storage back and removes the directory at the end of its own cleanup, after every
        /// cleanup the scenario adds.
        func saveChatsInTemporaryDirectory() async throws {
            XCTAssertNil(chatStorage.directory, "Chat storage is redirected once for a fixture")
            let chatsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderRunFixture-chats-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsURL, withIntermediateDirectories: true)
            chatStorage.directory = chatsURL
            await ChatDataService.test_setWorkspaceRootOverride(chatsURL)
        }

        /// What could still save one of this window's chats, as reasons. Empty once the window's
        /// cleanup has run.
        fileprivate func pendingChatWriters() async -> [String] {
            var reasons: [String] = []
            if !viewModel.tabsWithActivePlanGeneration.isEmpty {
                reasons.append("a follow-up was still generating")
            }
            if mcpRuns.contains(where: { $0.result == nil }) {
                reasons.append("a run the fixture started had not ended")
            }
            if await !oracleReplies.hasEndedEveryReply {
                reasons.append("a provider reply was still pending")
            }
            if window.workspaceManager.isChatBusy {
                reasons.append("a chat was still streaming")
            }
            if window.workspaceManager.workspaces.contains(where: { $0.id == workspaceID }) {
                reasons.append("a window could still save a chat")
            }
            return reasons
        }

        /// The `index`th prompt the window's Oracle sent to a provider, once it has been sent.
        func oracleRequest(
            _ index: Int,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> ContextBuilderOracleReplies.Request {
            try await waitFor(
                "the Oracle to send prompt \(index + 1) to its provider",
                allowingRunErrors: true,
                file: file,
                line: line
            ) {
                await self.oracleReplies.requests.count > index
            }
            return await oracleReplies.requests[index]
        }

        /// Lets the `context_builder` tool resolve a run's agent and model in this window
        /// whatever providers the machine has: Cursor is reported connected and verified, which
        /// makes a selection available without running provider validation.
        func makeRunAuthorityResolvable(cleanup: FixtureCleanup) {
            let settings = window.apiSettingsViewModel
            let wasConnected = settings.isCursorConnected
            let wasComplete = settings.isContextBuilderProviderValidationComplete
            let verifiedProviders = settings.contextBuilderVerifiedCLIProviders
            cleanup.add {
                settings.isCursorConnected = wasConnected
                if wasComplete {
                    settings.test_completeContextBuilderProviderValidation(verifiedProviders: verifiedProviders)
                } else {
                    settings.test_resetContextBuilderProviderValidation()
                }
            }
            settings.isCursorConnected = true
            settings.test_completeContextBuilderProviderValidation(verifiedProviders: [.cursor])
        }

        /// Shows `slot` and presses Run, as the Context Builder panel does. Returns the run the
        /// press started, or nil when it was ignored.
        @discardableResult
        func pressRun(on slot: TabSlot) async -> UUID? {
            await window.promptManager.switchComposeTab(slot.tabID)
            let previousRunID = viewModel.activeRunIDForTesting(tabID: slot.tabID)
            viewModel.runContextBuilderAgent()
            noteRegisteredRunIDs()
            let runID = viewModel.activeRunIDForTesting(tabID: slot.tabID)
            return runID == previousRunID ? nil : runID
        }

        /// Registers a hold that ``settleRuns()`` releases when a scenario ends early.
        func releaseOnSettle(_ release: @escaping @MainActor () async -> Void) {
            holdReleases.append(release)
        }

        // MARK: Reading state

        func identity(of slot: TabSlot) -> WorkspaceSelectionIdentity {
            WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: slot.tabID)
        }

        func session(_ slot: TabSlot) -> ContextBuilderAgentViewModel.TabSession? {
            viewModel.sessions[slot.tabID]
        }

        func operationToken(_ slot: TabSlot) -> OperationToken? {
            session(slot)?.operationToken
        }

        func activeRunID(_ slot: TabSlot) -> UUID? {
            viewModel.activeRunIDForTesting(tabID: slot.tabID)
        }

        func storedTab(_ slot: TabSlot) -> ComposeTabState? {
            window.workspaceManager.composeTab(for: identity(of: slot))
        }

        /// The tabs the fixture's workspace holds, in order.
        var storedTabIDs: [UUID] {
            window.workspaceManager.workspaces.first { $0.id == workspaceID }?.composeTabs.map(\.id) ?? []
        }

        func slot(forRunID runID: UUID) throws -> TabSlot {
            noteRegisteredRunIDs()
            return try XCTUnwrap(slots.first { runIDsByTabID[$0.tabID] == runID })
        }

        func child(forRunID runID: UUID?) -> ContextBuilderProviderChild? {
            guard let runID else { return nil }
            return children.first { $0.runID == runID }
        }

        /// The run registered on `slot`, once there is one.
        func registeredRunID(
            on slot: TabSlot,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> UUID {
            try await waitFor("the \(slot.name) tab's run to be registered", file: file, line: line) {
                self.activeRunID(slot) != nil
            }
            return try XCTUnwrap(activeRunID(slot), file: file, line: line)
        }

        /// The routed child of `runID`, once its provider has registered a process for the run.
        func childWithRegisteredProcess(
            forRunID runID: UUID,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> ContextBuilderProviderChild {
            try await waitFor("the run's provider to register its process", file: file, line: line) {
                self.child(forRunID: runID)?.registeredProviderPID != nil
            }
            return try XCTUnwrap(child(forRunID: runID), file: file, line: line)
        }

        /// The unconsumed pending policies `clientName` holds for the fixture's runs, oldest first.
        func pendingPolicyRunIDs(
            clientName: String? = AgentProviderKind.claudeCode.mcpClientNameHint
        ) async throws -> [UUID] {
            noteRegisteredRunIDs()
            let runIDs = Set(runIDsByTabID.values).union(children.compactMap(\.runID))
            return try await manager.debugPendingPolicySnapshot(for: XCTUnwrap(clientName))
                .compactMap(\.runID)
                .filter(runIDs.contains)
        }

        /// The reasons the app recorded for refusing a connection to `runID`, oldest first.
        func connectionRefusalReasons(forRunID runID: UUID) async -> [String] {
            await routingEvents(forRunID: runID).compactMap { event in
                guard event["event"] as? String == "policy_rejected" else { return nil }
                return (event["fields"] as? [String: String])?["reason"]
            }
        }

        /// The names of the routing events the app recorded for `runID`, oldest first.
        func routingEventNames(forRunID runID: UUID) async -> [String] {
            await routingEvents(forRunID: runID).compactMap { $0["event"] as? String }
        }

        private func routingEvents(forRunID runID: UUID) async -> [[String: Any]] {
            let history = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 500)
            return history["events"] as? [[String: Any]] ?? []
        }

        // MARK: Waiting

        /// Polls `condition` until it holds. Fails and aborts at the deadline, and as soon as an
        /// MCP run ends in an error unless `allowingRunErrors`, naming each run's routing events so
        /// a stall shows its last boundary.
        func waitFor(
            _ expectation: String,
            allowingRunErrors: Bool = false,
            timeout: Duration = .seconds(30),
            file: StaticString = #filePath,
            line: UInt = #line,
            until condition: @MainActor () async -> Bool
        ) async throws {
            var runError: Error?
            let held = await poll(timeout: timeout) {
                self.noteRegisteredRunIDs()
                if !allowingRunErrors {
                    for case let .failure(error)? in self.mcpRuns.map(\.result) {
                        runError = error
                        return true
                    }
                }
                return await condition()
            }
            if let runError {
                XCTFail("A run ended in an error while waiting for \(expectation): \(runError)", file: file, line: line)
            } else if !held {
                let routingEvents = await routingEventSummary()
                XCTFail("Timed out waiting for \(expectation).\n\(routingEvents)", file: file, line: line)
            } else {
                return
            }
            throw ScenarioAborted()
        }

        func completion(
            of run: MCPRun,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> Completion {
            try await waitFor("the \(run.slot.name) tab's run to return", file: file, line: line) {
                run.result != nil
            }
            return try XCTUnwrap(run.result, file: file, line: line).get()
        }

        /// Waits until `slot` holds no operation token, which is when its last run and any
        /// follow-up that run owned have both settled.
        func waitForRelease(
            of slot: TabSlot,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            try await waitFor(
                "the \(slot.name) tab's operation token to be released",
                allowingRunErrors: true,
                file: file,
                line: line
            ) { self.operationToken(slot) == nil }
        }

        private func poll(timeout: Duration, until condition: @MainActor () async -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while true {
                if await condition() { return true }
                guard clock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        // MARK: Assertions

        /// The run completed with its own tab's exact committed prompt and selection, written over
        /// the connection its own child was admitted on.
        func assertCommitted(
            _ completion: Completion,
            by child: ContextBuilderProviderChild,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let runID = try XCTUnwrap(child.runID, file: file, line: line)
            let slot = try slot(forRunID: runID)
            XCTAssertEqual(completion.terminalDisposition, .completed, file: file, line: line)
            XCTAssertEqual(completion.runID, runID, file: file, line: line)
            XCTAssertEqual(completion.tabID, slot.tabID, file: file, line: line)
            XCTAssertEqual(completion.agentOutput, slot.agentOutput, file: file, line: line)
            XCTAssertEqual(
                child.admission,
                ContextBuilderProviderChild.Admission(
                    routedRunID: runID,
                    runConnectionID: child.connectionID,
                    boundTabID: slot.tabID
                ),
                file: file,
                line: line
            )
            let committed = try XCTUnwrap(completion.committedTab, file: file, line: line)
            XCTAssertEqual(committed.nestedRunID, runID, file: file, line: line)
            XCTAssertEqual(committed.identity, identity(of: slot), file: file, line: line)
            XCTAssertEqual(committed.tab.id, slot.tabID, file: file, line: line)
            XCTAssertEqual(committed.tab.promptText, slot.promptText, file: file, line: line)
            XCTAssertEqual(committed.tab.selection.selectedPaths, [slot.fileURL.path], file: file, line: line)
            XCTAssertFalse(committed.usedAgentOutputAsPrompt, file: file, line: line)
            assertStoredTabMatchesSlot(slot, file: file, line: line)
        }

        /// The tab's stored state is what its own child wrote.
        func assertStoredTabMatchesSlot(
            _ slot: TabSlot,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let stored = storedTab(slot)
            XCTAssertEqual(stored?.promptText, slot.promptText, file: file, line: line)
            XCTAssertEqual(stored?.selection.selectedPaths, [slot.fileURL.path], file: file, line: line)
        }

        // MARK: Providers and cleanup

        fileprivate func makeProvider(_ request: ProviderRequest) -> HeadlessAgentProvider {
            providerRequests.append(request)
            if let scripted = providerScript?(request) {
                return scripted
            }
            let child = ContextBuilderProviderChild(
                fixture: self,
                clientName: request.agentKind.mcpClientNameHint ?? request.agentKind.rawValue,
                waitsForConnectionRelease: holdsChildConnections,
                waitsForTurnRelease: holdsChildTurns,
                waitsForDisposalRelease: holdsChildDisposal,
                writes: childWrites
            )
            children.append(child)
            return ContextBuilderRoutedProvider(child: child)
        }

        /// A provider for `request` that starts its CLI twice inside one discovery turn. Its first
        /// process connects and makes no tool call; its second waits for
        /// ``ContextBuilderProviderChild/allowConnection()`` and then performs the turn.
        func makeRelaunchingProvider(for request: ProviderRequest) -> ContextBuilderRelaunchingProvider {
            let clientName = request.agentKind.mcpClientNameHint ?? request.agentKind.rawValue
            let firstProcess = ContextBuilderProviderChild(
                fixture: self,
                clientName: clientName,
                waitsForConnectionRelease: false,
                writes: ContextBuilderProviderChild.Writes(
                    setsPrompt: false,
                    setsSelection: false,
                    repliesWithOutput: false
                )
            )
            let relaunchedProcess = ContextBuilderProviderChild(
                fixture: self,
                clientName: clientName,
                waitsForConnectionRelease: true,
                writes: childWrites
            )
            children.append(contentsOf: [firstProcess, relaunchedProcess])
            let provider = ContextBuilderRelaunchingProvider(
                firstProcess: firstProcess,
                relaunchedProcess: relaunchedProcess
            )
            releaseOnSettle { await provider.exitFirstProcess() }
            return provider
        }

        /// A child that does the MCP work of a provider process the fixture did not start. The
        /// caller passes that process's helper to
        /// ``ContextBuilderProviderChild/serve(runID:asHelperPID:)``.
        func makeHelperChild(
            for agentKind: AgentProviderKind,
            writes: ContextBuilderProviderChild.Writes
        ) -> ContextBuilderProviderChild {
            let child = ContextBuilderProviderChild(
                fixture: self,
                clientName: agentKind.mcpClientNameHint ?? agentKind.rawValue,
                waitsForConnectionRelease: false,
                writes: writes
            )
            children.append(child)
            return child
        }

        private func noteRegisteredRunIDs() {
            for slot in slots {
                if let runID = viewModel.activeRunIDForTesting(tabID: slot.tabID) {
                    runIDsByTabID[slot.tabID] = runID
                }
            }
        }

        private func routingEventSummary() async -> String {
            var lines: [String] = []
            for slot in slots {
                guard let runID = runIDsByTabID[slot.tabID] else {
                    lines.append("\(slot.name) tab: no run registered")
                    continue
                }
                let events = await routingEventNames(forRunID: runID)
                lines.append("\(slot.name) tab run \(runID): \(events.joined(separator: " > "))")
            }
            return lines.joined(separator: "\n")
        }

        /// Releases every hold, cancels any run or follow-up still active, and removes the routing
        /// state the runs installed, so a failed expectation still leaves shared MCP state settled.
        private func settleRuns() async {
            for release in holdReleases {
                await release()
            }
            for child in children {
                await child.allowConnection()
                await child.allowTurn()
                await child.allowDisposal()
            }
            await viewModel.cancelAllActiveRuns()
            for run in mcpRuns {
                await run.task?.value
            }
            noteRegisteredRunIDs()
            let runIDs = Set(runIDsByTabID.values).union(children.compactMap(\.runID))
            _ = await poll(timeout: .seconds(10)) {
                runIDs.allSatisfy { !self.viewModel.isRunTeardownPendingForTesting(runID: $0) }
            }
            for child in children {
                await child.closeConnection()
                if let runID = child.runID {
                    await manager.clearClientConnectionPolicy(
                        for: child.clientName,
                        windowID: window.windowID,
                        runID: runID
                    )
                }
            }
            for runID in runIDs {
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await MCPRoutingWaiter.cleanup(runID: runID)
            }
            await manager.debugRemoveRoutingSessionsForTesting(Set(children.map(\.sessionToken)))
        }
    }

    /// The provider side of a fixture window's Oracle. The window's query service hands it every
    /// prompt the Oracle would send to a provider and gets back a stream that a test answers
    /// when it chooses, so a follow-up can be held with its reply pending and then completed.
    ///
    /// The provider pool, the API key lookup, the network, and the query service's own stream
    /// buffering and cancellation bookkeeping are not exercised.
    actor ContextBuilderOracleReplies {
        /// One prompt the Oracle sent: what it carried, and where its reply comes from.
        struct Request {
            let userPrompt: String
            let fileBlocks: [String]
            fileprivate let stream: OracleControlledStream

            /// Answers the prompt with `text` as a provider reply that completed.
            func complete(with text: String) async {
                await stream.yield(ChatStreamOutput(
                    text: text,
                    reasoning: nil,
                    tokens: ChatTokenInfo(),
                    terminalOutcome: .completed
                ))
                await stream.finish()
            }
        }

        private(set) var requests: [Request] = []
        /// Whether ``finishAll()`` has ended every reply and no prompt has been sent since.
        fileprivate private(set) var hasEndedEveryReply = false

        fileprivate func open(
            userPrompt: String,
            fileBlocks: [String]
        ) async -> (id: ChatStreamID, stream: AsyncThrowingStream<ChatStreamOutput, Error>) {
            let stream = OracleControlledStream()
            requests.append(Request(userPrompt: userPrompt, fileBlocks: fileBlocks, stream: stream))
            hasEndedEveryReply = false
            return await stream.makeStream()
        }

        /// Ends every reply still pending, so nothing waits on one after a scenario.
        fileprivate func finishAll() async {
            for request in requests {
                await request.stream.finish()
            }
            hasEndedEveryReply = true
        }
    }

    /// Chat storage a scenario redirected, and the fixture windows that can save a chat into it.
    @MainActor
    private final class ChatStorageRedirect {
        var directory: URL?
        var windows: [ContextBuilderRunFixture] = []

        /// Puts chat storage back and removes the scenario's directory.
        ///
        /// The override is process-wide, so a save that starts after it is reset goes to the real
        /// chat storage. This step is registered before any window's cleanup and therefore runs
        /// after all of it: by then each window's follow-ups are cancelled and joined, its provider
        /// replies have ended, and the window is torn down with its last saves drained. Anything
        /// still able to save a chat at that point fails the test.
        func restore() async {
            // Each fixture holds this redirect, so it lets go of them whichever way it returns.
            defer { windows.removeAll() }
            guard let directory else { return }
            for window in windows {
                for reason in await window.pendingChatWriters() {
                    XCTFail("Chat storage was put back while \(reason)")
                }
            }
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Lets the window's provider factory, which exists before the fixture does, reach it.
    @MainActor
    private final class ProviderSource {
        weak var fixture: ContextBuilderRunFixture?

        func makeProvider(_ request: ContextBuilderRunFixture.ProviderRequest) -> HeadlessAgentProvider {
            guard let fixture else {
                return UnsupportedHeadlessAgentProvider(reason: "The Context Builder run fixture is gone")
            }
            return fixture.makeProvider(request)
        }
    }

    /// A provider whose single discovery turn is performed by a ``ContextBuilderProviderChild``.
    private final class ContextBuilderRoutedProvider: HeadlessAgentProvider {
        private let child: ContextBuilderProviderChild

        init(child: ContextBuilderProviderChild) {
            self.child = child
        }

        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            let child = child
            return AsyncThrowingStream { continuation in
                let turn = Task { @MainActor in
                    do {
                        if let output = try await child.discover(runID: runID) {
                            continuation.yield(AIStreamResult(type: "content", text: output))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in turn.cancel() }
            }
        }

        func dispose() async {
            await child.dispose()
        }
    }

    /// A provider that starts its CLI twice inside one discovery turn, as the Codex exec provider
    /// does when it retries with a fallback model or without a broken MCP server. The first process
    /// connects and, once ``exitFirstProcess()`` allows, exits without a reply. The second, a
    /// process family and session token of its own registered for the same run, performs the turn.
    @MainActor
    final class ContextBuilderRelaunchingProvider: HeadlessAgentProvider {
        let firstProcess: ContextBuilderProviderChild
        let relaunchedProcess: ContextBuilderProviderChild
        private let firstProcessExitGate = ContextBuilderTestGate()

        fileprivate init(firstProcess: ContextBuilderProviderChild, relaunchedProcess: ContextBuilderProviderChild) {
            self.firstProcess = firstProcess
            self.relaunchedProcess = relaunchedProcess
        }

        func exitFirstProcess() async {
            await firstProcessExitGate.open()
        }

        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            let firstProcess = firstProcess
            let relaunchedProcess = relaunchedProcess
            let firstProcessExitGate = firstProcessExitGate
            return AsyncThrowingStream { continuation in
                let turn = Task { @MainActor in
                    do {
                        _ = try await firstProcess.discover(runID: runID)
                        await firstProcessExitGate.wait()
                        await firstProcess.dispose()
                        try Task.checkCancellation()
                        if let output = try await relaunchedProcess.discover(runID: runID) {
                            continuation.yield(AIStreamResult(type: "content", text: output))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in turn.cancel() }
            }
        }

        func dispose() async {
            await firstProcessExitGate.open()
            await firstProcess.dispose()
            await relaunchedProcess.dispose()
        }
    }

    /// A provider that never opens an MCP connection, so its run ends as a routing failure. Its
    /// turn yields `events` and then, unless it `finishesImmediately`, stays open until
    /// ``finish()``, keeping its run active for as long as a test needs.
    @MainActor
    final class ContextBuilderUnroutedProvider: HeadlessAgentProvider {
        private let events: [String]
        private let finishesImmediately: Bool
        private let finishGate = ContextBuilderTestGate()
        private(set) var runID: UUID?

        init(events: [String] = [], finishesImmediately: Bool = false) {
            self.events = events
            self.finishesImmediately = finishesImmediately
        }

        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            self.runID = runID
            let events = events
            let finishGate = finishGate
            let finishesImmediately = finishesImmediately
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(AIStreamResult(type: "content", text: event))
                }
                guard !finishesImmediately else {
                    continuation.finish()
                    return
                }
                Task {
                    await finishGate.wait()
                    continuation.finish()
                }
            }
        }

        func finish() async {
            await finishGate.open()
        }

        func dispose() async {
            await finishGate.open()
        }
    }

    /// What a provider CLI does for one discovery prompt: start its process family, register it as
    /// the run's expected agent, connect its MCP helper through bootstrap admission, call tools on
    /// the run's tab, and reply.
    @MainActor
    final class ContextBuilderProviderChild {
        /// Where the app routed this child's connection, read once `initialize` was admitted.
        struct Admission: Equatable {
            let routedRunID: UUID?
            let runConnectionID: UUID?
            let boundTabID: UUID?
        }

        /// The tool calls a child makes on its run's tab, and whether it replies with output.
        struct Writes {
            /// Whether the child reads the tab's prompt and selection before it writes either.
            var readsTabFirst = false
            var setsPrompt = true
            var setsSelection = true
            var repliesWithOutput = true
            /// Whether the child's turn ends in ``ConnectionError/turnFailed`` once its tool calls
            /// are done, as a provider that fails after it has worked on its tab does.
            var failsAfterToolCalls = false
        }

        /// The raw tool responses a child got for its tab's prompt and selection.
        struct TabRead: Equatable {
            let prompt: String
            let selection: String
        }

        enum ConnectionError: LocalizedError {
            case bootstrapRegistrationRefused
            case initializeRefused(String)
            case toolFailed(tool: String, response: String)
            case turnFailed

            var errorDescription: String? {
                switch self {
                case .bootstrapRegistrationRefused:
                    "The app refused to register the child connection."
                case let .initializeRefused(message):
                    "The app refused the child's initialize: \(message)"
                case let .toolFailed(tool, response):
                    "The child's \(tool) call failed: \(response)"
                case .turnFailed:
                    "The child's provider failed after its tool calls."
                }
            }
        }

        let connectionID = UUID()
        let sessionToken = "context-builder-run-fixture-\(UUID().uuidString)"
        let clientName: String
        private(set) var runID: UUID?
        private(set) var registeredProviderPID: pid_t?
        private(set) var admission: Admission?
        private(set) var tabReadBeforeWriting: TabRead?
        private(set) var disposeCount = 0
        private(set) var hasFinishedDisposal = false
        private weak var fixture: ContextBuilderRunFixture?
        private let waitsForConnectionRelease: Bool
        private let waitsForTurnRelease: Bool
        private let waitsForDisposalRelease: Bool
        private let writes: Writes
        private let connectionGate = ContextBuilderTestGate()
        private let turnGate = ContextBuilderTestGate()
        private let disposalGate = ContextBuilderTestGate()
        private var processFamily: ProviderProcessFamily?
        private var client: PersistentMCPTestSocketClient?
        private var connectionManager: BootstrapSocketConnectionManager?

        fileprivate init(
            fixture: ContextBuilderRunFixture,
            clientName: String,
            waitsForConnectionRelease: Bool,
            waitsForTurnRelease: Bool = false,
            waitsForDisposalRelease: Bool = false,
            writes: Writes
        ) {
            self.fixture = fixture
            self.clientName = clientName
            self.waitsForConnectionRelease = waitsForConnectionRelease
            self.waitsForTurnRelease = waitsForTurnRelease
            self.waitsForDisposalRelease = waitsForDisposalRelease
            self.writes = writes
        }

        func allowConnection() async {
            await connectionGate.open()
        }

        func allowTurn() async {
            await turnGate.open()
        }

        /// Whether the child has connected and is waiting for ``allowTurn()``.
        func isTurnHeld() async -> Bool {
            guard waitsForTurnRelease else { return false }
            return await turnGate.entered
        }

        func allowDisposal() async {
            await disposalGate.open()
        }

        /// Whether the child's disposal was asked for and is waiting for ``allowDisposal()``.
        func isDisposalHeld() async -> Bool {
            guard waitsForDisposalRelease, !hasFinishedDisposal else { return false }
            return await disposalGate.entered
        }

        fileprivate func discover(runID: UUID?) async throws -> String? {
            let fixture = try XCTUnwrap(fixture)
            let runID = try XCTUnwrap(runID)
            self.runID = runID

            let family = try await ProviderProcessFamily.spawn()
            processFamily = family
            await fixture.manager.registerExpectedAgentPID(family.providerPID, for: clientName, runID: runID)
            registeredProviderPID = family.providerPID

            if waitsForConnectionRelease {
                await connectionGate.wait()
            }
            try Task.checkCancellation()
            return try await serve(runID: runID, asHelperPID: family.helperPID)
        }

        /// The MCP side of a discovery turn, done as the helper process `helperPID` of a provider
        /// process already registered for `runID`: connect through bootstrap admission, then call
        /// tools on the run's tab.
        @discardableResult
        func serve(runID: UUID, asHelperPID helperPID: pid_t) async throws -> String? {
            let fixture = try XCTUnwrap(fixture)
            self.runID = runID
            let slot = try fixture.slot(forRunID: runID)

            let client = try await connect(as: helperPID, in: fixture)
            admission = await Admission(
                routedRunID: fixture.manager.runIDForConnection(connectionID),
                runConnectionID: fixture.window.mcpServer.connectionID(forRunID: runID),
                boundTabID: fixture.window.mcpServer.tabContextByConnectionID[connectionID]?.tabID
            )
            try client.sendNotification(method: "notifications/initialized", params: [:])
            await fixture.window.mcpServer.domainRoutingPublishTask?.value
            if waitsForTurnRelease {
                await turnGate.wait()
                try Task.checkCancellation()
            }
            if writes.readsTabFirst {
                tabReadBeforeWriting = try await TabRead(
                    prompt: call(MCPWindowToolName.prompt, ["op": "get"], on: client),
                    selection: call(MCPWindowToolName.manageSelection, ["op": "get", "view": "files"], on: client)
                )
            }
            if writes.setsPrompt {
                try await call(MCPWindowToolName.prompt, ["op": "set", "text": slot.promptText], on: client)
            }
            if writes.setsSelection {
                try await call(
                    MCPWindowToolName.manageSelection,
                    ["op": "set", "paths": [slot.fileURL.path], "mode": "full"],
                    on: client
                )
            }
            if writes.failsAfterToolCalls {
                throw ConnectionError.turnFailed
            }
            return writes.repliesWithOutput ? slot.agentOutput : nil
        }

        /// Ends the provider as process exit does: the family dies, its connection closes, and the
        /// run no longer expects its PID.
        fileprivate func dispose() async {
            disposeCount += 1
            await connectionGate.open()
            if waitsForDisposalRelease {
                await disposalGate.wait()
            }
            defer { hasFinishedDisposal = true }
            client?.close()
            guard let family = processFamily else { return }
            family.terminate()
            if let runID, let fixture {
                await fixture.manager.clearExpectedAgentPID(family.providerPID, for: clientName, runID: runID)
            }
        }

        /// A tool call on the child's connection, answered with whatever the app sent back for it:
        /// a result or a tool error.
        func callTool(_ tool: String, _ arguments: [String: Any]) async throws -> PersistentMCPTestRPCResponse {
            try await XCTUnwrap(client).request(
                method: "tools/call",
                params: ["name": tool, "arguments": arguments]
            )
        }

        /// Closes the child's socket, as the death of its helper process does.
        func closeAsProcessExit() {
            client?.close()
        }

        fileprivate func closeConnection() async {
            client?.close()
            await connectionManager?.stop()
            processFamily?.terminate()
            guard let fixture else { return }
            await fixture.manager.debugRemoveConnection(connectionID)
            fixture.window.mcpServer.removeTabContext(
                forConnectionID: connectionID,
                clientName: clientName,
                windowID: nil,
                runID: nil
            )
        }

        /// Opens a socket to the app as the helper process and sends `initialize` through production
        /// bootstrap registration, approval, and pending-policy admission.
        private func connect(
            as helperPID: pid_t,
            in fixture: ContextBuilderRunFixture
        ) async throws -> PersistentMCPTestSocketClient {
            let (client, connectionManager) = try BootstrapTestConnectionFactory.make(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientName: clientName,
                clientPid: Int(helperPID),
                observedKernelPeerPID: Int(helperPID),
                parentManager: fixture.manager
            )
            self.client = client
            self.connectionManager = connectionManager
            guard await fixture.manager.debugRegisterAndStartBootstrapConnectionForTesting(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(helperPID),
                clientName: clientName,
                manager: connectionManager
            ) else {
                throw ConnectionError.bootstrapRegistrationRefused
            }
            let response = try await client.request(
                method: "initialize",
                params: [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": ["name": clientName, "version": "context-builder-run-fixture"]
                ]
            )
            if let refusal = try JSONRPCErrorBody(response) {
                throw ConnectionError.initializeRefused(refusal.message)
            }
            return client
        }

        @discardableResult
        private func call(
            _ tool: String,
            _ arguments: [String: Any],
            on client: PersistentMCPTestSocketClient
        ) async throws -> String {
            let response = try await client.request(
                method: "tools/call",
                params: ["name": tool, "arguments": arguments]
            )
            guard try JSONRPCErrorBody(response) == nil, !response.rawJSON.contains("\"isError\":true") else {
                throw ConnectionError.toolFailed(tool: tool, response: response.rawJSON)
            }
            return response.rawJSON
        }
    }

    /// A shell standing in for a provider CLI, and its child standing in for the MCP helper that
    /// CLI launches. A run registers the shell's PID and its connection presents the child's, so
    /// admission walks process ancestry that another run's family does not share.
    private struct ProviderProcessFamily {
        enum SpawnError: Error {
            case helperProcessNotReported(String)
        }

        let process: Process
        let helperPID: pid_t

        var providerPID: pid_t {
            process.processIdentifier
        }

        static func spawn() async throws -> ProviderProcessFamily {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "/bin/sleep 120 & echo $!; wait"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let reader = output.fileHandleForReading
            let reported: Data = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: reader.availableData)
                }
            }
            let text = String(decoding: reported, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let helperPID = pid_t(text) else {
                process.terminate()
                throw SpawnError.helperProcessNotReported(text)
            }
            return ProviderProcessFamily(process: process, helperPID: helperPID)
        }

        func terminate() {
            kill(helperPID, SIGKILL)
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// A gate whose waiters end with `CancellationError` when their task is cancelled, for holding
    /// work that must still respond to cancellation.
    final class ContextBuilderCancellableTestGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var entries = 0
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

        var entryCount: Int {
            lock.withLock { entries }
        }

        func wait() async throws {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let immediate: Result<Void, Error>? = lock.withLock {
                        entries += 1
                        if isOpen { return .success(()) }
                        if Task.isCancelled { return .failure(CancellationError()) }
                        waiters[waiterID] = continuation
                        return nil
                    }
                    if let immediate {
                        continuation.resume(with: immediate)
                    }
                }
            } onCancel: {
                let waiter = lock.withLock { waiters.removeValue(forKey: waiterID) }
                waiter?.resume(throwing: CancellationError())
            }
        }

        func open() {
            let pending = lock.withLock {
                isOpen = true
                defer { waiters.removeAll() }
                return Array(waiters.values)
            }
            pending.forEach { $0.resume() }
        }
    }
#endif
