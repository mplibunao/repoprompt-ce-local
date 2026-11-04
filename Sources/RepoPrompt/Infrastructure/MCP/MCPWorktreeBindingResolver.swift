import Foundation
import MCP

/// Turns an existing worktree of a loaded workspace root into a worktree binding without an Agent
/// session. Agent startup and worktree-scoped `create_tab` share its repository discovery, root
/// prefix, and binding construction; each keeps its own rule for which root it binds.
@MainActor
struct MCPWorktreeBindingResolver {
    /// A loaded logical root and the repository that contains it.
    struct RootRepository: Equatable {
        let logicalRoot: WorkspaceRootRef
        let repo: GitRepoDescriptor
        let backendKind: VCSBackendKind
    }

    let vcsService: VCSService
    let gitTargetResolver: GitRepoTargetResolver

    /// The repository that contains each root, in `roots` order, skipping roots outside a
    /// repository. Roots that share a repository each keep their own entry.
    func rootRepositories(_ roots: [WorkspaceRootRef]) async -> [RootRepository] {
        var result: [RootRepository] = []
        for root in roots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) {
                result.append(RootRepository(
                    logicalRoot: root,
                    repo: GitRepoDescriptor(rootURL: resolved.rootURL),
                    backendKind: resolved.backendKind
                ))
            }
        }
        return result
    }

    /// The first loaded root that a `worktree_repo_root` token names by name or path.
    static func explicitLogicalRoot(for token: String, in roots: [WorkspaceRootRef]) -> WorkspaceRootRef? {
        explicitLogicalRoots(for: token, in: roots).first
    }

    /// Every loaded root that a `worktree_repo_root` token names by name or path, in load order;
    /// roots in different folders can share a name. A token that starts with a tree specifier,
    /// such as `@main`, names no root.
    static func explicitLogicalRoots(for token: String, in roots: [WorkspaceRootRef]) -> [WorkspaceRootRef] {
        guard !token.hasPrefix("@") else { return [] }
        let canonical = standardizedPath((token as NSString).expandingTildeInPath)
        let lowered = token.lowercased()
        return roots.filter { root in
            root.name.lowercased() == lowered
                || standardizedPath(root.standardizedFullPath) == canonical
                || standardizedPath(root.fullPath) == canonical
        }
    }

    /// The logical root's path inside its repository. A binding appends it to the worktree path,
    /// so a root below the repository's top level maps to the same folder of the worktree.
    static func repositoryRelativeRootPrefix(
        logicalRoot: WorkspaceRootRef,
        repositoryRoot: URL
    ) throws -> GitRepositoryRelativeRootPrefix {
        let rootPath = StandardizedPath.absolute(logicalRoot.standardizedFullPath)
        let repositoryPath = StandardizedPath.absolute(repositoryRoot.path)
        guard rootPath == repositoryPath || rootPath.hasPrefix(repositoryPath + "/") else {
            throw MCPError.invalidParams("The logical root is outside the selected Git repository.")
        }
        let relative = rootPath == repositoryPath
            ? ""
            : String(rootPath.dropFirst(repositoryPath.count + 1))
        return try GitRepositoryRelativeRootPrefix(relative)
    }

    static func makeBinding(
        worktree: GitWorktreeDescriptor,
        logicalRoot: WorkspaceRootRef,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
        visualLabel: String?,
        visualColorHex: String?,
        replacing previous: AgentSessionWorktreeBinding?,
        source: String
    ) -> AgentSessionWorktreeBinding {
        let physicalRootPath = repositoryRelativeRootPrefix.value.isEmpty
            ? worktree.path
            : URL(fileURLWithPath: worktree.path, isDirectory: true)
            .appendingPathComponent(repositoryRelativeRootPrefix.value, isDirectory: true)
            .standardizedFileURL.path
        return AgentSessionWorktreeBinding(
            id: previous?.id ?? UUID().uuidString,
            repositoryID: worktree.repository.repositoryID,
            repoKey: worktree.repository.repoKey,
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktree.worktreeID,
            worktreeRootPath: physicalRootPath,
            worktreeName: worktree.name,
            branch: worktree.branch,
            head: worktree.head,
            visualLabel: visualLabel,
            visualColorHex: visualColorHex,
            boundAt: previous?.worktreeID == worktree.worktreeID ? previous?.boundAt ?? Date() : Date(),
            source: source
        )
    }

    private static func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

// MARK: - Worktree-scoped tabs

extension MCPWorktreeBindingResolver {
    static let tabScopeBindingSource = "manage_workspaces.create_tab"

    /// The loaded Git root a worktree-scoped tab binds. Only Git roots count, because worktrees
    /// are listed only for Git repositories. Without a token, exactly one loaded Git root must
    /// exist. A token must be the name or absolute path of exactly one loaded Git root; it takes no
    /// tree specifier, because a tab has no primary root and load order never settles a choice.
    func selectTabScopeRoot(
        repoRootToken: String?,
        loadedRoots: [WorkspaceRootRef]
    ) async throws -> RootRepository {
        let candidates = await rootRepositories(loadedRoots).filter { $0.backendKind == .git }
        guard let firstCandidate = candidates.first else {
            throw MCPCreateTabWorktreeError.noGitRoot
        }
        guard let token = repoRootToken else {
            guard candidates.count == 1 else { throw MCPCreateTabWorktreeError.severalGitRoots }
            return firstCandidate
        }
        let namedRoots = Self.explicitLogicalRoots(for: token, in: loadedRoots)
        guard namedRoots.count == 1,
              let match = candidates.first(where: { $0.logicalRoot == namedRoots[0] })
        else {
            throw MCPCreateTabWorktreeError.rootNotUnique
        }
        return match
    }

    /// The binding that scopes `root` to the worktree `selector` names, or `nil` when the selector
    /// names the root's own checkout and no projection is needed. Only the root's repository is
    /// searched. The worktree must independently resolve to the exact listed checkout of that
    /// repository, and the root's folder must exist in it. The binding takes the worktree's
    /// existing visual identity, if any, without creating one.
    func resolveExistingBinding(
        selector: String,
        root: RootRepository
    ) async throws -> AgentSessionWorktreeBinding? {
        let worktree: GitWorktreeDescriptor
        do {
            worktree = try await gitTargetResolver.resolveWorktree(
                selector: selector,
                repo: root.repo,
                allRepos: [root.repo]
            )
        } catch let error as GitRepoTargetResolverError {
            if await selectorNamesCheckoutOfAnotherRepository(selector, repo: root.repo) {
                throw MCPCreateTabWorktreeError.foreignRepository(root: root.logicalRoot)
            }
            throw MCPError.invalidParams(error.message)
        }
        try Task.checkCancellation()
        guard let currentRepo = await vcsService.resolveRepo(
            from: URL(fileURLWithPath: root.logicalRoot.standardizedFullPath)
        ), Self.samePath(currentRepo.rootURL.path, root.repo.rootPath) else {
            throw MCPCreateTabWorktreeError.authorityChanged
        }
        if Self.samePath(worktree.path, root.repo.rootPath) {
            return nil
        }
        guard Self.isDirectory(worktree.path) else {
            throw MCPCreateTabWorktreeError.folderMissing(root: root.logicalRoot)
        }
        guard await listedWorktreeIsCheckout(worktree, of: root.repo) else {
            throw MCPCreateTabWorktreeError.foreignRepository(root: root.logicalRoot)
        }
        let identity = GlobalSettingsStore.shared.worktreeVisualIdentity(
            repositoryID: worktree.repository.repositoryID,
            worktreeID: worktree.worktreeID
        )
        let binding = try Self.makeBinding(
            worktree: worktree,
            logicalRoot: root.logicalRoot,
            repositoryRelativeRootPrefix: Self.repositoryRelativeRootPrefix(
                logicalRoot: root.logicalRoot,
                repositoryRoot: root.repo.rootURL
            ),
            visualLabel: identity?.label,
            visualColorHex: identity?.colorHex,
            replacing: nil,
            source: Self.tabScopeBindingSource
        )
        guard Self.isDirectory(binding.worktreeRootPath) else {
            throw MCPCreateTabWorktreeError.folderMissing(root: root.logicalRoot)
        }
        return binding
    }

    /// Whether the listed worktree resolves on its own to that exact checkout of `repo`: the same
    /// common Git directory, the per-worktree Git directory the listing read, and the same
    /// worktree ID, so a checkout whose `.git` now points at another worktree of the repository
    /// doesn't pass.
    private func listedWorktreeIsCheckout(_ worktree: GitWorktreeDescriptor, of repo: GitRepoDescriptor) async -> Bool {
        let worktreeRoot = URL(fileURLWithPath: worktree.path, isDirectory: true)
        guard let resolved = await vcsService.resolveRepo(from: worktreeRoot),
              Self.samePath(resolved.rootURL.path, worktree.path),
              let worktreeLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot),
              let repoLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo.rootURL),
              let listedGitDir = worktree.gitDir
        else { return false }
        let recomputedID = GitWorktreeIdentity.worktreeID(
            repositoryID: worktree.repository.repositoryID,
            gitDir: worktreeLayout.gitDir.standardizedFileURL,
            isMain: !worktreeLayout.isLinkedWorktree,
            path: worktreeRoot
        )
        return Self.samePath(worktreeLayout.commonDir.path, repoLayout.commonDir.path)
            && Self.samePath(worktreeLayout.commonDir.path, worktree.repository.commonGitDir)
            && Self.samePath(worktreeLayout.gitDir.path, listedGitDir)
            && worktreeLayout.isLinkedWorktree == !worktree.isMain
            && recomputedID == worktree.worktreeID
    }

    /// Whether an absolute-path selector that `repo` doesn't list is a checkout of another
    /// repository, so the refusal can say so instead of reporting no match.
    private func selectorNamesCheckoutOfAnotherRepository(_ selector: String, repo: GitRepoDescriptor) async -> Bool {
        let path = (selector as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), Self.isDirectory(path),
              let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: path, isDirectory: true)),
              let selectedLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: resolved.rootURL),
              let repoLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo.rootURL)
        else { return false }
        return !Self.samePath(selectedLayout.commonDir.path, repoLayout.commonDir.path)
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        GitRepoRootAuthorization.canonicalPath(lhs) == GitRepoRootAuthorization.canonicalPath(rhs)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// The worktree arguments of a `manage_workspaces` `create_tab` call, checked before any window,
/// tab, or connection binding changes.
struct MCPCreateTabWorktreeRequest: Equatable {
    /// The existing-worktree selector; a `worktree_id` arrives as `@id:<id>`.
    let selector: String
    let repoRoot: String?

    /// Refuses the worktree arguments on any action other than `create_tab`.
    static func rejectArguments(_ args: [String: Value], forAction action: String) throws {
        guard action != "create_tab",
              MCPWorktreeArgumentName.createTabAccepted.contains(where: { args[$0] != nil })
        else { return }
        throw MCPCreateTabWorktreeError.wrongAction
    }

    /// The call's worktree request, or `nil` when it names no worktree. Agent options that create
    /// or decorate a worktree are refused rather than ignored.
    static func parse(_ args: [String: Value], mode: String) throws -> MCPCreateTabWorktreeRequest? {
        let worktree = try nonEmptyString(args, key: "worktree")
        let worktreeID = try nonEmptyString(args, key: "worktree_id")
        let repoRoot = try nonEmptyString(args, key: "worktree_repo_root")
        if worktree != nil, worktreeID != nil {
            throw MCPCreateTabWorktreeError.bothSelectors
        }
        if repoRoot != nil, worktree == nil, worktreeID == nil {
            throw MCPCreateTabWorktreeError.rootWithoutSelector
        }
        if mode == "fork", worktree != nil || worktreeID != nil {
            throw MCPCreateTabWorktreeError.selectorWithFork
        }
        let unsupported = MCPWorktreeArgumentName.createTabRefused
            .filter { args[$0] != nil }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPCreateTabWorktreeError.unsupportedArguments(unsupported)
        }
        if let worktree {
            let form = GitRepoTargetResolver.worktreeSelectorForm(worktree)
            if form.hasRepositoryPrefix {
                throw MCPCreateTabWorktreeError.repositoryPrefix
            }
            if form.namesOwnCheckout {
                throw MCPCreateTabWorktreeError.ownCheckoutSelector
            }
            return MCPCreateTabWorktreeRequest(selector: worktree, repoRoot: repoRoot)
        }
        // A worktree ID never contains `@`. One that does would be parsed again as a selector,
        // so `@branch:review` would become a branch lookup.
        if let worktreeID, worktreeID.contains("@") {
            throw MCPCreateTabWorktreeError.worktreeIDNotAnID
        }
        return worktreeID.map { MCPCreateTabWorktreeRequest(selector: "@id:\($0)", repoRoot: repoRoot) }
    }

    private static func nonEmptyString(_ args: [String: Value], key: String) throws -> String? {
        guard let value = args[key] else { return nil }
        guard case let .string(raw) = value else {
            throw MCPCreateTabWorktreeError.notNonEmptyString(key)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPCreateTabWorktreeError.notNonEmptyString(key)
        }
        return trimmed
    }
}

/// The refusals of a worktree-scoped `create_tab`.
enum MCPCreateTabWorktreeError {
    static let wrongAction = MCPError.invalidParams(
        "worktree, worktree_id, and worktree_repo_root are only valid with action='create_tab'."
    )
    static let bothSelectors = MCPError.invalidParams("worktree and worktree_id are mutually exclusive for create_tab.")
    static let rootWithoutSelector = MCPError.invalidParams(
        "worktree_repo_root requires worktree or worktree_id for create_tab."
    )
    static let selectorWithFork = MCPError.invalidParams(
        "create_tab mode='fork' inherits its source tab's worktree scope. Use mode='blank' to choose a worktree."
    )
    static let repositoryPrefix = MCPError.invalidParams(
        "create_tab worktree selectors must not include a repository prefix. Specify the loaded root with worktree_repo_root."
    )
    static let worktreeIDNotAnID = MCPError.invalidParams(
        "worktree_id must be a worktree ID, not a selector. Pass @main, @branch:<branch>, and other selector forms as worktree."
    )
    static let ownCheckoutSelector = MCPError.invalidParams(
        "create_tab can't scope a tab with @current or @wt, because they name the loaded root's own checkout. Use @main, @id:<id>, @branch:<branch>, a branch or worktree name, or an absolute worktree path."
    )
    static let severalGitRoots = MCPError.invalidParams(
        "create_tab requires worktree_repo_root when more than one loaded Git root is available. Use an exact loaded root name or absolute root path."
    )
    static let noGitRoot = MCPError.invalidParams(
        "No Git repository is available in the loaded workspace roots. Load the intended project workspace before creating a worktree-scoped tab."
    )
    static let rootNotUnique = MCPError.invalidParams(
        "worktree_repo_root must be the name or absolute path of exactly one loaded Git root in this workspace."
    )
    static let ownCheckout = MCPError.invalidParams(
        "The selected worktree is the loaded root's own checkout. Omit the worktree arguments to create an ordinary tab."
    )
    static let authorityChanged = MCPError.invalidParams(
        "The workspace or worktree binding changed while the tab was being prepared. No tab was created. Retry against the intended context."
    )

    static func notNonEmptyString(_ argument: String) -> MCPError {
        .invalidParams("\(argument) must be a non-empty string.")
    }

    static func unsupportedArguments(_ names: [String]) -> MCPError {
        .invalidParams(
            "create_tab binds an existing worktree only. Unsupported worktree arguments: \(names.joined(separator: ", "))."
        )
    }

    static func foreignRepository(root: WorkspaceRootRef) -> MCPError {
        .invalidParams(
            "The selected worktree does not belong to the repository of root '\(displayed(root.name))'. No tab was created."
        )
    }

    static func folderMissing(root: WorkspaceRootRef) -> MCPError {
        .invalidParams(
            "The selected worktree folder for root '\(displayed(root.name))' is missing or is not a directory. Choose an available worktree. No tab was created."
        )
    }

    static func partialCreation(tabName: String, contextID: UUID) -> MCPError {
        .invalidParams(
            "Tab '\(displayed(tabName))' (context_id '\(contextID.uuidString)') was created, but its worktree scope could not be loaded. It was not bound or focused. Restore the worktree or bind another tab. No canonical checkout was used."
        )
    }

    private static func displayed(_ label: String) -> String {
        MCPUnavailableWorktreeDiagnostic.displayValue(label) ?? ""
    }
}
