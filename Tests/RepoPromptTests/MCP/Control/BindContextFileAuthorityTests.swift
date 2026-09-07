import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class BindContextFileAuthorityTests: XCTestCase {
        @MainActor
        func testBindStoresAuthorityConsumedByNextFileOperation() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )

            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: "BindContextFileAuthorityTests",
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            )
            let consumed = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                from: metadata(for: fixture)
            )

            XCTAssertTrue(authority.hasSameRoutingAuthority(as: consumed))
            XCTAssertEqual(consumed.lookupContext, authority.lookupContext)
        }

        @MainActor
        func testRepeatedBindRefreshesStoredAuthorityWithoutChangingRoute() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let first = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: first
            )
            fixture.window.workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting()
            let refreshed = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )

            fixture.window.mcpServer.updateBoundFileToolAuthority(
                connectionID: fixture.connectionID,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                authority: refreshed
            )
            let consumed = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                from: metadata(for: fixture)
            )

            XCTAssertTrue(refreshed.hasSameRoutingAuthority(as: consumed))
            XCTAssertFalse(first.hasSameRoutingAuthority(as: consumed))
        }

        @MainActor
        func testFailedReplacementPreservesPriorBinding() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            )
            let prior = fixture.window.mcpServer.connectionBindingSnapshot(
                forConnection: fixture.connectionID
            )

            XCTAssertThrowsError(try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: UUID(),
                workspaceID: UUID(),
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            ))

            let retained = fixture.window.mcpServer.connectionBindingSnapshot(
                forConnection: fixture.connectionID
            )
            XCTAssertEqual(retained.windowID, prior.windowID)
            XCTAssertEqual(retained.workspaceID, prior.workspaceID)
            XCTAssertEqual(retained.tabID, prior.tabID)
            XCTAssertEqual(retained.explicitlyBound, prior.explicitlyBound)
        }

        @MainActor
        func testSupersededCatalogRejectsPreviouslyIssuedAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            fixture.window.workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting()

            do {
                try await authority.validate(
                    workspaceManager: fixture.window.workspaceManager,
                    store: fixture.window.promptManager.workspaceFileContextStore
                )
                XCTFail("A superseded readiness ticket must not remain usable")
            } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                XCTAssertEqual(failure, .superseded)
            }

            var enteredCommit = false
            let performed = try await fixture.window.mcpServer.performIfFileToolAuthorityIsCurrent(
                authority,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            ) {
                enteredCommit = true
            }
            XCTAssertFalse(performed)
            XCTAssertFalse(enteredCommit)
        }

        @MainActor
        func testCanonicalRootMutationAfterCaptureRejectsAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            let additionalRoot = try makeTemporaryRoot()
            let loaded = try await fixture.window.promptManager.workspaceFileContextStore.loadRoot(
                path: additionalRoot.path,
                kind: .primaryWorkspace
            )
            addTeardownBlock {
                await fixture.window.promptManager.workspaceFileContextStore.unloadRoot(id: loaded.id)
            }

            do {
                try await authority.validate(
                    workspaceManager: fixture.window.workspaceManager,
                    store: fixture.window.promptManager.workspaceFileContextStore
                )
                XCTFail("A changed canonical root set must invalidate captured authority")
            } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                XCTAssertEqual(failure, .mismatchedProjection)
            }
        }

        @MainActor
        func testAffinityFailurePreservesPriorBindingAndAuthority() async throws {
            let prior = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let replacement = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let priorAuthority = try await prior.window.mcpServer.resolveFileToolAuthority(
                tabID: prior.contextID,
                workspaceID: prior.workspace.id
            )
            try prior.window.mcpServer.bindTabForConnection(
                connectionID: prior.connectionID,
                clientName: nil,
                tabID: prior.contextID,
                workspaceID: prior.workspace.id,
                windowID: prior.window.windowID,
                frozenFileToolAuthority: priorAuthority
            )
            let replacementAuthority = try await replacement.window.mcpServer.resolveFileToolAuthority(
                tabID: replacement.contextID,
                workspaceID: replacement.workspace.id
            )
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [prior.window, replacement.window]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            let service = WindowRoutingService(
                windowStates: WindowStatesManager.shared,
                networkMgr: ServerNetworkManager.shared,
                setActiveWindowForCurrentConnection: { _ in throw AffinityFailure.injected }
            )

            do {
                _ = try await service.test_bindTarget(
                    windowID: replacement.window.windowID,
                    workspaceID: replacement.workspace.id,
                    tabID: replacement.contextID,
                    repoPaths: replacement.workspace.repoPaths,
                    connectionID: prior.connectionID,
                    authority: replacementAuthority
                )
                XCTFail("The injected affinity failure must reject replacement")
            } catch {
                XCTAssertTrue(error is AffinityFailure)
            }

            let retained = prior.window.mcpServer.connectionBindingSnapshot(forConnection: prior.connectionID)
            XCTAssertEqual(retained.windowID, prior.window.windowID)
            XCTAssertEqual(retained.workspaceID, prior.workspace.id)
            XCTAssertEqual(retained.tabID, prior.contextID)
            let consumed = try await prior.window.mcpServer.requiredFileToolLookupContext(from: metadata(for: prior))
            XCTAssertTrue(priorAuthority.hasSameRoutingAuthority(as: consumed))
            XCTAssertNil(replacement.window.mcpServer.boundTabID(forConnection: prior.connectionID))
        }

        @MainActor
        func testBindSerializesHeldHydrationAsRetryableAuthorityFailure() async throws {
            let root = try makeTemporaryRoot()
            let targetWindow = WindowState()
            await targetWindow.workspaceManager.awaitInitialized()
            let contextID = UUID()
            let workspace = WorkspaceModel(
                name: "Held Hydration",
                repoPaths: [root.path],
                composeTabs: [ComposeTabState(id: contextID, name: "Context")],
                activeComposeTabID: contextID
            )
            targetWindow.workspaceManager.workspaces = [workspace]
            let gate = RootHydrationSuspensionGate()
            targetWindow.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { _ in
                await gate.hold()
            }
            addTeardownBlock { @MainActor in
                targetWindow.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
                await gate.release()
            }
            let switchTask = Task { @MainActor in
                await targetWindow.workspaceManager.switchWorkspace(
                    to: workspace,
                    saveState: false,
                    reason: "bind-context-held-hydration-test"
                )
            }
            await gate.waitUntilHeld()

            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [targetWindow]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let toolsEnabled = await targetWindow.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(toolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await targetWindow.mcpServer.setWindowToolsEnabled(false)
            }
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let result = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(result.isError, true, toolText(result))
            let data = try XCTUnwrap(toolText(result).data(using: .utf8))
            let response = try JSONDecoder().decode(BindContextResponse.self, from: data)
            XCTAssertEqual(response.changed, false)
            XCTAssertEqual(response.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(response.retryable, true)
            XCTAssertEqual(response.retryAfterMilliseconds, 1000)
            XCTAssertFalse(response.binding.explicit)
            XCTAssertNil(response.binding.contextID)

            await gate.release()
            _ = await switchTask.value
        }

        @MainActor
        func testGenuinelyRootlessBindProducesExplicitEmptyAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )

            XCTAssertTrue(authority.rootCatalogSnapshot.isGenuinelyRootless)
            XCTAssertEqual(authority.lookupContext.bindingProjection, nil)
        }

        func testFileTreeReadinessFailureIsTypedAndRetryable() throws {
            let value = try failureValue(tool: MCPWindowToolName.getFileTree, args: ["type": .string("roots")])
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.FileTreeDTO.self))
            XCTAssertEqual(reply.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(reply.retryable, true)
            XCTAssertEqual(reply.retryAfterMilliseconds, 1000)
        }

        func testReadFileReadinessFailurePreservesRequestedPath() throws {
            let value = try failureValue(tool: MCPWindowToolName.readFile, args: ["path": .string("README.md")])
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.ReadFileReply.self))
            XCTAssertEqual(reply.displayPath, "README.md")
            XCTAssertEqual(reply.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(reply.retryable, true)
        }

        func testFileSearchReadinessFailureIsTypedAndEmpty() throws {
            let value = try failureValue(tool: MCPWindowToolName.search, args: ["pattern": .string("needle")])
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.SearchResultDTO.self))
            XCTAssertEqual(reply.totalMatches, 0)
            XCTAssertEqual(reply.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(reply.retryable, true)
        }

        func testCodeStructureReadinessFailurePrecedesProjection() throws {
            let value = try failureValue(
                tool: MCPWindowToolName.getCodeStructure,
                args: ["paths": .array([.string("Sources")])]
            )
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.CodeStructureReplyDTO.self))
            XCTAssertEqual(reply.status, .unavailable)
            XCTAssertEqual(reply.issues.map(\.code), ["workspace_authority_timeout"])
            XCTAssertEqual(reply.issues.map(\.retryable), [true])
            XCTAssertEqual(reply.files, [])
        }

        private func failureValue(tool: String, args: [String: Value]) throws -> Value {
            try MCPFileToolProvider.authorityFailureValue(
                toolName: tool,
                args: args,
                failure: .timedOut
            )
        }

        @MainActor
        private func makeFixture(rootPaths: [String]) async throws -> Fixture {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
            let window = WindowState()
            await window.workspaceManager.awaitInitialized()
            let contextID = UUID()
            let workspace = WorkspaceModel(
                name: "Authority",
                repoPaths: rootPaths,
                composeTabs: [ComposeTabState(id: contextID, name: "Context")],
                activeComposeTabID: contextID
            )
            window.workspaceManager.workspaces = [workspace]
            let result = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "bind-context-file-authority-test"
            )
            XCTAssertTrue(result.didSwitch)
            return Fixture(
                window: window,
                workspace: workspace,
                contextID: contextID,
                connectionID: UUID()
            )
        }

        private func makeTemporaryRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-bind-authority-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return root
        }

        @MainActor
        private func metadata(for fixture: Fixture) -> MCPServerViewModel.RequestMetadata {
            MCPServerViewModel.RequestMetadata(
                connectionID: fixture.connectionID,
                clientName: "BindContextFileAuthorityTests",
                windowID: fixture.window.windowID
            )
        }

        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }

        private func makeProductionMCPConnection() async throws -> ProductionMCPConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer {
                for descriptor in descriptors where descriptor >= 0 {
                    Darwin.close(descriptor)
                }
            }

            let connectionID = UUID()
            let sessionToken = "bind-file-authority-\(UUID().uuidString)"
            let clientName = "BindContextFileAuthorityTests"
            let networkManager = ServerNetworkManager.shared
            let wasNetworkManagerRunning = await networkManager.isRunning()
            let connectionManager = try BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                observedKernelPeerPID: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: true,
                connectedFD: descriptors[0],
                parentManager: networkManager
            )
            descriptors[0] = -1
            let clientTransport = try UnixSocketMCPTransport(
                connectedFD: descriptors[1],
                connectionID: connectionID,
                correlationConnectionID: sessionToken
            )
            descriptors[1] = -1
            await networkManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: connectionManager,
                pendingClientID: clientName
            )
            _ = await networkManager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)

            do {
                try await connectionManager.start { $0.name == clientName }
                let client = Client(name: clientName, version: "1.0")
                _ = try await client.connect(transport: clientTransport)
                return ProductionMCPConnection(
                    client: client,
                    connectionID: connectionID,
                    connectionManager: connectionManager,
                    wasNetworkManagerRunning: wasNetworkManagerRunning
                )
            } catch {
                await clientTransport.disconnect()
                await connectionManager.stop()
                await networkManager.debugRemoveConnection(connectionID)
                if !wasNetworkManagerRunning {
                    await networkManager.stop()
                }
                throw error
            }
        }
    }

    private struct Fixture {
        let window: WindowState
        let workspace: WorkspaceModel
        let contextID: UUID
        let connectionID: UUID
    }

    private enum AffinityFailure: Error {
        case injected
    }

    private actor RootHydrationSuspensionGate {
        private var held = false
        private var released = false
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            held = true
            let waiters = heldWaiters
            heldWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilHeld() async {
            guard !held else { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private struct ProductionMCPConnection {
        let client: Client
        let connectionID: UUID
        let connectionManager: BootstrapSocketConnectionManager
        let wasNetworkManagerRunning: Bool

        func cleanup() async {
            let networkManager = ServerNetworkManager.shared
            await client.disconnect()
            await connectionManager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            if !wasNetworkManagerRunning {
                await networkManager.stop()
            }
        }
    }
#endif
