import Foundation
@testable import RepoPromptApp
import XCTest

final class SubtreeRemovalTests: XCTestCase {
    func testRemovalPreservesOrderedDeltasAndInventory() async throws {
        let cases: [(
            name: String,
            top: String,
            items: [String: Bool],
            deltas: [FileSystemDelta],
            remaining: [String: Bool]
        )] = [
            (
                "nested",
                "a",
                ["a": true, "a/b": true, "a/b/c": false, "keep": false],
                [.fileRemoved("a/b/c"), .folderRemoved("a/b"), .folderRemoved("a")],
                ["keep": false]
            ),
            (
                "slash neighbour",
                "a/b",
                ["a": true, "a/b": true, "a/b/x": false, "a/bc": true, "a/bc/y": false],
                [.fileRemoved("a/b/x"), .folderRemoved("a/b")],
                ["a": true, "a/bc": true, "a/bc/y": false]
            ),
            (
                "top already removed",
                "a/b",
                ["a": true, "a/b/x": false, "a/bc": true],
                [.fileRemoved("a/b/x")],
                ["a": true, "a/bc": true]
            ),
            (
                "missing folder",
                "missing",
                ["a": true, "a/b": false, "keep": false],
                [],
                ["a": true, "a/b": false, "keep": false]
            )
        ]
        let root = try makeTestDirectory()

        for testCase in cases {
            let service = try await FileSystemService(
                path: root.path,
                testVisitedPaths: Set(testCase.items.keys),
                testVisitedItems: testCase.items,
                testIgnoreRules: IgnoreRules(policy: .nonGitRoot),
                isTestMode: true
            )
            let deltas = await service.removeSubtree(for: testCase.top)
            let remainingPaths = await service.getTrackedPaths()
            let remainingItems = await service.getTestState().visitedItems

            XCTAssertEqual(deltas, testCase.deltas, testCase.name)
            XCTAssertEqual(Set(remainingPaths), Set(testCase.remaining.keys), testCase.name)
            XCTAssertEqual(remainingItems, testCase.remaining, testCase.name)
        }
    }
}
