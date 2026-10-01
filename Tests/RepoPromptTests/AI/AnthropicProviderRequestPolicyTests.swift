import Foundation
@testable import RepoPromptApp
import XCTest

/// Serializes the exact `MessageParameter` both AnthropicProvider request paths send. No direct
/// Anthropic request runs in validation, so the encoded body is the evidence for request shape.
final class AnthropicProviderRequestPolicyTests: XCTestCase {
    private let adaptiveModels: [AIModel] = [
        .claudeSonnet55,
        .claudeSonnet5,
        .claudeOpus55,
        .claudeOpus5,
        .claudeFable51,
        .claudeMythos51,
        // Saved custom names: legacy thinking suffixes, mixed case, and surrounding whitespace.
        .anthropicCustom(name: "claude-sonnet-5-5-thinking"),
        .anthropicCustom(name: "claude-opus-5-5-thinking-max"),
        .anthropicCustom(name: "CLAUDE-FABLE-5-1"),
        .anthropicCustom(name: " claude-mythos-5-1 "),
        .anthropicCustom(name: " claude-sonnet-5-5-Thinking-MAX "),
        .anthropicCustom(name: "\tclaude-opus-5-5-THINKING\n")
    ]

    func testClaude5RequestsOmitManualThinkingAndSamplingKeys() throws {
        for model in adaptiveModels {
            for stream in [true, false] {
                // An enabled temperature override is the case that used to reach streaming requests.
                for temperature in [nil, 0.7] {
                    let body = try encodedRequest(model, stream: stream, temperature: temperature)
                    let context = "\(model.rawValue) stream=\(stream) temperature=\(String(describing: temperature))"
                    XCTAssertNil(body["thinking"], context)
                    XCTAssertNil(body["temperature"], context)
                    XCTAssertEqual(body["stream"] as? Bool, stream, context)
                }
            }
        }

        // Surrounding whitespace and the local thinking suffix, in any case, never reach the wire model.
        let wireModels: [(AIModel, String)] = [
            (.anthropicCustom(name: "claude-sonnet-5-5-thinking"), "claude-sonnet-5-5"),
            (.anthropicCustom(name: "claude-opus-5-5-thinking-max"), "claude-opus-5-5"),
            (.anthropicCustom(name: " claude-sonnet-5-5-Thinking-MAX "), "claude-sonnet-5-5"),
            (.anthropicCustom(name: "\tclaude-opus-5-5-THINKING\n"), "claude-opus-5-5"),
            (.anthropicCustom(name: " claude-mythos-5-1 "), "claude-mythos-5-1"),
            (.claudeMythos51, "claude-mythos-5-1")
        ]
        for (model, wireModel) in wireModels {
            for stream in [true, false] {
                XCTAssertEqual(try encodedRequest(model, stream: stream)["model"] as? String, wireModel, "\(model.rawValue) stream=\(stream)")
            }
        }
    }

    func testAdaptiveDefaultsAndExplicitCapsAreModeCorrect() throws {
        for model in adaptiveModels {
            XCTAssertEqual(try encodedRequest(model, stream: true)["max_tokens"] as? Int, 64000, model.rawValue)
            XCTAssertEqual(try encodedRequest(model, stream: false)["max_tokens"] as? Int, 16000, model.rawValue)
            for stream in [true, false] {
                XCTAssertEqual(
                    try encodedRequest(model, maxTokens: 2048, stream: stream)["max_tokens"] as? Int,
                    2048,
                    "\(model.rawValue) stream=\(stream) keeps an explicit cap"
                )
            }
        }
    }

    func testLegacyThinkingRequestShapesRemainUnchanged() throws {
        struct LegacyRow {
            let model: AIModel
            let wireModel: String
            let thinkingBudget: Int?
            let streamingMaxTokens: Int
            let nonStreamingDefaultMaxTokens: Int
        }
        let rows: [LegacyRow] = [
            .init(model: .claude4Sonnet, wireModel: "claude-sonnet-4-5-20250929", thinkingBudget: nil, streamingMaxTokens: 8192, nonStreamingDefaultMaxTokens: 4096),
            .init(model: .claude45Haiku, wireModel: "claude-haiku-4-5", thinkingBudget: nil, streamingMaxTokens: 8192, nonStreamingDefaultMaxTokens: 4096),
            .init(model: .claude4SonnetThinking, wireModel: "claude-sonnet-4-5-20250929", thinkingBudget: 16000, streamingMaxTokens: 64000, nonStreamingDefaultMaxTokens: 64000),
            .init(model: .claude4SonnetThinkingMax, wireModel: "claude-sonnet-4-5-20250929", thinkingBudget: 32000, streamingMaxTokens: 64000, nonStreamingDefaultMaxTokens: 64000),
            .init(model: .claude4OpusThinking, wireModel: "claude-opus-4-6", thinkingBudget: 16000, streamingMaxTokens: 32000, nonStreamingDefaultMaxTokens: 32000),
            .init(model: .anthropicCustom(name: "claude-opus-4-8-thinking"), wireModel: "claude-opus-4-8", thinkingBudget: 16000, streamingMaxTokens: 32000, nonStreamingDefaultMaxTokens: 32000),
            // Saved custom names with surrounding whitespace and a differently cased suffix.
            .init(model: .anthropicCustom(name: " claude-opus-4-8-Thinking "), wireModel: "claude-opus-4-8", thinkingBudget: 16000, streamingMaxTokens: 32000, nonStreamingDefaultMaxTokens: 32000),
            .init(model: .anthropicCustom(name: "claude-sonnet-4-5-20250929-THINKING-max\n"), wireModel: "claude-sonnet-4-5-20250929", thinkingBudget: 32000, streamingMaxTokens: 64000, nonStreamingDefaultMaxTokens: 64000),
            .init(model: .anthropicCustom(name: " claude-haiku-4-5 "), wireModel: "claude-haiku-4-5", thinkingBudget: nil, streamingMaxTokens: 8192, nonStreamingDefaultMaxTokens: 4096)
        ]

        for row in rows {
            let name = row.model.rawValue
            let expectedThinking: [String: AnyHashable]? = row.thinkingBudget.map { ["type": "enabled", "budget_tokens": $0] }

            let streaming = try encodedRequest(row.model, stream: true)
            XCTAssertEqual(streaming["model"] as? String, row.wireModel, name)
            XCTAssertEqual(streaming["thinking"] as? [String: AnyHashable], expectedThinking, name)
            XCTAssertEqual(streaming["max_tokens"] as? Int, row.streamingMaxTokens, name)
            // Streaming has always used its fixed per-mode cap rather than the caller's cap.
            XCTAssertEqual(try encodedRequest(row.model, maxTokens: 2048, stream: true)["max_tokens"] as? Int, row.streamingMaxTokens, name)

            let overridden = try encodedRequest(row.model, stream: true, temperature: 0.7)
            if row.thinkingBudget == nil {
                XCTAssertEqual(streaming["temperature"] as? Double, 0, name)
                XCTAssertEqual(overridden["temperature"] as? Double, 0.7, name)
            } else {
                XCTAssertNil(streaming["temperature"], name)
                XCTAssertNil(overridden["temperature"], name)
            }

            let nonStreaming = try encodedRequest(row.model, stream: false, temperature: 0.7)
            XCTAssertEqual(nonStreaming["model"] as? String, row.wireModel, name)
            XCTAssertEqual(nonStreaming["thinking"] as? [String: AnyHashable], expectedThinking, name)
            XCTAssertEqual(nonStreaming["max_tokens"] as? Int, row.nonStreamingDefaultMaxTokens, name)
            XCTAssertNil(nonStreaming["temperature"], name)
            XCTAssertEqual(try encodedRequest(row.model, maxTokens: 2048, stream: false)["max_tokens"] as? Int, 2048, name)
        }

        XCTAssertThrowsError(try AnthropicProvider.makeMessageParameters(
            for: AIMessage(systemPrompt: "", userMessage: "user"),
            model: .claudeSonnet55,
            maxTokens: nil,
            stream: true
        ))
    }

    private func encodedRequest(
        _ model: AIModel,
        maxTokens: Int? = nil,
        stream: Bool,
        temperature: Double? = nil
    ) throws -> [String: Any] {
        let message = AIMessage(systemPrompt: "system", userMessage: "user", temperature: temperature)
        let parameters = try AnthropicProvider.makeMessageParameters(for: message, model: model, maxTokens: maxTokens, stream: stream)
        // Same key strategy SwiftAnthropic applies when it encodes the request body.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(parameters)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
