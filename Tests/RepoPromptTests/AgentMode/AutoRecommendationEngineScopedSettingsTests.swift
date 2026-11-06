import Combine
import enum MCP.Value
@testable import RepoPromptApp
import XCTest

@MainActor
final class AutoRecommendationEngineScopedSettingsTests: XCTestCase {
    func testOperationIdentityRejectsWorkspaceAndInheritanceChanges() {
        let workspaceID = UUID()
        let identity = AgentModelsOperationIdentity(
            sourceWorkspaceID: workspaceID,
            inheritanceMode: .useWorkspaceOverrides
        )

        XCTAssertTrue(identity.matches(sourceWorkspaceID: workspaceID, inheritanceMode: .useWorkspaceOverrides))
        XCTAssertFalse(identity.matches(sourceWorkspaceID: UUID(), inheritanceMode: .useWorkspaceOverrides))
        XCTAssertFalse(identity.matches(sourceWorkspaceID: workspaceID, inheritanceMode: .useGlobalSettings))
    }

    func testRecommendationActionRevisionGuardRejectsSameIdentityAfterDurableChange() {
        var guardState = RecommendationActionRevisionGuard()
        guardState.markComputed()
        XCTAssertTrue(guardState.isCurrent)

        guardState.invalidate()
        XCTAssertFalse(guardState.isCurrent)

        guardState.markComputed()
        XCTAssertTrue(guardState.isCurrent)
    }

    func testRecommendationSatisfactionUsesTargetEditingScope() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let recommended = try recommendedOpenAIModelRaw(from: fixture.engine)
        let nonRecommended = AIModel.claude4Sonnet.rawValue

        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: recommended,
                preferredComposeModelRaw: recommended
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: nonRecommended,
                preferredComposeModelRaw: nonRecommended
            )
        )

        let globalRecommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            enabledProviders: [.openAI]
        )
        let workspaceRecommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            enabledProviders: [.openAI]
        )

        XCTAssertEqual(globalRecommendations.chatModel?.defaultBackend, .openAI)
        XCTAssertEqual(globalRecommendations.chatModel?.alreadySatisfied, true)
        XCTAssertEqual(workspaceRecommendations.chatModel?.defaultBackend, .openAI)
        XCTAssertEqual(workspaceRecommendations.chatModel?.alreadySatisfied, false)
    }

    func testBulkApplyWritesWorkspaceProfileWithoutMutatingGlobalProfile() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModel.claudeSonnet.rawValue
            ]
        )
        fixture.store.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: AIModel.claude4Sonnet.rawValue,
                preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue
            )
        )

        let recommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            enabledProviders: [.openAI]
        )
        let recommended = try XCTUnwrap(recommendations.chatModel?.openAIOption?.modelString)
        fixture.engine.applyModelRecommendations(
            recommendations,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        let workspaceProfile = try XCTUnwrap(fixture.store.workspaceAgentModelsProfile(for: workspaceID))
        XCTAssertEqual(workspaceProfile.planningModelRaw, recommended)
        XCTAssertEqual(workspaceProfile.preferredComposeModelRaw, recommended)
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), globalProfile)
    }

    func testBulkApplyWithPresetExposureNotifiesEachAffectedScopeAndCoalescesGlobal() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let nonRecommended = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: nonRecommended,
                preferredComposeModelRaw: nonRecommended
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: nonRecommended,
                preferredComposeModelRaw: nonRecommended
            )
        )
        let recommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            enabledProviders: [.openAI]
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter {
                $0.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID == workspaceID
            }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        fixture.engine.applyModelRecommendations(
            recommendations,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            includePresetExposure: true
        )

        XCTAssertEqual(receivedNotifications.count, 2)
        XCTAssertEqual(
            Set(receivedNotifications.compactMap {
                $0.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
            }),
            Set([
                AgentModelsSettingsNotification.Scope.workspace.rawValue,
                AgentModelsSettingsNotification.Scope.global.rawValue
            ])
        )
        let workspaceNotification = try XCTUnwrap(receivedNotifications.first { notification in
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
                == AgentModelsSettingsNotification.Scope.workspace.rawValue
        })
        XCTAssertEqual(
            workspaceNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID,
            workspaceID
        )

        receivedNotifications.removeAll()
        fixture.engine.applyModelRecommendations(
            recommendations,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            includePresetExposure: true
        )

        XCTAssertEqual(receivedNotifications.count, 1)
        let globalNotification = try XCTUnwrap(receivedNotifications.first)
        XCTAssertEqual(
            globalNotification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String,
            AgentModelsSettingsNotification.Scope.global.rawValue
        )
        XCTAssertNil(globalNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
    }

    func testContextBuilderRecommendationWritesTargetWorkspaceProfileOnly() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: AgentProviderKind.codexExec.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.codexExec.rawValue: AgentModel.gpt55CodexLow.rawValue
            ]
        )
        fixture.store.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: AgentModelsSettingsProfile())
        let beforeWorkspaceChatSettings = fixture.store.chatSettings(for: workspaceID)

        let recommendation = ContextBuilderRecommendation(
            recommendedAgent: .claudeCode,
            recommendedModel: .claudeSonnet,
            rationale: "test"
        )
        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        let workspaceProfile = try XCTUnwrap(fixture.store.workspaceAgentModelsProfile(for: workspaceID))
        XCTAssertEqual(workspaceProfile.contextBuilderAgentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(
            workspaceProfile.contextBuilderModelsByAgent?[AgentProviderKind.claudeCode.rawValue],
            AgentModel.claudeSonnet.rawValue
        )
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), globalProfile)
        let afterWorkspaceChatSettings = fixture.store.chatSettings(for: workspaceID)
        XCTAssertEqual(afterWorkspaceChatSettings.contextBuilderAgentRaw, beforeWorkspaceChatSettings.contextBuilderAgentRaw)
        XCTAssertEqual(afterWorkspaceChatSettings.contextBuilderAgentModelRaw, beforeWorkspaceChatSettings.contextBuilderAgentModelRaw)
        XCTAssertEqual(
            afterWorkspaceChatSettings.didUserSetContextBuilderDefaults,
            beforeWorkspaceChatSettings.didUserSetContextBuilderDefaults
        )
    }

    func testRoleDefaultsRecommendationClearsOnlyTargetWorkspaceOverrides() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalOverride = AgentModelSelectionID(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexHigh.rawValue
        ).rawValue
        let workspaceOverride = AgentModelSelectionID(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexMedium.rawValue
        ).rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                mcpAgentRoleOverrides: [AgentModelCatalog.TaskLabelKind.explore.rawValue: globalOverride]
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                mcpAgentRoleOverrides: [AgentModelCatalog.TaskLabelKind.explore.rawValue: workspaceOverride]
            )
        )

        let recommendation = MCPAgentDefaultsRecommendation(
            currentRoleDefaults: [],
            recommendedRoleDefaults: [],
            upgradeHint: nil
        )
        fixture.engine.applyMCPAgentDefaultsRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        XCTAssertEqual(
            fixture.store.globalAgentModelsProfile().mcpAgentRoleOverrides,
            [AgentModelCatalog.TaskLabelKind.explore.rawValue: globalOverride]
        )
        XCTAssertNil(fixture.store.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides)
    }

    func testContextBuilderRecommendationWriteIntentDistinguishesAutomaticSeedFromExplicitApply() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let recommendation = ContextBuilderRecommendation(
            recommendedAgent: .claudeCode,
            recommendedModel: .claudeSonnet,
            rationale: "test"
        )

        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            contextBuilderWriteIntent: .automaticSeed
        )

        XCTAssertFalse(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)

        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            contextBuilderWriteIntent: .userInitiated
        )

        XCTAssertTrue(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)

        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            contextBuilderWriteIntent: .automaticSeed
        )

        XCTAssertTrue(
            fixture.store.hasUserSetGlobalContextBuilderAgentDefaults,
            "Automatic seeding must not demote an established user-owned selection."
        )
    }

    /// Clearing a saved Claude model must keep Claude at runtime and in Settings, using its catalog default
    /// without saving it, both immediately and after a fresh-store reload.
    func testContextBuilderModelClearKeepsSettingsAndRuntimeProviderInAgreement() async throws {
        let fixture = try makeFixture()
        defer { fixture.apiSettings.prepareForWindowClose() }
        fixture.apiSettings.isClaudeCodeConnected = true
        fixture.apiSettings.isCodexConnected = true
        fixture.apiSettings.isCursorConnected = false
        fixture.apiSettings.isGrokBuildConnected = false
        fixture.apiSettings.test_completeContextBuilderProviderValidation(verifiedProviders: [.claudeCode, .codexExec])
        let claudeRaw = AgentProviderKind.claudeCode.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                contextBuilderAgentRaw: claudeRaw,
                contextBuilderModelsByAgent: [claudeRaw: AgentModel.claudeSonnet.rawValue]
            ),
            contextBuilderWriteIntent: .userInitiated
        )
        func runtimeSelection(from store: GlobalSettingsStore) -> AgentModelCatalog.NormalizedAgentSelection? {
            let profile = store.effectiveAgentModelsProfile(workspaceID: nil)
            let agentRaw = profile.contextBuilderAgentRaw
            return AutoRecommendationEngine.resolveContextBuilderSelection(
                persistedAgentRaw: agentRaw,
                persistedModelRaw: agentRaw.flatMap { profile.contextBuilderModelsByAgent?[$0] },
                availability: fixture.apiSettings.contextBuilderRestorationAvailabilityContext,
                enabledRecommendationProviders: store.globalRecommendationProviderFilter()
            )
        }
        XCTAssertEqual(
            runtimeSelection(from: fixture.store),
            AgentModelCatalog.NormalizedAgentSelection(agent: .claudeCode, modelRaw: AgentModel.claudeSonnet.rawValue),
            "Precondition: runtime accepts the saved, available Claude/Sonnet pair"
        )
        XCTAssertTrue(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)

        let clear = try await AppSettingsMCPService(store: fixture.store, notificationCenter: NotificationCenter()).handleForTesting([
            "op": .string("set"),
            "key": .string("context_builder.model"),
            "value": .null
        ])
        XCTAssertEqual(clear.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(clear.objectValue?["applied"]?.boolValue, true)
        XCTAssertNil(clear.objectValue?["persistence_blocked"])

        let expectedDefault = AgentModelCatalog.NormalizedAgentSelection(
            agent: .claudeCode,
            modelRaw: AgentModelCatalog.defaultModelRaw(
                for: .claudeCode,
                availability: fixture.apiSettings.contextBuilderRestorationAvailabilityContext
            )
        )

        func assertClearedSelection(in store: GlobalSettingsStore, phase: String) async throws {
            let settings = AgentModelsSettingsViewModel(
                apiSettingsVM: fixture.apiSettings,
                workspaceID: nil,
                settingsManager: store,
                settingsStore: store,
                notificationCenter: NotificationCenter()
            )
            XCTAssertEqual(runtimeSelection(from: store), expectedDefault, "\(phase): a clear must keep the saved provider on its catalog default")
            XCTAssertEqual(
                settings.selectedContextBuilderSelection,
                expectedDefault,
                "\(phase): Settings and runtime must use the same normalized default"
            )
            let profile = store.globalAgentModelsProfile()
            XCTAssertEqual(profile.contextBuilderAgentRaw, claudeRaw, phase)
            XCTAssertNil(profile.contextBuilderModelsByAgent?[claudeRaw], "\(phase): the synthesized default must not be saved")
            XCTAssertTrue(store.hasUserSetGlobalContextBuilderAgentDefaults, phase)
            let get = try await AppSettingsMCPService(store: store, notificationCenter: NotificationCenter()).handleForTesting([
                "op": .string("get"),
                "keys": .array([.string("context_builder.model")])
            ])
            XCTAssertEqual(get.objectValue?["values"]?.objectValue?["context_builder.model"], .null, phase)
        }
        try await assertClearedSelection(in: fixture.store, phase: "after clear")
        let reloaded = GlobalSettingsStore(
            defaults: fixture.defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL)
        )
        try await assertClearedSelection(in: reloaded, phase: "after reload")
    }

    /// A usable saved agent with an absent or blank model keeps its provider and catalog default, even when the
    /// recommendation filter excludes it. An invalid nonempty model or an unavailable agent still falls back to
    /// exactly what resolving with no saved selection returns.
    func testContextBuilderResolverKeepsSavedProviderDefaultBeforeRecommendationFiltering() throws {
        let invalidModel = "not-a-claude-model"
        let claudeAndCodex = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false
        )
        let codexOnly = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false
        )
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: invalidModel, for: .claudeCode, availability: claudeAndCodex))
        func resolve(
            agentRaw: String?,
            modelRaw: String?,
            availability: AgentModelCatalog.AvailabilityContext
        ) -> AgentModelCatalog.NormalizedAgentSelection? {
            AutoRecommendationEngine.resolveContextBuilderSelection(
                persistedAgentRaw: agentRaw,
                persistedModelRaw: modelRaw,
                availability: availability,
                enabledRecommendationProviders: [.codex]
            )
        }
        let claudeDefault = AgentModelCatalog.NormalizedAgentSelection(
            agent: .claudeCode,
            modelRaw: AgentModelCatalog.defaultModelRaw(for: .claudeCode, availability: claudeAndCodex)
        )
        let scenarios: [(
            name: String, model: String?, availability: AgentModelCatalog.AvailabilityContext, keepsSavedClaude: Bool
        )] = [
            ("absent model keeps Claude despite the Codex-only filter", nil, claudeAndCodex, true),
            ("empty model keeps Claude despite the Codex-only filter", "", claudeAndCodex, true),
            ("whitespace model keeps Claude despite the Codex-only filter", " \n\t ", claudeAndCodex, true),
            ("invalid nonempty Claude model keeps the fallback", invalidModel, claudeAndCodex, false),
            ("unavailable Claude with an absent model keeps the fallback", nil, codexOnly, false)
        ]
        for scenario in scenarios {
            let selection = try XCTUnwrap(
                resolve(
                    agentRaw: AgentProviderKind.claudeCode.rawValue,
                    modelRaw: scenario.model,
                    availability: scenario.availability
                ),
                scenario.name
            )
            if scenario.keepsSavedClaude {
                XCTAssertEqual(selection, claudeDefault, scenario.name)
            } else {
                let fallback = try XCTUnwrap(
                    resolve(agentRaw: nil, modelRaw: nil, availability: scenario.availability),
                    scenario.name
                )
                XCTAssertEqual(fallback.agent, .codexExec, scenario.name)
                XCTAssertEqual(selection, fallback, scenario.name)
            }
        }
    }

    private func recommendedOpenAIModelRaw(from engine: AutoRecommendationEngine) throws -> String {
        let recommendations = engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: UUID(), scope: .global),
            enabledProviders: [.openAI]
        )
        return try XCTUnwrap(recommendations.chatModel?.openAIOption?.modelString)
    }

    private func makeFixture() throws -> (
        store: GlobalSettingsStore,
        engine: AutoRecommendationEngine,
        apiSettings: APISettingsViewModel,
        defaults: UserDefaults,
        fileURL: URL
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRecommendationEngineScopedSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "AutoRecommendationEngineScopedSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        apiSettings.openAIApiKey = "test-key"
        apiSettings.isOpenAIKeyValid = true
        let engine = AutoRecommendationEngine(
            settingsStore: store,
            profileSettingsManager: store,
            apiSettingsViewModel: apiSettings
        )
        return (store, engine, apiSettings, defaults, fileURL)
    }
}
