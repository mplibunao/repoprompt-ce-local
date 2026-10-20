@testable import RepoPromptApp

/// A selection host double with one shown workspace and nothing else, so every tab it can
/// read or store is shown, and an offscreen read or commit fails as a missing tab would.
@MainActor
protocol ShownOnlySelectionHost: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel? { get set }
}

extension ShownOnlySelectionHost {
    func shownTabSelection(for identity: WorkspaceSelectionIdentity) -> StoredSelection? {
        guard activeWorkspace?.id == identity.workspaceID else { return nil }
        return activeWorkspace?.composeTabs.first { $0.id == identity.tabID }?.selection
    }

    @discardableResult
    func storeShownTabSelection(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        marksUnsaved _: Bool
    ) -> Bool {
        guard var workspace = activeWorkspace,
              workspace.id == identity.workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == identity.tabID })
        else { return false }
        workspace.composeTabs[index].selection = selection
        activeWorkspace = workspace
        return true
    }

    func readTabSelection(for identity: WorkspaceSelectionIdentity) async throws -> StoredSelection {
        guard let selection = shownTabSelection(for: identity) else {
            throw WorkspaceContentGatewayError.tabUnavailable(identity)
        }
        return selection
    }

    func commitTabSelection(
        for identity: WorkspaceSelectionIdentity,
        mirrorToUIIfActive _: Bool,
        presentsCanonicalWrite _: Bool,
        didStore _: @escaping @MainActor (StoredSelection, UInt64?) -> Void,
        _: (StoredSelection) throws -> StoredSelection
    ) async throws -> (before: StoredSelection, after: StoredSelection) {
        throw WorkspaceContentGatewayError.tabUnavailable(identity)
    }
}
