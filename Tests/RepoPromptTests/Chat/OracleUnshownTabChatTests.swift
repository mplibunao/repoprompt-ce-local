@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Oracle chats linked to a tab of a workspace the window doesn't show, in a runtime-backed
    /// window that shows another workspace.
    @MainActor
    final class OracleUnshownTabChatTests: XCTestCase {
        private var fixture: RuntimeBackedWorkspaceFixture!

        override func setUp() async throws {
            try await super.setUp()
            fixture = try await RuntimeBackedWorkspaceFixture(name: "OracleUnshownTabChatTests")
        }

        override func tearDown() async throws {
            await fixture.tearDown()
            fixture = nil
            try await super.tearDown()
        }

        /// A chat is saved in its workspace's chat folder, so a background chat for an unshown tab
        /// must name that tab's workspace, and it starts from that tab's stored selection.
        func testBackgroundChatForUnshownTabBelongsToAndStartsFromThatTabsWorkspace() async throws {
            let metaPromptID = UUID()
            let parkedTab = ComposeTabState(
                name: "Parked",
                selection: StoredSelection(selectedPaths: ["/tmp/parked/plan.swift"]),
                selectedMetaPromptIDs: [metaPromptID]
            )
            let window = try await openWindow(parkedTab: parkedTab)

            let session = try await window.oracle.createSession(
                named: "Parked chat",
                tabID: parkedTab.id,
                activateInUI: false,
                setActiveForTab: false
            )

            XCTAssertEqual(session.workspaceID, window.parkedWorkspaceID)
            XCTAssertEqual(session.composeTabID, parkedTab.id)
            XCTAssertEqual(session.selectedFilePaths, ["/tmp/parked/plan.swift"])
            XCTAssertEqual(session.selectedPromptIDs, [metaPromptID])
        }

        /// A chat whose tab is in a workspace the window doesn't show keeps that tab. A check that
        /// only saw the shown workspace would add a blank duplicate tab there.
        func testChatLinkedToUnshownTabKeepsItsTab() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let window = try await openWindow(parkedTab: parkedTab)
            let shownTabIDs = window.manager.activeWorkspace?.composeTabs.map(\.id)
            let session = ChatSession(
                workspaceID: window.parkedWorkspaceID,
                composeTabID: parkedTab.id,
                name: "Parked chat"
            )

            let tabID = await window.oracle.ensureTabForSession(session)

            XCTAssertEqual(tabID, parkedTab.id)
            XCTAssertEqual(window.manager.activeWorkspace?.composeTabs.map(\.id), shownTabIDs)
        }

        /// A background chat deleted while its tab's link to it is written isn't returned as
        /// created, and the tab doesn't keep a link to it.
        func testBackgroundChatDeletedWhileItsTabIsLinkedIsNotCreated() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let window = try await openWindow(parkedTab: parkedTab)
            let gateway = window.manager.contentGateway
            addTeardownBlock { @MainActor in
                gateway.commitSubmissionWillBeginHandlerForTesting = nil
            }
            var deletedSessionID: UUID?
            gateway.commitSubmissionWillBeginHandlerForTesting = { workspaceID in
                guard workspaceID == window.parkedWorkspaceID,
                      deletedSessionID == nil,
                      let session = window.oracle.sessions.first(where: { $0.composeTabID == parkedTab.id })
                else { return }
                deletedSessionID = session.id
                await window.oracle.deleteSession(session)
            }

            let createdID = await window.oracle.startNewChatSession(
                name: "Parked chat",
                tabID: parkedTab.id,
                activateInUI: false,
                setActiveForTab: true
            )

            XCTAssertNotNil(deletedSessionID)
            XCTAssertNil(createdID)
            let tab = try await gateway.readComposeTab(
                WorkspaceSelectionIdentity(workspaceID: window.parkedWorkspaceID, tabID: parkedTab.id),
                source: "test.readParkedTabLink",
                capturingLiveUIState: false
            )
            XCTAssertNil(tab.activeChatSessionID)
        }

        /// Creating a background chat fails when its tab refuses the link to it, instead of returning
        /// the window's current chat. Here another write advanced the tab's document first, and the
        /// tab keeps its active chat.
        func testBackgroundChatWhoseTabLinkIsRefusedIsNotCreated() async throws {
            let parkedTab = ComposeTabState(name: "Parked")
            let window = try await openWindow(parkedTab: parkedTab)
            let gateway = window.manager.contentGateway
            let identity = WorkspaceSelectionIdentity(workspaceID: window.parkedWorkspaceID, tabID: parkedTab.id)
            let createdCurrentChatID = await window.oracle.startNewChatSession(name: "Current chat")
            let currentChatID = try XCTUnwrap(createdCurrentChatID)
            XCTAssertEqual(window.oracle.currentSessionID, currentChatID)
            addTeardownBlock { @MainActor in
                gateway.commitSubmissionWillBeginHandlerForTesting = nil
            }
            var advancedTheDocument = false
            gateway.commitSubmissionWillBeginHandlerForTesting = { workspaceID in
                guard workspaceID == window.parkedWorkspaceID, !advancedTheDocument else { return }
                advancedTheDocument = true
                _ = try? await gateway.mutateComposeTab(
                    identity,
                    source: "test.renameParkedTabFirst",
                    persistence: .working
                ) { tab in
                    tab.name = "Renamed first"
                }
            }

            do {
                let session = try await window.oracle.createSession(
                    named: "Parked chat",
                    tabID: parkedTab.id,
                    activateInUI: false,
                    setActiveForTab: true
                )
                XCTFail("A refused link returned chat \(session.id) as created")
            } catch {
                XCTAssertEqual((error as? ChatToolError)?.code, .internalError, "Unexpected error: \(error)")
            }

            XCTAssertTrue(advancedTheDocument)
            XCTAssertEqual(window.oracle.currentSessionID, currentChatID)
            XCTAssertFalse(window.oracle.sessions.contains { $0.composeTabID == parkedTab.id })
            let tab = try await gateway.readComposeTab(
                identity,
                source: "test.readRefusedParkedTabLink",
                capturingLiveUIState: false
            )
            XCTAssertEqual(tab.name, "Renamed first")
            XCTAssertNil(tab.activeChatSessionID)
        }

        private struct OpenWindow {
            let manager: WorkspaceManagerViewModel
            let oracle: OracleViewModel
            let parkedWorkspaceID: UUID
        }

        /// A window that shows "Alpha Shown" while a workspace holding `parkedTab` sits unshown in
        /// its catalog.
        private func openWindow(parkedTab: ComposeTabState) async throws -> OpenWindow {
            let shownTab = ComposeTabState(
                name: "Shown",
                selection: StoredSelection(selectedPaths: ["/tmp/shown/main.swift"])
            )
            let shown = WorkspaceModel(
                name: "Alpha Shown",
                repoPaths: [fixture.storageRoot.appendingPathComponent("shown-root").path],
                composeTabs: [shownTab],
                activeComposeTabID: shownTab.id
            )
            let parked = WorkspaceModel(
                name: "Parked",
                repoPaths: [fixture.storageRoot.appendingPathComponent("parked-root").path],
                lastUsed: Date(timeIntervalSinceReferenceDate: 690_000_000),
                composeTabs: [parkedTab],
                activeComposeTabID: parkedTab.id
            )
            try fixture.writeWorkspace(shown)
            try fixture.writeWorkspace(parked)
            try fixture.writeLegacyIndex([shown, parked])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "oracle-unshown-tab")
            let (manager, _) = await fixture.makeProjectedManager(windowID: -7301, runtime: runtime)
            XCTAssertEqual(manager.activeWorkspaceID, shown.id, "The window must show the other workspace")
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let oracle = OracleViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                promptViewModel: manager.promptViewModel,
                workspaceManager: manager,
                chatData: ChatDataService()
            )
            return OpenWindow(manager: manager, oracle: oracle, parkedWorkspaceID: parked.id)
        }
    }
#endif
