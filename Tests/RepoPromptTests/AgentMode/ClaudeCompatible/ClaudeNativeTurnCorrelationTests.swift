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

    func testProviderExecutionOwnsItsOutputAndIsNamedByItsResult() throws {
        let queued = UUID(), foreign = UUID()
        let cases: [(label: String, activity: [String: Any], answer: [String: Any])] = [
            ("unstamped activity", assistant(), result()),
            ("activity stamped only with a foreign identity", assistant(foreign), result([foreign]))
        ]
        for testCase in cases {
            var correlation = matchingCorrelation()
            correlation.register(queued)
            XCTAssertEqual(try correlation.observeActivity(testCase.activity), .provider, testCase.label)
            let providerTurnID = try XCTUnwrap(correlation.providerTurnID, testCase.label)
            var retired = correlation
            XCTAssertEqual(retired.drain(), [queued, providerTurnID], "Retiring the transport also fails the provider turn: \(testCase.label)")

            let resolution = try correlation.resolve(testCase.answer)
            XCTAssertEqual(resolution.inputIDs, [], testCase.label)
            XCTAssertEqual(resolution.providerTurnID, providerTurnID, testCase.label)
            XCTAssertNil(correlation.providerTurnID, testCase.label)
            XCTAssertEqual(try correlation.resolve(result([queued])).inputIDs, [queued], testCase.label)
        }

        var hostExecution = matchingCorrelation()
        hostExecution.register(queued)
        XCTAssertEqual(try hostExecution.observeActivity(assistant(queued)), .host)
        XCTAssertNil(hostExecution.providerTurnID, "Activity for a known host input isn't provider work")
    }

    func testProviderExecutionThatPicksUpHostInputHandsItTheOutputAndSettlesBoth() throws {
        let host = UUID()
        var correlation = matchingCorrelation()
        correlation.register(host)
        XCTAssertEqual(try correlation.observeActivity(assistant()), .provider)
        let providerTurnID = try XCTUnwrap(correlation.providerTurnID)

        XCTAssertEqual(try correlation.observeActivity(assistant(host)), .host, "Claude Code picked the host input up into its own turn")
        XCTAssertEqual(correlation.providerTurnID, providerTurnID, "Picking up input doesn't start another turn")
        XCTAssertNil(try correlation.observeActivity(assistant(UUID())), "A foreign message in that turn belongs to no run")

        let resolution = try correlation.resolve(result([host]))
        XCTAssertEqual(resolution.inputIDs, [host])
        XCTAssertEqual(resolution.providerTurnID, providerTurnID, "One result settles the host input and the provider turn together")
    }

    // MARK: - Controller ingress

    func testProviderStartedTurnIsInFlightUntilItsCompletion() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        try await feed(sessionState("running"), to: controller)
        try await feed(assistant(text: "The background task finished; reading its output."), to: controller)
        let probeDuringTurn = await controller.idleProbe()
        let sendSeesTurn = await controller.hasTurnInFlight
        XCTAssertTrue(probeDuringTurn.turnInFlight, "The idle gate must not retire the process during the turn")
        XCTAssertTrue(sendSeesTurn, "A send during the turn must treat it as running")

        try await feed(result(text: "Done."), to: controller)
        let probeAwaitingIdle = await controller.idleProbe()
        let sendSeesDeferredCompletion = await controller.hasTurnInFlight
        XCTAssertTrue(probeAwaitingIdle.turnInFlight, "The turn stays busy until Claude Code reports idle")
        XCTAssertTrue(sendSeesDeferredCompletion)

        try await feed(sessionState("idle"), to: controller)
        let probeAfterTurn = await controller.idleProbe()
        let sendAfterTurn = await controller.hasTurnInFlight
        XCTAssertFalse(probeAfterTurn.turnInFlight)
        XCTAssertFalse(sendAfterTurn)

        let events = await eventsAfterShutdown(of: controller)
        let started = providerTurnStarts(in: events)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(
            settlements(in: events),
            started.map { Settlement(turnIDs: [$0], status: .completed) },
            "The completion names the turn its start announced"
        )
    }

    func testProviderTurnIsAnnouncedBeforeItsOutputOrApprovalRequest() async throws {
        let cases: [(label: String, firstEvidence: [String: Any])] = [
            ("output first", assistant(text: "wake-up output")),
            ("approval request first", approvalRequest())
        ]
        for testCase in cases {
            let controller = makeController()
            try await feed(initPayload(), to: controller)
            try await feed(testCase.firstEvidence, to: controller)
            try await feed(assistant(text: "more wake-up output"), to: controller)
            try await feed(result(text: "wake-up answer"), to: controller)

            let events = await eventsAfterShutdown(of: controller)
            let started = providerTurnStarts(in: events)
            XCTAssertEqual(started.count, 1, testCase.label)
            let startIndex = try XCTUnwrap(events.firstIndex { event in
                if case .providerTurnStarted = event {
                    return true
                }
                return false
            }, testCase.label)
            let firstTurnEventIndex = try XCTUnwrap(events.firstIndex { event in
                switch event {
                case .approvalRequest: true
                case let .stream(result): result.text?.contains("wake-up") == true
                default: false
                }
            }, testCase.label)
            XCTAssertLessThan(startIndex, firstTurnEventIndex, testCase.label)
            let text = streamText(in: events)
            XCTAssertTrue(text.contains("more wake-up output"), testCase.label)
            XCTAssertTrue(text.contains("wake-up answer"), testCase.label)
            XCTAssertEqual(settlements(in: events), started.map { Settlement(turnIDs: [$0], status: .completed) }, testCase.label)
        }
    }

    func testFramesWithoutMainThreadActivityStartNoProviderTurn() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        // The frames Claude Code 2.1.319 sent around a background command's end, before its wake-up
        // turn, plus subagent and orphan tool output and results no execution preceded.
        var subagentMessage = assistant(text: "subagent text")
        subagentMessage["parent_tool_use_id"] = "toolu_agent"
        let frames: [[String: Any]] = [
            ["type": "system", "subtype": "task_started", "task_id": "task-1", "task_type": "local_bash", "tool_use_id": "toolu_bg", "description": "Sleep 60 seconds"],
            ["type": "system", "subtype": "task_updated", "task_id": "task-1", "patch": ["status": "completed"]],
            ["type": "system", "subtype": "task_notification", "task_id": "task-1", "tool_use_id": "toolu_bg", "status": "completed", "summary": "Background command completed (exit code 0)"],
            ["type": "system", "subtype": "background_tasks_changed", "tasks": [[String: Any]]()],
            initPayload(),
            ["type": "system", "subtype": "thinking_tokens", "estimated_tokens": 50, "estimated_tokens_delta": 50],
            ["type": "system", "subtype": "notification", "key": "stop-hook-error", "text": "Stop hook error occurred"],
            subagentMessage,
            ["type": "stream_event", "parentToolUseId": "toolu_agent", "event": ["type": "message_start"]],
            ["type": "command_lifecycle", "parent_tool_use_id": "toolu_agent", "state": "started", "command_uuid": UUID().uuidString],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_orphan", "content": "orphan output"]]]],
            result(text: "result with no execution"),
            result([UUID()], text: "foreign result with no execution")
        ]
        for frame in frames {
            try await feed(frame, to: controller)
        }
        let probeAfterFrames = await controller.idleProbe()
        let sendSeesTurn = await controller.hasTurnInFlight
        XCTAssertFalse(probeAfterFrames.turnInFlight)
        XCTAssertFalse(sendSeesTurn)

        // The wake-up turn's first main-thread frame does start it.
        try await feed(assistant(text: "The background command finished."), to: controller)
        let events = await eventsAfterShutdown(of: controller)
        XCTAssertEqual(providerTurnStarts(in: events).count, 1)
        XCTAssertEqual(settlements(in: events), [], "Results no execution preceded settle nothing")
    }

    func testUnsolicitedTurnCannotSettleOrSpeakForQueuedHostInput() async throws {
        let controller = makeController()
        try await feed(initPayload(), to: controller)
        try await feed(assistant(text: "provider wake-up text"), to: controller)
        let host = await controller.test_beginTurnTracking()
        try await feed(approvalRequest(), to: controller)
        await controller.test_handleInboundLine(Data("provider plaintext recovered while the queued input waited for service".utf8))
        try await feed(result(text: "provider wake-up answer"), to: controller)
        let hostStillPending = await controller.hasTurnInFlight
        XCTAssertTrue(hostStillPending, "The wake-up turn's result must not settle the queued input")

        for parentKey in ["parent_tool_use_id", "parentToolUseId"] {
            var subagent = assistant(host, text: "subagent text stamped with the host input")
            subagent[parentKey] = "toolu_parent"
            try await feed(subagent, to: controller)
        }
        // Had a subagent frame claimed the main thread for the host input, this text would belong
        // to the host input instead of starting a second provider turn.
        try await feed(assistant(text: "provider main-thread text after subagent frames"), to: controller)
        try await feed(assistant(host, text: "owned text"), to: controller)
        try await feed(assistant(UUID(), text: "unowned text from a foreign input"), to: controller)
        try await feed(result([host], text: "owned final"), to: controller)
        try await feed(result([host], text: "unowned duplicate answer"), to: controller)

        let events = await eventsAfterShutdown(of: controller)
        // The unstamped text after the subagent frames starts a second provider turn, which then
        // picks up the host input, so one result settles both.
        let started = providerTurnStarts(in: events)
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(settlements(in: events), [
            Settlement(turnIDs: Array(started.prefix(1)), status: .completed),
            Settlement(turnIDs: [host] + started.dropFirst(), status: .completed)
        ])
        let text = streamText(in: events)
        XCTAssertFalse(text.contains("unowned"), text)
        XCTAssertFalse(text.contains("subagent text"), text)
        XCTAssertTrue(text.contains("provider wake-up text"), text)
        XCTAssertTrue(text.contains("provider plaintext recovered"), text)
        XCTAssertTrue(text.contains("provider wake-up answer"), text)
        XCTAssertTrue(text.contains("provider main-thread text after subagent frames"), text)
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
        let wakeUp = providerTurnStarts(in: events)
        XCTAssertEqual(wakeUp.count, 1)
        XCTAssertEqual(
            settlements(in: events),
            [Settlement(turnIDs: wakeUp, status: .completed), Settlement(turnIDs: [first], status: .completed)],
            "Each idle frame settles one earlier result's targets, never the second input"
        )
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

    private func providerTurnStarts(in events: [ClaudeNativeProcessSessionController.Event]) -> [UUID] {
        events.compactMap { event in
            guard case let .providerTurnStarted(turnID) = event else { return nil }
            return turnID
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
