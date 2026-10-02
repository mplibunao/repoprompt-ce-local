import Foundation
import SwiftAnthropic

class AnthropicProvider: AIProvider {
    private let service: AnthropicService

    init(apiKey: String, betaHeaders: [String] = ["messages-2023-12-15", "prompt-caching-2024-07-31", "output-128k-2025-02-19"]) {
        service = AnthropicServiceFactory.service(apiKey: apiKey, betaHeaders: betaHeaders)
    }

    static func isSuccessfulCompletionStopReason(_ stopReason: String) -> Bool {
        switch stopReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "end_turn", "stop_sequence":
            true
        default:
            false
        }
    }

    private static func createMessages(for aiMessage: AIMessage) -> [MessageParameter.Message] {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        var messages: [MessageParameter.Message] = []

        for (idx, entry) in aiMessage.conversationMessages.enumerated() {
            let contentText: String = if let lastIdx = lastUserIndex,
                                         entry.role == .user,
                                         idx == lastIdx,
                                         !tail.isEmpty
            {
                "\(tail)\n\n\(entry.content)"
            } else {
                entry.content
            }

            let role: MessageParameter.Message.Role = (entry.role == .user) ? .user : .assistant
            messages.append(
                MessageParameter.Message(
                    role: role,
                    content: .text(contentText)
                )
            )
        }

        return messages
    }

    private static func createSystemParameter(systemPrompt: String) -> MessageParameter.System {
        .list([
            MessageParameter.Cache(
                type: .text,
                text: systemPrompt,
                cacheControl: MessageParameter.CacheControl(type: .ephemeral)
            )
        ])
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        // Check if streaming is enabled for the model
        if !model.canStream {
            let result = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                switch result.completionOutcome {
                case .completed:
                    continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
                case let .incomplete(reason):
                    continuation.yield(AIStreamResult(type: AIStreamResult.incompleteType, text: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens, stopReason: reason))
                }
                continuation.finish()
            }
        }
        let parameters = try Self.makeMessageParameters(for: aiMessage, model: model, maxTokens: maxTokens, stream: true)
        let stream = try await service.streamMessage(parameters)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Track current thinking content
                    var currentThinking = ""
                    // Track token counts
                    var promptTokens: Int? = nil
                    var completionTokens: Int? = nil
                    var observedStopReason: String?
                    var didObserveMessageStop = false

                    for try await result in stream {
                        var reasoning: String? = nil
                        var shouldYieldEvent = true

                        // Handle different stream events
                        switch result.streamEvent {
                        case .contentBlockStart:
                            // Check if this is a thinking block starting
                            if let contentBlock = result.contentBlock, contentBlock.type == "thinking" {
                                if let thinking = contentBlock.thinking {
                                    currentThinking = thinking
                                    reasoning = thinking
                                }
                            }

                        case .contentBlockDelta:
                            // Check for thinking delta updates
                            if let delta = result.delta, delta.type == "thinking_delta" {
                                if let thinking = delta.thinking {
                                    reasoning = thinking
                                }
                            }

                        case .contentBlockStop:
                            // If we're stopping a thinking block, include the final thinking
                            if currentThinking.count > 0 {
                                reasoning = currentThinking
                                currentThinking = ""
                            }

                        case .messageDelta:
                            if let stopReason = result.delta?.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !stopReason.isEmpty
                            {
                                observedStopReason = stopReason
                            }
                            if let usage = result.usage {
                                promptTokens = usage.inputTokens
                                completionTokens = usage.outputTokens + (usage.thinkingTokens ?? 0)
                            }

                        case .messageStop:
                            didObserveMessageStop = true
                            shouldYieldEvent = false
                            // Extract token usage from the end of stream
                            if let usage = result.usage {
                                promptTokens = usage.inputTokens
                                // Combine outputTokens and thinkingTokens for completion tokens
                                let outputTokens = usage.outputTokens
                                let thinkingTokens = usage.thinkingTokens ?? 0
                                completionTokens = outputTokens + thinkingTokens
                            }

                        default:
                            break
                        }

                        // Create AIStreamResult with text and reasoning
                        let aiResult = AIStreamResult(
                            type: result.type,
                            text: result.contentBlock?.text ?? result.delta?.text,
                            reasoning: reasoning,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens
                        )

                        if shouldYieldEvent {
                            continuation.yield(aiResult)
                        }
                    }

                    if didObserveMessageStop {
                        let stopReason = observedStopReason ?? "missing_stop_reason"
                        let type = Self.isSuccessfulCompletionStopReason(stopReason)
                            ? "message_stop"
                            : AIStreamResult.incompleteType
                        continuation.yield(AIStreamResult(
                            type: type,
                            text: nil,
                            reasoning: nil,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            stopReason: stopReason
                        ))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        let parameters = try Self.makeMessageParameters(for: aiMessage, model: model, maxTokens: maxTokens, stream: false)
        return try await executeCompletion(parameters)
    }

    static let adaptiveStreamingMaxTokens = 64000
    static let adaptiveNonStreamingMaxTokens = 16000

    /// Claude 5.x-generation models (Sonnet 5/5.5, Opus 5/5.5, Fable, Mythos) accept only adaptive
    /// thinking: `thinking.budget_tokens` and sampling parameters such as `temperature` return 400.
    /// Omitting `thinking` runs adaptive thinking at the model's default effort.
    static func usesAdaptiveThinkingOnly(_ modelName: String) -> Bool {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = ["claude-fable-", "claude-mythos-", "claude-opus-5", "claude-sonnet-5"]
        return prefixes.contains { normalized.hasPrefix($0) }
    }

    /// RepoPrompt's `-thinking` / `-thinking-max` model-name suffixes select a manual thinking budget.
    /// The suffix is a local request-shape marker and is never sent to the API.
    enum ManualThinkingSuffix: String {
        case thinkingMax = "-thinking-max"
        case thinking = "-thinking"
    }

    static func splitThinkingSuffix(_ modelName: String) -> (baseModelName: String, suffix: ManualThinkingSuffix?) {
        for suffix in [ManualThinkingSuffix.thinkingMax, .thinking] {
            if let range = modelName.range(of: suffix.rawValue, options: [.caseInsensitive, .anchored, .backwards]) {
                return (String(modelName[..<range.lowerBound]), suffix)
            }
        }
        return (modelName, nil)
    }

    /// Builds the exact request both public paths send, so request-shape policy has one owner.
    static func makeMessageParameters(
        for aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int?,
        stream: Bool
    ) throws -> MessageParameter {
        guard !aiMessage.systemPrompt.isEmpty else {
            throw AIProviderError.invalidSystemPrompt
        }

        // Saved custom names may carry stray whitespace or a differently cased suffix; neither
        // belongs in the wire model ID. The persisted raw is left as saved.
        let modelName = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let (baseModelName, thinkingSuffix) = splitThinkingSuffix(modelName)
        let requestMaxTokens: Int
        let thinking: MessageParameter.Thinking?
        let temperature: Double?

        if usesAdaptiveThinkingOnly(baseModelName) {
            // Adaptive thinking consumes output tokens, so the default leaves room for reasoning
            // plus the answer; an explicit caller cap still wins.
            requestMaxTokens = maxTokens ?? (stream ? adaptiveStreamingMaxTokens : adaptiveNonStreamingMaxTokens)
            thinking = nil
            temperature = nil
        } else {
            let thinkingBudget: Int?
            let thinkingMaxTokens: Int?
            switch thinkingSuffix {
            case .thinkingMax:
                thinkingBudget = 32000
                thinkingMaxTokens = 64000
            case .thinking:
                thinkingBudget = 16000
                thinkingMaxTokens = modelName.lowercased().contains("opus") ? 32000 : 64000
            case nil:
                thinkingBudget = nil
                thinkingMaxTokens = nil
            }
            thinking = thinkingBudget.map { MessageParameter.Thinking(budgetTokens: $0) }

            if stream {
                // The streaming path has always used fixed per-mode caps rather than the caller's cap.
                requestMaxTokens = thinkingMaxTokens ?? 8192
                temperature = thinking == nil ? (aiMessage.effectiveTemperature(for: model) ?? 0) : nil
            } else {
                requestMaxTokens = maxTokens ?? thinkingMaxTokens ?? 4096
                temperature = nil
            }
        }

        return MessageParameter(
            model: SwiftAnthropic.Model.other(baseModelName),
            messages: createMessages(for: aiMessage),
            maxTokens: requestMaxTokens,
            system: createSystemParameter(systemPrompt: aiMessage.systemPrompt),
            stream: stream,
            temperature: temperature,
            thinking: thinking
        )
    }

    private func executeCompletion(_ parameters: MessageParameter) async throws -> AICompletionResult {
        let response = try await service.createMessage(parameters)

        let text = response.content.compactMap { contentItem in
            switch contentItem {
            case let .text(text, _):
                text
            case .toolUse:
                nil
            case let .thinking(thinking):
                thinking.thinking
            case .serverToolUse:
                nil
            case .webSearchToolResult:
                nil
            case .toolResult:
                nil
            case .codeExecutionToolResult:
                nil
            }
        }.joined()

        // Extract token counts from the response
        let promptTokens = response.usage.inputTokens
        // Combine outputTokens and thinkingTokens for completion tokens
        let outputTokens = response.usage.outputTokens
        let thinkingTokens = response.usage.thinkingTokens ?? 0
        let completionTokens = outputTokens + thinkingTokens

        let stopReason = response.stopReason ?? "missing_stop_reason"
        let completionOutcome: AIProviderCompletionOutcome = Self.isSuccessfulCompletionStopReason(stopReason)
            ? .completed
            : .incomplete(reason: stopReason)

        return AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            completionOutcome: completionOutcome
        )
    }

    func testAPIKey() async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        let parameters = MessageParameter(
            model: .claude3Haiku,
            messages: Self.createMessages(for: testMessage),
            maxTokens: 4096,
            system: Self.createSystemParameter(systemPrompt: testMessage.systemPrompt),
            stream: false
        )
        let result = try await executeCompletion(parameters)
        return result.text.lowercased().contains("hello")
    }
}
