import Foundation

/// Versioned JSON document stored at
/// `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`.
///
/// Schema v1 contains copy settings, chat settings, and cross-workspace global
/// defaults. Schema v2 adds optional scalar preference groups. Schema v4 adds
/// workspace-scoped Agent Models profiles. Schema v8 adds OpenCode-style ACP
/// parameter pins to Agent Models profiles. Scalar fields stay optional so missing
/// JSON fields fall back through the typed GlobalSettingsStore accessors without
/// losing current default behavior.
struct GlobalSettingsDocument: Codable {
    /// Fixed feature-version constants are permanent compatibility boundaries. Add a new
    /// constant for each schema-requiring feature; never infer an existing feature's minimum
    /// version from `currentSchemaVersion`.
    static let baselineSchemaVersion = 2
    static let workspaceAgentModelsSchemaVersion = 4
    /// OpenCode-style ACP parameter pins stored on Agent Models profiles.
    static let agentModelParameterPinsSchemaVersion = 8
    /// Experimental schema versions this family never accepts, even with a valid lineage
    /// marker. v6 was written only by experimental builds and must be rejected, not imported.
    static let rejectedExperimentalSchemaVersions = 6 ... 6
    static let currentSchemaVersion = 8
    /// Lineage marker for settings files written by this open-source CE schema family.
    ///
    /// CE inherited numeric schema versions from classic/internal builds, so version numbers
    /// alone are not globally meaningful. Unlineaged v1/v2 files are accepted as legacy CE
    /// documents; unlineaged higher versions are treated as foreign/future documents even if
    /// this fork later reaches the same numeric schema version.
    static let schemaLineage = "repoprompt-ce.global-settings"
    /// FROZEN at 2 forever: this is the last schema version OSS CE wrote without
    /// a lineage marker. It must never track `currentSchemaVersion`.
    static let legacyUnlineagedSchemaVersionCeiling = 2

    var schemaVersion: Int
    var schemaLineage: String?
    var updatedAt: Date
    var copySettingsByWorkspaceID: [String: CopyGlobalSettings]
    var chatSettingsByWorkspaceID: [String: ChatGlobalSettings]
    var agentModelsSettingsByWorkspaceID: [String: WorkspaceAgentModelsSettings]?
    var globalDefaults: GlobalDefaults
    var scalarPreferences: GlobalScalarPreferences?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        copySettings: [UUID: CopyGlobalSettings] = [:],
        chatSettings: [UUID: ChatGlobalSettings] = [:],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] = [:],
        globalDefaults: GlobalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
        scalarPreferences: GlobalScalarPreferences? = nil
    ) {
        self.schemaVersion = schemaVersion
        schemaLineage = Self.schemaLineage
        self.updatedAt = updatedAt
        copySettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(copySettings)
        chatSettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(chatSettings)
        agentModelsSettingsByWorkspaceID = agentModelsSettings.isEmpty
            ? nil
            : Self.encodeUUIDKeyedDictionary(agentModelsSettings)
        self.globalDefaults = globalDefaults
        self.scalarPreferences = scalarPreferences
    }

    var copySettings: [UUID: CopyGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(copySettingsByWorkspaceID)
    }

    var chatSettings: [UUID: ChatGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(chatSettingsByWorkspaceID)
    }

    var agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] {
        Self.decodeUUIDKeyedDictionary(agentModelsSettingsByWorkspaceID ?? [:])
    }

    /// Lowest CE schema version that can faithfully represent this document's content.
    ///
    /// Each feature contributes its own fixed introduction version. Future schema bumps must
    /// add another feature constant and participate in this maximum; they must not change the
    /// minimum version of content that existing features already know how to represent.
    var requiredSchemaVersion: Int {
        var requiredVersion = Self.baselineSchemaVersion
        if let agentModelsSettingsByWorkspaceID, !agentModelsSettingsByWorkspaceID.isEmpty {
            requiredVersion = max(requiredVersion, Self.workspaceAgentModelsSchemaVersion)
        }
        let hasGlobalParameterPins = globalDefaults.mcpAgentRoleModelParameters?.isEmpty == false
            || globalDefaults.contextBuilderModelParametersByAgent?.isEmpty == false
        let hasWorkspaceParameterPins = agentModelsSettings.values.contains { settings in
            settings.profile?.mcpAgentRoleModelParameters?.isEmpty == false
                || settings.profile?.contextBuilderModelParametersByAgent?.isEmpty == false
        }
        if hasGlobalParameterPins || hasWorkspaceParameterPins {
            requiredVersion = max(requiredVersion, Self.agentModelParameterPinsSchemaVersion)
        }
        return requiredVersion
    }

    func replacing(
        copySettings: [UUID: CopyGlobalSettings],
        chatSettings: [UUID: ChatGlobalSettings],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings],
        globalDefaults: GlobalDefaults,
        scalarPreferences: GlobalScalarPreferences? = nil,
        updatedAt: Date = Date()
    ) -> GlobalSettingsDocument {
        GlobalSettingsDocument(
            schemaVersion: Self.currentSchemaVersion,
            updatedAt: updatedAt,
            copySettings: copySettings,
            chatSettings: chatSettings,
            agentModelsSettings: agentModelsSettings,
            globalDefaults: globalDefaults,
            scalarPreferences: scalarPreferences ?? self.scalarPreferences
        )
    }

    private static func encodeUUIDKeyedDictionary<Value>(_ values: [UUID: Value]) -> [String: Value] {
        values.reduce(into: [String: Value]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
    }

    private static func decodeUUIDKeyedDictionary<Value>(_ values: [String: Value]) -> [UUID: Value] {
        var winners: [UUID: (rawKey: String, value: Value)] = [:]
        for rawKey in values.keys.sorted() {
            guard let uuid = UUID(uuidString: rawKey), let value = values[rawKey] else { continue }
            let canonicalKey = uuid.uuidString
            if winners[uuid] == nil || rawKey == canonicalKey {
                winners[uuid] = (rawKey, value)
            }
        }
        return winners.mapValues(\.value)
    }
}

// MARK: - Scoped Agent Models Settings

enum AgentModelsInheritanceMode: String, Codable, Equatable {
    case useGlobalSettings
    case useWorkspaceOverrides
}

enum AgentModelsEditingScope: Hashable {
    case global
    case workspace(UUID)

    static func resolve(
        workspaceID: UUID?,
        inheritanceMode: AgentModelsInheritanceMode
    ) -> AgentModelsEditingScope {
        guard let workspaceID, inheritanceMode == .useWorkspaceOverrides else { return .global }
        return .workspace(workspaceID)
    }
}

/// Stable identity for one Agent Models operation. The source workspace drives
/// workspace-local wizard bookkeeping while `scope` is the exact durable profile
/// the operation may read or mutate.
struct AgentModelsOperationIdentity: Hashable {
    let sourceWorkspaceID: UUID
    let scope: AgentModelsEditingScope

    init(sourceWorkspaceID: UUID, scope: AgentModelsEditingScope) {
        self.sourceWorkspaceID = sourceWorkspaceID
        self.scope = scope
    }

    init(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) {
        self.sourceWorkspaceID = sourceWorkspaceID
        scope = AgentModelsEditingScope.resolve(
            workspaceID: sourceWorkspaceID,
            inheritanceMode: inheritanceMode
        )
    }

    func matches(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) -> Bool {
        self == AgentModelsOperationIdentity(
            sourceWorkspaceID: sourceWorkspaceID,
            inheritanceMode: inheritanceMode
        )
    }
}

enum ContextBuilderSettingsWriteIntent {
    case preserveExistingOwnership
    case userInitiated
    case automaticSeed
}

struct AgentModelsSettingsProfile: Codable, Equatable {
    var planningModelRaw: String?
    var preferredComposeModelRaw: String?
    var syncChatModelWithOracle: Bool
    var contextBuilderAgentRaw: String?
    var contextBuilderModelsByAgent: [String: String]?
    var mcpAgentRoleOverrides: [String: String]?
    var restrictMCPAgentDiscoveryToRoleLabels: Bool
    /// OpenCode-style ACP parameter pins per Sub-Agent role. Keys are `TaskLabelKind`
    /// rawValues; values are model-scoped selections, so a pin only survives while its role's
    /// stored override still resolves to the same provider and canonical model.
    var mcpAgentRoleModelParameters: [String: [ACPModelParameterSelection]]?
    /// OpenCode-style ACP parameter pins per Context Builder agent. Keys are
    /// `AgentProviderKind` rawValues, mirroring `contextBuilderModelsByAgent`.
    var contextBuilderModelParametersByAgent: [String: [ACPModelParameterSelection]]?

    init(
        planningModelRaw: String? = nil,
        preferredComposeModelRaw: String? = nil,
        syncChatModelWithOracle: Bool = false,
        contextBuilderAgentRaw: String? = nil,
        contextBuilderModelsByAgent: [String: String]? = nil,
        mcpAgentRoleOverrides: [String: String]? = nil,
        restrictMCPAgentDiscoveryToRoleLabels: Bool = false,
        mcpAgentRoleModelParameters: [String: [ACPModelParameterSelection]]? = nil,
        contextBuilderModelParametersByAgent: [String: [ACPModelParameterSelection]]? = nil
    ) {
        self.planningModelRaw = Self.normalizedChatModelRaw(planningModelRaw)
        self.preferredComposeModelRaw = Self.normalizedChatModelRaw(preferredComposeModelRaw)
        self.syncChatModelWithOracle = syncChatModelWithOracle
        self.contextBuilderAgentRaw = Self.normalizedAgentRaw(contextBuilderAgentRaw)
        let normalizedModelsByAgent = Self.normalizedContextBuilderModelsByAgent(contextBuilderModelsByAgent)
        self.contextBuilderModelsByAgent = normalizedModelsByAgent
        let normalizedRoleOverrides = Self.normalizedStringMap(mcpAgentRoleOverrides)
        self.mcpAgentRoleOverrides = normalizedRoleOverrides
        self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
        self.mcpAgentRoleModelParameters = Self.coherentRoleModelParameters(
            mcpAgentRoleModelParameters,
            roleOverrides: normalizedRoleOverrides
        )
        self.contextBuilderModelParametersByAgent = Self.coherentContextBuilderModelParameters(
            contextBuilderModelParametersByAgent,
            modelsByAgent: normalizedModelsByAgent
        )
    }

    private enum CodingKeys: String, CodingKey {
        case planningModelRaw
        case preferredComposeModelRaw
        case syncChatModelWithOracle
        case contextBuilderAgentRaw
        case contextBuilderModelsByAgent
        case mcpAgentRoleOverrides
        case restrictMCPAgentDiscoveryToRoleLabels
        case mcpAgentRoleModelParameters
        case contextBuilderModelParametersByAgent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let roleOverrides = try Self.normalizedStringMap(
            container.decodeIfPresent([String: String].self, forKey: .mcpAgentRoleOverrides)
        )
        mcpAgentRoleOverrides = roleOverrides
        planningModelRaw = try Self.normalizedChatModelRaw(
            container.decodeIfPresent(String.self, forKey: .planningModelRaw)
        )
        preferredComposeModelRaw = try Self.normalizedChatModelRaw(
            container.decodeIfPresent(String.self, forKey: .preferredComposeModelRaw)
        )
        syncChatModelWithOracle = try container.decodeIfPresent(Bool.self, forKey: .syncChatModelWithOracle) ?? false
        contextBuilderAgentRaw = try Self.normalizedAgentRaw(
            container.decodeIfPresent(String.self, forKey: .contextBuilderAgentRaw)
        )
        contextBuilderModelsByAgent = try Self.normalizedContextBuilderModelsByAgent(
            container.decodeIfPresent([String: String].self, forKey: .contextBuilderModelsByAgent)
        )
        restrictMCPAgentDiscoveryToRoleLabels = try container.decodeIfPresent(
            Bool.self,
            forKey: .restrictMCPAgentDiscoveryToRoleLabels
        ) ?? false
        mcpAgentRoleModelParameters = try Self.coherentRoleModelParameters(
            container.decodeIfPresent(
                [String: [ACPModelParameterSelection]].self,
                forKey: .mcpAgentRoleModelParameters
            ),
            roleOverrides: roleOverrides
        )
        contextBuilderModelParametersByAgent = try Self.coherentContextBuilderModelParameters(
            container.decodeIfPresent(
                [String: [ACPModelParameterSelection]].self,
                forKey: .contextBuilderModelParametersByAgent
            ),
            modelsByAgent: contextBuilderModelsByAgent
        )
    }

    func replacingContextBuilderModel(_ modelRaw: String?, for agentRaw: String?) -> AgentModelsSettingsProfile {
        let resolvedAgentRaw = Self.normalizedAgentRaw(agentRaw) ?? contextBuilderAgentRaw
        guard let resolvedAgentRaw else { return self }

        var next = self
        var modelsByAgent = contextBuilderModelsByAgent ?? [:]
        if let normalizedModelRaw = Self.trimmedNonEmpty(modelRaw) {
            modelsByAgent[resolvedAgentRaw] = normalizedModelRaw
        } else {
            modelsByAgent[resolvedAgentRaw] = nil
        }
        next.contextBuilderModelsByAgent = modelsByAgent.isEmpty ? nil : modelsByAgent
        return next
    }

    /// Single owner of the role-pin↔role-model relationship. A stored pin survives only while
    /// its role still has a stored override resolving to the same provider and canonical model.
    /// This runs on every construction and decode, so every writer — the Settings view model,
    /// the static role service, recommendations, resets and MCP — gets cleanup for free without
    /// any of them enforcing it. Persisted identities only: transient availability never erases
    /// explicit intent.
    private static func coherentRoleModelParameters(
        _ buckets: [String: [ACPModelParameterSelection]]?,
        roleOverrides: [String: String]?
    ) -> [String: [ACPModelParameterSelection]]? {
        guard let buckets else { return nil }
        var coherent: [String: [ACPModelParameterSelection]] = [:]
        for rawKey in buckets.keys.sorted() {
            guard let key = trimmedNonEmpty(rawKey),
                  let selectionID = roleOverrides?[key].flatMap(AgentModelSelectionID.parse),
                  let providerID = AgentProviderKind(rawValue: selectionID.agentRaw)?.acpProviderID,
                  let selections = buckets[rawKey]
            else { continue }
            let matching = ACPModelParameterSelection.selections(
                for: providerID,
                activeBaseModelRaw: selectionID.modelRaw,
                from: selections
            )
            guard !matching.isEmpty else { continue }
            coherent[key] = matching
        }
        return coherent.isEmpty ? nil : coherent
    }

    /// Single owner of the Context Builder pin↔model relationship. Mirrors
    /// `coherentRoleModelParameters` for the agent-keyed Context Builder bucket.
    private static func coherentContextBuilderModelParameters(
        _ buckets: [String: [ACPModelParameterSelection]]?,
        modelsByAgent: [String: String]?
    ) -> [String: [ACPModelParameterSelection]]? {
        guard let buckets else { return nil }
        var coherent: [String: [ACPModelParameterSelection]] = [:]
        for rawKey in buckets.keys.sorted() {
            guard let key = trimmedNonEmpty(rawKey),
                  let providerID = AgentProviderKind(rawValue: key)?.acpProviderID,
                  let modelRaw = modelsByAgent?[key],
                  let selections = buckets[rawKey]
            else { continue }
            let matching = ACPModelParameterSelection.selections(
                for: providerID,
                activeBaseModelRaw: modelRaw,
                from: selections
            )
            guard !matching.isEmpty else { continue }
            coherent[key] = matching
        }
        return coherent.isEmpty ? nil : coherent
    }

    /// The Context Builder pin for a resolved agent + model, requiring the persisted explicit
    /// CB agent to match. The single eligibility rule for the CB bucket, shared by the display
    /// getters, the setter, and the run-side filter — so all four agree by construction.
    func contextBuilderModelParameterSelections(
        for agent: AgentProviderKind,
        modelRaw: String
    ) -> [ACPModelParameterSelection] {
        guard let providerID = agent.acpProviderID,
              contextBuilderAgentRaw == agent.rawValue,
              let bucket = contextBuilderModelParametersByAgent?[agent.rawValue]
        else { return [] }
        return ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: modelRaw,
            from: bucket
        )
    }

    /// Apply one pin edit to a role's bucket, leaving every other identity in it untouched.
    ///
    /// Set keeps sibling kinds for the displayed model, drops pins left over for any other
    /// model, and commits the displayed selection as the role override in the same mutation: a
    /// pin written against a merely recommended model would be dropped as ineligible the moment
    /// it is saved. A displayed availability fallback is therefore adopted. Clear removes only
    /// its identity and never writes the override: the chip offers "Default" to a role still
    /// tracking its recommendation, and a clear must not make that role's model durable. An edit
    /// whose identity is not the displayed provider and model, or a set that cannot reach the
    /// wire, returns the profile unchanged.
    func applyingRoleModelParameterChange(
        _ change: ACPModelParameterPinChange,
        for roleRawValue: String,
        displayedSelectionID: AgentModelSelectionID
    ) -> AgentModelsSettingsProfile {
        guard change.isApplicable,
              let providerID = AgentProviderKind(rawValue: displayedSelectionID.agentRaw)?.acpProviderID,
              change.targets(providerID: providerID, modelRaw: displayedSelectionID.modelRaw)
        else { return self }
        let bucket = mcpAgentRoleModelParameters?[roleRawValue] ?? []
        // Identity includes the canonical model, so pins retained for an unavailable stored model
        // are never eligible while its fallback is displayed.
        let eligible = ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: displayedSelectionID.modelRaw,
            from: bucket
        )
        guard let edited = Self.editedBucket(bucket, eligible: eligible, applying: change) else { return self }
        var next = self
        if case .set = change {
            var overrides = next.mcpAgentRoleOverrides ?? [:]
            overrides[roleRawValue] = displayedSelectionID.rawValue
            next.mcpAgentRoleOverrides = overrides
        }
        var pins = next.mcpAgentRoleModelParameters ?? [:]
        pins[roleRawValue] = edited.isEmpty ? nil : edited
        next.mcpAgentRoleModelParameters = pins.isEmpty ? nil : pins
        return next
    }

    /// `applyingRoleModelParameterChange` for the Context Builder bucket of `agentRaw`.
    ///
    /// Set commits the displayed agent and model as the Context Builder choice. Set and Clear
    /// both work from the Context Builder read predicate, which counts a bucket only while
    /// `agentRaw` is the persisted Context Builder agent: buckets for other agents are per-agent
    /// memory the surface does not show, so a set must not carry them into the new choice.
    func applyingContextBuilderModelParameterChange(
        _ change: ACPModelParameterPinChange,
        for agentRaw: String?,
        modelRaw: String
    ) -> AgentModelsSettingsProfile {
        guard change.isApplicable,
              let resolvedAgentRaw = Self.normalizedAgentRaw(agentRaw) ?? contextBuilderAgentRaw,
              let agent = AgentProviderKind(rawValue: resolvedAgentRaw),
              let providerID = agent.acpProviderID,
              change.targets(providerID: providerID, modelRaw: modelRaw)
        else { return self }
        guard let edited = Self.editedBucket(
            contextBuilderModelParametersByAgent?[resolvedAgentRaw] ?? [],
            eligible: contextBuilderModelParameterSelections(for: agent, modelRaw: modelRaw),
            applying: change
        ) else { return self }
        var next = self
        if case .set = change {
            next = replacingContextBuilderModel(modelRaw, for: resolvedAgentRaw)
            next.contextBuilderAgentRaw = resolvedAgentRaw
        }
        var pins = next.contextBuilderModelParametersByAgent ?? [:]
        pins[resolvedAgentRaw] = edited.isEmpty ? nil : edited
        next.contextBuilderModelParametersByAgent = pins.isEmpty ? nil : pins
        return next
    }

    /// One pin edit applied to a stored bucket, where `eligible` is the part of it the surface
    /// displays. Set keeps the eligible siblings, replacing only the edited identity; clear
    /// removes the identity from the bucket. Returns nil when the edit changes nothing, and an
    /// empty array when the bucket should be removed.
    private static func editedBucket(
        _ bucket: [ACPModelParameterSelection],
        eligible: [ACPModelParameterSelection],
        applying change: ACPModelParameterPinChange
    ) -> [ACPModelParameterSelection]? {
        switch change {
        case let .set(selection):
            return ACPModelParameterSelection.normalized(eligible + [selection])
        case let .clear(identity):
            guard eligible.contains(where: { $0.identity == identity }) else { return nil }
            return bucket.filter { $0.identity != identity }
        }
    }

    private static func normalizedChatModelRaw(_ raw: String?) -> String? {
        trimmedNonEmpty(raw)
    }

    private static func normalizedAgentRaw(_ raw: String?) -> String? {
        trimmedNonEmpty(raw)
    }

    private static func normalizedContextBuilderModelsByAgent(_ values: [String: String]?) -> [String: String]? {
        normalizedStringMap(values)
    }

    private static func normalizedStringMap(_ values: [String: String]?) -> [String: String]? {
        guard let values else { return nil }
        let normalized = values.keys.sorted().reduce(into: [String: String]()) { result, rawKey in
            guard let key = trimmedNonEmpty(rawKey),
                  let value = trimmedNonEmpty(values[rawKey])
            else {
                return
            }
            result[key] = value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

struct WorkspaceAgentModelsSettings: Codable, Equatable {
    var inheritanceMode: AgentModelsInheritanceMode
    var profile: AgentModelsSettingsProfile?

    init(
        inheritanceMode: AgentModelsInheritanceMode = .useGlobalSettings,
        profile: AgentModelsSettingsProfile? = nil
    ) {
        self.inheritanceMode = inheritanceMode
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case inheritanceMode, profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inheritanceMode = try container.decodeIfPresent(AgentModelsInheritanceMode.self, forKey: .inheritanceMode)
            ?? .useGlobalSettings
        profile = try container.decodeIfPresent(AgentModelsSettingsProfile.self, forKey: .profile)
    }
}

// MARK: - Worktree Visual Identity

enum WorktreeVisualMarkerStyle: String, Codable, Equatable {
    case dot
    case ring
    case capsule
}

struct WorktreeVisualIdentity: Codable, Equatable {
    static let defaultIconName = "circle.fill"
    static let defaultMarkerStyle = WorktreeVisualMarkerStyle.dot

    var label: String?
    var colorHex: String
    var iconName: String
    var markerStyle: WorktreeVisualMarkerStyle
    var updatedAt: Date?

    init(
        label: String? = nil,
        colorHex: String,
        iconName: String = Self.defaultIconName,
        markerStyle: WorktreeVisualMarkerStyle = Self.defaultMarkerStyle,
        updatedAt: Date? = nil
    ) {
        self.label = label
        self.colorHex = colorHex
        self.iconName = iconName
        self.markerStyle = markerStyle
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case label, colorHex, iconName, markerStyle, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? Self.defaultIconName
        markerStyle = try container.decodeIfPresent(WorktreeVisualMarkerStyle.self, forKey: .markerStyle) ?? Self.defaultMarkerStyle
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct WorktreeVisualIdentityRepositoryBucket: Codable, Equatable {
    var identitiesByWorktreeID: [String: WorktreeVisualIdentity]

    init(identitiesByWorktreeID: [String: WorktreeVisualIdentity] = [:]) {
        self.identitiesByWorktreeID = identitiesByWorktreeID
    }
}

// MARK: - Scalar Preferences

/// Optional scalar preferences stored in schema v2.
///
/// Keep groups and fields optional so missing values continue to use the same
/// defaults as the typed settings accessors.
struct GlobalScalarPreferences: Codable, Equatable {
    var ui: UISettings?
    var promptPackaging: PromptPackagingSettings?
    var modelSelection: ModelSelectionSettings?
    var contextBuilder: ContextBuilderSettings?
    var mcp: MCPSettings?
    var fileSystem: FileSystemSettings?
    var agentMode: AgentModeSettings?
    var telemetry: TelemetrySettings?
    var modelOverrides: ModelOverrideSettingsData?

    init(
        ui: UISettings? = nil,
        promptPackaging: PromptPackagingSettings? = nil,
        modelSelection: ModelSelectionSettings? = nil,
        contextBuilder: ContextBuilderSettings? = nil,
        mcp: MCPSettings? = nil,
        fileSystem: FileSystemSettings? = nil,
        agentMode: AgentModeSettings? = nil,
        telemetry: TelemetrySettings? = nil,
        modelOverrides: ModelOverrideSettingsData? = nil
    ) {
        self.ui = ui
        self.promptPackaging = promptPackaging
        self.modelSelection = modelSelection
        self.contextBuilder = contextBuilder
        self.mcp = mcp
        self.fileSystem = fileSystem
        self.agentMode = agentMode
        self.telemetry = telemetry
        self.modelOverrides = modelOverrides
    }

    struct UISettings: Codable, Equatable {
        var appearanceMode: String?
        var useTransparency: Bool?
        var collapseLatestFileChanges: Bool?
        var showTooltips: Bool?
        var experimentalAttributedTextEditor: Bool?
        var fileMentionPickerStyle: String?
        var enableKeyboardShortcuts: Bool?
        var fontScaleBodySize: Double?
        var showDatesInMessageTimestamps: Bool?

        init(
            appearanceMode: String? = nil,
            useTransparency: Bool? = nil,
            collapseLatestFileChanges: Bool? = nil,
            showTooltips: Bool? = nil,
            experimentalAttributedTextEditor: Bool? = nil,
            fileMentionPickerStyle: String? = nil,
            enableKeyboardShortcuts: Bool? = nil,
            fontScaleBodySize: Double? = nil,
            showDatesInMessageTimestamps: Bool? = nil
        ) {
            self.appearanceMode = appearanceMode
            self.useTransparency = useTransparency
            self.collapseLatestFileChanges = collapseLatestFileChanges
            self.showTooltips = showTooltips
            self.experimentalAttributedTextEditor = experimentalAttributedTextEditor
            self.fileMentionPickerStyle = fileMentionPickerStyle
            self.enableKeyboardShortcuts = enableKeyboardShortcuts
            self.fontScaleBodySize = fontScaleBodySize
            self.showDatesInMessageTimestamps = showDatesInMessageTimestamps
        }
    }

    struct PromptPackagingSettings: Codable, Equatable {
        var promptSectionsOrder: String?
        var duplicateUserInstructionsAtTop: Bool?
        var filePathDisplayOption: String?
        var selectedFilesSortMethod: String?
        var fileEditFormat: String?
        var includeDatetimeInUserInstructions: Bool?
        var customPlanningPrompt: String?
        var modelTemperature: Double?
        var setModelTemperature: Bool?
        var complexEditStrategy: String?

        init(
            promptSectionsOrder: String? = nil,
            duplicateUserInstructionsAtTop: Bool? = nil,
            filePathDisplayOption: String? = nil,
            selectedFilesSortMethod: String? = nil,
            fileEditFormat: String? = nil,
            includeDatetimeInUserInstructions: Bool? = nil,
            customPlanningPrompt: String? = nil,
            modelTemperature: Double? = nil,
            setModelTemperature: Bool? = nil,
            complexEditStrategy: String? = nil
        ) {
            self.promptSectionsOrder = promptSectionsOrder
            self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
            self.filePathDisplayOption = filePathDisplayOption
            self.selectedFilesSortMethod = selectedFilesSortMethod
            self.fileEditFormat = fileEditFormat
            self.includeDatetimeInUserInstructions = includeDatetimeInUserInstructions
            self.customPlanningPrompt = customPlanningPrompt
            self.modelTemperature = modelTemperature
            self.setModelTemperature = setModelTemperature
            self.complexEditStrategy = complexEditStrategy
        }
    }

    struct ModelSelectionSettings: Codable, Equatable {
        var preferredComposeModel: String?
        var planningModel: String?
        var syncChatModelWithOracle: Bool?

        init(
            preferredComposeModel: String? = nil,
            planningModel: String? = nil,
            syncChatModelWithOracle: Bool? = nil
        ) {
            self.preferredComposeModel = preferredComposeModel
            self.planningModel = planningModel
            self.syncChatModelWithOracle = syncChatModelWithOracle
        }
    }

    struct ContextBuilderSettings: Codable, Equatable {
        var contextTokenBudget: Int?
        var analysisTokenBudget: Int?
        var enhancementMode: String?
        var questionTimeoutSeconds: TimeInterval?
        var allowUIClarifyingQuestions: Bool?
        var allowMCPClarifyingQuestions: Bool?
        var followUpAnalysisEnabled: Bool?

        init(
            contextTokenBudget: Int? = nil,
            analysisTokenBudget: Int? = nil,
            enhancementMode: String? = nil,
            questionTimeoutSeconds: TimeInterval? = nil,
            allowUIClarifyingQuestions: Bool? = nil,
            allowMCPClarifyingQuestions: Bool? = nil,
            followUpAnalysisEnabled: Bool? = nil
        ) {
            self.contextTokenBudget = contextTokenBudget
            self.analysisTokenBudget = analysisTokenBudget
            self.enhancementMode = enhancementMode
            self.questionTimeoutSeconds = questionTimeoutSeconds
            self.allowUIClarifyingQuestions = allowUIClarifyingQuestions
            self.allowMCPClarifyingQuestions = allowMCPClarifyingQuestions
            self.followUpAnalysisEnabled = followUpAnalysisEnabled
        }
    }

    struct MCPSettings: Codable, Equatable {
        var autoStart: Bool?
        var showModelPresets: Bool?
        var temporarilyDisablePresets: Bool?

        init(
            autoStart: Bool? = nil,
            showModelPresets: Bool? = nil,
            temporarilyDisablePresets: Bool? = nil
        ) {
            self.autoStart = autoStart
            self.showModelPresets = showModelPresets
            self.temporarilyDisablePresets = temporarilyDisablePresets
        }
    }

    struct FileSystemSettings: Codable, Equatable {
        var respectRepoIgnore: Bool?
        var respectCursorignore: Bool?
        var globalIgnoreDefaults: String?
        var enableHierarchicalIgnores: Bool?
        var skipSymlinks: Bool?
        var showEmptyFolders: Bool?

        init(
            respectRepoIgnore: Bool? = nil,
            respectCursorignore: Bool? = nil,
            globalIgnoreDefaults: String? = nil,
            enableHierarchicalIgnores: Bool? = nil,
            skipSymlinks: Bool? = nil,
            showEmptyFolders: Bool? = nil
        ) {
            self.respectRepoIgnore = respectRepoIgnore
            self.respectCursorignore = respectCursorignore
            self.globalIgnoreDefaults = globalIgnoreDefaults
            self.enableHierarchicalIgnores = enableHierarchicalIgnores
            self.skipSymlinks = skipSymlinks
            self.showEmptyFolders = showEmptyFolders
        }
    }

    struct TelemetrySettings: Codable, Equatable {
        var enabled: Bool?
        var appHangReportsEnabled: Bool?
        var performanceTracingEnabled: Bool?

        init(
            enabled: Bool? = nil,
            appHangReportsEnabled: Bool? = nil,
            performanceTracingEnabled: Bool? = nil
        ) {
            self.enabled = enabled
            self.appHangReportsEnabled = appHangReportsEnabled
            self.performanceTracingEnabled = performanceTracingEnabled
        }
    }

    struct ModelOverrideSettingsData: Codable, Equatable {
        var diffOverrides: [String: Bool]?
        var streamOverrides: [String: Bool]?
        var temperatureOverrides: [String: Double]?
        var responsesOverrides: [String: Bool]?

        init(
            diffOverrides: [String: Bool]? = nil,
            streamOverrides: [String: Bool]? = nil,
            temperatureOverrides: [String: Double]? = nil,
            responsesOverrides: [String: Bool]? = nil
        ) {
            self.diffOverrides = diffOverrides
            self.streamOverrides = streamOverrides
            self.temperatureOverrides = temperatureOverrides
            self.responsesOverrides = responsesOverrides
        }
    }

    struct AgentModeSettings: Codable, Equatable {
        var proEditAgentMode: Bool?
        var proEditAgentKind: String?
        var proEditAgentModel: String?
        var proEditAgentModeMigrated: Bool?
        // DEPRECATED: Auto-Expand Tool Cards was removed in 2026-04.
        // Kept temporarily for decode/rollback compatibility only; do not read from UI/runtime.
        var agentAutoExpandToolCards: Bool?
        // DEPRECATED: The background Agent compose-tab limit was removed in 2026-08.
        // Kept for decode/rollback compatibility and round-trip preservation only.
        var maxBackgroundAgentComposeTabs: Int?
        var showBuiltInWorkflowCleanupGuidance: Bool?
        var codexGoalSupportEnabled: Bool?
        var codexReasoningSummariesEnabled: Bool?
        var codexMemoriesEnabled: Bool?
        var codexAppsEnabled: Bool?
        var codexPluginsEnabled: Bool?
        var codexMCPElicitationEnabled: Bool?
        var codexToolSuggestionsEnabled: Bool?
        var codexHookApprovalStrictModeEnabled: Bool?
        var codexHookApprovalStrictModeWorkspaceOverrides: [String: Bool]?
        var providerConversationCleanupAction: String?
        var restrictMCPAgentDiscoveryToRoleLabels: Bool?
        var agentSessionHandoffInstructions: String?

        init(
            proEditAgentMode: Bool? = nil,
            proEditAgentKind: String? = nil,
            proEditAgentModel: String? = nil,
            proEditAgentModeMigrated: Bool? = nil,
            agentAutoExpandToolCards: Bool? = nil,
            maxBackgroundAgentComposeTabs: Int? = nil,
            showBuiltInWorkflowCleanupGuidance: Bool? = nil,
            codexGoalSupportEnabled: Bool? = nil,
            codexReasoningSummariesEnabled: Bool? = nil,
            codexMemoriesEnabled: Bool? = nil,
            codexAppsEnabled: Bool? = nil,
            codexPluginsEnabled: Bool? = nil,
            codexMCPElicitationEnabled: Bool? = nil,
            codexToolSuggestionsEnabled: Bool? = nil,
            codexHookApprovalStrictModeEnabled: Bool? = nil,
            codexHookApprovalStrictModeWorkspaceOverrides: [String: Bool]? = nil,
            providerConversationCleanupAction: String? = nil,
            restrictMCPAgentDiscoveryToRoleLabels: Bool? = nil,
            agentSessionHandoffInstructions: String? = nil
        ) {
            self.proEditAgentMode = proEditAgentMode
            self.proEditAgentKind = proEditAgentKind
            self.proEditAgentModel = proEditAgentModel
            self.proEditAgentModeMigrated = proEditAgentModeMigrated
            self.agentAutoExpandToolCards = agentAutoExpandToolCards
            self.maxBackgroundAgentComposeTabs = maxBackgroundAgentComposeTabs
            self.showBuiltInWorkflowCleanupGuidance = showBuiltInWorkflowCleanupGuidance
            self.codexGoalSupportEnabled = codexGoalSupportEnabled
            self.codexReasoningSummariesEnabled = codexReasoningSummariesEnabled
            self.codexMemoriesEnabled = codexMemoriesEnabled
            self.codexAppsEnabled = codexAppsEnabled
            self.codexPluginsEnabled = codexPluginsEnabled
            self.codexMCPElicitationEnabled = codexMCPElicitationEnabled
            self.codexToolSuggestionsEnabled = codexToolSuggestionsEnabled
            self.codexHookApprovalStrictModeEnabled = codexHookApprovalStrictModeEnabled
            self.codexHookApprovalStrictModeWorkspaceOverrides = codexHookApprovalStrictModeWorkspaceOverrides
            self.providerConversationCleanupAction = providerConversationCleanupAction
            self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
            self.agentSessionHandoffInstructions = agentSessionHandoffInstructions
        }
    }
}
