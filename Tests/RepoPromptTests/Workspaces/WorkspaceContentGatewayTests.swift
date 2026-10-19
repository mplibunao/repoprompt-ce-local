import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// Runs the gateway in a runtime-backed window that shows one workspace while a second, parked
    /// workspace sits unshown in its catalog.
    @MainActor
    final class WorkspaceContentGatewayTests: XCTestCase {
        private var fixture: RuntimeBackedWorkspaceFixture!

        override func setUp() async throws {
            try await super.setUp()
            fixture = try await RuntimeBackedWorkspaceFixture(name: "WorkspaceContentGatewayTests")
        }

        override func tearDown() async throws {
            await fixture.tearDown()
            fixture = nil
            try await super.tearDown()
        }

        func testMetadataEditPreservesUnshownComposeAndStashedPayloads() async throws {
            let plan = ComposeTabState(
                name: "Plan",
                lastModified: Date(timeIntervalSinceReferenceDate: 690_000_000),
                isPinned: true,
                activeChatSessionID: UUID(),
                activeAgentSessionID: UUID(),
                selection: StoredSelection(
                    selectedPaths: ["/tmp/parked/plan.swift"],
                    slices: ["/tmp/parked/notes.swift": [LineRange(start: 3, end: 9)]]
                ),
                promptText: "Finish the parked plan"
            )
            let notes = ComposeTabState(
                name: "Notes",
                lastModified: Date(timeIntervalSinceReferenceDate: 690_000_010),
                promptText: "Second tab"
            )
            let fork = StashedTab(
                tab: ComposeTabState(
                    name: "Fork",
                    lastModified: Date(timeIntervalSinceReferenceDate: 690_000_020),
                    isPinned: true,
                    activeAgentSessionID: UUID(),
                    promptText: "Forked session"
                ),
                stashedAt: Date(timeIntervalSinceReferenceDate: 690_000_100)
            )
            let idea = StashedTab(
                tab: ComposeTabState(
                    name: "Idea",
                    lastModified: Date(timeIntervalSinceReferenceDate: 690_000_030),
                    activeChatSessionID: UUID(),
                    promptText: "Old idea"
                ),
                stashedAt: Date(timeIntervalSinceReferenceDate: 690_000_200)
            )
            let parked = parkedWorkspace(composeTabs: [plan, notes], activeTabID: notes.id, stashedTabs: [fork, idea])
            let window = try await openWindow(windowID: -7101, parked: parked)

            let receipt = try await window.manager.contentGateway.mutateWorkspace(
                parked.id,
                source: "test.rename",
                persistence: .saved
            ) { $0.name = "Parked Renamed" }

            let savedBytes = try Data(contentsOf: fixture.workspaceFileURL(for: parked))
            let reopened = try JSONDecoder().decode(WorkspaceModel.self, from: savedBytes)
            XCTAssertEqual(reopened.name, "Parked Renamed")
            XCTAssertEqual(reopened.composeTabs, parked.composeTabs)
            XCTAssertEqual(reopened.activeComposeTabID, notes.id)
            XCTAssertEqual(reopened.stashedTabs, parked.stashedTabs)
            guard case let .committed(_, digest, changedTabIDs) = receipt else {
                return XCTFail("An edit to an unshown workspace commits canonically; got \(receipt)")
            }
            XCTAssertEqual(digest, DomainContentDigest.sha256(savedBytes))
            XCTAssertEqual(changedTabIDs, [])
        }

        func testConflictingTabEditDoesNotReplaceCanonicalWinner() async throws {
            let parkedTab = ComposeTabState(name: "Parked", promptText: "Base")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7102, parked: parked)
            let shownIdentity = WorkspaceSelectionIdentity(
                workspaceID: window.shown.id,
                tabID: window.shown.composeTabs[0].id
            )
            var unsavedShownTab = try XCTUnwrap(window.manager.composeTab(for: shownIdentity))
            unsavedShownTab.promptText = "Unsaved shown prompt"
            XCTAssertTrue(window.manager.updateComposeTabStoredOnly(unsavedShownTab, inWorkspaceID: window.shown.id))

            let gate = ArrivalGate()
            let gateway = interceptedGateway(for: window, afterCanonicalRead: { await gate.arriveAndWaitForRelease() })
            let parkedIdentity = WorkspaceSelectionIdentity(workspaceID: parked.id, tabID: parkedTab.id)
            let losingEdit = Task { @MainActor in
                try await gateway.mutateComposeTab(
                    parkedIdentity,
                    source: "test.losingEdit",
                    persistence: .working
                ) { $0.promptText = "Losing edit" }
            }
            await gate.waitForArrival()

            let peer = DomainWorkspaceAuthorityClient(store: window.runtime.workspaceStore, windowID: -7199)
            let baselineSnapshot = await peer.canonicalWorkspaceSnapshot(parked.id)
            let baseline = try XCTUnwrap(baselineSnapshot)
            var winner = try decodedModel(baseline)
            winner.composeTabs[0].promptText = "Winning edit"
            let winningOutcome = try await peer.replaceWorking(
                winner,
                fileURL: baseline.document.fileURL,
                expectedWorkspaceRevision: baseline.revisions.workingRevision
            )
            XCTAssertEqual(winningOutcome.disposition, .applied)
            await gate.release()

            do {
                _ = try await losingEdit.value
                XCTFail("An edit read at a stale revision must not commit")
            } catch let error as DomainWorkspaceAuthorityOperationError {
                XCTAssertEqual(error.outcome.disposition, .conflict)
                XCTAssertEqual(error.outcome.errorCode, .stateConflict)
            }
            let canonicalSnapshot = await peer.canonicalWorkspaceSnapshot(parked.id)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            XCTAssertEqual(canonical.document.contentDigest, winningOutcome.resultingDigest)
            XCTAssertEqual(try decodedModel(canonical).composeTabs.first?.promptText, "Winning edit")
            XCTAssertNotEqual(window.manager.workspace(withID: parked.id)?.composeTabs.first?.promptText, "Losing edit")
            XCTAssertEqual(window.manager.composeTab(for: shownIdentity)?.promptText, "Unsaved shown prompt")
        }

        func testEditRefusedWhenDecodeLosesStashedTabs() async throws {
            struct Row {
                let name: String
                /// Appends the stashed entry the app decode loses and returns the tab IDs it loses.
                let appendLostEntry: (_ stashedTabs: inout [Any], _ parkedTab: ComposeTabState, _ kept: StashedTab) throws
                    -> Set<UUID>
            }
            let rows = [
                Row(name: "wrapper without stashedAt") { stashedTabs, _, kept in
                    // The app decode rejects the wrapper and then drops the whole stashed array,
                    // including the well-formed fork.
                    let malformedTabID = UUID()
                    stashedTabs.append([
                        "id": UUID().uuidString,
                        "tab": ["id": malformedTabID.uuidString, "name": "Malformed"]
                    ])
                    return [kept.tab.id, malformedTabID]
                },
                Row(name: "stashed tab with a compose tab's ID") { stashedTabs, parkedTab, _ in
                    // Normalization drops a stashed tab whose ID a compose tab already uses.
                    let colliding = StashedTab(
                        tab: ComposeTabState(id: parkedTab.id, name: "Colliding fork", promptText: "Stashed copy"),
                        stashedAt: Date(timeIntervalSinceReferenceDate: 690_000_100)
                    )
                    try stashedTabs.append(JSONSerialization.jsonObject(with: JSONEncoder().encode(colliding)))
                    return [parkedTab.id]
                }
            ]

            for (index, row) in rows.enumerated() {
                if index > 0 {
                    try await resetFixture()
                }
                let parkedTab = ComposeTabState(name: "Parked")
                let kept = StashedTab(
                    tab: ComposeTabState(name: "Kept fork", isPinned: true),
                    stashedAt: Date(timeIntervalSinceReferenceDate: 690_000_000)
                )
                let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id, stashedTabs: [kept])
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(parked)) as? [String: Any]
                )
                var stashedTabs = object["stashedTabs"] as? [Any] ?? []
                let lostTabIDs = try row.appendLostEntry(&stashedTabs, parkedTab, kept)
                object["stashedTabs"] = stashedTabs
                let parkedBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                let window = try await openWindow(windowID: -7103, parked: parked, parkedDocument: parkedBytes)
                let fileURL = fixture.workspaceFileURL(for: parked)
                let canonicalBefore = await window.runtime.workspaceStore.canonicalWorkspaceSnapshot(parked.id)

                do {
                    _ = try await window.manager.contentGateway.mutateWorkspace(
                        parked.id,
                        source: "test.rename",
                        persistence: .saved
                    ) { $0.name = "Parked Renamed" }
                    XCTFail("\(row.name): a decode that lost listed tabs must not be written back")
                } catch let error as WorkspaceContentGatewayError {
                    XCTAssertEqual(
                        error,
                        .decodeLostTabs(workspaceID: parked.id, tabIDs: lostTabIDs),
                        row.name
                    )
                }
                XCTAssertEqual(window.manager.domainWorkspaceAuthorityIssue?.workspaceID, parked.id, row.name)
                XCTAssertEqual(
                    window.manager.domainWorkspaceAuthorityIssue?.diagnostic,
                    WorkspaceContentGatewayError.decodeLostTabsDiagnostic,
                    row.name
                )
                XCTAssertEqual(try Data(contentsOf: fileURL), parkedBytes, row.name)
                let canonicalAfter = await window.runtime.workspaceStore.canonicalWorkspaceSnapshot(parked.id)
                XCTAssertEqual(canonicalAfter?.document.documentBytes, parkedBytes, row.name)
                XCTAssertEqual(canonicalAfter?.revisions, canonicalBefore?.revisions, row.name)
            }
        }

        func testGatewayEditThenRenameInSameWindowKeepsBoth() async throws {
            let parkedTab = ComposeTabState(name: "Parked", promptText: "Before the gateway edit")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7104, parked: parked)
            let identity = WorkspaceSelectionIdentity(workspaceID: parked.id, tabID: parkedTab.id)

            let write = try await window.manager.contentGateway.mutateComposeTab(
                identity,
                source: "test.prompt",
                persistence: .working
            ) { $0.promptText = "Gateway edit" }
            guard case .committed = write.receipt else {
                return XCTFail("An edit to an unshown workspace commits canonically; got \(write.receipt)")
            }

            let canonical = try await renameAndReadCanonical(window, parked.id, to: "Parked Renamed")
            XCTAssertEqual(canonical.name, "Parked Renamed")
            XCTAssertEqual(canonical.composeTabs.first { $0.id == parkedTab.id }?.promptText, "Gateway edit")
        }

        func testSavedEditOfShownActiveTabReachesSavedDocumentAndLivePrompt() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7106, parked: parked)
            let shownTabID = window.shown.composeTabs[0].id
            let prompt = window.manager.promptViewModel
            try prompt.loadComposeTabsFromWorkspace(
                XCTUnwrap(window.manager.workspace(withID: window.shown.id)),
                syncPromptText: true
            )
            XCTAssertEqual(prompt.activeComposeTabID, shownTabID)
            // Typing that no save capture has copied into the stored tab yet.
            prompt.promptText = "Typed live"

            let write = try await window.manager.contentGateway.mutateComposeTab(
                WorkspaceSelectionIdentity(workspaceID: window.shown.id, tabID: shownTabID),
                source: "test.prompt",
                persistence: .saved
            ) { $0.promptText += " + gateway" }
            guard case .committed = write.receipt else {
                return XCTFail("A saved edit of the shown workspace awaits its save; got \(write.receipt)")
            }

            XCTAssertEqual(prompt.promptText, "Typed live + gateway")
            let saved = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: Data(contentsOf: fixture.workspaceFileURL(for: window.shown))
            )
            XCTAssertEqual(saved.composeTabs.first { $0.id == shownTabID }?.promptText, "Typed live + gateway")
        }

        func testAcceptedWriteKeepsNewerRevisionRecordedDuringSubmit() async throws {
            let parkedTab = ComposeTabState(name: "Parked", promptText: "Before the gateway edit")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7107, parked: parked)
            let windowCopy = try XCTUnwrap(window.manager.workspace(withID: parked.id))
            let newerRevisions = DomainRevisionState(workingRevision: 1000, savedRevision: 1000, dirtyRevision: nil)
            let gateway = interceptedGateway(for: window, duringSubmit: {
                // A later write reached the window while the submit was in flight.
                window.manager.applyDomainAuthorityBaseline(
                    workspaceID: parked.id,
                    revisions: newerRevisions,
                    digest: "newer-baseline",
                    health: .writable,
                    catalogRevision: 0
                )
            })

            let write = try await gateway.mutateComposeTab(
                WorkspaceSelectionIdentity(workspaceID: parked.id, tabID: parkedTab.id),
                source: "test.prompt",
                persistence: .working
            ) { $0.promptText = "Gateway edit" }
            guard case .committed = write.receipt else {
                return XCTFail("The authority accepted the write; got \(write.receipt)")
            }

            XCTAssertEqual(window.manager.workspace(withID: parked.id), windowCopy)
            let recorded = window.manager.contentGatewayCommittedState(for: parked.id)
            XCTAssertEqual(recorded?.revisions, newerRevisions)
            XCTAssertEqual(recorded?.digest, "newer-baseline")
        }

        func testLocalEditDuringSubmitAndGatewayEditBothReachLaterSave() async throws {
            let parkedTab = ComposeTabState(name: "Parked", promptText: "Before the gateway edit")
            let notesTab = ComposeTabState(name: "Notes")
            let parked = parkedWorkspace(composeTabs: [parkedTab, notesTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7108, parked: parked)
            let gateway = interceptedGateway(for: window, duringSubmit: {
                let notes = WorkspaceSelectionIdentity(workspaceID: parked.id, tabID: notesTab.id)
                guard var tab = window.manager.composeTab(for: notes) else { return }
                tab.name = "Renamed during submit"
                window.manager.updateComposeTabStoredOnly(tab, inWorkspaceID: parked.id)
            })

            let probe = EditProbe()
            let receipt = try await gateway.mutateWorkspace(
                parked.id,
                source: "test.edit",
                persistence: .working
            ) { workspace in
                probe.runs += 1
                let created = ComposeTabState(name: "Created by the gateway")
                probe.createdTabID = probe.createdTabID ?? created.id
                workspace.composeTabs.append(created)
                if let index = workspace.composeTabs.firstIndex(where: { $0.id == parkedTab.id }) {
                    workspace.composeTabs[index].promptText = "Gateway edit"
                }
            }
            guard case .committed = receipt else {
                return XCTFail("The authority accepted the write; got \(receipt)")
            }
            XCTAssertEqual(probe.runs, 1, "The edit runs once")
            let createdTabID = try XCTUnwrap(probe.createdTabID)
            XCTAssertEqual(
                window.manager.workspace(withID: parked.id)?.composeTabs.map(\.id),
                [parkedTab.id, notesTab.id, createdTabID],
                "The window's copy holds the created tab under its committed ID"
            )

            let canonical = try await renameAndReadCanonical(window, parked.id, to: "Parked Renamed")
            XCTAssertEqual(canonical.name, "Parked Renamed")
            XCTAssertEqual(canonical.composeTabs.map(\.id), [parkedTab.id, notesTab.id, createdTabID])
            XCTAssertEqual(canonical.composeTabs.first { $0.id == parkedTab.id }?.promptText, "Gateway edit")
            XCTAssertEqual(canonical.composeTabs.first { $0.id == notesTab.id }?.name, "Renamed during submit")
        }

        func testEditDuringSwitchAwayFromShownWorkspaceCommitsCanonically() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7109, parked: parked)
            let shownIdentity = WorkspaceSelectionIdentity(
                workspaceID: window.shown.id,
                tabID: window.shown.composeTabs[0].id
            )
            // This hook holds the switch after it installed the target and before it restores the
            // target's UI.
            let gate = ArrivalGate()
            window.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { _ in
                await gate.arriveAndWaitForRelease()
            }
            // The edit starts when the switch begins loading its target, while the window still
            // shows the workspace it leaves, and gets its first turn at the load's suspension.
            let probe = EditProbe()
            window.manager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting { phase in
                guard phase == .loadingTargetWorkspace, probe.task == nil else { return }
                probe.task = Task { @MainActor in
                    try await window.manager.contentGateway.mutateComposeTab(
                        shownIdentity,
                        source: "test.prompt",
                        persistence: .working
                    ) { tab in
                        probe.ran = true
                        tab.promptText = "Edited during the switch"
                    }
                }
            }
            let target = try XCTUnwrap(window.manager.workspace(withID: parked.id))
            // With saveState off, the switch publishes nothing for the workspace it leaves.
            let switchTask = Task { @MainActor in
                await window.manager.switchWorkspace(to: target, saveState: false)
            }
            await gate.waitForArrival()
            let editTask = try XCTUnwrap(probe.task)
            await yieldMainActor()
            XCTAssertFalse(probe.ran, "The edit must wait while the switch replaces the shown workspace")
            await gate.release()

            let switchResult = await switchTask.value
            XCTAssertEqual(switchResult, .switched)
            let write = try await editTask.value
            guard case .committed = write.receipt else {
                return XCTFail("After the switch the workspace is unshown and commits canonically; got \(write.receipt)")
            }
            let canonical = try await canonicalModel(window, window.shown.id)
            XCTAssertEqual(
                canonical.composeTabs.first { $0.id == shownIdentity.tabID }?.promptText,
                "Edited during the switch"
            )
        }

        func testEditDuringSwitchRecoveryWaitsAndCommitsCanonically() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7112, parked: parked)
            let parkedIdentity = WorkspaceSelectionIdentity(workspaceID: parked.id, tabID: parkedTab.id)
            // Holds the switch after it installed the parked workspace.
            let hydrationGate = ArrivalGate()
            window.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { _ in
                await hydrationGate.arriveAndWaitForRelease()
            }
            let target = try XCTUnwrap(window.manager.workspace(withID: parked.id))
            let switchTask = Task { @MainActor in
                await window.manager.switchWorkspace(to: target, saveState: false)
            }
            await hydrationGate.waitForArrival()
            XCTAssertEqual(window.manager.activeWorkspaceID, parked.id)

            // Cancelling the switch sends it into recovery, which retargets it to the workspace it
            // left and starts its preparation again. This hook holds it there, while the window still
            // names the parked workspace as active and the activity no longer does.
            let recoveryGate = ArrivalGate()
            window.manager.setWorkspaceSwitchReadinessDidInvalidateHandlerForTesting {
                await recoveryGate.arriveAndWaitForRelease()
            }
            switchTask.cancel()
            await hydrationGate.release()
            await recoveryGate.waitForArrival()
            XCTAssertEqual(window.manager.activeWorkspaceSwitch?.phase, .preparing)
            XCTAssertEqual(window.manager.activeWorkspaceSwitch?.targetWorkspaceID, window.shown.id)
            XCTAssertEqual(window.manager.activeWorkspaceID, parked.id)

            let probe = EditProbe()
            let editTask = Task { @MainActor in
                try await window.manager.contentGateway.mutateComposeTab(
                    parkedIdentity,
                    source: "test.prompt",
                    persistence: .working
                ) { tab in
                    probe.ran = true
                    tab.promptText = "Edited during recovery"
                }
            }
            await yieldMainActor()
            XCTAssertFalse(probe.ran, "The edit must wait while recovery replaces the active workspace")
            await recoveryGate.release()

            _ = await switchTask.value
            XCTAssertEqual(window.manager.activeWorkspaceID, window.shown.id, "Recovery returns to the workspace it left")
            let write = try await editTask.value
            guard case .committed = write.receipt else {
                return XCTFail("After recovery the workspace is unshown and commits canonically; got \(write.receipt)")
            }
            let canonical = try await canonicalModel(window, parked.id)
            XCTAssertEqual(canonical.composeTabs.first?.promptText, "Edited during recovery")
        }

        func testEditDuringSwitchConfirmationGoesToShownCopyWithoutWaiting() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let window = try await openWindow(windowID: -7110, parked: parked)
            let shownIdentity = WorkspaceSelectionIdentity(
                workspaceID: window.shown.id,
                tabID: window.shown.composeTabs[0].id
            )
            // An active session makes the switch ask for confirmation, and it waits there.
            let sessions = ActiveSessionStub()
            window.manager.registerSwitchSessionProvider(sessions)
            let target = try XCTUnwrap(window.manager.workspace(withID: parked.id))
            let switchTask = Task { @MainActor in
                await window.manager.requestWorkspaceSwitch(to: target)
            }
            await sessions.waitUntilAsked()
            let confirmation = try XCTUnwrap(window.manager.pendingSwitchConfirmation)

            let probe = EditProbe()
            let editTask = Task { @MainActor in
                try await window.manager.contentGateway.mutateComposeTab(
                    shownIdentity,
                    source: "test.prompt",
                    persistence: .working
                ) { tab in
                    probe.ran = true
                    tab.promptText = "Edited during confirmation"
                }
            }
            await yieldMainActor()
            XCTAssertTrue(probe.ran, "An edit during the confirmation dialog must not wait for the switch")
            window.manager.resolveSwitchConfirmation(id: confirmation.id, allow: false)

            guard case .cancelled = await switchTask.value else {
                return XCTFail("Declining the confirmation cancels the switch")
            }
            let write = try await editTask.value
            guard case .pendingLocal = write.receipt else {
                return XCTFail("The edit goes to the shown copy; got \(write.receipt)")
            }
            XCTAssertEqual(window.manager.composeTab(for: shownIdentity)?.promptText, "Edited during confirmation")
        }

        func testSwitchWaitEndsOnCancellationAndWhenTheGatewayCloses() async throws {
            struct Row {
                let name: String
                let endWait: @MainActor (_ gateway: WorkspaceContentGateway, _ edit: Task<WorkspaceComposeTabWrite, Error>) -> Void
                let isExpectedError: (Error) -> Bool
            }
            let rows = [
                Row(
                    name: "edit task cancelled",
                    endWait: { _, edit in edit.cancel() },
                    isExpectedError: { $0 is CancellationError }
                ),
                Row(
                    name: "gateway invalidated as its window closes",
                    endWait: { gateway, _ in gateway.invalidate() },
                    isExpectedError: { ($0 as? WorkspaceContentGatewayError) == .gatewayClosed }
                )
            ]

            for (index, row) in rows.enumerated() {
                if index > 0 {
                    try await resetFixture()
                }
                let parkedTab = ComposeTabState(name: "Parked")
                let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
                let window = try await openWindow(windowID: -7111, parked: parked)
                let shownIdentity = WorkspaceSelectionIdentity(
                    workspaceID: window.shown.id,
                    tabID: window.shown.composeTabs[0].id
                )
                let gate = ArrivalGate()
                window.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { _ in
                    await gate.arriveAndWaitForRelease()
                }
                let target = try XCTUnwrap(window.manager.workspace(withID: parked.id))
                let switchTask = Task { @MainActor in
                    await window.manager.switchWorkspace(to: target, saveState: false)
                }
                await gate.waitForArrival()

                let probe = EditProbe()
                let editTask = Task { @MainActor in
                    defer { probe.finished = true }
                    return try await window.manager.contentGateway.mutateComposeTab(
                        shownIdentity,
                        source: "test.prompt",
                        persistence: .working
                    ) { tab in
                        probe.ran = true
                        tab.promptText = "Never applied"
                    }
                }
                await yieldMainActor()
                XCTAssertFalse(probe.finished, "\(row.name): the edit waits while the switch is held")
                row.endWait(window.manager.contentGateway, editTask)
                await yieldMainActor()
                XCTAssertTrue(probe.finished, "\(row.name): the wait ends before the switch does")
                await gate.release()
                _ = await switchTask.value

                switch await editTask.result {
                case .success:
                    XCTFail("\(row.name): the edit must not run")
                case let .failure(error):
                    XCTAssertTrue(row.isExpectedError(error), "\(row.name): unexpected error \(error)")
                }
                XCTAssertFalse(probe.ran, row.name)
            }
        }

        func testLoadSnapshotDiagnosticReportsOneWindowsCountsAndResets() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let parked = parkedWorkspace(composeTabs: [parkedTab], activeTabID: parkedTab.id)
            let shown = try writeCatalog(parked: parked)
            let runtime = try await fixture.makeRuntime(profileIdentifier: "content-gateway-diagnostics")
            let window = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(window)
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            let manager = window.workspaceManager
            await manager.awaitInitialized()
            let target = try XCTUnwrap([shown, parked].first {
                $0.id != manager.activeWorkspaceID && manager.workspaceSummary(withID: $0.id) != nil
            })
            _ = try await diagnosticsPayload(windowID: window.windowID, reset: true)

            _ = try await manager.contentGateway.readWorkspaceContent(target.id, source: "test.diagnostics")
            let counted = try await diagnosticsPayload(windowID: window.windowID, reset: true)
            let cleared = try await diagnosticsPayload(windowID: window.windowID, reset: false)

            XCTAssertEqual(counted["ok"] as? Bool, true)
            XCTAssertEqual((counted["window_id"] as? NSNumber)?.intValue, window.windowID)
            let workspaces = try XCTUnwrap(counted["workspaces"] as? [[String: Any]])
            XCTAssertEqual(workspaces.map { $0["workspace_id"] as? String }, [target.id.uuidString])
            XCTAssertEqual((workspaces.first?["loads"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((workspaces.first?["decodes"] as? NSNumber)?.intValue, 1)
            let sources = try XCTUnwrap(workspaces.first?["sources"] as? [[String: Any]])
            XCTAssertEqual(sources.map { $0["source"] as? String }, ["test.diagnostics"])
            XCTAssertEqual((cleared["workspaces"] as? [Any])?.count, 0)
            XCTAssertEqual((cleared["total_loads"] as? NSNumber)?.intValue, 0)
        }

        // MARK: - Helpers

        @MainActor
        private final class EditProbe {
            var ran = false
            var runs = 0
            var finished = false
            var createdTabID: UUID?
            var task: Task<WorkspaceComposeTabWrite, Error>?
        }

        /// Reports one active session, so a requested switch stops at its confirmation dialog.
        @MainActor
        private final class ActiveSessionStub: WorkspaceSwitchSessionProvider {
            private var wasAsked = false
            private var askedWaiters: [CheckedContinuation<Void, Never>] = []

            func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
                wasAsked = true
                askedWaiters.forEach { $0.resume() }
                askedWaiters.removeAll()
                return [WorkspaceSwitchSessionItem(
                    id: "agent",
                    count: 1,
                    singularLabel: "agent run",
                    pluralLabel: "agent runs"
                )]
            }

            func cancelSwitchSessions() async {}

            /// Returns after the switch asked for active sessions, which it does right before it
            /// shows the confirmation in the same main-actor turn.
            func waitUntilAsked() async {
                guard !wasAsked else { return }
                await withCheckedContinuation { askedWaiters.append($0) }
            }
        }

        /// A gateway for `window` whose backend runs `afterCanonicalRead` once, after its first
        /// canonical read, and `duringSubmit` once the authority answered a submit.
        private func interceptedGateway(
            for window: OpenWindow,
            afterCanonicalRead: (@MainActor () async -> Void)? = nil,
            duringSubmit: (@MainActor () -> Void)? = nil
        ) -> WorkspaceContentGateway {
            let backend = SubmitInterceptingBackend(
                client: DomainWorkspaceAuthorityClient(store: window.runtime.workspaceStore, windowID: window.windowID)
            )
            backend.afterCanonicalRead = afterCanonicalRead
            backend.afterSubmit = duringSubmit
            return WorkspaceContentGateway(manager: window.manager, backend: backend)
        }

        /// The production backend, with a hook that runs once after its first canonical read and a
        /// hook that runs once the authority answered a submit.
        @MainActor
        private final class SubmitInterceptingBackend: WorkspaceContentBackend {
            private let backend: DomainWorkspaceContentBackend
            /// Runs after the read returns and before the gateway decodes it, then clears itself.
            var afterCanonicalRead: (@MainActor () async -> Void)?
            var afterSubmit: (@MainActor () -> Void)?

            init(client: DomainWorkspaceAuthorityClient) {
                backend = DomainWorkspaceContentBackend(client: client)
            }

            func canonicalDocument(for workspaceID: UUID) async -> WorkspaceContentDocument? {
                let document = await backend.canonicalDocument(for: workspaceID)
                if let hook = afterCanonicalRead {
                    afterCanonicalRead = nil
                    await hook()
                }
                return document
            }

            func readOverlayDocument(for workspaceID: UUID) async -> WorkspaceContentDocument? {
                await backend.readOverlayDocument(for: workspaceID)
            }

            func commit(
                _ workspace: WorkspaceModel,
                fileURL: URL,
                expectedRevision: UInt64,
                expectedDigest: String,
                persistence: WorkspaceContentPersistence
            ) async -> WorkspaceContentCommitResult {
                let result = await backend.commit(
                    workspace,
                    fileURL: fileURL,
                    expectedRevision: expectedRevision,
                    expectedDigest: expectedDigest,
                    persistence: persistence
                )
                afterSubmit?()
                return result
            }
        }

        private struct OpenWindow {
            let windowID: Int
            let runtime: MCPDomainRuntime
            let manager: WorkspaceManagerViewModel
            let shown: WorkspaceModel
        }

        private func shownWorkspace() -> WorkspaceModel {
            let tab = ComposeTabState(name: "Shown", promptText: "Shown prompt")
            return WorkspaceModel(
                name: "Alpha Shown",
                repoPaths: [fixture.storageRoot.appendingPathComponent("shown-root").path],
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
        }

        private func parkedWorkspace(
            composeTabs: [ComposeTabState],
            activeTabID: UUID,
            stashedTabs: [StashedTab] = []
        ) -> WorkspaceModel {
            WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 690_000_000),
                name: "Parked",
                repoPaths: [fixture.storageRoot.appendingPathComponent("parked-root").path],
                lastUsed: Date(timeIntervalSinceReferenceDate: 690_000_000),
                composeTabs: composeTabs,
                activeComposeTabID: activeTabID,
                stashedTabs: stashedTabs
            )
        }

        /// Writes "Alpha Shown", `parked` as `parkedDocument` when one is given, and an index that
        /// lists both, and returns the shown workspace.
        private func writeCatalog(parked: WorkspaceModel, parkedDocument: Data? = nil) throws -> WorkspaceModel {
            let shown = shownWorkspace()
            try fixture.writeWorkspace(shown)
            if let parkedDocument {
                try fixture.writeWorkspaceDocument(parkedDocument, workspaceID: parked.id, name: parked.name)
            } else {
                try fixture.writeWorkspace(parked)
            }
            try fixture.writeLegacyIndex([shown, parked])
            return shown
        }

        /// A window that shows "Alpha Shown" while `parked` sits in its catalog unshown.
        private func openWindow(
            windowID: Int,
            parked: WorkspaceModel,
            parkedDocument: Data? = nil
        ) async throws -> OpenWindow {
            let shown = try writeCatalog(parked: parked, parkedDocument: parkedDocument)
            let runtime = try await fixture.makeRuntime(profileIdentifier: "content-gateway")
            let (manager, _) = await fixture.makeProjectedManager(windowID: windowID, runtime: runtime)
            XCTAssertEqual(manager.activeWorkspaceID, shown.id, "The window must show the other workspace")
            XCTAssertNotNil(manager.workspaceSummary(withID: parked.id), "The parked workspace must be in the catalog")
            return OpenWindow(windowID: windowID, runtime: runtime, manager: manager, shown: shown)
        }

        /// Replaces the fixture with a fresh one, so a table row gets its own storage root and runtime.
        private func resetFixture() async throws {
            await fixture.tearDown()
            fixture = try await RuntimeBackedWorkspaceFixture(name: "WorkspaceContentGatewayTests")
        }

        private func decodedModel(_ snapshot: DomainWorkspaceSnapshot) throws -> WorkspaceModel {
            try JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
        }

        /// The workspace's canonical document, decoded.
        private func canonicalModel(_ window: OpenWindow, _ workspaceID: UUID) async throws -> WorkspaceModel {
            let snapshot = await window.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            return try decodedModel(XCTUnwrap(snapshot))
        }

        /// Renames the workspace through the window's ordinary whole-model save of its own copy,
        /// waits for that save to reach the authority, and returns the canonical document it left.
        private func renameAndReadCanonical(
            _ window: OpenWindow,
            _ workspaceID: UUID,
            to newName: String
        ) async throws -> WorkspaceModel {
            let subscription = await window.runtime.workspaceStore.subscribe()
            let local = try XCTUnwrap(window.manager.workspace(withID: workspaceID))
            window.manager.renameWorkspace(local, newName: newName)
            let renameSaved = await waitForEvent(in: subscription.events) {
                $0.kind == .savedDocumentCommitted && $0.workspaceID == workspaceID
            }
            XCTAssertTrue(renameSaved, "The rename's save never reached the authority")
            return try await canonicalModel(window, workspaceID)
        }

        /// Gives tasks waiting on the main actor ten turns, so a check that one hasn't run yet
        /// follows the turns it would have run in.
        private func yieldMainActor() async {
            for _ in 0 ..< 10 {
                await Task.yield()
            }
        }

        private func diagnosticsPayload(windowID: Int, reset: Bool) async throws -> [String: Any] {
            let result = await ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("workspace_content_load_snapshot"),
                    "window_id": .int(windowID),
                    "reset": .bool(reset)
                ]
            )
            let text = try XCTUnwrap(result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.first)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        /// Waits for a matching event. A match returns immediately, and the deadline only limits how
        /// long a missing event can hold up the test.
        private func waitForEvent(
            in events: AsyncStream<DomainWorkspaceEvent>,
            timeout: Duration = .seconds(10),
            matching predicate: @escaping @Sendable (DomainWorkspaceEvent) -> Bool
        ) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await event in events where predicate(event) {
                        return true
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }
    }

    /// Holds the operation that arrives, such as a gateway read or a workspace switch, until the
    /// test releases it.
    private actor ArrivalGate {
        private var arrived = false
        private var released = false
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWaitForRelease() async {
            arrived = true
            arrivalWaiters.forEach { $0.resume() }
            arrivalWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitForArrival() async {
            guard !arrived else { return }
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }
#endif
