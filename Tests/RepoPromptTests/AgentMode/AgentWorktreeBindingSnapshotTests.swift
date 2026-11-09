#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    /// The scalar worktree-binding lookup resolves against a snapshot of only the target session's
    /// tabs, while the plural lookup builds the full snapshot of every tab.
    @MainActor
    final class AgentWorktreeBindingSnapshotTests: XCTestCase {
        @MainActor
        private final class Fixture {
            let viewModel: AgentModeViewModel
            let manager: WorkspaceManagerViewModel
            let prompt: PromptViewModel
            let sessionID: UUID
            let targetTabID: UUID
            let liveSession: AgentModeViewModel.TabSession

            init(viewModel: AgentModeViewModel, manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
                self.viewModel = viewModel
                self.manager = manager
                self.prompt = prompt
                let sessionID = UUID()
                self.sessionID = sessionID
                let target = ComposeTabState(name: "Target", activeAgentSessionID: sessionID)
                targetTabID = target.id
                let unrelated = ComposeTabState(name: "Unrelated", activeAgentSessionID: UUID())
                let workspace = WorkspaceModel(
                    name: "Binding snapshot",
                    repoPaths: [],
                    ephemeralFlag: true,
                    composeTabs: [unrelated, target],
                    activeComposeTabID: target.id
                )
                manager.workspaces = [workspace]
                manager.activeWorkspace = workspace
                viewModel.workspaceManager = manager

                liveSession = AgentModeViewModel.TabSession(tabID: target.id)
                viewModel.test_installLiveSession(liveSession)
                liveSession.testInstallPersistentSessionBinding(sessionID: sessionID)
                liveSession.hasLoadedPersistedState = true
            }

            var targetComposeIndex: Int {
                manager.workspaces[0].composeTabs.firstIndex { $0.id == targetTabID }!
            }

            func installSessionIndex(_ tabIDBySessionID: [UUID: UUID]) {
                let entries = Dictionary(uniqueKeysWithValues: tabIDBySessionID.map { sessionID, tabID in
                    (sessionID, AgentSessionIndexEntry(
                        id: sessionID,
                        tabID: tabID,
                        name: "Indexed",
                        lastUserMessageAt: nil,
                        savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        lastRunStateRaw: nil,
                        itemCount: 0,
                        agentKindRaw: nil,
                        agentModelRaw: nil,
                        agentReasoningEffortRaw: nil,
                        autoEditEnabled: false,
                        parentSessionID: nil,
                        hasUnknownConversationContent: false,
                        isMCPOriginated: false,
                        worktreeBindingSummaries: [],
                        activeWorktreeMergeSummaries: []
                    ))
                })
                let workspace = manager.workspaces[0]
                let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
                viewModel.test_installSessionIndexSnapshot(
                    entries,
                    owner: owner,
                    latestOwner: owner,
                    activeWorkspace: workspace
                )
            }
        }

        func testTargetedScalarReadMatchesFullAuthorityWithFreshConflicts() {
            let cases: [(label: String, arrange: (Fixture) -> Void, expected: AgentSessionWorktreeBindingState)] = [
                ("hydrated live claim", { _ in }, .hydrated([])),
                ("unhydrated live claim", { $0.liveSession.hasLoadedPersistedState = false }, .unhydrated),
                ("duplicate stashed claim", { fixture in
                    fixture.manager.workspaces[0].stashedTabs.append(
                        StashedTab(tab: ComposeTabState(activeAgentSessionID: fixture.sessionID))
                    )
                }, .unavailable),
                ("duplicate claim in another workspace", { fixture in
                    fixture.manager.workspaces.append(WorkspaceModel(
                        name: "Other",
                        repoPaths: [],
                        ephemeralFlag: true,
                        composeTabs: [ComposeTabState(activeAgentSessionID: fixture.sessionID)]
                    ))
                }, .unavailable),
                ("second live claimant", { fixture in
                    let second = AgentModeViewModel.TabSession(tabID: UUID())
                    fixture.viewModel.test_installLiveSession(second)
                    second.testInstallPersistentSessionBinding(sessionID: fixture.sessionID)
                }, .unavailable),
                ("target tab's persisted claim changed to another session", { fixture in
                    fixture.manager.workspaces[0].composeTabs[fixture.targetComposeIndex].activeAgentSessionID = UUID()
                }, .unavailable),
                ("earlier persisted tab with the target's ID claims another session", { fixture in
                    // With no live claim, only the later persisted claim makes the target's tab a
                    // candidate, so the earlier conflicting claim is read in a second pass.
                    fixture.liveSession.testInstallPersistentSessionBinding(sessionID: nil)
                    fixture.manager.workspaces.insert(WorkspaceModel(
                        name: "Earlier",
                        repoPaths: [],
                        ephemeralFlag: true,
                        stashedTabs: [StashedTab(tab: ComposeTabState(id: fixture.targetTabID, activeAgentSessionID: UUID()))]
                    ), at: 0)
                }, .unavailable),
                ("indexed fallback to an unclaimed compose tab", { fixture in
                    fixture.liveSession.testInstallPersistentSessionBinding(sessionID: nil)
                    fixture.manager.workspaces[0].composeTabs[fixture.targetComposeIndex].activeAgentSessionID = nil
                    fixture.installSessionIndex([fixture.sessionID: fixture.targetTabID])
                }, .unhydrated),
                ("indexed tab claimed by another session", { fixture in
                    fixture.liveSession.testInstallPersistentSessionBinding(sessionID: nil)
                    fixture.manager.workspaces[0].composeTabs[fixture.targetComposeIndex].activeAgentSessionID = UUID()
                    fixture.installSessionIndex([fixture.sessionID: fixture.targetTabID])
                }, .unavailable)
            ]

            for testCase in cases {
                let fixture = makeFixture()
                testCase.arrange(fixture)
                XCTAssertEqual(
                    fixture.viewModel.worktreeBindingState(forAgentSessionID: fixture.sessionID, tabID: fixture.targetTabID),
                    testCase.expected,
                    "scalar: \(testCase.label)"
                )
                XCTAssertEqual(
                    fixture.viewModel.worktreeBindingStates(forAgentSessionIDs: [fixture.sessionID])[fixture.sessionID],
                    testCase.expected,
                    "full snapshot: \(testCase.label)"
                )
            }
        }

        func testTargetedScalarReadOmitsUnrelatedMaterializedClaims() throws {
            let fixture = makeFixture()
            let otherSessionID = UUID()
            for index in 0 ..< 3 {
                fixture.manager.workspaces[0].composeTabs.append(
                    ComposeTabState(name: "Unrelated \(index)", activeAgentSessionID: UUID())
                )
            }
            fixture.manager.workspaces[0].stashedTabs = [
                StashedTab(tab: ComposeTabState(activeAgentSessionID: UUID())),
                StashedTab(tab: ComposeTabState(id: fixture.targetTabID, activeAgentSessionID: otherSessionID))
            ]
            let unrelatedLive = AgentModeViewModel.TabSession(tabID: fixture.manager.workspaces[0].composeTabs[0].id)
            fixture.viewModel.test_installLiveSession(unrelatedLive)
            unrelatedLive.testInstallPersistentSessionBinding(
                sessionID: fixture.manager.workspaces[0].composeTabs[0].activeAgentSessionID
            )
            var index: [UUID: UUID] = [:]
            for tab in fixture.manager.workspaces[0].composeTabs {
                try index[XCTUnwrap(tab.activeAgentSessionID)] = tab.id
            }
            fixture.installSessionIndex(index)

            fixture.viewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
            XCTAssertEqual(
                fixture.viewModel.worktreeBindingState(forAgentSessionID: fixture.sessionID, tabID: fixture.targetTabID),
                .unavailable,
                "another session's claim on the target tab must keep the target ambiguous"
            )
            XCTAssertEqual(
                fixture.viewModel.test_persistentBindingResolutionBuildCount,
                0,
                "the scalar read must not build the full snapshot"
            )

            let snapshot = fixture.viewModel.test_persistentBindingResolutionSnapshot(forSessionIDs: [fixture.sessionID])
            let target = fixture.targetTabID
            XCTAssertEqual(snapshot.liveClaimsByTabID, [target: fixture.sessionID])
            XCTAssertEqual(snapshot.workspaceClaimsByTabID, [target: [fixture.sessionID, otherSessionID]])
            XCTAssertEqual(snapshot.claimedTabIDsBySessionID, [fixture.sessionID: [target], otherSessionID: [target]])
            XCTAssertEqual(snapshot.conflictingTabIDsBySessionID, [fixture.sessionID: [target], otherSessionID: [target]])
            XCTAssertEqual(snapshot.indexedTabIDBySessionID, [fixture.sessionID: target])
            XCTAssertEqual(snapshot.composeTabIDs, [target])
        }

        private func makeFixture() -> Fixture {
            let fileManager = WorkspaceFilesViewModel()
            let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: fileManager,
                apiSettingsViewModel: apiSettings,
                windowID: -1,
                settingsManager: WindowSettingsManager(windowID: -1)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: prompt,
                performInitialWorkspaceActivation: false
            )
            let viewModel = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Binding snapshot tests must not start a Codex session")
            })
            return Fixture(viewModel: viewModel, manager: manager, prompt: prompt)
        }
    }
#endif
