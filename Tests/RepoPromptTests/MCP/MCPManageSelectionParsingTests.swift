import MCP
@testable import RepoPromptApp
import XCTest

final class MCPManageSelectionParsingTests: XCTestCase {
    func testMalformedJSONRangesAreRejected() {
        let cases: [(label: String, range: [String: Value], problem: String)] = [
            ("missing start", ["end_line": .int(10)], "start_line is required"),
            ("missing end", ["start_line": .int(7324), "description": .string("x")], "end_line is required"),
            ("null end", ["start_line": .int(1), "end_line": .null], "end_line must be an integer"),
            ("non-numeric string start", ["start_line": .string("abc"), "end_line": .int(2)], "start_line must be an integer"),
            ("boolean end", ["start_line": .int(1), "end_line": .bool(true)], "end_line must be an integer"),
            ("integral double start", ["start_line": .double(7324.0), "end_line": .int(7360)], "start_line must be an integer"),
            ("fractional double end", ["start_line": .int(1), "end_line": .double(12.5)], "end_line must be an integer"),
            ("invalid end_line beside valid end", ["start_line": .int(1), "end_line": .string("abc"), "end": .int(5)], "end_line must be an integer"),
            ("invalid start alias", ["start": .string("abc"), "end_line": .int(5)], "start_line must be an integer"),
            ("reversed", ["start_line": .int(20), "end_line": .int(10)], "end_line must be greater than or equal to start_line")
        ]

        for testCase in cases {
            let parsed = parse(slices: [["path": .string("A.swift"), "ranges": .array([.object(testCase.range)])]])

            XCTAssertEqual(
                parsed.sliceErrors,
                ["Invalid slice range for path 'A.swift': \(testCase.problem); expected ranges: [{start_line, end_line}]."],
                testCase.label
            )
            XCTAssertEqual(parsed.sliceInputs.flatMap(\.ranges), [], testCase.label)
        }
    }

    func testSliceLevelEndpointsAreRejected() {
        let completeRange: Value = .array([.object(["start_line": .int(1), "end_line": .int(2)])])
        let cases: [(label: String, slice: [String: Value], keys: String)] = [
            (
                "end_line beside a start-only range",
                ["end_line": .int(420), "ranges": .array([.object(["start_line": .int(345), "description": .string("x")])])],
                "end_line"
            ),
            ("start_line beside a complete range", ["start_line": .int(1), "ranges": completeRange], "start_line"),
            ("aliases beside lines, including null", ["start": .int(1), "end": .null, "lines": .string("1-2")], "start, end"),
            (
                "all four keys",
                ["end": .int(2), "start": .int(1), "end_line": .int(2), "start_line": .int(1), "ranges": completeRange],
                "start_line, end_line, start, end"
            )
        ]

        for testCase in cases {
            var slice = testCase.slice
            slice["path"] = .string("A.swift")
            let parsed = parse(slices: [slice])

            XCTAssertEqual(
                parsed.sliceErrors,
                ["Invalid slice for path 'A.swift': \(testCase.keys) must be inside ranges: [{start_line, end_line}], not beside path."],
                testCase.label
            )
            XCTAssertEqual(parsed.sliceInputs, [], testCase.label)
        }
    }

    func testShorthandRequiresClosedRanges() {
        let cases: [(label: String, paths: [String], slices: [[String: Value]], token: String, path: String)] = [
            ("open dash", [], [["path": .string("A.swift"), "lines": .string("10-")]], "10-", "A.swift"),
            ("non-numeric end", [], [["path": .string("A.swift"), "lines": .string("10-x")]], "10-x", "A.swift"),
            ("reversed", [], [["path": .string("A.swift"), "lines": .string("20-10")]], "20-10", "A.swift"),
            ("open dash path suffix", ["A.swift#L10-"], [], "10-", "A.swift#L10-")
        ]

        for testCase in cases {
            let parsed = parse(paths: testCase.paths, slices: testCase.slices)

            XCTAssertEqual(
                parsed.sliceErrors,
                ["Invalid slice '\(testCase.token)' for path '\(testCase.path)': use a single line or a closed range, or ranges: [{start_line, end_line}]."],
                testCase.label
            )
            XCTAssertEqual(parsed.sliceInputs.flatMap(\.ranges), [], testCase.label)
        }
    }

    func testValidSliceFormsPreserveTheirRanges() {
        func ranges(_ items: [[String: Value]]) -> [[String: Value]] {
            [["path": .string("A.swift"), "ranges": .array(items.map { .object($0) })]]
        }
        let cases: [(label: String, paths: [String], slices: [[String: Value]], expected: [WorkspaceSelectionSliceInput])] = [
            (
                "canonical endpoints",
                [],
                ranges([["start_line": .int(10), "end_line": .int(20)]]),
                [.init(path: "A.swift", ranges: [LineRange(start: 10, end: 20)])]
            ),
            (
                "equal endpoints",
                [],
                ranges([["start_line": .int(40), "end_line": .int(40)]]),
                [.init(path: "A.swift", ranges: [LineRange(start: 40, end: 40)])]
            ),
            (
                "numeric strings",
                [],
                ranges([["start_line": .string("10"), "end_line": .string("20")]]),
                [.init(path: "A.swift", ranges: [LineRange(start: 10, end: 20)])]
            ),
            (
                "start and end aliases",
                [],
                ranges([["start": .int(10), "end": .int(20)]]),
                [.init(path: "A.swift", ranges: [LineRange(start: 10, end: 20)])]
            ),
            (
                "description aliases",
                [],
                ranges([
                    ["start_line": .int(1), "end_line": .int(2), "description": .string(" first ")],
                    ["start_line": .int(3), "end_line": .int(4), "desc": .string("second")],
                    ["start_line": .int(5), "end_line": .int(6), "label": .string("third")]
                ]),
                [.init(path: "A.swift", ranges: [
                    LineRange(start: 1, end: 2, description: "first"),
                    LineRange(start: 3, end: 4, description: "second"),
                    LineRange(start: 5, end: 6, description: "third")
                ])]
            ),
            (
                "lines shorthand",
                [],
                [["path": .string("A.swift"), "lines": .string("10-20,40")]],
                [.init(path: "A.swift", ranges: [LineRange(start: 10, end: 20), LineRange(start: 40, end: 40)])]
            ),
            (
                "path suffix",
                ["A.swift#L10-20"],
                [],
                [.init(path: "A.swift", ranges: [LineRange(start: 10, end: 20)])]
            ),
            (
                "empty ranges",
                [],
                [["path": .string("A.swift"), "ranges": .array([])]],
                [.init(path: "A.swift", ranges: [])]
            )
        ]

        for testCase in cases {
            let parsed = parse(paths: testCase.paths, slices: testCase.slices)

            XCTAssertEqual(parsed.sliceErrors, [], testCase.label)
            XCTAssertEqual(parsed.sliceInputs, testCase.expected, testCase.label)
        }
    }

    private func parse(paths: [String] = [], slices: [[String: Value]]) -> MCPServerViewModel.ManageSelectionInputs {
        MCPServerViewModel.parseManageSelectionInputs(
            rawPaths: paths,
            slicesValue: slices.isEmpty ? nil : .array(slices.map { .object($0) })
        )
    }
}
