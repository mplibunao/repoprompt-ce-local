import Foundation
import RepoPromptDomainRuntime

/// How a gateway write leaves this window.
enum WorkspaceContentPersistence: Equatable {
    /// At most one accepted working-document commit.
    case working
    /// The working-document commit, then the separate saved-document phase.
    case saved
}

/// What one gateway write did. No receipt carries a catalog.
enum WorkspaceContentWriteReceipt: Equatable {
    /// The authority accepted the document at these revisions and digest. `changedTabIDs` lists the
    /// compose and stashed tabs the write added, removed, or changed.
    case committed(revisions: DomainRevisionState, digest: String, changedTabIDs: Set<UUID>)
    /// The edit changed content this window holds itself: its shown workspace, whose debounced
    /// working-state publish carries the edit, or one of its own ephemeral workspaces, which never
    /// persist.
    case pendingLocal(stateVersion: Int, selectionRevision: UInt64?)
}

/// A compose-tab write and the tab as the write left it.
struct WorkspaceComposeTabWrite: Equatable {
    let receipt: WorkspaceContentWriteReceipt
    let tab: ComposeTabState
    /// For a canonical write, the selection revision the window gave the tab when its projection
    /// installed the write's accepted revision. A canonical edit that doesn't change the document
    /// has the one from the install of the revision it read. An edit of the window's copy has none.
    /// Neither does a canonical write whose install the gateway can't identify. The window may not
    /// have installed that revision yet, or a later install of the workspace may have replaced it.
    var projectedSelectionRevision: UInt64?
}

/// A workspace as this window lists it: from the window's own copy when the window holds the
/// workspace, and from the store's summary otherwise. It has no tab content.
struct ListedWorkspace: Equatable {
    let workspaceID: UUID
    let name: String
    let repoPaths: [String]
    let customStoragePath: URL?
    let isSystemWorkspace: Bool
    let isHiddenInMenus: Bool
    let isEphemeral: Bool
    let consolidatedIntoWorkspaceID: UUID?
    let activeTabID: UUID?
    let lastUsed: Date
    let dateModified: Date

    init(_ workspace: WorkspaceModel) {
        workspaceID = workspace.id
        name = workspace.name
        repoPaths = workspace.repoPaths
        customStoragePath = workspace.customStoragePath
        isSystemWorkspace = workspace.isSystemWorkspace
        isHiddenInMenus = workspace.isHiddenInMenus
        isEphemeral = workspace.isEphemeral
        consolidatedIntoWorkspaceID = workspace.consolidatedIntoWorkspaceID
        activeTabID = workspace.activeComposeTabID
        lastUsed = workspace.lastUsed
        dateModified = workspace.dateModified
    }

    /// `isHiddenInMenus` replaces the summary's flag for a listing that hides more than the
    /// document does.
    init(_ summary: DomainWorkspaceSummary, isHiddenInMenus: Bool? = nil) {
        workspaceID = summary.workspaceID
        name = summary.name
        repoPaths = summary.repoPaths
        customStoragePath = summary.customStoragePath
        isSystemWorkspace = summary.isSystemWorkspace
        self.isHiddenInMenus = isHiddenInMenus ?? summary.isHiddenInMenus
        isEphemeral = summary.isEphemeral
        consolidatedIntoWorkspaceID = summary.consolidatedIntoWorkspaceID
        activeTabID = summary.activeContextID
        lastUsed = summary.lastUsed
        dateModified = summary.dateModified
    }
}

/// A compose or stashed tab as this window lists it, by the rule `ListedWorkspace` follows.
struct ListedTab: Equatable {
    let identity: WorkspaceSelectionIdentity
    let location: DomainWorkspaceTabLocation
    let name: String
    let activeAgentSessionID: UUID?
    let activeChatSessionID: UUID?
    let isPinned: Bool

    init(_ tab: ComposeTabState, workspaceID: UUID, location: DomainWorkspaceTabLocation) {
        identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tab.id)
        self.location = location
        name = tab.name
        activeAgentSessionID = tab.activeAgentSessionID
        activeChatSessionID = tab.activeChatSessionID
        isPinned = tab.isPinned
    }

    init(_ summary: DomainTabSummary, workspaceID: UUID) {
        identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: summary.tabID)
        location = summary.location
        name = summary.name
        activeAgentSessionID = summary.activeAgentSessionID
        activeChatSessionID = summary.activeChatSessionID
        isPinned = summary.isPinned
    }
}

/// A tab ID looked up across the summary catalog.
enum WorkspaceTabIdentityResolution: Equatable {
    case unique(WorkspaceSelectionIdentity, location: DomainWorkspaceTabLocation)
    /// More than one workspace lists the tab ID, so the caller has to name the workspace.
    case ambiguous([WorkspaceSelectionIdentity])
    case notFound
}

/// Which document an edit changes.
enum WorkspaceContentEditTarget: Equatable {
    /// The window's own copy, for content it holds: its shown workspace or its own ephemeral one.
    case windowCopy
    /// The canonical document, decoded for this edit, for a workspace the window doesn't hold.
    case canonicalDocument
}

enum WorkspaceContentGatewayError: LocalizedError, Equatable {
    case workspaceUnavailable(UUID)
    case tabUnavailable(WorkspaceSelectionIdentity)
    /// The app decode of the canonical document doesn't contain every tab its summary lists, so
    /// writing the decoded model back would rewrite the document's saved tabs.
    case decodeLostTabs(workspaceID: UUID, tabIDs: Set<UUID>)
    /// The document changed again while it was being read, or legacy storage changed before a write.
    case stateConflict(UUID)
    /// The shown workspace's save refused the edit, which stays in the window's copy.
    case saveRejected(WorkspacePersistenceRejection)
    /// The window closed while the operation was in flight.
    case gatewayClosed

    static let decodeLostTabsDiagnostic = "workspace_decode_lost_tabs"

    var errorDescription: String? {
        switch self {
        case let .workspaceUnavailable(workspaceID):
            "[workspace_unavailable] Workspace \(workspaceID.uuidString) is not available."
        case let .tabUnavailable(identity):
            "[workspace_unavailable] Tab \(identity.tabID.uuidString) is not in workspace \(identity.workspaceID.uuidString)."
        case let .decodeLostTabs(workspaceID, tabIDs):
            "[\(Self.decodeLostTabsDiagnostic)] Workspace \(workspaceID.uuidString) doesn't decode with all \(tabIDs.count) of its listed tabs, so it can't be edited until it is shown and repaired."
        case let .stateConflict(workspaceID):
            "[state_conflict] Workspace \(workspaceID.uuidString) changed during the operation."
        case let .saveRejected(rejection):
            "[\(rejection.reason)] The workspace's save was refused."
        case .gatewayClosed:
            "[cancelled] The window closed before the workspace operation finished."
        }
    }
}

/// A workspace document as storage holds it, with the summary of those exact bytes.
struct WorkspaceContentDocument {
    let summary: DomainWorkspaceSummary
    let documentBytes: Data

    init(summary: DomainWorkspaceSummary, documentBytes: Data) {
        self.summary = summary
        self.documentBytes = documentBytes
    }

    init(snapshot: DomainWorkspaceSnapshot) {
        summary = snapshot.summary
        documentBytes = snapshot.document.documentBytes
    }
}

/// The result of submitting one complete document.
struct WorkspaceContentCommitResult {
    /// Accepted authority outcomes in phase order. Empty for legacy storage.
    var acceptedOutcomes: [DomainCommandOutcome] = []
    /// The durable state after the last accepted phase; nil when no phase was accepted.
    var accepted: (revisions: DomainRevisionState, digest: String)?
    /// Why the first rejected phase failed; nil when every requested phase was accepted.
    var failure: Error?

    /// Interprets authority outcomes in phase order: each accepted phase advances the durable state,
    /// and the first rejection ends the commit. A rejected save after an accepted working commit
    /// leaves that working commit in place.
    init(phases: [DomainCommandOutcome]) {
        for outcome in phases {
            guard outcome.isSuccessfulDomainMutation,
                  let revisions = outcome.workspace?.revisions ?? outcome.after,
                  let digest = outcome.workspace?.document.contentDigest ?? outcome.resultingDigest
            else {
                failure = DomainWorkspaceAuthorityOperationError(
                    outcome: outcome,
                    workingCommitted: accepted != nil
                )
                return
            }
            acceptedOutcomes.append(outcome)
            accepted = (revisions, digest)
        }
    }

    init(accepted: (revisions: DomainRevisionState, digest: String)?, failure: Error?) {
        self.accepted = accepted
        self.failure = failure
    }
}

/// Where the gateway reads canonical documents and submits complete ones.
@MainActor
protocol WorkspaceContentBackend: AnyObject {
    /// The persisted command-authority document, never a read registration.
    func canonicalDocument(for workspaceID: UUID) async -> WorkspaceContentDocument?
    /// A read registration, which only an ephemeral workspace another window owns relies on.
    func readOverlayDocument(for workspaceID: UUID) async -> WorkspaceContentDocument?
    /// Submits `workspace` at the exact canonical working revision and digest, failing closed when
    /// another writer advanced the document.
    func commit(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedRevision: UInt64,
        expectedDigest: String,
        persistence: WorkspaceContentPersistence
    ) async -> WorkspaceContentCommitResult
    /// Saves the canonical working document at exactly `expectedRevision` without submitting a
    /// document, failing closed when another writer advanced it.
    func saveWorkingDocument(of workspaceID: UUID, expectedRevision: UInt64) async -> WorkspaceContentCommitResult
}

/// The production backend: the runtime's revisioned workspace authority.
@MainActor
final class DomainWorkspaceContentBackend: WorkspaceContentBackend {
    private let client: DomainWorkspaceAuthorityClient

    init(client: DomainWorkspaceAuthorityClient) {
        self.client = client
    }

    func canonicalDocument(for workspaceID: UUID) async -> WorkspaceContentDocument? {
        await client.canonicalWorkspaceSnapshot(workspaceID).map(WorkspaceContentDocument.init(snapshot:))
    }

    func readOverlayDocument(for workspaceID: UUID) async -> WorkspaceContentDocument? {
        await client.workspaceSnapshot(workspaceID).map(WorkspaceContentDocument.init(snapshot:))
    }

    func commit(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedRevision: UInt64,
        expectedDigest: String,
        persistence: WorkspaceContentPersistence
    ) async -> WorkspaceContentCommitResult {
        do {
            switch persistence {
            case .working:
                let outcome = try await client.replaceWorking(
                    workspace,
                    fileURL: fileURL,
                    expectedWorkspaceRevision: expectedRevision,
                    conflictRecoveryPolicy: .failClosed
                )
                return WorkspaceContentCommitResult(phases: [outcome])
            case .saved:
                let phased = try await client.saveFailClosed(
                    workspace,
                    fileURL: fileURL,
                    expectedWorkspaceRevision: expectedRevision,
                    expectedContentDigest: expectedDigest
                )
                return WorkspaceContentCommitResult(phases: [phased.working, phased.saved].compactMap(\.self))
            }
        } catch {
            // Encoding the document failed, so nothing reached the authority.
            return WorkspaceContentCommitResult(accepted: nil, failure: error)
        }
    }

    func saveWorkingDocument(of workspaceID: UUID, expectedRevision: UInt64) async -> WorkspaceContentCommitResult {
        await WorkspaceContentCommitResult(phases: [
            client.saveWorkingDocument(workspaceID, expectedWorkspaceRevision: expectedRevision)
        ])
    }
}

/// The isolated legacy owner's configured storage, for a manager built without an authority
/// client. It reads only under the manager's storage root and has no production disk fallback.
@MainActor
final class LegacyWorkspaceContentBackend: WorkspaceContentBackend {
    private weak var manager: WorkspaceManagerViewModel?

    init(manager: WorkspaceManagerViewModel) {
        self.manager = manager
    }

    func canonicalDocument(for workspaceID: UUID) async -> WorkspaceContentDocument? {
        guard let manager,
              let workspace = manager.workspace(withID: workspaceID),
              !workspace.isEphemeral
        else { return nil }
        let fileURL = manager.workspaceFileURL(for: workspace)
        let root = manager.effectiveWorkspaceStorageRoot
        // Without the flush, a save still queued for this file leaves the read with the older bytes.
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: fileURL)
        return await Task.detached(priority: .utility) {
            guard (try? WorkspaceStoragePaths.requireProfileLocation(fileURL, within: root)) != nil,
                  let bytes = try? Data(contentsOf: fileURL),
                  let document = try? DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL),
                  document.workspaceID == workspaceID
            else { return nil }
            return WorkspaceContentDocument(
                summary: DomainWorkspaceSummary(document: document, revisions: .initial, health: .writable),
                documentBytes: bytes
            )
        }.value
    }

    func readOverlayDocument(for _: UUID) async -> WorkspaceContentDocument? {
        nil
    }

    /// Legacy storage is its saved file. Its documents are never ahead of a save, so the gateway
    /// doesn't call this.
    func saveWorkingDocument(of workspaceID: UUID, expectedRevision _: UInt64) async -> WorkspaceContentCommitResult {
        WorkspaceContentCommitResult(accepted: nil, failure: WorkspaceContentGatewayError.workspaceUnavailable(workspaceID))
    }

    func commit(
        _ workspace: WorkspaceModel,
        fileURL: URL,
        expectedRevision _: UInt64,
        expectedDigest: String,
        persistence _: WorkspaceContentPersistence
    ) async -> WorkspaceContentCommitResult {
        guard let manager else {
            return WorkspaceContentCommitResult(accepted: nil, failure: WorkspaceContentGatewayError.gatewayClosed)
        }
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: fileURL)
        let currentDigest = await Self.digest(of: fileURL)
        guard currentDigest == expectedDigest else {
            return WorkspaceContentCommitResult(
                accepted: nil,
                failure: WorkspaceContentGatewayError.stateConflict(workspace.id)
            )
        }
        do {
            let writtenURL = try await manager.saveWorkspaceToFileAsync(
                workspace,
                baseRoot: manager.effectiveWorkspaceStorageRoot
            )
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: writtenURL)
            guard let digest = await Self.digest(of: writtenURL) else {
                return WorkspaceContentCommitResult(
                    accepted: nil,
                    failure: WorkspaceContentGatewayError.workspaceUnavailable(workspace.id)
                )
            }
            // Without a projection, the backend installs its own commit in the manager's copy.
            manager.contentGatewayInstallLegacyCommit(workspace)
            return WorkspaceContentCommitResult(accepted: (.initial, digest), failure: nil)
        } catch {
            return WorkspaceContentCommitResult(accepted: nil, failure: error)
        }
    }

    private static func digest(of fileURL: URL) async -> String? {
        await Task.detached(priority: .utility) {
            (try? Data(contentsOf: fileURL)).map(DomainContentDigest.sha256)
        }.value
    }
}

/// The one exact-identity reader and writer of workspace content for a window. Content the window
/// holds itself is its shown workspace and its own ephemeral workspaces. A read of any other
/// workspace loads its canonical document and decodes it for that operation only. A write to one
/// decodes the canonical document, applies the edit, and submits the whole document at the
/// canonical revision, failing closed.
@MainActor
final class WorkspaceContentGateway {
    private weak var manager: WorkspaceManagerViewModel?
    private let backend: any WorkspaceContentBackend
    private var isInvalidated = false
    /// Operations waiting out a workspace switch, by wait token.
    private var switchWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    #if DEBUG
        private var loadSnapshot = WorkspaceContentLoadSnapshot()
        /// Runs before a commit submits its document, so a test can change what the window shows
        /// while the write is in flight.
        var commitSubmissionWillBeginHandlerForTesting: (@MainActor (_ workspaceID: UUID) async -> Void)?
        /// Runs after the authority answered a commit and before the gateway reports the answer, so
        /// a test can deliver a later commit's result first.
        var commitResultWillReturnHandlerForTesting: (@MainActor (_ workspaceID: UUID) async -> Void)?
        /// Runs before an operation's canonical read, with the operation's source label, so a test
        /// can pause one operation's load.
        var canonicalReadWillBeginHandlerForTesting: (@MainActor (_ workspaceID: UUID, _ source: String) async -> Void)?
    #endif

    init(manager: WorkspaceManagerViewModel, backend: any WorkspaceContentBackend) {
        self.manager = manager
        self.backend = backend
    }

    /// Ends the gateway with its window: operations in flight stop before their next edit, and one
    /// waiting out a workspace switch stops waiting.
    func invalidate() {
        isInvalidated = true
        let waiters = switchWaiters.values
        switchWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Summary lookups

    func workspaceSummary(_ workspaceID: UUID) -> DomainWorkspaceSummary? {
        manager?.workspaceSummary(withID: workspaceID)
    }

    /// The tab's summary at `location`, or in either location when `location` is nil.
    func tabSummary(
        _ identity: WorkspaceSelectionIdentity,
        location: DomainWorkspaceTabLocation? = nil
    ) -> DomainTabSummary? {
        guard let summary = workspaceSummary(identity.workspaceID) else { return nil }
        let composed = summary.composeTabs.first { $0.tabID == identity.tabID }
        let stashed = summary.stashedTabs.first { $0.tabID == identity.tabID }
        return switch location {
        case .composed: composed
        case .stashed: stashed
        case nil: composed ?? stashed
        }
    }

    /// The workspace as this window lists it. The window's own copy of a workspace it holds can list
    /// a tab its summary doesn't yet, because the shown workspace's edits publish on a debounce.
    func listedWorkspace(_ workspaceID: UUID) -> ListedWorkspace? {
        if let held = heldWorkspace(workspaceID) {
            return ListedWorkspace(held)
        }
        return workspaceSummary(workspaceID).map { ListedWorkspace($0) }
    }

    /// The tab as this window lists it, at `location`, or in either location when `location` is nil.
    func listedTab(
        _ identity: WorkspaceSelectionIdentity,
        location: DomainWorkspaceTabLocation? = .composed
    ) -> ListedTab? {
        if let held = heldWorkspace(identity.workspaceID) {
            let composed = held.composeTabs.first { $0.id == identity.tabID }
                .map { ListedTab($0, workspaceID: held.id, location: .composed) }
            let stashed = held.stashedTabs.first { $0.tab.id == identity.tabID }
                .map { ListedTab($0.tab, workspaceID: held.id, location: .stashed) }
            return switch location {
            case .composed: composed
            case .stashed: stashed
            case nil: composed ?? stashed
            }
        }
        return tabSummary(identity, location: location).map { ListedTab($0, workspaceID: identity.workspaceID) }
    }

    /// Resolves a bare tab ID across the catalog, reading the window's own copy of each workspace it
    /// holds. A tab ID that more than one workspace lists is ambiguous, whatever the catalog order.
    func uniqueTabIdentity(tabID: UUID, includeStashed: Bool) -> WorkspaceTabIdentityResolution {
        var matches: [(identity: WorkspaceSelectionIdentity, location: DomainWorkspaceTabLocation)] = []
        let held = heldWorkspaces()
        for workspace in held {
            let identity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID)
            if workspace.composeTabs.contains(where: { $0.id == tabID }) {
                matches.append((identity, .composed))
            } else if includeStashed, workspace.stashedTabs.contains(where: { $0.tab.id == tabID }) {
                matches.append((identity, .stashed))
            }
        }
        let heldIDs = Set(held.map(\.id))
        for summary in manager?.workspaceSummaries ?? [] where !heldIDs.contains(summary.workspaceID) {
            let identity = WorkspaceSelectionIdentity(workspaceID: summary.workspaceID, tabID: tabID)
            if summary.composeTabs.contains(where: { $0.tabID == tabID }) {
                matches.append((identity, .composed))
            } else if includeStashed, summary.stashedTabs.contains(where: { $0.tabID == tabID }) {
                matches.append((identity, .stashed))
            }
        }
        switch matches.count {
        case 0:
            return .notFound
        case 1:
            return .unique(matches[0].identity, location: matches[0].location)
        default:
            return .ambiguous(matches.map(\.identity))
        }
    }

    // MARK: - Shown content

    /// The stored tab of the shown workspace, for UI paths that only act on what the window shows.
    func shownComposeTab(_ identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        guard let manager, manager.activeWorkspaceID == identity.workspaceID else { return nil }
        return manager.workspace(withID: identity.workspaceID)?
            .composeTabs.first { $0.id == identity.tabID }
    }

    // MARK: - Reads

    /// The workspace's content for one operation. Content the window holds comes back with its
    /// unsaved edits, and with the active tab's live UI state when `capturingLiveUIState` is set;
    /// anything else is decoded from its canonical document and never installed in the window.
    func readWorkspaceContent(
        _ workspaceID: UUID,
        source: String,
        capturingLiveUIState: Bool = true
    ) async throws -> WorkspaceModel {
        if let local = try localContent(workspaceID, capturingLiveUIState: capturingLiveUIState) {
            return local
        }
        let model = try await readContentNotHeldLocally(workspaceID, source: source)
        if let local = try localContent(workspaceID, capturingLiveUIState: capturingLiveUIState) {
            // The window started showing the workspace during the read; its copy is the newest.
            return local
        }
        return model
    }

    func readComposeTab(
        _ identity: WorkspaceSelectionIdentity,
        source: String,
        capturingLiveUIState: Bool = true
    ) async throws -> ComposeTabState {
        let workspace = try await readWorkspaceContent(
            identity.workspaceID,
            source: source,
            capturingLiveUIState: capturingLiveUIState
        )
        guard let tab = workspace.composeTabs.first(where: { $0.id == identity.tabID }) else {
            throw WorkspaceContentGatewayError.tabUnavailable(identity)
        }
        return tab
    }

    // MARK: - Writes

    /// Applies `edit` to the workspace. Content the window holds is edited in place and the receipt
    /// is `.pendingLocal`, except that `.saved` on the shown workspace also awaits its save and
    /// returns `.committed`. Any other workspace is decoded from its canonical document, refused if
    /// that decode lost a listed tab, edited, and submitted whole at the canonical revision.
    ///
    /// On the shown workspace the edit sees the active tab's live UI state, and the prompt UI then
    /// shows the edited active tab. An edit to the copy or chat preset, the copy customizations, or
    /// a meta prompt selection doesn't last there: the gateway doesn't apply those to the UI, and
    /// the next save capture copies them from it.
    ///
    /// While a switch can change whether the window shows the workspace, in the span
    /// `WorkspaceManagerViewModel.contentGatewayShownStateIsChanging(_:)` defines, the edit waits.
    /// It then edits the window's copy if the window still holds the workspace, and the canonical
    /// document if not. Cancellation and the window closing end the wait. An edit before that span
    /// goes to the shown copy, and a switch with `saveState` off leaves it unpublished there.
    ///
    /// A step of the switch calling this for the workspace being switched would wait on itself.
    /// The switch's own flush of the shown workspace's working state must therefore not use this
    /// method or `mutateComposeTab`.
    ///
    /// `validation` runs on the main actor right before `edit`, after the read's last suspension.
    /// An ownership check there sees the state the gateway dispatches the write from.
    func mutateWorkspace(
        _ workspaceID: UUID,
        source: String,
        persistence: WorkspaceContentPersistence,
        validation: @MainActor () throws -> Void = {},
        edit: (inout WorkspaceModel) throws -> Void
    ) async throws -> WorkspaceContentWriteReceipt {
        try await mutate(
            workspaceID,
            selectionTabID: nil,
            source: source,
            persistence: persistence,
            mirrorsShownEdit: true,
            presentsCanonicalWrite: true,
            validation: validation,
            didStore: nil
        ) { workspace, _ in
            try edit(&workspace)
        }.receipt
    }

    /// Applies `edit` to one compose tab, through `mutateWorkspace`'s rules. A tab the edit changes
    /// gets a new `lastModified`, and its workspace a new `dateModified`.
    ///
    /// `didStore` gets the tab as stored, in the main-actor turn that stores it: right after the
    /// window's copy takes the edit, or when the authority's answer arrives. That turn is the
    /// write's place in the window's order. It precedes any UI mirror, save, or projection wait,
    /// so a caller can report the write before work that can suspend. Its `acceptedRevision` is the
    /// working revision the authority accepted a canonical write at, and nil for an edit of the
    /// window's copy. A canonical write returns once the window's projection has installed that
    /// revision, so the window's copy and its selection revisions include the write. When a
    /// canonical edit doesn't change the document, the gateway doesn't send a command. Its
    /// `acceptedRevision` is then the revision the edit read, and it returns without waiting for the
    /// projection.
    ///
    /// Unless `mirrorsShownEdit` is false, the prompt UI and file tree show an edit the shown
    /// workspace takes. With it false, only the tab presentation follows, and UI snapshots queued
    /// before the edit can't revert a selection it changed.
    ///
    /// The window can start showing the workspace while a canonical write is in flight. The write
    /// then returns once the window presents it the same way, unless `presentsCanonicalWrite` is
    /// false. A caller that presents its canonical write by another path passes false.
    func mutateComposeTab(
        _ identity: WorkspaceSelectionIdentity,
        source: String,
        persistence: WorkspaceContentPersistence,
        mirrorsShownEdit: Bool = true,
        presentsCanonicalWrite: Bool = true,
        validation: @MainActor () throws -> Void = {},
        didStore: (@MainActor (ComposeTabState, _ acceptedRevision: UInt64?) -> Void)? = nil,
        edit: (inout ComposeTabState) throws -> Void
    ) async throws -> WorkspaceComposeTabWrite {
        try await mutateComposeTab(
            identity,
            source: source,
            persistence: persistence,
            mirrorsShownEdit: mirrorsShownEdit,
            presentsCanonicalWrite: presentsCanonicalWrite,
            validation: validation,
            didStore: didStore
        ) { tab, _ in
            try edit(&tab)
        }
    }

    /// `mutateComposeTab`, with an edit that learns which document it changes.
    func mutateComposeTab(
        _ identity: WorkspaceSelectionIdentity,
        source: String,
        persistence: WorkspaceContentPersistence,
        mirrorsShownEdit: Bool = true,
        presentsCanonicalWrite: Bool = true,
        validation: @MainActor () throws -> Void = {},
        didStore: (@MainActor (ComposeTabState, _ acceptedRevision: UInt64?) -> Void)? = nil,
        edit: (inout ComposeTabState, WorkspaceContentEditTarget) throws -> Void
    ) async throws -> WorkspaceComposeTabWrite {
        var editedTab: ComposeTabState?
        let write = try await mutate(
            identity.workspaceID,
            selectionTabID: identity.tabID,
            source: source,
            persistence: persistence,
            mirrorsShownEdit: mirrorsShownEdit,
            presentsCanonicalWrite: presentsCanonicalWrite,
            validation: validation,
            didStore: didStore.map { report in
                { workspace, acceptedRevision in
                    if let tab = workspace.composeTabs.first(where: { $0.id == identity.tabID }) {
                        report(tab, acceptedRevision)
                    }
                }
            }
        ) { workspace, target in
            guard let index = workspace.composeTabs.firstIndex(where: { $0.id == identity.tabID }) else {
                throw WorkspaceContentGatewayError.tabUnavailable(identity)
            }
            var tab = workspace.composeTabs[index]
            let original = tab
            try edit(&tab, target)
            if tab != original {
                let now = Date()
                tab.lastModified = now
                workspace.composeTabs[index] = tab
                workspace.dateModified = now
            }
            editedTab = tab
        }
        guard let editedTab else { throw WorkspaceContentGatewayError.tabUnavailable(identity) }
        return WorkspaceComposeTabWrite(
            receipt: write.receipt,
            tab: editedTab,
            projectedSelectionRevision: write.projectedInstall?.selectionRevisionByTabID[identity.tabID]
        )
    }

    /// Submits a complete document the caller already holds, for cleanup and recovery that rebuild
    /// a whole workspace. `expectedRevision` and `expectedDigest` must come from a canonical
    /// snapshot, never a read registration. It skips the tab-loss check, because those callers
    /// remove tabs on purpose, and always commits canonically, even for the shown workspace.
    func commitExactWorkspaceDocument(
        _ workspace: WorkspaceModel,
        expectedRevision: UInt64,
        expectedDigest: String,
        persistence: WorkspaceContentPersistence
    ) async throws -> WorkspaceContentWriteReceipt {
        guard let manager, !isInvalidated else { throw WorkspaceContentGatewayError.gatewayClosed }
        guard !workspace.isEphemeral, manager.contentGatewayCatalogContains(workspace.id) else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspace.id)
        }
        let fileURL = workspaceSummary(workspace.id)?.fileURL ?? manager.workspaceFileURL(for: workspace)
        let previous = manager.workspace(withID: workspace.id)
        try Task.checkCancellation()
        // The window's copy takes the document when the bridge projects it, as a remote write's.
        return try await commit(
            workspace,
            changedTabIDs: previous.map { Self.changedTabIDs(from: $0, to: workspace) }
                ?? Self.tabIDs(of: workspace),
            fileURL: fileURL,
            expectedRevision: expectedRevision,
            expectedDigest: expectedDigest,
            persistence: persistence,
            didStore: nil
        ).receipt
    }

    // MARK: - Internals

    /// A write's receipt. A canonical write also has the window projection's install of the
    /// workspace at exactly the write's accepted revision, when the gateway can identify it.
    private struct Write {
        let receipt: WorkspaceContentWriteReceipt
        var projectedInstall: ProjectedWorkspaceInstall?
    }

    private func mutate(
        _ workspaceID: UUID,
        selectionTabID: UUID?,
        source: String,
        persistence: WorkspaceContentPersistence,
        mirrorsShownEdit: Bool,
        presentsCanonicalWrite: Bool,
        validation: @MainActor () throws -> Void,
        didStore: (@MainActor (WorkspaceModel, _ acceptedRevision: UInt64?) -> Void)?,
        edit: (inout WorkspaceModel, WorkspaceContentEditTarget) throws -> Void
    ) async throws -> Write {
        guard manager != nil, !isInvalidated else { throw WorkspaceContentGatewayError.gatewayClosed }
        if let receipt = try await mutateLocalIfHeld(
            workspaceID,
            selectionTabID: selectionTabID,
            source: source,
            persistence: persistence,
            mirrorsShownEdit: mirrorsShownEdit,
            validation: validation,
            didStore: didStore,
            edit: edit
        ) {
            return Write(receipt: receipt)
        }

        // A write's baseline is the canonical document, never a read registration.
        guard let document = await operationCanonicalDocument(workspaceID, source: source) else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID)
        }
        recordLoad(workspaceID, source: source)
        let baseline = try await decode(document, source: source)

        let mismatchedTabIDs = Self.tabIDsMismatchedByDecode(summary: document.summary, decoded: baseline)
        guard mismatchedTabIDs.isEmpty else {
            manager?.reportDomainAuthorityIssue(
                workspaceID: workspaceID,
                operation: "content_gateway_\(source)",
                diagnostic: WorkspaceContentGatewayError.decodeLostTabsDiagnostic
            )
            throw WorkspaceContentGatewayError.decodeLostTabs(workspaceID: workspaceID, tabIDs: mismatchedTabIDs)
        }

        // The window can start showing the workspace during the read. Its copy can carry edits the
        // canonical document lacks, and the edit then goes to that copy.
        if let receipt = try await mutateLocalIfHeld(
            workspaceID,
            selectionTabID: selectionTabID,
            source: source,
            persistence: persistence,
            mirrorsShownEdit: mirrorsShownEdit,
            validation: validation,
            didStore: didStore,
            edit: edit
        ) {
            return Write(receipt: receipt)
        }

        try validation()
        var edited = baseline
        try edit(&edited, .canonicalDocument)
        guard edited != baseline else {
            let readRevision = document.summary.revisions.workingRevision
            // A saved edit still owes the save when the working document already has its change,
            // as it does on a retry after a save whose working phase landed and saved phase failed.
            // Only the save command goes, at the revision read. It leaves the working document unchanged.
            if persistence == .saved, document.summary.revisions.dirtyRevision != nil {
                try Task.checkCancellation()
                return try await submit(baseline, changedTabIDs: [], didStore: didStore) {
                    await backend.saveWorkingDocument(of: workspaceID, expectedRevision: readRevision)
                }
            }
            // Otherwise a no-op edit doesn't send a command and leaves the parked document's bytes
            // as they are. It reports the revision it read, and the projection's install at exactly
            // that revision when the window has one.
            didStore?(baseline, readRevision)
            return Write(
                receipt: .committed(
                    revisions: document.summary.revisions,
                    digest: document.summary.contentDigest,
                    changedTabIDs: []
                ),
                projectedInstall: manager?.projectedInstall(of: workspaceID, exactly: readRevision)
            )
        }
        try Task.checkCancellation()
        let write = try await commit(
            edited,
            changedTabIDs: Self.changedTabIDs(from: baseline, to: edited),
            fileURL: document.summary.fileURL,
            expectedRevision: document.summary.revisions.workingRevision,
            expectedDigest: document.summary.contentDigest,
            persistence: persistence,
            didStore: didStore
        )
        if presentsCanonicalWrite {
            await presentCanonicalWriteIfShown(
                from: baseline,
                to: edited,
                mirrorsShownEdit: mirrorsShownEdit,
                validation: validation
            )
        }
        return write
    }

    /// A window that started showing the workspace while the write was in flight shows the state its
    /// switch loaded. The next capture of its UI would store that state over the write. Once any
    /// switch involving the workspace ends, a window that shows the workspace presents the write, if
    /// the write's `validation` still passes. A cancelled caller skips the presentation, as it skips
    /// a local edit's.
    private func presentCanonicalWriteIfShown(
        from baseline: WorkspaceModel,
        to accepted: WorkspaceModel,
        mirrorsShownEdit: Bool,
        validation: @MainActor () throws -> Void
    ) async {
        do {
            try await awaitShownStateSettled(accepted.id)
        } catch {
            return
        }
        guard let manager, manager.activeWorkspaceID == accepted.id, (try? validation()) != nil else { return }
        await manager.contentGatewayPresentAcceptedEdit(
            from: baseline,
            to: accepted,
            mirrorsShownEdit: mirrorsShownEdit
        )
    }

    /// Waits out a switch that can change whether the window shows the workspace, then applies the
    /// edit to the window's copy if the window holds the workspace. Nil when the edit goes to the
    /// canonical document instead.
    private func mutateLocalIfHeld(
        _ workspaceID: UUID,
        selectionTabID: UUID?,
        source: String,
        persistence: WorkspaceContentPersistence,
        mirrorsShownEdit: Bool,
        validation: @MainActor () throws -> Void,
        didStore: (@MainActor (WorkspaceModel, _ acceptedRevision: UInt64?) -> Void)?,
        edit: (inout WorkspaceModel, WorkspaceContentEditTarget) throws -> Void
    ) async throws -> WorkspaceContentWriteReceipt? {
        try await awaitShownStateSettled(workspaceID)
        if holdsLocally(workspaceID) {
            return try await mutateLocal(
                workspaceID,
                selectionTabID: selectionTabID,
                source: source,
                persistence: persistence,
                mirrorsShownEdit: mirrorsShownEdit,
                validation: validation,
                didStore: didStore,
                edit: edit
            )
        }
        guard manager?.contentGatewayCatalogContains(workspaceID) == true else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID)
        }
        return nil
    }

    /// Submits the document and reports whatever the authority accepted, even when the caller
    /// cancels its task during the submit, because cancelling doesn't undo an accepted write.
    /// `didStore` gets the accepted document and its working revision in the turn the answer
    /// arrives. The window's copy takes the document only when the bridge projects it, as every
    /// other window's copy does, and the write returns after that projection.
    private func commit(
        _ workspace: WorkspaceModel,
        changedTabIDs: Set<UUID>,
        fileURL: URL,
        expectedRevision: UInt64,
        expectedDigest: String,
        persistence: WorkspaceContentPersistence,
        didStore: (@MainActor (WorkspaceModel, _ acceptedRevision: UInt64?) -> Void)?
    ) async throws -> Write {
        try await submit(workspace, changedTabIDs: changedTabIDs, didStore: didStore) {
            await backend.commit(
                workspace,
                fileURL: fileURL,
                expectedRevision: expectedRevision,
                expectedDigest: expectedDigest,
                persistence: persistence
            )
        }
    }

    /// Sends one submission for `workspace` to the authority and returns its write.
    private func submit(
        _ workspace: WorkspaceModel,
        changedTabIDs: Set<UUID>,
        didStore: (@MainActor (WorkspaceModel, _ acceptedRevision: UInt64?) -> Void)?,
        _ submission: () async -> WorkspaceContentCommitResult
    ) async throws -> Write {
        #if DEBUG
            if let handler = commitSubmissionWillBeginHandlerForTesting { await handler(workspace.id) }
        #endif
        let result = await submission()
        #if DEBUG
            if let handler = commitResultWillReturnHandlerForTesting { await handler(workspace.id) }
        #endif
        for outcome in result.acceptedOutcomes {
            manager?.reportDomainAuthorityOutcomeHealth(outcome, workspaceID: workspace.id)
        }
        if result.failure == nil, let accepted = result.accepted {
            didStore?(workspace, accepted.revisions.workingRevision)
        }
        if let failure = result.failure { throw failure }
        guard let accepted = result.accepted else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspace.id)
        }
        // The write happened, so it returns even when the wait ends without the projection. A later
        // install describes a later write, so only the install at the accepted revision counts.
        let install = await manager?.awaitProjectedInstall(of: workspace.id, atLeast: accepted.revisions.workingRevision)
        return Write(
            receipt: .committed(revisions: accepted.revisions, digest: accepted.digest, changedTabIDs: changedTabIDs),
            projectedInstall: install?.workingRevision == accepted.revisions.workingRevision ? install : nil
        )
    }

    private func mutateLocal(
        _ workspaceID: UUID,
        selectionTabID: UUID?,
        source: String,
        persistence: WorkspaceContentPersistence,
        mirrorsShownEdit: Bool,
        validation: @MainActor () throws -> Void,
        didStore: (@MainActor (WorkspaceModel, _ acceptedRevision: UInt64?) -> Void)?,
        edit: (inout WorkspaceModel, WorkspaceContentEditTarget) throws -> Void
    ) async throws -> WorkspaceContentWriteReceipt {
        guard let manager, let current = manager.workspace(withID: workspaceID) else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID)
        }
        try validation()
        let wasShown = manager.activeWorkspaceID == workspaceID
        // On the shown workspace the edit starts from what the next save capture stores, so the
        // live UI state that capture copies in is already part of the edited model.
        let base = manager.contentGatewayShownSaveCapture(workspaceID) ?? current
        var edited = base
        try edit(&edited, .windowCopy)
        try Task.checkCancellation()
        let changedTabIDs = Self.changedTabIDs(from: base, to: edited)
        if edited != base {
            manager.contentGatewayInstallLocalEdit(edited)
            didStore?(edited, nil)
            if mirrorsShownEdit {
                await manager.contentGatewayMirrorShownEdit(from: base, to: edited)
            } else {
                manager.contentGatewayPresentShownSelections(from: base, to: edited)
            }
        } else {
            didStore?(edited, nil)
        }

        guard persistence == .saved, wasShown, !edited.isEphemeral else {
            return .pendingLocal(
                stateVersion: manager.contentGatewayStateVersion(for: workspaceID),
                selectionRevision: selectionTabID.map {
                    manager.selectionRevisionForMCP(workspaceID: workspaceID, tabID: $0)
                }
            )
        }
        let saveSource = WorkspaceSaveSource("contentGateway.\(source)")
        let outcome: WorkspacePersistenceOutcome = if manager.activeWorkspaceID == workspaceID,
                                                      !manager.contentGatewayShownStateIsChanging(workspaceID)
        {
            // The save takes this workspace's ID. A switch while it runs can't move it elsewhere.
            await manager.pollAndSaveStateWithOutcomeAsync(workspaceID: workspaceID, source: saveSource)
        } else {
            // A switch started during the UI apply. A capture now would read UI state the switch is
            // replacing, and the stored copy already holds the edit, so it is saved as it is.
            await manager.contentGatewaySaveStoredCopy(workspaceID, source: saveSource)
        }
        if case let .rejected(rejection) = outcome {
            throw WorkspaceContentGatewayError.saveRejected(rejection)
        }
        if let saved = manager.contentGatewayRecordedAuthorityState(for: workspaceID) {
            return .committed(revisions: saved.revisions, digest: saved.digest, changedTabIDs: changedTabIDs)
        }
        guard let document = await backend.canonicalDocument(for: workspaceID) else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID)
        }
        return .committed(
            revisions: document.summary.revisions,
            digest: document.summary.contentDigest,
            changedTabIDs: changedTabIDs
        )
    }

    /// The window's own copy, for content it holds: its shown workspace or its own ephemeral one.
    private func localContent(_ workspaceID: UUID, capturingLiveUIState: Bool) throws -> WorkspaceModel? {
        guard let manager, !isInvalidated else { throw WorkspaceContentGatewayError.gatewayClosed }
        guard holdsLocally(workspaceID), var workspace = manager.workspace(withID: workspaceID) else { return nil }
        // During a switch from or to the workspace the UI may already belong to the other one, so a
        // read gets the stored copy, as the poll timer skips its capture then.
        if capturingLiveUIState, !manager.contentGatewaySwitchInvolves(workspaceID) {
            workspace.composeTabs = workspace.composeTabs.map {
                manager.contentGatewayLiveSnapshot(of: $0, inWorkspace: workspaceID)
            }
        }
        return workspace
    }

    /// The canonical document an operation loads.
    private func operationCanonicalDocument(_ workspaceID: UUID, source: String) async -> WorkspaceContentDocument? {
        #if DEBUG
            if let handler = canonicalReadWillBeginHandlerForTesting {
                await handler(workspaceID, source)
            }
        #endif
        return await backend.canonicalDocument(for: workspaceID)
    }

    private func holdsLocally(_ workspaceID: UUID) -> Bool {
        heldWorkspace(workspaceID) != nil
    }

    /// The window's own copy of a workspace it holds: its shown workspace or its own ephemeral one.
    private func heldWorkspace(_ workspaceID: UUID) -> WorkspaceModel? {
        guard let manager, manager.holdsWorkspaceContent(workspaceID) else { return nil }
        return manager.workspace(withID: workspaceID)
    }

    private func heldWorkspaces() -> [WorkspaceModel] {
        guard let manager else { return [] }
        return manager.workspaces.filter { manager.holdsWorkspaceContent($0.id) }
    }

    private func readContentNotHeldLocally(_ workspaceID: UUID, source: String) async throws -> WorkspaceModel {
        guard let isCatalogMember = manager?.contentGatewayCatalogContains(workspaceID) else {
            throw WorkspaceContentGatewayError.gatewayClosed
        }
        guard isCatalogMember else {
            // Only an ephemeral workspace that another window owns lacks a canonical record. Its
            // read registration is the only content it has.
            guard let overlay = await backend.readOverlayDocument(for: workspaceID),
                  overlay.summary.isEphemeral
            else { throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID) }
            recordLoad(workspaceID, source: source)
            let model = try await decode(overlay, source: source)
            try recheckLifetime()
            return model
        }
        // A read sees the last published working state. If the document changes during the
        // decode, the read retries once, and a second change returns a state conflict.
        for _ in 0 ..< 2 {
            guard let document = await operationCanonicalDocument(workspaceID, source: source) else {
                throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID)
            }
            recordLoad(workspaceID, source: source)
            let model = try await decode(document, source: source)
            try recheckLifetime()
            guard manager?.contentGatewayCatalogContains(workspaceID) == true,
                  let current = await backend.canonicalDocument(for: workspaceID)
            else { throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID) }
            if current.summary.contentDigest == document.summary.contentDigest {
                return model
            }
        }
        throw WorkspaceContentGatewayError.stateConflict(workspaceID)
    }

    /// Waits while a switch changes whether the window shows the workspace, rechecking at each
    /// phase change. Cancellation and `invalidate()` end the wait with their errors.
    private func awaitShownStateSettled(_ workspaceID: UUID) async throws {
        while true {
            try recheckLifetime()
            guard let manager, manager.contentGatewayShownStateIsChanging(workspaceID) else { return }
            let token = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { return continuation.resume() }
                    switchWaiters[token] = continuation
                    manager.contentGatewayOnNextSwitchProgress { [weak self] in
                        self?.resumeSwitchWaiter(token)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resumeSwitchWaiter(token)
                }
            }
        }
    }

    private func resumeSwitchWaiter(_ token: UUID) {
        switchWaiters.removeValue(forKey: token)?.resume()
    }

    private func recheckLifetime() throws {
        try Task.checkCancellation()
        guard manager != nil, !isInvalidated else { throw WorkspaceContentGatewayError.gatewayClosed }
    }

    private func decode(_ document: WorkspaceContentDocument, source: String) async throws -> WorkspaceModel {
        let bytes = document.documentBytes
        let fileURL = document.summary.fileURL
        let model = try await Task.detached(priority: .utility) {
            try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: bytes, fileURL: fileURL)
        }.value
        recordDecode(document.summary.workspaceID, source: source)
        return model
    }

    /// The tab IDs that the document's summary and the app decode of the same bytes disagree on.
    /// Normalization's one default tab for an empty compose list loses nothing, so it doesn't count.
    static func tabIDsMismatchedByDecode(summary: DomainWorkspaceSummary, decoded: WorkspaceModel) -> Set<UUID> {
        let listedCompose = Set(summary.composeTabs.map(\.tabID))
        var decodedCompose = Set(decoded.composeTabs.map(\.id))
        if listedCompose.isEmpty, decoded.composeTabs.count == 1 {
            decodedCompose.removeAll()
        }
        let listedStashed = Set(summary.stashedTabs.map(\.tabID))
        let decodedStashed = Set(decoded.stashedTabs.map(\.tab.id))
        return listedCompose.symmetricDifference(decodedCompose)
            .union(listedStashed.symmetricDifference(decodedStashed))
    }

    static func changedTabIDs(from baseline: WorkspaceModel, to edited: WorkspaceModel) -> Set<UUID> {
        changedIDs(tabsByID(baseline.composeTabs, id: \.id), tabsByID(edited.composeTabs, id: \.id))
            .union(changedIDs(tabsByID(baseline.stashedTabs, id: \.tab.id), tabsByID(edited.stashedTabs, id: \.tab.id)))
    }

    /// The IDs that one side holds and the other lacks or holds with a different value.
    private static func changedIDs<Tab: Equatable>(_ before: [UUID: Tab], _ after: [UUID: Tab]) -> Set<UUID> {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    /// The tabs by ID. For a list that holds one tab ID twice, the first of them.
    private static func tabsByID<Tab>(_ tabs: [Tab], id: (Tab) -> UUID) -> [UUID: Tab] {
        Dictionary(tabs.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func tabIDs(of workspace: WorkspaceModel) -> Set<UUID> {
        Set(workspace.composeTabs.map(\.id)).union(workspace.stashedTabs.map(\.tab.id))
    }

    private func recordLoad(_ workspaceID: UUID, source: String) {
        #if DEBUG
            loadSnapshot.record(workspaceID: workspaceID, source: source, loads: 1, decodes: 0)
        #endif
    }

    private func recordDecode(_ workspaceID: UUID, source: String) {
        #if DEBUG
            loadSnapshot.record(workspaceID: workspaceID, source: source, loads: 0, decodes: 1)
        #endif
    }

    #if DEBUG
        func debugLoadSnapshot() -> WorkspaceContentLoadSnapshot {
            loadSnapshot
        }

        func resetDebugLoadSnapshot() {
            loadSnapshot = WorkspaceContentLoadSnapshot()
        }
    #endif
}

#if DEBUG
    /// Counts of the workspace documents one window's gateway loaded and decoded, by workspace and by
    /// the caller's source label. Tests read it in process, and the `workspace_content_load_snapshot`
    /// diagnostics op reports it. It shows which documents the gateway decoded, not their memory use.
    struct WorkspaceContentLoadSnapshot: Equatable {
        struct Counts: Equatable {
            var loads = 0
            var decodes = 0
        }

        private(set) var countsByWorkspaceID: [UUID: [String: Counts]] = [:]

        /// Counts for one workspace, summed over its sources.
        func counts(for workspaceID: UUID) -> Counts {
            (countsByWorkspaceID[workspaceID] ?? [:]).values.reduce(into: Counts()) {
                $0.loads += $1.loads
                $0.decodes += $1.decodes
            }
        }

        mutating func record(workspaceID: UUID, source: String, loads: Int, decodes: Int) {
            var counts = countsByWorkspaceID[workspaceID, default: [:]][source, default: Counts()]
            counts.loads += loads
            counts.decodes += decodes
            countsByWorkspaceID[workspaceID, default: [:]][source] = counts
        }
    }
#endif
