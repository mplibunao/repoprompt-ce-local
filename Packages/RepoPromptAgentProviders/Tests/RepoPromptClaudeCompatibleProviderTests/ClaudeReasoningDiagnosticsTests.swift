import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

#if DEBUG
    final class ClaudeReasoningDiagnosticsTests: XCTestCase {
        private var temporaryParent: URL!

        override func setUpWithError() throws {
            temporaryParent = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeReasoningDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryParent, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            if let temporaryParent {
                try? FileManager.default.removeItem(at: temporaryParent)
            }
        }

        func testLogPathIsAPackageOwnedPerProcessNamespace() {
            let url = ClaudeReasoningDebugLog.logFileURL(temporaryDirectory: temporaryParent, processID: 4242)

            XCTAssertEqual(
                url.path,
                temporaryParent.path + "/RepoPromptClaudeCompatibleProvider-Debug/4242/claude-reasoning-debug.log"
            )
            XCTAssertFalse(url.pathComponents.contains("RepoPrompt CE"))
            XCTAssertFalse(url.pathComponents.contains("RepoPrompt CE Debug"))
            XCTAssertEqual(
                ClaudeReasoningDebugLog.fileURL,
                ClaudeReasoningDebugLog.logFileURL(
                    temporaryDirectory: FileManager.default.temporaryDirectory,
                    processID: ProcessInfo.processInfo.processIdentifier
                )
            )
        }

        func testAppendWritesOnlyToTheInjectedLog() throws {
            let url = ClaudeReasoningDebugLog.logFileURL(temporaryDirectory: temporaryParent, processID: 4242)

            ClaudeReasoningDebugLog.append("first", to: url)
            ClaudeReasoningDebugLog.append("second", to: url)

            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.count, 2)
            XCTAssertTrue(lines[0].hasSuffix(" first"))
            XCTAssertTrue(lines[1].hasSuffix(" second"))
        }

        func testFailedAppendIsDroppedWithoutTouchingTheProfileTemporaryRoot() throws {
            let profileTemporaryLog = temporaryParent.appendingPathComponent("RepoPrompt CE/claude-reasoning-debug.log")
            try FileManager.default.createDirectory(
                at: profileTemporaryLog.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("production".utf8).write(to: profileTemporaryLog)
            // A regular file where the namespace directory belongs makes every write fail.
            let blocker = temporaryParent.appendingPathComponent("RepoPromptClaudeCompatibleProvider-Debug")
            try Data("blocker".utf8).write(to: blocker)
            let url = ClaudeReasoningDebugLog.logFileURL(temporaryDirectory: temporaryParent, processID: 4242)

            ClaudeReasoningDebugLog.append("dropped", to: url)

            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: profileTemporaryLog), Data("production".utf8))
            XCTAssertEqual(try Data(contentsOf: blocker), Data("blocker".utf8))
            XCTAssertEqual(
                try Set(FileManager.default.contentsOfDirectory(atPath: temporaryParent.path)),
                ["RepoPrompt CE", "RepoPromptClaudeCompatibleProvider-Debug"]
            )
        }
    }
#endif
