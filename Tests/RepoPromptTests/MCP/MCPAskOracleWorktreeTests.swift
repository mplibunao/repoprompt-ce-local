import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class MCPAskOracleWorktreeTests: XCTestCase {
        func testOracleSendContextKeepsConversationOwnerSeparateFromDelegatedPackagingSource() throws {
            let childTabID = UUID()
            let childWorkspaceID = UUID()
            let childSessionID = UUID()
            let childRunID = UUID()
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceRunID = UUID()
            let delegationID = UUID()
            let sourceSelection = StoredSelection(
                selectedPaths: ["/tmp/source/Sources/Feature.swift"],
                codemapAutoEnabled: false
            )
            let sourceCapability = SelectedGitArtifactCapability(
                workspaceID: childWorkspaceID,
                workspaceDirectoryPath: "/tmp/workspace",
                gitDataRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: "_git_data",
                    fullPath: "/tmp/workspace/_git_data"
                ),
                creatorTabID: sourceTabID,
                sessionID: sourceSessionID,
                boundCheckouts: [],
                canonicalWorkspaceRootPaths: ["/tmp/source"]
            )
            let sourceReviewContext = FrozenPromptGitReviewContext(
                artifactCapability: sourceCapability,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
            let capturedSource = AgentRunOracleReviewSource.Captured(
                delegationID: delegationID,
                sourceTabID: sourceTabID,
                workspaceID: childWorkspaceID,
                sourceSelectionRevision: 42,
                promptText: "source prompt",
                selection: sourceSelection,
                lookupContext: .visibleWorkspace,
                reviewGitContext: sourceReviewContext,
                sourceAgentSessionID: sourceSessionID,
                sourceAgentRunID: sourceRunID,
                sourceWorktreeBindings: []
            )
            let delegated = DelegatedAgentRunOracleReviewContext(
                source: .captured(capturedSource),
                target: AgentRunOracleReviewTargetSnapshot(
                    tabID: childTabID,
                    workspaceID: childWorkspaceID,
                    agentSessionID: childSessionID,
                    activationID: UUID(),
                    expectedParentSessionID: sourceSessionID,
                    worktreeBindings: [],
                    validationFailure: nil
                ),
                targetRunID: childRunID
            )
            let packaging = try OracleViewModel.OracleSendPackagingContext(delegated: delegated)
            let context = OracleViewModel.OracleSendTabContext(
                tabID: childTabID,
                workspaceID: childWorkspaceID,
                origin: .askOracle,
                agentModeSessionID: childSessionID,
                agentModeRunID: childRunID,
                packaging: packaging
            )

            XCTAssertEqual(context.tabID, childTabID)
            XCTAssertEqual(context.agentModeSessionID, childSessionID)
            XCTAssertEqual(context.agentModeRunID, childRunID)
            XCTAssertEqual(context.packaging.sourceTabID, sourceTabID)
            XCTAssertEqual(context.packaging.sourceAgentSessionID, sourceSessionID)
            XCTAssertEqual(context.packaging.sourceAgentRunID, sourceRunID)
            XCTAssertEqual(context.packaging.selection, sourceSelection)
            XCTAssertEqual(context.packaging.provenance, .delegated(delegationID: delegationID))
            guard case let .delegated(artifactDelegation) = try XCTUnwrap(
                context.packaging.reviewGitContext.artifactCapability
            ).access else {
                return XCTFail("Expected delegated artifact capability")
            }
            XCTAssertEqual(artifactDelegation.sourceTabID, sourceTabID)
            XCTAssertEqual(artifactDelegation.targetTabID, childTabID)
            XCTAssertEqual(artifactDelegation.targetAgentSessionID, childSessionID)
            XCTAssertEqual(artifactDelegation.targetAgentRunID, childRunID)
            XCTAssertEqual(
                context.packaging.reviewGitContext.artifactDelegationConsumer,
                SelectedGitArtifactDelegationConsumer(
                    workspaceID: childWorkspaceID,
                    tabID: childTabID,
                    agentSessionID: childSessionID,
                    agentRunID: childRunID,
                    boundCheckouts: []
                )
            )
        }

        func testExplicitOracleContinuationRequiresExactAgentSessionAndRunOwner() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let owned = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID
            )
            let unownedLegacy = ChatSession(composeTabID: tabID)

            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: UUID()
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: UUID(),
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: nil
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
        }

        func testOracleLogLookupDoesNotAdoptLegacyOrSiblingRun() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let exact = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 1)
            )
            let newerSibling = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: UUID(),
                savedAt: Date(timeIntervalSince1970: 3)
            )
            let newestLegacy = ChatSession(
                composeTabID: tabID,
                savedAt: Date(timeIntervalSince1970: 4)
            )

            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling, exact],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                exact.id
            )
            XCTAssertNil(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
        }

        func testChildContextBuilderReviewEndsDelegatedReviewPackaging() async throws {
            let child = try await makeDelegatedReviewChild(name: "own-review-ends-delegation")
            let createdChatID = await child.window.oracleViewModel.startNewChatSession(
                name: "Own review",
                tabID: child.tabID,
                agentModeSessionID: child.sessionID,
                agentModeRunID: child.runID
            )
            let ownReviewChatID = try XCTUnwrap(createdChatID)
            let shortID = child.window.oracleViewModel.resolveSession(id: ownReviewChatID.uuidString)?.shortID ?? ""
            _ = try await runContextBuilderAnswer(on: child, mode: .review) {
                ChatSendReply(chatId: ownReviewChatID, shortId: shortID, mode: "review", response: "Own review", errors: nil)
            }
            let followUpSelection = child.selection(of: "ChildFollowUp.swift")
            try child.setSelection(followUpSelection)

            let packaging = try await askOracleReviewPackaging(on: child, chatID: ownReviewChatID)

            XCTAssertEqual(packaging.provenance, .direct)
            XCTAssertEqual(packaging.selection, followUpSelection)
        }

        func testDelegatedReviewPackagingPersistsUntilChildReviewReturns() async throws {
            struct ReviewGenerationFailed: Error {}
            let child = try await makeDelegatedReviewChild(name: "delegation-persists")
            let precedingSteps: [(label: String, run: @MainActor () async throws -> Void)] = [
                ("no context_builder call", {}),
                ("returned plan answer", {
                    _ = try await self.runContextBuilderAnswer(on: child, mode: .plan) {
                        ChatSendReply(chatId: UUID(), shortId: "", mode: "plan", response: "Plan", errors: nil)
                    }
                }),
                ("returned question answer", {
                    _ = try await self.runContextBuilderAnswer(on: child, mode: .chat) {
                        ChatSendReply(chatId: UUID(), shortId: "", mode: "chat", response: "Answer", errors: nil)
                    }
                }),
                ("review that throws", {
                    do {
                        _ = try await self.runContextBuilderAnswer(on: child, mode: .review) {
                            throw ReviewGenerationFailed()
                        }
                        XCTFail("Expected the review generation error")
                    } catch is ReviewGenerationFailed {}
                })
            ]

            for step in precedingSteps {
                try await step.run()
                let packaging = try await askOracleReviewPackaging(on: child, chatID: nil)
                XCTAssertEqual(packaging.provenance, .delegated(delegationID: child.delegationID), step.label)
                XCTAssertEqual(packaging.selection, child.launcherSelection, step.label)
            }
        }

        // MARK: - Delegated review child

        @MainActor
        private struct DelegatedReviewChild {
            let fixture: MCPOracleCompletionPolicyFixture
            let tabID: UUID
            let sessionID: UUID
            let runID: UUID
            let delegationID: UUID
            let launcherSelection: StoredSelection

            var window: WindowState {
                fixture.window
            }

            func selection(of fileName: String) -> StoredSelection {
                StoredSelection(
                    selectedPaths: [fixture.root.appendingPathComponent(fileName).path],
                    codemapAutoEnabled: false
                )
            }

            /// Oracle packaging re-reads the selection from the workspace's compose tab, so a change
            /// to the connection's stored snapshot would not be seen.
            func setSelection(_ selection: StoredSelection) throws {
                var tab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
                tab.selection = selection
                XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(tab, inWorkspaceID: fixture.workspaceID))
            }
        }

        /// Leaves what `agent_run op=start` leaves for a child's first run: the fixture's active tab as
        /// the launcher, a background child tab bound to the child's Agent session, a delegated review
        /// context for the exact session and run, and the child's MCP connection bound to that tab,
        /// session, and run.
        private func makeDelegatedReviewChild(name: String) async throws -> DelegatedReviewChild {
            let fixture = try await MCPOracleCompletionPolicyFixture.make(name: name)
            addTeardownBlock { await fixture.cleanup() }
            let window = fixture.window
            // The resolver reads this window's view model; a standalone one is never consulted.
            let agentModeViewModel = window.agentModeViewModel
            let sessionID = UUID()
            let runID = UUID()
            let delegationID = UUID()
            // A background tab, as `agent_run` creates: the window's live UI state belongs to the
            // active tab and can overwrite that tab's stored selection.
            let createdChildTab = await window.promptManager.createBackgroundComposeTab(
                strategy: .blank,
                name: "Child"
            )
            let childTabID = try XCTUnwrap(createdChildTab).id

            let childSession = await agentModeViewModel.ensureSessionReady(tabID: childTabID)
            XCTAssertNotNil(agentModeViewModel.test_installPersistentSessionBinding(
                sessionID: sessionID,
                on: childSession,
                compareAndSetInWorkspaceID: fixture.workspaceID
            ))
            agentModeViewModel.upsertSessionIndex(
                sessionID: sessionID,
                tabID: childTabID,
                name: "Child",
                lastUserMessageAt: nil,
                savedAt: Date(),
                lastRunStateRaw: AgentSessionRunState.running.rawValue,
                itemCount: 0,
                agentKindRaw: nil,
                agentModelRaw: nil,
                agentReasoningEffortRaw: nil,
                autoEditEnabled: false
            )
            // Activation clears the session's review contexts, so it comes before staging.
            try await agentModeViewModel.mcpActivateControlContext(
                forTabID: childTabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                startPending: true
            )
            addTeardownBlock {
                await agentModeViewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
            let child = DelegatedReviewChild(
                fixture: fixture,
                tabID: childTabID,
                sessionID: sessionID,
                runID: runID,
                delegationID: delegationID,
                launcherSelection: StoredSelection(
                    selectedPaths: [fixture.root.appendingPathComponent("Launcher.swift").path],
                    codemapAutoEnabled: false
                )
            )
            try agentModeViewModel.mcpStageAgentRunOracleReviewSource(
                .captured(.init(
                    delegationID: delegationID,
                    sourceTabID: fixture.tabID,
                    // Staging records a workspace mismatch unless this is the window's active workspace.
                    workspaceID: fixture.workspaceID,
                    sourceSelectionRevision: 1,
                    promptText: "launcher prompt",
                    selection: child.launcherSelection,
                    lookupContext: .visibleWorkspace,
                    reviewGitContext: .automaticOnly(base: "HEAD", workspaceRootPaths: [fixture.root.path]),
                    sourceAgentSessionID: nil,
                    sourceAgentRunID: nil,
                    sourceWorktreeBindings: []
                )),
                targetTabID: childTabID,
                targetSessionID: sessionID,
                expectedParentSessionID: nil
            )
            XCTAssertNotNil(agentModeViewModel.mcpBindPendingAgentRunOracleReviewContext(
                tabID: childTabID,
                runID: runID
            ))

            // `ask_oracle` takes its owner from the connection's snapshot. Without the session, or
            // with a run other than the bound one, the delegated lookup throws instead of packaging.
            let childTab = try XCTUnwrap(window.workspaceManager.composeTab(with: childTabID))
            window.mcpServer.tabContextByConnectionID[fixture.connectionID] = MCPServerViewModel.TabContextSnapshot(
                tabID: childTabID,
                windowID: window.windowID,
                workspaceID: fixture.workspaceID,
                promptText: childTab.promptText,
                selection: childTab.selection,
                selectedMetaPromptIDs: childTab.selectedMetaPromptIDs,
                tabName: childTab.name,
                runID: runID,
                activeAgentSessionID: sessionID,
                explicitlyBound: false
            )
            try child.setSelection(child.selection(of: "Child.swift"))
            return child
        }

        /// Passes a `context_builder` answer through the production closure, with `generate`
        /// standing in for discovery and the model.
        private func runContextBuilderAnswer(
            on child: DelegatedReviewChild,
            mode: HeadlessMode,
            generate: @escaping @MainActor @Sendable () async throws -> ChatSendReply
        ) async throws -> ChatSendReply {
            let mcpServer = child.window.mcpServer
            mcpServer.setContextBuilderFollowUpOverrideForTesting { _, _, _, _, _, _, _, _, _, _, _, _ in
                try await generate()
            }
            defer { mcpServer.setContextBuilderFollowUpOverrideForTesting(nil) }
            return try await mcpServer.runMCPPlanOrQuestionForTesting(
                child.window.contextBuilderAgentViewModel,
                WorkspaceSelectionIdentity(workspaceID: child.fixture.workspaceID, tabID: child.tabID),
                child.sessionID,
                child.runID,
                mode,
                "Review the child's change.",
                StoredSelection(),
                nil,
                .automaticOnly(base: "HEAD"),
                nil,
                nil,
                nil
            )
        }

        /// Sends a `review`-mode `ask_oracle` from the child's connection and returns the package
        /// it chose. A nil `chatID` starts a new chat.
        private func askOracleReviewPackaging(
            on child: DelegatedReviewChild,
            chatID: UUID?
        ) async throws -> OracleViewModel.OracleSendPackagingContext {
            var observedPackaging: OracleViewModel.OracleSendPackagingContext?
            child.window.mcpServer.setOracleChatSendOverrideForTesting { _, _, tabContext, _ in
                observedPackaging = tabContext?.packaging
                return ["chat_id": .string("packaging-test"), "response": .string("ok")]
            }
            defer { child.window.mcpServer.setOracleChatSendOverrideForTesting(nil) }
            var args: [String: Value] = [
                "message": .string("Which files did you receive?"),
                "mode": .string("review")
            ]
            if let chatID {
                args["chat_id"] = .string(chatID.uuidString)
            } else {
                args["new_chat"] = .bool(true)
            }
            let capturedArgs = args
            _ = try await ServerNetworkManager.$currentConnectionID.withValue(child.fixture.connectionID) {
                try await child.window.mcpServer.executeAskOracleForTesting(args: capturedArgs)
            }
            return try XCTUnwrap(observedPackaging)
        }
    }
#endif
