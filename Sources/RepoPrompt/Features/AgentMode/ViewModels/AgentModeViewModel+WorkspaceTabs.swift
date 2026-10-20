import Foundation
import RepoPromptDomainRuntime

/// A workspace whose tabs Agent Mode looks up: the window's own copy of a workspace it holds, which
/// is its shown workspace or one of its own ephemeral workspaces, and the store's summary of any
/// other. It lists tab identities, names, pins, and session references, never tab content.
enum AgentListedWorkspace {
    case held(WorkspaceModel)
    case summary(DomainWorkspaceSummary)

    var workspaceID: UUID {
        switch self {
        case let .held(workspace): workspace.id
        case let .summary(summary): summary.workspaceID
        }
    }

    var activeTabID: UUID? {
        switch self {
        case let .held(workspace): workspace.activeComposeTabID
        case let .summary(summary): summary.activeContextID
        }
    }

    /// The tab at `location`, or the compose tab before the stashed one when `location` is nil.
    func tab(_ tabID: UUID, location: DomainWorkspaceTabLocation? = nil) -> ListedTab? {
        if location != .stashed, let composed = firstTab(tabID, at: .composed) {
            return composed
        }
        return location == .composed ? nil : firstTab(tabID, at: .stashed)
    }

    /// Whether a compose or stashed tab satisfies `predicate`.
    func containsTab(where predicate: (ListedTab) -> Bool) -> Bool {
        switch self {
        case let .held(workspace):
            workspace.composeTabs.contains { predicate(ListedTab($0, workspaceID: workspace.id, location: .composed)) }
                || workspace.stashedTabs.contains {
                    predicate(ListedTab($0.tab, workspaceID: workspace.id, location: .stashed))
                }
        case let .summary(summary):
            summary.composeTabs.contains { predicate(ListedTab($0, workspaceID: summary.workspaceID)) }
                || summary.stashedTabs.contains { predicate(ListedTab($0, workspaceID: summary.workspaceID)) }
        }
    }

    /// Calls `body` with each tab at `location`, in the workspace's order.
    func forEachTab(at location: DomainWorkspaceTabLocation, _ body: (ListedTab) -> Void) {
        switch (self, location) {
        case let (.held(workspace), .composed):
            for tab in workspace.composeTabs {
                body(ListedTab(tab, workspaceID: workspace.id, location: .composed))
            }
        case let (.held(workspace), .stashed):
            for stashed in workspace.stashedTabs {
                body(ListedTab(stashed.tab, workspaceID: workspace.id, location: .stashed))
            }
        case let (.summary(summary), .composed):
            for tab in summary.composeTabs {
                body(ListedTab(tab, workspaceID: summary.workspaceID))
            }
        case let (.summary(summary), .stashed):
            for tab in summary.stashedTabs {
                body(ListedTab(tab, workspaceID: summary.workspaceID))
            }
        }
    }

    private func firstTab(_ tabID: UUID, at location: DomainWorkspaceTabLocation) -> ListedTab? {
        switch (self, location) {
        case let (.held(workspace), .composed):
            workspace.composeTabs.first { $0.id == tabID }
                .map { ListedTab($0, workspaceID: workspace.id, location: .composed) }
        case let (.held(workspace), .stashed):
            workspace.stashedTabs.first { $0.tab.id == tabID }
                .map { ListedTab($0.tab, workspaceID: workspace.id, location: .stashed) }
        case let (.summary(summary), .composed):
            summary.composeTabs.first { $0.tabID == tabID }
                .map { ListedTab($0, workspaceID: summary.workspaceID) }
        case let (.summary(summary), .stashed):
            summary.stashedTabs.first { $0.tabID == tabID }
                .map { ListedTab($0, workspaceID: summary.workspaceID) }
        }
    }
}

/// The compose and stashed tabs whose agent session reference one write changed.
struct AgentSessionReferenceWrite: Equatable {
    var composeTabIDs: Set<UUID> = []
    var stashedTabIDs: Set<UUID> = []

    var didChange: Bool {
        !composeTabIDs.isEmpty || !stashedTabIDs.isEmpty
    }
}

@MainActor
extension AgentModeViewModel {
    // MARK: - Listed tabs

    /// The workspace as Agent Mode lists it, or nil when this window lists no such workspace.
    func agentListedWorkspace(_ workspaceID: UUID) -> AgentListedWorkspace? {
        if let held = heldWorkspaceContent(workspaceID) {
            return .held(held)
        }
        return workspaceManager?.workspaceSummary(withID: workspaceID).map(AgentListedWorkspace.summary)
    }

    /// Every workspace this window lists, in catalog order: the store's summaries, with the window's
    /// own copy in place of a workspace it holds, then the held workspaces the store doesn't list,
    /// which are the window's own ephemeral workspaces and the shown workspace of a window built
    /// without a domain runtime.
    func agentListedCatalog() -> [AgentListedWorkspace] {
        guard let workspaceManager else { return [] }
        var listed: [AgentListedWorkspace] = []
        var listedIDs = Set<UUID>()
        for summary in workspaceManager.workspaceSummaries where listedIDs.insert(summary.workspaceID).inserted {
            listed.append(heldWorkspaceContent(summary.workspaceID).map(AgentListedWorkspace.held) ?? .summary(summary))
        }
        for workspace in workspaceManager.workspaces
            where workspaceManager.holdsWorkspaceContent(workspace.id) && listedIDs.insert(workspace.id).inserted
        {
            listed.append(.held(workspace))
        }
        return listed
    }

    /// The first tab with this ID that `predicate` accepts, searching the catalog in order, or only
    /// `workspaceID` when it is set. With `location` nil, a workspace's compose tab comes before its
    /// stashed one. This is the catalog-order search the manager's session lookups make, over
    /// listings instead of decoded tabs.
    func firstListedTab(
        _ tabID: UUID,
        location: DomainWorkspaceTabLocation? = nil,
        inWorkspaceID workspaceID: UUID? = nil,
        where predicate: (ListedTab) -> Bool = { _ in true }
    ) -> ListedTab? {
        let workspaces = if let workspaceID {
            agentListedWorkspace(workspaceID).map { [$0] } ?? []
        } else {
            agentListedCatalog()
        }
        for workspace in workspaces {
            if let tab = workspace.tab(tabID, location: location), predicate(tab) {
                return tab
            }
        }
        return nil
    }

    /// The agent session reference of the first workspace, in catalog order, that lists the tab,
    /// from its compose tab or else its stashed one.
    func listedAgentSessionID(forTabID tabID: UUID, inWorkspaceID workspaceID: UUID? = nil) -> UUID? {
        firstListedTab(tabID, inWorkspaceID: workspaceID)?.activeAgentSessionID
    }

    /// The exact identity of a compose tab named only by ID: the shown workspace's tab when the window
    /// shows one with this ID, and otherwise the one workspace that lists it. Nil when no workspace
    /// lists it, or when more than one other workspace does.
    func resolvedComposeTabIdentity(_ tabID: UUID) -> WorkspaceSelectionIdentity? {
        guard let workspaceManager else { return nil }
        if let shownID = workspaceManager.activeWorkspaceID {
            let shown = WorkspaceSelectionIdentity(workspaceID: shownID, tabID: tabID)
            if workspaceManager.contentGateway.shownComposeTab(shown) != nil {
                return shown
            }
        }
        guard case let .unique(identity, location: .composed) = workspaceManager.contentGateway
            .uniqueTabIdentity(tabID: tabID, includeStashed: false)
        else { return nil }
        return identity
    }

    /// The compose tab named only by ID, as this window lists it, by `resolvedComposeTabIdentity`'s
    /// rule.
    func resolvedListedComposeTab(_ tabID: UUID) -> ListedTab? {
        guard let identity = resolvedComposeTabIdentity(tabID) else { return nil }
        return workspaceManager?.contentGateway.listedTab(identity, location: .composed)
    }

    /// The shown workspace's stored compose tab with this ID.
    func shownComposeTab(_ tabID: UUID) -> ComposeTabState? {
        guard let workspaceManager, let shownID = workspaceManager.activeWorkspaceID else { return nil }
        return workspaceManager.contentGateway.shownComposeTab(
            WorkspaceSelectionIdentity(workspaceID: shownID, tabID: tabID)
        )
    }

    /// Whether the window holds the workspace's content itself: its shown workspace or one of its own
    /// ephemeral workspaces. Agent Mode edits held content in the window's copy at once.
    func holdsWorkspaceContent(_ workspaceID: UUID) -> Bool {
        heldWorkspaceContent(workspaceID) != nil
    }

    // MARK: - Session references in workspaces the window doesn't hold

    /// Sets the agent session reference to `replacement` on each tab of `tabIDs`, or on every tab
    /// when it is nil, whose reference is `expected`, in compose and stashed tabs of a workspace the
    /// window doesn't hold. It makes one fail-closed write of the workspace's canonical document, and
    /// the comparison runs on that document. The write runs in its own task, so cancelling the caller
    /// doesn't stop it, as cancelling couldn't stop an edit of the window's own copy. A failed write
    /// is reported as a workspace authority issue under `operation` and isn't retried.
    func compareAndSetUnheldAgentSessionReferences(
        inWorkspaceID workspaceID: UUID,
        tabIDs: Set<UUID>?,
        expected: UUID?,
        replacement: UUID?,
        operation: String
    ) async -> AgentSessionReferenceWrite {
        guard let workspaceManager else { return AgentSessionReferenceWrite() }
        let write = Task { @MainActor () -> AgentSessionReferenceWrite in
            var changed = AgentSessionReferenceWrite()
            do {
                _ = try await workspaceManager.contentGateway.mutateWorkspace(
                    workspaceID,
                    source: "agentMode.\(operation)",
                    persistence: .working
                ) { workspace in
                    changed = Self.compareAndSetAgentSessionReferences(
                        in: &workspace,
                        tabIDs: tabIDs,
                        expected: expected,
                        replacement: replacement
                    )
                }
                return changed
            } catch {
                Self.reportAgentSessionReferenceWriteFailure(
                    error,
                    workspaceID: workspaceID,
                    operation: operation,
                    workspaceManager: workspaceManager
                )
                return AgentSessionReferenceWrite()
            }
        }
        return await write.value
    }

    private static func compareAndSetAgentSessionReferences(
        in workspace: inout WorkspaceModel,
        tabIDs: Set<UUID>?,
        expected: UUID?,
        replacement: UUID?
    ) -> AgentSessionReferenceWrite {
        var changed = AgentSessionReferenceWrite()
        let now = Date()
        for index in workspace.composeTabs.indices
            where tabIDs?.contains(workspace.composeTabs[index].id) ?? true
            && workspace.composeTabs[index].activeAgentSessionID == expected
        {
            workspace.composeTabs[index].activeAgentSessionID = replacement
            workspace.composeTabs[index].lastModified = now
            changed.composeTabIDs.insert(workspace.composeTabs[index].id)
        }
        for index in workspace.stashedTabs.indices
            where tabIDs?.contains(workspace.stashedTabs[index].tab.id) ?? true
            && workspace.stashedTabs[index].tab.activeAgentSessionID == expected
        {
            workspace.stashedTabs[index].tab.activeAgentSessionID = replacement
            workspace.stashedTabs[index].tab.lastModified = now
            changed.stashedTabIDs.insert(workspace.stashedTabs[index].tab.id)
        }
        if changed.didChange {
            workspace.dateModified = now
        }
        return changed
    }

    private static func reportAgentSessionReferenceWriteFailure(
        _ error: Error,
        workspaceID: UUID,
        operation: String,
        workspaceManager: WorkspaceManagerViewModel
    ) {
        if let failure = error as? DomainWorkspaceAuthorityOperationError {
            workspaceManager.reportDomainAuthorityIssue(failure.outcome, operation: operation)
            return
        }
        if error is CancellationError {
            return
        }
        if let gatewayError = error as? WorkspaceContentGatewayError {
            switch gatewayError {
            case .decodeLostTabs, .gatewayClosed:
                // The gateway reported the lost tabs itself, and a closed window has no one to tell.
                return
            case .workspaceUnavailable, .tabUnavailable, .stateConflict, .saveRejected:
                break
            }
        }
        workspaceManager.reportDomainAuthorityIssue(
            workspaceID: workspaceID,
            operation: operation,
            diagnostic: error.localizedDescription
        )
    }

    // MARK: - Held content

    /// The window's own copy of a workspace it holds: its shown workspace or one of its own ephemeral
    /// workspaces.
    func heldWorkspaceContent(_ workspaceID: UUID) -> WorkspaceModel? {
        guard let workspaceManager, workspaceManager.holdsWorkspaceContent(workspaceID) else { return nil }
        return workspaceManager.workspace(withID: workspaceID)
    }
}
