@testable import RepoPromptApp
import XCTest

final class PromptMigrationRemovalTests: XCTestCase {
    @MainActor
    func testMissingCopyPresetSelectionFallsBackToDocumentedStandardDefault() {
        XCTAssertEqual(PromptViewModel.defaultCopyPresetID, BuiltInCopyPresets.standard.id)
    }

    @MainActor
    func testPromptSectionOrderUsesValidStoredOrderWithoutOldDefaultMigration() throws {
        let order: [PromptSection] = [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions]
        let raw = try String(data: JSONEncoder().encode(order), encoding: .utf8).unwrapForTest()

        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: raw), order)
    }

    @MainActor
    func testLegacyDiffFormattingSectionFallsBackToCurrentDefault() {
        let legacyRaw = "[\u{22}fileMap\u{22},\u{22}fileContents\u{22},\u{22}gitDiff\u{22},\u{22}diffFormatting\u{22},\u{22}metaPrompts\u{22},\u{22}userInstructions\u{22}]"

        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: legacyRaw), PromptAssemblyBuilder.defaultSectionOrder)
    }

    @MainActor
    func testPromptSectionOrderFallsBackToCurrentDefaultForMissingOrInvalidOrder() throws {
        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: ""), PromptAssemblyBuilder.defaultSectionOrder)

        let incomplete: [PromptSection] = [.fileMap, .fileContents]
        let raw = try String(data: JSONEncoder().encode(incomplete), encoding: .utf8).unwrapForTest()
        XCTAssertEqual(PromptViewModel.resolvedPromptSectionOrder(raw: raw), PromptAssemblyBuilder.defaultSectionOrder)
    }

    func testLegacyCopyPresetEditAndMCPFieldsDecodeSafelyAndDoNotReencode() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let raw = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy MCP XML",
          "builtInKind": "mcpAgent",
          "isBuiltIn": true,
          "includeFiles": true,
          "xmlFormat": "diff",
          "systemPromptFlavor": "mcpAgent",
          "includeMCPMetadata": true
        }
        """.data(using: .utf8)!

        let preset = try JSONDecoder().decode(CopyPreset.self, from: raw)
        XCTAssertEqual(preset.builtInKind, .standard)
        XCTAssertEqual(preset.includeFiles, true)

        let encoded = try String(data: JSONEncoder().encode(preset), encoding: .utf8).unwrapForTest()
        XCTAssertFalse(encoded.contains("xmlFormat"))
        XCTAssertFalse(encoded.contains("systemPromptFlavor"))
        XCTAssertFalse(encoded.contains("includeMCPMetadata"))
    }

    func testLegacyCopyOverridesAndCustomizationsIgnoreRemovedFields() throws {
        let presetID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000456"))
        let overridesRaw = """
        {
          "presetID": "\(presetID.uuidString)",
          "includeFiles": false,
          "xmlFormat": "whole",
          "systemPromptFlavor": "mcpBuilder",
          "includeMCPMetadata": true
        }
        """.data(using: .utf8)!
        let overrides = try JSONDecoder().decode(CopyPresetOverrides.self, from: overridesRaw)
        XCTAssertEqual(overrides.presetID, presetID)
        XCTAssertEqual(overrides.includeFiles, false)

        let customRaw = """
        {
          "includeUserPrompt": false,
          "xmlFormat": "architect",
          "systemPromptFlavor": "mcpDiscover",
          "includeMCPMetadata": true
        }
        """.data(using: .utf8)!
        let custom = try JSONDecoder().decode(CopyCustomizations.self, from: customRaw)
        XCTAssertEqual(custom.includeUserPrompt, false)

        let encodedOverrides = try String(data: JSONEncoder().encode(overrides), encoding: .utf8).unwrapForTest()
        let encodedCustom = try String(data: JSONEncoder().encode(custom), encoding: .utf8).unwrapForTest()
        for removedKey in ["xmlFormat", "systemPromptFlavor", "includeMCPMetadata"] {
            XCTAssertFalse(encodedOverrides.contains(removedKey))
            XCTAssertFalse(encodedCustom.contains(removedKey))
        }
    }
}

@MainActor
final class ReviewPromptUpgradeTests: XCTestCase {
    private static let reviewPromptID = UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!

    /// The [Review] default that shipped before the current one. It is copied here instead of read from
    /// `previousReviewPromptV2`, so an accidental edit to that snapshot fails this test.
    private static let previousShippedReviewDefault = """
    You are reviewing code changes with git diffs included in the prompt. The git diff shows what changed; the file contents show full context. Use both.

    **Review Criteria:**

    1. **Correctness & Safety**:
    \t- Do the changes achieve their intended purpose without regressions?
    \t- Are edge cases and error paths handled?
    \t- Any security vulnerabilities, race conditions, or resource leaks?
    \t- Any breaking changes to APIs or contracts?

    2. **Design & Complexity**:
    \t- Do changes increase coupling or reduce separation of concerns?
    \t- Is new complexity justified, or can the same result be achieved more simply?
    \t- Are there DRY violations — duplicated logic that should be extracted?
    \t- Do abstractions sit at the right level (not too early, not too late)?

    3. **Intentionality**:
    \t- Does every change have a clear purpose? Flag accidental modifications or dead code.
    \t- Are the changes minimal and focused, or is scope creeping in?

    **Severity Levels — be disciplined about classification:**
    - **P0 (Must fix)**: Bugs, data loss, security holes, crashes — things that break correctness.
    - **P1 (Should fix)**: Design issues that will compound — poor separation of concerns, growing complexity, DRY violations, missing error handling for reachable paths.
    - **P2 (Consider)**: Style, naming, minor refactoring opportunities, test coverage gaps.

    Most findings should be P1 or P2. Reserve P0 for genuinely broken behavior.

    **Output Format:**
    1. One-paragraph summary of what the changes accomplish.
    2. Findings grouped by severity (P0 → P1 → P2), each with: file reference, what's wrong, and a concrete suggestion. Omit empty severity groups.
    3. If no issues found at a severity level, skip it — don't pad the review.
    """

    func testUneditedPreviousReviewDefaultUpgradesAndEditedCopyIsKept() throws {
        let freshInstall = try loadReviewPrompt(seeding: [])
        XCTAssertNotEqual(freshInstall.loaded.content, Self.previousShippedReviewDefault)

        /// A store saved by any earlier launch holds every built-in, so seeding all of them leaves
        /// the [Review] decision as the only reason the load can save.
        func storeWithReview(content: String) -> [StoredPromptRecord] {
            freshInstall.storedPrompts.map { prompt in
                guard prompt.id == Self.reviewPromptID else { return prompt }
                return StoredPromptRecord(id: prompt.id, title: "[Review]", content: content)
            }
        }

        let upgraded = try loadReviewPrompt(seeding: storeWithReview(content: Self.previousShippedReviewDefault))
        XCTAssertEqual(upgraded.loaded.content, freshInstall.loaded.content)
        XCTAssertFalse(upgraded.loaded.isUserEdited)
        XCTAssertEqual(upgraded.persisted, upgraded.loaded)
        XCTAssertFalse(upgraded.persisted.isUserEdited)

        let editedContent = Self.previousShippedReviewDefault + "\nAlso check logging."
        let edited = try loadReviewPrompt(seeding: storeWithReview(content: editedContent))
        XCTAssertEqual(edited.loaded.content, editedContent)
        XCTAssertTrue(edited.loaded.isUserEdited)
        XCTAssertEqual(edited.persisted.content, editedContent)
    }

    private func loadReviewPrompt(
        seeding seededPrompts: [StoredPromptRecord]
    ) throws -> (loaded: StoredPromptRecord, persisted: StoredPromptRecord, storedPrompts: [StoredPromptRecord]) {
        let directory = try makeTestDirectory()
        let storage = PromptStorage(fileURL: directory.appendingPathComponent("SavedPrompts.json"))
        if !seededPrompts.isEmpty {
            _ = try storage.mutatePrompts { prompts in
                prompts = seededPrompts
                return ((), true)
            }.get()
        }

        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        addTeardownBlock { @MainActor in apiSettings.prepareForWindowClose() }
        let prompts = PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: -1931,
            settingsManager: WindowSettingsManager(windowID: -1931),
            storedPromptPersistence: StoredPromptPersistenceService(storage: storage)
        )
        let loaded = try XCTUnwrap(prompts.storedPrompts.first { $0.id == Self.reviewPromptID })
        // Storage reads and writes share one serial queue, so this read waits for the load's background save.
        let persisted = try XCTUnwrap(storage.loadPrompts().get().first { $0.id == Self.reviewPromptID })
        return (loaded, persisted, prompts.storedPrompts)
    }
}

private extension String? {
    func unwrapForTest(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(self, file: file, line: line)
    }
}
