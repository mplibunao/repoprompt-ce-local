import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeTurnCorrelationTests: XCTestCase {
    private typealias CorrelationError = ClaudeNativeTurnCorrelation.CorrelationError

    func testMatchingTurnsOnOnlyForSupportedVersionWithLifecycleCapability() {
        let cases: [(label: String, payload: [String: Any], enabled: Bool)] = [
            ("minimum version", initPayload(version: "2.1.292"), true),
            ("later minor version", initPayload(version: "2.2.0"), true),
            ("earlier patch version", initPayload(version: "2.1.291"), false),
            ("earlier major version with a higher patch", initPayload(version: "1.9.999"), false),
            ("lifecycle capability missing", initPayload(capabilities: ["interrupt_receipt_v1"]), false),
            ("capabilities not a string list", initPayload(capabilities: "msg_lifecycle_v1"), false),
            ("two-part version", initPayload(version: "2.1"), false),
            ("prerelease suffix", initPayload(version: "2.1.292-beta"), false),
            ("signed component", initPayload(version: "+2.1.292"), false),
            ("version not a string", initPayload(version: 2.1), false),
            ("version missing", initPayload(version: nil), false)
        ]
        for testCase in cases {
            var correlation = ClaudeNativeTurnCorrelation()
            correlation.observeInit(testCase.payload)
            XCTAssertEqual(correlation.enabled, testCase.enabled, testCase.label)
        }
    }

    func testResultsSettleExactlyTheHostInputsTheyEchoOnce() throws {
        let first = UUID(), second = UUID(), third = UUID(), foreign = UUID()
        var correlation = ClaudeNativeTurnCorrelation()
        correlation.register(first)
        correlation.observeInit(initPayload())
        correlation.register(second)
        correlation.register(third)

        try correlation.observeActivity(assistant(second))
        XCTAssertEqual(try correlation.resolve(result([second])).inputIDs, [second], "A later input answered first settles alone")
        XCTAssertEqual(
            try correlation.resolve(result([third, foreign, first])).inputIDs,
            [third, first],
            "A grouped answer settles its host inputs in its own order, including one sent before matching turned on, and skips a foreign identity"
        )
        XCTAssertFalse(correlation.hasOutstanding)
        XCTAssertEqual(try correlation.resolve(result([third, first])).inputIDs, [], "A duplicate result settles nothing")
    }

    func testMalformedOrContradictoryIdentityFailsWithoutRetiringInputs() throws {
        let running = UUID(), queued = UUID()
        var correlation = matchingCorrelation()
        correlation.register(running)
        correlation.register(queued)
        try correlation.observeActivity(assistant(running))

        let cases: [(label: String, payload: [String: Any], error: CorrelationError)] = [
            ("malformed UUID after a valid one", ["type": "result", "user_message_uuids": [queued.uuidString, "not-a-uuid"]], .invalidInputIdentity),
            ("plural not a string list", ["type": "result", "user_message_uuids": queued.uuidString], .invalidInputIdentity),
            (
                "65 entries, counted before duplicates are removed",
                ["type": "result", "user_message_uuids": Array(repeating: queued.uuidString, count: 65)],
                .invalidInputIdentity
            ),
            (
                "singular contradicts the plural's last identity",
                ["type": "result", "user_message_uuids": [running.uuidString, queued.uuidString], "user_message_uuid": running.uuidString],
                .invalidInputIdentity
            ),
            ("singular with an empty plural", ["type": "result", "user_message_uuids": [String](), "user_message_uuid": queued.uuidString], .invalidInputIdentity),
            ("answer omits the running execution's input", result([queued]), .missingAnswerIdentity),
            ("unstamped answer to a host execution", result(), .missingAnswerIdentity)
        ]
        for testCase in cases {
            XCTAssertThrowsError(try correlation.resolve(testCase.payload), testCase.label) { error in
                XCTAssertEqual(error as? CorrelationError, testCase.error, testCase.label)
            }
        }

        let sixtyFourEntries = [running.uuidString] + Array(repeating: queued.uuidString, count: 63)
        let answer: [String: Any] = ["type": "result", "user_message_uuids": sixtyFourEntries, "user_message_uuid": queued.uuidString]
        XCTAssertEqual(try correlation.resolve(answer).inputIDs, [running, queued], "Rejected results retired no input, and 64 entries are within the cap")
    }

    func testErrorResultBeforeExecutionEvidenceFailsUnlessInterruptIsPending() throws {
        let input = UUID()
        var errorResult = result()
        errorResult["subtype"] = "error_during_execution"
        errorResult["is_error"] = true

        var withoutInterrupt = matchingCorrelation()
        withoutInterrupt.register(input)
        XCTAssertThrowsError(try withoutInterrupt.resolve(errorResult)) { error in
            XCTAssertEqual(error as? CorrelationError, .missingAnswerIdentity)
        }

        var withInterrupt = matchingCorrelation()
        withInterrupt.register(input)
        _ = withInterrupt.beginInterrupt()
        XCTAssertEqual(try withInterrupt.resolve(errorResult).inputIDs, [], "The aborted turn's error answers no queued input")
        XCTAssertEqual(try withInterrupt.resolve(result([input])).inputIDs, [input])
    }

    func testInterruptCannotCancelALaterInput() throws {
        enum Ordering: CaseIterable {
            case resultBeforeAcknowledgement
            case acknowledgementBeforeExecutionEvidence
            case timeoutBeforeExecutionEvidence
        }
        for ordering in Ordering.allCases {
            let later = UUID()
            var correlation = matchingCorrelation()
            switch ordering {
            case .resultBeforeAcknowledgement:
                let running = UUID()
                correlation.register(running)
                try correlation.observeActivity(assistant(running))
                let token = correlation.beginInterrupt()
                correlation.register(later)
                XCTAssertTrue(try correlation.resolve(result([running])).interrupted, "The interrupt applies to the execution running when it was requested")
                XCTAssertFalse(correlation.isInterruptPending(token))
                correlation.acknowledgeInterrupt(token)
            case .acknowledgementBeforeExecutionEvidence:
                correlation.register(later)
                let token = correlation.beginInterrupt()
                correlation.acknowledgeInterrupt(token)
            case .timeoutBeforeExecutionEvidence:
                correlation.register(later)
                let token = correlation.beginInterrupt()
                correlation.abandonInterrupt(token)
            }
            try correlation.observeActivity(assistant(later))
            let resolution = try correlation.resolve(result([later]))
            XCTAssertEqual(resolution.inputIDs, [later], "\(ordering)")
            XCTAssertFalse(resolution.interrupted, "\(ordering)")
        }
    }

    func testActivityWithoutKnownHostInputTracksProviderExecutionWithoutOwningOutput() throws {
        let queued = UUID(), foreign = UUID()
        let cases: [(label: String, activity: [String: Any], answer: [String: Any])] = [
            ("unstamped activity", assistant(), result()),
            ("activity stamped only with a foreign identity", assistant(foreign), result([foreign]))
        ]
        for testCase in cases {
            var correlation = matchingCorrelation()
            correlation.register(queued)
            XCTAssertFalse(try correlation.observeActivity(testCase.activity), testCase.label)
            XCTAssertFalse(correlation.ownsOutput, testCase.label)
            XCTAssertNotNil(correlation.providerTurnID, testCase.label)

            XCTAssertEqual(try correlation.resolve(testCase.answer).inputIDs, [], testCase.label)
            XCTAssertNil(correlation.providerTurnID, testCase.label)
            XCTAssertEqual(try correlation.resolve(result([queued])).inputIDs, [queued], testCase.label)
        }

        var hostExecution = matchingCorrelation()
        hostExecution.register(queued)
        XCTAssertTrue(try hostExecution.observeActivity(assistant(queued)))
        XCTAssertNil(hostExecution.providerTurnID, "Activity for a known host input isn't provider work")
    }

    // MARK: - Controller ingress

    func testProviderStartedTurnKeepsIdleProbeBusyWithoutCountingAsHostWork() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        try await feed(assistant(text: "The background task finished; reading its output."), to: controller)
        let probeDuringTurn = await controller.idleProbe()
        let hostWorkDuringTurn = await controller.hasTurnInFlight
        XCTAssertTrue(probeDuringTurn.turnInFlight, "The idle gate must not retire the process during the turn")
        XCTAssertFalse(hostWorkDuringTurn, "A send during a turn the user can't see queues instead of interrupting it")

        try await feed(result(text: "Done."), to: controller)
        let probeAfterTurn = await controller.idleProbe()
        let hostWorkAfterTurn = await controller.hasTurnInFlight
        XCTAssertFalse(probeAfterTurn.turnInFlight)
        XCTAssertFalse(hostWorkAfterTurn)
    }

    func testUnsolicitedTurnCannotSettleOrSpeakForQueuedHostInput() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        try await feed(assistant(text: "unowned wake-up text"), to: controller)
        let host = await controller.test_beginTurnTracking()
        try await feed(approvalRequest(), to: controller)
        await controller.test_handleInboundLine(Data("unowned plaintext recovered while the queued input waited for service".utf8))
        try await feed(result(text: "unowned wake-up answer"), to: controller)
        let hostStillPending = await controller.hasTurnInFlight
        XCTAssertTrue(hostStillPending, "The wake-up turn's result must not settle the queued input")

        for parentKey in ["parent_tool_use_id", "parentToolUseId"] {
            var subagent = assistant(host, text: "subagent text stamped with the host input")
            subagent[parentKey] = "toolu_parent"
            try await feed(subagent, to: controller)
        }
        // Had a subagent frame claimed the main thread for the host input, this text would be owned.
        try await feed(assistant(text: "unowned main-thread text after subagent frames"), to: controller)
        try await feed(assistant(host, text: "owned text"), to: controller)
        try await feed(assistant(UUID(), text: "unowned text from a foreign input"), to: controller)
        try await feed(result([host], text: "owned final"), to: controller)
        try await feed(result([host], text: "unowned duplicate answer"), to: controller)

        let events = await eventsAfterShutdown(of: controller)
        XCTAssertEqual(settlements(in: events), [Settlement(turnIDs: [host], status: .completed)])
        let text = streamText(in: events)
        XCTAssertFalse(text.contains("unowned"), text)
        XCTAssertFalse(text.contains("subagent"), text)
        XCTAssertTrue(text.contains("owned text"), text)
        XCTAssertTrue(text.contains("owned final"), text)
        XCTAssertTrue(events.contains { event in
            if case .approvalRequest = event {
                return true
            }
            return false
        }, "Ownership filtering withholds output, not approvals")
    }

    func testPositionalCompletionEmitsOneTurnCompletedAtTheLifecycleBoundary() async throws {
        for observesLifecycle in [false, true] {
            let label = observesLifecycle ? "deferred until idle" : "immediate without lifecycle events"
            let controller = makeController()
            try await feed(initPayload(version: "2.1.291", capabilities: [String]()), to: controller)
            let input = await controller.test_beginTurnTracking()
            if observesLifecycle {
                try await feed(sessionState("running"), to: controller)
            }

            try await feed(result(), to: controller)
            let pendingAfterResult = await controller.hasTurnInFlight
            XCTAssertEqual(pendingAfterResult, observesLifecycle, label)
            if observesLifecycle {
                try await feed(sessionState("idle"), to: controller)
            }
            let pendingAfterBoundary = await controller.hasTurnInFlight
            XCTAssertFalse(pendingAfterBoundary, label)

            // Shutdown flushes deferred completions, so inspect delivery before shutdown.
            let stream = await controller.events
            await controller.resetEventsStreamForNewRun()
            var positional: [Settlement] = []
            for await event in stream {
                switch event {
                case let .turnCompleted(turnID, status):
                    positional.append(Settlement(turnIDs: [turnID], status: status))
                case .turnsCompleted:
                    XCTFail("Positional settlement must not emit a keyed completion: \(label)")
                default:
                    break
                }
            }
            XCTAssertEqual(positional, [Settlement(turnIDs: [input], status: .completed)], label)
            await controller.shutdown()
        }
    }

    func testDeferredCompletionKeepsTheInputItsResultAnswered() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        try await feed(sessionState("running"), to: controller)
        let first = await controller.test_beginTurnTracking()
        // Claude Code runs a wake-up turn before it serves the queued input.
        try await feed(assistant(text: "wake-up turn"), to: controller)
        try await feed(result(text: "wake-up answer"), to: controller)
        try await feed(sessionState("idle"), to: controller)
        try await feed(assistant(first), to: controller)
        try await feed(result([first]), to: controller)
        let second = await controller.test_beginTurnTracking()
        try await feed(sessionState("idle"), to: controller)
        let secondStillPending = await controller.hasTurnInFlight
        XCTAssertTrue(secondStillPending, "An input sent after the first answer must wait for its own")

        // Finish the stream without shutdown, which would flush deferred completions itself.
        let stream = await controller.events
        await controller.resetEventsStreamForNewRun()
        var events: [ClaudeNativeProcessSessionController.Event] = []
        for await event in stream {
            events.append(event)
        }
        XCTAssertEqual(settlements(in: events), [Settlement(turnIDs: [first], status: .completed)], "The idle frame settles the first input only")
        await controller.shutdown()
    }

    func testStdoutEOFReportsAnsweredOutcomeOnceAndFailsOnlyUnansweredInputs() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        try await feed(sessionState("running"), to: controller)
        let unanswered = await controller.test_beginTurnTracking()
        let answered = await controller.test_beginTurnTracking()
        try await feed(assistant(answered), to: controller)
        try await feed(result([answered]), to: controller)

        await controller.test_handleStdoutEOF()
        var events: [ClaudeNativeProcessSessionController.Event] = []
        for await event in await controller.events {
            events.append(event)
        }
        XCTAssertEqual(settlements(in: events), [
            Settlement(turnIDs: [answered], status: .completed),
            Settlement(turnIDs: [unanswered], status: .failed)
        ])
    }

    func testCorrelationFailureIsReportedWhenStdoutClosesRightAfterIt() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        let input = await controller.test_beginTurnTracking()
        try await feed(assistant(input), to: controller)
        var malformed = result([input])
        malformed["user_message_uuid"] = "not-a-uuid"
        // The CLI's last line has no newline, so it's handled while stdout closes.
        try await controller.test_handleStdoutChunk(JSONSerialization.data(withJSONObject: malformed))
        await controller.test_handleStdoutEOF()

        var events: [ClaudeNativeProcessSessionController.Event] = []
        for await event in await controller.events {
            events.append(event)
        }
        let errors = events.compactMap { event -> String? in
            guard case let .error(message) = event else { return nil }
            return message
        }
        XCTAssertEqual(errors, ["Claude input correlation failed; the process must be restarted."])
        XCTAssertEqual(settlements(in: events), [Settlement(turnIDs: [input], status: .failed)])
    }

    // MARK: - Runner settlement

    @MainActor
    func testCompletionRetiresEveryAnsweredInputBeforeDecidingTheRunEnds() throws {
        typealias Runner = ClaudeIntegratedAgentModeRunner
        let first = UUID(), second = UUID(), third = UUID(), predecessor = UUID()
        let session = AgentModeViewModel.TabSession(tabID: UUID())

        session.claudeExpectedTurnIDs = [first, second, third]
        let partial = try XCTUnwrap(Runner.settleCompletedTurnIDs([first, second], session: session, waitForAllUnprotected: true))
        XCTAssertFalse(partial.terminal, "A keyed answer waits for the run's other unprotected input")
        XCTAssertEqual(session.claudeExpectedTurnIDs, [third])
        XCTAssertEqual(Runner.settleCompletedTurnIDs([second, third], session: session, waitForAllUnprotected: true)?.terminal, true)
        XCTAssertNil(Runner.settleCompletedTurnIDs([third], session: session, waitForAllUnprotected: true), "A repeated answer is stale")

        session.claudeExpectedTurnIDs = [predecessor, first]
        session.claudeSupersedingProtectedTurnIDs = [predecessor]
        session.pendingSupersedingTurnCompletions = 1
        let predecessorOnly = try XCTUnwrap(Runner.settleCompletedTurnIDs([predecessor], session: session, waitForAllUnprotected: true))
        XCTAssertFalse(predecessorOnly.terminal, "A protected predecessor's answer doesn't end the run")
        XCTAssertFalse(predecessorOnly.answeredUnprotected, "Its outcome can't become the successor's")

        session.claudeExpectedTurnIDs = [predecessor, first]
        session.claudeSupersedingProtectedTurnIDs = [predecessor]
        session.pendingSupersedingTurnCompletions = 1
        XCTAssertEqual(Runner.settleCompletedTurnIDs([predecessor, first], session: session, waitForAllUnprotected: true)?.terminal, true)
        XCTAssertTrue(session.claudeExpectedTurnIDs.isEmpty)
        XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.isEmpty)
        XCTAssertEqual(session.pendingSupersedingTurnCompletions, 0)

        session.claudeExpectedTurnIDs = [first, second]
        XCTAssertEqual(
            Runner.settleCompletedTurnIDs([first], session: session, waitForAllUnprotected: false)?.terminal,
            true,
            "Positional settlement keeps ending the run at its first unprotected answer"
        )
    }

    // MARK: - Fixtures

    private struct Settlement: Equatable {
        let turnIDs: [UUID]
        let status: ClaudeNativeProcessSessionController.TurnStatus
    }

    private func makeController() -> ClaudeNativeProcessSessionController {
        // A fallback long enough that only an `idle` frame settles a deferred completion.
        ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false"),
            authoritativeTurnIdleFallbackSeconds: 600
        )
    }

    private func feed(_ payload: [String: Any], to controller: ClaudeNativeProcessSessionController) async throws {
        try await controller.test_handleInboundLine(JSONSerialization.data(withJSONObject: payload))
    }

    /// Shutting down finishes the event stream, so every event the controller emitted can be read.
    private func eventsAfterShutdown(of controller: ClaudeNativeProcessSessionController) async -> [ClaudeNativeProcessSessionController.Event] {
        await controller.shutdown()
        var events: [ClaudeNativeProcessSessionController.Event] = []
        for await event in await controller.events {
            events.append(event)
        }
        return events
    }

    private func settlements(in events: [ClaudeNativeProcessSessionController.Event]) -> [Settlement] {
        events.compactMap { event in
            switch event {
            case let .turnCompleted(turnID, status): Settlement(turnIDs: [turnID], status: status)
            case let .turnsCompleted(turnIDs, status): Settlement(turnIDs: turnIDs, status: status)
            default: nil
            }
        }
    }

    private func streamText(in events: [ClaudeNativeProcessSessionController.Event]) -> String {
        events.compactMap { event in
            guard case let .stream(result) = event else { return nil }
            return result.text ?? result.reasoning
        }.joined(separator: "\n")
    }

    private func sessionState(_ state: String) -> [String: Any] {
        ["type": "system", "subtype": "session_state_changed", "state": state]
    }

    private func approvalRequest() -> [String: Any] {
        [
            "type": "control_request",
            "request_id": "approval-1",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"]]
        ]
    }

    private func initPayload(version: Any? = "2.1.292", capabilities: Any = ["msg_lifecycle_v1"]) -> [String: Any] {
        var payload: [String: Any] = ["type": "system", "subtype": "init", "capabilities": capabilities]
        if let version {
            payload["claude_code_version"] = version
        }
        return payload
    }

    private func matchingCorrelation() -> ClaudeNativeTurnCorrelation {
        var correlation = ClaudeNativeTurnCorrelation()
        correlation.observeInit(initPayload())
        return correlation
    }

    private func assistant(_ inputID: UUID? = nil, text: String = "working") -> [String: Any] {
        var payload: [String: Any] = [
            "type": "assistant",
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]]
        ]
        if let inputID {
            payload["user_message_uuid"] = inputID.uuidString
        }
        return payload
    }

    private func result(_ inputIDs: [UUID]? = nil, text: String = "answer") -> [String: Any] {
        var payload: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": text]
        if let inputIDs, let lastID = inputIDs.last {
            payload["user_message_uuids"] = inputIDs.map(\.uuidString)
            payload["user_message_uuid"] = lastID.uuidString
        }
        return payload
    }
}
