import Foundation
@testable import RepoPromptApp
import XCTest

final class OracleHeadlessRuntimeTests: XCTestCase {
    @MainActor
    func testExecuteAccumulatesStreamOutputAndClearsTabRegistration() async throws {
        let tabID = UUID()
        let streamID = UUID()
        var progressText: [String] = []

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    continuation.yield(
                        ChatStreamOutput(
                            text: "  Hello ",
                            reasoning: nil,
                            tokens: ChatTokenInfo(promptTokens: 1)
                        )
                    )
                    continuation.yield(
                        ChatStreamOutput(
                            text: "world  ",
                            reasoning: nil,
                            tokens: ChatTokenInfo(promptTokens: 2, completionTokens: 3, cost: 0.25),
                            terminalOutcome: .completed
                        )
                    )
                    continuation.finish()
                }
                return (streamID, stream)
            },
            cancelStream: { _ in },
            cleanupConversation: { _, _ in }
        )

        let output = try await runtime.execute(
            message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
            model: .claude4Sonnet,
            tabID: tabID,
            completionPolicy: .contextBuilderStrict,
            onProgress: { text, _ in progressText.append(text) }
        )

        XCTAssertEqual(output.text, "Hello world")
        XCTAssertEqual(output.tokenInfo.promptTokens, 2)
        XCTAssertEqual(output.tokenInfo.completionTokens, 3)
        XCTAssertEqual(output.tokenInfo.cost, 0.25)
        XCTAssertEqual(progressText, ["  Hello ", "  Hello world  "])
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }

    @MainActor
    func testExecuteKeepsTransportActivityOutOfSemanticContent() async throws {
        let tabID = UUID()
        let expected = "Line one\n\n  Indented café 🧪\nLine three reconnecting"
        var progressText: [String] = []

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    if let activity = AIQueriesService.transportActivityOutput(
                        for: AIStreamResult(type: "status", text: "Reconnecting... 1/5")
                    ) {
                        continuation.yield(activity)
                    }
                    continuation.yield(ChatStreamOutput(
                        text: "Line one\n\n  Indented café 🧪\n",
                        reasoning: nil,
                        tokens: ChatTokenInfo()
                    ))
                    if let activity = AIQueriesService.transportActivityOutput(
                        for: AIStreamResult(type: "status", text: "Retrying request")
                    ) {
                        continuation.yield(activity)
                    }
                    continuation.yield(ChatStreamOutput(
                        text: "Line three reconnecting",
                        reasoning: nil,
                        tokens: ChatTokenInfo(),
                        terminalOutcome: .completed
                    ))
                    continuation.finish()
                }
                return (UUID(), stream)
            },
            cancelStream: { _ in },
            cleanupConversation: { _, _ in }
        )

        let output = try await runtime.execute(
            message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
            model: .claude4Sonnet,
            tabID: tabID,
            completionPolicy: .contextBuilderStrict,
            onProgress: { text, _ in progressText.append(text) }
        )

        XCTAssertEqual(output.text, expected)
        XCTAssertEqual(progressText.last, expected)
        XCTAssertTrue(progressText.allSatisfy { !$0.contains("Reconnecting") && !$0.contains("Retrying") })
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }

    @MainActor
    func testStrictCompletedTransportOnlyStreamIsEmptyContent() async throws {
        let tabID = UUID()
        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    if let activity = AIQueriesService.transportActivityOutput(
                        for: AIStreamResult(type: "status", text: "Reconnecting... 1/5")
                    ) {
                        continuation.yield(activity)
                    }
                    continuation.yield(ChatStreamOutput(
                        text: "",
                        reasoning: nil,
                        tokens: ChatTokenInfo(),
                        terminalOutcome: .completed
                    ))
                    continuation.finish()
                }
                return (UUID(), stream)
            },
            cancelStream: { _ in },
            cleanupConversation: { _, _ in }
        )

        do {
            _ = try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .contextBuilderStrict
            )
            XCTFail("Expected transport-only completion to have no semantic content")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .emptyProcessedContent)
        }
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }

    @MainActor
    func testStrictTerminalFailuresRemainTyped() async throws {
        let scenarios: [(ChatStreamTerminalOutcome?, OracleContextBuilderCompletionError)] = [
            (.incomplete(reason: "provider stopped"), .providerTerminatedIncomplete(reason: "provider stopped")),
            (nil, .streamEndedWithoutProviderCompletion)
        ]

        for (terminalOutcome, expectedError) in scenarios {
            let tabID = UUID()
            let runtime = OracleHeadlessRuntime(
                sendPrompt: { _, _ in
                    let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                        continuation.yield(ChatStreamOutput(
                            text: "partial",
                            reasoning: nil,
                            tokens: ChatTokenInfo(),
                            terminalOutcome: terminalOutcome
                        ))
                        continuation.finish()
                    }
                    return (UUID(), stream)
                },
                cancelStream: { _ in },
                cleanupConversation: { _, _ in }
            )

            do {
                _ = try await runtime.execute(
                    message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                    model: .claude4Sonnet,
                    tabID: tabID,
                    completionPolicy: .contextBuilderStrict
                )
                XCTFail("Expected strict terminal failure")
            } catch let error as OracleContextBuilderCompletionError {
                XCTAssertEqual(error, expectedError)
            }
            XCTAssertFalse(runtime.hasActiveStream(for: tabID))
        }
    }

    @MainActor
    func testTimeoutWithOnlyAChatNameTagStaysAFailure() async throws {
        let tabID = UUID()
        let streamID = UUID()
        let timeoutGate = OracleHeadlessTimeoutTestGate()
        let cancellationRecorder = OracleHeadlessStreamCancellationRecorder()

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    continuation.yield(ChatStreamOutput(text: "<chatName=\"Only a name\"/>\n", reasoning: nil, tokens: ChatTokenInfo(promptTokens: 1)))
                }
                return (streamID, stream)
            },
            cancelStream: { id in
                await cancellationRecorder.record(id)
            },
            cleanupConversation: { _, _ in },
            timeout: .seconds(7),
            sleep: { _ in
                await timeoutGate.wait()
            }
        )

        let execution = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .contextBuilderStrict
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        await timeoutGate.release()
        do {
            _ = try await execution.value
            XCTFail("Expected the empty timeout to fail")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .emptyProcessedContent)
        }
        let cancelledStreamIDs = await cancellationRecorder.streamIDs()
        XCTAssertEqual(cancelledStreamIDs, [streamID])
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }

    @MainActor
    func testTimeoutPreservesAccumulatedTextAndAddsMarker() async throws {
        let tabID = UUID()
        let streamID = UUID()
        let progressReceived = expectation(description: "partial response received")
        let timeoutGate = OracleHeadlessTimeoutTestGate()
        let cancellationRecorder = OracleHeadlessStreamCancellationRecorder()

        let runtime = OracleHeadlessRuntime(
            sendPrompt: { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    continuation.yield(
                        ChatStreamOutput(
                            text: "Partial headless answer",
                            reasoning: nil,
                            tokens: ChatTokenInfo(promptTokens: 4, completionTokens: 5)
                        )
                    )
                }
                return (streamID, stream)
            },
            cancelStream: { id in
                await cancellationRecorder.record(id)
            },
            cleanupConversation: { _, _ in },
            timeout: .seconds(7),
            sleep: { _ in
                await timeoutGate.wait()
            }
        )

        let execution = Task { @MainActor in
            try await runtime.execute(
                message: AIMessage(systemPrompt: "system", userMessage: "prompt"),
                model: .claude4Sonnet,
                tabID: tabID,
                completionPolicy: .contextBuilderStrict,
                onProgress: { _, _ in progressReceived.fulfill() }
            )
        }

        await fulfillment(of: [progressReceived], timeout: 1)
        await timeoutGate.release()
        let output = try await execution.value

        let expectedMarker =
            "[RepoPrompt: response ended after 7 s without completion; content above is partial]"
        XCTAssertEqual(output.text, "Partial headless answer\n\n\(expectedMarker)")
        XCTAssertEqual(output.timeout?.partialText, "Partial headless answer")
        XCTAssertEqual(output.timeout?.marker, expectedMarker)
        XCTAssertEqual(output.tokenInfo.promptTokens, 4)
        XCTAssertEqual(output.tokenInfo.completionTokens, 5)
        let cancelledStreamIDs = await cancellationRecorder.streamIDs()
        XCTAssertEqual(cancelledStreamIDs, [streamID])
        XCTAssertFalse(runtime.hasActiveStream(for: tabID))
    }
}

private actor OracleHeadlessTimeoutTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor OracleHeadlessStreamCancellationRecorder {
    private var recordedStreamIDs: [ChatStreamID] = []

    func record(_ streamID: ChatStreamID) {
        recordedStreamIDs.append(streamID)
    }

    func streamIDs() -> [ChatStreamID] {
        recordedStreamIDs
    }
}
