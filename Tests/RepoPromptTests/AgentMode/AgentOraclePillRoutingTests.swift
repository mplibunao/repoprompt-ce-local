import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentOraclePillRoutingTests: XCTestCase {
    func testExplicitRequestStateRejectsBlankStaleTabAndMismatchedSession() throws {
        let tabID = UUID()
        let otherTabID = UUID()
        let workspaceID = UUID()
        let session = ChatSession(workspaceID: workspaceID, composeTabID: tabID, name: "Exact Session")
        let otherSession = ChatSession(workspaceID: workspaceID, composeTabID: tabID, name: "Other Session")

        XCTAssertNil(
            AgentOraclePillLogic.explicitOpenRequest(
                chatID: "  \n ",
                workspaceID: workspaceID,
                tabID: tabID,
                generation: 1
            )
        )

        let request = try XCTUnwrap(
            AgentOraclePillLogic.explicitOpenRequest(
                chatID: session.id.uuidString.lowercased(),
                workspaceID: workspaceID,
                tabID: tabID,
                generation: 4,
                presentation: .generatedAnswerReadOnly
            )
        )
        XCTAssertEqual(request.presentation, .generatedAnswerReadOnly)
        XCTAssertTrue(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 5,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertNil(AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: session.id,
            isExplicit: true,
            currentWorkspaceID: UUID(),
            sameTabSessions: [session],
            eligibleSessions: [session],
            streamingSessionIDs: []
        ))
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: otherTabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: otherSession,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: UUID(),
                currentTabID: tabID
            )
        )
    }

    func testCompletedOracleHistorySurvivesRunAdvanceWithinSameAgentSession() {
        let workspaceID = UUID()
        let tabID = UUID()
        let agentID = UUID()
        let previousRunID = UUID()
        let nextRunID = UUID()
        let previous = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            agentModeSessionID: agentID,
            agentModeRunID: previousRunID,
            name: "Completed Oracle",
            messages: [StoredMessage(isUser: false, rawText: "Completed answer", sequenceIndex: 0)]
        )
        let otherAgent = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            agentModeSessionID: UUID(),
            agentModeRunID: nextRunID,
            name: "Other agent",
            messages: previous.messages
        )
        let legacy = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Unowned",
            messages: previous.messages
        )
        let sessions = [otherAgent, previous, legacy]
        let eligible = AgentOraclePillLogic.eligibleSessions(
            sessions: sessions,
            streamingSessionIDs: [],
            liveMessageCount: { _ in nil },
            activeAgentSessionID: agentID,
            activeRunID: nextRunID
        )

        XCTAssertEqual(eligible.map(\.id), [previous.id])
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(in: eligible, streamingSessionIDs: [])?.id,
            previous.id
        )
        XCTAssertEqual(AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: previous.id,
            isExplicit: false,
            currentWorkspaceID: workspaceID,
            sameTabSessions: sessions,
            eligibleSessions: eligible,
            streamingSessionIDs: []
        ), previous.id)
        XCTAssertEqual(AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: previous.id,
            in: eligible,
            streamingSessionIDs: []
        ), previous.id)
    }

    func testCurrentRunOracleDisplacesHistoryOnlyWhenRenderableOrStreaming() {
        let agentID = UUID()
        let runID = UUID()
        let history = ChatSession(
            agentModeSessionID: agentID,
            agentModeRunID: UUID(),
            name: "History",
            messages: [StoredMessage(isUser: false, rawText: "Answer", sequenceIndex: 0)]
        )
        let current = ChatSession(
            agentModeSessionID: agentID,
            agentModeRunID: runID,
            name: "Current"
        )

        for (name, streamingIDs, expectedID) in [
            ("empty current run keeps history", Set<UUID>(), history.id),
            ("streaming current run displaces history", Set([current.id]), current.id)
        ] {
            let eligible = AgentOraclePillLogic.eligibleSessions(
                sessions: [history, current],
                streamingSessionIDs: streamingIDs,
                liveMessageCount: { _ in nil },
                activeAgentSessionID: agentID,
                activeRunID: runID
            )
            XCTAssertEqual(eligible.map(\.id), [expectedID], name)
        }

        let eligible = AgentOraclePillLogic.eligibleSessions(
            sessions: [history, current],
            streamingSessionIDs: [],
            liveMessageCount: { $0 == current.id ? 1 : nil },
            activeAgentSessionID: agentID,
            activeRunID: runID
        )
        XCTAssertEqual(eligible.map(\.id), [current.id], "live message count displaces history")
        XCTAssertEqual(AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: history.id,
            in: eligible,
            streamingSessionIDs: []
        ), current.id)
    }

    func testOracleHistoryFallbackPreservesOwnerAndLegacyPrecedence() {
        let agentID = UUID()
        let foreignAgentID = UUID()
        let runID = UUID()
        let unmatchedRunID = UUID()
        let messages = [StoredMessage(isUser: false, rawText: "Answer", sequenceIndex: 0)]

        let history = ChatSession(
            agentModeSessionID: agentID,
            agentModeRunID: UUID(),
            name: "History",
            messages: messages
        )
        let runless = ChatSession(
            agentModeSessionID: agentID,
            name: "Runless",
            messages: messages
        )
        let unowned = ChatSession(name: "Unowned", messages: messages)
        let other = ChatSession(
            agentModeSessionID: foreignAgentID,
            agentModeRunID: runID,
            name: "Other",
            messages: messages
        )
        let foreignRunless = ChatSession(
            agentModeSessionID: foreignAgentID,
            name: "Foreign runless",
            messages: messages
        )
        let exact = ChatSession(
            agentModeSessionID: agentID,
            agentModeRunID: runID,
            name: "Exact",
            messages: messages
        )

        let cases: [(name: String, sessions: [ChatSession], agent: UUID?, run: UUID?, expected: [UUID])] = [
            ("runless precedes history", [history, runless, unowned, other], agentID, runID, [runless.id]),
            ("foreign exact does not block unowned", [other, unowned], agentID, runID, [unowned.id]),
            ("foreign exact alone is hidden", [other], agentID, runID, []),
            ("foreign runless does not block unowned", [foreignRunless, unowned], agentID, runID, [unowned.id]),
            ("run-only unmatched falls back to unowned", [history, other, unowned], nil, unmatchedRunID, [unowned.id]),
            ("run-only exact accepts its owner", [history, other, unowned], nil, runID, [other.id]),
            ("agent-only retains history", [history, other, unowned], agentID, nil, [history.id]),
            ("exact precedes every lower bucket", [runless, history, other, unowned, exact], agentID, runID, [exact.id]),
            ("agent-only includes runless and history", [history, runless, other, unowned], agentID, nil, [history.id, runless.id]),
            ("agent-only unowned fallback", [other, unowned], agentID, nil, [unowned.id]),
            ("agent-only foreign isolation", [other], agentID, nil, []),
            ("run-only accepts foreign runless", [history, foreignRunless, unowned], nil, runID, [foreignRunless.id]),
            ("run-only retains all owned runless", [runless, foreignRunless, unowned], nil, runID, [runless.id, foreignRunless.id]),
            ("run-only exact precedes runless", [foreignRunless, other, unowned], nil, runID, [other.id]),
            ("run-only has no arbitrary history fallback", [history, other], nil, unmatchedRunID, [])
        ]

        for item in cases {
            XCTAssertEqual(
                AgentOraclePillLogic.eligibleSessions(
                    sessions: item.sessions,
                    streamingSessionIDs: [],
                    liveMessageCount: { _ in nil },
                    activeAgentSessionID: item.agent,
                    activeRunID: item.run
                ).map(\.id),
                item.expected,
                item.name
            )
        }
    }

    func testMultipleEarlierRunsRetainHistoryAndSelectNewestSavedAnswer() {
        let agentID = UUID()
        let activeRunID = UUID()
        let messages = [StoredMessage(isUser: false, rawText: "Saved answer", sequenceIndex: 0)]
        let histories = [200.0, 300.0, 100.0].map { timestamp in
            ChatSession(
                agentModeSessionID: agentID,
                agentModeRunID: UUID(),
                name: "History \(timestamp)",
                savedAt: Date(timeIntervalSince1970: timestamp),
                messages: messages
            ).listStub()
        }

        let eligible = AgentOraclePillLogic.eligibleSessions(
            sessions: histories,
            streamingSessionIDs: [],
            liveMessageCount: { _ in nil },
            activeAgentSessionID: agentID,
            activeRunID: activeRunID
        )

        XCTAssertEqual(eligible.map(\.id), histories.map(\.id))
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(in: eligible, streamingSessionIDs: [])?.id,
            histories[1].id
        )
        XCTAssertEqual(AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: nil,
            in: eligible,
            streamingSessionIDs: []
        ), histories[1].id)
        XCTAssertEqual(AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: histories[2].id,
            in: eligible,
            streamingSessionIDs: []
        ), histories[2].id)
    }

    func testTranscriptActionPolicyMatchesPopoverPresentation() {
        XCTAssertEqual(
            AgentOraclePillLogic.transcriptActionPolicy(for: .standard),
            .standard
        )
        XCTAssertEqual(
            AgentOraclePillLogic.transcriptActionPolicy(for: .generatedAnswerReadOnly),
            .nonMutating
        )
    }

    func testExactInMemoryResolutionUsesUUIDOrShortIDInsteadOfLatestSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let exact = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Exact Session",
            savedAt: Date(timeIntervalSince1970: 100),
            messages: [StoredMessage(isUser: false, rawText: "exact", sequenceIndex: 0)]
        )
        let newer = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Newer Session",
            savedAt: Date(timeIntervalSince1970: 200),
            messages: [StoredMessage(isUser: false, rawText: "newer", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [exact, newer]
        let didLoadExactSessionMessages = await fixture.oracleViewModel.ensureSessionMessagesLoaded(exact.id)
        XCTAssertTrue(didLoadExactSessionMessages)

        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: fixture.oracleViewModel.sessions(forTabID: fixture.tabID),
                streamingSessionIDs: [newer.id]
            )?.id,
            newer.id
        )

        let byUUID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: exact.id.uuidString.lowercased(),
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byUUID?.id, exact.id)

        let byShortID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: exact.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byShortID?.id, exact.id)
        XCTAssertEqual(fixture.oracleViewModel.messagesSnapshot(for: exact.id).count, 1)
    }

    func testLatestStreamingSessionDoesNotFallbackToStaleCompletedSession() {
        let workspaceID = UUID()
        let tabID = UUID()
        let olderStreaming = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Older Streaming",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let staleCompleted = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Stale Completed",
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let newerStreaming = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Newer Streaming",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let sessions = [olderStreaming, staleCompleted, newerStreaming]

        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id]
            )?.id,
            newerStreaming.id
        )
        XCTAssertEqual(
            AgentOraclePillLogic.latestStreamingSession(
                in: sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id]
            )?.id,
            newerStreaming.id
        )
        XCTAssertNil(AgentOraclePillLogic.latestStreamingSession(
            in: sessions,
            streamingSessionIDs: []
        ))
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: sessions,
                streamingSessionIDs: []
            )?.id,
            staleCompleted.id
        )
    }

    func testExactPersistedResolutionHydratesAndRegistersUUIDAndShortID() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let persisted = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Persisted Exact Session",
            savedAt: Date(timeIntervalSince1970: 100),
            messages: [StoredMessage(isUser: false, rawText: "persisted", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persisted,
            for: fixture.workspace
        )
        let distractor = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Newer Distractor",
            savedAt: Date(timeIntervalSince1970: 300),
            messages: [StoredMessage(isUser: false, rawText: "distractor", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [distractor]

        let byShortID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persisted.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byShortID?.id, persisted.id)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == persisted.id })?.messages.count,
            1
        )
        XCTAssertEqual(fixture.oracleViewModel.messagesSnapshot(for: persisted.id).count, 1)

        fixture.oracleViewModel.sessions = [distractor]
        let byUUID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persisted.id.uuidString.lowercased(),
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byUUID?.id, persisted.id)
        XCTAssertTrue(fixture.oracleViewModel.sessions.contains(where: { $0.id == persisted.id }))

        let collidingShortID = "shared-oracle-chat"
        let persistedCollision = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Persisted Collision",
            messages: [StoredMessage(isUser: false, rawText: "same-tab collision", sequenceIndex: 0)],
            shortID: collidingShortID
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persistedCollision,
            for: fixture.workspace
        )
        let wrongTabCollision = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.otherTabID,
            name: "Wrong Tab Collision",
            messages: [StoredMessage(isUser: false, rawText: "wrong-tab collision", sequenceIndex: 0)],
            shortID: collidingShortID
        )
        fixture.oracleViewModel.sessions = [distractor, wrongTabCollision]

        let collisionResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: collidingShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(collisionResult?.id, persistedCollision.id)
        XCTAssertEqual(collisionResult?.composeTabID, fixture.tabID)
    }

    func testExactPersistedResolutionRejectsWrongTabAndUnknownWithoutLatestFallback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let wrongTab = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.otherTabID,
            name: "Wrong Tab Session",
            messages: [StoredMessage(isUser: false, rawText: "wrong tab", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            wrongTab,
            for: fixture.workspace
        )
        let latest = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Latest Session",
            savedAt: Date(timeIntervalSince1970: 500),
            messages: [StoredMessage(isUser: false, rawText: "latest", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [latest]

        let wrongTabResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: wrongTab.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(wrongTabResult)

        let unknownResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: UUID().uuidString,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(unknownResult)
        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [latest.id])

        let persistedBeforeReassignment = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Reassigned Session",
            messages: [StoredMessage(isUser: false, rawText: "persisted tab", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persistedBeforeReassignment,
            for: fixture.workspace
        )
        var reassignedInMemory = persistedBeforeReassignment
        reassignedInMemory.composeTabID = fixture.otherTabID
        fixture.oracleViewModel.sessions = [latest, reassignedInMemory]

        let staleDiskResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persistedBeforeReassignment.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(staleDiskResult)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == persistedBeforeReassignment.id })?.composeTabID,
            fixture.otherTabID
        )
    }

    func testExactResolutionRejectsSameTabShortIDCollisionsInMemoryAndOnDisk() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let sharedShortID = "same-tab-collision"
        let first = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "First Collision",
            messages: [StoredMessage(isUser: false, rawText: "first", sequenceIndex: 0)],
            shortID: sharedShortID
        )
        let second = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Second Collision",
            messages: [StoredMessage(isUser: false, rawText: "second", sequenceIndex: 0)],
            shortID: sharedShortID
        )

        fixture.oracleViewModel.sessions = [first, second]
        let inMemoryCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(inMemoryCollision)

        _ = try await fixture.oracleViewModel.chatData.saveChatSession(first, for: fixture.workspace)
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(second, for: fixture.workspace)
        fixture.oracleViewModel.sessions = [first]
        let mixedCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(mixedCollision)

        fixture.oracleViewModel.sessions = []
        let persistedCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(persistedCollision)
    }

    func testExactResolutionRejectsWorkspaceMismatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let session = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Workspace Bound",
            messages: [StoredMessage(isUser: false, rawText: "workspace", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [session]

        let wrongWorkspace = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: session.shortID,
            workspaceID: UUID(),
            tabID: fixture.tabID
        )
        XCTAssertNil(wrongWorkspace)
    }

    private static var nextFixtureWindowID = -1200

    private static func allocateFixtureWindowID() -> Int {
        nextFixtureWindowID -= 1
        return nextFixtureWindowID
    }

    private func makeFixture() async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let composition = WindowStateCompositionFactory.make(
            windowID: Self.allocateFixtureWindowID(),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOraclePillRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tabID = UUID()
        let otherTabID = UUID()
        workspace.customStoragePath = storageRoot
        workspace.composeTabs = [ComposeTabState(id: tabID), ComposeTabState(id: otherTabID)]
        workspace.activeComposeTabID = tabID
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        await composition.oracleViewModel.loadSessionsFromWorkspace()
        composition.oracleViewModel.sessions = []

        return Fixture(
            composition: composition,
            workspace: workspace,
            tabID: tabID,
            otherTabID: otherTabID,
            storageRoot: storageRoot
        )
    }

    @MainActor
    private struct Fixture {
        let composition: WindowStateComposition
        let workspace: WorkspaceModel
        let tabID: UUID
        let otherTabID: UUID
        let storageRoot: URL

        var oracleViewModel: OracleViewModel {
            composition.oracleViewModel
        }

        func cleanup() {
            oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }
}
