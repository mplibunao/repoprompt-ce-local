import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderFollowUpFinalizationMonitorTests: XCTestCase {
    private var originalMCPAutoStart = false
    private var chatWorkspaceRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        chatWorkspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderFollowUpFinalizationMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
        await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)
    }

    override func tearDown() async throws {
        await ChatDataService.test_setWorkspaceRootOverride(nil)
        try? FileManager.default.removeItem(at: chatWorkspaceRoot)
        GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
        try await super.tearDown()
    }

    func testInactivityTimeoutPreservesPartialResponseAndAddsMarker() async throws {
        let clock = ContextBuilderFollowUpFinalizationTestClock()
        let cancellationRecorder = ContextBuilderFollowUpCancellationRecorder()
        let finalizationGate = ContextBuilderFollowUpCancellationGate()
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }

        let result = try await ContextBuilderFollowUpFinalizationMonitor.wait(
            activityEvents: events,
            configuration: ContextBuilderFollowUpFinalizationConfiguration(
                overallTimeout: 100,
                inactivityTimeout: 10,
                checkInterval: 10
            ),
            clock: { clock.now() },
            sleep: { seconds in
                clock.advance(by: seconds)
                await Task.yield()
            },
            waitForFinalization: {
                try await finalizationGate.wait()
            },
            partialResponse: {
                "Partial answer"
            },
            cancelStreaming: {
                await cancellationRecorder.record()
            }
        )

        guard case let .timedOut(timeout) = result else {
            return XCTFail("Expected a typed timeout result")
        }
        XCTAssertEqual(timeout.partialText, "Partial answer")
        XCTAssertEqual(
            timeout.marker,
            "[RepoPrompt: response ended after 10 s without stream activity; content above is partial]"
        )
        XCTAssertEqual(timeout.responseText, "Partial answer\n\n\(timeout.marker)")
        XCTAssertTrue(timeout.errorMessage.contains("no streaming/finalization activity"))
        let cancellationCount = await cancellationRecorder.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testTimeoutWithOnlyControlMarkupLeftIsAnEmptyResponse() async throws {
        let clock = ContextBuilderFollowUpFinalizationTestClock()
        let cancellationRecorder = ContextBuilderFollowUpCancellationRecorder()
        let finalizationGate = ContextBuilderFollowUpCancellationGate()
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }

        do {
            _ = try await ContextBuilderFollowUpFinalizationMonitor.wait(
                activityEvents: events,
                configuration: ContextBuilderFollowUpFinalizationConfiguration(
                    overallTimeout: 100,
                    inactivityTimeout: 10,
                    checkInterval: 10
                ),
                clock: { clock.now() },
                sleep: { seconds in
                    clock.advance(by: seconds)
                    await Task.yield()
                },
                waitForFinalization: {
                    try await finalizationGate.wait()
                },
                partialResponse: {
                    "  \n"
                },
                cancelStreaming: {
                    await cancellationRecorder.record()
                }
            )
            XCTFail("Expected the marker-only timeout to fail as an empty response")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .emptyProcessedContent)
        }
        let cancellationCount = await cancellationRecorder.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testInactivityTimeoutSettlementPersistsMarkedResponseAcrossReplyPreviewAndReload() async throws {
        let partialText = "Partial answer"
        let fixture = try await makeSettlementFixture(partialText: partialText)
        let composition = fixture.composition
        let workspace = fixture.workspace
        let createdSession = fixture.oracleSession
        let fileURL = fixture.fileURL
        let queryID = fixture.queryID

        let clock = ContextBuilderFollowUpFinalizationTestClock()
        let cancellationRecorder = ContextBuilderFollowUpCancellationRecorder()
        let finalizationGate = ContextBuilderFollowUpCancellationGate()
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }
        let finalizationResult = try await ContextBuilderFollowUpFinalizationMonitor.wait(
            activityEvents: events,
            configuration: ContextBuilderFollowUpFinalizationConfiguration(
                overallTimeout: 100,
                inactivityTimeout: 10,
                checkInterval: 10
            ),
            clock: { clock.now() },
            sleep: { seconds in
                clock.advance(by: seconds)
                await Task.yield()
            },
            waitForFinalization: {
                try await finalizationGate.wait()
            },
            partialResponse: {
                partialText
            },
            cancelStreaming: {
                await cancellationRecorder.record()
            }
        )

        let reply = try await composition.contextBuilderAgentViewModel.settleFollowUpFinalization(
            finalizationResult,
            oracleViewModel: composition.oracleViewModel,
            queryID: queryID,
            oracleSession: createdSession,
            originWorkspaceID: workspace.id,
            modeName: "plan",
            session: fixture.tabSession
        )

        let response = try XCTUnwrap(reply.response)
        let preview = try XCTUnwrap(fixture.tabSession.backgroundPlanResponsePreviewText)
        let persistedMessage = try XCTUnwrap(composition.oracleViewModel.getChatMessage(withId: queryID))
        let reloadedSession = try await ChatDataService().loadChatSession(from: fileURL)
        let reloadedMessage = try XCTUnwrap(reloadedSession.messages.first(where: { $0.id == queryID }))
        let marker = "[RepoPrompt: response ended after 10 s without stream activity; content above is partial]"

        XCTAssertEqual(response, partialText + "\n\n" + marker)
        XCTAssertEqual(preview, response)
        XCTAssertEqual(persistedMessage.content, response)
        XCTAssertEqual(reloadedMessage.rawText, response)
        XCTAssertTrue(response.hasSuffix(marker))
        let cancellationCount = await cancellationRecorder.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testTimeoutSettlementThrowsWhenMarkedSnapshotSaveFails() async throws {
        let partialText = "Partial answer"
        let fixture = try await makeSettlementFixture(partialText: partialText)
        let timeout = OraclePartialResponseTimeout(
            partialText: partialText,
            reason: .inactivity(seconds: 10),
            errorMessage: "Timed out"
        )

        do {
            _ = try await fixture.composition.contextBuilderAgentViewModel.settleFollowUpFinalization(
                .timedOut(timeout),
                oracleViewModel: fixture.composition.oracleViewModel,
                queryID: fixture.queryID,
                oracleSession: fixture.oracleSession,
                originWorkspaceID: fixture.workspace.id,
                modeName: "plan",
                session: fixture.tabSession,
                timeoutSessionSaver: { _ in
                    throw ContextBuilderTimeoutSaveTestError.failed
                }
            )
            XCTFail("Expected timeout settlement to propagate the save failure")
        } catch ContextBuilderTimeoutSaveTestError.failed {}

        let reloadedSession = try await ChatDataService().loadChatSession(from: fixture.fileURL)
        let reloadedMessage = try XCTUnwrap(reloadedSession.messages.first(where: { $0.id == fixture.queryID }))
        XCTAssertEqual(reloadedMessage.rawText, partialText)
    }

    func testCancellationDuringTimeoutPersistenceDoesNotRepublishPreviewOrRoute() async throws {
        let partialText = "Partial answer"
        let fixture = try await makeSettlementFixture(partialText: partialText)
        let timeout = OraclePartialResponseTimeout(
            partialText: partialText,
            reason: .inactivity(seconds: 10),
            errorMessage: "Timed out"
        )
        let saveGate = ContextBuilderTimeoutSaveGate()

        let settlementTask = Task { @MainActor in
            try await fixture.composition.contextBuilderAgentViewModel.settleFollowUpFinalization(
                .timedOut(timeout),
                oracleViewModel: fixture.composition.oracleViewModel,
                queryID: fixture.queryID,
                oracleSession: fixture.oracleSession,
                originWorkspaceID: fixture.workspace.id,
                modeName: "plan",
                session: fixture.tabSession,
                timeoutSessionSaver: { session in
                    await saveGate.suspend()
                    return try await fixture.composition.oracleViewModel.autosaveSession(session)
                }
            )
        }

        await saveGate.waitUntilSuspended()
        settlementTask.cancel()
        fixture.tabSession.isBackgroundPlanGenerating = false
        fixture.tabSession.followUpOracleSessionID = nil
        fixture.tabSession.backgroundPlanResponseText = nil
        fixture.tabSession.backgroundPlanResponsePreviewText = nil
        fixture.tabSession.generatedAnswerRoute = nil
        await saveGate.resume()

        do {
            _ = try await settlementTask.value
            XCTFail("Expected cancellation after the suspended save")
        } catch is CancellationError {}

        XCTAssertNil(fixture.tabSession.backgroundPlanResponseText)
        XCTAssertNil(fixture.tabSession.backgroundPlanResponsePreviewText)
        XCTAssertNil(fixture.tabSession.generatedAnswerRoute)
    }

    /// A timed-out follow-up is saving its marked response when its owner loses the tab's session
    /// to another holder. Nothing cancels the follow-up and the session still reads as generating
    /// for the chat the follow-up created, because the new holder left both as they were, so the
    /// owner's own check is all that tells the follow-up the session is no longer its to write.
    /// The follow-up ends as cancelled and the session and the stored tab's chat stay the
    /// holder's.
    func testTimeoutSettlementWhoseOwnerLostItsSessionDuringPersistencePublishesNothing() async throws {
        let partialText = "Partial answer"
        let fixture = try await makeSettlementFixture(partialText: partialText)
        let workspaceManager = fixture.composition.workspaceManager
        let tabID = fixture.tabSession.tabID
        let timeout = OraclePartialResponseTimeout(
            partialText: partialText,
            reason: .inactivity(seconds: 10),
            errorMessage: "Timed out"
        )
        let saveGate = ContextBuilderTimeoutSaveGate()
        let ownership = ContextBuilderFollowUpOwnership()
        let settlement = ContextBuilderSettlementOutcome()

        let settlementTask = Task { @MainActor in
            do {
                settlement.result = try await .success(
                    fixture.composition.contextBuilderAgentViewModel.settleFollowUpFinalization(
                        .timedOut(timeout),
                        oracleViewModel: fixture.composition.oracleViewModel,
                        queryID: fixture.queryID,
                        oracleSession: fixture.oracleSession,
                        originWorkspaceID: fixture.workspace.id,
                        modeName: "plan",
                        session: fixture.tabSession,
                        ownerStillOwns: { ownership.isOwned },
                        timeoutSessionSaver: { session in
                            await saveGate.suspend()
                            return try await fixture.composition.oracleViewModel.autosaveSession(session)
                        }
                    )
                )
            } catch {
                settlement.result = .failure(error)
            }
        }
        // A failed assertion can leave the save suspended, so the settlement is let go and joined
        // however the test ends.
        addTeardownBlock {
            await saveGate.release()
            settlementTask.cancel()
            await settlementTask.value
        }

        // A settlement that ends without saving never reaches the gate, so its end is watched too.
        let reachedItsSave = await waitUntil { await saveGate.hasSuspended || settlement.result != nil }
        guard reachedItsSave, settlement.result == nil else {
            return XCTFail("The settlement did not reach its save: \(String(describing: settlement.result))")
        }
        ownership.isOwned = false
        let holderAnswer = "Answer held by the tab's new holder"
        let holderRoute = ContextBuilderGeneratedAnswerRoute(
            workspaceID: fixture.workspace.id,
            tabID: tabID,
            chatID: "holder-chat"
        )
        let holderChatID = UUID()
        fixture.tabSession.backgroundPlanResponseText = holderAnswer
        fixture.tabSession.backgroundPlanResponsePreviewText = holderAnswer
        fixture.tabSession.generatedAnswerRoute = holderRoute
        workspaceManager.setActiveChatSessionID(holderChatID, forTabID: tabID)
        await saveGate.resume()

        let ended = await waitUntil { settlement.result != nil }
        XCTAssertTrue(ended, "The settlement did not end once its save was let go")
        var endedAsCancelled = false
        if case let .failure(error)? = settlement.result {
            endedAsCancelled = error is CancellationError
        }
        XCTAssertTrue(
            endedAsCancelled,
            "Expected the follow-up to end as cancelled once its owner had lost the session, not "
                + String(describing: settlement.result)
        )

        XCTAssertTrue(fixture.tabSession.isBackgroundPlanGenerating)
        XCTAssertEqual(fixture.tabSession.followUpOracleSessionID, fixture.oracleSession.id)
        XCTAssertEqual(fixture.tabSession.backgroundPlanResponseText, holderAnswer)
        XCTAssertEqual(fixture.tabSession.backgroundPlanResponsePreviewText, holderAnswer)
        XCTAssertEqual(fixture.tabSession.generatedAnswerRoute, holderRoute)
        XCTAssertEqual(workspaceManager.activeChatSessionID(forTabID: tabID), holderChatID)
    }

    func testNormalCompletionReturnsResponseUnchanged() async throws {
        let cancellationRecorder = ContextBuilderFollowUpCancellationRecorder()
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }
        let expected = "  Complete answer with original whitespace.  \n"

        let result = try await ContextBuilderFollowUpFinalizationMonitor.wait(
            activityEvents: events,
            configuration: ContextBuilderFollowUpFinalizationConfiguration(
                overallTimeout: 100,
                inactivityTimeout: 10,
                checkInterval: 60
            ),
            waitForFinalization: {
                expected
            },
            partialResponse: {
                "unused partial"
            },
            cancelStreaming: {
                await cancellationRecorder.record()
            }
        )

        XCTAssertEqual(result, .completed(expected))
        let cancellationCount = await cancellationRecorder.count()
        XCTAssertEqual(cancellationCount, 0)
    }

    /// Polls `condition` until it holds or `timeout` passes, and returns whether it held.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if await condition() { return true }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSettlementFixture(partialText: String) async throws -> ContextBuilderTimeoutSettlementFixture {
        let composition = WindowStateCompositionFactory.make(
            windowID: -704,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()

        let repoRoot = chatWorkspaceRoot
            .appendingPathComponent("Repository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let workspace = composition.workspaceManager.createWorkspace(
            name: "Context Builder timeout settlement",
            repoPaths: [repoRoot.path],
            ephemeral: true
        )
        await composition.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: #function
        )

        let tabID = UUID()
        let workspaceIndex = try XCTUnwrap(
            composition.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
        )
        composition.workspaceManager.workspaces[workspaceIndex].composeTabs = [ComposeTabState(id: tabID)]
        composition.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
        composition.promptManager.loadComposeTabsFromWorkspace(
            composition.workspaceManager.workspaces[workspaceIndex],
            syncPromptText: true
        )

        let created = try await composition.oracleViewModel.createSessionFromHeadlessRun(
            prompt: "Test prompt",
            response: partialText,
            model: .gpt41,
            tokenInfo: ChatTokenInfo(),
            selection: StoredSelection(),
            chatName: "Timeout test",
            chatPresetID: nil,
            tabID: tabID,
            workspaceID: workspace.id,
            setActiveForTab: true
        )
        let fileURL = try XCTUnwrap(created.session.fileURL)
        let queryID = try XCTUnwrap(created.session.messages.first(where: { !$0.isUser })?.id)
        await composition.oracleViewModel.loadChatSession(from: fileURL)

        let tabSession = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        tabSession.isBackgroundPlanGenerating = true
        tabSession.followUpOracleSessionID = created.session.id
        tabSession.backgroundPlanResponseText = partialText
        tabSession.backgroundPlanResponsePreviewText = partialText
        tabSession.generatedAnswerRoute = ContextBuilderGeneratedAnswerRoute(
            workspaceID: workspace.id,
            tabID: tabID,
            chatID: created.session.shortID
        )
        return ContextBuilderTimeoutSettlementFixture(
            composition: composition,
            workspace: workspace,
            oracleSession: created.session,
            fileURL: fileURL,
            queryID: queryID,
            tabSession: tabSession
        )
    }
}

private struct ContextBuilderTimeoutSettlementFixture {
    let composition: WindowStateComposition
    let workspace: WorkspaceModel
    let oracleSession: ChatSession
    let fileURL: URL
    let queryID: UUID
    let tabSession: ContextBuilderAgentViewModel.TabSession
}

private enum ContextBuilderTimeoutSaveTestError: Error {
    case failed
}

/// Whether a follow-up's owner still holds the session the follow-up writes to.
@MainActor
private final class ContextBuilderFollowUpOwnership {
    var isOwned = true
}

/// How a settlement ended, once it has.
@MainActor
private final class ContextBuilderSettlementOutcome {
    var result: Result<ChatSendReply, Error>?
}

private actor ContextBuilderTimeoutSaveGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var waiterContinuation: CheckedContinuation<Void, Never>?

    /// Whether a save has reached the gate.
    var hasSuspended: Bool {
        isSuspended
    }

    func suspend() async {
        isSuspended = true
        waiterContinuation?.resume()
        waiterContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    /// Lets a suspended save go on and keeps a later one from suspending, so that nothing is left
    /// at the gate once a test is over.
    func release() {
        isReleased = true
        resume()
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            waiterContinuation = continuation
        }
    }

    func resume() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

private final class ContextBuilderFollowUpFinalizationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private actor ContextBuilderFollowUpCancellationRecorder {
    private var cancellationCount = 0

    func record() {
        cancellationCount += 1
    }

    func count() -> Int {
        cancellationCount
    }
}

private final class ContextBuilderFollowUpCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelledBeforeWait = false

    func wait() async throws -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelledBeforeWait {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            cancelledBeforeWait = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
        try Task.checkCancellation()
        return "unexpected completion"
    }
}
