import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Polls `condition` until it holds or `seconds` elapse and reports whether it held. Every
    /// bounded wait in the startup suites goes through here, so a start that never settles fails
    /// the test instead of hanging the suite.
    @MainActor
    func startupTestWaitBounded(seconds: TimeInterval = 5, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    /// Runs `operation` in its own task and returns a flag set when it finishes, so the caller can
    /// bound its wait for work that may never finish. The operation stays registered with
    /// `tracking` until it finishes, so that owner's teardown can cancel one a timed-out wait left
    /// behind.
    @MainActor
    func startupTestRunTracked(
        _ operation: @escaping @MainActor () async -> Void,
        in tracking: StartupTestTrackedOperations
    ) -> StartupTestCompletionFlag {
        startupTestRunTracked(operation, in: tracking, alsoCancelling: nil)
    }

    /// `alsoCancelling` runs wherever the tracked task is cancelled, so a join can cancel the task
    /// it joins, not just the task doing the joining. Without `tracking`, the caller's own bounded
    /// wait is what cancels an operation that does not finish.
    @MainActor
    private func startupTestRunTracked(
        _ operation: @escaping @MainActor () async -> Void,
        in tracking: StartupTestTrackedOperations?,
        alsoCancelling cancelJoined: (() -> Void)?
    ) -> StartupTestCompletionFlag {
        let finished = StartupTestCompletionFlag()
        let id = UUID()
        let task = Task { @MainActor [weak tracking] in
            await operation()
            finished.value = true
            tracking?.unfinished[id] = nil
        }
        finished.cancel = {
            task.cancel()
            cancelJoined?()
        }
        if !finished.value {
            tracking?.unfinished[id] = finished.cancel
        }
        return finished
    }

    @MainActor
    final class StartupTestCompletionFlag {
        var value = false
        fileprivate(set) var cancel: () -> Void = {}
    }

    /// One owner's tracked operations that have not finished yet, by how to cancel them. Each
    /// fixture owns its own, so one teardown never cancels work another owner registered.
    @MainActor
    final class StartupTestTrackedOperations {
        fileprivate var unfinished: [UUID: () -> Void] = [:]

        /// Cancels every operation this owner tracks that is still running.
        func cancelUnfinished() {
            let cancellations = unfinished.values
            unfinished.removeAll()
            cancellations.forEach { $0() }
        }
    }

    /// Awaits `operation` for at most `seconds` and reports it as unfinished otherwise, so a
    /// teardown step stuck on a start that never settled fails instead of hanging the suite.
    @MainActor
    func startupTestAwaitBounded(
        _ failureMessage: String,
        seconds: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let finished = startupTestRunTracked(operation, in: nil, alsoCancelling: nil)
        let didFinish = await startupTestWaitBounded(seconds: seconds) { finished.value }
        if !didFinish {
            finished.cancel()
        }
        XCTAssertTrue(didFinish, failureMessage, file: file, line: line)
    }

    /// Joins `task` for at most `seconds` and reports whether it finished. A timed-out join, or one
    /// teardown finds unfinished, cancels `task` itself; the wait stays bounded even if `task`
    /// ignores cancellation.
    @MainActor
    @discardableResult
    func startupTestJoinBounded(
        _ task: Task<some Any, Never>,
        _ failureMessage: String = "the joined task did not finish",
        seconds: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let finished = startupTestRunTracked({
            _ = await task.value
        }, in: nil, alsoCancelling: {
            task.cancel()
        })
        let didFinish = await startupTestWaitBounded(seconds: seconds) { finished.value }
        if !didFinish {
            finished.cancel()
        }
        XCTAssertTrue(didFinish, failureMessage, file: file, line: line)
        return didFinish
    }

    /// Joins `task` as a test step, failing the step at the caller when it does not finish.
    @MainActor
    func startupTestJoin(
        _ task: Task<some Any, Never>?,
        seconds: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        guard let task else { return }
        guard await startupTestJoinBounded(
            task,
            "Timed out joining a task",
            seconds: seconds,
            file: file,
            line: line
        ) else { throw StartupTestJoinTimeout() }
    }

    struct StartupTestJoinTimeout: Error {}

    /// Runs `operation` against `fixture` and waits at most `seconds` for it, failing at the caller
    /// when it does not finish. An operation that times out stays tracked by the fixture, whose
    /// teardown cancels it.
    @MainActor
    func startupTestSettle(
        on fixture: StartupTestSessionFixture,
        seconds: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @MainActor () async -> Void
    ) async throws {
        struct SettleTimeout: Error {}
        let finished = startupTestRunTracked(operation, in: fixture.cleanup.trackedOperations)
        if await startupTestWaitBounded(seconds: seconds, until: { finished.value }) { return }
        XCTFail("Timed out waiting for condition", file: file, line: line)
        throw SettleTimeout()
    }

    /// A Codex session that has loaded its persisted state, ready to take a submission.
    @MainActor
    func startupTestCodexSession(tabID: UUID = UUID()) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        return session
    }

    /// What a startup test hands to fixture teardown: releases and gates it holds, the starts and
    /// tasks to join once those are released, and steps that must wait until everything has
    /// settled.
    @MainActor
    final class StartupTestCleanup {
        var releases: [@MainActor () -> Void] = []
        var heldGates: [StartupTestHeldGate] = []
        var tickets: [AgentRunStartupTicket] = []
        var afterStartsSettle: [@MainActor () async -> Void] = []
        /// Operations a test runs against this fixture that may outlive a timed-out wait.
        let trackedOperations = StartupTestTrackedOperations()
        fileprivate private(set) var taskJoins: [@MainActor () async -> Void] = []

        /// Joins `task` at teardown after the releases and ticket joins, cancelling it if the
        /// bounded join times out.
        func join(_ task: Task<some Any, Never>) {
            taskJoins.append {
                await startupTestJoinBounded(task, "a test task did not finish during teardown")
            }
        }
    }

    /// A live view-model session driven by gated readiness and a recording Codex controller. Each
    /// suite builds the view model and session it needs; subclasses add suite-specific controls.
    @MainActor
    class StartupTestSessionFixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID = UUID()
        let readiness: StartupTestGatedReadiness
        let controller: StartupTestCodexController
        let cleanup = StartupTestCleanup()

        var tabID: UUID {
            session.tabID
        }

        var errorTexts: [String] {
            session.items.filter { $0.kind == .error }.map(\.text)
        }

        /// Installs `session` as the view model's live session for its tab.
        init(
            viewModel: AgentModeViewModel,
            session: AgentModeViewModel.TabSession,
            readiness: StartupTestGatedReadiness,
            controller: StartupTestCodexController
        ) {
            self.viewModel = viewModel
            self.session = session
            self.readiness = readiness
            self.controller = controller
            viewModel.test_installLiveSession(session)
        }

        /// Submits a manual turn into the inactive session and returns the startup ticket the
        /// submission installed; teardown joins its start.
        func submit(_ text: String) throws -> AgentRunStartupTicket {
            XCTAssertEqual(viewModel.submitUserTurn(text: text, tabID: tabID), .submitted)
            let ticket = try XCTUnwrap(session.unresolvedStartupTicket)
            cleanup.tickets.append(ticket)
            return ticket
        }

        /// Puts the session under MCP control, as `agent_run` does; `startPending` raises the
        /// queued-start flag `agent_run start` raises. Teardown deactivates it once starts settle.
        @discardableResult
        func activateMCPControl(startPending: Bool = true) async throws -> AgentRunSessionStore.Registration {
            let registration = try await startupTestActivateMCPControl(
                viewModel: viewModel,
                session: session,
                sessionID: sessionID,
                startPending: startPending
            )
            let viewModel = viewModel
            let sessionID = sessionID
            cleanup.afterStartsSettle.append {
                await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
            return registration
        }

        /// Completes the active native turn as the app-server reports it: started, then completed.
        func completeActiveTurn(turnID: String) async throws {
            let coordinator = viewModel.test_codexCoordinator
            await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: turnID), session: session, sourceController: controller)
            await coordinator.test_handleCodexNativeEvent(
                .turnCompleted(turnID: turnID, status: .completed),
                session: session,
                sourceController: controller
            )
        }

        /// Every gate is released before anything is awaited, and every await is bounded, so a
        /// test that fails while a start is held reports it instead of hanging teardown.
        func tearDown() async {
            readiness.releaseAll(ready: false)
            controller.releaseStartup()
            cleanup.releases.forEach { $0() }
            cleanup.heldGates.forEach { $0.release() }
            let viewModel = viewModel
            let tabID = tabID
            let liveSession = viewModel.session(for: tabID)
            if liveSession.runState.isActive || liveSession.unresolvedStartupTicket != nil {
                await startupTestAwaitBounded("fixture teardown cancellation did not finish") {
                    await viewModel.cancelAgentRun(tabID: tabID)
                }
            }
            for ticket in cleanup.tickets {
                guard let task = ticket.task else { continue }
                await startupTestJoinBounded(task, "a held start did not finish during teardown")
            }
            for join in cleanup.taskJoins {
                await join()
            }
            for step in cleanup.afterStartsSettle {
                await startupTestAwaitBounded("a cleanup step did not finish during teardown", step)
            }
            cleanup.trackedOperations.cancelUnfinished()
        }
    }

    /// Records every terminal revision handed to publication, then publishes it normally. Opt-in:
    /// a suite that asserts on publications installs one on its view model.
    @MainActor
    final class StartupTestPublicationRecorder {
        private(set) var revisions: [AgentRunTerminalCommitRevision] = []

        func install(on viewModel: AgentModeViewModel) {
            viewModel.test_setTerminalPublicationOverride { [weak self, weak viewModel] revision, successorKind, session in
                guard let self, let viewModel else { return .rejected(reason: "fixture released") }
                revisions.append(revision)
                viewModel.test_setTerminalPublicationOverride(nil)
                defer { install(on: viewModel) }
                return await viewModel.test_publishTerminalCommit(revision, successorKind: successorKind, for: session)
            }
        }
    }

    /// Gives `session` prior Codex history whose saved thread needs a reconnect, as a restored or
    /// previously used session has; `nil` identifiers model a saved thread missing them.
    @MainActor
    func startupTestInstallSavedCodexHistory(
        on session: AgentModeViewModel.TabSession,
        conversationID: String?,
        rolloutPath: String?
    ) {
        session.setItemsSilently(
            [
                .user("earlier", sequenceIndex: 0),
                .assistant("earlier reply", sequenceIndex: 1)
            ],
            reason: .persistedSessionHydration
        )
        session.nextSequenceIndex = 2
        session.codexConversationID = conversationID
        session.codexRolloutPath = rolloutPath
        session.codexNeedsReconnect = true
    }

    /// Installs what a cold restore of a saved session installs: the persisted run state after
    /// cold-restore normalization, and the transcript built from the saved items under that state.
    @MainActor
    func startupTestInstallRestoredState(
        on session: AgentModeViewModel.TabSession,
        items: [AgentChatItem],
        persistedRunState: AgentSessionRunState?
    ) {
        let runState = AgentSessionRestoreSupport.normalizeColdRestoredRunState(persistedRunState)
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: runState,
            nextSequenceIndex: items.count,
            policy: .liveSession(hidePendingQuestionToolCall: false)
        )
        session.setItemsSilently(AgentTranscriptIO.workingSourceItems(from: transcript), reason: .persistedSessionHydration)
        session.transcript = transcript
        session.nextSequenceIndex = transcript.nextSequenceIndex
        session.hasLoadedPersistedState = true
        session.runState = runState
    }

    /// Puts `session` under MCP control, as `agent_run` does; `startPending` raises the queued-start
    /// flag an `agent_run start` raises.
    @MainActor
    @discardableResult
    func startupTestActivateMCPControl(
        viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        sessionID: UUID,
        startPending: Bool
    ) async throws -> AgentRunSessionStore.Registration {
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        return try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: UUID(),
            startPending: startPending,
            markSessionAsMCPOriginated: true,
            requireInactiveRunState: true
        ).registration
    }

    /// Holds every caller of `wait()` until `release()`; later callers pass straight through.
    @MainActor
    final class StartupTestHeldGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isWaiting: Bool {
            !waiters.isEmpty
        }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// Readiness dependency whose selected calls (1-based) suspend until the test releases them,
    /// and whose calls can fail with a typed readiness error. `enter()` is the Boolean enabler
    /// form, `require()` the throwing form; a `false` release surfaces through `require()` as the
    /// catalog-readiness rejection a Boolean enabler adapts to.
    @MainActor
    final class StartupTestGatedReadiness {
        private(set) var callCount = 0
        var onCall: ((Int) -> Void)?
        /// Calls (1-based) that fail immediately with the given error.
        var failures: [Int: Error] = [:]
        private let gatedCalls: Set<Int>
        private var waiters: [Int: CheckedContinuation<Result<Void, Error>, Never>] = [:]

        init(gatedCalls: Set<Int>) {
            self.gatedCalls = gatedCalls
        }

        func enter() async -> Bool {
            if case .success = await nextOutcome() { return true }
            return false
        }

        func require() async throws {
            try await nextOutcome().get()
        }

        private func nextOutcome() async -> Result<Void, Error> {
            callCount += 1
            let call = callCount
            onCall?(call)
            if let failure = failures[call] {
                return .failure(failure)
            }
            guard gatedCalls.contains(call) else { return .success(()) }
            return await withCheckedContinuation { continuation in
                waiters[call] = continuation
            }
        }

        func isWaiting(_ call: Int) -> Bool {
            waiters[call] != nil
        }

        func release(_ call: Int, ready: Bool) {
            waiters.removeValue(forKey: call)?.resume(returning: Self.outcome(ready: ready))
        }

        func release(_ call: Int, failingWith error: Error) {
            waiters.removeValue(forKey: call)?.resume(returning: .failure(error))
        }

        func releaseAll(ready: Bool) {
            let pending = waiters
            waiters.removeAll()
            for continuation in pending.values {
                continuation.resume(returning: Self.outcome(ready: ready))
            }
        }

        private static func outcome(ready: Bool) -> Result<Void, Error> {
            ready ? .success(()) : .failure(MCPBootstrapReadinessError.catalogReadinessRejected)
        }
    }

    /// Codex controller that records native startup and first-turn dispatch, optionally holding
    /// startup (which stands in for native start plus routing) until the test releases it, or
    /// failing it with `startupError` or with what `startupHook` throws for the start's resume
    /// target; `compactError` fails a compaction request, after `compactHold` releases it when one
    /// is set.
    @MainActor
    final class StartupTestCodexController: @preconcurrency CodexSessionControlling {
        private(set) var hasActiveThread = false
        private(set) var startOrResumeCount = 0
        /// The resume target of each start, `nil` for a fresh thread.
        private(set) var startOrResumeTargets: [CodexNativeSessionController.SessionRef?] = []
        var startupHook: ((CodexNativeSessionController.SessionRef?) async throws -> Void)?
        private(set) var startUserTurnTexts: [String] = []
        private(set) var steerUserTurnTexts: [String] = []
        var startupError: Error?
        var compactError: Error?
        var compactHold: StartupTestHeldGate?
        private var gatesStartup: Bool
        private var startupWaiters: [CheckedContinuation<Void, Never>] = []

        init(gatesStartup: Bool) {
            self.gatesStartup = gatesStartup
        }

        var isStartupWaiting: Bool {
            !startupWaiters.isEmpty
        }

        func releaseStartup() {
            gatesStartup = false
            let waiters = startupWaiters
            startupWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { _ in }
        }

        func ensureEventsStreamReady() {}

        func startOrResume(
            existing: CodexNativeSessionController.SessionRef?,
            baseInstructions: String
        ) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(
                existing: existing,
                baseInstructions: baseInstructions,
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
        }

        func startOrResume(
            existing: CodexNativeSessionController.SessionRef?,
            baseInstructions: String,
            model: String?,
            reasoningEffort: String?
        ) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(
                existing: existing,
                baseInstructions: baseInstructions,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: nil
            )
        }

        func startOrResume(
            existing: CodexNativeSessionController.SessionRef?,
            baseInstructions _: String,
            model: String?,
            reasoningEffort: String?,
            serviceTier _: String?
        ) async throws -> CodexNativeSessionController.SessionRef {
            startOrResumeCount += 1
            startOrResumeTargets.append(existing)
            try await startupHook?(existing)
            if gatesStartup {
                await withCheckedContinuation { continuation in
                    startupWaiters.append(continuation)
                }
            }
            if let startupError {
                throw startupError
            }
            hasActiveThread = true
            return CodexNativeSessionController.SessionRef(
                conversationID: "startup-ticket-test",
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        }

        func readThreadSnapshot(
            includeTurns _: Bool,
            timeout _: TimeInterval?
        ) async throws -> CodexNativeSessionController.ThreadSnapshot {
            CodexNativeSessionController.ThreadSnapshot(
                conversationID: "startup-ticket-test",
                rolloutPath: nil,
                model: nil,
                reasoningEffort: nil,
                runtimeStatus: .idle,
                currentTurnID: nil,
                activeTurnIDs: [],
                latestTurnStatus: nil
            )
        }

        func setThreadName(_: String, threadID _: String?) async throws {}

        /// An empty inventory lets the first turn pass the project-hooks gate without a review.
        func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
            try CodexHookInventory(executionCWD: FileManager.default.temporaryDirectory.path, hooks: [])
        }

        func startUserTurn(
            text: String,
            images _: [AgentImageAttachment],
            model _: String?,
            reasoningEffort _: String?,
            serviceTier _: String?
        ) async throws -> CodexTurnStartReceipt {
            startUserTurnTexts.append(text)
            return CodexTurnStartReceipt(provisionalSubmissionID: "startup-ticket-test-\(startUserTurnTexts.count)")
        }

        func steerUserTurn(
            text: String,
            images _: [AgentImageAttachment],
            expectedTurnID: String
        ) async throws -> CodexTurnSteerReceipt {
            steerUserTurnTexts.append(text)
            return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
        }

        func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
            expectedCurrentTurnID _: String,
            acceptedDispatchTurnID _: String
        ) async -> Bool {
            true
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
        }

        func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
            CodexTurnInterruptReceipt(interruptedTurnID: "startup-ticket-test")
        }

        func compactThread() async throws {
            if let compactHold {
                await compactHold.wait()
            }
            if let compactError {
                throw compactError
            }
        }

        func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
            nil
        }

        func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func setThreadGoalStatus(
            _: CodexNativeSessionController.ThreadGoalStatus
        ) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func clearThreadGoal() async throws -> Bool {
            false
        }

        func pendingTurnFailure(
            turnID _: String?
        ) async -> CodexNativeSessionController.TurnFailure? {
            nil
        }

        func acknowledgePendingTurnFailure(
            turnID _: String?,
            failure _: CodexNativeSessionController.TurnFailure
        ) async {}

        func cancelCurrentTurn() async {}
        func shutdown() async {}

        func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
    }
#endif
