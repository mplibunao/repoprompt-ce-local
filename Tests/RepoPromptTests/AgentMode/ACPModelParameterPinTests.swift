@testable import RepoPromptApp
import XCTest

/// Pure coverage for the shared pin projection and the single-identity profile edits that every
/// Settings pin surface writes through.
final class ACPModelParameterPinTests: XCTestCase {
    private static let grokModelRaw = "grok-4.6"
    private static let openCodeModelRaw = "ollama-cloud/kimi-k3"

    // MARK: - Projection

    func testCursorModelProjectsThinkingAndSpeedControlsTogether() throws {
        let controls = cursorControls(modelRaw: Self.grokModelRaw, saved: [])

        XCTAssertEqual(controls.map(\.kind), [.thinking, .speed])
        let effort = try XCTUnwrap(controls.first?.definition)
        XCTAssertEqual(effort.configID, "effort")
        XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        let speed = try XCTUnwrap(controls.last?.definition)
        XCTAssertEqual(speed.configID, "fast")
        XCTAssertEqual(speed.choices.map(\.rawValue), ["false", "true"])
        XCTAssertTrue(controls.allSatisfy { $0.saved == nil }, "Advertised current values are not pins.")
    }

    func testSavedPinUnderAliasMatchesCanonicalModel() {
        let aliasPin = cursorSelection(modelRaw: "cursor-grok-4.6", kind: .speed, configID: "fast", valueRaw: "false")

        let controls = cursorControls(modelRaw: Self.grokModelRaw, saved: [aliasPin])

        XCTAssertEqual(controls.first { $0.kind == .speed }?.saved, aliasPin)
        XCTAssertNil(controls.first { $0.kind == .thinking }?.saved)
    }

    func testSavedPinForRemovedCursorModelStaysAsSavedOnlyControl() {
        let modelRaw = "grok-removed-9"
        let pin = cursorSelection(modelRaw: modelRaw, kind: .thinking, configID: "effort", valueRaw: "high")

        let controls = cursorControls(modelRaw: modelRaw, saved: [pin])

        XCTAssertEqual(controls.count, 1)
        XCTAssertNil(controls[0].definition, "No metadata exists, so no choices may be invented.")
        XCTAssertEqual(controls[0].saved, pin)
        XCTAssertEqual(controls[0].baseModelRaw, modelRaw)
    }

    func testOpenCodeSavedPinWithoutMetadataStaysAsSavedOnlyControl() {
        let pin = openCodeSelection(valueRaw: "max")

        let controls = ACPModelParameterResolver.pinControls(
            providerID: .openCode,
            selectedModelRaw: Self.openCodeModelRaw,
            parameterSet: nil,
            persistedSelections: [pin]
        )

        XCTAssertEqual(controls.map(\.kind), [.thinking])
        XCTAssertNil(controls[0].definition)
        XCTAssertEqual(controls[0].saved, pin)
    }

    func testRepeatedDefinitionsForOneKindAreWithheld() {
        let first = ACPModelParameterTestSupport.definition(kind: .thinking, configID: "effort", values: ["low", "high"])
        let second = ACPModelParameterTestSupport.definition(kind: .thinking, configID: "reasoning", values: ["min", "max"])
        let speed = ACPModelParameterTestSupport.definition(kind: .speed, configID: "fast", values: ["false", "true"])
        let parameterSet = ACPModelParameterSet(
            baseModelRaw: Self.openCodeModelRaw,
            parameters: [first, second, speed]
        )

        let unsaved = ACPModelParameterResolver.pinControls(
            providerID: .openCode,
            selectedModelRaw: Self.openCodeModelRaw,
            parameterSet: parameterSet,
            persistedSelections: []
        )
        XCTAssertEqual(unsaved.map(\.kind), [.speed], "An ambiguous kind with no saved pin has nothing honest to show.")

        let pin = openCodeSelection(valueRaw: "high")
        let saved = ACPModelParameterResolver.pinControls(
            providerID: .openCode,
            selectedModelRaw: Self.openCodeModelRaw,
            parameterSet: parameterSet,
            persistedSelections: [pin]
        )
        XCTAssertEqual(saved.map(\.kind), [.thinking, .speed])
        XCTAssertNil(saved[0].definition, "The first of two selectors must not be picked.")
        XCTAssertEqual(saved[0].saved, pin)
    }

    /// A saved value warns as unavailable once the provider's parameter set resolved and cannot
    /// apply it; missing metadata keeps it plain.
    func testSavedPinWarnsOnlyWhenResolvedMetadataCannotApplyIt() throws {
        let effortPin = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "high")
        let composerPin = cursorSelection(modelRaw: "composer-2.5", kind: .thinking, configID: "effort", valueRaw: "high")
        let unadvertised = try XCTUnwrap(cursorControls(modelRaw: "composer-2.5", saved: [composerPin]).first { $0.kind == .thinking })
        XCTAssertNil(unadvertised.definition)
        XCTAssertTrue(unadvertised.hasParameterSet)
        XCTAssertTrue(unadvertised.isSavedValueUnavailable, "composer-2.5 offers no effort.")

        let unknownModelPin = cursorSelection(modelRaw: "grok-removed-9", kind: .thinking, configID: "effort", valueRaw: "high")
        let noMetadata = try XCTUnwrap(cursorControls(modelRaw: "grok-removed-9", saved: [unknownModelPin]).first)
        XCTAssertFalse(noMetadata.hasParameterSet)
        XCTAssertFalse(noMetadata.isSavedValueUnavailable, "Unknown metadata is not a warning.")

        let first = ACPModelParameterTestSupport.definition(kind: .thinking, configID: "effort", values: ["low", "high"])
        let second = ACPModelParameterTestSupport.definition(kind: .thinking, configID: "reasoning", values: ["low", "high"])
        let ambiguous = try XCTUnwrap(ACPModelParameterResolver.pinControls(
            providerID: .openCode,
            selectedModelRaw: Self.openCodeModelRaw,
            parameterSet: ACPModelParameterSet(baseModelRaw: Self.openCodeModelRaw, parameters: [first, second]),
            persistedSelections: [openCodeSelection(valueRaw: "high")]
        ).first)
        XCTAssertTrue(ambiguous.isSavedValueUnavailable)

        let advertised = try XCTUnwrap(cursorControls(modelRaw: Self.grokModelRaw, saved: [effortPin]).first)
        XCTAssertFalse(advertised.isSavedValueUnavailable)
        let retired = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "ultra")
        let retiredControl = try XCTUnwrap(cursorControls(modelRaw: Self.grokModelRaw, saved: [retired]).first)
        XCTAssertTrue(retiredControl.isSavedValueUnavailable)
    }

    func testChoosingAnAdvertisedValueKeepsExactWireStrings() throws {
        let control = try XCTUnwrap(cursorControls(modelRaw: "cursor-grok-4.6", saved: []).last)
        let definition = try XCTUnwrap(control.definition)
        let fast = try XCTUnwrap(definition.choices.first { $0.rawValue == "true" })

        let change = ACPModelParameterPinChange.pinning(
            fast,
            of: definition,
            providerID: control.providerID,
            baseModelRaw: control.baseModelRaw
        )

        guard case let .set(selection) = change else { return XCTFail("Choosing a value must set a pin.") }
        XCTAssertEqual(selection.kind, .speed)
        XCTAssertEqual(selection.configID, "fast")
        XCTAssertEqual(selection.valueRaw, "true", "The wire value, never the display name \"Fast\".")
        XCTAssertEqual(selection.baseModelRaw, Self.grokModelRaw)
        XCTAssertTrue(change.targets(providerID: .cursor, modelRaw: "cursor-grok-4.6"))
    }

    func testProviderWireValueNamedDefaultIsAnExplicitPin() {
        let definition = ACPModelParameterTestSupport.definition(kind: .thinking, configID: "effort", values: ["default", "high"])
        let change = ACPModelParameterPinChange.pinning(
            definition.choices[0],
            of: definition,
            providerID: .openCode,
            baseModelRaw: Self.openCodeModelRaw
        )
        let profile = AgentModelsSettingsProfile().applyingRoleModelParameterChange(
            change,
            for: "engineer",
            displayedSelectionID: openCodeSelectionID
        )

        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"]?.map(\.valueRaw), ["default"])
    }

    // MARK: - Profile edits

    func testSettingOneKindKeepsTheOtherKind() {
        let effort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "xhigh")
        let speed = cursorSelection(kind: .speed, configID: "fast", valueRaw: "false")

        let profile = AgentModelsSettingsProfile()
            .applyingRoleModelParameterChange(.set(effort), for: "engineer", displayedSelectionID: cursorSelectionID)
            .applyingRoleModelParameterChange(.set(speed), for: "engineer", displayedSelectionID: cursorSelectionID)

        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"], [effort, speed])
        XCTAssertEqual(profile.mcpAgentRoleOverrides?["engineer"], cursorSelectionID.rawValue)
    }

    func testReplacingOneKindKeepsItsPositionAndSibling() {
        let effort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "low")
        let speed = cursorSelection(kind: .speed, configID: "fast", valueRaw: "false")
        let newerEffort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "high")
        let start = rolePinned([effort, speed])

        let profile = start.applyingRoleModelParameterChange(
            .set(newerEffort),
            for: "engineer",
            displayedSelectionID: cursorSelectionID
        )

        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"], [newerEffort, speed])
    }

    func testClearingOneKindKeepsTheOtherAndTheOverride() {
        let effort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "high")
        let speed = cursorSelection(kind: .speed, configID: "fast", valueRaw: "true")
        let start = rolePinned([effort, speed])

        let roleCleared = start.applyingRoleModelParameterChange(
            .clear(effort.identity),
            for: "engineer",
            displayedSelectionID: cursorSelectionID
        )
        XCTAssertEqual(roleCleared.mcpAgentRoleModelParameters?["engineer"], [speed])
        XCTAssertEqual(roleCleared.mcpAgentRoleOverrides?["engineer"], cursorSelectionID.rawValue)

        let lastCleared = roleCleared.applyingRoleModelParameterChange(
            .clear(speed.identity),
            for: "engineer",
            displayedSelectionID: cursorSelectionID
        )
        XCTAssertNil(lastCleared.mcpAgentRoleModelParameters)
        XCTAssertEqual(
            lastCleared.mcpAgentRoleOverrides?["engineer"],
            cursorSelectionID.rawValue,
            "Clearing the last pin leaves the model override in place."
        )

        let cbStart = contextBuilderPinned([effort, speed])
        let cbCleared = cbStart.applyingContextBuilderModelParameterChange(
            .clear(speed.identity),
            for: "cursor",
            modelRaw: Self.grokModelRaw
        )
        XCTAssertEqual(cbCleared.contextBuilderModelParametersByAgent?["cursor"], [effort])
        XCTAssertEqual(cbCleared.contextBuilderModelsByAgent?["cursor"], Self.grokModelRaw)
    }

    func testSetIgnoresPinsLeftForAPreviousModel() {
        let oldModelPin = cursorSelection(modelRaw: "grok-4.5", kind: .speed, configID: "fast", valueRaw: "false")
        var start = rolePinned([])
        start.mcpAgentRoleModelParameters = ["engineer": [oldModelPin]]
        let effort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "low")

        let profile = start.applyingRoleModelParameterChange(
            .set(effort),
            for: "engineer",
            displayedSelectionID: cursorSelectionID
        )

        XCTAssertEqual(profile.mcpAgentRoleModelParameters?["engineer"], [effort])
    }

    func testNoOpAndInvalidEditsReturnTheProfileUnchanged() {
        let effort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "high")
        let start = rolePinned([effort])
        let speedIdentity = cursorSelection(kind: .speed, configID: "fast", valueRaw: "true").identity
        let blankValue = cursorSelection(kind: .speed, configID: "fast", valueRaw: " ")
        let blankSelector = cursorSelection(kind: .speed, configID: "", valueRaw: "true")
        let otherModel = cursorSelection(modelRaw: "grok-4.5", kind: .speed, configID: "fast", valueRaw: "true")
        let changes: [ACPModelParameterPinChange] = [
            .set(effort),
            .clear(speedIdentity),
            .set(blankValue),
            .set(blankSelector),
            .set(otherModel)
        ]

        for change in changes {
            XCTAssertEqual(
                start.applyingRoleModelParameterChange(change, for: "engineer", displayedSelectionID: cursorSelectionID),
                start,
                "\(change) must not change the role profile."
            )
        }
        let cbStart = contextBuilderPinned([effort])
        for change in changes {
            XCTAssertEqual(
                cbStart.applyingContextBuilderModelParameterChange(change, for: "cursor", modelRaw: Self.grokModelRaw),
                cbStart,
                "\(change) must not change the Context Builder profile."
            )
        }
        XCTAssertFalse(ACPModelParameterPinChange.set(blankValue).isApplicable)
    }

    func testClearingOnAFallbackKeepsTheUnavailableModelsPins() {
        // The stored override is grok-4.5; the surface displays grok-4.6 as a fallback.
        let storedPin = cursorSelection(modelRaw: "grok-4.5", kind: .thinking, configID: "effort", valueRaw: "high")
        let start = AgentModelsSettingsProfile(
            mcpAgentRoleOverrides: ["engineer": "cursor:grok-4.5"],
            mcpAgentRoleModelParameters: ["engineer": [storedPin]]
        )
        let displayedIdentity = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "high").identity

        let cleared = start.applyingRoleModelParameterChange(
            .clear(displayedIdentity),
            for: "engineer",
            displayedSelectionID: cursorSelectionID
        )
        XCTAssertEqual(cleared, start)

        // Setting while the fallback is displayed adopts the fallback, as pinning always has.
        let fallbackPin = cursorSelection(kind: .speed, configID: "fast", valueRaw: "false")
        let set = start.applyingRoleModelParameterChange(
            .set(fallbackPin),
            for: "engineer",
            displayedSelectionID: cursorSelectionID
        )
        XCTAssertEqual(set.mcpAgentRoleOverrides?["engineer"], cursorSelectionID.rawValue)
        XCTAssertEqual(set.mcpAgentRoleModelParameters?["engineer"], [fallbackPin])
    }

    /// The persisted Context Builder agent (OpenCode) is unavailable, so the surface displays the
    /// Cursor fallback with Effort: Default even though Cursor's per-agent bucket still holds
    /// effort=low. Pinning speed commits only what the user saw plus the new speed.
    func testContextBuilderSetDoesNotReviveHiddenBucketPins() {
        let hiddenEffort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "low")
        let start = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: "openCode",
            contextBuilderModelsByAgent: ["openCode": Self.openCodeModelRaw, "cursor": Self.grokModelRaw],
            contextBuilderModelParametersByAgent: ["cursor": [hiddenEffort]]
        )
        XCTAssertEqual(start.contextBuilderModelParametersByAgent?["cursor"], [hiddenEffort])
        XCTAssertTrue(start.contextBuilderModelParameterSelections(for: .cursor, modelRaw: Self.grokModelRaw).isEmpty)
        let speed = cursorSelection(kind: .speed, configID: "fast", valueRaw: "true")

        let next = start.applyingContextBuilderModelParameterChange(.set(speed), for: "cursor", modelRaw: Self.grokModelRaw)

        XCTAssertEqual(next.contextBuilderAgentRaw, "cursor")
        XCTAssertEqual(next.contextBuilderModelParametersByAgent?["cursor"], [speed])
        XCTAssertEqual(next.contextBuilderModelParameterSelections(for: .cursor, modelRaw: Self.grokModelRaw), [speed])
    }

    func testContextBuilderClearRequiresThePersistedAgent() {
        let effort = cursorSelection(kind: .thinking, configID: "effort", valueRaw: "high")
        var start = contextBuilderPinned([effort])
        start.contextBuilderAgentRaw = "openCode"

        let cleared = start.applyingContextBuilderModelParameterChange(
            .clear(effort.identity),
            for: "cursor",
            modelRaw: Self.grokModelRaw
        )

        XCTAssertEqual(cleared, start, "Another agent's bucket is per-agent memory, not the displayed pin.")
    }

    func testOldSingleKindProfileDecodesAndGainsASibling() throws {
        let json = """
        {
          "syncChatModelWithOracle": false,
          "restrictMCPAgentDiscoveryToRoleLabels": false,
          "mcpAgentRoleOverrides": { "engineer": "openCode:\(Self.openCodeModelRaw)" },
          "mcpAgentRoleModelParameters": {
            "engineer": [
              {
                "providerID": "openCode",
                "baseModelRaw": "\(Self.openCodeModelRaw)",
                "kind": "thinking",
                "configID": "effort",
                "valueRaw": "high"
              }
            ]
          }
        }
        """
        let decoded = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.mcpAgentRoleModelParameters?["engineer"], [openCodeSelection(valueRaw: "high")])

        let speed = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: Self.openCodeModelRaw,
            kind: .speed,
            configID: "fast",
            valueRaw: "true"
        )
        let next = decoded.applyingRoleModelParameterChange(
            .set(speed),
            for: "engineer",
            displayedSelectionID: openCodeSelectionID
        )
        XCTAssertEqual(next.mcpAgentRoleModelParameters?["engineer"], [openCodeSelection(valueRaw: "high"), speed])
    }

    // MARK: - Fixtures

    private var cursorSelectionID: AgentModelSelectionID {
        AgentModelSelectionID(agentRaw: "cursor", modelRaw: Self.grokModelRaw)
    }

    private var openCodeSelectionID: AgentModelSelectionID {
        AgentModelSelectionID(agentRaw: "openCode", modelRaw: Self.openCodeModelRaw)
    }

    private func cursorControls(
        modelRaw: String,
        saved: [ACPModelParameterSelection]
    ) -> [ACPModelParameterPinControl] {
        ACPModelParameterResolver.pinControls(
            providerID: .cursor,
            selectedModelRaw: modelRaw,
            parameterSet: ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: modelRaw),
            persistedSelections: saved
        )
    }

    private func rolePinned(_ selections: [ACPModelParameterSelection]) -> AgentModelsSettingsProfile {
        AgentModelsSettingsProfile(
            mcpAgentRoleOverrides: ["engineer": cursorSelectionID.rawValue],
            mcpAgentRoleModelParameters: selections.isEmpty ? nil : ["engineer": selections]
        )
    }

    private func contextBuilderPinned(_ selections: [ACPModelParameterSelection]) -> AgentModelsSettingsProfile {
        AgentModelsSettingsProfile(
            contextBuilderAgentRaw: "cursor",
            contextBuilderModelsByAgent: ["cursor": Self.grokModelRaw],
            contextBuilderModelParametersByAgent: ["cursor": selections]
        )
    }

    private func cursorSelection(
        modelRaw: String = ACPModelParameterPinTests.grokModelRaw,
        kind: ACPModelParameterKind,
        configID: String,
        valueRaw: String
    ) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: modelRaw,
            kind: kind,
            configID: configID,
            valueRaw: valueRaw
        )
    }

    private func openCodeSelection(valueRaw: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: Self.openCodeModelRaw,
            kind: .thinking,
            configID: "effort",
            valueRaw: valueRaw
        )
    }
}
