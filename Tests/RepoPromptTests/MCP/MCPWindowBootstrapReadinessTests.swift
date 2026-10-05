import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// Concurrent agent-bootstrap readiness for one window: same-intent callers share one transition,
    /// while explicit window-tools changes still fence older callers.
    @MainActor
    final class MCPWindowBootstrapReadinessTests: XCTestCase {
        func testOverlappingEnsuresShareOneTransitionAndAllSucceed() async throws {
            try await withReadinessWindow { window, _ in
                let server = window.mcpServer
                let gate = ReadinessTestGate()
                server.setAfterWindowToolRegistrationBeforeRetentionForTesting {
                    await gate.arriveAndWait()
                }
                let generationBefore = server.windowToolRegistrationIntentGenerationForTesting()
                let startsBefore = server.windowToolTransitionStartsByGenerationForTesting()

                let ensures = launchReadinessCallers(7, on: server)
                let generation = await awaitSharedTransition(at: gate, on: server, joiners: 6)
                XCTAssertEqual(generation, generationBefore + 1, "Same-intent callers must mint exactly one intent.")

                await gate.release()
                for ensure in ensures {
                    try await ensure.value
                }

                XCTAssertTrue(server.windowToolsEnabled)
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), generation)
                var expectedStarts = startsBefore
                expectedStarts[generation] = 1
                XCTAssertEqual(
                    server.windowToolTransitionStartsByGenerationForTesting(),
                    expectedStarts,
                    "Seven overlapping ensures must run one physical transition."
                )
            }
        }

        func testReadinessIsNotPublishedBeforeRegistrationAndWindowJoinFinish() async throws {
            try await withReadinessWindow { window, service in
                let server = window.mcpServer
                let beforeRegistration = ReadinessTestGate()
                let afterRegistration = ReadinessTestGate()
                server.setBeforeWindowToolRegistrationForTesting {
                    await beforeRegistration.arriveAndWait()
                }
                server.setAfterWindowToolRegistrationBeforeRetentionForTesting {
                    await afterRegistration.arriveAndWait()
                }
                let completion = CompletionFlag()
                let ensure = Task { @MainActor in
                    try await server.requireServerReadyForAgentBootstrap()
                    completion.set()
                }

                let reachedRegistration = await beforeRegistration.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(reachedRegistration)
                XCTAssertFalse(completion.isSet)
                XCTAssertFalse(server.windowToolsEnabled)
                let scopeActiveBeforeRegistration = await Self.windowScopeIsActive(window)
                XCTAssertFalse(scopeActiveBeforeRegistration)

                await beforeRegistration.release()
                let registered = await afterRegistration.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(registered)
                XCTAssertFalse(completion.isSet, "Readiness must wait for the window to join the service.")
                XCTAssertFalse(server.windowToolsEnabled)
                let joinedWhileGated = await service.joinedWindowIDsForTesting()
                XCTAssertFalse(joinedWhileGated.contains(window.windowID))

                await afterRegistration.release()
                try await ensure.value
                XCTAssertTrue(completion.isSet)
                XCTAssertTrue(server.windowToolsEnabled)
                let joined = await service.joinedWindowIDsForTesting()
                XCTAssertTrue(joined.contains(window.windowID))
                let scopeActive = await Self.windowScopeIsActive(window)
                XCTAssertTrue(scopeActive)
            }
        }

        func testExplicitDisableFailsPendingEnsuresAndReclaimsOnlyItsOwnRegistration() async throws {
            try await withReadinessWindows(count: 2) { windows in
                let peer = windows[0].window
                let window = windows[1].window
                let service = windows[1].service
                try await peer.mcpServer.requireServerReadyForAgentBootstrap()
                let server = window.mcpServer
                let gate = ReadinessTestGate()
                server.setAfterWindowToolRegistrationBeforeRetentionForTesting {
                    await gate.arriveAndWait()
                }
                let ensures = launchReadinessCallers(3, on: server)
                let enableGeneration = await awaitSharedTransition(at: gate, on: server, joiners: 2)

                let disabling = Task { @MainActor in
                    await server.stopServer()
                }
                let disableObserved = await waitUntil {
                    server.windowToolRegistrationIntentGenerationForTesting() == enableGeneration + 1
                }
                XCTAssertTrue(disableObserved)
                await gate.release()

                for ensure in ensures {
                    await Self.assertReadinessFails(ensure, with: .windowDisabledDuringReadiness)
                }
                await disabling.value

                XCTAssertFalse(server.windowToolsEnabled)
                XCTAssertFalse(server.windowToolsAreRequested)
                XCTAssertNil(server.windowToolRegistrationFailureDescription)
                let joined = await service.joinedWindowIDsForTesting()
                XCTAssertFalse(joined.contains(window.windowID))
                let windowScopeActive = await Self.windowScopeIsActive(window)
                XCTAssertFalse(
                    windowScopeActive,
                    "The disable must reclaim the registration its superseded enable created."
                )
                let peerScopeActive = await Self.windowScopeIsActive(peer)
                XCTAssertTrue(
                    peerScopeActive,
                    "Reclaiming one window's registration must leave another window's intact."
                )
            }
        }

        func testDisableThenReEnableKeepsTheNewRegistration() async throws {
            try await withReadinessWindow { window, service in
                let server = window.mcpServer
                let gate = ReadinessTestGate()
                server.setAfterWindowToolRegistrationBeforeRetentionForTesting {
                    await gate.arriveAndWait()
                }
                let original = launchReadinessCallers(1, on: server)[0]
                let originalGeneration = await awaitSharedTransition(at: gate, on: server, joiners: 0)

                let disabling = Task { @MainActor in
                    await server.stopServer()
                }
                let disableObserved = await waitUntil {
                    server.windowToolRegistrationIntentGenerationForTesting() == originalGeneration + 1
                }
                XCTAssertTrue(disableObserved)
                let reEnable = Task { @MainActor in
                    try await server.requireServerReadyForAgentBootstrap()
                }
                let reEnableObserved = await waitUntil {
                    server.windowToolRegistrationIntentGenerationForTesting() == originalGeneration + 2
                }
                XCTAssertTrue(reEnableObserved, "An ensure after a disable must mint a new enable intent.")

                await gate.release()
                await Self.assertReadinessFails(original, with: .supersededByExplicitWindowTransition)
                await disabling.value
                try await reEnable.value

                XCTAssertTrue(server.windowToolsEnabled)
                XCTAssertTrue(server.windowToolsAreRequested)
                let joined = await service.joinedWindowIDsForTesting()
                XCTAssertTrue(joined.contains(window.windowID))
                let scopeActive = await Self.windowScopeIsActive(window)
                XCTAssertTrue(
                    scopeActive,
                    "Cleanup from the superseded intents must not remove the re-enabled registration."
                )
            }
        }

        func testCancellingOneWaiterLeavesOtherCallersSuccessful() async throws {
            try await withReadinessWindow { window, _ in
                let server = window.mcpServer
                let gate = ReadinessTestGate()
                server.setAfterWindowToolRegistrationBeforeRetentionForTesting {
                    await gate.arriveAndWait()
                }
                let ensures = launchReadinessCallers(3, on: server)
                let generation = await awaitSharedTransition(at: gate, on: server, joiners: 2)

                ensures[0].cancel()
                await gate.release()

                do {
                    try await ensures[0].value
                    XCTFail("A cancelled caller must not report readiness.")
                } catch is CancellationError {
                    // Expected: cancellation stays cancellation, not a readiness failure.
                } catch {
                    XCTFail("A cancelled caller must throw CancellationError, got \(error)")
                }
                try await ensures[1].value
                try await ensures[2].value
                XCTAssertTrue(server.windowToolsEnabled)
                XCTAssertEqual(server.windowToolTransitionStartsByGenerationForTesting()[generation], 1)
            }
        }

        func testRegistrationFailureReachesEveryJoinedCallerAndLaterEnsureRecovers() async throws {
            try await withReadinessWindow { window, _ in
                let server = window.mcpServer
                let gate = ReadinessTestGate()
                let failures = FailureBudget(count: 1)
                server.setBeforeWindowToolRegistrationForTesting {
                    guard failures.consume() else { return }
                    await gate.arriveAndWait()
                    throw InjectedRegistrationFailure()
                }
                let ensures = launchReadinessCallers(3, on: server)
                let failedGeneration = await awaitSharedTransition(at: gate, on: server, joiners: 2)
                await gate.release()

                let expected = MCPBootstrapReadinessError.windowCatalogRegistrationFailed(
                    diagnostic: String(reflecting: InjectedRegistrationFailure())
                )
                for ensure in ensures {
                    await Self.assertReadinessFails(ensure, with: expected)
                }
                XCTAssertFalse(server.windowToolsEnabled)
                XCTAssertEqual(
                    server.windowToolRegistrationFailureDescription,
                    "window_catalog: \(String(reflecting: InjectedRegistrationFailure()))"
                )

                try await server.requireServerReadyForAgentBootstrap()
                XCTAssertTrue(server.windowToolsEnabled)
                XCTAssertNil(server.windowToolRegistrationFailureDescription)
                XCTAssertEqual(
                    server.windowToolRegistrationIntentGenerationForTesting(),
                    failedGeneration + 1,
                    "Recovery must run as its own independent transition."
                )
                let scopeActive = await Self.windowScopeIsActive(window)
                XCTAssertTrue(scopeActive)
            }
        }

        func testTransitionResultDeliveredAfterExplicitDisableReportsDisabled() async throws {
            try await withReadinessWindow { window, _ in
                let server = window.mcpServer
                let registrationGate = ReadinessTestGate()
                let deliveryGate = ReadinessTestGate()
                server.setAfterWindowToolRegistrationBeforeRetentionForTesting {
                    await registrationGate.arriveAndWait()
                }
                server.setBootstrapReadinessCheckpointForTesting { checkpoint in
                    guard checkpoint == .transitionResultReceived else { return }
                    await deliveryGate.arriveAndWait()
                }
                let ensures = launchReadinessCallers(2, on: server)
                let generation = await awaitSharedTransition(at: registrationGate, on: server, joiners: 1)
                await registrationGate.release()

                // Both callers hold a successful result but have not consumed it yet.
                let bothHoldingResult = await deliveryGate.waitUntilArrivals(2, timeout: .seconds(5))
                XCTAssertTrue(bothHoldingResult)
                XCTAssertTrue(server.windowToolsEnabled, "The shared transition itself succeeded.")
                await server.stopServer()
                XCTAssertFalse(server.windowToolsEnabled)
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), generation + 1)

                await deliveryGate.release()
                for ensure in ensures {
                    await Self.assertReadinessFails(ensure, with: .windowDisabledDuringReadiness)
                }
            }
        }

        func testCancellationDuringEnabledWindowCatalogConfirmationThrowsCancellation() async throws {
            try await withReadinessWindow { window, _ in
                let server = window.mcpServer
                try await server.requireServerReadyForAgentBootstrap()
                let startsBefore = server.windowToolTransitionStartsByGenerationForTesting()
                let gate = ReadinessTestGate()
                server.setBootstrapReadinessCheckpointForTesting { checkpoint in
                    guard checkpoint == .applicationCatalogConfirmation else { return }
                    await gate.arriveAndWait()
                }
                let ensure = Task { @MainActor in
                    try await server.requireServerReadyForAgentBootstrap()
                }
                let confirming = await gate.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(confirming, "An enabled, registered window must take the confirmation path.")
                ensure.cancel()
                await gate.release()

                await Self.assertCancelled(ensure)
                XCTAssertTrue(server.windowToolsEnabled, "Cancellation must not publish a readiness failure.")
                XCTAssertNil(server.windowToolRegistrationFailureDescription)
                XCTAssertEqual(server.windowToolTransitionStartsByGenerationForTesting(), startsBefore)
            }
        }

        // MARK: - Lease acquisition

        func testLeaseBooleanReadinessRefusalReportsCancellationWhenCancelled() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let refused = Self.makeLeaseFixture(mcpServerEnabler: { false })
                await Self.assertAcquireFails(refused, with: .catalogReadinessRejected)

                let gate = ReadinessTestGate()
                let cancelled = Self.makeLeaseFixture(mcpServerEnabler: {
                    await gate.arriveAndWait()
                    return false
                })
                let cancelledLease = cancelled.lease
                let acquisition = Task { try await cancelledLease.requireAcquired() }
                let entered = await gate.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(entered)
                acquisition.cancel()
                await gate.release()

                await Self.assertCancelled(acquisition)
                await Self.assertAcquireFails(cancelled, with: .leaseNoLongerUsable)
            }
        }

        func testLeaseExpectedPIDArmingRefusalReportsCancellationWhenCancelled() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let refused = Self.makeLeaseFixture(requiresExpectedAgentPID: true, expectedPIDPolicyArmer: { false })
                await Self.assertAcquireFails(refused, with: .expectedPIDPolicyArmingFailed)
                let refusedClears = await refused.policy.clearCount
                XCTAssertEqual(refusedClears, 1)

                let gate = ReadinessTestGate()
                let cancelled = Self.makeLeaseFixture(requiresExpectedAgentPID: true, expectedPIDPolicyArmer: {
                    await gate.arriveAndWait()
                    return false
                })
                let cancelledLease = cancelled.lease
                let acquisition = Task { try await cancelledLease.requireAcquired() }
                let entered = await gate.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(entered)
                acquisition.cancel()
                await gate.release()

                await Self.assertCancelled(acquisition)
                let installs = await cancelled.policy.installCount
                XCTAssertEqual(installs, 1)
                let clears = await cancelled.policy.clearCount
                XCTAssertEqual(clears, 1, "A cancelled acquisition must clear its policy before it throws.")
                await Self.assertRoutingRemoved(for: cancelled)
                let gateSnapshot = await HeadlessAgentConnectionGate.snapshot()
                XCTAssertNotEqual(gateSnapshot.activeConnectionID, cancelled.spec.gateID)
                await Self.assertAcquireFails(cancelled, with: .leaseNoLongerUsable)
            }
        }

        func testLeaseCancellationDuringFinalGateReleaseDoesNotReportSuccess() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let acquired = Self.makeLeaseFixture(requiresExpectedAgentPID: true, expectedPIDPolicyArmer: { true })
                try await acquired.lease.requireAcquired()
                try await acquired.lease.requireAcquired()
                let acquiredLease = acquired.lease
                let cancelledCachedCall = Task { @MainActor in
                    try await acquiredLease.requireAcquired()
                }
                // The task cannot start before this MainActor test suspends, so it begins cancelled.
                cancelledCachedCall.cancel()
                await Self.assertCancelled(cancelledCachedCall)
                await acquired.lease.cancelAndCleanup()

                let gate = ReadinessTestGate()
                let cancelled = Self.makeLeaseFixture(requiresExpectedAgentPID: true, expectedPIDPolicyArmer: { true })
                await cancelled.lease.debugSetAfterExpectedPIDGateReleaseHook {
                    await gate.arriveAndWait()
                }
                let cancelledLease = cancelled.lease
                let acquisition = Task { try await cancelledLease.requireAcquired() }
                let releasing = await gate.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(releasing)
                acquisition.cancel()
                await gate.release()

                await Self.assertCancelled(acquisition)
                let clears = await cancelled.policy.clearCount
                XCTAssertEqual(clears, 1, "Cleanup triggered by the cancellation must finish before it throws.")
                await Self.assertRoutingRemoved(for: cancelled)
                await Self.assertAcquireFails(cancelled, with: .leaseNoLongerUsable)
            }
        }

        func testLeaseCancellationDuringFailureCleanupReportsCancellation() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let clearing = ReadinessTestGate()
                let fixture = Self.makeLeaseFixture(
                    requiresExpectedAgentPID: true,
                    expectedPIDPolicyArmer: { false },
                    policyClearGate: clearing
                )
                let lease = fixture.lease
                let acquisition = Task { try await lease.requireAcquired() }
                let clearingStarted = await clearing.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(clearingStarted, "The arming rejection must reach policy cleanup.")
                acquisition.cancel()
                await clearing.release()

                await Self.assertCancelled(acquisition)
                let clears = await fixture.policy.clearCount
                XCTAssertEqual(clears, 1)
                await Self.assertRoutingRemoved(for: fixture)
            }
        }

        // MARK: - Bounded readiness

        /// Two starts wait on one cold enable transition, each with its own bound. The bound that
        /// elapses removes only its own start, while the transition is still held: the transition
        /// is neither cancelled nor restarted, and the other start becomes ready through it.
        func testContextBuilderReadinessExpiryRemovesOnlyThatWaiter() async throws {
            try await withReadinessWindow { window, _ in
                let server = window.mcpServer
                let gate = ReadinessTestGate()
                server.setBeforeWindowToolRegistrationForTesting {
                    await gate.arriveAndWait()
                }
                let bound = Duration.seconds(30)
                let expiringClock = MCPExportWatchdogManualClock()
                let patientClock = MCPExportWatchdogManualClock()

                let expiry = ReadinessOutcome()
                Task { @MainActor in
                    do {
                        try await server.requireContextBuilderReadiness(
                            timeout: bound,
                            clock: Self.routingClock(expiringClock)
                        )
                        expiry.result = .success(())
                    } catch {
                        expiry.result = .failure(error)
                    }
                }
                let generation = await awaitSharedTransition(at: gate, on: server, joiners: 0)
                let patient = Task { @MainActor in
                    try await server.requireContextBuilderReadiness(
                        timeout: bound,
                        clock: Self.routingClock(patientClock)
                    )
                }
                let joined = await waitUntil {
                    server.windowToolTransitionJoinsByGenerationForTesting()[generation, default: 0] == 1
                }
                XCTAssertTrue(joined, "The second start must join the transition the first one began.")

                do {
                    try await expiringClock.waitForSleeperCount(1)
                    try await expiringClock.advanceNext(expected: bound)
                } catch {
                    await gate.release()
                    throw error
                }
                // The transition is still held, so the start is waited for with a bound: one that
                // stayed behind the transition would never return.
                _ = await waitUntil { expiry.result != nil }
                switch expiry.result {
                case .failure(is MCPServerViewModel.ContextBuilderReadinessTimeout)?:
                    // Expected: the start left with its own typed failure.
                    break
                case let .failure(error)?:
                    XCTFail("Expected the readiness timeout, got \(error)")
                case .success?:
                    XCTFail("A start whose bound elapsed must not report readiness.")
                case nil:
                    XCTFail("A start whose bound elapsed must leave while the transition is still held.")
                }
                XCTAssertFalse(server.windowToolsEnabled, "The start must leave while the transition is still held.")
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), generation)

                await gate.release()
                try await patient.value
                XCTAssertTrue(server.windowToolsEnabled)
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), generation)
                XCTAssertEqual(server.windowToolTransitionStartsByGenerationForTesting()[generation], 1)
                let patientDeadlines = await patientClock.sleeperCount()
                XCTAssertEqual(patientDeadlines, 0, "A start that became ready must drop its deadline.")
            }
        }

        /// A start whose wait was settled, with readiness or with a failure, and whose caller is
        /// cancelled before it resumes reports cancellation.
        ///
        /// The cancellation is issued from the readiness checkpoint. That checkpoint runs in the
        /// start's join, in the main-actor turn that goes on to settle the wait without suspending,
        /// so the wait is settled with the join's result before the cancellation can settle it and
        /// before the caller can resume.
        func testContextBuilderReadinessCancelledAtDeliveryReportsCancellation() async throws {
            for settlesWithFailure in [false, true] {
                try await withReadinessWindow { window, _ in
                    let server = window.mcpServer
                    if settlesWithFailure {
                        server.setBeforeWindowToolRegistrationForTesting {
                            throw InjectedRegistrationFailure()
                        }
                    }
                    let start = ReadinessStart()
                    server.setBootstrapReadinessCheckpointForTesting { checkpoint in
                        guard checkpoint == .transitionResultReceived else { return }
                        start.task?.cancel()
                    }
                    let clock = MCPExportWatchdogManualClock()
                    let task = Task { @MainActor in
                        try await server.requireContextBuilderReadiness(
                            timeout: .seconds(30),
                            clock: Self.routingClock(clock)
                        )
                    }
                    start.task = task

                    await Self.assertCancelled(task)
                    XCTAssertEqual(
                        server.windowToolsEnabled,
                        !settlesWithFailure,
                        "The transition settles as it would for a start that was not cancelled."
                    )
                    let pendingDeadlines = await clock.sleeperCount()
                    XCTAssertEqual(pendingDeadlines, 0)
                }
            }
        }

        // MARK: - Routing deadline

        /// With no matching connection the wait ends at the absence bound: the one deadline it
        /// scheduled is exactly that bound. The timeout consults route authority once and, with no
        /// route committed, revokes the run's policy.
        func testRoutingWaitWithoutConnectionEndsAtAbsenceBound() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let clock = MCPExportWatchdogManualClock()
                let progress = RoutingProgressLog()
                let fixture = Self.makeLeaseFixture(requiresExpectedAgentPID: true, routeAuthority: .revocationFenced)
                try await Self.withRoutingWait(on: fixture, clock: clock, progress: progress) { wait in
                    try await clock.advanceNext(expected: Self.routingWaitPolicy.noConnectionTimeout)
                    let outcome = await wait.value

                    XCTAssertEqual(outcome, .timedOutBeforeConnection)
                    XCTAssertEqual(progress.phases, [.waitingForChildConnection, .routingTimeoutBeforeConnection])
                    let authorityChecks = await fixture.policy.routeAuthorityCheckCount
                    XCTAssertEqual(authorityChecks, 1)
                    let clears = await fixture.policy.clearCount
                    XCTAssertEqual(clears, 1)
                    await Self.assertRoutingRemoved(for: fixture)
                }
            }
        }

        /// The first matching connection replaces the absence bound with one grace period. A
        /// repeated observation four seconds later leaves that deadline where it was, so the wait
        /// ends one grace period after the first observation.
        func testFirstObservationStartsOneGraceThatLaterObservationsDoNotExtend() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let clock = MCPExportWatchdogManualClock()
                let progress = RoutingProgressLog()
                let fixture = Self.makeLeaseFixture(requiresExpectedAgentPID: true, routeAuthority: .revocationFenced)
                let grace = Self.routingWaitPolicy.observedConnectionGrace
                try await Self.withRoutingWait(on: fixture, clock: clock, progress: progress) { wait in
                    let runID = fixture.spec.runID
                    let wasFirstObservation = await MCPRoutingWaiter.notifyConnectionObserved(runID: runID)
                    XCTAssertTrue(wasFirstObservation)
                    // The absence deadline was dropped with that observation; this is the grace.
                    try await clock.waitForSleeperCount(1)

                    try await clock.advanceWithoutWakingSleepers(by: .seconds(4))
                    let wasRepeatedObservation = await MCPRoutingWaiter.notifyConnectionObserved(runID: runID)
                    XCTAssertFalse(wasRepeatedObservation)

                    try await clock.advanceNext(expected: grace)
                    let outcome = await wait.value

                    XCTAssertEqual(outcome, .timedOutAfterConnection)
                    XCTAssertEqual(
                        clock.currentTime(),
                        grace,
                        "A grace restarted by the repeated observation would end four seconds later."
                    )
                    XCTAssertEqual(progress.phases, [
                        .waitingForChildConnection,
                        .childConnectionObserved,
                        .waitingForRouting,
                        .routingTimeoutAfterConnection
                    ])
                    let clears = await fixture.policy.clearCount
                    XCTAssertEqual(clears, 1)
                }
            }
        }

        /// Cancelling the waiting caller ends the wait as cancelled, not as a timeout: its deadline
        /// is dropped and route authority is never consulted.
        func testCancellingRoutingWaitReportsCancellationAndDropsItsDeadline() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let clock = MCPExportWatchdogManualClock()
                let progress = RoutingProgressLog()
                let fixture = Self.makeLeaseFixture(requiresExpectedAgentPID: true, routeAuthority: .committed)
                try await Self.withRoutingWait(on: fixture, clock: clock, progress: progress) { wait in
                    wait.cancel()
                    let outcome = await wait.value

                    XCTAssertEqual(outcome, .cancelled)
                    let pendingDeadlines = await clock.sleeperCount()
                    XCTAssertEqual(pendingDeadlines, 0)
                    XCTAssertEqual(progress.phases, [.waitingForChildConnection])
                    let authorityChecks = await fixture.policy.routeAuthorityCheckCount
                    XCTAssertEqual(authorityChecks, 0)
                    let clears = await fixture.policy.clearCount
                    XCTAssertEqual(clears, 1)
                    await Self.assertRoutingRemoved(for: fixture)
                }
            }
        }

        /// A route committed before the deadline's revocation wins even though its routed signal
        /// never reached the waiter: the wait reports the route and the policy is kept.
        func testRouteCommittedBeforeRevocationWinsAtDeadline() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let clock = MCPExportWatchdogManualClock()
                let progress = RoutingProgressLog()
                let fixture = Self.makeLeaseFixture(requiresExpectedAgentPID: true, routeAuthority: .committed)
                try await Self.withRoutingWait(on: fixture, clock: clock, progress: progress) { wait in
                    try await clock.advanceNext(expected: Self.routingWaitPolicy.noConnectionTimeout)
                    let outcome = await wait.value

                    XCTAssertEqual(outcome, .routed)
                    XCTAssertEqual(progress.phases, [
                        .waitingForChildConnection,
                        .childConnectionObserved,
                        .waitingForRouting,
                        .routingConfirmed
                    ])
                    let authorityChecks = await fixture.policy.routeAuthorityCheckCount
                    XCTAssertEqual(authorityChecks, 1)
                    let clears = await fixture.policy.clearCount
                    XCTAssertEqual(clears, 0, "A committed route keeps its policy.")
                }
            }
        }

        // MARK: - Routing refusal

        /// A bootstrap-ready window is not admission: a connection refused for joining an
        /// established run by ancestry alone resumes no connection waiter and stays unbound.
        func testExpectedPIDOnlyRefusalDoesNotNotifyWaitersOrBindReadyWindow() async throws {
            try await withReadinessWindow { window, _ in
                try await window.mcpServer.requireServerReadyForAgentBootstrap()
                let cleanup = FixtureCleanup()
                try await cleanup.perform {
                    let run = try await ExpectedPIDRunFixture.establish(in: window, sessionName: nil, cleanup: cleanup)
                    let manager = run.manager
                    let clientName = run.clientName
                    await manager.debugEnsureRunningLifecycleForSocketFixture()
                    let waitersBefore = await manager.debugConnectionWaiterCountForLifecycleFenceTest()
                    let waiter = Task { await manager.waitForNewConnection(clientName: clientName, timeout: 30) }
                    // A waiter left running would take a later test's connection notification.
                    cleanup.add {
                        waiter.cancel()
                        _ = await waiter.value
                    }
                    let waiterRegistered = await waitUntil {
                        await manager.debugConnectionWaiterCountForLifecycleFenceTest() == waitersBefore + 1
                    }
                    XCTAssertTrue(waiterRegistered)

                    let handshake = try await run.handshake(run.c2, sessionToken: run.c2Token)
                    XCTAssertNotNil(handshake.error)
                    // An admitted handshake resumes its waiter before the initialize response is sent.
                    waiter.cancel()
                    let notifiedConnectionID = await waiter.value
                    XCTAssertNil(notifiedConnectionID)
                    await run.assertUnrouted(run.c2)
                    XCTAssertTrue(window.mcpServer.windowToolsEnabled)
                }
            }
        }

        // MARK: - Fixture

        private struct ReadinessWindow {
            let window: WindowState
            let service: MCPService
        }

        private func withReadinessWindow(
            _ body: (WindowState, MCPService) async throws -> Void
        ) async throws {
            try await withReadinessWindows(count: 1) { windows in
                try await body(windows[0].window, windows[0].service)
            }
        }

        /// Creates every window under one shared-MCP lease; the lease is not re-entrant.
        ///
        /// Windows keep their production `WindowState.sharedMCPService`, whose join and leave only
        /// track window membership. Constructing another `MCPService` would rewire the process-wide
        /// controller and dashboard hooks for every later test.
        private func withReadinessWindows(
            count: Int,
            _ body: ([ReadinessWindow]) async throws -> Void
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                let controllerServiceBefore = await ServerController.shared.mcpService
                let windows = (0 ..< count).map { _ in
                    let window = Self.makeWindowWithoutAutoStart()
                    WindowStatesManager.shared.registerWindowState(window)
                    return ReadinessWindow(window: window, service: window.mcpServer.service)
                }
                for entry in windows {
                    XCTAssertTrue(entry.service === WindowState.sharedMCPService)
                }
                do {
                    try await body(windows)
                } catch {
                    for entry in windows {
                        await Self.tearDown(entry.window)
                    }
                    throw error
                }
                for entry in windows {
                    await Self.tearDown(entry.window)
                }
                // The shared service may finish installing itself as the real owner meanwhile.
                let controllerServiceAfter = await ServerController.shared.mcpService
                XCTAssertTrue(
                    controllerServiceAfter === controllerServiceBefore
                        || controllerServiceAfter === WindowState.sharedMCPService,
                    "The fixture must leave the controller wired to its existing MCP service."
                )
            }
        }

        private static func tearDown(_ window: WindowState) async {
            window.mcpServer.setBeforeWindowToolRegistrationForTesting(nil)
            window.mcpServer.setAfterWindowToolRegistrationBeforeRetentionForTesting(nil)
            window.mcpServer.setBootstrapReadinessCheckpointForTesting(nil)
            // The disable reclaims this window's exact registration handle before teardown.
            _ = await window.mcpServer.setWindowToolsEnabled(false)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }

        private static func makeWindowWithoutAutoStart() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
            return WindowState()
        }

        private static func windowScopeIsActive(_ window: WindowState) async -> Bool {
            let snapshot = await AppDomainRuntimeComposition.shared.catalogSnapshot()
            let scope = MCPDomainToolRegistrationScope.window(id: window.windowID)
            return snapshot.activeScopesByToolName[MCPWindowToolName.readFile]?.contains(scope) == true
        }

        private static func assertReadinessFails(
            _ ensure: Task<Void, Error>,
            with expected: MCPBootstrapReadinessError,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await ensure.value
                XCTFail("Expected readiness to fail with \(expected)", file: file, line: line)
            } catch let error as MCPBootstrapReadinessError {
                XCTAssertEqual(error, expected, file: file, line: line)
            } catch {
                XCTFail("Expected \(expected), got \(error)", file: file, line: line)
            }
        }

        private struct LeaseFixture {
            let lease: MCPBootstrapLease
            let spec: MCPBootstrapLeaseSpec
            let policy: LeasePolicyRecorder
        }

        /// A lease whose policy hooks are recorded locally; routing and gate state stay scoped to
        /// its own run and gate IDs. A `routeAuthority` answers the lease's route-authority check in
        /// place of the connection manager.
        private static func makeLeaseFixture(
            requiresExpectedAgentPID: Bool = false,
            mcpServerEnabler: (@Sendable () async -> Bool)? = nil,
            expectedPIDPolicyArmer: (@Sendable () async -> Bool)? = nil,
            policyClearGate: ReadinessTestGate? = nil,
            routeAuthority: MCPRunRouteAuthorityDecision? = nil
        ) -> LeaseFixture {
            let spec = MCPBootstrapLeaseSpec(
                runID: UUID(),
                gateID: UUID(),
                windowID: 0,
                tabID: nil,
                clientName: nil,
                restrictedTools: [],
                additionalTools: nil,
                oneShot: true,
                reason: "bootstrap-readiness-tests",
                ttl: 30,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: requiresExpectedAgentPID
            )
            let policy = LeasePolicyRecorder()
            let lease = MCPBootstrapLease(
                spec: spec,
                mcpServerEnabler: mcpServerEnabler,
                policyInstaller: { _ in await policy.recordInstall() },
                expectedPIDPolicyArmer: { _ in await expectedPIDPolicyArmer?() ?? true },
                policyClearer: { _ in
                    await policy.recordClear()
                    await policyClearGate?.arriveAndWait()
                },
                routeAuthorityResolver: routeAuthority.map { decision in
                    { _ in
                        await policy.recordRouteAuthorityCheck()
                        return decision
                    }
                }
            )
            return LeaseFixture(lease: lease, spec: spec, policy: policy)
        }

        private static let routingWaitPolicy = ContextBuilderStartupPolicy.standard.routingWait

        private static func routingClock(_ clock: MCPExportWatchdogManualClock) -> MCPRoutingWaitClock {
            MCPRoutingWaitClock(
                now: { clock.currentTime() },
                sleep: { try await clock.sleep(for: $0) }
            )
        }

        /// Acquires `fixture`'s lease, starts its bounded routing wait on `clock`, and runs `body`
        /// once that wait's absence deadline is pending, so a signal or an advance made by `body`
        /// reaches an enrolled waiter. The wait and the lease are settled however `body` ends.
        private static func withRoutingWait(
            on fixture: LeaseFixture,
            clock: MCPExportWatchdogManualClock,
            progress: RoutingProgressLog,
            _ body: (Task<MCPRoutingWaitOutcome, Never>) async throws -> Void
        ) async throws {
            try await fixture.lease.requireAcquired()
            let lease = fixture.lease
            let wait = Task {
                await lease.releaseWhenRouted(
                    waitPolicy: routingWaitPolicy,
                    clock: routingClock(clock),
                    progressReporter: { progress.record($0) }
                )
            }
            let result: Result<Void, Error>
            do {
                try await clock.waitForSleeperCount(1)
                let enrolledWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: fixture.spec.runID)
                XCTAssertEqual(enrolledWaiters, 1)
                try await body(wait)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            wait.cancel()
            _ = await wait.value
            await fixture.lease.cancelAndCleanup()
            try result.get()
        }

        private static func assertAcquireFails(
            _ fixture: LeaseFixture,
            with expected: MCPBootstrapReadinessError,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await fixture.lease.requireAcquired()
                XCTFail("Expected acquisition to fail with \(expected)", file: file, line: line)
            } catch let error as MCPBootstrapReadinessError {
                XCTAssertEqual(error, expected, file: file, line: line)
            } catch {
                XCTFail("Expected \(expected), got \(error)", file: file, line: line)
            }
        }

        private static func assertCancelled(
            _ task: Task<Void, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await task.value
                XCTFail("A cancelled caller must not report success.", file: file, line: line)
            } catch is CancellationError {
                // Cancellation stays cancellation, never a readiness failure.
            } catch {
                XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
            }
        }

        /// Cancellation cleanup signals a routing failure and then removes the run's waiter state, so a
        /// retained failed outcome would mean the routing cleanup never ran.
        private static func assertRoutingRemoved(
            for fixture: LeaseFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let outcome = await MCPRoutingWaiter.currentTerminalOutcome(runID: fixture.spec.runID)
            XCTAssertNil(outcome, "Routing state must be removed for the run.", file: file, line: line)
            let continuations = await MCPRoutingWaiter.debugContinuationCount(runID: fixture.spec.runID)
            XCTAssertEqual(continuations, 0, file: file, line: line)
        }

        /// Starts `count` bootstrap ensures that run concurrently on the main actor.
        private func launchReadinessCallers(_ count: Int, on server: MCPServerViewModel) -> [Task<Void, Error>] {
            (0 ..< count).map { _ in
                Task { @MainActor in
                    try await server.requireServerReadyForAgentBootstrap()
                }
            }
        }

        /// Waits for the shared transition to reach `gate`, captures the intent generation it serves,
        /// then waits until `joiners` other callers have joined it. Returns that generation.
        private func awaitSharedTransition(
            at gate: ReadinessTestGate,
            on server: MCPServerViewModel,
            joiners: Int,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> UInt64 {
            let entered = await gate.waitUntilEntered(timeout: .seconds(5))
            XCTAssertTrue(entered, "The shared transition must reach its gate.", file: file, line: line)
            let generation = server.windowToolRegistrationIntentGenerationForTesting()
            let joined = await waitUntil {
                server.windowToolTransitionJoinsByGenerationForTesting()[generation, default: 0] == joiners
            }
            XCTAssertTrue(joined, "\(joiners) callers must join the shared transition.", file: file, line: line)
            return generation
        }

        /// Polls a condition that another task makes true; the timeout bounds a broken fixture.
        private func waitUntil(
            timeout: Duration = .seconds(5),
            _ condition: @MainActor () async -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() { return true }
                try? await clock.sleep(for: .milliseconds(5))
            }
            return await condition()
        }
    }

    private struct InjectedRegistrationFailure: Error {}

    private actor LeasePolicyRecorder {
        private(set) var installCount = 0
        private(set) var clearCount = 0
        private(set) var routeAuthorityCheckCount = 0

        func recordInstall() {
            installCount += 1
        }

        func recordClear() {
            clearCount += 1
        }

        func recordRouteAuthorityCheck() {
            routeAuthorityCheckCount += 1
        }
    }

    /// Lets a hook installed before a start exists reach that start's task.
    @MainActor
    private final class ReadinessStart {
        var task: Task<Void, Error>?
    }

    /// Where a readiness start leaves its outcome, so a test waits for it with a bound.
    @MainActor
    private final class ReadinessOutcome {
        var result: Result<Void, Error>?
    }

    @MainActor
    private final class RoutingProgressLog {
        private(set) var phases: [MCPBootstrapRoutingProgress] = []

        func record(_ phase: MCPBootstrapRoutingProgress) {
            phases.append(phase)
        }
    }

    @MainActor
    private final class CompletionFlag {
        private(set) var isSet = false

        func set() {
            isSet = true
        }
    }

    @MainActor
    private final class FailureBudget {
        private var remaining: Int

        init(count: Int) {
            remaining = count
        }

        func consume() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    /// Holds every arrival until released; arrivals after the release pass straight through.
    actor ReadinessTestGate {
        private var arrivals = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            arrivals += 1
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered(timeout: Duration) async -> Bool {
            await waitUntilArrivals(1, timeout: timeout)
        }

        func waitUntilArrivals(_ count: Int, timeout: Duration) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while arrivals < count, clock.now < deadline {
                try? await clock.sleep(for: .milliseconds(5))
            }
            return arrivals >= count
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif
