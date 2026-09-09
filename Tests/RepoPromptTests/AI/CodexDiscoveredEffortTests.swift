import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class CodexDiscoveredEffortTests: XCTestCase {
    func testAdvertisedAstraEffortsProduceStandardAndFastWireParameters() throws {
        let records = [record("gpt-6-astra", efforts: ["high", "max", "ultra"], defaultEffort: "high")]
        let options = CodexDynamicModelMapper.options(from: records)
        XCTAssertEqual(options.map(\.id), ["gpt-6-astra-high", "gpt-6-astra-max", "gpt-6-astra-ultra"])

        try assertWire(
            raw: "gpt-6-astra-max",
            records: records,
            model: "gpt-6-astra",
            effort: "max",
            serviceTier: nil
        )
        try assertWire(
            raw: "gpt-6-astra-ultra",
            records: records,
            model: "gpt-6-astra",
            effort: "ultra",
            serviceTier: nil
        )
        try assertWire(
            raw: "gpt-6-astra-fast-max",
            records: records,
            model: "gpt-6-astra",
            effort: "max",
            serviceTier: "fast"
        )
        try assertWire(
            raw: "gpt-6-astra-fast-ultra",
            records: records,
            model: "gpt-6-astra",
            effort: "ultra",
            serviceTier: "fast"
        )
    }

    func testDefaultRepeatedAndUnknownEffortsRetainTolerantMapping() {
        let records = [record(
            "gpt-6-astra",
            efforts: [" unknown ", " ULTRA ", "ultra"],
            defaultEffort: " MAX ",
            isDefault: true
        )]

        let options = CodexDynamicModelMapper.options(from: records)
        XCTAssertEqual(options.map(\.id), ["gpt-6-astra-max", "gpt-6-astra-ultra"])
        XCTAssertEqual(options.map(\.isDefault), [true, false])
    }

    func testExactExtendedIDsWinMappingDisplayAndWireIdentity() throws {
        let records = [
            record("  GPT-6-ASTRA  ", efforts: [" MAX ", " ULTRA "]),
            record(" gPt-6-AsTrA-MaX ", displayName: "Literal Max Model", efforts: ["high"]),
            record(" gPt-6-AsTrA-Ultra ", displayName: "Literal Ultra Model", efforts: [])
        ]

        let options = CodexDynamicModelMapper.options(from: records)
        XCTAssertEqual(Set(options.map(\.id)), ["GPT-6-ASTRA", "gPt-6-AsTrA-MaX-high", "gPt-6-AsTrA-Ultra"])
        XCTAssertEqual(
            CodexDynamicModelMapper.displayName(forModelID: " GPT-6-ASTRA-MAX ", records: records),
            "Literal Max Model"
        )
        XCTAssertEqual(
            CodexDynamicModelMapper.displayName(forModelID: " GPT-6-ASTRA-ULTRA ", records: records),
            "Literal Ultra Model"
        )

        try assertWire(
            raw: "gPt-6-AsTrA-MaX",
            records: records,
            model: "gPt-6-AsTrA-MaX",
            effort: nil,
            serviceTier: nil
        )
        try assertWire(
            raw: "gPt-6-AsTrA-Ultra",
            records: records,
            model: "gPt-6-AsTrA-Ultra",
            effort: nil,
            serviceTier: nil
        )
    }

    func testPlainFastIdentityWinsOverSyntheticFastVariant() throws {
        let baseModelID = "gpt-6-example"
        XCTAssertEqual(CodexServiceTierVariantCatalog.fastVariantID(
            baseModelID: baseModelID,
            reasoningEffort: nil,
            discoveredRecords: []
        ), "gpt-6-example-fast")

        let records = [
            record(baseModelID, efforts: []),
            record(" GPT-6-EXAMPLE-FAST ", displayName: "Literal Fast Model", efforts: [])
        ]

        XCTAssertNil(CodexServiceTierVariantCatalog.fastVariantID(
            baseModelID: baseModelID,
            reasoningEffort: nil,
            discoveredRecords: records
        ))
        try assertWire(
            raw: "gpt-6-example-fast",
            records: records,
            model: "gpt-6-example-fast",
            effort: nil,
            serviceTier: nil
        )
    }

    func testFastCompoundUsesExactCandidateCapabilitiesBeforeStrippedBase() throws {
        let fastRecords = [
            record("gpt-6-astra", efforts: ["max"]),
            record("gpt-6-astra-fast", efforts: ["ultra"])
        ]
        try assertWire(
            raw: "gpt-6-astra-fast-ultra",
            records: fastRecords,
            model: "gpt-6-astra-fast",
            effort: "ultra",
            serviceTier: nil
        )

        let baseRecords = [record("gpt-6-astra", efforts: ["ultra"])]
        try assertWire(
            raw: "gpt-6-astra-fast-ultra",
            records: baseRecords,
            model: "gpt-6-astra",
            effort: "ultra",
            serviceTier: "fast"
        )
    }

    func testExactFastEffortIdentitySuppressesConflictingSyntheticOption() throws {
        let records = [
            record("gpt-6-astra", efforts: ["ultra"]),
            record(" GPT-6-ASTRA-FAST-ULTRA ", displayName: "Literal Fast Ultra", efforts: [])
        ]

        XCTAssertNil(CodexServiceTierVariantCatalog.fastVariantID(
            baseModelID: "gpt-6-astra",
            reasoningEffort: .ultra,
            discoveredRecords: records
        ))
        try assertWire(
            raw: "gpt-6-astra-fast-ultra",
            records: records,
            model: "gpt-6-astra-fast-ultra",
            effort: nil,
            serviceTier: nil
        )
    }

    func testUnsupportedExtendedSuffixPassesThroughWithoutMetadata() throws {
        let records = [record("gpt-6-astra", efforts: ["max"])]
        try assertWire(
            raw: "gpt-6-astra-ultra",
            records: records,
            model: "gpt-6-astra-ultra",
            effort: nil,
            serviceTier: nil
        )
    }

    func testOrdinaryLegacyParsingDoesNotLoadDiscoveryMetadata() {
        var loadCount = 0
        func discoveryRecords() -> [CodexDynamicModelRecord] {
            loadCount += 1
            return []
        }

        let selection = CodexModelSpecifier(raw: "gpt-5.4-high", discoveredRecords: discoveryRecords())
        XCTAssertEqual(selection.baseModel, "gpt-5.4")
        XCTAssertEqual(selection.reasoningEffort, .high)
        XCTAssertEqual(loadCount, 0)
    }

    func testLegacySelectionsKeepFrozenParsingBehavior() throws {
        let cases: [(raw: String, model: String, effort: String?)] = [
            ("gpt-5.6-sol-ultra", "gpt-5.6-sol", "ultra"),
            ("gpt-5.6-luna-max", "gpt-5.6-luna", "max"),
            ("gpt-5.1-codex-max-high", "gpt-5.1-codex-max", "high"),
            ("gpt-5.1-codex-max", "gpt-5.1-codex-max", nil)
        ]

        for value in cases {
            try assertWire(
                raw: value.raw,
                records: [],
                model: value.model,
                effort: value.effort,
                serviceTier: nil
            )
        }
    }

    func testDecodeCacheAndPersistedSelectionTrackMutationRemovalCorruptionAndSuites() throws {
        let firstSuite = "CodexDiscoveredEffortTests.first.\(UUID().uuidString)"
        let secondSuite = "CodexDiscoveredEffortTests.second.\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let second = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }

        XCTAssertTrue(CodexDynamicModelStore.load(defaults: first).isEmpty)
        CodexDynamicModelStore.save([remoteModel("gpt-6-astra", effort: "max")], defaults: first)
        let maxRecords = CodexDynamicModelStore.load(defaults: first)
        XCTAssertEqual(maxRecords.first?.defaultReasoningEffort, "max")
        XCTAssertEqual(CodexDynamicModelMapper.options(from: maxRecords).map(\.id), ["gpt-6-astra-max"])
        try assertWire(
            raw: "gpt-6-astra-max",
            records: maxRecords,
            model: "gpt-6-astra",
            effort: "max",
            serviceTier: nil
        )

        CodexDynamicModelStore.save([remoteModel("gpt-6-astra", effort: "ultra")], defaults: first)
        let ultraRecords = CodexDynamicModelStore.load(defaults: first)
        XCTAssertEqual(ultraRecords.first?.defaultReasoningEffort, "ultra")
        XCTAssertEqual(CodexDynamicModelMapper.options(from: ultraRecords).map(\.id), ["gpt-6-astra-ultra"])
        try assertWire(
            raw: "gpt-6-astra-ultra",
            records: ultraRecords,
            model: "gpt-6-astra",
            effort: "ultra",
            serviceTier: nil
        )

        CodexDynamicModelStore.save([remoteModel("gpt-other", effort: "high")], defaults: second)
        XCTAssertEqual(CodexDynamicModelStore.load(defaults: second).map(\.id), ["gpt-other"])
        XCTAssertEqual(CodexDynamicModelStore.load(defaults: first).map(\.id), ["gpt-6-astra"])

        first.removePersistentDomain(forName: firstSuite)
        XCTAssertTrue(CodexDynamicModelStore.load(defaults: first).isEmpty)

        CodexDynamicModelStore.save([remoteModel("gpt-6-astra", effort: "max")], defaults: first)
        XCTAssertEqual(CodexDynamicModelStore.load(defaults: first).map(\.id), ["gpt-6-astra"])
        first.set(Data("not-json".utf8), forKey: "CodexDynamicModelRecords")
        XCTAssertTrue(CodexDynamicModelStore.load(defaults: first).isEmpty)
    }

    func testPreferredLiveResolutionUsesProvidedRecordsInsteadOfAmbientCache() throws {
        let defaults = UserDefaults.standard
        let storageKey = "CodexDynamicModelRecords"
        let priorData = defaults.data(forKey: storageKey)
        let priorLiveModels = AgentCodexModelRegistry.shared.currentLiveModels()
        defer {
            _ = AgentCodexModelRegistry.shared.updateLiveModels(priorLiveModels)
            if let priorData {
                defaults.set(priorData, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
            _ = CodexDynamicModelStore.load()
        }

        let preferredModels = [remoteModel("gpt-6-astra", effort: "ultra")]
        let preferredRecords = CodexDynamicModelStore.canonicalRecords(from: preferredModels)
        let cacheCases: [(name: String, models: [CodexAppServerClient.RemoteModel])] = [
            ("empty", []),
            ("stale exact Fast", [
                remoteModel("gpt-6-astra", effort: "ultra"),
                remoteModel("gpt-6-astra-fast-ultra", effort: "high")
            ])
        ]

        for cacheCase in cacheCases {
            CodexDynamicModelStore.save(cacheCase.models)
            _ = CodexDynamicModelStore.load()
            let cacheDataBeforeResolution = defaults.data(forKey: storageKey)

            let options = AgentCodexModelRegistry.shared.resolvedOptions(
                staticOptions: [],
                preferredLiveModels: preferredModels
            )
            XCTAssertEqual(
                options.map(\.rawValue),
                ["default", "gpt-6-astra-ultra", "gpt-6-astra-fast-ultra"],
                cacheCase.name
            )
            try assertWire(
                raw: "gpt-6-astra-ultra",
                records: preferredRecords,
                model: "gpt-6-astra",
                effort: "ultra",
                serviceTier: nil
            )
            try assertWire(
                raw: "gpt-6-astra-fast-ultra",
                records: preferredRecords,
                model: "gpt-6-astra",
                effort: "ultra",
                serviceTier: "fast"
            )
            XCTAssertEqual(defaults.data(forKey: storageKey), cacheDataBeforeResolution, cacheCase.name)
            XCTAssertEqual(AgentCodexModelRegistry.shared.currentLiveModels(), priorLiveModels, cacheCase.name)
        }
    }

    private func assertWire(
        raw: String,
        records: [CodexDynamicModelRecord],
        model: String,
        effort: String?,
        serviceTier: String?
    ) throws {
        let specifier = CodexModelSpecifier(raw: raw, discoveredRecords: records)
        XCTAssertEqual(specifier.appServerModelParam, model, raw)
        XCTAssertEqual(specifier.appServerEffortParam, effort, raw)
        XCTAssertEqual(specifier.appServerServiceTierParam, serviceTier, raw)
        XCTAssertEqual(specifier.cliModelArgs, ["--model", model], raw)
        XCTAssertEqual(
            specifier.cliReasoningConfigArgs,
            effort.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [],
            raw
        )
        XCTAssertEqual(
            specifier.cliServiceTierConfigArgs,
            serviceTier.map { ["-c", "service_tier=\($0)"] } ?? [],
            raw
        )
    }

    private func record(
        _ id: String,
        displayName: String? = nil,
        efforts: [String],
        defaultEffort: String? = nil,
        isDefault: Bool = false
    ) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id,
            model: id,
            displayName: displayName ?? id,
            description: "",
            isDefault: isDefault,
            supportedReasoningEfforts: efforts.map {
                .init(reasoningEffort: $0, description: "")
            },
            defaultReasoningEffort: defaultEffort
        )
    }

    private func remoteModel(_ id: String, effort: String) -> CodexAppServerClient.RemoteModel {
        CodexAppServerClient.RemoteModel(
            id: id,
            model: id,
            displayName: id,
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [.init(reasoningEffort: effort, description: "")],
            defaultReasoningEffort: effort
        )
    }
}
