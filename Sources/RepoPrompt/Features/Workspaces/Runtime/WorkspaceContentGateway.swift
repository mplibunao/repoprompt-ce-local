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
}

/// A tab ID looked up across the summary catalog.
enum WorkspaceTabIdentityResolution: Equatable {
    case unique(WorkspaceSelectionIdentity, location: DomainWorkspaceTabLocation)
    /// More than one workspace lists the tab ID, so the caller has to name the workspace.
    case ambiguous([WorkspaceSelectionIdentity])
    case notFound
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

    /// Resolves a bare tab ID across the catalog. A tab ID that more than one workspace lists is
    /// ambiguous; catalog order never picks a winner.
    func uniqueTabIdentity(tabID: UUID, includeStashed: Bool) -> WorkspaceTabIdentityResolution {
        var matches: [(identity: WorkspaceSelectionIdentity, location: DomainWorkspaceTabLocation)] = []
        for summary in manager?.workspaceSummaries ?? [] {
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
            validation: validation,
            edit: edit
        )
    }

    /// Applies `edit` to one compose tab, through `mutateWorkspace`'s rules. A tab the edit changes
    /// gets a new `lastModified`, and its workspace a new `dateModified`.
    func mutateComposeTab(
        _ identity: WorkspaceSelectionIdentity,
        source: String,
        persistence: WorkspaceContentPersistence,
        validation: @MainActor () throws -> Void = {},
        edit: (inout ComposeTabState) throws -> Void
    ) async throws -> WorkspaceComposeTabWrite {
        var editedTab: ComposeTabState?
        let receipt = try await mutate(
            identity.workspaceID,
            selectionTabID: identity.tabID,
            source: source,
            persistence: persistence,
            validation: validation
        ) { workspace in
            guard let index = workspace.composeTabs.firstIndex(where: { $0.id == identity.tabID }) else {
                throw WorkspaceContentGatewayError.tabUnavailable(identity)
            }
            var tab = workspace.composeTabs[index]
            let original = tab
            try edit(&tab)
            if tab != original {
                let now = Date()
                tab.lastModified = now
                workspace.composeTabs[index] = tab
                workspace.dateModified = now
            }
            editedTab = tab
        }
        guard let editedTab else { throw WorkspaceContentGatewayError.tabUnavailable(identity) }
        return WorkspaceComposeTabWrite(receipt: receipt, tab: editedTab)
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
        return try await commit(
            workspace,
            changedTabIDs: previous.map { Self.changedTabIDs(from: $0, to: workspace) }
                ?? Self.tabIDs(of: workspace),
            fileURL: fileURL,
            expectedRevision: expectedRevision,
            expectedDigest: expectedDigest,
            persistence: persistence,
            // The whole document replaces the window's copy, local edits included, as a remote
            // write does. On the shown workspace the next capture puts the live UI back on top.
            localEditsDuringSubmit: .replace
        )
    }

    // MARK: - Internals

    private func mutate(
        _ workspaceID: UUID,
        selectionTabID: UUID?,
        source: String,
        persistence: WorkspaceContentPersistence,
        validation: @MainActor () throws -> Void,
        edit: (inout WorkspaceModel) throws -> Void
    ) async throws -> WorkspaceContentWriteReceipt {
        guard manager != nil, !isInvalidated else { throw WorkspaceContentGatewayError.gatewayClosed }
        if let receipt = try await mutateLocalIfHeld(
            workspaceID,
            selectionTabID: selectionTabID,
            source: source,
            persistence: persistence,
            validation: validation,
            edit: edit
        ) {
            return receipt
        }

        // A write's baseline is the canonical document, never a read registration.
        guard let document = await backend.canonicalDocument(for: workspaceID) else {
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
            validation: validation,
            edit: edit
        ) {
            return receipt
        }

        try validation()
        var edited = baseline
        try edit(&edited)
        guard edited != baseline else {
            // A no-op edit sends no command and leaves the parked document's bytes as they are.
            return .committed(
                revisions: document.summary.revisions,
                digest: document.summary.contentDigest,
                changedTabIDs: []
            )
        }
        try Task.checkCancellation()
        return try await commit(
            edited,
            changedTabIDs: Self.changedTabIDs(from: baseline, to: edited),
            fileURL: document.summary.fileURL,
            expectedRevision: document.summary.revisions.workingRevision,
            expectedDigest: document.summary.contentDigest,
            persistence: persistence,
            localEditsDuringSubmit: .merge(
                baseline: baseline,
                baselineRevision: document.summary.revisions.workingRevision
            )
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
        validation: @MainActor () throws -> Void,
        edit: (inout WorkspaceModel) throws -> Void
    ) async throws -> WorkspaceContentWriteReceipt? {
        try await awaitShownStateSettled(workspaceID)
        if holdsLocally(workspaceID) {
            return try await mutateLocal(
                workspaceID,
                selectionTabID: selectionTabID,
                source: source,
                persistence: persistence,
                validation: validation,
                edit: edit
            )
        }
        guard manager?.contentGatewayCatalogContains(workspaceID) == true else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspaceID)
        }
        return nil
    }

    /// How `commit` updates a window copy that took local edits during the submit.
    private enum LocalEditsDuringSubmit {
        /// The edit's changes from `baseline`, read at `baselineRevision`, are merged into the copy.
        case merge(baseline: WorkspaceModel, baselineRevision: UInt64)
        /// The committed document replaces the copy.
        case replace
    }

    /// Submits the document and applies whatever the authority accepted, also when the caller's task
    /// is cancelled during the submit. An accepted write stays accepted.
    private func commit(
        _ workspace: WorkspaceModel,
        changedTabIDs: Set<UUID>,
        fileURL: URL,
        expectedRevision: UInt64,
        expectedDigest: String,
        persistence: WorkspaceContentPersistence,
        localEditsDuringSubmit: LocalEditsDuringSubmit
    ) async throws -> WorkspaceContentWriteReceipt {
        let stateVersionAtDispatch = manager?.contentGatewayStateVersion(for: workspace.id)
        let recordedRevisionAtDispatch = manager?.contentGatewayCommittedState(for: workspace.id)?
            .revisions.workingRevision
        let result = await backend.commit(
            workspace,
            fileURL: fileURL,
            expectedRevision: expectedRevision,
            expectedDigest: expectedDigest,
            persistence: persistence
        )
        if let manager, let accepted = result.accepted {
            // A newer revision recorded during the submit means a later write already reached this
            // window. Applying this older outcome or model would move the window backward.
            let recordedRevision = manager.contentGatewayCommittedState(for: workspace.id)?.revisions.workingRevision
            if recordedRevision.map({ $0 <= accepted.revisions.workingRevision }) ?? true {
                for outcome in result.acceptedOutcomes {
                    manager.contentGatewayApplyAcceptedOutcome(outcome, workspaceID: workspace.id)
                }
                // The window keeps a full model of every workspace. Unless its copy carries the
                // write, its next whole-model save of this workspace reverts it.
                if manager.contentGatewayStateVersion(for: workspace.id) == stateVersionAtDispatch {
                    manager.contentGatewayInstallAcceptedCopy(workspace)
                } else if let local = manager.workspace(withID: workspace.id) {
                    // The copy took local edits during the submit, and the self-echo keeps it as it
                    // is. The edit's changes go into it so it carries both. The merge holds only
                    // for a copy that started from the edit's baseline: a window that hadn't taken
                    // an earlier write would read that write's changes as absent and revert them.
                    if case let .merge(baseline, baselineRevision) = localEditsDuringSubmit,
                       recordedRevisionAtDispatch == baselineRevision,
                       let merged = Self.merging(workspace, from: baseline, into: local)
                    {
                        manager.contentGatewayInstallLocalEdit(merged)
                    } else {
                        manager.contentGatewayInstallAcceptedCopy(workspace)
                    }
                }
            }
        }
        if let failure = result.failure { throw failure }
        guard let accepted = result.accepted else {
            throw WorkspaceContentGatewayError.workspaceUnavailable(workspace.id)
        }
        return .committed(revisions: accepted.revisions, digest: accepted.digest, changedTabIDs: changedTabIDs)
    }

    private func mutateLocal(
        _ workspaceID: UUID,
        selectionTabID: UUID?,
        source: String,
        persistence: WorkspaceContentPersistence,
        validation: @MainActor () throws -> Void,
        edit: (inout WorkspaceModel) throws -> Void
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
        try edit(&edited)
        try Task.checkCancellation()
        let changedTabIDs = Self.changedTabIDs(from: base, to: edited)
        if edited != base {
            manager.contentGatewayInstallLocalEdit(edited)
            await manager.contentGatewayMirrorShownEdit(from: base, to: edited)
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
        if let committed = manager.contentGatewayCommittedState(for: workspaceID) {
            return .committed(revisions: committed.revisions, digest: committed.digest, changedTabIDs: changedTabIDs)
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

    private func holdsLocally(_ workspaceID: UUID) -> Bool {
        guard let manager, let workspace = manager.workspace(withID: workspaceID) else { return false }
        return manager.activeWorkspaceID == workspaceID || workspace.isEphemeral
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
            guard let document = await backend.canonicalDocument(for: workspaceID) else {
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

    /// `copy` with the edit's changes from `baseline` to `edited` merged in: each tab the edit
    /// created, replaced, or removed, with created tabs placed in the edit's order, and each
    /// workspace field the edit changed. A local change to a tab the edit replaced gives way to the
    /// edit's version of that tab.
    ///
    /// Nil when no merge keeps both sides: a tab list holds one tab ID twice, the copy moved or
    /// removed a tab the edit changed, the edit reordered tabs it kept, or the result's active tab
    /// is gone or a tab ID ends up both composed and stashed.
    static func merging(
        _ edited: WorkspaceModel,
        from baseline: WorkspaceModel,
        into copy: WorkspaceModel
    ) -> WorkspaceModel? {
        guard let composeTabs = mergedTabs(
            baseline: baseline.composeTabs,
            edited: edited.composeTabs,
            copy: copy.composeTabs,
            id: \.id
        ),
            let stashedTabs = mergedTabs(
                baseline: baseline.stashedTabs,
                edited: edited.stashedTabs,
                copy: copy.stashedTabs,
                id: \.tab.id
            )
        else { return nil }

        // This starts from the edit's fields and takes the copy's value only for a field the copy
        // changed and the edit didn't, which equals applying the edit's field changes to the copy.
        // A field this list misses keeps the committed value instead of reverting it.
        var merged = edited
        func keepLocalChange(_ field: WritableKeyPath<WorkspaceModel, some Equatable>) {
            if copy[keyPath: field] != baseline[keyPath: field],
               edited[keyPath: field] == baseline[keyPath: field]
            {
                merged[keyPath: field] = copy[keyPath: field]
            }
        }
        keepLocalChange(\.schemaVersion)
        keepLocalChange(\.dateModified)
        keepLocalChange(\.customStoragePath)
        keepLocalChange(\.isSystemWorkspace)
        keepLocalChange(\.isHiddenInMenus)
        keepLocalChange(\.consolidatedIntoWorkspaceID)
        keepLocalChange(\.ephemeralFlag)
        keepLocalChange(\.name)
        keepLocalChange(\.repoPaths)
        keepLocalChange(\.presets)
        keepLocalChange(\.activePresetID)
        keepLocalChange(\.lastUsed)
        keepLocalChange(\.customPath)
        keepLocalChange(\.currentPromptText)
        keepLocalChange(\.lastSearchQuery)
        keepLocalChange(\.selectedMetaPromptIDs)
        keepLocalChange(\.copyPresetId)
        keepLocalChange(\.copyCustomizations)
        keepLocalChange(\.chatPresetId)
        keepLocalChange(\.activeComposeTabID)
        merged.composeTabs = composeTabs
        merged.stashedTabs = stashedTabs

        if let activeTabID = merged.activeComposeTabID, !composeTabs.contains(where: { $0.id == activeTabID }) {
            return nil
        }
        guard Set(composeTabs.map(\.id)).isDisjoint(with: stashedTabs.map(\.tab.id)) else { return nil }
        return merged
    }

    /// One tab list of `merging(_:from:into:)`. Nil when a list holds one tab ID twice, the copy
    /// moved or removed a tab the edit changed, already holds a tab the edit created, or the edit
    /// reordered the tabs it kept.
    private static func mergedTabs<Tab: Equatable>(
        baseline: [Tab],
        edited: [Tab],
        copy: [Tab],
        id: (Tab) -> UUID
    ) -> [Tab]? {
        // Matching by tab ID can't tell two tabs with one ID apart.
        for tabs in [baseline, edited, copy] where Set(tabs.map(id)).count != tabs.count {
            return nil
        }
        let baselineByID = tabsByID(baseline, id: id)
        let editedByID = tabsByID(edited, id: id)
        let copyIDs = Set(copy.map(id))
        guard edited.map(id).filter({ baselineByID[$0] != nil }) == baseline.map(id).filter({ editedByID[$0] != nil })
        else { return nil }
        let changed = changedIDs(baselineByID, editedByID)
        guard changed.allSatisfy({ copyIDs.contains($0) == (baselineByID[$0] != nil) }) else { return nil }

        var merged = copy.compactMap { tab -> Tab? in
            changed.contains(id(tab)) ? editedByID[id(tab)] : tab
        }
        for (index, tab) in edited.enumerated() where baselineByID[id(tab)] == nil {
            // After the nearest tab before it in the edit's order that the merged list holds.
            var position = 0
            for previous in edited[..<index].reversed() {
                if let previousIndex = merged.firstIndex(where: { id($0) == id(previous) }) {
                    position = previousIndex + 1
                    break
                }
            }
            merged.insert(tab, at: position)
        }
        return merged
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
