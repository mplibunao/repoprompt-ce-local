import Foundation
import RepoPromptDomainRuntime

/// The window's catalog as listings without tab content: the store's summaries, and the window's
/// own copy of each workspace the summaries don't list yet, such as its temporary workspaces and a
/// workspace it created that the store hasn't published.
extension WorkspaceManagerViewModel {
    /// The ID of every workspace the window's catalog lists.
    var listedWorkspaceIDs: Set<UUID> {
        Set(workspaceSummaries.map(\.workspaceID)).union(workspaces.map(\.id))
    }

    /// Every workspace the window's catalog lists. A workspace the window holds is listed from its
    /// own copy, and any other from its summary.
    func listedWorkspaceCatalog() -> [ListedWorkspace] {
        var listedIDs = Set<UUID>()
        var listed: [ListedWorkspace] = []
        for summary in workspaceSummaries where listedIDs.insert(summary.workspaceID).inserted {
            listed.append(contentGateway.listedWorkspace(summary.workspaceID) ?? ListedWorkspace(summary))
        }
        for workspace in workspaces where listedIDs.insert(workspace.id).inserted {
            listed.append(ListedWorkspace(workspace))
        }
        return listed
    }

    /// The workspace as `listedWorkspaceCatalog()` lists it, or nil when the catalog doesn't list it.
    func listedWorkspace(withID workspaceID: UUID) -> ListedWorkspace? {
        contentGateway.listedWorkspace(workspaceID) ?? workspace(withID: workspaceID).map { ListedWorkspace($0) }
    }

    /// The workspace's compose tabs, then its stashed tabs, as the window lists them: from its own
    /// copy when it shows the workspace, holds it as a temporary workspace, or has no summary of
    /// it, and from the summary otherwise. Empty when the catalog doesn't list the workspace.
    func listedTabs(inWorkspace workspaceID: UUID) -> [ListedTab] {
        let summary = workspaceSummary(withID: workspaceID)
        if let copy = workspace(withID: workspaceID),
           activeWorkspaceID == workspaceID || copy.isEphemeral || summary == nil
        {
            return copy.composeTabs.map { ListedTab($0, workspaceID: workspaceID, location: .composed) }
                + copy.stashedTabs.map { ListedTab($0.tab, workspaceID: workspaceID, location: .stashed) }
        }
        guard let summary else { return [] }
        return (summary.composeTabs + summary.stashedTabs).map { ListedTab($0, workspaceID: workspaceID) }
    }
}
