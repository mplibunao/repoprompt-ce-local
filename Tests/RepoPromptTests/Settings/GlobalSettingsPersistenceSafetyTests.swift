import Foundation
@testable import RepoPromptApp
import XCTest

/// Guards the durable behavior of the schema-v8 parameter-pin admission and the Agent Models
/// pin buckets: content-derived schema stamping, the rejected experimental v6, unported-content
/// preservation, bucket coherence, and the frozen-codec rollback boundary.
@MainActor
final class GlobalSettingsPersistenceSafetyTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = try makeTemporaryRoot()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    // MARK: - Round trips and global decomposition

    /// Round-trip + global decomposition for the OpenCode parameter-pin buckets. A profile
    /// field without a backing `GlobalDefaults` field mapped in **both**
    /// `globalAgentModelsProfile()` and `setGlobalAgentModelsProfile` is dropped on the next
    /// read, so both halves are asserted here.
    func testAgentModelParameterPinsSurviveCodecAndGlobalDecomposition() throws {
        let pin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let cbPin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "low"
        )
        let profile = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: "openCode",
            contextBuilderModelsByAgent: ["openCode": "ollama-cloud/kimi-k3"],
            mcpAgentRoleOverrides: ["engineer": "openCode:ollama-cloud/kimi-k3"],
            mcpAgentRoleModelParameters: ["engineer": [pin]],
            contextBuilderModelParametersByAgent: ["openCode": [cbPin]]
        )

        // Codec round-trip.
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: encoded)
        XCTAssertEqual(decoded.mcpAgentRoleModelParameters?["engineer"], [pin])
        XCTAssertEqual(decoded.contextBuilderModelParametersByAgent?["openCode"], [cbPin])

        // Global decomposition: set → read through the backing GlobalDefaults store.
        let store = try makeStore()

        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .userInitiated)
        let readBack = store.globalAgentModelsProfile()
        XCTAssertEqual(readBack.mcpAgentRoleModelParameters?["engineer"], [pin])
        XCTAssertEqual(readBack.contextBuilderModelParametersByAgent?["openCode"], [cbPin])
    }

    /// Workspace-scope pins persist through the file store and reload with the workspace's
    /// effective profile, and the read predicate scopes to the persisted Context Builder agent.
    func testContextBuilderPinWorkspaceRoundTripScopesToPersistedAgentAndModel() throws {
        let workspaceID = UUID()
        let cbPin = makePin(valueRaw: "high")
        let store = try makeStore()

        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        store.setAgentModelsContextBuilderModelParameter(
            .set(cbPin),
            agentRaw: "openCode",
            modelRaw: Self.modelRaw,
            scope: .workspace(workspaceID)
        )

        let effective = store.effectiveAgentModelsProfile(workspaceID: workspaceID)
        XCTAssertEqual(
            effective.contextBuilderModelParameterSelections(for: .openCode, modelRaw: Self.modelRaw),
            [cbPin]
        )
        // Eligibility requires the bucket's agent to be the persisted Context Builder agent:
        // another ACP agent with the same model raw reads nothing.
        XCTAssertEqual(
            effective.contextBuilderModelParameterSelections(for: .cursor, modelRaw: Self.modelRaw),
            []
        )

        // Reload from disk: the workspace bucket survives a fresh store.
        let reloaded = try makeStore()
        XCTAssertEqual(
            reloaded.effectiveAgentModelsProfile(workspaceID: workspaceID)
                .contextBuilderModelParameterSelections(for: .openCode, modelRaw: Self.modelRaw),
            [cbPin]
        )
    }

    // MARK: - Coherence and backing-state cleanup

    /// A role bucket survives only while its role override resolves to the same provider and
    /// canonical model; changing the override through the plain overrides setter drops the
    /// bucket through the shared coherence owner.
    func testRolePinBucketDropsWhenOverrideMovesToAnotherModel() throws {
        let store = try makeStore()
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )
        XCTAssertEqual(store.globalAgentModelsProfile().mcpAgentRoleOverrides?["engineer"], "openCode:\(Self.modelRaw)")

        store.setAgentModelsMCPAgentRoleOverrides(
            ["engineer": "openCode:anthropic/claude-sonnet"],
            scope: .global
        )

        let profile = store.globalAgentModelsProfile()
        XCTAssertNil(profile.mcpAgentRoleModelParameters?["engineer"])
        XCTAssertEqual(profile.mcpAgentRoleOverrides?["engineer"], "openCode:anthropic/claude-sonnet")
    }

    /// A Context Builder bucket drops once the persisted Context Builder model moves. The
    /// profile value update defers to the construction/decode coherence boundary, so the
    /// user-facing guarantee is asserted where it is enforced: the save→load round trip.
    func testContextBuilderPinBucketDropsWhenPersistedModelChanges() throws {
        let cbPin = makePin(valueRaw: "high")
        let profile = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: "openCode",
            contextBuilderModelsByAgent: ["openCode": Self.modelRaw],
            contextBuilderModelParametersByAgent: ["openCode": [cbPin]]
        )

        let store = try makeStore()
        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .userInitiated)
        XCTAssertNotNil(store.globalAgentModelsProfile().contextBuilderModelParametersByAgent?["openCode"])

        let changed = profile.replacingContextBuilderModel("anthropic/claude-sonnet", for: "openCode")
        store.setGlobalAgentModelsProfile(changed, contextBuilderWriteIntent: .userInitiated)

        let reloaded = try makeStore()
        let finalProfile = reloaded.globalAgentModelsProfile()
        XCTAssertEqual(finalProfile.contextBuilderModelsByAgent?["openCode"], "anthropic/claude-sonnet")
        XCTAssertNil(finalProfile.contextBuilderModelParametersByAgent?["openCode"])
    }

    /// Clearing pins removes the backing fields entirely (nil, not empty maps), so the saved
    /// JSON does not accumulate empty pin containers.
    func testClearingPinsRemovesBackingFieldsFromDisk() throws {
        let store = try makeStore()
        let roleSelection = AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw)
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: roleSelection,
            scope: .global
        )
        store.setAgentModelsContextBuilderModelParameter(
            .set(makePin(valueRaw: "low")),
            agentRaw: "openCode",
            modelRaw: Self.modelRaw,
            scope: .global
        )
        let savedRoot = try readJSONObject()
        let savedGlobalDefaults = try XCTUnwrap(savedRoot["globalDefaults"] as? [String: Any])
        XCTAssertNotNil(savedGlobalDefaults["mcpAgentRoleModelParameters"])
        XCTAssertNotNil(savedGlobalDefaults["contextBuilderModelParametersByAgent"])

        store.setAgentModelsRoleModelParameter(
            .clear(makePin(valueRaw: "high").identity),
            roleRawValue: "engineer",
            displayedSelectionID: roleSelection,
            scope: .global
        )
        store.setAgentModelsContextBuilderModelParameter(
            .clear(makePin(valueRaw: "low").identity),
            agentRaw: "openCode",
            modelRaw: Self.modelRaw,
            scope: .global
        )

        let clearedRoot = try readJSONObject()
        let clearedGlobalDefaults = try XCTUnwrap(clearedRoot["globalDefaults"] as? [String: Any])
        XCTAssertNil(clearedGlobalDefaults["mcpAgentRoleModelParameters"])
        XCTAssertNil(clearedGlobalDefaults["contextBuilderModelParametersByAgent"])
    }

    // MARK: - No-op writes

    /// Re-committing the identical pin is a no-op: no save happens, so the file bytes (and the
    /// stamped `updatedAt`) are untouched. Without the guard, a no-op pin click would still
    /// claim Context Builder ownership and restamp the document.
    func testNoOpPinWriteLeavesFileBytesUntouched() throws {
        let store = try makeStore()
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )
        store.setAgentModelsContextBuilderModelParameter(
            .set(makePin(valueRaw: "low")),
            agentRaw: "openCode",
            modelRaw: Self.modelRaw,
            scope: .global
        )
        let bytesAfterWrites = try Data(contentsOf: fileURL)

        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )
        store.setAgentModelsContextBuilderModelParameter(
            .set(makePin(valueRaw: "low")),
            agentRaw: "openCode",
            modelRaw: Self.modelRaw,
            scope: .global
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), bytesAfterWrites)
    }

    // MARK: - Schema fences

    /// Pins stamp v8 (the pin fence); Context Builder scalar content stays baseline v2 (there
    /// is no v5 fence in this lineage), and a v5 same-lineage header is accepted. The frozen
    /// v1.0.28 codec rejects the pinned v8 file, which is the rollback boundary.
    func testParameterPinsStampV8WhileContextBuilderScalarsStayBaseline() throws {
        let contextBuilderDocument = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                contextBuilder: .init(
                    contextTokenBudget: 1234,
                    analysisTokenBudget: 5678,
                    enhancementMode: "balanced",
                    questionTimeoutSeconds: 91,
                    allowUIClarifyingQuestions: true,
                    allowMCPClarifyingQuestions: false,
                    followUpAnalysisEnabled: true
                )
            )
        )
        XCTAssertEqual(
            contextBuilderDocument.requiredSchemaVersion,
            GlobalSettingsDocument.baselineSchemaVersion
        )
        XCTAssertFalse(GlobalSettingsFileStore.shouldPreserveWithoutLoading(
            schemaVersion: 5,
            schemaLineage: GlobalSettingsDocument.schemaLineage
        ))

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(contextBuilderDocument)
        XCTAssertEqual(
            try readJSONObject()["schemaVersion"] as? Int,
            GlobalSettingsDocument.baselineSchemaVersion
        )

        let store = try makeStore()
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )

        XCTAssertEqual(
            try readJSONObject()["schemaVersion"] as? Int,
            GlobalSettingsDocument.agentModelParameterPinsSchemaVersion
        )
        XCTAssertThrowsError(try FrozenV1028GlobalSettingsDocument.load(from: fileURL)) { error in
            XCTAssertEqual(
                error as? FrozenV1028GlobalSettingsDocument.CompatibilityError,
                .unsupportedFutureSchema(GlobalSettingsDocument.agentModelParameterPinsSchemaVersion)
            )
        }
    }

    /// Same-lineage v6 was written only by experimental builds: load rejects it, the bytes are
    /// preserved, and even an explicit compatible import is refused.
    func testSameLineageV6IsRejectedOnLoadAndRefusedByCompatibleImport() throws {
        let store = try makeStore()
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )

        var v6Root = try readJSONObject()
        v6Root["schemaVersion"] = 6
        try writeJSONObject(v6Root)
        let v6Bytes = try Data(contentsOf: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        XCTAssertThrowsError(try fileStore.load()) { error in
            XCTAssertEqual(
                error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError,
                .incompatibleSchema
            )
        }
        XCTAssertEqual(fileStore.blockReason, .incompatibleSchema)

        let blockedStore = try makeStore()
        XCTAssertEqual(blockedStore.persistenceBlockReason, .incompatibleSchema)
        XCTAssertEqual(try Data(contentsOf: fileURL), v6Bytes)

        XCTAssertFalse(fileStore.performUserInitiatedCompatibleImport())
        XCTAssertEqual(try Data(contentsOf: fileURL), v6Bytes)
    }

    /// An old-writer regression to v2 that preserved the global pin content loads fine, and the
    /// next current-build save restamps v8 through the content-derived minimum.
    func testOldWriterV2FileWithGlobalPinsRestampsV8OnCurrentSave() throws {
        let store = try makeStore()
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )

        var regressedRoot = try readJSONObject()
        regressedRoot["schemaVersion"] = 2
        try writeJSONObject(regressedRoot)

        let loaded = try GlobalSettingsFileStore(fileURL: fileURL).load()
        XCTAssertEqual(
            loaded.requiredSchemaVersion,
            GlobalSettingsDocument.agentModelParameterPinsSchemaVersion
        )

        let restampingStore = try makeStore()
        restampingStore.setAppearanceModeRaw("Dark")
        let restampedRoot = try readJSONObject()
        XCTAssertEqual(
            restampedRoot["schemaVersion"] as? Int,
            GlobalSettingsDocument.agentModelParameterPinsSchemaVersion
        )
        XCTAssertEqual(
            ((restampedRoot["scalarPreferences"] as? [String: Any])?["ui"] as? [String: Any])?["appearanceMode"]
                as? String,
            "Dark"
        )
        let pinBuckets = try XCTUnwrap(
            (restampedRoot["globalDefaults"] as? [String: Any])?["mcpAgentRoleModelParameters"] as? [String: Any]
        )
        XCTAssertNotNil(pinBuckets["engineer"])
    }

    // MARK: - Unported-content preservation

    /// Populated unported Oracle-roster fields block at either location with the original bytes
    /// preserved; an empty roster carries nothing and passes.
    func testPopulatedUnportedOracleRosterFieldsArePreservedNotRewritten() throws {
        try assertContentBlockedAfterMutation { root in
            var scalarPreferences = root["scalarPreferences"] as? [String: Any] ?? [:]
            var modelSelection = scalarPreferences["modelSelection"] as? [String: Any] ?? [:]
            modelSelection["additionalOracleModels"] = ["x-ai/grok-code"]
            scalarPreferences["modelSelection"] = modelSelection
            root["scalarPreferences"] = scalarPreferences
        }
        try assertContentBlockedAfterMutation { root in
            let workspaceID = try XCTUnwrap((root["agentModelsSettingsByWorkspaceID"] as? [String: Any])?.keys.first)
            var agentModels = root["agentModelsSettingsByWorkspaceID"] as? [String: Any] ?? [:]
            var workspace = agentModels[workspaceID] as? [String: Any] ?? [:]
            var profile = workspace["profile"] as? [String: Any] ?? [:]
            profile["additionalOracleModelRaws"] = ["x-ai/grok-code"]
            workspace["profile"] = profile
            agentModels[workspaceID] = workspace
            root["agentModelsSettingsByWorkspaceID"] = agentModels
        }

        // An empty roster carries no models and must not block; start from a clean document
        // because the blocked-mutation sections above left the shared file unloadable.
        try? FileManager.default.removeItem(at: fileURL)
        let store = try makeStore()
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )
        var rosterRoot = try readJSONObject()
        var scalarPreferences = rosterRoot["scalarPreferences"] as? [String: Any] ?? [:]
        var modelSelection = scalarPreferences["modelSelection"] as? [String: Any] ?? [:]
        modelSelection["additionalOracleModels"] = []
        scalarPreferences["modelSelection"] = modelSelection
        rosterRoot["scalarPreferences"] = scalarPreferences
        try writeJSONObject(rosterRoot)

        let rosterStore = try makeStore()
        XCTAssertNil(rosterStore.persistenceBlockReason)
        XCTAssertEqual(
            rosterStore.globalAgentModelsProfile().mcpAgentRoleModelParameters?["engineer"],
            [makePin(valueRaw: "high")]
        )
    }

    /// Parameter structures naming a provider or kind this build cannot represent block, while
    /// an unadvertised effort `valueRaw` is valid stored intent and round-trips untouched.
    func testUnrepresentableParameterEnumsBlockWhileUnsupportedEffortValuesStayValidIntent() throws {
        try assertContentBlockedAfterMutation { root in
            var globalDefaults = root["globalDefaults"] as? [String: Any] ?? [:]
            globalDefaults["mcpAgentRoleModelParameters"] = [
                "engineer": [[
                    "providerID": "warpDrive",
                    "baseModelRaw": Self.modelRaw,
                    "kind": "thinking",
                    "configID": "effort",
                    "valueRaw": "high"
                ]]
            ]
            root["globalDefaults"] = globalDefaults
        }
        try assertContentBlockedAfterMutation { root in
            var globalDefaults = root["globalDefaults"] as? [String: Any] ?? [:]
            globalDefaults["contextBuilderModelParametersByAgent"] = [
                "openCode": [[
                    "providerID": "openCode",
                    "baseModelRaw": Self.modelRaw,
                    "kind": "vibe",
                    "configID": "effort",
                    "valueRaw": "high"
                ]]
            ]
            root["globalDefaults"] = globalDefaults
        }

        // An unsupported effort value is stored intent, not unrepresentable content: it saves,
        // reloads, and reads back exactly. Start from a clean document because the blocked
        // mutations above left the shared file unloadable.
        try? FileManager.default.removeItem(at: fileURL)
        let store = try makeStore()
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "ultra")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )
        let reloaded = try makeStore()
        XCTAssertEqual(
            reloaded.globalAgentModelsProfile().mcpAgentRoleModelParameters?["engineer"],
            [makePin(valueRaw: "ultra")]
        )
    }

    // MARK: - Helpers

    private static let modelRaw = "ollama-cloud/kimi-k3"

    private var fileURL: URL {
        temporaryRoot.appendingPathComponent("Settings/globalSettings.json")
    }

    private func makePin(valueRaw: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: Self.modelRaw,
            kind: .thinking,
            configID: "effort",
            valueRaw: valueRaw
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalSettingsPersistenceSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let suiteName = "GlobalSettingsPersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
    }

    /// Writes a valid pinned document, applies a raw JSON mutation, and asserts the mutated
    /// content blocks the load with the bytes preserved. The shared per-test file is reset
    /// first so each call blocks on its own mutation, independent of earlier blocked state.
    private func assertContentBlockedAfterMutation(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        try? FileManager.default.removeItem(at: fileURL)
        let workspaceID = UUID()
        let store = try makeStore()
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        store.setAgentModelsRoleModelParameter(
            .set(makePin(valueRaw: "high")),
            roleRawValue: "engineer",
            displayedSelectionID: AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.modelRaw),
            scope: .global
        )

        var root = try readJSONObject()
        try mutate(&root)
        try writeJSONObject(root)
        let blockedBytes = try Data(contentsOf: fileURL)

        let blockedStore = try makeStore()
        XCTAssertEqual(blockedStore.persistenceBlockReason, .incompatibleSchema)
        XCTAssertEqual(try Data(contentsOf: fileURL), blockedBytes)
    }

    private func readJSONObject() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func writeJSONObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }
}
