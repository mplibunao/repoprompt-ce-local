import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeCompatiblePluginBridgeTests: XCTestCase {
    func testClaudeCodeCatalogExposesOpus55AcrossAgentSelection() {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: false,
            openCodeAvailable: false
        )
        let options = AgentModelCatalog.options(for: .claudeCode, availability: availability)
        let opus55Options = options.filter { $0.rawValue.hasPrefix("claude-opus-5-5:") }

        XCTAssertEqual(
            opus55Options.map(\.rawValue),
            [
                "claude-opus-5-5:low",
                "claude-opus-5-5:medium",
                "claude-opus-5-5:high",
                "claude-opus-5-5:xhigh",
                "claude-opus-5-5:max"
            ]
        )
        XCTAssertEqual(opus55Options.first?.displayName, "Opus 5.5 Low")
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: "claude-opus-5-5:xhigh",
            for: .claudeCode,
            availability: availability
        ))
        XCTAssertEqual(
            AgentModelCatalog.displayName(
                for: "claude-opus-5-5:xhigh",
                agentKind: .claudeCode,
                availability: availability
            ),
            "Opus 5.5 XHigh"
        )
        XCTAssertTrue(AgentModel.modelsForAgent(.claudeCode).contains(.claudeOpus55))
    }

    func testClaudeCodeCatalogKeepsAgentAndChatPinnedModelsConsistent() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: false,
            openCodeAvailable: false
        )
        let agentOptions = AgentModelCatalog.options(for: .claudeCode, availability: availability)
        let chatMenu = AIModel.claudeCodeMenu(for: AIModel.modelsForProvider(.claudeCode))
        let expectedEfforts = ["low", "medium", "high", "xhigh", "max"]

        // The provider package (through Agent Mode options) and the chat picker must offer the same
        // effort variants; a mismatch lets one surface accept a selection the other rejects.
        for (model, displayName) in [
            (AgentModel.claudeFable52, "Fable 5.2"),
            (.claudeFable51, "Fable 5.1"),
            (.claudeSonnet55, "Sonnet 5.5"),
            (.claudeMythos51, "Mythos 5.1 (Restricted)")
        ] {
            let raw = model.rawValue
            let expectedRaws = expectedEfforts.map { "\(raw):\($0)" }
            XCTAssertEqual(agentOptions.filter { $0.rawValue.hasPrefix("\(raw):") }.map(\.rawValue), expectedRaws, raw)
            let chatGroup = try XCTUnwrap(chatMenu.groups.first { $0.baseModelRaw == raw }, raw)
            XCTAssertEqual(chatGroup.displayName, displayName)
            XCTAssertEqual(chatGroup.options.compactMap(\.model.claudeCodeRuntimeSpecifierRaw), expectedRaws)
            XCTAssertEqual(model.displayName, displayName)
            XCTAssertTrue(AgentModel.modelsForAgent(.claudeCode).contains(model), raw)
            XCTAssertEqual(model.contextWindowTokens, 1_000_000, raw)
            XCTAssertEqual(AgentModel.resolvedModel(forRaw: "\(raw):high", agentKind: .claudeCode), model)
            for effortRaw in ["\(raw):xhigh", "\(raw):max"] {
                XCTAssertTrue(AgentModelCatalog.isValid(rawModel: effortRaw, for: .claudeCode, availability: availability), effortRaw)
            }
            XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "\(raw):ultra", for: .claudeCode, availability: availability))
            XCTAssertNil(ClaudeCodeAIModelCatalog.validatedModel(specifier: "\(raw):ultra"))
        }

        XCTAssertEqual(AgentModel.claudeFable52.discoveryTags, AgentModel.claudeFable51.discoveryTags)
        XCTAssertEqual(AgentModel.claudeSonnet55.discoveryTags, [.balanced, .engineering, .extendedContext])
        XCTAssertEqual(AgentModel.claudeSonnet5.discoveryTags, [])
        // The restricted tier is selectable but never a recommendation target or provider default.
        XCTAssertEqual(AgentModel.claudeMythos51.discoveryTags, [])
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .claudeCode, availability: availability), AgentModel.claudeOpus.rawValue)
        XCTAssertFalse(agentOptions.contains { $0.isProviderDefault && $0.rawValue.hasPrefix(AgentModel.claudeMythos51.rawValue) })
    }

    func testBridgeRuntimeSmokeMapsPluginIDsDiscoveryRuntimeAndHeadlessAdapters() throws {
        let cases: [(AgentProviderKind, String)] = [
            (.claudeCode, "claude-code"),
            (.claudeCodeGLM, "zai-claude-code"),
            (.kimiCode, "kimi-claude-code"),
            (.customClaudeCompatible, "custom-claude-compatible")
        ]

        for (agentKind, expectedPluginID) in cases {
            XCTAssertEqual(ClaudeCompatiblePluginBridge.pluginID(for: agentKind)?.rawValue, expectedPluginID)
            XCTAssertEqual(try ClaudeCompatiblePluginBridge.agentKind(for: XCTUnwrap(ClaudeCompatiblePluginBridge.pluginID(for: agentKind))), agentKind)

            let provider = AgentRuntimeProviderService.shared.makeProvider(
                for: agentKind,
                modelString: "sonnet"
            )
            let adapter = try XCTUnwrap(provider as? ClaudeCompatibleHeadlessProviderAdapter)
            XCTAssertEqual(adapter.runtimeConfig.pluginID.rawValue, expectedPluginID)
            XCTAssertEqual(adapter.runtimeConfig.mode.rawValue, "discovery")
            XCTAssertEqual(adapter.runtimeConfig.commandName, "claude")
            XCTAssertEqual(adapter.runtimeConfig.modelString, "sonnet")
        }
        XCTAssertNil(ClaudeCompatiblePluginBridge.pluginID(for: .codexExec))

        let config = try XCTUnwrap(ClaudeCompatiblePluginBridge.discoveryRuntimeConfig(
            agentKind: .claudeCodeGLM,
            modelString: "sonnet",
            enableDebugLogging: true
        ))
        XCTAssertEqual(config.pluginID.rawValue, "zai-claude-code")
        XCTAssertEqual(config.mode.rawValue, "discovery")
        XCTAssertEqual(config.commandName, "claude")
        XCTAssertEqual(config.permissionMode, "bypassPermissions")
        XCTAssertFalse(config.allowNativeBashTool)
        XCTAssertEqual(config.toolContext.rawValue, "discoverRun")
        XCTAssertTrue(config.mcpStrictMode)
        XCTAssertFalse(config.toolSearchEnabled)
        XCTAssertEqual(config.backendConfig?.id.rawValue, "glmZAI")
    }

    func testGLMOldDefaultSlotMappingMigratesOnConfigLookup() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        let updatedAt = Date(timeIntervalSince1970: 1_703_000_000)
        let oldConfig = oldGLMDefaultConfig(updatedAt: updatedAt)
        try persistConfigs([.glmZAI: oldConfig], defaults: defaults)

        let migrated = store.config(for: .glmZAI)

        XCTAssertEqual(migrated.modelBehavior, ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior)
        XCTAssertEqual(migrated.id, oldConfig.id)
        XCTAssertEqual(migrated.isEnabled, oldConfig.isEnabled)
        XCTAssertEqual(migrated.displayName, oldConfig.displayName)
        XCTAssertEqual(migrated.baseURL, oldConfig.baseURL)
        XCTAssertEqual(migrated.auth, oldConfig.auth)
        XCTAssertEqual(migrated.updatedAt, updatedAt)

        let persisted = try loadPersistedConfig(for: .glmZAI, defaults: defaults)
        XCTAssertEqual(persisted, migrated)

        let secondRead = store.config(for: .glmZAI)
        XCTAssertEqual(secondRead, migrated)
        XCTAssertEqual(secondRead.updatedAt, updatedAt)
    }

    func testGLMPartialLegacySlotMappingMigratesUntouchedSlotsOnly() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        var partiallyCustomized = oldGLMDefaultConfig()
        partiallyCustomized.modelBehavior = .claudeSlotMapping(.init(
            haiku: "glm-4.7",
            sonnet: "glm-5-turbo",
            opus: "custom-opus"
        ))
        try persistConfigs([.glmZAI: partiallyCustomized], defaults: defaults)

        var expected = partiallyCustomized
        expected.modelBehavior = .claudeSlotMapping(.init(
            haiku: "glm-4.5-air",
            sonnet: "glm-5.2[1m]",
            opus: "custom-opus"
        ))

        XCTAssertEqual(store.config(for: .glmZAI), expected)
        XCTAssertEqual(try loadPersistedConfig(for: .glmZAI, defaults: defaults), expected)
    }

    func testGLMFullyCustomSlotMappingDoesNotMigrate() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        var customized = oldGLMDefaultConfig()
        customized.modelBehavior = .claudeSlotMapping(.init(
            haiku: "custom-haiku",
            sonnet: "custom-sonnet",
            opus: "custom-opus"
        ))
        try persistConfigs([.glmZAI: customized], defaults: defaults)

        XCTAssertEqual(store.config(for: .glmZAI), customized)
        XCTAssertEqual(try loadPersistedConfig(for: .glmZAI, defaults: defaults), customized)
    }

    func testGLMMigrationDoesNotAffectNonGLMConfigs() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        let custom = ClaudeCodeCompatibleBackendConfig(
            id: .custom,
            isEnabled: true,
            displayName: "Custom old-looking GLM",
            baseURL: "https://custom.example.test/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "glm-4.7",
                sonnet: "glm-5-turbo",
                opus: "glm-5.1"
            )),
            updatedAt: Date(timeIntervalSince1970: 1_704_000_000)
        )
        let kimi = ClaudeCodeCompatibleBackendConfig(
            id: .kimi,
            isEnabled: true,
            displayName: "Moonshot",
            baseURL: "https://api.kimi.com/coding/",
            auth: .anthropicAPIKey,
            modelBehavior: .noModel,
            updatedAt: Date(timeIntervalSince1970: 1_705_000_000)
        )
        try persistConfigs([.custom: custom, .kimi: kimi], defaults: defaults)

        XCTAssertEqual(store.config(for: .custom), custom)
        XCTAssertEqual(store.config(for: .kimi), kimi)
        XCTAssertEqual(try loadPersistedConfig(for: .custom, defaults: defaults), custom)
        XCTAssertEqual(try loadPersistedConfig(for: .kimi, defaults: defaults), kimi)
    }

    func testGLMCompatibleBackendPickerLabelsSlotsAndLegacyChoicesDistinctly() throws {
        let restore = installTemporaryOldGLMDefaultSlotMapping()
        defer { restore() }

        let models = ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.glmZAI)
        let menu = AIModel.claudeCodeMenu(for: models)
        let group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "compatible:glmzai" })

        XCTAssertEqual(group.displayName, "Saved CC Zai")
        XCTAssertEqual(group.options.map(\.displayName), [
            "GLM 4.5 Air — Haiku",
            "GLM 5.2 (1M) — Sonnet",
            "GLM 5.2 (1M) — Opus",
            "GLM 4.7",
            "GLM 5 Turbo",
            "GLM 5.1"
        ])
    }

    /// XHigh eligibility is declared in three places: the provider package's
    /// per-model effort lists (read here through the adapter snapshot), the
    /// adapter's eligibility set, and the AI picker's model definitions. This
    /// guards against the hand-synced copies drifting apart.
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "ClaudeCompatiblePluginBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func oldGLMDefaultConfig(updatedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> ClaudeCodeCompatibleBackendConfig {
        ClaudeCodeCompatibleBackendConfig(
            id: .glmZAI,
            isEnabled: false,
            displayName: "Saved CC Zai",
            baseURL: "https://saved.example.test/api/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "glm-4.7",
                sonnet: "glm-5-turbo",
                opus: "glm-5.1"
            )),
            updatedAt: updatedAt
        )
    }

    private func persistConfigs(
        _ configs: [ClaudeCodeCompatibleBackendID: ClaudeCodeCompatibleBackendConfig],
        defaults: UserDefaults
    ) throws {
        let keyedConfigs = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
        let data = try JSONEncoder().encode(keyedConfigs)
        defaults.set(data, forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
    }

    private func loadPersistedConfig(
        for id: ClaudeCodeCompatibleBackendID,
        defaults: UserDefaults
    ) throws -> ClaudeCodeCompatibleBackendConfig {
        let data = try XCTUnwrap(defaults.data(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey))
        let configs = try JSONDecoder().decode([String: ClaudeCodeCompatibleBackendConfig].self, from: data)
        return try XCTUnwrap(configs[id.rawValue])
    }

    private func installTemporaryOldGLMDefaultSlotMapping() -> () -> Void {
        let defaults = UserDefaults.standard
        let store = ClaudeCodeCompatibleBackendStore.shared
        let configsKey = ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        let configuredKey = store.configuredDefaultsKey(for: .glmZAI)
        let legacyConfiguredKey = ClaudeCodeGLMIntegration.configuredDefaultsKey
        let previousConfigs = defaults.data(forKey: configsKey)
        let previousConfigured = defaults.object(forKey: configuredKey)
        let previousLegacyConfigured = defaults.object(forKey: legacyConfiguredKey)

        try? persistConfigs([.glmZAI: oldGLMDefaultConfig()], defaults: defaults)
        _ = store.setConfigured(true, for: .glmZAI)

        return {
            if let previousConfigs {
                defaults.set(previousConfigs, forKey: configsKey)
            } else {
                defaults.removeObject(forKey: configsKey)
            }
            if let previousConfigured {
                defaults.set(previousConfigured, forKey: configuredKey)
            } else {
                defaults.removeObject(forKey: configuredKey)
            }
            if let previousLegacyConfigured {
                defaults.set(previousLegacyConfigured, forKey: legacyConfiguredKey)
            } else {
                defaults.removeObject(forKey: legacyConfiguredKey)
            }
        }
    }

    private func installTemporaryCustomSlotMapping() -> () -> Void {
        let defaults = UserDefaults.standard
        let store = ClaudeCodeCompatibleBackendStore.shared
        let configsKey = ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        let configuredKey = store.configuredDefaultsKey(for: .custom)
        let previousConfigs = defaults.data(forKey: configsKey)
        let previousConfigured = defaults.object(forKey: configuredKey)

        store.saveConfig(ClaudeCodeCompatibleBackendConfig(
            id: .custom,
            isEnabled: true,
            displayName: "CC Custom GLM",
            baseURL: "https://example.test/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "custom-fast",
                sonnet: "glm-5.2[1m]",
                opus: "glm-5.2"
            ))
        ))
        _ = store.setConfigured(true, for: .custom)

        return {
            if let previousConfigs {
                defaults.set(previousConfigs, forKey: configsKey)
            } else {
                defaults.removeObject(forKey: configsKey)
            }
            if let previousConfigured {
                defaults.set(previousConfigured, forKey: configuredKey)
            } else {
                defaults.removeObject(forKey: configuredKey)
            }
        }
    }
}

#if DEBUG
    @MainActor
    final class ClaudeCompactionContextUsageTests: XCTestCase {
        func testCompactionBoundaryWaitsForFreshOccupancy() async throws {
            for trigger in ["manual", "auto"] {
                let viewModel = makeViewModel()
                let session = viewModel.session(for: UUID())
                defer { session.saveDebounceTask?.cancel() }
                session.selectedAgent = .claudeCode
                session.appendItem(.user(String(repeating: "Pre-compaction transcript context. ", count: 1000)))
                let runID = UUID()
                let attemptID = UUID()
                session.installRunID(runID)
                session.beginRunAttempt(source: "compaction-replay", attemptID: attemptID)
                var translator = ClaudeSDKNDJSONTranslator()
                let sidebar = AgentRuntimeSidebarViewModel()
                func consume(_ line: String) async {
                    for result in translator.parseNDJSONLine(Data(line.utf8)) {
                        await viewModel.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
                    }
                    sidebar.update(
                        snapshot: AgentTranscriptAnalyticsBuilder.build(from: session.transcript, selectedAgent: session.selectedAgent),
                        codexUsage: session.codexContextUsage
                    )
                }
                func billedTokens() -> Int {
                    session.providerTokenUsageByTurn.map(\.providerTotalTokens).reduce(0, +)
                }
                // The translator retains the first session_id it sees, so later fixtures omit it. Init repeats it as a real one does.
                let sessionID = "72c65f88-2b76-4406-9b32-93d61df09272"
                let usage = #"{"type":"assistant","session_id":"\#(sessionID)","message":{"id":"msg_before_compaction","role":"assistant","content":[],"usage":{"input_tokens":1000,"cache_read_input_tokens":149000,"output_tokens":10}}}"#
                let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done","duration_ms":100,"duration_api_ms":100,"num_turns":1,"total_cost_usd":0,"usage":{"input_tokens":150000,"output_tokens":10},"modelUsage":{"claude-sonnet-4-6":{"contextWindow":200000}}}"#
                viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Earlier turn", submissionID: nil)
                await consume(usage)
                await consume(result)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 150_000, trigger)
                await consume(#"{"type":"system","subtype":"task_notification","task_id":"worker-1","status":"completed","summary":"Context compacted inside worker task"}"#)
                await consume(#"{"type":"system","message":"The worker reported context compacted successfully"}"#)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 150_000, "\(trigger): task prose is not a compaction boundary")
                XCTAssertFalse(session.providerTokenUsageByTurn.contains(where: \.contextCompacted), trigger)

                viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "/compact", submissionID: nil)
                // Automatic compaction can occur after this turn already reported its old context.
                if trigger == "auto" {
                    await consume(usage)
                }
                let rowsBeforeBoundary = session.providerTokenUsageByTurn.count
                let billedBeforeBoundary = billedTokens()
                let userEstimateBeforeBoundary = try XCTUnwrap(session.activeNonCodexTurnTokenAccumulator).estimatedUserInputTokens
                await consume(#"{"type":"system","subtype":"status","status":"compacting"}"#)
                await consume("{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compact_metadata\":{\"trigger\":\"\(trigger)\",\"pre_tokens\":150000}}")
                XCTAssertNil(session.contextUsageSnapshot?.used, trigger)
                XCTAssertNotNil(session.contextUsageSnapshot?.compactedAt, trigger)
                XCTAssertNil(sidebar.snapshot.usedTokens, trigger)
                XCTAssertEqual(sidebar.snapshot.contextWindowTokens, 200_000, trigger)
                XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage, trigger)
                XCTAssertEqual(sidebar.snapshot.usageSource, .awaitingPostCompaction, trigger)
                XCTAssertEqual(sidebar.snapshot.displayUsageLabel, "Awaiting post-compaction usage", trigger)
                XCTAssertGreaterThan(try XCTUnwrap(sidebar.snapshot.estimatedTranscriptTokens), 0, trigger)
                XCTAssertNil(sidebar.snapshot.displayUsedTokens, "\(trigger): never substitute the whole historical transcript while pending")
                let accumulator = try XCTUnwrap(session.activeNonCodexTurnTokenAccumulator)
                XCTAssertNil(accumulator.observedContextUsedTokens, trigger)
                XCTAssertEqual(accumulator.estimatedUserInputTokens, userEstimateBeforeBoundary, "\(trigger): input estimates survive the boundary")
                XCTAssertEqual(session.providerTokenUsageByTurn.count, rowsBeforeBoundary + 1, trigger)
                let fence = try XCTUnwrap(session.providerTokenUsageByTurn.last)
                XCTAssertTrue(fence.contextCompacted, trigger)
                XCTAssertNil(fence.contextUsedTokens, trigger)
                XCTAssertEqual(fence.estimatedInputTokens, 0, trigger)
                XCTAssertEqual(billedTokens(), billedBeforeBoundary, "\(trigger): a compaction fence is not billable usage")

                if trigger == "manual" {
                    // Init has no post-compaction size; result usage is a billed aggregate, not occupancy.
                    await consume(#"{"type":"system","subtype":"init","session_id":"\#(sessionID)","model":"claude-sonnet-4-6"}"#)
                    await viewModel.test_handleStreamResult(
                        AIStreamResult(type: "usage", text: nil, promptTokens: 150_000),
                        session: session, runID: runID, runAttemptID: attemptID
                    )
                    XCTAssertNil(session.contextUsageSnapshot?.used, "Billed input alone cannot establish post-compaction occupancy")
                    await consume(result)
                    XCTAssertNil(sidebar.snapshot.usedTokens, "Finalization must not restore old context")
                    XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage)
                    XCTAssertNil(session.providerTokenUsageByTurn.last?.contextUsedTokens)
                    viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Continue", submissionID: nil)
                    await consume(result)
                    XCTAssertNil(sidebar.snapshot.usedTokens, "Unmeasured later turns must remain unknown")
                    XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage)
                    viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Fresh measurement", submissionID: nil)
                }

                // Auto-compaction resumes the same turn with a new API context; manual compaction
                // measures in the fresh turn started above.
                await consume(#"{"type":"assistant","message":{"id":"msg_after_compaction","role":"assistant","content":[],"usage":{"input_tokens":2000,"cache_read_input_tokens":8000,"output_tokens":10}}}"#)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 10000, trigger)
                XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage, trigger)
                await consume(result)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 10000, trigger)
                XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage, trigger)
                XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 10000, trigger)

                if trigger == "auto" {
                    viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Unmeasured after recovery", submissionID: nil)
                    await consume(result)
                    XCTAssertEqual(sidebar.snapshot.usedTokens, 10000)
                    XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage)
                    // A fresh reading outside any billed turn, then a terminal finalization without
                    // counters: the reading must reach the rows, or reopening rebuilds to pending.
                    await consume(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":10000}}"#)
                    await consume(#"{"type":"assistant","message":{"id":"msg_unbilled","role":"assistant","content":[],"usage":{"input_tokens":1000,"cache_read_input_tokens":4000,"output_tokens":10}}}"#)
                    viewModel.finalizeNonCodexTurnUsageIfNeeded(for: session, promptTokens: nil, completionTokens: nil, contextUsedTokens: nil)
                    XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 5000)
                    XCTAssertEqual(
                        AgentModeViewModel.contextUsageFromClaudeProviderTokens(session.providerTokenUsageByTurn, modelContextWindow: 200_000)?.lastTotalTokens,
                        5000
                    )
                }
            }
        }

        func testRebuildStopsAtLatestCompactionFence() {
            let measured = AgentTokenUsagePersist(promptTokens: 150_000, completionTokens: 10, contextUsedTokens: 150_000)
            let fence = AgentTokenUsagePersist(promptTokens: 0, completionTokens: 0, contextCompacted: true)
            let unmeasured = AgentTokenUsagePersist(promptTokens: 42, completionTokens: 5)
            let fresh = AgentTokenUsagePersist(promptTokens: 1000, completionTokens: 10, contextUsedTokens: 10000)
            let cases: [(label: String, rows: [AgentTokenUsagePersist], window: Int?, used: Int?, pending: Bool)] = [
                ("fence without a known window", [measured, fence], nil, nil, true),
                ("unmeasured rows after the fence", [measured, fence, unmeasured], 200_000, nil, true),
                ("fresh occupancy after the fence", [measured, fence, fresh, unmeasured], 200_000, 10000, false),
                ("a later fence after fresh occupancy", [measured, fence, fresh, fence], 200_000, nil, true)
            ]
            for testCase in cases {
                let rebuilt = AgentModeViewModel.contextUsageFromClaudeProviderTokens(testCase.rows, modelContextWindow: testCase.window)
                XCTAssertEqual(rebuilt?.lastTotalTokens, testCase.used, testCase.label)
                XCTAssertEqual(rebuilt?.awaitingPostCompactionUsage == true, testCase.pending, testCase.label)
                XCTAssertEqual(rebuilt?.modelContextWindow, testCase.window, testCase.label)
            }
        }

        func testProviderSwitchClearsPendingUsageWithoutDroppingWindow() throws {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            session.appendItem(.user("Historical transcript retained across the provider switch."))
            session.codexContextUsage = AgentContextUsage(
                modelContextWindow: 200_000,
                lastTotalTokens: nil,
                totalTotalTokens: nil,
                awaitingPostCompactionUsage: true
            )
            let sidebar = AgentRuntimeSidebarViewModel()
            func refreshSidebar() {
                sidebar.update(items: session.items, codexUsage: session.codexContextUsage)
            }
            refreshSidebar()
            XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage)
            XCTAssertNil(sidebar.snapshot.displayUsedTokens)

            // No coordinator clears usage on a Claude to Claude-compatible switch; the session does.
            session.selectedAgent = .claudeCodeGLM
            refreshSidebar()

            XCTAssertNil(session.codexContextUsage?.awaitingPostCompactionUsage)
            let glmWindow = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
                forRequestedModelRaw: session.selectedModelRaw,
                agentKind: .claudeCodeGLM
            ))
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, glmWindow, "The window stays, resized for the new provider")
            XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage)
            XCTAssertEqual(sidebar.snapshot.usageSource, .unavailable, "A window without occupancy is not Live")
            XCTAssertGreaterThan(try XCTUnwrap(sidebar.snapshot.displayUsedTokens), 0)
            XCTAssertEqual(sidebar.snapshot.displayUsageLabel, "Estimated")
        }

        func testPendingUsageSurvivesHydrationAndHistoryReopen() async throws {
            // Rows saved before fences existed carry no key and are ordinary measurements.
            let legacyRow = try JSONDecoder().decode(
                AgentTokenUsagePersist.self,
                from: Data(#"{"promptTokens":150000,"completionTokens":10,"contextUsedTokens":150000,"timestamp":0}"#.utf8)
            )
            XCTAssertFalse(legacyRow.contextCompacted)

            let fixture = try await TemporaryAgentSessionWindow.make(name: "ClaudeCompactionHydration")
            defer { fixture.tearDown() }
            let viewModel = fixture.viewModel
            let tabID = fixture.tabID
            let oldRequest = AgentChatItem.user(String(repeating: "Old context. ", count: 1000))
            let storedTranscript = AgentTranscript(turns: [AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(from: oldRequest),
                terminalState: .completed,
                startedAt: oldRequest.timestamp,
                completedAt: oldRequest.timestamp
            )], nextSequenceIndex: 1)
            let compactedAt = Date(timeIntervalSince1970: 100)
            // A measured turn, the compaction fence, then a billing-only turn with no occupancy.
            let rows = [
                legacyRow,
                AgentTokenUsagePersist(promptTokens: 0, completionTokens: 0, contextCompacted: true, timestamp: compactedAt),
                AgentTokenUsagePersist(promptTokens: 150_000, completionTokens: 10)
            ]
            func save(_ usage: [AgentTokenUsagePersist], staleStoredCount: Int? = nil) async throws -> UUID {
                let id = UUID()
                try await fixture.save(AgentSession(
                    id: id, workspaceID: fixture.workspace.id, composeTabID: tabID, name: "Compacted Claude",
                    transcript: storedTranscript, agentKind: AgentProviderKind.claudeCode.rawValue,
                    agentModel: "claude-sonnet-4-6", lastRunState: "completed", providerTokenUsageByTurn: usage,
                    codexContextWindow: 200_000, codexLastTotalTokens: staleStoredCount, codexTotalTotalTokens: staleStoredCount
                ))
                return id
            }
            func assertPending(_ session: AgentTabSession, file: StaticString = #filePath, line: UInt = #line) {
                let sidebar = AgentRuntimeSidebarViewModel()
                XCTAssertFalse(session.transcript.turns.isEmpty, file: file, line: line)
                sidebar.update(
                    snapshot: AgentTranscriptAnalyticsBuilder.build(from: session.transcript, selectedAgent: session.selectedAgent),
                    codexUsage: session.codexContextUsage
                )
                XCTAssertGreaterThan(sidebar.snapshot.estimatedTranscriptTokens ?? 0, 0, file: file, line: line)
                XCTAssertNil(sidebar.snapshot.displayUsedTokens, file: file, line: line)
                XCTAssertEqual(sidebar.snapshot.displayUsageLabel, "Awaiting post-compaction usage", file: file, line: line)
                XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage, file: file, line: line)
                XCTAssertNil(session.codexContextUsage?.lastTotalTokens, file: file, line: line)
                XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 200_000, file: file, line: line)
                XCTAssertEqual(session.contextCompactedAt, compactedAt, file: file, line: line)
            }

            let initialID = try await save(rows)
            let initial = viewModel.session(for: tabID)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: initialID, on: initial, updateWorkspaceMetadata: true))
            initial.hasLoadedPersistedState = false
            let hydrated = await viewModel.ensureSessionReady(tabID: tabID)
            XCTAssertEqual(hydrated.activeAgentSessionID, initialID)
            assertPending(hydrated)

            // A different saved conversation takes the history route, and its stale flattened
            // count must not override the fence.
            let historyID = try await save(rows, staleStoredCount: 150_000)
            let routed = await viewModel.activateRoutedAgentSession(tabID: tabID, sessionID: historyID, workspace: fixture.workspace)
            XCTAssertEqual(routed, .ready)
            let reopened = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(reopened.activeAgentSessionID, historyID)
            assertPending(reopened)

            let fresh = AgentTokenUsagePersist(promptTokens: 1000, completionTokens: 10, contextUsedTokens: 10000)
            let recoveredID = try await save(rows + [fresh, AgentTokenUsagePersist(promptTokens: 500, completionTokens: 5)])
            let recoveredRoute = await viewModel.activateRoutedAgentSession(tabID: tabID, sessionID: recoveredID, workspace: fixture.workspace)
            XCTAssertEqual(recoveredRoute, .ready)
            let recovered = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(recovered.activeAgentSessionID, recoveredID)
            XCTAssertEqual(recovered.codexContextUsage?.lastTotalTokens, 10000)
            XCTAssertNotEqual(recovered.codexContextUsage?.awaitingPostCompactionUsage, true)
        }

        private func makeViewModel() -> AgentModeViewModel {
            AgentModeViewModel(
                testWindowID: -972,
                testWorkspacePath: FileManager.default.currentDirectoryPath,
                codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Usage replay must not launch a provider") },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }
            )
        }
    }

    /// Records saved before capacities were stored hold only the effective window, which may have
    /// been an auto-compact cap. Restoring one must not turn it into a ceiling or a lasting
    /// denominator; a stored capacity bounds restored rows, and each runtime init re-derives the window.
    @MainActor
    final class ClaudeContextWindowCapacityRestoreTests: XCTestCase {
        func testLegacyCappedRecordAndCapacityRecordRestore() async throws {
            let fixture = try await TemporaryAgentSessionWindow.make(name: "ClaudeCapacityRestore")
            defer { fixture.tearDown() }
            let viewModel = fixture.viewModel
            let tabID = fixture.tabID
            let request = AgentChatItem.user("Capacity restore")
            let transcript = AgentTranscript(turns: [AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(from: request),
                terminalState: .completed,
                startedAt: request.timestamp,
                completedAt: request.timestamp
            )], nextSequenceIndex: 1)
            // A 200K catalog model whose sessions were saved under a 150K cap.
            let model = "opus"
            func save(_ rows: [AgentTokenUsagePersist], capacity: AgentContextWindowCapacity?) async throws -> UUID {
                let id = UUID()
                try await fixture.save(AgentSession(
                    id: id, workspaceID: fixture.workspace.id, composeTabID: tabID, name: "Capped Claude",
                    transcript: transcript, agentKind: AgentProviderKind.claudeCode.rawValue,
                    agentModel: model, lastRunState: "completed", providerTokenUsageByTurn: rows,
                    codexContextWindow: 150_000, contextWindowCapacity: capacity
                ))
                return id
            }
            func runtimeInit(cap: Int?, _ session: AgentTabSession) {
                _ = viewModel.claudeCoordinator.observeRuntimeInit(
                    .init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: cap),
                    session: session
                )
            }
            func route(to sessionID: UUID) async throws -> AgentTabSession {
                let routed = await viewModel.activateRoutedAgentSession(tabID: tabID, sessionID: sessionID, workspace: fixture.workspace)
                XCTAssertEqual(routed, .ready)
                return try XCTUnwrap(viewModel.sessions[tabID])
            }

            // Legacy: a 180K reading taken under the 150K cap, saved without a capacity.
            let legacyID = try await save(
                [AgentTokenUsagePersist(promptTokens: 180_000, completionTokens: 10, contextUsedTokens: 180_000)],
                capacity: nil
            )
            let initial = viewModel.session(for: tabID)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: legacyID, on: initial, updateWorkspaceMetadata: true))
            initial.hasLoadedPersistedState = false
            let legacy = await viewModel.ensureSessionReady(tabID: tabID)
            XCTAssertEqual(legacy.selectedModelRaw, model)
            XCTAssertNil(legacy.contextWindowCapacity, "A stored window is never promoted to capacity")
            XCTAssertEqual(legacy.codexContextUsage?.lastTotalTokens, 180_000, "The legacy cap is not a ceiling")
            XCTAssertEqual(legacy.codexContextUsage?.modelContextWindow, 150_000, "It stays as historical display data")
            runtimeInit(cap: nil, legacy)
            XCTAssertNil(legacy.codexContextUsage?.modelContextWindow, "An uncapped process does not keep the legacy cap")

            let capacity = AgentContextWindowCapacity(
                tokens: 200_000,
                agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: AgentContextWindowCapacity.modelKey(forRaw: model)
            )
            let currentID = try await save([
                AgentTokenUsagePersist(promptTokens: 190_000, completionTokens: 10, contextUsedTokens: 190_000),
                AgentTokenUsagePersist(promptTokens: 250_000, completionTokens: 10, contextUsedTokens: 250_000)
            ], capacity: capacity)
            let current = try await route(to: currentID)
            XCTAssertEqual(current.contextWindowCapacity, capacity)
            XCTAssertEqual(current.codexContextUsage?.lastTotalTokens, 190_000, "The stored capacity rejects an impossible row")
            XCTAssertEqual(current.codexContextUsage?.modelContextWindow, 150_000)
            let inits: [(label: String, cap: Int?, window: Int)] = [
                ("an uncapped process shows the capacity", nil, 200_000),
                ("a capped process shows its cap", 160_000, 160_000)
            ]
            for initCase in inits {
                runtimeInit(cap: initCase.cap, current)
                XCTAssertEqual(current.codexContextUsage?.modelContextWindow, initCase.window, initCase.label)
                XCTAssertEqual(current.codexContextUsage?.lastTotalTokens, 190_000, initCase.label)
            }

            // A baseline event with the stored capacity first replaces the hydrated snapshot with a live
            // usage one. A new capacity under the same cap then leaves both the window and the snapshot
            // as they were, so only the capacity change itself can schedule its save.
            let runID = UUID()
            let attemptID = UUID()
            current.installRunID(runID)
            _ = current.beginRunAttempt(source: "capacity-save", attemptID: attemptID)
            func reportCapacity(_ tokens: Int) async {
                await viewModel.test_handleStreamResult(
                    AIStreamResult(type: "usage", text: nil, modelContextWindow: tokens),
                    session: current, runID: runID, runAttemptID: attemptID
                )
            }
            await reportCapacity(200_000)
            await viewModel.flushSave(for: tabID)
            let baseline = try XCTUnwrap(current.contextUsageSnapshot)
            XCTAssertEqual(baseline.source, .claudeUsageEvent, "The baseline event replaces the hydrated snapshot")
            let saveGeneration = current.saveRequestGeneration
            await reportCapacity(300_000)
            XCTAssertEqual(current.contextUsageSnapshot, baseline, "A capacity-only report does not change the snapshot")
            XCTAssertEqual(current.codexContextUsage?.modelContextWindow, 160_000)
            XCTAssertGreaterThan(current.saveRequestGeneration, saveGeneration, "A capacity-only change schedules a save")
            _ = current.endCurrentRunAttempt(source: "capacity-save")
            await viewModel.flushSave(for: tabID)

            // Reopening the legacy record in the same tab takes neither the capacity nor the cap along.
            let reopened = try await route(to: legacyID)
            XCTAssertNil(reopened.contextWindowCapacity)
            XCTAssertNil(reopened.claudeAutoCompactWindowTokens)
            XCTAssertEqual(reopened.codexContextUsage?.lastTotalTokens, 180_000)

            let resaved = try await route(to: currentID)
            XCTAssertEqual(resaved.contextWindowCapacity?.tokens, 300_000, "The app's own save persisted the new capacity")
        }
    }

    /// A registered window whose ephemeral workspace saves agent sessions under a temporary root.
    @MainActor
    private final class TemporaryAgentSessionWindow {
        let window: WindowState
        let tabID: UUID
        private let root: URL
        private let workspaceID: UUID

        var viewModel: AgentModeViewModel {
            window.agentModeViewModel
        }

        var workspace: WorkspaceModel {
            guard let workspace = window.workspaceManager.workspaces.first(where: { $0.id == workspaceID }) else {
                preconditionFailure("The fixture workspace was removed during the test")
            }
            return workspace
        }

        private init(window: WindowState, tabID: UUID, root: URL, workspaceID: UUID) {
            self.window = window
            self.tabID = tabID
            self.root = root
            self.workspaceID = workspaceID
        }

        static func make(name: String) async throws -> TemporaryAgentSessionWindow {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            do {
                await window.workspaceManager.awaitInitialized()
                let created = window.workspaceManager.createWorkspace(name: name, repoPaths: [root.path], ephemeral: true)
                await window.workspaceManager.switchWorkspace(to: created, saveState: false, reason: "temporaryAgentSessionWindow")
                let active = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                window.promptManager.loadComposeTabsFromWorkspace(active, syncPromptText: true)
                let tabID = try XCTUnwrap(active.activeComposeTabID)
                let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == active.id })
                window.workspaceManager.workspaces[index].customStoragePath = root.appendingPathComponent("sessions", isDirectory: true)
                return TemporaryAgentSessionWindow(window: window, tabID: tabID, root: root, workspaceID: active.id)
            } catch {
                WindowStatesManager.shared.unregisterWindowState(window)
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func save(_ session: AgentSession) async throws {
            _ = try await AgentSessionDataService.shared.saveAgentSession(session, for: workspace)
        }

        func tearDown() {
            for session in viewModel.sessions.values {
                session.saveDebounceTask?.cancel()
            }
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: root)
        }
    }
#endif
