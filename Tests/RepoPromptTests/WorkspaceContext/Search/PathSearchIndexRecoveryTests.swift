@testable import RepoPromptApp
import XCTest

final class PathSearchIndexRecoveryTests: XCTestCase {
    func testSearchMatchesFilenameSubpathTokensAndPublishesDeterministicRankMetadata() async {
        let paths = [
            "/Volumes/Repo/Sources/Zeta/Widget.swift",
            "Sources/βeta/Search/Unicode.swift",
            "Sources/App/Search/Alpha.swift",
            "Sources/App/Search/Alpha.swift",
            "Sources/App/Features/SearchPanel.swift",
            "docs/absolute-search-notes.md",
            "Worktree/Sources/CompositeCatalogTarget.rpfixture\n/Volumes/Worktree/Sources/CompositeCatalogTarget.rpfixture"
        ]
        let expectedFilenames = [
            "Widget.swift",
            "Unicode.swift",
            "Alpha.swift",
            "Alpha.swift",
            "SearchPanel.swift",
            "absolute-search-notes.md",
            "CompositeCatalogTarget.rpfixture"
        ]
        let index = PathSearchIndex(paths: paths)

        let duplicateHits = await index.search("Alpha.swift", limit: 10)
        XCTAssertEqual(duplicateHits.map(\.index), [2, 3])
        assertMappings(duplicateHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let truncatedDuplicateHits = await index.search("Alpha.swift", limit: 1)
        XCTAssertEqual(truncatedDuplicateHits.map(\.index), [2])
        assertMappings(truncatedDuplicateHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let truncatedWildcardHits = await index.search("*.swift", limit: 3)
        XCTAssertEqual(truncatedWildcardHits.map(\.index), [0, 4, 2])
        assertMappings(truncatedWildcardHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let wildcardHits = await index.search("*.swift", limit: 20)
        XCTAssertEqual(wildcardHits.map(\.index), [0, 4, 2, 3, 1])
        XCTAssertEqual(wildcardHits.map(\.filename), [
            "Widget.swift",
            "SearchPanel.swift",
            "Alpha.swift",
            "Alpha.swift",
            "Unicode.swift"
        ])
        assertMappings(wildcardHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let spaceANDHits = await index.search("App Search", limit: 20)
        XCTAssertEqual(spaceANDHits.map(\.index), [4, 2, 3])
        assertMappings(spaceANDHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let unicodeHits = await index.search("βeta", limit: 20)
        XCTAssertEqual(unicodeHits.map(\.index), [1])
        assertMappings(unicodeHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let absolutePathHits = await index.search("Volumes Widget", limit: 20)
        XCTAssertEqual(absolutePathHits.map(\.index), [0])
        assertMappings(absolutePathHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let compositeHits = await index.search("CompositeCatalogTarget", limit: 20)
        XCTAssertEqual(compositeHits.map(\.index), [6])
        assertMappings(compositeHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let zeroLimitHits = await index.search("swift", limit: 0)
        XCTAssertEqual(zeroLimitHits, [])
        XCTAssertEqual(wildcardHits.count, 5)

        for invalidIndex in [-1, index.count, index.count + 10] {
            XCTAssertNil(index.path(at: invalidIndex))
            XCTAssertNil(index.filename(at: invalidIndex))
        }

        let emptyIndex = PathSearchIndex(paths: [])
        XCTAssertEqual(emptyIndex.count, 0)
        XCTAssertNil(emptyIndex.path(at: -1))
        XCTAssertNil(emptyIndex.path(at: 0))
        XCTAssertNil(emptyIndex.filename(at: -1))
        XCTAssertNil(emptyIndex.filename(at: 0))
        let emptyHits = await emptyIndex.search("swift", limit: 20)
        XCTAssertEqual(emptyHits, [])

        for iteration in 0 ..< 64 {
            let replacementPaths = [
                "Loop/Shared.swift",
                "Loop/Shared.swift",
                "/tmp/repoprompt-\(iteration)/Absolute.swift",
                "Loop/βeta/Unicode.swift"
            ]
            let replacementFilenames = [
                "Shared.swift",
                "Shared.swift",
                "Absolute.swift",
                "Unicode.swift"
            ]
            let replacement = PathSearchIndex(paths: replacementPaths)
            let replacementHits = replacement.searchSynchronously("*.swift", limit: 20)
            XCTAssertEqual(replacementHits.count, replacementPaths.count)
            assertMappings(
                replacementHits,
                in: replacement,
                paths: replacementPaths,
                expectedFilenames: replacementFilenames
            )
        }

        // The old immutable generation remains valid after replacements are constructed and released.
        let retainedHits = await index.search("Alpha.swift", limit: 10)
        XCTAssertEqual(retainedHits, duplicateHits)
        assertMappings(retainedHits, in: index, paths: paths, expectedFilenames: expectedFilenames)
    }

    func testProjectedPatchWithExplicitPathsMatchesFreshIndex() async throws {
        struct Match: Equatable {
            let entry: WorkspaceSearchCatalogEntry
            let score: Int32
            let tieBreakKey: String
        }
        let root = WorkspaceRootRecord(name: "ProjectedRoot", fullPath: "/Volumes/ProjectedRoot")
        func entry(_ relativePath: String) -> WorkspaceSearchCatalogEntry {
            WorkspaceSearchCatalogEntry(
                file: WorkspaceFileRecord(
                    rootID: root.id,
                    name: (relativePath as NSString).lastPathComponent,
                    relativePath: relativePath,
                    fullPath: root.standardizedFullPath + "/" + relativePath,
                    parentFolderID: nil
                ),
                root: root
            )
        }
        func catalogOrdered(_ entries: [WorkspaceSearchCatalogEntry]) -> [WorkspaceSearchCatalogEntry] {
            entries.sorted(by: WorkspaceFileContextStore.searchCatalogEntryPrecedes)
        }

        let basePaths = [
            "Docs/Guide.md",
            "Docs/Notes.md",
            "Sources/Alpha.swift",
            "Sources/Beta.swift",
            "Sources/Gamma.swift"
        ]
        let snapshot = try await WorkspaceRootSeedTestSupport.snapshot(paths: basePaths.map { ($0, "100644") })
        let baseEntries = catalogOrdered(basePaths.map(entry))
        let identity = WorkspaceSearchRootPathIndexIdentity(rootID: root.id, lifetimeID: UUID(), topologyGeneration: 1)
        let projected = try XCTUnwrap(WorkspaceSearchRootPathIndex(
            identity: identity,
            root: root,
            projectedSnapshot: snapshot,
            changedRelativeFilePaths: [],
            tombstonedBaseRelativeFilePaths: [],
            entries: baseEntries
        ))

        // One batch removes a base file, adds a file, and gives a base path a new ID, which displaces
        // the base entry at that path.
        let removed = try XCTUnwrap(baseEntries.first { $0.standardizedRelativePath == "Docs/Notes.md" })
        let displaced = try XCTUnwrap(baseEntries.first { $0.standardizedRelativePath == "Sources/Beta.swift" })
        let replacement = entry("Sources/Beta.swift")
        let added = entry("Sources/Delta.swift")
        let patchedEntries = catalogOrdered(
            baseEntries.filter { $0.id != removed.id && $0.id != displaced.id } + [replacement, added]
        )
        let patched = projected.applyingPatch(
            identity: WorkspaceSearchRootPathIndexIdentity(
                rootID: identity.rootID,
                lifetimeID: identity.lifetimeID,
                topologyGeneration: identity.topologyGeneration + 1
            ),
            entries: patchedEntries,
            patch: WorkspaceSearchRootPathIndexPatch(
                affectedFileIDs: [removed.id, displaced.id, replacement.id, added.id],
                changedEntries: catalogOrdered([replacement, added]),
                changedRelativePaths: ["Docs/Notes.md", "Sources/Beta.swift", "Sources/Delta.swift"]
            )
        )
        XCTAssertEqual(patched.buildKind, .projectedReuse)

        let fresh = WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: root.standardizedFullPath,
            entries: patchedEntries
        )
        for query in ["Beta", "Notes", "Delta", "Guide", "*.swift", "Sources"] {
            XCTAssertEqual(
                patched.search(query, limit: 20).map { Match(entry: $0.entry, score: $0.score, tieBreakKey: $0.tieBreakKey) },
                fresh.search(query, limit: 20).map { Match(entry: $0.entry, score: $0.score, tieBreakKey: $0.tieBreakKey) },
                query
            )
        }
    }

    func testMaterializedOverlayRebasePreservesSearchResults() throws {
        struct Match: Equatable {
            let entry: WorkspaceSearchCatalogEntry
            let score: Int32
            let tieBreakKey: String
        }
        let root = WorkspaceRootRecord(name: "RebaseRoot", fullPath: "/Volumes/RebaseRoot")
        let identity = WorkspaceSearchRootPathIndexIdentity(rootID: root.id, lifetimeID: UUID(), topologyGeneration: 1)
        func entry(_ relativePath: String) -> WorkspaceSearchCatalogEntry {
            WorkspaceSearchCatalogEntry(
                file: WorkspaceFileRecord(
                    rootID: root.id,
                    name: (relativePath as NSString).lastPathComponent,
                    relativePath: relativePath,
                    fullPath: root.standardizedFullPath + "/" + relativePath,
                    parentFolderID: nil
                ),
                root: root
            )
        }
        func catalogOrdered(_ entries: [WorkspaceSearchCatalogEntry]) -> [WorkspaceSearchCatalogEntry] {
            entries.sorted(by: WorkspaceFileContextStore.searchCatalogEntryPrecedes)
        }
        func matches(_ index: WorkspaceSearchRootPathIndex, _ query: String) -> [Match] {
            index.search(query, limit: 64).map { Match(entry: $0.entry, score: $0.score, tieBreakKey: $0.tieBreakKey) }
        }

        var entries = catalogOrdered(
            ["Sources/Alpha.swift", "Sources/Beta.swift", "Sources/Gamma.swift", "Docs/Guide.md", "Docs/Notes.md"]
                .map(entry)
        )
        var index = WorkspaceSearchRootPathIndex(identity: identity, rootPath: root.standardizedFullPath, entries: entries)
        /// Each patch is one overlay payload, shaped as the shard's patch builder reports it: a same-path
        /// replacement removes the old ID and inserts the new one.
        func patch(removing removedPaths: [String] = [], inserting insertedPaths: [String] = []) throws {
            let removed = try removedPaths.map { path in
                try XCTUnwrap(entries.first { $0.standardizedRelativePath == path }, path)
            }
            let inserted = insertedPaths.map(entry)
            let removedIDs = Set(removed.map(\.id))
            entries = catalogOrdered(entries.filter { !removedIDs.contains($0.id) } + inserted)
            index = index.applyingPatch(
                identity: identity,
                entries: entries,
                patch: WorkspaceSearchRootPathIndexPatch(
                    affectedFileIDs: removedIDs.union(inserted.map(\.id)),
                    changedEntries: catalogOrdered(inserted),
                    changedRelativePaths: Set(removedPaths + insertedPaths)
                )
            )
        }
        let queries = ["Alpha", "Beta", "Delta", "Notes", "Guide", "Gamma", "Before", "After", "*.swift", "Filler"]

        // Before the capture: a removal, a same-path replacement, and an add, then fillers. Twenty payloads.
        try patch(removing: ["Docs/Notes.md"])
        try patch(removing: ["Sources/Beta.swift"], inserting: ["Sources/Beta.swift"])
        try patch(inserting: ["Sources/Delta.swift"])
        for fillerIndex in 0 ..< 17 {
            try patch(inserting: ["Filler/Before\(fillerIndex).txt"])
        }
        let capturedIndex = index
        let capture = try XCTUnwrap(capturedIndex.rebaseCapture())
        XCTAssertEqual(capture.overlayPayloadCount, 20)
        let capturedResults = queries.map { matches(capturedIndex, $0) }

        // After the capture: nineteen payloads, so the oldest of them sit in a compacted overlay page.
        // They remove a base entry, replace an entry an earlier overlay added, and re-add a removed path.
        try patch(removing: ["Sources/Alpha.swift"])
        try patch(removing: ["Sources/Delta.swift"], inserting: ["Sources/Delta.swift"])
        try patch(inserting: ["Docs/Notes.md"])
        for fillerIndex in 0 ..< 16 {
            try patch(inserting: ["Filler/After\(fillerIndex).txt"])
        }
        let overlaidIndex = index

        let rebasedBase = WorkspaceSearchRootPathIndex.buildRebasedBase(capture)
        let rebasedIndex = try XCTUnwrap(overlaidIndex.rebased(onto: rebasedBase))
        XCTAssertEqual(rebasedIndex.buildKind, .rebase)
        XCTAssertEqual(rebasedIndex.overlayPayloadCount, 19)
        XCTAssertEqual(rebasedIndex.overlayMentionCount, 20)

        let fresh = WorkspaceSearchRootPathIndex(identity: identity, rootPath: root.standardizedFullPath, entries: entries)
        for query in queries {
            XCTAssertEqual(matches(overlaidIndex, query), matches(fresh, query), "before the rebase: \(query)")
            XCTAssertEqual(matches(rebasedIndex, query), matches(fresh, query), "after the rebase: \(query)")
        }
        // A reader holding the captured index keeps the results it had, including the entries removed since.
        XCTAssertEqual(queries.map { matches(capturedIndex, $0) }, capturedResults)
        XCTAssertTrue(capturedResults[0].contains { $0.entry.standardizedRelativePath == "Sources/Alpha.swift" })
    }

    private func assertMappings(
        _ candidates: [PathSearchIndex.Candidate],
        in index: PathSearchIndex,
        paths: [String],
        expectedFilenames: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(expectedFilenames.count, paths.count, file: file, line: line)
        for candidate in candidates {
            XCTAssertTrue(paths.indices.contains(candidate.index), file: file, line: line)
            guard paths.indices.contains(candidate.index) else { continue }
            XCTAssertEqual(candidate.path, paths[candidate.index], file: file, line: line)
            XCTAssertEqual(candidate.filename, expectedFilenames[candidate.index], file: file, line: line)
            XCTAssertEqual(candidate.tieBreakKey, candidate.path, file: file, line: line)
            XCTAssertEqual(index.path(at: candidate.index), candidate.path, file: file, line: line)
            XCTAssertEqual(index.filename(at: candidate.index), expectedFilenames[candidate.index], file: file, line: line)
            XCTAssertEqual(index.filename(at: candidate.index), candidate.filename, file: file, line: line)
            XCTAssertEqual(candidate.score, 1, file: file, line: line)
        }
    }
}
