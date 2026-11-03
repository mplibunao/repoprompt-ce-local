import Foundation

struct ContextBuilderWorkspaceContext {
    /// The invoking tab's Agent session. Outside Agent Mode it is the session of the tab the call
    /// runs in, or nil when that tab has none.
    let parentAgentSessionID: UUID?
    let frozenTabContext: MCPServerViewModel.TabContextSnapshot
    let worktreeBindings: [AgentSessionWorktreeBinding]
    let lookupContext: WorkspaceLookupContext
    let providerWorkspacePath: String
    let reviewGitContext: FrozenPromptGitReviewContext
    let frozenReviewAuthority: ContextBuilderFrozenReviewAuthority
    let reviewTargetResolution: ContextBuilderReviewTargetResolution
    private let reviewDiagnosticSink: ContextBuilderReviewDiagnosticSink?

    var tabID: UUID {
        frozenTabContext.tabID
    }

    /// Freezes the invoking tab's lookup, review Git context, and review target for one
    /// Context Builder call. `requiresParentAgentRun` is true for Agent Mode calls, which must
    /// come from an Agent session's run.
    static func resolve(
        from snapshot: MCPServerViewModel.TabContextSnapshot,
        requiresParentAgentRun: Bool,
        workspaceRepoPaths: [String],
        workspaceDirectoryPath: String,
        store: WorkspaceFileContextStore,
        reviewDiagnosticSink: ContextBuilderReviewDiagnosticSink? = nil
    ) async throws -> ContextBuilderWorkspaceContext {
        let parentAgentSessionID = snapshot.activeAgentSessionID
        if requiresParentAgentRun {
            guard parentAgentSessionID != nil else {
                throw ContextBuilderWorkspaceContextError.missingParentAgentSession
            }
            guard snapshot.runID != nil else {
                throw ContextBuilderWorkspaceContextError.missingParentAgentRun
            }
        }
        guard let workspaceID = snapshot.workspaceID else {
            throw ContextBuilderWorkspaceContextError.missingWorkspace
        }
        let bindings: [AgentSessionWorktreeBinding]
        switch (parentAgentSessionID, snapshot.worktreeBindingState) {
        case let (.some, .hydrated(sessionBindings)):
            bindings = sessionBindings
        case (nil, .notApplicable):
            bindings = []
        case let (nil, .hydrated(unownedBindings)) where unownedBindings.isEmpty:
            bindings = []
        default:
            // Bindings with no session have no projection owner, and an unhydrated or unavailable
            // state has no known bindings. Either would read the main checkout.
            throw ContextBuilderWorkspaceContextError.unavailableWorktreeBindingState
        }

        let requestedRootPaths = Set(workspaceRepoPaths.compactMap {
            AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0)
        })
        // The worktree projection below checks only the bound roots against the loaded roots.
        // A call from outside Agent Mode can come from a tab in a workspace that isn't the visible
        // one, so every root of the invoking workspace must be loaded. An Agent Mode run belongs
        // to the visible workspace, and a bound run needs only its bound roots.
        if bindings.isEmpty || !requiresParentAgentRun {
            let primaryRoots = await store.roots().filter { $0.kind == .primaryWorkspace }
            let loadedPrimaryRootPaths = Set(primaryRoots.map(\.standardizedFullPath))
            guard !requestedRootPaths.isEmpty,
                  requestedRootPaths.isSubset(of: loadedPrimaryRootPaths)
            else {
                throw ContextBuilderWorkspaceContextError.unavailableWorkspaceProjection
            }
        }

        let lookupContext: WorkspaceLookupContext
        if bindings.isEmpty {
            lookupContext = WorkspaceLookupContext(
                rootScope: .sessionBoundWorkspace(
                    canonicalRootPaths: requestedRootPaths,
                    physicalRootPaths: []
                ),
                bindingProjection: nil
            )
        } else {
            do {
                lookupContext = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                    source: AgentWorkspaceLookupContextSource(
                        activeAgentSessionID: parentAgentSessionID,
                        worktreeBindingState: .hydrated(bindings)
                    ),
                    store: store
                )
            } catch {
                throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
            }
        }

        let reviewGitContext = await FrozenPromptGitReviewContext.make(
            workspaceID: workspaceID,
            workspaceDirectoryPath: workspaceDirectoryPath,
            workspaceRootPaths: workspaceRepoPaths,
            tabID: snapshot.tabID,
            sessionID: parentAgentSessionID,
            bindings: bindings,
            base: "HEAD",
            store: store
        )
        let frozenReviewAuthority = ContextBuilderFrozenReviewAuthority(
            workspaceID: workspaceID,
            tabID: snapshot.tabID,
            reviewGitContext: reviewGitContext
        )
        let reviewTargetResolution = try await ContextBuilderReviewTargetResolver(
            diagnosticSink: reviewDiagnosticSink
        ).resolve(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: snapshot.tabID,
                selectionRevision: snapshot.selectionRevision,
                selection: snapshot.selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext
            ),
            store: store
        )

        let providerWorkspacePath = try providerWorkspacePath(
            availableTarget: reviewTargetResolution.availableTarget,
            bindings: bindings,
            workspaceRepoPaths: workspaceRepoPaths,
            workspaceDirectoryPath: workspaceDirectoryPath,
            requiresParentAgentRun: requiresParentAgentRun
        )

        let context = ContextBuilderWorkspaceContext(
            parentAgentSessionID: parentAgentSessionID,
            frozenTabContext: snapshot,
            worktreeBindings: bindings,
            lookupContext: lookupContext,
            providerWorkspacePath: StandardizedPath.absolute(providerWorkspacePath),
            reviewGitContext: reviewGitContext,
            frozenReviewAuthority: frozenReviewAuthority,
            reviewTargetResolution: reviewTargetResolution,
            reviewDiagnosticSink: reviewDiagnosticSink
        )
        try context.validateAvailability()
        return context
    }

    /// The discovery agent's working directory. It is not Git authority: discovery `git` calls
    /// use the frozen review target carried in the run-scoped tab snapshot.
    private static func providerWorkspacePath(
        availableTarget: ContextBuilderReviewTarget?,
        bindings: [AgentSessionWorktreeBinding],
        workspaceRepoPaths: [String],
        workspaceDirectoryPath: String,
        requiresParentAgentRun: Bool
    ) throws -> String {
        if let availableTarget {
            return availableTarget.primaryCheckout.checkoutRootPath
        }
        if !bindings.isEmpty {
            let primaryRoot = workspaceRepoPaths.first
            if requiresParentAgentRun {
                guard let projected = try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                    bindings: bindings,
                    fallbackWorkspacePath: primaryRoot ?? workspaceDirectoryPath
                ) else {
                    throw ContextBuilderWorkspaceContextError.missingWorkspaceRoot
                }
                return projected
            }
            // Outside Agent Mode no agent shell fixes the start folder, and a lone binding can be
            // for a secondary root. Its worktree holds the bound files, where the primary-root
            // rule would start discovery in an unrelated root.
            if bindings.count == 1 {
                return bindings[0].worktreeRootPath
            }
            if AgentWorktreeRuntimeWorkspaceResolver.primaryExecutionBinding(
                in: bindings,
                fallbackWorkspacePath: primaryRoot
            ) != nil, let projected = try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                bindings: bindings,
                fallbackWorkspacePath: primaryRoot
            ) {
                return projected
            }
            return workspaceDirectoryPath
        }
        if workspaceRepoPaths.count == 1, let onlyRoot = workspaceRepoPaths.first {
            return onlyRoot
        }
        return workspaceDirectoryPath
    }

    func validateAvailability() throws {
        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(worktreeBindings)
        } catch {
            throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: providerWorkspacePath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ContextBuilderWorkspaceContextError.unavailableProviderWorkspace
        }
    }

    func validateReviewTargetAvailability(store: WorkspaceFileContextStore) async throws {
        guard case let .available(target) = reviewTargetResolution else { return }
        if let reason = await ContextBuilderReviewTargetResolver().revalidate(target, store: store) {
            throw reason
        }
    }

    func authorizeFinalReviewSelection(
        _ selection: StoredSelection,
        workspaceID: UUID,
        tabID: UUID,
        selectionRevision: UInt64,
        store: WorkspaceFileContextStore
    ) async throws -> ContextBuilderFinalReviewAuthorization {
        try await ContextBuilderReviewTargetResolver(
            diagnosticSink: reviewDiagnosticSink
        ).finalizeSelection(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: tabID,
                selectionRevision: selectionRevision,
                selection: selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext
            ),
            initialResolution: reviewTargetResolution,
            store: store
        )
    }

    /// The discovery run's tab snapshot. Lookup, review target, selection, and provenance come
    /// from this frozen context. The prompt comes from the admitted call, which refreshes it after
    /// the freeze; a refreshed prompt doesn't re-elect the review target.
    func nestedDiscoveryTabContext(
        runID: UUID,
        promptText: String,
        usedAgentOutputAsPrompt: Bool
    ) -> MCPServerViewModel.TabContextSnapshot {
        let source = frozenTabContext
        return MCPServerViewModel.TabContextSnapshot(
            tabID: source.tabID,
            windowID: source.windowID,
            workspaceID: source.workspaceID,
            promptText: promptText,
            usedAgentOutputAsPrompt: usedAgentOutputAsPrompt,
            selection: source.selection,
            selectionRevision: source.selectionRevision,
            selectedMetaPromptIDs: source.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: source.selectedContextBuilderPromptIDs,
            tabName: source.tabName,
            runID: runID,
            activeAgentSessionID: parentAgentSessionID,
            worktreeBindings: worktreeBindings,
            frozenLookupContext: lookupContext,
            contextBuilderFrozenReviewAuthority: frozenReviewAuthority,
            contextBuilderReviewTargetResolution: reviewTargetResolution,
            explicitlyBound: source.explicitlyBound,
            readFileAutoSelectionGeneration: source.readFileAutoSelectionGeneration
        )
    }
}

enum ContextBuilderWorkspaceContextError: LocalizedError, Equatable {
    case missingParentAgentSession
    case missingParentAgentRun
    case missingWorkspace
    case missingWorkspaceRoot
    case unavailableWorkspaceProjection
    case unavailableWorktreeBindingState
    case unavailableWorktreeProjection
    case unavailableProviderWorkspace

    var errorDescription: String? {
        switch self {
        case .missingParentAgentSession:
            "context_builder could not freeze the invoking Agent Mode session identity. Retry after Agent Mode routing settles."
        case .missingParentAgentRun:
            "context_builder could not freeze the invoking Agent Mode run identity. Retry after Agent Mode routing settles."
        case .missingWorkspace:
            "context_builder could not freeze the invoking workspace identity."
        case .missingWorkspaceRoot:
            "context_builder requires a project workspace root for the invoking tab."
        case .unavailableWorkspaceProjection:
            "The invoking tab's workspace roots could not be loaded. Context Builder stopped rather than using the visible workspace."
        case .unavailableWorktreeBindingState:
            "The invoking tab's worktree bindings are not hydrated or are unavailable. Context Builder stopped rather than falling back to the canonical checkout."
        case .unavailableWorktreeProjection:
            "The invoking tab's worktree bindings could not be loaded. Context Builder stopped rather than falling back to the canonical checkout."
        case .unavailableProviderWorkspace:
            "The invoking tab's workspace is unavailable. Context Builder stopped rather than falling back to another checkout."
        }
    }
}
