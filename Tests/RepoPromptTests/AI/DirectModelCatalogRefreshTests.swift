import Foundation
@testable import RepoPromptApp
import XCTest

/// Direct OpenAI, Azure OpenAI, Anthropic, and OpenRouter entries are verified only by these
/// deterministic checks (no live request runs), so each row pins the persisted UI raw, the wire
/// identity, and the effort the provider actually sends.
final class DirectModelCatalogRefreshTests: XCTestCase {
    private struct OpenAIRow {
        let model: AIModel
        let raw: String
        let wireModel: String
        let effort: String
        let displayName: String
    }

    private let openAIRows: [OpenAIRow] = [
        .init(model: .gpt61Sol, raw: "gpt-6.1-sol", wireModel: "gpt-6.1-sol", effort: "medium", displayName: "GPT-6.1 Sol Med"),
        .init(model: .gpt61SolLow, raw: "gpt-6.1-sol-low", wireModel: "gpt-6.1-sol", effort: "low", displayName: "GPT-6.1 Sol Low"),
        .init(model: .gpt61SolHigh, raw: "gpt-6.1-sol-high", wireModel: "gpt-6.1-sol", effort: "high", displayName: "GPT-6.1 Sol High"),
        .init(model: .gpt61SolXHigh, raw: "gpt-6.1-sol-xhigh", wireModel: "gpt-6.1-sol", effort: "xhigh", displayName: "GPT-6.1 Sol XHigh"),
        .init(model: .gpt61SolMax, raw: "gpt-6.1-sol-max", wireModel: "gpt-6.1-sol", effort: "max", displayName: "GPT-6.1 Sol Max"),
        .init(model: .gpt6Astra, raw: "gpt-6-astra", wireModel: "gpt-6-astra", effort: "medium", displayName: "GPT-6 Astra Med"),
        .init(model: .gpt6AstraLow, raw: "gpt-6-astra-low", wireModel: "gpt-6-astra", effort: "low", displayName: "GPT-6 Astra Low"),
        .init(model: .gpt6AstraHigh, raw: "gpt-6-astra-high", wireModel: "gpt-6-astra", effort: "high", displayName: "GPT-6 Astra High"),
        .init(model: .gpt6AstraXHigh, raw: "gpt-6-astra-xhigh", wireModel: "gpt-6-astra", effort: "xhigh", displayName: "GPT-6 Astra XHigh"),
        .init(model: .gpt6AstraMax, raw: "gpt-6-astra-max", wireModel: "gpt-6-astra", effort: "max", displayName: "GPT-6 Astra Max"),
        .init(model: .gpt6Luna, raw: "gpt-6-luna", wireModel: "gpt-6-luna", effort: "medium", displayName: "GPT-6 Luna Med"),
        .init(model: .gpt6LunaLow, raw: "gpt-6-luna-low", wireModel: "gpt-6-luna", effort: "low", displayName: "GPT-6 Luna Low"),
        .init(model: .gpt6LunaHigh, raw: "gpt-6-luna-high", wireModel: "gpt-6-luna", effort: "high", displayName: "GPT-6 Luna High"),
        .init(model: .gpt6LunaXHigh, raw: "gpt-6-luna-xhigh", wireModel: "gpt-6-luna", effort: "xhigh", displayName: "GPT-6 Luna XHigh"),
        .init(model: .gpt6Sol, raw: "gpt-6-sol", wireModel: "gpt-6-sol", effort: "medium", displayName: "GPT-6 Sol Med")
    ]

    func testOpenAIRefreshVariantsRoundTripAndResolveWireEfforts() {
        let provider = OpenAIProvider(apiKey: "test-key")
        let message = AIMessage(systemPrompt: "system", userMessage: "user")
        let openAIModels = Set(AIModel.modelsForProvider(.openAI))

        for row in openAIRows {
            XCTAssertEqual(row.model.rawValue, row.raw)
            XCTAssertEqual(AIModel.fromModelName(row.raw), row.model, row.raw)
            XCTAssertTrue(openAIModels.contains(row.model), row.raw)
            XCTAssertEqual(row.model.providerType, .openAI, row.raw)
            XCTAssertEqual(row.model.displayName, row.displayName)
            XCTAssertTrue(row.model.usesResponsesAPI, row.raw)
            XCTAssertEqual(row.model.defaultReasoningEffort, row.effort, row.raw)

            // Production resolves the cap first and hands it to the builder; the builder must still
            // leave it to the API for first-party GPT-6 models.
            let resolvedMaxTokens = provider.resolvedResponseMaxTokens(for: row.model, override: nil)
            XCTAssertEqual(resolvedMaxTokens, 128_000, row.raw)
            // The suffixed UI raw must never reach the API as the model name.
            for stream in [false, true] {
                let parameters = provider.buildForegroundResponseParameters(message, model: row.model, maxTokens: resolvedMaxTokens, stream: stream)
                XCTAssertEqual(parameters.model, row.wireModel, row.raw)
                XCTAssertEqual(parameters.reasoning?.effort, row.effort, row.raw)
                XCTAssertNil(parameters.maxOutputTokens, "First-party GPT-6 requests leave the output cap to the API: \(row.raw)")
            }
        }

        // The direct effort set has no Medium raw, no Ultra, and no Luna Max.
        for raw in ["gpt-6.1-sol-medium", "gpt-6.1-sol-ultra", "gpt-6-astra-ultra", "gpt-6-luna-max", "gpt-6-sol-high"] {
            XCTAssertNil(AIModel.fromModelName(raw), raw)
        }

        // Saved custom raws keep their exact representation instead of becoming new built-ins.
        let savedReasoning = AIModel.fromModelName("openai_custom_reasoning_high__gpt-6-sol")
        XCTAssertEqual(savedReasoning, .openaiCustomReasoning(name: "gpt-6-sol", effort: .high))
        XCTAssertEqual(savedReasoning?.rawValue, "openai_custom_reasoning_high__gpt-6-sol")
        XCTAssertEqual(AIModel.fromModelName("openai_custom_gpt-6.1-sol"), .openaiCustom(name: "gpt-6.1-sol"))
    }

    func testAzureRefreshVariantsPreserveDeploymentAndEffort() throws {
        let rowsByRaw = Dictionary(uniqueKeysWithValues: openAIRows.map { ($0.raw, $0) })
        let unconfigured = try azureProvider(models: [])

        // Generated catalog entries (offered as app-settings model candidates) carry an internal
        // marker; they must still reach the base-model deployment with the variant's effort.
        let generatedEntries = AIModel.allModels().filter { $0.providerType == .azure && rowsByRaw[$0.modelName] != nil }
        XCTAssertEqual(Set(generatedEntries.map(\.modelName)), Set(rowsByRaw.keys))
        for entry in generatedEntries {
            let row = try XCTUnwrap(rowsByRaw[entry.modelName])
            XCTAssertEqual(entry.rawValue, "azure_custom___azure_default__\(row.raw)")
            XCTAssertEqual(AIModel.fromModelName(entry.rawValue), entry)
            XCTAssertEqual(entry.displayName, "azure/\(row.displayName)")
            try assertRoute(unconfigured.requestRoute(for: entry), deploymentID: row.wireModel, row: row)
        }

        // Settings picker entries are built from the default deployment descriptors.
        let pickerEntries = AzureOpenAIProvider.prioritizedDeployments(from: AzureOpenAIProvider.defaultModelDescriptors)
            .map { AIModel.azureCustom(name: $0.id) }
            .filter { rowsByRaw[$0.modelName] != nil }
        XCTAssertEqual(Set(pickerEntries.map(\.modelName)), Set(rowsByRaw.keys))
        for entry in pickerEntries {
            let row = try XCTUnwrap(rowsByRaw[entry.modelName])
            XCTAssertEqual(entry.displayName, "azure/\(row.displayName)")
            try assertRoute(unconfigured.requestRoute(for: entry), deploymentID: row.wireModel, row: row)
        }

        // A configured deployment ID is authoritative, including one named exactly like a variant;
        // the catalog model behind it still supplies the effort.
        let configured = try azureProvider(models: [
            .init(id: "prod-sol", displayName: "Prod Sol", baseModelID: "gpt-6.1-sol-xhigh"),
            .init(id: "gpt-6.1-sol-high", baseModelID: "gpt-6.1-sol-high"),
            .init(id: "gpt-6-astra-max", baseModelID: "gpt-6-astra-max"),
            .init(id: "gpt-6-luna-low", baseModelID: "gpt-6-luna-low")
        ])
        try assertRoute(configured.requestRoute(for: .azureCustom(name: "prod-sol")), deploymentID: "prod-sol", row: XCTUnwrap(rowsByRaw["gpt-6.1-sol-xhigh"]))
        for raw in ["gpt-6.1-sol-high", "gpt-6-astra-max", "gpt-6-luna-low"] {
            let row = try XCTUnwrap(rowsByRaw[raw])
            try assertRoute(configured.requestRoute(for: .azureCustom(name: raw)), deploymentID: raw, row: row)
        }
        let olderVariant = try azureProvider(models: [.init(id: "gpt-5.4-high", baseModelID: "gpt-5.4-high")])
        try assertRoute(
            olderVariant.requestRoute(for: .azureCustom(name: "gpt-5.4-high")),
            deploymentID: "gpt-5.4-high",
            row: OpenAIRow(model: .gpt54High, raw: "gpt-5.4-high", wireModel: "gpt-5.4", effort: "high", displayName: "GPT-5.4 High")
        )

        // A variant without its own deployment uses the configured base-model deployment.
        let configuredBase = try azureProvider(models: [.init(id: "gpt-6.1-sol", baseModelID: "gpt-6.1-sol")])
        try assertRoute(
            configuredBase.requestRoute(for: .azureCustom(name: "gpt-6.1-sol-xhigh")),
            deploymentID: "gpt-6.1-sol",
            row: XCTUnwrap(rowsByRaw["gpt-6.1-sol-xhigh"])
        )
    }

    private func azureProvider(models: [AzureOpenAIConfiguration.ModelDescriptor]) throws -> AzureOpenAIProvider {
        try AzureOpenAIProvider(configuration: AzureOpenAIConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://example.openai.azure.com")),
            apiKey: "test-key",
            apiVersion: "2025-04-01-preview",
            models: models
        ))
    }

    private func assertRoute(
        _ route: AzureOpenAIProvider.RequestRoute,
        deploymentID: String,
        row: OpenAIRow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(route.deploymentID, deploymentID, row.raw, file: file, line: line)
        XCTAssertEqual(route.baseModel?.modelName, row.wireModel, row.raw, file: file, line: line)
        XCTAssertEqual(route.reasoningEffort, row.effort, row.raw, file: file, line: line)
        XCTAssertTrue(route.usesResponsesAPI, row.raw, file: file, line: line)
    }

    func testAnthropicAndOpenRouterRefreshRawsStayProviderSpecific() {
        let anthropicRows: [(AIModel, String, String)] = [
            (.claudeSonnet55, "claude-sonnet-5-5", "Claude Sonnet 5.5"),
            (.claudeSonnet5, "claude-sonnet-5", "Claude Sonnet 5"),
            (.claudeOpus55, "claude-opus-5-5", "Claude Opus 5.5"),
            (.claudeOpus5, "claude-opus-5", "Claude Opus 5"),
            (.claudeFable51, "claude-fable-5-1", "Claude Fable 5.1"),
            (.claudeMythos51, "claude-mythos-5-1", "Claude Mythos 5.1 (Restricted)")
        ]
        let anthropicModels = Set(AIModel.modelsForProvider(.anthropic))
        for (model, raw, displayName) in anthropicRows {
            XCTAssertEqual(model.rawValue, raw)
            XCTAssertEqual(AIModel.fromModelName(raw), model, raw)
            XCTAssertTrue(anthropicModels.contains(model), raw)
            XCTAssertEqual(model.providerType, .anthropic, raw)
            XCTAssertEqual(model.modelName, raw)
            XCTAssertEqual(model.displayName, displayName)
        }

        // The Claude Code chat namespace stays distinct from direct Anthropic IDs with the same name.
        let claudeCodeSonnet55 = AIModel.fromModelName("claude_code__claude-sonnet-5-5")
        XCTAssertEqual(claudeCodeSonnet55, .claudeCodeModel(specifier: "claude-sonnet-5-5"))
        XCTAssertEqual(claudeCodeSonnet55?.providerType, .claudeCode)
        XCTAssertNotEqual(claudeCodeSonnet55, .claudeSonnet55)
        XCTAssertEqual(AIModel.fromModelName("claude-sonnet-5-5:high"), .claudeCodeModel(specifier: "claude-sonnet-5-5:high"))

        let openRouterRows: [(AIModel, String, String)] = [
            (.openrouterGpt61Sol, "openai/gpt-6.1-sol", "oRouter/GPT-6.1 Sol"),
            (.openrouterGpt6Astra, "openai/gpt-6-astra", "oRouter/GPT-6 Astra"),
            (.openrouterGpt6Luna, "openai/gpt-6-luna", "oRouter/GPT-6 Luna"),
            (.openrouterClaudeSonnet55, "anthropic/claude-sonnet-5.5", "oRouter/Claude Sonnet 5.5"),
            (.openrouterClaudeOpus55, "anthropic/claude-opus-5.5", "oRouter/Claude Opus 5.5"),
            (.openrouterClaudeFable51, "anthropic/claude-fable-5.1", "oRouter/Claude Fable 5.1")
        ]
        let openRouterModels = AIModel.modelsForProvider(.openRouter)
        for (model, raw, displayName) in openRouterRows {
            XCTAssertEqual(model.rawValue, raw)
            XCTAssertEqual(AIModel.fromModelName(raw), model, raw)
            XCTAssertTrue(openRouterModels.contains(model), raw)
            XCTAssertEqual(model.providerType, .openRouter, raw)
            XCTAssertTrue(model.isOpenRouterModel, raw)
            XCTAssertEqual(model.modelName, raw, "OpenRouter slugs keep their dotted versions on the wire")
            XCTAssertEqual(model.displayName, displayName)
        }
        // Anthropic's hyphenated IDs are not OpenRouter slugs, and restricted Mythos has no preset.
        XCTAssertNil(AIModel.fromModelName("anthropic/claude-sonnet-5-5"))
        XCTAssertFalse(openRouterModels.contains { $0.rawValue.contains("mythos") })
    }

    // MARK: - Priority hints

    /// Each diff list's GPT-6.1 hints, in order, ahead of its GPT-5.6 CLI entries.
    private let gpt61DiffHints: [(name: String, priorities: [AIModel], hints: [String])] = [
        ("simple", AIModel.simpleDiffPriority, ["gpt-6.1-sol-medium", "gpt-6.1-sol-low", "gpt-6.1-sol-high"]),
        ("medium", AIModel.mediumDiffPriority, ["gpt-6.1-sol-high", "gpt-6.1-sol-medium", "gpt-6.1-sol-low"]),
        ("high", AIModel.highDiffPriority, ["gpt-6.1-sol-high", "gpt-6.1-sol-xhigh", "gpt-6.1-sol-medium"])
    ]

    func testDynamicCodexPriorityHintsDoNotCreateAvailableModels() {
        let discoveryState = CodexDiscoveryTestState.capture()
        defer { discoveryState.restore() }

        for list in gpt61DiffHints {
            let codexEntries = list.priorities.filter { $0.providerType == .codex }
            XCTAssertEqual(
                Array(codexEntries.prefix(3)),
                list.hints.map { AIModel.codexCustom(name: $0) },
                "\(list.name) hints are the exact discovered option identities"
            )
        }

        // Before discovery the picker holds the static GPT-5.6 entries only; selection must not
        // return a hinted GPT-6.1 identity the catalog never offered.
        CodexDiscoveryTestState.setDiscoveredModels([])
        let staticCodex = AIModel.modelsForProvider(.codex)
        XCTAssertFalse(staticCodex.contains { $0.rawValue.contains("gpt-6.1") }, "\(staticCodex.map(\.rawValue))")
        let staticExpectations: [AIModel] = [.codexCliGpt56SolMedium, .codexCliGpt56SolHigh, .codexCliGpt56SolHigh]
        for (list, expected) in zip(gpt61DiffHints, staticExpectations) {
            XCTAssertEqual(
                AIModel.findBestAvailableModel(in: staticCodex, desiredFormat: .diff, priorities: list.priorities),
                expected,
                list.name
            )
        }

        // A catalog advertising only GPT-6.1 Low satisfies only the hint naming that exact option;
        // the High list skips to the backfilled GPT-5.6 entry instead of inventing GPT-6.1 High.
        CodexDiscoveryTestState.setDiscoveredModels([
            CodexDiscoveryTestState.remoteModel("gpt-6.1-sol", efforts: ["low"], isDefault: true)
        ])
        let partialCodex = AIModel.modelsForProvider(.codex)
        XCTAssertEqual(
            Set(partialCodex.compactMap { model -> String? in
                guard case let .codexCustom(name) = model, name.hasPrefix("gpt-6.1-"), !name.contains("-fast") else { return nil }
                return name
            }),
            ["gpt-6.1-sol-low"]
        )
        let partialExpectations: [AIModel] = [
            .codexCustom(name: "gpt-6.1-sol-low"),
            .codexCustom(name: "gpt-6.1-sol-low"),
            .codexCliGpt56SolHigh
        ]
        for (list, expected) in zip(gpt61DiffHints, partialExpectations) {
            let picked = AIModel.findBestAvailableModel(in: partialCodex, desiredFormat: .diff, priorities: list.priorities)
            XCTAssertEqual(picked, expected, list.name)
            XCTAssertTrue(picked.map { partialCodex.contains($0) } == true, list.name)
        }
    }

    func testPrioritySelectionPreservesRequestedEffort() {
        let discoveryState = CodexDiscoveryTestState.capture()
        defer { discoveryState.restore() }

        // Discovered GPT-6.1 Sol (with its synthesized Fast variants and every advertised effort)
        // satisfies each list's first hint at exactly that effort and standard service tier.
        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt61Models())
        let codex = AIModel.modelsForProvider(.codex)
        let withoutHigh = codex.filter { $0 != .codexCustom(name: "gpt-6.1-sol-high") }
        let codexExpectations: [(full: String, withoutHigh: String)] = [
            ("gpt-6.1-sol-medium", "gpt-6.1-sol-medium"),
            ("gpt-6.1-sol-high", "gpt-6.1-sol-medium"),
            ("gpt-6.1-sol-high", "gpt-6.1-sol-xhigh")
        ]
        for (list, expected) in zip(gpt61DiffHints, codexExpectations) {
            for (available, name) in [(codex, expected.full), (withoutHigh, expected.withoutHigh)] {
                let picked = AIModel.findBestAvailableModel(in: available, desiredFormat: .diff, priorities: list.priorities)
                XCTAssertEqual(picked, .codexCustom(name: name), list.name)
                XCTAssertEqual(picked?.defaultReasoningEffort, CodexModelSpecifier(raw: name).reasoningEffort?.rawValue, list.name)
                XCTAssertNil(picked?.codexServiceTier, list.name)
            }
        }

        // Direct OpenAI entries keep the effort their position names in each list.
        let openAI = AIModel.modelsForProvider(.openAI)
        let directExpectations: [(priorities: [AIModel], format: PromptViewModel.FileEditFormat, model: AIModel, effort: String)] = [
            (AIModel.simpleDiffPriority, .diff, .gpt61SolLow, "low"),
            (AIModel.mediumDiffPriority, .diff, .gpt61Sol, "medium"),
            (AIModel.highDiffPriority, .diff, .gpt61SolHigh, "high"),
            (AIModel.simpleWholePriority, .whole, .gpt6LunaLow, "low"),
            (AIModel.mediumWholePriority, .whole, .gpt61Sol, "medium"),
            (AIModel.highWholePriority, .whole, .gpt61SolHigh, "high")
        ]
        for expected in directExpectations {
            let picked = AIModel.findBestAvailableModel(in: openAI, desiredFormat: expected.format, priorities: expected.priorities)
            XCTAssertEqual(picked, expected.model, expected.model.rawValue)
            XCTAssertEqual(picked?.defaultReasoningEffort, expected.effort, expected.model.rawValue)
        }

        // Sonnet 5.5 precedes Sonnet 4 for direct Anthropic and OpenRouter keys.
        for list in gpt61DiffHints {
            let anthropic = AIModel.modelsForProvider(.anthropic)
            XCTAssertEqual(AIModel.findBestAvailableModel(in: anthropic, desiredFormat: .diff, priorities: list.priorities), .claudeSonnet55, list.name)
            let openRouter: [AIModel] = [.openrouterClaude4Sonnet, .openrouterClaudeSonnet55]
            XCTAssertEqual(
                AIModel.findBestAvailableModel(in: openRouter, desiredFormat: .diff, priorities: list.priorities),
                .openrouterClaudeSonnet55,
                list.name
            )
        }
    }

    func testRestrictedMythosIsNeverAnAutomaticFallback() {
        let restricted: [AIModel] = [
            .claudeMythos51,
            .anthropicCustom(name: "claude-mythos-5-1"),
            .anthropicCustom(name: " Claude-Mythos-5-1-thinking "),
            .anthropicCustom(name: "claude-mythos-5-1-thinking-max"),
            .claudeCodeModel(specifier: "claude-mythos-5-1"),
            .claudeCodeModel(specifier: "claude-mythos-5-1:max")
        ]
        for model in restricted {
            XCTAssertFalse(model.isEligibleForAutomaticSelection, model.rawValue)
        }
        let ordinary: [AIModel] = [
            .claudeSonnet55,
            .claudeFable51,
            .claudeCodeModel(specifier: "claude-sonnet-5-5:high"),
            .anthropicCustom(name: "claude-sonnet-5-5-thinking"),
            .openrouterClaudeFable51,
            .gpt61SolHigh,
            .codexCustom(name: "gpt-6.1-sol-high")
        ]
        for model in ordinary {
            XCTAssertTrue(model.isEligibleForAutomaticSelection, model.rawValue)
        }

        // findBestAvailableModel: neither the priority step nor the unlisted fallback picks Mythos.
        for format in [PromptViewModel.FileEditFormat.diff, .whole] {
            XCTAssertNil(AIModel.findBestAvailableModel(in: restricted, desiredFormat: format, priorities: [.claudeMythos51]))
            XCTAssertEqual(
                AIModel.findBestAvailableModel(in: [.claudeMythos51, .claudeSonnet55], desiredFormat: format, priorities: [.claudeMythos51, .claudeSonnet55]),
                .claudeSonnet55
            )
            XCTAssertEqual(
                AIModel.findBestAvailableModel(in: restricted + [.claudeOpus55], desiredFormat: format, priorities: []),
                .claudeOpus55
            )
        }

        // Shared first-eligible helper used by the chat last-resort fallback and the provider-key
        // removal reset: with an Anthropic key saved, Mythos can lead the available list.
        let available: [AIModel] = [.claudeMythos51, .claudeOpus55, .gpt61Sol]
        XCTAssertEqual(AIModel.firstAutomaticallyEligibleModel(in: available), .claudeOpus55)
        XCTAssertEqual(AIModel.firstAutomaticallyEligibleModel(in: available, where: { !$0.isOpenAIModel }), .claudeOpus55)
        XCTAssertEqual(AIModel.firstAutomaticallyEligibleModel(in: available, where: { !$0.isAnthropicModel }), .gpt61Sol)
        XCTAssertNil(AIModel.firstAutomaticallyEligibleModel(in: restricted))
        XCTAssertNil(AIModel.firstAutomaticallyEligibleModel(in: [.claudeMythos51, .gpt61Sol], where: { !$0.isOpenAIModel }))

        // Explicit selections and saved pins are not filtered.
        XCTAssertEqual(AIModel.fromModelName("claude-mythos-5-1"), .claudeMythos51)
        XCTAssertEqual(
            ClaudeCodeAIModelCatalog.validatedModel(specifier: "claude-mythos-5-1:high"),
            .claudeCodeModel(specifier: "claude-mythos-5-1:high")
        )
    }
}
