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
            .set(rolePin),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: modelRaw),
            scope: .global
        )
        fixture.store.setAgentModelsContextBuilderModelParameter(
            .set(cbPin),
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
            .set(rolePin),
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
            .set(staleClickPin),
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

    // MARK: - Per-identity pin edits

    /// A menu opened before another surface pinned effort sends only its speed edit, so the
    /// newer effort survives for both the role and the Context Builder bucket.
    func testSpeedEditPreservesANewerEffortFromAnotherSurface() throws {
        let fixture = try makeCursorFixture()
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)
        let effort = cursorPin(kind: .thinking, configID: "effort", valueRaw: "xhigh")
        let speed = cursorPin(kind: .speed, configID: "fast", valueRaw: "false")

        fixture.store.setAgentModelsRoleModelParameter(
            .set(effort),
            roleRawValue: "engineer",
            displayedSelectionID: cursorSelectionID,
            scope: .global
        )
        fixture.store.setAgentModelsContextBuilderModelParameter(
            .set(effort),
            agentRaw: "cursor",
            modelRaw: Self.cursorModelRaw,
            scope: .global
        )

        viewModel.setRoleModelParameter(
            .set(speed),
            for: .engineer,
            expectedProviderID: .cursor,
            expectedModelRaw: Self.cursorModelRaw,
            expectedScope: .global
        )
        viewModel.setContextBuilderModelParameter(
            .set(speed),
            expectedProviderID: .cursor,
            expectedModelRaw: Self.cursorModelRaw,
            expectedScope: .global
        )

        let profile = fixture.store.globalAgentModelsProfile()
        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"], [effort, speed])
        XCTAssertEqual(profile.contextBuilderModelParametersByAgent?["cursor"], [effort, speed])
    }

    func testClearingOneKindPreservesTheOtherKind() throws {
        let fixture = try makeCursorFixture()
        let effort = cursorPin(kind: .thinking, configID: "effort", valueRaw: "high")
        let speed = cursorPin(kind: .speed, configID: "fast", valueRaw: "true")
        for pin in [effort, speed] {
            fixture.store.setAgentModelsRoleModelParameter(
                .set(pin),
                roleRawValue: "engineer",
                displayedSelectionID: cursorSelectionID,
                scope: .global
            )
            fixture.store.setAgentModelsContextBuilderModelParameter(
                .set(pin),
                agentRaw: "cursor",
                modelRaw: Self.cursorModelRaw,
                scope: .global
            )
        }
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)

        viewModel.setRoleModelParameter(
            .clear(effort.identity),
            for: .engineer,
            expectedProviderID: .cursor,
            expectedModelRaw: Self.cursorModelRaw,
            expectedScope: .global
        )
        viewModel.setContextBuilderModelParameter(
            .clear(speed.identity),
            expectedProviderID: .cursor,
            expectedModelRaw: Self.cursorModelRaw,
            expectedScope: .global
        )

        let profile = fixture.store.globalAgentModelsProfile()
        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"], [speed])
        XCTAssertEqual(profile.contextBuilderModelParametersByAgent?["cursor"], [effort])
        XCTAssertEqual(profile.mcpAgentRoleOverrides?["engineer"], cursorSelectionID.rawValue)
    }

    /// Stale scope, model, and provider targets, and an edit whose identity disagrees with its
    /// captured target, all leave both profiles untouched.
    func testStaleTargetsChangeNeitherProfile() throws {
        let fixture = try makeCursorFixture()
        let workspaceID = UUID()
        let effort = cursorPin(kind: .thinking, configID: "effort", valueRaw: "high")
        fixture.store.setAgentModelsRoleModelParameter(
            .set(effort),
            roleRawValue: "engineer",
            displayedSelectionID: cursorSelectionID,
            scope: .global
        )
        fixture.store.setAgentModelsContextBuilderModelParameter(
            .set(effort),
            agentRaw: "cursor",
            modelRaw: Self.cursorModelRaw,
            scope: .global
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
        XCTAssertEqual(viewModel.editingScope, .workspace(workspaceID))
        fixture.store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
        let globalBefore = fixture.store.globalAgentModelsProfile()
        let workspaceBefore = fixture.store.workspaceAgentModelsSettings(for: workspaceID).profile

        let speed = cursorPin(kind: .speed, configID: "fast", valueRaw: "false")
        let otherModelSpeed = cursorPin(modelRaw: "grok-4.5", kind: .speed, configID: "fast", valueRaw: "false")
        let openCodePin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let staleEdits: [(ACPModelParameterPinChange, ACPProviderID, String, AgentModelsEditingScope)] = [
            // Scope switched to global while the menu was open.
            (.set(speed), .cursor, Self.cursorModelRaw, .workspace(workspaceID)),
            (.clear(effort.identity), .cursor, Self.cursorModelRaw, .workspace(workspaceID)),
            // The menu was built for a model that is no longer displayed.
            (.set(otherModelSpeed), .cursor, "grok-4.5", .global),
            // The menu was built for another provider.
            (.set(openCodePin), .openCode, "ollama-cloud/kimi-k3", .global),
            // The edit's own identity disagrees with the captured target.
            (.set(otherModelSpeed), .cursor, Self.cursorModelRaw, .global)
        ]
        for (change, providerID, modelRaw, scope) in staleEdits {
            viewModel.setRoleModelParameter(
                change,
                for: .engineer,
                expectedProviderID: providerID,
                expectedModelRaw: modelRaw,
                expectedScope: scope
            )
            viewModel.setContextBuilderModelParameter(
                change,
                expectedProviderID: providerID,
                expectedModelRaw: modelRaw,
                expectedScope: scope
            )
        }

        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), globalBefore)
        XCTAssertEqual(fixture.store.workspaceAgentModelsSettings(for: workspaceID).profile, workspaceBefore)
    }

    /// Choosing Default where nothing is pinned writes nothing and posts nothing, so it cannot
    /// claim Context Builder ownership, stop automatic recommendations, or trigger a refresh.
    func testNoOpDefaultWritesAndPostsNothing() async throws {
        let fixture = try makeCursorFixture()
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                contextBuilderAgentRaw: "cursor",
                contextBuilderModelsByAgent: ["cursor": Self.cursorModelRaw],
                mcpAgentRoleOverrides: ["engineer": cursorSelectionID.rawValue]
            ),
            contextBuilderWriteIntent: .automaticSeed
        )
        XCTAssertFalse(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)
        let center = NotificationCenter()
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil, notificationCenter: center)
        let posts = PostRecorder()
        let viewModelObserver = center.addObserver(forName: nil, object: nil, queue: nil) {
            posts.record(viewModel: $0.name)
        }
        let storeObserver = NotificationCenter.default.addObserver(
            forName: .agentModelsSettingsDidChange,
            object: nil,
            queue: nil
        ) { _ in posts.recordStore() }
        defer {
            center.removeObserver(viewModelObserver)
            NotificationCenter.default.removeObserver(storeObserver)
        }
        let effort = cursorPin(kind: .thinking, configID: "effort", valueRaw: "high")
        let profileBefore = fixture.store.globalAgentModelsProfile()

        viewModel.setContextBuilderModelParameter(
            .clear(effort.identity),
            expectedProviderID: .cursor,
            expectedModelRaw: Self.cursorModelRaw,
            expectedScope: .global
        )
        viewModel.setRoleModelParameter(
            .clear(effort.identity),
            for: .engineer,
            expectedProviderID: .cursor,
            expectedModelRaw: Self.cursorModelRaw,
            expectedScope: .global
        )
        // The Context Builder refresh posts on the next main-queue turn; give it that turn.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), profileBefore)
        XCTAssertFalse(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)
        XCTAssertEqual(posts.viewModelNames, [], "A no-op pin edit must not ask anything to refresh.")
        XCTAssertEqual(posts.storeCount, 0, "A no-op pin edit must not announce a settings change.")

        viewModel.setContextBuilderModelParameter(
            .set(effort),
            expectedProviderID: .cursor,
            expectedModelRaw: Self.cursorModelRaw,
            expectedScope: .global
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(
            fixture.store.hasUserSetGlobalContextBuilderAgentDefaults,
            "A real pin commits the displayed Context Builder choice, which is a user decision."
        )
        XCTAssertTrue(posts.viewModelNames.contains(.recommendationsShouldRefresh), "A real edit still refreshes.")
        XCTAssertGreaterThan(posts.storeCount, 0, "A real edit still announces the settings change.")
    }

    /// The stored role model is unavailable and the surface displays a fallback. Clearing the
    /// fallback's identity keeps the stored model's pins; setting a pin adopts the fallback and
    /// leaves behind the pins that belonged to the stored model.
    func testFallbackDisplayedClearKeepsStoredPinsAndSetAdoptsFallback() throws {
        let fixture = try makeCursorFixture()
        let storedPin = cursorPin(modelRaw: "grok-4.5", kind: .thinking, configID: "effort", valueRaw: "low")
        fixture.store.setAgentModelsRoleModelParameter(
            .set(storedPin),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "cursor", modelRaw: "grok-4.5"),
            scope: .global
        )
        let stored = fixture.store.globalAgentModelsProfile()

        fixture.store.setAgentModelsRoleModelParameter(
            .clear(cursorPin(kind: .thinking, configID: "effort", valueRaw: "low").identity),
            roleRawValue: "engineer",
            displayedSelectionID: cursorSelectionID,
            scope: .global
        )
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), stored)

        let fallbackSpeed = cursorPin(kind: .speed, configID: "fast", valueRaw: "true")
        fixture.store.setAgentModelsRoleModelParameter(
            .set(fallbackSpeed),
            roleRawValue: "engineer",
            displayedSelectionID: cursorSelectionID,
            scope: .global
        )
        let adopted = fixture.store.globalAgentModelsProfile()
        XCTAssertEqual(adopted.mcpAgentRoleOverrides?["engineer"], cursorSelectionID.rawValue)
        XCTAssertEqual(
            adopted.mcpAgentRoleModelParameters?["engineer"],
            [fallbackSpeed],
            "A set must not carry the previous model's pins into the adopted model's bucket."
        )
    }

    // MARK: - Fixture

    /// Notification log shared with observer blocks, which run on the posting thread.
    private final class PostRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [Notification.Name] = []
        private var stores = 0

        var viewModelNames: [Notification.Name] {
            lock.withLock { names }
        }

        var storeCount: Int {
            lock.withLock { stores }
        }

        func record(viewModel name: Notification.Name) {
            lock.withLock { names.append(name) }
        }

        func recordStore() {
            lock.withLock { stores += 1 }
        }
    }

    private nonisolated static let cursorModelRaw = "grok-4.6"

    private var cursorSelectionID: AgentModelSelectionID {
        AgentModelSelectionID(agentRaw: "cursor", modelRaw: Self.cursorModelRaw)
    }

    private func cursorPin(
        modelRaw: String = AgentModelsSettingsViewModelStaleEditTests.cursorModelRaw,
        kind: ACPModelParameterKind,
        configID: String,
        valueRaw: String
    ) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: modelRaw,
            kind: kind,
            configID: configID,
            valueRaw: valueRaw
        )
    }

    /// Cursor connected, with the engineer role and the Context Builder on the Cursor model.
    private func makeCursorFixture() throws -> (store: GlobalSettingsStore, apiSettings: APISettingsViewModel) {
        let fixture = try makeFixture()
        fixture.apiSettings.isCursorConnected = true
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                contextBuilderAgentRaw: "cursor",
                contextBuilderModelsByAgent: ["cursor": Self.cursorModelRaw],
                mcpAgentRoleOverrides: ["engineer": cursorSelectionID.rawValue]
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        return fixture
    }

    private func makeViewModel(
        fixture: (store: GlobalSettingsStore, apiSettings: APISettingsViewModel),
        workspaceID: UUID?,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> AgentModelsSettingsViewModel {
        AgentModelsSettingsViewModel(
            apiSettingsVM: fixture.apiSettings,
            workspaceID: workspaceID,
            settingsManager: fixture.store,
            settingsStore: fixture.store,
            notificationCenter: notificationCenter
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
