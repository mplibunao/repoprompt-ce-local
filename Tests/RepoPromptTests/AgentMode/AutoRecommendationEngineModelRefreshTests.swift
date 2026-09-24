@testable import RepoPromptApp
import XCTest

@MainActor
final class AutoRecommendationEngineModelRefreshTests: XCTestCase {
    private var discoveryState: CodexDiscoveryTestState?

    override func setUp() async throws {
        try await super.setUp()
        discoveryState = CodexDiscoveryTestState.capture()
        CodexDiscoveryTestState.setDiscoveredModels([])
    }

    override func tearDown() async throws {
        discoveryState?.restore()
        try await super.tearDown()
    }

    // MARK: - Chat recommendation policy

    func testOpenAIRecommendationUsesFixedGPT6SolHighIdentity() throws {
        let fixture = try makeFixture()
        let recommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: UUID(), scope: .global),
            enabledProviders: [.openAI]
        )
        let chat = try XCTUnwrap(recommendations.chatModel)

        XCTAssertEqual(chat.defaultBackend, .openAI)
        XCTAssertEqual(
            chat.openAIOption?.modelString,
            AIModel.openaiCustomReasoning(name: "gpt-6-sol", effort: .high).rawValue
        )
        XCTAssertEqual(chat.openAIOption?.modelString, "openai_custom_reasoning_high__gpt-6-sol")
        XCTAssertEqual(chat.openAIOption?.description, "GPT-6 Sol High via the OpenAI API – pay-per-use planning and review")
        XCTAssertEqual(chat.priorityPath, ["OpenAI API (GPT-6 Sol High)", "Claude Code"])
        XCTAssertEqual(
            chat.upgradeHint,
            "Connect Codex CLI for GPT-6 Sol High – strong reasoning with practical usage limits (requires OpenAI Plus/Pro)."
        )
        XCTAssertNil(chat.codexOption)
    }

    func testRecommendedChatModelRawPrefersSuppliedOptionsThenPolicyFallbacks() throws {
        let fixture = try makeFixture()
        let supplied = ChatModelRecommendation(
            defaultBackend: .codex,
            codexOption: option(.codex, "codex_custom_supplied"),
            openAIOption: option(.openAI, "openai_supplied"),
            claudeCodeOption: option(.claudeCode, "claude_supplied"),
            priorityPath: []
        )
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(supplied, backend: .codex), "codex_custom_supplied")
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(supplied, backend: .openAI), "openai_supplied")
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(supplied, backend: .claudeCode), "claude_supplied")

        let empty = ChatModelRecommendation(
            defaultBackend: .codex,
            codexOption: nil,
            openAIOption: nil,
            claudeCodeOption: nil,
            priorityPath: []
        )
        XCTAssertEqual(
            fixture.engine.recommendedChatModelRaw(empty, backend: .openAI),
            "openai_custom_reasoning_high__gpt-6-sol"
        )
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(empty, backend: .claudeCode), AIModel.claudeCodeOpus.rawValue)
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(empty, backend: .codex), "codex_custom_gpt-5.6-sol-high")

        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt6Models())
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(empty, backend: .codex), "codex_custom_gpt-6-sol-high")
    }

    // MARK: - Context Builder and explore defaults

    func testContextBuilderRecommendsSolLowAndKeepsProviderRanking() throws {
        let allReady = status(codex: .ready, claude: .ready, cursor: .ready)

        let beforeDiscovery = try XCTUnwrap(AutoRecommendationEngine.contextBuilderRecommendation(status: allReady))
        XCTAssertEqual(beforeDiscovery.recommendedAgent, .codexExec)
        XCTAssertEqual(beforeDiscovery.recommendedModel, .gpt56SolLow)
        XCTAssertEqual(beforeDiscovery.rationale, BestPracticeProfiles.contextBuilderRationale)

        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt6Models())
        let discovered = try XCTUnwrap(AutoRecommendationEngine.contextBuilderRecommendation(status: allReady))
        XCTAssertEqual(discovered.recommendedAgent, .codexExec)
        XCTAssertEqual(discovered.recommendedModel, .gpt6SolLow)

        let claudeOnly = try XCTUnwrap(
            AutoRecommendationEngine.contextBuilderRecommendation(status: status(claude: .ready, cursor: .ready))
        )
        XCTAssertEqual(claudeOnly.recommendedAgent, .claudeCode)
        XCTAssertEqual(claudeOnly.recommendedModel, .claudeSonnet)
        XCTAssertTrue(claudeOnly.upgradeHint?.contains("GPT-6 Sol Low") == true, claudeOnly.upgradeHint ?? "")

        let cursorOnly = try XCTUnwrap(AutoRecommendationEngine.contextBuilderRecommendation(status: status(cursor: .ready)))
        XCTAssertEqual(cursorOnly.recommendedAgent, .cursor)
        XCTAssertTrue(cursorOnly.upgradeHint?.contains("GPT-6 Sol Low") == true, cursorOnly.upgradeHint ?? "")

        XCTAssertNil(AutoRecommendationEngine.contextBuilderRecommendation(status: status()))
    }

    func testComputingRecommendationsDoesNotMutateSettings() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalBefore = fixture.store.globalAgentModelsProfile()

        _ = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global)
        )
        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt6Models())
        _ = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), globalBefore)
        XCTAssertNil(fixture.store.workspaceAgentModelsProfile(for: workspaceID))
    }

    // MARK: - Saved selections

    func testSavedRoleOverridesAndContextBuilderSelectionSurviveDiscoveryChanges() {
        let availability = AgentModelCatalog.AvailabilityContext()
        let overrides = [
            AgentModelCatalog.TaskLabelKind.explore.rawValue: AgentModelSelectionID(
                agentRaw: AgentProviderKind.codexExec.rawValue,
                modelRaw: "gpt-5.6-sol-low"
            ).rawValue,
            AgentModelCatalog.TaskLabelKind.pair.rawValue: AgentModelSelectionID(
                agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: AgentModel.claudeOpus55.rawValue
            ).rawValue
        ]
        let store = AgentModelsProfileRoleDefaultsStore(overrides: overrides)

        let discoveryStates: [(label: String, models: [CodexAppServerClient.RemoteModel])] = [
            ("before discovery", []),
            ("GPT-6 discovered", CodexDiscoveryTestState.gpt6Models())
        ]
        for (label, models) in discoveryStates {
            CodexDiscoveryTestState.setDiscoveredModels(models)
            let resolutions = MCPAgentRoleDefaultsService.resolutions(
                availability: availability,
                recommendedAvailability: availability,
                settingsStore: store
            )
            let effective = Dictionary(uniqueKeysWithValues: resolutions.map { ($0.role, $0.effective) })

            // Overridden roles keep their saved selection; unpinned roles follow discovery.
            XCTAssertEqual(effective[.explore], selection(.codexExec, "gpt-5.6-sol-low"), label)
            XCTAssertEqual(effective[.pair], selection(.claudeCode, AgentModel.claudeOpus55.rawValue), label)
            XCTAssertEqual(
                effective[.engineer],
                selection(.codexExec, models.isEmpty ? "gpt-5.6-sol-medium" : "gpt-6-sol-medium"),
                label
            )
            XCTAssertEqual(store.mcpAgentRoleOverrides(scope: .global), overrides, label)

            XCTAssertEqual(
                AutoRecommendationEngine.resolveContextBuilderSelection(
                    persistedAgentRaw: AgentProviderKind.codexExec.rawValue,
                    persistedModelRaw: "gpt-5.6-sol-high",
                    availability: availability
                ),
                selection(.codexExec, "gpt-5.6-sol-high"),
                label
            )
            // With nothing saved, startup restore takes the recommendation, which never names
            // GPT-6 until Codex advertises it.
            XCTAssertEqual(
                AutoRecommendationEngine.resolveContextBuilderSelection(
                    persistedAgentRaw: nil,
                    persistedModelRaw: nil,
                    availability: availability
                ),
                selection(.codexExec, models.isEmpty ? "gpt-5.6-sol-low" : "gpt-6-sol-low"),
                label
            )
        }
    }

    // MARK: - Best practice table

    func testBestPracticeTableNamesTheDistributionDefaults() {
        XCTAssertEqual(BestPracticeProfiles.versionCode, 202_609)
        XCTAssertEqual(BestPracticeProfiles.tableTitle, "Best Models by Use Case (GPT-6)")

        XCTAssertEqual(BestPracticeProfiles.bestAgent.modelString, "gpt-6-luna-high")
        XCTAssertEqual(BestPracticeProfiles.bestAgent.agentModel, .gpt6LunaHigh)
        XCTAssertEqual(BestPracticeProfiles.bestContextBuilder.modelString, "gpt-6-sol-low")
        XCTAssertEqual(BestPracticeProfiles.bestContextBuilder.agentModel, .gpt6SolLow)
        XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.modelString, "codex_custom_gpt-6-sol-high")
        XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.agentModel, .gpt6SolHigh)
        XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelString, "gpt-6-sol")
        XCTAssertNil(BestPracticeProfiles.bestPlanning.agentModel)

        XCTAssertTrue(BestPracticeProfiles.claudeCodeOpusRecommendationLabel.contains("Opus 5.5"))
        XCTAssertTrue(BestPracticeProfiles.contextBuilderRationale.contains("GPT-6 Sol Low"))
        XCTAssertTrue(BestPracticeProfiles.contextWindowNote.contains("GPT-6 Sol Low"))
    }

    func testBestPracticeCopyNeverRecommendsLunaLow() {
        let useCaseText = BestPracticeProfiles.all.flatMap { useCase in
            [useCase.title, useCase.modelLabel, useCase.accessLabel, useCase.modelString ?? ""] + useCase.strengths
        }
        let text = useCaseText + [
            BestPracticeProfiles.tableTitle,
            BestPracticeProfiles.claudeCodeOpusRecommendationLabel,
            BestPracticeProfiles.claudeStrengths,
            BestPracticeProfiles.gpt5HighStrengths,
            BestPracticeProfiles.geminiStrengths,
            BestPracticeProfiles.codexVsOpenAIExplanation,
            BestPracticeProfiles.contextBuilderRationale,
            BestPracticeProfiles.contextWindowNote,
            BestPracticeProfiles.codexHarnessNote
        ]
        for string in text {
            let normalized = string.lowercased()
            XCTAssertFalse(normalized.contains("luna low"), string)
            XCTAssertFalse(normalized.contains("luna-low"), string)
        }
    }

    // MARK: - Helpers

    private func status(
        codex: ProviderStatusSnapshot.Availability = .notConfigured,
        claude: ProviderStatusSnapshot.Availability = .notConfigured,
        cursor: ProviderStatusSnapshot.Availability = .notConfigured
    ) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            claudeCodeCLI: claude,
            codexCLI: codex,
            cursorCLI: cursor,
            grokBuildCLI: .notConfigured,
            openAI: .notConfigured
        )
    }

    private func option(_ kind: ChatBackendKind, _ modelString: String) -> ChatBackendOption {
        ChatBackendOption(kind: kind, displayName: kind.displayName, modelString: modelString, description: "", tradeoffs: [])
    }

    private func selection(
        _ agent: AgentProviderKind,
        _ modelRaw: String
    ) -> AgentModelCatalog.NormalizedAgentSelection {
        AgentModelCatalog.NormalizedAgentSelection(agent: agent, modelRaw: modelRaw)
    }

    /// Returns the settings view model too because the engine only holds it weakly.
    private func makeFixture() throws -> (
        store: GlobalSettingsStore,
        engine: AutoRecommendationEngine,
        apiSettings: APISettingsViewModel
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRecommendationEngineModelRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "AutoRecommendationEngineModelRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: temp.appendingPathComponent("Settings/globalSettings.json"))
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
        return (store, engine, apiSettings)
    }
}
