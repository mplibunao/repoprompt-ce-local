import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

#if DEBUG
    /// Context Builder runs on different compose tabs of one window, routed through production
    /// pending-policy admission, run-to-connection mapping, nested tool calls, and the final-context
    /// commit by ``ContextBuilderRunFixture``.
    @MainActor
    final class ContextBuilderCrossTabConcurrencyTests: XCTestCase {
        /// Start state: the window's MCP tools are disabled and neither tab has a run, so both runs
        /// reach window-tool readiness cold and share one enable transition. The runs enter through
        /// the view model's MCP entry directly; a caller's `context_builder` request reaches that
        /// entry only on a window whose tools are already enabled.
        ///
        /// The run whose pending policy is older is then held before its child connects, so the
        /// other run's child is admitted, mutates its tab, and commits past that older policy.
        func testColdDifferentTabsCompleteWithReversedChildConnections() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let server = fixture.window.mcpServer
                fixture.holdsChildConnections = true

                XCTAssertFalse(server.windowToolsEnabled)
                let enableGeneration = server.windowToolRegistrationIntentGenerationForTesting() + 1
                let registrationGate = ContextBuilderTestGate()
                server.setBeforeWindowToolRegistrationForTesting { await registrationGate.wait() }
                cleanup.add {
                    server.setBeforeWindowToolRegistrationForTesting(nil)
                    await registrationGate.open()
                }

                let runs = fixture.slots.map { fixture.startMCPRun(on: $0) }
                try await fixture.waitFor("both cold starts to share one enable transition") {
                    await registrationGate.entered
                        && server.windowToolTransitionJoinsByGenerationForTesting()[enableGeneration] == 1
                }
                XCTAssertFalse(server.windowToolsEnabled)
                await registrationGate.open()

                try await fixture.waitFor("both providers to register a process before connecting") {
                    fixture.children.count == 2 && fixture.children.allSatisfy { $0.registeredProviderPID != nil }
                }
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), enableGeneration)
                XCTAssertEqual(server.windowToolTransitionStartsByGenerationForTesting()[enableGeneration], 1)

                let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingRunIDs.count, 2)
                let held = try XCTUnwrap(fixture.child(forRunID: pendingRunIDs.first))
                let early = try XCTUnwrap(fixture.children.first { $0 !== held })
                let heldRunID = try XCTUnwrap(held.runID)
                let heldSlot = try fixture.slot(forRunID: heldRunID)
                let earlySlot = try fixture.slot(forRunID: XCTUnwrap(early.runID))
                let heldRun = try XCTUnwrap(runs.first { $0.slot == heldSlot })
                let earlyRun = try XCTUnwrap(runs.first { $0.slot == earlySlot })

                await early.allowConnection()
                let earlyCompletion = try await fixture.completion(of: earlyRun)
                try fixture.assertCommitted(earlyCompletion, by: early)

                // The older policy still waits for its own child: nothing the early run did
                // consumed it, observed it, or reached its tab.
                XCTAssertEqual(fixture.activeRunID(heldSlot), heldRunID)
                XCTAssertNil(held.admission)
                let heldWasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: heldRunID)
                XCTAssertFalse(heldWasObserved)
                let stillPendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(stillPendingRunIDs, [heldRunID])
                XCTAssertEqual(fixture.storedTab(heldSlot)?.promptText, "")
                XCTAssertEqual(fixture.storedTab(heldSlot)?.selection.selectedPaths, [])

                await held.allowConnection()
                let heldCompletion = try await fixture.completion(of: heldRun)
                try fixture.assertCommitted(heldCompletion, by: held)
                fixture.assertStoredTabMatchesSlot(earlySlot)

                try await fixture.waitFor("both runs to finish teardown") {
                    fixture.children.allSatisfy { child in
                        child.disposeCount > 0
                            && child.runID.map { !fixture.viewModel.isRunTeardownPendingForTesting(runID: $0) } == true
                    }
                }
                XCTAssertEqual(fixture.children.map(\.disposeCount), [1, 1])
                let leftoverPendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(leftoverPendingRunIDs, [])
                XCTAssertEqual(fixture.slots.map { fixture.operationToken($0) }, [nil, nil])
            }
        }

        /// Start state: the window's MCP tools are disabled. The first run's start begins the
        /// enable transition and is held at window-tool registration; the second run's start joins
        /// that transition.
        ///
        /// Cancelling the first run while both wait ends that run alone and at once, with the
        /// transition still held. The transition it began is neither cancelled nor replaced, and the
        /// second run goes on through it to a routed, committed discovery.
        func testColdReadinessIsJoinedAndOneCancelledWaiterDoesNotCancelOther() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let server = fixture.window.mcpServer
                let cancelledSlot = fixture.slots[0]
                let survivingSlot = fixture.slots[1]

                XCTAssertFalse(server.windowToolsEnabled)
                let enableGeneration = server.windowToolRegistrationIntentGenerationForTesting() + 1
                let registrationGate = ContextBuilderTestGate()
                server.setBeforeWindowToolRegistrationForTesting { await registrationGate.wait() }
                cleanup.add {
                    server.setBeforeWindowToolRegistrationForTesting(nil)
                    await registrationGate.open()
                }

                let cancelledRun = fixture.startMCPRun(on: cancelledSlot)
                try await fixture.waitFor("the first start to begin the enable transition") {
                    await registrationGate.entered
                }
                let survivingRun = fixture.startMCPRun(on: survivingSlot)
                try await fixture.waitFor("the second start to join that transition") {
                    server.windowToolTransitionJoinsByGenerationForTesting()[enableGeneration] == 1
                }
                let survivingRunID = try XCTUnwrap(fixture.activeRunID(survivingSlot))

                await fixture.viewModel.cancelMCPContextBuilderRun(forTabID: cancelledSlot.tabID)
                try await fixture.waitFor("the cancelled run to return", allowingRunErrors: true) {
                    cancelledRun.result != nil
                }
                XCTAssertThrowsError(try XCTUnwrap(cancelledRun.result).get()) { error in
                    XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
                }
                // The cancelled run left its wait while readiness was still held for the other.
                XCTAssertFalse(server.windowToolsEnabled)
                XCTAssertNil(fixture.operationToken(cancelledSlot))
                XCTAssertEqual(fixture.activeRunID(survivingSlot), survivingRunID)
                XCTAssertNil(survivingRun.result)
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), enableGeneration)

                await registrationGate.open()
                try await fixture.waitFor("the surviving run to return", allowingRunErrors: true) {
                    survivingRun.result != nil
                }
                let completion = try XCTUnwrap(survivingRun.result).get()
                XCTAssertEqual(completion.runID, survivingRunID)
                let child = try XCTUnwrap(fixture.child(forRunID: survivingRunID))
                try fixture.assertCommitted(completion, by: child)

                XCTAssertTrue(server.windowToolsEnabled)
                XCTAssertEqual(server.windowToolRegistrationIntentGenerationForTesting(), enableGeneration)
                XCTAssertEqual(server.windowToolTransitionStartsByGenerationForTesting()[enableGeneration], 1)
                XCTAssertEqual(fixture.providerRequests.count, 1, "The cancelled run must not reach its provider.")
                XCTAssertEqual(fixture.storedTab(cancelledSlot)?.promptText, "")
                let leftoverPendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(leftoverPendingRunIDs, [])
                XCTAssertEqual(fixture.slots.map { fixture.operationToken($0) }, [nil, nil])
            }
        }

        /// Start state: the window's MCP tools are disabled. A UI run on the shown tab and an MCP
        /// run on the background tab, the second admitted with a pin and a provider workspace of
        /// its own, are both stopped at window-tool registration: admitted, with no provider yet.
        ///
        /// What the window offers then changes under both: the workspace's roots, the automatic
        /// follow-up setting, and the active tab. Each provider is still created with what its run
        /// was admitted with. The background run's child then connects and commits first and its
        /// plan follow-up starts, and the shown tab's run commits after it and starts the
        /// follow-up it was started with. With both replies pending, each follow-up has sent its
        /// own tab's prompt and file to a chat of its own tab. The replies complete in the other
        /// order, and each answer, route, and chat stays with its own tab.
        func testConcurrentRunsKeepFrozenInputsAndFollowUps() async throws {
            let pin = ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            )
            try await ContextBuilderRunFixture.withFixture(tabNames: ["shown", "background"]) { fixture, cleanup in
                let viewModel = fixture.viewModel
                let server = fixture.window.mcpServer
                let manager = fixture.window.workspaceManager
                let promptManager = fixture.window.promptManager
                let oracle = fixture.window.oracleViewModel
                let shown = fixture.slots[0]
                let background = fixture.slots[1]
                try await fixture.saveChatsInTemporaryDirectory()
                fixture.enableAutomaticFollowUp(cleanup: cleanup)
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    resolveMCPFollowUpModel: { _ in
                        (model: ContextBuilderRunFixture.followUpModel, chatPresetID: nil, mcpControlInfo: nil)
                    }
                ))

                XCTAssertFalse(server.windowToolsEnabled)
                let registrationGate = ContextBuilderTestGate()
                server.setBeforeWindowToolRegistrationForTesting { await registrationGate.wait() }
                cleanup.add {
                    server.setBeforeWindowToolRegistrationForTesting(nil)
                    await registrationGate.open()
                }
                let backgroundRoot = fixture.rootURL.appendingPathComponent("background-root", isDirectory: true)
                let laterRoot = fixture.rootURL.appendingPathComponent("later-root", isDirectory: true)
                for directory in [backgroundRoot, laterRoot] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }

                fixture.holdsChildConnections = true
                let agentShownAtPress = viewModel.selectedAgent
                let pressed = await fixture.pressRun(on: shown)
                let shownRunID = try XCTUnwrap(pressed)
                let backgroundRun = fixture.startMCPRun(
                    on: background,
                    modelParameterSelections: [pin],
                    providerWorkspacePath: backgroundRoot.path,
                    followUp: .plan
                )
                let backgroundRunID = try await fixture.registeredRunID(on: background)
                try await fixture.waitFor("the runs to reach window-tool registration") {
                    await registrationGate.entered
                }
                XCTAssertEqual(fixture.providerRequests, [])

                // What the window offers changes after both runs were admitted.
                let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspaceID })
                manager.workspaces[workspaceIndex].repoPaths = [laterRoot.path]
                var behavior = GlobalSettingsStore.shared.contextBuilderBehaviorSettings()
                behavior.followUpAnalysisEnabled = false
                GlobalSettingsStore.shared.setContextBuilderBehaviorSettings(behavior, commit: false)
                await promptManager.switchComposeTab(background.tabID)
                XCTAssertEqual(viewModel.currentTabID, background.tabID)

                await registrationGate.open()
                try await fixture.waitFor("both providers to be created") { fixture.providerRequests.count == 2 }
                manager.workspaces[workspaceIndex].repoPaths = [fixture.rootURL.path]
                let shownRequest = try XCTUnwrap(
                    fixture.providerRequests.first { $0.workspacePath == fixture.rootURL.path },
                    "\(fixture.providerRequests)"
                )
                XCTAssertEqual(shownRequest.agentKind, agentShownAtPress)
                XCTAssertNotEqual(shownRequest.modelParameterSelections, [pin])
                XCTAssertEqual(
                    fixture.providerRequests.first { $0.workspacePath == backgroundRoot.path },
                    ContextBuilderRunFixture.ProviderRequest(
                        agentKind: .claudeCode,
                        modelString: nil,
                        workspacePath: backgroundRoot.path,
                        modelParameterSelections: [pin]
                    )
                )
                let shownChild = try await fixture.childWithRegisteredProcess(forRunID: shownRunID)
                let backgroundChild = try await fixture.childWithRegisteredProcess(forRunID: backgroundRunID)

                // The background tab's run commits first and goes on to its follow-up.
                await backgroundChild.allowConnection()
                try await fixture.waitFor("the background tab's follow-up to send its prompt or end") {
                    if await fixture.oracleReplies.requests.isEmpty == false { return true }
                    return backgroundRun.followUpResult != nil
                }
                if let ended = backgroundRun.followUpResult {
                    XCTFail("The background tab's follow-up ended before it sent a prompt: \(ended)")
                    throw ContextBuilderRunFixture.ScenarioAborted()
                }
                let backgroundAsk = try await fixture.oracleRequest(0)
                let backgroundSession = try XCTUnwrap(fixture.session(background))
                XCTAssertTrue(backgroundAsk.userPrompt.contains(background.promptText), backgroundAsk.userPrompt)
                XCTAssertFalse(backgroundAsk.userPrompt.contains(shown.promptText), backgroundAsk.userPrompt)
                fixture.assertStoredTabMatchesSlot(background)
                XCTAssertEqual(backgroundSession.lastAgentOutput, background.agentOutput)
                XCTAssertEqual(fixture.activeRunID(shown), shownRunID, "The shown tab's run still waits for its child.")
                XCTAssertEqual(fixture.storedTab(shown)?.promptText, "")

                // The shown tab's run commits while another tab is active, and starts the
                // follow-up it was started with although the setting has been turned off since.
                // Showing a tab restores its chat's own model, so the model that follow-up sends
                // with is chosen after the last tab change before it starts.
                fixture.useFollowUpModelForUIFollowUps(cleanup: cleanup)
                await shownChild.allowConnection()
                try await fixture.waitFor("the shown tab's follow-up to send its prompt or fail") {
                    if await fixture.oracleReplies.requests.count > 1 { return true }
                    return fixture.session(shown)?.backgroundPlanError != nil
                }
                let shownSession = try XCTUnwrap(fixture.session(shown))
                XCTAssertNil(shownSession.backgroundPlanError)
                let shownAsk = try await fixture.oracleRequest(1)
                XCTAssertTrue(shownAsk.userPrompt.contains(shown.promptText), shownAsk.userPrompt)
                XCTAssertFalse(shownAsk.userPrompt.contains(background.promptText), shownAsk.userPrompt)
                fixture.assertStoredTabMatchesSlot(shown)
                XCTAssertEqual(shownSession.lastAgentOutput, shown.agentOutput)
                XCTAssertEqual(
                    shownChild.admission,
                    Admission(routedRunID: shownRunID, runConnectionID: shownChild.connectionID, boundTabID: shown.tabID)
                )
                XCTAssertEqual(
                    backgroundChild.admission,
                    Admission(
                        routedRunID: backgroundRunID,
                        runConnectionID: backgroundChild.connectionID,
                        boundTabID: background.tabID
                    )
                )

                // Both replies are pending: each follow-up sent its own tab's file to its own chat.
                for (ask, own, other) in [(shownAsk, shown, background), (backgroundAsk, background, shown)] {
                    let files = ask.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(files.contains(own.fileURL.lastPathComponent), "\(own.name): \(files)")
                    XCTAssertFalse(files.contains(other.fileURL.lastPathComponent), "\(own.name): \(files)")
                }
                let shownChatID = try XCTUnwrap(shownSession.followUpOracleSessionID)
                let backgroundChatID = try XCTUnwrap(backgroundSession.followUpOracleSessionID)
                XCTAssertNotEqual(shownChatID, backgroundChatID)
                XCTAssertEqual(oracle.sessions.first { $0.id == shownChatID }?.composeTabID, shown.tabID)
                XCTAssertEqual(oracle.sessions.first { $0.id == backgroundChatID }?.composeTabID, background.tabID)
                XCTAssertNil(backgroundRun.result, "The background tab's call is still generating its follow-up.")

                // The reply to the follow-up that started second completes first.
                await promptManager.switchComposeTab(shown.tabID)
                let shownPlan = "Plan for the shown tab"
                let backgroundPlan = "Plan for the background tab"
                await shownAsk.complete(with: shownPlan)
                try await fixture.waitForRelease(of: shown)
                XCTAssertEqual(shownSession.backgroundPlanResponseText, shownPlan)
                XCTAssertEqual(shownSession.generatedAnswerRoute?.tabID, shown.tabID)
                XCTAssertEqual(manager.activeChatSessionID(forTabID: shown.tabID), shownChatID)
                XCTAssertTrue(backgroundSession.isBackgroundPlanGenerating)
                XCTAssertNil(backgroundSession.backgroundPlanResponseText)
                XCTAssertEqual(fixture.operationToken(background)?.origin, .mcp)
                XCTAssertNil(backgroundRun.result)

                await backgroundAsk.complete(with: backgroundPlan)
                let backgroundCompletion = try await fixture.completion(of: backgroundRun)
                try fixture.assertCommitted(backgroundCompletion, by: backgroundChild)
                let backgroundReply = try XCTUnwrap(backgroundRun.followUpResult).get()
                XCTAssertEqual(backgroundReply.response, backgroundPlan)
                XCTAssertEqual(backgroundReply.chatId, backgroundChatID)
                XCTAssertEqual(backgroundSession.backgroundPlanResponseText, backgroundPlan)
                XCTAssertEqual(
                    backgroundSession.generatedAnswerRoute,
                    ContextBuilderGeneratedAnswerRoute(
                        workspaceID: fixture.workspaceID,
                        tabID: background.tabID,
                        chatID: backgroundReply.shortId
                    )
                )
                XCTAssertEqual(manager.activeChatSessionID(forTabID: background.tabID), backgroundChatID)
                XCTAssertEqual(shownSession.backgroundPlanResponseText, shownPlan)
                XCTAssertNotEqual(shownSession.generatedAnswerRoute?.chatID, backgroundReply.shortId)
                XCTAssertEqual(manager.activeChatSessionID(forTabID: shown.tabID), shownChatID)
                fixture.assertStoredTabMatchesSlot(shown)

                XCTAssertEqual(fixture.providerRequests.count, 2)
                let requestCount = await fixture.oracleReplies.requests.count
                XCTAssertEqual(requestCount, 2)
                XCTAssertEqual(fixture.slots.map { fixture.operationToken($0) }, [nil, nil])
            }
        }

        /// Start state: the shown tab's run and the background tab's run are both routed, and each
        /// child may ask the user questions.
        ///
        /// The shown tab's child asks, and the window shows its question. The background tab's
        /// child then asks through its own connection. That question is held on the background
        /// tab's session for the background tab's run, and the window goes on showing the shown
        /// tab's question. Answering either one answers only the child that asked it.
        func testBackgroundTabsQuestionStaysOnItsSessionAndLeavesShownTabsQuestion() async throws {
            try await ContextBuilderRunFixture.withFixture(tabNames: ["shown", "background"]) { fixture, _ in
                let viewModel = fixture.viewModel
                let shown = fixture.slots[0]
                let background = fixture.slots[1]
                fixture.clarifyingQuestionTimeoutSeconds = 300
                fixture.holdsChildTurns = true

                let shownRun = fixture.startMCPRun(on: shown)
                let backgroundRun = fixture.startMCPRun(on: background)
                let shownRunID = try await fixture.registeredRunID(on: shown)
                let backgroundRunID = try await fixture.registeredRunID(on: background)
                let shownChild = try await fixture.childWithRegisteredProcess(forRunID: shownRunID)
                let backgroundChild = try await fixture.childWithRegisteredProcess(forRunID: backgroundRunID)
                try await fixture.waitFor("both children to hold their turns") {
                    guard await shownChild.isTurnHeld() else { return false }
                    return await backgroundChild.isTurnHeld()
                }
                XCTAssertEqual(viewModel.currentTabID, shown.tabID)

                let shownAsk = Task {
                    try await shownChild.callTool(
                        MCPWindowToolName.askUser,
                        ["question": "Which module does the shown tab mean?", "timeout_seconds": 300]
                    )
                }
                try await fixture.waitFor("the shown tab's question to be pending") {
                    fixture.session(shown)?.pendingAskUser != nil
                }
                let shownQuestion = try XCTUnwrap(fixture.session(shown)?.pendingAskUser?.interaction)
                XCTAssertEqual(viewModel.pendingAskUser?.interaction.id, shownQuestion.id)

                let backgroundAsk = Task {
                    try await backgroundChild.callTool(
                        MCPWindowToolName.askUser,
                        ["question": "Which module does the background tab mean?", "timeout_seconds": 300]
                    )
                }
                try await fixture.waitFor("the background tab's question to be pending") {
                    fixture.session(background)?.pendingAskUser != nil
                }
                let backgroundQuestion = try XCTUnwrap(fixture.session(background)?.pendingAskUser?.interaction)
                XCTAssertNotEqual(backgroundQuestion.id, shownQuestion.id)
                XCTAssertEqual(backgroundQuestion.questions.map(\.question), ["Which module does the background tab mean?"])
                XCTAssertEqual(fixture.session(background)?.pendingAskUserRunID, backgroundRunID)
                XCTAssertEqual(fixture.session(shown)?.pendingAskUser?.interaction.id, shownQuestion.id)
                XCTAssertEqual(fixture.session(shown)?.pendingAskUserRunID, shownRunID)
                XCTAssertEqual(viewModel.currentTabID, shown.tabID)
                XCTAssertEqual(
                    viewModel.pendingAskUser?.interaction.id,
                    shownQuestion.id,
                    "The window still shows the shown tab's question."
                )

                viewModel.submitQuestionResponse(
                    tabID: background.tabID,
                    interactionID: backgroundQuestion.id,
                    response: "Answer for the background tab"
                )
                let backgroundAnswer = try await backgroundAsk.value
                XCTAssertTrue(backgroundAnswer.rawJSON.contains("Answer for the background tab"), backgroundAnswer.rawJSON)
                XCTAssertNil(fixture.session(background)?.pendingAskUser)
                XCTAssertEqual(fixture.session(shown)?.pendingAskUser?.interaction.id, shownQuestion.id)
                XCTAssertEqual(viewModel.pendingAskUser?.interaction.id, shownQuestion.id)

                viewModel.submitQuestionResponse(
                    tabID: shown.tabID,
                    interactionID: shownQuestion.id,
                    response: "Answer for the shown tab"
                )
                let shownAnswer = try await shownAsk.value
                XCTAssertTrue(shownAnswer.rawJSON.contains("Answer for the shown tab"), shownAnswer.rawJSON)
                XCTAssertFalse(shownAnswer.rawJSON.contains("Answer for the background tab"), shownAnswer.rawJSON)
                XCTAssertNil(fixture.session(shown)?.pendingAskUser)
                XCTAssertNil(viewModel.pendingAskUser)

                await backgroundChild.allowTurn()
                let backgroundCompletion = try await fixture.completion(of: backgroundRun)
                try fixture.assertCommitted(backgroundCompletion, by: backgroundChild)
                await shownChild.allowTurn()
                let shownCompletion = try await fixture.completion(of: shownRun)
                try fixture.assertCommitted(shownCompletion, by: shownChild)
            }
        }

        /// Start state: three tabs with a run each, every child routed through production
        /// admission. The shown tab's UI run is routed and held before its reply is processed. The
        /// waiting tab's MCP run still waits for its child on the oldest pending policy. The ending
        /// tab's MCP run is routed and has worked on its tab.
        ///
        /// The ending tab's run then ends: cancelled by its caller in one case, failed by its
        /// provider in the other. Neither end reaches the other two runs. Each keeps its run, its
        /// claim, its session, and its route or pending policy, the window goes on mirroring the
        /// shown tab's run, and both commit their own tabs afterwards. The ended run reports no
        /// commit, and its tab is as it left it once the other two have committed.
        func testCancellationAndFailureDoNotRetireOtherTab() async throws {
            for ending in RunEnding.allCases {
                try await ContextBuilderRunFixture.withFixture(
                    tabNames: ["shown", "waiting", "ending"]
                ) { fixture, cleanup in
                    let viewModel = fixture.viewModel
                    let shown = fixture.slots[0]
                    let waiting = fixture.slots[1]
                    let endingSlot = fixture.slots[2]
                    fixture.holdsChildConnections = true

                    let waitingRun = fixture.startMCPRun(on: waiting)
                    let waitingRunID = try await fixture.registeredRunID(on: waiting)
                    let waitingChild = try await fixture.childWithRegisteredProcess(forRunID: waitingRunID)
                    let pressed = await fixture.pressRun(on: shown)
                    let shownRunID = try XCTUnwrap(pressed)
                    let shownChild = try await fixture.childWithRegisteredProcess(forRunID: shownRunID)
                    if ending == .providerFailure {
                        fixture.childWrites = .init(failsAfterToolCalls: true)
                    }
                    let endingRun = fixture.startMCPRun(on: endingSlot)
                    let endingRunID = try await fixture.registeredRunID(on: endingSlot)
                    let endingChild = try await fixture.childWithRegisteredProcess(forRunID: endingRunID)

                    let shownTurn = ContextBuilderCancellableTestGate()
                    let endingTurn = ContextBuilderCancellableTestGate()
                    var tornDownRunIDs: Set<UUID> = []
                    cleanup.add { viewModel.installRunTestHooks(nil) }
                    fixture.releaseOnSettle {
                        shownTurn.open()
                        endingTurn.open()
                    }
                    viewModel.installRunTestHooks(.init(
                        beforeProcessingProviderEvent: { _, runID in
                            if runID == shownRunID {
                                try? await shownTurn.wait()
                            } else if runID == endingRunID {
                                try? await endingTurn.wait()
                            }
                        },
                        providerEventDisposition: nil,
                        teardownCompleted: { tornDownRunIDs.insert($0) }
                    ))

                    await shownChild.allowConnection()
                    try await fixture.waitFor("the shown tab's run to be held before its reply is processed") {
                        shownTurn.entryCount == 1
                    }
                    let shownBefore = await SurvivingRun(shownRunID, on: shown, child: shownChild, in: fixture)
                    let waitingBefore = await SurvivingRun(waitingRunID, on: waiting, child: waitingChild, in: fixture)
                    XCTAssertEqual(
                        shownBefore.route,
                        Admission(routedRunID: shownRunID, runConnectionID: shownChild.connectionID, boundTabID: shown.tabID)
                    )
                    XCTAssertEqual(shownBefore.operationToken?.origin, .ui)
                    XCTAssertEqual(waitingBefore.route, Admission(routedRunID: nil, runConnectionID: nil, boundTabID: nil))
                    XCTAssertTrue(waitingBefore.hasPendingPolicy)
                    XCTAssertEqual(waitingBefore.operationToken?.origin, .mcp)
                    XCTAssertEqual(viewModel.agentRunState, .running(shownRunID))

                    await endingChild.allowConnection()
                    if ending == .callerCancellation {
                        try await fixture.waitFor("the ending tab's run to be held before its reply is processed") {
                            endingTurn.entryCount == 1
                        }
                        await viewModel.cancelMCPContextBuilderRun(forTabID: endingSlot.tabID)
                    }
                    try await fixture.waitFor("the ending tab's run to return", allowingRunErrors: true) {
                        endingRun.result != nil
                    }
                    XCTAssertEqual(
                        endingChild.admission,
                        Admission(
                            routedRunID: endingRunID,
                            runConnectionID: endingChild.connectionID,
                            boundTabID: endingSlot.tabID
                        ),
                        "The run that ended was routed and bound to its tab."
                    )
                    let endedLogMessage: String
                    switch ending {
                    case .callerCancellation:
                        XCTAssertThrowsError(try XCTUnwrap(endingRun.result).get()) { error in
                            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
                        }
                        endedLogMessage = "Cancelled by user"
                    case .providerFailure:
                        let completion = try XCTUnwrap(endingRun.result).get()
                        guard case let .failed(message) = completion.terminalDisposition else {
                            return XCTFail("Expected the run to fail with its provider's error, got \(completion.terminalDisposition)")
                        }
                        endedLogMessage = try XCTUnwrap(ContextBuilderProviderChild.ConnectionError.turnFailed.errorDescription)
                        XCTAssertTrue(message.contains(endedLogMessage), message)
                        XCTAssertNil(completion.committedTab)
                    }
                    try await fixture.waitFor("the ended run to finish teardown", allowingRunErrors: true) {
                        tornDownRunIDs.contains(endingRunID)
                    }
                    let endedLog = fixture.session(endingSlot)?.agentLog.map(\.message) ?? []
                    XCTAssertTrue(endedLog.contains { $0.contains(endedLogMessage) }, "\(endedLog)")
                    XCTAssertEqual(endingChild.disposeCount, 1)
                    XCTAssertNil(fixture.operationToken(endingSlot))
                    XCTAssertNil(fixture.activeRunID(endingSlot))
                    XCTAssertNil(fixture.window.mcpServer.connectionID(forRunID: endingRunID))
                    let endedRouteRunID = await fixture.manager.runIDForConnection(endingChild.connectionID)
                    XCTAssertNil(endedRouteRunID)
                    let endedTab = fixture.storedTab(endingSlot)

                    let shownAfter = await SurvivingRun(shownRunID, on: shown, child: shownChild, in: fixture)
                    let waitingAfter = await SurvivingRun(waitingRunID, on: waiting, child: waitingChild, in: fixture)
                    XCTAssertEqual(shownAfter, shownBefore)
                    XCTAssertEqual(waitingAfter, waitingBefore)
                    XCTAssertNil(waitingRun.result)
                    let waitingWasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: waitingRunID)
                    XCTAssertFalse(waitingWasObserved)
                    XCTAssertEqual(viewModel.agentRunState, .running(shownRunID), "The window still mirrors the shown tab's run.")
                    XCTAssertTrue(viewModel.isAgentBusy)
                    for survivor in [shown, waiting] {
                        let log = fixture.session(survivor)?.agentLog.map(\.message) ?? []
                        XCTAssertFalse(log.contains { $0.contains(endedLogMessage) }, "\(survivor.name): \(log)")
                    }
                    XCTAssertFalse(viewModel.agentLog.contains { $0.message.contains(endedLogMessage) })

                    shownTurn.open()
                    try await fixture.waitForRelease(of: shown)
                    XCTAssertEqual(fixture.session(shown)?.agentRunState, .completed)
                    fixture.assertStoredTabMatchesSlot(shown)

                    await waitingChild.allowConnection()
                    try await fixture.waitFor("the waiting tab's run to return", allowingRunErrors: true) {
                        waitingRun.result != nil
                    }
                    try fixture.assertCommitted(XCTUnwrap(waitingRun.result).get(), by: waitingChild)

                    XCTAssertEqual(fixture.storedTab(endingSlot)?.promptText, endedTab?.promptText)
                    XCTAssertEqual(fixture.storedTab(endingSlot)?.selection, endedTab?.selection)
                    XCTAssertEqual(fixture.slots.map { fixture.operationToken($0) }, [nil, nil, nil])
                }
            }
        }

        /// Start state: the first tab's run has completed and committed, and its provider's
        /// disposal is still held, so the teardown of its record is unfinished. A successor run on
        /// the first tab and a run on the second tab have both started since, and each waits for
        /// its child on its own pending policy.
        ///
        /// The held disposal is then let go and the finished run's teardown completes. It takes
        /// nothing from the two later runs: their pending policies, claims, sessions, and run state
        /// are as they were, the first tab still holds what the finished run committed, and both
        /// later runs go on to commit through their own children.
        func testLateTeardownCannotAffectOtherTabOrSuccessor() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let first = fixture.slots[0]
                let second = fixture.slots[1]
                var tornDownRunIDs: Set<UUID> = []
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: { tornDownRunIDs.insert($0) }
                ))

                fixture.holdsChildDisposal = true
                let finishedRun = fixture.startMCPRun(on: first)
                let finishedCompletion = try await fixture.completion(of: finishedRun)
                fixture.holdsChildDisposal = false
                let finishedRunID = finishedCompletion.runID
                let finishedChild = try XCTUnwrap(fixture.child(forRunID: finishedRunID))
                try fixture.assertCommitted(finishedCompletion, by: finishedChild)
                try await fixture.waitFor("the finished run's provider disposal to be held") {
                    await finishedChild.isDisposalHeld()
                }
                XCTAssertTrue(viewModel.isRunTeardownPendingForTesting(runID: finishedRunID))
                XCTAssertNil(fixture.operationToken(first))

                fixture.holdsChildConnections = true
                let successorRun = fixture.startMCPRun(on: first)
                let successorRunID = try await fixture.registeredRunID(on: first)
                let successorChild = try await fixture.childWithRegisteredProcess(forRunID: successorRunID)
                let otherRun = fixture.startMCPRun(on: second)
                let otherRunID = try await fixture.registeredRunID(on: second)
                let otherChild = try await fixture.childWithRegisteredProcess(forRunID: otherRunID)
                XCTAssertNotEqual(successorRunID, finishedRunID)
                let pendingBefore = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingBefore, [successorRunID, otherRunID])
                let successorBefore = await SurvivingRun(successorRunID, on: first, child: successorChild, in: fixture)
                let otherBefore = await SurvivingRun(otherRunID, on: second, child: otherChild, in: fixture)
                XCTAssertEqual(successorBefore.runState, .running(successorRunID))
                XCTAssertEqual(successorBefore.storedPrompt, first.promptText, "The first tab holds the finished run's commit.")
                XCTAssertFalse(tornDownRunIDs.contains(finishedRunID))

                await finishedChild.allowDisposal()
                try await fixture.waitFor("the finished run's teardown to complete") {
                    tornDownRunIDs.contains(finishedRunID)
                }
                XCTAssertEqual(finishedChild.disposeCount, 1)
                XCTAssertTrue(finishedChild.hasFinishedDisposal)
                XCTAssertFalse(viewModel.isRunTeardownPendingForTesting(runID: finishedRunID))

                let successorAfter = await SurvivingRun(successorRunID, on: first, child: successorChild, in: fixture)
                let otherAfter = await SurvivingRun(otherRunID, on: second, child: otherChild, in: fixture)
                XCTAssertEqual(successorAfter, successorBefore)
                XCTAssertEqual(otherAfter, otherBefore)
                let pendingAfter = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingAfter, [successorRunID, otherRunID])
                XCTAssertNil(successorRun.result)
                XCTAssertNil(otherRun.result)

                await otherChild.allowConnection()
                let otherCompletion = try await fixture.completion(of: otherRun)
                try fixture.assertCommitted(otherCompletion, by: otherChild)
                await successorChild.allowConnection()
                let successorCompletion = try await fixture.completion(of: successorRun)
                try fixture.assertCommitted(successorCompletion, by: successorChild)

                try await fixture.waitFor("the two later runs to finish teardown") {
                    tornDownRunIDs.isSuperset(of: [successorRunID, otherRunID])
                }
                XCTAssertEqual(fixture.children.map(\.disposeCount), [1, 1, 1])
                let leftoverPendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(leftoverPendingRunIDs, [])
                XCTAssertEqual(fixture.slots.map { fixture.operationToken($0) }, [nil, nil])
            }
        }

        /// Start state: the second tab's run has written its tab and is held inside its commit when
        /// the tab is closed into the stash. The close settles the run by force once its grace has
        /// passed and finishes with the run's task still alive. The tab is then restored under the
        /// same ID and a successor run is started on it, which waits for its child on its own
        /// pending policy.
        ///
        /// The held commit is then let go and the settled run's task runs to its end: it leaves its
        /// commit, is retired, and clears its own routing policy. It takes nothing from the
        /// successor, whose pending policy, claim, session, and run state are as they were, and
        /// which goes on to commit the restored tab through its own child.
        func testForceSettledRunsTailCannotAffectSuccessorOnItsRestoredTab() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let promptManager = fixture.window.promptManager
                let slot = fixture.slots[1]
                let afterWrite = ContextBuilderTestGate()
                let reported = ReportedPhases()
                var tornDownRunIDs: Set<UUID> = []
                cleanup.add { viewModel.installRunTestHooks(nil) }
                fixture.releaseOnSettle { await afterWrite.open() }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: { tornDownRunIDs.insert($0) },
                    afterCommittedTabSnapshotCaptured: { _, _ in await afterWrite.wait() }
                ))

                fixture.childWrites = .init(setsPrompt: false, setsSelection: true, repliesWithOutput: true)
                let settledRun = fixture.startMCPRun(on: slot, progressReporter: { phase in
                    reported.phases.append(phase)
                })
                try await fixture.waitFor("the run to have written its tab") { await afterWrite.entered }
                let settledRunID = try XCTUnwrap(fixture.activeRunID(slot))

                _ = await promptManager.stashComposeTabs(withIDs: [slot.tabID])
                XCTAssertNil(fixture.storedTab(slot), "The tab closed")
                XCTAssertNil(viewModel.sessions[slot.tabID])
                let settledCompletion = try await fixture.completion(of: settledRun)
                XCTAssertEqual(settledCompletion.terminalDisposition, .cancelled)
                XCTAssertEqual(settledCompletion.committedTab?.tab.promptText, slot.agentOutput)
                XCTAssertFalse(reported.phases.contains(.runFinalization), "The run's task is still inside its commit")

                let restored = await promptManager.restoreStashedComposeTab(containingTabID: slot.tabID)
                XCTAssertEqual(restored?.id, slot.tabID)
                XCTAssertEqual(fixture.storedTab(slot)?.promptText, slot.agentOutput)
                fixture.childWrites = .init()
                fixture.holdsChildConnections = true
                let successorRun = fixture.startMCPRun(on: slot)
                let successorRunID = try await fixture.registeredRunID(on: slot)
                let successorChild = try await fixture.childWithRegisteredProcess(forRunID: successorRunID)
                XCTAssertNotEqual(successorRunID, settledRunID)
                let pendingBefore = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingBefore, [successorRunID])
                let successorBefore = await SurvivingRun(successorRunID, on: slot, child: successorChild, in: fixture)
                XCTAssertEqual(successorBefore.runState, .running(successorRunID))
                XCTAssertEqual(successorBefore.operationToken?.origin, .mcp)
                XCTAssertFalse(reported.phases.contains(.runFinalization))
                let policyClearsBeforeTail = await fixture.routingEventNames(forRunID: settledRunID)
                    .count(where: { $0 == "policy_cleared" })

                await afterWrite.open()
                try await fixture.waitFor("the settled run's task to leave its commit") {
                    reported.phases.contains(.runFinalization)
                }
                // A run settled by force is torn down without waiting for its task, so its teardown
                // does not show that the task has ended. The task's last step clears the run's
                // routing policy, and the successor is read once that and the teardown are done.
                try await fixture.waitFor("the settled run's task to clear its routing policy") {
                    await fixture.routingEventNames(forRunID: settledRunID)
                        .count(where: { $0 == "policy_cleared" }) > policyClearsBeforeTail
                }
                try await fixture.waitFor("the settled run's teardown to complete") {
                    tornDownRunIDs.contains(settledRunID)
                }
                XCTAssertFalse(viewModel.isRunTeardownPendingForTesting(runID: settledRunID))
                let successorAfter = await SurvivingRun(successorRunID, on: slot, child: successorChild, in: fixture)
                XCTAssertEqual(successorAfter, successorBefore)
                let pendingAfter = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingAfter, [successorRunID])
                XCTAssertNil(successorRun.result)

                await successorChild.allowConnection()
                let successorCompletion = try await fixture.completion(of: successorRun)
                try fixture.assertCommitted(successorCompletion, by: successorChild)
                let leftoverPendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(leftoverPendingRunIDs, [])
                XCTAssertNil(fixture.operationToken(slot))
            }
        }

        /// Start state: two tabs' runs are routed and their children hold their turns. Each child
        /// has a `get_file_tree` call in flight, so the window's settlement registry holds a lease
        /// for each.
        ///
        /// The detaching tab's call ignores its cancellation while its deadline and cleanup grace
        /// run out, so it is answered as detached with its operation still running. The pressed
        /// tab's call in flight is answered normally. The pressed tab's next fenced call, its
        /// prompt write, is refused with `tool_execution_structure_settlement_busy` naming the
        /// detached call, and its run, claim, route, and stored tab stay as they were.
        ///
        /// Cancelling the detaching tab's run and disposing its provider does not lift the refusal.
        /// The detached operation finishing does, and the pressed tab's run then commits.
        func testDetachedToolCallGivesOtherTabTypedPressureOnly() async throws {
            try await ContextBuilderRunFixture.withFixture(tabNames: ["detaching", "pressed"]) { fixture, cleanup in
                let viewModel = fixture.viewModel
                let manager = fixture.manager
                let windowID = fixture.window.windowID
                let detaching = fixture.slots[0]
                let pressed = fixture.slots[1]
                var tornDownRunIDs: Set<UUID> = []
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: { tornDownRunIDs.insert($0) }
                ))

                let clock = MCPExportWatchdogManualClock()
                let detachingOperation = MCPExecutionIgnoringCancellationGate()
                let overlappingOperation = ContextBuilderTestGate()
                cleanup.add {
                    await detachingOperation.release()
                    await overlappingOperation.open()
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.getFileTree,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.getFileTree) {
                    if await detachingOperation.enteredCount() == 0 {
                        await detachingOperation.enterAndWait()
                    } else {
                        await overlappingOperation.wait()
                    }
                    return .object(["ok": .bool(true)])
                }

                fixture.holdsChildTurns = true
                let detachingRun = fixture.startMCPRun(on: detaching)
                let pressedRun = fixture.startMCPRun(on: pressed)
                let detachingRunID = try await fixture.registeredRunID(on: detaching)
                let pressedRunID = try await fixture.registeredRunID(on: pressed)
                let detachingChild = try await fixture.childWithRegisteredProcess(forRunID: detachingRunID)
                let pressedChild = try await fixture.childWithRegisteredProcess(forRunID: pressedRunID)
                try await fixture.waitFor("both children to hold their turns") {
                    guard await detachingChild.isTurnHeld() else { return false }
                    return await pressedChild.isTurnHeld()
                }

                let detachedCall = Task {
                    try await detachingChild.callTool(MCPWindowToolName.getFileTree, ["_rawJSON": true])
                }
                try await detachingOperation.waitUntilEntered(count: 1)
                try await clock.waitForSleeperCount(1)
                // The second call starts more than one cleanup grace after the first, so its own
                // deadline is still ahead of the clock when the first call's grace has run out.
                try await clock.advanceWithoutWakingSleepers(
                    by: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace + .seconds(1)
                )
                let overlappingCall = Task {
                    try await pressedChild.callTool(MCPWindowToolName.getFileTree, ["_rawJSON": true])
                }
                try await fixture.waitFor("the pressed tab's call to be in flight") {
                    await overlappingOperation.entered
                }
                try await clock.waitForSleeperCount(2)
                let leasesInFlight = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                XCTAssertEqual(leasesInFlight, .init(activeCount: 2, detachedCount: 0))

                try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                try await clock.waitForSleeperCount(2)
                try await clock.advanceSleeper(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
                let detachedAnswer = try await Self.toolPayload(detachedCall.value)
                XCTAssertEqual(detachedAnswer["code"] as? String, "tool_execution_timeout")
                XCTAssertEqual(detachedAnswer["settlement"] as? String, "detached")
                let leasesAfterDetach = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                XCTAssertEqual(leasesAfterDetach, .init(activeCount: 2, detachedCount: 1))
                XCTAssertNil(detachingRun.result, "A detached tool call does not end its own run.")

                await overlappingOperation.open()
                let overlappingAnswer = try await overlappingCall.value
                XCTAssertFalse(overlappingAnswer.rawJSON.contains("\"isError\":true"), overlappingAnswer.rawJSON)
                let leasesAfterOverlap = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                XCTAssertEqual(leasesAfterOverlap, .init(activeCount: 1, detachedCount: 1))

                let pressedBefore = await SurvivingRun(pressedRunID, on: pressed, child: pressedChild, in: fixture)
                let pressedRoutingBefore = await fixture.routingEventNames(forRunID: pressedRunID)
                XCTAssertEqual(
                    pressedBefore.route,
                    Admission(routedRunID: pressedRunID, runConnectionID: pressedChild.connectionID, boundTabID: pressed.tabID)
                )
                XCTAssertEqual(pressedBefore.runState, .running(pressedRunID))
                XCTAssertEqual(pressedBefore.storedPrompt, "")
                let promptWrite: [String: Any] = ["op": "set", "text": pressed.promptText, "_rawJSON": true]
                let refusal = try await Self.toolPayload(pressedChild.callTool(MCPWindowToolName.prompt, promptWrite))
                XCTAssertEqual(refusal["code"] as? String, "tool_execution_structure_settlement_busy")
                XCTAssertEqual(refusal["busy_reason"] as? String, "detached_settlement_in_progress")
                XCTAssertEqual(refusal["settlement"] as? String, "busy")
                XCTAssertEqual(refusal["retryable"] as? Bool, true)
                XCTAssertEqual(refusal["origin_tool"] as? String, MCPWindowToolName.getFileTree)
                XCTAssertEqual(refusal["origin_connection_id"] as? String, detachingChild.connectionID.uuidString)
                XCTAssertEqual(
                    refusal["retry_after_ms"] as? Int,
                    Int(MCPCodeStructureSettlementRegistry.recoveryHorizon.components.seconds) * 1000
                )
                XCTAssertEqual(refusal["released_provider_count"] as? Int, 0)

                let pressedAfterRefusal = await SurvivingRun(pressedRunID, on: pressed, child: pressedChild, in: fixture)
                XCTAssertEqual(pressedAfterRefusal, pressedBefore)
                XCTAssertNil(pressedRun.result)
                let pressedRoutingAfter = await fixture.routingEventNames(forRunID: pressedRunID)
                XCTAssertEqual(pressedRoutingAfter, pressedRoutingBefore)
                for child in [detachingChild, pressedChild] {
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: child.connectionID)
                    XCTAssertFalse(isTerminal)
                }

                await viewModel.cancelMCPContextBuilderRun(forTabID: detaching.tabID)
                try await fixture.waitFor("the detaching tab's run to finish teardown", allowingRunErrors: true) {
                    detachingRun.result != nil && tornDownRunIDs.contains(detachingRunID)
                }
                XCTAssertThrowsError(try XCTUnwrap(detachingRun.result).get()) { error in
                    XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
                }
                await detachingChild.allowTurn()
                XCTAssertEqual(detachingChild.disposeCount, 1)
                XCTAssertTrue(detachingChild.hasFinishedDisposal)
                XCTAssertNil(fixture.operationToken(detaching))
                let leasesAfterDisposal = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                XCTAssertEqual(leasesAfterDisposal, .init(activeCount: 1, detachedCount: 1))
                let refusalAfterDisposal = try await Self.toolPayload(
                    pressedChild.callTool(MCPWindowToolName.prompt, promptWrite)
                )
                XCTAssertEqual(refusalAfterDisposal["code"] as? String, "tool_execution_structure_settlement_busy")
                XCTAssertEqual(
                    refusalAfterDisposal["origin_connection_id"] as? String,
                    detachingChild.connectionID.uuidString
                )
                let pressedAfterDisposal = await SurvivingRun(pressedRunID, on: pressed, child: pressedChild, in: fixture)
                XCTAssertEqual(pressedAfterDisposal, pressedBefore)

                await detachingOperation.release()
                try await fixture.waitFor("the detached operation's lease to be removed", allowingRunErrors: true) {
                    await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                        == .init(activeCount: 0, detachedCount: 0)
                }
                let admittedWrite = try await pressedChild.callTool(MCPWindowToolName.prompt, promptWrite)
                XCTAssertFalse(admittedWrite.rawJSON.contains("\"isError\":true"), admittedWrite.rawJSON)
                XCTAssertEqual(fixture.storedTab(pressed)?.promptText, pressed.promptText)

                await pressedChild.allowTurn()
                try await fixture.waitFor("the pressed tab's run to return", allowingRunErrors: true) {
                    pressedRun.result != nil
                }
                try fixture.assertCommitted(XCTUnwrap(pressedRun.result).get(), by: pressedChild)
                XCTAssertEqual(fixture.slots.map { fixture.operationToken($0) }, [nil, nil])
            }
        }

        /// The JSON object the app answered a raw-output tool call with.
        private static func toolPayload(_ response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.rawJSON.utf8)) as? [String: Any],
                response.rawJSON
            )
            let result = try XCTUnwrap(envelope["result"] as? [String: Any], response.rawJSON)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]], response.rawJSON)
            let text = content.compactMap { $0["text"] as? String }.joined()
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
        }

        private typealias Admission = ContextBuilderProviderChild.Admission

        /// The progress phases a run reported, oldest first.
        @MainActor
        private final class ReportedPhases {
            var phases: [ContextBuilderMCPProgressPhase] = []
        }

        /// How the ending tab's run ends.
        private enum RunEnding: CaseIterable {
            case callerCancellation
            case providerFailure
        }

        /// What one run's end or late teardown must leave as it was on another run.
        private struct SurvivingRun: Equatable {
            let activeRunID: UUID?
            let operationToken: ContextBuilderRunFixture.OperationToken?
            let session: ObjectIdentifier?
            let runState: AgentRunState?
            let isBusy: Bool?
            let route: Admission
            let hasPendingPolicy: Bool
            let childDisposeCount: Int
            let storedPrompt: String?
            let storedSelection: [String]?

            @MainActor
            init(
                _ runID: UUID,
                on slot: ContextBuilderRunFixture.TabSlot,
                child: ContextBuilderProviderChild,
                in fixture: ContextBuilderRunFixture
            ) async {
                let session = fixture.session(slot)
                activeRunID = fixture.activeRunID(slot)
                operationToken = fixture.operationToken(slot)
                self.session = session.map(ObjectIdentifier.init)
                runState = session?.agentRunState
                isBusy = session?.isAgentBusy
                route = await Admission(
                    routedRunID: fixture.manager.runIDForConnection(child.connectionID),
                    runConnectionID: fixture.window.mcpServer.connectionID(forRunID: runID),
                    boundTabID: fixture.window.mcpServer.tabContextByConnectionID[child.connectionID]?.tabID
                )
                hasPendingPolicy = await fixture.manager.debugPendingPolicySnapshot(for: child.clientName)
                    .contains { $0.runID == runID }
                childDisposeCount = child.disposeCount
                let stored = fixture.storedTab(slot)
                storedPrompt = stored?.promptText
                storedSelection = stored?.selection.selectedPaths
            }
        }
    }
#endif
