import RepoPromptDomainRuntime
import XCTest

final class ApplyEditsNoChangeTests: XCTestCase {
    func testNetZeroBatchesKeepMatchesButNeverWrite() async throws {
        struct Case {
            let name: String
            let edits: [ApplyEditsOperation]
            let expectedOutcomeStatuses: [String]
        }
        let cases: [Case] = [
            Case(
                name: "edit and its inverse",
                edits: [.init(search: "A", replace: "B", replaceAll: false), .init(search: "B", replace: "A", replaceAll: false)],
                expectedOutcomeStatuses: ["success", "success"]
            ),
            Case(
                name: "identity edit",
                edits: [.init(search: "A", replace: "A", replaceAll: false)],
                expectedOutcomeStatuses: ["success"]
            ),
            Case(
                name: "identity replace-all",
                edits: [.init(search: "A", replace: "A", replaceAll: true)],
                expectedOutcomeStatuses: ["success"]
            ),
            Case(
                name: "inverse pair around a failed sibling",
                edits: [
                    .init(search: "A", replace: "B", replaceAll: false),
                    .init(search: "missing", replace: "C", replaceAll: false),
                    .init(search: "B", replace: "A", replaceAll: false)
                ],
                expectedOutcomeStatuses: ["success", "failed", "success"]
            )
        ]
        for testCase in cases {
            let host = RecordingEditHost(text: "A\n")
            let service = ApplyEditsService(engine: .default, host: host)
            let result = try await service.run(.init(path: "file.txt", mode: .batch(testCase.edits), verbose: false))

            XCTAssertEqual(result.status.rawValue, "no_change", testCase.name)
            XCTAssertEqual(result.editsApplied, 0, testCase.name)
            XCTAssertEqual(result.editsRequested, testCase.edits.count, testCase.name)
            XCTAssertTrue(result.updatedText.utf8.elementsEqual("A\n".utf8), testCase.name)
            XCTAssertEqual(result.outcomes?.map(\.status), testCase.expectedOutcomeStatuses, testCase.name)
            XCTAssertTrue(result.note?.contains("no net change") == true, testCase.name)
            XCTAssertNil(result.stats, testCase.name)
            XCTAssertTrue(result.diffChunks.isEmpty, testCase.name)
            XCTAssertNil(result.unifiedDiff, testCase.name)
            XCTAssertNil(result.toolCardUnifiedDiff, testCase.name)
            let writes = await host.writeCount
            XCTAssertEqual(writes, 0, testCase.name)
        }
    }

    func testUnicodeNormalizationChangeIsNotAByteIdenticalNoOp() async throws {
        let original = "\u{00E9}\n"
        let replacement = "e\u{0301}\n"
        let host = RecordingEditHost(text: original)
        let result = try await ApplyEditsService(engine: .default, host: host).run(.init(
            path: "unicode.txt",
            mode: .batch([.init(search: original, replace: replacement, replaceAll: false)]),
            verbose: false
        ))
        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.updatedText.utf8.elementsEqual(replacement.utf8))
        // String equality treats the two forms as equal, so compare the stored bytes.
        let stored = await host.text
        let writes = await host.writeCount
        XCTAssertTrue(stored?.utf8.elementsEqual(replacement.utf8) == true)
        XCTAssertEqual(writes, 1)
    }

    func testWhitespaceOnlyMutationStillWrites() async throws {
        let host = RecordingEditHost(text: "A B\n")
        let result = try await ApplyEditsService(engine: .default, host: host).run(.init(
            path: "file.txt", mode: .batch([.init(search: "A B", replace: "AB", replaceAll: false)]), verbose: false
        ))
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.editsApplied, 1)
        let stored = await host.text
        let writes = await host.writeCount
        XCTAssertEqual(stored, "AB\n")
        XCTAssertEqual(writes, 1)
    }

    func testMissingEmptyFileIsCreated() async throws {
        let host = RecordingEditHost(text: nil)
        let created = try await ApplyEditsService(engine: .default, host: host).run(.init(
            path: "empty.txt", mode: .rewrite(newText: "", onMissing: .create), verbose: false
        ))
        XCTAssertEqual(created.status, .success)
        XCTAssertTrue(created.fileCreated)
        let stored = await host.text
        let writes = await host.writeCount
        XCTAssertEqual(stored, "")
        XCTAssertEqual(writes, 1)
    }
}

private actor RecordingEditHost: FileEditHost {
    var text: String?
    var writeCount = 0

    init(text: String?) {
        self.text = text
    }

    func fileExists(path: String) async -> Bool {
        text != nil
    }

    func readText(path: String) async throws -> String {
        text ?? ""
    }

    func writeText(path: String, content: String, overwrite: Bool) async throws {
        writeCount += 1
        text = content
    }
}
