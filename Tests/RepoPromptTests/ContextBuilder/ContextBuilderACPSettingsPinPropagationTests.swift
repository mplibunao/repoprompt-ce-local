@testable import RepoPromptApp
import XCTest

/// Request boundary for Context Builder parameter pins: Cursor effort and speed pinned through
/// the Settings write path both reach `ContextBuilderResolvedRunAuthority`, the only place a
/// Context Builder run receives its model parameters.
@MainActor
final class ContextBuilderACPSettingsPinPropagationTests: XCTestCase {
    private static let modelRaw = "grok-4.6"

    func testSettingsPinnedCursorEffortAndSpeedReachRunAuthority() async throws {
        let store = try makeIsolatedStore()
        let (window, tabID) = await makeWindow()
        addTeardownBlock { @MainActor in
            _ = await window.mcpServer.setWindowToolsEnabled(false)
        }
        window.apiSettingsViewModel.isCursorConnected = true
        window.apiSettingsViewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.cursor])
        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                contextBuilderAgentRaw: AgentProviderKind.cursor.rawValue,
                contextBuilderModelsByAgent: [AgentProviderKind.cursor.rawValue: Self.modelRaw]
            ),
            contextBuilderWriteIntent: .userInitiated
        )
        let viewModel = ContextBuilderAgentViewModel(
            promptManager: window.promptManager,
            workspaceManager: window.workspaceManager,
            mcpServer: window.mcpServer,
            oracleViewModel: window.oracleViewModel,
            settingsManager: store
        )
        XCTAssertEqual(viewModel.selectedAgent, .cursor)
        XCTAssertEqual(viewModel.selectedModelRaw, Self.modelRaw)
        let effort = pin(kind: .thinking, configID: "effort", valueRaw: "xhigh")
        let speed = pin(kind: .speed, configID: "fast", valueRaw: "false")
        for pin in [effort, speed] {
            viewModel.setContextBuilderModelParameter(
                .set(pin),
                expectedProviderID: .cursor,
                expectedModelRaw: Self.modelRaw,
                expectedScope: viewModel.contextBuilderEditingScope
            )
        }
        XCTAssertEqual(viewModel.contextBuilderModelParameters, [effort, speed])

        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let identity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID)
        var nested = MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.mcpServer.windowID,
            workspaceID: workspace.id,
            promptText: "",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            selectedContextBuilderPromptIDs: [],
            tabName: "",
            runID: nil,
            explicitlyBound: true
        )
        nested.frozenLookupContext = .visibleWorkspace

        let authority = try await viewModel.resolveMCPRunAuthority(
            identity: identity,
            nestedTabContext: nested,
            workspaceContext: nil,
            responseType: nil
        )

        XCTAssertEqual(authority.agentKind, .cursor)
        XCTAssertEqual(authority.modelRaw, Self.modelRaw)
        XCTAssertEqual(authority.modelParameterSelections, [effort, speed])
        // The UI-run and MCP-override reads use the same eligibility predicate over the same
        // profile, so they see the same two pins.
        XCTAssertEqual(
            store.effectiveAgentModelsProfile(workspaceID: workspace.id)
                .contextBuilderModelParameterSelections(for: .cursor, modelRaw: Self.modelRaw),
            authority.modelParameterSelections
        )
    }

    // MARK: - Fixtures

    private func pin(kind: ACPModelParameterKind, configID: String, valueRaw: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: Self.modelRaw,
            kind: kind,
            configID: configID,
            valueRaw: valueRaw
        )
    }

    private func makeIsolatedStore() throws -> GlobalSettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderACPSettingsPinPropagationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ContextBuilderACPSettingsPinPropagationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("Settings/globalSettings.json"))
        )
    }

    private func makeWindow() async -> (WindowState, UUID) {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let window = ACPModelParameterTestSupport.makeWindowWithoutLiveProviderCatalogs()
        await window.workspaceManager.awaitInitialized()
        _ = await window.mcpServer.setWindowToolsEnabled(true)
        let tab = ComposeTabState(name: "Pins")
        let workspace = WorkspaceModel(
            name: "Context Builder pins",
            repoPaths: [FileManager.default.temporaryDirectory.path],
            composeTabs: [tab],
            activeComposeTabID: tab.id
        )
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.promptManager.loadComposeTabsFromWorkspace(workspace)
        return (window, tab.id)
    }
}
