import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// How a `context_builder` call that has claimed its tab, and has no registered run yet, is
    /// ended when its tab or window closes. Every call here is a real tool call from a caller
    /// connection, held at one of the handler's own steps between the claim and registration.
    ///
    /// Three things are told apart throughout: the call being told to stop, the handler having
    /// unwound and released the tab, and the step the call was suspended in having returned. A
    /// step that ends when cancelled gives all three together. A step that ignores cancellation
    /// gives only the first until it returns on its own, and these tests release such a step
    /// themselves instead of asserting how long it takes.
    @MainActor
    final class MCPContextBuilderPreparationCancellationTests: XCTestCase {
        /// Closing the window ends a call held in a step that ends when cancelled, as the
        /// auto-selection drain does: the call is told to stop, its handler unwinds, the tab is
        /// released, and the caller is answered on a connection that stays open. The test never
        /// releases the step.
        func testWindowCloseEndsCallHeldInPreparation() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let slot = fixture.slots[1]
                let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                let step = HeldStep(ignoresCancellation: false)
                Self.holdProviderValidation(at: step, on: fixture, cleanup: cleanup)
                let call = ToolCall(caller, tabID: slot.tabID)
                fixture.releaseOnSettle {
                    step.open()
                    await call.join()
                }
                try await fixture.waitFor("the call to be held in its preparation") { step.entryCount == 1 }
                let token = try XCTUnwrap(fixture.operationToken(slot))
                XCTAssertEqual(token.origin, .mcp)
                XCTAssertNil(fixture.activeRunID(slot))
                XCTAssertEqual(fixture.session(slot)?.preparationCancellation?.tokenID, token.id)

                let close = WindowClose(fixture.window)
                try await fixture.waitFor("the window's close to return") { close.hasReturned }
                guard step.wasToldToStop else {
                    XCTFail("Closing the window did not tell the call held in preparation to stop")
                    throw ContextBuilderRunFixture.ScenarioAborted()
                }
                try await fixture.waitFor("the cancelled call to be answered") { call.hasEnded }
                try Self.assertAnsweredAsCancelled(call)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertNil(fixture.session(slot)?.preparationCancellation)
                XCTAssertEqual(fixture.viewModel.tabsHeldAgainstNewRun, [])
                XCTAssertNil(fixture.activeRunID(slot))
                XCTAssertEqual(fixture.providerRequests, [])
                try await Self.assertStillAnswers(caller)
            }
        }

        /// Closing a tab ends that tab's held call and nothing else: a run on another tab keeps its
        /// claim, its routing policy, and its provider, and completes with its own commit.
        func testTabCloseEndsOnlyThatTabsCallHeldInPreparation() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let other = fixture.slots[0]
                let closing = fixture.slots[1]
                let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                let step = HeldStep(ignoresCancellation: false)
                Self.holdProviderValidation(at: step, on: fixture, cleanup: cleanup)

                fixture.holdsChildConnections = true
                let otherRun = fixture.startMCPRun(on: other)
                let otherRunID = try await fixture.registeredRunID(on: other)
                let otherChild = try await fixture.childWithRegisteredProcess(forRunID: otherRunID)
                let otherToken = try XCTUnwrap(fixture.operationToken(other))

                let call = ToolCall(caller, tabID: closing.tabID)
                fixture.releaseOnSettle {
                    step.open()
                    await call.join()
                }
                try await fixture.waitFor("the call to be held in its preparation") { step.entryCount == 1 }
                XCTAssertEqual(fixture.operationToken(closing)?.origin, .mcp)

                await fixture.window.promptManager.closeComposeTab(closing.tabID)
                XCTAssertNil(fixture.storedTab(closing), "The tab closed")
                guard step.wasToldToStop else {
                    XCTFail("Closing the tab did not tell its call held in preparation to stop")
                    throw ContextBuilderRunFixture.ScenarioAborted()
                }
                try await fixture.waitFor("the cancelled call to be answered") { call.hasEnded }
                try Self.assertAnsweredAsCancelled(call)
                XCTAssertNil(fixture.session(closing))
                XCTAssertEqual(fixture.viewModel.tabsHeldAgainstNewRun, [other.tabID])
                try await Self.assertStillAnswers(caller)

                XCTAssertNil(otherRun.result)
                XCTAssertEqual(fixture.operationToken(other), otherToken)
                XCTAssertEqual(fixture.activeRunID(other), otherRunID)
                XCTAssertEqual(otherChild.disposeCount, 0)
                XCTAssertEqual(fixture.providerRequests.count, 1)
                let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingRunIDs, [otherRunID])

                await otherChild.allowConnection()
                try await fixture.assertCommitted(fixture.completion(of: otherRun), by: otherChild)
            }
        }

        /// Provider validation does not respond to a call's cancellation. A call held there is told
        /// to stop when its window closes, and the window's close returns with the step still
        /// held. The handler has not unwound by then: the caller is unanswered and the tab is still
        /// claimed. Both follow once the step returns.
        func testCallHeldInStepThatIgnoresCancellationUnwindsWhenThatStepReturns() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let slot = fixture.slots[1]
                let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                let step = HeldStep(ignoresCancellation: true)
                Self.holdProviderValidation(at: step, on: fixture, cleanup: cleanup)
                let call = ToolCall(caller, tabID: slot.tabID)
                fixture.releaseOnSettle {
                    step.open()
                    await call.join()
                }
                try await fixture.waitFor("the call to be held in its preparation") { step.entryCount == 1 }
                let token = try XCTUnwrap(fixture.operationToken(slot))

                let close = WindowClose(fixture.window)
                try await fixture.waitFor("the window's close to return") { close.hasReturned }
                guard step.wasToldToStop else {
                    XCTFail("Closing the window did not tell the call held in preparation to stop")
                    throw ContextBuilderRunFixture.ScenarioAborted()
                }
                XCTAssertFalse(call.hasEnded)
                XCTAssertEqual(fixture.operationToken(slot), token)

                step.open()
                try await fixture.waitFor("the call to be answered once its step returned") { call.hasEnded }
                try Self.assertAnsweredAsCancelled(call)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertEqual(fixture.providerRequests, [])
                try await Self.assertStillAnswers(caller)
            }
        }

        /// A call cancelled during preparation never starts a run, however late in preparation it
        /// was cancelled. Each call here has resolved its run authority and is held sending its
        /// first stage-progress update, a step that ignores cancellation, when it is cancelled.
        /// Once that step returns the call registers no run and asks for no provider.
        ///
        /// The caller's own cancellation leaves the tab claimed and its window open, so nothing
        /// but the call having been cancelled stops it there.
        func testCallCancelledAfterResolvingItsRunAuthorityNeverStartsRun() async throws {
            for cancellation in LateCancellation.allCases {
                try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                    let viewModel = fixture.viewModel
                    let slot = fixture.slots[1]
                    let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                    cleanup.add { viewModel.installRunTestHooks(nil) }
                    viewModel.installRunTestHooks(Self.hooks(validatingProviders: {}))
                    let step = HeldStep(ignoresCancellation: true)
                    Self.holdFirstStageProgress(at: step, on: fixture, cleanup: cleanup)
                    let registrations = RegistrationRecorder(viewModel, tabID: slot.tabID)
                    cleanup.add { registrations.stop() }

                    let requestID = caller.client.nextRequestIDForTesting()
                    let call = ToolCall(caller, tabID: slot.tabID)
                    fixture.releaseOnSettle {
                        step.open()
                        call.abandon()
                        await call.join()
                    }
                    try await fixture.waitFor("the \(cancellation) call to be held after resolving its run authority") {
                        step.entryCount == 1
                    }
                    let token = try XCTUnwrap(fixture.operationToken(slot))
                    XCTAssertEqual(fixture.session(slot)?.preparationCancellation?.tokenID, token.id)

                    switch cancellation {
                    case .tabClose:
                        await fixture.window.promptManager.closeComposeTab(slot.tabID)
                        XCTAssertNil(fixture.storedTab(slot), "The tab closed")
                    case .windowClose:
                        let close = WindowClose(fixture.window)
                        try await fixture.waitFor("the window's close to return") {
                            close.hasReturned
                        }
                    case .callerCancellation:
                        try caller.client.sendNotification(
                            method: "notifications/cancelled",
                            params: ["requestId": requestID]
                        )
                        try await fixture.waitFor("the caller's cancellation to reach the call") {
                            step.wasToldToStop
                        }
                    }
                    guard step.wasToldToStop else {
                        XCTFail("The \(cancellation) did not tell the call held in preparation to stop")
                        throw ContextBuilderRunFixture.ScenarioAborted()
                    }
                    if cancellation != .tabClose {
                        XCTAssertEqual(fixture.operationToken(slot), token, "\(cancellation)")
                    }

                    step.open()
                    switch cancellation {
                    case .tabClose, .windowClose:
                        try await fixture.waitFor("the \(cancellation) call to be answered once its step returned") {
                            call.hasEnded
                        }
                        try Self.assertAnsweredAsCancelled(call)
                    case .callerCancellation:
                        // A cancelled request is not answered, so the release of its tab is what
                        // shows that its handler unwound.
                        try await fixture.waitFor("the cancelled call's tab to be released") {
                            fixture.operationToken(slot) == nil
                        }
                    }

                    XCTAssertEqual(registrations.count, 0, "\(cancellation)")
                    XCTAssertNil(fixture.activeRunID(slot), "\(cancellation)")
                    XCTAssertEqual(fixture.providerRequests, [], "\(cancellation)")
                    XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [], "\(cancellation)")
                    if cancellation == .tabClose {
                        XCTAssertNil(viewModel.sessions[slot.tabID])
                    } else {
                        let session = try XCTUnwrap(fixture.session(slot), "\(cancellation)")
                        XCTAssertNil(session.operationToken, "\(cancellation)")
                        XCTAssertNil(session.preparationCancellation, "\(cancellation)")
                        XCTAssertEqual(session.runHistory.count, 0, "\(cancellation)")
                    }
                }
            }
        }

        /// A window that is already closing refuses the claim, so the call gets no cancel action
        /// and reaches none of its preparation steps.
        func testCallRefusedByClosingWindowInstallsNoCancelAction() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let slot = fixture.slots[1]
                let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                let step = HeldStep(ignoresCancellation: false)
                Self.holdProviderValidation(at: step, on: fixture, cleanup: cleanup)
                fixture.releaseOnSettle { step.open() }
                var claims = 0
                let claimed = fixture.viewModel.$tabsHeldAgainstNewRun
                    .filter { $0.contains(slot.tabID) }
                    .sink { _ in claims += 1 }
                cleanup.add { claimed.cancel() }

                fixture.viewModel.prepareForWindowClose()
                let call = ToolCall(caller, tabID: slot.tabID)
                fixture.releaseOnSettle { await call.join() }
                try await fixture.waitFor("the refused call to be answered") { call.hasEnded }

                try Self.assertAnsweredAsCancelled(call)
                XCTAssertEqual(claims, 0)
                XCTAssertEqual(step.entryCount, 0)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertNil(fixture.session(slot)?.preparationCancellation)
                XCTAssertEqual(fixture.providerRequests, [])
            }
        }

        /// The cancel action is gone in the main-actor turn that registers the call's run, and
        /// from then on closing the window cancels the call through that run.
        func testRegisteringTheRunRemovesTheCancelAction() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[1]
                let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(Self.hooks(validatingProviders: {}))
                let provider = ContextBuilderUnroutedProvider()
                fixture.providerScript = { _ in provider }
                fixture.releaseOnSettle { await provider.finish() }

                // Published in the turn that registers the run.
                var actionsAtRegistration: [UUID?] = []
                var runsAtRegistration: [UUID?] = []
                let registered = viewModel.$tabsWithActiveContextBuilderRun
                    .filter { $0.contains(slot.tabID) }
                    .sink { _ in
                        actionsAtRegistration.append(fixture.session(slot)?.preparationCancellation?.tokenID)
                        runsAtRegistration.append(fixture.activeRunID(slot))
                    }
                cleanup.add { registered.cancel() }

                let call = ToolCall(caller, tabID: slot.tabID)
                fixture.releaseOnSettle { await call.join() }
                try await fixture.waitFor("the call's provider to start its turn") { provider.runID != nil }
                let runID = try XCTUnwrap(fixture.activeRunID(slot))
                let token = try XCTUnwrap(fixture.operationToken(slot))
                XCTAssertEqual(actionsAtRegistration, [nil])
                XCTAssertEqual(runsAtRegistration, [runID])
                XCTAssertNil(fixture.session(slot)?.preparationCancellation)

                // Nothing is left for the claim's own cancellation to act on.
                viewModel.cancelMCPPreparation(forTabID: slot.tabID, controlToken: token.id)
                XCTAssertEqual(fixture.activeRunID(slot), runID)
                XCTAssertFalse(call.hasEnded)

                let close = WindowClose(fixture.window)
                try await fixture.waitFor("the window's close to return") { close.hasReturned }
                XCTAssertNil(fixture.activeRunID(slot))
                try await fixture.waitFor("the cancelled call to be answered") { call.hasEnded }
                try Self.assertAnsweredAsCancelled(call)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertEqual(fixture.providerRequests.count, 1)
            }
        }

        /// A call whose preparation fails on its own takes its cancel action with it: the tab is
        /// released, nothing is left to cancel, and the tab can be claimed again.
        func testPreparationThatFailsOnItsOwnLeavesNoCancelAction() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[1]
                let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                let step = HeldStep(ignoresCancellation: true)
                cleanup.add { viewModel.installRunTestHooks(nil) }
                // Validation that has not completed when the step returns fails the call.
                viewModel.installRunTestHooks(Self.hooks(validatingProviders: {
                    await step.wait()
                    fixture.window.apiSettingsViewModel.test_resetContextBuilderProviderValidation()
                }))
                let call = ToolCall(caller, tabID: slot.tabID)
                fixture.releaseOnSettle {
                    step.open()
                    await call.join()
                }
                try await fixture.waitFor("the call to be held in its preparation") { step.entryCount == 1 }
                let token = try XCTUnwrap(fixture.operationToken(slot))
                XCTAssertEqual(fixture.session(slot)?.preparationCancellation?.tokenID, token.id)

                step.open()
                try await fixture.waitFor("the failed call to be answered") { call.hasEnded }
                let response = try XCTUnwrap(call.response)
                XCTAssertTrue(response.rawJSON.contains("\"isError\":true"), response.rawJSON)
                XCTAssertTrue(response.rawJSON.contains("validation is still in progress"), response.rawJSON)
                XCTAssertFalse(step.wasToldToStop)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertNil(fixture.session(slot)?.preparationCancellation)

                viewModel.cancelMCPPreparation(forTabID: slot.tabID, controlToken: token.id)
                let successor = try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                XCTAssertNil(fixture.session(slot)?.preparationCancellation)
                await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: successor)
                XCTAssertNil(fixture.operationToken(slot))
            }
        }

        /// A cancel action acts only for the claim that installed it. Once that claim is released
        /// and a later call has claimed the same tab, neither asking for the earlier claim's
        /// cancellation nor running the earlier action itself touches the later call. Asking for
        /// the later claim's own cancellation ends it.
        func testCancelActionOfAnEarlierCallLeavesLaterCallOnTheTabRunning() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[1]
                let caller = try await Self.connectCaller(to: fixture, cleanup: cleanup)
                let earlierStep = HeldStep(ignoresCancellation: false)
                let laterStep = HeldStep(ignoresCancellation: false)
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(Self.hooks(validatingProviders: {
                    await (earlierStep.entryCount == 0 ? earlierStep : laterStep).wait()
                }))
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(finishesImmediately: true) }

                let earlier = ToolCall(caller, tabID: slot.tabID)
                fixture.releaseOnSettle {
                    earlierStep.open()
                    laterStep.open()
                    await earlier.join()
                }
                try await fixture.waitFor("the earlier call to be held in its preparation") {
                    earlierStep.entryCount == 1
                }
                let earlierToken = try XCTUnwrap(fixture.operationToken(slot))
                let earlierAction = try XCTUnwrap(fixture.session(slot)?.preparationCancellation)
                XCTAssertEqual(earlierAction.tokenID, earlierToken.id)

                earlierStep.open()
                try await fixture.waitFor("the earlier call to end") { earlier.hasEnded }
                XCTAssertFalse(earlierStep.wasToldToStop)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertEqual(fixture.providerRequests.count, 1)

                let later = ToolCall(caller, tabID: slot.tabID)
                fixture.releaseOnSettle { await later.join() }
                try await fixture.waitFor("the later call to be held in its preparation") {
                    laterStep.entryCount == 1
                }
                let laterToken = try XCTUnwrap(fixture.operationToken(slot))
                XCTAssertNotEqual(laterToken.id, earlierToken.id)
                XCTAssertEqual(fixture.session(slot)?.preparationCancellation?.tokenID, laterToken.id)

                viewModel.cancelMCPPreparation(forTabID: slot.tabID, controlToken: earlierToken.id)
                earlierAction.cancel()
                guard !laterStep.wasToldToStop else {
                    XCTFail("The earlier call's cancel action told the later call to stop")
                    throw ContextBuilderRunFixture.ScenarioAborted()
                }
                XCTAssertFalse(later.hasEnded)
                XCTAssertEqual(fixture.operationToken(slot), laterToken)
                XCTAssertEqual(fixture.session(slot)?.preparationCancellation?.tokenID, laterToken.id)

                viewModel.cancelMCPPreparation(forTabID: slot.tabID, controlToken: laterToken.id)
                XCTAssertTrue(laterStep.wasToldToStop)
                try await fixture.waitFor("the later call to be answered") { later.hasEnded }
                try Self.assertAnsweredAsCancelled(later)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertEqual(fixture.providerRequests.count, 1)
            }
        }

        // MARK: Support

        /// What cancels a call that is already past resolving its run authority.
        private enum LateCancellation: CaseIterable {
            case tabClose
            case windowClose
            case callerCancellation
        }

        /// Starts the window's server, lets the tool resolve a run authority in it, and connects
        /// a caller with no tab binding, which names the tab it calls for.
        private static func connectCaller(
            to fixture: ContextBuilderRunFixture,
            cleanup: FixtureCleanup
        ) async throws -> PersistentMCPTestEndpoint {
            await fixture.startWindowServer()
            fixture.makeRunAuthorityResolvable(cleanup: cleanup)
            return try await fixture.connectCaller("preparation", cleanup: cleanup)
        }

        private static func hooks(
            validatingProviders: @escaping @MainActor @Sendable () async -> Void
        ) -> ContextBuilderAgentViewModel.RunTestHooks {
            .init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                validateContextBuilderProviders: validatingProviders
            )
        }

        /// Holds every call at provider validation, a step inside run-authority resolution.
        private static func holdProviderValidation(
            at step: HeldStep,
            on fixture: ContextBuilderRunFixture,
            cleanup: FixtureCleanup
        ) {
            let viewModel = fixture.viewModel
            cleanup.add { viewModel.installRunTestHooks(nil) }
            viewModel.installRunTestHooks(hooks(validatingProviders: { await step.wait() }))
        }

        /// Holds every call at its first stage-progress send, which follows run-authority
        /// resolution and precedes the run's registration.
        private static func holdFirstStageProgress(
            at step: HeldStep,
            on fixture: ContextBuilderRunFixture,
            cleanup: FixtureCleanup
        ) {
            let server = fixture.window.mcpServer
            cleanup.add { server.installStageProgressSinkForTesting(nil) }
            server.installStageProgressSinkForTesting { _, tool, stage, _ in
                guard tool == MCPWindowToolName.contextBuilder, stage == "starting" else { return }
                await step.wait()
            }
        }

        private static func assertAnsweredAsCancelled(
            _ call: ToolCall,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let response = try XCTUnwrap(call.response, "\(String(describing: call.failure))", file: file, line: line)
            XCTAssertTrue(response.rawJSON.contains("\"isError\":true"), response.rawJSON, file: file, line: line)
            XCTAssertTrue(response.rawJSON.contains("Tool execution was cancelled."), response.rawJSON, file: file, line: line)
        }

        /// The caller's connection is still open: a further request on it is answered.
        private static func assertStillAnswers(
            _ caller: PersistentMCPTestEndpoint,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let listed = try await caller.client.request(method: "tools/list", params: [:])
            XCTAssertFalse(listed.rawJSON.isEmpty, file: file, line: line)
        }
    }

    /// One `context_builder` call from a caller connection, running beside the test.
    @MainActor
    private final class ToolCall {
        private(set) var response: PersistentMCPTestRPCResponse?
        private(set) var failure: Error?
        private var task: Task<Void, Never>?

        var hasEnded: Bool {
            response != nil || failure != nil
        }

        init(_ caller: PersistentMCPTestEndpoint, tabID: UUID) {
            task = Task { @MainActor in
                do {
                    self.response = try await caller.callTool(
                        name: MCPWindowToolName.contextBuilder,
                        arguments: ["context_id": tabID.uuidString, "instructions": "Find the entry point"],
                        timeoutSeconds: 120
                    )
                } catch {
                    self.failure = error
                }
            }
        }

        /// Stops waiting for an answer that will not come.
        func abandon() {
            task?.cancel()
        }

        func join() async {
            await task?.value
        }
    }

    /// An ordinary close of a window, running beside the test.
    @MainActor
    private final class WindowClose {
        private(set) var hasReturned = false

        init(_ window: WindowState) {
            Task { @MainActor in
                window.beginClose()
                await window.tearDown()
                self.hasReturned = true
            }
        }
    }

    /// Counts the times a tab became the tab of a registered run.
    @MainActor
    private final class RegistrationRecorder {
        private(set) var count = 0
        private var subscription: AnyCancellable?

        init(_ viewModel: ContextBuilderAgentViewModel, tabID: UUID) {
            subscription = viewModel.$tabsWithActiveContextBuilderRun
                .filter { $0.contains(tabID) }
                .sink { [weak self] _ in self?.count += 1 }
        }

        func stop() {
            subscription?.cancel()
        }
    }

    /// A step of an admitted call that a test holds open. It records when the task waiting in it
    /// is cancelled, which is how the call is told to stop. Unless it `ignoresCancellation` it
    /// ends at that moment, as the read-file auto-selection drain does; otherwise it stays held
    /// until the test opens it, as provider validation and a stage-progress send do.
    private final class HeldStep: @unchecked Sendable {
        private let lock = NSLock()
        private let ignoresCancellation: Bool
        private var entries = 0
        private var toldToStop = false
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(ignoresCancellation: Bool) {
            self.ignoresCancellation = ignoresCancellation
        }

        var entryCount: Int {
            lock.withLock { entries }
        }

        var wasToldToStop: Bool {
            lock.withLock { toldToStop }
        }

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let endsNow = lock.withLock { () -> Bool in
                        entries += 1
                        if Task.isCancelled {
                            toldToStop = true
                        }
                        if isOpen || (toldToStop && !ignoresCancellation) {
                            return true
                        }
                        waiters.append(continuation)
                        return false
                    }
                    if endsNow {
                        continuation.resume()
                    }
                }
            } onCancel: {
                let ended = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    toldToStop = true
                    guard !ignoresCancellation else { return [] }
                    defer { waiters.removeAll() }
                    return waiters
                }
                ended.forEach { $0.resume() }
            }
        }

        func open() {
            let ended = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            ended.forEach { $0.resume() }
        }
    }
#endif
