@testable import RepoPromptApp
import XCTest

final class MCPContextBuilderResponseDispositionTests: XCTestCase {
    func testPlanOrQuestionIsNotSentWhenDiscoveryLeftTheSelectionEmpty() {
        for responseType in [ContextBuilderResponseType.plan, .question] {
            let empty = disposition(responseType, selection: StoredSelection())
            if case let .failed(message) = empty {
                XCTAssertEqual(
                    message,
                    "context_builder_discovery_empty: Context Builder discovery finished with no files selected, "
                        + "so the \(responseType.rawValue) request was not sent."
                )
            } else {
                XCTFail("\(responseType) with an empty selection: expected failed, got \(empty)")
            }

            let slicesOnly = disposition(
                responseType,
                selection: StoredSelection(slices: ["/repo/Sources/App.swift": [LineRange(start: 1, end: 20)]])
            )
            if case let .generate(_, prompt) = slicesOnly {
                XCTAssertEqual(prompt, "Explain the change")
            } else {
                XCTFail("\(responseType) with a sliced file: expected generate, got \(slicesOnly)")
            }
        }
    }

    private func disposition(
        _ responseType: ContextBuilderResponseType,
        selection: StoredSelection
    ) -> ContextBuilderResponseDisposition {
        MCPContextBuilderToolProvider.responseDisposition(
            responseType: responseType,
            terminalDisposition: .completed,
            selection: selection,
            usedAgentOutputAsPrompt: false,
            effectivePrompt: "",
            callerInstructions: "Explain the change"
        )
    }
}
