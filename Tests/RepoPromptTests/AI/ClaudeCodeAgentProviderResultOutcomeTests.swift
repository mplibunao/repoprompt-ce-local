import Foundation
@testable import RepoPromptApp
import XCTest

/// The stream tests run the headless Claude provider against a stub CLI that replays stream-json lines
/// recorded from Claude Code 2.1.307, with fields that don't affect the outcome removed.
final class ClaudeCodeAgentProviderResultOutcomeTests: XCTestCase {
    func testErrorResultFailsTheStreamWithTheResultText() async throws {
        // A rejected token: the CLI retries once, writes a synthetic assistant message, then reports
        // `subtype: success` with `is_error: true` and exits 1.
        let outcome = try await runProvider(replaying: [
            #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":2,"retry_delay_ms":580,"error_status":401,"error":"authentication_failed","session_id":"s1"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","type":"message","content":[{"type":"text","text":"Failed to authenticate. API Error: 401 token expired or incorrect"}]},"session_id":"s1","error":"authentication_failed","is_api_error_message":true,"api_error_status":401}"#,
            #"{"type":"result","subtype":"success","is_error":true,"api_error_status":401,"terminal_reason":"api_error","stop_reason":"stop_sequence","result":"Failed to authenticate. API Error: 401 token expired or incorrect","session_id":"s1","num_turns":1,"total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}"#
        ], exitStatus: 1)

        guard case let .invalidConfiguration(detail)? = outcome.error as? AIProviderError else {
            return XCTFail("Expected the stream to fail with the result text, got \(String(describing: outcome.error))")
        }
        XCTAssertEqual(detail, "Failed to authenticate. API Error: 401 token expired or incorrect")
    }

    func testRetryEventFollowedBySuccessfulResultCompletesTheStream() async throws {
        // An overloaded response the CLI retried, then a normal answer.
        let outcome = try await runProvider(replaying: [
            #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":2,"retry_delay_ms":596,"error_status":529,"error":"overloaded","session_id":"s2"}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","role":"assistant","stop_reason":null,"type":"message","content":[{"type":"text","text":"hi"}]},"session_id":"s2"}"#,
            #"{"type":"system","subtype":"post_turn_summary","status_category":"review_ready","status_detail":"hi","session_id":"s2"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"terminal_reason":"completed","stop_reason":"end_turn","result":"hi","session_id":"s2","num_turns":1,"total_cost_usd":0.000066,"usage":{"input_tokens":12,"output_tokens":2}}"#
        ], exitStatus: 0)

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.finalContent, "hi")
    }

    func testErrorSubtypeErrorsOrAnAbortTheCallerDidNotRequestFailTheRun() {
        let provider = ClaudeCodeAgentProvider(
            runner: CLIProcessRunner(config: CLIProcessConfiguration(
                command: "/usr/bin/false",
                workingDirectory: FileManager.default.temporaryDirectory.path,
                environment: [:],
                additionalPaths: [],
                shellLookupMode: .disabled
            )),
            config: .discovery(commandName: "/usr/bin/false"),
            serverReadiness: { true }
        )
        let cases: [(label: String, line: String, expected: String)] = [
            (
                "error subtype",
                #"{"type":"result","subtype":"error_max_turns","session_id":"s3"}"#,
                "failed: Claude CLI ended the run with an error result (error_max_turns)."
            ),
            (
                "errors",
                #"{"type":"result","subtype":"success","errors":[{"message":"Upstream timeout"}],"result":"partial","session_id":"s3"}"#,
                "failed: Upstream timeout"
            ),
            (
                // Reads as cancelled, but nothing cancelled the run.
                "abort",
                #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["The operation was aborted due to timeout"],"session_id":"s3"}"#,
                "failed: The operation was aborted due to timeout"
            )
        ]
        for testCase in cases {
            let outcome: String
            do {
                let events = try provider.parseStreamEvents(Data(testCase.line.utf8))
                outcome = "parsed \(events.count) events"
            } catch is CancellationError {
                outcome = "cancelled"
            } catch let AIProviderError.invalidConfiguration(detail) {
                outcome = "failed: \(detail)"
            } catch {
                outcome = "unexpected error: \(error)"
            }
            XCTAssertEqual(outcome, testCase.expected, testCase.label)
        }
    }

    private struct StreamOutcome {
        var finalContent: String?
        var error: Error?
    }

    private func runProvider(replaying lines: [String], exitStatus: Int32) async throws -> StreamOutcome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeAgentProviderResultOutcomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recording = root.appendingPathComponent("stream.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: recording, atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("claude-stub")
        try """
        #!/bin/sh
        cat >/dev/null
        cat '\(recording.path)'
        exit \(exitStatus)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let configService = MCPConfigExportService(
            identity: .repoPromptCE(.debug),
            configDirectoryURL: root.appendingPathComponent("MCP", isDirectory: true),
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )
        _ = try await configService.prepareStableWrapperConfigFile()
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: executable.path,
            workingDirectory: root.path,
            environment: ProcessInfo.processInfo.environment,
            additionalPaths: [],
            shellLookupMode: .disabled
        ))
        let provider = ClaudeCodeAgentProvider(
            runner: runner,
            config: .discovery(commandName: executable.path),
            configService: configService,
            serverReadiness: { true }
        )

        var outcome = StreamOutcome()
        let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: "test"), runID: UUID())
        do {
            for try await result in stream where result.type == "final_content" {
                outcome.finalContent = result.text
            }
        } catch {
            outcome.error = error
        }
        await provider.dispose()
        return outcome
    }
}
