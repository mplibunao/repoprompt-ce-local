import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeSDKNDJSONTranslatorTests: XCTestCase {
    func testAssistantToolAndResultSmokePreservesUsageArgsAndStableInvocationID() throws {
        var translator = ClaudeSDKNDJSONTranslator(
            treatsToolResultErrorsAsHostOwned: { $0 == "mcp__RepoPromptCE__read_file" }
        )
        let line = jsonLine([
            "type": "assistant",
            "message": [
                "usage": [
                    "input_tokens": 7,
                    "output_tokens": 3,
                    "cache_read_input_tokens": 5,
                    "cache_creation_input_tokens": 2
                ],
                "content": [
                    ["type": "text", "text": "Hello"],
                    [
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "mcp__RepoPromptCE__read_file",
                        "input": ["path": "Sources/App.swift"]
                    ]
                ]
            ]
        ])

        let results = translator.parseNDJSONLine(line)

        XCTAssertEqual(results.map(\.type), ["usage", "content", "tool_call"])
        guard results.count == 3 else { return }
        XCTAssertEqual(results[0].promptTokens, 7)
        XCTAssertEqual(results[0].completionTokens, 3)
        XCTAssertEqual(results[0].contextUsedTokens, 14)
        XCTAssertEqual(results[1].text, "Hello")
        XCTAssertEqual(results[2].toolName, "mcp__RepoPromptCE__read_file")
        let invocationID = try XCTUnwrap(results[2].toolInvocationID)
        XCTAssertEqual(try jsonObject(from: results[2].toolArgsJSON), ["path": "Sources/App.swift"])

        let resultLine = jsonLine([
            "type": "user",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_1",
                    "content": [["type": "text", "text": "contents"]]
                ]]
            ]
        ])
        let toolResult = try XCTUnwrap(translator.parseNDJSONLine(resultLine).first)
        XCTAssertEqual(toolResult.type, "tool_result")
        XCTAssertEqual(toolResult.toolName, "mcp__RepoPromptCE__read_file")
        XCTAssertEqual(toolResult.toolOutput, "contents")
        XCTAssertEqual(toolResult.toolInvocationID, invocationID)
        XCTAssertNil(toolResult.toolIsError, "Host-owned tool result errors are tracked by the host completion handler, not inferred here.")
    }

    func testLifecycleAndStreamSmokeCoversSessionCancellationDeltaStopAndContextUsage() throws {
        var translator = ClaudeSDKNDJSONTranslator()

        let initResults = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "init",
            "session_id": "claude-session-1"
        ]))
        XCTAssertEqual(initResults.map(\.type), [ClaudeProviderStreamResult.lifecycleType])
        XCTAssertEqual(translator.cliSessionID, "claude-session-1")

        let usage = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_start",
                "message": [
                    "usage": [
                        "inputTokens": 4,
                        "outputTokens": 0,
                        "cacheReadInputTokens": 6
                    ]
                ]
            ]
        ]))
        XCTAssertEqual(usage.first?.type, "usage")
        XCTAssertEqual(usage.first?.contextUsedTokens, 10)

        let delta = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "partial"]
            ]
        ]))
        XCTAssertEqual(delta.first?.type, "content")
        XCTAssertEqual(delta.first?.text, "partial")

        let stop = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": ["input_tokens": 4, "output_tokens": 9]
            ]
        ]))
        XCTAssertEqual(stop.map(\.type), ["usage", "message_stop"])
        XCTAssertEqual(stop.last?.stopReason, "end_turn")

        let cancelled = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "error_during_execution",
            "session_id": "claude-session-2",
            "is_error": true,
            "errors": ["Request was aborted by user"],
            "stop_reason": "cancelled",
            "usage": ["input_tokens": 11, "output_tokens": 0],
            "total_cost_usd": 0.12
        ]))
        XCTAssertEqual(cancelled.map(\.type), ["message_stop"])
        let cancelledStop = try XCTUnwrap(cancelled.first)
        XCTAssertEqual(cancelledStop.providerSessionID, "claude-session-2")
        XCTAssertEqual(cancelledStop.promptTokens, 11)
        XCTAssertEqual(cancelledStop.completionTokens, 0)
        XCTAssertEqual(cancelledStop.cost, 0.12)
        XCTAssertEqual(cancelledStop.stopReason, "cancelled")
        XCTAssertEqual(translator.cliSessionID, "claude-session-2")
    }

    func testBackgroundTasksChangedReportsLiveNonAmbientTasks() {
        var translator = ClaudeSDKNDJSONTranslator()
        // The entry Claude Code 2.1.304 sent for a backgrounded shell command, which has no
        // `ambient` key.
        let shell: [String: Any] = [
            "task_id": "b6gh9ra6z",
            "run_id": "0mvgkv0tj-d646b612",
            "task_type": "local_bash",
            "description": "Sleep for 900 seconds in background"
        ]
        let subagent: [String: Any] = ["task_id": "a3subagent", "task_type": "local_agent", "ambient": false]
        let monitor: [String: Any] = ["task_id": "m7monitor", "task_type": "monitor_ws", "ambient": true]

        let live = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "background_tasks_changed",
            "tasks": [shell, subagent, monitor],
            "uuid": "4f7c0a52-6a43-4d5e-9d1b-2f0e8c1b7a90",
            "session_id": "claude-session-1"
        ]))
        XCTAssertEqual(live.map(\.type), ["background_tasks_changed"])
        XCTAssertEqual(live.first?.text, "b6gh9ra6z\na3subagent")

        // Each event replaces the whole set, so an empty set must still be reported.
        let cleared = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "background_tasks_changed",
            "tasks": [Any](),
            "session_id": "claude-session-1"
        ]))
        XCTAssertEqual(cleared.map(\.type), ["background_tasks_changed"])
        XCTAssertEqual(cleared.first?.text, "")

        // An entry without a usable task ID still counts as live unless it is ambient.
        let unidentifiedTasks: [[String: Any]] = [
            ["task_type": "local_bash"],
            ["task_id": "  ", "task_type": "local_bash"],
            ["task_type": "monitor_ws", "ambient": true]
        ]
        let unidentified = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "background_tasks_changed",
            "tasks": unidentifiedTasks
        ]))
        XCTAssertEqual(unidentified.map(\.type), ["background_tasks_changed"])
        XCTAssertEqual(unidentified.first?.text?.split(separator: "\n").count, 2, "entries without a task ID")

        // A payload with no `tasks` array says nothing about the set, so it yields no result.
        let missing = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "background_tasks_changed",
            "session_id": "claude-session-1"
        ]))
        XCTAssertEqual(missing.map(\.type), [], "payload without a tasks array")
    }

    private func jsonObject(from jsonString: String?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let value = try XCTUnwrap(jsonString, file: file, line: line)
        let data = Data(value.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String], file: file, line: line)
    }

    private func jsonLine(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            XCTFail("Invalid JSON fixture", file: file, line: line)
            return Data()
        }
        return data
    }
}
