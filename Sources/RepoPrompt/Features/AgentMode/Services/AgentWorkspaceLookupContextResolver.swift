import Foundation

enum AgentSessionWorktreeBindingState: Equatable {
    case notApplicable
    case hydrated([AgentSessionWorktreeBinding])
    case unhydrated
    case unavailable

    var bindings: [AgentSessionWorktreeBinding]? {
        guard case let .hydrated(bindings) = self else { return nil }
        return bindings
    }
}

struct AgentWorkspaceLookupContextSource: Equatable {
    /// The tab's Agent session, for provenance. It never holds a tab ID.
    let activeAgentSessionID: UUID?
    /// The UUID the worktree projection is registered under: the Agent session's ID, or the
    /// compose tab's ID for a tab-owned worktree scope. Without an owner, lookup is canonical.
    let worktreeOwnerID: UUID?
    let worktreeBindingState: AgentSessionWorktreeBindingState

    init(
        activeAgentSessionID: UUID?,
        worktreeOwnerID: UUID?,
        worktreeBindingState: AgentSessionWorktreeBindingState
    ) {
        self.activeAgentSessionID = activeAgentSessionID
        self.worktreeOwnerID = worktreeOwnerID
        self.worktreeBindingState = worktreeBindingState
    }

    /// An Agent-owned source: the session, if any, owns the projection.
    init(
        activeAgentSessionID: UUID?,
        worktreeBindingState: AgentSessionWorktreeBindingState
    ) {
        self.init(
            activeAgentSessionID: activeAgentSessionID,
            worktreeOwnerID: activeAgentSessionID,
            worktreeBindingState: worktreeBindingState
        )
    }

    init(
        activeAgentSessionID: UUID?,
        worktreeBindings: [AgentSessionWorktreeBinding]
    ) {
        self.init(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingState: activeAgentSessionID == nil ? .notApplicable : .hydrated(worktreeBindings)
        )
    }

    var worktreeBindings: [AgentSessionWorktreeBinding] {
        worktreeBindingState.bindings ?? []
    }

    var identity: AgentWorkspaceLookupContextIdentity {
        AgentWorkspaceLookupContextIdentity(
            activeAgentSessionID: activeAgentSessionID,
            worktreeOwnerID: worktreeOwnerID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindingState)
        )
    }

    /// Canonical routed contexts have authority without a worktree owner identity.
    var authorityIdentity: AgentWorkspaceLookupContextIdentity? {
        worktreeOwnerID == nil ? nil : identity
    }

    /// True when the compose tab, not an Agent session, owns the projection.
    var isTabOwned: Bool {
        worktreeOwnerID != nil && worktreeOwnerID != activeAgentSessionID
    }

    /// The bindings an authoritative lookup may use. Empty means canonical lookup, which a source
    /// with no owner or an Agent session with no bindings allows. Bindings without an owner and a
    /// tab scope without bindings have no projection to read; an unhydrated or unavailable state
    /// has no known bindings.
    func validatedWorktreeBindings() throws -> [AgentSessionWorktreeBinding] {
        switch (worktreeOwnerID, worktreeBindingState) {
        case (nil, .notApplicable):
            return []
        case let (nil, .hydrated(bindings)):
            guard bindings.isEmpty else { throw AgentWorkspaceLookupContextResolutionError.unavailableProjection }
            return []
        case let (.some, .hydrated(bindings)):
            guard !bindings.isEmpty || !isTabOwned else {
                throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
            }
            return bindings
        case (_, .notApplicable), (_, .unhydrated), (_, .unavailable):
            throw AgentWorkspaceLookupContextResolutionError.unknownBindingState
        }
    }

    static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        worktreeBindingFingerprint(.hydrated(bindings))
    }

    static func worktreeBindingFingerprint(_ state: AgentSessionWorktreeBindingState) -> String {
        switch state {
        case .notApplicable:
            "not-applicable"
        case .unhydrated:
            "unhydrated"
        case .unavailable:
            "unavailable"
        case let .hydrated(bindings):
            bindings
                .map { binding in
                    [
                        binding.repositoryID,
                        binding.repoKey,
                        StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath),
                        binding.worktreeID,
                        StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath),
                        binding.branch ?? "",
                        binding.head ?? ""
                    ].joined(separator: "\u{1F}")
                }
                .sorted()
                .joined(separator: "\u{1E}")
        }
    }
}

struct AgentWorkspaceLookupContextIdentity: Hashable {
    let activeAgentSessionID: UUID?
    let worktreeOwnerID: UUID?
    let worktreeBindingFingerprint: String
}

enum AgentWorkspaceLookupContextResolver {
    private struct CacheKey: Hashable {
        let storeID: ObjectIdentifier
        let identity: AgentWorkspaceLookupContextIdentity
    }

    private final class ProjectionCache {
        private let limit = 16
        private let lock = NSLock()
        private var contexts: [CacheKey: WorkspaceLookupContext] = [:]
        private var order: [CacheKey] = []

        func context(for key: CacheKey) -> WorkspaceLookupContext? {
            lock.lock()
            defer { lock.unlock() }
            guard let context = contexts[key] else { return nil }
            touch(key)
            return context
        }

        func store(_ context: WorkspaceLookupContext, for key: CacheKey) {
            lock.lock()
            contexts[key] = context
            touch(key)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                contexts.removeValue(forKey: oldest)
            }
            lock.unlock()
        }

        func removeValue(for key: CacheKey) {
            lock.lock()
            contexts.removeValue(forKey: key)
            order.removeAll { $0 == key }
            lock.unlock()
        }

        private func touch(_ key: CacheKey) {
            order.removeAll { $0 == key }
            order.append(key)
        }
    }

    private static let projectionCache = ProjectionCache()

    static let failClosedLookupContext = WorkspaceLookupContext(
        rootScope: .sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: []),
        bindingProjection: nil
    )

    static func requiredLookupContext(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceLookupContext {
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        return try await requiredLookupContext(
            source: source,
            visibleRoots: visibleRoots,
            store: store
        )
    }

    static func requiredLookupContext(
        source: AgentWorkspaceLookupContextSource,
        visibleRoots: [WorkspaceRootRef],
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceLookupContext {
        let capturedCanonicalRoots = Set(visibleRoots)
        guard await Set(store.rootRefs(scope: .visibleWorkspace)) == capturedCanonicalRoots else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
        let bindings = try source.validatedWorktreeBindings()
        guard !bindings.isEmpty, let ownerID = source.worktreeOwnerID else {
            return WorkspaceLookupContext(
                rootScope: .validatedSessionBoundWorkspace(
                    canonicalRoots: capturedCanonicalRoots,
                    physicalRoots: []
                ),
                bindingProjection: nil
            )
        }

        for root in visibleRoots {
            guard let currentRoot = await store.exactRootRef(
                path: root.standardizedFullPath,
                kind: .primaryWorkspace
            ), currentRoot == root else {
                throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
            }
        }
        let visibleRootPaths = Set(visibleRoots.map(\.standardizedFullPath))
        let logicalRootPaths = Set(bindings.compactMap {
            AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0.logicalRootPath)
        })
        let bindingsMapDistinctLogicalRootsToWorktrees = bindings.allSatisfy { binding in
            guard let logicalRootPath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(
                binding.logicalRootPath
            ), let worktreeRootPath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(
                binding.worktreeRootPath
            ) else { return false }
            return logicalRootPath != worktreeRootPath
        }
        guard logicalRootPaths.count == bindings.count,
              logicalRootPaths.isSubset(of: visibleRootPaths),
              bindingsMapDistinctLogicalRootsToWorktrees
        else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }

        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)
        } catch let error as AgentWorktreeRuntimeWorkspaceError {
            throw AgentWorkspaceLookupContextResolutionError.unavailableWorktree(error)
        } catch {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
        let cacheKey = CacheKey(storeID: ObjectIdentifier(store), identity: source.identity)
        if let cached = projectionCache.context(for: cacheKey) {
            if await canReuseAuthoritativeLookupContext(
                cached,
                source: source,
                visibleRoots: visibleRoots,
                store: store
            ) {
                return cached
            }
            projectionCache.removeValue(for: cacheKey)
        }

        guard let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
                  sessionID: ownerID,
                  bindings: bindings,
                  visibleRoots: visibleRoots
              ),
              !projection.isEmpty,
              projection.isFullyMaterialized
        else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }

        switch await store.rootScopeAvailability(projection.lookupRootScope) {
        case .available:
            let context = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
            projectionCache.store(context, for: cacheKey)
            return context
        case .sessionWorktreeUnavailable:
            projectionCache.removeValue(for: cacheKey)
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
    }

    static func canReuseAuthoritativeLookupContext(
        _ lookupContext: WorkspaceLookupContext,
        source: AgentWorkspaceLookupContextSource,
        visibleRoots suppliedVisibleRoots: [WorkspaceRootRef]? = nil,
        store: WorkspaceFileContextStore
    ) async -> Bool {
        guard !Task.isCancelled,
              let ownerID = source.worktreeOwnerID,
              case let .hydrated(bindings) = source.worktreeBindingState,
              !bindings.isEmpty,
              let projection = lookupContext.bindingProjection,
              projection.sessionID == ownerID,
              projection.isFullyMaterialized,
              lookupContext.rootScope == projection.lookupRootScope,
              AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(bindings)
              == AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(
                  projection.boundRootsForMetadata.map(\.binding)
              )
        else { return false }

        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)
        } catch {
            return false
        }

        let visibleRoots = if let suppliedVisibleRoots {
            suppliedVisibleRoots
        } else {
            await store.rootRefs(scope: .visibleWorkspace)
        }
        guard !Task.isCancelled else { return false }
        let visibleRootIDsByPath = Dictionary(
            visibleRoots.map { ($0.standardizedFullPath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        guard Set(projection.visibleLogicalRootRefs) == Set(visibleRoots), projection.logicalRootRefs.allSatisfy({ visibleRootIDsByPath[$0.standardizedFullPath] == $0.id }) else {
            return false
        }

        let sessionRootSnapshot = await store.sessionBoundRootScopeValidationSnapshot(
            projection.lookupRootScope,
            expectedPhysicalRoots: projection.physicalRootRefs
        )
        guard !Task.isCancelled, let sessionRootSnapshot else { return false }
        return sessionRootSnapshot.isGenerationCurrent()
    }

    static func authoritativeLookupContextOrFailClosed(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        do {
            return try await requiredLookupContext(source: source, store: store)
        } catch {
            return failClosedLookupContext
        }
    }

    /// Permissive resolution is reserved for non-authoritative UI consumers.
    static func lookupContext(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        let startMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        var fields: [String: String] = [
            "activeAgentSessionID": AgentSelectedFilesDiagnostics.shortID(source.activeAgentSessionID),
            "worktreeOwnerID": AgentSelectedFilesDiagnostics.shortID(source.worktreeOwnerID),
            "bindingState": String(describing: source.worktreeBindingState),
            "bindingCount": String(source.worktreeBindings.count),
            "bindingFingerprint": String(source.identity.worktreeBindingFingerprint.prefix(16))
        ]
        AgentSelectedFilesDiagnostics.event("lookupResolver.lookupContext.start", fields: fields)
        guard let ownerID = source.worktreeOwnerID,
              case let .hydrated(bindings) = source.worktreeBindingState,
              !bindings.isEmpty
        else {
            fields["result"] = "visibleWorkspace"
            AgentSelectedFilesDiagnostics.durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
            return WorkspaceLookupContext.visibleWorkspace
        }

        let cacheKey = CacheKey(storeID: ObjectIdentifier(store), identity: source.identity)
        if let cached = projectionCache.context(for: cacheKey) {
            if await canReuseAuthoritativeLookupContext(cached, source: source, store: store) {
                fields["result"] = "cachedProjection"
                fields["physicalRoots"] = String(cached.bindingProjection?.physicalRootRefs.count ?? 0)
                fields["fullyMaterialized"] = String(cached.bindingProjection?.isFullyMaterialized ?? false)
                AgentSelectedFilesDiagnostics.durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
                return cached
            }
            projectionCache.removeValue(for: cacheKey)
        }

        guard let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
                  sessionID: ownerID,
                  bindings: bindings
              ),
              !projection.isEmpty
        else {
            fields["result"] = "visibleWorkspace"
            AgentSelectedFilesDiagnostics.durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
            return WorkspaceLookupContext.visibleWorkspace
        }
        fields["result"] = "projection"
        fields["physicalRoots"] = String(projection.physicalRootRefs.count)
        fields["fullyMaterialized"] = String(projection.isFullyMaterialized)
        AgentSelectedFilesDiagnostics.durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
        let context = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        projectionCache.store(context, for: cacheKey)
        return context
    }
}

enum AgentWorkspaceLookupContextResolutionError: LocalizedError {
    case unavailableProjection
    /// A bound worktree folder failed the runtime availability check. Its description matches
    /// `.unavailableProjection` so callers that forward it as text never show the worktree path.
    case unavailableWorktree(AgentWorktreeRuntimeWorkspaceError)
    case unknownBindingState

    var errorDescription: String? {
        switch self {
        case .unavailableProjection, .unavailableWorktree:
            "The Agent session worktree projection is unavailable. The operation stopped rather than falling back to the canonical checkout."
        case .unknownBindingState:
            "The Agent session worktree bindings are not hydrated or are unavailable. The operation stopped rather than falling back to the canonical checkout."
        }
    }
}
