@_spi(TestSupport) import RepoPromptShared
import XCTest

final class MCPFilesystemIdentityTests: XCTestCase {
    override func tearDown() {
        MCPFilesystemIdentity.test_setApplicationSupportRootOverride(nil)
        super.tearDown()
    }

    func testXCTestWithoutExplicitSandboxUsesProcessTemporaryRoot() {
        MCPFilesystemIdentity.test_setApplicationSupportRootOverride(nil)
        var baseEnvironment = ProcessInfo.processInfo.environment
        baseEnvironment.removeValue(forKey: "REPOPROMPT_TEST_SANDBOX_ROOT")
        let hasEnvironmentMarker = baseEnvironment["XCTestConfigurationFilePath"] != nil
            || baseEnvironment["XCTestBundlePath"] != nil
        XCTAssertTrue(
            hasEnvironmentMarker || CommandLine.arguments.contains(where: { $0.hasPrefix("-XCTest") }),
            "The test runner must provide a supported XCTest process marker"
        )

        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let realProfileRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .standardizedFileURL
        for explicitValue in [nil, "  \n"] as [String?] {
            var environment = baseEnvironment
            environment["REPOPROMPT_TEST_SANDBOX_ROOT"] = explicitValue
            let resolved = MCPFilesystemIdentity.repoPromptCE(.debug).test_applicationSupportRootURL(
                environment: environment
            ).standardizedFileURL
            let processSandboxRoot = resolved.deletingLastPathComponent().deletingLastPathComponent()

            XCTAssertTrue(resolved.path.hasPrefix(temporaryRoot.path + "/"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: processSandboxRoot.path))
            XCTAssertFalse(resolved.path == realProfileRoot.path)
            XCTAssertFalse(resolved.path.hasPrefix(realProfileRoot.path + "/"))
        }
    }

    func testExplicitSandboxOverrideWinsDuringXCTest() {
        MCPFilesystemIdentity.test_setApplicationSupportRootOverride(nil)
        let explicitRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPFilesystemIdentityTests-explicit-\(UUID().uuidString)", isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["REPOPROMPT_TEST_SANDBOX_ROOT"] = "  \(explicitRoot.path)\n"

        let resolved = MCPFilesystemIdentity.repoPromptCE(.debug).test_applicationSupportRootURL(
            environment: environment
        )
        let expected = explicitRoot
            .appendingPathComponent("profile", isDirectory: true)
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)

        XCTAssertEqual(resolved.standardizedFileURL, expected.standardizedFileURL)
    }
}
