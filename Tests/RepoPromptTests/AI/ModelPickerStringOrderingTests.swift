import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class ModelPickerStringOrderingTests: XCTestCase {
    func testScalarOrderingUsesAsciiFoldThenRawScalarTieBreak() {
        XCTAssertEqual(
            ModelPickerStringOrdering.compare("GPT-5", "gpt-5", caseInsensitiveASCII: true),
            .orderedAscending
        )
        XCTAssertEqual(
            ["ı", "i", "I"].sorted { ModelPickerStringOrdering.precedes($0, $1) },
            ["I", "i", "ı"]
        )
    }

    func testSemanticOrderingUsesVersionEffortAndFamilyBeforeDisplayName() {
        let codexModels: [AIModel] = [
            .codexCustom(name: "gpt-5.2-high"),
            .codexCustom(name: "gpt-5.4-fast-high"),
            .codexCustom(name: "gpt-5.4-low")
        ]
        XCTAssertEqual(AIModel.sortedForPicker(codexModels).map(\.modelName), [
            "gpt-5.4-low",
            "gpt-5.4-fast-high",
            "gpt-5.2-high"
        ])

        let customModels: [AIModel] = [
            .customProvider(name: "Aardvark", provider: "custom", model: "zzz-1"),
            .customProvider(name: "Zed", provider: "custom", model: "aaa-1")
        ]
        XCTAssertEqual(AIModel.sortedForPicker(customModels).map(\.modelName), ["aaa-1", "zzz-1"])
    }

    func testDynamicCatalogRetainsFrozenDefaultAndEffortOrdering() {
        let records = [
            CodexDynamicModelRecord(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: "high", description: ""),
                    .init(reasoningEffort: "low", description: "")
                ],
                defaultReasoningEffort: "high"
            )
        ]

        XCTAssertEqual(CodexDynamicModelMapper.options(from: records).map(\.id), [
            "gpt-5.4-low",
            "gpt-5.4-high"
        ])
    }

    func testCodexMaxFamilyTokenIsNotParsedAsReasoningEffort() {
        let base = CodexModelSpecifier(raw: "gpt-5.1-codex-max")
        XCTAssertEqual(base.baseModel, "gpt-5.1-codex-max")
        XCTAssertNil(base.reasoningEffort)

        let high = CodexModelSpecifier(raw: "gpt-5.1-codex-max-high")
        XCTAssertEqual(high.baseModel, "gpt-5.1-codex-max")
        XCTAssertEqual(high.reasoningEffort, .high)
    }

    func testDisplaySuffixStrippingDistinguishesFamilyTokensFromEffortTokens() {
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast Ultra"), "GPT-5.6 Sol Fast")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max High"), "GPT-5.1 Codex Max")
    }

    func testClaudeCodePickerExposesOpus55WithSupportedEfforts() throws {
        let models = AIModel.modelsForProvider(.claudeCode)
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-opus-5-5")))
        XCTAssertEqual(
            ClaudeCodeAIModelCatalog.validatedModel(specifier: "claude-opus-5-5:xhigh"),
            .claudeCodeModel(specifier: "claude-opus-5-5:xhigh")
        )
        XCTAssertNil(ClaudeCodeAIModelCatalog.validatedModel(specifier: "claude-opus-5-5:ultra"))

        let menu = AIModel.claudeCodeMenu(for: models)
        let groupRaws = menu.groups.map(\.baseModelRaw)
        let opusRunStart = try XCTUnwrap(groupRaws.firstIndex(of: "opus[1m]"))
        XCTAssertEqual(
            Array(groupRaws[opusRunStart...].prefix(5)),
            ["opus[1m]", "opus", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"]
        )
        let group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-opus-5-5" })
        XCTAssertEqual(group.displayName, "Opus 5.5")
        XCTAssertEqual(group.options.compactMap(\.model.claudeCodeRuntimeSpecifierRaw), [
            "claude-opus-5-5:low",
            "claude-opus-5-5:medium",
            "claude-opus-5-5:high",
            "claude-opus-5-5:xhigh",
            "claude-opus-5-5:max"
        ])

        // Sonnet 5.5 leads the pinned Sonnet run; restricted Mythos sits after the Fable pins rather
        // than leading the menu, labeled so users know it needs an entitled account.
        let sonnetRunStart = try XCTUnwrap(groupRaws.firstIndex(of: "sonnet"))
        XCTAssertEqual(
            Array(groupRaws[sonnetRunStart...].prefix(3)),
            ["sonnet", "claude-sonnet-5-5", "claude-sonnet-5"]
        )
        let fableRunStart = try XCTUnwrap(groupRaws.firstIndex(of: "fable"))
        XCTAssertEqual(
            Array(groupRaws[fableRunStart...].prefix(5)),
            ["fable", "claude-fable-5-1", "claude-fable-5", "claude-mythos-5-1", "opus[1m]"]
        )
        for (raw, displayName) in [("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-mythos-5-1", "Mythos 5.1 (Restricted)")] {
            let newGroup = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == raw }, raw)
            XCTAssertEqual(newGroup.displayName, displayName)
            XCTAssertEqual(newGroup.options.map(\.displayName), ["Low", "Medium", "High", "XHigh", "Max"], raw)
            XCTAssertEqual(
                newGroup.options.compactMap(\.model.claudeCodeRuntimeSpecifierRaw),
                ["low", "medium", "high", "xhigh", "max"].map { "\(raw):\($0)" }
            )
        }
        XCTAssertEqual(
            ClaudeCodeAIModelCatalog.displayName(for: "claude-mythos-5-1:high"),
            "Claude Code Mythos 5.1 (Restricted) High"
        )
        XCTAssertEqual(AIModel.claudeMythos51.displayName, "Claude Mythos 5.1 (Restricted)")
        XCTAssertEqual(menu.groups.first?.baseModelRaw, "fable")

        XCTAssertEqual(AgentModel(rawValue: "claude-opus-5-5"), .claudeOpus55)
        XCTAssertEqual(AgentModel.claudeOpus55.contextWindowTokens, 1_000_000)
        XCTAssertTrue(AgentModel.claudeOpus55.isExtendedContext)
        XCTAssertEqual(
            BestPracticeProfiles.claudeCodeOpusRecommendationLabel,
            "Claude Opus via Claude Code's stable Opus alias (Opus 5.5 on the Anthropic API)"
        )
    }
}
