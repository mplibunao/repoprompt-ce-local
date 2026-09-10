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
                let url = try await fixture.oracleViewModel.chatData.saveChatSession(session, for: fixture.workspace)
                savedURL = url
                return url
            }
        )

        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [decoy.id, seeded.session.id])
        XCTAssertNil(fixture.oracleViewModel.sessions[0].fileURL)
        XCTAssertTrue(fixture.oracleViewModel.sessions[0].messages.isEmpty)

        let updated = fixture.oracleViewModel.sessions[1]
        XCTAssertEqual(updated.fileURL, savedURL)
        XCTAssertEqual(
            updated.messages.first(where: { $0.id == seeded.answerID })?.rawText,
            "partial answer"
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
                ),
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
