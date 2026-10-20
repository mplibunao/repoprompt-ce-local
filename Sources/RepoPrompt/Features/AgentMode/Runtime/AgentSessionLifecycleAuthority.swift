import CryptoKit
import Foundation
import OSLog

/// Single decision authority for Agent compose-tab/session identity transitions.
///
/// Callers may own presentation, persistence, provider, or MCP mechanics, but none of
/// those layers may independently retarget a live Agent operation. They consume the
/// immutable identities and typed decisions produced here.
struct AgentProvisionalAdmissionIdentity: Equatable, Hashable {
    let recoveryID: UUID
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID
    let replacementTabID: UUID
}

final class AgentProvisionalAdmissionClaim: Equatable {
    enum State: Equatable {
        case provisional
        case recoveringWorkspace
        case workspaceRecovered
        case blockedManual(WorkspacePersistenceFailureCategory)
        case complete
        case accepted
    }

    let identity: AgentProvisionalAdmissionIdentity
    @MainActor
    private(set) var state: State = .provisional

    init(identity: AgentProvisionalAdmissionIdentity) {
        self.identity = identity
    }

    @MainActor
    @discardableResult
    func beginWorkspaceRecovery() -> Bool {
        transition(from: .provisional, to: .recoveringWorkspace)
    }

    @MainActor
    @discardableResult
    func markWorkspaceRecovered() -> Bool {
        transition(from: .recoveringWorkspace, to: .workspaceRecovered)
    }

    @MainActor
    @discardableResult
    func markComplete() -> Bool {
        switch state {
        case .provisional, .recoveringWorkspace, .workspaceRecovered:
            state = .complete
            return true
        case .blockedManual, .complete, .accepted:
            return false
        }
    }

    @MainActor
    @discardableResult
    func markBlockedForManualRecovery(_ category: WorkspacePersistenceFailureCategory) -> Bool {
        switch state {
        case .recoveringWorkspace:
            state = .blockedManual(category)
            return true
        case let .blockedManual(existing) where existing == category:
            return true
        case .blockedManual:
            return false
        case .provisional, .workspaceRecovered, .complete, .accepted:
            return false
        }
    }

    @MainActor
    @discardableResult
    func resumeBlockedWorkspaceRecovery() -> Bool {
        guard case .blockedManual = state else { return false }
        state = .recoveringWorkspace
        return true
    }

    @MainActor
    @discardableResult
    func markAccepted() -> Bool {
        transition(from: .provisional, to: .accepted)
    }

    static func == (lhs: AgentProvisionalAdmissionClaim, rhs: AgentProvisionalAdmissionClaim) -> Bool {
        lhs.identity == rhs.identity
    }

    @MainActor
    private func transition(from expected: State, to replacement: State) -> Bool {
        guard state == expected else { return false }
        state = replacement
        return true
    }
}

@MainActor
final class AgentSessionLifecycleAuthority {
    struct Identity: Equatable, Hashable {
        let workspaceID: UUID
        let tabID: UUID
        let sessionID: UUID?
        let persistentBindingGeneration: UUID?
        let bindingTransitionGeneration: UInt64
    }

    struct ProtectionClaim: Equatable {
        let identity: Identity
        let tab: ComposeTabState
        let isLive: Bool
        let isActive: Bool
        let isPinned: Bool
        let hasActiveRun: Bool

        var isProtected: Bool {
            isLive || isPinned
        }
    }

    struct MutationTarget: Equatable {
        let tabID: UUID
        let identity: Identity?
    }

    enum CallerCategory: String {
        case agentRunStart = "agent_run_start"
        case agentSessionControl = "agent_session_control"
        case domainProjection = "domain_projection"
        case providerLifecycle = "provider_lifecycle"
    }

    enum Intent: String {
        case createOrContinue = "create_or_continue"
        case applyProjection = "apply_projection"
        case setStatus = "set_status"
        case shareThoughts = "share_thoughts"
        case waitForInstruction = "wait_for_instruction"
        case askUser = "ask_user"
        case providerStart = "provider_start"
    }

    enum Phase: String {
        case beforeBinding = "before_binding"
        case bindingPersisted = "binding_persisted"
        case beforeProviderStart = "before_provider_start"
        case afterProviderStart = "after_provider_start"
        case mutationValidation = "mutation_validation"
        case projectionReconciliation = "projection_reconciliation"
    }

    enum Decision: String {
        case admitted
        case protected
        case rejected
        case unchanged
    }

    enum RejectionReason: String, Error {
        case cancelled
        case workspacePersistenceRejected = "workspace_persistence_rejected"
        case workspaceChanged = "workspace_changed"
        case tabMissing = "tab_missing"
        case sessionMissing = "session_missing"
        case sessionIdentityChanged = "session_identity_changed"
        case bindingGenerationChanged = "binding_generation_changed"
        case transitionGenerationChanged = "transition_generation_changed"
    }

    enum AdmissionDecision: Equatable {
        case commit
        case rollback(RejectionReason)
    }

    enum DurableAdmissionDecision: Equatable {
        case commit
        case localRollback(RejectionReason)
        case recoverWorkspace(RejectionReason)
    }

    struct Event: Equatable {
        let caller: CallerCategory
        let intent: Intent
        let phase: Phase
        let decision: Decision
        let identity: Identity?
        let previousSessionID: UUID?
        let currentSessionID: UUID?
        let isPinned: Bool
        let isLive: Bool
        let isActive: Bool
        let isProtected: Bool
        let workspaceSaveResult: String
        let reason: String
    }

    struct ProjectionOutcome: Equatable {
        /// The shown workspace to install, nil only when the projection drops the workspace and no
        /// claim protects it.
        let workspace: WorkspaceModel?
        let isProtected: Bool
        let protectedClaimCount: Int
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "AgentSessionLifecycle"
    )

    #if DEBUG
        private static var eventObserver: ((Event) -> Void)?

        static func setEventObserverForTesting(_ observer: ((Event) -> Void)?) {
            eventObserver = observer
        }
    #endif

    /// `current` is the target's identity now, nil when its live session no longer owns a listed tab.
    func validateMutationTarget(
        expected: Identity,
        current: Identity?
    ) -> Result<MutationTarget, RejectionReason> {
        guard let current else { return .failure(.tabMissing) }
        guard current.tabID == expected.tabID else { return .failure(.tabMissing) }
        guard current.sessionID == expected.sessionID else {
            return .failure(.sessionIdentityChanged)
        }
        guard current.persistentBindingGeneration == expected.persistentBindingGeneration else {
            return .failure(.bindingGenerationChanged)
        }
        guard current.bindingTransitionGeneration == expected.bindingTransitionGeneration else {
            return .failure(.transitionGenerationChanged)
        }
        return .success(MutationTarget(tabID: expected.tabID, identity: expected))
    }

    /// Owns the commit/rollback decision for every create-or-continue admission.
    /// Presentation and persistence layers provide facts but do not independently
    /// decide whether provider-visible identity may be published.
    func decideAdmission(
        persistence: WorkspacePersistenceOutcome,
        targetWorkspaceID: UUID,
        bindingStillCurrent: Bool
    ) -> AdmissionDecision {
        guard persistence.acceptedForLifecycleAdmission else {
            return .rollback(.workspacePersistenceRejected)
        }
        guard persistence.workspaceID == targetWorkspaceID else {
            return .rollback(.workspaceChanged)
        }
        guard bindingStillCurrent else {
            return .rollback(.sessionIdentityChanged)
        }
        return .commit
    }

    func decideDurableAdmission(
        receipt: AgentAdmissionPersistenceReceipt,
        targetWorkspaceID: UUID,
        bindingStillCurrent: Bool,
        isCancelled: Bool
    ) -> DurableAdmissionDecision {
        let hasCanonicalCommit = switch receipt.commitEvidence {
        case .none: false
        case .canonicalWorking, .saved: true
        }
        let durabilityRequiresRecovery = hasCanonicalCommit || {
            if case .persisted = receipt.outcome { return true }
            return false
        }()

        if isCancelled {
            return durabilityRequiresRecovery
                ? .recoverWorkspace(.cancelled)
                : .localRollback(.cancelled)
        }
        if let persistedWorkspaceID = receipt.outcome.workspaceID,
           persistedWorkspaceID != targetWorkspaceID
        {
            return durabilityRequiresRecovery
                ? .recoverWorkspace(.workspaceChanged)
                : .localRollback(.workspaceChanged)
        }
        guard bindingStillCurrent else {
            return durabilityRequiresRecovery
                ? .recoverWorkspace(.sessionIdentityChanged)
                : .localRollback(.sessionIdentityChanged)
        }

        switch receipt.commitEvidence {
        case .saved:
            // Exact canonical/disk evidence wins over a lost or cancelled save response.
            return .commit
        case .canonicalWorking:
            return .recoverWorkspace(.workspacePersistenceRejected)
        case .none:
            switch receipt.outcome {
            case .persisted:
                return .recoverWorkspace(.workspacePersistenceRejected)
            case let .notRequired(workspaceID):
                return workspaceID == targetWorkspaceID
                    ? .commit
                    : .localRollback(.workspaceChanged)
            case .rejected:
                return .localRollback(.workspacePersistenceRejected)
            }
        }
    }

    /// Reconciles the projection of the window's shown workspace with the window's copy of it,
    /// which `claims` describe. A live or pinned tab keeps the copy's content, and a projection that
    /// drops the workspace keeps the copy while a claim protects one of its tabs.
    func reconcileProjection(
        projectedWorkspace: WorkspaceModel?,
        currentWorkspace: WorkspaceModel,
        claims: [ProtectionClaim]
    ) -> ProjectionOutcome {
        let protectedClaims = claims.filter { $0.isProtected && $0.identity.workspaceID == currentWorkspace.id }
        guard !protectedClaims.isEmpty else {
            return ProjectionOutcome(workspace: projectedWorkspace, isProtected: false, protectedClaimCount: 0)
        }
        guard let previous = projectedWorkspace else {
            recordProjectionProtection(
                claims: protectedClaims,
                previousTabs: [],
                reason: "workspace_missing_from_projection"
            )
            return ProjectionOutcome(
                workspace: currentWorkspace,
                isProtected: true,
                protectedClaimCount: protectedClaims.count
            )
        }

        var next = previous
        let protectedTabIDs = Set(protectedClaims.map(\.identity.tabID))
        next.stashedTabs.removeAll { protectedTabIDs.contains($0.tab.id) }
        var keptTabsByID: [UUID: ComposeTabState] = [:]

        for claim in protectedClaims {
            let tabID = claim.identity.tabID
            if let sessionID = claim.identity.sessionID {
                for tabIndex in next.composeTabs.indices
                    where next.composeTabs[tabIndex].id != tabID
                    && next.composeTabs[tabIndex].activeAgentSessionID == sessionID
                {
                    next.composeTabs[tabIndex].activeAgentSessionID = nil
                }
            }
            if let index = next.composeTabs.firstIndex(where: { $0.id == tabID }) {
                // Protection keeps the tab and its session binding. Its selection follows the
                // canonical document, so it takes the projection's value. When the selection is all
                // that differs, the tab is the projection's, timestamp included.
                let projected = next.composeTabs[index]
                var kept = claim.tab
                kept.selection = projected.selection
                kept.lastModified = projected.lastModified
                if kept != projected {
                    kept.lastModified = claim.tab.lastModified
                }
                next.composeTabs[index] = kept
                keptTabsByID[tabID] = kept
            } else if let localIndex = currentWorkspace.composeTabs.firstIndex(where: { $0.id == tabID }) {
                next.composeTabs.insert(claim.tab, at: min(localIndex, next.composeTabs.count))
            } else {
                next.composeTabs.append(claim.tab)
            }
        }

        if let activeTabID = currentWorkspace.activeComposeTabID,
           protectedTabIDs.contains(activeTabID)
        {
            next.activeComposeTabID = activeTabID
        }

        guard next != previous else {
            return ProjectionOutcome(workspace: previous, isProtected: false, protectedClaimCount: 0)
        }
        let changedClaims = protectedClaims.filter { claim in
            let previousTab = previous.composeTabs.first(where: { $0.id == claim.identity.tabID })
            return previousTab != (keptTabsByID[claim.identity.tabID] ?? claim.tab)
                || previous.stashedTabs.contains(where: { $0.tab.id == claim.identity.tabID })
                || (claim.isActive && previous.activeComposeTabID != claim.identity.tabID)
        }
        recordProjectionProtection(
            claims: changedClaims,
            previousTabs: previous.composeTabs,
            reason: "stale_projection_reconciled"
        )
        return ProjectionOutcome(workspace: next, isProtected: true, protectedClaimCount: changedClaims.count)
    }

    func record(_ event: Event) {
        let identity = event.identity
        let line = [
            "caller=\(event.caller.rawValue)",
            "intent=\(event.intent.rawValue)",
            "phase=\(event.phase.rawValue)",
            "decision=\(event.decision.rawValue)",
            "workspace=\(Self.hashedID(identity?.workspaceID))",
            "tab=\(Self.hashedID(identity?.tabID))",
            "session=\(Self.hashedID(identity?.sessionID))",
            "previousSession=\(Self.hashedID(event.previousSessionID))",
            "currentSession=\(Self.hashedID(event.currentSessionID))",
            "binding=\(Self.hashedID(identity?.persistentBindingGeneration))",
            "transition=\(identity.map { String($0.bindingTransitionGeneration) } ?? "nil")",
            "pinned=\(event.isPinned)",
            "live=\(event.isLive)",
            "active=\(event.isActive)",
            "protected=\(event.isProtected)",
            "workspaceSave=\(Self.sanitizedCategory(event.workspaceSaveResult))",
            "reason=\(Self.sanitizedCategory(event.reason))"
        ].joined(separator: " ")
        Self.logger.notice("\(line, privacy: .public)")
        #if DEBUG
            Self.eventObserver?(event)
        #endif
    }

    private func recordProjectionProtection(
        claims: [ProtectionClaim],
        previousTabs: [ComposeTabState],
        reason: String
    ) {
        // One event per affected identity, capped to keep a damaged projection bounded.
        for claim in claims.prefix(8) {
            let previousSessionID = previousTabs
                .first(where: { $0.id == claim.identity.tabID })?
                .activeAgentSessionID
            record(Event(
                caller: .domainProjection,
                intent: .applyProjection,
                phase: .projectionReconciliation,
                decision: .protected,
                identity: claim.identity,
                previousSessionID: previousSessionID,
                currentSessionID: claim.identity.sessionID,
                isPinned: claim.isPinned,
                isLive: claim.isLive,
                isActive: claim.isActive,
                isProtected: true,
                workspaceSaveResult: "pending_recovery",
                reason: reason
            ))
        }
    }

    private static func hashedID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedCategory(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = raw.unicodeScalars.prefix(64).map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(scalars)
    }
}
