import Darwin
import Foundation

private enum MCPApplicationSupportRootResolver {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var testOverride: URL?
    private static let xctestSandboxRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoPromptCE-XCTest-\(getpid())-\(UUID().uuidString)", isDirectory: true)

    /// Only a test runner loads XCTest, and the Objective-C runtime reports that
    /// independently of how the runner was launched. Launch-shaped signals are not
    /// portable: `swift test` exports none of the `XCTest*` variables Xcode's runner
    /// sets, and passes `-XCTest` only when the run is filtered.
    static let isXCTestRuntime = NSClassFromString("XCTestCase") != nil

    static func resolve(
        directoryName: String,
        fileManager: FileManager,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestProcess: Bool = isXCTestRuntime
    ) -> URL {
        if let override = lock.withLock({ testOverride }) {
            return override
        }
        if isXCTestProcess {
            // Deriving the profile from the suite sandbox keeps independently sharded test processes disjoint.
            if let sandboxRoot = environment["REPOPROMPT_TEST_SANDBOX_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !sandboxRoot.isEmpty
            {
                return URL(fileURLWithPath: sandboxRoot, isDirectory: true)
                    .appendingPathComponent("profile", isDirectory: true)
                    .appendingPathComponent(directoryName, isDirectory: true)
            }
            // A sandbox creation failure must surface through later file writes rather than expose the live profile.
            try? fileManager.createDirectory(at: xctestSandboxRoot, withIntermediateDirectories: true)
            return xctestSandboxRoot
                .appendingPathComponent("profile", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        }
        if let homeDirectory {
            return homeDirectory
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// A test-scoped profile keeps its temporary state inside that profile, so independently
    /// sharded test processes never share one flavor-wide temporary namespace.
    static func resolveTemporaryRoot(
        directoryName: String,
        temporaryDirectory: URL,
        fileManager: FileManager,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestProcess: Bool = isXCTestRuntime
    ) -> URL {
        guard isTestScoped(isXCTestProcess: isXCTestProcess) else {
            return temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        }
        return resolve(
            directoryName: directoryName,
            fileManager: fileManager,
            environment: environment,
            isXCTestProcess: isXCTestProcess
        ).appendingPathComponent("Temporary", isDirectory: true)
    }

    static func isTestScoped(isXCTestProcess: Bool = isXCTestRuntime) -> Bool {
        lock.withLock { testOverride } != nil || isXCTestProcess
    }

    static func setTestOverride(_ url: URL?) {
        lock.withLock {
            testOverride = url?.standardizedFileURL
        }
    }
}

/// Shared filesystem and stable-name authority for RepoPrompt MCP products.
///
/// Callers select their build flavor locally and pass it explicitly so this
/// shared target never depends on compile-configuration conditionals.
public struct MCPFilesystemIdentity: Equatable, Sendable {
    public enum Product: String, Sendable {
        case repoPromptCE
    }

    public enum BuildFlavor: String, Sendable {
        case debug
        case release
    }

    public static let currentProtocolVersion = 7

    public let product: Product
    public let buildFlavor: BuildFlavor
    public let protocolVersion: Int

    public init(
        product: Product,
        buildFlavor: BuildFlavor,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.product = product
        self.buildFlavor = buildFlavor
        self.protocolVersion = protocolVersion
    }

    public static func repoPromptCE(_ buildFlavor: BuildFlavor) -> Self {
        Self(product: .repoPromptCE, buildFlavor: buildFlavor)
    }

    /// True when profile paths resolve to a test-owned location, an explicit test override or the
    /// loaded-XCTest sandbox, rather than the user's profile.
    public static var resolvesTestScopedProfile: Bool {
        MCPApplicationSupportRootResolver.isTestScoped()
    }

    public var socketDirectoryName: String {
        switch product {
        case .repoPromptCE:
            "repoprompt-ce-mcp"
        }
    }

    public var bootstrapSocketName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            "repoprompt-ce-D-\(protocolVersion).sock"
        case (.repoPromptCE, .release):
            "repoprompt-ce-\(protocolVersion).sock"
        }
    }

    public var externalEventsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            "MCPEvents-CE-D-\(protocolVersion)"
        case (.repoPromptCE, .release):
            "MCPEvents-CE-\(protocolVersion)"
        }
    }

    public var applicationSupportDirectoryName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            "RepoPrompt CE Debug"
        case (.repoPromptCE, .release):
            "RepoPrompt CE"
        }
    }

    public var killSignalsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.repoPromptCE, .debug):
            "MCPKillSignals-CE-D-\(protocolVersion)"
        case (.repoPromptCE, .release):
            "MCPKillSignals-CE-\(protocolVersion)"
        }
    }

    public var stableWrapperConfigFileName: String {
        switch buildFlavor {
        case .debug:
            "discovery_debug.json"
        case .release:
            "discovery.json"
        }
    }

    public var networkConfigFileName: String {
        switch buildFlavor {
        case .debug:
            "mcp-config_debug.json"
        case .release:
            "mcp-config.json"
        }
    }

    public var routingStateFileName: String {
        switch buildFlavor {
        case .debug:
            "mcp-routing_debug.json"
        case .release:
            "mcp-routing.json"
        }
    }

    public var userSpaceCLIFileName: String {
        switch buildFlavor {
        case .debug:
            "repoprompt_ce_cli_debug"
        case .release:
            "repoprompt_ce_cli"
        }
    }

    public var pathCLICommandName: String {
        switch buildFlavor {
        case .debug:
            "rpce-cli-debug"
        case .release:
            "rpce-cli"
        }
    }

    public var claudeWrapperCommandName: String {
        switch buildFlavor {
        case .debug:
            "claude-rpce-debug"
        case .release:
            "claude-rpce"
        }
    }

    public func socketDirectoryURL(userID: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/tmp/\(socketDirectoryName)-\(userID)", isDirectory: true)
    }

    public func bootstrapSocketURL(userID: uid_t = getuid()) -> URL {
        socketDirectoryURL(userID: userID).appendingPathComponent(bootstrapSocketName, isDirectory: false)
    }

    public func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        MCPApplicationSupportRootResolver.resolve(
            directoryName: applicationSupportDirectoryName,
            fileManager: fileManager
        )
    }

    /// Resolves the profile under a caller-supplied home directory. Test overrides and the XCTest
    /// sandbox keep precedence, exactly as for the default-location overload.
    public func applicationSupportRootURL(homeDirectory: URL, fileManager: FileManager = .default) -> URL {
        MCPApplicationSupportRootResolver.resolve(
            directoryName: applicationSupportDirectoryName,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
    }

    #if DEBUG
        @_spi(TestSupport)
        public static func test_setApplicationSupportRootOverride(_ url: URL?) {
            MCPApplicationSupportRootResolver.setTestOverride(url)
        }

        @_spi(TestSupport)
        public static var test_isRunningUnderXCTest: Bool {
            MCPApplicationSupportRootResolver.isXCTestRuntime
        }

        @_spi(TestSupport)
        public func test_applicationSupportRootURL(
            fileManager: FileManager = .default,
            homeDirectory: URL? = nil,
            environment: [String: String],
            isXCTestProcess: Bool = MCPFilesystemIdentity.test_isRunningUnderXCTest
        ) -> URL {
            MCPApplicationSupportRootResolver.resolve(
                directoryName: applicationSupportDirectoryName,
                fileManager: fileManager,
                homeDirectory: homeDirectory,
                environment: environment,
                isXCTestProcess: isXCTestProcess
            )
        }

        @_spi(TestSupport)
        public func test_temporaryRootURL(
            temporaryDirectory: URL,
            fileManager: FileManager = .default,
            environment: [String: String],
            isXCTestProcess: Bool = MCPFilesystemIdentity.test_isRunningUnderXCTest
        ) -> URL {
            MCPApplicationSupportRootResolver.resolveTemporaryRoot(
                directoryName: applicationSupportDirectoryName,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager,
                environment: environment,
                isXCTestProcess: isXCTestProcess
            )
        }
    #endif

    public func temporaryRootURL(fileManager: FileManager = .default) -> URL {
        temporaryRootURL(temporaryDirectory: fileManager.temporaryDirectory, fileManager: fileManager)
    }

    public func temporaryRootURL(temporaryDirectory: URL, fileManager: FileManager = .default) -> URL {
        MCPApplicationSupportRootResolver.resolveTemporaryRoot(
            directoryName: applicationSupportDirectoryName,
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )
    }

    public func configDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent("MCP", isDirectory: true)
    }

    public func stableWrapperConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(stableWrapperConfigFileName, isDirectory: false)
    }

    public func launchConfigDirectoryURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("LaunchConfigs", isDirectory: true)
    }

    public func externalEventsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(externalEventsDirectoryName, isDirectory: true)
    }

    public func killSignalsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(killSignalsDirectoryName, isDirectory: true)
    }

    public func networkConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(networkConfigFileName, isDirectory: false)
    }

    public func routingStateURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(routingStateFileName, isDirectory: false)
    }

    public func userSpaceCLIURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("RepoPrompt", isDirectory: true)
            .appendingPathComponent(userSpaceCLIFileName, isDirectory: false)
    }
}

// MARK: - Debug profile isolation

/// A debug-owned state location that cannot be used without risking production state.
public enum MCPProfileIsolationError: Error, Equatable, Sendable {
    case invalidPath(URL)
    case overlapsProduction(URL)
    case uninspectablePath(URL)
}

extension MCPProfileIsolationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidPath(url):
            "Debug profile isolation: \(url.path) is not an absolute file path. "
                + "Use an absolute directory that is separate from the production RepoPrompt CE profile."
        case let .overlapsProduction(url):
            "Debug profile isolation: \(url.path) resolves to, contains, or lies inside production "
                + "RepoPrompt CE state. Debug builds keep their own state and never write production state. "
                + "Remove the symlink or override that points there, then relaunch."
        case let .uninspectablePath(url):
            "Debug profile isolation: \(url.path) cannot be inspected. "
                + "Fix its permissions or remove it, then relaunch."
        }
    }
}

/// Path-component containment over symlink-resolved locations.
///
/// Resolved locations are compared exactly as `realpath` spells them. Standardizing them again
/// would strip a leading `/private` only when the stripped path exists, so an existing root and
/// its not-yet-created child under `/tmp` or `/var` would stop comparing as parent and child.
public enum MCPFilesystemPathContainment {
    /// Resolves symlinks in the longest existing prefix of `url` and re-appends the not-yet-created
    /// tail, so a location is compared where a write would actually land.
    public static func resolvedLocation(of url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw MCPProfileIsolationError.invalidPath(url)
        }
        var existing = standardized
        var missingComponents: [String] = []
        while existing.path != "/" {
            var status = Darwin.stat()
            if lstat(existing.path, &status) == 0 { break }
            guard errno == ENOENT || errno == ENOTDIR else {
                throw MCPProfileIsolationError.uninspectablePath(url)
            }
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let resolvedPath = realpath(existing.path, nil) else {
            throw MCPProfileIsolationError.uninspectablePath(url)
        }
        defer { free(resolvedPath) }
        var resolved = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    /// Compares path components of two resolved locations, so `RepoPrompt CE Debug` is never
    /// treated as inside `RepoPrompt CE`.
    public static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// The store-side check of profile isolation: true when `location`, with every existing
    /// symlink along it resolved, including a symlink at `location` itself, lies strictly inside
    /// `root`. A store calls it where it resolves a location, before reading, writing, or deleting
    /// there, and refuses through its own error. A location that cannot be inspected is outside.
    public static func resolvesStrictlyInside(_ location: URL, root: URL) -> Bool {
        guard let resolvedRoot = try? resolvedLocation(of: root),
              let candidate = try? resolvedLocation(of: location)
        else { return false }
        return candidate.pathComponents.count > resolvedRoot.pathComponents.count
            && isSameOrDescendant(candidate, of: resolvedRoot)
    }
}

public extension MCPFilesystemIdentity {
    /// The saved-prompt folder name. Release keeps it directly under Application Support, shared
    /// with pre-CE builds; the debug build keeps the same name inside its own profile.
    static let sharedPromptDirectoryName = "com.pvncher.repoprompt"

    /// Production state that a debug-owned location must never equal, contain, or lie inside: the
    /// canonical release profile, the release runtime temporary root, and the release prompt
    /// folder. Callers that resolve a profile under an injected home or temporary directory pass
    /// the same inputs here.
    static func productionStateRoots(
        product: Product = .repoPromptCE,
        homeDirectory: URL? = nil,
        temporaryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        let releaseDirectoryName = Self(product: product, buildFlavor: .release).applicationSupportDirectoryName
        let applicationSupport = homeDirectory.map {
            $0.appendingPathComponent("Library/Application Support", isDirectory: true)
        } ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            applicationSupport.appendingPathComponent(releaseDirectoryName, isDirectory: true),
            (temporaryDirectory ?? fileManager.temporaryDirectory)
                .appendingPathComponent(releaseDirectoryName, isDirectory: true),
            applicationSupport.appendingPathComponent(sharedPromptDirectoryName, isDirectory: true)
        ]
    }

    /// Rejects debug-owned locations that resolve to, contain, or lie inside production state.
    ///
    /// Read-only and constant-size: it inspects the supplied locations, never repository files, and
    /// performs no repair, move, delete, or fallback read. Replacing a location after it passed is
    /// outside this check.
    static func validateDebugProfileLocations(
        profileRoot: URL,
        temporaryRoot: URL,
        managedStateURLs: [URL],
        productionStateRoots: [URL]
    ) throws {
        let protectedRoots = try productionStateRoots.map(MCPFilesystemPathContainment.resolvedLocation(of:))
        for location in [profileRoot, temporaryRoot] + managedStateURLs {
            let resolved = try MCPFilesystemPathContainment.resolvedLocation(of: location)
            for protectedRoot in protectedRoots
                where MCPFilesystemPathContainment.isSameOrDescendant(resolved, of: protectedRoot)
                || MCPFilesystemPathContainment.isSameOrDescendant(protectedRoot, of: resolved)
            {
                throw MCPProfileIsolationError.overlapsProduction(location)
            }
        }
    }

    /// Validates this flavor's default profile before any profile-backed store starts. Release
    /// state is the production profile itself and is not validated.
    ///
    /// The immediate entries of the profile and of the temporary root are checked as managed
    /// locations, so an existing top-level symlink into production is caught without maintaining a
    /// list of store names. Fixed locations below a top-level entry are checked where they are
    /// declared: this identity's MCP files plus `managedStateURLs` from the stores that own them, so
    /// a symlinked file or directory deeper in the profile is caught without scanning it.
    /// Tests supply their own protected roots instead of resolving both flavors through one override.
    func validateProfileIsolation(
        managedStateURLs: [URL] = [],
        productionStateRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard buildFlavor == .debug else { return }
        let profileRoot = applicationSupportRootURL(fileManager: fileManager)
        let temporaryRoot = temporaryRootURL(fileManager: fileManager)
        let productionRoots = productionStateRoots
            ?? Self.productionStateRoots(product: product, fileManager: fileManager)
        // The root is checked before its entries are listed, so a root aliased into production is
        // rejected without enumerating production's directory.
        try Self.validateDebugProfileLocations(
            profileRoot: profileRoot,
            temporaryRoot: temporaryRoot,
            managedStateURLs: [],
            productionStateRoots: productionRoots
        )
        try Self.validateDebugProfileLocations(
            profileRoot: profileRoot,
            temporaryRoot: temporaryRoot,
            managedStateURLs: Self.immediateEntries(of: profileRoot, fileManager: fileManager)
                + Self.immediateEntries(of: temporaryRoot, fileManager: fileManager)
                + [
                    launchConfigDirectoryURL(fileManager: fileManager),
                    stableWrapperConfigURL(fileManager: fileManager),
                    routingStateURL(fileManager: fileManager),
                    networkConfigURL(fileManager: fileManager)
                ]
                + managedStateURLs,
            productionStateRoots: productionRoots
        )
    }

    private static func immediateEntries(of directory: URL, fileManager: FileManager) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw MCPProfileIsolationError.uninspectablePath(directory)
        }
    }
}
