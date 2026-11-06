import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

#if DEBUG
    /// A Codex thread binding must name a thread before anything treats the session as started.
    /// The controller rejects a `thread/start` or `thread/resume` response without a thread ID
    /// before applying thread state, draining events buffered while binding, or becoming active;
    /// the coordinator then fails the start at its thread-identity phase without a first dispatch.
    /// A saved rollout path without a thread ID fails as a resume with no fresh-start fallback, and a
    /// session with no saved thread identity starts fresh.
    @MainActor
    final class CodexThreadBindingReadinessTests: XCTestCase {
        private var storageRoot: URL!

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexThreadBindingReadinessTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        // MARK: - Controller

        func testBindingResponsesWithoutAThreadIDAreRejectedBeforeThreadStateIsApplied() async throws {
            let invalidResponses: [(label: String, thread: [String: Any])] = [
                ("missing", ["path": "/tmp/rollout.jsonl"]),
                ("null", ["id": NSNull()]),
                ("empty", ["id": ""]),
                ("whitespace-only", ["id": " \n\t "]),
                ("numeric", ["id": 123]),
                // A thread's own ID is required; a nested turn ID must not stand in for it.
                ("nested turn ID only", ["turns": [["id": "turn-1", "status": "completed"]]])
            ]
            for request in [CodexSessionControllerError.ThreadBindingRequest.start, .resume] {
                for response in invalidResponses {
                    let context = "\(request.rawValue) with a \(response.label) thread ID"
                    let controller = makeController()
                    try await controller.test_beginBindingSession()
                    await controller.test_bufferNotificationDuringBinding(bufferedNotification)

                    do {
                        _ = try await controller.test_completeThreadBinding(
                            response: ["thread": response.thread],
                            request: request,
                            fallbackEffort: nil
                        )
                        XCTFail("\(context) was accepted")
                    } catch {
                        XCTAssertEqual(
                            error as? CodexSessionControllerError,
                            .threadBindingResponseMissingThreadID(request),
                            context
                        )
                    }

                    XCTAssertFalse(controller.hasActiveThread, context)
                    XCTAssertNil(controller.currentSessionReference, "\(context) applied thread state")
                    let bufferState = try await controller.test_bindingBufferState()
                    XCTAssertTrue(bufferState.isBinding, "\(context) finished the binding")
                    XCTAssertEqual(bufferState.bufferedCount, 1, "\(context) drained the buffered events")

                    // The controller never became active: the same binding still completes once a
                    // valid response arrives, which it could not after a successful start.
                    let sessionRef = try await controller.test_completeThreadBinding(
                        response: ["thread": ["id": "thread-1"]],
                        request: request,
                        fallbackEffort: nil
                    )
                    XCTAssertEqual(sessionRef.conversationID, "thread-1", context)
                }
            }
        }

        func testValidBindingNormalizesTheThreadIDAndDrainsBufferedEvents() async throws {
            let controller = makeController()
            try await controller.test_beginBindingSession()
            await controller.test_bufferNotificationDuringBinding(bufferedNotification)

            let sessionRef = try await controller.test_completeThreadBinding(
                response: ["thread": ["threadId": "  thread-7\n", "path": "/tmp/rollout-7.jsonl"]],
                request: .start,
                fallbackEffort: "medium"
            )

            XCTAssertEqual(sessionRef.conversationID, "thread-7")
            XCTAssertEqual(sessionRef.rolloutPath, "/tmp/rollout-7.jsonl")
            XCTAssertTrue(controller.hasActiveThread)
            XCTAssertEqual(controller.currentSessionReference?.conversationID, "thread-7")
            let bufferState = try await controller.test_bindingBufferState()
            XCTAssertFalse(bufferState.isBinding)
            XCTAssertEqual(bufferState.bufferedCount, 0)
        }

        /// The rejection runs through `startOrResume` itself: a real thread request whose response
        /// names no thread cancels the binding, discards the events buffered during it, clears the
        /// expected-PID registration, and leaves the controller able to start again.
        func testRequestBackedBindingFailureCleansUpAndAllowsARetry() async throws {
            let registrations = PIDRegistrationRecorder()
            let client = CodexAppServerClient(
                livenessProbe: { _ in true },
                // A real app-server must never be spawned; the installed test transport stands in.
                processSpawnPreparation: { throw RealAppServerSpawnAttempted() },
                runtimeStatePreparer: { _ in },
                expectedAgentPIDRegistrar: .init(
                    register: { pid, _, _ in registrations.record("register \(pid)") },
                    clear: { pid, _, _ in registrations.record("clear \(pid)") }
                )
            )
            var options = CodexNativeSessionController.Options.agentModeDefault(goalSupportEnabledProvider: { false })
            options.repoPromptMCPProvisioner = { _ in }
            // The launch policy startup applies, applied first: a policy change would otherwise
            // terminate the test transport.
            await client.updateProcessLaunchPolicy(
                featurePolicy: .resolved(goalsEnabled: false, memoriesEnabled: false, computerUseEnabled: false, capabilities: .disabled),
                modelReasoningSummary: options.processModelReasoningSummary
            )
            await client.debugInstallPreparedRuntime(CodexRuntimeAuthority.Runtime(
                executableURL: storageRoot.appendingPathComponent("codex"),
                version: .init(major: 0, minor: 149, patch: 0),
                source: .externalOverride,
                statePaths: .init(
                    codexHome: storageRoot.appendingPathComponent("codex-home"),
                    sqliteHome: storageRoot.appendingPathComponent("codex-sqlite")
                )
            ))
            await client.debugInstallTestTransport()
            let transportGeneration = await client.debugTransportGeneration()

            let requests = ThreadRequestScript(responses: [
                ["thread": ["path": "/tmp/rollout.jsonl"]],
                ["thread": ["id": "thread-2"]]
            ])
            let controllerBox = ControllerBox()
            let controller = CodexNativeSessionController(
                client: client,
                runID: UUID(),
                tabID: UUID(),
                windowID: 1,
                workspacePaths: .uniform(storageRoot.path),
                options: options,
                expectedMCPClientName: "RepoPromptCE",
                requestExecutor: { method, _, _ in
                    guard method == "thread/start" else { return [:] }
                    let response = requests.next()
                    if requests.count == 1, let controller = controllerBox.controller {
                        // An inbound notification arrives while the binding is in flight.
                        await client.debugIngestRawStdoutLine(Data(#"{"method":"test/bufferedDuringBinding","params":{}}"#.utf8))
                        let deadline = Date().addingTimeInterval(5)
                        while Date() < deadline {
                            if try await controller.test_bindingBufferState().bufferedCount == 1 {
                                requests.markBufferedEventObserved()
                                break
                            }
                            try await Task.sleep(nanoseconds: 2_000_000)
                        }
                    }
                    return response
                }
            )
            controllerBox.controller = controller
            let shutDown = {
                await startupTestAwaitBounded("the controller did not shut down") { await controller.shutdown() }
                await startupTestAwaitBounded("the client did not stop") { await client.stop() }
            }
            addTeardownBlock { @MainActor in await shutDown() }

            switch try await boundedStart(controller) {
            case .success:
                XCTFail("a thread/start response without a thread ID started the controller")
            case let .failure(error):
                XCTAssertEqual(error as? CodexSessionControllerError, .threadBindingResponseMissingThreadID(.start))
            }
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(requests.observedBufferedEvent, "no event was buffered while the binding was in flight")
            XCTAssertFalse(controller.hasActiveThread)
            XCTAssertNil(controller.currentSessionReference)
            let bufferState = try await controller.test_bindingBufferState()
            XCTAssertFalse(bufferState.isBinding, "the failed binding was not cancelled")
            XCTAssertEqual(bufferState.bufferedCount, 0, "the failed binding kept its buffered events")
            XCTAssertEqual(registrations.events, ["register \(pid_t.max)", "clear \(pid_t.max)"])

            // The lifecycle went back to fresh, so the same controller starts again.
            let sessionRef = try await boundedStart(controller).get()
            XCTAssertEqual(sessionRef.conversationID, "thread-2")
            XCTAssertTrue(controller.hasActiveThread)
            XCTAssertEqual(registrations.events, ["register \(pid_t.max)", "clear \(pid_t.max)", "register \(pid_t.max)"])
            let generationAfterStarts = await client.debugTransportGeneration()
            XCTAssertEqual(generationAfterStarts, transportGeneration, "startup replaced the test transport")
            await shutDown()
        }

        /// Runs a fresh start as a joined task, so a start that never returns fails the test.
        private func boundedStart(
            _ controller: CodexNativeSessionController,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> Result<CodexNativeSessionController.SessionRef, Error> {
            let start = Task { @MainActor () -> Result<CodexNativeSessionController.SessionRef, Error> in
                do {
                    return try await .success(controller.startOrResume(existing: nil, baseInstructions: ""))
                } catch {
                    return .failure(error)
                }
            }
            try await startupTestJoin(start, file: file, line: line)
            return await start.value
        }

        func testSavedThreadWithoutAnIDIsRejectedBeforeTheControllerStarts() async {
            let controller = makeController()
            do {
                _ = try await controller.startOrResume(
                    existing: .init(conversationID: "  ", rolloutPath: "/tmp/rollout.jsonl", model: nil, reasoningEffort: nil),
                    baseInstructions: ""
                )
                XCTFail("a saved thread without an ID was resumed")
            } catch {
                XCTAssertEqual(error as? CodexSessionControllerError, .invalidResumeReferenceMissingThreadID)
            }
            XCTAssertFalse(controller.hasActiveThread)
            XCTAssertNil(controller.currentSessionReference)
        }

        // MARK: - Coordinator

        func testStartWhoseBindingNamedNoThreadFailsAtThreadIdentityBeforeDispatch() async throws {
            let fixture = makeFixture()
            fixture.controller.startupError = CodexSessionControllerError.threadBindingResponseMissingThreadID(.start)

            let ticket = try fixture.submit("first")
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(fixture.controller.startOrResumeTargets, [nil])
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.errorTexts, [
                "Codex startup failed during thread binding: the thread/start response named no thread."
            ])
            XCTAssertEqual(ticket.phase, .rejected)
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.terminalState, .failed)
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.failureReason, .agentError)
            XCTAssertNil(fixture.session.codexController, "the controller that produced the response was kept")
            XCTAssertNil(fixture.session.codexConversationID, "an unnamed thread was persisted")
            XCTAssertNil(fixture.session.providerCleanupHandle)
            XCTAssertTrue(fixture.session.codexNeedsReconnect)
        }

        func testResumeWhoseBindingNamedNoThreadKeepsTheSavedThread() async throws {
            let fixture = makeFixture()
            startupTestInstallSavedCodexHistory(on: fixture.session, conversationID: "saved-thread", rolloutPath: nil)
            fixture.controller.startupError = CodexSessionControllerError.threadBindingResponseMissingThreadID(.resume)

            let ticket = try fixture.submit("next")
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(fixture.controller.startOrResumeTargets.map { $0?.conversationID }, ["saved-thread"])
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.errorTexts, [
                "Codex startup failed during thread binding: the thread/resume response named no thread."
            ])
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertNil(fixture.session.codexController, "the controller that produced the response was kept")
            XCTAssertEqual(fixture.session.codexConversationID, "saved-thread", "the saved thread was overwritten")
        }

        /// A start whose controller was replaced while it was suspended fails on behalf of nobody:
        /// it reports superseded and neither retires nor marks for reconnect the replacement.
        func testBindingFailureOfAReplacedControllerLeavesTheReplacementAlone() async {
            let fixture = makeFixture(gatesStartup: true)
            let original = fixture.controller
            let startup = Task { await fixture.viewModel.test_codexCoordinator.ensureCodexNativeSession(session: fixture.session) }
            fixture.cleanup.join(startup)
            let startupBegan = await startupTestWaitBounded { original.isStartupWaiting }
            XCTAssertTrue(startupBegan, "the original start never began")

            let replacement = StartupTestCodexController(gatesStartup: false)
            fixture.session.codexController = replacement
            XCTAssertFalse(fixture.session.codexNeedsReconnect)
            original.startupError = CodexSessionControllerError.threadBindingResponseMissingThreadID(.start)
            original.releaseStartup()
            guard await startupTestJoinBounded(startup, "the original start did not finish") else { return }

            XCTAssertTrue(fixture.session.codexController === replacement, "the replacement was retired")
            XCTAssertFalse(fixture.session.codexNeedsReconnect, "the replacement was marked for reconnect")
            XCTAssertEqual(fixture.errorTexts, [])
            let outcome = await startup.value
            guard case .superseded = outcome else {
                return XCTFail("the replaced controller's failure was reported as \(outcome)")
            }
        }

        /// A start whose managed-auth refresh was still running when its controller was replaced
        /// reports superseded; neither refresh outcome reconnects or retires the replacement.
        func testManagedAuthRefreshAfterTheControllerWasReplacedLeavesTheReplacementAlone() async {
            let outcomes: [CodexManagedAuthRefreshResult] = [
                .recovered(account: nil),
                .requiresUserLogin(message: "Sign in to Codex again.")
            ]
            for refreshOutcome in outcomes {
                let context = "refresh \(refreshOutcome)"
                let authRecovery = GatedAuthRecovery(result: refreshOutcome)
                let fixture = makeFixture(authRecovery: authRecovery)
                let original = fixture.controller
                original.startupError = NSError(
                    domain: "CodexThreadBindingReadinessTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "external auth is active"]
                )
                // Auth recovery runs only for an active run.
                fixture.session.runState = .running
                let startup = Task { await fixture.viewModel.test_codexCoordinator.ensureCodexNativeSession(session: fixture.session) }
                fixture.cleanup.join(startup)
                fixture.cleanup.heldGates.append(authRecovery.gate)
                let refreshBegan = await startupTestWaitBounded { authRecovery.gate.isWaiting }
                XCTAssertTrue(refreshBegan, "\(context) never began")

                let replacement = StartupTestCodexController(gatesStartup: false)
                fixture.session.codexController = replacement
                XCTAssertFalse(fixture.session.codexNeedsReconnect, context)
                authRecovery.gate.release()
                guard await startupTestJoinBounded(startup, "\(context): the original start did not finish") else { return }

                XCTAssertTrue(fixture.session.codexController === replacement, "\(context) retired the replacement")
                XCTAssertFalse(fixture.session.codexNeedsReconnect, "\(context) marked the replacement for reconnect")
                XCTAssertEqual(original.startOrResumeCount, 1, "\(context) started a recovered controller")
                let outcome = await startup.value
                if case .superseded = outcome {} else {
                    XCTFail("\(context): the replaced controller's failure was reported as \(outcome)")
                }
                fixture.session.runState = .idle
                await fixture.tearDown()
            }
        }

        /// History whose saved thread has a rollout path but no ID cannot be resumed; the start fails
        /// as a resume and never falls back to a fresh thread that would replace that history.
        func testPathOnlySavedThreadFailsAsAResumeWithoutAFreshStart() async throws {
            let rolloutPath = "/tmp/saved-rollout.jsonl"
            let fixture = makeFixture()
            startupTestInstallSavedCodexHistory(on: fixture.session, conversationID: nil, rolloutPath: rolloutPath)
            // The real controller's own check decides; a fresh start here would be a fallback.
            let realController = makeController()
            fixture.controller.startupHook = { target in
                guard let target else { throw FreshStartAttempted() }
                _ = try await realController.startOrResume(existing: target, baseInstructions: "")
            }

            let ticket = try fixture.submit("next")
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(
                fixture.controller.startOrResumeTargets,
                [.init(conversationID: "", rolloutPath: rolloutPath, model: nil, reasoningEffort: nil)]
            )
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.errorTexts, ["Codex native resume failed: the saved thread ID is missing."])
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.terminalState, .failed)
            XCTAssertEqual(fixture.session.codexRolloutPath, rolloutPath)
            XCTAssertFalse(
                fixture.session.items.contains { $0.kind == .system },
                "a path-only saved thread announced a fresh-thread recovery"
            )
        }

        /// A first start that fails before Codex names a thread leaves no saved identity and a
        /// reconnect request. The next submission starts a fresh thread instead of resuming an
        /// empty thread ID.
        func testFailedFirstStartWithoutIdentityAllowsALaterFreshSend() async throws {
            let fixture = makeFixture()
            // The real controller's own check decides any resume; the recording controller answers
            // fresh starts.
            let realController = makeController()
            fixture.controller.startupHook = { target in
                guard let target else { return }
                _ = try await realController.startOrResume(existing: target, baseInstructions: "")
            }
            fixture.controller.startupError = NSError(
                domain: "CodexThreadBindingReadinessTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "the app-server exited before the thread started"]
            )
            let first = try fixture.submit("first")
            try await startupTestJoin(first.task)
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertNil(fixture.session.codexConversationID)
            XCTAssertNil(fixture.session.codexRolloutPath)
            XCTAssertTrue(fixture.session.codexNeedsReconnect, "the failed first start did not request a reconnect")

            fixture.controller.startupError = nil
            let second = try fixture.submit("second")
            try await startupTestJoin(second.task)

            XCTAssertEqual(fixture.controller.startOrResumeTargets, [nil, nil])
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["second"])
            XCTAssertEqual(fixture.errorTexts, [
                "Codex native start failed: the app-server exited before the thread started"
            ])
            XCTAssertEqual(fixture.session.codexConversationID, "startup-ticket-test")
            XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .fresh)
            XCTAssertFalse(
                fixture.session.items.contains { $0.kind == .system },
                "the fresh start announced a fresh-thread recovery"
            )
        }

        /// A saved thread stays the resume target while no controller holds an active thread, even
        /// when nothing requested a reconnect.
        func testSavedThreadResumesWithoutActiveControllerWhenReconnectIsFalse() async throws {
            let fixture = makeFixture()
            startupTestInstallSavedCodexHistory(
                on: fixture.session,
                conversationID: "saved-thread",
                rolloutPath: "/tmp/saved-rollout.jsonl"
            )
            fixture.session.codexNeedsReconnect = false
            XCTAssertNil(fixture.session.codexController)

            let ticket = try fixture.submit("next")
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(
                fixture.controller.startOrResumeTargets,
                [.init(conversationID: "saved-thread", rolloutPath: "/tmp/saved-rollout.jsonl", model: nil, reasoningEffort: nil)]
            )
            XCTAssertEqual(fixture.controller.startUserTurnTexts, ["next"])
            XCTAssertEqual(fixture.errorTexts, [])
            XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumed)
        }

        /// A start cancelled while its resume is in flight does not start a fresh thread, even when
        /// the resume then fails with the missing-rollout diagnostic for the saved thread.
        func testCancelledStartupDoesNotRetryMissingRollout() async throws {
            let rolloutPath = "/tmp/saved-rollout.jsonl"
            let fixture = makeFixture(gatesStartup: true)
            startupTestInstallSavedCodexHistory(on: fixture.session, conversationID: "saved-thread", rolloutPath: rolloutPath)
            fixture.controller.startupError = CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: -32600,
                message: "failed to resolve rollout path \(rolloutPath): file does not exist",
                data: nil
            ))

            let ticket = try fixture.submit("cancelled during resume")
            try await startupTestEventually { fixture.controller.isStartupWaiting }
            try await startupTestSettle(on: fixture) { await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID) }
            fixture.controller.releaseStartup()
            try await startupTestJoin(ticket.task)

            XCTAssertEqual(ticket.phase, .cancelled)
            XCTAssertEqual(fixture.controller.startOrResumeCount, 1, "the cancelled resume retried as a fresh start")
            XCTAssertEqual(fixture.controller.startUserTurnTexts, [])
            XCTAssertEqual(fixture.session.codexConversationID, "saved-thread")
            XCTAssertEqual(fixture.session.codexRolloutPath, rolloutPath)
            XCTAssertFalse(
                fixture.session.items.contains { $0.kind == .system },
                "the cancelled start announced a fresh-thread recovery"
            )
        }

        /// A failed resume becomes a fresh start only for Codex's rollout-path diagnostic naming the
        /// saved thread's own rollout, or for the legacy missing-thread messages. Other missing-file
        /// errors, other paths, and other requests keep failing as the resume they are. Hook-trust
        /// restoration of a pre-turn thread applies the same rule.
        func testMissingRolloutFallbackIsNarrow() {
            typealias SessionRef = CodexNativeSessionController.SessionRef
            let savedPath = "/tmp/saved-rollout.jsonl"
            let otherPath = "/tmp/other-rollout.jsonl"
            let saved = SessionRef(conversationID: "saved-thread", rolloutPath: savedPath, model: nil, reasoningEffort: nil)
            let mixedCase = SessionRef(conversationID: "saved-thread", rolloutPath: "/tmp/CaseSensitive.jsonl", model: nil, reasoningEffort: nil)
            let idOnly = SessionRef(conversationID: "saved-thread", rolloutPath: nil, model: nil, reasoningEffort: nil)
            func missing(_ path: String) -> String {
                "failed to resolve rollout path \(path): file does not exist"
            }

            let textCases: [(label: String, ref: SessionRef?, message: String, retries: Bool)] = [
                ("the saved rollout", saved, missing(savedPath), true),
                ("upper case, padding, and a final period", saved, "  FAILED TO RESOLVE ROLLOUT PATH \(savedPath): FILE DOES NOT EXIST.  ", true),
                ("another rollout", saved, missing(otherPath), false),
                ("the saved rollout in its own case", mixedCase, missing("/tmp/CaseSensitive.jsonl"), true),
                ("a path differing only in case", mixedCase, missing("/tmp/casesensitive.jsonl"), false),
                ("any absolute path for an ID-only saved thread", idOnly, missing(otherPath), true),
                ("a relative path for an ID-only saved thread", idOnly, missing("other-rollout.jsonl"), false),
                ("the legacy missing-thread message", saved, "no rollout found for thread id saved-thread", true),
                ("no saved thread", nil, missing(savedPath), false),
                ("a workspace path", saved, "failed to resolve workspace path \(savedPath): file does not exist", false),
                ("another reason", saved, "failed to resolve rollout path \(savedPath): permission denied", false),
                ("a leading word", saved, "warning: \(missing(savedPath))", false),
                ("a trailing explanation", saved, "\(missing(savedPath)); check permissions", false)
            ]
            for testCase in textCases {
                XCTAssertEqual(
                    CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
                        existingRef: testCase.ref,
                        errorDescription: testCase.message
                    ),
                    testCase.retries,
                    "text: \(testCase.label)"
                )
            }

            // A typed request failure is judged by its request, code, and path alone; one that
            // names another path or request is not rescued by the text rules above.
            let typedCases: [(label: String, ref: SessionRef, method: String, code: Int, message: String, retries: Bool)] = [
                ("thread/resume naming the saved rollout", saved, "thread/resume", -32600, missing(savedPath), true),
                ("thread/memoryMode/set naming the saved rollout", saved, "thread/memoryMode/set", -32600, missing(savedPath), true),
                ("thread/resume naming another rollout", saved, "thread/resume", -32600, missing(otherPath), false),
                ("thread/resume naming a path differing only in case", mixedCase, "thread/resume", -32600, missing("/tmp/casesensitive.jsonl"), false),
                ("another request naming the saved rollout", saved, "config/read", -32600, missing(savedPath), false),
                ("thread/resume rejected for its parameters", saved, "thread/resume", -32602, missing(savedPath), false)
            ]
            for testCase in typedCases {
                XCTAssertEqual(
                    CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
                        existingRef: testCase.ref,
                        method: testCase.method,
                        code: testCase.code,
                        message: testCase.message
                    ),
                    testCase.retries,
                    "typed: \(testCase.label)"
                )
            }

            let hookTrustCases: [(label: String, rolloutPath: String?, method: String, code: Int, message: String, startsFresh: Bool)] = [
                ("the saved rollout", savedPath, "thread/resume", -32600, missing(savedPath), true),
                ("another rollout", savedPath, "thread/resume", -32600, missing(otherPath), false),
                ("any absolute path with no saved rollout", nil, "thread/resume", -32600, missing(otherPath), true),
                ("the legacy unknown-thread message", savedPath, "thread/resume", -32600, "thread not found: saved-thread", true),
                ("another request", savedPath, "thread/start", -32600, missing(savedPath), false),
                ("another error code", savedPath, "thread/resume", -32602, missing(savedPath), false)
            ]
            for testCase in hookTrustCases {
                let error = CodexAppServerClient.ClientError.requestFailed(.init(
                    method: testCase.method,
                    code: testCase.code,
                    message: testCase.message,
                    data: nil
                ))
                XCTAssertEqual(
                    CodexNativeSessionController.test_isMissingFreshThreadResumeError(
                        error,
                        threadID: "saved-thread",
                        rolloutPath: testCase.rolloutPath
                    ),
                    testCase.startsFresh,
                    "hook trust: \(testCase.label)"
                )
            }
        }

        // MARK: - Fixture

        private struct FreshStartAttempted: Error {}
        private struct RealAppServerSpawnAttempted: Error {}

        private final class PIDRegistrationRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [String] = []

            func record(_ event: String) {
                lock.withLock { recorded.append(event) }
            }

            var events: [String] {
                lock.withLock { recorded }
            }
        }

        /// Answers each `thread/start` with the next scripted response and records whether the
        /// first request saw an event buffered while it was in flight.
        private final class ThreadRequestScript: @unchecked Sendable {
            private let lock = NSLock()
            private var remaining: [[String: Any]]
            private var served = 0
            private var sawBufferedEvent = false

            init(responses: [[String: Any]]) {
                remaining = responses
            }

            func next() -> [String: Any] {
                lock.withLock {
                    served += 1
                    return remaining.removeFirst()
                }
            }

            func markBufferedEventObserved() {
                lock.withLock { sawBufferedEvent = true }
            }

            var count: Int {
                lock.withLock { served }
            }

            var observedBufferedEvent: Bool {
                lock.withLock { sawBufferedEvent }
            }
        }

        /// Holds each managed-account refresh until the test releases it, then reports `result`.
        private final class GatedAuthRecovery: CodexManagedAuthRecovering, @unchecked Sendable {
            let gate: StartupTestHeldGate
            private let result: CodexManagedAuthRefreshResult

            @MainActor
            init(result: CodexManagedAuthRefreshResult) {
                gate = StartupTestHeldGate()
                self.result = result
            }

            func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
                await gate.wait()
                return result
            }

            func managedAccountSnapshot() async -> CodexManagedAccount? {
                nil
            }

            func startManagedChatgptLogin(
                openURL _: @MainActor @escaping @Sendable (URL) -> Void
            ) async -> CodexManagedChatgptLoginResult {
                .failed(message: "unused")
            }

            func startManagedChatgptDeviceCodeLogin(
                presentDeviceCode _: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
            ) async -> CodexManagedChatgptLoginResult {
                .failed(message: "unused")
            }

            func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
                .signedOut
            }
        }

        private final class ControllerBox: @unchecked Sendable {
            weak var controller: CodexNativeSessionController?
        }

        private var bufferedNotification: CodexAppServerClient.Notification {
            CodexAppServerClient.Notification(method: "test/bufferedDuringBinding", params: [:])
        }

        private func makeController() -> CodexNativeSessionController {
            CodexNativeSessionController(
                client: CodexAppServerClient(),
                runID: UUID(),
                tabID: UUID(),
                windowID: 1,
                workspacePaths: .uniform(storageRoot.path)
            )
        }

        private func makeFixture(
            gatesStartup: Bool = false,
            authRecovery: (any CodexManagedAuthRecovering)? = nil
        ) -> StartupTestSessionFixture {
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: gatesStartup)
            let viewModel = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                testWorkspaceDirectory: storageRoot,
                codexControllerFactory: { _, _, _, _, _, _ in controller },
                mcpServerReadinessRequirement: { try await readiness.require() },
                testCodexManagedAuthRecovery: authRecovery
            )
            let fixture = StartupTestSessionFixture(
                viewModel: viewModel,
                session: startupTestCodexSession(),
                readiness: readiness,
                controller: controller
            )
            addTeardownBlock { @MainActor in await fixture.tearDown() }
            return fixture
        }
    }
#endif
