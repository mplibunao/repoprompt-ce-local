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

    func testOpenAIRecommendationUsesDirectGPT61SolHigh() throws {
        let fixture = try makeFixture()
        let recommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: UUID(), scope: .global),
            enabledProviders: [.openAI]
        )
        let chat = try XCTUnwrap(recommendations.chatModel)
        let option = try XCTUnwrap(chat.openAIOption)

        XCTAssertEqual(chat.defaultBackend, .openAI)
        XCTAssertEqual(option.modelString, "gpt-6.1-sol-high")
        // The applied raw is the direct built-in, so the request carries High effort rather than the
        // built-in's Medium default.
        let model = try XCTUnwrap(option.modelString.flatMap(AIModel.fromModelName))
        XCTAssertEqual(model, .gpt61SolHigh)
        XCTAssertEqual(model.defaultReasoningEffort, "high")
        XCTAssertEqual(option.description, "GPT-6.1 Sol High via the OpenAI API – pay-per-use planning and review")
        XCTAssertTrue(option.tradeoffs.contains("• GPT-6.1 Sol is available through the OpenAI Responses API"))
        XCTAssertEqual(chat.priorityPath, ["OpenAI API (GPT-6.1 Sol High)", "Claude Code"])
        XCTAssertEqual(
            chat.upgradeHint,
            "Connect Codex CLI for GPT-6.1 Sol High – strong reasoning with practical usage limits (requires OpenAI Plus/Pro)."
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
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(empty, backend: .openAI), "gpt-6.1-sol-high")
        XCTAssertEqual(fixture.engine.recommendedChatModelRaw(empty, backend: .claudeCode), AIModel.claudeCodeOpus.rawValue)

        // The Codex fallback names the newest Sol advertised at High, and GPT-5.6 Sol High otherwise.
        let codexStates: [(label: String, models: [CodexAppServerClient.RemoteModel], expected: String)] = [
            ("before discovery", [], "codex_custom_gpt-5.6-sol-high"),
            ("GPT-6 discovered", CodexDiscoveryTestState.gpt6Models(), "codex_custom_gpt-6-sol-high"),
            ("GPT-6.1 discovered", CodexDiscoveryTestState.gpt61Models(), "codex_custom_gpt-6.1-sol-high"),
            ("GPT-6.1 Low only", Self.gpt61LowOnlyModels(), "codex_custom_gpt-5.6-sol-high")
        ]
        for state in codexStates {
            CodexDiscoveryTestState.setDiscoveredModels(state.models)
            XCTAssertEqual(fixture.engine.recommendedChatModelRaw(empty, backend: .codex), state.expected, state.label)
        }
    }

    // MARK: - Context Builder and explore defaults

    func testContextBuilderRecommendsSolLowAndKeepsProviderRanking() throws {
        let allReady = status(codex: .ready, claude: .ready, cursor: .ready)

        let beforeDiscovery = try XCTUnwrap(AutoRecommendationEngine.contextBuilderRecommendation(status: allReady))
        XCTAssertEqual(beforeDiscovery.recommendedAgent, .codexExec)
        XCTAssertEqual(beforeDiscovery.recommendedModel, .gpt56SolLow)
        XCTAssertEqual(beforeDiscovery.rationale, BestPracticeProfiles.contextBuilderRationale)

        // The newest advertised Sol wins at Low, including a GPT-6.1 catalog that offers only Low.
        let discoveredStates: [(label: String, models: [CodexAppServerClient.RemoteModel], expected: AgentModel)] = [
            ("GPT-6 discovered", CodexDiscoveryTestState.gpt6Models(), .gpt6SolLow),
            ("GPT-6.1 discovered", CodexDiscoveryTestState.gpt61Models(), .gpt61SolLow),
            ("GPT-6.1 Low only", Self.gpt61LowOnlyModels(), .gpt61SolLow)
        ]
        for state in discoveredStates {
            CodexDiscoveryTestState.setDiscoveredModels(state.models)
            let discovered = try XCTUnwrap(AutoRecommendationEngine.contextBuilderRecommendation(status: allReady))
            XCTAssertEqual(discovered.recommendedAgent, .codexExec, state.label)
            XCTAssertEqual(discovered.recommendedModel, state.expected, state.label)
        }

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

    /// Fresh defaults are the computed recommendation before Apply; computing them through every
    /// discovery state, including a repeated identical update, writes no profile.
    func testComputingRecommendationsDoesNotMutateSettings() throws {
        let fixture = try makeFixture()
        fixture.apiSettings.isCodexConnected = true
        fixture.apiSettings.test_completeContextBuilderProviderValidation(verifiedProviders: [.codexExec])
        let workspaceID = UUID()
        let globalBefore = fixture.store.globalAgentModelsProfile()

        let states: [(label: String, models: [CodexAppServerClient.RemoteModel], defaults: CodexDefaults)] = [
            ("before discovery", [], CodexDefaults(
                explore: "gpt-5.6-luna-high", engineer: "gpt-5.6-sol-medium", pair: "gpt-5.6-sol-high", contextBuilder: "gpt-5.6-sol-low"
            )),
            ("GPT-6 discovered", CodexDiscoveryTestState.gpt6Models(), CodexDefaults(
                explore: "gpt-6-luna-high", engineer: "gpt-6-sol-medium", pair: "gpt-6-sol-high", contextBuilder: "gpt-6-sol-low"
            )),
            ("GPT-6.1 discovered", CodexDiscoveryTestState.gpt61Models(), Self.gpt61Defaults),
            // Engineer and Pair keep their GPT-5.6 fallbacks; only Context Builder's Low is advertised.
            ("GPT-6.1 Low only", Self.gpt61LowOnlyModels(), CodexDefaults(
                explore: "gpt-6-luna-high", engineer: "gpt-5.6-sol-medium", pair: "gpt-5.6-sol-high", contextBuilder: "gpt-6.1-sol-low"
            )),
            ("GPT-6.1 repeated", CodexDiscoveryTestState.gpt61Models(), Self.gpt61Defaults)
        ]
        for (index, state) in states.enumerated() {
            CodexDiscoveryTestState.setDiscoveredModels(state.models)
            let scope: AgentModelsEditingScope = index.isMultiple(of: 2) ? .global : .workspace(workspaceID)
            let recommendations = fixture.engine.computeRecommendations(
                for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: scope),
                enabledProviders: [.codex]
            )

            XCTAssertEqual(
                recommendations.chatModel?.codexOption?.modelString,
                AIModel.codexCustom(name: state.defaults.pair).rawValue,
                state.label
            )
            let contextBuilder = try XCTUnwrap(recommendations.contextBuilder, state.label)
            XCTAssertEqual(contextBuilder.recommendedModel.rawValue, state.defaults.contextBuilder, state.label)
            XCTAssertEqual(
                fixture.engine.recommendedContextBuilderModelRaw(contextBuilder),
                state.defaults.contextBuilder,
                state.label
            )
            let roles = Dictionary(uniqueKeysWithValues: (recommendations.mcpAgentDefaults?.recommendedRoleDefaults ?? []).map {
                ($0.role, $0.selectionIDRaw)
            })
            for (role, modelRaw) in [
                (AgentModelCatalog.TaskLabelKind.explore, state.defaults.explore),
                (.engineer, state.defaults.engineer),
                (.pair, state.defaults.pair)
            ] {
                XCTAssertEqual(
                    roles[role],
                    AgentModelSelectionID(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: modelRaw).rawValue,
                    "\(state.label) \(role)"
                )
            }
        }

        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), globalBefore)
        XCTAssertNil(fixture.store.workspaceAgentModelsProfile(for: workspaceID))
    }

    // MARK: - Saved selections

    func testSavedRoleOverridesAndContextBuilderSelectionSurviveDiscoveryChanges() throws {
        let fixture = try makeFixture()
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
        let customPlanningRaw = "openai_custom_reasoning_high__gpt-6-sol"
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: customPlanningRaw,
                preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
                contextBuilderAgentRaw: AgentProviderKind.codexExec.rawValue,
                contextBuilderModelsByAgent: [AgentProviderKind.codexExec.rawValue: "gpt-5.6-sol-high"],
                mcpAgentRoleOverrides: overrides
            ),
            contextBuilderWriteIntent: .userInitiated
        )
        let saved = fixture.store.globalAgentModelsProfile()
        XCTAssertEqual(saved.planningModelRaw, customPlanningRaw)

        let discoveryStates: [(label: String, models: [CodexAppServerClient.RemoteModel], engineer: String, contextBuilder: String)] = [
            ("before discovery", [], "gpt-5.6-sol-medium", "gpt-5.6-sol-low"),
            ("GPT-6 discovered", CodexDiscoveryTestState.gpt6Models(), "gpt-6-sol-medium", "gpt-6-sol-low"),
            ("GPT-6.1 discovered", CodexDiscoveryTestState.gpt61Models(), "gpt-6.1-sol-medium", "gpt-6.1-sol-low"),
            ("GPT-6.1 Low only", Self.gpt61LowOnlyModels(), "gpt-5.6-sol-medium", "gpt-6.1-sol-low")
        ]
        for state in discoveryStates {
            CodexDiscoveryTestState.setDiscoveredModels(state.models)
            let resolutions = MCPAgentRoleDefaultsService.resolutions(
                availability: availability,
                recommendedAvailability: availability,
                settingsStore: fixture.store
            )
            let effective = Dictionary(uniqueKeysWithValues: resolutions.map { ($0.role, $0.effective) })

            // Overridden roles keep their saved selection; unpinned roles follow discovery.
            XCTAssertEqual(effective[.explore], selection(.codexExec, "gpt-5.6-sol-low"), state.label)
            XCTAssertEqual(effective[.pair], selection(.claudeCode, AgentModel.claudeOpus55.rawValue), state.label)
            XCTAssertEqual(effective[.engineer], selection(.codexExec, state.engineer), state.label)

            let profile = fixture.store.globalAgentModelsProfile()
            XCTAssertEqual(
                AutoRecommendationEngine.resolveContextBuilderSelection(
                    persistedAgentRaw: profile.contextBuilderAgentRaw,
                    persistedModelRaw: profile.contextBuilderModelsByAgent?[AgentProviderKind.codexExec.rawValue],
                    availability: availability
                ),
                selection(.codexExec, "gpt-5.6-sol-high"),
                state.label
            )
            // With nothing saved, startup restore takes the recommendation, which names a newer
            // Sol only once Codex advertises it at Low.
            XCTAssertEqual(
                AutoRecommendationEngine.resolveContextBuilderSelection(
                    persistedAgentRaw: nil,
                    persistedModelRaw: nil,
                    availability: availability
                ),
                selection(.codexExec, state.contextBuilder),
                state.label
            )

            _ = fixture.engine.computeRecommendations(
                for: AgentModelsOperationIdentity(sourceWorkspaceID: UUID(), scope: .global)
            )
            XCTAssertEqual(fixture.store.globalAgentModelsProfile(), saved, state.label)
        }

        // A relaunch reads the same saved choices back from disk.
        let reloaded = fixture.settings.reloadStore().globalAgentModelsProfile()
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.mcpAgentRoleOverrides, overrides)
        XCTAssertEqual(reloaded.contextBuilderModelsByAgent?[AgentProviderKind.codexExec.rawValue], "gpt-5.6-sol-high")
        XCTAssertEqual(reloaded.planningModelRaw, customPlanningRaw)
    }

    // MARK: - Best practice table

    func testBestPracticeTableNamesTheDistributionDefaults() {
        XCTAssertEqual(BestPracticeProfiles.versionCode, 202_609)
        XCTAssertEqual(BestPracticeProfiles.tableTitle, "Best Models by Use Case (GPT-6)")

        XCTAssertEqual(BestPracticeProfiles.bestAgent.modelString, "gpt-6-luna-high")
        XCTAssertEqual(BestPracticeProfiles.bestAgent.agentModel, .gpt6LunaHigh)
        XCTAssertEqual(BestPracticeProfiles.bestContextBuilder.modelString, "gpt-6-sol-low")
        XCTAssertEqual(BestPracticeProfiles.bestContextBuilder.agentModel, .gpt6SolLow)
        XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.modelString, "codex_custom_gpt-6.1-sol-high")
        XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.agentModel, .gpt61SolHigh)
        XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelString, "gpt-6.1-sol")
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

    private struct CodexDefaults {
        let explore: String
        let engineer: String
        let pair: String
        let contextBuilder: String
    }

    private static let gpt61Defaults = CodexDefaults(
        explore: "gpt-6-luna-high",
        engineer: "gpt-6.1-sol-medium",
        pair: "gpt-6.1-sol-high",
        contextBuilder: "gpt-6.1-sol-low"
    )

    /// GPT-6.1 Sol advertising only Low beside a complete GPT-6 Luna.
    private static func gpt61LowOnlyModels() -> [CodexAppServerClient.RemoteModel] {
        [
            CodexDiscoveryTestState.remoteModel("gpt-6.1-sol", efforts: ["low"], isDefault: true),
            CodexDiscoveryTestState.remoteModel("gpt-6-luna", efforts: ["low", "medium", "high", "xhigh", "max"])
        ]
    }

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

    /// Holds the settings fixture too because the engine only references its view model weakly.
    @MainActor
    private struct Fixture {
        let settings: IsolatedAPISettingsFixture
        let engine: AutoRecommendationEngine

        var store: GlobalSettingsStore {
            settings.store
        }

        var apiSettings: APISettingsViewModel {
            settings.apiSettings
        }
    }

    private func makeFixture(name: String = #function) throws -> Fixture {
        let settings = try makeIsolatedAPISettingsFixture(name: name)
        settings.apiSettings.openAIApiKey = "test-key"
        settings.apiSettings.isOpenAIKeyValid = true
        let engine = AutoRecommendationEngine(
            settingsStore: settings.store,
            profileSettingsManager: settings.store,
            apiSettingsViewModel: settings.apiSettings
        )
        return Fixture(settings: settings, engine: engine)
    }
}
