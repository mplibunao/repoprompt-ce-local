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
        func testOneShotHintOnUnboundConnectionResolvesAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let expected = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )

            let consumed = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                from: hintMetadata(for: fixture)
            )

            XCTAssertEqual(consumed.lookupContext, expected.lookupContext)
            XCTAssertNil(fixture.window.mcpServer.boundTabID(forConnection: fixture.connectionID))
        }

        @MainActor
        func testOneShotHintOnUnboundConnectionHydratesAgentSessionAuthority() async throws {
            let fixture = try await makeFixture(
                rootPaths: [makeTemporaryRoot().path],
                activeAgentSessionID: UUID()
            )
            installWorktreeBindingHydration(on: fixture.window.mcpServer)

            let consumed = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                from: hintMetadata(for: fixture)
            )

            XCTAssertNil(consumed.lookupContext.bindingProjection)
            XCTAssertNil(fixture.window.mcpServer.boundTabID(forConnection: fixture.connectionID))
        }

        @MainActor
        func testBoundRouteReplacedDuringHydrationIsSuperseded() async throws {
            let replacementTabID = UUID()
            let fixture = try await makeFixture(
                rootPaths: [makeTemporaryRoot().path],
                activeAgentSessionID: UUID(),
                additionalTabIDs: [replacementTabID]
            )
            let server = fixture.window.mcpServer
            try server.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID
            )
            installWorktreeBindingHydration(on: server) {
                try? server.bindTabForConnection(
                    connectionID: fixture.connectionID,
                    clientName: nil,
                    tabID: replacementTabID,
                    workspaceID: fixture.workspace.id,
                    windowID: fixture.window.windowID
                )
            }
            let staleCompletionsBefore = server.fileToolLookupContextStaleCompletionCount

            await assertSuperseded {
                _ = try await server.requiredFileToolLookupContext(from: metadata(for: fixture))
            }
            XCTAssertEqual(server.boundTabID(forConnection: fixture.connectionID), replacementTabID)
            // Pins the failure to the post-hydration binding check, the only stale completion on this path.
            XCTAssertEqual(server.fileToolLookupContextStaleCompletionCount, staleCompletionsBefore + 1)
        }

        @MainActor
        func testBoundRouteWithoutFrozenAuthorityResolvesAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let server = fixture.window.mcpServer
            try server.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID
            )
            installRootCatalogCaptureHook(on: fixture) {}

            let consumed = try await server.requiredFileToolLookupContext(from: metadata(for: fixture))

            XCTAssertEqual(server.boundTabID(forConnection: fixture.connectionID), fixture.contextID)
            XCTAssertNil(consumed.lookupContext.bindingProjection)
        }

        @MainActor
        func testOneShotHintWhoseTabChangesDuringHydrationIsSuperseded() async throws {
            let fixture = try await makeFixture(
                rootPaths: [makeTemporaryRoot().path],
                activeAgentSessionID: UUID()
            )
            installWorktreeBindingHydration(on: fixture.window.mcpServer) {
                Self.reassignAgentSession(of: fixture)
            }

            await assertSuperseded {
                _ = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                    from: hintMetadata(for: fixture)
                )
            }
        }

        @MainActor
        func testOneShotHintWhoseTabChangesDuringRootCatalogWaitIsSuperseded() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            installRootCatalogCaptureHook(on: fixture) {
                Self.reassignAgentSession(of: fixture)
            }

            await assertSuperseded {
                _ = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                    from: hintMetadata(for: fixture)
                )
            }
        }

        @MainActor
        func testRunCarryingHintOnUnboundConnectionIsSuperseded() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let server = fixture.window.mcpServer
            server.connectionIDToRunID[fixture.connectionID] = UUID()
            addTeardownBlock { @MainActor in
                server.connectionIDToRunID.removeValue(forKey: fixture.connectionID)
            }

            await assertSuperseded {
                _ = try await server.requiredFileToolLookupContext(from: hintMetadata(for: fixture))
            }
        }

        @MainActor
        func testBoundRouteReplacedDuringRootCatalogWaitIsSuperseded() async throws {
            let replacementTabID = UUID()
            let fixture = try await makeFixture(
                rootPaths: [makeTemporaryRoot().path],
                additionalTabIDs: [replacementTabID]
            )
            let server = fixture.window.mcpServer
            try server.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID
            )
            installRootCatalogCaptureHook(on: fixture) {
                try? server.bindTabForConnection(
                    connectionID: fixture.connectionID,
                    clientName: nil,
                    tabID: replacementTabID,
                    workspaceID: fixture.workspace.id,
                    windowID: fixture.window.windowID
                )
            }

            await assertSuperseded {
                _ = try await server.requiredFileToolLookupContext(from: metadata(for: fixture))
            }
            XCTAssertEqual(server.boundTabID(forConnection: fixture.connectionID), replacementTabID)
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

        /// Binding to a tab whose worktree folder is gone, through its Agent session or through the
        /// tab's own worktree scope, refuses with the missing-worktree refusal and keeps the
        /// connection's previous binding.
        @MainActor
        func testBindToDeletedWorktreePreservesPreviousBinding() async throws {
            for owner in MissingWorktreeOwner.allCases {
                try await assertBindToDeletedWorktreePreservesPreviousBinding(ownedBy: owner)
            }
        }

        @MainActor
        private func assertBindToDeletedWorktreePreservesPreviousBinding(ownedBy owner: MissingWorktreeOwner) async throws {
            let root = try makeTemporaryRoot()
            let deletedWorktree = try makeTemporaryRoot()
            try FileManager.default.removeItem(at: deletedWorktree)
            let healthyTabID = UUID()
            let binding = worktreeBinding(logicalRoot: root, worktreeRoot: deletedWorktree)
            let fixture = try await makeFixture(
                rootPaths: [root.path],
                activeAgentSessionID: owner == .agentSession ? UUID() : nil,
                worktreeScope: owner == .tab ? .bound([binding]) : nil,
                additionalTabIDs: [healthyTabID]
            )
            if owner == .agentSession {
                installHydratedWorktreeBindings([binding], on: fixture.window.mcpServer)
            }
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [fixture.window]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let toolsEnabled = await fixture.window.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(toolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await fixture.window.mcpServer.setWindowToolsEnabled(false)
            }
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let healthy = try await bindContext(healthyTabID, over: connection)
            XCTAssertEqual(healthy.changed, true)
            XCTAssertNil(healthy.errorCode)
            XCTAssertEqual(healthy.binding.contextID, healthyTabID)

            let stale = try await bindContext(fixture.contextID, over: connection)

            let expected = MCPUnavailableWorktreeDiagnostic(
                binding: binding,
                routeContext: .init(tabName: "Context", windowID: fixture.window.windowID)
            )
            XCTAssertEqual(stale.changed, false, "\(owner)")
            XCTAssertEqual(stale.errorCode, "worktree_scope_unavailable", "\(owner)")
            XCTAssertEqual(stale.error, expected.message, "\(owner)")
            XCTAssertEqual(stale.retryable, false, "\(owner)")
            XCTAssertNil(stale.retryAfterMilliseconds, "\(owner)")
            XCTAssertEqual(stale.binding, healthy.binding, "\(owner)")
            XCTAssertEqual(
                fixture.window.mcpServer.connectionBindingSnapshot(forConnection: connection.connectionID).tabID,
                healthyTabID,
                "\(owner)"
            )
        }

        /// A lifetime check can fail while the worktree folder still exists, for example when the
        /// store no longer owns the session root. That isn't a missing folder, so it stays generic.
        @MainActor
        func testExistingDirectoryWithRevokedWorktreeAuthorityKeepsGenericFailure() async throws {
            let root = try makeTemporaryRoot()
            let worktreeRoot = try makeTemporaryRoot()
            let sessionID = UUID()
            let fixture = try await makeFixture(rootPaths: [root.path], activeAgentSessionID: sessionID)
            installHydratedWorktreeBindings(
                [worktreeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)],
                on: fixture.window.mcpServer
            )
            let store = fixture.window.promptManager.workspaceFileContextStore
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            addTeardownBlock { await materializer.release(sessionID: sessionID) }
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            XCTAssertNotNil(authority.lookupContext.bindingProjection)

            await materializer.release(sessionID: sessionID)

            do {
                try await authority.validate(workspaceManager: fixture.window.workspaceManager, store: store)
                XCTFail("Revoked session-root ownership must invalidate captured authority")
            } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                XCTAssertEqual(failure, .worktreeScopeUnavailable)
                XCTAssertTrue(failure.retryable)
                XCTAssertEqual(failure.retryAfterMilliseconds, 1000)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: worktreeRoot.path))
        }

        /// A worktree scope saved with its tab restores in a new window, so reads through the tab
        /// come from the worktree with no projection left from before the save. A saved scope that
        /// doesn't decode keeps that tab and its siblings, and the tab's reads are refused rather
        /// than served from the main checkout.
        @MainActor
        func testRestoredTabScopePreservesCheckoutAuthority() async throws {
            let root = try makeTemporaryRoot()
            let worktreeRoot = try makeTemporaryRoot()
            let sentinelPath = root.appendingPathComponent("scope-sentinel.txt").path
            let mainSentinel = "restored-scope-main-checkout"
            let worktreeSentinel = "restored-scope-worktree"
            try mainSentinel.write(toFile: sentinelPath, atomically: true, encoding: .utf8)
            try worktreeSentinel.write(
                to: worktreeRoot.appendingPathComponent("scope-sentinel.txt"),
                atomically: true,
                encoding: .utf8
            )
            let scopedTabID = UUID()
            let malformedTabID = UUID()
            let siblingTabID = UUID()
            let binding = worktreeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)
            let savedBytes = try JSONEncoder().encode(WorkspaceModel(
                name: "Authority",
                repoPaths: [root.path],
                composeTabs: [
                    ComposeTabState(id: scopedTabID, name: "Scoped", worktreeScope: .bound([binding])),
                    ComposeTabState(id: malformedTabID, name: "Malformed", worktreeScope: .bound([binding])),
                    ComposeTabState(id: siblingTabID, name: "Sibling")
                ],
                activeComposeTabID: siblingTabID
            ))
            // A saved scope with an empty binding list is malformed.
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: savedBytes) as? [String: Any])
            var savedTabs = try XCTUnwrap(document["composeTabs"] as? [[String: Any]])
            savedTabs[1]["worktreeScope"] = ["state": "bound", "bindings": [Any]()]
            document["composeTabs"] = savedTabs
            let restored = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: JSONSerialization.data(withJSONObject: document)
            )
            XCTAssertEqual(restored.composeTabs.map(\.id), [scopedTabID, malformedTabID, siblingTabID])
            XCTAssertEqual(restored.composeTabs[1].worktreeScope, .unavailable)

            let fixture = try await makeFixture(workspace: restored, contextID: scopedTabID)
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [fixture.window]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            let store = fixture.window.promptManager.workspaceFileContextStore
            addTeardownBlock {
                await WorkspaceRootBindingProjectionMaterializer(store: store).release(sessionID: scopedTabID)
            }
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let toolsEnabled = await fixture.window.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(toolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await fixture.window.mcpServer.setWindowToolsEnabled(false)
            }
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let refused = try await readFile(sentinelPath, contextID: malformedTabID, over: connection)
            XCTAssertEqual(refused.errorCode, "workspace_authority_unavailable")
            XCTAssertFalse(refused.content.contains(mainSentinel), refused.content)

            let bound = try await bindContext(scopedTabID, over: connection)
            XCTAssertNil(bound.errorCode, bound.error ?? "")
            let read = try await readFile(sentinelPath, over: connection)
            XCTAssertNil(read.errorCode, read.errorMessage ?? "")
            XCTAssertTrue(read.content.contains(worktreeSentinel), read.content)
            XCTAssertFalse(read.content.contains(mainSentinel), read.content)
        }

        /// An Agent review launched from a tab with its own worktree scope freezes that scope as
        /// its packaging source: the frozen lookup reads the worktree under the tab's ownership,
        /// the source carries the scope's bindings, and no Agent session is recorded as provenance.
        @MainActor
        func testScopedTabReviewLaunchSourceFreezesTabWorktree() async throws {
            let root = try makeTemporaryRoot()
            let worktreeRoot = try makeTemporaryRoot()
            let binding = worktreeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)
            let scopedTabID = UUID()
            let fixture = try await makeFixture(
                workspace: WorkspaceModel(
                    name: "Authority",
                    repoPaths: [root.path],
                    composeTabs: [ComposeTabState(id: scopedTabID, name: "Scoped", worktreeScope: .bound([binding]))],
                    activeComposeTabID: scopedTabID
                ),
                contextID: scopedTabID
            )
            let store = fixture.window.promptManager.workspaceFileContextStore
            addTeardownBlock {
                await WorkspaceRootBindingProjectionMaterializer(store: store).release(sessionID: scopedTabID)
            }
            let launch = AgentRunOracleReviewLaunchSnapshot(
                route: .explicitTabContext,
                windowID: fixture.window.windowID,
                workspaceID: fixture.workspace.id,
                tabID: scopedTabID,
                selectionRevision: fixture.window.workspaceManager.selectionRevisionForMCP(
                    workspaceID: fixture.workspace.id,
                    tabID: scopedTabID
                ),
                promptText: "",
                selection: StoredSelection(),
                sourceAgentSessionID: nil,
                routedRunID: nil
            )

            let source = await fixture.window.mcpServer.testCaptureAgentRunOracleReviewSource(
                snapshot: launch,
                targetWindow: fixture.window
            )

            guard case let .captured(captured) = source else {
                return XCTFail("Expected a captured review source, got \(source)")
            }
            let physicalPath = captured.lookupContext.translateInputPath(
                root.appendingPathComponent("review-source.swift").path
            )
            XCTAssertEqual(
                URL(fileURLWithPath: physicalPath).resolvingSymlinksInPath().deletingLastPathComponent().path,
                worktreeRoot.resolvingSymlinksInPath().path
            )
            XCTAssertEqual(captured.lookupContext.bindingProjection?.sessionID, scopedTabID)
            XCTAssertEqual(captured.sourceWorktreeBindings, [binding])
            XCTAssertNil(captured.sourceAgentSessionID)
        }

        /// The logical file tree can't show a path that exists only in a tab's worktree, so when a
        /// worktree-scoped tab is the visible tab, an MCP snapshot keeps the tab's stored selection
        /// instead of capturing and flushing the file tree's. That holds for an unreadable scope too.
        @MainActor
        func testVisibleScopedTabSnapshotKeepsStoredWorktreeSelection() async throws {
            let root = try makeTemporaryRoot()
            let worktreeRoot = try makeTemporaryRoot()
            try "worktree".write(
                to: worktreeRoot.appendingPathComponent("worktree-only.swift"),
                atomically: true,
                encoding: .utf8
            )
            let storedSelection = StoredSelection(
                selectedPaths: [root.appendingPathComponent("worktree-only.swift").path]
            )
            let binding = worktreeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)
            for scope: ComposeTabWorktreeScope in [.bound([binding]), .unavailable] {
                let scopedTabID = UUID()
                let fixture = try await makeFixture(
                    workspace: WorkspaceModel(
                        name: "Authority",
                        repoPaths: [root.path],
                        composeTabs: [ComposeTabState(
                            id: scopedTabID,
                            name: "Scoped",
                            worktreeScope: scope,
                            selection: storedSelection
                        )],
                        activeComposeTabID: scopedTabID
                    ),
                    contextID: scopedTabID
                )

                let snapshot = try fixture.window.mcpServer.makeTabContextSnapshot(
                    tabID: scopedTabID,
                    workspaceID: fixture.workspace.id,
                    windowID: fixture.window.windowID,
                    runID: nil,
                    explicitlyBound: true,
                    captureActiveUIState: true,
                    flushActiveSelection: true
                )

                XCTAssertEqual(snapshot.selection, storedSelection, "\(scope)")
            }
        }

        /// A fork of a worktree-scoped tab owns its own projection of the same worktree. Closing the
        /// source releases the source's ownership of the worktree root, and a lookup for the source
        /// still in flight at the close can't install it again. The fork's authority, captured
        /// before the close, still validates, and the fork keeps reading the worktree.
        @MainActor
        func testClosingScopedTabRevokesItsAuthorityWithoutRevokingFork() async throws {
            let root = try makeTemporaryRoot()
            let worktreeRoot = try makeTemporaryRoot()
            let sentinelPath = root.appendingPathComponent("fork-sentinel.txt").path
            let mainSentinel = "fork-scope-main-checkout"
            let worktreeSentinel = "fork-scope-worktree"
            try mainSentinel.write(toFile: sentinelPath, atomically: true, encoding: .utf8)
            try worktreeSentinel.write(
                to: worktreeRoot.appendingPathComponent("fork-sentinel.txt"),
                atomically: true,
                encoding: .utf8
            )
            let binding = worktreeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)
            let sourceTabID = UUID()
            let visibleTabID = UUID()
            let fixture = try await makeFixture(
                workspace: WorkspaceModel(
                    name: "Authority",
                    repoPaths: [root.path],
                    composeTabs: [
                        ComposeTabState(id: visibleTabID, name: "Visible"),
                        ComposeTabState(id: sourceTabID, name: "Scoped", worktreeScope: .bound([binding]))
                    ],
                    activeComposeTabID: visibleTabID
                ),
                contextID: sourceTabID
            )
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [fixture.window]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            let server = fixture.window.mcpServer
            let manager = fixture.window.workspaceManager
            let store = fixture.window.promptManager.workspaceFileContextStore
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let toolsEnabled = await server.setWindowToolsEnabled(true)
            XCTAssertTrue(toolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await server.setWindowToolsEnabled(false)
            }
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let forked = try await connection.client.callTool(name: "manage_workspaces", arguments: [
                "action": .string("create_tab"),
                "mode": .string("fork"),
                "source_tab": .string(sourceTabID.uuidString),
                "bind": .bool(false)
            ])
            XCTAssertNotEqual(forked.isError, true, toolText(forked))
            let forkTab = try XCTUnwrap(manager.activeWorkspace?.composeTabs.first {
                $0.id != visibleTabID && $0.id != sourceTabID
            })
            addTeardownBlock {
                await WorkspaceRootBindingProjectionMaterializer(store: store).release(sessionID: forkTab.id)
            }
            XCTAssertEqual(forkTab.worktreeScope, .bound([binding]))
            XCTAssertNil(forkTab.activeAgentSessionID)

            let sourceAuthority = try await server.resolveFileToolAuthority(
                tabID: sourceTabID,
                workspaceID: fixture.workspace.id
            )
            XCTAssertEqual(sourceAuthority.lookupContext.bindingProjection?.sessionID, sourceTabID)
            let forkAuthority = try await server.resolveFileToolAuthority(
                tabID: forkTab.id,
                workspaceID: fixture.workspace.id
            )
            XCTAssertEqual(forkAuthority.lookupContext.bindingProjection?.sessionID, forkTab.id)
            let gate = RootHydrationSuspensionGate()
            try server.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: sourceTabID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID
            )
            server.setBeforeFileToolLookupContextResolutionForTesting { await gate.hold() }
            addTeardownBlock { @MainActor in
                server.setBeforeFileToolLookupContextResolutionForTesting(nil)
                await gate.release()
            }
            let lateLookup = Task { @MainActor in
                try await server.requiredFileToolLookupContext(from: self.metadata(for: fixture))
            }
            await gate.waitUntilHeld()

            let closed = try await connection.client.callTool(name: "manage_workspaces", arguments: [
                "action": .string("close_tab"),
                "tab": .string(sourceTabID.uuidString)
            ])
            XCTAssertNotEqual(closed.isError, true, toolText(closed))
            XCTAssertNil(manager.composeTab(with: sourceTabID))

            func sourceOwnedRoots() async -> [WorkspaceRootRecord]? {
                await store.installedSessionWorktreeRoots(
                    ownerID: sourceTabID,
                    bindingFingerprint: AgentWorkspaceLookupContextSource.worktreeBindingFingerprint([binding]),
                    physicalRootPaths: [worktreeRoot.path]
                )
            }
            let rootsAfterClose = await sourceOwnedRoots()
            XCTAssertNil(rootsAfterClose, "Closing the scoped tab must release its worktree root")
            await gate.release()
            let lateResult = await lateLookup.result
            if case .success = lateResult {
                XCTFail("A lookup for the closed tab must not complete")
            }
            let rootsAfterLateLookup = await sourceOwnedRoots()
            XCTAssertNil(rootsAfterLateLookup, "A late lookup reinstalled the closed tab's worktree root")
            do {
                try await forkAuthority.validate(workspaceManager: manager, store: store)
            } catch {
                XCTFail("Closing the source revoked the fork's authority: \(error)")
            }

            let forkRead = try await readFile(sentinelPath, contextID: forkTab.id, over: connection)
            XCTAssertNil(forkRead.errorCode, forkRead.errorMessage ?? "")
            XCTAssertTrue(forkRead.content.contains(worktreeSentinel), forkRead.content)
            XCTAssertFalse(forkRead.content.contains(mainSentinel), forkRead.content)
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
        private func bindContext(
            _ contextID: UUID,
            over connection: ProductionMCPConnection
        ) async throws -> BindContextResponse {
            let result = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(result.isError, true, toolText(result))
            let data = try XCTUnwrap(toolText(result).data(using: .utf8))
            return try JSONDecoder().decode(BindContextResponse.self, from: data)
        }

        /// Reads `path` through the connection's binding, or through `contextID` as a one-shot hint.
        @MainActor
        private func readFile(
            _ path: String,
            contextID: UUID? = nil,
            over connection: ProductionMCPConnection
        ) async throws -> ToolResultDTOs.ReadFileReply {
            var arguments: [String: Value] = ["path": .string(path), "_rawJSON": .bool(true)]
            if let contextID {
                arguments["context_id"] = .string(contextID.uuidString)
            }
            let result = try await connection.client.callTool(name: MCPWindowToolName.readFile, arguments: arguments)
            let data = try XCTUnwrap(toolText(result).data(using: .utf8))
            return try JSONDecoder().decode(ToolResultDTOs.ReadFileReply.self, from: data)
        }

        private func worktreeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
            AgentSessionWorktreeBinding(
                id: "bind-authority-binding",
                repositoryID: "bind-authority-repo",
                repoKey: logicalRoot.path,
                logicalRootPath: logicalRoot.path,
                logicalRootName: "bind-authority-root",
                worktreeID: "bind-authority-worktree",
                worktreeRootPath: worktreeRoot.path,
                worktreeName: "stale-worktree",
                branch: "bugfix/stale-worktree",
                source: "test"
            )
        }

        /// Reports the tab's agent session as already hydrated with `bindings`.
        @MainActor
        private func installHydratedWorktreeBindings(
            _ bindings: [AgentSessionWorktreeBinding],
            on server: MCPServerViewModel
        ) {
            let previousProvider = server.agentWorktreeBindingStateProvider
            let previousResolver = server.agentWorktreeBindingStateResolver
            server.agentWorktreeBindingStateProvider = { _, _ in .hydrated(bindings) }
            server.agentWorktreeBindingStateResolver = { _, _ in .hydrated(bindings) }
            addTeardownBlock { @MainActor in
                server.agentWorktreeBindingStateProvider = previousProvider
                server.agentWorktreeBindingStateResolver = previousResolver
            }
        }

        /// Reports the tab's agent-session worktree binding as unhydrated until the resolver runs,
        /// and runs `duringHydration` inside that await, the window in which a route can be replaced.
        @MainActor
        private func installWorktreeBindingHydration(
            on server: MCPServerViewModel,
            duringHydration: @escaping @MainActor () -> Void = {}
        ) {
            let state = WorktreeBindingStateBox()
            let previousProvider = server.agentWorktreeBindingStateProvider
            let previousResolver = server.agentWorktreeBindingStateResolver
            server.agentWorktreeBindingStateProvider = { _, _ in state.value }
            server.agentWorktreeBindingStateResolver = { _, _ in
                duringHydration()
                state.value = .hydrated([])
                return state.value
            }
            addTeardownBlock { @MainActor in
                server.agentWorktreeBindingStateProvider = previousProvider
                server.agentWorktreeBindingStateResolver = previousResolver
            }
        }

        @MainActor
        private func installRootCatalogCaptureHook(
            on fixture: Fixture,
            _ action: @escaping @MainActor () -> Void
        ) {
            let manager = fixture.window.workspaceManager
            manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting { action() }
            addTeardownBlock { @MainActor in
                manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting(nil)
            }
        }

        @MainActor
        private static func reassignAgentSession(of fixture: Fixture) {
            let manager = fixture.window.workspaceManager
            guard let workspaceIndex = manager.workspaces.firstIndex(where: { $0.id == fixture.workspace.id }),
                  let tabIndex = manager.workspaces[workspaceIndex].composeTabs
                      .firstIndex(where: { $0.id == fixture.contextID })
            else { return XCTFail("Hinted tab must exist before it is reassigned") }
            manager.workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID = UUID()
        }

        @MainActor
        private func assertSuperseded(
            _ operation: @MainActor () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("Expected superseded file-tool authority", file: file, line: line)
            } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                XCTAssertEqual(failure, .superseded, file: file, line: line)
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }

        @MainActor
        private func makeFixture(
            rootPaths: [String],
            activeAgentSessionID: UUID? = nil,
            worktreeScope: ComposeTabWorktreeScope? = nil,
            additionalTabIDs: [UUID] = []
        ) async throws -> Fixture {
            let contextID = UUID()
            return try await makeFixture(
                workspace: WorkspaceModel(
                    name: "Authority",
                    repoPaths: rootPaths,
                    composeTabs: [ComposeTabState(
                        id: contextID,
                        name: "Context",
                        activeAgentSessionID: activeAgentSessionID,
                        worktreeScope: worktreeScope
                    )] + additionalTabIDs.map { ComposeTabState(id: $0, name: "Other") },
                    activeComposeTabID: contextID
                ),
                contextID: contextID
            )
        }

        /// Opens `workspace` in a new window, which has its own store and no projections.
        @MainActor
        private func makeFixture(workspace: WorkspaceModel, contextID: UUID) async throws -> Fixture {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
            let window = WindowState()
            await window.workspaceManager.awaitInitialized()
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

        @MainActor
        private func hintMetadata(for fixture: Fixture) -> MCPServerViewModel.RequestMetadata {
            MCPServerViewModel.RequestMetadata(
                connectionID: fixture.connectionID,
                clientName: "BindContextFileAuthorityTests",
                windowID: fixture.window.windowID,
                tabContextHint: MCPServerViewModel.TabContextHint(
                    tabID: fixture.contextID,
                    workspaceID: fixture.workspace.id,
                    windowID: fixture.window.windowID
                )
            )
        }

        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content {
                    return text
                }
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

    @MainActor
    private final class WorktreeBindingStateBox {
        var value: AgentSessionWorktreeBindingState = .unhydrated
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
