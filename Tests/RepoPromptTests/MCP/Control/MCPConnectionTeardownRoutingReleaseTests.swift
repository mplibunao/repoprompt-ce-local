import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// An ended MCP connection must leave the domain routing coordinator. Every routing outcome the
    /// coordinator retains copies all registered connections, so each connection left behind adds
    /// memory for as long as the app runs.
    @MainActor
    final class MCPConnectionTeardownRoutingReleaseTests: XCTestCase {
        func testConnectionTeardownUnregistersConnectionFromRoutingCoordinator() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let server = context.window.mcpServer
                let otherServer = fixture.contextB.window.mcpServer
                let manager = fixture.networkManager
                do {
                    let coordinator = try XCTUnwrap(server.domainRoutingCoordinator)
                    try await fixture.registerDomainWorkspace(context)
                    try await MCPWindowTestSupport.activateWorkspace(context, reason: "MCPConnectionTeardownRoutingReleaseTests")
                    let toolsEnabled = await server.setWindowToolsEnabled(true)
                    XCTAssertTrue(toolsEnabled)
                    // A single MCP-enabled window makes an unbound connection eligible for automatic binding.
                    let otherToolsEnabled = await otherServer.setWindowToolsEnabled(true)
                    XCTAssertTrue(otherToolsEnabled)
                    let windowID = context.window.windowID

                    // The calls rpce-cli makes for `-e 'windows'` without `-w`, `-w 1 -e 'windows'`,
                    // `-w 1 -c get_file_tree`, and `--context-id … -c read_file`. A closing window leaves
                    // `allWindows` before its teardown, so the last kind ends with no window to target; it
                    // stays last because the fixture's windows aren't registered again.
                    let kinds: [(label: String, calls: [(name: String, arguments: [String: Any])], closesWindows: Bool)] = [
                        ("never binds", [
                            ("bind_context", ["op": "list"])
                        ], false),
                        ("lists windows", [
                            ("bind_context", ["op": "bind", "window_id": windowID]),
                            ("bind_context", ["op": "list"])
                        ], false),
                        ("targets a window", [
                            ("bind_context", ["op": "bind", "window_id": windowID]),
                            (MCPWindowToolName.getFileTree, ["type": "roots", "_windowID": windowID])
                        ], false),
                        ("binds a tab", [
                            ("bind_context", ["op": "bind", "context_id": context.tabID.uuidString]),
                            (MCPWindowToolName.readFile, [
                                "path": context.fileURL.path,
                                "limit": 5,
                                "_windowID": windowID,
                                "context_id": context.tabID.uuidString
                            ])
                        ], false),
                        ("never binds, every window closed first", [
                            ("bind_context", ["op": "list"])
                        ], true)
                    ]
                    for kind in kinds {
                        let endpoint = try await PersistentMCPTestEndpoint.make(
                            label: "teardown-release",
                            networkManager: manager
                        )
                        for call in kind.calls {
                            let response = try await endpoint.callTool(name: call.name, arguments: call.arguments)
                            XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), "\(kind.label) \(call.name): \(response.rawJSON)")
                        }
                        let registeredWhileOpen = await Self.isRegistered(endpoint.connectionID, in: coordinator)
                        XCTAssertTrue(registeredWhileOpen, "\(kind.label): connection was never registered")
                        if kind.closesWindows {
                            for window in [context.window, fixture.contextB.window] {
                                WindowStatesManager.shared.unregisterWindowState(window)
                            }
                            XCTAssertTrue(WindowStatesManager.shared.allWindows.isEmpty, "\(kind.label): a window is still registered")
                        }

                        // Remove the connection before closing the client. The client's EOF starts the same
                        // teardown, and while that runs, removal returns at once, before any release is queued.
                        await manager.debugRemoveConnection(endpoint.connectionID)
                        endpoint.client.close()
                        await endpoint.connectionManager.stop()
                        for mcpServer in [server, otherServer] {
                            await mcpServer.domainRoutingPublishTask?.value
                        }
                        await manager.clearClientConnectionPolicy(for: endpoint.clientName)
                        await manager.debugClearPersistedRoutingState(for: endpoint.clientName)

                        let registeredAfterTeardown = await Self.isRegistered(endpoint.connectionID, in: coordinator)
                        XCTAssertFalse(registeredAfterTeardown, "\(kind.label): ended connection is still registered")
                    }
                    _ = await server.setWindowToolsEnabled(false)
                    _ = await otherServer.setWindowToolsEnabled(false)
                    await fixture.cleanup()
                } catch {
                    _ = await server.setWindowToolsEnabled(false)
                    _ = await otherServer.setWindowToolsEnabled(false)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private static func isRegistered(_ connectionID: UUID, in coordinator: DomainRoutingCoordinator) async -> Bool {
            await coordinator.snapshot().connections.contains { $0.registration.connectionID == connectionID }
        }
    }
#endif
