import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentMCPModelParameterSupportTests: XCTestCase {
    func testCursorDefinitionsPreserveExactWireIdentifiersAndChoices() {
        let definitions = AgentMCPModelParameterSupport.definitions(agent: .cursor, modelRaw: "grok-4.6")

        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions[0].configID, "effort")
        XCTAssertEqual(definitions[0].choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(definitions[1].configID, "fast")
        XCTAssertEqual(definitions[1].choices.map(\.rawValue), ["false", "true"])
    }

    func testCursorDefinitionValuesPreserveListAgentsWireShape() {
        let values = AgentMCPModelParameterSupport.definitionValues(agent: .cursor, modelRaw: "grok-4.6")

        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].objectValue?["kind"]?.stringValue, "thinking")
        XCTAssertEqual(values[0].objectValue?["config_id"]?.stringValue, "effort")
        XCTAssertEqual(values[0].objectValue?["name"]?.stringValue, "Effort")
        XCTAssertEqual(values[0].objectValue?["current_value"]?.stringValue, "high")
        XCTAssertEqual(
            values[0].objectValue?["choices"]?.arrayValue?.compactMap { $0.objectValue?["value"]?.stringValue },
            ["low", "medium", "high", "xhigh"]
        )
        XCTAssertEqual(values[1].objectValue?["kind"]?.stringValue, "speed")
        XCTAssertEqual(values[1].objectValue?["config_id"]?.stringValue, "fast")
        XCTAssertEqual(values[1].objectValue?["name"]?.stringValue, "Speed")
        XCTAssertEqual(values[1].objectValue?["current_value"]?.stringValue, "true")
        XCTAssertEqual(
            values[1].objectValue?["choices"]?.arrayValue?.compactMap { $0.objectValue?["value"]?.stringValue },
            ["false", "true"]
        )
    }

    /// OpenCode definitions no longer read the provider-global registry synchronously: the
    /// demand-scoped authority lives behind the async observation overload, so the sync surface
    /// is Cursor-only and returns empty for OpenCode without acquired metadata.
    func testOpenCodeDefinitionsEmptyWithoutDiscoveryMetadata() {
        XCTAssertTrue(
            AgentMCPModelParameterSupport.definitions(
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3"
            ).isEmpty
        )
        XCTAssertTrue(
            AgentMCPModelParameterSupport.definitionValues(
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3"
            ).isEmpty
        )
    }

    /// Advertisement reduces a one-shot demand-scoped observation: a terminal `.available`
    /// observation for the exact (workspace, model) yields definitions; `.noUsableParameters`
    /// yields none. The per-call injected provider keeps this hermetic (no live ACP process,
    /// no mutable global override).
    func testOpenCodeAsyncDefinitionsComeFromOneShotObservation() async throws {
        let availableProvider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: "/workspace-a", modelRaw: "ollama-cloud/kimi-k3"),
                state: .available(self.openCodeEffortSet()),
                updatedAt: Date()
            )
        }
        let definitions = try await AgentMCPModelParameterSupport.definitions(
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3",
            workspacePath: "/workspace-a",
            oneShot: availableProvider
        )
        XCTAssertEqual(definitions.map(\.configID), ["effort"])
        XCTAssertEqual(definitions.first?.choices.map(\.rawValue), ["low", "high"])

        let noUsableProvider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: "/workspace-a", modelRaw: "ollama-cloud/kimi-k3"),
                state: .noUsableParameters,
                updatedAt: Date()
            )
        }
        let emptyDefinitions = try await AgentMCPModelParameterSupport.definitions(
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3",
            workspacePath: "/workspace-a",
            oneShot: noUsableProvider
        )
        XCTAssertTrue(emptyDefinitions.isEmpty)
    }

    func testNonACPDefinitionsReturnEmpty() {
        XCTAssertTrue(AgentMCPModelParameterSupport.definitions(agent: .codexExec, modelRaw: "gpt-5").isEmpty)
        XCTAssertTrue(AgentMCPModelParameterSupport.definitionValues(agent: .codexExec, modelRaw: "gpt-5").isEmpty)
    }

    func testResolveRejectsUnknownConfigBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("unknown"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown"))
        }
    }

    func testResolveRejectsUnknownValueBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("maximum")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("maximum"))
        }
    }

    func testResolvePreservesExactProviderWireValueAndCanonicalBase() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("HIGH")]),
            .object(["config_id": .string("fast"), "value": .string("true")])
        ])

        let selections = try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "Cursor Grok 4.6"
        )

        XCTAssertEqual(selections.map(\.configID), ["effort", "fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["high", "true"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["grok-4.6", "grok-4.6"])
    }

    func testResolveCanonicalizesLegacyComposer2BaseModel() throws {
        let selections = try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("fast"), "value": .string("true")])
            ]),
            agent: .cursor,
            modelRaw: "composer-2"
        )

        XCTAssertEqual(selections.map(\.baseModelRaw), ["composer-2.5"])
        XCTAssertEqual(selections.map(\.configID), ["fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["true"])
    }

    func testResolveRejectsWhitespaceBearingProviderConfigID() throws {
        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string(" effort "), "value": .string("high")])
            ]),
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testResolveRejectsDuplicateConfigIDs() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("low")]),
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testNonACPProviderRejectsModelParameters() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .codexExec,
            modelRaw: "gpt-5"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("ACP"))
        }
    }

    /// OpenCode explicit parameters are demand-scoped: the synchronous resolver cannot satisfy
    /// them, so it rejects with the existing "metadata unavailable" argument error rather than
    /// reading a provider-global snapshot.
    func testOpenCodeSyncResolveRejectsAsDemandScoped() {
        XCTAssertThrowsError(
            try AgentMCPModelParameterSupport.resolve(
                value: .array([
                    .object(["config_id": .string("effort"), "value": .string("high")])
                ]),
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("metadata is unavailable"))
        }
    }

    /// An explicit OpenCode request is validated by a fresh targeted observation. A throwing
    /// injected provider produces the existing "metadata unavailable" argument error — never an
    /// empty successful selection list.
    func testOpenCodeAsyncResolveErrorsWhenMetadataUnavailable() async {
        struct ScriptedTransportError: Error {}
        let failingProvider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            throw ScriptedTransportError()
        }
        do {
            _ = try await AgentMCPModelParameterSupport.resolve(
                value: .array([
                    .object(["config_id": .string("effort"), "value": .string("high")])
                ]),
                agent: .openCode,
                modelRaw: "anthropic/claude-sonnet",
                workspacePath: nil,
                oneShot: failingProvider
            )
            XCTFail("Expected an argument error when OpenCode metadata is unavailable.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("metadata is unavailable"))
        }
    }

    /// The central regression: metadata reaches the resolver and validates an explicit request
    /// *before any ACP session exists*, via the demand-scoped observation rather than a
    /// provider-global snapshot.
    func testOpenCodeAsyncResolveAcceptsInjectedObservationBeforeFirstPrompt() async throws {
        let provider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: "/workspace-a", modelRaw: "ollama-cloud/kimi-k3"),
                state: .available(self.openCodeEffortSet()),
                updatedAt: Date()
            )
        }
        let selections = try await AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("effort"), "value": .string("high")])
            ]),
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3",
            workspacePath: "/workspace-a",
            oneShot: provider
        )
        XCTAssertEqual(selections.map(\.providerID), [.openCode])
        XCTAssertEqual(selections.map(\.valueRaw), ["high"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["ollama-cloud/kimi-k3"])
    }

    /// The explicit-request path preserves cancellation: when the acquisition itself throws
    /// `CancellationError`, the explicit resolver surfaces it rather than converting it into
    /// "metadata unavailable". Real in-flight cancellation belongs to the polling-service
    /// lifecycle tests; here the injected provider proves the resolver's catch does not swallow
    /// cancellation.
    func testOpenCodeExplicitResolvePreservesCancellation() async throws {
        let provider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            throw CancellationError()
        }
        do {
            _ = try await AgentMCPModelParameterSupport.resolve(
                value: .array([
                    .object(["config_id": .string("effort"), "value": .string("high")])
                ]),
                agent: .openCode,
                modelRaw: "ollama-cloud/kimi-k3",
                workspacePath: "/workspace-a",
                oneShot: provider
            )
            XCTFail("Expected cancellation to propagate from the explicit OpenCode resolver.")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "Cancellation must propagate, not be converted into another error; got \(error)"
            )
        }
    }

    private func openCodeEffortSet() -> ACPModelParameterSet {
        ACPModelParameterSet(
            baseModelRaw: "ollama-cloud/kimi-k3",
            parameters: [
                .init(
                    kind: .thinking,
                    configID: "effort",
                    displayName: "Effort",
                    choices: [
                        .init(rawValue: "low", displayName: "Low"),
                        .init(rawValue: "high", displayName: "High")
                    ],
                    currentValueRaw: "low"
                )
            ]
        )
    }

    func testEffectiveSelectionsIncludeOpenCodeProvider() {
        let selections = [
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.openCode.rawValue,
                modelRaw: "ollama-cloud/kimi-k3"
            ),
            selections
        )
    }

    func testAgentRunSnapshotPublishesEffectiveModelParameterSelections() throws {
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            tabID: UUID(),
            sessionName: "Cursor run",
            agentRaw: AgentProviderKind.cursor.rawValue,
            agentDisplayName: "Cursor",
            modelRaw: "grok",
            reasoningEffortRaw: nil,
            modelParameterSelections: [
                .init(
                    providerID: ACPProviderID.cursor.rawValue,
                    baseModelRaw: "grok",
                    kind: ACPModelParameterKind.thinking.rawValue,
                    configID: "thought_level",
                    valueRaw: "high"
                )
            ],
            status: .running,
            statusText: nil,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )

        let parameter = try XCTUnwrap(
            snapshot.asObject()["agent"]?.objectValue?["model_parameters"]?.arrayValue?.first?.objectValue
        )
        XCTAssertEqual(parameter["provider_id"]?.stringValue, "cursor")
        XCTAssertEqual(parameter["base_model"]?.stringValue, "grok")
        XCTAssertEqual(parameter["kind"]?.stringValue, "thinking")
        XCTAssertEqual(parameter["config_id"]?.stringValue, "thought_level")
        XCTAssertEqual(parameter["value"]?.stringValue, "high")
    }

    func testEffectiveSelectionsExcludeOtherCursorBaseModels() {
        let selections = [
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "grok-4.6",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "high"
            ),
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "composer-2",
                kind: .speed,
                configID: "model_config",
                valueRaw: "fast"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "Grok 4.6"
            ),
            [
                ACPModelParameterSelection(
                    providerID: .cursor,
                    baseModelRaw: "grok-4.6",
                    kind: .thinking,
                    configID: "Cursor.Thought-Level",
                    valueRaw: "high"
                )
            ]
        )
    }

    // MARK: - Distribution role-pin merge and capture (issue #81, plan §8.5)

    /// Launch paths merge the role's inherited pin with the caller's explicit parameters:
    /// explicit wins per identity, an EMPTY explicit list is not a reset, and distinct
    /// identities coexist.
    func testMergedExplicitParametersLastWinPerIdentityAndEmptyIsNoReset() {
        let inheritedEffort = cursorPin(kind: .thinking, configID: "effort", valueRaw: "high")
        let explicitEffort = cursorPin(kind: .thinking, configID: "effort", valueRaw: "low")
        let explicitSpeed = cursorPin(kind: .speed, configID: "fast", valueRaw: "true")

        XCTAssertEqual(
            AgentMCPModelParameterSupport.merged(inherited: [inheritedEffort], explicit: [explicitEffort]),
            [explicitEffort]
        )
        XCTAssertEqual(
            AgentMCPModelParameterSupport.merged(inherited: [inheritedEffort], explicit: []),
            [inheritedEffort]
        )

        let coexisting = AgentMCPModelParameterSupport.merged(
            inherited: [inheritedEffort],
            explicit: [explicitSpeed]
        )
        XCTAssertEqual(coexisting.count, 2)
        XCTAssertEqual(coexisting.first { $0.kind == .thinking }?.valueRaw, "high")
        XCTAssertEqual(coexisting.first { $0.kind == .speed }?.valueRaw, "true")
    }

    /// Per-role stored pins resolve through the role-defaults service: each role's effective
    /// selection carries its OWN bucket pin, and a pin whose base model differs from the
    /// override's model is filtered out rather than retargeted.
    @MainActor
    func testEffectiveSelectionCarriesPerRoleStoredPinAndFiltersModelMismatch() throws {
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)
        let override = AgentModelSelectionID(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok-4.6"
        ).rawValue
        let engineerPin = cursorPin(kind: .thinking, configID: "effort", valueRaw: "high")
        let explorePin = cursorPin(kind: .thinking, configID: "effort", valueRaw: "low")
        let mismatchedPin = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "composer-2.5",
            kind: .thinking,
            configID: "effort",
            valueRaw: "medium"
        )
        let store = AgentModelsProfileRoleDefaultsStore(
            overrides: [
                AgentModelCatalog.TaskLabelKind.engineer.rawValue: override,
                AgentModelCatalog.TaskLabelKind.explore.rawValue: override
            ],
            roleModelParameters: [
                AgentModelCatalog.TaskLabelKind.engineer.rawValue: [engineerPin],
                AgentModelCatalog.TaskLabelKind.explore.rawValue: [explorePin, mismatchedPin]
            ]
        )

        let engineer = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .engineer,
            availability: availability,
            settingsStore: store
        ))
        XCTAssertEqual(engineer.effective.agent, .cursor)
        XCTAssertEqual(engineer.effective.modelRaw, "grok-4.6")
        XCTAssertEqual(engineer.modelParameters, [engineerPin])

        let explore = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .explore,
            availability: availability,
            settingsStore: store
        ))
        XCTAssertEqual(explore.modelParameters, [explorePin], "a pin for another base model must be filtered, not retargeted")
    }

    // MARK: - Role pins without a recommendation

    /// OpenCode is in no role's recommendation chain, so an OpenCode-only install has no
    /// recommendation for any role. A stored executable pin must still resolve, with only the
    /// parameters that match its provider and model.
    @MainActor
    func testRecommendationlessRolePinsResolveWithMatchingParameters() throws {
        let availability = openCodeOnlyAvailability
        let roles = AgentModelCatalog.TaskLabelKind.allCases
        let models = [Self.openCodeGlobalModel, Self.openCodeWorkspaceModel]
        let values = ["low", "medium", "high", "xhigh"]

        var overrides: [String: String] = [:]
        var buckets: [String: [ACPModelParameterSelection]] = [:]
        for (index, role) in roles.enumerated() {
            let model = models[index % models.count]
            let otherModel = models[(index + 1) % models.count]
            overrides[role.rawValue] = openCodeSelectionID(model)
            buckets[role.rawValue] = [
                openCodePin(baseModelRaw: " \(model.uppercased()) ", valueRaw: values[index]),
                openCodePin(baseModelRaw: otherModel, valueRaw: "ignored-other-model"),
                cursorPin(baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: "ignored-other-provider")
            ]
        }

        try withOpenCodeRolePinFixture(
            store: AgentModelsProfileRoleDefaultsStore(overrides: overrides, roleModelParameters: buckets),
            availability: availability
        ) {
            for (index, role) in roles.enumerated() {
                let model = models[index % models.count]
                try assertRolePinResolves(
                    role: role,
                    availability: availability,
                    model: model,
                    parameters: [openCodePin(baseModelRaw: " \(model.uppercased()) ", valueRaw: values[index])],
                    role.rawValue
                )
            }
        }

        try withOpenCodeRolePinFixture(
            store: AgentModelsProfileRoleDefaultsStore(
                overrides: [AgentModelCatalog.TaskLabelKind.pair.rawValue: openCodeSelectionID(Self.openCodeGlobalModel)]
            ),
            availability: availability
        ) {
            let resolved = try AgentMCPSelectionResolver.resolve(modelID: "pair", availability: availability)
            assertResolved(resolved, model: Self.openCodeGlobalModel, role: .pair, parameters: [], "pin without a bucket")
        }
    }

    /// Role resolution reads the effective Agent Models profile for the workspace: a workspace
    /// override replaces the global profile instead of overlaying it.
    @MainActor
    func testRecommendationlessRolePinsUseEffectiveWorkspaceProfile() throws {
        let availability = openCodeOnlyAvailability
        let store = try makeIsolatedSettingsStore()
        let workspaceID = UUID()
        let roleLessWorkspaceID = UUID()
        let pair = AgentModelCatalog.TaskLabelKind.pair.rawValue

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                mcpAgentRoleOverrides: [pair: openCodeSelectionID(Self.openCodeGlobalModel)],
                mcpAgentRoleModelParameters: [pair: [openCodePin(baseModelRaw: Self.openCodeGlobalModel, valueRaw: "high")]]
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                mcpAgentRoleOverrides: [pair: openCodeSelectionID(Self.openCodeWorkspaceModel)],
                mcpAgentRoleModelParameters: [pair: [openCodePin(baseModelRaw: Self.openCodeWorkspaceModel, valueRaw: "low")]]
            )
        )
        // Save the role-less profile before selecting it; the reverse order on a workspace
        // with no saved profile would copy the global profile, including its pair pin.
        store.setWorkspaceAgentModelsProfile(workspaceID: roleLessWorkspaceID, profile: AgentModelsSettingsProfile())
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: roleLessWorkspaceID, mode: .useWorkspaceOverrides)

        try withOpenCodeRolePinFixture(store: store, availability: availability) {
            let globalPin = openCodePin(baseModelRaw: Self.openCodeGlobalModel, valueRaw: "high")
            let workspacePin = openCodePin(baseModelRaw: Self.openCodeWorkspaceModel, valueRaw: "low")

            try assertRolePinResolves(
                role: .pair, availability: availability, workspaceID: nil,
                model: Self.openCodeGlobalModel, parameters: [globalPin], "global"
            )
            try assertRolePinResolves(
                role: .pair, availability: availability, workspaceID: workspaceID,
                model: Self.openCodeWorkspaceModel, parameters: [workspacePin], "workspace override"
            )

            store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
            try assertRolePinResolves(
                role: .pair, availability: availability, workspaceID: workspaceID,
                model: Self.openCodeGlobalModel, parameters: [globalPin], "inherited global"
            )

            assertNoRolePin(workspaceID: roleLessWorkspaceID, availability: availability, "override profile without the role")
        }
    }

    /// Negative boundary of the stored-pin fallback: a pin that is missing, malformed, from an
    /// unknown or unavailable provider, or for a model the catalog lacks keeps the existing
    /// result (error for a label, all-nil for an omitted request).
    @MainActor
    func testIneligibleRecommendationlessRolePinsPreserveFallback() {
        let pair = AgentModelCatalog.TaskLabelKind.pair.rawValue
        let rows: [(name: String, overrides: [String: String], availability: AgentModelCatalog.AvailabilityContext)] = [
            ("no role override", [:], openCodeOnlyAvailability),
            ("malformed pin", [pair: "not-a-compound-id"], openCodeOnlyAvailability),
            ("unknown provider", [pair: "unknownProvider:\(Self.openCodeGlobalModel)"], openCodeOnlyAvailability),
            ("provider unavailable", [pair: openCodeSelectionID(Self.openCodeGlobalModel)], .none),
            // Codex skips model validation, so availability is the only check its pin gets.
            ("Codex unavailable", [pair: codexSelectionID], openCodeOnlyAvailability),
            ("model missing from catalog", [pair: openCodeSelectionID("rolepin/missing")], openCodeOnlyAvailability)
        ]

        for row in rows {
            let store = AgentModelsProfileRoleDefaultsStore(
                overrides: row.overrides,
                roleModelParameters: [pair: [openCodePin(baseModelRaw: Self.openCodeGlobalModel, valueRaw: "high")]]
            )
            withOpenCodeRolePinFixture(store: store, availability: row.availability) {
                assertNoRolePin(workspaceID: nil, availability: row.availability, row.name)
            }
        }
    }

    /// With a recommendation, resolution reports the effective selection, pin flags, pin state and
    /// parameters the Agent Models rows display. A pin that is not executable falls back to the
    /// recommendation, is flagged unavailable, and carries no parameters.
    @MainActor
    func testRecommendedRoleResolutionPreservesPinMetadata() throws {
        let availability = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.cursor)
        let role = AgentModelCatalog.TaskLabelKind.engineer
        let recommended = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(role, availability: availability))
        XCTAssertEqual(recommended.agent, .cursor, "fixture: Cursor must back the recommendation")
        let customModel = "grok-4.6"
        XCTAssertNotEqual(customModel, recommended.modelRaw, "fixture: the custom pin must differ from the recommendation")

        func cursorID(_ modelRaw: String) -> String {
            AgentModelSelectionID(agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: modelRaw).rawValue
        }

        let recommendedPin = cursorPin(baseModelRaw: recommended.modelRaw, kind: .thinking, configID: "effort", valueRaw: "low")
        let customPin = cursorPin(baseModelRaw: customModel, kind: .thinking, configID: "effort", valueRaw: "high")
        let bucket = [recommendedPin, customPin]

        func resolve(override: String?) throws -> MCPAgentRoleDefaultsService.RoleDefaultResolution {
            let store = AgentModelsProfileRoleDefaultsStore(
                overrides: override.map { [role.rawValue: $0] },
                roleModelParameters: [role.rawValue: bucket]
            )
            return try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
                for: role,
                availability: availability,
                settingsStore: store
            ))
        }

        struct Row {
            let name: String
            let override: String?
            let effective: AgentModelCatalog.NormalizedAgentSelection
            let stored: Bool
            let custom: Bool
            let unavailable: Bool
            let pinState: MCPAgentRoleDefaultsService.PinState
            let parameters: [ACPModelParameterSelection]
        }
        let recommendedDisplayName = try resolve(override: nil).recommendedDisplayName
        let customSelection = AgentModelCatalog.NormalizedAgentSelection(agent: .cursor, modelRaw: customModel)
        let rows = [
            Row(
                name: "absent", override: nil, effective: recommended,
                stored: false, custom: false, unavailable: false, pinState: .none, parameters: []
            ),
            Row(
                name: "equals the recommendation", override: cursorID(recommended.modelRaw), effective: recommended,
                stored: true, custom: false, unavailable: false, pinState: .pinnedToRecommended,
                parameters: [recommendedPin]
            ),
            Row(
                name: "valid and different", override: cursorID(customModel), effective: customSelection,
                stored: true, custom: true, unavailable: false,
                pinState: .custom(recommendedDisplayName: recommendedDisplayName), parameters: [customPin]
            ),
            Row(
                name: "malformed", override: "not-a-compound-id", effective: recommended,
                stored: true, custom: true, unavailable: true, pinState: .unavailable, parameters: []
            ),
            Row(
                name: "provider unavailable", override: openCodeSelectionID(Self.openCodeGlobalModel),
                effective: recommended,
                stored: true, custom: true, unavailable: true, pinState: .unavailable, parameters: []
            ),
            Row(
                name: "Codex unavailable", override: codexSelectionID, effective: recommended,
                stored: true, custom: true, unavailable: true, pinState: .unavailable, parameters: []
            )
        ]

        for row in rows {
            let resolution = try resolve(override: row.override)
            XCTAssertEqual(resolution.recommended, recommended, row.name)
            XCTAssertEqual(resolution.effective, row.effective, row.name)
            XCTAssertEqual(resolution.hasStoredOverride, row.stored, row.name)
            XCTAssertEqual(resolution.hasCustomOverride, row.custom, row.name)
            XCTAssertEqual(resolution.overrideUnavailable, row.unavailable, row.name)
            XCTAssertEqual(resolution.pinState, row.pinState, row.name)
            XCTAssertEqual(resolution.modelParameters, row.parameters, row.name)
        }
    }

    private static let openCodeGlobalModel = "rolepin/global"
    private static let openCodeWorkspaceModel = "rolepin/workspace"

    /// OpenCode available and nothing else: no role has a recommendation.
    private var openCodeOnlyAvailability: AgentModelCatalog.AvailabilityContext {
        AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.openCode)
    }

    /// A Codex pin. Codex model IDs are not validated, so the model is arbitrary.
    private var codexSelectionID: String {
        AgentModelSelectionID(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: AgentModel.gpt56SolHigh.rawValue).rawValue
    }

    private func openCodeSelectionID(_ modelRaw: String) -> String {
        AgentModelSelectionID(agentRaw: AgentProviderKind.openCode.rawValue, modelRaw: modelRaw).rawValue
    }

    private func openCodePin(baseModelRaw: String, valueRaw: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: baseModelRaw,
            kind: .thinking,
            configID: "effort",
            valueRaw: valueRaw
        )
    }

    /// A settings store that owns its defaults suite and settings file, removed at teardown. It
    /// never touches `GlobalSettingsStore.shared` or the developer's settings.
    @MainActor
    private func makeIsolatedSettingsStore() throws -> GlobalSettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMCPModelParameterSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AgentMCPModelParameterSupportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        return GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
    }

    /// Stages two discovered OpenCode models and installs `store` as the role-defaults store for
    /// `body`, then restores the previous store and clears the registry. `body` must not suspend.
    /// The registry also writes its dynamic-model file, so these tests belong in the disposable
    /// conductor test profile.
    @MainActor
    private func withOpenCodeRolePinFixture(
        store: any MCPAgentRoleDefaultsStoring,
        availability: AgentModelCatalog.AvailabilityContext,
        _ body: @MainActor () throws -> Void
    ) rethrows {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        let previousStore = AgentMCPSelectionResolver.testRoleDefaultsStore
        AgentMCPSelectionResolver.testRoleDefaultsStore = store
        defer {
            AgentMCPSelectionResolver.testRoleDefaultsStore = previousStore
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        }

        let options = [Self.openCodeGlobalModel, Self.openCodeWorkspaceModel].map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        let registered = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(options: options, currentModelRaw: Self.openCodeGlobalModel),
            for: .openCode
        )
        XCTAssertTrue(registered, "fixture: OpenCode models were not registered")
        if availability.openCodeAvailable {
            XCTAssertTrue(
                AgentModelCatalog.isValid(rawModel: Self.openCodeGlobalModel, for: .openCode, availability: availability),
                "fixture: the registered OpenCode model must be valid"
            )
        }
        for role in AgentModelCatalog.TaskLabelKind.allCases {
            XCTAssertNil(
                AgentModelCatalog.resolveTaskLabelKind(role, availability: availability),
                "fixture: \(role.rawValue) must have no recommendation"
            )
        }
        try body()
    }

    /// Resolves `role` as an explicit label and as an omitted `model_id` with that default role.
    /// Both must return the same pin.
    @MainActor
    private func assertRolePinResolves(
        role: AgentModelCatalog.TaskLabelKind,
        availability: AgentModelCatalog.AvailabilityContext,
        workspaceID: UUID? = nil,
        model: String,
        parameters: [ACPModelParameterSelection],
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let explicit = try AgentMCPSelectionResolver.resolve(
            modelID: role.rawValue,
            availability: availability,
            workspaceID: workspaceID
        )
        assertResolved(
            explicit, model: model, role: role, parameters: parameters,
            "explicit, \(context)", file: file, line: line
        )
        let omitted = try AgentMCPSelectionResolver.resolve(
            modelID: nil,
            defaultTaskLabel: role,
            availability: availability,
            workspaceID: workspaceID
        )
        assertResolved(
            omitted, model: model, role: role, parameters: parameters,
            "omitted, \(context)", file: file, line: line
        )
    }

    private func assertResolved(
        _ resolved: AgentMCPSelectionResolver.ResolvedSelection,
        model: String,
        role: AgentModelCatalog.TaskLabelKind,
        parameters: [ACPModelParameterSelection],
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.openCode.rawValue, context, file: file, line: line)
        XCTAssertEqual(resolved.modelRaw, model, context, file: file, line: line)
        XCTAssertEqual(resolved.taskLabelKind, role, context, file: file, line: line)
        XCTAssertEqual(resolved.modelParameterSelections, parameters, context, file: file, line: line)
    }

    /// With no usable pin, an explicit `pair` throws the existing error and an omitted request
    /// resolves to nothing, so the caller runs with the agent default.
    @MainActor
    private func assertNoRolePin(
        workspaceID: UUID?,
        availability: AgentModelCatalog.AvailabilityContext,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AgentMCPSelectionResolver.resolve(modelID: "pair", availability: availability, workspaceID: workspaceID),
            context,
            file: file,
            line: line
        ) { error in
            guard let mcpError = error as? MCPError, case let .invalidParams(message) = mcpError else {
                XCTFail("Expected MCPError.invalidParams, got \(error). \(context)", file: file, line: line)
                return
            }
            XCTAssertEqual(message, "No available agent/model for task label 'pair'.", context, file: file, line: line)
        }
        do {
            let omitted = try AgentMCPSelectionResolver.resolve(
                modelID: nil,
                defaultTaskLabel: .pair,
                availability: availability,
                workspaceID: workspaceID
            )
            XCTAssertNil(omitted.agentRaw, context, file: file, line: line)
            XCTAssertNil(omitted.modelRaw, context, file: file, line: line)
            XCTAssertNil(omitted.taskLabelKind, context, file: file, line: line)
            XCTAssertTrue(omitted.modelParameterSelections.isEmpty, context, file: file, line: line)
        } catch {
            XCTFail("Omitted request must not throw: \(error). \(context)", file: file, line: line)
        }
    }

    private func cursorPin(
        baseModelRaw: String = "grok-4.6",
        kind: ACPModelParameterKind,
        configID: String,
        valueRaw: String
    ) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: baseModelRaw,
            kind: kind,
            configID: configID,
            valueRaw: valueRaw
        )
    }
}
