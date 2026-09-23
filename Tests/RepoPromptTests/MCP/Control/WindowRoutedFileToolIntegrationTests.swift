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
                    try await Self.activateWorkspace(context)
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
                        let text = try Self.toolResultText(response)
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
                    let structureData = try XCTUnwrap(Self.toolResultText(structure).data(using: .utf8))
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

        private static func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "WindowRoutedFileToolIntegrationTests"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any], response.rawJSON)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]], response.rawJSON)
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
    }
#endif
