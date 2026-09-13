import Foundation
@testable import RepoPromptApp
import XCTest

/// `persistContextBuilderTimeoutResponse` suspends twice (autosave drain, session save) and
/// the user can delete or reorder chats in between; these tests pin that the write lands on
/// the chat it was asked about, or nowhere.
@MainActor
final class OracleContextBuilderTimeoutPersistenceTests: XCTestCase {
    private static var nextFixtureWindowID = -1400

    private static func allocateFixtureWindowID() -> Int {
        nextFixtureWindowID -= 1
        return nextFixtureWindowID
    }

    func testDeletingTheChatDuringSaveThrowsInsteadOfWritingAnotherChat() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()
        let decoy = ChatSession(workspaceID: fixture.workspace.id, composeTabID: fixture.tabID, name: "Decoy")

        do {
            try await fixture.oracleViewModel.persistContextBuilderTimeoutResponse(
                "partial answer",
                queryID: seeded.answerID,
                sessionID: seeded.session.id,
                saveSession: { session in
                    fixture.oracleViewModel.sessions = [decoy]
                    return try await fixture.oracleViewModel.chatData.saveChatSession(session, for: fixture.workspace)
                }
            )
            XCTFail("Expected missingExactQuery once the chat was deleted mid-save")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .missingExactQuery)
        }

        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [decoy.id])
        XCTAssertNil(fixture.oracleViewModel.sessions[0].fileURL)
        XCTAssertTrue(fixture.oracleViewModel.sessions[0].messages.isEmpty)
    }

    func testReorderingChatsDuringSaveStillUpdatesTheOriginalChat() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()
        let decoy = ChatSession(workspaceID: fixture.workspace.id, composeTabID: fixture.tabID, name: "Decoy")
        var savedURL: URL?

        try await fixture.oracleViewModel.persistContextBuilderTimeoutResponse(
            "partial answer",
            queryID: seeded.answerID,
            sessionID: seeded.session.id,
            saveSession: { session in
                fixture.oracleViewModel.sessions.insert(decoy, at: 0)
                if let index = fixture.oracleViewModel.sessions.firstIndex(where: { $0.id == seeded.session.id }) {
                    fixture.oracleViewModel.sessions[index].name = "Renamed while saving"
                }
                let url = try await fixture.oracleViewModel.chatData.saveChatSession(session, for: fixture.workspace)
                savedURL = url
                return url
            }
        )

        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [decoy.id, seeded.session.id])
        XCTAssertNil(fixture.oracleViewModel.sessions[0].fileURL)
        XCTAssertTrue(fixture.oracleViewModel.sessions[0].messages.isEmpty)

        let updated = fixture.oracleViewModel.sessions[1]
        XCTAssertEqual(updated.name, "Renamed while saving")
        XCTAssertEqual(updated.fileURL, savedURL)
        XCTAssertEqual(
            updated.messages.first(where: { $0.id == seeded.answerID })?.rawText,
            "partial answer"
        )
    }

    func testRemovingTheAnswerWhileAutosavesDrainThrows() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()
        // A resend drops the finalized answer from the same chat. Reloading a copy of the chat
        // that lacks the answer reproduces that from disk, and running it as a tracked autosave
        // lands it exactly while the drain is suspended.
        var resent = seeded.session
        resent.messages = seeded.session.messages.filter(\.isUser)
        let resentURL = try await fixture.oracleViewModel.chatData.saveChatSession(resent, for: fixture.workspace)
        fixture.oracleViewModel.scheduleTrackedAutosave(for: seeded.session) {
            await fixture.oracleViewModel.loadChatSession(from: resentURL)
        }

        do {
            try await fixture.oracleViewModel.persistContextBuilderTimeoutResponse(
                "partial answer",
                queryID: seeded.answerID,
                sessionID: seeded.session.id,
                saveSession: { session in
                    XCTFail("Nothing should be saved once the answer is gone")
                    return try await fixture.oracleViewModel.chatData.saveChatSession(session, for: fixture.workspace)
                }
            )
            XCTFail("Expected missingExactQuery once the answer was removed")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .missingExactQuery)
        }
    }

    func testRemovingTheAnswerWhileSavingThrowsAndRefreshesTheFile() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()
        var resent = seeded.session
        resent.messages = seeded.session.messages.filter(\.isUser)
        let resentURL = try await fixture.oracleViewModel.chatData.saveChatSession(resent, for: fixture.workspace)
        var resendLanded = false

        do {
            try await fixture.oracleViewModel.persistContextBuilderTimeoutResponse(
                "partial answer",
                queryID: seeded.answerID,
                sessionID: seeded.session.id,
                saveSession: { session in
                    // The resend lands once, while the first save is suspended; the stale snapshot
                    // is then written over it, which is the state the guard must detect. The
                    // awaited repair that follows must not be disturbed again.
                    if !resendLanded {
                        resendLanded = true
                        await fixture.oracleViewModel.loadChatSession(from: resentURL)
                    }
                    return try await fixture.oracleViewModel.chatData.saveChatSession(session, for: fixture.workspace)
                }
            )
            XCTFail("Expected missingExactQuery once the answer was removed during the save")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .missingExactQuery)
        }

        let live = try XCTUnwrap(fixture.oracleViewModel.sessions.first(where: { $0.id == seeded.session.id }))
        XCTAssertFalse(live.messages.contains(where: { $0.rawText.contains("partial answer") }))
    }

    func testATurnAddedWhileSavingSurvivesInTheTranscript() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()
        // Loading a copy of the chat stands in for the live store gaining a turn, so the copy must
        // carry the marked answer the way the live store already does at that point.
        var extended = seeded.session
        extended.messages = extended.messages.map { message in
            guard message.id == seeded.answerID else { return message }
            return StoredMessage(
                id: message.id,
                isUser: false,
                rawText: "partial answer",
                timestamp: message.timestamp,
                sequenceIndex: message.sequenceIndex,
                allowedFilePaths: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                modelName: nil
            )
        }
        extended.messages.append(
            StoredMessage(
                id: UUID(),
                isUser: true,
                rawText: "follow-up question",
                timestamp: Date(),
                sequenceIndex: 2,
                allowedFilePaths: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                modelName: nil
            )
        )
        let extendedURL = try await fixture.oracleViewModel.chatData.saveChatSession(extended, for: fixture.workspace)
        var turnLanded = false

        try await fixture.oracleViewModel.persistContextBuilderTimeoutResponse(
            "partial answer",
            queryID: seeded.answerID,
            sessionID: seeded.session.id,
            saveSession: { session in
                // The user's next turn lands while the first save is suspended; the corrective
                // save that follows must not be disturbed again.
                if !turnLanded {
                    turnLanded = true
                    await fixture.oracleViewModel.loadChatSession(from: extendedURL)
                }
                return try await fixture.oracleViewModel.chatData.saveChatSession(session, for: fixture.workspace)
            }
        )
        XCTAssertTrue(turnLanded)

        let live = try XCTUnwrap(fixture.oracleViewModel.sessions.first(where: { $0.id == seeded.session.id }))
        XCTAssertEqual(live.messages.count, 3)
        XCTAssertTrue(live.messages.contains(where: { $0.rawText == "follow-up question" }))

        // The corrective save is awaited, so the file already carries the added turn.
        let onDisk = try await fixture.oracleViewModel.chatData.loadChatSession(from: XCTUnwrap(live.fileURL))
        XCTAssertEqual(onDisk.messages.count, 3)
        XCTAssertTrue(onDisk.messages.contains(where: { $0.rawText == "follow-up question" }))
        XCTAssertTrue(onDisk.messages.contains(where: { $0.rawText == "partial answer" }))
    }

    func testDeletingTheChatDuringTheCorrectiveSaveThrows() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()
        var extended = seeded.session
        extended.messages = extended.messages.map { message in
            guard message.id == seeded.answerID else { return message }
            return StoredMessage(
                id: message.id,
                isUser: false,
                rawText: "partial answer",
                timestamp: message.timestamp,
                sequenceIndex: message.sequenceIndex,
                allowedFilePaths: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                modelName: nil
            )
        }
        extended.messages.append(
            StoredMessage(
                id: UUID(),
                isUser: true,
                rawText: "follow-up question",
                timestamp: Date(),
                sequenceIndex: 2,
                allowedFilePaths: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                modelName: nil
            )
        )
        let extendedURL = try await fixture.oracleViewModel.chatData.saveChatSession(extended, for: fixture.workspace)
        let decoy = ChatSession(workspaceID: fixture.workspace.id, composeTabID: fixture.tabID, name: "Decoy")
        var saveCount = 0

        do {
            try await fixture.oracleViewModel.persistContextBuilderTimeoutResponse(
                "partial answer",
                queryID: seeded.answerID,
                sessionID: seeded.session.id,
                saveSession: { session in
                    saveCount += 1
                    // A turn lands during the first save, which forces the corrective save; the
                    // chat is deleted while that second save is suspended.
                    if saveCount == 1 {
                        await fixture.oracleViewModel.loadChatSession(from: extendedURL)
                    } else {
                        fixture.oracleViewModel.sessions = [decoy]
                    }
                    return try await fixture.oracleViewModel.chatData.saveChatSession(session, for: fixture.workspace)
                }
            )
            XCTFail("Expected missingExactQuery once the chat was deleted during the corrective save")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .missingExactQuery)
        }

        XCTAssertEqual(saveCount, 2)
        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [decoy.id])
        XCTAssertNil(fixture.oracleViewModel.sessions[0].fileURL)
    }

    func testFinalizedAssistantContentReadsTheProcessedMessage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()
        let userID = try XCTUnwrap(seeded.session.messages.first(where: \.isUser)?.id)

        XCTAssertEqual(
            fixture.oracleViewModel.finalizedAssistantContent(for: seeded.answerID, in: seeded.session.id),
            "truncated"
        )
        XCTAssertNil(fixture.oracleViewModel.finalizedAssistantContent(for: userID, in: seeded.session.id))
        XCTAssertNil(fixture.oracleViewModel.finalizedAssistantContent(for: seeded.answerID, in: UUID()))
    }

    func testQueryScopedCancelIgnoresASessionWhoseActiveQueryDiffers() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.seedFinalizedExchange()

        // Nothing is streaming, so the active query is nil and a stale query id must not cancel.
        await fixture.oracleViewModel.cancelStreaming(in: seeded.session.id, ifActiveQueryIs: seeded.answerID)
        XCTAssertEqual(
            fixture.oracleViewModel.finalizedAssistantContent(for: seeded.answerID, in: seeded.session.id),
            "truncated"
        )
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
            .appendingPathComponent("OracleContextBuilderTimeoutPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tabID = UUID()
        workspace.customStoragePath = storageRoot
        workspace.composeTabs = [ComposeTabState(id: tabID)]
        workspace.activeComposeTabID = tabID
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        await composition.oracleViewModel.loadSessionsFromWorkspace()
        composition.oracleViewModel.sessions = []

        return Fixture(composition: composition, workspace: workspace, tabID: tabID, storageRoot: storageRoot)
    }

    @MainActor
    private struct Fixture {
        let composition: WindowStateComposition
        let workspace: WorkspaceModel
        let tabID: UUID
        let storageRoot: URL

        var oracleViewModel: OracleViewModel {
            composition.oracleViewModel
        }

        /// Saves a chat with one finalized question/answer pair to disk and loads it back, which is
        /// the only route that registers the answer in the view model's private message store.
        func seedFinalizedExchange() async throws -> (session: ChatSession, answerID: UUID) {
            let answerID = UUID()
            var session = ChatSession(workspaceID: workspace.id, composeTabID: tabID, name: "Seeded")
            session.messages = [
                StoredMessage(
                    id: UUID(),
                    isUser: true,
                    rawText: "question",
                    timestamp: Date(),
                    sequenceIndex: 0,
                    allowedFilePaths: nil,
                    promptTokens: nil,
                    completionTokens: nil,
                    cost: nil,
                    modelName: nil
                ),
                StoredMessage(
                    id: answerID,
                    isUser: false,
                    rawText: "truncated",
                    timestamp: Date(),
                    sequenceIndex: 1,
                    allowedFilePaths: nil,
                    promptTokens: nil,
                    completionTokens: nil,
                    cost: nil,
                    modelName: nil
                )
            ]
            let fileURL = try await oracleViewModel.chatData.saveChatSession(session, for: workspace)
            await oracleViewModel.loadChatSession(from: fileURL)
            let loaded = try XCTUnwrap(oracleViewModel.sessions.first(where: { $0.id == session.id }))
            return (loaded, answerID)
        }

        func cleanup() {
            oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }
}
