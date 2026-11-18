import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexHookReviewCardStateTests: XCTestCase {
    func testSelectionStartsEmpty() {
        let state = CodexHookReviewCardState(interactionID: UUID())

        XCTAssertTrue(state.selectedHookKeys.isEmpty)
    }

    func testSelectionIsPreservedForPhaseOrErrorUpdatesWithSameInteractionID() {
        let interactionID = UUID()
        var state = CodexHookReviewCardState(interactionID: interactionID)
        state.selectedHookKeys = ["hook-a"]
        state.actionErrorMessage = "write failed"

        state.synchronize(interactionID: interactionID)

        XCTAssertEqual(state.selectedHookKeys, ["hook-a"])
        XCTAssertEqual(state.actionErrorMessage, "write failed")
    }

    func testSelectionResetsWhenInteractionIDChanges() {
        var state = CodexHookReviewCardState(interactionID: UUID())
        state.selectedHookKeys = ["hook-a"]
        state.isContinueConfirmationPresented = true
        state.actionErrorMessage = "stale"

        state.synchronize(interactionID: UUID())

        XCTAssertTrue(state.selectedHookKeys.isEmpty)
        XCTAssertFalse(state.isContinueConfirmationPresented)
        XCTAssertNil(state.actionErrorMessage)
    }

    /// The card shows a hook's command over several lines, so it asks for line breaks and tabs to stay. Every other
    /// control or bidi character still shows as its escape, and every other hook field gets no exception.
    func testHookDisplayEscapingKeepsLineBreaksAndTabsOnlyWhenAsked() {
        let command = "a\tb\nc\r\nd\u{2028}e\u{202E}f\u{7}g\u{200F}h"

        XCTAssertEqual(
            command.escapedForDisplay(keepingLineBreaksAndTabs: true),
            "a\tb\nc\r\nd\u{2028}e\\u{202E}f\\u{0007}g\\u{200F}h"
        )
        XCTAssertEqual(
            command.escapedForDisplay(),
            "a\\u{0009}b\\nc\\nd\\ne\\u{202E}f\\u{0007}g\\u{200F}h"
        )
    }

    func testLiveStrictModeToggleHidesAndShowsContinueAndDismissesConfirmation() {
        var state = CodexHookReviewCardState(interactionID: UUID())
        var isStrictModeEnabled = false
        XCTAssertTrue(!isStrictModeEnabled)
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting.allCases.map {
                $0.label(globalStrictModeEnabled: isStrictModeEnabled)
            },
            [
                "App default (currently: not required)",
                "Always require approval",
                "Don't require approval"
            ]
        )
        state.isContinueConfirmationPresented = true

        isStrictModeEnabled = true
        state.strictModeDidChange(isEnabled: isStrictModeEnabled)

        XCTAssertFalse(!isStrictModeEnabled)
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting.appDefault.label(
                globalStrictModeEnabled: isStrictModeEnabled
            ),
            "App default (currently: required)"
        )
        XCTAssertFalse(state.isContinueConfirmationPresented)

        isStrictModeEnabled = false
        state.strictModeDidChange(isEnabled: isStrictModeEnabled)

        XCTAssertTrue(!isStrictModeEnabled)
        XCTAssertEqual(
            CodexHookApprovalWorkspaceSetting.appDefault.label(
                globalStrictModeEnabled: isStrictModeEnabled
            ),
            "App default (currently: not required)"
        )
    }
}
