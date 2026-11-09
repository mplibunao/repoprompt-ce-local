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

    // MARK: - Fixtures

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

    private func assistant(_ inputID: UUID? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "assistant",
            "message": ["role": "assistant", "content": [["type": "text", "text": "working"]]]
        ]
        if let inputID {
            payload["user_message_uuid"] = inputID.uuidString
        }
        return payload
    }

    private func result(_ inputIDs: [UUID]? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": "answer"]
        if let inputIDs, let lastID = inputIDs.last {
            payload["user_message_uuids"] = inputIDs.map(\.uuidString)
            payload["user_message_uuid"] = lastID.uuidString
        }
        return payload
    }
}
