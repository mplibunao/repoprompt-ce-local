import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// The first-turn Codex hook gate on the real submission path. An unresolved global (`user`)
    /// hook holds the first turn until the user approves it. Hook-discovery warnings that arrive
    /// with nothing to review appear once in the transcript and don't hold the turn.
    @MainActor
    final class CodexHookGateTests: XCTestCase {
        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexHookGateTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        func testUserHookPausesFirstTurnUntilApproved() async throws {
            let fixture = makeFixture()
            let executionCWD = storageRoot.path
            let untrusted = try Self.userHook(trustStatus: .untrusted)
            let trusted = try Self.userHook(trustStatus: .trusted)
            var trustRequests: [[CodexHookTrustCandidate]] = []
            fixture.controller.hookList = {
                try CodexHookInventory(executionCWD: executionCWD, hooks: [untrusted])
            }
            fixture.controller.hookTrust = { candidates, _ in
                trustRequests.append(candidates)
                return try CodexHookInventory(executionCWD: executionCWD, hooks: [trusted])
            }

            let ticket = try fixture.submit("first")
            try await startupTestEventually { fixture.session.pendingCodexHookReview?.phase == .reviewRequired }
            let review = try XCTUnwrap(fixture.session.pendingCodexHookReview)
            XCTAssertEqual(review.hooks.map(\.key), [untrusted.key])
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [], "the first turn ran before the user hook was reviewed")

            try await fixture.viewModel.submitCodexHookReviewDecision(
                tabID: fixture.tabID,
                requestID: review.id,
                decision: .approveSelected(hookKeys: [untrusted.key])
            )
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(trustRequests, [[CodexHookTrustCandidate(key: untrusted.key, currentHash: untrusted.currentHash)]])
            XCTAssertNil(fixture.session.pendingCodexHookReview)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["first"])
        }

        func testDiscoveryWarningsAppendOneNoticeAndDispatch() async throws {
            let fixture = makeFixture()
            let executionCWD = storageRoot.path
            let longWarning = "hook timeout clamped: " + String(repeating: "x", count: 400)
            let warnings = [
                "failed to parse hooks config /codex-home/hooks.json: EOF while parsing a list\nat line 1 column 31",
                longWarning,
                "hooks.json and inline [hooks] are both present in /codex-home",
                "additionalContextLimit is ignored"
            ]
            fixture.controller.hookList = {
                try CodexHookInventory(executionCWD: executionCWD, hooks: [], warnings: warnings)
            }

            let ticket = try fixture.submit("first")
            try await startupTestJoin(ticket.task)

            let summary = [
                "failed to parse hooks config /codex-home/hooks.json: EOF while parsing a list at line 1 column 31",
                String(longWarning.prefix(300)),
                "hooks.json and inline [hooks] are both present in /codex-home"
            ].joined(separator: "; ")
            let expectedNotice = "Codex reported 4 hook discovery warning(s), so some hooks may not be loaded: \(summary). "
                + "Global hooks are copied from ~/.codex/hooks.json at launch and are edited there."
            let hookNotices = fixture.session.items
                .filter { $0.kind == .system && $0.text.contains("hook discovery") }
                .map(\.text)
            XCTAssertEqual(hookNotices, [expectedNotice])
            XCTAssertNil(fixture.session.pendingCodexHookReview)
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["first"])
        }

        // MARK: - Fixture

        private func makeFixture() -> StartupTestSessionFixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: false)
            let viewModel = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                testWorkspaceDirectory: storageRoot,
                shouldManageCodexTooling: false,
                codexControllerFactory: { _, _, _, _, _, _ in controller },
                mcpServerReadinessRequirement: { try await readiness.require() }
            )
            let fixture = StartupTestSessionFixture(
                viewModel: viewModel,
                session: startupTestCodexSession(),
                readiness: readiness,
                controller: controller
            )
            addTeardownBlock { @MainActor in await fixture.tearDown() }
            return fixture
        }

        /// The rtk hook as Codex 0.159.0 reports it from the private Codex home's `hooks.json`.
        private static func userHook(trustStatus: CodexHookTrustStatus) throws -> CodexHookMetadata {
            try CodexHookMetadata(
                eventName: "preToolUse",
                source: "user",
                sourcePath: "/codex-home/hooks.json",
                key: "/codex-home/hooks.json:pre_tool_use:0:0",
                currentHash: "sha256:rtk",
                enabled: true,
                handlerType: "command",
                trustStatus: trustStatus,
                commandOrHandler: "rtk hook codex"
            )
        }
    }
#endif
