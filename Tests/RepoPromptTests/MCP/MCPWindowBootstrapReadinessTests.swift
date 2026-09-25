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
        /// its own run and gate IDs.
        private static func makeLeaseFixture(
            requiresExpectedAgentPID: Bool = false,
            mcpServerEnabler: (@Sendable () async -> Bool)? = nil,
            expectedPIDPolicyArmer: (@Sendable () async -> Bool)? = nil,
            policyClearGate: ReadinessTestGate? = nil
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
                }
            )
            return LeaseFixture(lease: lease, spec: spec, policy: policy)
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

        func recordInstall() {
            installCount += 1
        }

        func recordClear() {
            clearCount += 1
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
    private actor ReadinessTestGate {
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
