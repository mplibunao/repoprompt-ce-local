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
                Self.enableAutomaticFollowUp(cleanup: cleanup)
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
                Self.enableAutomaticFollowUp(cleanup: cleanup)
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
                Self.enableAutomaticFollowUp(cleanup: cleanup)
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

        // MARK: Support

        private static let followUpAnswer = "Follow-up answer"

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
            XCTAssertEqual(
                refusal.localizedDescription,
                "Context Builder is already running for this tab.",
                file: file,
                line: line
            )
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

        private static func enableAutomaticFollowUp(cleanup: FixtureCleanup) {
            let store = GlobalSettingsStore.shared
            let previous = store.contextBuilderBehaviorSettings()
            cleanup.add { store.setContextBuilderBehaviorSettings(previous, commit: false) }
            var settings = previous
            settings.followUpAnalysisEnabled = true
            store.setContextBuilderBehaviorSettings(settings, commit: false)
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
