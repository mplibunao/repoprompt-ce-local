import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class BindContextRoutingAuthorityTests: XCTestCase {
    #if DEBUG
        @MainActor
        func testExplicitBindThenContextIDRoutedToolUsesSameCompositeContext() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-bind-routing-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: rootURL)
            }

            let contextID = UUID()
            let staleMatch = workspace(name: "Stored Target", root: rootURL.path, contextID: contextID)
            let unrelated = workspace(
                name: "Active Unrelated",
                root: rootURL.appendingPathComponent("unrelated").path,
                contextID: UUID()
            )
            let activeTarget = workspace(name: "Active Target", root: rootURL.path, contextID: contextID)
            let replacementActive = workspace(
                name: "Replacement Active",
                root: rootURL.appendingPathComponent("replacement").path,
                contextID: UUID()
            )
            let orderedWindows = [makeWindowInstance(), makeWindowInstance()].sorted { $0.windowID < $1.windowID }
            let staleWindow = orderedWindows[0]
            let targetWindow = orderedWindows[1]
            try await configureWindow(staleWindow, activeWorkspace: unrelated, savedWorkspaces: [staleMatch])
            try await configureWindow(targetWindow, activeWorkspace: activeTarget)
            _ = installWindows(orderedWindows)
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let staleToolsEnabled = await staleWindow.mcpServer.setWindowToolsEnabled(true)
            let targetToolsEnabled = await targetWindow.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(staleToolsEnabled)
            XCTAssertTrue(targetToolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await staleWindow.mcpServer.setWindowToolsEnabled(false)
                _ = await targetWindow.mcpServer.setWindowToolsEnabled(false)
            }

            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let bindResult = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(bindResult.isError, true, toolText(bindResult))

            let boundBeforeCall = targetWindow.mcpServer.connectionBindingSnapshot(
                forConnection: connection.connectionID
            )
            XCTAssertEqual(boundBeforeCall.windowID, targetWindow.windowID)
            XCTAssertEqual(boundBeforeCall.workspaceID, activeTarget.id)
            XCTAssertEqual(boundBeforeCall.tabID, contextID)
            XCTAssertTrue(boundBeforeCall.explicitlyBound)
            XCTAssertNil(boundBeforeCall.runID)

            let routedResult = try await connection.client.callTool(name: "workspace_context", arguments: [
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(routedResult.isError, true, toolText(routedResult))

            try await configureWindow(
                targetWindow,
                activeWorkspace: replacementActive,
                savedWorkspaces: [activeTarget]
            )
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, replacementActive.id)

            let routedAfterWorkspaceSwitch = try await connection.client.callTool(
                name: "workspace_context",
                arguments: [
                    "context_id": .string(contextID.uuidString),
                    "_rawJSON": .bool(true)
                ]
            )
            XCTAssertNotEqual(
                routedAfterWorkspaceSwitch.isError,
                true,
                toolText(routedAfterWorkspaceSwitch)
            )

            let statusResult = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("status"),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(statusResult.isError, true, toolText(statusResult))
            let statusData = try XCTUnwrap(toolText(statusResult).data(using: .utf8))
            let status = try JSONDecoder().decode(BindContextResponse.self, from: statusData)
            XCTAssertEqual(status.binding.windowID, targetWindow.windowID)
            XCTAssertEqual(status.binding.workspaceID, activeTarget.id)
            XCTAssertEqual(status.binding.contextID, contextID)
            XCTAssertTrue(status.binding.explicit)
            XCTAssertFalse(status.binding.runScoped)

            let boundAfterCall = targetWindow.mcpServer.connectionBindingSnapshot(
                forConnection: connection.connectionID
            )
            XCTAssertEqual(boundAfterCall.windowID, boundBeforeCall.windowID)
            XCTAssertEqual(boundAfterCall.workspaceID, boundBeforeCall.workspaceID)
            XCTAssertEqual(boundAfterCall.tabID, boundBeforeCall.tabID)
            XCTAssertTrue(boundAfterCall.explicitlyBound)
            XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)

            await connection.cleanup()
            let networkManagerRunningAfterCleanup = await ServerNetworkManager.shared.isRunning()
            XCTAssertEqual(networkManagerRunningAfterCleanup, connection.wasNetworkManagerRunning)
        }
    #endif

    @MainActor
    func testContextIDBindIgnoresPreferredInactiveWorkspaceMatch() async throws {
        let contextID = UUID()
        let target = workspace(name: "Target", root: "/tmp/repoprompt-bind-target", contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let targetWindow = try await makeWindow(activeWorkspace: target)
        let service = installWindows([staleWindow, targetWindow])

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )

        XCTAssertEqual(resolved.windowID, targetWindow.windowID)
        XCTAssertEqual(resolved.workspaceID, target.id)
        XCTAssertEqual(resolved.tabID, contextID)
        XCTAssertEqual(resolved.repoPaths, target.repoPaths)
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    @MainActor
    func testContextIDBindDeterministicFallbackExcludesInactiveWorkspaceMatch() async throws {
        let contextID = UUID()
        let root = "/tmp/repoprompt-bind-target"
        let inactiveDuplicate = workspace(name: "Stored Target", root: root, contextID: contextID)
        let firstTarget = workspace(name: "First Active Target", root: root, contextID: contextID)
        let secondTarget = workspace(name: "Second Active Target", root: root, contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [inactiveDuplicate])
        let firstTargetWindow = try await makeWindow(activeWorkspace: firstTarget)
        let secondTargetWindow = try await makeWindow(activeWorkspace: secondTarget)
        let service = installWindows([staleWindow, firstTargetWindow, secondTargetWindow])
        let expectedWindow = try XCTUnwrap(
            [firstTargetWindow, secondTargetWindow].min { $0.windowID < $1.windowID }
        )
        let expectedWorkspace = expectedWindow.windowID == firstTargetWindow.windowID ? firstTarget : secondTarget

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: nil
        )

        XCTAssertEqual(resolved.windowID, expectedWindow.windowID)
        XCTAssertEqual(resolved.workspaceID, expectedWorkspace.id)
        XCTAssertEqual(resolved.tabID, contextID)
        XCTAssertEqual(resolved.repoPaths, expectedWorkspace.repoPaths)
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    @MainActor
    func testContextIDBindOnlyInactiveMatchFailsClosed() async throws {
        let contextID = UUID()
        let target = workspace(name: "Target", root: "/tmp/repoprompt-bind-target", contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let service = installWindows([staleWindow])

        XCTAssertThrowsError(try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("No open RepoPrompt window actively shows context_id"), message)
        }
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    func testBindContextWindowIDAcceptsOnlyExactIntegersAndKeepsSelectorCombinations() throws {
        XCTAssertNil(try WindowRoutingService.parseBindContextRequest(["op": .string("list")]).windowID)
        XCTAssertEqual(
            try WindowRoutingService.parseBindContextRequest(["op": .string("list"), "window_id": .int(7)]).windowID,
            7
        )
        XCTAssertEqual(
            try WindowRoutingService.parseBindContextRequest(["op": .string("list"), "window_id": .double(7)]).windowID,
            7
        )

        // Each of these used to read as an absent window_id, broadening a filtered list.
        let malformed: [Value] = [
            .null, .bool(true), .string("7"), .double(7.5), .double(.infinity), .double(.nan), .double(1e19),
            .array([.int(7)]), .object(["id": .int(7)])
        ]
        for op in ["list", "status", "bind"] {
            for value in malformed {
                XCTAssertThrowsError(
                    try WindowRoutingService.parseBindContextRequest(["op": .string(op), "window_id": value])
                ) { error in
                    XCTAssertTrue(
                        error.localizedDescription.contains("window_id must be a JSON integer"),
                        "\(op) \(value): \(error.localizedDescription)"
                    )
                }
            }
        }

        let windowOnly = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "window_id": .int(3)
        ])
        XCTAssertEqual(windowOnly.matchKind, .windowID)
        let workingDirsInWindow = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "working_dirs": .array([.string("/tmp/repoprompt-bind-root")]),
            "window_id": .int(3)
        ])
        XCTAssertEqual(workingDirsInWindow.matchKind, .workingDirs)
        XCTAssertEqual(workingDirsInWindow.windowID, 3)
        XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "context_id": .string(UUID().uuidString),
            "working_dirs": .string("/tmp/repoprompt-bind-root")
        ]))
        let statusWithBindFields = try WindowRoutingService.parseBindContextRequest([
            "op": .string("status"),
            "window_id": .int(3),
            "create_if_missing": .bool(true)
        ])
        XCTAssertEqual(statusWithBindFields.op, .status)
    }

    #if DEBUG
        @MainActor
        func testWindowFilteredListReturnsEveryComposeTabWithoutSideEffects() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let activeID = UUID()
            let boundID = UUID()
            let idleIDs = [UUID(), UUID()]
            let discovery = WorkspaceModel(
                name: "Discovery",
                repoPaths: [roots[0].path],
                composeTabs: [
                    ComposeTabState(id: activeID, name: "Active"),
                    ComposeTabState(id: boundID, name: "Bound"),
                    ComposeTabState(id: idleIDs[0], name: "Idle One"),
                    ComposeTabState(id: idleIDs[1], name: "Idle Two")
                ],
                activeComposeTabID: activeID
            )
            let unrelated = workspace(name: "Unrelated", root: roots[1].path, contextID: UUID())
            let windows = try await makeRegisteredWindows(activeWorkspaces: [discovery, unrelated])
            let target = windows[0]
            let other = windows[1]
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            // Binding an inactive tab by its listed context_id is the discovery flow's last step.
            _ = try await bindContextResponse(connection, [
                "op": .string("bind"),
                "context_id": .string(boundID.uuidString)
            ])
            let bindingBefore = target.mcpServer.connectionBindingSnapshot(forConnection: connection.connectionID)
            XCTAssertEqual(bindingBefore.tabID, boundID)

            let unfiltered = try await bindContextResponse(connection, ["op": .string("list")])
            XCTAssertEqual(
                Set(unfiltered.windows?.map(\.windowID) ?? []),
                Set(windows.map(\.windowID))
            )

            let filtered = try await bindContextResponse(connection, [
                "op": .string("list"),
                "window_id": .int(target.windowID)
            ])
            XCTAssertEqual(filtered.windows?.map(\.windowID), [target.windowID])
            let tabs = try XCTUnwrap(filtered.windows?.first).tabs
            XCTAssertEqual(tabs.map(\.contextID), [activeID, boundID] + idleIDs)
            XCTAssertEqual(tabs.filter(\.isActive).map(\.contextID), [activeID])
            XCTAssertEqual(tabs.filter(\.isBound).map(\.contextID), [boundID])

            let formatted = await callBindContext(connection, [
                "op": .string("list"),
                "window_id": .int(target.windowID)
            ])
            XCTAssertFalse(formatted.isError, formatted.text)
            for contextID in [activeID, boundID] + idleIDs {
                XCTAssertTrue(formatted.text.contains(contextID.uuidString), formatted.text)
            }

            let unknownWindowID = (windows.map(\.windowID).max() ?? 0) + 1000
            let unknown = await callBindContext(connection, [
                "op": .string("list"),
                "window_id": .int(unknownWindowID)
            ])
            XCTAssertTrue(unknown.isError, unknown.text)
            XCTAssertTrue(unknown.text.contains("Unknown window_id \(unknownWindowID)"), unknown.text)

            let malformed: [Value] = [.string(String(target.windowID)), .null, .bool(true), .double(1.5)]
            for value in malformed {
                let result = await callBindContext(connection, [
                    "op": .string("list"),
                    "window_id": value,
                    "_rawJSON": .bool(true)
                ])
                XCTAssertTrue(result.isError, "window_id \(value): \(result.text)")
                XCTAssertTrue(result.text.contains("window_id must be a JSON integer"), result.text)
            }

            let bindingAfter = target.mcpServer.connectionBindingSnapshot(forConnection: connection.connectionID)
            XCTAssertEqual(bindingAfter.windowID, bindingBefore.windowID)
            XCTAssertEqual(bindingAfter.workspaceID, bindingBefore.workspaceID)
            XCTAssertEqual(bindingAfter.tabID, bindingBefore.tabID)
            XCTAssertTrue(bindingAfter.explicitlyBound)
            XCTAssertEqual(target.workspaceManager.activeWorkspaceID, discovery.id)
            XCTAssertEqual(target.workspaceManager.activeWorkspace?.activeComposeTabID, activeID)
            XCTAssertEqual(other.workspaceManager.activeWorkspaceID, unrelated.id)
        }

        @MainActor
        func testWindowBindCapturesActiveTabOnceAndWindowSelectsContextIDMatch() async throws {
            let roots = try makeTemporaryRoots(count: 3)
            let sharedContextID = UUID()
            let boundPrompt = "bound-workspace-prompt-\(UUID().uuidString)"
            let visiblePrompt = "replacement-workspace-prompt-\(UUID().uuidString)"
            let first = workspace(
                name: "First",
                root: roots[0].path,
                contextID: sharedContextID,
                promptText: boundPrompt
            )
            let second = workspace(name: "Second", root: roots[1].path, contextID: sharedContextID)
            let replacement = workspace(
                name: "Replacement",
                root: roots[2].path,
                contextID: UUID(),
                promptText: visiblePrompt
            )
            let windows = try await makeRegisteredWindows(activeWorkspaces: [first, second])
            let lower = windows[0]
            let higher = windows[1]
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            // Both windows show the context; without window_id the lowest window would win.
            let disambiguated = try await bindContextResponse(connection, [
                "op": .string("bind"),
                "context_id": .string(sharedContextID.uuidString),
                "window_id": .int(higher.windowID)
            ])
            XCTAssertEqual(disambiguated.binding.windowID, higher.windowID)
            XCTAssertEqual(disambiguated.binding.workspaceID, second.id)
            XCTAssertEqual(disambiguated.binding.contextID, sharedContextID)

            let captured = try await bindContextResponse(connection, [
                "op": .string("bind"),
                "window_id": .int(lower.windowID)
            ])
            XCTAssertEqual(captured.binding.windowID, lower.windowID)
            XCTAssertEqual(captured.binding.workspaceID, first.id)
            XCTAssertEqual(captured.binding.contextID, sharedContextID)
            XCTAssertTrue(captured.binding.explicit)

            // The fixture activates workspaces without loading the editor. Mirror the app, where the
            // editor shows the active tab's prompt, so leaving the bound tab snapshots it unchanged.
            lower.promptManager.promptText = boundPrompt
            try await configureWindow(lower, activeWorkspace: replacement, savedWorkspaces: [first])
            XCTAssertEqual(lower.workspaceManager.activeWorkspaceID, replacement.id)
            let status = try await bindContextResponse(connection, ["op": .string("status")])
            XCTAssertEqual(status.binding.windowID, lower.windowID)
            XCTAssertEqual(status.binding.workspaceID, first.id)
            XCTAssertEqual(status.binding.contextID, sharedContextID)
            let stickyRead = await readPromptThroughBinding(connection)
            XCTAssertFalse(stickyRead.isError, stickyRead.text)
            XCTAssertTrue(stickyRead.text.contains(boundPrompt), stickyRead.text)
            XCTAssertFalse(stickyRead.text.contains(visiblePrompt), stickyRead.text)

            // window_id restricts the context_id match instead of being ignored.
            let mismatch = await callBindContext(connection, [
                "op": .string("bind"),
                "context_id": .string(sharedContextID.uuidString),
                "window_id": .int(lower.windowID)
            ])
            XCTAssertTrue(mismatch.isError, mismatch.text)
            XCTAssertTrue(mismatch.text.contains("does not actively show context_id"), mismatch.text)
        }

        @MainActor
        func testWindowBindKeepsCapturedTabWhenVisibleTabChangesInSameWorkspace() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let boundTabID = UUID()
            let visibleTabID = UUID()
            let boundPrompt = "bound-tab-prompt-\(UUID().uuidString)"
            let visiblePrompt = "visible-tab-prompt-\(UUID().uuidString)"
            let tabs = WorkspaceModel(
                name: "Tabs",
                repoPaths: [roots[0].path],
                composeTabs: [
                    ComposeTabState(id: boundTabID, name: "Bound", promptText: boundPrompt),
                    ComposeTabState(id: visibleTabID, name: "Visible", promptText: visiblePrompt)
                ],
                activeComposeTabID: boundTabID
            )
            let unrelated = workspace(name: "Unrelated", root: roots[1].path, contextID: UUID())
            let windows = try await makeRegisteredWindows(activeWorkspaces: [tabs, unrelated])
            let target = windows[0]
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let captured = try await bindContextResponse(connection, [
                "op": .string("bind"),
                "window_id": .int(target.windowID)
            ])
            XCTAssertEqual(captured.binding.contextID, boundTabID)

            // Mirror the app, where the editor shows the active tab's prompt, so the switch below
            // snapshots the bound tab unchanged.
            target.promptManager.promptText = boundPrompt
            await target.promptManager.switchComposeTab(visibleTabID)
            XCTAssertEqual(target.workspaceManager.activeWorkspace?.activeComposeTabID, visibleTabID)
            XCTAssertEqual(target.promptManager.promptText, visiblePrompt)

            let stickyRead = await readPromptThroughBinding(connection)
            XCTAssertFalse(stickyRead.isError, stickyRead.text)
            XCTAssertTrue(stickyRead.text.contains(boundPrompt), stickyRead.text)
            XCTAssertFalse(stickyRead.text.contains(visiblePrompt), stickyRead.text)
            let status = try await bindContextResponse(connection, ["op": .string("status")])
            XCTAssertEqual(status.binding.contextID, boundTabID)
        }

        /// A window route names a window, not a tab: `_windowID` with no `context_id` is what a
        /// client that only selected a window sends on every call. `prompt` and `manage_selection`
        /// reach tab resolution by different routes.
        @MainActor
        func testWindowRoutedCallOnBoundConnectionUsesBoundTabNotVisibleTab() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let boundTabID = UUID()
            let visibleTabID = UUID()
            let boundPrompt = "bound-tab-prompt-\(UUID().uuidString)"
            let visiblePrompt = "visible-tab-prompt-\(UUID().uuidString)"
            let boundFile = roots[0].appendingPathComponent("BoundSelection.swift")
            let visibleFile = roots[0].appendingPathComponent("VisibleSelection.swift")
            try "struct BoundSelection {}\n".write(to: boundFile, atomically: true, encoding: .utf8)
            try "struct VisibleSelection {}\n".write(to: visibleFile, atomically: true, encoding: .utf8)
            let tabs = WorkspaceModel(
                name: "Tabs",
                repoPaths: [roots[0].path],
                composeTabs: [
                    ComposeTabState(
                        id: boundTabID,
                        name: "Bound",
                        selection: StoredSelection(selectedPaths: [boundFile.path]),
                        promptText: boundPrompt
                    ),
                    ComposeTabState(
                        id: visibleTabID,
                        name: "Visible",
                        selection: StoredSelection(selectedPaths: [visibleFile.path]),
                        promptText: visiblePrompt
                    )
                ],
                activeComposeTabID: visibleTabID
            )
            let unrelated = workspace(name: "Unrelated", root: roots[1].path, contextID: UUID())
            let windows = try await makeRegisteredWindows(activeWorkspaces: [tabs, unrelated])
            let target = windows[0]
            // Mirror the app, where the editor shows the active tab's prompt.
            target.promptManager.promptText = visiblePrompt
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            func windowRouted(
                _ toolName: String,
                contextID: UUID? = nil
            ) async -> (text: String, isError: Bool) {
                var arguments: [String: Value] = [
                    "op": .string("get"),
                    "_windowID": .int(target.windowID),
                    "_rawJSON": .bool(true)
                ]
                if let contextID {
                    arguments["context_id"] = .string(contextID.uuidString)
                }
                if toolName == "manage_selection" {
                    arguments["view"] = .string("files")
                }
                return await callTool(connection, name: toolName, arguments: arguments)
            }

            let boundTab = (prompt: boundPrompt, selectedFile: boundFile.lastPathComponent)
            let visibleTab = (prompt: visiblePrompt, selectedFile: visibleFile.lastPathComponent)
            func assertWindowRouteUses(
                _ used: (prompt: String, selectedFile: String),
                not other: (prompt: String, selectedFile: String),
                line: UInt = #line
            ) async {
                let read = await windowRouted("prompt")
                XCTAssertFalse(read.isError, read.text, line: line)
                XCTAssertTrue(read.text.contains(used.prompt), read.text, line: line)
                XCTAssertFalse(read.text.contains(other.prompt), read.text, line: line)
                let selection = await windowRouted("manage_selection")
                XCTAssertFalse(selection.isError, selection.text, line: line)
                XCTAssertTrue(selection.text.contains(used.selectedFile), selection.text, line: line)
                XCTAssertFalse(selection.text.contains(other.selectedFile), selection.text, line: line)
            }

            await assertWindowRouteUses(visibleTab, not: boundTab)

            let bound = try await bindContextResponse(connection, [
                "op": .string("bind"),
                "context_id": .string(boundTabID.uuidString)
            ])
            XCTAssertEqual(bound.binding.contextID, boundTabID)
            XCTAssertTrue(bound.binding.explicit)
            XCTAssertEqual(target.workspaceManager.activeWorkspace?.activeComposeTabID, visibleTabID)

            await assertWindowRouteUses(boundTab, not: visibleTab)

            for toolName in ["prompt", "manage_selection"] {
                let visibleTabByContextID = await windowRouted(toolName, contextID: visibleTabID)
                XCTAssertTrue(visibleTabByContextID.isError, visibleTabByContextID.text)
                XCTAssertTrue(
                    visibleTabByContextID.text.contains("conflicts with this connection's authoritative"),
                    visibleTabByContextID.text
                )
            }

            let status = try await bindContextResponse(connection, ["op": .string("status")])
            XCTAssertEqual(status.binding.contextID, boundTabID)

            // A run's tab binding is authoritative without being explicit, so it replaces the
            // explicit binding here and has to keep its tab on its own.
            try target.mcpServer.bindTabForConnection(
                connectionID: connection.connectionID,
                clientName: nil,
                tabID: boundTabID,
                workspaceID: tabs.id,
                windowID: target.windowID,
                runID: UUID(),
                explicitlyBound: false
            )
            let runScoped = target.mcpServer.connectionBindingSnapshot(forConnection: connection.connectionID)
            XCTAssertFalse(runScoped.explicitlyBound)
            XCTAssertNotNil(runScoped.runID)
            XCTAssertEqual(runScoped.tabID, boundTabID)
            await assertWindowRouteUses(boundTab, not: visibleTab)
        }
    #endif

    #if DEBUG
        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }

        private func callTool(
            _ connection: ProductionMCPConnection,
            name: String,
            arguments: [String: Value]
        ) async -> (text: String, isError: Bool) {
            do {
                let result = try await connection.client.callTool(name: name, arguments: arguments)
                return (toolText(result), result.isError == true)
            } catch {
                return (error.localizedDescription, true)
            }
        }

        private func callBindContext(
            _ connection: ProductionMCPConnection,
            _ arguments: [String: Value]
        ) async -> (text: String, isError: Bool) {
            await callTool(connection, name: "bind_context", arguments: arguments)
        }

        /// Reads the prompt with no window_id, context_id, or _windowID, so only the connection's
        /// binding can route the call.
        private func readPromptThroughBinding(
            _ connection: ProductionMCPConnection
        ) async -> (text: String, isError: Bool) {
            await callTool(connection, name: "prompt", arguments: [
                "op": .string("get"),
                "_rawJSON": .bool(true)
            ])
        }

        private func bindContextResponse(
            _ connection: ProductionMCPConnection,
            _ arguments: [String: Value]
        ) async throws -> BindContextResponse {
            var rawArguments = arguments
            rawArguments["_rawJSON"] = .bool(true)
            let result = await callBindContext(connection, rawArguments)
            XCTAssertFalse(result.isError, result.text)
            return try JSONDecoder().decode(BindContextResponse.self, from: Data(result.text.utf8))
        }

        @MainActor
        private func makeRegisteredWindows(activeWorkspaces: [WorkspaceModel]) async throws -> [WindowState] {
            let windows = activeWorkspaces.map { _ in makeWindowInstance() }.sorted { $0.windowID < $1.windowID }
            for (window, workspace) in zip(windows, activeWorkspaces) {
                try await configureWindow(window, activeWorkspace: workspace)
            }
            _ = installWindows(windows)
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            for window in windows {
                let enabled = await window.mcpServer.setWindowToolsEnabled(true)
                XCTAssertTrue(enabled)
            }
            addTeardownBlock { @MainActor in
                for window in windows {
                    _ = await window.mcpServer.setWindowToolsEnabled(false)
                }
            }
            return windows
        }

        private func makeTemporaryRoots(count: Int) throws -> [URL] {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-bind-discovery-\(UUID().uuidString)", isDirectory: true)
            let roots = (0 ..< count).map { base.appendingPathComponent("root\($0)", isDirectory: true) }
            for root in roots {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            addTeardownBlock {
                try? FileManager.default.removeItem(at: base)
            }
            return roots
        }
    #endif

    @MainActor
    private func makeWindowInstance() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowState()
    }

    @MainActor
    private func configureWindow(
        _ window: WindowState,
        activeWorkspace: WorkspaceModel,
        savedWorkspaces: [WorkspaceModel] = []
    ) async throws {
        await window.workspaceManager.awaitInitialized()
        window.workspaceManager.workspaces = [activeWorkspace] + savedWorkspaces
        _ = await window.workspaceManager.switchWorkspace(
            to: activeWorkspace,
            saveState: false,
            reason: "bindContextRoutingAuthorityTest"
        )
        guard window.workspaceManager.activeWorkspaceID == activeWorkspace.id else {
            throw BindContextRoutingFixtureError.workspaceActivationFailed
        }
    }

    #if DEBUG
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
            let sessionToken = "bind-routing-\(UUID().uuidString)"
            let clientName = "BindContextRoutingAuthorityTests"
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
    #endif

    private func workspace(name: String, root: String, contextID: UUID, promptText: String = "") -> WorkspaceModel {
        WorkspaceModel(
            name: name,
            repoPaths: [root],
            composeTabs: [ComposeTabState(id: contextID, name: "Context", promptText: promptText)],
            activeComposeTabID: contextID
        )
    }

    @MainActor
    private func makeWindow(
        activeWorkspace: WorkspaceModel,
        savedWorkspaces: [WorkspaceModel] = []
    ) async throws -> WindowState {
        let window = makeWindowInstance()
        try await configureWindow(
            window,
            activeWorkspace: activeWorkspace,
            savedWorkspaces: savedWorkspaces
        )
        return window
    }

    @MainActor
    private func installWindows(_ windows: [WindowState]) -> WindowRoutingService {
        let previousWindows = WindowStatesManager.shared.allWindows
        WindowStatesManager.shared.allWindows = windows
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.allWindows = previousWindows
        }
        return WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
    }
}

#if DEBUG
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

private enum BindContextRoutingFixtureError: Error {
    case workspaceActivationFailed
}
