import Foundation
@testable import RepoPromptApp
import XCTest

/// Which Codex hooks RepoPrompt offers for approval and is willing to trust: exactly those whose
/// source is `project` or `user`. A hook from any other source stays out of review, and selecting
/// one stops the trust request before it writes anything.
final class CodexHookTrustTests: XCTestCase {
    private static let executionCWD = "/workspace/repo"

    func testReviewableSourcesAndCandidateEligibility() throws {
        let user = try Self.hook(source: "user", key: "user:pre_tool_use:0:0", trustStatus: .untrusted)
        let disabledUser = try Self.hook(
            source: "user",
            key: "user:pre_tool_use:1:0",
            trustStatus: .untrusted,
            enabled: false
        )
        let trustedUser = try Self.hook(source: "user", key: "user:session_start:0:0", trustStatus: .trusted)
        let modifiedProject = try Self.hook(source: "project", key: "project:pre_tool_use:0:0", trustStatus: .modified)
        let managedProject = try Self.hook(source: "project", key: "project:stop:0:0", trustStatus: .managed)
        let plugin = try Self.hook(source: "plugin", key: "plugin:pre_tool_use:0:0", trustStatus: .untrusted)
        let inventory = try CodexHookInventory(
            executionCWD: Self.executionCWD,
            hooks: [user, disabledUser, trustedUser, modifiedProject, managedProject, plugin]
        )

        XCTAssertEqual(
            Set(inventory.reviewableHooks.map(\.key)),
            Set([user, disabledUser, trustedUser, modifiedProject, managedProject].map(\.key))
        )
        XCTAssertEqual(
            Set(inventory.unresolvedReviewableHooks.map(\.key)),
            Set([user, disabledUser, modifiedProject].map(\.key))
        )
        XCTAssertTrue(inventory.validatesUnresolvedReviewableHooks(
            for: [Self.candidate(user), Self.candidate(disabledUser), Self.candidate(modifiedProject)]
        ))
        XCTAssertFalse(
            inventory.validatesUnresolvedReviewableHooks(for: [Self.candidate(plugin)]),
            "an untrusted plugin hook was accepted for trust"
        )
        XCTAssertFalse(
            inventory.validatesUnresolvedReviewableHooks(for: [Self.candidate(user), Self.candidate(plugin)]),
            "a selection containing a plugin hook was accepted for trust"
        )
    }

    func testTrustWritesOnlyValidatedSelections() async throws {
        let userKey = "/codex-home/hooks.json:pre_tool_use:0:0"
        let untrustedUser = try Self.hook(source: "user", key: userKey, trustStatus: .untrusted)
        let trustedUser = try Self.hook(source: "user", key: userKey, trustStatus: .trusted)
        let plugin = try Self.hook(source: "plugin", key: "plugin:pre_tool_use:0:0", trustStatus: .untrusted)
        let codex = FakeHookTrustAppServer(
            beforeWrite: [untrustedUser, plugin],
            afterWrite: [trustedUser, plugin]
        )
        let service = CodexHookTrustService(
            requestExecutor: { method, params, _ in try codex.request(method: method, params: params) },
            mutationExecutor: { method, params, _ in codex.mutate(method: method, params: params) },
            executionCWD: Self.executionCWD,
            timeout: nil,
            writeSettlementDeadline: 5
        )
        let preflight = try await service.listHooks()

        do {
            _ = try await service.trustHooks(
                expectedCandidates: [Self.candidate(plugin)],
                expectedInventoryFingerprint: preflight.fingerprint
            )
            XCTFail("a plugin hook was trusted")
        } catch let error as CodexHookTrustError {
            guard case .inventoryChanged = error else {
                return XCTFail("expected inventoryChanged, got \(error)")
            }
        }
        XCTAssertTrue(codex.mutations.isEmpty, "a non-reviewable selection reached config/batchWrite")

        let verified = try await service.trustHooks(
            expectedCandidates: [Self.candidate(untrustedUser)],
            expectedInventoryFingerprint: preflight.fingerprint
        )

        let mutations = codex.mutations
        XCTAssertEqual(mutations.map(\.method), ["config/batchWrite"])
        let expectedParams: [String: Any] = [
            "edits": [[
                "keyPath": "hooks.state",
                "value": [userKey: ["trusted_hash": untrustedUser.currentHash]],
                "mergeStrategy": "upsert"
            ]],
            "reloadUserConfig": true
        ]
        XCTAssertEqual(
            mutations.first?.params.map { NSDictionary(dictionary: $0) },
            NSDictionary(dictionary: expectedParams)
        )
        XCTAssertEqual(verified, try CodexHookInventory(executionCWD: Self.executionCWD, hooks: [trustedUser, plugin]))
    }

    // MARK: - Helpers

    /// Answers `hooks/list` with one inventory until a mutation arrives and with another after
    /// it, and records every mutation.
    private final class FakeHookTrustAppServer: @unchecked Sendable {
        struct Mutation {
            let method: String
            let params: [String: Any]?
        }

        private let lock = NSLock()
        private let beforeWrite: [CodexHookMetadata]
        private let afterWrite: [CodexHookMetadata]
        private var recordedMutations: [Mutation] = []

        init(beforeWrite: [CodexHookMetadata], afterWrite: [CodexHookMetadata]) {
            self.beforeWrite = beforeWrite
            self.afterWrite = afterWrite
        }

        var mutations: [Mutation] {
            lock.withLock { recordedMutations }
        }

        func request(method: String, params: [String: Any]?) throws -> [String: Any] {
            guard method == "hooks/list",
                  params?["cwds"] as? [String] == [CodexHookTrustTests.executionCWD]
            else {
                throw CodexHookTrustService.RequestError.unsupportedMethod
            }
            let hooks = lock.withLock { recordedMutations.isEmpty ? beforeWrite : afterWrite }
            return [
                "data": [[
                    "cwd": CodexHookTrustTests.executionCWD,
                    "hooks": hooks.map(CodexHookTrustTests.protocolHook),
                    "errors": [String](),
                    "warnings": [String]()
                ]]
            ]
        }

        func mutate(method: String, params: [String: Any]?) -> CodexHookTrustMutationSettlement {
            lock.withLock { recordedMutations.append(Mutation(method: method, params: params)) }
            return .response(["status": "ok"])
        }
    }

    private static func hook(
        source: String,
        key: String,
        trustStatus: CodexHookTrustStatus,
        enabled: Bool = true
    ) throws -> CodexHookMetadata {
        try CodexHookMetadata(
            eventName: "preToolUse",
            source: source,
            sourcePath: "/\(source)/hooks.json",
            key: key,
            currentHash: "sha256:\(key)",
            enabled: enabled,
            handlerType: "command",
            trustStatus: trustStatus,
            commandOrHandler: "rtk hook codex"
        )
    }

    private static func candidate(_ hook: CodexHookMetadata) -> CodexHookTrustCandidate {
        CodexHookTrustCandidate(key: hook.key, currentHash: hook.currentHash)
    }

    /// The `hooks/list` entry Codex reports for `hook`.
    private static func protocolHook(_ hook: CodexHookMetadata) -> [String: Any] {
        [
            "eventName": hook.eventName,
            "source": hook.source,
            "sourcePath": hook.sourcePath,
            "key": hook.key,
            "currentHash": hook.currentHash,
            "enabled": hook.enabled,
            "trustStatus": hook.trustStatus.rawValue,
            "handlerType": hook.handlerType,
            "command": hook.commandOrHandler ?? NSNull()
        ]
    }
}
