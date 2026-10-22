import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class MCPReadAutoSelectionRecoveryIntegrationTests: XCTestCase {
        func testBackgroundReadSelectionDoesNotBlockLaterDrainsOrChangeForegroundSelection() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let server = context.window.mcpServer
                let manager = context.window.workspaceManager
                var endpoint: PersistentMCPTestEndpoint?
                do {
                    try await fixture.registerDomainWorkspace(context)
                    try await Self.activateWorkspace(context)
                    let caller = try await Self.makeBoundEndpoint(label: "background-reader", fixture: fixture)
                    endpoint = caller
                    _ = try await caller.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "clear"])
                    let created = await context.window.promptManager.createBackgroundComposeTab(strategy: .blank, name: "Foreground")
                    let foreground = try XCTUnwrap(created)
                    await context.window.promptManager.switchComposeTab(foreground.id)
                    let foregroundSelection = Set(context.window.workspaceFilesViewModel.selectedFiles.map(\.fullPath))
                    XCTAssertFalse(foregroundSelection.contains(context.fileURL.path))

                    let read = try await caller.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": context.fileURL.path]
                    )
                    XCTAssertFalse(read.rawJSON.contains("\"isError\":true"), read.rawJSON)
                    let metadata = MCPServerViewModel.RequestMetadata(
                        connectionID: caller.connectionID, clientName: nil, windowID: context.window.windowID
                    )
                    let firstDrain = try await server.drainReadFileAutoSelection(
                        metadata: metadata,
                        requirement: .mirroredSelectionAndMetrics
                    )
                    XCTAssertEqual(firstDrain, .completed)
                    XCTAssertTrue(try XCTUnwrap(Self.storedSelection(context)).selectedPaths.contains(context.fileURL.path))
                    let add = try await caller.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "add", "paths": [context.fileURL.path]]
                    )
                    XCTAssertFalse(add.rawJSON.contains("\"isError\":true"), add.rawJSON)
                    XCTAssertEqual(manager.activeWorkspace?.activeComposeTabID, foreground.id)
                    XCTAssertEqual(Set(context.window.workspaceFilesViewModel.selectedFiles.map(\.fullPath)), foregroundSelection)

                    await context.window.promptManager.switchComposeTab(context.tabID)
                    XCTAssertTrue(context.window.workspaceFilesViewModel.selectedFiles.contains { $0.fullPath == context.fileURL.path })
                    await Self.cleanupEndpoint(caller, manager: fixture.networkManager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: fixture.networkManager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testParkedMirrorConnectionRemovalPreservesSameWindowOwnerAndSelectionMutations() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let manager = fixture.networkManager
                let server = fixture.contextA.window.mcpServer
                let mirrorGate = MCPExecutionIgnoringCancellationGate()
                let secondRelativePath = "Sources/RecoverySurvivor.swift"
                let secondURL = fixture.contextA.rootURL.appendingPathComponent(secondRelativePath)
                var removedEndpoint: PersistentMCPTestEndpoint?
                var survivorEndpoint: PersistentMCPTestEndpoint?
                var firstReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                _ = try await fixture.contextA.window.workspaceFileContextStore.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: secondRelativePath,
                    content: SwiftFixtureSource.emptyStruct("RecoverySurvivor")
                )
                do {
                    try await fixture.registerDomainWorkspace(fixture.contextA)
                    try await Self.activateWorkspace(fixture.contextA)
                    let first = try await Self.makeBoundEndpoint(
                        label: "parked-owner",
                        fixture: fixture
                    )
                    removedEndpoint = first
                    let survivor = try await Self.makeBoundEndpoint(
                        label: "surviving-owner",
                        fixture: fixture
                    )
                    survivorEndpoint = survivor

                    _ = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "clear"]
                    )
                    server.setReadFileAutoSelectionMirrorGateForTesting {
                        await mirrorGate.enterAndWait()
                    }
                    let activeFirstReadTask = Task {
                        try await first.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    firstReadTask = activeFirstReadTask
                    try await mirrorGate.waitUntilEntered(count: 1)

                    let removalTask = Task {
                        await manager.removeConnection(first.connectionID)
                    }
                    await mirrorGate.release()
                    await removalTask.value
                    _ = try? await activeFirstReadTask.value
                    firstReadTask = nil
                    removedEndpoint = nil
                    XCTAssertNil(server.tabContextByConnectionID[first.connectionID])
                    XCTAssertEqual(
                        server.tabContextByConnectionID[survivor.connectionID]?.tabID,
                        fixture.contextA.tabID
                    )

                    server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                    let add = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [secondURL.path],
                            "view": "files"
                        ]
                    )
                    XCTAssertFalse(add.rawJSON.contains("\"isError\":true"), add.rawJSON)
                    let get = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "get", "view": "files"]
                    )
                    let text = try Self.toolResultText(get)
                    XCTAssertTrue(text.contains(fixture.contextA.fileURL.lastPathComponent), text)
                    XCTAssertTrue(text.contains(secondURL.lastPathComponent), text)
                    XCTAssertEqual(
                        Set(server.tabContextByConnectionID[survivor.connectionID]?.selection.selectedPaths ?? []),
                        Set([fixture.contextA.fileURL.path, secondURL.path])
                    )

                    await Self.cleanupEndpoint(survivor, manager: manager)
                    survivorEndpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    firstReadTask?.cancel()
                    await mirrorGate.release()
                    server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                    if let firstReadTask { _ = try? await firstReadTask.value }
                    if let removedEndpoint { await Self.cleanupEndpoint(removedEndpoint, manager: manager) }
                    if let survivorEndpoint { await Self.cleanupEndpoint(survivorEndpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testDeferredSelectionPrerequisiteIsReportedAsItsOwnErrorNotCancellation() async throws {
            // A zero mirror wait defers every drain while the read's mirror is held.
            try await withHeldMirrorRead(label: "deferred", mirrorWaitTimeout: .zero) { held in
                // A repeated call gets the same refusal, not a busy tab, because the first released its admission.
                for attempt in 1 ... 2 {
                    let text = try await held.refusalText(
                        MCPWindowToolName.contextBuilder,
                        ["instructions": "selection prerequisite regression", "response_type": "clarify"],
                        code: "context_builder_selection_prerequisite_deferred"
                    )
                    XCTAssertFalse(text.contains(Self.contextBuilderBusyText), "attempt \(attempt): \(text)")
                }
            }
        }

        func testSelectionPrerequisiteWaitCancelledByCallerStaysCancellation() async throws {
            enum Row: CaseIterable {
                case contextBuilder
            }

            for row in Row.allCases {
                try await withHeldMirrorRead(label: "cancelled-\(row)", mirrorWaitTimeout: .seconds(60)) { held in
                    let error: Error? = switch row {
                    case .contextBuilder:
                        try await held.cancelWhileWaiting(MCPWindowToolName.contextBuilder, [
                            "instructions": .string("selection prerequisite regression"),
                            "response_type": .string("clarify")
                        ])
                    }
                    XCTAssertTrue(error is MCPToolExecutionCancelledError, "\(row): \(String(describing: error))")
                    XCTAssertEqual(held.coordinator.debugSnapshot().mirrorWaiterCount, 0, "\(row)")
                    XCTAssertEqual(held.storedSelection, held.expectedSelection, "\(row)")
                    if row == .contextBuilder {
                        // The cancelled call released its admission, so the next call isn't refused as busy.
                        held.coordinator.setMirrorWaitTimeoutForTesting(.zero)
                        let reply = try await held.endpoint.callTool(
                            name: MCPWindowToolName.contextBuilder,
                            arguments: ["instructions": "selection prerequisite regression", "response_type": "clarify"]
                        )
                        let text = try Self.toolResultText(reply)
                        XCTAssertFalse(text.contains(Self.contextBuilderBusyText), text)
                    }
                }
            }
        }

        private static let contextBuilderBusyText = "Context Builder is already running for this tab."

        /// A real bound read whose selection prerequisite can't complete while a test hook holds one of its lanes.
        @MainActor
        private struct HeldRead {
            let fixture: PersistentMCPTestFixture
            let endpoint: PersistentMCPTestEndpoint
            let probe: SelectionLaneProbe
            /// The stored selection a refused or cancelled tool must leave in place.
            let expectedSelection: StoredSelection

            var context: PersistentMCPTestContext {
                fixture.contextA
            }

            var server: MCPServerViewModel {
                context.window.mcpServer
            }

            var coordinator: MCPReadFileAutoSelectionCoordinator {
                server.readFileAutoSelectionCoordinator
            }

            var storedSelection: StoredSelection? {
                MCPReadAutoSelectionRecoveryIntegrationTests.storedSelection(context)
            }

            /// Calls `tool` on the bound connection, checks that it was refused with `code` and
            /// changed no selection, and returns the reply text.
            func refusalText(
                _ tool: String,
                _ arguments: [String: Any],
                code: String,
                file: StaticString = #filePath,
                line: UInt = #line
            ) async throws -> String {
                let reply = try await endpoint.callTool(name: tool, arguments: arguments)
                let text = try MCPReadAutoSelectionRecoveryIntegrationTests.toolResultText(reply)
                XCTAssertTrue(reply.rawJSON.contains("\"isError\":true"), "\(tool): \(reply.rawJSON)", file: file, line: line)
                XCTAssertTrue(text.hasPrefix("Error: \(code):"), "\(tool): \(text)", file: file, line: line)
                XCTAssertFalse(
                    text.contains(MCPToolExecutionCancelledError().localizedDescription),
                    "\(tool): \(text)",
                    file: file,
                    line: line
                )
                XCTAssertEqual(storedSelection, expectedSelection, "\(tool) changed the selection", file: file, line: line)
                return text
            }

            /// Calls `toolName` in process for the bound connection and returns what it threw, or nil.
            /// `whileRunning` receives the call's task once it has started.
            func inProcessCallError(
                _ toolName: String,
                _ arguments: [String: Value],
                whileRunning: @MainActor (Task<Error?, Never>) async -> Void = { _ in }
            ) async throws -> Error? {
                let tools = await server.windowMCPTools
                let tool = try XCTUnwrap(tools.first { $0.name == toolName }, "\(toolName) is not a window tool")
                let connectionID = endpoint.connectionID
                server.setRequestMetadataOverrideForTesting(.init(
                    connectionID: connectionID,
                    clientName: nil,
                    windowID: context.window.windowID
                ))
                defer { server.setRequestMetadataOverrideForTesting(nil) }
                let invocation = Task { @MainActor () -> Error? in
                    do {
                        // context_builder finds the caller's binding through this task-local, as a socket call does.
                        _ = try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                            try await tool(arguments)
                        }
                        return nil
                    } catch {
                        return error
                    }
                }
                await whileRunning(invocation)
                return await invocation.value
            }

            /// Calls `toolName` in process, cancels the caller once its drain waits on the held mirror,
            /// and returns what the call threw.
            func cancelWhileWaiting(_ toolName: String, _ arguments: [String: Value]) async throws -> Error? {
                let waiting = probe.expect(.waiterRegistered, on: .mirror)
                return try await inProcessCallError(toolName, arguments) { invocation in
                    _ = await MCPReadAutoSelectionRecoveryIntegrationTests.awaitEvent(waiting)
                    invocation.cancel()
                }
            }
        }

        /// Runs `body` while a bound read's physical mirror is held, so a mirrored drain waits at most
        /// `mirrorWaitTimeout` and then defers.
        private func withHeldMirrorRead(
            label: String,
            mirrorWaitTimeout: Duration,
            _ body: @MainActor (HeldRead) async throws -> Void
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let server = context.window.mcpServer
                let coordinator = server.readFileAutoSelectionCoordinator
                let probe = SelectionLaneProbe(context: context)
                let mirrorGate = MCPExecutionIgnoringCancellationGate()
                let mirrorEntered = XCTestExpectation(description: "the read's mirror reached its gate")
                mirrorEntered.assertForOverFulfill = false
                var endpoint: PersistentMCPTestEndpoint?
                var mirrorHeld = false
                @MainActor
                func releaseHeldRead() async {
                    coordinator.setMirrorWaitTimeoutForTesting(.seconds(10))
                    let mirrorStopped = probe.expect(.workerStopped, on: .mirror)
                    await mirrorGate.release()
                    if mirrorHeld {
                        _ = await Self.awaitEvent(mirrorStopped)
                    }
                    server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                    MCPReadFileAutoSelectionDiagnosticTracer.setTestSink(nil)
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: fixture.networkManager) }
                    endpoint = nil
                    await fixture.cleanup()
                }

                do {
                    try await fixture.registerDomainWorkspace(context)
                    try await Self.activateWorkspace(context)
                    let caller = try await Self.makeBoundEndpoint(label: "prerequisite-\(label)", fixture: fixture)
                    endpoint = caller
                    _ = try await caller.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "clear"])
                    MCPReadFileAutoSelectionDiagnosticTracer.setTestSink { probe.record($0) }
                    server.setReadFileAutoSelectionMirrorGateForTesting {
                        mirrorEntered.fulfill()
                        await mirrorGate.enterAndWait()
                    }
                    // A CLI read waits for its own mirror before it replies; a zero wait lets it reply while the mirror is held.
                    coordinator.setMirrorWaitTimeoutForTesting(.zero)
                    let read = try await caller.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": context.fileURL.path]
                    )
                    XCTAssertFalse(read.rawJSON.contains("\"isError\":true"), read.rawJSON)
                    mirrorHeld = await Self.awaitEvent(mirrorEntered)
                    coordinator.setMirrorWaitTimeoutForTesting(mirrorWaitTimeout)
                    let accepted = try XCTUnwrap(Self.storedSelection(context))
                    XCTAssertTrue(accepted.selectedPaths.contains(context.fileURL.path))
                    try await body(HeldRead(
                        fixture: fixture,
                        endpoint: caller,
                        probe: probe,
                        expectedSelection: accepted
                    ))
                    await releaseHeldRead()
                    try await fixture.assertCleanedUp()
                } catch {
                    await releaseHeldRead()
                    throw error
                }
            }
        }

        /// Waits up to 10 s for `expectation`, records a failure if it expires, and reports whether it was fulfilled.
        private static func awaitEvent(
            _ expectation: XCTestExpectation,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> Bool {
            let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
            XCTAssertEqual(result, .completed, "Timed out waiting until \(expectation.description)", file: file, line: line)
            return result == .completed
        }

        private static func makeBoundEndpoint(
            label: String,
            fixture: PersistentMCPTestFixture
        ) async throws -> PersistentMCPTestEndpoint {
            let manager = fixture.networkManager
            let clientName = "read-recovery-\(label)-\(UUID().uuidString)"
            let endpoint = try await PersistentMCPTestEndpoint.make(
                label: label,
                networkManager: manager,
                clientName: clientName,
                requiredToolNames: [MCPWindowToolName.readFile, MCPWindowToolName.manageSelection]
            )
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: .verified(
                    processID: Int(getpid()),
                    fingerprint: "test:verified:read-auto-selection-recovery"
                )
            )
            let bind = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": fixture.contextA.tabID.uuidString]
            )
            XCTAssertFalse(bind.rawJSON.contains("\"isError\":true"), bind.rawJSON)
            await fixture.contextA.window.mcpServer.domainRoutingPublishTask?.value
            return endpoint
        }

        private static func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPReadAutoSelectionRecoveryIntegrationTests"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(
                workspace,
                syncPromptText: true
            )
        }

        private static func cleanupEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            manager: ServerNetworkManager
        ) async {
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: nil
            )
            endpoint.client.close()
            await endpoint.connectionManager.stop()
            await manager.debugRemoveConnection(endpoint.connectionID)
            await manager.clearClientConnectionPolicy(for: endpoint.clientName)
            await manager.debugClearPersistedRoutingState(for: endpoint.clientName)
        }

        private static func storedSelection(_ context: PersistentMCPTestContext) -> StoredSelection? {
            context.window.workspaceManager.composeTab(
                for: WorkspaceSelectionIdentity(workspaceID: context.workspaceID, tabID: context.tabID)
            )?.selection
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let object = try MCPWindowTestSupport.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return try XCTUnwrap(content.first?["text"] as? String)
        }
    }

    /// Read auto-selection lane events for one tab, so a test can wait for a drain to start waiting or
    /// for a held worker to stop without polling. An expectation is fulfilled by the first matching
    /// event after it is requested.
    private final class SelectionLaneProbe: @unchecked Sendable {
        private struct Trigger: Hashable {
            let kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind
            let lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane
        }

        private let windowID: Int
        private let workspaceID: UUID
        private let tabID: UUID
        private let lock = NSLock()
        private var pending: [Trigger: XCTestExpectation] = [:]

        @MainActor
        init(context: PersistentMCPTestContext) {
            windowID = context.window.windowID
            workspaceID = context.workspaceID
            tabID = context.tabID
        }

        func expect(
            _ kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
            on lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane
        ) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "the \(lane.rawValue) lane reports \(kind.rawValue)")
            lock.withLock { pending[Trigger(kind: kind, lane: lane)] = expectation }
            return expectation
        }

        func record(_ event: MCPReadFileAutoSelectionDiagnosticEvent) {
            guard event.windowID == windowID, event.workspaceID == workspaceID, event.tabID == tabID else { return }
            let expectation = lock.withLock { pending.removeValue(forKey: Trigger(kind: event.kind, lane: event.lane)) }
            expectation?.fulfill()
        }
    }
#endif
