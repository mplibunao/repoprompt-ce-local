import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// File tools called with only a hidden `_windowID`, on a connection that never ran
    /// `bind_context`, through the production domain-routing read path.
    @MainActor
    final class WindowRoutedFileToolIntegrationTests: XCTestCase {
        func testWindowRoutedFileToolsSucceedWithoutConnectionBinding() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let server = context.window.mcpServer
                do {
                    XCTAssertNotNil(server.domainRoutingCoordinator)
                    XCTAssertNotNil(server.domainWorkspaceAuthorityClient)
                    try await fixture.registerDomainWorkspace(context)
                    try await MCPWindowTestSupport.activateWorkspace(context, reason: "WindowRoutedFileToolIntegrationTests")
                    let toolsEnabled = await server.setWindowToolsEnabled(true)
                    XCTAssertTrue(toolsEnabled)
                    let endpoint = try fixture.endpointA()
                    let tabIdentity = WorkspaceSelectionIdentity(workspaceID: context.workspaceID, tabID: context.tabID)
                    let selectionBefore = context.window.workspaceManager.composeTab(for: tabIdentity)?.selection

                    let calls: [(name: String, arguments: [String: Any], expected: String)] = [
                        (MCPWindowToolName.readFile, ["path": context.fileURL.path], context.sentinel),
                        (MCPWindowToolName.search, ["pattern": "distinctMCPConnectionSentinelA"], context.fileURL.lastPathComponent),
                        (MCPWindowToolName.getFileTree, ["type": "roots"], context.rootURL.lastPathComponent)
                    ]
                    for call in calls {
                        var arguments = call.arguments
                        arguments["_windowID"] = context.window.windowID
                        let response = try await endpoint.callTool(name: call.name, arguments: arguments)
                        let text = try MCPWindowTestSupport.toolResultText(response)
                        XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), "\(call.name): \(response.rawJSON)")
                        XCTAssertFalse(text.contains("workspace_authority"), "\(call.name): \(text)")
                        XCTAssertFalse(text.contains("Workspace authority unavailable"), "\(call.name): \(text)")
                        XCTAssertTrue(text.contains(call.expected), "\(call.name): \(text)")
                    }

                    // The fixture root is not a git checkout, so committed code structure reports
                    // `git_root_unavailable`; reaching that projection means file authority resolved.
                    let structure = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: [
                            "paths": [context.fileURL.path],
                            "_windowID": context.window.windowID,
                            "_rawJSON": true
                        ]
                    )
                    let structureData = try XCTUnwrap(MCPWindowTestSupport.toolResultText(structure).data(using: .utf8))
                    let structureReply = try JSONDecoder().decode(
                        ToolResultDTOs.CodeStructureReplyDTO.self,
                        from: structureData
                    )
                    XCTAssertFalse(
                        structureReply.issues.contains { $0.code.hasPrefix("workspace_authority") },
                        structure.rawJSON
                    )

                    XCTAssertNil(server.tabContextByConnectionID[endpoint.connectionID])
                    XCTAssertEqual(context.window.workspaceManager.composeTab(for: tabIdentity)?.selection, selectionBefore)
                    _ = await server.setWindowToolsEnabled(false)
                    await fixture.cleanup()
                } catch {
                    _ = await server.setWindowToolsEnabled(false)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// The window's active tab holds an Agent session bound to a worktree whose folder was
        /// deleted. Reads refuse with the tab and worktree identity instead of a generic authority
        /// failure, and never fall back to the canonical checkout.
        func testFileReadsReportDeletedWorktreeWithoutCanonicalFallback() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let server = context.window.mcpServer
                let store = context.window.workspaceFileContextStore
                let sessionID = UUID()
                let boundConnectionID = UUID()
                let previousProvider = server.agentWorktreeBindingStateProvider
                let previousResolver = server.agentWorktreeBindingStateResolver
                @MainActor
                func cleanup() async {
                    server.removeTabContext(
                        forConnectionID: boundConnectionID,
                        clientName: nil,
                        windowID: nil,
                        runID: nil
                    )
                    server.agentWorktreeBindingStateProvider = previousProvider
                    server.agentWorktreeBindingStateResolver = previousResolver
                    await WorkspaceRootBindingProjectionMaterializer(store: store).release(sessionID: sessionID)
                    _ = await server.setWindowToolsEnabled(false)
                    await fixture.cleanup()
                }
                do {
                    try await fixture.registerDomainWorkspace(context)
                    try await MCPWindowTestSupport.activateWorkspace(context, reason: "WindowRoutedFileToolIntegrationTests")
                    let toolsEnabled = await server.setWindowToolsEnabled(true)
                    XCTAssertTrue(toolsEnabled)
                    let endpoint = try fixture.endpointA()

                    let worktreeRoot = fixture.rootURL.appendingPathComponent("stale-worktree", isDirectory: true)
                    let worktreeFile = worktreeRoot
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(context.fileURL.lastPathComponent)
                    try FileManager.default.createDirectory(
                        at: worktreeFile.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let worktreeSentinel = "let staleWorktreeSentinel = \"worktree-only\""
                    try "\(worktreeSentinel)\n".write(to: worktreeFile, atomically: true, encoding: .utf8)
                    let binding = AgentSessionWorktreeBinding(
                        id: "stale-worktree-binding",
                        repositoryID: "stale-worktree-repo",
                        repoKey: context.rootURL.path,
                        logicalRootPath: context.rootURL.path,
                        logicalRootName: context.rootURL.lastPathComponent,
                        worktreeID: "stale-worktree-id",
                        worktreeRootPath: worktreeRoot.path,
                        worktreeName: "stale-worktree",
                        branch: "bugfix/stale-worktree",
                        source: "test"
                    )
                    server.agentWorktreeBindingStateProvider = { _, _ in .hydrated([binding]) }
                    server.agentWorktreeBindingStateResolver = { _, _ in .hydrated([binding]) }
                    let workspaceManager = context.window.workspaceManager
                    let workspaceIndex = try XCTUnwrap(workspaceManager.workspaces.firstIndex { $0.id == context.workspaceID })
                    let tabIndex = try XCTUnwrap(
                        workspaceManager.workspaces[workspaceIndex].composeTabs.firstIndex { $0.id == context.tabID }
                    )
                    workspaceManager.workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID = sessionID
                    let tabName = workspaceManager.workspaces[workspaceIndex].composeTabs[tabIndex].name
                    let tabIdentity = WorkspaceSelectionIdentity(workspaceID: context.workspaceID, tabID: context.tabID)
                    let selectionBefore = workspaceManager.composeTab(for: tabIdentity)?.selection

                    // While the folder exists, an unbound read is served from the worktree.
                    let healthyRead = try await MCPWindowTestSupport.toolResultText(endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": context.fileURL.path, "_windowID": context.window.windowID]
                    ))
                    XCTAssertTrue(healthyRead.contains(worktreeSentinel), healthyRead)
                    XCTAssertFalse(healthyRead.contains(context.sentinel), healthyRead)

                    // A connection bound while the folder exists holds frozen authority for the tab.
                    let authority = try await server.resolveFileToolAuthority(
                        tabID: context.tabID,
                        workspaceID: context.workspaceID
                    )
                    XCTAssertNotNil(authority.lookupContext.bindingProjection)
                    try server.bindTabForConnection(
                        connectionID: boundConnectionID,
                        clientName: "WindowRoutedFileToolIntegrationTests",
                        tabID: context.tabID,
                        workspaceID: context.workspaceID,
                        windowID: context.window.windowID,
                        frozenFileToolAuthority: authority
                    )

                    try FileManager.default.removeItem(at: worktreeRoot)

                    let expected = MCPUnavailableWorktreeDiagnostic(
                        binding: binding,
                        routeContext: .init(tabName: tabName, windowID: context.window.windowID)
                    )
                    XCTAssertEqual(
                        expected.summary,
                        "Tab '\(tabName)' (window \(context.window.windowID)) can't be used: "
                            + "its Agent Mode worktree 'stale-worktree' is missing from disk."
                    )
                    XCTAssertEqual(
                        expected.recovery,
                        "Retrying won't help. Tell the user so they can switch to another tab."
                    )
                    XCTAssertFalse(expected.message.contains(fixture.rootURL.path), expected.message)

                    // Unbound leg: calls without a tab argument route to the stale active tab.
                    @MainActor
                    func rawCall<Reply: Decodable>(
                        _ tool: String,
                        _ arguments: [String: Any],
                        as _: Reply.Type
                    ) async throws -> Reply {
                        var arguments = arguments
                        arguments["_windowID"] = context.window.windowID
                        arguments["_rawJSON"] = true
                        let response = try await endpoint.callTool(name: tool, arguments: arguments)
                        let text = try MCPWindowTestSupport.toolResultText(response)
                        XCTAssertFalse(text.contains(context.sentinel), "\(tool): \(text)")
                        XCTAssertFalse(text.contains(worktreeSentinel), "\(tool): \(text)")
                        let data = try XCTUnwrap(text.data(using: .utf8))
                        return try JSONDecoder().decode(Reply.self, from: data)
                    }

                    let read = try await rawCall(
                        MCPWindowToolName.readFile,
                        ["path": context.fileURL.path],
                        as: ToolResultDTOs.ReadFileReply.self
                    )
                    XCTAssertEqual(read.content, "")
                    XCTAssertEqual(read.displayPath, context.fileURL.path)
                    XCTAssertEqual(read.errorCode, "worktree_scope_unavailable")
                    XCTAssertEqual(read.errorMessage, expected.message)
                    XCTAssertEqual(read.retryable, false)
                    XCTAssertNil(read.retryAfterMilliseconds)

                    let search = try await rawCall(
                        MCPWindowToolName.search,
                        ["pattern": "Sentinel"],
                        as: ToolResultDTOs.SearchResultDTO.self
                    )
                    XCTAssertEqual(search.totalMatches, 0)
                    XCTAssertEqual(search.errorCode, "worktree_scope_unavailable")
                    XCTAssertEqual(search.errorMessage, expected.summary)
                    XCTAssertEqual(search.suggestion, expected.recovery)
                    XCTAssertEqual(search.retryable, false)
                    XCTAssertNil(search.retryAfterMilliseconds)

                    for treeType in ["roots", "files"] {
                        let tree = try await rawCall(
                            MCPWindowToolName.getFileTree,
                            ["type": treeType],
                            as: ToolResultDTOs.FileTreeDTO.self
                        )
                        XCTAssertEqual(tree.rootsCount, 0, treeType)
                        XCTAssertEqual(tree.tree, expected.message, treeType)
                        XCTAssertEqual(tree.note, "Bound worktree folder unavailable", treeType)
                        XCTAssertEqual(tree.errorCode, "worktree_scope_unavailable", treeType)
                        XCTAssertEqual(tree.retryable, false, treeType)
                        XCTAssertNil(tree.retryAfterMilliseconds, treeType)
                    }

                    let structure = try await rawCall(
                        MCPWindowToolName.getCodeStructure,
                        ["paths": [context.fileURL.path]],
                        as: ToolResultDTOs.CodeStructureReplyDTO.self
                    )
                    XCTAssertEqual(structure.status, .unavailable)
                    XCTAssertEqual(structure.files, [])
                    XCTAssertTrue(structure.roots.isEmpty)
                    XCTAssertEqual(structure.issues.map(\.code), ["worktree_scope_unavailable"])
                    XCTAssertEqual(structure.issues.map(\.message), [expected.message])
                    XCTAssertEqual(structure.issues.map(\.retryable), [false])
                    XCTAssertEqual(structure.issues.map(\.retryAfterMilliseconds), [nil])
                    XCTAssertEqual(structure.retry?.retryable, false)
                    XCTAssertNil(structure.retry?.retryAfterMilliseconds)

                    // The formatted read shows the refusal and its message.
                    let formattedRead = try await MCPWindowTestSupport.toolResultText(endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": context.fileURL.path, "_windowID": context.window.windowID]
                    ))
                    XCTAssertTrue(formattedRead.hasPrefix("## File Read ❌"), formattedRead)
                    XCTAssertTrue(formattedRead.contains(expected.message), formattedRead)
                    XCTAssertFalse(formattedRead.contains("Retryable"), formattedRead)

                    // The formatted code structure prints the message whole, with no generic retry line.
                    let formattedStructure = try await MCPWindowTestSupport.toolResultText(endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: ["paths": [context.fileURL.path], "_windowID": context.window.windowID]
                    ))
                    XCTAssertEqual(formattedStructure, "## Code Structure ❌ unavailable — \(expected.message)")

                    XCTAssertNil(server.tabContextByConnectionID[endpoint.connectionID])
                    XCTAssertEqual(workspaceManager.composeTab(for: tabIdentity)?.selection, selectionBefore)

                    // Bound leg: the frozen authority captured before deletion reports the same refusal.
                    do {
                        _ = try await server.requiredFileToolLookupContext(from: MCPServerViewModel.RequestMetadata(
                            connectionID: boundConnectionID,
                            clientName: "WindowRoutedFileToolIntegrationTests",
                            windowID: context.window.windowID
                        ))
                        XCTFail("Frozen authority for a deleted worktree must not resolve")
                    } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                        XCTAssertEqual(failure, .unavailableWorktree(expected))
                    }
                    await cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await cleanup()
                    throw error
                }
            }
        }
    }
#endif
