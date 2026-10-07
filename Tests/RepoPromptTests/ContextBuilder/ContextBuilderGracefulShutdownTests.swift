import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderGracefulShutdownTests: XCTestCase {
    func testRetainedSnapshotIncludesEveryRegistryOwnedLifecycleState() {
        let registry = ContextBuilderRunRegistry()
        let active = makeRecord()
        let terminal = makeRecord()
        let activeSlotReleased = makeRecord()
        let teardownStarted = makeRecord()

        for record in [active, terminal, activeSlotReleased, teardownStarted] {
            XCTAssertTrue(registry.register(record))
        }
        XCTAssertTrue(terminal.claimTerminal(.completed))
        XCTAssertTrue(registry.releaseActiveSlot(for: activeSlotReleased))
        XCTAssertNotNil(teardownStarted.beginTeardown())

        let snapshot = registry.retainedRecordsSnapshot()

        XCTAssertEqual(Set(snapshot.map(\.runID)), Set([
            active.runID,
            terminal.runID,
            activeSlotReleased.runID,
            teardownStarted.runID
        ]))
    }

    func testTeardownSettlementSupportsConcurrentAndLateWaitersExactlyOnce() async {
        let record = makeRecord()
        XCTAssertNotNil(record.beginTeardown())
        let first = Task { await record.awaitTeardownSettlement() }
        let second = Task { await record.awaitTeardownSettlement() }

        record.markProviderDisposalFinished()
        record.markProviderDisposalFinished()
        record.markExecutionTaskFinished()
        record.markExecutionTaskFinished()

        await first.value
        await second.value
        await record.awaitTeardownSettlement()
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testAppShutdownRetiresHiddenRecordAndWaitsForProviderAndExecution() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: false, releaseActiveSlot: true))

        let shutdownFinished = ContextBuilderTestFlag()
        let shutdown = Task {
            await viewModel.shutdownForAppTermination()
            await shutdownFinished.set()
        }
        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()

        XCTAssertEqual(record.terminalOutcome, .cancelled)
        let finishedBeforeDisposal = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeDisposal)
        await provider.allowDispose()
        let finishedBeforeExecution = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeExecution)
        await executionGate.open()
        await shutdown.value

        let finishedAfterSettlement = await shutdownFinished.current()
        XCTAssertTrue(finishedAfterSettlement)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testAppTerminationStopsWaitingForCancellationIgnoringExecutionAfterGrace() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        viewModel.setCloseSettlementGraceForTesting(1)
        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))

        let shutdownFinished = ContextBuilderTestFlag()
        let shutdown = Task {
            await viewModel.shutdownForAppTermination()
            await shutdownFinished.set()
        }
        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()
        await provider.allowDispose()

        let settledWithinBound = await waitUntil {
            await shutdownFinished.current()
        }
        XCTAssertTrue(settledWithinBound)

        await executionGate.open()
        await shutdown.value
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testWindowRegistrationIsRejectedAfterTerminationSignal() {
        let manager = WindowStatesManager.shared
        let window = makeWindow()
        manager.setTerminatingForTesting(true)
        defer {
            if manager.allWindows.contains(where: { $0 === window }) {
                manager.unregisterWindowState(window)
            }
            manager.setTerminatingForTesting(false)
        }

        manager.registerWindowState(window)

        XCTAssertTrue(window.isClosing)
        XCTAssertFalse(manager.allWindows.contains { $0 === window })
    }

    func testManagerShutdownIncludesWindowUnregisteredBeforeTerminationSignal() async {
        let manager = WindowStatesManager.shared
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let firstEvent = ContextBuilderTestFirstEvent()
        let provider = GatedHeadlessAgentProvider {
            await firstEvent.signal(.providerDisposalStarted)
        }
        let executionGate = ContextBuilderTestGate()
        let closingCaptureGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: false, releaseActiveSlot: true))

        manager.registerWindowState(window)
        let pendingTearDown = Task { @MainActor [window] in
            await closingCaptureGate.wait()
            _ = window.windowID
        }
        await closingCaptureGate.waitUntilEntered()
        manager.unregisterWindowState(window)
        XCTAssertFalse(manager.allWindows.contains { $0 === window })

        let shutdownFinished = ContextBuilderTestFlag()
        let shutdown = Task {
            await manager.shutdownAllAgentSessions()
            await shutdownFinished.set()
            await firstEvent.signal(.managerShutdownFinished)
        }

        let observedFirstEvent = await firstEvent.wait()
        XCTAssertEqual(observedFirstEvent, .providerDisposalStarted)
        guard observedFirstEvent == .providerDisposalStarted else {
            await provider.allowDispose()
            await executionGate.open()
            await viewModel.shutdownForAppTermination()
            await closingCaptureGate.open()
            await pendingTearDown.value
            return
        }

        await executionGate.waitUntilEntered()
        let finishedBeforeGatesOpen = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeGatesOpen)
        await provider.allowDispose()
        let finishedBeforeExecution = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeExecution)
        await executionGate.open()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
        await closingCaptureGate.open()
        await pendingTearDown.value
    }

    func testManagerStartsAgentModeShutdownWhileFinalContextCancellationIsDeferred() async {
        let manager = WindowStatesManager.shared
        let window = makeWindow()
        defer {
            if manager.allWindows.contains(where: { $0 === window }) {
                manager.unregisterWindowState(window)
            }
            manager.setTerminatingForTesting(false)
        }

        let contextBuilderViewModel = window.contextBuilderAgentViewModel
        contextBuilderViewModel.setCloseSettlementGraceForTesting(5_000_000_000)
        let provider = GatedHeadlessAgentProvider()
        let finalContextGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        let executionTask = Task { @MainActor [weak contextBuilderViewModel, record] in
            await finalContextGate.wait()
            _ = contextBuilderViewModel?.finishDeferredCancellationAtSafeBoundaryForTesting(record)
        }
        record.executionTask = executionTask
        XCTAssertTrue(contextBuilderViewModel.registerRunRecordForTesting(record, makeCurrent: true))
        XCTAssertTrue(record.claimFinalContextCommit())

        let controller = ShutdownRecordingNativeController()
        let agentSession = AgentTabSession(tabID: UUID())
        agentSession.claudeController = controller
        window.agentModeViewModel.test_installLiveSession(agentSession)

        manager.registerWindowState(window)
        manager.signalTermination()
        let shutdown = Task { await manager.shutdownAllAgentSessions() }

        let agentShutdownStarted = await waitUntil {
            await controller.shutdownCallCount() == 1
        }
        XCTAssertTrue(agentShutdownStarted)
        XCTAssertEqual(record.cancellationState, .deferredUntilFinalContextCommitCompletes)
        let disposeCallCountBeforeSafeBoundary = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCountBeforeSafeBoundary, 0)

        await finalContextGate.open()
        await executionTask.value
        await provider.waitUntilDisposeStarted()
        await provider.allowDispose()
        await shutdown.value

        let shutdownCallCount = await controller.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testTerminationSignalRetainsMCPRunOwnerUntilManagerShutdownJoinsProvider() async {
        let manager = WindowStatesManager.shared
        defer { manager.setTerminatingForTesting(false) }
        var window: WindowState? = makeWindow()
        weak var weakWindow: WindowState?
        weakWindow = window
        let firstEvent = ContextBuilderTestFirstEvent()
        let provider = GatedHeadlessAgentProvider {
            await firstEvent.signal(.providerDisposalStarted)
        }
        let record = makeRecord(origin: .mcp(controlToken: UUID()))
        XCTAssertTrue(record.installProvider(provider))
        // The strong binding must stay scoped to this block: once `window` is cleared, the
        // manager's termination retention is the only thing keeping the window alive, which is
        // exactly what the deallocation assertion measures.
        if let registeredWindow = window {
            XCTAssertTrue(registeredWindow.contextBuilderAgentViewModel.registerRunRecordForTesting(
                record,
                makeCurrent: true
            ))
            manager.registerWindowState(registeredWindow)
            manager.signalTermination()
            manager.unregisterWindowState(registeredWindow)
        } else {
            XCTFail("Expected test window")
            return
        }
        window = nil

        let shutdown = Task {
            await manager.shutdownAllAgentSessions()
            await firstEvent.signal(.managerShutdownFinished)
        }
        let observedFirstEvent = await firstEvent.wait()
        guard observedFirstEvent == .providerDisposalStarted else {
            XCTFail("Expected provider disposal before manager shutdown finished, got \(observedFirstEvent)")
            await shutdown.value
            return
        }

        await provider.allowDispose()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
        XCTAssertNil(weakWindow)
    }

    func testAppShutdownJoinsAlreadyStartedTeardownWithoutDuplicateDisposal() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: false))
        viewModel.scheduleRunTeardownForTesting(record)
        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()

        let shutdown = Task { await viewModel.shutdownForAppTermination() }
        await provider.allowDispose()
        await executionGate.open()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testStartedTeardownSettlesAfterViewModelDeallocationWithoutDuplicateDisposal() async {
        var window: WindowState? = makeWindow()
        weak var weakViewModel = window?.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(weakViewModel?.registerRunRecordForTesting(record, makeCurrent: false) == true)
        weakViewModel?.scheduleRunTeardownForTesting(record)
        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()

        window?.beginClose()
        window = nil
        XCTAssertNil(weakViewModel)

        await provider.allowDispose()
        await executionGate.open()
        await record.awaitTeardownSettlement()
        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
    }

    func testOrdinaryCancellationWaitsForClaimedFinalContextSafeBoundary() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let safeBoundaryGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        let executionTask = Task { @MainActor [weak viewModel, record] in
            await safeBoundaryGate.wait()
            _ = viewModel?.finishDeferredCancellationAtSafeBoundaryForTesting(record)
        }
        record.executionTask = executionTask
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))
        XCTAssertTrue(record.claimFinalContextCommit())

        viewModel.cancelRunForTesting(record)

        XCTAssertEqual(record.cancellationState, .deferredUntilFinalContextCommitCompletes)
        let disposeCallCountBeforeSafeBoundary = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCountBeforeSafeBoundary, 0)
        await safeBoundaryGate.open()
        await executionTask.value
        await provider.waitUntilDisposeStarted()
        await provider.allowDispose()
        await record.awaitTeardownSettlement()

        XCTAssertEqual(record.terminalOutcome, .cancelled)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testOrdinaryCancellationWaitsForStaleClaimedFinalContextSafeBoundary() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let safeBoundaryGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        let executionTask = Task { @MainActor [weak viewModel, record] in
            await safeBoundaryGate.wait()
            _ = viewModel?.finishDeferredCancellationAtSafeBoundaryForTesting(record)
        }
        record.executionTask = executionTask
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true, releaseActiveSlot: true))
        XCTAssertTrue(record.claimFinalContextCommit())

        viewModel.cancelRunForTesting(record)

        XCTAssertEqual(record.cancellationState, .deferredUntilFinalContextCommitCompletes)
        let disposeCallCountBeforeSafeBoundary = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCountBeforeSafeBoundary, 0)
        await safeBoundaryGate.open()
        await executionTask.value
        await provider.waitUntilDisposeStarted()
        await provider.allowDispose()
        await record.awaitTeardownSettlement()

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertEqual(record.terminalOutcome, .cancelled)
        XCTAssertNotNil(record.teardownFinishedAt)
    }

    func testAppTerminationForcesClaimedFinalContextAfterGrace() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        viewModel.setCloseSettlementGraceForTesting(1)
        let provider = GatedHeadlessAgentProvider()
        let safeBoundaryGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        let executionTask = Task { @MainActor [weak viewModel, record] in
            await safeBoundaryGate.wait()
            _ = viewModel?.finishDeferredCancellationAtSafeBoundaryForTesting(record)
        }
        record.executionTask = executionTask
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))
        XCTAssertTrue(record.claimFinalContextCommit())

        let shutdown = Task { await viewModel.shutdownForAppTermination() }
        await provider.waitUntilDisposeStarted()

        XCTAssertEqual(record.cancellationState, .applied)
        XCTAssertEqual(record.terminalOutcome, .cancelled)
        XCTAssertFalse(viewModel.acceptsRunEventsForTesting(record))
        await provider.allowDispose()
        await shutdown.value

        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertNotNil(record.teardownFinishedAt)
        let registryReleased = await waitUntil {
            !viewModel.retainsRunRecordForTesting(record)
        }
        XCTAssertTrue(registryReleased)

        await safeBoundaryGate.open()
        await executionTask.value
    }

    func testExplicitCancellationAndNormalCompletionResolveBeforeGatedTeardown() async throws {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel

        try await assertWaiterResolvesBeforeTeardown(
            viewModel: viewModel,
            terminalOutcome: .cancelled,
            settle: { viewModel.cancelRunForTesting($0) }
        )
        try await assertWaiterResolvesBeforeTeardown(
            viewModel: viewModel,
            terminalOutcome: .completed,
            settle: { _ = viewModel.finalizeRunForTesting($0, outcome: .completed) }
        )
    }

    private func assertWaiterResolvesBeforeTeardown(
        viewModel: ContextBuilderAgentViewModel,
        terminalOutcome: ContextBuilderRunTerminalOutcome,
        settle: (ContextBuilderRunRecord) -> Void
    ) async throws {
        var capturedContinuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>?
        let waiter = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                capturedContinuation = continuation
            }
        }
        while capturedContinuation == nil {
            await Task.yield()
        }

        let provider = GatedHeadlessAgentProvider()
        let executionGate = ContextBuilderTestGate()
        let record = makeRecord(
            continuation: capturedContinuation
        )
        XCTAssertTrue(record.installProvider(provider))
        record.executionTask = Task { await executionGate.wait() }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))

        settle(record)
        let completion = try await waiter.value
        XCTAssertEqual(completion.terminalDisposition, terminalOutcome)
        XCTAssertNil(record.teardownFinishedAt)

        await provider.waitUntilDisposeStarted()
        await executionGate.waitUntilEntered()
        await provider.allowDispose()
        await executionGate.open()
        await record.awaitTeardownSettlement()
        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
    }

    private func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowState(contextBuilderProviderFactory: { _, _, _, _ in
            UnsupportedHeadlessAgentProvider(reason: "Unused by synthetic lifecycle tests")
        })
    }

    private func makeRecord(
        continuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>? = nil,
        origin: ContextBuilderRunOrigin = .ui
    ) -> ContextBuilderRunRecord {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        return ContextBuilderRunRecord(
            runID: UUID(),
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "graceful-shutdown-test"),
            origin: origin,
            agentKind: .claudeCode,
            modelRaw: AgentModel.defaultModel.rawValue,
            continuation: continuation
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

private actor ShutdownRecordingNativeController: NativeAgentRuntimeControlling {
    private var shutdownCalls = 0

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        AsyncStream { $0.finish() }
    }

    func ensureEventsStreamReady() {}
    func resetEventsStreamForNewRun() {}

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: existingSessionID)
    }

    func currentSessionRef() -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "completed-test-session")
    }

    func applyModelAndEffort(
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?
    ) async throws {}

    func sendUserMessage(_ text: String) async throws -> UUID {
        UUID()
    }

    func interruptTurn(reason: String) -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() {
        shutdownCalls += 1
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) {}

    func shutdownCallCount() -> Int {
        shutdownCalls
    }
}

@MainActor
final class ContextBuilderWindowAdmissionTests: XCTestCase {
    private let streamGate = ContextBuilderTestGate()
    /// Providers in the order their runs started; see `startRun`.
    private var providers: [GatedHeadlessAgentProvider] = []

    /// Each compose tab admits its own run: two tabs in one window run together, and a tab that
    /// already runs one refuses a second before it creates a provider.
    func testTabsInOneWindowRunConcurrentlyAndABusyTabRefusesASecondRun() async throws {
        let (window, tabIDs) = await makeGatedWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let first = try await startRun(window, tabID: tabIDs[0])
        let second = try await startRun(window, tabID: tabIDs[1])
        XCTAssertNotNil(viewModel.activeRunIDForTesting(tabID: tabIDs[0]))

        do {
            _ = try await runMCP(window, tabID: tabIDs[0])
            XCTFail("Expected the busy tab to refuse a second run")
        } catch {
            XCTAssertEqual((error as NSError).code, 2, "Expected the busy-tab refusal, got \(error)")
        }
        XCTAssertEqual(providers.count, 2)
        XCTAssertNotNil(viewModel.activeRunIDForTesting(tabID: tabIDs[0]))

        await streamGate.open()
        _ = try await first.value
        _ = try await second.value
        let successor = try viewModel.beginMCPControlledRun(forTabID: tabIDs[0], responseType: nil, planModelName: nil)
        await viewModel.clearMCPControlledRun(forTabID: tabIDs[0], controlToken: successor)
    }

    /// Closing a tab cancels that tab's run and releases its claim, while the run in the window's
    /// other tab keeps going to a normal finish.
    func testClosingATabCancelsOnlyItsOwnRun() async throws {
        let (window, tabIDs) = await makeGatedWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let closing = try await startRun(window, tabID: tabIDs[0])
        let staying = try await startRun(window, tabID: tabIDs[1])

        let report = await window.promptManager.closeComposeTab(tabIDs[0])
        XCTAssertEqual(report.removedComposeTabIDs, [tabIDs[0]])
        XCTAssertNil(viewModel.activeRunIDForTesting(tabID: tabIDs[0]))
        XCTAssertNotNil(viewModel.activeRunIDForTesting(tabID: tabIDs[1]))
        let stayingDisposals = await providers[1].disposeCallCount()
        XCTAssertEqual(stayingDisposals, 0)

        await streamGate.open()
        do {
            _ = try await closing.value
            XCTFail("Expected the closed tab's call to end cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let closedTabDisposed = await waitUntil { await self.providers[0].disposeCallCount() == 1 }
        XCTAssertTrue(closedTabDisposed, "The closed tab's provider was not disposed")
        let stayingCompletion = try await staying.value
        // This provider opens no MCP client, so its own finish is `mcp_completed_without_route`.
        XCTAssertNotEqual(stayingCompletion.terminalDisposition, .cancelled)
    }

    /// Closing a window ends every run it holds: each is cancelled as the close begins, ahead of
    /// the window's teardown, and the teardown disposes each run's provider once.
    func testClosingAWindowEndsItsRuns() async throws {
        let (window, tabIDs) = await makeGatedWindow()
        let viewModel = window.contextBuilderAgentViewModel
        var runs = try await [startRun(window, tabID: tabIDs[0])]
        // A second run that does not start has already failed the test; the close is checked anyway.
        if let second = try? await startRun(window, tabID: tabIDs[1]) { runs.append(second) }

        window.beginClose()
        let cancelledAsCloseBegan = await waitUntil {
            tabIDs.allSatisfy { viewModel.activeRunIDForTesting(tabID: $0) == nil }
        }
        XCTAssertTrue(cancelledAsCloseBegan, "Runs were still active after the window's close began")

        await streamGate.open()
        for run in runs {
            do {
                _ = try await run.value
                XCTFail("Expected the closed window's call to end cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
        await window.tearDown()
        for provider in providers {
            let disposals = await provider.disposeCallCount()
            XCTAssertEqual(disposals, 1)
        }
    }

    /// A cancelled MCP call keeps its tab until its run's execution has ended, so no new run can
    /// claim the tab while the cancelled one is still unwinding.
    func testCancelledCallKeepsItsTabUntilItsExecutionEnds() async throws {
        let execution = ContextBuilderTestGate()
        let (window, tabIDs) = await makeGatedWindow(event: "Looking around")
        let viewModel = window.contextBuilderAgentViewModel
        viewModel.installRunTestHooks(.init(
            beforeProcessingProviderEvent: { _, _ in await execution.wait() },
            providerEventDisposition: nil,
            teardownCompleted: nil
        ))
        addTeardownBlock { await execution.open() }
        let call = try await startRun(window, tabID: tabIDs[0])
        let executionHeld = await waitUntil { await execution.entered }
        XCTAssertTrue(executionHeld, "The run never reached its provider's event")

        await viewModel.cancelMCPContextBuilderRun(forTabID: tabIDs[0])
        let claimedWhileExecuting = await waitUntil(timeout: .milliseconds(200)) {
            guard let probe = try? viewModel.beginMCPControlledRun(
                forTabID: tabIDs[0], responseType: nil, planModelName: nil
            ) else { return false }
            await viewModel.clearMCPControlledRun(forTabID: tabIDs[0], controlToken: probe)
            return true
        }
        XCTAssertFalse(claimedWhileExecuting, "The tab was claimable while the cancelled run was still executing")

        await execution.open()
        await streamGate.open()
        do {
            _ = try await call.value
            XCTFail("Expected the cancelled call to end cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let successor = try viewModel.beginMCPControlledRun(
            forTabID: tabIDs[0], responseType: nil, planModelName: nil
        )
        await viewModel.clearMCPControlledRun(forTabID: tabIDs[0], controlToken: successor)
    }

    func testFailureBeforeProviderCreationReleasesAdmission() async throws {
        var providerCount = 0
        let provider = GatedHeadlessAgentProvider()
        let (window, tabIDs) = await makeWindow { _, _, _, _ in
            providerCount += 1
            return provider
        }
        addTeardownBlock { @MainActor in
            _ = await window.mcpServer.setWindowToolsEnabled(false)
        }
        let viewModel = window.contextBuilderAgentViewModel

        do {
            _ = try await runMCP(window, tabID: UUID())
            XCTFail("Expected missing workspace failure")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(providerCount, 0)
        let token = try viewModel.beginMCPControlledRun(
            forTabID: tabIDs[0], responseType: nil, planModelName: nil
        )
        await viewModel.clearMCPControlledRun(forTabID: tabIDs[0], controlToken: token)
        await provider.allowDispose()
    }

    /// The frozen model-parameter selections admitted with the run reach the provider factory
    /// unchanged, and each run carries only its own admitted selections — a second run with
    /// different authority selections proves nothing stale is reused across runs.
    func testAdmittedModelParameterSelectionsReachProviderFactoryUnchanged() async throws {
        let highPin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let lowPin = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "low"
        )
        var receivedSelections: [[ACPModelParameterSelection]] = []
        let (window, tabIDs) = await makeWindow { _, _, _, modelParameterSelections in
            receivedSelections.append(modelParameterSelections)
            let provider = GatedHeadlessAgentProvider()
            Task { await provider.allowDispose() }
            return provider
        }
        addTeardownBlock { @MainActor in
            _ = await window.mcpServer.setWindowToolsEnabled(false)
        }

        _ = try await runMCP(window, tabID: tabIDs[0], modelParameterSelections: [highPin])
        _ = try await runMCP(window, tabID: tabIDs[1], modelParameterSelections: [lowPin])

        XCTAssertEqual(receivedSelections, [[highPin], [lowPin]])
    }

    private func runMCP(
        _ window: WindowState,
        tabID: UUID,
        modelParameterSelections: [ACPModelParameterSelection] = []
    ) async throws -> ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion {
        let viewModel = window.contextBuilderAgentViewModel
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let identity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID)
        var nested = MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.mcpServer.windowID,
            workspaceID: workspace.id,
            promptText: "",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            selectedContextBuilderPromptIDs: [],
            tabName: "",
            runID: nil,
            explicitlyBound: true
        )
        nested.frozenLookupContext = .visibleWorkspace
        let configuration = ContextBuilderMCPRunConfiguration(
            identity: identity,
            nestedTabContext: nested,
            providerWorkspacePath: FileManager.default.temporaryDirectory.path,
            runBehavior: ContextBuilderRunBehavior(
                tokenBudget: 1000,
                enhancementMode: .preserve,
                questionTimeoutSeconds: 1,
                allowClarifyingQuestions: false,
                automaticFollowUp: nil
            ),
            responseType: nil,
            planningModelRaw: nil,
            isSystemWorkspace: false
        )
        let token = try viewModel.beginMCPControlledRun(forTabID: tabID, responseType: nil, planModelName: nil)
        return try await AsyncScope.withCleanup({}, cleanup: {
            await viewModel.clearMCPControlledRun(forTabID: tabID, controlToken: token)
        }) {
            try await viewModel.runContextBuilderForMCP(
                authority: ContextBuilderResolvedRunAuthority(
                    configuration: configuration,
                    agentKind: .claudeCode,
                    modelRaw: AgentModel.defaultModel.rawValue,
                    modelParameterSelections: modelParameterSelections
                ),
                mcpControlToken: token
            )
        }
    }

    /// A window whose every run gets a new provider that streams `event`, when given, and then
    /// waits for `streamGate` before it finishes. Teardown opens that gate and every provider's
    /// disposal gate, so none stays closed after a failed test.
    private func makeGatedWindow(event: String? = nil) async -> (WindowState, [UUID]) {
        let (window, tabIDs) = await makeWindow { [unowned self] _, _, _, _ in
            let provider = GatedHeadlessAgentProvider(streamGate: streamGate, event: event)
            providers.append(provider)
            return provider
        }
        addTeardownBlock { @MainActor in
            await self.streamGate.open()
            for provider in self.providers {
                await provider.allowDispose()
            }
            _ = await window.mcpServer.setWindowToolsEnabled(false)
        }
        return (window, tabIDs)
    }

    /// Starts an MCP run on `tabID` and returns once it is registered on the tab with its own
    /// provider, so `providers` stays in start order. A run that never starts fails the test here.
    private func startRun(
        _ window: WindowState,
        tabID: UUID
    ) async throws -> Task<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error> {
        let providerCount = providers.count
        let run = Task { try await self.runMCP(window, tabID: tabID) }
        let started = await waitUntil {
            self.providers.count > providerCount
                && window.contextBuilderAgentViewModel.activeRunIDForTesting(tabID: tabID) != nil
        }
        // Disposal is not under test; leaving it gated would only stall a close that joins it.
        await providers.last?.allowDispose()
        return try XCTUnwrap(
            started ? run : nil,
            "The run on tab \(tabID) did not start after \(providerCount) earlier run(s) had started"
        )
    }

    private func makeWindow(
        providerFactory: @escaping ContextBuilderAgentViewModel.ProviderFactory
    ) async -> (WindowState, [UUID]) {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let window = WindowState(contextBuilderProviderFactory: providerFactory)
        await window.workspaceManager.awaitInitialized()
        _ = await window.mcpServer.setWindowToolsEnabled(true)
        let tabs = [ComposeTabState(name: "First"), ComposeTabState(name: "Second")]
        let workspace = WorkspaceModel(
            name: "Window admission",
            repoPaths: [FileManager.default.temporaryDirectory.path],
            composeTabs: tabs,
            activeComposeTabID: tabs[0].id
        )
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.promptManager.loadComposeTabsFromWorkspace(workspace)
        return (window, tabs.map(\.id))
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private final class GatedHeadlessAgentProvider: HeadlessAgentProvider, @unchecked Sendable {
    private let disposeGate = ContextBuilderTestGate()
    private let state = GatedHeadlessAgentProviderState()
    private let streamGate: ContextBuilderTestGate?
    private let event: String?
    private let onDisposeStarted: @Sendable () async -> Void

    init(
        streamGate: ContextBuilderTestGate? = nil,
        event: String? = nil,
        onDisposeStarted: @escaping @Sendable () async -> Void = {}
    ) {
        self.streamGate = streamGate
        self.event = event
        self.onDisposeStarted = onDisposeStarted
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            if let event {
                continuation.yield(AIStreamResult(type: "content", text: event))
            }
            guard let streamGate else {
                continuation.finish()
                return
            }
            Task {
                await streamGate.wait()
                continuation.finish()
            }
        }
    }

    func dispose() async {
        await state.noteDisposeStarted()
        await onDisposeStarted()
        await disposeGate.wait()
    }

    func waitUntilDisposeStarted() async {
        await state.waitUntilDisposeStarted()
    }

    func allowDispose() async {
        await disposeGate.open()
    }

    func disposeCallCount() async -> Int {
        await state.disposeCallCount
    }
}

private actor GatedHeadlessAgentProviderState {
    private(set) var disposeCallCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func noteDisposeStarted() {
        disposeCallCount += 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilDisposeStarted() async {
        if disposeCallCount > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

actor ContextBuilderTestGate {
    private var isOpen = false
    private(set) var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = openWaiters
        openWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ContextBuilderTestFirstEvent {
    enum Event: Equatable {
        case providerDisposalStarted
        case managerShutdownFinished
    }

    private var firstEvent: Event?
    private var waiters: [CheckedContinuation<Event, Never>] = []

    func signal(_ event: Event) {
        guard firstEvent == nil else { return }
        firstEvent = event
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: event) }
    }

    func wait() async -> Event {
        if let firstEvent { return firstEvent }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ContextBuilderTestFlag {
    private var value = false

    func set() {
        value = true
    }

    func current() -> Bool {
        value
    }
}
