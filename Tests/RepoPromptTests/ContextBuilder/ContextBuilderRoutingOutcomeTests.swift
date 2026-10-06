import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// How a Context Builder run ends when its startup cannot complete: the run that could not
    /// start fails with the cause that stopped it, only a cancelled run ends as cancelled, and a
    /// run on another tab is left alone.
    @MainActor
    final class ContextBuilderRoutingOutcomeTests: XCTestCase {
        private typealias Fixture = ContextBuilderRunFixture

        /// Start state: the window's MCP tools are disabled, so each run stops at window-tool
        /// registration, where the test changes what the run meets next.
        ///
        /// A second pending policy under the first run's ID keeps the manager from binding that
        /// run's policy to one expected process, which is an arming failure. An explicit disable
        /// while the second run waits is a readiness failure. Both runs end failed with that cause
        /// and never as cancelled; a caller that really is cancelled gets `CancellationError`.
        func testAcquisitionFailureIsNotCancellation() async throws {
            try await Fixture.withFixture { fixture, cleanup in
                let server = fixture.window.mcpServer
                let armingSlot = fixture.slots[0]
                let readinessSlot = fixture.slots[1]
                let clientName = try XCTUnwrap(AgentProviderKind.claudeCode.mcpClientNameHint)

                XCTAssertFalse(server.windowToolsEnabled)
                let armingGate = ContextBuilderTestGate()
                server.setBeforeWindowToolRegistrationForTesting { await armingGate.wait() }
                cleanup.add {
                    server.setBeforeWindowToolRegistrationForTesting(nil)
                    await armingGate.open()
                }

                let armingRun = fixture.startMCPRun(on: armingSlot)
                try await fixture.waitFor("the first run to reach window-tool registration") {
                    await armingGate.entered
                }
                let armingRunID = try XCTUnwrap(fixture.activeRunID(armingSlot))
                cleanup.add {
                    await fixture.manager.clearClientConnectionPolicy(
                        for: clientName,
                        windowID: fixture.window.windowID,
                        runID: armingRunID
                    )
                }
                await fixture.manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.window.windowID,
                    restrictedTools: [],
                    reason: "routing-outcome-tests duplicate policy",
                    runID: armingRunID,
                    purpose: .discoverRun,
                    requiresExpectedAgentPID: true,
                    prunesOnlyAfterSettlement: true
                )
                await armingGate.open()

                let armingCompletion = try await fixture.completion(of: armingRun)
                XCTAssertEqual(
                    armingCompletion.terminalDisposition,
                    .failed(
                        "Failed to prepare MCP connection policy: "
                            + "RepoPrompt MCP expected-PID routing policy could not be armed."
                    )
                )
                XCTAssertNil(armingCompletion.committedTab)
                XCTAssertNil(fixture.operationToken(armingSlot))
                XCTAssertEqual(fixture.providerRequests, [])
                let pendingAfterArmingFailure = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingAfterArmingFailure, [], "A failed acquisition must leave no policy behind.")
                XCTAssertTrue(server.windowToolsEnabled)

                // Disabling the window puts the next run back at window-tool registration.
                _ = await server.setWindowToolsEnabled(false)
                let readinessGate = ContextBuilderTestGate()
                server.setBeforeWindowToolRegistrationForTesting { await readinessGate.wait() }
                var disabling: Task<Void, Never>?
                // The disable is chained behind the enable transition the gate holds, so one
                // cleanup opens the gate before it joins the disable.
                cleanup.add {
                    await readinessGate.open()
                    await disabling?.value
                }
                let enableGeneration = server.windowToolRegistrationIntentGenerationForTesting() + 1

                let readinessRun = fixture.startMCPRun(on: readinessSlot)
                try await fixture.waitFor("the second run to reach window-tool registration") {
                    await readinessGate.entered
                }
                disabling = Task { @MainActor in
                    _ = await server.setWindowToolsEnabled(false)
                }
                try await fixture.waitFor("the explicit disable to replace the run's enable intent") {
                    server.windowToolRegistrationIntentGenerationForTesting() == enableGeneration + 1
                }
                await readinessGate.open()

                let readinessCompletion = try await fixture.completion(of: readinessRun)
                XCTAssertEqual(
                    readinessCompletion.terminalDisposition,
                    .failed(
                        "Failed to start MCP server: "
                            + "RepoPrompt MCP tools were disabled for this window while readiness was pending."
                    )
                )
                await disabling?.value
                XCTAssertFalse(server.windowToolsEnabled, "A failed start must not enable the window again.")
                XCTAssertFalse(server.windowToolsAreRequested)
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), enableGeneration + 1)
                XCTAssertNil(fixture.operationToken(readinessSlot))
                XCTAssertEqual(fixture.providerRequests, [])

                let cancelledRunID = UUID()
                let cancelledSpec = AgentRunSpec(
                    type: .discover,
                    runID: cancelledRunID,
                    agentKind: .claudeCode,
                    modelString: nil,
                    windowID: fixture.window.windowID,
                    restrictedTools: [],
                    connectionTTL: 30
                )
                let cancelledAcquisition = Task { @MainActor in
                    try await AgentRunCoordinator.shared.prepareAndInstallPolicy(
                        cancelledSpec,
                        reason: "routing-outcome-tests cancelled acquisition",
                        gateID: cancelledRunID
                    )
                }
                // The task cannot start before this main-actor test suspends, so it begins cancelled.
                cancelledAcquisition.cancel()
                do {
                    let lease = try await cancelledAcquisition.value
                    await lease.failAndCleanup()
                    XCTFail("A cancelled acquisition must not return a lease.")
                } catch is CancellationError {
                    // Expected: cancellation stays cancellation, not a readiness failure.
                } catch {
                    XCTFail("Expected CancellationError, got \(error)")
                }
                let policiesAfterCancellation = await fixture.manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertFalse(policiesAfterCancellation.contains { $0.runID == cancelledRunID })
            }
        }

        /// Three runs wait for their providers' MCP connections on one manual clock, with the
        /// production startup bounds, and each is inside its own bound for as long as it waits.
        ///
        /// The silent tab's run is started from the panel at 0 s and its provider never connects,
        /// so it fails when the absence bound elapses at 30 s. The observed tab's run is started
        /// through the MCP entry at 30 s; its child connects and is held between the manager's
        /// observation of it and its route, so it fails when the grace period elapses at 40 s, and
        /// the held connection is refused once it is let go. Each timed-out run gives its tab back
        /// through its own origin's release. The survivor tab's run is enrolled at 20 s, so its own
        /// bound ends at 50 s; it loses nothing to either timeout and then routes, commits, and
        /// completes.
        func testRoutingTimeoutFailsOnlyOwningRun() async throws {
            try await Fixture.withFixture(tabNames: ["silent", "observed", "survivor"]) { fixture, cleanup in
                let viewModel = fixture.viewModel
                let manager = fixture.manager
                let silent = fixture.slots[0]
                let observed = fixture.slots[1]
                let survivor = fixture.slots[2]
                let bounds = ContextBuilderStartupPolicy.standard
                let clock = MCPExportWatchdogManualClock()
                Self.useProductionStartupBounds(on: clock, in: viewModel)
                var tornDownRunIDs: Set<UUID> = []
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: { tornDownRunIDs.insert($0) }
                ))
                fixture.holdsChildConnections = true

                let silentProvider = ContextBuilderUnroutedProvider()
                fixture.providerScript = { _ in silentProvider }
                fixture.releaseOnSettle { await silentProvider.finish() }
                let pressed = await fixture.pressRun(on: silent)
                let silentRunID = try XCTUnwrap(pressed)
                try await waitForEnrolledRoutingWait(on: silent, pendingDeadlines: 1, clock: clock, in: fixture)
                fixture.providerScript = nil
                XCTAssertEqual(fixture.activeRunID(silent), silentRunID)
                XCTAssertEqual(fixture.operationToken(silent)?.origin, .ui)
                let silentClientName = try XCTUnwrap(fixture.providerRequests.first?.agentKind.mcpClientNameHint)

                let survivorEnrollment = Duration.seconds(20)
                try await clock.advanceWithoutWakingSleepers(by: survivorEnrollment)
                let survivorRun = fixture.startMCPRun(on: survivor)
                try await waitForEnrolledRoutingWait(on: survivor, pendingDeadlines: 2, clock: clock, in: fixture)
                let survivorRunID = try XCTUnwrap(fixture.activeRunID(survivor))
                let survivorChild = try await fixture.childWithRegisteredProcess(forRunID: survivorRunID)

                // The silent run's deadline is the older of the two pending ones.
                try await clock.advanceNext(expected: bounds.routingWait.noConnectionTimeout)
                XCTAssertEqual(clock.currentTime(), .seconds(30))
                try await fixture.waitForRelease(of: silent)
                let silentFailure = try failureMessage(on: silent, in: fixture)
                XCTAssertTrue(
                    silentFailure.hasPrefix("mcp_routing_timeout_before_connection:"),
                    silentFailure
                )
                try await assertFailedAndCleanedUp(
                    runID: silentRunID,
                    on: silent,
                    clientName: silentClientName,
                    tornDownRunIDs: { tornDownRunIDs },
                    in: fixture
                )
                try await assertStillWaitingForItsChild(survivorRunID, on: survivor, child: survivorChild, in: fixture)

                await manager.debugSuspendNextPendingPolicyRouteInstallation()
                cleanup.add { await manager.debugResumePendingPolicyRouteInstallation() }
                let observedRun = fixture.startMCPRun(on: observed)
                try await waitForEnrolledRoutingWait(on: observed, pendingDeadlines: 2, clock: clock, in: fixture)
                let observedRunID = try XCTUnwrap(fixture.activeRunID(observed))
                XCTAssertEqual(fixture.operationToken(observed)?.origin, .mcp)
                let observedChild = try await fixture.childWithRegisteredProcess(forRunID: observedRunID)
                await observedChild.allowConnection()
                try await fixture.waitFor("the observed tab's child to be held between its observation and its route") {
                    await manager.debugIsPendingPolicyRouteInstallationSuspended()
                }
                let observedWasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: observedRunID)
                XCTAssertTrue(observedWasObserved)
                // The observation dropped that run's absence deadline; its grace joins the
                // survivor's absence deadline.
                try await clock.waitForSleeperCount(2)
                try await clock.advanceSleeper(expected: bounds.routingWait.observedConnectionGrace)
                XCTAssertEqual(clock.currentTime(), .seconds(40))

                try await fixture.waitFor("the observed tab's run to be failed") {
                    fixture.activeRunID(observed) == nil
                }
                let connectionStillHeld = await manager.debugIsPendingPolicyRouteInstallationSuspended()
                XCTAssertTrue(connectionStillHeld, "The failure must not wait for the held connection.")
                await manager.debugResumePendingPolicyRouteInstallation()

                let observedCompletion = try await fixture.completion(of: observedRun)
                let observedFailure = try failureMessage(on: observed, in: fixture)
                XCTAssertTrue(
                    observedFailure.hasPrefix("mcp_routing_timeout_after_connection:"),
                    observedFailure
                )
                XCTAssertEqual(observedCompletion.runID, observedRunID)
                XCTAssertEqual(observedCompletion.terminalDisposition, .failed(observedFailure))
                XCTAssertNil(observedCompletion.committedTab)
                try await assertFailedAndCleanedUp(
                    runID: observedRunID,
                    on: observed,
                    clientName: observedChild.clientName,
                    tornDownRunIDs: { tornDownRunIDs },
                    in: fixture
                )
                // The connection let go after its run was revoked is rolled back, not routed.
                try await fixture.waitFor("the released connection to be rolled back") {
                    await manager.runIDForConnection(observedChild.connectionID) == nil
                }
                XCTAssertNil(fixture.window.mcpServer.connectionID(forRunID: observedRunID))
                XCTAssertNil(observedChild.admission)
                try await assertStillWaitingForItsChild(survivorRunID, on: survivor, child: survivorChild, in: fixture)
                XCTAssertLessThan(
                    clock.currentTime(),
                    survivorEnrollment + bounds.routingWait.noConnectionTimeout,
                    "The survivor must still be inside its own bound."
                )

                await survivorChild.allowConnection()
                let survivorCompletion = try await fixture.completion(of: survivorRun)
                try fixture.assertCommitted(survivorCompletion, by: survivorChild)
                for slot in [silent, observed] {
                    XCTAssertEqual(fixture.storedTab(slot)?.promptText, "")
                    XCTAssertEqual(fixture.storedTab(slot)?.selection.selectedPaths, [])
                }
                let pendingDeadlines = await clock.sleeperCount()
                XCTAssertEqual(pendingDeadlines, 0, "A routed run must drop its deadline.")
            }
        }

        /// A route commits while the run's provider is still initializing, and the publication of
        /// that route is held where it reports its progress to the MCP caller. Provider
        /// initialization then fails. The run ends failed with the provider's error and gives its
        /// tab back, and the held publication, once let go, adds no log entry and updates no
        /// binding for the run that has ended.
        ///
        /// The route is signalled on the routing waiter directly: what the run does with a
        /// committed route depends on that signal alone.
        func testRouteCommittedBeforeProviderInitializationFailsPublishesNothingAfterRunEnds() async throws {
            try await Fixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[0]
                await fixture.window.promptManager.switchComposeTab(slot.tabID)
                let provider = InitializationFailingProvider()
                fixture.providerScript = { _ in provider }
                let publication = ContextBuilderTestGate()
                let publicationResumed = MainActorFlag()

                let run = try Self.startMCPCall(on: slot, in: fixture) { phase in
                    guard phase == .waitingForProviderStreamEvent else { return }
                    await publication.wait()
                    // Set in the main-actor turn that goes on to publish the route.
                    publicationResumed.isSet = true
                }
                cleanup.add {
                    await provider.failInitialization()
                    await publication.open()
                    run.cancel()
                    await run.join()
                }

                try await fixture.waitFor("the provider to be held in initialization with the routing wait enrolled") {
                    guard let runID = provider.runID else { return false }
                    return await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
                }
                let runID = try XCTUnwrap(provider.runID)
                await MCPRoutingWaiter.notifyRouted(runID: runID)
                try await fixture.waitFor("the committed route's publication to be held") {
                    await publication.entered
                }
                XCTAssertFalse(Self.mentionsCommittedRoute(fixture.session(slot)?.agentLog))

                await provider.failInitialization()
                // The publication is still held, so the call is waited for with a bound: a run that
                // waited for the task publishing its route would never return.
                let completion = try await Self.completion(of: run, in: fixture)
                XCTAssertEqual(completion.runID, runID)
                guard case let .failed(failure) = completion.terminalDisposition else {
                    XCTFail("Expected a failed run, got \(completion.terminalDisposition)")
                    throw Fixture.ScenarioAborted()
                }
                XCTAssertTrue(failure.hasPrefix(InitializationFailingProvider.failureMessage), failure)
                XCTAssertNil(completion.committedTab)
                XCTAssertNil(fixture.activeRunID(slot))
                XCTAssertNil(fixture.operationToken(slot))
                let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingRunIDs, [])

                let sessionLogAtRunEnd = fixture.session(slot)?.agentLog
                let publishedLogAtRunEnd = viewModel.agentLog
                var logsPublishedAfterRunEnd: [[AgentLogEntry]] = []
                let subscription = viewModel.$agentLog.dropFirst().sink { logsPublishedAfterRunEnd.append($0) }
                cleanup.add { subscription.cancel() }

                await publication.open()
                try await fixture.waitFor("the held publication to resume") {
                    publicationResumed.isSet
                }
                XCTAssertEqual(fixture.session(slot)?.agentLog, sessionLogAtRunEnd)
                XCTAssertEqual(viewModel.agentLog, publishedLogAtRunEnd)
                XCTAssertFalse(Self.mentionsCommittedRoute(fixture.session(slot)?.agentLog))
                XCTAssertEqual(logsPublishedAfterRunEnd, [])
                XCTAssertNil(fixture.operationToken(slot))
            }
        }

        // MARK: - Provider initialization that outlives its run

        func testUIRunTimedOutDuringProviderInitializationEndsWithoutWaitingForProvider() async throws {
            try await assertRunEndsWithoutWaitingForProviderInitialization(origin: .ui, ending: .routingTimeout)
        }

        func testMCPRunTimedOutDuringProviderInitializationEndsWithoutWaitingForProvider() async throws {
            try await assertRunEndsWithoutWaitingForProviderInitialization(origin: .mcp, ending: .routingTimeout)
        }

        func testUIRunCancelledDuringProviderInitializationEndsWithoutWaitingForProvider() async throws {
            try await assertRunEndsWithoutWaitingForProviderInitialization(origin: .ui, ending: .cancellation)
        }

        func testMCPRunCancelledDuringProviderInitializationEndsWithoutWaitingForProvider() async throws {
            try await assertRunEndsWithoutWaitingForProviderInitialization(origin: .mcp, ending: .cancellation)
        }

        func testUIRunLosingRouteOwnershipDuringProviderInitializationEndsWithoutWaitingForProvider() async throws {
            try await assertRunEndsWithoutWaitingForProviderInitialization(origin: .ui, ending: .routingOwnershipLoss)
        }

        func testMCPRunLosingRouteOwnershipDuringProviderInitializationEndsWithoutWaitingForProvider() async throws {
            try await assertRunEndsWithoutWaitingForProviderInitialization(origin: .mcp, ending: .routingOwnershipLoss)
        }

        /// A route commits while the run's provider is still initializing, and the publication of
        /// that route is held in its progress report. Cancelling the call then ends it and gives
        /// its tab back while the provider and that progress report are both still held: the run
        /// does not wait for the task that publishes its route.
        func testCancellationDoesNotWaitForRoutePublicationHeldInProgressReport() async throws {
            try await Fixture.withFixture { fixture, cleanup in
                let slot = fixture.slots[0]
                await fixture.window.promptManager.switchComposeTab(slot.tabID)
                let initialization = ContextBuilderTestGate()
                let publication = ContextBuilderTestGate()
                cleanup.add {
                    await initialization.open()
                    await publication.open()
                }
                let provider = HeldInitializationProvider(initialization: initialization)
                fixture.providerScript = { _ in provider }
                let publicationResumed = MainActorFlag()

                let call = try Self.startMCPCall(on: slot, in: fixture) { phase in
                    guard phase == .waitingForProviderStreamEvent else { return }
                    await publication.wait()
                    // Set in the main-actor turn that goes on to publish the route.
                    publicationResumed.isSet = true
                }
                cleanup.add {
                    await initialization.open()
                    await publication.open()
                    call.cancel()
                    await call.join()
                }

                try await fixture.waitFor("the provider to be held in initialization with the routing wait enrolled") {
                    guard let runID = provider.runID, await initialization.entered else { return false }
                    return await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
                }
                let runID = try XCTUnwrap(provider.runID)
                await MCPRoutingWaiter.notifyRouted(runID: runID)
                try await fixture.waitFor("the committed route's publication to be held") {
                    await publication.entered
                }

                call.cancel()
                try await fixture.waitFor(
                    "the cancelled call to give its tab back while both holds are still closed",
                    timeout: .seconds(10)
                ) {
                    fixture.operationToken(slot) == nil
                }
                try await Self.assertCancelled(call, in: fixture)
                XCTAssertFalse(provider.didReturnStream)
                XCTAssertFalse(publicationResumed.isSet)
                XCTAssertEqual(fixture.session(slot)?.agentRunState, .cancelled)
                XCTAssertNil(fixture.activeRunID(slot))

                let sessionLogAtRunEnd = fixture.session(slot)?.agentLog
                await publication.open()
                try await fixture.waitFor("the held publication to resume") {
                    publicationResumed.isSet
                }
                XCTAssertEqual(fixture.session(slot)?.agentLog, sessionLogAtRunEnd)
                XCTAssertFalse(Self.mentionsCommittedRoute(fixture.session(slot)?.agentLog))
                XCTAssertTrue(fixture.viewModel.isRunTeardownPendingForTesting(runID: runID))

                await initialization.open()
                try await fixture.waitFor("the ended run's teardown to complete") {
                    !fixture.viewModel.isRunTeardownPendingForTesting(runID: runID)
                        && provider.disposalsOfLateStream == 1
                }
                XCTAssertEqual(provider.disposalsDuringInitialization, 1)
            }
        }

        private enum RunOrigin {
            case ui
            case mcp
        }

        private enum RunEnding {
            case routingTimeout
            case cancellation
            case routingOwnershipLoss
        }

        /// The ended tab's run has a provider that stays in initialization whatever happens to
        /// the run: neither cancellation nor disposal lets it go. The run is ended by its routing
        /// bound, by cancellation, or by losing ownership of its route, while a run on the other
        /// tab, enrolled 20 s later, waits for its own child.
        ///
        /// Ownership is lost through the signal the connection manager sends for each run it owns
        /// when its routing state is reset, sent here for the ended run alone so that the other
        /// tab's run keeps its route.
        ///
        /// With the provider still initializing, the ended run has its terminal outcome, has
        /// committed nothing, holds no policy or routing wait, and has given its tab back through
        /// its origin's release; a successor is admitted on that tab; the other tab's run is
        /// untouched; and the ended run's teardown is still pending. Once the provider is let go
        /// it returns a live stream that already carries output. Teardown disposes that stream
        /// and completes, nothing of it reaches the session or the successor, and the successor
        /// and the other tab's run then route and commit. After an ownership loss the other tab's
        /// run is ended by the same signal instead: it has its provider's stream, so its stream
        /// consumer reports the loss, with the same cause.
        ///
        /// An MCP-origin run is made through the view model's MCP entry inside the cleanup scope
        /// the `context_builder` handler releases its claim in, so its tab is given back only by
        /// that scope ending.
        private func assertRunEndsWithoutWaitingForProviderInitialization(
            origin: RunOrigin,
            ending: RunEnding
        ) async throws {
            try await Fixture.withFixture(tabNames: ["ended", "other"]) { fixture, cleanup in
                let viewModel = fixture.viewModel
                let ended = fixture.slots[0]
                let other = fixture.slots[1]
                let bounds = ContextBuilderStartupPolicy.standard
                let clock = MCPExportWatchdogManualClock()
                Self.useProductionStartupBounds(on: clock, in: viewModel)

                // Nothing that waits on the provider can be joined while this gate is closed, so
                // it is opened first by the fixture's own settlement and by every cleanup below
                // that joins a task.
                let initialization = ContextBuilderTestGate()
                fixture.releaseOnSettle { await initialization.open() }
                cleanup.add { await initialization.open() }

                var tornDownRunIDs: Set<UUID> = []
                var runIDsOfProcessedProviderEvents: [UUID] = []
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: { _, runID, _ in runIDsOfProcessedProviderEvents.append(runID) },
                    teardownCompleted: { tornDownRunIDs.insert($0) }
                ))
                fixture.holdsChildConnections = true
                let heldProvider = HeldInitializationProvider(initialization: initialization)
                fixture.providerScript = { [unowned fixture] _ in
                    fixture.providerRequests.count == 1 ? heldProvider : nil
                }

                await fixture.window.promptManager.switchComposeTab(ended.tabID)
                var mcpCall: MCPCall?
                switch origin {
                case .ui:
                    let pressed = await fixture.pressRun(on: ended)
                    XCTAssertNotNil(pressed)
                case .mcp:
                    let call = try Self.startMCPCall(on: ended, in: fixture)
                    mcpCall = call
                    cleanup.add {
                        await initialization.open()
                        call.cancel()
                        await call.join()
                    }
                }
                try await waitForEnrolledRoutingWait(on: ended, pendingDeadlines: 1, clock: clock, in: fixture)
                try await fixture.waitFor("the ended tab's provider to be held in initialization") {
                    await initialization.entered
                }
                let endedRunID = try XCTUnwrap(fixture.activeRunID(ended))
                XCTAssertEqual(heldProvider.runID, endedRunID)
                let endedToken = try XCTUnwrap(fixture.operationToken(ended))
                XCTAssertEqual(endedToken.origin, origin == .ui ? .ui : .mcp)
                let agentKind = try XCTUnwrap(fixture.providerRequests.first?.agentKind)
                let clientName = try XCTUnwrap(agentKind.mcpClientNameHint)

                let otherEnrollment = Duration.seconds(20)
                try await clock.advanceWithoutWakingSleepers(by: otherEnrollment)
                let otherRun = fixture.startMCPRun(on: other)
                try await waitForEnrolledRoutingWait(on: other, pendingDeadlines: 2, clock: clock, in: fixture)
                let otherRunID = try XCTUnwrap(fixture.activeRunID(other))
                let otherChild = try await fixture.childWithRegisteredProcess(forRunID: otherRunID)

                switch (ending, origin) {
                case (.routingTimeout, _):
                    // The ended run's deadline is the older of the two pending ones.
                    try await clock.advanceNext(expected: bounds.routingWait.noConnectionTimeout)
                    XCTAssertEqual(clock.currentTime(), .seconds(30))
                case (.cancellation, .ui):
                    await viewModel.cancelAgentRun()
                case (.cancellation, .mcp):
                    mcpCall?.cancel()
                case (.routingOwnershipLoss, _):
                    MCPRoutingWaiter.signalFailed(endedRunID)
                }
                try await fixture.waitFor(
                    "the ended run's tab to be given back while its provider is still initializing",
                    timeout: .seconds(10)
                ) {
                    fixture.operationToken(ended) == nil
                }

                let ownershipLossFailure = "mcp_routing_failed: \(agentKind.displayName) lost ownership of the "
                    + "expected MCP client '\(clientName)' before routing committed. "
                    + "The run was terminated and MCP bootstrap state was released."
                let expectedFailure: String? = switch ending {
                case .routingTimeout:
                    "mcp_routing_timeout_before_connection: \(agentKind.displayName) did not open "
                        + "the expected MCP client '\(clientName)' within 30 seconds. "
                        + "The run was terminated and MCP bootstrap state was released."
                case .routingOwnershipLoss:
                    ownershipLossFailure
                case .cancellation:
                    nil
                }
                // The provider is still held, so the MCP call is waited for with a bound.
                if let expectedFailure {
                    XCTAssertEqual(fixture.session(ended)?.agentRunState, .failed(expectedFailure))
                    if let mcpCall {
                        let completion = try await Self.completion(of: mcpCall, in: fixture)
                        XCTAssertEqual(completion.runID, endedRunID)
                        XCTAssertEqual(completion.terminalDisposition, .failed(expectedFailure))
                        XCTAssertNil(completion.committedTab)
                    }
                } else {
                    XCTAssertEqual(fixture.session(ended)?.agentRunState, .cancelled)
                    if let mcpCall {
                        try await Self.assertCancelled(mcpCall, in: fixture)
                    }
                }
                if ending != .routingTimeout {
                    // The bound was never reached and the run's deadline went with it.
                    XCTAssertEqual(clock.currentTime(), otherEnrollment)
                    XCTAssertFalse(
                        fixture.session(ended)?.agentLog.contains { $0.message.contains("mcp_routing_timeout") } == true
                    )
                }
                try await fixture.waitFor("the provider to be disposed while it is still initializing") {
                    heldProvider.disposalsDuringInitialization == 1
                }
                XCTAssertFalse(heldProvider.didReturnStream)
                XCTAssertNil(fixture.activeRunID(ended))
                XCTAssertEqual(fixture.storedTab(ended)?.promptText, "")
                XCTAssertEqual(fixture.storedTab(ended)?.selection.selectedPaths, [])
                try await assertNoRoutingState(forEndedRunID: endedRunID, clientName: clientName, in: fixture)
                let deadlinesAfterRunEnded = await clock.sleeperCount()
                XCTAssertEqual(deadlinesAfterRunEnded, 1, "Only the other tab's deadline may remain.")
                XCTAssertTrue(viewModel.isRunTeardownPendingForTesting(runID: endedRunID))
                XCTAssertFalse(tornDownRunIDs.contains(endedRunID))

                let successorRun = fixture.startMCPRun(on: ended)
                try await waitForEnrolledRoutingWait(on: ended, pendingDeadlines: 2, clock: clock, in: fixture)
                let successorRunID = try XCTUnwrap(fixture.activeRunID(ended))
                XCTAssertNotEqual(successorRunID, endedRunID)
                let successorToken = try XCTUnwrap(fixture.operationToken(ended))
                XCTAssertNotEqual(successorToken.id, endedToken.id)
                let successorChild = try await fixture.childWithRegisteredProcess(forRunID: successorRunID)
                try await assertStillWaitingForItsChild(otherRunID, on: other, child: otherChild, in: fixture)
                XCTAssertLessThan(
                    clock.currentTime(),
                    otherEnrollment + bounds.routingWait.noConnectionTimeout,
                    "The other tab's run must still be inside its own bound."
                )
                XCTAssertTrue(viewModel.isRunTeardownPendingForTesting(runID: endedRunID))

                let sessionLogBeforeLateStream = fixture.session(ended)?.agentLog
                let lastOutputBeforeLateStream = fixture.session(ended)?.lastAgentOutput
                let publishedLogBeforeLateStream = viewModel.agentLog
                var logsPublishedAfterLateStream: [[AgentLogEntry]] = []
                let subscription = viewModel.$agentLog.dropFirst().sink { logsPublishedAfterLateStream.append($0) }
                cleanup.add { subscription.cancel() }

                await initialization.open()
                try await fixture.waitFor("the ended run's teardown to complete") {
                    tornDownRunIDs.contains(endedRunID)
                }
                XCTAssertFalse(viewModel.isRunTeardownPendingForTesting(runID: endedRunID))
                XCTAssertTrue(heldProvider.didReturnStream)
                XCTAssertEqual(heldProvider.disposalsDuringInitialization, 1)
                XCTAssertEqual(heldProvider.disposalsOfLateStream, 1)
                XCTAssertEqual(fixture.session(ended)?.agentLog, sessionLogBeforeLateStream)
                XCTAssertEqual(fixture.session(ended)?.lastAgentOutput, lastOutputBeforeLateStream)
                XCTAssertEqual(viewModel.agentLog, publishedLogBeforeLateStream)
                XCTAssertEqual(logsPublishedAfterLateStream, [])
                XCTAssertFalse(runIDsOfProcessedProviderEvents.contains(endedRunID))
                XCTAssertEqual(fixture.operationToken(ended), successorToken)
                XCTAssertEqual(fixture.activeRunID(ended), successorRunID)
                XCTAssertEqual(fixture.storedTab(ended)?.promptText, "")
                XCTAssertEqual(fixture.storedTab(ended)?.selection.selectedPaths, [])
                try await assertNoRoutingState(forEndedRunID: endedRunID, clientName: clientName, in: fixture)
                let deadlinesAfterLateCleanup = await clock.sleeperCount()
                XCTAssertEqual(deadlinesAfterLateCleanup, 2, "Only the successor's and the other tab's deadlines remain.")
                subscription.cancel()

                await successorChild.allowConnection()
                let successorCompletion = try await fixture.completion(of: successorRun)
                try fixture.assertCommitted(successorCompletion, by: successorChild)
                if ending == .routingOwnershipLoss {
                    MCPRoutingWaiter.signalFailed(otherRunID)
                    let otherCompletion = try await fixture.completion(of: otherRun)
                    XCTAssertEqual(otherCompletion.runID, otherRunID)
                    XCTAssertEqual(otherCompletion.terminalDisposition, .failed(ownershipLossFailure))
                    XCTAssertNil(otherCompletion.committedTab)
                    XCTAssertNil(fixture.operationToken(other))
                    XCTAssertNil(otherChild.admission)
                } else {
                    await otherChild.allowConnection()
                    let otherCompletion = try await fixture.completion(of: otherRun)
                    try fixture.assertCommitted(otherCompletion, by: otherChild)
                }
                fixture.assertStoredTabMatchesSlot(ended)
                XCTAssertFalse(runIDsOfProcessedProviderEvents.contains(endedRunID))
                XCTAssertEqual(heldProvider.disposalsOfLateStream, 1)
            }
        }

        // MARK: - Helpers

        private static func mentionsCommittedRoute(_ log: [AgentLogEntry]?) -> Bool {
            log?.contains { $0.message.contains("analyzing workspace") } == true
        }

        /// Runs the view model's startup bounds at their production values on `clock`.
        private static func useProductionStartupBounds(
            on clock: MCPExportWatchdogManualClock,
            in viewModel: ContextBuilderAgentViewModel
        ) {
            let bounds = ContextBuilderStartupPolicy.standard
            viewModel.setStartupPolicyForTesting(ContextBuilderStartupPolicy(
                readinessTimeout: bounds.readinessTimeout,
                routingWait: bounds.routingWait,
                clock: MCPRoutingWaitClock(
                    now: { clock.currentTime() },
                    sleep: { try await clock.sleep(for: $0) }
                )
            ))
        }

        /// Makes a call on `slot` as the `context_builder` handler does once it has admitted one:
        /// it claims the tab, then runs discovery inside the cleanup scope that releases the
        /// claim. The call's result is set only when that scope has ended.
        private static func startMCPCall(
            on slot: Fixture.TabSlot,
            in fixture: Fixture,
            progressReporter: ContextBuilderMCPProgressReporter? = nil
        ) throws -> MCPCall {
            let viewModel = fixture.viewModel
            let authority = try fixture.mcpAuthority(for: slot)
            let token = try viewModel.beginMCPControlledRun(
                forTabID: slot.tabID,
                workspaceID: fixture.workspaceID,
                responseType: nil,
                planModelName: nil
            )
            let call = MCPCall()
            call.task = Task { @MainActor in
                do {
                    call.result = try await .success(AsyncScope.withCleanup({}, cleanup: {
                        await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: token)
                    }) {
                        try await viewModel.runContextBuilderForMCP(
                            authority: authority,
                            mcpControlToken: token,
                            progressReporter: progressReporter
                        )
                    })
                } catch {
                    call.result = .failure(error)
                }
            }
            return call
        }

        /// The call's result, read once its cleanup scope has ended. The wait is bounded: a call
        /// that cannot end behind something the test still holds closed fails here, and the
        /// test's cleanups then open those holds before they join the call.
        private static func result(
            of call: MCPCall,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> Result<Fixture.Completion, Error> {
            try await fixture.waitFor("the MCP call to return", timeout: .seconds(10), file: file, line: line) {
                call.result != nil
            }
            return try XCTUnwrap(call.result, file: file, line: line)
        }

        private static func completion(
            of call: MCPCall,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> Fixture.Completion {
            try await result(of: call, in: fixture, file: file, line: line).get()
        }

        private static func assertCancelled(
            _ call: MCPCall,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            switch try await result(of: call, in: fixture, file: file, line: line) {
            case .success:
                XCTFail("A cancelled call must not return a result.", file: file, line: line)
            case .failure(is CancellationError):
                // Expected: the caller's cancellation is what the call reports.
                break
            case let .failure(error):
                XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
            }
        }

        /// Nothing of the ended run is left in routing: no pending policy and no routing wait.
        /// The run is named by its ID because its tab may already belong to a successor.
        private func assertNoRoutingState(
            forEndedRunID runID: UUID,
            clientName: String,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let pendingPolicies = await fixture.manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pendingPolicies.contains { $0.runID == runID }, file: file, line: line)
            let enrolledWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(enrolledWaiters, 0, file: file, line: line)
            let routingOutcome = await MCPRoutingWaiter.currentTerminalOutcome(runID: runID)
            XCTAssertNil(routingOutcome, file: file, line: line)
        }

        /// Waits until the run on `slot` has its routing wait enrolled and `clock` holds
        /// `pendingDeadlines` deadlines, the newest of them that wait's own.
        private func waitForEnrolledRoutingWait(
            on slot: Fixture.TabSlot,
            pendingDeadlines: Int,
            clock: MCPExportWatchdogManualClock,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            try await fixture.waitFor("the \(slot.name) tab's routing wait to be enrolled", file: file, line: line) {
                guard let runID = fixture.activeRunID(slot) else { return false }
                let enrolledWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
                let deadlines = await clock.sleeperCount()
                return enrolledWaiters == 1 && deadlines == pendingDeadlines
            }
        }

        /// The failure the tab's last run published on its session.
        private func failureMessage(
            on slot: Fixture.TabSlot,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> String {
            guard case let .failed(message)? = fixture.session(slot)?.agentRunState else {
                XCTFail(
                    "Expected a failed run on the \(slot.name) tab, got \(String(describing: fixture.session(slot)?.agentRunState))",
                    file: file,
                    line: line
                )
                throw Fixture.ScenarioAborted()
            }
            return message
        }

        /// The timed-out run committed nothing and gave back everything it held: its tab, its
        /// pending policy, its routing wait, and its provider.
        private func assertFailedAndCleanedUp(
            runID: UUID,
            on slot: Fixture.TabSlot,
            clientName: String,
            tornDownRunIDs: () -> Set<UUID>,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            XCTAssertEqual(fixture.storedTab(slot)?.promptText, "", file: file, line: line)
            XCTAssertEqual(fixture.storedTab(slot)?.selection.selectedPaths, [], file: file, line: line)
            XCTAssertNil(fixture.activeRunID(slot), file: file, line: line)
            XCTAssertNil(fixture.operationToken(slot), file: file, line: line)
            let pendingRunIDs = try await fixture.pendingPolicyRunIDs(clientName: clientName)
            XCTAssertFalse(pendingRunIDs.contains(runID), file: file, line: line)
            let enrolledWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(enrolledWaiters, 0, file: file, line: line)
            let routingOutcome = await MCPRoutingWaiter.currentTerminalOutcome(runID: runID)
            XCTAssertNil(routingOutcome, "The run's routing state must be removed.", file: file, line: line)
            try await fixture.waitFor("the timed-out run's teardown", file: file, line: line) {
                tornDownRunIDs().contains(runID)
            }
        }

        /// The run is still active with its claim, its pending policy, and its routing wait, and
        /// its child has neither been admitted nor disposed.
        private func assertStillWaitingForItsChild(
            _ runID: UUID,
            on slot: Fixture.TabSlot,
            child: ContextBuilderProviderChild,
            in fixture: Fixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            XCTAssertEqual(fixture.activeRunID(slot), runID, file: file, line: line)
            XCTAssertEqual(fixture.operationToken(slot)?.origin, .mcp, file: file, line: line)
            XCTAssertNil(child.admission, file: file, line: line)
            XCTAssertEqual(child.disposeCount, 0, file: file, line: line)
            let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
            XCTAssertTrue(pendingRunIDs.contains(runID), file: file, line: line)
            let enrolledWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(enrolledWaiters, 1, file: file, line: line)
            let wasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: runID)
            XCTAssertFalse(wasObserved, file: file, line: line)
        }
    }

    /// A provider whose initialization stays open until it is told to fail, so no turn of its
    /// ever streams.
    @MainActor
    private final class InitializationFailingProvider: HeadlessAgentProvider {
        struct InitializationFailure: LocalizedError {
            var errorDescription: String? {
                InitializationFailingProvider.failureMessage
            }
        }

        nonisolated static let failureMessage = "The provider process could not be started."

        private let initialization = ContextBuilderTestGate()
        private(set) var runID: UUID?

        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            self.runID = runID
            await initialization.wait()
            throw InitializationFailure()
        }

        func failInitialization() async {
            await initialization.open()
        }

        func dispose() async {
            await initialization.open()
        }
    }

    /// A provider that stays in initialization until its gate is opened: neither cancelling the
    /// start nor disposing the provider ends that hold. Once let go it returns a live stream that
    /// already carries output and stays open until the provider is disposed again.
    @MainActor
    private final class HeldInitializationProvider: HeadlessAgentProvider {
        private let initialization: ContextBuilderTestGate
        private let lateTurn = ContextBuilderUnroutedProvider(events: ["Output that arrived after its run had ended"])
        private(set) var runID: UUID?
        private(set) var didReturnStream = false
        /// Disposals that found the provider still initializing, with nothing yet to end.
        private(set) var disposalsDuringInitialization = 0
        /// Disposals that ended the stream initialization went on to return.
        private(set) var disposalsOfLateStream = 0

        init(initialization: ContextBuilderTestGate) {
            self.initialization = initialization
        }

        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            self.runID = runID
            await initialization.wait()
            let stream = try await lateTurn.streamAgentMessage(message, runID: runID)
            didReturnStream = true
            return stream
        }

        func dispose() async {
            guard didReturnStream else {
                disposalsDuringInitialization += 1
                return
            }
            disposalsOfLateStream += 1
            await lateTurn.dispose()
        }
    }

    /// A flag read and written on the main actor only, so setting it and whatever its setter
    /// does next without suspending are seen together.
    @MainActor
    private final class MainActorFlag {
        var isSet = false
    }

    /// A call made as the `context_builder` handler makes one. `result` is set once the call's
    /// cleanup scope has ended, so a test waits for the call with a bound instead of joining it.
    @MainActor
    private final class MCPCall {
        var result: Result<ContextBuilderRunFixture.Completion, Error>?
        var task: Task<Void, Never>?

        func cancel() {
            task?.cancel()
        }

        /// Joins the call. For cleanups, once every hold the call can wait behind is open.
        func join() async {
            await task?.value
        }
    }
#endif
