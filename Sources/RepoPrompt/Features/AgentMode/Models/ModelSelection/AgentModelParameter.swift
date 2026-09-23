import Foundation

enum ACPModelParameterKind: String, Codable, Hashable, CaseIterable {
    case thinking
    case speed

    var sortOrder: Int {
        switch self {
        case .thinking: 0
        case .speed: 1
        }
    }
}

/// Per-kind wording for pin controls when no live definition supplies the provider's own.
extension ACPModelParameterKind {
    /// Display name for a control synthesized from saved intent alone.
    var recoveryDisplayName: String {
        switch self {
        case .thinking: "Thinking"
        case .speed: "Speed"
        }
    }

    /// The noun a Default tooltip uses for the provider's current value.
    var tooltipNoun: String {
        switch self {
        case .thinking: "effort"
        case .speed: "speed"
        }
    }

    /// The noun for a saved pin in unavailable-value tooltips.
    var savedValueNoun: String {
        switch self {
        case .thinking: "thinking level"
        case .speed: "speed"
        }
    }

    /// Title for a saved pin's tooltip when no definition names the parameter.
    var savedValueTitle: String {
        switch self {
        case .thinking: "Thinking level"
        case .speed: "Speed"
        }
    }
}

struct ACPModelParameterChoice: Codable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?

    init(rawValue: String, displayName: String, description: String? = nil) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
    }
}

struct ACPModelParameterDefinition: Codable, Hashable {
    let kind: ACPModelParameterKind
    let configID: String
    let displayName: String
    let choices: [ACPModelParameterChoice]
    let currentValueRaw: String

    func choice(matching requestedValue: String) -> ACPModelParameterChoice? {
        if let exact = choices.first(where: { $0.rawValue == requestedValue }) {
            return exact
        }
        let matches = choices.filter {
            $0.rawValue.caseInsensitiveCompare(requestedValue) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct ACPModelParameterSet: Codable, Hashable {
    let baseModelRaw: String
    let parameters: [ACPModelParameterDefinition]

    func definition(configID: String) -> ACPModelParameterDefinition? {
        parameters.first { $0.configID == configID }
    }

    func definition(kind: ACPModelParameterKind) -> ACPModelParameterDefinition? {
        let matches = parameters.filter { $0.kind == kind }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct ACPModelParameterSelection: Codable, Hashable {
    let providerID: ACPProviderID
    let baseModelRaw: String
    let kind: ACPModelParameterKind
    let configID: String
    let valueRaw: String

    var identity: ACPModelParameterIdentity {
        ACPModelParameterIdentity(
            providerID: providerID,
            baseModelRaw: baseModelRaw,
            kind: kind
        )
    }

    static func normalized(_ selections: [Self]) -> [Self] {
        var valueByIdentity: [ACPModelParameterIdentity: Self] = [:]
        var orderedIdentities: [ACPModelParameterIdentity] = []
        for selection in selections {
            let identity = selection.identity
            if valueByIdentity[identity] == nil {
                orderedIdentities.append(identity)
            }
            valueByIdentity[identity] = selection
        }
        return orderedIdentities.compactMap { valueByIdentity[$0] }
    }

    static func selections(
        for providerID: ACPProviderID,
        activeBaseModelRaw: String,
        from selections: [Self]
    ) -> [Self] {
        normalized(selections).filter {
            $0.providerID == providerID
                && ACPModelParameterIdentity.sameModel($0.baseModelRaw, activeBaseModelRaw, providerID: providerID)
        }
    }
}

/// One edit to a saved parameter pin, addressed to a single provider/model/kind identity.
///
/// Pin surfaces send an operation rather than a replacement bucket, and storage merges it into
/// its latest state. A menu opened before another surface pinned a sibling kind therefore can
/// never write a stale bucket over that newer sibling.
enum ACPModelParameterPinChange: Hashable {
    /// Pin an advertised value. The selector and value are the provider's wire strings.
    case set(ACPModelParameterSelection)
    /// Remove the pin for one identity. Needs no discovered selector.
    case clear(ACPModelParameterIdentity)

    var identity: ACPModelParameterIdentity {
        switch self {
        case let .set(selection): selection.identity
        case let .clear(identity): identity
        }
    }

    /// A set with a blank selector or value cannot reach the wire. Callers treat it as a no-op,
    /// never as a clear.
    var isApplicable: Bool {
        guard case let .set(selection) = self else { return true }
        return !selection.configID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selection.valueRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether this edit addresses `modelRaw` for `providerID` under canonical model identity.
    func targets(providerID: ACPProviderID, modelRaw: String) -> Bool {
        identity.providerID == providerID
            && ACPModelParameterIdentity.sameModel(
                identity.canonicalBaseModelRaw,
                modelRaw,
                providerID: providerID
            )
    }

    /// The pin for choosing `choice` from an advertised definition, keeping its exact selector
    /// and wire value.
    static func pinning(
        _ choice: ACPModelParameterChoice,
        of definition: ACPModelParameterDefinition,
        providerID: ACPProviderID,
        baseModelRaw: String
    ) -> Self {
        .set(ACPModelParameterSelection(
            providerID: providerID,
            baseModelRaw: baseModelRaw,
            kind: definition.kind,
            configID: definition.configID,
            valueRaw: choice.rawValue
        ))
    }
}

struct ACPModelParameterIdentity: Hashable {
    let providerID: ACPProviderID
    let canonicalBaseModelRaw: String
    let kind: ACPModelParameterKind

    init(
        providerID: ACPProviderID,
        baseModelRaw: String,
        kind: ACPModelParameterKind
    ) {
        self.providerID = providerID
        canonicalBaseModelRaw = Self.canonicalBaseModelRaw(baseModelRaw, providerID: providerID)
        self.kind = kind
    }

    static func canonicalBaseModelRaw(_ raw: String, providerID: ACPProviderID) -> String {
        if providerID == .cursor {
            return CursorAIModelCatalog.option(matching: raw)?.rawValue
                ?? ACPAIModelCatalog.normalizedCursorModelAlias(raw)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether two model strings name the same model for `providerID`. Canonicalization is
    /// idempotent, so either side may already be canonical.
    static func sameModel(_ lhs: String, _ rhs: String, providerID: ACPProviderID) -> Bool {
        canonicalBaseModelRaw(lhs, providerID: providerID) == canonicalBaseModelRaw(rhs, providerID: providerID)
    }
}

extension AgentModelCatalog.NormalizedAgentSelection {
    /// Whether a parameter pin captured for `providerID`'s `modelRaw` still addresses this
    /// selection. Always false for an agent with no ACP provider.
    func isPinTarget(providerID: ACPProviderID, modelRaw: String) -> Bool {
        agent.acpProviderID == providerID
            && ACPModelParameterIdentity.sameModel(self.modelRaw, modelRaw, providerID: providerID)
    }
}

/// One parameter kind for a selected provider and model, as every pin surface lists it: the
/// advertised definition when exactly one exists, and the saved pin when there is one. Surfaces
/// apply their own display policies on top; nothing here is persisted.
struct ACPModelParameterPinControl: Hashable {
    let providerID: ACPProviderID
    /// The advertised set's base model when a definition exists, else the saved pin's.
    let baseModelRaw: String
    let kind: ACPModelParameterKind
    /// Nil while metadata is missing, loading, or failed, and when the kind is advertised more
    /// than once (the runtime cannot pick between ambiguous selectors either).
    let definition: ACPModelParameterDefinition?
    let saved: ACPModelParameterSelection?
    /// Whether the provider's parameter set for this model resolved. With a set but no usable
    /// definition, the model does not offer this kind unambiguously, so a saved value cannot
    /// apply; without a set, metadata is simply unknown.
    let hasParameterSet: Bool

    var identity: ACPModelParameterIdentity {
        ACPModelParameterIdentity(providerID: providerID, baseModelRaw: baseModelRaw, kind: kind)
    }

    /// Whether the provider's metadata resolved and cannot apply the saved value: the value is
    /// absent from the definition's choices (for example a level later disabled in
    /// `opencode.json`), or the model offers no unambiguous definition for the kind. While
    /// metadata is missing, loading, or failed, a saved value is not reported unavailable.
    var isSavedValueUnavailable: Bool {
        guard let savedValueRaw = saved?.valueRaw else { return false }
        guard let definition else { return hasParameterSet }
        return definition.choice(matching: savedValueRaw) == nil
    }
}

enum ACPModelParameterResolver {
    /// The composer's displayed choice for one definition. OpenCode must show unsupported saved
    /// intent, not a default that the next run will never use. Cursor deliberately retains its
    /// display fallback to the advertised current value.
    static func composerSelectedChoice(
        definition: ACPModelParameterDefinition,
        saved: ACPModelParameterSelection?,
        providerID: ACPProviderID
    ) -> ACPModelParameterChoice? {
        let savedChoice = saved.flatMap { selection in
            definition.choice(matching: selection.valueRaw)
                ?? (
                    providerID == .openCode
                        ? ACPModelParameterChoice(rawValue: selection.valueRaw, displayName: selection.valueRaw)
                        : nil
                )
        }
        return savedChoice ?? definition.choice(matching: definition.currentValueRaw)
    }

    /// Every parameter kind to list for `selectedModelRaw`: the union of advertised kinds and
    /// saved kinds, in `sortOrder`, one control per kind that has an unambiguous definition or a
    /// saved pin. `parameterSet` comes from `parameterSet(...)`; nil means no usable metadata.
    static func pinControls(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        parameterSet: ACPModelParameterSet?,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [ACPModelParameterPinControl] {
        let savedByKind = Dictionary(
            ACPModelParameterSelection.selections(
                for: providerID,
                activeBaseModelRaw: selectedModelRaw,
                from: persistedSelections
            ).map { ($0.kind, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let kinds = Set((parameterSet?.parameters ?? []).map(\.kind)).union(savedByKind.keys)
        return kinds.sorted { $0.sortOrder < $1.sortOrder }.compactMap { kind in
            let definition = parameterSet?.definition(kind: kind)
            let saved = savedByKind[kind]
            guard definition != nil || saved != nil else { return nil }
            let baseModelRaw = definition != nil ? parameterSet?.baseModelRaw : saved?.baseModelRaw
            return ACPModelParameterPinControl(
                providerID: providerID,
                baseModelRaw: baseModelRaw ?? selectedModelRaw,
                kind: kind,
                definition: definition,
                saved: saved,
                hasParameterSet: parameterSet != nil
            )
        }
    }

    static func parameterSet(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        workspacePath: String? = nil,
        openCodeParameters: OpenCodeACPModelParameterSnapshot? = nil
    ) -> ACPModelParameterSet? {
        switch providerID {
        case .cursor:
            CursorAIModelCatalog.parameterSet(for: selectedModelRaw)
        case .openCode:
            openCodeParameterSet(
                selectedModelRaw: selectedModelRaw,
                workspacePath: workspacePath,
                observation: openCodeParameters
            )
        default:
            nil
        }
    }

    /// The parameter set a pin surface lists for `selectedModelRaw`. OpenCode metadata needs the
    /// surface's resolved discovery key: no key means no OpenCode set, never a nil-workspace
    /// lookup. Other providers ignore the key and resolve without a session.
    static func parameterSet(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        openCodeKey: OpenCodeACPModelParameterKey?,
        openCodeParameters: OpenCodeACPModelParameterSnapshot?
    ) -> ACPModelParameterSet? {
        guard providerID == .openCode else {
            return parameterSet(providerID: providerID, selectedModelRaw: selectedModelRaw)
        }
        guard let openCodeKey else { return nil }
        return parameterSet(
            providerID: providerID,
            selectedModelRaw: selectedModelRaw,
            workspacePath: openCodeKey.workspacePath,
            openCodeParameters: openCodeParameters
        )
    }

    /// Accept OpenCode metadata only when the observation is `.available`, its key matches the
    /// requested normalized workspace+model exactly, and the advertised set matches that model
    /// unambiguously. Missing or mismatched context yields no parameter set — never a fall back
    /// to the provider-global registry, whose per-provider snapshot cannot represent the
    /// demand-scoped `(workspace, model)` authority.
    private static func openCodeParameterSet(
        selectedModelRaw: String,
        workspacePath: String?,
        observation: OpenCodeACPModelParameterSnapshot?
    ) -> ACPModelParameterSet? {
        guard let observation,
              case let .available(parameterSet) = observation.state
        else { return nil }
        let targetIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            selectedModelRaw,
            providerID: .openCode
        )
        // Compare the constructed expected key directly; `observation.key`'s fields are already
        // canonical at construction, so re-canonicalizing them would be a no-op. Key equality
        // covers both the canonical model identity and the normalized workspace.
        let expectedKey = OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: selectedModelRaw)
        guard observation.key == expectedKey else { return nil }
        guard ACPModelParameterIdentity.canonicalBaseModelRaw(
            parameterSet.baseModelRaw,
            providerID: .openCode
        ) == targetIdentity else { return nil }
        return parameterSet
    }

    static func effectiveSelections(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [ACPModelParameterSelection] {
        ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: selectedModelRaw,
            from: persistedSelections
        )
    }
}
