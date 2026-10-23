@testable import RepoPromptApp
import XCTest

final class UnifiedDiffGeneratorRecoveryTests: XCTestCase {
    func testGeneratedDiffHeadersNormalizeAbsolutePathsWithSpacesAndSummarizeCreatesDeletes() async throws {
        let createDiff = try await UnifiedDiffGenerator.build(
            oldLines: nil,
            newLines: [SwiftFixtureSource.emptyStruct("Created", trailingNewline: false)],
            filePath: "Repo Root/Sources/New File.swift"
        )
        XCTAssertEqual(createDiff, "--- /dev/null\n+++ b/Repo Root/Sources/New File.swift\n")

        let deleteDiff = try await UnifiedDiffGenerator.build(
            oldLines: ["final class Removed {}"],
            newLines: nil,
            filePath: "Repo Root/Sources/Removed File.swift"
        )
        XCTAssertEqual(deleteDiff, "--- a/Repo Root/Sources/Removed File.swift\n+++ /dev/null\n")
    }

    /// A create diffs against an empty file and a full deletion against an empty result; both take
    /// a shortcut past the general edit search, which must leave their hunks and the distance cap
    /// exactly as the search produced them.
    func testEmptySideDiffsAreOneHunkOfEveryLineFromLineOne() {
        XCTAssertEqual(
            UnifiedDiffGenerator.diffChunks(oldLines: [], newLines: ["a", "a", "b"]),
            [DiffChunk(lines: [DiffLine(content: "+a"), DiffLine(content: "+a"), DiffLine(content: "+b")], startLine: 1)]
        )
        XCTAssertEqual(
            UnifiedDiffGenerator.diffChunks(oldLines: ["x", "y"], newLines: []),
            [DiffChunk(lines: [DiffLine(content: "-x"), DiffLine(content: "-y")], startLine: 1)]
        )
        XCTAssertTrue(DiffEditCreator.myersDiff(oldLines: [], newLines: ["a", "b"], maximumEditDistance: 1).isEmpty)
        XCTAssertEqual(
            DiffEditCreator.myersDiff(oldLines: [], newLines: ["a", "b"], maximumEditDistance: 2).count,
            2
        )
    }

    func testBuildFromEditChunksCarriesCumulativeDeltaAcrossSortedHunks() {
        let laterChunk = DiffChunk(
            lines: [
                DiffLine(content: " line10"),
                DiffLine(content: "-line11"),
                DiffLine(content: "+LINE11")
            ],
            startLine: 10
        )
        let earlierChunk = DiffChunk(
            lines: [
                DiffLine(content: " line1"),
                DiffLine(content: "-line2"),
                DiffLine(content: "+LINE2"),
                DiffLine(content: "+line2b")
            ],
            startLine: 1
        )

        let diff = UnifiedDiffGenerator.buildFromEditChunks(
            filePath: "Sources/File With Spaces.swift",
            chunks: [laterChunk, earlierChunk],
            startLineBase: .oneBased
        )

        XCTAssertTrue(diff.hasPrefix("--- a/Sources/File With Spaces.swift\n+++ b/Sources/File With Spaces.swift\n"))
        XCTAssertTrue(diff.contains("@@ -1,2 +1,3 @@"))
        XCTAssertTrue(diff.contains("@@ -10,2 +11,2 @@"))
        XCTAssertFalse(diff.contains("@@ -10,2 +10,2 @@"))
    }
}
