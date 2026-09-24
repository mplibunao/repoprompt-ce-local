@testable import RepoPromptApp
import XCTest

final class CodexModelSpecifierModelRefreshTests: XCTestCase {
    func testGPT6FamiliesSplitEveryEffortWithoutDiscovery() {
        for base in ["gpt-6-sol", "gpt-6-luna"] {
            for effort in ["low", "medium", "high", "xhigh", "max"] {
                assertWire(raw: "\(base)-\(effort)", records: [], model: base, effort: effort, serviceTier: nil)
            }
            assertWire(raw: base, records: [], model: base, effort: nil, serviceTier: nil)
        }
    }

    func testGPT6UltraIsNotBackfilled() {
        for base in ["gpt-6-sol", "gpt-6-luna"] {
            assertWire(raw: "\(base)-ultra", records: [], model: "\(base)-ultra", effort: nil, serviceTier: nil)
        }
        // Discovered capability, not the family backfill, authorizes Ultra.
        assertWire(
            raw: "gpt-6-sol-ultra",
            records: [record("gpt-6-sol", efforts: ["high", "ultra"])],
            model: "gpt-6-sol",
            effort: "ultra",
            serviceTier: nil
        )
    }

    func testExactAdvertisedIdentifierOwnsItsWireIdentity() {
        assertWire(
            raw: "gpt-6-sol-max",
            records: [record("gpt-6-sol-max", efforts: ["high"])],
            model: "gpt-6-sol-max",
            effort: nil,
            serviceTier: nil
        )
        assertWire(
            raw: "gpt-6-luna-fast",
            records: [record("gpt-6-luna-fast", efforts: [])],
            model: "gpt-6-luna-fast",
            effort: nil,
            serviceTier: nil
        )
    }

    func testExistingExtendedFamilyBehaviorIsUnchanged() {
        assertWire(raw: "gpt-5.1-codex-max", records: [], model: "gpt-5.1-codex-max", effort: nil, serviceTier: nil)
        assertWire(raw: "gpt-5.1-codex-max-high", records: [], model: "gpt-5.1-codex-max", effort: "high", serviceTier: nil)
        assertWire(raw: "gpt-5.6-sol-ultra", records: [], model: "gpt-5.6-sol", effort: "ultra", serviceTier: nil)
        assertWire(raw: "gpt-5.6-luna-max", records: [], model: "gpt-5.6-luna", effort: "max", serviceTier: nil)
        assertWire(raw: "gpt-5.6-luna-ultra", records: [], model: "gpt-5.6-luna-ultra", effort: nil, serviceTier: nil)
    }

    func testFastServiceTierStaysSeparateFromModelAndEffort() {
        assertWire(raw: "gpt-6-sol-fast-high", records: [], model: "gpt-6-sol", effort: "high", serviceTier: "fast")
        assertWire(raw: "gpt-6-luna-fast-max", records: [], model: "gpt-6-luna", effort: "max", serviceTier: "fast")
        assertWire(raw: "gpt-6-sol-fast", records: [], model: "gpt-6-sol", effort: nil, serviceTier: "fast")
    }

    // MARK: - Helpers

    private func assertWire(
        raw: String,
        records: [CodexDynamicModelRecord],
        model: String,
        effort: String?,
        serviceTier: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let specifier = CodexModelSpecifier(raw: raw, discoveredRecords: records)
        XCTAssertEqual(specifier.appServerModelParam, model, raw, file: file, line: line)
        XCTAssertEqual(specifier.appServerEffortParam, effort, raw, file: file, line: line)
        XCTAssertEqual(specifier.appServerServiceTierParam, serviceTier, raw, file: file, line: line)
        XCTAssertEqual(specifier.cliModelArgs, ["--model", model], raw, file: file, line: line)
        XCTAssertEqual(
            specifier.cliReasoningConfigArgs,
            effort.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [],
            raw,
            file: file,
            line: line
        )
    }

    private func record(_ id: String, efforts: [String]) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id,
            model: id,
            displayName: id,
            description: "",
            isDefault: false,
            supportedReasoningEfforts: efforts.map { .init(reasoningEffort: $0, description: "") },
            defaultReasoningEffort: nil
        )
    }
}
