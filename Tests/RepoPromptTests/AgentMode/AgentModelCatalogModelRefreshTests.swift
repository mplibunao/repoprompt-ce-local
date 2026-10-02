@testable import RepoPromptApp
import XCTest

final class AgentModelCatalogModelRefreshTests: XCTestCase {
    private var discoveryState: CodexDiscoveryTestState?

    override func setUp() {
        super.setUp()
        discoveryState = CodexDiscoveryTestState.capture()
        CodexDiscoveryTestState.setDiscoveredModels([])
    }

    override func tearDown() {
        discoveryState?.restore()
        super.tearDown()
    }

    // MARK: - Approved-family preference

    func testFamilyPreferenceComparesVersionsNumerically() {
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption(
                "sol",
                from: options(["gpt-5.9-sol-high", "gpt-5.10-sol-high", "gpt-5.11-terra-high"])
            )?.rawValue,
            "gpt-5.10-sol-high"
        )
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption(
                "sol",
                from: options(["gpt-5.6-sol-high", "gpt-6-sol-low", "gpt-5.6-sol-xhigh"])
            )?.rawValue,
            "gpt-6-sol-low"
        )
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption(
                "  LUNA ",
                from: options(["gpt-6-sol-high", "gpt-5.6-luna-high", "gpt-6-luna-medium"])
            )?.rawValue,
            "gpt-6-luna-medium"
        )
    }

    func testFamilyPreferenceKeepsFirstAdvertisedSpellingOfEquivalentVersions() {
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption(
                "sol",
                from: options(["gpt-6-sol-high", "gpt-6.0-sol-high"])
            )?.rawValue,
            "gpt-6-sol-high"
        )
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption(
                "sol",
                from: options(["gpt-6.0-sol-high", "gpt-6-sol-high"])
            )?.rawValue,
            "gpt-6.0-sol-high"
        )
    }

    func testFamilyPreferenceIgnoresEmptyPlaceholderUnknownAndMalformedOptions() {
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyOption("sol", from: []))
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyOption(" ", from: options(["gpt-6-sol-high"])))

        let placeholder = AgentModelOption(
            rawValue: "gpt-6-sol-high",
            displayName: "Default",
            description: nil,
            isPlaceholderDefault: true,
            isProviderDefault: false
        )
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyOption("sol", from: [placeholder]))
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyOption(
            "sol",
            from: options(["gpt-5.6-terra-high", "gpt-6-luna-high", "gpt-5.3-codex"])
        ))

        let malformed = [
            "gpt-sol-high",
            "gpt--sol-high",
            "gpt-5..6-sol-high",
            "gpt-.6-sol-high",
            "gpt-6.-sol-high",
            "gpt-+6-sol-high",
            "gpt--6-sol-high",
            "gpt-6a-sol-high",
            "gpt-99999999999999999999-sol-high"
        ]
        for raw in malformed {
            XCTAssertNil(AgentModelCatalog.preferredCodexFamilyOption("sol", from: options([raw])), raw)
        }
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption(
                "sol",
                from: options(malformed + ["gpt-5.6-sol-high"])
            )?.rawValue,
            "gpt-5.6-sol-high"
        )
    }

    func testFamilyPreferenceRecognizesSyntheticFastOptionsWithoutRecommendingThem() {
        CodexDiscoveryTestState.setDiscoveredModels([CodexDiscoveryTestState.remoteModel("gpt-6-sol", efforts: ["low"])])

        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption("sol", from: options(["gpt-6-sol-fast-high"]))?.rawValue,
            "gpt-6-sol-fast-high"
        )
        let advertised = AgentModelCatalog.options(for: .codexExec, availability: AgentModelCatalog.AvailabilityContext())
            .map(\.rawValue)
        XCTAssertTrue(advertised.contains("gpt-6-sol-fast-low"), "\(advertised)")
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .low, availability: AgentModelCatalog.AvailabilityContext()),
            "gpt-6-sol-low"
        )
    }

    func testPreferredRawAdmitsOnlyAdvertisedEffortsOfTheNewestFamily() {
        CodexDiscoveryTestState.setDiscoveredModels([
            CodexDiscoveryTestState.remoteModel("gpt-6-sol", efforts: ["low", "medium", "high"]),
            CodexDiscoveryTestState.remoteModel("gpt-5.6-sol", efforts: ["low", "medium", "high", "xhigh"])
        ])
        let availability = AgentModelCatalog.AvailabilityContext()

        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyOption("sol", availability: availability)?.rawValue,
            "gpt-6-sol-low"
        )
        XCTAssertEqual(AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .high, availability: availability), "gpt-6-sol-high")
        // The newest family lacks XHigh; the helper never searches older generations or synthesizes it.
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .xhigh, availability: availability))
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .max, availability: availability))
        // Without discovered GPT-6 Luna, the newest Luna is the backfilled GPT-5.6 family.
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyModelRaw("luna", effort: .low, availability: availability),
            "gpt-5.6-luna-low"
        )

        CodexDiscoveryTestState.setDiscoveredModels([
            CodexDiscoveryTestState.remoteModel("gpt-6.1-sol", efforts: ["low", "medium"]),
            CodexDiscoveryTestState.remoteModel("gpt-6-sol", efforts: ["low", "medium", "high"])
        ])
        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .medium, availability: availability),
            "gpt-6.1-sol-medium"
        )
        // GPT-6 Sol advertises High, but GPT-6.1 is the newest family and does not.
        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .high, availability: availability))
    }

    func testExactAdvertisedFastIdentityIsNotTreatedAsTheFamily() {
        CodexDiscoveryTestState.setDiscoveredModels([CodexDiscoveryTestState.remoteModel("gpt-6-sol-fast", efforts: ["high"])])
        let availability = AgentModelCatalog.AvailabilityContext()

        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .high, availability: availability),
            "gpt-5.6-sol-high"
        )
    }

    // MARK: - Role defaults

    func testRoleDefaultsFallBackToGPT56BeforeDiscovery() {
        let availability = AgentModelCatalog.AvailabilityContext()

        XCTAssertEqual(resolve(.explore, availability), selection(.codexExec, "gpt-5.6-luna-high"))
        XCTAssertEqual(resolve(.engineer, availability), selection(.codexExec, "gpt-5.6-sol-medium"))
        XCTAssertEqual(resolve(.pair, availability), selection(.codexExec, "gpt-5.6-sol-high"))
        XCTAssertEqual(resolve(.design, availability)?.agent, .claudeCode)
        XCTAssertEqual(
            resolve(.design, AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: false)),
            selection(.codexExec, "gpt-5.6-sol-medium")
        )
    }

    func testRoleDefaultsPreferDiscoveredGPT6AtEachRolePosition() {
        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt6Models())
        let availability = AgentModelCatalog.AvailabilityContext()

        XCTAssertEqual(resolve(.explore, availability), selection(.codexExec, "gpt-6-luna-high"))
        XCTAssertEqual(resolve(.engineer, availability), selection(.codexExec, "gpt-6-sol-medium"))
        XCTAssertEqual(resolve(.pair, availability), selection(.codexExec, "gpt-6-sol-high"))
        XCTAssertEqual(resolve(.design, availability)?.agent, .claudeCode)
        XCTAssertEqual(
            resolve(.design, AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: false)),
            selection(.codexExec, "gpt-6-sol-medium")
        )

        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt61Models())

        XCTAssertEqual(resolve(.explore, availability), selection(.codexExec, "gpt-6-luna-high"))
        XCTAssertEqual(resolve(.engineer, availability), selection(.codexExec, "gpt-6.1-sol-medium"))
        XCTAssertEqual(resolve(.pair, availability), selection(.codexExec, "gpt-6.1-sol-high"))
        XCTAssertEqual(resolve(.design, availability)?.agent, .claudeCode)
        XCTAssertEqual(
            resolve(.design, AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: false)),
            selection(.codexExec, "gpt-6.1-sol-medium")
        )
    }

    func testRoleDefaultsFallBackWhenNewestFamilyLacksTheEffort() {
        CodexDiscoveryTestState.setDiscoveredModels([
            CodexDiscoveryTestState.remoteModel("gpt-6-luna", efforts: ["low"]),
            CodexDiscoveryTestState.remoteModel("gpt-6-sol", efforts: ["medium", "high"])
        ])
        let availability = AgentModelCatalog.AvailabilityContext()

        XCTAssertEqual(resolve(.explore, availability), selection(.codexExec, "gpt-5.6-luna-high"))
        XCTAssertEqual(resolve(.engineer, availability), selection(.codexExec, "gpt-6-sol-medium"))

        // GPT-6.1 Sol is the newest Sol but advertises only Low, so Engineer and Pair take their explicit
        // GPT-5.6 fallbacks instead of GPT-6 Sol's advertised Medium and High.
        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt6Models() + [
            CodexDiscoveryTestState.remoteModel("gpt-6.1-sol", efforts: ["low"]),
            CodexDiscoveryTestState.remoteModel("gpt-5.6-sol", efforts: ["low", "medium", "high", "xhigh"])
        ])

        XCTAssertEqual(
            AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .low, availability: availability),
            "gpt-6.1-sol-low"
        )
        XCTAssertEqual(resolve(.explore, availability), selection(.codexExec, "gpt-6-luna-high"))
        XCTAssertEqual(resolve(.engineer, availability), selection(.codexExec, "gpt-5.6-sol-medium"))
        XCTAssertEqual(resolve(.pair, availability), selection(.codexExec, "gpt-5.6-sol-high"))
        XCTAssertEqual(
            resolve(.design, AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: false)),
            selection(.codexExec, "gpt-5.6-sol-medium")
        )
    }

    func testPartialGPT61CatalogDoesNotBackfillGPT61Efforts() {
        // GPT-6.1 Sol, GPT-6 Luna Low, and GPT-5.3 Codex are advertised but GPT-5.6 Sol is not, so the
        // static list is merged in while GPT-6.1 keeps only its advertised efforts.
        CodexDiscoveryTestState.setDiscoveredModels([
            CodexDiscoveryTestState.remoteModel("gpt-6.1-sol", efforts: ["low", "medium", "high"], isDefault: true),
            CodexDiscoveryTestState.remoteModel("gpt-6-luna", efforts: ["low"]),
            CodexDiscoveryTestState.remoteModel("gpt-5.3-codex", efforts: ["medium"])
        ])
        let availability = AgentModelCatalog.AvailabilityContext()
        let agentRaws = AgentModelCatalog.options(for: .codexExec, availability: availability).map(\.rawValue)
        let chatRaws = AIModel.modelsForProvider(.codex).compactMap { model -> String? in
            if case let .codexCustom(name) = model { return name }
            let prefix = "codex_cli_"
            return model.rawValue.hasPrefix(prefix) ? String(model.rawValue.dropFirst(prefix.count)) : nil
        }

        for (surface, raws) in [("Agent Mode", agentRaws), ("chat", chatRaws)] {
            XCTAssertEqual(
                Set(raws.filter { $0.hasPrefix("gpt-6.1-") && !$0.contains("-fast") }),
                ["gpt-6.1-sol-low", "gpt-6.1-sol-medium", "gpt-6.1-sol-high"],
                surface
            )
            for raw in ["gpt-5.6-sol-low", "gpt-5.6-sol-medium", "gpt-5.6-sol-high"] {
                XCTAssertTrue(raws.contains(raw), "\(surface) lacks \(raw): \(raws)")
            }
        }
        // The newest Luna lacks High, so Explore's GPT-5.6 fallback must remain a listed option.
        XCTAssertEqual(resolve(.explore, availability), selection(.codexExec, "gpt-5.6-luna-high"))
        XCTAssertTrue(agentRaws.contains("gpt-5.6-luna-high"), "\(agentRaws)")
    }

    func testFilteredCodexProviderCannotWinRoleDefaults() {
        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt6Models())
        let availability = AgentModelCatalog.AvailabilityContext(codexAvailable: false)

        XCTAssertNil(AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .high, availability: availability))
        for kind in AgentModelCatalog.taskLabels.map(\.kind) {
            XCTAssertNotEqual(resolve(kind, availability)?.agent, .codexExec, "\(kind)")
        }
    }

    // MARK: - Enum identity and metadata

    func testGPT6ResolverMapsEveryEffortToItsUIBinding() {
        let expected: [(family: String, efforts: [String: AgentModel])] = [
            ("gpt-6-sol", [
                "low": .gpt6SolLow, "medium": .gpt6SolMedium, "high": .gpt6SolHigh,
                "xhigh": .gpt6SolXHigh, "max": .gpt6SolMax
            ]),
            ("gpt-6-luna", [
                "low": .gpt6LunaLow, "medium": .gpt6LunaMedium, "high": .gpt6LunaHigh,
                "xhigh": .gpt6LunaXHigh, "max": .gpt6LunaMax
            ]),
            ("gpt-6.1-sol", [
                "low": .gpt61SolLow, "medium": .gpt61SolMedium, "high": .gpt61SolHigh,
                "xhigh": .gpt61SolXHigh, "max": .gpt61SolMax
            ]),
            ("gpt-6-astra", [
                "low": .gpt6AstraLow, "medium": .gpt6AstraMedium, "high": .gpt6AstraHigh,
                "xhigh": .gpt6AstraXHigh, "max": .gpt6AstraMax
            ])
        ]
        for (family, efforts) in expected {
            for (effort, model) in efforts {
                let raw = "\(family)-\(effort)"
                XCTAssertEqual(AgentModel.resolvedModel(forRaw: raw, agentKind: .codexExec), model, raw)
                XCTAssertEqual(model.rawValue, raw)
            }
            let medium = efforts["medium"]
            for raw in [family, "\(family)-none", "\(family)-minimal"] {
                XCTAssertEqual(AgentModel.resolvedModel(forRaw: raw, agentKind: .codexExec), medium, raw)
            }
            // Ultra is never backfilled for GPT-6, so it stays an unresolved raw identity.
            XCTAssertNil(AgentModel.resolvedModel(forRaw: "\(family)-ultra", agentKind: .codexExec))
        }

        /// A saved selection keeps its exact raw, never the approximate UI binding, with or without discovery.
        func assertPersistedRawsAreKept(_ discoveryState: String) {
            for raw in ["gpt-6.1-sol-ultra", "gpt-6.1-sol-max", "gpt-6.1-sol", "gpt-6-astra-ultra", "gpt-6-astra-max"] {
                let normalized = AgentModelCatalog.normalizePersistedSelection(
                    agentRaw: AgentProviderKind.codexExec.rawValue,
                    modelRaw: raw,
                    availability: AgentModelCatalog.AvailabilityContext()
                )
                XCTAssertEqual(normalized, selection(.codexExec, raw), "\(discoveryState): \(raw)")
            }
        }
        assertPersistedRawsAreKept("no discovery")

        CodexDiscoveryTestState.setDiscoveredModels(CodexDiscoveryTestState.gpt61Models())
        assertPersistedRawsAreKept("GPT-6.1 discovery")
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-6.1-sol-ultra", agentKind: .codexExec), .gpt61SolUltra)
        // Astra's UI binding stops at Max; the selected raw still sends and labels Ultra.
        let astraUltra = "gpt-6-astra-ultra"
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: astraUltra, agentKind: .codexExec), .gpt6AstraMax)
        XCTAssertEqual(CodexModelSpecifier(raw: astraUltra).appServerModelParam, "gpt-6-astra")
        XCTAssertEqual(CodexModelSpecifier(raw: astraUltra).appServerEffortParam, "ultra")
        let astraUltraLabel = AgentModelCatalog.displayName(
            for: astraUltra,
            agentKind: .codexExec,
            availability: AgentModelCatalog.AvailabilityContext()
        )
        XCTAssertTrue(astraUltraLabel.hasSuffix(" Ultra"), astraUltraLabel)
    }

    func testGPT6MetadataAndDiscoveryTags() {
        let generation = AgentModel.allCases.filter { $0.rawValue.hasPrefix("gpt-6") }
        let solAndLuna = generation.filter { $0.rawValue.hasPrefix("gpt-6-sol-") || $0.rawValue.hasPrefix("gpt-6-luna-") }
        let gpt61Sol = generation.filter { $0.rawValue.hasPrefix("gpt-6.1-sol-") }
        let astra = generation.filter { $0.rawValue.hasPrefix("gpt-6-astra-") }
        XCTAssertEqual(generation.count, solAndLuna.count + gpt61Sol.count + astra.count)
        XCTAssertEqual([solAndLuna.count, gpt61Sol.count, astra.count], [10, 6, 5])
        for model in solAndLuna {
            XCTAssertEqual(model.contextWindowTokens, 1_050_000, model.rawValue)
            XCTAssertTrue(model.isExtendedContext, model.rawValue)
            XCTAssertTrue(model.displayName.hasPrefix("GPT-6 "), model.rawValue)
        }
        // A Codex session's configured context is smaller than the API maximum, so these claim none.
        for model in gpt61Sol + astra {
            XCTAssertNil(model.contextWindowTokens, model.rawValue)
            XCTAssertFalse(model.isExtendedContext, model.rawValue)
            XCTAssertTrue(model.displayName.hasPrefix(gpt61Sol.contains(model) ? "GPT-6.1 Sol " : "GPT-6 Astra "), model.rawValue)
            XCTAssertEqual(model.discoveryTags, model == .gpt61SolHigh ? [.complex, .engineering, .pair] : [], model.rawValue)
        }
        XCTAssertEqual(AgentModel.gpt6LunaHigh.discoveryTags, [.exploration, .engineering])
        XCTAssertEqual(AgentModel.gpt6SolHigh.discoveryTags, [.complex, .engineering, .pair])
        XCTAssertEqual(AgentModel.gpt6LunaLow.discoveryTags, [])
        XCTAssertEqual(AgentModel.gpt56SolLow.discoveryTags, [.fast, .exploration, .engineering])
        XCTAssertEqual(AgentModel.claudeOpus55.contextWindowTokens, 1_000_000)
    }

    func testStaticCodexListDoesNotAdmitGPT6() {
        let staticRaws = AgentModel.modelsForAgent(.codexExec).map(\.rawValue)
        XCTAssertFalse(staticRaws.contains { $0.hasPrefix("gpt-6") }, "\(staticRaws)")
        XCTAssertTrue(staticRaws.contains(AgentModel.gpt56LunaHigh.rawValue))
        XCTAssertTrue(staticRaws.contains(AgentModel.gpt56SolLow.rawValue))
    }

    // MARK: - Helpers

    private func resolve(
        _ kind: AgentModelCatalog.TaskLabelKind,
        _ availability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelCatalog.NormalizedAgentSelection? {
        AgentModelCatalog.resolveTaskLabelKind(kind, availability: availability)
    }

    private func selection(
        _ agent: AgentProviderKind,
        _ modelRaw: String
    ) -> AgentModelCatalog.NormalizedAgentSelection {
        AgentModelCatalog.NormalizedAgentSelection(agent: agent, modelRaw: modelRaw)
    }

    private func options(_ raws: [String]) -> [AgentModelOption] {
        raws.map {
            AgentModelOption(rawValue: $0, displayName: $0, description: nil, isPlaceholderDefault: false, isProviderDefault: false)
        }
    }
}
