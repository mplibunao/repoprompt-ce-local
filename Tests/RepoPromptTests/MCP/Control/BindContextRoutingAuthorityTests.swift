import Combine
import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
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
            let windows = try await makeRuntimeBackedWindows(
                catalog: [unrelated, staleMatch, activeTarget, replacementActive],
                showing: [unrelated, activeTarget]
            ).windows
            let staleWindow = windows[0]
            let targetWindow = windows[1]

            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            try await bindContext(connection, contextID: contextID)

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

            try await show(replacementActive.id, in: targetWindow)

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

        @MainActor
        func testStickyBindingEditsUnshownWorkspaceWithoutChangingShownTab() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let boundFile = try makeFile(named: "bound.swift", in: roots[0])
            let shownFile = try makeFile(named: "shown.swift", in: roots[1])
            let boundTab = ComposeTabState(
                name: "Bound",
                selection: StoredSelection(selectedPaths: [boundFile.path]),
                promptText: "Bound prompt"
            )
            let bound = WorkspaceModel(
                name: "Bound Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [boundTab],
                activeComposeTabID: boundTab.id
            )
            let shownSelection = StoredSelection(selectedPaths: [shownFile.path])
            let shownTab = ComposeTabState(name: "Shown", selection: shownSelection, promptText: "Shown prompt")
            let shown = WorkspaceModel(
                name: "Shown Workspace",
                repoPaths: [roots[1].path],
                composeTabs: [shownTab],
                activeComposeTabID: shownTab.id
            )
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [bound, shown], showing: [bound])
            let window = windows[0]
            let connectionID = UUID()
            let clientName = "BindContextRoutingAuthorityTests"
            try await window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: boundTab.id,
                workspaceID: bound.id,
                windowID: window.windowID
            )
            try await show(shown.id, in: window)
            let uiSelectionBefore = window.workspaceFilesViewModel.snapshotSelection()

            // The calls pass no window, tab, or context hint, so only the binding routes them.
            window.mcpServer.setRequestMetadataOverrideForTesting(MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: clientName,
                windowID: window.windowID
            ))
            addTeardownBlock { @MainActor in
                window.mcpServer.setRequestMetadataOverrideForTesting(nil)
            }
            let tools = await window.mcpServer.windowMCPToolCatalogService.tools
            let promptTool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.prompt })
            let selectionTool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.manageSelection })
            _ = try await promptTool(["op": .string("set"), "text": .string("Sticky edit")])
            _ = try await selectionTool(["op": .string("clear")])

            let storedBoundTab = try await canonicalTab(boundTab.id, of: bound.id, in: runtime)
            XCTAssertEqual(storedBoundTab.promptText, "Sticky edit")
            XCTAssertEqual(storedBoundTab.selection, StoredSelection())
            let binding = window.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
            XCTAssertEqual(binding.workspaceID, bound.id)
            XCTAssertEqual(binding.tabID, boundTab.id)

            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, shown.id)
            XCTAssertEqual(window.promptManager.activeComposeTabID, shownTab.id)
            XCTAssertEqual(window.promptManager.promptText, "Shown prompt")
            let storedShownTab = try XCTUnwrap(
                window.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == shownTab.id }
            )
            XCTAssertEqual(storedShownTab.promptText, "Shown prompt")
            XCTAssertEqual(storedShownTab.selection, shownSelection)
            XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection(), uiSelectionBefore)
        }

        @MainActor
        func testOffscreenContextCommitPreservesNewerSelection() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let fileC = try makeFile(named: "C.swift", in: roots[0])
            let shownFile = try makeFile(named: "shown.swift", in: roots[1])
            let targetTab = ComposeTabState(
                name: "Target",
                selection: StoredSelection(selectedPaths: [fileA.path]),
                promptText: "Before the run"
            )
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let shownSelection = StoredSelection(selectedPaths: [shownFile.path])
            let shownTab = ComposeTabState(name: "Shown", selection: shownSelection, promptText: "Shown prompt")
            let shown = WorkspaceModel(
                name: "Shown Workspace",
                repoPaths: [roots[1].path],
                composeTabs: [shownTab],
                activeComposeTabID: shownTab.id
            )
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [target, shown], showing: [target])
            let window = windows[0]
            let manager = window.workspaceManager
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            let connectionID = UUID()
            let runID = UUID()
            // The run's final context, captured while the window showed the target. The run changed
            // the tab's selection, A, to B without storing it yet.
            window.mcpServer.tabContextByConnectionID[connectionID] = MCPServerViewModel.TabContextSnapshot(
                tabID: targetTab.id,
                windowID: window.windowID,
                workspaceID: target.id,
                promptText: "Context Builder prompt",
                selection: StoredSelection(selectedPaths: [fileB.path]),
                selectionRevision: manager.selectionRevisionForMCP(workspaceID: target.id, tabID: targetTab.id),
                storedSelectionAtRevision: targetTab.selection,
                selectedMetaPromptIDs: [],
                selectedContextBuilderPromptIDs: [],
                tabName: targetTab.name,
                runID: runID,
                explicitlyBound: false
            )
            try await show(shown.id, in: window)
            let uiSelectionBefore = window.workspaceFilesViewModel.snapshotSelection()

            // A newer selection lands while the commit's load of the tab is paused.
            let newerSelection = StoredSelection(selectedPaths: [fileC.path])
            var heldCommitLoads = 0
            manager.contentGateway.canonicalReadWillBeginHandlerForTesting = { workspaceID, source in
                guard workspaceID == target.id, source == "mcp.commitTabContext" else { return }
                heldCommitLoads += 1
                _ = await window.selectionCoordinator.persistSelection(
                    newerSelection,
                    for: identity,
                    mirrorToUIIfActive: false
                )
            }
            addTeardownBlock { @MainActor in
                manager.contentGateway.canonicalReadWillBeginHandlerForTesting = nil
            }
            let completion = await window.mcpServer.commitContextBuilderTabContext(
                connectionID: connectionID,
                expectedRunID: runID,
                authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
            )

            XCTAssertEqual(heldCommitLoads, 1)
            XCTAssertEqual(completion.outcome, .committed)
            let storedTargetTab = try await canonicalTab(targetTab.id, of: target.id, in: runtime)
            XCTAssertEqual(storedTargetTab.promptText, "Context Builder prompt")
            XCTAssertEqual(storedTargetTab.selection, newerSelection)
            XCTAssertEqual(completion.committedTab?.tab.selection, newerSelection)

            XCTAssertEqual(manager.activeWorkspaceID, shown.id)
            XCTAssertEqual(window.promptManager.activeComposeTabID, shownTab.id)
            XCTAssertEqual(window.promptManager.promptText, "Shown prompt")
            let storedShownTab = try XCTUnwrap(manager.activeWorkspace?.composeTabs.first { $0.id == shownTab.id })
            XCTAssertEqual(storedShownTab.promptText, "Shown prompt")
            XCTAssertEqual(storedShownTab.selection, shownSelection)
            XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection(), uiSelectionBefore)
        }

        @MainActor
        func testOffscreenContextCommitPreservesSelectionFromAnotherWindow() async throws {
            for row in ForeignSelectionRow.allCases {
                try await assertRunCommitPreservesForeignSelection(row)
            }
        }

        /// How the run window and another window change the run's tab before the run, started on that
        /// tab from a window that doesn't show it, commits. The other window's change is the newest
        /// in every row, so the commit has to keep it.
        private enum ForeignSelectionRow: String, CaseIterable {
            /// The run window's own write is projected, then the other window writes.
            case ownWriteThenForeignWrite
            /// The run window changes the selection and back within one publish and switches away,
            /// then the other window writes the run window's intermediate value.
            case toggleWithinOnePublishThenForeignWriteOfToggledValue
        }

        @MainActor
        private func assertRunCommitPreservesForeignSelection(_ row: ForeignSelectionRow) async throws {
            let message = row.rawValue
            let roots = try makeTemporaryRoots(count: 3)
            let selections = try ["A", "B", "C"].map { name in
                try StoredSelection(selectedPaths: [makeFile(named: "\(name).swift", in: roots[0]).path])
            }
            let targetTab = ComposeTabState(name: "Target", selection: selections[0], promptText: "Before the run")
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let otherShown = WorkspaceModel(name: "Other Shown", repoPaths: [roots[1].path])
            let parking = WorkspaceModel(name: "Parking", repoPaths: [roots[2].path])
            let runWindowStartsOnTarget = row == .toggleWithinOnePublishThenForeignWriteOfToggledValue
            let (windows, runtime) = try await makeRuntimeBackedWindows(
                catalog: [target, otherShown, parking],
                showing: [otherShown, runWindowStartsOnTarget ? target : parking]
            )
            let otherWindow = windows[0]
            let runWindow = windows[1]
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            func runRevision() -> UInt64 {
                runWindow.workspaceManager.selectionRevisionForMCP(workspaceID: target.id, tabID: targetTab.id)
            }
            func write(_ selection: StoredSelection, from window: WindowState) async {
                _ = await window.selectionCoordinator.persistSelection(
                    selection,
                    for: identity,
                    mirrorToUIIfActive: false
                )
            }

            let contextSelection: StoredSelection
            let foreignSelection: StoredSelection
            switch row {
            case .ownWriteThenForeignWrite:
                await write(selections[1], from: runWindow)
                let ownRevision = runRevision()
                await waitForSummaryProjection(of: windows, runtime: runtime)
                XCTAssertEqual(runRevision(), ownRevision, message)
                contextSelection = selections[1]
                foreignSelection = selections[2]
            case .toggleWithinOnePublishThenForeignWriteOfToggledValue:
                // The two stores run in one main-actor turn, so no publish includes the first one.
                XCTAssertTrue(runWindow.workspaceManager.storeShownTabSelection(selections[1], for: identity), message)
                XCTAssertTrue(runWindow.workspaceManager.storeShownTabSelection(selections[0], for: identity), message)
                try await show(parking.id, in: runWindow)
                await waitForSummaryProjection(of: windows, runtime: runtime)
                contextSelection = selections[0]
                foreignSelection = selections[1]
            }

            let connectionID = UUID()
            let runID = UUID()
            runWindow.mcpServer.tabContextByConnectionID[connectionID] = MCPServerViewModel.TabContextSnapshot(
                tabID: targetTab.id,
                windowID: runWindow.windowID,
                workspaceID: target.id,
                promptText: "Context Builder prompt",
                selection: contextSelection,
                selectionRevision: runRevision(),
                selectedMetaPromptIDs: [],
                selectedContextBuilderPromptIDs: [],
                tabName: targetTab.name,
                runID: runID,
                explicitlyBound: false
            )

            // The other window makes the newest change before the run completes.
            await write(foreignSelection, from: otherWindow)
            await waitForSummaryProjection(of: [runWindow], runtime: runtime)
            let storedBeforeCommit = try await canonicalTab(targetTab.id, of: target.id, in: runtime)
            XCTAssertEqual(storedBeforeCommit.selection, foreignSelection, message)

            let completion = await runWindow.mcpServer.commitContextBuilderTabContext(
                connectionID: connectionID,
                expectedRunID: runID,
                authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
            )

            XCTAssertEqual(completion.outcome, .committed, message)
            let storedTargetTab = try await canonicalTab(targetTab.id, of: target.id, in: runtime)
            XCTAssertEqual(storedTargetTab.promptText, "Context Builder prompt", message)
            XCTAssertEqual(storedTargetTab.selection, foreignSelection, message)
        }

        @MainActor
        func testOffscreenContextCommitKeepsASelectionTheWindowHasNotProjected() async throws {
            let roots = try makeTemporaryRoots(count: 3)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let fileC = try makeFile(named: "C.swift", in: roots[0])
            let targetTab = ComposeTabState(
                name: "Target",
                selection: StoredSelection(selectedPaths: [fileA.path]),
                promptText: "Before the run"
            )
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let otherShown = WorkspaceModel(name: "Other Shown", repoPaths: [roots[1].path])
            let parking = WorkspaceModel(name: "Parking", repoPaths: [roots[2].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(
                catalog: [target, otherShown, parking],
                showing: [otherShown, parking]
            )
            let otherWindow = windows[0]
            let runWindow = windows[1]
            addTeardownBlock { @MainActor in
                runWindow.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting(nil)
                runWindow.workspaceManager.contentGateway.commitSubmissionWillBeginHandlerForTesting = nil
            }
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            func runRevision() -> UInt64 {
                runWindow.workspaceManager.selectionRevisionForMCP(workspaceID: target.id, tabID: targetTab.id)
            }
            let connectionID = UUID()
            let runID = UUID()
            let contextRevision = runRevision()
            // The run changed the tab's selection, A, to B without storing it yet.
            runWindow.mcpServer.tabContextByConnectionID[connectionID] = MCPServerViewModel.TabContextSnapshot(
                tabID: targetTab.id,
                windowID: runWindow.windowID,
                workspaceID: target.id,
                promptText: "Context Builder prompt",
                selection: StoredSelection(selectedPaths: [fileB.path]),
                selectionRevision: contextRevision,
                storedSelectionAtRevision: targetTab.selection,
                selectedMetaPromptIDs: [],
                selectedContextBuilderPromptIDs: [],
                tabName: targetTab.name,
                runID: runID,
                explicitlyBound: false
            )
            await waitForSummaryProjection(of: [runWindow], runtime: runtime)

            // The run reads and edits the tab before the run window projects the other window's
            // commit of C, so the run window's revision counter doesn't show C.
            let submitted = ArrivalGate()
            var commit: Task<MCPServerViewModel.ContextBuilderTabContextCommitResult, Never>?
            var revisionWhenSubmitting: UInt64?
            runWindow.workspaceManager.contentGateway.commitSubmissionWillBeginHandlerForTesting = { workspaceID in
                guard workspaceID == target.id, revisionWhenSubmitting == nil else { return }
                revisionWhenSubmitting = runRevision()
                await submitted.arriveAndWaitForRelease()
            }
            runWindow.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting { event in
                guard event.workspaceID == target.id, commit == nil else { return }
                commit = Task { @MainActor in
                    await runWindow.mcpServer.commitContextBuilderTabContext(
                        connectionID: connectionID,
                        expectedRunID: runID,
                        authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
                    )
                }
                await submitted.waitForArrival()
                await submitted.release()
            }
            let foreignSelection = StoredSelection(selectedPaths: [fileC.path])
            _ = await otherWindow.selectionCoordinator.persistSelection(
                foreignSelection,
                for: identity,
                mirrorToUIIfActive: false
            )
            await submitted.waitForArrival()
            let commitTask = try XCTUnwrap(commit)
            let result = await commitTask.value
            runWindow.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting(nil)

            XCTAssertEqual(revisionWhenSubmitting, contextRevision)
            XCTAssertEqual(result.outcome, .committed)
            let storedTargetTab = try await canonicalTab(targetTab.id, of: target.id, in: runtime)
            XCTAssertEqual(storedTargetTab.selection, foreignSelection)
            XCTAssertEqual(storedTargetTab.promptText, "Context Builder prompt")
        }

        @MainActor
        func testScreenEndsOnTheLatestEditToAWorkspaceShownDuringACanonicalSubmission() async throws {
            for row in ShownDuringSubmissionRow.allCases {
                try await assertScreenEndsOnTheLatestEdit(row)
            }
        }

        /// What a canonical write to the tab changes. The window starts showing the tab's workspace
        /// after the write read the canonical document and before the gateway submits it.
        private enum ShownDuringSubmissionRow: String, CaseIterable {
            /// The write changes the prompt, which the prompt editor shows.
            case promptWrite
            /// The write changes the selection, which the file tree shows. A prompt typed into the
            /// shown tab before the submission stays in the editor.
            case selectionWrite
            /// An MCP selection commit changes the selection, and peer propagation presents it.
            /// After the authority accepts the commit and before the window installs it, an MCP
            /// store into the now shown tab sets a later selection, which the file tree keeps.
            case mcpSelectionCommitBeforeALaterShownStore
        }

        @MainActor
        private func assertScreenEndsOnTheLatestEdit(_ row: ShownDuringSubmissionRow) async throws {
            let message = row.rawValue
            let roots = try makeTemporaryRoots(count: 2)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let fileC = try makeFile(named: "C.swift", in: roots[0])
            let targetTab = ComposeTabState(
                name: "Target",
                selection: StoredSelection(selectedPaths: [fileA.path]),
                promptText: "Before the write"
            )
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let shown = WorkspaceModel(name: "Shown Workspace", repoPaths: [roots[1].path])
            let (windows, _) = try await makeRuntimeBackedWindows(catalog: [target, shown], showing: [shown])
            let window = windows[0]
            let manager = window.workspaceManager
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            let writtenSelection = StoredSelection(selectedPaths: [fileB.path])
            let laterSelection = StoredSelection(selectedPaths: [fileC.path])
            addTeardownBlock { @MainActor in
                manager.contentGateway.commitSubmissionWillBeginHandlerForTesting = nil
                manager.contentGateway.commitResultWillReturnHandlerForTesting = nil
                window.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting(nil)
            }
            manager.contentGateway.commitSubmissionWillBeginHandlerForTesting = { workspaceID in
                guard workspaceID == target.id else { return }
                manager.contentGateway.commitSubmissionWillBeginHandlerForTesting = nil
                try? await self.show(target.id, in: window)
                // A capture between the write's install and its presentation would put the copy back
                // on what the switch showed.
                await self.settleQueuedCaptures(in: window)
                if row == .selectionWrite {
                    manager.promptViewModel.promptText = "Typed after the switch"
                    // Typing queues another capture, which runs here instead.
                    await self.settleQueuedCaptures(in: window)
                }
            }

            switch row {
            case .promptWrite, .selectionWrite:
                _ = try await manager.contentGateway.mutateComposeTab(
                    identity,
                    source: "test.write",
                    persistence: .working
                ) { tab in
                    if row == .promptWrite {
                        tab.promptText = "Written prompt"
                    } else {
                        tab.selection = writtenSelection
                    }
                }
            case .mcpSelectionCommitBeforeALaterShownStore:
                // Both hooks run on the main actor, and the answer hook resumes the event hook
                // without suspending. The commit's answer then registers the commit before the
                // event hook makes the later store, and the bridge installs the commit after it.
                var answerReturned = false
                var eventWaiter: CheckedContinuation<Void, Never>?
                var heldEvent = false
                manager.contentGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id else { return }
                    manager.contentGateway.commitResultWillReturnHandlerForTesting = nil
                    answerReturned = true
                    eventWaiter?.resume()
                    eventWaiter = nil
                }
                window.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting { event in
                    guard event.workspaceID == target.id, !heldEvent else { return }
                    heldEvent = true
                    if !answerReturned {
                        await withCheckedContinuation { eventWaiter = $0 }
                    }
                    _ = await window.selectionCoordinator.persistSelection(
                        laterSelection,
                        for: identity,
                        source: .mcpTabContext,
                        mirrorToUIIfActive: true
                    )
                }
                _ = await window.selectionCoordinator.persistSelection(
                    writtenSelection,
                    for: identity,
                    source: .mcpTabContext,
                    mirrorToUIIfActive: true
                )
                XCTAssertTrue(heldEvent, message)
            }

            XCTAssertEqual(manager.activeWorkspaceID, target.id, message)
            let expectedPrompt = switch row {
            case .promptWrite: "Written prompt"
            case .selectionWrite: "Typed after the switch"
            case .mcpSelectionCommitBeforeALaterShownStore: targetTab.promptText
            }
            let expectedPaths = switch row {
            case .promptWrite: targetTab.selection.selectedPaths
            case .selectionWrite: writtenSelection.selectedPaths
            case .mcpSelectionCommitBeforeALaterShownStore: laterSelection.selectedPaths
            }
            XCTAssertEqual(manager.promptViewModel.promptText, expectedPrompt, message)
            XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection().selectedPaths, expectedPaths, message)
            // A UI capture stores what the screen shows.
            manager.publishActiveComposeTabSnapshot()
            let stored = try XCTUnwrap(manager.contentGateway.shownComposeTab(identity), message)
            XCTAssertEqual(stored.promptText, expectedPrompt, message)
            XCTAssertEqual(stored.selection.selectedPaths, expectedPaths, message)
        }

        @MainActor
        func testOffscreenContextCommitReceiptCarriesOnlyTheRevisionItsOwnInstallGaveTheTab() async throws {
            for row in OffscreenReceiptRow.allCases {
                try await assertOffscreenContextCommitReceipt(row)
            }
        }

        /// What happens between the window's projection of an offscreen context commit and the
        /// commit's return.
        private enum OffscreenReceiptRow: String, CaseIterable {
            /// The window starts showing the tab and stores a later selection in its own copy.
            case laterStoreOnTheShownTab
            /// Another writer commits a different selection and then the run's selection again, and
            /// the window projects both. The tab ends on the run's selection at a later revision.
            case laterCanonicalCommitsRestoreTheSelection
        }

        @MainActor
        private func assertOffscreenContextCommitReceipt(_ row: OffscreenReceiptRow) async throws {
            let message = row.rawValue
            let roots = try makeTemporaryRoots(count: 2)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let fileC = try makeFile(named: "C.swift", in: roots[0])
            let targetTab = ComposeTabState(name: "Target", selection: StoredSelection(selectedPaths: [fileA.path]))
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let shown = WorkspaceModel(name: "Shown Workspace", repoPaths: [roots[1].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [target, shown], showing: [shown])
            let window = windows[0]
            let manager = window.workspaceManager
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            let connectionID = UUID()
            let runID = UUID()
            let runSelection = StoredSelection(selectedPaths: [fileB.path])
            window.mcpServer.tabContextByConnectionID[connectionID] = MCPServerViewModel.TabContextSnapshot(
                tabID: targetTab.id,
                windowID: window.windowID,
                workspaceID: target.id,
                promptText: "Context Builder prompt",
                selection: runSelection,
                selectionRevision: manager.selectionRevisionForMCP(workspaceID: target.id, tabID: targetTab.id),
                storedSelectionAtRevision: targetTab.selection,
                selectedMetaPromptIDs: [],
                selectedContextBuilderPromptIDs: [],
                tabName: targetTab.name,
                runID: runID,
                explicitlyBound: false
            )
            func revision() -> UInt64 {
                manager.selectionRevisionForMCP(workspaceID: target.id, tabID: targetTab.id)
            }

            let peer = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -7301)
            /// Commits `selection` to the target tab as another writer, and waits until the window
            /// projects it.
            func commitAsPeer(_ selection: StoredSelection) async throws {
                let snapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(target.id)
                let canonical = try XCTUnwrap(snapshot, message)
                var document = try JSONDecoder().decode(WorkspaceModel.self, from: canonical.document.documentBytes)
                let index = try XCTUnwrap(document.composeTabs.firstIndex { $0.id == targetTab.id }, message)
                document.composeTabs[index].selection = selection
                let outcome = try await peer.replaceWorking(
                    document,
                    fileURL: canonical.document.fileURL,
                    expectedWorkspaceRevision: canonical.revisions.workingRevision
                )
                XCTAssertEqual(outcome.disposition, .applied, message)
                let committed = try XCTUnwrap(outcome.after?.workingRevision, message)
                let projected = await manager.awaitProjectedInstall(of: target.id, atLeast: committed)
                XCTAssertNotNil(projected, message)
            }

            // The window projects the commit before its answer arrives, and the row's later writes
            // happen before the commit returns.
            var revisionAtProjection: UInt64?
            manager.contentGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                guard workspaceID == target.id, revisionAtProjection == nil else { return }
                let acceptedSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(target.id)
                let accepted = acceptedSnapshot?.revisions.workingRevision ?? 0
                let projected = await manager.awaitProjectedInstall(of: target.id, atLeast: accepted)
                XCTAssertNotNil(projected, message)
                revisionAtProjection = revision()
                do {
                    switch row {
                    case .laterStoreOnTheShownTab:
                        try await self.show(target.id, in: window)
                        XCTAssertTrue(
                            manager.storeShownTabSelection(StoredSelection(selectedPaths: [fileC.path]), for: identity),
                            message
                        )
                    case .laterCanonicalCommitsRestoreTheSelection:
                        try await commitAsPeer(StoredSelection(selectedPaths: [fileC.path]))
                        try await commitAsPeer(runSelection)
                    }
                } catch {
                    XCTFail("\(message): \(error)")
                }
            }
            addTeardownBlock { @MainActor in
                manager.contentGateway.commitResultWillReturnHandlerForTesting = nil
            }
            let completion = await window.mcpServer.commitContextBuilderTabContext(
                connectionID: connectionID,
                expectedRunID: runID,
                authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
            )

            XCTAssertEqual(completion.outcome, .committed, message)
            let committedTab = try XCTUnwrap(completion.committedTab, message)
            XCTAssertEqual(committedTab.tab.selection, runSelection, message)
            let projectionRevision = try XCTUnwrap(revisionAtProjection, message)
            XCTAssertNotEqual(revision(), projectionRevision, message)
            switch row {
            case .laterStoreOnTheShownTab:
                XCTAssertEqual(committedTab.selectionRevision, projectionRevision, message)
            case .laterCanonicalCommitsRestoreTheSelection:
                // The tab stores the run's selection again, but a later write put it there. The
                // receipt can't show that the selection hasn't changed since the commit.
                let stored = try await canonicalTab(targetTab.id, of: target.id, in: runtime)
                XCTAssertEqual(stored.selection, runSelection, message)
                XCTAssertNil(committedTab.selectionRevision, message)
            }
        }

        @MainActor
        func testUnchangedOffscreenContextCommitReceiptCarriesTheRevisionTheWindowGaveTheReadDocument() async throws {
            for row in UnchangedOffscreenReceiptRow.allCases {
                try await assertUnchangedOffscreenContextCommitReceipt(row)
            }
        }

        /// Whether the window has installed the canonical revision that an offscreen context commit
        /// reads, when the tab already stores the commit's context.
        private enum UnchangedOffscreenReceiptRow: String, CaseIterable {
            /// The runtime loaded the tab with the context from disk, at working revision 0.
            case contextLoadedFromDisk
            /// Discovery stored the context through the window's gateway, which returned once the
            /// window installed that write.
            case discoveryStoredTheContext
            /// Another writer stored the context, and the bridge holds that write's event.
            case windowLacksTheReadRevision
        }

        @MainActor
        private func assertUnchangedOffscreenContextCommitReceipt(_ row: UnchangedOffscreenReceiptRow) async throws {
            let message = row.rawValue
            let roots = try makeTemporaryRoots(count: 2)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let runSelection = StoredSelection(selectedPaths: [fileB.path])
            let runPrompt = "Context Builder prompt"
            let targetTab = switch row {
            case .contextLoadedFromDisk:
                ComposeTabState(name: "Target", selection: runSelection, promptText: runPrompt)
            case .discoveryStoredTheContext, .windowLacksTheReadRevision:
                ComposeTabState(name: "Target", selection: StoredSelection(selectedPaths: [fileA.path]))
            }
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let shown = WorkspaceModel(name: "Shown Workspace", repoPaths: [roots[1].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [target, shown], showing: [shown])
            let window = windows[0]
            let manager = window.workspaceManager
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            let connectionID = UUID()
            let runID = UUID()

            let heldEvent = ArrivalGate()
            if row == .discoveryStoredTheContext {
                _ = try await manager.contentGateway.mutateComposeTab(
                    identity,
                    source: "test.discovery",
                    persistence: .working
                ) { tab in
                    tab.selection = runSelection
                    tab.promptText = runPrompt
                }
            }
            if row == .windowLacksTheReadRevision {
                var heldEvents = 0
                window.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting { event in
                    guard event.workspaceID == target.id, heldEvents == 0 else { return }
                    heldEvents += 1
                    await heldEvent.arriveAndWaitForRelease()
                }
                addTeardownBlock { @MainActor in
                    window.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting(nil)
                    await heldEvent.release()
                }
                let snapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(target.id)
                let canonical = try XCTUnwrap(snapshot, message)
                var document = try JSONDecoder().decode(WorkspaceModel.self, from: canonical.document.documentBytes)
                document.composeTabs[0].selection = runSelection
                document.composeTabs[0].promptText = runPrompt
                let peer = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -7302)
                let outcome = try await peer.replaceWorking(
                    document,
                    fileURL: canonical.document.fileURL,
                    expectedWorkspaceRevision: canonical.revisions.workingRevision
                )
                XCTAssertEqual(outcome.disposition, .applied, message)
                await heldEvent.waitForArrival()
            }

            window.mcpServer.tabContextByConnectionID[connectionID] = MCPServerViewModel.TabContextSnapshot(
                tabID: targetTab.id,
                windowID: window.windowID,
                workspaceID: target.id,
                promptText: runPrompt,
                selection: runSelection,
                selectionRevision: manager.selectionRevisionForMCP(workspaceID: target.id, tabID: targetTab.id),
                storedSelectionAtRevision: runSelection,
                selectedMetaPromptIDs: [],
                selectedContextBuilderPromptIDs: [],
                tabName: targetTab.name,
                runID: runID,
                explicitlyBound: false
            )
            let readSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(target.id)
            let readRevision = try XCTUnwrap(readSnapshot, message).revisions.workingRevision
            if row == .contextLoadedFromDisk {
                XCTAssertEqual(readRevision, 0, message)
            } else {
                XCTAssertGreaterThan(readRevision, 0, message)
            }
            let completion = await window.mcpServer.commitContextBuilderTabContext(
                connectionID: connectionID,
                expectedRunID: runID,
                authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
            )
            let afterSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(target.id)
            let afterRevision = try XCTUnwrap(afterSnapshot, message).revisions.workingRevision

            XCTAssertEqual(afterRevision, readRevision, "\(message): the commit must change nothing")
            XCTAssertEqual(completion.outcome, .committed, message)
            let committedTab = try XCTUnwrap(completion.committedTab, message)
            XCTAssertEqual(committedTab.tab.selection, runSelection, message)
            switch row {
            case .contextLoadedFromDisk, .discoveryStoredTheContext:
                XCTAssertEqual(
                    committedTab.selectionRevision,
                    manager.selectionRevisionForMCP(workspaceID: target.id, tabID: targetTab.id),
                    message
                )
            case .windowLacksTheReadRevision:
                XCTAssertNil(committedTab.selectionRevision, message)
                await heldEvent.release()
            }
        }

        @MainActor
        func testPromptReplyDescribesTheTabItWroteWhenTheConnectionRebinds() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let boundTab = ComposeTabState(name: "Bound", promptText: "Bound prompt")
            let bound = WorkspaceModel(
                name: "Bound Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [boundTab],
                activeComposeTabID: boundTab.id
            )
            let shownTab = ComposeTabState(name: "Shown", promptText: "Shown prompt")
            let shown = WorkspaceModel(
                name: "Shown Workspace",
                repoPaths: [roots[1].path],
                composeTabs: [shownTab],
                activeComposeTabID: shownTab.id
            )
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [bound, shown], showing: [shown])
            let window = windows[0]
            let server = window.mcpServer
            let connectionID = UUID()
            let clientName = "BindContextRoutingAuthorityTests"
            try await server.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: boundTab.id,
                workspaceID: bound.id,
                windowID: window.windowID
            )
            server.setRequestMetadataOverrideForTesting(MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: clientName,
                windowID: window.windowID
            ))
            let gateway = window.workspaceManager.contentGateway
            addTeardownBlock { @MainActor in
                server.setRequestMetadataOverrideForTesting(nil)
                gateway.canonicalReadWillBeginHandlerForTesting = nil
            }
            let tools = await server.windowMCPToolCatalogService.tools
            let promptTool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.prompt })

            // The connection rebinds to the shown tab while the edit loads the bound tab.
            var heldLoads = 0
            gateway.canonicalReadWillBeginHandlerForTesting = { workspaceID, source in
                guard workspaceID == bound.id, source == "mcp.prompt", heldLoads == 0 else { return }
                heldLoads += 1
                _ = try? await server.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: clientName,
                    tabID: shownTab.id,
                    workspaceID: shown.id,
                    windowID: window.windowID
                )
            }
            let reply = try await promptTool(["op": .string("set"), "text": .string("Written")])

            XCTAssertEqual(heldLoads, 1)
            let replyText = try String(decoding: JSONEncoder().encode(reply), as: UTF8.self)
            XCTAssertTrue(replyText.contains("Written"), replyText)
            XCTAssertFalse(replyText.contains("Shown prompt"), replyText)
            let storedBoundTab = try await canonicalTab(boundTab.id, of: bound.id, in: runtime)
            XCTAssertEqual(storedBoundTab.promptText, "Written")
            XCTAssertEqual(server.tabContextByConnectionID[connectionID]?.tabID, shownTab.id)
            XCTAssertEqual(server.tabContextByConnectionID[connectionID]?.promptText, "Shown prompt")
        }

        @MainActor
        func testRefusedStickyPromptCommitFailsTheCallAndKeepsTheBindingPrompt() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let boundTab = ComposeTabState(name: "Bound", promptText: "Bound prompt")
            let bound = WorkspaceModel(
                name: "Bound Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [boundTab],
                activeComposeTabID: boundTab.id
            )
            // A stashed entry without `stashedAt` makes the app decode drop the stashed array, so the
            // gateway refuses to write the document back.
            var boundObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(bound)) as? [String: Any]
            )
            boundObject["stashedTabs"] = [[
                "id": UUID().uuidString,
                "tab": ["id": UUID().uuidString, "name": "Malformed"]
            ]]
            let boundBytes = try JSONSerialization.data(withJSONObject: boundObject, options: [.sortedKeys])
            let shownTab = ComposeTabState(name: "Shown", promptText: "Shown prompt")
            let shown = WorkspaceModel(
                name: "Shown Workspace",
                repoPaths: [roots[1].path],
                composeTabs: [shownTab],
                activeComposeTabID: shownTab.id
            )
            let (windows, runtime) = try await makeRuntimeBackedWindows(
                catalog: [bound, shown],
                showing: [shown],
                documentBytes: [bound.id: boundBytes]
            )
            let window = windows[0]
            let connectionID = UUID()
            let clientName = "BindContextRoutingAuthorityTests"
            try await window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: boundTab.id,
                workspaceID: bound.id,
                windowID: window.windowID
            )
            window.mcpServer.setRequestMetadataOverrideForTesting(MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: clientName,
                windowID: window.windowID
            ))
            addTeardownBlock { @MainActor in
                window.mcpServer.setRequestMetadataOverrideForTesting(nil)
            }
            let tools = await window.mcpServer.windowMCPToolCatalogService.tools
            let promptTool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.prompt })

            do {
                _ = try await promptTool(["op": .string("set"), "text": .string("Refused edit")])
                XCTFail("The prompt tool should report the refused commit")
            } catch {
                XCTAssertTrue(
                    "\(error) \(error.localizedDescription)".contains(WorkspaceContentGatewayError.decodeLostTabsDiagnostic),
                    "\(error)"
                )
            }

            let storedBoundTab = try await canonicalTab(boundTab.id, of: bound.id, in: runtime)
            XCTAssertEqual(storedBoundTab.promptText, "Bound prompt")
            XCTAssertEqual(window.mcpServer.tabContextByConnectionID[connectionID]?.promptText, "Bound prompt")
            XCTAssertEqual(window.promptManager.promptText, "Shown prompt")
        }

        @MainActor
        func testPromptAppendDuringAnotherAppendToAnUnshownTabKeepsBoth() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let boundTab = ComposeTabState(name: "Bound", promptText: "Base")
            let bound = WorkspaceModel(
                name: "Bound Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [boundTab],
                activeComposeTabID: boundTab.id
            )
            let shown = WorkspaceModel(name: "Shown Workspace", repoPaths: [roots[1].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [bound, shown], showing: [shown])
            let window = windows[0]
            let connectionID = UUID()
            let clientName = "BindContextRoutingAuthorityTests"
            try await window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: boundTab.id,
                workspaceID: bound.id,
                windowID: window.windowID
            )
            window.mcpServer.setRequestMetadataOverrideForTesting(MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: clientName,
                windowID: window.windowID
            ))
            let gateway = window.workspaceManager.contentGateway
            addTeardownBlock { @MainActor in
                window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                gateway.canonicalReadWillBeginHandlerForTesting = nil
            }
            let tools = await window.mcpServer.windowMCPToolCatalogService.tools
            let promptTool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.prompt })

            // The second append runs to completion while the first one's load of the tab waits.
            var heldLoads = 0
            var secondAppendError: Error?
            gateway.canonicalReadWillBeginHandlerForTesting = { workspaceID, source in
                guard workspaceID == bound.id, source == "mcp.prompt", heldLoads == 0 else { return }
                heldLoads += 1
                do {
                    _ = try await promptTool(["op": .string("append"), "text": .string(" second")])
                } catch {
                    secondAppendError = error
                }
            }
            _ = try await promptTool(["op": .string("append"), "text": .string(" first")])

            XCTAssertEqual(heldLoads, 1)
            XCTAssertNil(secondAppendError)
            let storedBoundTab = try await canonicalTab(boundTab.id, of: bound.id, in: runtime)
            XCTAssertEqual(storedBoundTab.promptText, "Base second first")
            XCTAssertEqual(window.mcpServer.tabContextByConnectionID[connectionID]?.promptText, "Base second first")
        }

        @MainActor
        func testPromptGetReturnsTheStoredPromptAfterAnAppendIsAnsweredLate() async throws {
            for row in LateAppendAnswerRow.allCases {
                try await assertPromptGetReturnsTheStoredPrompt(row)
            }
        }

        /// What happens to the bound tab, in a workspace the window doesn't show, between the
        /// authority accepting a first append and the binding getting that answer.
        private enum LateAppendAnswerRow: String, CaseIterable {
            /// A second append commits on top of the first and answers first, and the window projects
            /// neither append before the first answer arrives.
            case laterAppendAnswersFirst
            /// The window projects the first append and starts showing the workspace. Then it stores a
            /// second append in its own copy. The switch reloads the tab from the workspace's saved
            /// file, so the copy can lack the first append.
            case shownStoreBeforeTheAnswer
        }

        @MainActor
        private func assertPromptGetReturnsTheStoredPrompt(_ row: LateAppendAnswerRow) async throws {
            let message = row.rawValue
            let roots = try makeTemporaryRoots(count: 2)
            let boundTab = ComposeTabState(name: "Bound", promptText: "Base")
            let bound = WorkspaceModel(
                name: "Bound Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [boundTab],
                activeComposeTabID: boundTab.id
            )
            let shown = WorkspaceModel(name: "Shown Workspace", repoPaths: [roots[1].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [bound, shown], showing: [shown])
            let window = windows[0]
            let connectionID = UUID()
            let clientName = "BindContextRoutingAuthorityTests"
            try await window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: boundTab.id,
                workspaceID: bound.id,
                windowID: window.windowID
            )
            window.mcpServer.setRequestMetadataOverrideForTesting(MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: clientName,
                windowID: window.windowID
            ))
            let gateway = window.workspaceManager.contentGateway
            addTeardownBlock { @MainActor in
                window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                gateway.commitResultWillReturnHandlerForTesting = nil
            }
            let tools = await window.mcpServer.windowMCPToolCatalogService.tools
            let promptTool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.prompt })

            var heldResults = 0
            var secondAppendError: Error?
            func appendSecond() async {
                do {
                    _ = try await promptTool(["op": .string("append"), "text": .string(" second")])
                } catch {
                    secondAppendError = error
                }
            }
            switch row {
            case .laterAppendAnswersFirst:
                // The bridge holds the first append's event until the binding has the first answer.
                let projection = ArrivalGate()
                var heldEvents = 0
                window.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting { event in
                    guard event.workspaceID == bound.id, heldEvents == 0 else { return }
                    heldEvents += 1
                    await projection.arriveAndWaitForRelease()
                }
                addTeardownBlock { @MainActor in
                    window.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting(nil)
                }
                // Both hooks run on the main actor. The second hook resumes the first without
                // suspending. The gateway then gives the binding the second answer before the first
                // hook resumes.
                var secondAnswered = false
                var secondAnswerWaiter: CheckedContinuation<Void, Never>?
                var secondAppend: Task<Void, Never>?
                gateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == bound.id else { return }
                    heldResults += 1
                    switch heldResults {
                    case 1:
                        secondAppend = Task { @MainActor in await appendSecond() }
                        if !secondAnswered {
                            await withCheckedContinuation { secondAnswerWaiter = $0 }
                        }
                        Task { @MainActor in await projection.release() }
                    case 2:
                        secondAnswered = true
                        secondAnswerWaiter?.resume()
                        secondAnswerWaiter = nil
                    default:
                        break
                    }
                }
                _ = try await promptTool(["op": .string("append"), "text": .string(" first")])
                await secondAppend?.value
                XCTAssertEqual(heldEvents, 1, message)
                XCTAssertEqual(heldResults, 2, message)
            case .shownStoreBeforeTheAnswer:
                gateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == bound.id, heldResults == 0 else { return }
                    heldResults += 1
                    let acceptedSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(bound.id)
                    let accepted = acceptedSnapshot?.revisions.workingRevision ?? 0
                    let projected = await window.workspaceManager.awaitProjectedInstall(of: bound.id, atLeast: accepted)
                    XCTAssertNotNil(projected, message)
                    do {
                        try await self.show(bound.id, in: window)
                    } catch {
                        XCTFail("\(message): \(error)")
                    }
                    await appendSecond()
                }
                _ = try await promptTool(["op": .string("append"), "text": .string(" first")])
                XCTAssertEqual(heldResults, 1, message)
            }
            gateway.commitResultWillReturnHandlerForTesting = nil

            XCTAssertNil(secondAppendError, message)
            let storedPrompt = switch row {
            case .laterAppendAnswersFirst:
                try await canonicalTab(boundTab.id, of: bound.id, in: runtime).promptText
            case .shownStoreBeforeTheAnswer:
                try XCTUnwrap(window.workspaceManager.contentGateway.shownComposeTab(WorkspaceSelectionIdentity(
                    workspaceID: bound.id,
                    tabID: boundTab.id
                ))?.promptText, message)
            }
            XCTAssertTrue(storedPrompt.hasSuffix(" second"), "\(message): \(storedPrompt)")
            let reply = try await promptTool(["op": .string("get")])
            let replyText = try String(decoding: JSONEncoder().encode(reply), as: UTF8.self)
            XCTAssertTrue(replyText.contains("\"prompt\":\"\(storedPrompt)\""), "\(message): \(replyText)")
        }

        /// Projections keep a pinned tab and its session binding, and the window that shows the tab
        /// still shows a selection another window commits to it.
        @MainActor
        func testPinnedTabShowsTheSelectionAnotherWindowCommitsToIt() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let activeTab = ComposeTabState(name: "Active")
            let pinnedTab = ComposeTabState(
                name: "Pinned",
                isPinned: true,
                selection: StoredSelection(selectedPaths: [fileA.path])
            )
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [activeTab, pinnedTab],
                activeComposeTabID: activeTab.id
            )
            let other = WorkspaceModel(name: "Other Shown", repoPaths: [roots[1].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(catalog: [target, other], showing: [target, other])
            let peer = windows[0]
            let committer = windows[1]
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: pinnedTab.id)
            let committedSelection = StoredSelection(selectedPaths: [fileB.path])

            _ = await committer.selectionCoordinator.persistSelection(
                committedSelection,
                for: identity,
                source: .mcpTabContext,
                mirrorToUIIfActive: false
            )

            let stored = try await canonicalTab(pinnedTab.id, of: target.id, in: runtime)
            XCTAssertEqual(stored.selection, committedSelection)
            XCTAssertEqual(peer.workspaceManager.shownTabSelection(for: identity), committedSelection)
        }

        @MainActor
        func testPeerPresentsSelectionsInAuthorityOrder() async throws {
            for mirrorsToUI in [false, true] {
                try await assertWindowsShowingTheTabEndOnTheLaterCommit(mirrorsToUI: mirrorsToUI)
            }
        }

        /// An earlier and a later writer commit selections to a tab neither window shows. The
        /// authority accepts them at r1 and r2, and the answer to r1 arrives after r2's. A third
        /// window shows the tab, and the later writer starts showing it while it submits its commit.
        /// Both end on r2's selection, presented as its mirror policy says.
        @MainActor
        private func assertWindowsShowingTheTabEndOnTheLaterCommit(mirrorsToUI: Bool) async throws {
            let message = "mirrorsToUI: \(mirrorsToUI)"
            let roots = try makeTemporaryRoots(count: 3)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let fileC = try makeFile(named: "C.swift", in: roots[0])
            let targetTab = ComposeTabState(name: "Target", selection: StoredSelection(selectedPaths: [fileA.path]))
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let firstShown = WorkspaceModel(name: "First Shown", repoPaths: [roots[1].path])
            let secondShown = WorkspaceModel(name: "Second Shown", repoPaths: [roots[2].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(
                catalog: [target, firstShown, secondShown],
                showing: [firstShown, secondShown, target]
            )
            let earlierWriter = windows[0]
            let laterWriter = windows[1]
            let peer = windows[2]
            let earlierGateway = earlierWriter.workspaceManager.contentGateway
            let laterGateway = laterWriter.workspaceManager.contentGateway
            addTeardownBlock { @MainActor in
                earlierGateway.commitResultWillReturnHandlerForTesting = nil
                laterGateway.commitSubmissionWillBeginHandlerForTesting = nil
            }
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            let earlierSelection = StoredSelection(selectedPaths: [fileB.path])
            let laterSelection = StoredSelection(selectedPaths: [fileC.path])
            let peerFileTreeBefore = peer.workspaceFilesViewModel.snapshotSelection()

            var laterWriterFileTreeWhenShown: StoredSelection?
            laterGateway.commitSubmissionWillBeginHandlerForTesting = { workspaceID in
                guard workspaceID == target.id, laterWriterFileTreeWhenShown == nil else { return }
                try? await self.show(target.id, in: laterWriter)
                laterWriterFileTreeWhenShown = laterWriter.workspaceFilesViewModel.snapshotSelection()
            }
            var heldResults = 0
            earlierGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                guard workspaceID == target.id, heldResults == 0 else { return }
                heldResults += 1
                _ = await laterWriter.selectionCoordinator.persistSelection(
                    laterSelection,
                    for: identity,
                    source: .mcpTabContext,
                    mirrorToUIIfActive: mirrorsToUI
                )
            }
            _ = await earlierWriter.selectionCoordinator.persistSelection(
                earlierSelection,
                for: identity,
                source: .mcpTabContext,
                mirrorToUIIfActive: mirrorsToUI
            )
            earlierGateway.commitResultWillReturnHandlerForTesting = nil
            laterGateway.commitSubmissionWillBeginHandlerForTesting = nil

            XCTAssertEqual(heldResults, 1, message)
            let storedTargetTab = try await canonicalTab(targetTab.id, of: target.id, in: runtime)
            XCTAssertEqual(storedTargetTab.selection, laterSelection, message)
            let laterWriterFileTreeBefore = try XCTUnwrap(laterWriterFileTreeWhenShown, message)
            for (window, fileTreeBefore) in [(peer, peerFileTreeBefore), (laterWriter, laterWriterFileTreeBefore)] {
                let windowMessage = "\(message), window \(window.windowID)"
                XCTAssertEqual(window.workspaceManager.shownTabSelection(for: identity), laterSelection, windowMessage)
                XCTAssertEqual(
                    window.workspaceManager.promptViewModel.currentComposeTabs.first { $0.id == targetTab.id }?.selection,
                    laterSelection,
                    windowMessage
                )
                if mirrorsToUI {
                    XCTAssertEqual(
                        window.workspaceFilesViewModel.snapshotSelection().selectedPaths,
                        laterSelection.selectedPaths,
                        windowMessage
                    )
                } else {
                    XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection(), fileTreeBefore, windowMessage)
                }
                // A UI snapshot published afterward keeps the selection.
                window.workspaceManager.publishActiveComposeTabSnapshot()
                XCTAssertEqual(window.workspaceManager.shownTabSelection(for: identity), laterSelection, windowMessage)
            }
        }

        @MainActor
        func testPeerEndsOnTheLatestOfShownAndCanonicalSelections() async throws {
            for row in MixedPropagationRow.allCases {
                try await assertPeerEndsOnTheLatestChange(row)
            }
        }

        /// How the windows showing the tab receive canonical commits, selections that a window stored
        /// on its shown workspace, and other writes. A commit takes its place in propagation order
        /// when its answer arrives. Windows take it only while their projection's latest install has
        /// the commit's selection, and every window showing the tab ends on the same selection.
        private enum MixedPropagationRow: String, CaseIterable {
            /// The store takes its propagation revision before the commit's answer arrives, and its
            /// propagation arrives after the commit's.
            case storeArrivesAfterCommit
            /// The store takes its propagation revision before the commit's answer arrives. The window
            /// projects the commit, then takes the store, then the commit's propagation arrives.
            case commitArrivesAfterStore
            /// The store takes its propagation revision after the commit's answer arrives and before
            /// the committing window projects the commit.
            case storeAfterTheCommitAnswer
            /// The window presents a commit, then takes a store, then the propagation of a commit the
            /// authority accepted earlier arrives.
            case olderCommitAfterNewerCommitAndStore
            /// The authority accepts two commits, and the test holds both answers. After the windows
            /// project the second commit, the store window makes a store. Then the answers arrive in
            /// revision order.
            case storeBetweenTwoCommitAnswersInRevisionOrder
            /// A window showing the tab makes an MCP store and propagates it, after a commit's
            /// acceptance and before its answer.
            case ownStoreBeforeTheCommitAnswer
            /// The test holds a commit's answer. Meanwhile the store window propagates a store and
            /// publishes it, and the windows project that publish before the answer arrives.
            case storePublishedBeforeTheCommitPropagates
            /// The test holds a commit's answer. Meanwhile a Context Builder run commits its final
            /// context to the tab from a window that doesn't show it, and the windows project that
            /// commit before the answer arrives.
            case contextCommitBeforeTheCommitPropagates
        }

        @MainActor
        private func assertPeerEndsOnTheLatestChange(_ row: MixedPropagationRow) async throws {
            let message = row.rawValue
            let roots = try makeTemporaryRoots(count: 2)
            let fileA = try makeFile(named: "A.swift", in: roots[0])
            let fileB = try makeFile(named: "B.swift", in: roots[0])
            let fileC = try makeFile(named: "C.swift", in: roots[0])
            let fileD = try makeFile(named: "D.swift", in: roots[0])
            let fileE = try makeFile(named: "E.swift", in: roots[0])
            let targetTab = ComposeTabState(name: "Target", selection: StoredSelection(selectedPaths: [fileA.path]))
            let target = WorkspaceModel(
                name: "Target Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [targetTab],
                activeComposeTabID: targetTab.id
            )
            let other = WorkspaceModel(name: "Other Shown", repoPaths: [roots[1].path])
            let (windows, runtime) = try await makeRuntimeBackedWindows(
                catalog: [target, other],
                showing: [target, target, other, other]
            )
            let storeWindow = windows[0]
            let peer = windows[1]
            let committer = windows[2]
            let laterCommitter = windows[3]
            let windowsShowingTheTab = [storeWindow, peer]
            let committerGateway = committer.workspaceManager.contentGateway
            let laterCommitterGateway = laterCommitter.workspaceManager.contentGateway
            addTeardownBlock { @MainActor in
                committerGateway.commitResultWillReturnHandlerForTesting = nil
                laterCommitterGateway.commitResultWillReturnHandlerForTesting = nil
                committer.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting(nil)
            }
            let identity = WorkspaceSelectionIdentity(workspaceID: target.id, tabID: targetTab.id)
            let committedSelection = StoredSelection(selectedPaths: [fileB.path])
            let storedSelection = StoredSelection(selectedPaths: [fileC.path])
            let laterCommitSelection = StoredSelection(selectedPaths: [fileD.path])
            let contextSelection = StoredSelection(selectedPaths: [fileE.path])
            func presentedSelection(in window: WindowState) -> StoredSelection? {
                window.workspaceManager.promptViewModel.currentComposeTabs.first { $0.id == targetTab.id }?.selection
            }
            /// Stores the selection on the store window's shown workspace the way an MCP selection does
            /// before its mirror, and takes its propagation revision. The propagation runs later. The
            /// store sets the window's marker and fences the selection, because without the fence a
            /// save capture of the file tree's older selection can replace it.
            func storeOnShownWorkspace() -> MCPSelectionPeerPropagation {
                let manager = storeWindow.workspaceManager
                XCTAssertTrue(manager.storeShownTabSelection(storedSelection, for: identity), message)
                manager.recordOrderedMCPSelectionStore(for: identity)
                storeWindow.selectionCoordinator.protectCanonicalMCPSelectionFromDeferredUISnapshots(
                    storedSelection,
                    for: identity
                )
                let registration = manager.registerMCPSelectionSourceMutation(for: identity, acceptedRevision: nil)
                return MCPSelectionPeerPropagation(
                    identity: identity,
                    selection: storedSelection,
                    sourceRevision: registration.sourceRevision,
                    peerHostIDs: registration.peerHostIDs,
                    mirrorToUIIfActive: false
                )
            }
            func commit(_ selection: StoredSelection, from window: WindowState) async {
                _ = await window.selectionCoordinator.persistSelection(
                    selection,
                    for: identity,
                    source: .mcpTabContext,
                    mirrorToUIIfActive: false
                )
            }
            func awaitProjectionOfTheCanonicalTab(in projectingWindows: [WindowState]? = nil) async {
                let acceptedSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(target.id)
                let accepted = acceptedSnapshot?.revisions.workingRevision ?? 0
                for window in projectingWindows ?? [peer] {
                    let projected = await window.workspaceManager.awaitProjectedInstall(of: target.id, atLeast: accepted)
                    XCTAssertNotNil(projected, "\(message), window \(window.windowID)")
                }
            }
            func assertWindowsStore(_ selection: StoredSelection, _ step: String) {
                for window in windowsShowingTheTab {
                    XCTAssertEqual(
                        window.workspaceManager.shownTabSelection(for: identity),
                        selection,
                        "\(message), \(step), window \(window.windowID)"
                    )
                }
            }

            // A capture copies a window's file tree selection into its copy of the tab, and these
            // commits don't change the file tree, so a capture during the row would put the copy back
            // on the tab's original selection.
            for window in windowsShowingTheTab {
                await settleQueuedCaptures(in: window)
            }

            var heldResults = 0
            // The selections each window presented before a held answer arrived, for rows whose
            // answer has to present nothing.
            var presentedBeforeTheAnswer: [Int: StoredSelection?] = [:]
            switch row {
            case .storeArrivesAfterCommit:
                var storePropagation: MCPSelectionPeerPropagation?
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, storePropagation == nil else { return }
                    heldResults += 1
                    storePropagation = storeOnShownWorkspace()
                }
                await commit(committedSelection, from: committer)
                let propagation = try XCTUnwrap(storePropagation, message)
                await storeWindow.workspaceManager.propagateMCPSelectionToPeerHosts(propagation)
            case .commitArrivesAfterStore:
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, heldResults == 0 else { return }
                    heldResults += 1
                    let propagation = storeOnShownWorkspace()
                    await awaitProjectionOfTheCanonicalTab()
                    await storeWindow.workspaceManager.propagateMCPSelectionToPeerHosts(propagation)
                    XCTAssertEqual(peer.workspaceManager.shownTabSelection(for: identity), storedSelection, message)
                }
                await commit(committedSelection, from: committer)
            case .storeAfterTheCommitAnswer:
                // The committing window projects the commit only after the store. The store runs in the
                // first turn after the one that delivers the commit's answer.
                let storeDone = ArrivalGate()
                var heldEvents = 0
                committer.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting { event in
                    guard event.workspaceID == target.id, heldEvents == 0 else { return }
                    heldEvents += 1
                    await storeDone.waitForArrival()
                }
                var store: Task<Void, Never>?
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, heldResults == 0 else { return }
                    heldResults += 1
                    store = Task { @MainActor in
                        await awaitProjectionOfTheCanonicalTab()
                        let propagation = storeOnShownWorkspace()
                        await storeWindow.workspaceManager.propagateMCPSelectionToPeerHosts(propagation)
                        await storeDone.arrive()
                    }
                }
                await commit(committedSelection, from: committer)
                await store?.value
                XCTAssertEqual(heldEvents, 1, message)
            case .olderCommitAfterNewerCommitAndStore:
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, heldResults == 0 else { return }
                    heldResults += 1
                    await commit(laterCommitSelection, from: laterCommitter)
                    XCTAssertEqual(peer.workspaceManager.shownTabSelection(for: identity), laterCommitSelection, message)
                    await storeWindow.workspaceManager.propagateMCPSelectionToPeerHosts(storeOnShownWorkspace())
                    XCTAssertEqual(peer.workspaceManager.shownTabSelection(for: identity), storedSelection, message)
                }
                await commit(committedSelection, from: committer)
            case .storeBetweenTwoCommitAnswersInRevisionOrder:
                let laterAnswer = ArrivalGate()
                laterCommitterGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id else { return }
                    await laterAnswer.arriveAndWaitForRelease()
                }
                var laterCommit: Task<Void, Never>?
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, heldResults == 0 else { return }
                    heldResults += 1
                    laterCommit = Task { @MainActor in await commit(laterCommitSelection, from: laterCommitter) }
                    await laterAnswer.waitForArrival()
                    await awaitProjectionOfTheCanonicalTab(in: windowsShowingTheTab)
                    assertWindowsStore(laterCommitSelection, "after the projection of the second commit")
                    await storeWindow.workspaceManager.propagateMCPSelectionToPeerHosts(storeOnShownWorkspace())
                    assertWindowsStore(storedSelection, "after the store")
                }
                await commit(committedSelection, from: committer)
                // The first answer's propagation presents nothing: the projection already has the
                // second commit's selection.
                assertWindowsStore(storedSelection, "after the first answer")
                for window in windowsShowingTheTab {
                    XCTAssertEqual(presentedSelection(in: window), storedSelection, "\(message), window \(window.windowID)")
                }
                await laterAnswer.release()
                await laterCommit?.value
            case .ownStoreBeforeTheCommitAnswer:
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, heldResults == 0 else { return }
                    heldResults += 1
                    await awaitProjectionOfTheCanonicalTab(in: windowsShowingTheTab)
                    _ = await storeWindow.selectionCoordinator.persistSelection(
                        storedSelection,
                        for: identity,
                        source: .mcpTabContext,
                        mirrorToUIIfActive: false
                    )
                    assertWindowsStore(storedSelection, "after the store")
                }
                await commit(committedSelection, from: committer)
            case .storePublishedBeforeTheCommitPropagates:
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, heldResults == 0 else { return }
                    heldResults += 1
                    await awaitProjectionOfTheCanonicalTab(in: windowsShowingTheTab)
                    await storeWindow.workspaceManager.propagateMCPSelectionToPeerHosts(storeOnShownWorkspace())
                    guard let copy = storeWindow.workspaceManager.workspace(withID: target.id) else {
                        return XCTFail("\(message): the store window lost the workspace")
                    }
                    await storeWindow.workspaceManager.debugPublishWorkingDocumentToDomainAuthority(copy)
                    let published = try? await self.canonicalTab(targetTab.id, of: target.id, in: runtime)
                    XCTAssertEqual(published?.selection, storedSelection, message)
                    await awaitProjectionOfTheCanonicalTab(in: windowsShowingTheTab)
                    assertWindowsStore(storedSelection, "after the publish")
                    for window in windowsShowingTheTab {
                        presentedBeforeTheAnswer[window.windowID] = presentedSelection(in: window)
                    }
                }
                await commit(committedSelection, from: committer)
            case .contextCommitBeforeTheCommitPropagates:
                committerGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                    guard workspaceID == target.id, heldResults == 0 else { return }
                    heldResults += 1
                    let connectionID = UUID()
                    let runID = UUID()
                    laterCommitter.mcpServer.tabContextByConnectionID[connectionID] = MCPServerViewModel.TabContextSnapshot(
                        tabID: targetTab.id,
                        windowID: laterCommitter.windowID,
                        workspaceID: target.id,
                        promptText: "Context Builder prompt",
                        selection: contextSelection,
                        selectionRevision: laterCommitter.workspaceManager.selectionRevisionForMCP(
                            workspaceID: target.id,
                            tabID: targetTab.id
                        ),
                        storedSelectionAtRevision: committedSelection,
                        selectedMetaPromptIDs: [],
                        selectedContextBuilderPromptIDs: [],
                        tabName: targetTab.name,
                        runID: runID,
                        explicitlyBound: false
                    )
                    let completion = await laterCommitter.mcpServer.commitContextBuilderTabContext(
                        connectionID: connectionID,
                        expectedRunID: runID,
                        authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
                    )
                    XCTAssertEqual(completion.outcome, .committed, message)
                    await awaitProjectionOfTheCanonicalTab(in: windowsShowingTheTab)
                    assertWindowsStore(contextSelection, "after the context commit")
                    for window in windowsShowingTheTab {
                        presentedBeforeTheAnswer[window.windowID] = presentedSelection(in: window)
                    }
                }
                await commit(committedSelection, from: committer)
            }
            committerGateway.commitResultWillReturnHandlerForTesting = nil
            laterCommitterGateway.commitResultWillReturnHandlerForTesting = nil
            committer.setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting(nil)

            XCTAssertEqual(heldResults, 1, message)
            let expected = switch row {
            case .storeArrivesAfterCommit, .commitArrivesAfterStore, .ownStoreBeforeTheCommitAnswer:
                committedSelection
            case .storeAfterTheCommitAnswer, .olderCommitAfterNewerCommitAndStore, .storePublishedBeforeTheCommitPropagates:
                storedSelection
            case .storeBetweenTwoCommitAnswersInRevisionOrder:
                laterCommitSelection
            case .contextCommitBeforeTheCommitPropagates:
                contextSelection
            }
            assertWindowsStore(expected, "at the end")
            for window in windowsShowingTheTab {
                let windowMessage = "\(message), window \(window.windowID)"
                switch row {
                case .storePublishedBeforeTheCommitPropagates, .contextCommitBeforeTheCommitPropagates:
                    // The held answer presents nothing.
                    let before = try XCTUnwrap(presentedBeforeTheAnswer[window.windowID], windowMessage)
                    XCTAssertEqual(presentedSelection(in: window), before, windowMessage)
                    XCTAssertNotEqual(presentedSelection(in: window), committedSelection, windowMessage)
                default:
                    XCTAssertEqual(presentedSelection(in: window), expected, windowMessage)
                }
            }
            if row == .storePublishedBeforeTheCommitPropagates {
                let canonical = try await canonicalTab(targetTab.id, of: target.id, in: runtime)
                XCTAssertEqual(peer.workspaceManager.shownTabSelection(for: identity), canonical.selection, message)
            }
        }

        @MainActor
        func testBindPreparedBeforeANewerBindIsDropped() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let shownTab = ComposeTabState(name: "Shown", promptText: "Shown prompt")
            let shown = WorkspaceModel(
                name: "Shown Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [shownTab],
                activeComposeTabID: shownTab.id
            )
            let parkedTab = ComposeTabState(name: "Parked", promptText: "Parked prompt")
            let parked = WorkspaceModel(
                name: "Parked Workspace",
                repoPaths: [roots[1].path],
                composeTabs: [parkedTab],
                activeComposeTabID: parkedTab.id
            )
            let (windows, _) = try await makeRuntimeBackedWindows(catalog: [shown, parked], showing: [shown])
            let window = windows[0]
            let server = window.mcpServer
            let gateway = window.workspaceManager.contentGateway
            let connectionID = UUID()

            // While the bind to the parked tab loads it, a bind to the shown tab completes.
            var heldLoads = 0
            gateway.canonicalReadWillBeginHandlerForTesting = { workspaceID, _ in
                guard workspaceID == parked.id, heldLoads == 0 else { return }
                heldLoads += 1
                _ = try? await server.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: nil,
                    tabID: shownTab.id,
                    workspaceID: shown.id,
                    windowID: window.windowID
                )
            }
            addTeardownBlock { @MainActor in
                gateway.canonicalReadWillBeginHandlerForTesting = nil
            }

            do {
                try await server.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: nil,
                    tabID: parkedTab.id,
                    workspaceID: parked.id,
                    windowID: window.windowID
                )
                XCTFail("The bind prepared before the newer one should be dropped")
            } catch MCPServerViewModel.TabBindError.bindingChanged {
                // Expected.
            } catch {
                XCTFail("Unexpected bind error: \(error)")
            }

            XCTAssertEqual(heldLoads, 1)
            let binding = server.connectionBindingSnapshot(forConnection: connectionID)
            XCTAssertEqual(binding.workspaceID, shown.id)
            XCTAssertEqual(binding.tabID, shownTab.id)
        }

        @MainActor
        func testBindPreparedInOneWindowIsDroppedForANewerBindInAnother() async throws {
            let roots = try makeTemporaryRoots(count: 3)
            let firstShownTab = ComposeTabState(name: "First Shown")
            let firstShown = WorkspaceModel(
                name: "First Shown",
                repoPaths: [roots[0].path],
                composeTabs: [firstShownTab],
                activeComposeTabID: firstShownTab.id
            )
            let parkedTab = ComposeTabState(name: "Parked")
            let parked = WorkspaceModel(
                name: "Parked",
                repoPaths: [roots[1].path],
                composeTabs: [parkedTab],
                activeComposeTabID: parkedTab.id
            )
            let secondShownTab = ComposeTabState(name: "Second Shown")
            let secondShown = WorkspaceModel(
                name: "Second Shown",
                repoPaths: [roots[2].path],
                composeTabs: [secondShownTab],
                activeComposeTabID: secondShownTab.id
            )
            let (windows, _) = try await makeRuntimeBackedWindows(
                catalog: [firstShown, parked, secondShown],
                showing: [firstShown, secondShown]
            )
            let olderWindow = windows[0]
            let newerWindow = windows[1]
            let gateway = olderWindow.workspaceManager.contentGateway
            addTeardownBlock { @MainActor in
                gateway.canonicalReadWillBeginHandlerForTesting = nil
            }
            let connectionID = UUID()

            // The connection has no binding in either window. While one window's bind loads the
            // parked tab, a bind in the other window completes.
            var heldLoads = 0
            gateway.canonicalReadWillBeginHandlerForTesting = { workspaceID, _ in
                guard workspaceID == parked.id, heldLoads == 0 else { return }
                heldLoads += 1
                _ = try? await newerWindow.mcpServer.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: nil,
                    tabID: secondShownTab.id,
                    workspaceID: secondShown.id,
                    windowID: newerWindow.windowID
                )
            }

            do {
                try await olderWindow.mcpServer.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: nil,
                    tabID: parkedTab.id,
                    workspaceID: parked.id,
                    windowID: olderWindow.windowID
                )
                XCTFail("The bind prepared before the other window's bind should be dropped")
            } catch MCPServerViewModel.TabBindError.bindingChanged {
                // Expected.
            } catch {
                XCTFail("Unexpected bind error: \(error)")
            }

            XCTAssertEqual(heldLoads, 1)
            XCTAssertNil(olderWindow.mcpServer.tabContextByConnectionID[connectionID])
            XCTAssertEqual(newerWindow.mcpServer.tabContextByConnectionID[connectionID]?.tabID, secondShownTab.id)
        }

        @MainActor
        func testBindPreparedBeforeABindAndItsReleaseIsDropped() async throws {
            let roots = try makeTemporaryRoots(count: 2)
            let shownTab = ComposeTabState(name: "Shown", promptText: "Shown prompt")
            let shown = WorkspaceModel(
                name: "Shown Workspace",
                repoPaths: [roots[0].path],
                composeTabs: [shownTab],
                activeComposeTabID: shownTab.id
            )
            let parkedTab = ComposeTabState(name: "Parked", promptText: "Parked prompt")
            let parked = WorkspaceModel(
                name: "Parked Workspace",
                repoPaths: [roots[1].path],
                composeTabs: [parkedTab],
                activeComposeTabID: parkedTab.id
            )
            let (windows, _) = try await makeRuntimeBackedWindows(catalog: [shown, parked], showing: [shown])
            let window = windows[0]
            let server = window.mcpServer
            let gateway = window.workspaceManager.contentGateway
            addTeardownBlock { @MainActor in
                gateway.canonicalReadWillBeginHandlerForTesting = nil
            }
            let connectionID = UUID()

            // The connection starts unbound. While the bind to the parked tab loads it, a bind to the
            // shown tab completes and the user releases it.
            var heldLoads = 0
            var innerBindWasInstalled = false
            gateway.canonicalReadWillBeginHandlerForTesting = { workspaceID, _ in
                guard workspaceID == parked.id, heldLoads == 0 else { return }
                heldLoads += 1
                _ = try? await server.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: nil,
                    tabID: shownTab.id,
                    workspaceID: shown.id,
                    windowID: window.windowID
                )
                innerBindWasInstalled = server.tabContextByConnectionID[connectionID]?.tabID == shownTab.id
                _ = server.clearExplicitBinding(forConnection: connectionID)
            }

            do {
                try await server.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: nil,
                    tabID: parkedTab.id,
                    workspaceID: parked.id,
                    windowID: window.windowID
                )
                XCTFail("The bind prepared before the released one should be dropped")
            } catch MCPServerViewModel.TabBindError.bindingChanged {
                // Expected.
            } catch {
                XCTFail("Unexpected bind error: \(error)")
            }

            XCTAssertEqual(heldLoads, 1)
            XCTAssertTrue(innerBindWasInstalled)
            XCTAssertNil(server.tabContextByConnectionID[connectionID])
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

        private func makeFile(named name: String, in root: URL) throws -> URL {
            let url = root.appendingPathComponent(name)
            try "// \(name)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        /// Windows over one runtime-backed catalog of `catalog` and a system Default workspace, in
        /// window ID order, each showing the workspace at its position in `shownWorkspaces`, with
        /// window tools enabled. A workspace a window doesn't show is listed from the catalog's
        /// summaries and read from its canonical document, as in the app.
        @MainActor
        private func makeRuntimeBackedWindows(
            catalog: [WorkspaceModel],
            showing shownWorkspaces: [WorkspaceModel],
            documentBytes: [UUID: Data] = [:]
        ) async throws -> (windows: [WindowState], runtime: MCPDomainRuntime) {
            let fixture = try await RuntimeBackedWorkspaceFixture(name: "BindContextRoutingAuthorityTests")
            addTeardownBlock { @MainActor in
                await fixture.tearDown()
            }
            // An established profile's index lists the system Default workspace, which each window
            // reuses at startup. A window that has to create its own Default can finish starting on
            // another workspace without loading that workspace's roots.
            var defaultWorkspace = WorkspaceModel(name: "Default", repoPaths: [])
            defaultWorkspace.isSystemWorkspace = true
            try fixture.writeWorkspace(defaultWorkspace)
            for workspace in catalog {
                if let bytes = documentBytes[workspace.id] {
                    try fixture.writeWorkspaceDocument(bytes, workspaceID: workspace.id, name: workspace.name)
                } else {
                    try fixture.writeWorkspace(workspace)
                }
            }
            try fixture.writeLegacyIndex([defaultWorkspace] + catalog)
            let runtime = try await fixture.makeRuntime(profileIdentifier: "bind-context-routing")
            let windows = shownWorkspaces.map { _ in WindowState(domainRuntime: runtime) }
                .sorted { $0.windowID < $1.windowID }
            addTeardownBlock { @MainActor in
                for window in windows {
                    window.beginClose()
                    await window.tearDown()
                }
            }
            _ = installWindows(windows)
            for (window, workspace) in zip(windows, shownWorkspaces) {
                await window.workspaceManager.awaitInitialized()
                try await show(workspace.id, in: window)
            }
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
            return (windows, runtime)
        }

        @MainActor
        private func show(_ workspaceID: UUID, in window: WindowState) async throws {
            _ = await window.workspaceManager.requestWorkspaceSwitch(
                toWorkspaceID: workspaceID,
                saveState: true,
                reason: "bindContextRoutingAuthorityTest"
            )
            guard window.workspaceManager.activeWorkspaceID == workspaceID else {
                throw BindContextRoutingFixtureError.workspaceActivationFailed
            }
        }

        /// Returns once the captures the window queued have run, and keeps the window from queuing a
        /// token recount. The captures are the debounced token recount and the debounced observations
        /// of the file selection, its slices, and the prompt.
        @MainActor
        private func settleQueuedCaptures(in window: WindowState) async {
            let manager = window.workspaceManager
            let tokenCounter = manager.promptViewModel.tokenCountingViewModel
            tokenCounter.suspendAutomaticRecounts()
            // Cancels the queued or running recount and counts once.
            await tokenCounter.forceImmediateRecount()
            // Each publisher sends its current value on subscription. This debounce uses the
            // window's scheduler and the longest interval among its observers, so it runs after
            // every observation the window debounced before this call.
            let observations = Publishers.Merge3(
                manager.fileManager.$selectedFiles.map { _ in () },
                manager.fileManager.$selectionSlicesByFileID.map { _ in () },
                manager.promptViewModel.$promptText.map { _ in () }
            )
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            for await _ in observations.first().values {}
        }

        /// Returns once each window projected the runtime's events so far, its summaries included.
        @MainActor
        private func waitForSummaryProjection(of windows: [WindowState], runtime: MCPDomainRuntime) async {
            let sequence = await runtime.workspaceStore.summarySnapshot().publicationSequence
            for window in windows {
                let projected = await window.waitUntilDomainWorkspaceProjectedForTesting(through: sequence)
                XCTAssertTrue(projected, "Window \(window.windowID) didn't project through \(sequence)")
            }
        }

        /// The tab as the runtime's canonical document of the workspace holds it.
        private func canonicalTab(
            _ tabID: UUID,
            of workspaceID: UUID,
            in runtime: MCPDomainRuntime
        ) async throws -> ComposeTabState {
            let snapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let document = try XCTUnwrap(snapshot).document
            let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: document.documentBytes)
            return try XCTUnwrap(workspace.composeTabs.first { $0.id == tabID })
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
        /// Binds the connection to `contextID` through `bind_context`, and fails the test if the bind
        /// doesn't succeed. A bind replies `workspace_authority_superseded`, with `retryable` set,
        /// when the window's workspace authority changes while the bind resolves it. As a client
        /// does, this calls again after the delay that reply names, up to three calls in all. Any
        /// other error fails the test.
        private func bindContext(_ connection: ProductionMCPConnection, contextID: UUID) async throws {
            for call in 1 ... 3 {
                let result = try await connection.client.callTool(name: "bind_context", arguments: [
                    "op": .string("bind"),
                    "context_id": .string(contextID.uuidString),
                    "_rawJSON": .bool(true)
                ])
                let text = toolText(result)
                guard result.isError != true else { return XCTFail(text) }
                let reply = try JSONDecoder().decode(BindContextResponse.self, from: XCTUnwrap(text.data(using: .utf8)))
                guard reply.error != nil else { return }
                guard reply.errorCode == "workspace_authority_superseded", reply.retryable == true, call < 3 else {
                    return XCTFail(text)
                }
                try await Task.sleep(for: .milliseconds(reply.retryAfterMilliseconds ?? 0))
            }
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
