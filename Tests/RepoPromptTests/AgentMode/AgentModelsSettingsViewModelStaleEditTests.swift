@testable import RepoPromptApp
import XCTest

/// Regression coverage for the Agent Models read-modify-write boundary.
///
/// These fixtures inject an isolated `NotificationCenter`: the store posts on `.default`, so
/// the view model never hears the external write and stays stale by construction — exactly the
/// window the bugs lived in.
@MainActor
final class AgentModelsSettingsViewModelStaleEditTests: XCTestCase {
    /// A stale editing scope must not redirect the write. Both setters replace every profile
    /// field, so writing global content into the workspace slot (or the reverse) silently
    /// replaced unrelated configuration.
    func testStaleEditingScopeWritesNeitherProfile() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()

        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(planningModelRaw: "global-oracle"),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspaceID,
            mode: .useWorkspaceOverrides
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(planningModelRaw: "workspace-oracle")
        )

        // Caches `.workspace` as the editing scope.
        let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
        XCTAssertEqual(viewModel.editingScope, .workspace(workspaceID))

        // Another surface routes this workspace back to global; the view model does not hear it.
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspaceID,
            mode: .useGlobalSettings
        )

        viewModel.setOracleModel(raw: "stale-oracle")

        XCTAssertEqual(
            fixture.store.globalAgentModelsProfile().planningModelRaw,
            "global-oracle",
            "A stale-scope edit must not overwrite the global profile."
        )
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsSettings(for: workspaceID).profile?.planningModelRaw,
            "workspace-oracle",
            "A stale-scope edit must not overwrite the workspace profile either."
        )
        XCTAssertEqual(
            viewModel.editingScope,
            .global,
            "Rejection must resync the view model to the store."
        )
    }

    /// A stale profile edit must be rejected, not applied to whatever is on disk now: pins
    /// another surface just wrote would be silently dropped by a whole-profile replacement.
    /// After the rejection resyncs the cache, a legitimate edit commits against the live
    /// profile and the foreign pins survive it.
    func testStaleProfileEditIsRejectedAndLaterCommitPreservesPins() throws {
        let fixture = try makeFixture()
        let modelRaw = "ollama-cloud/kimi-k3"
        let rolePin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: modelRaw,
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let cbPin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: modelRaw,
            kind: .thinking,
            configID: "effort",
            valueRaw: "low"
        )

        // The view model caches the empty default profile.
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)

        // Another surface writes role and Context Builder pins; the view model does not hear it.
        fixture.store.setAgentModelsRoleModelParameter(
            [rolePin],
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: modelRaw),
            scope: .global
        )
        fixture.store.setAgentModelsContextBuilderModelParameter(
            [cbPin],
            agentRaw: "openCode",
            modelRaw: modelRaw,
            scope: .global
        )

        viewModel.setOracleModel(raw: "stale-oracle")

        var profile = fixture.store.globalAgentModelsProfile()
        XCTAssertNil(
            profile.planningModelRaw,
            "A stale-profile edit must be rejected rather than applied to the live profile."
        )
        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"], [rolePin])
        XCTAssertEqual(profile.contextBuilderModelParametersByAgent?["openCode"], [cbPin])

        // The rejection reloaded the cache, so a follow-up edit is fresh: it commits against
        // the live profile, and the mutation leaves the foreign pins intact.
        viewModel.setOracleModel(raw: "fresh-oracle")

        profile = fixture.store.globalAgentModelsProfile()
        XCTAssertEqual(profile.planningModelRaw, "fresh-oracle")
        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"], [rolePin])
        XCTAssertEqual(profile.contextBuilderModelParametersByAgent?["openCode"], [cbPin])
    }

    /// A pin click captured against one scope must not write after an inheritance switch even
    /// when the provider and model resolve identically in both scopes — the new workspace
    /// override profile starts as a copy of the global one, so identity alone cannot prove the
    /// scope is still current.
    func testPinClickWithSameModelAcrossInheritanceChangeIsRejected() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let modelRaw = "ollama-cloud/kimi-k3"
        let rolePin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: modelRaw,
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let staleClickPin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: modelRaw,
            kind: .thinking,
            configID: "effort",
            valueRaw: "max"
        )

        fixture.store.setAgentModelsRoleModelParameter(
            [rolePin],
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: modelRaw),
            scope: .global
        )
        // The workspace override profile materializes as a copy of the global one, pins included.
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspaceID,
            mode: .useWorkspaceOverrides
        )
        let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
        XCTAssertEqual(viewModel.editingScope, .workspace(workspaceID))

        // Another surface routes the workspace back to global; the view model does not hear it.
        // The engineer role still resolves to the same openCode model in the now-live scope.
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspaceID,
            mode: .useGlobalSettings
        )

        viewModel.setRoleModelParameter(
            [staleClickPin],
            for: .engineer,
            expectedProviderID: .openCode,
            expectedModelRaw: modelRaw,
            expectedScope: .workspace(workspaceID)
        )

        XCTAssertEqual(
            fixture.store.globalAgentModelsProfile().mcpAgentRoleModelParameters?["engineer"],
            [rolePin],
            "A pin click captured against a stale scope must not overwrite the live profile's pin."
        )
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsSettings(for: workspaceID).profile?
                .mcpAgentRoleModelParameters?["engineer"],
            [rolePin],
            "A pin click captured against a stale scope must not overwrite the dormant profile either."
        )
    }

    /// The published toggles must still commit: their `didSet` handlers read the very property
    /// being mutated, so a pre-mutation reload would silently revert every toggle edit.
    func testToggleWritesNewValueWithoutPreMutationReload() throws {
        let fixture = try makeFixture()
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: "oracle-a",
                preferredComposeModelRaw: "chat-a",
                syncChatModelWithOracle: false
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )

        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)
        XCTAssertFalse(viewModel.syncChatWithOracle)

        viewModel.syncChatWithOracle = true

        let profile = fixture.store.globalAgentModelsProfile()
        XCTAssertTrue(
            profile.syncChatModelWithOracle,
            "A toggle edit on a fresh cache must commit, not be reverted by a reload."
        )
        XCTAssertEqual(profile.planningModelRaw, "oracle-a")
        XCTAssertEqual(profile.preferredComposeModelRaw, "oracle-a")
        XCTAssertTrue(viewModel.syncChatWithOracle)
    }

    // MARK: - Fixture

    private func makeViewModel(
        fixture: (store: GlobalSettingsStore, apiSettings: APISettingsViewModel),
        workspaceID: UUID?
    ) -> AgentModelsSettingsViewModel {
        AgentModelsSettingsViewModel(
            apiSettingsVM: fixture.apiSettings,
            workspaceID: workspaceID,
            settingsManager: fixture.store,
            settingsStore: fixture.store,
            notificationCenter: NotificationCenter()
        )
    }

    private func makeFixture() throws -> (store: GlobalSettingsStore, apiSettings: APISettingsViewModel) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModelsSettingsViewModelStaleEditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }

        let suiteName = "AgentModelsSettingsViewModelStaleEditTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
            )
        )
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return (store, apiSettings)
    }
}
