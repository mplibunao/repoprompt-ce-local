import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// The per-tab operation token: one Context Builder operation per tab for UI and MCP runs alike,
    /// claimed before any other effect and released by exactly one owner per origin.
    @MainActor
    final class ContextBuilderTabAdmissionTests: XCTestCase {
        private typealias OperationToken = ContextBuilderRunFixture.OperationToken

        /// A second tab is admitted while the first is running. A second attempt on an occupied tab
        /// is refused at once whichever entry made the first, and changes nothing about the run
        /// already there.
        func testDifferentTabsAdmitAndSameTabRefuses() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let viewModel = fixture.viewModel
                let first = fixture.slots[0]
                let second = fixture.slots[1]
                var providers: [ContextBuilderUnroutedProvider] = []
                fixture.providerScript = { _ in
                    let provider = ContextBuilderUnroutedProvider()
                    providers.append(provider)
                    return provider
                }
                fixture.releaseOnSettle {
                    for provider in providers {
                        await provider.finish()
                    }
                }

                let pressed = await fixture.pressRun(on: first)
                let uiRunID = try XCTUnwrap(pressed)
                try await fixture.waitFor("the first tab's provider to start its turn") {
                    providers.first?.runID == uiRunID
                }
                XCTAssertEqual(
                    fixture.operationToken(first),
                    OperationToken(id: uiRunID, origin: .ui, workspaceID: fixture.workspaceID)
                )

                // Each refused attempt is compared in the main-actor turn it ran in, so nothing the
                // running run does on its own can stand in for a change the attempt made.
                let uiIncumbent = TabState(fixture, first)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: first.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(TabState(fixture, first), uiIncumbent)
                viewModel.runContextBuilderAgent()
                XCTAssertEqual(TabState(fixture, first), uiIncumbent)
                XCTAssertEqual(providers.count, 1)

                let mcpRun = fixture.startMCPRun(on: second)
                try await fixture.waitFor("the second tab's provider to start its turn") {
                    providers.count == 2 && providers[1].runID != nil
                }
                let mcpRunID = try XCTUnwrap(fixture.activeRunID(second))
                XCTAssertEqual(providers[1].runID, mcpRunID)
                XCTAssertEqual(fixture.operationToken(second)?.origin, .mcp)
                XCTAssertEqual(fixture.activeRunID(first), uiRunID)

                await fixture.window.promptManager.switchComposeTab(second.tabID)
                let mcpIncumbent = TabState(fixture, second)
                viewModel.runContextBuilderAgent()
                XCTAssertEqual(TabState(fixture, second), mcpIncumbent)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: second.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(TabState(fixture, second), mcpIncumbent)
                XCTAssertEqual(providers.count, 2)

                await providers[0].finish()
                try await fixture.waitForRelease(of: first)
                XCTAssertNil(fixture.activeRunID(first))
                XCTAssertEqual(providers.count, 2)
                XCTAssertEqual(fixture.activeRunID(second), mcpRunID)
                try await assertClaimable(first, in: fixture)

                await providers[1].finish()
                let completion = try await fixture.completion(of: mcpRun)
                XCTAssertEqual(completion.runID, mcpRunID)
                XCTAssertNil(fixture.operationToken(second))
                XCTAssertEqual(providers.count, 2)
            }
        }

        /// Releasing a token again after a successor claimed the tab leaves the successor's claim.
        func testStaleReleaseCannotReleaseSuccessor() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[0]

                let first = try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: "plan",
                    planModelName: nil
                )
                await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: first)
                XCTAssertNil(fixture.operationToken(slot))

                let successor = try viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: "review",
                    planModelName: nil
                )
                XCTAssertNotEqual(successor, first)
                let claimed = OperationToken(id: successor, origin: .mcp, workspaceID: fixture.workspaceID)

                await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: first)
                await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: first)
                XCTAssertEqual(fixture.operationToken(slot), claimed)
                XCTAssertEqual(fixture.session(slot)?.mcpResponseType, "review")
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: slot.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(fixture.operationToken(slot), claimed)

                await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: successor)
                XCTAssertNil(fixture.operationToken(slot))
                XCTAssertNil(fixture.session(slot)?.mcpResponseType)
            }
        }

        /// A run that fails before a provider exists gives the tab back: the MCP path through its
        /// cleanup scope with the error the caller sees, the UI path on its own once the run ends.
        func testFailureBeforeProviderCreationReleasesTabToken() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let viewModel = fixture.viewModel
                let mcpSlot = fixture.slots[0]
                let uiSlot = fixture.slots[1]

                let token = try viewModel.beginMCPControlledRun(
                    forTabID: mcpSlot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                do {
                    _ = try await viewModel.runContextBuilderForMCP(
                        authority: Self.systemWorkspaceAuthority(from: fixture.mcpAuthority(for: mcpSlot)),
                        mcpControlToken: token
                    )
                    XCTFail("A system workspace cannot run Context Builder")
                } catch {
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, "DiscoverAgent")
                    XCTAssertEqual(failure.code, 3)
                }
                XCTAssertEqual(fixture.operationToken(mcpSlot)?.id, token)
                await viewModel.clearMCPControlledRun(forTabID: mcpSlot.tabID, controlToken: UUID())
                XCTAssertEqual(fixture.operationToken(mcpSlot)?.id, token)
                await viewModel.clearMCPControlledRun(forTabID: mcpSlot.tabID, controlToken: token)
                assertNoOwnershipLeft(on: mcpSlot, in: fixture)
                try await assertClaimable(mcpSlot, in: fixture)

                let workspaceIndex = try XCTUnwrap(
                    fixture.window.workspaceManager.workspaces.firstIndex { $0.id == fixture.workspaceID }
                )
                fixture.window.workspaceManager.workspaces[workspaceIndex].repoPaths = []
                let pressed = await fixture.pressRun(on: uiSlot)
                let uiRunID = try XCTUnwrap(pressed)
                XCTAssertEqual(fixture.operationToken(uiSlot)?.id, uiRunID)
                try await fixture.waitForRelease(of: uiSlot)
                XCTAssertEqual(
                    fixture.session(uiSlot)?.agentRunState,
                    .failed(
                        "The target workspace has no usable provider root. "
                            + "Open or repair that workspace before running Context Builder."
                    )
                )
                assertNoOwnershipLeft(on: uiSlot, in: fixture)
                try await assertClaimable(uiSlot, in: fixture)

                XCTAssertEqual(fixture.providerRequests, [])
                let pendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertEqual(pendingRunIDs, [])
            }
        }

        /// A UI run's provider starts in the workspace root its tab had when Run was pressed, even
        /// when the workspace's roots have changed by the time the provider is created.
        func testUIRunProviderStartsInWorkspaceRootCapturedAtClaim() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let server = fixture.window.mcpServer
                let workspaceManager = fixture.window.workspaceManager
                let slot = fixture.slots[0]
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(finishesImmediately: true) }

                // The window's tools are still disabled, so the run stops at their registration:
                // after its claim and before its provider exists.
                XCTAssertFalse(server.windowToolsEnabled)
                let registrationGate = ContextBuilderTestGate()
                server.setBeforeWindowToolRegistrationForTesting { await registrationGate.wait() }
                cleanup.add {
                    server.setBeforeWindowToolRegistrationForTesting(nil)
                    await registrationGate.open()
                }

                let pressed = await fixture.pressRun(on: slot)
                XCTAssertNotNil(pressed)
                try await fixture.waitFor("the run to reach window-tool registration") {
                    await registrationGate.entered
                }
                XCTAssertEqual(fixture.providerRequests, [])

                let laterRoot = fixture.rootURL.appendingPathComponent("later-root", isDirectory: true)
                try FileManager.default.createDirectory(at: laterRoot, withIntermediateDirectories: true)
                let workspaceIndex = try XCTUnwrap(
                    workspaceManager.workspaces.firstIndex { $0.id == fixture.workspaceID }
                )
                workspaceManager.workspaces[workspaceIndex].repoPaths = [laterRoot.path]
                XCTAssertEqual(workspaceManager.activeWorkspace?.repoPaths, [laterRoot.path])

                await registrationGate.open()
                try await fixture.waitForRelease(of: slot)
                XCTAssertEqual(fixture.providerRequests.map(\.workspacePath), [fixture.rootURL.path])
            }
        }

        /// Two runs that overlap, each with its own model-parameter pins and its own provider,
        /// reach the provider factory with exactly the pins they were admitted with.
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
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let first = fixture.slots[0]
                let second = fixture.slots[1]
                var providers: [ContextBuilderUnroutedProvider] = []
                fixture.providerScript = { _ in
                    let provider = ContextBuilderUnroutedProvider()
                    providers.append(provider)
                    return provider
                }
                fixture.releaseOnSettle {
                    for provider in providers {
                        await provider.finish()
                    }
                }

                let highRun = fixture.startMCPRun(on: first, modelParameterSelections: [highPin])
                try await fixture.waitFor("the first run's provider to start its turn") {
                    providers.first?.runID != nil
                }
                let lowRun = fixture.startMCPRun(on: second, modelParameterSelections: [lowPin])
                try await fixture.waitFor("the second run's provider to start its turn") {
                    providers.count == 2 && providers[1].runID != nil
                }

                let highRunID = try XCTUnwrap(fixture.activeRunID(first))
                let lowRunID = try XCTUnwrap(fixture.activeRunID(second))
                XCTAssertEqual(providers.map(\.runID), [highRunID, lowRunID])
                XCTAssertEqual(
                    fixture.providerRequests,
                    [highPin, lowPin].map { pin in
                        ContextBuilderRunFixture.ProviderRequest(
                            agentKind: .claudeCode,
                            modelString: nil,
                            workspacePath: fixture.rootURL.path,
                            modelParameterSelections: [pin]
                        )
                    }
                )

                await providers[1].finish()
                let lowCompletion = try await fixture.completion(of: lowRun)
                XCTAssertEqual(lowCompletion.runID, lowRunID)
                XCTAssertEqual(fixture.activeRunID(first), highRunID)
                await providers[0].finish()
                let highCompletion = try await fixture.completion(of: highRun)
                XCTAssertEqual(highCompletion.runID, highRunID)
                XCTAssertEqual(fixture.providerRequests.count, 2)
            }
        }

        /// A UI run holds the same token an MCP run does and still behaves as a UI run: its
        /// automatic follow-up starts and the tab is not shown as MCP-controlled. The token is held
        /// until that follow-up settles, and is released after discovery when none starts.
        func testUIRunKeepsAutomaticFollowUpAndUIIdentity() async throws {
            try await ContextBuilderRunFixture.withFixture(tabNames: ["settles", "fails", "cancelled", "unprompted"]) { fixture, cleanup in
                let viewModel = fixture.viewModel
                fixture.enableAutomaticFollowUp(cleanup: cleanup)
                let followUps = Self.holdUIFollowUps(on: fixture, cleanup: cleanup)

                let settles = fixture.slots[0]
                var pressed = await fixture.pressRun(on: settles)
                let runID = try XCTUnwrap(pressed)
                XCTAssertEqual(
                    fixture.operationToken(settles),
                    OperationToken(id: runID, origin: .ui, workspaceID: fixture.workspaceID)
                )
                try await fixture.waitFor("the follow-up to be all that still holds the first tab") {
                    followUps.entryCount == 1
                        && fixture.operationToken(settles)?.isHeldByFollowUpOnly == true
                }
                let session = try XCTUnwrap(fixture.session(settles))
                XCTAssertEqual(session.agentRunState, .completed)
                XCTAssertNil(fixture.activeRunID(settles))
                XCTAssertEqual(fixture.operationToken(settles)?.id, runID)
                XCTAssertEqual(fixture.operationToken(settles)?.origin, .ui)
                XCTAssertFalse(session.isMCPControlledRun)
                XCTAssertFalse(viewModel.isMCPControlledRun)
                XCTAssertNil(viewModel.mcpResponseType)
                XCTAssertTrue(viewModel.isBackgroundPlanGenerating)
                fixture.assertStoredTabMatchesSlot(settles)
                XCTAssertEqual(fixture.providerRequests.map(\.workspacePath), [fixture.rootURL.path])

                followUps.open()
                try await fixture.waitForRelease(of: settles)
                XCTAssertFalse(session.isBackgroundPlanGenerating)
                XCTAssertEqual(session.backgroundPlanResponseText, Self.followUpAnswer)
                try await assertClaimable(settles, in: fixture)

                // Discovery did not complete.
                let fails = fixture.slots[1]
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(finishesImmediately: true) }
                pressed = await fixture.pressRun(on: fails)
                XCTAssertEqual(fixture.operationToken(fails)?.id, try XCTUnwrap(pressed))
                try await fixture.waitForRelease(of: fails)
                guard case .failed = fixture.session(fails)?.agentRunState else {
                    return XCTFail("A provider that never connects cannot complete discovery")
                }
                fixture.providerScript = nil
                try await assertClaimable(fails, in: fixture)

                // The user asked to cancel, and discovery still completed.
                let cancelled = fixture.slots[2]
                fixture.holdsChildConnections = true
                pressed = await fixture.pressRun(on: cancelled)
                let cancelledRunID = try XCTUnwrap(pressed)
                try await fixture.waitFor("the third tab's provider to be ready to connect") {
                    fixture.child(forRunID: cancelledRunID)?.registeredProviderPID != nil
                }
                XCTAssertTrue(viewModel.beginCancellation(forTabID: cancelled.tabID))
                await fixture.child(forRunID: cancelledRunID)?.allowConnection()
                try await fixture.waitForRelease(of: cancelled)
                XCTAssertEqual(fixture.session(cancelled)?.agentRunState, .completed)
                fixture.holdsChildConnections = false
                try await assertClaimable(cancelled, in: fixture)

                // Discovery completed and left the tab without a prompt to analyze.
                let unprompted = fixture.slots[3]
                fixture.childWrites = .init(setsPrompt: false, setsSelection: true, repliesWithOutput: false)
                pressed = await fixture.pressRun(on: unprompted)
                XCTAssertEqual(fixture.operationToken(unprompted)?.id, try XCTUnwrap(pressed))
                try await fixture.waitForRelease(of: unprompted)
                XCTAssertEqual(fixture.session(unprompted)?.agentRunState, .completed)
                XCTAssertEqual(fixture.storedTab(unprompted)?.promptText, "")
                try await assertClaimable(unprompted, in: fixture)

                XCTAssertEqual(followUps.entryCount, 1)
            }
        }

        /// While a UI run's follow-up holds the tab, an MCP claim is refused and a new UI run takes
        /// the tab over by cancelling that follow-up. The cancelled follow-up's own release, which
        /// arrives after the new run claimed the tab, leaves the new run's token in place.
        func testUIRunSupersedesUIFollowUpAndMCPRefusesDuringFollowUp() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[0]
                fixture.enableAutomaticFollowUp(cleanup: cleanup)
                let followUps = Self.holdUIFollowUps(on: fixture, cleanup: cleanup)

                var pressed = await fixture.pressRun(on: slot)
                let firstRunID = try XCTUnwrap(pressed)
                try await fixture.waitFor("the follow-up to be all that still holds the tab") {
                    followUps.entryCount == 1 && fixture.operationToken(slot)?.isHeldByFollowUpOnly == true
                }
                let session = try XCTUnwrap(fixture.session(slot))
                let heldByFollowUp = try XCTUnwrap(fixture.operationToken(slot))
                XCTAssertEqual(heldByFollowUp.id, firstRunID)

                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: slot.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(fixture.operationToken(slot), heldByFollowUp)
                XCTAssertTrue(session.isBackgroundPlanGenerating)

                let supersededFollowUp = try XCTUnwrap(session.backgroundPlanTask)
                let successorProvider = ContextBuilderUnroutedProvider()
                fixture.providerScript = { _ in successorProvider }
                fixture.releaseOnSettle { await successorProvider.finish() }
                pressed = await fixture.pressRun(on: slot)
                let successorRunID = try XCTUnwrap(pressed)
                XCTAssertNotEqual(successorRunID, firstRunID)
                let successorToken = OperationToken(id: successorRunID, origin: .ui, workspaceID: fixture.workspaceID)
                XCTAssertEqual(fixture.operationToken(slot), successorToken)
                XCTAssertFalse(session.isBackgroundPlanGenerating)

                await supersededFollowUp.value
                XCTAssertEqual(fixture.operationToken(slot), successorToken)
                XCTAssertEqual(fixture.activeRunID(slot), successorRunID)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: slot.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }

                await successorProvider.finish()
                try await fixture.waitForRelease(of: slot)
                XCTAssertEqual(followUps.entryCount, 1)
            }
        }

        /// A cancelled follow-up can still be unwinding when the user starts the next one under the
        /// same token. When it finally unwinds it settles nothing: the replacement keeps its task
        /// and its generating state, the tab stays claimed and closed to an MCP run until the
        /// replacement settles, and the answer published is the replacement's.
        func testCancelledFollowUpStillUnwindingCannotSettleItsReplacement() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[0]
                fixture.enableAutomaticFollowUp(cleanup: cleanup)
                let cancelled = Self.holdUIFollowUpThroughItsCancellation(on: fixture, cleanup: cleanup)

                let pressed = await fixture.pressRun(on: slot)
                let runID = try XCTUnwrap(pressed)
                try await fixture.waitFor("the follow-up to be all that still holds the tab") {
                    cancelled.started.entryCount == 1 && fixture.operationToken(slot)?.isHeldByFollowUpOnly == true
                }
                let session = try XCTUnwrap(fixture.session(slot))
                let heldByFollowUp = try XCTUnwrap(fixture.operationToken(slot))
                XCTAssertEqual(heldByFollowUp.id, runID)
                let cancelledFollowUp = try XCTUnwrap(session.backgroundPlanTask)

                viewModel.cancelBackgroundPlanGeneration(forTabID: slot.tabID)
                await cancelled.unwinding.waitUntilEntered()
                XCTAssertNil(session.backgroundPlanTask)
                XCTAssertFalse(session.isBackgroundPlanGenerating)
                XCTAssertEqual(fixture.operationToken(slot), heldByFollowUp)

                let replacements = Self.holdUIFollowUps(on: fixture, cleanup: cleanup)
                viewModel.startBackgroundPlanGeneration(
                    tabID: slot.tabID,
                    oracleViewModel: fixture.window.oracleViewModel
                )
                let replacement = try XCTUnwrap(session.backgroundPlanTask)
                XCTAssertNotEqual(replacement, cancelledFollowUp)
                try await fixture.waitFor("the replacement follow-up to start generating") {
                    replacements.entryCount == 1
                }

                await cancelled.unwinding.open()
                await cancelledFollowUp.value
                XCTAssertEqual(session.backgroundPlanTask, replacement)
                XCTAssertTrue(session.isBackgroundPlanGenerating)
                XCTAssertTrue(viewModel.isBackgroundPlanGenerating)
                XCTAssertNil(session.backgroundPlanResponseText)
                XCTAssertEqual(fixture.operationToken(slot), heldByFollowUp)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: slot.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(fixture.operationToken(slot), heldByFollowUp)

                replacements.open()
                await replacement.value
                XCTAssertNil(session.backgroundPlanTask)
                XCTAssertFalse(session.isBackgroundPlanGenerating)
                XCTAssertFalse(viewModel.isBackgroundPlanGenerating)
                XCTAssertEqual(session.backgroundPlanResponseText, Self.followUpAnswer)
                XCTAssertNil(session.backgroundPlanError)
                try await assertClaimable(slot, in: fixture)
                XCTAssertEqual(fixture.providerRequests.count, 1)
            }
        }

        /// Cancelling a follow-up only asks it to end. One cancelled before its run has cleared its
        /// routing policy still counts when that run settles: the tab stays claimed, and closed to
        /// an MCP run, until the follow-up has unwound.
        ///
        /// The run is one the user cancelled, which the panel no longer shows as running while its
        /// execution has yet to clear the policy. A follow-up started in that interval is cancelled
        /// and is holding its unwinding before the execution is let go, so the run can only settle
        /// with that follow-up still unwinding.
        func testFollowUpCancelledBeforeItsRunSettlesHoldsTabUntilItUnwinds() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[0]
                let execution = ContextBuilderTestGate()
                fixture.releaseOnSettle { await execution.open() }
                let cancelled = Self.holdUIFollowUpThroughItsCancellation(
                    on: fixture,
                    cleanup: cleanup,
                    holdingRunExecutionAt: execution
                )
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }

                let pressed = await fixture.pressRun(on: slot)
                let runID = try XCTUnwrap(pressed)
                await execution.waitUntilEntered()
                await viewModel.cancelAgentRun()
                let heldByRun = OperationToken(id: runID, origin: .ui, workspaceID: fixture.workspaceID)
                XCTAssertNil(fixture.activeRunID(slot))
                XCTAssertEqual(fixture.operationToken(slot), heldByRun)

                viewModel.startBackgroundPlanGeneration(
                    tabID: slot.tabID,
                    oracleViewModel: fixture.window.oracleViewModel
                )
                try await fixture.waitFor("the follow-up to start generating") {
                    cancelled.started.entryCount == 1
                }
                viewModel.cancelBackgroundPlanGeneration(forTabID: slot.tabID)
                await cancelled.unwinding.waitUntilEntered()
                let session = try XCTUnwrap(fixture.session(slot))
                XCTAssertNil(session.backgroundPlanTask)
                XCTAssertEqual(fixture.operationToken(slot), heldByRun)

                await execution.open()
                try await fixture.waitFor("the run to settle its claim on the tab") {
                    fixture.operationToken(slot).map(\.isHeldByFollowUpOnly) ?? true
                }
                var heldByFollowUp = heldByRun
                heldByFollowUp.isHeldByFollowUpOnly = true
                XCTAssertEqual(fixture.operationToken(slot), heldByFollowUp)
                XCTAssertNil(session.backgroundPlanTask)
                XCTAssertFalse(session.isBackgroundPlanGenerating)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: slot.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(fixture.operationToken(slot), heldByFollowUp)

                await cancelled.unwinding.open()
                try await fixture.waitForRelease(of: slot)
                XCTAssertNil(session.backgroundPlanResponseText)
                XCTAssertNil(session.backgroundPlanError)
                try await assertClaimable(slot, in: fixture)
                XCTAssertEqual(fixture.providerRequests.count, 1)
            }
        }

        /// A cancelled run stops being the tab's active run at once and keeps the tab until it has
        /// cleared its routing policy. For that whole interval the tab is published as held against
        /// a new run, which is what keeps the Run control unavailable, and pressing Run starts
        /// nothing. The hold is withdrawn when the token is released.
        func testCancelledUIRunHoldsTabAgainstNewRunUntilTokenRelease() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let slot = fixture.slots[0]
                let processingGate = ContextBuilderTestGate()
                cleanup.add { viewModel.installRunTestHooks(nil) }
                fixture.releaseOnSettle { await processingGate.open() }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: { _, _ in await processingGate.wait() },
                    providerEventDisposition: nil,
                    teardownCompleted: nil
                ))
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }

                var publishedHolds: [Set<UUID>] = []
                let subscription = viewModel.$tabsHeldAgainstNewRun.dropFirst().sink { publishedHolds.append($0) }
                cleanup.add { subscription.cancel() }
                XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [])

                let pressed = await fixture.pressRun(on: slot)
                let runID = try XCTUnwrap(pressed)
                await processingGate.waitUntilEntered()
                XCTAssertEqual(viewModel.tabsWithActiveContextBuilderRun, [slot.tabID])
                XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [slot.tabID])

                await viewModel.cancelAgentRun()
                XCTAssertNil(fixture.activeRunID(slot))
                XCTAssertEqual(viewModel.tabsWithActiveContextBuilderRun, [])
                XCTAssertFalse(viewModel.isAgentBusy)
                XCTAssertEqual(
                    fixture.operationToken(slot),
                    OperationToken(id: runID, origin: .ui, workspaceID: fixture.workspaceID)
                )
                XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [slot.tabID])
                let ignored = await fixture.pressRun(on: slot)
                XCTAssertNil(ignored)
                XCTAssertEqual(fixture.providerRequests.count, 1)
                XCTAssertEqual(publishedHolds, [[slot.tabID]])

                await processingGate.open()
                try await fixture.waitForRelease(of: slot)
                XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [])
                XCTAssertEqual(publishedHolds, [[slot.tabID], []])

                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(finishesImmediately: true) }
                let restarted = await fixture.pressRun(on: slot)
                XCTAssertNotNil(restarted)
                XCTAssertNotEqual(restarted, runID)
                try await fixture.waitForRelease(of: slot)
                XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [])
            }
        }

        /// An MCP run that does not complete keeps its tab until the caller's cleanup scope releases
        /// it, and that release waits for the run to clear its routing policy. Until then a
        /// successor is refused.
        func testFailedMCPRunHoldsTokenUntilCleanupScope() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel

                let failedSlot = fixture.slots[0]
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(finishesImmediately: true) }
                let failedToken = try viewModel.beginMCPControlledRun(
                    forTabID: failedSlot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                let failed = try await viewModel.runContextBuilderForMCP(
                    authority: fixture.mcpAuthority(for: failedSlot),
                    mcpControlToken: failedToken
                )
                guard case .failed = failed.terminalDisposition else {
                    return XCTFail("A provider that never connects cannot complete discovery")
                }
                let stillClaimed = OperationToken(id: failedToken, origin: .mcp, workspaceID: fixture.workspaceID)
                XCTAssertEqual(fixture.operationToken(failedSlot), stillClaimed)
                XCTAssertEqual(fixture.session(failedSlot)?.isMCPControlledRun, true)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: failedSlot.tabID, responseType: nil, planModelName: nil)
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(fixture.operationToken(failedSlot), stillClaimed)

                await viewModel.clearMCPControlledRun(forTabID: failedSlot.tabID, controlToken: failedToken)
                XCTAssertNil(fixture.operationToken(failedSlot))
                var pendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertFalse(pendingRunIDs.contains(failed.runID))
                try await assertClaimable(failedSlot, in: fixture)

                // A cancelled run whose provider event is still being processed has finished for
                // its caller while its execution, which ends by clearing the policy, has not.
                let cancelledSlot = fixture.slots[1]
                let processingGate = ContextBuilderTestGate()
                cleanup.add { viewModel.installRunTestHooks(nil) }
                fixture.releaseOnSettle { await processingGate.open() }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: { _, _ in await processingGate.wait() },
                    providerEventDisposition: nil,
                    teardownCompleted: nil
                ))
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }
                let cancelledToken = try viewModel.beginMCPControlledRun(
                    forTabID: cancelledSlot.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                let authority = try fixture.mcpAuthority(for: cancelledSlot)
                let cancelledRun = Task { @MainActor in
                    try await viewModel.runContextBuilderForMCP(authority: authority, mcpControlToken: cancelledToken)
                }
                try await fixture.waitFor("the second tab's run to be processing a provider event") {
                    await processingGate.entered
                }
                let cancelledRunID = try XCTUnwrap(fixture.activeRunID(cancelledSlot))
                await viewModel.cancelMCPContextBuilderRun(runID: cancelledRunID)
                let cancelledResult = await cancelledRun.result
                XCTAssertThrowsError(try cancelledResult.get()) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertNil(fixture.activeRunID(cancelledSlot))
                XCTAssertEqual(fixture.operationToken(cancelledSlot)?.id, cancelledToken)

                // The release runs on the main actor, as this test does, and enters the release call
                // in the same turn that sets `releaseStarted`. The flag can therefore only be seen
                // here once the release has stopped running: it has finished, or it is suspended at
                // its first wait inside the call.
                var releaseStarted = false
                var released = false
                let release = Task { @MainActor in
                    releaseStarted = true
                    await viewModel.clearMCPControlledRun(forTabID: cancelledSlot.tabID, controlToken: cancelledToken)
                    released = true
                }
                try await fixture.waitFor("the release to run up to its first wait") { releaseStarted }
                XCTAssertFalse(released)
                XCTAssertEqual(fixture.operationToken(cancelledSlot)?.id, cancelledToken)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(
                        forTabID: cancelledSlot.tabID,
                        responseType: nil,
                        planModelName: nil
                    )
                ) { Self.assertTabBusy($0) }

                await processingGate.open()
                await release.value
                XCTAssertNil(fixture.operationToken(cancelledSlot))
                pendingRunIDs = try await fixture.pendingPolicyRunIDs()
                XCTAssertFalse(pendingRunIDs.contains(cancelledRunID))
                try await assertClaimable(cancelledSlot, in: fixture)
            }
        }

        /// A follow-up started by hand is not admitted to a tab that another operation holds. No
        /// run is registered for such a tab and no follow-up is generating on it, which is all
        /// the Generate Plan control would otherwise look at.
        func testManualFollowUpIsNotAdmittedWhileAnotherOperationHoldsTheTab() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let viewModel = fixture.viewModel
                let held = fixture.slots[0]
                let free = fixture.slots[1]
                XCTAssertTrue(viewModel.admitsManualFollowUp(forTabID: held.tabID))

                let token = try viewModel.beginMCPControlledRun(
                    forTabID: held.tabID,
                    workspaceID: fixture.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                XCTAssertEqual(viewModel.tabsWithActiveContextBuilderRun, [])
                XCTAssertEqual(fixture.session(held)?.isBackgroundPlanGenerating, false)
                XCTAssertFalse(viewModel.admitsManualFollowUp(forTabID: held.tabID))
                XCTAssertTrue(viewModel.admitsManualFollowUp(forTabID: free.tabID))

                await viewModel.clearMCPControlledRun(forTabID: held.tabID, controlToken: token)
                XCTAssertTrue(viewModel.admitsManualFollowUp(forTabID: held.tabID))
            }
        }

        /// Once the window has begun closing, neither entry claims a tab or leaves anything behind.
        func testClaimRefusesWhileWindowIsClosing() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let viewModel = fixture.viewModel
                let visible = fixture.slots[0]
                let hidden = fixture.slots[1]
                await fixture.window.promptManager.switchComposeTab(visible.tabID)
                let sessionsBefore = Set(viewModel.sessions.keys)
                let visibleBefore = TabState(fixture, visible)

                viewModel.prepareForWindowClose()

                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: hidden.tabID, responseType: "plan", planModelName: nil)
                ) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(forTabID: visible.tabID, responseType: "plan", planModelName: nil)
                ) { XCTAssertTrue($0 is CancellationError) }
                viewModel.runContextBuilderAgent()

                XCTAssertEqual(Set(viewModel.sessions.keys), sessionsBefore)
                XCTAssertEqual(TabState(fixture, visible), visibleBefore)
                XCTAssertNil(fixture.session(visible)?.mcpResponseType)
                XCTAssertFalse(viewModel.isMCPControlledRun)
                XCTAssertNil(viewModel.mcpResponseType)
                XCTAssertEqual(viewModel.tabsWithActiveContextBuilderRun, [])
                XCTAssertEqual(fixture.providerRequests, [])
            }
        }

        /// While a close of several tabs waits for a run that has claimed its final-context commit,
        /// nothing is admitted to any tab in that close. A tab the workspace no longer holds is
        /// refused for that reason alone. A stashed tab restored before the wait ends is stored and
        /// visible again, and is still refused to both entries until the close has removed its
        /// session. A run on a tab outside the close is untouched throughout.
        func testTabsBeingClosedAdmitNothingWhileTheirCloseWaitsOnACommit() async throws {
            try await ContextBuilderRunFixture.withFixture(
                tabNames: ["visible", "committing", "idle", "other"]
            ) { fixture, cleanup in
                let viewModel = fixture.viewModel
                let promptManager = fixture.window.promptManager
                let committing = fixture.slots[1]
                let idle = fixture.slots[2]
                let other = fixture.slots[3]
                let afterWrite = ContextBuilderTestGate()
                cleanup.add { viewModel.installRunTestHooks(nil) }
                // The close waits on the commit for as long as the gate holds it, not on a grace.
                cleanup.add { viewModel.setCloseSettlementGraceForTesting(500_000_000) }
                viewModel.setCloseSettlementGraceForTesting(600 * NSEC_PER_SEC)
                fixture.releaseOnSettle { await afterWrite.open() }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    afterCommittedTabSnapshotCaptured: { _, receipt in
                        if receipt.identity.tabID == committing.tabID {
                            await afterWrite.wait()
                        }
                    }
                ))

                let committingRun = fixture.startMCPRun(on: committing)
                try await fixture.waitFor("the committing tab's run to have written its tab") {
                    await afterWrite.entered
                }
                let committingRunID = try XCTUnwrap(fixture.activeRunID(committing))
                let committingToken = try XCTUnwrap(fixture.operationToken(committing))

                fixture.holdsChildConnections = true
                let otherRun = fixture.startMCPRun(on: other)
                try await fixture.waitFor("the other tab's provider to be ready to connect") {
                    fixture.child(forRunID: fixture.activeRunID(other))?.registeredProviderPID != nil
                }
                let otherRunID = try XCTUnwrap(fixture.activeRunID(other))
                let otherChild = try XCTUnwrap(fixture.child(forRunID: otherRunID))
                let otherSession = try XCTUnwrap(fixture.session(other))
                let otherToken = try XCTUnwrap(fixture.operationToken(other))

                let close = CloseObservation()
                Task { @MainActor in
                    _ = await promptManager.stashComposeTabs(withIDs: [committing.tabID, idle.tabID])
                    close.returned = true
                }
                try await fixture.waitFor("the close to be waiting on the commit") {
                    fixture.session(committing)?.isCancelling == true
                }
                XCTAssertFalse(close.returned)
                XCTAssertNil(fixture.storedTab(committing))
                XCTAssertNil(fixture.storedTab(idle))
                XCTAssertNil(viewModel.sessions[idle.tabID])

                // Neither tab is in the workspace any more.
                let sessionsDuringWait = Set(viewModel.sessions.keys)
                for closing in [committing, idle] {
                    XCTAssertThrowsError(
                        try viewModel.beginMCPControlledRun(
                            forTabID: closing.tabID,
                            workspaceID: fixture.workspaceID,
                            responseType: nil,
                            planModelName: nil
                        )
                    ) { XCTAssertTrue($0 is CancellationError, "Refused as \($0)") }
                }
                XCTAssertEqual(Set(viewModel.sessions.keys), sessionsDuringWait)
                XCTAssertNil(viewModel.sessions[idle.tabID])
                XCTAssertEqual(fixture.operationToken(committing), committingToken)

                // Restored before the wait ends: in the workspace and on screen, and still closing.
                let restored = await promptManager.restoreStashedComposeTab(containingTabID: idle.tabID)
                XCTAssertEqual(restored?.id, idle.tabID)
                XCTAssertNotNil(fixture.storedTab(idle))
                XCTAssertEqual(viewModel.currentTabID, idle.tabID)
                guard !close.returned else {
                    XCTFail("The close returned before the commit it waits on was let go")
                    throw ContextBuilderRunFixture.ScenarioAborted()
                }
                // Run is pressed first, so that neither entry's refusal can be the other's claim.
                let requestsBefore = fixture.providerRequests.count
                let pressed = await fixture.pressRun(on: idle)
                XCTAssertNil(pressed)
                XCTAssertNil(fixture.operationToken(idle))
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(
                        forTabID: idle.tabID,
                        workspaceID: fixture.workspaceID,
                        responseType: nil,
                        planModelName: nil
                    )
                ) { XCTAssertTrue($0 is CancellationError, "Refused as \($0)") }
                XCTAssertNil(fixture.operationToken(idle))
                XCTAssertNil(fixture.activeRunID(idle))
                XCTAssertEqual(fixture.session(idle)?.agentLog.count ?? 0, 0)
                XCTAssertEqual(fixture.providerRequests.count, requestsBefore)
                XCTAssertFalse(viewModel.tabsHeldAgainstNewRun.contains(idle.tabID))
                XCTAssertFalse(viewModel.tabsWithActiveContextBuilderRun.contains(idle.tabID))
                XCTAssertFalse(close.returned)

                // The run outside the close.
                XCTAssertNil(otherRun.result)
                XCTAssertTrue(fixture.session(other) === otherSession)
                XCTAssertEqual(fixture.operationToken(other), otherToken)
                XCTAssertEqual(fixture.activeRunID(other), otherRunID)
                XCTAssertEqual(otherChild.disposeCount, 0)

                // Once the close has finished, the restored tab is a tab like any other, and the
                // one still stashed has no tab to claim.
                await afterWrite.open()
                try await fixture.waitFor("the close to return") { close.returned }
                let committed = try await fixture.completion(of: committingRun)
                XCTAssertEqual(committed.runID, committingRunID)
                XCTAssertEqual(committed.terminalDisposition, .cancelled)
                XCTAssertNotNil(committed.committedTab)
                try await assertClaimable(idle, in: fixture)
                XCTAssertThrowsError(
                    try viewModel.beginMCPControlledRun(
                        forTabID: committing.tabID,
                        workspaceID: fixture.workspaceID,
                        responseType: nil,
                        planModelName: nil
                    )
                ) { XCTAssertTrue($0 is CancellationError, "Refused as \($0)") }
                XCTAssertNil(viewModel.sessions[committing.tabID])

                XCTAssertNil(otherRun.result)
                XCTAssertEqual(fixture.operationToken(other), otherToken)
                await otherChild.allowConnection()
                try await fixture.assertCommitted(fixture.completion(of: otherRun), by: otherChild)
            }
        }

        /// A claim can reach the view model after its tab has gone: its caller saw the tab and then
        /// suspended. Such a claim is refused as a cancellation, not as a busy tab, and makes no
        /// session. So is a claim that names a tab, or a workspace for the tab, that never held it.
        func testClaimOnTabItsWorkspaceDoesNotHoldIsCancelledAndMakesNoSession() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, _ in
                let viewModel = fixture.viewModel
                let kept = fixture.slots[0]
                let closed = fixture.slots[1]
                try await assertClaimable(closed, in: fixture)
                await fixture.window.promptManager.closeComposeTab(closed.tabID)
                XCTAssertNil(fixture.storedTab(closed), "The tab closed")
                XCTAssertNil(viewModel.sessions[closed.tabID])
                let sessionsBefore = Set(viewModel.sessions.keys)
                let keptBefore = TabState(fixture, kept)

                let neverStored = UUID()
                let claims: [(tabID: UUID, workspaceID: UUID?)] = [
                    (closed.tabID, fixture.workspaceID),
                    (closed.tabID, nil),
                    (neverStored, fixture.workspaceID),
                    (kept.tabID, UUID())
                ]
                for claim in claims {
                    XCTAssertThrowsError(
                        try viewModel.beginMCPControlledRun(
                            forTabID: claim.tabID,
                            workspaceID: claim.workspaceID,
                            responseType: "plan",
                            planModelName: nil
                        )
                    ) { XCTAssertTrue($0 is CancellationError, "Refused as \($0)") }
                }

                XCTAssertEqual(Set(viewModel.sessions.keys), sessionsBefore)
                XCTAssertNil(viewModel.sessions[closed.tabID])
                XCTAssertNil(viewModel.sessions[neverStored])
                XCTAssertEqual(TabState(fixture, kept), keptBefore)
                XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [])
                XCTAssertFalse(viewModel.isMCPControlledRun)
                XCTAssertNil(viewModel.mcpResponseType)
                try await assertClaimable(kept, in: fixture)
            }
        }

        /// A workspace switch drops a tab's session while a follow-up started for the tab is still
        /// unwinding. When the tab is shown again it has another session. The follow-up ignores
        /// its cancellation and goes on to answer, and that answer stays with the session it was
        /// started for: the tab's present session, what the window shows of it, and the stored
        /// tab are all left as they were.
        func testFollowUpThatOutlivesItsSessionPublishesNothingOnceItsTabIsShownAgain() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let viewModel = fixture.viewModel
                let manager = fixture.window.workspaceManager
                let slot = fixture.slots[0]
                let execution = ContextBuilderTestGate()
                let started = ContextBuilderCancellableTestGate()
                let unwinding = ContextBuilderTestGate()
                cleanup.add { viewModel.installRunTestHooks(nil) }
                fixture.releaseOnSettle {
                    await execution.open()
                    started.open()
                    await unwinding.open()
                }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: { _, _ in await execution.wait() },
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    runUIFollowUp: { _, mode in
                        // Held until cancelled, then held again where cancellation cannot reach
                        // it, and then it answers as if it had never been cancelled.
                        try? await started.wait()
                        await unwinding.wait()
                        return ChatSendReply(
                            chatId: UUID(),
                            shortId: "late",
                            mode: mode.mcpModeName,
                            response: Self.lateFollowUpAnswer,
                            errors: nil
                        )
                    }
                ))
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }

                // A cancelled run whose execution is still held, and a follow-up started under it.
                let pressed = await fixture.pressRun(on: slot)
                let runID = try XCTUnwrap(pressed)
                await execution.waitUntilEntered()
                await viewModel.cancelAgentRun()
                XCTAssertEqual(
                    fixture.operationToken(slot),
                    OperationToken(id: runID, origin: .ui, workspaceID: fixture.workspaceID)
                )
                viewModel.startBackgroundPlanGeneration(
                    tabID: slot.tabID,
                    oracleViewModel: fixture.window.oracleViewModel
                )
                try await fixture.waitFor("the follow-up to start generating") { started.entryCount == 1 }
                let outlived = try XCTUnwrap(fixture.session(slot))
                let outlivingFollowUp = try XCTUnwrap(outlived.backgroundPlanTask)

                // Away, which drops the session and cancels the follow-up, and back to the tab.
                let elsewhere = manager.createWorkspace(
                    name: "Context Builder runs, other workspace",
                    repoPaths: [fixture.rootURL.path],
                    ephemeral: true
                )
                cleanup.add { manager.workspaces.removeAll { $0.id == elsewhere.id } }
                await manager.switchWorkspace(to: elsewhere, saveState: false, reason: "ContextBuilderTabAdmissionTests")
                try await fixture.waitFor("the switch to cancel the follow-up") { await unwinding.entered }
                let origin = try XCTUnwrap(manager.workspaces.first { $0.id == fixture.workspaceID })
                await manager.switchWorkspace(to: origin, saveState: false, reason: "ContextBuilderTabAdmissionTests")
                try await fixture.waitFor("the tab to be shown again") {
                    manager.activeWorkspaceID == fixture.workspaceID
                        && viewModel.currentTabID == slot.tabID
                        && fixture.session(slot) != nil
                }

                // The run's execution ends, and the tab's present session is given state of its own.
                await execution.open()
                try await fixture.waitForRelease(of: slot)
                let present = try XCTUnwrap(fixture.session(slot))
                XCTAssertFalse(present === outlived)
                viewModel.setBackgroundPlanGenerating(true, forTabID: slot.tabID)
                viewModel.setBackgroundPlanResponseText(Self.followUpAnswer, forTabID: slot.tabID)
                XCTAssertTrue(viewModel.isBackgroundPlanGenerating)
                let shownAnswer = try XCTUnwrap(viewModel.backgroundPlanResponsePreviewText)
                let shownLog = viewModel.agentLog.map(\.id)
                let shownRunState = viewModel.agentRunState
                let storedBefore = try XCTUnwrap(fixture.storedTab(slot))

                await unwinding.open()
                await outlivingFollowUp.value

                // The late answer was written, to the session the follow-up was started for.
                XCTAssertEqual(outlived.backgroundPlanResponseText, Self.lateFollowUpAnswer)
                XCTAssertFalse(outlived.isBackgroundPlanGenerating)

                XCTAssertTrue(fixture.session(slot) === present)
                XCTAssertTrue(present.isBackgroundPlanGenerating)
                XCTAssertEqual(present.backgroundPlanResponseText, Self.followUpAnswer)
                XCTAssertNil(present.operationToken)
                XCTAssertTrue(viewModel.isBackgroundPlanGenerating)
                XCTAssertEqual(viewModel.backgroundPlanResponsePreviewText, shownAnswer)
                XCTAssertNil(viewModel.backgroundPlanError)
                XCTAssertEqual(viewModel.agentLog.map(\.id), shownLog)
                XCTAssertEqual(viewModel.agentRunState, shownRunState)
                XCTAssertEqual(fixture.storedTab(slot), storedBefore)
                XCTAssertFalse(viewModel.tabsHeldAgainstNewRun.contains(slot.tabID))
            }
        }

        /// A UI run's automatic follow-up has created its chat and sent its prompt, and its reply is
        /// pending, when the session it was started for goes: the user switches the window to
        /// another workspace and back, or the tab is closed into the stash and restored. A switch
        /// made without asking is refused while the follow-up's chat streams, so the user's switch,
        /// which stops what is running once it is allowed, is the one that reaches such a
        /// follow-up.
        ///
        /// What this shows is the cancellation and what it leaves in place, not a completion of the
        /// follow-up that ran late. Both ways stop the follow-up's stream, and the follow-up ends
        /// without its reply. Another holder then claims the tab and starts an answer of its own.
        /// The fixture's provider stream does not end when the Oracle cancels it, so the provider's
        /// reply still arrives and the Oracle's stream reader takes it. The follow-up has nothing
        /// left to run by then, and what the Oracle does with the reply reaches nothing the holder
        /// has: no chat is created, the stored tab keeps its chat, and the holder's session, claim,
        /// and answer are as the holder left them.
        func testAutomaticFollowUpDetachedWithItsReplyPendingLeavesItsTabsNextHolderUntouched() async throws {
            for detachment in FollowUpDetachment.allCases {
                try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                    let viewModel = fixture.viewModel
                    let manager = fixture.window.workspaceManager
                    let promptManager = fixture.window.promptManager
                    let oracle = fixture.window.oracleViewModel
                    let slot = fixture.slots[0]
                    try await fixture.saveChatsInTemporaryDirectory()
                    fixture.enableAutomaticFollowUp(cleanup: cleanup)

                    // A completed UI run whose follow-up has sent its prompt and holds the tab.
                    // Showing a tab restores its chat's own model, so the follow-up's model is
                    // chosen once the tab is shown and before the run can complete.
                    fixture.holdsChildConnections = true
                    let pressed = await fixture.pressRun(on: slot)
                    let runID = try XCTUnwrap(pressed)
                    fixture.useFollowUpModelForUIFollowUps(cleanup: cleanup)
                    try await fixture.childWithRegisteredProcess(forRunID: runID).allowConnection()
                    fixture.holdsChildConnections = false
                    try await fixture.waitFor("\(detachment): the follow-up to send its prompt or fail") {
                        if await fixture.oracleReplies.requests.isEmpty == false { return true }
                        return fixture.session(slot)?.backgroundPlanError != nil
                    }
                    let requests = await fixture.oracleReplies.requests
                    let request = try XCTUnwrap(
                        requests.first,
                        "The follow-up failed before it sent: \(fixture.session(slot)?.backgroundPlanError ?? "no error")"
                    )
                    XCTAssertTrue(request.userPrompt.contains(slot.promptText), request.userPrompt)
                    try await fixture.waitFor("\(detachment): the follow-up to be all that still holds the tab") {
                        fixture.operationToken(slot)?.isHeldByFollowUpOnly == true
                    }
                    XCTAssertEqual(fixture.operationToken(slot)?.id, runID)
                    let detached = try XCTUnwrap(fixture.session(slot))
                    let detachedFollowUp = try XCTUnwrap(detached.backgroundPlanTask)
                    let followUpChatID = try XCTUnwrap(detached.followUpOracleSessionID, "The follow-up had created its chat")
                    XCTAssertTrue(oracle.isSessionStreaming(followUpChatID))
                    let followUpQueryID = try XCTUnwrap(oracle.activeQueryId(for: followUpChatID))
                    let followUpEnded = FollowUpEnd()
                    Task { @MainActor in
                        await detachedFollowUp.value
                        followUpEnded.hasHappened = true
                    }

                    switch detachment {
                    case .workspaceSwitch:
                        let elsewhere = manager.createWorkspace(
                            name: "Context Builder runs, other workspace",
                            repoPaths: [fixture.rootURL.path],
                            ephemeral: true
                        )
                        cleanup.add { manager.workspaces.removeAll { $0.id == elsewhere.id } }
                        let unasked = await manager.switchWorkspace(
                            to: elsewhere,
                            saveState: false,
                            reason: "ContextBuilderTabAdmissionTests"
                        )
                        XCTAssertEqual(unasked, .blocked("Cannot switch workspaces while chat is busy."))
                        XCTAssertTrue(fixture.session(slot) === detached)
                        XCTAssertFalse(followUpEnded.hasHappened)

                        let userSwitch = Task { @MainActor in
                            await manager.requestWorkspaceSwitch(
                                to: elsewhere,
                                saveState: false,
                                reason: "ContextBuilderTabAdmissionTests"
                            )
                        }
                        cleanup.add {
                            userSwitch.cancel()
                            _ = await userSwitch.value
                        }
                        try await fixture.waitFor("the switch to ask about what is running") {
                            manager.pendingSwitchConfirmation != nil
                        }
                        let confirmation = try XCTUnwrap(manager.pendingSwitchConfirmation)
                        manager.resolveSwitchConfirmation(id: confirmation.id, allow: true)
                        let switched = await userSwitch.value
                        XCTAssertEqual(switched, .switched)
                        // Context Builder handles a switch in a later turn of the main actor.
                        try await fixture.waitFor("the switch to drop the tab's session") {
                            fixture.session(slot) == nil
                        }
                        let origin = try XCTUnwrap(manager.workspaces.first { $0.id == fixture.workspaceID })
                        let returned = await manager.switchWorkspace(
                            to: origin,
                            saveState: false,
                            reason: "ContextBuilderTabAdmissionTests"
                        )
                        XCTAssertEqual(returned, .switched)
                        try await fixture.waitFor("the tab to be shown again") {
                            viewModel.currentTabID == slot.tabID && fixture.session(slot) != nil
                        }
                    case .tabCloseAndRestore:
                        _ = await promptManager.stashComposeTabs(withIDs: [slot.tabID])
                        XCTAssertNil(fixture.storedTab(slot), "The tab closed")
                        let restored = await promptManager.restoreStashedComposeTab(containingTabID: slot.tabID)
                        XCTAssertEqual(restored?.id, slot.tabID)
                    }
                    try await fixture.waitFor("\(detachment): the tab to be shown again with a chat") {
                        guard manager.activeWorkspaceID == fixture.workspaceID,
                              let chatID = manager.activeChatSessionID(forTabID: slot.tabID)
                        else { return false }
                        return oracle.sessions.contains { $0.id == chatID }
                    }

                    // The tab's next holder, with an answer of its own under way.
                    let claim = try viewModel.beginMCPControlledRun(
                        forTabID: slot.tabID,
                        workspaceID: fixture.workspaceID,
                        responseType: "question",
                        planModelName: nil
                    )
                    let holder = try XCTUnwrap(fixture.session(slot))
                    XCTAssertFalse(holder === detached)
                    viewModel.setBackgroundPlanGenerating(true, forTabID: slot.tabID)
                    viewModel.setBackgroundPlanResponseText(Self.followUpAnswer, forTabID: slot.tabID)
                    let holderState = TabState(fixture, slot)
                    let storedChatID = manager.activeChatSessionID(forTabID: slot.tabID)
                    let chats = oracle.sessions.map(\.id)
                    let storedBefore = try XCTUnwrap(fixture.storedTab(slot))

                    XCTAssertFalse(oracle.isSessionStreaming(followUpChatID), "\(detachment): the follow-up's stream was stopped")
                    try await fixture.waitFor("\(detachment): the detached follow-up to end without its reply") {
                        followUpEnded.hasHappened
                    }

                    // The late reply is synchronized on two observed points: the Oracle's
                    // provider-stop observation and, when the query's message isn't already final,
                    // the query's finalization. The tab is read after them to check the ownership
                    // guard of the follow-up's progress callback. Other work the Oracle does with
                    // the reply may still be under way.
                    let lateReply = QueryActivity()
                    let observerID = oracle.addMessageLifecycleActivityObserver(for: followUpQueryID) { event in
                        lateReply.kinds.append(event.kind)
                    }
                    cleanup.add {
                        oracle.removeMessageLifecycleActivityObserver(for: followUpQueryID, observerID: observerID)
                    }
                    let finalizesLateReply = oracle.getChatMessage(withId: followUpQueryID)?.isFinalized != true
                    await request.complete(with: Self.lateFollowUpAnswer)
                    try await fixture.waitFor("\(detachment): the Oracle to take the late reply") {
                        lateReply.kinds.contains(.providerStopObserved)
                    }
                    if finalizesLateReply {
                        try await fixture.waitFor("\(detachment): the Oracle to finalize the cancelled query") {
                            lateReply.kinds.contains(.finalizationCompleted)
                        }
                    }

                    XCTAssertTrue(fixture.session(slot) === holder, "\(detachment)")
                    XCTAssertEqual(TabState(fixture, slot), holderState, "\(detachment)")
                    XCTAssertEqual(holder.operationToken?.id, claim, "\(detachment)")
                    XCTAssertTrue(holder.isBackgroundPlanGenerating, "\(detachment)")
                    XCTAssertEqual(holder.backgroundPlanResponseText, Self.followUpAnswer, "\(detachment)")
                    XCTAssertNil(holder.backgroundPlanError, "\(detachment)")
                    XCTAssertNil(holder.generatedAnswerRoute, "\(detachment)")
                    XCTAssertNil(holder.followUpOracleSessionID, "\(detachment)")
                    XCTAssertEqual(manager.activeChatSessionID(forTabID: slot.tabID), storedChatID, "\(detachment)")
                    XCTAssertEqual(oracle.sessions.map(\.id), chats, "\(detachment): no chat was created")
                    // The stored tab also holds file-tree state, which a switch back goes on updating.
                    let stored = try XCTUnwrap(fixture.storedTab(slot))
                    XCTAssertEqual(stored.promptText, storedBefore.promptText, "\(detachment)")
                    XCTAssertEqual(stored.selection, storedBefore.selection, "\(detachment)")
                    XCTAssertEqual(stored.contextBuilder, storedBefore.contextBuilder, "\(detachment)")
                    XCTAssertFalse(oracle.sessions.contains { oracle.isSessionPinnedForTesting($0.id) }, "\(detachment)")
                    let requestCount = await fixture.oracleReplies.requests.count
                    XCTAssertEqual(requestCount, 1, "\(detachment): the follow-up sent nothing more")
                    await viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: claim)
                }
            }
        }

        /// A stored tab that two windows show admits one Context Builder operation between them.
        /// While one window works in the tab, the other's MCP claim on it is the tab-busy error and
        /// its Run press starts nothing and says why in the log its panel shows. Neither changes the
        /// holder, and the refused window is left without a claim or a run. Each window holds once,
        /// so the rule is shown in both directions. The workspace's other tabs stay free. A tab is
        /// free again once its holder releases it.
        func testSameTabInSecondWindowRefuses() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let second = try await first.openPeerWindow(cleanup: cleanup)
                XCTAssertFalse(first.window === second.window)
                XCTAssertEqual(second.storedTabIDs, first.storedTabIDs)
                let tab = first.slots[0]
                let otherTab = first.slots[1]
                var providers: [ContextBuilderUnroutedProvider] = []
                for fixture in [first, second] {
                    fixture.providerScript = { _ in
                        let provider = ContextBuilderUnroutedProvider()
                        providers.append(provider)
                        return provider
                    }
                    fixture.releaseOnSettle {
                        for provider in providers {
                            await provider.finish()
                        }
                    }
                }

                let pressed = await first.pressRun(on: tab)
                let runID = try XCTUnwrap(pressed)
                try await first.waitFor("the first window's provider to start its turn") {
                    providers.first?.runID == runID
                }
                await assertRefused(tab, in: second, heldBy: first)

                let claim = try second.viewModel.beginMCPControlledRun(
                    forTabID: otherTab.tabID,
                    workspaceID: second.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                XCTAssertEqual(
                    second.operationToken(otherTab),
                    OperationToken(id: claim, origin: .mcp, workspaceID: second.workspaceID)
                )
                XCTAssertEqual(first.activeRunID(tab), runID)
                await assertRefused(otherTab, in: first, heldBy: second)

                await second.viewModel.clearMCPControlledRun(forTabID: otherTab.tabID, controlToken: claim)
                try await assertClaimable(otherTab, in: first)
                await providers[0].finish()
                try await first.waitForRelease(of: tab)
                try await assertClaimable(tab, in: second)
            }
        }

        /// A window closes while its run is committing: the commit is claimed and captured, and
        /// nothing is written yet. From the moment the window leaves the open windows the other
        /// window that shows the tab is refused it, because that commit could still write, and it
        /// stays free to use the workspace's other tabs. The close gives the commit its grace and
        /// then retires the run. The tab is free for the other window from then on, and the
        /// commit, still held, writes nothing when it goes on.
        func testClosingWindowKeepsItsTabFromAnotherWindowUntilItsCloseRetiresItsRun() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let closing = try await first.openPeerWindow(cleanup: cleanup)
                let tab = first.slots[0]
                let observed = CloseObservation()
                let (run, beforeWrite) = try await Self.holdCommitBeforeItsWrite(on: tab, in: closing, observed: observed)

                closing.window.beginClose()
                WindowStatesManager.shared.unregisterWindowState(closing.window)
                XCTAssertFalse(WindowStatesManager.shared.allWindows.contains { $0 === closing.window })
                await assertRefused(tab, in: first, heldBy: closing)
                try await assertClaimable(first.slots[1], in: first)

                Task { @MainActor in
                    await closing.window.tearDown()
                    observed.returned = true
                }
                try await closing.waitFor("the window's close to return with the commit still held") {
                    observed.returned
                }
                let completion = try await closing.completion(of: run)
                XCTAssertEqual(completion.terminalDisposition, .cancelled)
                XCTAssertNil(completion.committedTab)
                try await closing.waitForRelease(of: tab)
                try await assertClaimable(tab, in: first)

                await beforeWrite.open()
                try await closing.waitFor("the run to leave its commit") { observed.runLeftItsCommit }
                XCTAssertEqual(closing.storedTab(tab)?.promptText, "")
            }
        }

        /// The same close with a commit that gets through within the close's grace. The other
        /// window is refused the tab while the closing window's teardown is waiting on that
        /// commit, the commit then lands in the closing window's stored tab, and the tab is free
        /// once the close has finished.
        func testClosingWindowKeepsItsTabFromAnotherWindowWhileItsCommitLands() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let closing = try await first.openPeerWindow(cleanup: cleanup)
                let tab = first.slots[0]
                let observed = CloseObservation()
                let viewModel = closing.viewModel
                cleanup.add { viewModel.setCloseSettlementGraceForTesting(500_000_000) }
                viewModel.setCloseSettlementGraceForTesting(600 * NSEC_PER_SEC)
                let (run, beforeWrite) = try await Self.holdCommitBeforeItsWrite(on: tab, in: closing, observed: observed)

                closing.window.beginClose()
                WindowStatesManager.shared.unregisterWindowState(closing.window)
                Task { @MainActor in
                    await closing.window.tearDown()
                    observed.returned = true
                }
                try await closing.waitFor("the closing window's teardown to ask the run to end") {
                    closing.session(tab)?.isCancelling == true
                }
                XCTAssertFalse(observed.returned)
                await assertRefused(tab, in: first, heldBy: closing)
                try await assertClaimable(first.slots[1], in: first)
                XCTAssertEqual(closing.storedTab(tab)?.promptText, "")

                await beforeWrite.open()
                let completion = try await closing.completion(of: run)
                XCTAssertEqual(completion.terminalDisposition, .cancelled)
                XCTAssertEqual(completion.committedTab?.tab.promptText, tab.agentOutput)
                XCTAssertEqual(closing.storedTab(tab)?.promptText, tab.agentOutput)

                try await closing.waitFor("the window's close to return") { observed.returned }
                try await closing.waitForRelease(of: tab)
                try await assertClaimable(tab, in: first)
            }
        }

        /// A panel run's claim is released by the run's own task. The other window is refused the
        /// tab from the moment the close begins, while the closing window is still among the open
        /// windows. A close stops waiting for a task that outlasts its grace, and the claim is
        /// still there: the other window is refused the tab after the close has returned, for as
        /// long as that task has not ended.
        func testClosedWindowWhoseRunTaskHasNotEndedKeepsItsTabFromAnotherWindow() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let closing = try await first.openPeerWindow(cleanup: cleanup)
                let tab = first.slots[0]
                let execution = ContextBuilderTestGate()
                let viewModel = closing.viewModel
                cleanup.add {
                    viewModel.installRunTestHooks(nil)
                    viewModel.setCloseSettlementGraceForTesting(500_000_000)
                }
                closing.releaseOnSettle { await execution.open() }
                viewModel.setCloseSettlementGraceForTesting(1)
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: { _, _ in await execution.wait() },
                    providerEventDisposition: nil,
                    teardownCompleted: nil
                ))
                closing.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }

                let pressed = await closing.pressRun(on: tab)
                let runID = try XCTUnwrap(pressed)
                try await closing.waitFor("the run's execution to be held") { await execution.entered }
                let held = OperationToken(id: runID, origin: .ui, workspaceID: closing.workspaceID)
                XCTAssertEqual(closing.operationToken(tab), held)

                closing.window.beginClose()
                XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === closing.window })
                await assertRefused(tab, in: first, heldBy: closing)
                WindowStatesManager.shared.unregisterWindowState(closing.window)
                let observed = CloseObservation()
                let teardown = Task { @MainActor in
                    await closing.window.tearDown()
                    observed.returned = true
                }
                cleanup.add {
                    await execution.open()
                    await teardown.value
                }
                try await closing.waitFor("the window's close to return with the run's task still held") {
                    observed.returned
                }
                XCTAssertNil(closing.activeRunID(tab))
                XCTAssertEqual(closing.operationToken(tab), held)
                await assertRefused(tab, in: first, heldBy: closing)

                await execution.open()
                try await closing.waitForRelease(of: tab)
                try await assertClaimable(tab, in: first)
            }
        }

        /// A claim refused because another window holds the tab changes nothing in the asking
        /// window. Here that window has never shown the tab and has no session for it, and the
        /// refused claim makes none.
        func testClaimRefusedForTabHeldInAnotherWindowMakesNoSession() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let second = try await first.openPeerWindow(cleanup: cleanup)
                let tab = first.slots[1]
                let claim = try second.viewModel.beginMCPControlledRun(
                    forTabID: tab.tabID,
                    workspaceID: second.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                let held = TabState(second, tab)
                XCTAssertNil(first.session(tab))
                let sessions = first.viewModel.sessions.mapValues(ObjectIdentifier.init)
                let heldAgainstNewRun = first.viewModel.tabsHeldAgainstNewRun

                XCTAssertThrowsError(
                    try first.viewModel.beginMCPControlledRun(
                        forTabID: tab.tabID,
                        workspaceID: first.workspaceID,
                        responseType: nil,
                        planModelName: nil
                    )
                ) { Self.assertTabBusy($0) }
                XCTAssertEqual(first.viewModel.sessions.mapValues(ObjectIdentifier.init), sessions)
                XCTAssertNil(first.activeRunID(tab))
                XCTAssertEqual(first.viewModel.tabsHeldAgainstNewRun, heldAgainstNewRun)
                XCTAssertEqual(TabState(second, tab), held)

                await second.viewModel.clearMCPControlledRun(forTabID: tab.tabID, controlToken: claim)
                try await assertClaimable(tab, in: first)
            }
        }

        /// A UI claim that only its follow-up still holds lets its own window's Run take the tab
        /// over, which is why that window does not count the tab as held against a new run. No
        /// other window can take the follow-up over, so there the tab is occupied until the
        /// follow-up settles.
        func testFollowUpOnlyHolderInAnotherWindowRefuses() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let second = try await first.openPeerWindow(cleanup: cleanup)
                let tab = first.slots[0]
                first.enableAutomaticFollowUp(cleanup: cleanup)
                let followUps = Self.holdUIFollowUps(on: first, cleanup: cleanup)

                let pressed = await first.pressRun(on: tab)
                let runID = try XCTUnwrap(pressed)
                try await first.waitFor("the follow-up to be all that still holds the tab") {
                    followUps.entryCount == 1 && first.operationToken(tab)?.isHeldByFollowUpOnly == true
                }
                XCTAssertEqual(first.operationToken(tab)?.id, runID)
                XCTAssertNil(first.activeRunID(tab))
                XCTAssertFalse(first.viewModel.tabsHeldAgainstNewRun.contains(tab.tabID))

                await assertRefused(tab, in: second, heldBy: first)
                XCTAssertEqual(first.session(tab)?.isBackgroundPlanGenerating, true)

                followUps.open()
                try await first.waitForRelease(of: tab)
                try await assertClaimable(tab, in: second)
            }
        }

        /// An MCP claim outlives its window's switch to another workspace, and it still occupies
        /// the tab of the workspace it was made for. The window that shows that workspace is
        /// refused until the claim is released, although the holder's window now shows another.
        func testHolderWhoseWindowSwitchedWorkspaceStillRefusesAnotherWindow() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let second = try await first.openPeerWindow(cleanup: cleanup)
                let tab = first.slots[0]
                let unclaimed = first.slots[1]
                let manager = second.window.workspaceManager

                let claim = try second.viewModel.beginMCPControlledRun(
                    forTabID: tab.tabID,
                    workspaceID: second.workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                // The switch drops every session that holds no MCP claim, which shows when the
                // view model has handled it.
                await second.window.promptManager.switchComposeTab(unclaimed.tabID)
                second.viewModel.refreshActiveSessionBindings()
                XCTAssertNotNil(second.session(unclaimed))

                let elsewhereID = await Self.showAnotherWorkspace(in: second)
                try await second.waitFor("the second window's Context Builder to follow the switch") {
                    second.session(unclaimed) == nil
                }
                XCTAssertEqual(manager.activeWorkspaceID, elsewhereID)
                XCTAssertEqual(
                    second.operationToken(tab),
                    OperationToken(id: claim, origin: .mcp, workspaceID: second.workspaceID)
                )

                await assertRefused(tab, in: first, heldBy: second)

                await second.viewModel.clearMCPControlledRun(forTabID: tab.tabID, controlToken: claim)
                try await assertClaimable(tab, in: first)
            }
        }

        /// A panel run that its window's workspace switch cancelled keeps its claim until its task
        /// has ended, on the session that took the place of the one the switch dropped. That claim
        /// still occupies the tab of the workspace the run was admitted in, so the window that
        /// shows that workspace is refused until the task ends.
        func testPanelClaimMovedByItsWindowsWorkspaceSwitchStillRefusesAnotherWindow() async throws {
            try await ContextBuilderRunFixture.withFixture { first, cleanup in
                let second = try await first.openPeerWindow(cleanup: cleanup)
                let tab = first.slots[0]
                let execution = ContextBuilderTestGate()
                let viewModel = second.viewModel
                cleanup.add { viewModel.installRunTestHooks(nil) }
                second.releaseOnSettle { await execution.open() }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: { _, _ in await execution.wait() },
                    providerEventDisposition: nil,
                    teardownCompleted: nil
                ))
                second.providerScript = { _ in ContextBuilderUnroutedProvider(events: ["Looking around"]) }

                let pressed = await second.pressRun(on: tab)
                let runID = try XCTUnwrap(pressed)
                try await second.waitFor("the run's execution to be held") { await execution.entered }
                let admitted = OperationToken(id: runID, origin: .ui, workspaceID: second.workspaceID)
                let droppedSession = try XCTUnwrap(second.session(tab))
                XCTAssertEqual(droppedSession.operationToken, admitted)

                let elsewhereID = await Self.showAnotherWorkspace(in: second)
                try await second.waitFor("the second window's Context Builder to follow the switch") {
                    second.session(tab).map { $0 !== droppedSession } == true
                }
                XCTAssertEqual(second.window.workspaceManager.activeWorkspaceID, elsewhereID)
                XCTAssertEqual(second.operationToken(tab), admitted)
                XCTAssertNil(droppedSession.operationToken)
                XCTAssertNil(second.activeRunID(tab))

                await assertRefused(tab, in: first, heldBy: second)

                await execution.open()
                try await second.waitForRelease(of: tab)
                try await assertClaimable(tab, in: first)
            }
        }

        // MARK: Support

        private static let tabBusyMessage = "Context Builder is already running for this tab."
        private static let followUpAnswer = "Follow-up answer"
        private static let lateFollowUpAnswer = "Answer of a follow-up that outlived its session"

        @MainActor
        private final class CloseObservation {
            var returned = false
            var runLeftItsCommit = false
        }

        /// Switches `fixture`'s window to a workspace of its own, which leaves the fixture's
        /// workspace among those its workspace manager holds. Returns the new workspace's ID.
        private static func showAnotherWorkspace(in fixture: ContextBuilderRunFixture) async -> UUID {
            var elsewhere = WorkspaceModel(name: "Elsewhere", repoPaths: [])
            elsewhere.isEphemeral = true
            let elsewhereTab = ComposeTabState(name: "elsewhere")
            elsewhere.composeTabs = [elsewhereTab]
            elsewhere.activeComposeTabID = elsewhereTab.id
            let manager = fixture.window.workspaceManager
            manager.workspaces.append(elsewhere)
            await manager.switchWorkspace(
                to: elsewhere,
                saveState: false,
                reason: "ContextBuilderTabAdmissionTests"
            )
            return elsewhere.id
        }

        /// Starts an MCP run on `slot` and holds it at its last step before the tab is written:
        /// the commit is claimed and captured and has changed nothing. The run's child leaves the
        /// prompt empty, so the commit is what fills it, from the run's output, and the stored
        /// prompt shows whether the commit wrote the tab.
        private static func holdCommitBeforeItsWrite(
            on slot: ContextBuilderRunFixture.TabSlot,
            in fixture: ContextBuilderRunFixture,
            observed: CloseObservation
        ) async throws -> (run: ContextBuilderRunFixture.MCPRun, beforeWrite: ContextBuilderTestGate) {
            let beforeWrite = ContextBuilderTestGate()
            fixture.childWrites = .init(setsPrompt: false, setsSelection: true, repliesWithOutput: true)
            fixture.releaseOnSettle { await beforeWrite.open() }
            let run = fixture.startMCPRun(on: slot, progressReporter: { phase in
                switch phase {
                case .tabContextCommit:
                    await beforeWrite.wait()
                case .runFinalization:
                    observed.runLeftItsCommit = true
                default:
                    break
                }
            })
            try await fixture.waitFor("the run to reach its last step before the tab is written") {
                await beforeWrite.entered
            }
            XCTAssertEqual(fixture.storedTab(slot)?.promptText, "")
            return (run, beforeWrite)
        }

        /// How a UI follow-up loses the session it was started for.
        private enum FollowUpDetachment: CaseIterable {
            case workspaceSwitch
            case tabCloseAndRestore
        }

        /// Whether a follow-up's task has ended.
        @MainActor
        private final class FollowUpEnd {
            var hasHappened = false
        }

        /// What the Oracle reported for one query, in order.
        @MainActor
        private final class QueryActivity {
            var kinds: [OracleMessageLifecycleActivityEvent.Kind] = []
        }

        /// What a refused attempt must leave as it found it.
        private struct TabState: Equatable {
            let activeRunID: UUID?
            let operationToken: OperationToken?
            let runState: AgentRunState?
            let isBusy: Bool?
            let logEntryIDs: [UUID]?
            let logMessages: [String]?
            let toolCallCount: Int?

            @MainActor
            init(_ fixture: ContextBuilderRunFixture, _ slot: ContextBuilderRunFixture.TabSlot) {
                let session = fixture.session(slot)
                activeRunID = fixture.activeRunID(slot)
                operationToken = session?.operationToken
                runState = session?.agentRunState
                isBusy = session?.isAgentBusy
                logEntryIDs = session?.agentLog.map(\.id)
                logMessages = session?.agentLog.map(\.message)
                toolCallCount = session?.toolCallCount
            }
        }

        private static func assertTabBusy(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
            let refusal = error as NSError
            XCTAssertEqual(refusal.domain, "DiscoverAgent", file: file, line: line)
            XCTAssertEqual(refusal.code, 2, file: file, line: line)
            XCTAssertEqual(refusal.localizedDescription, tabBusyMessage, file: file, line: line)
        }

        /// `asking` cannot take `slot` while `holder`, another window, works in it. Its MCP claim
        /// is the tab-busy error and changes neither window. Its Run press starts nothing, leaves
        /// the holder as it was, and adds the reason to the log the asking window's panel shows.
        /// Each attempt is compared in the main-actor turn it ran in.
        private func assertRefused(
            _ slot: ContextBuilderRunFixture.TabSlot,
            in asking: ContextBuilderRunFixture,
            heldBy holder: ContextBuilderRunFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            await asking.window.promptManager.switchComposeTab(slot.tabID)
            asking.viewModel.refreshActiveSessionBindings()
            let held = TabState(holder, slot)
            let before = TabState(asking, slot)
            let providerRequests = asking.providerRequests.count

            XCTAssertThrowsError(
                try asking.viewModel.beginMCPControlledRun(
                    forTabID: slot.tabID,
                    workspaceID: asking.workspaceID,
                    responseType: nil,
                    planModelName: nil
                ),
                file: file,
                line: line
            ) { Self.assertTabBusy($0, file: file, line: line) }
            XCTAssertEqual(TabState(holder, slot), held, file: file, line: line)
            XCTAssertEqual(TabState(asking, slot), before, file: file, line: line)

            asking.viewModel.runContextBuilderAgent()
            XCTAssertEqual(TabState(holder, slot), held, file: file, line: line)
            let refused = TabState(asking, slot)
            XCTAssertNil(refused.operationToken, file: file, line: line)
            XCTAssertNil(refused.activeRunID, file: file, line: line)
            XCTAssertEqual(refused.isBusy, false, file: file, line: line)
            XCTAssertEqual(refused.toolCallCount, before.toolCallCount, file: file, line: line)
            XCTAssertEqual(refused.runState, .failed(Self.tabBusyMessage), file: file, line: line)
            XCTAssertEqual(
                refused.logMessages,
                (before.logMessages ?? []) + [Self.tabBusyMessage],
                file: file,
                line: line
            )
            XCTAssertEqual(asking.providerRequests.count, providerRequests, file: file, line: line)
            XCTAssertFalse(asking.viewModel.tabsHeldAgainstNewRun.contains(slot.tabID), file: file, line: line)
            XCTAssertEqual(asking.viewModel.agentLog.last?.message, Self.tabBusyMessage, file: file, line: line)
            XCTAssertEqual(asking.viewModel.agentLog.last?.type, .system, file: file, line: line)
            XCTAssertEqual(asking.viewModel.agentRunState, .failed(Self.tabBusyMessage), file: file, line: line)
        }

        /// The tab is free: a new claim succeeds and is released again.
        private func assertClaimable(
            _ slot: ContextBuilderRunFixture.TabSlot,
            in fixture: ContextBuilderRunFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            XCTAssertNil(fixture.operationToken(slot), file: file, line: line)
            let token = try fixture.viewModel.beginMCPControlledRun(
                forTabID: slot.tabID,
                workspaceID: fixture.workspaceID,
                responseType: nil,
                planModelName: nil
            )
            await fixture.viewModel.clearMCPControlledRun(forTabID: slot.tabID, controlToken: token)
            XCTAssertNil(fixture.operationToken(slot), file: file, line: line)
        }

        private func assertNoOwnershipLeft(
            on slot: ContextBuilderRunFixture.TabSlot,
            in fixture: ContextBuilderRunFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let session = fixture.session(slot)
            XCTAssertNil(session?.operationToken, file: file, line: line)
            XCTAssertNil(session?.activeRunOwnership, file: file, line: line)
            XCTAssertEqual(session?.isAgentBusy, false, file: file, line: line)
            XCTAssertEqual(session?.agentRunState.isRunning, false, file: file, line: line)
            XCTAssertNil(fixture.activeRunID(slot), file: file, line: line)
            XCTAssertFalse(
                fixture.viewModel.tabsWithActiveContextBuilderRun.contains(slot.tabID),
                file: file,
                line: line
            )
        }

        private static func systemWorkspaceAuthority(
            from authority: ContextBuilderResolvedRunAuthority
        ) -> ContextBuilderResolvedRunAuthority {
            let configuration = authority.configuration
            return ContextBuilderResolvedRunAuthority(
                configuration: ContextBuilderMCPRunConfiguration(
                    identity: configuration.identity,
                    nestedTabContext: configuration.nestedTabContext,
                    providerWorkspacePath: configuration.providerWorkspacePath,
                    runBehavior: configuration.runBehavior,
                    responseType: configuration.responseType,
                    planningModelRaw: configuration.planningModelRaw,
                    isSystemWorkspace: true
                ),
                agentKind: authority.agentKind,
                modelRaw: authority.modelRaw,
                modelParameterSelections: authority.modelParameterSelections
            )
        }

        /// Replaces the Oracle generation of UI follow-ups with one that waits at `started` to be
        /// cancelled and then holds its unwinding at `unwinding`, which cancellation cannot open.
        /// With `execution`, a run's execution is also held there while it processes a provider
        /// event, which is before it can clear its routing policy and settle its claim on the tab.
        private static func holdUIFollowUpThroughItsCancellation(
            on fixture: ContextBuilderRunFixture,
            cleanup: FixtureCleanup,
            holdingRunExecutionAt execution: ContextBuilderTestGate? = nil
        ) -> (started: ContextBuilderCancellableTestGate, unwinding: ContextBuilderTestGate) {
            let started = ContextBuilderCancellableTestGate()
            let unwinding = ContextBuilderTestGate()
            let viewModel = fixture.viewModel
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle {
                started.open()
                await unwinding.open()
            }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: execution.map { execution in { _, _ in await execution.wait() } },
                providerEventDisposition: nil,
                teardownCompleted: nil,
                runUIFollowUp: { _, _ in
                    do {
                        try await started.wait()
                    } catch {
                        await unwinding.wait()
                        throw error
                    }
                    throw CancellationError()
                }
            ))
            return (started, unwinding)
        }

        /// Replaces the Oracle generation of UI follow-ups with one that waits on the returned gate
        /// and still ends when its follow-up is cancelled.
        private static func holdUIFollowUps(
            on fixture: ContextBuilderRunFixture,
            cleanup: FixtureCleanup
        ) -> ContextBuilderCancellableTestGate {
            let gate = ContextBuilderCancellableTestGate()
            let viewModel = fixture.viewModel
            cleanup.add { viewModel.installRunTestHooks(nil) }
            fixture.releaseOnSettle { gate.open() }
            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                runUIFollowUp: { _, mode in
                    try await gate.wait()
                    return ChatSendReply(
                        chatId: UUID(),
                        shortId: "follow-up",
                        mode: mode.mcpModeName,
                        response: followUpAnswer,
                        errors: nil
                    )
                }
            ))
            return gate
        }
    }
#endif
