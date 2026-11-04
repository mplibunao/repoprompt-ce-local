import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class DirectHeadlessCompositionTests: XCTestCase {
    func testCanonicalDefinitionsMatchReadableGeneratedReviewSnapshot() throws {
        let root = try RepoRoot.url()
        let snapshotURL = root.appendingPathComponent("docs/spec/mcp-domain-canonical-tool-definitions.generated.json")
        let updateMarker = root.appendingPathComponent(".build/update-mcp-domain-schema-review-snapshot")
        let generated = try MCPDomainCanonicalToolDefinitions.reviewSnapshotData()
        if FileManager.default.fileExists(atPath: updateMarker.path) {
            try generated.write(to: snapshotURL, options: .atomic)
            try FileManager.default.removeItem(at: updateMarker)
        }
        XCTAssertEqual(try Data(contentsOf: snapshotURL), generated)
    }

    func testHeadlessBindContextRejectsAdvertisedWindowSelectorWithoutChangingScope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-bind-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MCPDomainRuntime(configuration: DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "test",
            storageDirectory: root.appendingPathComponent("Runtime", isDirectory: true),
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true)
        ))
        try await runtime.start()
        let scopeID = DomainStandaloneScopeID()
        _ = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: UUID(),
            workingDirectories: []
        )
        let context = DirectHeadlessDomainContext(runtime: runtime, scopeID: scopeID)
        let settingsStore = DomainDirectSettingsStore(
            persistence: runtime.persistenceCoordinator,
            profileIdentifier: runtime.configuration.profileIdentifier
        )
        let global = DirectHeadlessGlobalBackend(
            runtime: runtime,
            scopeID: scopeID,
            context: context,
            settingsStore: settingsStore
        )
        let providers = DirectHeadlessProviderCoordinator(
            runtime: runtime,
            context: context,
            settingsStore: settingsStore,
            environment: [:]
        )
        let installation = try await MCPDomainStandaloneToolInstaller.install(
            runtime: runtime,
            scopeID: scopeID,
            backends: MCPDomainStandaloneCapabilityBackends(
                global: global,
                workspace: DirectHeadlessWorkspaceBackend(context: context),
                filesystem: DirectHeadlessFilesystemBackend(context: context),
                conversation: DirectHeadlessConversationBackend(coordinator: providers),
                versionControl: DirectHeadlessVersionControlBackend(runtime: runtime, context: context),
                agent: DirectHeadlessAgentBackend(coordinator: providers),
                history: DirectHeadlessHistoryBackend(runtime: runtime)
            )
        )
        let resolution = await runtime.toolRegistry.resolve(
            toolName: MCPGlobalToolName.bindContext,
            scope: .application
        )
        let bindContext = try XCTUnwrap(resolution).binding
        XCTAssertEqual(
            bindContext.definition,
            MCPDomainCanonicalToolDefinitions.definition(named: MCPGlobalToolName.bindContext)
        )
        let bindingBefore = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID).binding
        let workspaceCountBefore = await runtime.workspaceStore.snapshot().workspaces.count

        // The same binding answers without window_id, so each failure below is the selector rejection.
        _ = try await bindContext(["op": .string("list")])
        let windowSelectors: [(op: String, windowID: Value)] = [
            ("list", .int(1)),
            ("status", .int(1)),
            ("list", .null),
            ("list", .string("1"))
        ]
        for selector in windowSelectors {
            do {
                _ = try await bindContext(["op": .string(selector.op), "window_id": selector.windowID])
                XCTFail("headless \(selector.op) accepted window_id \(selector.windowID)")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("window_id is unavailable with --backend headless"),
                    error.localizedDescription
                )
            }
        }

        // bind reaches the backend only after protected-mutation authorization, so call the owning
        // backend directly; the window rejection must precede context_id resolution.
        do {
            _ = try await global.routeContext(DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode([
                    "op": Value.string("bind"),
                    "window_id": .int(1),
                    "context_id": .string(UUID().uuidString)
                ]),
                securityContext: nil
            ))
            XCTFail("headless bind accepted window_id")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("window_id is unavailable with --backend headless"),
                error.localizedDescription
            )
        }

        let bindingAfter = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID).binding
        XCTAssertEqual(bindingAfter, bindingBefore)
        let workspaceCountAfter = await runtime.workspaceStore.snapshot().workspaces.count
        XCTAssertEqual(workspaceCountAfter, workspaceCountBefore)

        await MCPDomainStandaloneToolInstaller.uninstall(installation, runtime: runtime)
        _ = await runtime.shutdown()
    }

    /// Headless has no worktree projections, so a saved tab with a worktree scope is refused
    /// before it is bound or read, and `create_tab` refuses a worktree selector or a scoped fork
    /// source before it writes the workspace; each would serve the main checkout. The connection
    /// keeps its previous context, and the scoped tab can still be listed and closed.
    func testWorktreeScopedContextsAreRejectedWithoutScopeChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-scoped-tab-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let repoPath = repo.standardizedFileURL.resolvingSymlinksInPath().path
        let runtime = MCPDomainRuntime(configuration: DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "test",
            storageDirectory: root.appendingPathComponent("Runtime", isDirectory: true),
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true)
        ))
        try await runtime.start()
        let scopeID = DomainStandaloneScopeID()
        _ = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: UUID(),
            workingDirectories: []
        )
        let context = DirectHeadlessDomainContext(runtime: runtime, scopeID: scopeID)
        let global = DirectHeadlessGlobalBackend(runtime: runtime, scopeID: scopeID, context: context)

        let workspaceID = UUID()
        let ordinaryID = UUID()
        let scopedID = UUID()
        let binding = AgentSessionWorktreeBinding(
            id: "headless-scoped-binding",
            repositoryID: "headless-scoped-repo",
            repoKey: repoPath,
            logicalRootPath: repoPath,
            worktreeID: "headless-scoped-worktree",
            worktreeRootPath: root.appendingPathComponent("worktree", isDirectory: true).path,
            source: "manage_workspaces.create_tab"
        )
        let savedScope: [String: Any] = try [
            "state": "bound",
            "bindings": [JSONSerialization.jsonObject(with: JSONEncoder().encode(binding))]
        ]
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: JSONSerialization.data(withJSONObject: [
                "id": workspaceID.uuidString,
                "schemaVersion": 1,
                "name": "Scoped headless",
                "repoPaths": [repoPath],
                "activeComposeTabID": ordinaryID.uuidString,
                "composeTabs": [
                    ["id": ordinaryID.uuidString, "name": "Ordinary", "prompt": "", "selectedPaths": []],
                    [
                        "id": scopedID.uuidString,
                        "name": "Scoped",
                        "prompt": "",
                        "selectedPaths": [],
                        "worktreeScope": savedScope
                    ]
                ]
            ] as [String: Any], options: [.sortedKeys]),
            fileURL: runtime.configuration.workspaceStorageDirectory
                .appendingPathComponent("\(workspaceID.uuidString).json", isDirectory: false)
        )
        let created = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: runtime.workspaceStore.snapshot().catalogRevision,
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        XCTAssertEqual(created.disposition, .applied)

        func request(_ arguments: [String: Value]) throws -> DomainPhysicalToolRequest {
            try DomainPhysicalToolRequest(argumentsJSON: JSONEncoder().encode(arguments), securityContext: nil)
        }
        func assertScopedRefusal(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
            guard case .worktreeScopedContext = error as? DirectHeadlessDomainContext.Error else {
                return XCTFail("Expected the worktree-scope refusal, got \(error)", file: file, line: line)
            }
        }
        let ordinary = DomainContextIdentity(workspaceID: workspaceID, contextID: ordinaryID)
        let scoped = DomainContextIdentity(workspaceID: workspaceID, contextID: scopedID)
        _ = try await global.routeContext(request(["op": .string("bind"), "context_id": .string(ordinaryID.uuidString)]))
        let bindingBefore = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID).binding

        do {
            _ = try await global.routeContext(request([
                "op": .string("bind"),
                "context_id": .string(scopedID.uuidString)
            ]))
            XCTFail("headless bound a worktree-scoped tab")
        } catch {
            assertScopedRefusal(error)
        }
        do {
            _ = try await context.snapshot(identity: scoped)
            XCTFail("headless took file authority from a worktree-scoped tab")
        } catch {
            assertScopedRefusal(error)
        }
        func savedDocument() async -> Data? {
            await runtime.workspaceStore.snapshot().workspaces
                .first { $0.document.workspaceID == workspaceID }?.document.documentBytes
        }
        let documentBefore = await savedDocument()
        let refusedCreations: [[String: Value]] = [
            ["worktree": .string("feature")],
            ["worktree": .null],
            ["worktree_id": .string("headless-scoped-worktree")],
            ["worktree_repo_root": .string(repoPath)],
            ["worktree_create": .bool(true)],
            ["mode": .string("fork"), "source_tab": .string(scopedID.uuidString)]
        ]
        for refused in refusedCreations {
            let arguments = refused.merging([
                "action": .string("create_tab"),
                "workspace": .string(workspaceID.uuidString)
            ]) { current, _ in current }
            do {
                _ = try await global.manageWorkspaceLifecycle(request(arguments))
                XCTFail("headless create_tab accepted \(refused)")
            } catch {
                assertScopedRefusal(error)
            }
        }
        let documentAfter = await savedDocument()
        XCTAssertEqual(documentAfter, documentBefore)
        let bindingAfter = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID).binding
        XCTAssertEqual(bindingAfter, bindingBefore)
        let ordinarySnapshot = try await context.snapshot(identity: ordinary)
        XCTAssertEqual(ordinarySnapshot.roots.map(\.path), [repoPath])

        let listed = try await global.manageWorkspaceLifecycle(request(["action": .string("list")]))
        XCTAssertTrue(String(decoding: listed.json, as: UTF8.self).contains(scopedID.uuidString))
        _ = try await global.manageWorkspaceLifecycle(request([
            "action": .string("close_tab"),
            "workspace": .string(workspaceID.uuidString),
            "tab": .string(scopedID.uuidString)
        ]))
        let remaining = await runtime.workspaceStore.snapshot().workspaces
            .first { $0.document.workspaceID == workspaceID }?
            .contexts.map(\.metadata.identity.contextID)
        XCTAssertEqual(remaining, [ordinaryID])

        _ = await runtime.shutdown()
    }

    func testCanonicalAgentSchemasAdvertiseCursorModelParameterInputs() throws {
        for toolName in ["agent_run", "agent_manage"] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let parameters = try XCTUnwrap(properties["model_parameters"]?.objectValue, toolName)
            XCTAssertEqual(parameters["type"], .string("array"))
            let items = try XCTUnwrap(parameters["items"]?.objectValue)
            XCTAssertEqual(items["required"], .array([.string("config_id"), .string("value")]))
            let itemProperties = try XCTUnwrap(items["properties"]?.objectValue)
            XCTAssertEqual(itemProperties["config_id"]?.objectValue?["type"], .string("string"))
            XCTAssertEqual(itemProperties["value"]?.objectValue?["type"], .string("string"))
            XCTAssertTrue(definition.description.contains("model_parameters"), toolName)
        }
    }

    func testHeadlessLaunchRejectsUnsupportedModelParametersBeforeProviderStartup() throws {
        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string("Reply OK"),
            "model_parameters": .array([
                .object(["config_id": .string("effort"), "value": .string("low")])
            ])
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("app-backed Cursor"))
        }
    }

    func testHeadlessAgentManageSchemaAdvertisesListWorkflows() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "agent_manage"))
        let encoded = try JSONEncoder().encode(definition.inputSchema)
        let schema = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(schema.contains("\"list_workflows\""), schema)
    }

    func testHeadlessWorkflowSelectionAppliesCanonicalPromptAndRejectsInvalidReferences() throws {
        let message = "Implement the bounded change."
        XCTAssertEqual(
            try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: ["message": .string(message)]),
            message
        )

        for workflow in RepoPromptBuiltInAgentWorkflow.allCases {
            let expected = workflow.wrapUserText(message)
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_id": .string(workflow.rawValue)
                ]),
                expected
            )
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_id": .string("builtin-\(workflow.rawValue)")
                ]),
                expected
            )
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_name": .string(workflow.metadata.displayName)
                ]),
                expected
            )
        }

        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string(message),
            "workflow_id": .string("build"),
            "workflow_name": .string("Plan & Build")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("either workflow_id or workflow_name"))
        }
        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string(message),
            "workflow_name": .string("missing-workflow")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("was not found"))
        }
    }

    func testHeadlessCodexExecUsesWorkspaceWriteWithoutRemovedFullAutoFlag() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(model: nil)

        XCTAssertFalse(arguments.contains("--full-auto"))
        XCTAssertEqual(
            Array(arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "-"]
        )
    }

    func testManageWorktreeFencesAbsoluteSelectorsToBoundWorkspaceRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-worktree-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("rp-headless-foreign-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let allowed = try DirectHeadlessVersionControlBackend.authorizeWorktreePath(root, roots: [root])
        XCTAssertEqual(allowed.path, root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.authorizeWorktreePath(outside, roots: [root])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the bound workspace roots"), error.localizedDescription)
        }
    }

    func testHeadlessMergeMutationRejectsPreviewEndpointMovedOutsideViaSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-outside-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.revalidateMergeEndpointPaths(
                sourceRoot: root,
                targetRoot: target,
                roots: [root],
                listedWorktrees: [root, target]
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("outside the bound workspace roots"),
                error.localizedDescription
            )
        }
    }

    func testHeadlessMergeMutationRejectsSameRepositorySameHeadWorktreeSwap() throws {
        let repositoryIdentity = "/tmp/headless-repo/.git"
        let head = String(repeating: "a", count: 40)
        let expectedWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/target"
        let currentWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/other"

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.validateMergeEndpointIdentity(
                expectedHead: head,
                currentHead: head,
                expectedRepositoryIdentity: repositoryIdentity,
                currentRepositoryIdentity: repositoryIdentity,
                expectedWorktreeIdentity: expectedWorktreeIdentity,
                currentWorktreeIdentity: currentWorktreeIdentity
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("endpoint identity changed"), String(describing: error))
        }
    }
}
