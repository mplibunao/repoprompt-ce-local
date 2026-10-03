import Foundation
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
@_spi(TestSupport) import RepoPromptShared
import XCTest

#if DEBUG
    final class MCPFilesystemIdentityIsolationTests: XCTestCase {
        private var fixtureRoot: URL!

        private var home: URL {
            fixtureRoot.appendingPathComponent("home", isDirectory: true)
        }

        private var temporary: URL {
            fixtureRoot.appendingPathComponent("tmp", isDirectory: true)
        }

        private var productionProfile: URL {
            home.appendingPathComponent("Library/Application Support/RepoPrompt CE", isDirectory: true)
        }

        private var productionTemporary: URL {
            temporary.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        }

        override func setUpWithError() throws {
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(nil)
            fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPFilesystemIdentityIsolationTests-\(UUID().uuidString)", isDirectory: true)
            for directory in ["Workspaces", "Settings"] {
                try FileManager.default.createDirectory(
                    at: productionProfile.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            try FileManager.default.createDirectory(at: productionTemporary, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(nil)
            if let fixtureRoot {
                makeTreeWritable(fixtureRoot)
                try? FileManager.default.removeItem(at: fixtureRoot)
            }
        }

        // MARK: - Exact names and locations

        func testReleaseValuesStayByteIdentical() {
            let release = MCPFilesystemIdentity.repoPromptCE(.release)
            XCTAssertEqual(release.applicationSupportDirectoryName, "RepoPrompt CE")
            XCTAssertEqual(release.bootstrapSocketURL(userID: 501).path, "/tmp/repoprompt-ce-mcp-501/repoprompt-ce-7.sock")
            XCTAssertEqual(release.externalEventsDirectoryName, "MCPEvents-CE-7")
            XCTAssertEqual(release.killSignalsDirectoryName, "MCPKillSignals-CE-7")
            XCTAssertEqual(release.stableWrapperConfigFileName, "discovery.json")
            XCTAssertEqual(release.networkConfigFileName, "mcp-config.json")
            XCTAssertEqual(release.routingStateFileName, "mcp-routing.json")
            XCTAssertEqual(release.userSpaceCLIFileName, "repoprompt_ce_cli")
            XCTAssertEqual(release.pathCLICommandName, "rpce-cli")
            XCTAssertEqual(release.claudeWrapperCommandName, "claude-rpce")

            let releaseHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
            XCTAssertEqual(
                release.test_applicationSupportRootURL(homeDirectory: releaseHome, environment: [:], isXCTestProcess: false).path,
                "/Users/example/Library/Application Support/RepoPrompt CE"
            )
            XCTAssertEqual(
                release.test_temporaryRootURL(
                    temporaryDirectory: URL(fileURLWithPath: "/private/tmp/example", isDirectory: true),
                    environment: [:],
                    isXCTestProcess: false
                ).path,
                "/private/tmp/example/RepoPrompt CE"
            )
            XCTAssertEqual(
                MCPFilesystemIdentity.productionStateRoots(
                    homeDirectory: releaseHome,
                    temporaryDirectory: URL(fileURLWithPath: "/private/tmp/example", isDirectory: true)
                ).map(\.path),
                [
                    "/Users/example/Library/Application Support/RepoPrompt CE",
                    "/private/tmp/example/RepoPrompt CE",
                    "/Users/example/Library/Application Support/com.pvncher.repoprompt"
                ]
            )
        }

        func testDebugProfileDefaultsToItsOwnSiblingDirectory() {
            let debug = MCPFilesystemIdentity.repoPromptCE(.debug)
            let debugHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
            XCTAssertEqual(debug.applicationSupportDirectoryName, "RepoPrompt CE Debug")
            XCTAssertEqual(
                debug.test_applicationSupportRootURL(homeDirectory: debugHome, environment: [:], isXCTestProcess: false).path,
                "/Users/example/Library/Application Support/RepoPrompt CE Debug"
            )
            XCTAssertEqual(
                debug.test_temporaryRootURL(
                    temporaryDirectory: URL(fileURLWithPath: "/private/tmp/example", isDirectory: true),
                    environment: [:],
                    isXCTestProcess: false
                ).path,
                "/private/tmp/example/RepoPrompt CE Debug"
            )
            XCTAssertEqual(debug.bootstrapSocketURL(userID: 501).path, "/tmp/repoprompt-ce-mcp-501/repoprompt-ce-D-7.sock")
            XCTAssertEqual(debug.pathCLICommandName, "rpce-cli-debug")
            XCTAssertEqual(debug.userSpaceCLIFileName, "repoprompt_ce_cli_debug")
        }

        func testXCTestSandboxKeepsAFlavorSpecificProfileAndTemporaryRoot() {
            let sandbox = fixtureRoot.appendingPathComponent("sandbox", isDirectory: true)
            let environment = ["REPOPROMPT_TEST_SANDBOX_ROOT": sandbox.path]
            for (flavor, name) in [(MCPFilesystemIdentity.BuildFlavor.debug, "RepoPrompt CE Debug"), (.release, "RepoPrompt CE")] {
                let identity = MCPFilesystemIdentity.repoPromptCE(flavor)
                let profile = sandbox.appendingPathComponent("profile/\(name)", isDirectory: true)
                XCTAssertEqual(
                    identity.test_applicationSupportRootURL(environment: environment, isXCTestProcess: true).standardizedFileURL,
                    profile.standardizedFileURL
                )
                XCTAssertEqual(
                    identity.test_temporaryRootURL(
                        temporaryDirectory: temporary,
                        environment: environment,
                        isXCTestProcess: true
                    ).standardizedFileURL,
                    profile.appendingPathComponent("Temporary", isDirectory: true).standardizedFileURL
                )
            }
        }

        func testExplicitOverrideIsTheCompleteRootForEitherFlavor() {
            let override = fixtureRoot.appendingPathComponent("override-profile", isDirectory: true)
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(override)
            for flavor in [MCPFilesystemIdentity.BuildFlavor.debug, .release] {
                let identity = MCPFilesystemIdentity.repoPromptCE(flavor)
                XCTAssertEqual(
                    identity.test_applicationSupportRootURL(homeDirectory: home, environment: [:], isXCTestProcess: false),
                    override.standardizedFileURL
                )
                XCTAssertEqual(
                    identity.test_temporaryRootURL(temporaryDirectory: temporary, environment: [:], isXCTestProcess: false),
                    override.standardizedFileURL.appendingPathComponent("Temporary", isDirectory: true)
                )
            }
            XCTAssertTrue(MCPFilesystemIdentity.resolvesTestScopedProfile)
        }

        func testCLIAdapterSelectsTheCompiledDebugFlavor() {
            XCTAssertEqual(RepoPromptMCP.MCPFilesystemConstants.identity, .repoPromptCE(.debug))
        }

        // MARK: - Location validation

        func testValidationRejectsLocationsThatOverlapProduction() throws {
            let alias = fixtureRoot.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: productionProfile)
            let separate = fixtureRoot.appendingPathComponent("separate-debug", isDirectory: true)
            try FileManager.default.createDirectory(at: separate, withIntermediateDirectories: true)
            let workspacesLink = separate.appendingPathComponent("Workspaces", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: workspacesLink,
                withDestinationURL: productionProfile.appendingPathComponent("Workspaces", isDirectory: true)
            )
            let cases: [(String, URL, [URL], URL)] = [
                ("alias symlink", alias, [], alias),
                ("inside production", productionProfile.appendingPathComponent("nested", isDirectory: true), [], productionProfile.appendingPathComponent("nested", isDirectory: true)),
                ("contains production", productionProfile.deletingLastPathComponent(), [], productionProfile.deletingLastPathComponent()),
                ("managed symlink", separate, [workspacesLink], workspacesLink)
            ]

            for (label, profileRoot, managed, rejected) in cases {
                XCTAssertThrowsError(try MCPFilesystemIdentity.validateDebugProfileLocations(
                    profileRoot: profileRoot,
                    temporaryRoot: fixtureRoot.appendingPathComponent("debug-tmp", isDirectory: true),
                    managedStateURLs: managed,
                    productionStateRoots: [productionProfile, productionTemporary]
                ), label) { error in
                    XCTAssertEqual(error as? MCPProfileIsolationError, .overlapsProduction(rejected), label)
                }
            }

            XCTAssertThrowsError(try MCPFilesystemIdentity.validateDebugProfileLocations(
                profileRoot: separate,
                temporaryRoot: productionTemporary,
                managedStateURLs: [],
                productionStateRoots: [productionProfile, productionTemporary]
            )) { error in
                XCTAssertEqual(error as? MCPProfileIsolationError, .overlapsProduction(self.productionTemporary))
            }
        }

        func testValidationAcceptsPrefixLookalikesAndNotYetCreatedLocations() throws {
            let lookalike = home.appendingPathComponent("Library/Application Support/RepoPrompt CE Debug", isDirectory: true)
            XCTAssertNoThrow(try MCPFilesystemIdentity.validateDebugProfileLocations(
                profileRoot: lookalike,
                temporaryRoot: temporary.appendingPathComponent("RepoPrompt CE Debug", isDirectory: true),
                managedStateURLs: [lookalike.appendingPathComponent("Workspaces/Not Yet Created", isDirectory: true)],
                productionStateRoots: [productionProfile, productionTemporary]
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: lookalike.path))
        }

        func testValidationReportsRelativeAndUninspectableLocations() throws {
            let relative = try XCTUnwrap(URL(string: "relative/profile"))
            XCTAssertThrowsError(try MCPFilesystemPathContainment.resolvedLocation(of: relative)) { error in
                XCTAssertEqual(error as? MCPProfileIsolationError, .invalidPath(relative))
            }

            try XCTSkipIf(getuid() == 0, "root bypasses directory permissions")
            let locked = fixtureRoot.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            let inside = locked.appendingPathComponent("child/profile", isDirectory: true)
            XCTAssertThrowsError(try MCPFilesystemIdentity.validateDebugProfileLocations(
                profileRoot: inside,
                temporaryRoot: fixtureRoot.appendingPathComponent("debug-tmp", isDirectory: true),
                managedStateURLs: [],
                productionStateRoots: [productionProfile]
            )) { error in
                XCTAssertEqual(error as? MCPProfileIsolationError, .uninspectablePath(inside))
            }
        }

        func testProfileValidationChecksTopLevelEntriesAndSkipsRelease() throws {
            let debugProfile = fixtureRoot.appendingPathComponent("debug-profile", isDirectory: true)
            try FileManager.default.createDirectory(at: debugProfile, withIntermediateDirectories: true)
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugProfile)
            XCTAssertNoThrow(try MCPFilesystemIdentity.repoPromptCE(.debug).validateProfileIsolation(
                productionStateRoots: [productionProfile, productionTemporary]
            ))

            let settingsLink = debugProfile.appendingPathComponent("Settings", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: settingsLink,
                withDestinationURL: productionProfile.appendingPathComponent("Settings", isDirectory: true)
            )
            XCTAssertThrowsError(try MCPFilesystemIdentity.repoPromptCE(.debug).validateProfileIsolation(
                productionStateRoots: [productionProfile, productionTemporary]
            )) { error in
                guard case let .overlapsProduction(location)? = error as? MCPProfileIsolationError else {
                    return XCTFail("Expected overlapsProduction, got \(error)")
                }
                XCTAssertEqual(location.lastPathComponent, "Settings")
            }
            XCTAssertNoThrow(try MCPFilesystemIdentity.repoPromptCE(.release).validateProfileIsolation(
                productionStateRoots: [productionProfile, productionTemporary]
            ))
        }

        func testProfileValidationChecksTemporaryRootEntries() throws {
            let debugProfile = fixtureRoot.appendingPathComponent("debug-profile", isDirectory: true)
            try FileManager.default.createDirectory(at: debugProfile, withIntermediateDirectories: true)
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugProfile)
            let identity = MCPFilesystemIdentity.repoPromptCE(.debug)
            // A test-scoped profile keeps its temporary root inside the profile.
            let temporaryRoot = identity.temporaryRootURL()
            let productionLog = productionTemporary.appendingPathComponent("claude-reasoning-debug.log")
            try Data("production".utf8).write(to: productionLog)
            let logLink = temporaryRoot.appendingPathComponent("claude-reasoning-debug.log")
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: logLink, withDestinationURL: productionLog)

            XCTAssertThrowsError(try identity.validateProfileIsolation(
                productionStateRoots: [productionProfile, productionTemporary]
            )) { error in
                guard case let .overlapsProduction(location)? = error as? MCPProfileIsolationError else {
                    return XCTFail("Expected overlapsProduction, got \(error)")
                }
                XCTAssertEqual(location.lastPathComponent, "claude-reasoning-debug.log")
            }
            XCTAssertEqual(try Data(contentsOf: productionLog), Data("production".utf8))
        }

        /// Installs a production sentinel and a debug-profile symlink pointing at its target.
        ///
        /// `sentinelURL` stays separate from `targetURL` because a directory link keeps its
        /// sentinel inside the target directory, while a file link writes the target itself.
        private func installProductionSymlink(
            at linkURL: URL,
            to targetURL: URL,
            sentinelURL: URL,
            contents: String
        ) throws {
            try FileManager.default.createDirectory(
                at: sentinelURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: sentinelURL)
            try FileManager.default.createDirectory(
                at: linkURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        }

        func testProfileValidationChecksTheManagedDiscoveryConfiguration() throws {
            let debugProfile = fixtureRoot.appendingPathComponent("debug-profile", isDirectory: true)
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugProfile)
            let identity = MCPFilesystemIdentity.repoPromptCE(.debug)
            let productionDiscovery = productionProfile.appendingPathComponent("MCP/discovery.json")
            // The debug MCP folder is real; only its discovery configuration links to production's.
            let discoveryLink = identity.stableWrapperConfigURL()
            XCTAssertEqual(discoveryLink.lastPathComponent, "discovery_debug.json")
            try installProductionSymlink(
                at: discoveryLink,
                to: productionDiscovery,
                sentinelURL: productionDiscovery,
                contents: "production"
            )

            XCTAssertThrowsError(try identity.validateProfileIsolation(
                productionStateRoots: [productionProfile, productionTemporary]
            )) { error in
                guard case let .overlapsProduction(location)? = error as? MCPProfileIsolationError else {
                    return XCTFail("Expected overlapsProduction, got \(error)")
                }
                XCTAssertEqual(location.lastPathComponent, "discovery_debug.json")
            }
            XCTAssertEqual(try Data(contentsOf: productionDiscovery), Data("production".utf8))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: discoveryLink.path),
                productionDiscovery.path
            )
        }

        // MARK: - Headless resolver

        func testHeadlessDefaultsMatchPolicyAdministrationForEachFlavor() throws {
            for flavor in [MCPFilesystemIdentity.BuildFlavor.debug, .release] {
                let identity = MCPFilesystemIdentity.repoPromptCE(flavor)
                let locations = try resolveHeadless(identity: identity, environment: [:])
                let policy = RuntimePolicyAdministration.makeRuntimeConfiguration(identity: identity)
                let root = identity.applicationSupportRootURL().standardizedFileURL

                XCTAssertEqual(locations.storageDirectory.path, root.path, flavor.rawValue)
                XCTAssertEqual(policy.storageDirectory.standardizedFileURL.path, root.path, flavor.rawValue)
                XCTAssertEqual(
                    locations.workspaceStorageDirectory.standardizedFileURL,
                    policy.workspaceStorageDirectory.standardizedFileURL,
                    flavor.rawValue
                )
                XCTAssertEqual(
                    locations.temporaryDirectory.standardizedFileURL,
                    identity.temporaryRootURL().standardizedFileURL,
                    flavor.rawValue
                )
                XCTAssertEqual(
                    policy.temporaryDirectory.standardizedFileURL,
                    identity.temporaryRootURL().standardizedFileURL,
                    flavor.rawValue
                )
                XCTAssertEqual(locations.enforcesWorkspaceStorageBoundary, flavor == .debug)
                XCTAssertEqual(policy.enforcesWorkspaceStorageBoundary, flavor == .debug)
                XCTAssertTrue(root.pathComponents.contains(identity.applicationSupportDirectoryName))
            }
        }

        func testHeadlessDebugIgnoresSavedCustomStorageWhileReleaseHonorsIt() throws {
            let custom = fixtureRoot.appendingPathComponent("custom-workspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)

            let debug = try resolveHeadless(identity: .repoPromptCE(.debug), environment: [:], customWorkspaceStoragePath: custom.path)
            let release = try resolveHeadless(identity: .repoPromptCE(.release), environment: [:], customWorkspaceStoragePath: custom.path)

            XCTAssertEqual(
                debug.workspaceStorageDirectory.standardizedFileURL,
                debug.storageDirectory.appendingPathComponent("Workspaces", isDirectory: true).standardizedFileURL
            )
            XCTAssertEqual(
                release.workspaceStorageDirectory.standardizedFileURL.path,
                custom.standardizedFileURL.resolvingSymlinksInPath().path
            )
        }

        func testHeadlessExplicitDebugProfileIsValidatedBeforeAnyDirectoryExists() throws {
            let aliasParent = fixtureRoot.appendingPathComponent("alias-parent", isDirectory: true)
            try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
            let alias = aliasParent.appendingPathComponent("profile", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: productionProfile)
            let productionBefore = try FileManager.default.contentsOfDirectory(atPath: productionProfile.path)

            XCTAssertThrowsError(try resolveHeadless(
                identity: .repoPromptCE(.debug),
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": "relative/profile"]
            )) { error in
                guard case .invalidPath? = error as? MCPProfileIsolationError else {
                    return XCTFail("Expected invalidPath, got \(error)")
                }
            }
            for rejected in [
                productionProfile,
                productionProfile.appendingPathComponent("nested", isDirectory: true),
                productionProfile.deletingLastPathComponent(),
                alias
            ] {
                XCTAssertThrowsError(try resolveHeadless(
                    identity: .repoPromptCE(.debug),
                    environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": rejected.path]
                ), rejected.path) { error in
                    guard case .overlapsProduction? = error as? MCPProfileIsolationError else {
                        return XCTFail("Expected overlapsProduction for \(rejected.path), got \(error)")
                    }
                }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: productionProfile.path), productionBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: productionProfile.appendingPathComponent("nested").path))

            let explicit = fixtureRoot.appendingPathComponent("explicit-profile", isDirectory: true)
            let accepted = try resolveHeadless(
                identity: .repoPromptCE(.debug),
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": explicit.path]
            )
            XCTAssertEqual(accepted.storageDirectory.path, explicit.standardizedFileURL.resolvingSymlinksInPath().path)
            XCTAssertEqual(accepted.temporaryDirectory.lastPathComponent, "Temporary")
            XCTAssertTrue(accepted.usesExplicitProfileDirectory)
            XCTAssertTrue(accepted.enforcesWorkspaceStorageBoundary)
            XCTAssertFalse(FileManager.default.fileExists(atPath: explicit.path))
        }

        func testHeadlessExplicitProfileRejectsADomainRuntimeLinkedIntoProduction() throws {
            let productionRuntime = productionProfile.appendingPathComponent("DomainRuntime", isDirectory: true)
            let explicit = fixtureRoot.appendingPathComponent("explicit-profile", isDirectory: true)
            try installProductionSymlink(
                at: explicit.appendingPathComponent("DomainRuntime", isDirectory: true),
                to: productionRuntime,
                sentinelURL: productionRuntime.appendingPathComponent("sentinel.json"),
                contents: #"{"marker":"production"}"#
            )
            let productionBefore = try FileManager.default.subpathsOfDirectory(atPath: productionProfile.path).sorted()
            let sentinelBefore = try Data(contentsOf: productionRuntime.appendingPathComponent("sentinel.json"))
            let linkedRuntime = explicit.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("DomainRuntime", isDirectory: true)

            XCTAssertThrowsError(try resolveHeadless(
                identity: .repoPromptCE(.debug),
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": explicit.path]
            )) { error in
                guard case let .overlapsProduction(location)? = error as? MCPProfileIsolationError else {
                    return XCTFail("Expected overlapsProduction, got \(error)")
                }
                XCTAssertTrue(
                    MCPFilesystemPathContainment.isSameOrDescendant(location, of: linkedRuntime),
                    location.path
                )
            }
            XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: productionProfile.path).sorted(), productionBefore)
            XCTAssertEqual(try Data(contentsOf: productionRuntime.appendingPathComponent("sentinel.json")), sentinelBefore)
        }

        func testHeadlessExplicitProfileRejectsADomainRuntimeFileLinkedIntoProduction() throws {
            let explicit = fixtureRoot.appendingPathComponent("explicit-profile", isDirectory: true)
            let explicitRoot = explicit.standardizedFileURL.resolvingSymlinksInPath()
            let runtimeRoot = DomainRuntimeConfiguration.runtimeRootDirectory(
                storageDirectory: explicitRoot,
                profileIdentifier: "default"
            )
            let policyLink = runtimeRoot.appendingPathComponent("settings/runtime-policy.json")
            let productionPolicy = productionProfile.appendingPathComponent("runtime-policy.json")
            try installProductionSymlink(
                at: policyLink,
                to: productionPolicy,
                sentinelURL: productionPolicy,
                contents: #"{"grants":"production"}"#
            )

            XCTAssertThrowsError(try resolveHeadless(
                identity: .repoPromptCE(.debug),
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": explicit.path]
            )) { error in
                guard case let .overlapsProduction(location)? = error as? MCPProfileIsolationError else {
                    return XCTFail("Expected overlapsProduction, got \(error)")
                }
                XCTAssertEqual(location.standardizedFileURL.path, policyLink.standardizedFileURL.path)
            }
            XCTAssertEqual(try Data(contentsOf: productionPolicy), Data(#"{"grants":"production"}"#.utf8))
        }

        func testHeadlessProfileRulesAndWorkingDirectoriesAreUnchanged() throws {
            XCTAssertThrowsError(try resolveHeadless(
                identity: .repoPromptCE(.debug),
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE": "named"]
            )) { error in
                XCTAssertEqual(error as? DirectHeadlessRuntimeLocationError, .profileDirectoryRequired("named"))
            }

            let blank = try resolveHeadless(
                identity: .repoPromptCE(.debug),
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": "  \n"]
            )
            XCTAssertFalse(blank.usesExplicitProfileDirectory)
            XCTAssertEqual(
                blank.storageDirectory.path,
                MCPFilesystemIdentity.repoPromptCE(.debug).applicationSupportRootURL().standardizedFileURL.path
            )

            let repository = fixtureRoot.appendingPathComponent("repository", isDirectory: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let environment = ["REPOPROMPT_MCP_WORKING_DIRS": repository.path]
            let fromRepository = try resolveHeadless(identity: .repoPromptCE(.debug), environment: environment, currentDirectory: repository)
            let fromElsewhere = try resolveHeadless(identity: .repoPromptCE(.debug), environment: environment, currentDirectory: home)
            XCTAssertEqual(fromRepository, fromElsewhere)
            XCTAssertEqual(fromRepository.workingDirectories.map(\.path), [repository.standardizedFileURL.resolvingSymlinksInPath().path])
            XCTAssertFalse(fromRepository.mayBootstrapIsolatedWorkspace)
        }

        // MARK: - Helpers

        private func resolveHeadless(
            identity: MCPFilesystemIdentity,
            environment: [String: String],
            currentDirectory: URL? = nil,
            customWorkspaceStoragePath: String? = nil
        ) throws -> DirectHeadlessRuntimeLocations {
            try DirectHeadlessRuntimeLocationResolver.resolve(
                environment: environment,
                currentDirectory: currentDirectory ?? fixtureRoot,
                identity: identity,
                homeDirectory: home,
                temporaryDirectory: temporary,
                customWorkspaceStoragePath: customWorkspaceStoragePath
            )
        }

        private func makeTreeWritable(_ root: URL) {
            guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return }
            for case let relative as String in enumerator {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: root.appendingPathComponent(relative).path
                )
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appendingPathComponent("locked").path
            )
        }
    }
#endif
