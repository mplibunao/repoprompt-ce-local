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

    /// Waiting for a run's execution ends when the execution has ended or teardown has stopped
    /// waiting for it, whether the wait began before or after that, and does not wait for the
    /// provider's disposal.
    func testExecutionSettlementResumesEarlyAndLateWaitersWithoutProviderDisposal() async {
        let record = makeRecord()
        XCTAssertNotNil(record.beginTeardown())
        // A waiter counts itself in the turn that enrols it: nothing suspends between the count
        // and the wait, and the wait suspends only once it is enrolled.
        let waits = SettlementWaits()
        for _ in 0 ..< 2 {
            Task {
                waits.enrolled += 1
                await record.awaitExecutionSettlement()
                waits.resumed += 1
            }
        }
        while waits.enrolled < 2 {
            await Task.yield()
        }
        await Task.yield()
        XCTAssertEqual(waits.resumed, 0, "Both waits began before execution settled and are still waiting")
        XCTAssertFalse(record.executionTaskFinished)

        record.stopAwaitingExecutionTaskForClose()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while waits.resumed < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(waits.resumed, 2, "Settlement resumed both waits that were enrolled before it")

        // A wait that begins after settlement has nothing to enrol for.
        await record.awaitExecutionSettlement()
        XCTAssertTrue(record.executionTaskFinished)
        XCTAssertFalse(record.providerDisposalFinished)
        XCTAssertNil(record.teardownFinishedAt)
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

    /// A provider start that ignores cancellation does not hold app termination. Shutdown joins
    /// the provider's first disposal and then, once the grace expires, settles with the start
    /// still held. The disposal that has to follow that start is not reported as finished until
    /// the start has returned and the provider has been disposed again.
    func testAppTerminationStopsWaitingForProviderStartAfterGrace() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        viewModel.setCloseSettlementGraceForTesting(1)
        let provider = GatedHeadlessAgentProvider()
        let startGate = ContextBuilderTestGate()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        let start = record.beginProviderStart {
            await startGate.wait()
            return AsyncThrowingStream { $0.finish() }
        }
        XCTAssertNotNil(start)
        record.executionTask = Task { @MainActor in
            _ = try? await start?.stream()
        }
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))

        let shutdownFinished = ContextBuilderTestFlag()
        let shutdown = ContextBuilderTestTaskHandle()
        // Runs once the test has returned, so it opens neither hold while the expectations below
        // are checked. When the test returns early it opens both before it joins shutdown, which
        // can be waiting behind either.
        addTeardownBlock { @MainActor in
            await provider.allowDispose()
            await startGate.open()
            await shutdown.task?.value
        }
        shutdown.task = Task {
            await viewModel.shutdownForAppTermination()
            await shutdownFinished.set()
        }
        guard await waitUntil(condition: { await provider.disposeCallCount() > 0 }) else {
            XCTFail("Shutdown did not start disposing the provider.")
            return
        }
        guard await waitUntil(condition: { await startGate.entered }) else {
            XCTFail("The provider start did not reach its hold.")
            return
        }
        let finishedBeforeFirstDisposal = await shutdownFinished.current()
        XCTAssertFalse(finishedBeforeFirstDisposal)
        await provider.allowDispose()

        let settledWithStartHeld = await waitUntil {
            await shutdownFinished.current()
        }
        XCTAssertTrue(settledWithStartHeld)
        XCTAssertEqual(record.terminalOutcome, .cancelled)
        XCTAssertFalse(record.providerDisposalFinished)
        let disposeCallsWithStartHeld = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallsWithStartHeld, 1)

        await startGate.open()
        await shutdown.task?.value
        let disposedAfterStart = await waitUntil {
            record.providerDisposalFinished
        }
        XCTAssertTrue(disposedAfterStart)
        let disposeCallsAfterStart = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallsAfterStart, 2)
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

    /// Closing a tab retires every run registered for it and nothing else. That includes a
    /// superseded record that no longer owns the tab, and a record on a tab that has no session,
    /// each of which still owns a provider. A run on another tab keeps its claim, its routing
    /// policy, and its provider, and completes with its own commit.
    func testTabCloseRetiresOnlyClosingTabIncludingHiddenRecord() async throws {
        try await ContextBuilderRunFixture.withFixture(tabNames: ["kept", "closing", "sessionless"]) { fixture, _ in
            let viewModel = fixture.viewModel
            let kept = fixture.slots[0]
            let closing = fixture.slots[1]
            let sessionless = fixture.slots[2]

            let hiddenRecords = [makeRecord(tabID: closing.tabID), makeRecord(tabID: sessionless.tabID)]
            let hiddenProviders = [GatedHeadlessAgentProvider(), GatedHeadlessAgentProvider()]
            for (record, provider) in zip(hiddenRecords, hiddenProviders) {
                await provider.allowDispose()
                XCTAssertTrue(record.installProvider(provider))
                XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: false, releaseActiveSlot: true))
            }
            XCTAssertNil(viewModel.sessions[sessionless.tabID])

            fixture.holdsChildConnections = true
            let keptRun = fixture.startMCPRun(on: kept)
            let closingRun = fixture.startMCPRun(on: closing)
            try await fixture.waitFor("both tabs' providers to be ready to connect") {
                [kept, closing].allSatisfy {
                    fixture.child(forRunID: fixture.activeRunID($0))?.registeredProviderPID != nil
                }
            }
            let keptRunID = try XCTUnwrap(fixture.activeRunID(kept))
            let keptChild = try XCTUnwrap(fixture.child(forRunID: keptRunID))
            let keptToken = try XCTUnwrap(fixture.operationToken(kept))
            let closingRunID = try XCTUnwrap(fixture.activeRunID(closing))
            let closingChild = try XCTUnwrap(fixture.child(forRunID: closingRunID))

            await fixture.window.promptManager.closeComposeTab(closing.tabID)
            await fixture.window.promptManager.closeComposeTab(sessionless.tabID)
            XCTAssertNil(fixture.storedTab(closing), "The tab closed")
            XCTAssertNil(fixture.storedTab(sessionless), "The tab closed")

            XCTAssertEqual(hiddenRecords.map(\.terminalOutcome), [.cancelled, .cancelled])
            XCTAssertNil(viewModel.sessions[closing.tabID])
            XCTAssertNil(fixture.activeRunID(closing))
            XCTAssertEqual(viewModel.tabsWithActiveContextBuilderRun, [kept.tabID])
            try await fixture.waitFor("the closing tab's run to return", allowingRunErrors: true) {
                closingRun.result != nil
            }
            XCTAssertThrowsError(try XCTUnwrap(closingRun.result).get()) { XCTAssertTrue($0 is CancellationError) }
            try await fixture.waitFor("the closed tabs' runs to be torn down", allowingRunErrors: true) {
                hiddenRecords.allSatisfy { $0.teardownFinishedAt != nil }
                    && !viewModel.isRunTeardownPendingForTesting(runID: closingRunID)
                    && closingChild.disposeCount > 0
            }
            XCTAssertEqual(closingChild.disposeCount, 1)
            for provider in hiddenProviders {
                let disposeCallCount = await provider.disposeCallCount()
                XCTAssertEqual(disposeCallCount, 1)
            }

            XCTAssertNil(keptRun.result)
            XCTAssertEqual(fixture.operationToken(kept), keptToken)
            XCTAssertEqual(fixture.activeRunID(kept), keptRunID)
            XCTAssertEqual(keptChild.disposeCount, 0)
            let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
            XCTAssertTrue(pendingRunIDs.contains(keptRunID))

            await keptChild.allowConnection()
            try await fixture.waitFor("the kept tab's run to return", allowingRunErrors: true) {
                keptRun.result != nil
            }
            try fixture.assertCommitted(XCTUnwrap(keptRun.result).get(), by: keptChild)
        }
    }

    /// An ordinary window close ends whatever phase each tab's Context Builder operation is in:
    /// an MCP call still preparing, a discovery run, a superseded record that no longer owns its
    /// tab, and a follow-up that is all that still holds a tab. The discovery run's provider
    /// start ignores cancellation and stays held throughout, and the close still returns.
    /// Afterwards every claim is released and every provider is disposed.
    func testWindowCloseCancelsPreparationDiscoveryAndFollowUp() async throws {
        try await ContextBuilderRunFixture.withFixture(
            tabNames: ["following", "preparing", "discovering"]
        ) { fixture, cleanup in
            let viewModel = fixture.viewModel
            let following = fixture.slots[0]
            let preparing = fixture.slots[1]
            let discovering = fixture.slots[2]
            await fixture.startWindowServer()
            fixture.makeRunAuthorityResolvable(cleanup: cleanup)
            let caller = try await fixture.connectCaller("window-close", cleanup: cleanup)
            fixture.enableAutomaticFollowUp(cleanup: cleanup)

            let observed = WindowCloseObservations()
            let followUpStep = ContextBuilderCancellableTestGate()
            let preparationStep = ContextBuilderCancellableTestGate()
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle {
                followUpStep.open()
                preparationStep.open()
            }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                runUIFollowUp: { _, _ in
                    do {
                        try await followUpStep.wait()
                    } catch {
                        observed.followUpWasCancelled = true
                        throw error
                    }
                    throw CancellationError()
                },
                validateContextBuilderProviders: {
                    do {
                        try await preparationStep.wait()
                    } catch {
                        observed.preparationWasCancelled = true
                    }
                }
            ))

            // Follow-up: a completed UI run whose automatic follow-up is all that holds its tab.
            let pressed = await fixture.pressRun(on: following)
            let followingRunID = try XCTUnwrap(pressed)
            try await fixture.waitFor("the follow-up to be all that still holds its tab") {
                followUpStep.entryCount == 1 && fixture.operationToken(following)?.isHeldByFollowUpOnly == true
            }
            let followingSession = try XCTUnwrap(fixture.session(following))
            XCTAssertNil(fixture.activeRunID(following))

            // Discovery: a run whose provider start ignores cancellation, on a tab that also has
            // a superseded record.
            let hiddenRecord = makeRecord(tabID: discovering.tabID)
            let hiddenProvider = GatedHeadlessAgentProvider()
            await hiddenProvider.allowDispose()
            XCTAssertTrue(hiddenRecord.installProvider(hiddenProvider))
            XCTAssertTrue(viewModel.registerRunRecordForTesting(hiddenRecord, makeCurrent: false, releaseActiveSlot: true))
            let startingProvider = StartHeldHeadlessAgentProvider()
            fixture.providerScript = { _ in startingProvider }
            fixture.releaseOnSettle { await startingProvider.releaseStart() }
            let discoveringRun = fixture.startMCPRun(on: discovering)
            try await fixture.waitFor("the discovery run's provider start to be held") {
                await startingProvider.startWasEntered()
            }
            let discoveringRunID = try XCTUnwrap(fixture.activeRunID(discovering))

            // Preparation: a tool call that has claimed its tab and has no run yet.
            let preparingCall = Task { @MainActor in
                observed.preparingResponse = try? await caller.callTool(
                    name: MCPWindowToolName.contextBuilder,
                    arguments: ["context_id": preparing.tabID.uuidString, "instructions": "Find the entry point"],
                    timeoutSeconds: 120
                )
                observed.preparingCallEnded = true
            }
            fixture.releaseOnSettle { await preparingCall.value }
            try await fixture.waitFor("the call to be held in its preparation") {
                preparationStep.entryCount == 1
            }
            XCTAssertEqual(fixture.operationToken(preparing)?.origin, .mcp)
            XCTAssertNil(fixture.activeRunID(preparing))

            Task { @MainActor in
                fixture.window.beginClose()
                await fixture.window.tearDown()
                observed.closeReturned = true
            }
            try await fixture.waitFor(
                "the window's close to return with the provider start still held",
                allowingRunErrors: true
            ) { observed.closeReturned }

            // What the close had cancelled by the time it returned.
            XCTAssertTrue(observed.preparationWasCancelled)
            XCTAssertNil(fixture.activeRunID(discovering))
            XCTAssertEqual(hiddenRecord.terminalOutcome, .cancelled)
            XCTAssertNotNil(hiddenRecord.teardownFinishedAt)
            XCTAssertTrue(observed.followUpWasCancelled)
            XCTAssertFalse(followingSession.isBackgroundPlanGenerating)
            let hiddenDisposeCount = await hiddenProvider.disposeCallCount()
            XCTAssertEqual(hiddenDisposeCount, 1)
            let disposeCountWithStartHeld = await startingProvider.disposeCallCount()
            XCTAssertEqual(disposeCountWithStartHeld, 1)

            // Each cancelled operation then ends for its owner and gives its tab back.
            try await fixture.waitFor("the preparing call to be answered", allowingRunErrors: true) {
                observed.preparingCallEnded
            }
            XCTAssertEqual(observed.preparingResponse?.rawJSON.contains("Tool execution was cancelled."), true)
            XCTAssertNil(fixture.operationToken(preparing))
            try await fixture.waitFor("the discovery run to return", allowingRunErrors: true) {
                discoveringRun.result != nil
            }
            XCTAssertThrowsError(try XCTUnwrap(discoveringRun.result).get()) { XCTAssertTrue($0 is CancellationError) }
            try await fixture.waitForRelease(of: following)

            // The provider whose start was held is disposed again once that start returns.
            await startingProvider.releaseStart()
            try await fixture.waitFor("the held start's provider to be disposed", allowingRunErrors: true) {
                await startingProvider.disposeCallCount() == 2
            }
            try await fixture.waitForRelease(of: discovering)
            XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [])
            XCTAssertEqual(viewModel.tabsWithActiveContextBuilderRun, [])
            XCTAssertEqual(fixture.child(forRunID: followingRunID)?.disposeCount, 1)
            XCTAssertFalse(viewModel.isRunTeardownPendingForTesting(runID: discoveringRunID))
            XCTAssertFalse(viewModel.retainsRunRecordForTesting(hiddenRecord))
        }
    }

    /// An ordinary window close asks a run to end as the close begins, in that same turn and
    /// before the window's teardown runs. Asking again changes nothing, and the teardown that
    /// follows still returns only once the run's provider has been disposed, once.
    func testWindowCloseRequestCancelsRunOnceAheadOfTeardown() async {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        let record = makeRecord()
        var tornDownRunIDs: [UUID] = []
        defer { viewModel.installRunTestHooks(nil) }
        viewModel.installRunTestHooks(.init(
            beforeProcessingProviderEvent: nil,
            providerEventDisposition: nil,
            teardownCompleted: { tornDownRunIDs.append($0) }
        ))
        XCTAssertTrue(record.installProvider(provider))
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))
        XCTAssertEqual(viewModel.activeRunIDForTesting(tabID: record.tabID), record.runID)

        window.beginClose()

        XCTAssertEqual(record.cancellationState, .requested)
        XCTAssertEqual(record.terminalOutcome, .cancelled)
        XCTAssertNil(viewModel.activeRunIDForTesting(tabID: record.tabID))

        window.beginClose()

        XCTAssertEqual(record.cancellationState, .requested)
        XCTAssertEqual(record.terminalOutcome, .cancelled)

        let close = Task { @MainActor in await window.tearDown() }
        guard await waitUntil(condition: { await provider.disposeCallCount() > 0 }) else {
            XCTFail("The window's close did not start disposing the provider.")
            await provider.allowDispose()
            await close.value
            return
        }
        XCTAssertNil(record.teardownFinishedAt)
        await provider.allowDispose()
        await close.value

        XCTAssertNotNil(record.teardownFinishedAt)
        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
        XCTAssertEqual(tornDownRunIDs, [record.runID])
    }

    /// As an ordinary window close begins it also asks to end what holds a tab outside a run and
    /// what a run is waiting on: a follow-up whose reply is still streaming into its chat, and a
    /// clarifying question that a run's child is waiting to have answered. Both are released from
    /// their tab's state before the window's teardown runs, and their callers settle afterwards.
    func testWindowCloseRequestCancelsFollowUpAndPendingQuestionAheadOfTeardown() async throws {
        try await ContextBuilderRunFixture.withFixture(tabNames: ["following", "asking"]) { fixture, cleanup in
            let viewModel = fixture.viewModel
            let following = fixture.slots[0]
            let asking = fixture.slots[1]
            try await fixture.saveChatsInTemporaryDirectory()
            cleanup.add { viewModel.installRunTestHooks(nil) }
            viewModel.installRunTestHooks(Self.hooksResolvingFollowUpModel)

            // Follow-up: an MCP answer whose reply is pending in the chat it streams into.
            let followUpClaim = try viewModel.beginMCPControlledRun(
                forTabID: following.tabID,
                workspaceID: fixture.workspaceID,
                responseType: "question",
                planModelName: nil
            )
            let followUpEnded = ContextBuilderTestFlag()
            let followUp = Task { @MainActor in
                try await viewModel.runMCPPlanOrQuestion(
                    for: fixture.identity(of: following),
                    oracleViewModel: fixture.window.oracleViewModel,
                    mode: .chat,
                    prompt: Self.followUpPrompt,
                    selection: StoredSelection(selectedPaths: [following.fileURL.path]),
                    reviewGitContext: .automaticOnly()
                )
            }
            Task {
                _ = await followUp.result
                await followUpEnded.set()
            }
            cleanup.add {
                followUp.cancel()
                _ = await followUp.result
            }
            _ = try await Self.firstRequest(sentBy: followUp, in: fixture)
            let followingSession = try XCTUnwrap(fixture.session(following))
            XCTAssertNotNil(followingSession.followUpOracleSessionID)
            XCTAssertTrue(followingSession.isBackgroundPlanGenerating)

            // Question: a run whose child is waiting for the user's answer.
            fixture.clarifyingQuestionTimeoutSeconds = 300
            fixture.holdsChildTurns = true
            let askingRun = fixture.startMCPRun(on: asking)
            let askingRunID = try await fixture.registeredRunID(on: asking)
            let askingChild = try await fixture.childWithRegisteredProcess(forRunID: askingRunID)
            fixture.releaseOnSettle { await askingChild.allowTurn() }
            try await fixture.waitFor("the asking tab's child to hold its turn") {
                await askingChild.isTurnHeld()
            }
            let askEnded = ContextBuilderTestFlag()
            let ask = Task {
                try await askingChild.callTool(
                    MCPWindowToolName.askUser,
                    ["question": "Which module does the asking tab mean?", "timeout_seconds": 300]
                )
            }
            Task {
                _ = await ask.result
                await askEnded.set()
            }
            try await fixture.waitFor("the asking tab's question to be pending") {
                fixture.session(asking)?.pendingAskUser != nil
            }
            let askingSession = try XCTUnwrap(fixture.session(asking))
            XCTAssertEqual(askingSession.pendingAskUserRunID, askingRunID)

            fixture.window.beginClose()

            XCTAssertNil(followingSession.followUpOracleSessionID)
            XCTAssertFalse(followingSession.isBackgroundPlanGenerating)
            XCTAssertNil(askingSession.pendingAskUser)
            XCTAssertNil(fixture.activeRunID(asking))

            await fixture.window.tearDown()

            // Each cancelled piece of work then ends for whoever was waiting on it.
            try await fixture.waitFor("the follow-up to end", allowingRunErrors: true) {
                await followUpEnded.current()
            }
            let followUpOutcome = await followUp.result
            XCTAssertThrowsError(try followUpOutcome.get()) {
                XCTAssertTrue($0 is CancellationError, "Ended with \($0)")
            }
            try await fixture.waitFor("the question's call to end", allowingRunErrors: true) {
                await askEnded.current()
            }
            // The child's call ends with the tool's cancellation, unless the run's connection was
            // closed before that reply could be written to it.
            if case let .success(reply) = await ask.result {
                XCTAssertTrue(reply.rawJSON.contains("Tool execution was cancelled."), reply.rawJSON)
            }
            try await fixture.waitFor("the asking tab's run to return", allowingRunErrors: true) {
                askingRun.result != nil
            }
            XCTAssertThrowsError(try XCTUnwrap(askingRun.result).get()) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(fixture.child(forRunID: askingRunID)?.disposeCount, 1)
            XCTAssertFalse(viewModel.isRunTeardownPendingForTesting(runID: askingRunID))
            await viewModel.clearMCPControlledRun(forTabID: following.tabID, controlToken: followUpClaim)
        }
    }

    /// While the app is terminating, a window's close request leaves the window's runs alone,
    /// because ending them is the termination's to do. The window still stops admitting work.
    func testWindowCloseRequestDuringAppTerminationLeavesRunsToTermination() async {
        let manager = WindowStatesManager.shared
        defer { manager.setTerminatingForTesting(false) }
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let provider = GatedHeadlessAgentProvider()
        await provider.allowDispose()
        let record = makeRecord()
        XCTAssertTrue(record.installProvider(provider))
        XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))
        XCTAssertThrowsError(
            try viewModel.requireMCPControlOwnership(forTabID: record.tabID, controlToken: UUID())
        ) { XCTAssertFalse($0 is CancellationError, "The window is still open: \($0)") }
        manager.setTerminatingForTesting(true)

        window.beginClose()

        XCTAssertEqual(record.cancellationState, .none)
        XCTAssertNil(record.terminalOutcome)
        XCTAssertEqual(viewModel.activeRunIDForTesting(tabID: record.tabID), record.runID)
        XCTAssertThrowsError(
            try viewModel.requireMCPControlOwnership(forTabID: record.tabID, controlToken: UUID())
        ) { XCTAssertTrue($0 is CancellationError, "The window stopped admitting work: \($0)") }

        await viewModel.shutdownForAppTermination()

        XCTAssertEqual(record.terminalOutcome, .cancelled)
        XCTAssertNotNil(record.teardownFinishedAt)
        let disposeCallCount = await provider.disposeCallCount()
        XCTAssertEqual(disposeCallCount, 1)
    }

    /// Switching the window's workspace cancels a UI run and leaves an MCP run alone. The
    /// cancelled UI run keeps its tab claimed until its own tail has run: its execution is held
    /// past the switch here, and for that whole time the tab admits no other run. The tab's
    /// session is replaced as before, so the claim is found on the replacement.
    func testWorkspaceSwitchDuringConcurrentUIAndMCPRuns() async throws {
        try await ContextBuilderRunFixture.withFixture(tabNames: ["ui", "mcp"]) { fixture, cleanup in
            let viewModel = fixture.viewModel
            let manager = fixture.window.workspaceManager
            let uiSlot = fixture.slots[0]
            let mcpSlot = fixture.slots[1]

            let processingGate = ContextBuilderTestGate()
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle { await processingGate.open() }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: { _, _ in await processingGate.wait() },
                providerEventDisposition: nil,
                teardownCompleted: nil
            ))
            let uiProvider = ContextBuilderUnroutedProvider(events: ["Looking around"])
            let mcpProvider = ContextBuilderUnroutedProvider()
            fixture.providerScript = { [unowned fixture] _ in
                fixture.providerRequests.count == 1 ? uiProvider : mcpProvider
            }
            fixture.releaseOnSettle {
                await uiProvider.finish()
                await mcpProvider.finish()
            }

            let pressed = await fixture.pressRun(on: uiSlot)
            let uiRunID = try XCTUnwrap(pressed)
            await processingGate.waitUntilEntered()
            let uiSession = try XCTUnwrap(fixture.session(uiSlot))
            let uiToken = try XCTUnwrap(fixture.operationToken(uiSlot))
            XCTAssertEqual(uiToken.id, uiRunID)

            let mcpRun = fixture.startMCPRun(on: mcpSlot)
            try await fixture.waitFor("the MCP run's provider to start its turn") { mcpProvider.runID != nil }
            let mcpRunID = try XCTUnwrap(fixture.activeRunID(mcpSlot))
            let mcpSession = try XCTUnwrap(fixture.session(mcpSlot))
            let mcpToken = try XCTUnwrap(fixture.operationToken(mcpSlot))

            let otherWorkspace = manager.createWorkspace(
                name: "Context Builder runs, other workspace",
                repoPaths: [fixture.rootURL.path],
                ephemeral: true
            )
            cleanup.add { manager.workspaces.removeAll { $0.id == otherWorkspace.id } }
            await manager.switchWorkspace(to: otherWorkspace, saveState: false, reason: "ContextBuilderGracefulShutdownTests")
            try await fixture.waitFor("the switch to cancel the UI run") { fixture.activeRunID(uiSlot) == nil }

            // The UI run is cancelled, and its claim still holds the tab.
            let replacement = try XCTUnwrap(fixture.session(uiSlot))
            XCTAssertFalse(replacement === uiSession)
            XCTAssertEqual(replacement.agentLog.count, 0)
            guard replacement.operationToken == uiToken else {
                XCTFail("The cancelled UI run's claim did not survive the workspace switch")
                throw ContextBuilderRunFixture.ScenarioAborted()
            }
            XCTAssertNil(uiSession.operationToken)
            XCTAssertTrue(viewModel.tabsHeldAgainstNewRun.contains(uiSlot.tabID))
            XCTAssertThrowsError(
                try viewModel.beginMCPControlledRun(
                    forTabID: uiSlot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
            ) { XCTAssertEqual(($0 as NSError).code, 2) }
            XCTAssertEqual(fixture.operationToken(uiSlot), uiToken)

            // The MCP run is untouched.
            XCTAssertNil(mcpRun.result)
            XCTAssertTrue(fixture.session(mcpSlot) === mcpSession)
            XCTAssertEqual(fixture.operationToken(mcpSlot), mcpToken)
            XCTAssertEqual(fixture.activeRunID(mcpSlot), mcpRunID)
            XCTAssertEqual(viewModel.tabsWithActiveContextBuilderRun, [mcpSlot.tabID])
            let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
            XCTAssertTrue(pendingRunIDs.contains(mcpRunID))

            // The claim goes when the cancelled run's tail has run.
            await processingGate.open()
            try await fixture.waitForRelease(of: uiSlot)
            XCTAssertFalse(viewModel.tabsHeldAgainstNewRun.contains(uiSlot.tabID))
            let successor = try viewModel.beginMCPControlledRun(
                forTabID: uiSlot.tabID,
                workspaceID: fixture.workspaceID,
                responseType: nil,
                planModelName: nil
            )
            await viewModel.clearMCPControlledRun(forTabID: uiSlot.tabID, controlToken: successor)

            XCTAssertNil(mcpRun.result)
            await mcpProvider.finish()
            guard case .failed = try await fixture.completion(of: mcpRun).terminalDisposition else {
                return XCTFail("The MCP run ran on to its own end: a provider that never connects fails it")
            }
        }
    }

    /// A window, and then a tab, closes while a run is committing its final context, and the run
    /// is settled by force with the commit still held.
    ///
    /// Held at its last step before the tab is written, the run has lost its tab by the time the
    /// commit goes on, and the tab is not written. Held just after the tab was written, the run's
    /// waiter is handed the exact tab that was committed, and what the run does once it resumes
    /// publishes nothing more into the tab's session.
    ///
    /// In both, the run's child leaves the prompt empty. The commit is then what fills the prompt,
    /// from the run's output, so the prompt shows whether the commit wrote the tab, and the
    /// commit reports that it used the output, a flag the run goes on to publish into the tab's
    /// session.
    func testCloseDuringCommitPreservesCommittedReceiptAndRejectsLatePublication() async throws {
        // Before the write.
        try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
            let viewModel = fixture.viewModel
            let slot = fixture.slots[0]
            let observed = CommitObservations()
            let beforeWrite = ContextBuilderTestGate()
            fixture.childWrites = .init(setsPrompt: false, setsSelection: true, repliesWithOutput: true)
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle { await beforeWrite.open() }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                committedTabSnapshotCaptured: { _, receipt in observed.receipts.append(receipt) }
            ))
            let run = fixture.startMCPRun(on: slot, progressReporter: { phase in
                observed.phases.append(phase)
                if phase == .tabContextCommit {
                    await beforeWrite.wait()
                }
            })
            try await fixture.waitFor("the run to reach its last step before the tab is written") {
                await beforeWrite.entered
            }
            XCTAssertEqual(fixture.storedTab(slot)?.promptText, "")

            Task { @MainActor in
                fixture.window.beginClose()
                await fixture.window.tearDown()
                observed.closeReturned = true
            }
            try await fixture.waitFor("the window's close to return with the commit still held") {
                observed.closeReturned
            }
            let completion = try await fixture.completion(of: run)
            XCTAssertEqual(completion.terminalDisposition, .cancelled)
            XCTAssertNil(completion.committedTab)

            await beforeWrite.open()
            try await fixture.waitFor("the run to leave its commit") { observed.phases.contains(.runFinalization) }
            XCTAssertEqual(fixture.storedTab(slot)?.promptText, "")
            XCTAssertEqual(observed.receipts.count, 0)
        }

        // After the write.
        try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
            let viewModel = fixture.viewModel
            let slot = fixture.slots[0]
            let observed = CommitObservations()
            let afterWrite = ContextBuilderTestGate()
            fixture.childWrites = .init(setsPrompt: false, setsSelection: true, repliesWithOutput: true)
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle { await afterWrite.open() }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                committedTabSnapshotCaptured: { _, receipt in observed.receipts.append(receipt) },
                afterCommittedTabSnapshotCaptured: { _, _ in await afterWrite.wait() }
            ))
            let run = fixture.startMCPRun(on: slot, progressReporter: { phase in
                observed.phases.append(phase)
            })
            try await fixture.waitFor("the run to have written its tab") { await afterWrite.entered }
            let runID = try XCTUnwrap(fixture.activeRunID(slot))
            let session = try XCTUnwrap(fixture.session(slot))
            let receipt = try XCTUnwrap(observed.receipts.first)
            XCTAssertEqual(observed.receipts.count, 1)
            XCTAssertEqual(fixture.storedTab(slot)?.promptText, slot.agentOutput)
            XCTAssertFalse(session.usedAgentOutputAsPrompt)

            Task { @MainActor in
                fixture.window.beginClose()
                await fixture.window.tearDown()
                observed.closeReturned = true
            }
            try await fixture.waitFor("the window's close to return with the commit still held") {
                observed.closeReturned
            }
            let completion = try await fixture.completion(of: run)
            XCTAssertEqual(completion.terminalDisposition, .cancelled)
            XCTAssertEqual(completion.runID, runID)
            guard let committed = completion.committedTab else {
                XCTFail("The run's waiter was not handed the tab the run had committed")
                throw ContextBuilderRunFixture.ScenarioAborted()
            }
            XCTAssertEqual(committed.nestedRunID, runID)
            XCTAssertEqual(committed.identity, fixture.identity(of: slot))
            XCTAssertEqual(committed.tab, receipt.tab)
            XCTAssertEqual(committed.selectionRevision, receipt.selectionRevision)
            XCTAssertEqual(committed.tab.promptText, slot.agentOutput)
            XCTAssertEqual(committed.tab.selection.selectedPaths, [slot.fileURL.path])
            XCTAssertTrue(committed.usedAgentOutputAsPrompt)
            XCTAssertTrue(completion.usedAgentOutputAsPrompt)
            XCTAssertEqual(fixture.storedTab(slot), committed.tab)

            let logBefore = session.agentLog.map(\.id)
            await afterWrite.open()
            try await fixture.waitFor("the run to leave its commit") { observed.phases.contains(.runFinalization) }
            XCTAssertFalse(session.usedAgentOutputAsPrompt)
            XCTAssertEqual(session.agentLog.map(\.id), logBefore)
            XCTAssertEqual(session.runHistory.count, 0)
            XCTAssertEqual(fixture.storedTab(slot), committed.tab)
        }

        // A tab, instead of the window, closes after the write. The close keeps the tab's session
        // for the grace and then settles the run by force, without waiting for its provider.
        try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
            let viewModel = fixture.viewModel
            let slot = fixture.slots[1]
            let observed = CommitObservations()
            let afterWrite = ContextBuilderTestGate()
            fixture.childWrites = .init(setsPrompt: false, setsSelection: true, repliesWithOutput: true)
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle { await afterWrite.open() }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                committedTabSnapshotCaptured: { _, receipt in observed.receipts.append(receipt) },
                afterCommittedTabSnapshotCaptured: { _, _ in await afterWrite.wait() }
            ))
            let run = fixture.startMCPRun(on: slot, progressReporter: { phase in
                observed.phases.append(phase)
            })
            try await fixture.waitFor("the run to have written its tab") { await afterWrite.entered }
            let runID = try XCTUnwrap(fixture.activeRunID(slot))
            let receipt = try XCTUnwrap(observed.receipts.first)

            Task { @MainActor in
                await fixture.window.promptManager.closeComposeTab(slot.tabID)
                observed.closeReturned = true
            }
            try await fixture.waitFor("the tab's close to return with the commit still held") {
                observed.closeReturned
            }
            XCTAssertNil(fixture.storedTab(slot), "The tab closed")
            let tabIDsAfterClose = fixture.storedTabIDs
            XCTAssertEqual(tabIDsAfterClose, [fixture.slots[0].tabID])
            XCTAssertNil(viewModel.sessions[slot.tabID])
            XCTAssertNil(fixture.activeRunID(slot))
            let completion = try await fixture.completion(of: run)
            XCTAssertEqual(completion.terminalDisposition, .cancelled)
            XCTAssertEqual(completion.runID, runID)
            guard let committed = completion.committedTab else {
                XCTFail("The run's waiter was not handed the tab the run had committed")
                throw ContextBuilderRunFixture.ScenarioAborted()
            }
            XCTAssertEqual(committed.nestedRunID, runID)
            XCTAssertEqual(committed.tab, receipt.tab)
            XCTAssertEqual(committed.selectionRevision, receipt.selectionRevision)
            XCTAssertEqual(committed.tab.promptText, slot.agentOutput)

            // The call has answered with its commit still held, and its tab admits no successor.
            XCTAssertThrowsError(
                try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
            ) { XCTAssertTrue($0 is CancellationError, "Refused as \($0)") }
            XCTAssertNil(viewModel.sessions[slot.tabID])

            // What the run does once it resumes neither brings the closed tab back nor gives it
            // a session again.
            await afterWrite.open()
            try await fixture.waitFor("the run to leave its commit") { observed.phases.contains(.runFinalization) }
            XCTAssertNil(fixture.storedTab(slot), "The tab stayed closed")
            XCTAssertEqual(fixture.storedTabIDs, tabIDsAfterClose)
            XCTAssertNil(viewModel.sessions[slot.tabID])
        }
    }

    /// A run whose final context claims a selection revision its tab never reached writes the tab
    /// and then cannot confirm the selection. The run fails, and still holds the receipt of what
    /// its commit left in the tab: the one it was handed in the turn of the write.
    func testRunWhoseCommitCannotConfirmItsSelectionFailsHoldingReceiptOfWhatWasStored() async throws {
        try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
            let viewModel = fixture.viewModel
            let server = fixture.window.mcpServer
            let slot = fixture.slots[1]
            let observed = CommitObservations()
            fixture.childWrites = .init(setsPrompt: false, setsSelection: true, repliesWithOutput: true)
            cleanup.add { viewModel.installRunTestHooks(nil) }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: { _, runID in
                    // The child has made its tool calls by the time its reply is processed.
                    guard let connectionID = fixture.child(forRunID: runID)?.connectionID,
                          let revision = server.tabContextByConnectionID[connectionID]?.selectionRevision,
                          revision == fixture.window.workspaceManager.selectionRevisionForMCP(
                              workspaceID: fixture.workspaceID,
                              tabID: slot.tabID
                          )
                    else { return }
                    server.tabContextByConnectionID[connectionID]?.selectionRevision = revision + 1
                },
                providerEventDisposition: nil,
                teardownCompleted: nil,
                committedTabSnapshotCaptured: { _, receipt in
                    observed.receipts.append(receipt)
                    observed.storedTabsAtReceipt.append(fixture.storedTab(slot))
                }
            ))

            let run = fixture.startMCPRun(on: slot)
            let completion = try await fixture.completion(of: run)

            guard case .failed = completion.terminalDisposition else {
                XCTFail("A commit that could not confirm its selection ended the run as \(completion.terminalDisposition)")
                throw ContextBuilderRunFixture.ScenarioAborted()
            }
            let stored = try XCTUnwrap(fixture.storedTab(slot))
            XCTAssertEqual(stored.promptText, slot.agentOutput, "The commit wrote the tab")
            XCTAssertEqual(observed.receipts.count, 1)
            let receipt = try XCTUnwrap(observed.receipts.first)
            XCTAssertEqual(receipt.tab, try XCTUnwrap(observed.storedTabsAtReceipt.first))
            XCTAssertEqual(receipt.tab.promptText, slot.agentOutput)
            XCTAssertEqual(receipt.tab.selection.selectedPaths, [slot.fileURL.path])
            guard let committed = completion.committedTab else {
                XCTFail("The failed run did not keep the receipt of what its commit wrote")
                throw ContextBuilderRunFixture.ScenarioAborted()
            }
            XCTAssertEqual(committed.nestedRunID, completion.runID)
            XCTAssertEqual(committed.identity, fixture.identity(of: slot))
            XCTAssertEqual(committed.tab, receipt.tab)
            XCTAssertEqual(committed.selectionRevision, receipt.selectionRevision)
            XCTAssertEqual(stored.promptText, committed.tab.promptText)
            XCTAssertEqual(stored.selection, committed.tab.selection)
        }
    }

    /// A cancelled MCP call keeps its tab until its run's execution has really ended, however
    /// long that takes: no grace applies to an ordinary cancellation. Until then the call's
    /// cleanup scope has not returned and a successor is refused as a busy tab.
    func testCancelledMCPCallKeepsItsTabUntilItsExecutionEnds() async throws {
        try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
            let viewModel = fixture.viewModel
            let slot = fixture.slots[0]
            let execution = ContextBuilderTestGate()
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle { await execution.open() }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: { _, _ in await execution.wait() },
                providerEventDisposition: nil,
                teardownCompleted: nil
            ))
            fixture.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }

            let run = fixture.startMCPRun(on: slot)
            try await fixture.waitFor("the run's execution to be held") { await execution.entered }
            let runID = try XCTUnwrap(fixture.activeRunID(slot))
            let token = try XCTUnwrap(fixture.operationToken(slot))

            await viewModel.cancelMCPContextBuilderRun(runID: runID)
            XCTAssertNil(fixture.activeRunID(slot))
            // Longer than the grace a closing tab or window gives an execution.
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertNil(run.result, "The call's cleanup scope has not returned")
            XCTAssertEqual(fixture.operationToken(slot), token)
            XCTAssertThrowsError(
                try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
            ) { XCTAssertEqual(($0 as NSError).code, 2) }
            XCTAssertEqual(fixture.operationToken(slot), token)

            await execution.open()
            try await fixture.waitFor("the cancelled call to return", allowingRunErrors: true) { run.result != nil }
            XCTAssertThrowsError(try XCTUnwrap(run.result).get()) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertNil(fixture.operationToken(slot))
            let successor = try viewModel.beginMCPControlledRun(
                forTabID: slot.tabID,
                workspaceID: fixture.workspaceID,
                responseType: nil,
                planModelName: nil
            )
            await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: successor)
        }
    }

    /// A window close stops waiting for an execution that outlasts its grace. The MCP call whose
    /// run that was then answers, with the execution still held, and its tab is released. The
    /// closing window admits no successor. Only the wait has ended: the run's record stays until
    /// the execution really has.
    func testWindowCloseAnswersCallWhoseExecutionOutlastsItsGrace() async throws {
        try await assertCallIsAnsweredWhileItsExecutionOutlastsTheGrace { fixture in
            fixture.window.beginClose()
            await fixture.window.tearDown()
        }
    }

    /// App termination stops waiting for such an execution in the same way. The MCP call's
    /// release of its tab waits for the run's execution, and the settlement termination forces
    /// after its grace ends that wait, so the call answers and the shutdown returns with the
    /// execution still held.
    func testAppTerminationAnswersCallWhoseExecutionOutlastsItsGrace() async throws {
        try await assertCallIsAnsweredWhileItsExecutionOutlastsTheGrace { fixture in
            await fixture.viewModel.shutdownForAppTermination()
        }
    }

    private func assertCallIsAnsweredWhileItsExecutionOutlastsTheGrace(
        of close: @escaping @MainActor (ContextBuilderRunFixture) async -> Void
    ) async throws {
        try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
            let viewModel = fixture.viewModel
            let slot = fixture.slots[0]
            let execution = ContextBuilderTestGate()
            let observed = CommitObservations()
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle { await execution.open() }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: { _, _ in await execution.wait() },
                providerEventDisposition: nil,
                teardownCompleted: { observed.tornDownRunIDs.append($0) }
            ))
            fixture.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }

            let run = fixture.startMCPRun(on: slot)
            try await fixture.waitFor("the run's execution to be held") { await execution.entered }
            let runID = try XCTUnwrap(fixture.activeRunID(slot))

            Task { @MainActor in
                await close(fixture)
                observed.closeReturned = true
            }
            try await fixture.waitFor("the call to answer with its execution still held", allowingRunErrors: true) {
                run.result != nil
            }
            XCTAssertThrowsError(try XCTUnwrap(run.result).get()) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(observed.tornDownRunIDs.contains(runID), "The execution has not ended")
            XCTAssertNil(fixture.operationToken(slot))
            XCTAssertThrowsError(
                try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
            ) { XCTAssertTrue($0 is CancellationError, "Refused as \($0)") }
            XCTAssertNil(fixture.operationToken(slot))
            try await fixture.waitFor("the close to return", allowingRunErrors: true) {
                observed.closeReturned
            }
            XCTAssertFalse(observed.tornDownRunIDs.contains(runID), "The execution has not ended")

            await execution.open()
            try await fixture.waitFor("the run's record to go once its execution has ended", allowingRunErrors: true) {
                observed.tornDownRunIDs.contains(runID)
            }
        }
    }

    /// An MCP follow-up is suspended resolving its model when its tab closes, which removes the
    /// tab's session. The follow-up ends there: it makes no session for the closed tab and writes
    /// nothing for it, whether or not the window still shows the tab's workspace.
    func testMCPFollowUpWhoseTabClosedWhileItResolvedItsModelWritesNothing() async throws {
        for showsTabsWorkspace in [false, true] {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let manager = fixture.window.workspaceManager
                let kept = fixture.slots[0]
                let closing = fixture.slots[1]
                let resolvingModel = ContextBuilderTestGate()
                cleanup.add { viewModel.installRunTestHooks(nil) }
                fixture.releaseOnSettle { await resolvingModel.open() }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    resolveMCPFollowUpModel: { _ in
                        await resolvingModel.wait()
                        return (model: .claude4Sonnet, chatPresetID: nil, mcpControlInfo: nil)
                    }
                ))
                // The follow-up runs under its tab's MCP claim, as it does inside the tool call.
                _ = try viewModel.beginMCPControlledRun(
                    forTabID: closing.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: "plan",
                    planModelName: nil
                )
                XCTAssertNotNil(fixture.session(closing))

                // A blank prompt is rejected before any model or provider is involved, and a
                // cancelled request stops at its next check, so a follow-up that got past its
                // closed tab would fail here instead of generating.
                let followUp = Task { @MainActor in
                    try await viewModel.runMCPPlanOrQuestion(
                        for: fixture.identity(of: closing),
                        oracleViewModel: fixture.window.oracleViewModel,
                        mode: .plan,
                        prompt: " ",
                        selection: StoredSelection(selectedPaths: []),
                        reviewGitContext: .automaticOnly()
                    )
                }
                try await fixture.waitFor("the follow-up to be resolving its model") {
                    await resolvingModel.entered
                }

                await fixture.window.promptManager.closeComposeTab(closing.tabID)
                XCTAssertNil(fixture.storedTab(closing), "The tab closed")
                XCTAssertNil(viewModel.sessions[closing.tabID])
                if showsTabsWorkspace {
                    followUp.cancel()
                } else {
                    let elsewhere = manager.createWorkspace(
                        name: "Context Builder runs, other workspace",
                        repoPaths: [fixture.rootURL.path],
                        ephemeral: true
                    )
                    cleanup.add { manager.workspaces.removeAll { $0.id == elsewhere.id } }
                    await manager.switchWorkspace(
                        to: elsewhere,
                        saveState: false,
                        reason: "ContextBuilderGracefulShutdownTests"
                    )
                    XCTAssertNotEqual(manager.activeWorkspaceID, fixture.workspaceID)
                }
                let sessionsBefore = Set(viewModel.sessions.keys)
                let tabIDsBefore = fixture.storedTabIDs

                await resolvingModel.open()
                let outcome = await followUp.result

                XCTAssertThrowsError(try outcome.get()) { XCTAssertTrue($0 is CancellationError, "Ended with \($0)") }
                XCTAssertNil(viewModel.sessions[closing.tabID], "No session was made for the closed tab")
                XCTAssertEqual(Set(viewModel.sessions.keys), sessionsBefore)
                XCTAssertNil(fixture.storedTab(closing))
                XCTAssertEqual(fixture.storedTabIDs, tabIDsBefore)
                XCTAssertNotNil(fixture.storedTab(kept))
                XCTAssertFalse(viewModel.isBackgroundPlanGenerating)
                XCTAssertNil(viewModel.backgroundPlanError)
                XCTAssertNil(viewModel.generatedAnswerRoute)
                XCTAssertFalse(viewModel.tabsHeldAgainstNewRun.contains(closing.tabID))
            }
        }
    }

    /// An MCP follow-up is suspended resolving its model when its tab is closed and then restored
    /// under the same ID for another holder, which has a session and a claim of its own. When the
    /// follow-up resumes there is a session for its tab, and it is not the one it started under.
    /// It ends as cancelled, writes nothing, and creates no chat. The holder's session, claim,
    /// controls, planning model, answer, and chat are exactly as the holder left them. This holds
    /// whether or not the window still shows the tab's workspace.
    func testMCPFollowUpWhoseTabWasRestoredForAnotherHolderLeavesThatHolderUntouched() async throws {
        for showsTabsWorkspace in [false, true] {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let manager = fixture.window.workspaceManager
                let promptManager = fixture.window.promptManager
                let oracle = fixture.window.oracleViewModel
                let slot = fixture.slots[1]
                let resolvingModel = ContextBuilderTestGate()
                let observed = FollowUpObservations()
                cleanup.add { viewModel.installRunTestHooks(nil) }
                fixture.releaseOnSettle { await resolvingModel.open() }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    resolveMCPFollowUpModel: { _ in
                        await resolvingModel.wait()
                        return (model: .claude4Sonnet, chatPresetID: nil, mcpControlInfo: nil)
                    }
                ))

                let staleClaim = try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: "plan",
                    planModelName: "stale plan model"
                )
                let staleSession = try XCTUnwrap(fixture.session(slot))
                staleSession.mcpPlanningModelRaw = "stale-planning-model"
                // Neither branch can go on to generate if it gets past its lost session. For a
                // workspace the window does not show, a blank prompt is rejected before a model
                // or a provider is involved. For the one it shows, the follow-up is cancelled as
                // it reports that it is about to create its chat, which is before it sends.
                let followUp = Task { @MainActor in
                    try await viewModel.runMCPPlanOrQuestion(
                        for: fixture.identity(of: slot),
                        oracleViewModel: oracle,
                        mode: .plan,
                        prompt: showsTabsWorkspace ? "Plan the change" : " ",
                        selection: StoredSelection(selectedPaths: []),
                        reviewGitContext: .automaticOnly(),
                        progressReporter: { phase in
                            observed.phases.append(phase)
                            if phase == .sessionCreationAndPersist {
                                observed.followUp?.cancel()
                            }
                        }
                    )
                }
                observed.followUp = followUp
                try await fixture.waitFor("the follow-up to be resolving its model") {
                    await resolvingModel.entered
                }

                // Closed, and restored under the same ID.
                _ = await promptManager.stashComposeTabs(withIDs: [slot.tabID])
                XCTAssertNil(fixture.storedTab(slot), "The tab closed")
                XCTAssertNil(viewModel.sessions[slot.tabID])
                let restored = await promptManager.restoreStashedComposeTab(containingTabID: slot.tabID)
                XCTAssertEqual(restored?.id, slot.tabID)
                // The window gives the tab it now shows a chat of its own accord. That chat is the
                // holder's, and waiting for it leaves the window nothing more to create.
                try await fixture.waitFor("the restored tab to be given its chat") {
                    guard let chatID = manager.activeChatSessionID(forTabID: slot.tabID) else { return false }
                    return oracle.sessions.contains { $0.id == chatID }
                }
                let holderChatID = try XCTUnwrap(manager.activeChatSessionID(forTabID: slot.tabID))

                // The tab's new holder, with state of its own.
                let claim = try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: "question",
                    planModelName: "holder plan model"
                )
                XCTAssertNotEqual(claim, staleClaim)
                let holder = try XCTUnwrap(fixture.session(slot))
                XCTAssertFalse(holder === staleSession)
                let holderToken = try XCTUnwrap(holder.operationToken)
                holder.mcpPlanningModelRaw = "holder-planning-model"
                let holderRoute = ContextBuilderGeneratedAnswerRoute(
                    workspaceID: fixture.workspaceID,
                    tabID: slot.tabID,
                    chatID: "holder-chat"
                )
                holder.generatedAnswerRoute = holderRoute
                viewModel.setBackgroundPlanResponseText("Answer held by the tab's new holder", forTabID: slot.tabID)
                if !showsTabsWorkspace {
                    let elsewhere = manager.createWorkspace(
                        name: "Context Builder runs, other workspace",
                        repoPaths: [fixture.rootURL.path],
                        ephemeral: true
                    )
                    cleanup.add { manager.workspaces.removeAll { $0.id == elsewhere.id } }
                    await manager.switchWorkspace(
                        to: elsewhere,
                        saveState: false,
                        reason: "ContextBuilderGracefulShutdownTests"
                    )
                    XCTAssertNotEqual(manager.activeWorkspaceID, fixture.workspaceID)
                }
                XCTAssertTrue(fixture.session(slot) === holder)
                let storedBefore = try XCTUnwrap(fixture.storedTab(slot))
                // The window lists a workspace's chats only while it shows that workspace.
                let chatsBefore = showsTabsWorkspace ? oracle.sessions.map(\.id) : nil

                await resolvingModel.open()
                let outcome = await followUp.result

                // The old follow-up.
                XCTAssertThrowsError(try outcome.get()) { XCTAssertTrue($0 is CancellationError, "Ended with \($0)") }
                XCTAssertEqual(observed.phases, [.modelResolution], "It took no step after resolving its model")
                XCTAssertFalse(staleSession.isBackgroundPlanGenerating)
                XCTAssertNil(staleSession.backgroundPlanError)
                XCTAssertNil(staleSession.followUpOracleSessionID)
                XCTAssertNil(staleSession.generatedAnswerRoute)
                if let chatsBefore {
                    XCTAssertEqual(oracle.sessions.map(\.id), chatsBefore, "It created no chat")
                }
                XCTAssertFalse(oracle.sessions.contains { oracle.isSessionPinnedForTesting($0.id) })

                // The tab's holder.
                XCTAssertTrue(fixture.session(slot) === holder)
                XCTAssertEqual(holder.operationToken, holderToken)
                XCTAssertEqual(holder.mcpResponseType, "question")
                XCTAssertEqual(holder.mcpPlanModel, "holder plan model")
                XCTAssertEqual(holder.mcpPlanningModelRaw, "holder-planning-model")
                XCTAssertEqual(holder.backgroundPlanResponseText, "Answer held by the tab's new holder")
                XCTAssertEqual(holder.generatedAnswerRoute, holderRoute)
                XCTAssertFalse(holder.isBackgroundPlanGenerating)
                XCTAssertNil(holder.backgroundPlanError)
                XCTAssertNil(holder.followUpOracleSessionID)
                XCTAssertEqual(manager.activeChatSessionID(forTabID: slot.tabID), holderChatID)
                XCTAssertEqual(fixture.storedTab(slot), storedBefore)

                await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: claim)
            }
        }
    }

    /// An MCP follow-up started while the window showed another workspace has sent its prompt
    /// without a chat and is waiting for the provider's reply. The window shows the tab's
    /// workspace again, and the tab is closed, restored under the same ID, and claimed by another
    /// holder, which starts an answer of its own. Closing a tab does not stop a reply that is not
    /// streaming into a chat, so the reply then arrives, completed. The follow-up ends as
    /// cancelled, and the holder's claim, controls, answer, and route, and the stored tab's chat,
    /// are as the holder left them.
    func testMCPHeadlessFollowUpWhoseTabChangedHandsBeforeItsReplyWritesNothing() async throws {
        try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
            let viewModel = fixture.viewModel
            let manager = fixture.window.workspaceManager
            let slot = fixture.slots[1]
            try await fixture.saveChatsInTemporaryDirectory()
            cleanup.add { viewModel.installRunTestHooks(nil) }
            viewModel.installRunTestHooks(Self.hooksResolvingFollowUpModel)

            let staleClaim = try viewModel.beginMCPControlledRun(
                forTabID: slot.tabID,
                workspaceID: fixture.workspaceID,
                responseType: "plan",
                planModelName: nil
            )
            let elsewhere = manager.createWorkspace(
                name: "Context Builder runs, other workspace",
                repoPaths: [fixture.rootURL.path],
                ephemeral: true
            )
            cleanup.add { manager.workspaces.removeAll { $0.id == elsewhere.id } }
            await manager.switchWorkspace(
                to: elsewhere,
                saveState: false,
                reason: "ContextBuilderGracefulShutdownTests"
            )
            XCTAssertNotEqual(manager.activeWorkspaceID, fixture.workspaceID)

            let followUp = Task { @MainActor in
                try await viewModel.runMCPPlanOrQuestion(
                    for: fixture.identity(of: slot),
                    oracleViewModel: fixture.window.oracleViewModel,
                    mode: .plan,
                    prompt: Self.followUpPrompt,
                    selection: StoredSelection(selectedPaths: [slot.fileURL.path]),
                    reviewGitContext: .automaticOnly()
                )
            }
            cleanup.add {
                followUp.cancel()
                _ = await followUp.result
            }
            let request = try await Self.firstRequest(sentBy: followUp, in: fixture)
            XCTAssertTrue(request.userPrompt.contains(Self.followUpPrompt), request.userPrompt)
            let staleSession = try XCTUnwrap(fixture.session(slot))
            XCTAssertEqual(staleSession.operationToken?.id, staleClaim)
            XCTAssertNil(staleSession.followUpOracleSessionID, "The reply is not streaming into a chat")

            let origin = try XCTUnwrap(manager.workspaces.first { $0.id == fixture.workspaceID })
            await manager.switchWorkspace(
                to: origin,
                saveState: false,
                reason: "ContextBuilderGracefulShutdownTests"
            )
            XCTAssertTrue(fixture.session(slot) === staleSession)
            let holder = try await Self.handTab(slot, toAnotherHolderIn: fixture)
            XCTAssertFalse(fixture.session(slot) === staleSession)
            await request.complete(with: Self.lateFollowUpReply)
            let outcome = await followUp.result

            XCTAssertThrowsError(try outcome.get()) { XCTAssertTrue($0 is CancellationError, "Ended with \($0)") }
            XCTAssertEqual(HolderState(of: slot, in: fixture), holder.state)
            let requestCount = await fixture.oracleReplies.requests.count
            XCTAssertEqual(requestCount, 1)
            await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: holder.claim)
        }
    }

    /// An MCP follow-up for a tab the window shows loses the tab at each of three points: as it
    /// is about to create its chat, as it is about to send its prompt, and with its provider's
    /// reply pending. Each time the tab is closed, restored under the same ID, and claimed by
    /// another holder, which starts an answer of its own. From that point the follow-up writes
    /// nothing. It creates no chat it had not created, sends nothing it had not sent, leaves no
    /// chat pinned, and ends as cancelled. The holder's claim, controls, answer, and route, and
    /// the stored tab's chat, are as the holder left them.
    func testMCPStreamedFollowUpWhoseTabChangedHandsWritesNothingFromThenOn() async throws {
        for point in HandoverPoint.allCases {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let oracle = fixture.window.oracleViewModel
                let slot = fixture.slots[1]
                let observed = HandoverObservations()
                try await fixture.saveChatsInTemporaryDirectory()
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(Self.hooksResolvingFollowUpModel)

                _ = try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: "plan",
                    planModelName: nil
                )
                let staleSession = try XCTUnwrap(fixture.session(slot))
                let handTabOver: @MainActor @Sendable () async throws -> Void = {
                    observed.holder = try await Self.handTab(slot, toAnotherHolderIn: fixture)
                    observed.chatsAtHandover = oracle.sessions.map(\.id)
                }
                let followUp = Task { @MainActor in
                    try await viewModel.runMCPPlanOrQuestion(
                        for: fixture.identity(of: slot),
                        oracleViewModel: oracle,
                        mode: .plan,
                        prompt: Self.followUpPrompt,
                        selection: StoredSelection(selectedPaths: [slot.fileURL.path]),
                        reviewGitContext: .automaticOnly(),
                        progressReporter: { phase in
                            observed.phases.append(phase)
                            if phase == point.phaseReportedJustBefore {
                                try? await handTabOver()
                            }
                        }
                    )
                }
                cleanup.add {
                    followUp.cancel()
                    _ = await followUp.result
                }
                if point == .replyPending {
                    let request = try await Self.firstRequest(sentBy: followUp, in: fixture)
                    XCTAssertTrue(request.userPrompt.contains(Self.followUpPrompt), request.userPrompt)
                    try await handTabOver()
                    await request.complete(with: Self.lateFollowUpReply)
                }
                let outcome = await followUp.result

                XCTAssertThrowsError(try outcome.get(), "\(point)") {
                    XCTAssertTrue($0 is CancellationError, "\(point): ended with \($0)")
                }
                let holder = try XCTUnwrap(observed.holder, "\(point): the tab was never handed over")
                XCTAssertFalse(fixture.session(slot) === staleSession, "\(point)")
                XCTAssertEqual(HolderState(of: slot, in: fixture), holder.state, "\(point)")
                XCTAssertEqual(oracle.sessions.map(\.id), observed.chatsAtHandover, "\(point): no chat was created")
                XCTAssertFalse(oracle.sessions.contains { oracle.isSessionPinnedForTesting($0.id) }, "\(point)")
                let requestCount = await fixture.oracleReplies.requests.count
                switch point {
                case .beforeChatCreation:
                    XCTAssertEqual(observed.phases.last, .sessionCreationAndPersist)
                    XCTAssertEqual(requestCount, 0)
                case .beforeSend:
                    XCTAssertEqual(observed.phases.last, .messageSend)
                    XCTAssertEqual(requestCount, 0, "Nothing was sent")
                case .replyPending:
                    XCTAssertTrue(observed.phases.contains(.streaming))
                    XCTAssertEqual(requestCount, 1)
                }
                await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: holder.claim)
            }
        }
    }

    private static let followUpPrompt = "Plan the change"
    private static let lateFollowUpReply = "Plan from the follow-up that had lost its tab"

    /// Hooks that give an MCP follow-up a model the Oracle can send with on any machine.
    private static var hooksResolvingFollowUpModel: ContextBuilderAgentViewModel.RunTestHooks {
        .init(
            beforeProcessingProviderEvent: nil,
            providerEventDisposition: nil,
            teardownCompleted: nil,
            resolveMCPFollowUpModel: { _ in
                (model: ContextBuilderRunFixture.followUpModel, chatPresetID: nil, mcpControlInfo: nil)
            }
        )
    }

    /// The first prompt `followUp` sends to its provider. Fails with the follow-up's own outcome
    /// when it ends without sending one.
    private static func firstRequest(
        sentBy followUp: Task<ChatSendReply, Error>,
        in fixture: ContextBuilderRunFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ContextBuilderOracleReplies.Request {
        let ended = ContextBuilderTestFlag()
        Task {
            _ = await followUp.result
            await ended.set()
        }
        try await fixture.waitFor("the follow-up to send its prompt or end", file: file, line: line) {
            if await fixture.oracleReplies.requests.isEmpty == false { return true }
            return await ended.current()
        }
        guard let request = await fixture.oracleReplies.requests.first else {
            let outcome = await followUp.result
            XCTFail("The follow-up ended before it sent a prompt: \(outcome)", file: file, line: line)
            throw ContextBuilderRunFixture.ScenarioAborted()
        }
        return request
    }

    /// Closes `slot` into the stash, restores it under the same ID, and claims it for another
    /// holder, which starts an answer of its own on the tab's new session. A claim on the session
    /// a follow-up is still generating on is refused, so this is how a tab changes hands under
    /// one.
    private static func handTab(
        _ slot: ContextBuilderRunFixture.TabSlot,
        toAnotherHolderIn fixture: ContextBuilderRunFixture
    ) async throws -> (claim: UUID, state: HolderState) {
        let viewModel = fixture.viewModel
        let manager = fixture.window.workspaceManager
        let promptManager = fixture.window.promptManager
        let oracle = fixture.window.oracleViewModel
        _ = await promptManager.stashComposeTabs(withIDs: [slot.tabID])
        let restored = await promptManager.restoreStashedComposeTab(containingTabID: slot.tabID)
        XCTAssertEqual(restored?.id, slot.tabID)
        // The window gives the tab it now shows a chat of its own accord. Waiting for that chat
        // leaves the window nothing more to create.
        try await fixture.waitFor("the restored tab to be given its chat") {
            guard let chatID = manager.activeChatSessionID(forTabID: slot.tabID) else { return false }
            return oracle.sessions.contains { $0.id == chatID }
        }
        let claim = try viewModel.beginMCPControlledRun(
            forTabID: slot.tabID,
            workspaceID: fixture.workspaceID,
            responseType: "question",
            planModelName: "holder plan model"
        )
        let session = try XCTUnwrap(fixture.session(slot))
        session.mcpPlanningModelRaw = "holder-planning-model"
        viewModel.setBackgroundPlanGenerating(true, forTabID: slot.tabID)
        viewModel.setBackgroundPlanResponseText("Answer held by the tab's new holder", forTabID: slot.tabID)
        session.generatedAnswerRoute = ContextBuilderGeneratedAnswerRoute(
            workspaceID: fixture.workspaceID,
            tabID: slot.tabID,
            chatID: "holder-chat"
        )
        return (claim, HolderState(of: slot, in: fixture))
    }

    /// A record that has lost its tab is retired without publishing into the tab's current
    /// session, and still hands its own waiter the exact tab it had committed. The run that took
    /// the tab over keeps its claim, its active slot, and its session untouched. A waiter that is
    /// owed a cancellation error instead of a snapshot receives the error.
    func testStaleRetirementReturnsCommittedSnapshot() async throws {
        let window = makeWindow()
        let viewModel = window.contextBuilderAgentViewModel
        let tabID = UUID()

        for waiterResolution in [ContextBuilderRunWaiterResolution.snapshot, .cancellationError] {
            var capturedContinuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>?
            let waiter = Task { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    capturedContinuation = continuation
                }
            }
            while capturedContinuation == nil {
                await Task.yield()
            }
            let stale = makeRecord(
                tabID: tabID,
                continuation: capturedContinuation,
                origin: .mcp(controlToken: UUID())
            )
            let staleProvider = GatedHeadlessAgentProvider()
            await staleProvider.allowDispose()
            XCTAssertTrue(stale.installProvider(staleProvider))
            XCTAssertTrue(viewModel.registerRunRecordForTesting(stale, makeCurrent: true, releaseActiveSlot: true))
            stale.output.append("Discovery output of the stale run", messageID: nil)
            var committedTab = ComposeTabState(id: tabID, name: "Committed")
            committedTab.promptText = "Prompt committed by the stale run"
            let receipt = MCPServerViewModel.ContextBuilderCommittedTabSnapshot(
                identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: tabID),
                nestedRunID: stale.runID,
                tab: committedTab,
                selectionRevision: 7,
                usedAgentOutputAsPrompt: true
            )
            XCTAssertTrue(stale.installCommittedTabSnapshot(receipt))

            let successor = makeRecord(tabID: tabID)
            let successorToken = ContextBuilderAgentViewModel.TabSession.OperationToken(
                id: successor.runID,
                origin: .ui,
                workspaceID: nil
            )
            successor.session.operationToken = successorToken
            XCTAssertTrue(viewModel.registerRunRecordForTesting(successor, makeCurrent: true))
            XCTAssertFalse(viewModel.acceptsRunEventsForTesting(stale))

            viewModel.retireStaleRunRecordForTesting(stale, waiterResolution: waiterResolution)

            let result = await waiter.result
            switch waiterResolution {
            case .snapshot:
                let completion = try result.get()
                XCTAssertEqual(completion.runID, stale.runID)
                XCTAssertEqual(completion.terminalDisposition, .cancelled)
                XCTAssertTrue(completion.usedAgentOutputAsPrompt)
                guard let committed = completion.committedTab else {
                    XCTFail("The stale run's waiter was not handed the tab that run had committed")
                    return
                }
                XCTAssertEqual(committed.identity, receipt.identity)
                XCTAssertEqual(committed.nestedRunID, receipt.nestedRunID)
                XCTAssertEqual(committed.tab, receipt.tab)
                XCTAssertEqual(committed.selectionRevision, receipt.selectionRevision)
                XCTAssertTrue(committed.usedAgentOutputAsPrompt)
            case .cancellationError:
                XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
            }

            XCTAssertEqual(stale.terminalOutcome, .cancelled)
            XCTAssertEqual(viewModel.activeRunIDForTesting(tabID: tabID), successor.runID)
            XCTAssertTrue(viewModel.acceptsRunEventsForTesting(successor))
            XCTAssertNil(successor.terminalOutcome)
            XCTAssertEqual(successor.session.operationToken, successorToken)
            XCTAssertNil(successor.session.lastAgentOutput)
            XCTAssertFalse(successor.session.usedAgentOutputAsPrompt)
            XCTAssertEqual(successor.session.agentLog.count, 0)

            await stale.awaitTeardownSettlement()
            let disposeCallCount = await staleProvider.disposeCallCount()
            XCTAssertEqual(disposeCallCount, 1)
            viewModel.cancelRunForTesting(successor)
            await successor.awaitTeardownSettlement()
        }
    }

    /// App termination and an ordinary window close can reach the same run. Whichever comes
    /// first starts the run's teardown and the other joins it, so the provider is disposed once.
    func testWindowCloseDuringAppTerminationDisposesEachProviderOnce() async {
        let manager = WindowStatesManager.shared
        defer { manager.setTerminatingForTesting(false) }

        // The app is already terminating when the window closes.
        do {
            let window = makeWindow()
            let viewModel = window.contextBuilderAgentViewModel
            let provider = GatedHeadlessAgentProvider()
            let record = makeRecord()
            XCTAssertTrue(record.installProvider(provider))
            XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))
            manager.registerWindowState(window)
            manager.signalTermination()
            let shutdown = Task { await manager.shutdownAllAgentSessions() }
            guard await waitUntil(condition: { await provider.disposeCallCount() > 0 }) else {
                XCTFail("App termination did not start disposing the provider.")
                await provider.allowDispose()
                await shutdown.value
                return
            }

            await window.tearDown()
            let disposeCallsAfterWindowClose = await provider.disposeCallCount()
            XCTAssertEqual(disposeCallsAfterWindowClose, 1)
            XCTAssertNil(record.teardownFinishedAt)

            await provider.allowDispose()
            await shutdown.value
            let disposeCallCount = await provider.disposeCallCount()
            XCTAssertEqual(disposeCallCount, 1)
            XCTAssertNotNil(record.teardownFinishedAt)
            if manager.allWindows.contains(where: { $0 === window }) {
                manager.unregisterWindowState(window)
            }
            manager.setTerminatingForTesting(false)
        }

        // The window is already closing when the app terminates.
        do {
            let window = makeWindow()
            let viewModel = window.contextBuilderAgentViewModel
            let provider = GatedHeadlessAgentProvider()
            let record = makeRecord()
            XCTAssertTrue(record.installProvider(provider))
            XCTAssertTrue(viewModel.registerRunRecordForTesting(record, makeCurrent: true))
            let close = Task { @MainActor in await window.tearDown() }
            guard await waitUntil(condition: { await provider.disposeCallCount() > 0 }) else {
                XCTFail("The window's close did not start disposing the provider.")
                await provider.allowDispose()
                await close.value
                return
            }

            // The shutdown runs on the main actor, as this test does, and enters the view model in
            // the turn that sets `shutdownStarted`. The flag can therefore only be seen here once
            // the shutdown has stopped running: it is suspended waiting for the run's teardown.
            var shutdownStarted = false
            var shutdownReturned = false
            let shutdown = Task { @MainActor in
                shutdownStarted = true
                await viewModel.shutdownForAppTermination()
                shutdownReturned = true
            }
            guard await waitUntil(condition: { shutdownStarted }) else {
                XCTFail("App termination did not start.")
                await provider.allowDispose()
                await close.value
                await shutdown.value
                return
            }
            XCTAssertFalse(shutdownReturned)
            let disposeCallsWhileBothWait = await provider.disposeCallCount()
            XCTAssertEqual(disposeCallsWhileBothWait, 1)

            await provider.allowDispose()
            await close.value
            await shutdown.value
            let disposeCallCount = await provider.disposeCallCount()
            XCTAssertEqual(disposeCallCount, 1)
            XCTAssertNotNil(record.teardownFinishedAt)
        }
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
        tabID: UUID = UUID(),
        continuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>? = nil,
        origin: ContextBuilderRunOrigin = .ui
    ) -> ContextBuilderRunRecord {
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

private final class GatedHeadlessAgentProvider: HeadlessAgentProvider, @unchecked Sendable {
    private let disposeGate = ContextBuilderTestGate()
    private let state = GatedHeadlessAgentProviderState()
    private let onDisposeStarted: @Sendable () async -> Void

    init(onDisposeStarted: @escaping @Sendable () async -> Void = {}) {
        self.onDisposeStarted = onDisposeStarted
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
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

/// A provider whose start ignores cancellation and stays held until the test releases it.
private final class StartHeldHeadlessAgentProvider: HeadlessAgentProvider, @unchecked Sendable {
    private let startGate = ContextBuilderTestGate()
    private let state = GatedHeadlessAgentProviderState()

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        await startGate.wait()
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {
        await state.noteDisposeStarted()
    }

    func startWasEntered() async -> Bool {
        await startGate.entered
    }

    func releaseStart() async {
        await startGate.open()
    }

    func disposeCallCount() async -> Int {
        await state.disposeCallCount
    }
}

/// What a window-close scenario saw of the work it closed over.
@MainActor
private final class WindowCloseObservations {
    var closeReturned = false
    var preparationWasCancelled = false
    var followUpWasCancelled = false
    var preparingCallEnded = false
    var preparingResponse: PersistentMCPTestRPCResponse?
}

/// What a close-during-commit scenario saw of the run's commit.
@MainActor
private final class CommitObservations {
    var closeReturned = false
    var phases: [ContextBuilderMCPProgressPhase] = []
    var receipts: [MCPServerViewModel.ContextBuilderCommittedTabSnapshot] = []
    /// The stored tab as it was in the turn that handed over each receipt.
    var storedTabsAtReceipt: [ComposeTabState?] = []
    var tornDownRunIDs: [UUID] = []
}

@MainActor
private final class SettlementWaits {
    var enrolled = 0
    var resumed = 0
}

@MainActor
private final class FollowUpObservations {
    var phases: [ContextBuilderMCPProgressPhase] = []
    var followUp: Task<ChatSendReply, Error>?
}

/// Where a streamed MCP follow-up is when its tab changes hands.
private enum HandoverPoint: CaseIterable {
    case beforeChatCreation
    case beforeSend
    case replyPending

    /// The progress phase the follow-up reports immediately before the step the handover
    /// precedes. A pending reply has no such phase: it is found by the prompt having been sent.
    var phaseReportedJustBefore: ContextBuilderMCPProgressPhase? {
        switch self {
        case .beforeChatCreation: .sessionCreationAndPersist
        case .beforeSend: .messageSend
        case .replyPending: nil
        }
    }
}

/// What a handover scenario saw of the follow-up, and of the tab as its new holder took it.
@MainActor
private final class HandoverObservations {
    var phases: [ContextBuilderMCPProgressPhase] = []
    var holder: (claim: UUID, state: HolderState)?
    var chatsAtHandover: [UUID] = []
}

/// What a tab's holder has on the tab: its session and claim, its MCP controls, the answer it is
/// generating, and the stored tab's chat. A follow-up that lost the tab must leave all of it.
private struct HolderState: Equatable {
    let session: ObjectIdentifier?
    let token: ContextBuilderRunFixture.OperationToken?
    let responseType: String?
    let planModel: String?
    let planningModelRaw: String?
    let isGenerating: Bool?
    let answer: String?
    let error: String?
    let route: ContextBuilderGeneratedAnswerRoute?
    let followUpChatID: UUID?
    let storedChatID: UUID?

    @MainActor
    init(of slot: ContextBuilderRunFixture.TabSlot, in fixture: ContextBuilderRunFixture) {
        let session = fixture.session(slot)
        self.session = session.map(ObjectIdentifier.init)
        token = session?.operationToken
        responseType = session?.mcpResponseType
        planModel = session?.mcpPlanModel
        planningModelRaw = session?.mcpPlanningModelRaw
        isGenerating = session?.isBackgroundPlanGenerating
        answer = session?.backgroundPlanResponseText
        error = session?.backgroundPlanError
        route = session?.generatedAnswerRoute
        followUpChatID = session?.followUpOracleSessionID
        storedChatID = fixture.window.workspaceManager.activeChatSessionID(forTabID: slot.tabID)
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

/// Lets a cleanup registered before a task is started join that task.
@MainActor
private final class ContextBuilderTestTaskHandle {
    var task: Task<Void, Never>?
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
