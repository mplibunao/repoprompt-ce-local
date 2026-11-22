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

    func testLivenessRenewedLaneCompletesAcrossInactivityBudgets() async throws {
        let lane = ContextBuilderFollowUpLivenessLane()
        let monitor = await lane.start(partialText: "unused partial")

        // Activity every 8 s against a 10 s budget, each check 7 s after the latest renewal.
        for renewal in stride(from: 8.0, through: 40.0, by: 8.0) {
            let recorded = await lane.deliverActivity(at: renewal)
            XCTAssertTrue(recorded, "the monitor didn't record activity at \(renewal) s")
            let survived = await lane.check(at: renewal + 7)
            XCTAssertTrue(survived, "the lane timed out 7 s after activity at \(renewal) s")
        }
        let survivedBeforeBudget = await lane.check(at: 49.9)
        XCTAssertTrue(survivedBeforeBudget, "the lane timed out 9.9 s after its last activity")
        lane.finalization.resolve("final answer")

        let result = try await monitor.value
        XCTAssertFalse(lane.deadlineExpired, "the monitor ended only when the lane's deadline cancelled it")
        XCTAssertEqual(result, .completed("final answer"))
        let cancellationCount = await lane.cancellations.count()
        XCTAssertEqual(cancellationCount, 0)
    }

    func testLaneWithoutFurtherLivenessTimesOut() async throws {
        let lane = ContextBuilderFollowUpLivenessLane()
        let monitor = await lane.start(partialText: "Partial answer")

        for renewal in [8.0, 16.0] {
            let recorded = await lane.deliverActivity(at: renewal)
            XCTAssertTrue(recorded, "the monitor didn't record activity at \(renewal) s")
        }
        let survivedBeforeBudget = await lane.check(at: 25.9)
        XCTAssertTrue(survivedBeforeBudget, "the lane timed out 9.9 s after its last activity")
        let survivedAtBudget = await lane.check(at: 26)
        guard !survivedAtBudget else {
            monitor.cancel()
            return XCTFail("the lane survived 10 s without activity")
        }

        let result = try await monitor.value
        XCTAssertFalse(lane.deadlineExpired, "the monitor ended only when the lane's deadline cancelled it")
        guard case let .timedOut(timeout) = result else {
            return XCTFail("Expected a typed timeout result, got \(result)")
        }
        XCTAssertEqual(timeout.reason, .inactivity(seconds: 10))
        XCTAssertEqual(timeout.partialText, "Partial answer")
        let cancellationCount = await lane.cancellations.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testUIFollowUpShowsTypedCompletionErrorDescription() async throws {
        let (composition, _, tabID) = try await makeCompositionWithComposeTab(
            workspaceName: "Context Builder UI follow-up failure"
        )
        let viewModel = composition.contextBuilderAgentViewModel
        let message = "Context Builder prepared message was rejected."
        viewModel.installRunTestHooks(.init(
            beforeProcessingProviderEvent: nil,
            providerEventDisposition: nil,
            teardownCompleted: nil,
            runUIFollowUp: { _, _ in
                throw OracleContextBuilderCompletionError.providerStreamFailed(message: message)
            }
        ))

        viewModel.startBackgroundPlanGeneration(tabID: tabID, oracleViewModel: composition.oracleViewModel)
        let session = try XCTUnwrap(viewModel.sessions[tabID])
        let followUp = try XCTUnwrap(session.backgroundPlanTask)
        await followUp.value

        XCTAssertEqual(session.backgroundPlanError, message)
    }

    private func makeCompositionWithComposeTab(
        workspaceName: String
    ) async throws -> (composition: WindowStateComposition, workspace: WorkspaceModel, tabID: UUID) {
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
            name: workspaceName,
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
        return (composition, workspace, tabID)
    }

    private func makeSettlementFixture(partialText: String) async throws -> ContextBuilderTimeoutSettlementFixture {
        let (composition, workspace, tabID) = try await makeCompositionWithComposeTab(
            workspaceName: "Context Builder timeout settlement"
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

private actor ContextBuilderTimeoutSaveGate {
    private var isSuspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var waiterContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        waiterContinuation?.resume()
        waiterContinuation = nil
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
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

/// Runs the monitor with a 10 s inactivity budget against a clock the test sets. Each inactivity
/// check waits for `check(at:)`, and each method returns only after the monitor has recorded the
/// activity or finished the check, so nothing races the clock.
private final class ContextBuilderFollowUpLivenessLane {
    let clock = ContextBuilderFollowUpFinalizationTestClock()
    let cancellations = ContextBuilderFollowUpCancellationRecorder()
    let finalization = ContextBuilderFollowUpCancellationGate()
    private let activity = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
    // Buffered: the check task asks for its first step as soon as the monitor starts.
    private let checkSteps = AsyncStream<Void>.makeStream()
    private let recordedActivity = AsyncStream<Void>.makeStream()
    private let waitingChecks = AsyncStream<Void>.makeStream()
    private var recordedActivityIterator: AsyncStream<Void>.Iterator
    private var waitingChecksIterator: AsyncStream<Void>.Iterator
    private let deadline = ContextBuilderFollowUpLaneDeadline()
    private var deadlineTask: Task<Void, Never>?

    /// True when the deadline, not the monitor, ended the run. Cancelling a stuck monitor can still
    /// return the result it had chosen, so a test must reject a run the deadline ended.
    var deadlineExpired: Bool {
        deadline.expired
    }

    init() {
        recordedActivityIterator = recordedActivity.stream.makeAsyncIterator()
        waitingChecksIterator = waitingChecks.stream.makeAsyncIterator()
    }

    deinit {
        deadlineTask?.cancel()
        activity.continuation.finish()
        checkSteps.continuation.finish()
    }

    /// Starts the monitor and returns once its first inactivity check is waiting.
    func start(partialText: String) async -> Task<ContextBuilderFollowUpFinalizationResult, Error> {
        let clock = clock
        let cancellations = cancellations
        let finalization = finalization
        let activityEvents = activity.stream
        let checkSteps = checkSteps.stream
        let recordedActivity = recordedActivity.continuation
        let waitingChecks = waitingChecks.continuation
        let deadline = deadline
        let monitor = Task {
            // A monitor that has ended can't acknowledge anything; finishing the acknowledgements
            // ends the test's wait instead of hanging it.
            defer {
                deadline.settle()
                recordedActivity.finish()
                waitingChecks.finish()
            }
            return try await ContextBuilderFollowUpFinalizationMonitor.wait(
                activityEvents: activityEvents,
                configuration: ContextBuilderFollowUpFinalizationConfiguration(
                    overallTimeout: 1000,
                    inactivityTimeout: 10,
                    checkInterval: 1
                ),
                clock: { clock.now() },
                sleep: { _ in
                    waitingChecks.yield()
                    // Cancellation ends the wait for a step, as it ends a real sleep.
                    var steps = checkSteps.makeAsyncIterator()
                    guard await steps.next() != nil else {
                        throw CancellationError()
                    }
                },
                waitForFinalization: {
                    try await finalization.wait()
                },
                partialResponse: {
                    partialText
                },
                cancelStreaming: {
                    await cancellations.record()
                },
                reportActivity: { _, _ in
                    recordedActivity.yield()
                }
            )
        }
        // A broken monitor can stop acknowledging without ending. The deadline ends the test's
        // waits and cancels the monitor, so the test fails instead of hanging the run.
        deadlineTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, deadline.expire() else { return }
            recordedActivity.finish()
            waitingChecks.finish()
            monitor.cancel()
        }
        _ = await waitingChecksIterator.next()
        return monitor
    }

    /// Delivers stream activity at `time`; false when the monitor ended, or the lane's deadline
    /// passed, before the monitor recorded it.
    func deliverActivity(at time: TimeInterval) async -> Bool {
        clock.set(to: time)
        activity.continuation.yield(OracleMessageLifecycleActivityEvent(kind: .streamActivity))
        return await recordedActivityIterator.next() != nil
    }

    /// Runs one inactivity check at `time`; true when the monitor survived it and waits for the
    /// next check, false when the monitor ended or the lane's deadline passed.
    func check(at time: TimeInterval) async -> Bool {
        clock.set(to: time)
        checkSteps.continuation.yield()
        return await waitingChecksIterator.next() != nil
    }
}

/// Decides, under one lock, whether the monitor settled before the lane's deadline expired.
private final class ContextBuilderFollowUpLaneDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var didExpire = false

    var expired: Bool {
        lock.withLock { didExpire }
    }

    func settle() {
        lock.withLock { settled = true }
    }

    /// Returns false when the monitor has already settled.
    func expire() -> Bool {
        lock.withLock {
            guard !settled else { return false }
            didExpire = true
            return true
        }
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

    func set(to time: TimeInterval) {
        lock.lock()
        value = time
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

/// Holds a follow-up's finalization until the test resolves it or the waiting task is cancelled.
private final class ContextBuilderFollowUpCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelledBeforeWait = false
    private var response: String?

    func resolve(_ response: String) {
        lock.lock()
        self.response = response
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async throws -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelledBeforeWait || response != nil {
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
        return lock.withLock { response } ?? "unexpected completion"
    }
}
