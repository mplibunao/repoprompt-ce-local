@testable import RepoPromptApp
import XCTest

/// A successful API-key validation seeds the chat (compose) model only while none is saved, so a
/// saved chat choice survives and a rejected key or failed key storage writes nothing.
@MainActor
final class APISettingsModelSeedTests: XCTestCase {
    func testSuccessfulValidationSeedsAnEmptyComposeModel() async throws {
        let seeds: [(provider: AIProviderType, model: AIModel, raw: String)] = [
            (.anthropic, .claudeSonnet55, "claude-sonnet-5-5"),
            (.openAI, .gpt6Luna, "gpt-6-luna"),
            (.openRouter, .openrouterClaudeSonnet55, "anthropic/claude-sonnet-5.5")
        ]
        let planning = AIModel.codexCustom(name: "gpt-5.6-sol-high").rawValue
        for seed in seeds {
            // A fresh fixture per provider, so an earlier seed cannot mask a later one.
            let fixture = try makeIsolatedAPISettingsFixture()
            fixture.store.setPlanningModelRaw(planning)

            let saved = try await fixture.apiSettings.validateAndSaveKey(key: " test-key ", for: seed.provider) { true }

            XCTAssertTrue(saved, "\(seed.provider)")
            XCTAssertEqual(fixture.store.preferredComposeModelRaw(), seed.raw, "\(seed.provider)")
            XCTAssertEqual(AIModel.fromModelName(seed.raw), seed.model, "\(seed.provider)")
            XCTAssertTrue(seed.model.isEligibleForAutomaticSelection, "\(seed.provider)")
            XCTAssertEqual(fixture.store.planningModelRaw(), planning, "\(seed.provider)")
            XCTAssertEqual(fixture.reloadStore().preferredComposeModelRaw(), seed.raw, "\(seed.provider)")
        }
    }

    func testSuccessfulValidationKeepsASavedComposeModel() async throws {
        let fixture = try makeIsolatedAPISettingsFixture()
        let custom = AIModel.openaiCustomReasoning(name: "gpt-6-sol", effort: .high).rawValue
        fixture.store.setPreferredComposeModelRaw(custom)

        let saved = try await fixture.apiSettings.validateAndSaveKey(key: "test-key", for: .openAI) { true }

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.store.preferredComposeModelRaw(), custom)
        XCTAssertNil(fixture.store.planningModelRaw())
    }

    func testRejectedKeyOrFailedKeyStorageWritesNoSeed() async throws {
        let rejected = try makeIsolatedAPISettingsFixture()
        let accepted = try await rejected.apiSettings.validateAndSaveKey(key: "test-key", for: .anthropic) { false }
        XCTAssertFalse(accepted)
        XCTAssertNil(rejected.store.preferredComposeModelRaw())
        XCTAssertNil(rejected.secureStorage.value(for: AIProviderType.anthropic.secureStorageAccount))

        let storageFailure = try makeIsolatedAPISettingsFixture()
        storageFailure.secureStorage.saveErrors[AIProviderType.openRouter.secureStorageAccount] = .interactionNotAllowed
        do {
            _ = try await storageFailure.apiSettings.validateAndSaveKey(key: "test-key", for: .openRouter) { true }
            XCTFail("The key-storage failure should propagate")
        } catch {
            XCTAssertEqual(error as? KeychainService.KeychainError, .interactionNotAllowed)
        }
        XCTAssertNil(storageFailure.store.preferredComposeModelRaw())
        XCTAssertFalse(storageFailure.apiSettings.isOpenRouterKeyValid)
    }
}
