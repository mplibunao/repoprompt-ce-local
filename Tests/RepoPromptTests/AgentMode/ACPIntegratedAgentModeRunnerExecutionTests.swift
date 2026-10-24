@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class ACPIntegratedAgentModeRunnerExecutionTests: XCTestCase {
    func testCompletedTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .completed,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.completed(assistantText: nil))
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.completed)]
        )
    }

    func testCancelledTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .cancelled,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.cancelled())
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.cancelled)]
        )
    }

    func testFailedTerminalPreservesProviderErrorText() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: "ACP provider refused the turn."
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.failed(assistantText: "ACP provider refused the turn."))
        )
        XCTAssertEqual(classification.errorText, "ACP provider refused the turn.")
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testFailedTerminalPreservesAbsentProviderErrorTextForSettlement() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: nil
        )

        guard case let .terminal(outcome) = classification.result else {
            return XCTFail("Expected terminal classification")
        }
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testSupersededExecutionRemainsNonterminal() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientSupersession()

        XCTAssertEqual(classification.result, .superseded)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .executionSuperseded]
        )
    }

    func testConfigurationSequenceStopsAfterOwnershipChangesDuringAwaitedStep() async throws {
        var isCurrent = true
        var providerMutations: [String] = []

        let completed = try await ACPIntegratedAgentModeRunner.testPerformConfigurationSequenceIfCurrent(
            isCurrent: { isCurrent },
            operations: [
                {
                    providerMutations.append("model")
                    await Task.yield()
                    isCurrent = false
                },
                {
                    providerMutations.append("parameters")
                }
            ]
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(providerMutations, ["model"])
    }

    func testModelParameterApplicationAcceptsAppliedAndAlreadyCurrentSelections() throws {
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "high"
        )

        XCTAssertNoThrow(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [selection],
            alreadyCurrent: [],
            skipped: []
        )))
        XCTAssertNoThrow(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [],
            alreadyCurrent: [selection],
            skipped: []
        )))
    }

    func testModelParameterApplicationRejectsStaleUnsupportedSelectionBeforePrompt() {
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .speed,
            configID: "fast",
            valueRaw: "true"
        )

        XCTAssertThrowsError(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [],
            alreadyCurrent: [],
            skipped: [selection]
        ))) { error in
            XCTAssertTrue(error.localizedDescription.contains("stale or unsupported"))
            XCTAssertTrue(error.localizedDescription.contains("fast=true"))
        }
    }

    func testCursorKnownModelPassesReleaseCatalogValidationBeforePrompt() throws {
        let model = try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: "grok-4.6"
        )

        XCTAssertEqual(model, "grok-4.6")
    }

    func testCursorAutoAliasPassesReleaseCatalogValidationBeforePrompt() throws {
        let model = try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: AgentModel.cursorAuto.rawValue
        )

        XCTAssertEqual(model, AgentModel.cursorAuto.rawValue)
    }

    func testCursorUnknownConcreteModelFailsClosedBeforePrompt() {
        XCTAssertThrowsError(try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: "cursor-future-model"
        )) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Expected invalid Cursor model configuration, got \(error)")
            }
            XCTAssertTrue(detail.contains("cursor-future-model"))
            XCTAssertTrue(detail.contains("supported model catalog"))
        }
    }

    #if DEBUG

        // MARK: - Follow-up respawn admission

        // A reused OpenCode session's helper stays connected and routed across turns. Each follow-up
        // turn arms one run-owned policy that admits a helper respawning during the turn; settling
        // the turn removes that policy and keeps the run's route.

        func testOnlyPrePromptRoutedProvidersArmOneFollowUpPolicy() async throws {
            try await withFollowUpRun { run, turns in
                XCTAssertNil(turns.begin(agentKind: .cursor))
                XCTAssertNil(turns.begin(agentKind: .grokBuild))
                XCTAssertEqual(turns.leaseCount, 0, "Prompt-deferred providers route each turn through their own deferred lease.")

                let turn = try XCTUnwrap(turns.begin())
                XCTAssertEqual(turns.leaseCount, 1)
                let armed = await turn.arm()
                XCTAssertTrue(armed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 1)
                await run.assertOwner(run.c1)
            }
        }

        func testRespawnedHelperConsumesFollowUpPolicyAndIsAdmitted() async throws {
            try await withFollowUpRun { run, turns in
                let turn = try XCTUnwrap(turns.begin())
                let armed = await turn.arm()
                XCTAssertTrue(armed)

                let respawn = try await run.handshake(run.c4, sessionToken: run.c4Token)
                XCTAssertNil(respawn.error)
                await run.assertOwner(run.c4)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0, "The respawned helper consumes the turn's one-shot policy.")

                await turn.settle(.completed)
                await run.assertOwner(run.c4)
            }
        }

        func testRepeatedFollowUpTurnsKeepEstablishedRouteAndToolTracking() async throws {
            try await withFollowUpRun { run, turns in
                for terminalState in [AgentSessionRunState.completed, .failed, .completed] {
                    let turn = try XCTUnwrap(turns.begin())
                    let armed = await turn.arm()
                    XCTAssertTrue(armed)
                    await turn.settle(terminalState)

                    let pending = await run.pendingPolicyCount()
                    XCTAssertEqual(pending, 0, "A \(terminalState) turn removes its unused policy.")
                    await run.assertOwner(run.c1)
                    let trackedRunID = await run.manager.runIDForConnection(run.c1)
                    XCTAssertEqual(trackedRunID, run.runID, "Tool tracking attributes the helper's calls to its run.")
                }
            }
        }

        func testSettledTurnsUnusedPolicyDoesNotBlockPeerSameTokenReconnect() async throws {
            try await withFollowUpRun { run, turns in
                let peer = try await run.establishPeerRun()
                let turn = try XCTUnwrap(turns.begin())
                _ = await turn.arm()
                await turn.settle(.completed)

                let reconnect = await Self.reconnect(peer, in: run)
                XCTAssertEqual(reconnect, "fallback")
                let peerRunID = await run.manager.runIDForConnection(peer.reconnectID)
                XCTAssertEqual(peerRunID, peer.runID)
                await run.assertOwner(run.c1)
            }
        }

        func testPeerSameTokenReconnectDuringFollowUpTurnKeepsItsOwnRun() async throws {
            try await withFollowUpRun { run, turns in
                let peer = try await run.establishPeerRun()
                let turn = try XCTUnwrap(turns.begin())
                _ = await turn.arm()

                let reconnect = await Self.reconnect(peer, in: run)
                XCTAssertEqual(
                    reconnect,
                    "fallback",
                    "The peer's session ticket routes it to its own run; this run's policy is not its to wait on."
                )
                let peerRunID = await run.manager.runIDForConnection(peer.reconnectID)
                XCTAssertEqual(peerRunID, peer.runID)
            }
        }

        func testLateFailedSettlementLeavesNewerTurnsPolicy() async throws {
            try await withFollowUpRun { run, turns in
                let earlier = try XCTUnwrap(turns.begin())
                _ = await earlier.arm()
                let later = try XCTUnwrap(turns.begin())
                let armed = await later.arm()
                XCTAssertTrue(armed)

                // The terminal barrier starts a queued follow-up before the earlier turn's teardown runs.
                await earlier.settle(.failed)

                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 1, "Only the newer turn's policy remains.")
                await run.assertOwner(run.c1)
                let respawn = await run.apply(run.c4, sessionKey: run.c4Token)
                XCTAssertEqual(respawn.outcome, "applied", "The newer turn still admits a respawned helper.")
            }
        }

        func testLateCancelledSettlementLeavesNewerTurnsRouteAndPolicy() async throws {
            try await withFollowUpRun { run, turns in
                let earlier = try XCTUnwrap(turns.begin())
                _ = await earlier.arm()
                let later = try XCTUnwrap(turns.begin())
                _ = await later.arm()

                await earlier.settle(.cancelled)

                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 1, "Only the newer turn's policy remains.")
                await run.assertOwner(run.c1)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertEqual(trackedRunID, run.runID)
            }
        }

        func testCancelledTurnEndsOnlyItsOwnRunsRouting() async throws {
            try await withFollowUpRun { run, turns in
                let peer = try await run.establishPeerRun()
                let turn = try XCTUnwrap(turns.begin())
                _ = await turn.arm()

                await turn.settle(.cancelled)

                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertNil(trackedRunID, "A cancelled turn ends its run's routing, as a cancelled fresh start does.")
                let peerRunID = await run.manager.runIDForConnection(peer.ownerID)
                XCTAssertEqual(peerRunID, peer.runID)
            }
        }

        func testFailedArmRemovesItsPolicyAndKeepsEstablishedRouteAndToolTracking() async throws {
            try await withFollowUpRun { run, turns in
                await Self.installUnreplacedRunPolicy(in: run)
                let turn = try XCTUnwrap(turns.begin())

                let armed = await turn.arm()

                XCTAssertFalse(armed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0, "A turn that cannot arm its policy leaves none pending.")
                await run.assertOwner(run.c1)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertEqual(trackedRunID, run.runID, "The turn continues on the route its helper already holds.")
            }
        }

        func testCancelledTurnEndsItsRunsRoutingAfterAFailedArm() async throws {
            try await withFollowUpRun { run, turns in
                await Self.installUnreplacedRunPolicy(in: run)
                let turn = try XCTUnwrap(turns.begin())
                let armed = await turn.arm()
                XCTAssertFalse(armed)

                await turn.settle(.cancelled)

                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertNil(trackedRunID, "Cancelling the turn ends its run's routing whether or not its policy was armed.")
            }
        }

        func testSettlementDuringArmKeepsEstablishedRouteAndToolTracking() async throws {
            try await withFollowUpRun { run, turns in
                let turn = try XCTUnwrap(turns.begin())
                let gate = ReadinessTestGate()
                let arming = try await turns.startArming(turn, heldBy: gate)

                // The turn settles after its policy is armed but before acquisition reports success.
                await turn.settle(.failed)
                await gate.release()
                let armed = await arming.value

                XCTAssertFalse(armed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                await run.assertOwner(run.c1)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertEqual(trackedRunID, run.runID)
            }
        }

        func testCancellationDuringArmEndsItsRunsRouting() async throws {
            try await withFollowUpRun { run, turns in
                let turn = try XCTUnwrap(turns.begin())
                let gate = ReadinessTestGate()
                let arming = try await turns.startArming(turn, heldBy: gate)

                arming.cancel()
                await gate.release()
                let armed = await arming.value

                XCTAssertFalse(armed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertNil(trackedRunID, "A turn cancelled while its policy is being armed ends its run's routing.")
            }
        }

        func testCancelledSettlementDuringPolicyInstallationEndsItsRunsRouting() async throws {
            try await withFollowUpRun { run, turns in
                let gate = ReadinessTestGate()
                let turn = try XCTUnwrap(turns.begin(installationHeldBy: gate))
                let arming = try await turns.startArming(turn, heldBy: gate)

                // The settlement's cleanup finds no installed policy to revoke; the installation
                // that completes after it still belongs to a cancelled turn.
                await turn.settle(.cancelled)
                await gate.release()
                let armed = await arming.value

                XCTAssertFalse(armed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertNil(trackedRunID, "A turn cancelled while its policy is being installed ends its run's routing.")
            }
        }

        func testEarlierTurnsAcquisitionEndingAfterItsSettlementLeavesNewerTurnsPolicy() async throws {
            try await withFollowUpRun { run, turns in
                let gate = ReadinessTestGate()
                let earlier = try XCTUnwrap(turns.begin())
                let arming = try await turns.startArming(earlier, heldBy: gate)
                await earlier.settle(.failed)

                let later = try XCTUnwrap(turns.begin())
                let laterArmed = await later.arm()
                XCTAssertTrue(laterArmed)
                let pendingWhileHeld = await run.pendingPolicyCount()
                XCTAssertEqual(pendingWhileHeld, 1)

                await gate.release()
                let earlierArmed = await arming.value

                XCTAssertFalse(earlierArmed)
                await Self.assertNewerTurnAdmitsRespawnedHelper(in: run)
            }
        }

        func testSettlementWaitsForItsTurnsInstallationInFlightAndRemovesItsPolicy() async throws {
            try await withFollowUpRun { run, turns in
                let gate = ReadinessTestGate()
                let earlier = try XCTUnwrap(turns.begin(installationHeldBy: gate))
                let arming = try await turns.startArming(earlier, heldBy: gate)

                let settling = Task { await earlier.settle(.failed) }
                let settlingEvent = await Self.firstEvent(of: settling) { await turns.releaseWaitsForInstallation(of: earlier) }
                XCTAssertEqual(settlingEvent, .waiting, "The settlement waits for the installation its clear has to remove.")

                await gate.release()
                await settling.value
                let pendingAfterSettlement = await run.pendingPolicyCount()
                XCTAssertEqual(pendingAfterSettlement, 0, "The settled turn leaves no policy it installed pending.")

                let later = try XCTUnwrap(turns.begin())
                let laterArmed = await later.arm()
                XCTAssertTrue(laterArmed)
                let pendingAfterLaterArmed = await run.pendingPolicyCount()
                XCTAssertEqual(pendingAfterLaterArmed, 1)
                let earlierArmed = await arming.value

                XCTAssertFalse(earlierArmed)
                await Self.assertNewerTurnAdmitsRespawnedHelper(in: run)
            }
        }

        /// The newer turn's arming settles the earlier turn first, so it installs only after the
        /// earlier installation has landed and been cleared, and the run's policy state stays the
        /// newer turn's.
        func testNewerTurnArmsAfterAnEarlierInstallationInFlightAndKeepsItsPolicyState() async throws {
            try await withFollowUpRun { run, turns in
                let gate = ReadinessTestGate()
                let earlier = try XCTUnwrap(turns.begin(installationHeldBy: gate))
                let earlierArming = try await turns.startArming(earlier, heldBy: gate)
                let later = try XCTUnwrap(turns.begin(taskLabelKind: .explore))

                let laterArming = Task { await later.arm() }
                let laterArmingEvent = await Self.firstEvent(of: laterArming) { await turns.releaseWaitsForInstallation(of: earlier) }
                XCTAssertEqual(laterArmingEvent, .waiting, "The newer turn's arming waits for the earlier installation in flight.")

                await gate.release()
                let laterArmed = await laterArming.value
                let earlierArmed = await earlierArming.value

                XCTAssertTrue(laterArmed)
                XCTAssertFalse(earlierArmed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 1)
                let policyState = await run.manager.debugEffectivePolicyState(for: run.c1)
                XCTAssertEqual(policyState.taskLabelKind, .explore, "The run's policy state is the newer turn's.")
            }
        }

        /// The second turn settles while its arming still waits for the first turn, whose
        /// installation is in flight. The third turn waits for both, so it installs only after the
        /// first turn's policy has landed and been cleared.
        func testThirdTurnInstallsAfterTheFirstTurnsInstallationWhenTheSecondSettlesWhileArming() async throws {
            try await withFollowUpRun { run, turns in
                let gate = ReadinessTestGate()
                let first = try XCTUnwrap(turns.begin(installationHeldBy: gate))
                let firstArming = try await turns.startArming(first, heldBy: gate)
                let second = try XCTUnwrap(turns.begin())
                let secondArming = Task { await second.arm() }
                let secondArmingEvent = await Self.firstEvent(of: secondArming) { second.debugPredecessorSettlementWaiterCount == 1 }
                XCTAssertEqual(secondArmingEvent, .waiting, "The second turn's arming waits for the first turn's settlement.")

                // The settlement joins the arming: both of the second turn's callers wait for the
                // first turn.
                let secondSettling = Task { await second.settle(.failed) }
                let secondSettlingEvent = await Self.firstEvent(of: secondSettling) { second.debugPredecessorSettlementWaiterCount == 2 }
                XCTAssertEqual(secondSettlingEvent, .waiting, "The second turn's settlement waits for the first turn's settlement.")

                let third = try XCTUnwrap(turns.begin(taskLabelKind: .explore))
                let thirdArming = Task { await third.arm() }
                let thirdArmingEvent = await Self.firstEvent(of: thirdArming) { third.debugPredecessorSettlementWaiterCount == 1 }
                XCTAssertEqual(thirdArmingEvent, .waiting, "The third turn's arming waits for the second turn's settlement.")

                await gate.release()
                let thirdArmed = await thirdArming.value
                await secondSettling.value
                _ = await secondArming.value
                let firstArmed = await firstArming.value

                XCTAssertTrue(thirdArmed)
                XCTAssertFalse(firstArmed)
                let policyState = await run.manager.debugEffectivePolicyState(for: run.c1)
                XCTAssertEqual(policyState.taskLabelKind, .explore, "The run's policy state is the third turn's.")
                await Self.assertNewerTurnAdmitsRespawnedHelper(in: run)
            }
        }

        /// The earlier turn's failed arming is held just before it removes the run's pending policy,
        /// and the turn settles there. The newer turn installs only after that removal, because the
        /// earlier lease keeps the bootstrap gate until it has removed the policy.
        func testFailedArmRemovesItsPolicyBeforeANewerTurnInstalls() async throws {
            try await withFollowUpRun { run, turns in
                await Self.installUnreplacedRunPolicy(in: run)
                let gate = ReadinessTestGate()
                let earlier = try XCTUnwrap(turns.begin())
                let earlierArming = try await turns.startArming(earlier, heldBy: gate, at: .pendingPolicyRemoval)
                await earlier.settle(.failed)

                let later = try XCTUnwrap(turns.begin(taskLabelKind: .explore))
                let laterArming = Task { await later.arm() }
                let laterArmingEvent = await Self.firstEvent(of: laterArming) {
                    await HeadlessAgentConnectionGate.shared.debugWaitingCount() > 0
                }
                XCTAssertEqual(laterArmingEvent, .waiting, "The newer turn's arming waits for the gate the earlier lease still owns.")

                await gate.release()
                let laterArmed = await laterArming.value
                let earlierArmed = await earlierArming.value

                XCTAssertTrue(laterArmed)
                XCTAssertFalse(earlierArmed)
                let policyState = await run.manager.debugEffectivePolicyState(for: run.c1)
                XCTAssertEqual(policyState.taskLabelKind, .explore, "The run's policy state is the newer turn's.")
                await Self.assertNewerTurnAdmitsRespawnedHelper(in: run)
            }
        }

        func testCancelledSettlementDuringAFailedArmsCleanupEndsItsRunsRouting() async throws {
            try await withFollowUpRun { run, turns in
                await Self.installUnreplacedRunPolicy(in: run)
                let gate = ReadinessTestGate()
                let turn = try XCTUnwrap(turns.begin())
                let arming = try await turns.startArming(turn, heldBy: gate, at: .pendingPolicyRemoval)

                await turn.settle(.cancelled)
                await gate.release()
                let armed = await arming.value

                XCTAssertFalse(armed)
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                let trackedRunID = await run.manager.runIDForConnection(run.c1)
                XCTAssertNil(trackedRunID, "A turn cancelled while its failed arming is being cleaned up ends its run's routing.")
            }
        }

        // MARK: Follow-up turns through the runner

        // These turns go through the view model's submission into the runner's reuse branch and
        // `continueRun`, on a real ACP controller whose open session is on a fake OpenCode agent.

        func testFollowUpTurnInstallsItsPolicyBeforeThePromptAndTeardownRemovesIt() async throws {
            try await withReusedOpenCodeSession { run, reused in
                for turn in 1 ... 2 {
                    try await reused.submit("Follow-up turn \(turn)")
                    XCTAssertEqual(
                        reused.events.entries.suffix(2),
                        [.policyInstalled, .promptSubmitted],
                        "Turn \(turn) installs its policy before its prompt is submitted."
                    )
                    let pending = await run.pendingPolicyCount()
                    XCTAssertEqual(pending, 1, "Turn \(turn)'s policy waits for a respawned helper while its prompt runs.")
                    XCTAssertTrue(ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: run.runID))

                    try await reused.finishPrompt()

                    let remaining = await run.pendingPolicyCount()
                    XCTAssertEqual(remaining, 0, "Turn \(turn)'s terminal teardown removes its unused policy.")
                    XCTAssertFalse(ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: run.runID))
                    await run.assertOwner(run.c1)
                }
                XCTAssertEqual(
                    reused.events.entries,
                    [.policyInstalled, .promptSubmitted, .policyInstalled, .promptSubmitted]
                )
            }
        }

        func testFollowUpTurnWhosePolicyCannotBeArmedRunsOnTheEstablishedRoute() async throws {
            try await withReusedOpenCodeSession { run, reused in
                await Self.installUnreplacedRunPolicy(in: run)

                try await reused.submit("Follow-up turn")

                XCTAssertEqual(reused.events.entries, [.policyInstalled, .promptSubmitted])
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0, "The turn's unarmed policy does not stay pending while its prompt runs.")
                await run.assertOwner(run.c1)

                try await reused.finishPrompt()
                await run.assertOwner(run.c1)
            }
        }

        /// No later turn settles this turn's admission as its predecessor, so only the turn's own
        /// teardown can release the issuer's record of it.
        func testSessionEndingAfterItsFirstTurnRetainsNoFollowUpBookkeeping() async throws {
            try await withReusedOpenCodeSession { run, reused in
                try await reused.submit("The session's only turn")
                try await reused.finishPrompt()
                await reused.end()

                XCTAssertFalse(ACPFollowUpRespawnAdmissions.debugTracksUnsettledAdmission(forRunID: run.runID))
                let pending = await run.pendingPolicyCount()
                XCTAssertEqual(pending, 0)
                XCTAssertEqual(reused.events.entries, [.policyInstalled, .promptSubmitted])
            }
        }

        // MARK: Follow-up fixture

        /// Issues follow-up turn admissions for the fixture's run through the runner's issuer, each
        /// with a real agent-mode lease.
        @MainActor
        private final class FollowUpTurns {
            private let run: ExpectedPIDRunFixture
            private let tabID: UUID
            private let admissions = ACPFollowUpRespawnAdmissions()
            private var issued: [ACPFollowUpRespawnAdmission] = []
            private var leases: [ObjectIdentifier: MCPBootstrapLease] = [:]
            private(set) var leaseCount = 0

            init(run: ExpectedPIDRunFixture, tabID: UUID) {
                self.run = run
                self.tabID = tabID
            }

            /// With `installationGate`, the turn's lease waits there before it installs the run's
            /// policy, so the lease has not yet recorded a policy as installed while it waits.
            func begin(
                agentKind: AgentProviderKind = .openCode,
                installationHeldBy installationGate: ReadinessTestGate? = nil,
                taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil
            ) -> ACPFollowUpRespawnAdmission? {
                var madeLease: MCPBootstrapLease?
                let admission = admissions.make(agentKind: agentKind, runID: run.runID) { runID in
                    leaseCount += 1
                    let lease = MCPBootstrapLease(
                        spec: .agentMode(
                            tabID: tabID,
                            runID: runID,
                            gateID: UUID(),
                            windowID: run.window.windowID,
                            agent: agentKind,
                            taskLabelKind: taskLabelKind
                        ),
                        policyInstaller: installationGate.map { gate in
                            { [run] _ in
                                await gate.arriveAndWait()
                                await run.installRunPolicy()
                            }
                        }
                    )
                    madeLease = lease
                    return lease
                }
                if let admission {
                    issued.append(admission)
                    leases[ObjectIdentifier(admission)] = madeLease
                }
                return admission
            }

            /// Whether a release of `turn`'s lease is waiting for the installation its acquisition
            /// has in flight.
            func releaseWaitsForInstallation(of turn: ACPFollowUpRespawnAdmission) async -> Bool {
                await leases[ObjectIdentifier(turn)]?.debugHasInstallationWaiter ?? false
            }

            /// Where `startArming` holds a lease's acquisition.
            enum ArmingHold {
                /// At the acquisition's last step: the policy is installed and armed, and success is
                /// not yet reported.
                case lastStep
                /// In the cleanup of an arming that failed, just before it removes the run's pending
                /// policy.
                case pendingPolicyRemoval
            }

            /// Starts arming `turn` and returns once `gate` holds its lease's acquisition. A turn begun with `installationHeldBy: gate` is held before its policy is
            /// installed. Any other turn is held at `hold`. The acquisition resumes when `gate` is
            /// released.
            func startArming(
                _ turn: ACPFollowUpRespawnAdmission,
                heldBy gate: ReadinessTestGate,
                at hold: ArmingHold = .lastStep,
                file: StaticString = #filePath,
                line: UInt = #line
            ) async throws -> Task<Bool, Never> {
                let lease = try XCTUnwrap(leases[ObjectIdentifier(turn)], file: file, line: line)
                switch hold {
                case .lastStep:
                    await lease.debugSetAfterExpectedPIDGateReleaseHook { await gate.arriveAndWait() }
                case .pendingPolicyRemoval:
                    await lease.debugSetBeforePendingPolicyRemovalHook { await gate.arriveAndWait() }
                }
                let arming = Task { await turn.arm() }
                // A failing test still lets the held acquisition finish.
                run.cleanup.add {
                    await gate.release()
                    _ = await arming.value
                }
                let held = await gate.waitUntilEntered(timeout: .seconds(5))
                XCTAssertTrue(held, "The turn's acquisition was not held.", file: file, line: line)
                return arming
            }

            func settleAll() async {
                for admission in issued {
                    await admission.settle(.completed)
                }
            }
        }

        private func withFollowUpRun(_ body: (ExpectedPIDRunFixture, FollowUpTurns) async throws -> Void) async throws {
            try await ExpectedPIDRunFixture.withEstablishedRun(
                sessionName: "OpenCode follow-up fixture session",
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools
            ) { run in
                let turns = try FollowUpTurns(run: run, tabID: XCTUnwrap(run.tabID))
                run.cleanup.add { await turns.settleAll() }
                try await body(run, turns)
            }
        }

        /// The newer turn's policy is the run's one pending policy after the earlier turn's
        /// acquisition ended, C1 still owns the run, and a respawned helper is admitted.
        private static func assertNewerTurnAdmitsRespawnedHelper(
            in run: ExpectedPIDRunFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let pending = await run.pendingPolicyCount()
            XCTAssertEqual(pending, 1, "The earlier turn's acquisition leaves the newer turn's policy in place.", file: file, line: line)
            await run.assertOwner(run.c1, file: file, line: line)
            let respawn = await run.apply(run.c4, sessionKey: run.c4Token)
            XCTAssertEqual(respawn.outcome, "applied", "The newer turn still admits a respawned helper.", file: file, line: line)
        }

        /// What a task started under a hold does first.
        private enum FirstEvent: Equatable {
            /// It reached the wait the test observes, where it stays until the hold is released.
            case waiting
            /// It finished without reaching that wait.
            case finished
            /// Neither within the deadline, which only keeps a stalled run from hanging.
            case neither
        }

        /// Polls until `isWaiting` holds or `task` finishes and reports which came first. A task
        /// that has to wait for the hold cannot finish before the hold is released, and one that
        /// does not wait finishes on its own, so each outcome is stable once it is seen.
        private static func firstEvent(
            of task: Task<some Sendable, Never>,
            isWaiting: @MainActor () async -> Bool
        ) async -> FirstEvent {
            let finished = StartupTestCompletionFlag()
            Task {
                _ = await task.value
                finished.value = true
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            while clock.now < deadline {
                if await isWaiting() { return .waiting }
                if finished.value { return .finished }
                try? await clock.sleep(for: .milliseconds(2))
            }
            return .neither
        }

        /// Leaves the run with a pending policy that a turn's installation does not replace, so the
        /// turn's own policy is not the run's only one and cannot be armed.
        private static func installUnreplacedRunPolicy(in run: ExpectedPIDRunFixture) async {
            await run.manager.installClientConnectionPolicy(
                for: run.clientName,
                windowID: run.window.windowID,
                restrictedTools: run.restrictedTools,
                oneShot: false,
                ttl: 60,
                tabID: run.tabID,
                runID: run.runID,
                purpose: .agentModeRun
            )
        }

        /// The peer session's helper reconnects with its own ticket from a process unrelated to the run.
        private static func reconnect(_ peer: PeerRun, in run: ExpectedPIDRunFixture) async -> String {
            await run.apply(
                peer.reconnectID,
                sessionKey: peer.token,
                clientPid: ExpectedPIDRunFixture.unrelatedHelperPID
            ).outcome
        }

        // MARK: Reused OpenCode session fixture

        /// The fixture's established run serves a reused OpenCode session: its helper is the routed
        /// owner C1, and the tab keeps the run and an open controller between turns.
        private func withReusedOpenCodeSession(
            _ body: (ExpectedPIDRunFixture, ReusedOpenCodeSession) async throws -> Void
        ) async throws {
            let workspace = try makeTestDirectory()
            let agentDirectory = try makeTestDirectory(name: "\(#function)-agent")
            let scriptURL = agentDirectory.appendingPathComponent("fake_opencode_acp_agent.py")
            try Self.writeFakeOpenCodeAgent(to: scriptURL)
            try await ExpectedPIDRunFixture.withEstablishedRun(
                sessionName: "OpenCode reused session",
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools
            ) { run in
                let reused = try await ReusedOpenCodeSession.open(
                    on: run,
                    workspace: workspace,
                    scriptURL: scriptURL,
                    releaseDirectory: agentDirectory
                )
                run.cleanup.add { await reused.tearDown() }
                try await body(run, reused)
            }
        }

        /// A live view-model tab whose reused OpenCode session is a real ACP controller on a fake
        /// agent. The agent holds each prompt's reply until the test finishes that prompt.
        @MainActor
        private final class ReusedOpenCodeSession {
            enum Failure: Error {
                case promptNotSubmitted
                case turnDidNotFinish
            }

            let viewModel: AgentModeViewModel
            let session: AgentModeViewModel.TabSession
            let controller: ACPAgentSessionController
            let events: FollowUpTurnEventLog
            private let runID: UUID
            private let releaseDirectory: URL
            private var submittedPrompts = 0
            private var finishedPrompts = 0

            private init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                controller: ACPAgentSessionController,
                events: FollowUpTurnEventLog,
                runID: UUID,
                releaseDirectory: URL
            ) {
                self.viewModel = viewModel
                self.session = session
                self.controller = controller
                self.events = events
                self.runID = runID
                self.releaseDirectory = releaseDirectory
            }

            /// Policies go through the view model's installer to the shared MCP manager, recording
            /// each installation. A turn that misses the reuse branch fails at provider creation.
            static func open(
                on run: ExpectedPIDRunFixture,
                workspace: URL,
                scriptURL: URL,
                releaseDirectory: URL
            ) async throws -> ReusedOpenCodeSession {
                let tabID = try XCTUnwrap(run.tabID)
                let events = FollowUpTurnEventLog()
                let provider = FakeOpenCodeProvider(
                    scriptPath: scriptURL.path,
                    releaseDirectory: releaseDirectory.path,
                    events: events
                )
                let controller = try ACPAgentSessionController(
                    provider: provider,
                    runRequest: ACPRunRequest(
                        agentKind: .openCode,
                        modelString: nil,
                        workspacePath: workspace.path,
                        resumeSessionID: nil,
                        attachments: [],
                        taskLabelKind: nil
                    )
                )
                do {
                    _ = try await controller.bootstrap()
                } catch {
                    await controller.shutdown()
                    throw error
                }
                let codex = StartupTestCodexController(gatesStartup: false)
                let viewModel = AgentModeViewModel(
                    testWindowID: run.window.windowID,
                    testWorkspacePath: workspace.path,
                    testWorkspaceDirectory: workspace,
                    codexControllerFactory: { _, _, _, _, _, _ in codex },
                    acpProviderFactory: { _, _ in nil },
                    connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
                        events.record(.policyInstalled)
                        await ServerNetworkManager.shared.installClientConnectionPolicy(
                            for: clientName,
                            windowID: windowID,
                            restrictedTools: restrictedTools,
                            oneShot: oneShot,
                            reason: reason,
                            ttl: ttl,
                            tabID: tabID,
                            runID: runID,
                            additionalTools: additionalTools,
                            purpose: purpose,
                            taskLabelKind: taskLabelKind,
                            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                            requiresExpectedAgentPID: requiresExpectedAgentPID
                        )
                    },
                    testOpenCodeModelParameterStreamProvider: { _, _ in AsyncStream { $0.finish() } }
                )
                viewModel.test_agentAvailabilityForRunOverride = { _ in true }
                let session = AgentModeViewModel.TabSession(tabID: tabID)
                session.hasLoadedPersistedState = true
                session.selectedAgent = .openCode
                session.acpController = controller
                session.installRunID(run.runID)
                viewModel.test_installLiveSession(session)
                return ReusedOpenCodeSession(
                    viewModel: viewModel,
                    session: session,
                    controller: controller,
                    events: events,
                    runID: run.runID,
                    releaseDirectory: releaseDirectory
                )
            }

            /// Submits a turn and returns once its prompt is submitted; the agent holds the reply.
            func submit(_ text: String, file: StaticString = #filePath, line: UInt = #line) async throws {
                XCTAssertEqual(session.runID, runID, "The tab keeps the run its reused session serves.", file: file, line: line)
                let reusable = await controller.hasReusableSession
                XCTAssertTrue(reusable, "The tab's controller still has an open session.", file: file, line: line)
                XCTAssertEqual(viewModel.submitUserTurn(text: text, tabID: session.tabID), .submitted, file: file, line: line)
                submittedPrompts += 1
                let prompt = submittedPrompts
                let events = events
                guard await startupTestWaitBounded(seconds: 10, until: { events.promptCount >= prompt }) else {
                    XCTFail("Prompt \(prompt) was not submitted; errors: \(errorTexts)", file: file, line: line)
                    throw Failure.promptNotSubmitted
                }
            }

            /// Lets the agent answer the held prompt, then waits for the turn to complete and for its
            /// terminal teardown to finish.
            func finishPrompt(file: StaticString = #filePath, line: UInt = #line) async throws {
                let turn = try XCTUnwrap(session.agentTask, "The submitted turn is running.", file: file, line: line)
                finishedPrompts += 1
                try release(finishedPrompts)
                guard await startupTestJoinBounded(
                    turn,
                    "The turn did not finish after its prompt was answered.",
                    seconds: 10,
                    file: file,
                    line: line
                ) else {
                    throw Failure.turnDidNotFinish
                }
                // Cancelling a terminal run only waits for its publication and teardown.
                guard session.runState.isTerminalForCommit else {
                    XCTFail("The turn ended in \(session.runState); errors: \(errorTexts)", file: file, line: line)
                    throw Failure.turnDidNotFinish
                }
                XCTAssertEqual(session.runState, .completed, "errors: \(errorTexts)", file: file, line: line)
                let viewModel = viewModel
                let tabID = session.tabID
                await startupTestAwaitBounded(
                    "The turn's terminal teardown did not finish.",
                    seconds: 10,
                    file: file,
                    line: line
                ) {
                    await viewModel.cancelAgentRun(tabID: tabID, completion: .terminalTeardownCompleted)
                }
            }

            /// Ends the session as closing its tab ends the provider: the agent process exits.
            func end(file: StaticString = #filePath, line: UInt = #line) async {
                await controller.shutdown()
                let reusable = await controller.hasReusableSession
                XCTAssertFalse(reusable, file: file, line: line)
            }

            /// Answers every held prompt so no turn stays parked, then stops anything still running.
            func tearDown() async {
                if submittedPrompts > finishedPrompts {
                    for prompt in (finishedPrompts + 1) ... submittedPrompts {
                        try? release(prompt)
                    }
                }
                if session.runState.isActive {
                    let viewModel = viewModel
                    let tabID = session.tabID
                    await startupTestAwaitBounded("The reused session's run did not stop.", seconds: 10) {
                        await viewModel.cancelAgentRun(tabID: tabID, completion: .terminalTeardownCompleted)
                    }
                }
                await controller.shutdown()
            }

            private var errorTexts: [String] {
                session.items.filter { $0.kind == .error }.map(\.text)
            }

            private func release(_ prompt: Int) throws {
                try Data().write(to: releaseDirectory.appendingPathComponent("release-\(prompt)"))
            }
        }

        /// What the runner did for each turn, in order: a policy installation through the view
        /// model's installer, and a prompt the controller built for submission.
        final class FollowUpTurnEventLog: @unchecked Sendable {
            enum Entry: Equatable {
                case policyInstalled
                case promptSubmitted
            }

            private let lock = NSLock()
            private var recorded: [Entry] = []

            var entries: [Entry] {
                lock.withLock { recorded }
            }

            var promptCount: Int {
                lock.withLock { recorded.count { $0 == .promptSubmitted } }
            }

            func record(_ entry: Entry) {
                lock.withLock { recorded.append(entry) }
            }
        }

        /// OpenCode's provider identity over the fake agent; records each prompt it builds.
        private struct FakeOpenCodeProvider: ACPAgentProvider {
            let providerID: ACPProviderID = .openCode
            let scriptPath: String
            let releaseDirectory: String
            let events: FollowUpTurnEventLog

            func support(for _: ACPRunRequest) async -> ACPSupportResult {
                .supported
            }

            func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
                ACPLaunchConfiguration(
                    providerID: providerID,
                    command: scriptPath,
                    arguments: [],
                    environment: ["ACP_RELEASE_DIR": releaseDirectory],
                    workingDirectory: request.workspacePath,
                    additionalPathHints: [],
                    enableDebugLogging: false
                )
            }

            func makeSessionConfiguration(
                for request: ACPRunRequest,
                mcpServer _: RepoPromptMCPServerConfiguration
            ) throws -> ACPSessionConfiguration {
                ACPSessionConfiguration(
                    mode: .new,
                    workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
                    mcpServers: []
                )
            }

            func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
                events.record(.promptSubmitted)
                return [["type": "text", "text": message.userMessage]]
            }

            func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
                []
            }

            func normalizeError(_ error: Error) -> Error {
                error
            }
        }

        /// An ACP agent advertising OpenCode's managed session modes. It answers prompt N only once
        /// `release-N` exists in `ACP_RELEASE_DIR`, and on its own after 30 seconds.
        private static func writeFakeOpenCodeAgent(to url: URL) throws {
            let script = #"""
            #!/usr/bin/env python3
            import json
            import os
            import sys
            import time
            release_dir = os.environ["ACP_RELEASE_DIR"]
            modes = ["repoprompt_acp", "repoprompt_acp_full_access"]
            current_mode = modes[0]
            prompts = 0
            def config_options():
                return [{
                    "id": "mode",
                    "name": "Mode",
                    "category": "mode",
                    "type": "select",
                    "currentValue": current_mode,
                    "options": [{"value": mode, "name": mode} for mode in modes],
                }]
            def respond(request_id, result):
                print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
            for line in sys.stdin:
                try:
                    request = json.loads(line)
                except Exception:
                    continue
                if "id" not in request or "method" not in request:
                    continue
                method = request["method"]
                params = request.get("params") or {}
                if method == "initialize":
                    respond(request["id"], {"agentCapabilities": {"loadSession": True}, "authMethods": []})
                elif method == "session/new":
                    respond(request["id"], {"sessionId": "opencode-reused-session", "configOptions": config_options()})
                elif method == "session/set_config_option":
                    if params.get("configId") == "mode":
                        current_mode = params.get("value")
                    respond(request["id"], {"configOptions": config_options()})
                elif method == "session/prompt":
                    prompts += 1
                    release = os.path.join(release_dir, "release-%d" % prompts)
                    deadline = time.time() + 30
                    while not os.path.exists(release) and time.time() < deadline:
                        time.sleep(0.01)
                    respond(request["id"], {"stopReason": "end_turn"})
                else:
                    respond(request["id"], {})
            """#
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    #endif
}

#if DEBUG

    // MARK: - Retirement and resume

    /// These runs go through the view model's submission into the runner's fresh-start branch, on
    /// real ACP controllers whose agent is `StartupTestACPPeer`.
    extension ACPIntegratedAgentModeRunnerExecutionTests {
        /// A released session's next turn waits for the old process to exit, then loads the stored
        /// conversation in a new process.
        func testRetiredSessionLoadsConversationAfterShutdown() async throws {
            let fixture = try makeACPRetirementFixture()
            let session = fixture.session
            let fact = "fact-\(UUID().uuidString)"
            try await fixture.runTurn("Remember \(fact).")
            let firstPID = try XCTUnwrap(fixture.peer.startedPIDs.first)
            let storedID = try XCTUnwrap(session.providerSessionID)
            let firstRunID = try XCTUnwrap(session.runID)

            let shutdownHold = StartupTestHeldGate()
            fixture.cleanup.heldGates.append(shutdownHold)
            let startsWaiting = StartupTestCounter()
            fixture.viewModel.test_setACPRetirementHooks(
                retirementWillShutDown: { _ in await shutdownHold.wait() },
                startWillAwaitRetirement: { _ in startsWaiting.value += 1 }
            )
            guard case .retiring = await fixture.viewModel.retireProviderIfIdle(session, reason: .explicitStop) else {
                return XCTFail("the idle session's process was not released")
            }
            XCTAssertNil(session.acpController)
            XCTAssertNil(session.runID)
            XCTAssertEqual(session.providerSessionID, storedID)

            let ticket = try fixture.submit("What did I ask you to remember?")
            // A start that skipped the wait shows up as a second process.
            try await startupTestEventually { startsWaiting.value == 1 || fixture.peer.startedPIDs.count > 1 }
            XCTAssertEqual(fixture.peer.startedPIDs, [firstPID], "a new process started while the old one was running")

            shutdownHold.release()
            try await startupTestJoin(ticket.task)
            try await fixture.awaitCompletedTurn()

            let records = fixture.peer.records
            let secondPID = try XCTUnwrap(fixture.peer.startedPIDs.last)
            XCTAssertNotEqual(secondPID, firstPID)
            let firstExit = try XCTUnwrap(records.firstIndex { $0.event == "exit" && $0.pid == firstPID })
            let secondStart = try XCTUnwrap(records.firstIndex { $0.event == "start" && $0.pid == secondPID })
            XCTAssertLessThan(firstExit, secondStart, "the new process started before the old one exited")
            let load = try XCTUnwrap(records.first { $0.event == "session/load" && $0.pid == secondPID })
            XCTAssertEqual(load.sessionID, storedID)
            XCTAssertEqual(load.history?.contains { $0.contains(fact) }, true, "\(String(describing: load.history))")
            XCTAssertFalse(records.contains { $0.event == "session/new" && $0.pid == secondPID })
            let secondPrompt = try XCTUnwrap(records.last { $0.event == "session/prompt" })
            XCTAssertEqual(secondPrompt.pid, secondPID)
            XCTAssertEqual(secondPrompt.sessionID, storedID)
            XCTAssertEqual(session.providerSessionID, storedID)
            XCTAssertNotNil(session.runID)
            XCTAssertNotEqual(session.runID, firstRunID)
            XCTAssertNotNil(session.acpController)
            XCTAssertFalse(fixture.viewModel.test_hasPendingACPRetirement(for: session))
        }

        /// When the agent can't load the stored conversation, the turn opens a new one, sends the
        /// transcript handoff with the message, and says so once in the transcript.
        func testResumeFallbackAddsOneNoticeAndHandoff() async throws {
            let savedID = "saved-acp-session"
            let notice = ACPIntegratedAgentModeRunner.resumeFallbackNotice(for: .cursor)
            for (label, loadSession, failLoad) in [
                ("stored conversation missing", true, true),
                ("agent can't load conversations", false, false)
            ] {
                let fixture = try makeACPRetirementFixture(loadSession: loadSession, failLoad: failLoad)
                Self.installEarlierConversation(on: fixture.session, providerSessionID: savedID)
                let earlierItems = fixture.session.items

                try await fixture.runTurn("after the fallback")

                let records = fixture.peer.records
                XCTAssertEqual(records.contains { $0.event == "session/load" }, loadSession, label)
                XCTAssertEqual(records.count { $0.event == "session/new" }, 1, label)
                let prompt = try XCTUnwrap(records.last { $0.event == "session/prompt" }?.text, label)
                let handoffEnd = try XCTUnwrap(prompt.range(of: "</forked_session>"), "\(label): \(prompt)")
                XCTAssertTrue(prompt[..<handoffEnd.lowerBound].contains("the earlier fact is 42"), "\(label): \(prompt)")
                XCTAssertTrue(prompt[handoffEnd.upperBound...].contains("after the fallback"), "\(label): \(prompt)")
                XCTAssertEqual(Self.systemTexts(in: fixture.session), [notice], label)
                XCTAssertEqual(Array(fixture.session.items.prefix(earlierItems.count)), earlierItems, label)
                let newID = try XCTUnwrap(fixture.session.providerSessionID, label)
                XCTAssertNotEqual(newID, savedID, label)
                XCTAssertEqual(records.last { $0.event == "session/prompt" }?.sessionID, newID, label)
            }
        }

        /// A fallback whose `session/new` fails too ends the run failed, without the notice that a
        /// new conversation started.
        func testFailedNewConversationAddsNoNotice() async throws {
            let savedID = "saved-acp-session"
            let fixture = try makeACPRetirementFixture(loadSession: false, failNew: true)
            Self.installEarlierConversation(on: fixture.session, providerSessionID: savedID)
            let ticket = try fixture.submit("after the fallback")
            try await startupTestJoin(ticket.task)
            try await startupTestEventually(seconds: 15) {
                !fixture.session.runState.isActive && fixture.session.activeRunOwnership == nil
            }
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertEqual(Self.systemTexts(in: fixture.session), [])
            XCTAssertFalse(fixture.peer.records.contains { $0.event == "session/prompt" })
        }

        private static func installEarlierConversation(
            on session: AgentModeViewModel.TabSession,
            providerSessionID: String
        ) {
            session.setItemsSilently(
                [
                    .user("what is the earlier fact?", sequenceIndex: 0),
                    .assistant("the earlier fact is 42", sequenceIndex: 1)
                ],
                reason: .persistedSessionHydration
            )
            session.nextSequenceIndex = 2
            session.providerSessionID = providerSessionID
        }

        private static func systemTexts(in session: AgentModeViewModel.TabSession) -> [String] {
            session.items.filter { $0.kind == .system }.map(\.text)
        }

        // MARK: Retirement fixture

        /// A Cursor session in a view model whose ACP starts use `peer` and whose idle timer runs on
        /// `idle`'s manual clock, recording the decisions its deadlines make.
        @MainActor
        final class ACPRetirementFixture: StartupTestSessionFixture {
            let peer: StartupTestACPPeer
            let idle: StartupTestIdleEnvironment
            /// What each of this tab's idle-timer deadlines decided, in order.
            private(set) var idleOutcomes: [AgentProviderIdleTimerOutcome] = []

            init(
                viewModel: AgentModeViewModel,
                session: AgentModeViewModel.TabSession,
                readiness: StartupTestGatedReadiness,
                controller: StartupTestCodexController,
                peer: StartupTestACPPeer,
                idle: StartupTestIdleEnvironment
            ) {
                self.peer = peer
                self.idle = idle
                super.init(viewModel: viewModel, session: session, readiness: readiness, controller: controller)
                let tabID = session.tabID
                viewModel.test_setACPIdleTimerOutcomeObserver { [weak self] observedTabID, outcome in
                    guard observedTabID == tabID else { return }
                    self?.idleOutcomes.append(outcome)
                }
            }

            /// The agent process started most recently.
            var lastPID: Int32 {
                get throws { try XCTUnwrap(peer.startedPIDs.last) }
            }

            var promptCount: Int {
                peer.records.count { $0.event == "session/prompt" }
            }

            /// Waits until this tab's deadlines have made `expected.count` decisions and checks them.
            func expectIdleOutcomes(
                _ expected: [AgentProviderIdleTimerOutcome],
                countingStale: Bool = false,
                _ label: String = "",
                file: StaticString = #filePath,
                line: UInt = #line
            ) async throws {
                try await startupTestExpectIdleOutcomes(
                    expected,
                    in: { [unowned self] in idleOutcomes },
                    countingStale: countingStale,
                    label,
                    file: file,
                    line: line
                )
            }

            /// Sends `text` as a manual turn and waits until its run has completed.
            func runTurn(_ text: String) async throws {
                let ticket = try submit(text)
                try await startupTestJoin(ticket.task)
                try await awaitCompletedTurn()
            }
        }

        /// Builds the fixture and registers its teardown, which also ends every agent process the
        /// test started, before any test step can throw.
        func makeACPRetirementFixture(
            loadSession: Bool = true,
            failLoad: Bool = false,
            failNew: Bool = false
        ) throws -> ACPRetirementFixture {
            let directory = try makeTestDirectory()
            let peer = try StartupTestACPPeer(directory: directory)
            let readiness = StartupTestGatedReadiness(gatedCalls: [])
            let controller = StartupTestCodexController(gatesStartup: false)
            let idle = StartupTestIdleEnvironment()
            let viewModel = startupTestMakeViewModel(
                storageRoot: directory,
                readiness: readiness,
                controller: controller,
                idle: idle,
                acpProvider: peer.provider(loadSession: loadSession, failLoad: failLoad, failNew: failNew)
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.hasLoadedPersistedState = true
            session.selectedAgent = .cursor
            let fixture = ACPRetirementFixture(
                viewModel: viewModel,
                session: session,
                readiness: readiness,
                controller: controller,
                peer: peer,
                idle: idle
            )
            addTeardownBlock { @MainActor in
                try? peer.releaseHold(Self.heldPrompt)
                await fixture.tearDown()
                idle.clock.cancelSleepers()
                await session.acpController?.shutdown()
                peer.killUnexitedProcesses()
            }
            return fixture
        }
    }

    // MARK: - Idle timer

    /// These runs go through the same path as the retirement tests above. The idle timer runs on a
    /// manual clock: a deadline passes only when a test advances it.
    extension ACPIntegratedAgentModeRunnerExecutionTests {
        /// The default setting of 5 minutes, which every fixture starts with.
        private static let idleInterval: Duration = .seconds(GlobalSettingsStore.defaultIdleProviderShutdownMinutes * 60)
        /// The hold name the scripted agent waits on before it answers a prompt containing it.
        static let heldPrompt = "held"

        /// A completed turn arms the timer. The process lives until the deadline, exits at it, and the
        /// next turn loads the same conversation in a new process.
        func testIdleDeadlineRetiresAndNextTurnLoadsSameConversation() async throws {
            let fixture = try makeACPRetirementFixture()
            let session = fixture.session
            let clock = fixture.idle.clock
            let fact = "fact-\(UUID().uuidString)"
            try await fixture.runTurn("Remember \(fact).")
            let firstPID = try fixture.lastPID
            let storedID = try XCTUnwrap(session.providerSessionID)
            let firstRunID = try XCTUnwrap(session.runID)
            let itemsBefore = session.items
            let deadline = clock.now + Self.idleInterval
            try await startupTestEventually { clock.pendingDeadlines == [deadline] }

            clock.advance(by: Self.idleInterval - .seconds(1))
            XCTAssertEqual(clock.pendingDeadlines, [deadline], "a deadline before the terminal's came due")
            XCTAssertFalse(fixture.peer.hasExited(firstPID))

            clock.advance(by: .seconds(1))
            try await fixture.expectIdleOutcomes([.retired])
            try await startupTestEventually {
                fixture.peer.hasExited(firstPID) && !fixture.viewModel.test_hasPendingACPRetirement(for: session)
            }
            XCTAssertNil(session.acpController)
            XCTAssertNil(session.runID, "the retired process kept its run ID")
            XCTAssertEqual(session.providerSessionID, storedID)
            XCTAssertEqual(session.items, itemsBefore)
            XCTAssertEqual(session.runState, .completed)

            try await fixture.runTurn("What did I ask you to remember?")
            let secondPID = try fixture.lastPID
            XCTAssertNotEqual(secondPID, firstPID)
            let records = fixture.peer.records
            let load = try XCTUnwrap(records.first { $0.event == "session/load" && $0.pid == secondPID })
            XCTAssertEqual(load.sessionID, storedID)
            XCTAssertEqual(load.history?.contains { $0.contains(fact) }, true, "\(String(describing: load.history))")
            XCTAssertFalse(records.contains { $0.event == "session/new" && $0.pid == secondPID })
            XCTAssertEqual(records.last { $0.event == "session/prompt" }?.sessionID, storedID)
            XCTAssertNotEqual(session.runID, firstRunID)
        }

        /// A run waiting for approval, a follow-up queued behind it and that follow-up in flight each
        /// keep the process past the deadline armed before them; the deadline armed by the last
        /// completed turn retires it.
        func testIdleDeadlineKeepsBusyACPWork() async throws {
            let fixture = try makeACPRetirementFixture()
            let session = fixture.session
            let clock = fixture.idle.clock
            try await fixture.runTurn("first turn")
            let pid = try fixture.lastPID

            clock.advance(by: .seconds(60))
            let approvalTurn = try fixture.submit("[permission] run the build")
            try await startupTestJoin(approvalTurn.task)
            try await startupTestEventually { session.pendingApproval != nil }
            clock.advance(by: Self.idleInterval)
            try await fixture.expectIdleOutcomes([.stale], countingStale: true, "pending approval")
            XCTAssertFalse(fixture.peer.hasExited(pid), "pending approval")

            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(text: "[hold:\(Self.heldPrompt)] queued follow-up", tabID: fixture.tabID),
                .submitted
            )
            XCTAssertEqual(session.pendingInstructions.count, 1, "the follow-up was not queued")
            let approval = try XCTUnwrap(session.pendingApproval)
            XCTAssertTrue(fixture.viewModel.submitApprovalDecision(
                tabID: fixture.tabID,
                requestID: approval.id,
                decision: .accept
            ))
            // The approved turn completes, arms a timer, and starts the queued follow-up.
            try await startupTestEventually(seconds: 15) {
                fixture.promptCount == 3 && session.pendingInstructions.isEmpty && session.runState == .running
            }
            let followUpArmedDeadline = clock.now + Self.idleInterval
            try await startupTestEventually { clock.pendingDeadlines == [followUpArmedDeadline] }
            clock.advance(by: Self.idleInterval)
            try await fixture.expectIdleOutcomes([.stale, .stale], countingStale: true, "follow-up in flight")
            XCTAssertFalse(fixture.peer.hasExited(pid), "follow-up in flight")

            try fixture.peer.releaseHold(Self.heldPrompt)
            try await fixture.awaitCompletedTurn()
            clock.advance(by: Self.idleInterval)
            try await fixture.expectIdleOutcomes([.stale, .stale, .retired], countingStale: true)
            try await startupTestEventually { fixture.peer.hasExited(pid) }
            XCTAssertEqual(fixture.peer.startedPIDs, [pid])
        }

        /// Work that holds an idle session, here a binding transition, keeps the process at the
        /// deadline. The timer asks again an interval later and retires the process once the work
        /// has ended.
        func testBlockedACPIdleDeadlineChecksAgainAfterAnInterval() async throws {
            let fixture = try makeACPRetirementFixture()
            let clock = fixture.idle.clock
            try await fixture.runTurn("turn")
            let pid = try fixture.lastPID
            let generation = fixture.session.beginPersistentBindingTransition()
            clock.advance(by: Self.idleInterval)
            try await fixture.expectIdleOutcomes([.rearmed])
            XCTAssertFalse(fixture.peer.hasExited(pid))
            XCTAssertNotNil(fixture.session.acpController)

            fixture.session.finishPersistentBindingTransition(generation: generation)
            clock.advance(by: Self.idleInterval)
            try await fixture.expectIdleOutcomes([.rearmed, .retired])
            try await startupTestEventually { fixture.peer.hasExited(pid) }
        }

        /// A switch to Never before the deadline keeps the process: the deadline ends the timer
        /// without asking the session to retire.
        func testNeverSettingAtACPIdleDeadlineKeepsProcess() async throws {
            let fixture = try makeACPRetirementFixture()
            let clock = fixture.idle.clock
            try await fixture.runTurn("turn")
            let pid = try fixture.lastPID
            fixture.idle.idleMinutes = 0

            clock.advance(by: Self.idleInterval)
            try await fixture.expectIdleOutcomes([.ended])
            XCTAssertNotNil(fixture.session.acpController, "the process was released under Never")
            XCTAssertFalse(fixture.peer.hasExited(pid))
            XCTAssertEqual(clock.pendingDeadlines, [])
        }

        /// The idle timer leaves an agent that can't reload a saved conversation running, since a
        /// new process could not resume it. An explicit stop still releases it.
        func testACPIdleTimerSkipsUnsupportedLoadCapability() async throws {
            let fixture = try makeACPRetirementFixture(loadSession: false)
            let session = fixture.session
            let clock = fixture.idle.clock
            try await fixture.runTurn("turn")
            let pid = try fixture.lastPID

            clock.advance(by: Self.idleInterval)
            try await fixture.expectIdleOutcomes([.ended])
            XCTAssertEqual(clock.pendingDeadlines, [], "the timer kept polling")
            XCTAssertFalse(fixture.peer.hasExited(pid))
            XCTAssertNotNil(session.acpController)

            guard case let .retiring(retirement) = await fixture.viewModel.retireProviderIfIdle(
                session,
                reason: .explicitStop
            ) else {
                return XCTFail("an explicit stop did not release the process")
            }
            try await startupTestJoin(retirement)
            XCTAssertTrue(fixture.peer.hasExited(pid))
        }

        /// A deadline whose timer a later turn replaced leaves the later turn's timer alone, even
        /// after the setting has grown and the same controller is still attached. The later
        /// timer waits out the grown setting, counted from its own turn, and retires the process
        /// then.
        func testStaleACPDeadlineCannotActOnNewerArm() async throws {
            let fixture = try makeACPRetirementFixture()
            let session = fixture.session
            let clock = fixture.idle.clock
            let firstTurnEnd = clock.now
            try await fixture.runTurn("first turn")
            clock.advance(by: .seconds(60))
            try await fixture.runTurn("second turn")
            let pid = try fixture.lastPID
            XCTAssertEqual(fixture.peer.startedPIDs, [pid], "the second turn started a new process")
            let controller = try XCTUnwrap(session.acpController)
            let secondDeadline = firstTurnEnd + .seconds(60) + Self.idleInterval
            try await startupTestEventually { clock.pendingDeadlines.contains(secondDeadline) }
            fixture.idle.idleMinutes = 10
            let grownDeadline = firstTurnEnd + .seconds(60 + 10 * 60)

            // The first turn's deadline passes and finds its timer replaced.
            clock.advance(by: Self.idleInterval - .seconds(60))
            try await fixture.expectIdleOutcomes([.stale], countingStale: true)
            XCTAssertEqual(clock.pendingDeadlines, [secondDeadline], "the stale deadline replaced the second turn's timer")

            // The second turn's deadline passes and waits out the grown setting.
            clock.advance(by: .seconds(60))
            try await fixture.expectIdleOutcomes([.stale, .rearmed], countingStale: true)
            try await startupTestEventually { clock.pendingDeadlines == [grownDeadline] }

            clock.advance(by: .seconds(10 * 60 - Self.idleInterval.components.seconds - 1))
            XCTAssertEqual(clock.pendingDeadlines, [grownDeadline], "a deadline before the grown one came due")
            XCTAssertTrue(session.acpController === controller)
            XCTAssertFalse(fixture.peer.hasExited(pid))

            clock.advance(by: .seconds(1))
            try await fixture.expectIdleOutcomes([.stale, .rearmed, .retired], countingStale: true)
            try await startupTestEventually { fixture.peer.hasExited(pid) }
        }
    }
#endif
