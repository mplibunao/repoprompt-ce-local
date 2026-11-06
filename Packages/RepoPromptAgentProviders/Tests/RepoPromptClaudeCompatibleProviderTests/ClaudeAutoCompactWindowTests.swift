@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeAutoCompactWindowTests: XCTestCase {
    func testAutoCompactWindowParsesOnlyPositiveIntegers() {
        // The environment key is spelled out because Claude Code reads exactly this name.
        let key = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
        let cases: [(label: String, environment: [String: String], expected: Int?)] = [
            ("plain integer", [key: "400000"], 400_000),
            ("surrounding whitespace", [key: " 400000\n"], 400_000),
            ("missing", [:], nil),
            ("empty", [key: ""], nil),
            ("zero", [key: "0"], nil),
            ("negative", [key: "-1"], nil),
            ("unit suffix", [key: "400k"], nil),
            ("exponent", [key: "4e5"], nil),
            ("overflow", [key: "99999999999999999999"], nil)
        ]
        for testCase in cases {
            XCTAssertEqual(ClaudeAutoCompactWindow.tokens(in: testCase.environment), testCase.expected, testCase.label)
        }
    }

    func testEffectiveWindowIsTheSmallerKnownWindow() {
        let effectiveCases: [(label: String, modelWindow: Int?, autoCompactWindow: Int?, expected: Int?)] = [
            ("cap below the model window", 1_000_000, 400_000, 400_000),
            ("Claude Code caps the setting at the model window", 200_000, 400_000, 200_000),
            ("unknown model window", nil, 400_000, 400_000),
            ("no cap", 1_000_000, nil, 1_000_000),
            ("neither known", nil, nil, nil)
        ]
        for testCase in effectiveCases {
            XCTAssertEqual(
                ClaudeAutoCompactWindow.effectiveWindow(
                    modelWindow: testCase.modelWindow,
                    autoCompactWindow: testCase.autoCompactWindow
                ),
                testCase.expected,
                testCase.label
            )
        }

        let reportCases: [(label: String, reportedWindow: Int?, expected: Int?)] = [
            ("no report invents no window", nil, nil),
            ("a withdrawal signal passes through", 0, 0),
            ("a reported window is capped", 1_000_000, 400_000)
        ]
        for testCase in reportCases {
            XCTAssertEqual(
                ClaudeAutoCompactWindow.cappedReportedWindow(testCase.reportedWindow, autoCompactWindow: 400_000),
                testCase.expected,
                testCase.label
            )
        }
    }
}
