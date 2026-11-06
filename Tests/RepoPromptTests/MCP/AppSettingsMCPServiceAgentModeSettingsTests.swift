import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppSettingsMCPServiceAgentModeSettingsTests: XCTestCase {
    func testCodexReasoningSummariesSettingListsReadsAndWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.codex_reasoning_summaries_enabled"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(catalog.objectValue?["value"]?.boolValue, false)

        let getDefault = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string(key)
        ])
        XCTAssertEqual(getDefault.objectValue?["values"]?.objectValue?[key]?.boolValue, false)

        let setTrue = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(setTrue.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(setTrue.objectValue?["old_value"]?.boolValue, false)
        XCTAssertEqual(setTrue.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(setTrue.objectValue?["changed"]?.boolValue, true)
        XCTAssertTrue(store.codexReasoningSummariesEnabled())

        let setFalse = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(false)
        ])
        XCTAssertEqual(setFalse.objectValue?["old_value"]?.boolValue, true)
        XCTAssertEqual(setFalse.objectValue?["new_value"]?.boolValue, false)
        XCTAssertEqual(setFalse.objectValue?["changed"]?.boolValue, true)
        XCTAssertFalse(store.codexReasoningSummariesEnabled())
    }

    func testIdleProviderShutdownSettingDefaultsAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.idle_provider_shutdown_minutes"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "number")
        XCTAssertEqual(catalog.objectValue?["value"]?.intValue, 5)

        let getDefault = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string(key)
        ])
        XCTAssertEqual(getDefault.objectValue?["values"]?.objectValue?[key]?.intValue, 5)

        let set = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .int(15)
        ])
        XCTAssertEqual(set.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(set.objectValue?["old_value"]?.intValue, 5)
        XCTAssertEqual(set.objectValue?["new_value"]?.intValue, 15)
        XCTAssertEqual(set.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(store.idleProviderShutdownMinutes(), 15)

        let persisted = try GlobalSettingsFileStore(fileURL: fileURL).load()
        XCTAssertEqual(persisted.scalarPreferences?.agentMode?.idleProviderShutdownMinutes, 15)
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        XCTAssertEqual(reloaded.idleProviderShutdownMinutes(), 15)
    }

    func testIdleProviderShutdownSettingRejectsInvalidValuesWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.idle_provider_shutdown_minutes"

        func set(_ value: Value) async throws -> Value {
            try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(key),
                "value": value
            ])
        }

        _ = try await set(.int(10))
        let fileBeforeInvalidWrites = try String(contentsOf: fileURL, encoding: .utf8)

        for (label, value) in [
            ("fraction", Value.double(1.5)),
            ("fraction string", .string("1.5")),
            ("negative", .int(-1)),
            ("above maximum", .int(121)),
            ("non-finite", .double(.infinity)),
            ("non-numeric string", .string("ten")),
            ("boolean", .bool(true)),
            ("null", .null)
        ] {
            do {
                _ = try await set(value)
                XCTFail("Expected \(label) to be rejected")
            } catch {}
            XCTAssertEqual(store.idleProviderShutdownMinutes(), 10, label)
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), fileBeforeInvalidWrites, label)
        }
        XCTAssertFalse(store.setIdleProviderShutdownMinutes(121))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), fileBeforeInvalidWrites)

        let disabled = try await set(.int(0))
        XCTAssertEqual(disabled.objectValue?["new_value"]?.intValue, 0)
        XCTAssertEqual(try GlobalSettingsFileStore(fileURL: fileURL).load().scalarPreferences?.agentMode?.idleProviderShutdownMinutes, 0)
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        XCTAssertEqual(reloaded.idleProviderShutdownMinutes(), 0)
    }

    func testAgentChatsPresentationPreferenceRemainsOutsideAppSettingsCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let keys = settings.compactMap { $0.objectValue?["key"]?.stringValue }
        let candidateKey = "agent_mode.show_compose_tabs_without_agent_sessions"
        XCTAssertFalse(keys.contains(candidateKey))

        for arguments: [String: Value] in [
            [
                "op": .string("get"),
                "key": .string(candidateKey)
            ],
            [
                "op": .string("set"),
                "key": .string(candidateKey),
                "value": .bool(true)
            ]
        ] {
            do {
                _ = try await service.handleForTesting(arguments)
                XCTFail("Expected \(candidateKey) to remain outside the app_settings catalog")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("Unknown or unavailable app setting key '\(candidateKey)'."),
                    String(describing: error)
                )
            }
        }
    }

    func testCodexHookApprovalStrictModeIsHumanOnlyAndPersistsWorkspaceOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let workspaceID = UUID()

        XCTAssertFalse(store.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID))
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting(
                workspaceOverride: store.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID)
            ),
            .appDefault
        )

        store.setGlobalCodexHookApprovalStrictModeEnabled(true)
        XCTAssertTrue(store.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID))
        XCTAssertNil(store.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID))

        for (setting, expectedEffectiveValue) in [
            (CodexHookApprovalWorkspaceSetting.dontRequireApproval, false),
            (.alwaysRequireApproval, true),
            (.appDefault, true)
        ] {
            store.setCodexHookApprovalStrictModeOverride(setting.workspaceOverride, for: workspaceID)
            XCTAssertEqual(
                CodexHookApprovalWorkspaceSetting(
                    workspaceOverride: store.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID)
                ),
                setting
            )
            XCTAssertEqual(store.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID), expectedEffectiveValue)
        }

        store.setCodexHookApprovalStrictModeOverride(
            CodexHookApprovalWorkspaceSetting.dontRequireApproval.workspaceOverride,
            for: workspaceID
        )
        let reloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertTrue(reloaded.globalCodexHookApprovalStrictModeEnabled())
        XCTAssertEqual(reloaded.codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID), false)
        XCTAssertFalse(reloaded.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID))

        let service = AppSettingsMCPService(store: reloaded)
        for key in [
            "agent_mode.codex_hook_approval_strict_mode_enabled",
            "agent_mode.codex_hook_approval_strict_mode_workspace_overrides"
        ] {
            do {
                _ = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string(key),
                    "value": .bool(true)
                ])
                XCTFail("Expected human-only setting rejection for \(key)")
            } catch {
                let diagnostic = String(describing: error)
                XCTAssertTrue(diagnostic.contains("security-sensitive"), diagnostic)
                XCTAssertTrue(diagnostic.contains("human"), diagnostic)
            }
        }
    }

    func testHandoffInstructionsRemainOutsideAppSettingsCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let candidateKey = "agent_mode.handoff_instructions"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let keys = settings.compactMap { $0.objectValue?["key"]?.stringValue }
        XCTAssertFalse(keys.contains(candidateKey))
        XCTAssertFalse(keys.contains { $0.localizedCaseInsensitiveContains("handoff") })

        for arguments: [String: Value] in [
            [
                "op": .string("get"),
                "key": .string(candidateKey)
            ],
            [
                "op": .string("set"),
                "key": .string(candidateKey),
                "value": .string("Must remain local")
            ]
        ] {
            do {
                _ = try await service.handleForTesting(arguments)
                XCTFail("Expected \(candidateKey) to remain outside the app_settings catalog")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("Unknown or unavailable app setting key '\(candidateKey)'."),
                    String(describing: error)
                )
            }
        }

        XCTAssertEqual(store.agentSessionHandoffInstructions(), "")
    }

    func testModelSyncClearsAndEnablesPreserveDurableInvariant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let service = AppSettingsMCPService(store: store)
        let model = AIModel.gpt54Pro.rawValue

        func set(_ key: String, _ value: Value) async throws -> Value {
            try await service.handleForTesting([
                "op": .string("set"),
                "key": .string(key),
                "value": value
            ])
        }

        let rejectedEnable = try await set("models.sync_chat_model_with_oracle", .bool(true))
        XCTAssertEqual(rejectedEnable.objectValue?["new_value"]?.boolValue, false)
        XCTAssertFalse(store.syncChatModelWithOracle())

        _ = try await set("models.planning_model", .string(model))
        _ = try await set("models.preferred_compose_model", .string(AIModel.claude4Sonnet.rawValue))
        let validEnable = try await set("models.sync_chat_model_with_oracle", .bool(true))
        XCTAssertEqual(validEnable.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(store.planningModelRaw(), model)
        XCTAssertEqual(store.preferredComposeModelRaw(), model)
        XCTAssertTrue(store.syncChatModelWithOracle())

        let clearedCompose = try await set("models.preferred_compose_model", .null)
        XCTAssertNil(clearedCompose.objectValue?["new_value"]?.stringValue)
        XCTAssertEqual(store.planningModelRaw(), model)
        XCTAssertNil(store.preferredComposeModelRaw())
        XCTAssertFalse(store.syncChatModelWithOracle())

        _ = try await set("models.preferred_compose_model", .string(model))
        _ = try await set("models.sync_chat_model_with_oracle", .bool(true))
        let clearedPlanning = try await set("models.planning_model", .null)
        XCTAssertNil(clearedPlanning.objectValue?["new_value"]?.stringValue)
        XCTAssertNil(store.planningModelRaw())
        XCTAssertEqual(store.preferredComposeModelRaw(), model)
        XCTAssertFalse(store.syncChatModelWithOracle())

        let persisted = try fileStore.load()
        XCTAssertNil(persisted.scalarPreferences?.modelSelection?.planningModel)
        XCTAssertEqual(persisted.scalarPreferences?.modelSelection?.preferredComposeModel, model)
        XCTAssertEqual(persisted.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
    }

    func testSetWarnsWhenGlobalSettingsPersistenceIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )

        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.codex_reasoning_summaries_enabled"
        let result = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])

        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(result.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["persistence_blocked"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["persistence_block_reason"]?.stringValue, "unsupported_future_schema")
        XCTAssertTrue(result.objectValue?["persistence_warning"]?.stringValue?.contains("will not persist") ?? false)
        XCTAssertTrue(store.codexReasoningSummariesEnabled())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    func testSetReportsAutomaticSchemaNormalizationFailureWithoutTouchingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let falseV4JSON = #"{"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        try Data(falseV4JSON.utf8).write(to: fileURL)
        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: fileURL,
                normalizationBackupWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )
        let service = AppSettingsMCPService(store: store)

        let result = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("agent_mode.codex_reasoning_summaries_enabled"),
            "value": .bool(true)
        ])

        XCTAssertEqual(
            result.objectValue?["persistence_block_reason"]?.stringValue,
            "automatic_schema_normalization_failed"
        )
        let warning = try XCTUnwrap(result.objectValue?["persistence_warning"]?.stringValue)
        XCTAssertTrue(warning.contains("applied in memory"))
        XCTAssertTrue(warning.contains("original file is preserved"))
        XCTAssertTrue(warning.contains("explicit recovery"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), falseV4JSON)
    }

    /// Reads report an unknown saved agent ID as stored, with no model, so clearing the model is a
    /// no-op. An explicit agent or model write then replaces the ID durably and keeps remembered models.
    func testContextBuilderAgentSetOfDisplayedFallbackReplacesUnknownStoredAgent() async throws {
        let claudeRaw = AgentProviderKind.claudeCode.rawValue
        let unknownRaw = "unknown-context-builder-agent"
        let rememberedModels = [unknownRaw: "unknown-remembered-model", claudeRaw: "haiku"]
        func seedUnknownAgent(in store: GlobalSettingsStore) {
            store.setGlobalAgentModelsProfile(
                AgentModelsSettingsProfile(
                    contextBuilderAgentRaw: unknownRaw,
                    contextBuilderModelsByAgent: rememberedModels
                ),
                contextBuilderWriteIntent: .userInitiated
            )
        }

        try await withContextBuilderSettings { store, service, _, _ in
            seedUnknownAgent(in: store)
            let get = try await service.handleForTesting([
                "op": .string("get"),
                "keys": .array([.string("context_builder.agent"), .string("context_builder.model")])
            ])
            let values = try XCTUnwrap(get.objectValue?["values"]?.objectValue)
            XCTAssertEqual(values["context_builder.agent"]?.stringValue, unknownRaw)
            XCTAssertEqual(values["context_builder.model"], .null)

            let clear = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string("context_builder.model"),
                "value": .null
            ])
            XCTAssertEqual(clear.objectValue?["changed"]?.boolValue, false)
            XCTAssertEqual(clear.objectValue?["applied"]?.boolValue, false)
            XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, unknownRaw)
            XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderModelsByAgent, rememberedModels)

            let options = try await service.handleForTesting([
                "op": .string("options"),
                "key": .string("context_builder.model")
            ])
            XCTAssertEqual(
                options.objectValue?["filters"]?.objectValue?["agent"]?.stringValue,
                claudeRaw,
                "implicit options target the model writer's agent"
            )
        }

        // `haiku` equals Claude's remembered model; the write still applies because the read was null.
        for (key, value) in [("context_builder.agent", claudeRaw), ("context_builder.model", "haiku")] {
            try await withContextBuilderSettings { store, service, defaults, fileURL in
                seedUnknownAgent(in: store)
                let set = try await service.handleForTesting([
                    "op": .string("set"),
                    "key": .string(key),
                    "value": .string(value)
                ])
                XCTAssertEqual(set.objectValue?["changed"]?.boolValue, true, key)
                XCTAssertEqual(set.objectValue?["applied"]?.boolValue, true, key)
                XCTAssertNil(set.objectValue?["persistence_blocked"], key)
                let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
                for (phase, profile) in [
                    ("live", store.globalAgentModelsProfile()),
                    ("reloaded", reloaded.globalAgentModelsProfile())
                ] {
                    XCTAssertEqual(profile.contextBuilderAgentRaw, claudeRaw, "\(key), \(phase)")
                    XCTAssertEqual(profile.contextBuilderModelsByAgent, rememberedModels, "\(key), \(phase)")
                }
            }
        }

        // With no saved agent, a model write saves Claude as the agent and marks the choice user-set.
        try await withContextBuilderSettings { store, service, _, _ in
            XCTAssertNil(store.globalAgentModelsProfile().contextBuilderAgentRaw)
            XCTAssertFalse(store.hasUserSetGlobalContextBuilderAgentDefaults)
            let set = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string("context_builder.model"),
                "value": .string("sonnet")
            ])
            XCTAssertEqual(set.objectValue?["new_value"]?.stringValue, "sonnet")
            let profile = store.globalAgentModelsProfile()
            XCTAssertEqual(profile.contextBuilderAgentRaw, claudeRaw)
            XCTAssertEqual(profile.contextBuilderModelsByAgent?[claudeRaw], "sonnet")
            XCTAssertTrue(store.hasUserSetGlobalContextBuilderAgentDefaults)
        }
    }

    /// A known agent that is unavailable stays the stored choice through both writers, and model
    /// writes change only that agent's slot.
    func testContextBuilderSettingsPreserveUnavailableStoredAgent() async throws {
        try await withContextBuilderSettings { store, service, defaults, fileURL in
            let cursorRaw = AgentProviderKind.cursor.rawValue
            XCTAssertFalse(
                AgentModelCatalog.isAgentAvailable(.cursor),
                "Precondition: the default availability context marks Cursor unavailable"
            )
            var expectedModels = [
                AgentProviderKind.claudeCode.rawValue: "haiku",
                AgentProviderKind.codexExec.rawValue: "codex-remembered-model"
            ]
            store.setGlobalAgentModelsProfile(
                AgentModelsSettingsProfile(
                    contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
                    contextBuilderModelsByAgent: expectedModels
                ),
                contextBuilderWriteIntent: .userInitiated
            )

            func set(_ key: String, _ value: Value) async throws -> Value {
                try await service.handleForTesting(["op": .string("set"), "key": .string(key), "value": value])
            }
            @MainActor func assertStoredCursor(
                models: [String: String],
                in store: GlobalSettingsStore,
                service: AppSettingsMCPService,
                _ phase: String
            ) async throws {
                let profile = store.globalAgentModelsProfile()
                XCTAssertEqual(profile.contextBuilderAgentRaw, cursorRaw, phase)
                XCTAssertEqual(profile.contextBuilderModelsByAgent, models, phase)
                let get = try await service.handleForTesting([
                    "op": .string("get"),
                    "keys": .array([.string("context_builder.agent"), .string("context_builder.model")])
                ])
                let values = try XCTUnwrap(get.objectValue?["values"]?.objectValue, phase)
                XCTAssertEqual(values["context_builder.agent"]?.stringValue, cursorRaw, phase)
                XCTAssertEqual(values["context_builder.model"], models[cursorRaw].map(Value.string) ?? .null, phase)
            }

            let setAgent = try await set("context_builder.agent", .string(cursorRaw))
            XCTAssertEqual(setAgent.objectValue?["new_value"]?.stringValue, cursorRaw)
            expectedModels[cursorRaw] = AgentModel.cursorAuto.rawValue
            try await assertStoredCursor(models: expectedModels, in: store, service: service, "after set agent")

            let setModel = try await set("context_builder.model", .string("cursor-custom-model"))
            XCTAssertEqual(setModel.objectValue?["changed"]?.boolValue, true)
            expectedModels[cursorRaw] = "cursor-custom-model"
            try await assertStoredCursor(models: expectedModels, in: store, service: service, "after set model")

            let clear = try await set("context_builder.model", .null)
            XCTAssertEqual(clear.objectValue?["changed"]?.boolValue, true)
            expectedModels[cursorRaw] = nil
            try await assertStoredCursor(models: expectedModels, in: store, service: service, "after clear")

            let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            try await assertStoredCursor(
                models: expectedModels,
                in: reloaded,
                service: AppSettingsMCPService(store: reloaded, notificationCenter: NotificationCenter()),
                "after reload"
            )
        }
    }

    /// An isolated store and `app_settings` service. `defaults` and the settings file URL let a test
    /// reload the store with `GlobalSettingsStore(defaults:fileStore:)`.
    private func withContextBuilderSettings(
        _ body: (GlobalSettingsStore, AppSettingsMCPService, UserDefaults, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        try await body(store, AppSettingsMCPService(store: store, notificationCenter: NotificationCenter()), defaults, fileURL)
    }
}
