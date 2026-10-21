@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// A workspace document whose identities and dates are all persisted, so decoding it
    /// synthesizes nothing and the result may be cached. Revisions differ only in fixed-width
    /// text, so every revision encodes to the same byte count. Declared outside the main-actor
    /// suite so detached tasks can decode with it.
    private enum DigestDecodeFixture {
        static let url = URL(fileURLWithPath: "/nonexistent/WorkspaceDigestDecodeCacheTests/workspace.json")
        static let otherURL = URL(fileURLWithPath: "/nonexistent/WorkspaceDigestDecodeCacheTests/copy.json")

        static let workspaceID = fixedUUID(0x01)
        static let presetID = fixedUUID(0x02)
        static let firstTabID = fixedUUID(0x03)
        static let secondTabID = fixedUUID(0x04)
        static let stashID = fixedUUID(0x05)
        static let stashedTabID = fixedUUID(0x06)
        static let missingTabID = fixedUUID(0x07)
        static let duplicateStashID = fixedUUID(0x08)
        static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

        static func model(revision: Int) -> WorkspaceModel {
            let text = String(format: "r%04d", revision)
            let preset = WorkspacePreset(
                id: presetID,
                name: "Preset \(text)",
                selectedFilePaths: ["Sources/App/main.swift"],
                expandedFolders: ["Sources"],
                lastUpdated: date
            )
            let firstTab = ComposeTabState(
                id: firstTabID,
                name: "T1",
                lastModified: date,
                selection: StoredSelection(
                    selectedPaths: ["Sources/App/main.swift", "Sources/App/View.swift"],
                    manualCodemapPaths: ["Sources/Lib/API.swift"],
                    slices: ["Sources/App/View.swift": [LineRange(start: 10, end: 24, description: "body")]]
                ),
                expandedFolders: ["Sources", "Sources/App"],
                promptText: "Prompt \(text)"
            )
            let secondTab = ComposeTabState(
                id: secondTabID,
                name: "T2",
                lastModified: date,
                promptText: "Second \(text)"
            )
            let stash = StashedTab(
                id: stashID,
                tab: ComposeTabState(
                    id: stashedTabID,
                    name: "Stashed",
                    lastModified: date,
                    promptText: "Stashed \(text)"
                ),
                stashedAt: date
            )
            return WorkspaceModel(
                id: workspaceID,
                dateModified: date,
                name: "Workspace \(text)",
                repoPaths: ["/nonexistent/WorkspaceDigestDecodeCacheTests/repo"],
                presets: [preset],
                activePresetID: presetID,
                lastUsed: date,
                composeTabs: [firstTab, secondTab],
                activeComposeTabID: firstTabID,
                stashedTabs: [stash]
            )
        }

        static func bytes(revision: Int) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(model(revision: revision))
        }

        /// Legacy and malformed documents are built by editing the encoded JSON, because the
        /// model's memberwise initializer normalizes away the states these tests need.
        static func jsonObject(revision: Int) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: bytes(revision: revision)) as? [String: Any])
        }

        static func data(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        static func decode(_ bytes: Data, at fileURL: URL = DigestDecodeFixture.url) throws -> WorkspaceModel {
            try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: bytes, fileURL: fileURL)
        }

        static func edit(
            _ json: inout [String: Any],
            element index: Int,
            of key: String,
            _ edit: (inout [String: Any]) throws -> Void
        ) throws {
            var elements = try XCTUnwrap(json[key] as? [[String: Any]], key)
            try edit(&elements[index])
            json[key] = elements
        }

        static func edit(
            _ json: inout [String: Any],
            object key: String,
            _ edit: (inout [String: Any]) throws -> Void
        ) throws {
            var object = try XCTUnwrap(json[key] as? [String: Any], key)
            try edit(&object)
            json[key] = object
        }

        private static func fixedUUID(_ value: UInt8) -> UUID {
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
        }
    }

    private struct DigestStats: Equatable {
        var entries = 0
        var orderCount = 0
        var inputBytes = 0
        var hits = 0
        var misses = 0

        static var current: DigestStats {
            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            return DigestStats(
                entries: stats.entries,
                orderCount: stats.orderCount,
                inputBytes: stats.inputBytes,
                hits: stats.hits,
                misses: stats.misses
            )
        }
    }

    /// One decode fallback that invents a value, and how to reach it from a complete document.
    private struct SynthesisSite {
        let name: String
        let edit: (inout [String: Any]) throws -> Void
        /// Reads the synthesized identity when the fallback invents a UUID.
        var synthesizedID: ((WorkspaceModel) -> UUID?)?
    }

    @MainActor
    final class WorkspaceDigestDecodeCacheTests: XCTestCase {
        private typealias Fixture = DigestDecodeFixture

        private var savedLimits: (maxEntries: Int, maxInputBytes: Int)?

        /// The cache is a process-wide singleton, so every test starts and ends empty with the
        /// production limits. A limit change takes effect at the next store, so tests set limits
        /// before their first decode.
        override func setUp() async throws {
            try await super.setUp()
            savedLimits = WorkspaceFileDecodeCache.shared.decodeCacheLimitsForTesting()
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            if let savedLimits {
                WorkspaceFileDecodeCache.shared.setDecodeCacheLimitsForTesting(
                    maxEntries: savedLimits.maxEntries,
                    maxInputBytes: savedLimits.maxInputBytes
                )
            }
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
            try await super.tearDown()
        }

        func testIdenticalBytesReuseDecodeWithoutSharingMutations() throws {
            let bytes = try Fixture.bytes(revision: 1)
            let expected = Fixture.model(revision: 1)

            var first = try Fixture.decode(bytes)
            XCTAssertEqual(first, expected)
            first.name = "edited"
            first.composeTabs[0].promptText = "edited prompt"
            first.composeTabs[0].selection = StoredSelection(
                selectedPaths: ["edited.swift"],
                slices: ["edited.swift": [LineRange(start: 1, end: 2, description: "edited")]]
            )
            first.presets[0].selectedFilePaths.removeAll()
            first.stashedTabs[0].tab.promptText = "edited stash"

            XCTAssertEqual(try Fixture.decode(bytes), expected)
            XCTAssertEqual(try Fixture.decode(bytes, at: Fixture.otherURL), expected)
            XCTAssertEqual(
                DigestStats.current,
                DigestStats(entries: 1, orderCount: 1, inputBytes: bytes.count, hits: 2, misses: 1)
            )
        }

        func testChangedBytesAtSameURLDecodeCurrentContent() throws {
            let documentA = try Fixture.bytes(revision: 1)
            let documentB = try Fixture.bytes(revision: 2)

            XCTAssertEqual(try Fixture.decode(documentA), Fixture.model(revision: 1))
            XCTAssertEqual(try Fixture.decode(documentB), Fixture.model(revision: 2))
            XCTAssertEqual(try Fixture.decode(documentA), Fixture.model(revision: 1))
            let resident = DigestStats(
                entries: 2,
                orderCount: 2,
                inputBytes: documentA.count + documentB.count,
                hits: 1,
                misses: 2
            )
            XCTAssertEqual(DigestStats.current, resident)

            XCTAssertThrowsError(try Fixture.decode(Data("{".utf8)))
            var afterFailure = resident
            afterFailure.misses += 1
            XCTAssertEqual(DigestStats.current, afterFailure)
        }

        func testCacheLimitsEvictLeastRecentlyUsedDigest() throws {
            let documentA = try Fixture.bytes(revision: 1)
            let documentB = try Fixture.bytes(revision: 2)
            let documentC = try Fixture.bytes(revision: 3)
            let documentSize = documentA.count
            XCTAssertEqual([documentB.count, documentC.count], [documentSize, documentSize])
            let cases: [(binding: String, maxEntries: Int, maxInputBytes: Int)] = [
                ("entry limit", 2, .max),
                ("byte limit", 128, 2 * documentSize)
            ]

            for limits in cases {
                WorkspaceFileDecodeCache.shared.removeAllForTesting()
                WorkspaceFileDecodeCache.shared.setDecodeCacheLimitsForTesting(
                    maxEntries: limits.maxEntries,
                    maxInputBytes: limits.maxInputBytes
                )

                // Reading A again makes B the least recently used, so storing C evicts B.
                for document in [documentA, documentB, documentA, documentC] {
                    _ = try Fixture.decode(document)
                }
                XCTAssertEqual(
                    DigestStats.current,
                    DigestStats(entries: 2, orderCount: 2, inputBytes: 2 * documentSize, hits: 1, misses: 3),
                    limits.binding
                )

                XCTAssertEqual(try Fixture.decode(documentA), Fixture.model(revision: 1), limits.binding)
                XCTAssertEqual(try Fixture.decode(documentC), Fixture.model(revision: 3), limits.binding)
                XCTAssertEqual(DigestStats.current.hits, 3, limits.binding)
                XCTAssertEqual(try Fixture.decode(documentB), Fixture.model(revision: 2), limits.binding)
                XCTAssertEqual(DigestStats.current.misses, 4, limits.binding)
            }
        }

        func testOversizedDocumentsBypassCacheWithoutEvictingResidents() throws {
            let documentA = try Fixture.bytes(revision: 1)
            let documentB = try Fixture.bytes(revision: 2)
            let residentBytes = documentA.count + documentB.count
            WorkspaceFileDecodeCache.shared.setDecodeCacheLimitsForTesting(
                maxEntries: 128,
                maxInputBytes: residentBytes
            )
            _ = try Fixture.decode(documentA)
            _ = try Fixture.decode(documentB)
            let resident = DigestStats(entries: 2, orderCount: 2, inputBytes: residentBytes, hits: 0, misses: 2)
            XCTAssertEqual(DigestStats.current, resident)

            // Trailing JSON whitespace keeps the content and pushes the input past the byte limit.
            var oversized = documentA
            oversized.append(Data(repeating: UInt8(ascii: " "), count: residentBytes))
            XCTAssertEqual(try Fixture.decode(oversized), Fixture.model(revision: 1))
            XCTAssertEqual(try Fixture.decode(oversized), Fixture.model(revision: 1))
            var afterOversized = resident
            afterOversized.misses += 2
            XCTAssertEqual(DigestStats.current, afterOversized)

            XCTAssertEqual(try Fixture.decode(documentA), Fixture.model(revision: 1))
            XCTAssertEqual(DigestStats.current.hits, afterOversized.hits + 1)
        }

        func testSynthesisSitesPreventMemoizationOnMainAndDetachedTasks() async throws {
            let sites = [
                SynthesisSite(name: "workspace id", edit: { $0["id"] = nil }, synthesizedID: { $0.id }),
                SynthesisSite(name: "workspace dateModified", edit: { $0["dateModified"] = nil }),
                SynthesisSite(name: "workspace lastUsed", edit: { $0["lastUsed"] = nil }),
                SynthesisSite(
                    name: "preset id",
                    edit: { json in try Fixture.edit(&json, element: 0, of: "presets") { $0["id"] = nil } },
                    synthesizedID: { $0.presets.first?.id }
                ),
                SynthesisSite(
                    name: "preset lastUpdated",
                    edit: { json in try Fixture.edit(&json, element: 0, of: "presets") { $0["lastUpdated"] = nil } }
                ),
                SynthesisSite(
                    name: "compose tab id",
                    edit: { json in try Fixture.edit(&json, element: 1, of: "composeTabs") { $0["id"] = nil } },
                    synthesizedID: { $0.composeTabs.last?.id }
                ),
                SynthesisSite(
                    name: "compose tab lastModified",
                    edit: { json in try Fixture.edit(&json, element: 1, of: "composeTabs") { $0["lastModified"] = nil } }
                ),
                SynthesisSite(
                    name: "stashed tab id",
                    edit: { json in
                        try Fixture.edit(&json, element: 0, of: "stashedTabs") { stash in
                            try Fixture.edit(&stash, object: "tab") { $0["id"] = nil }
                        }
                    },
                    synthesizedID: { $0.stashedTabs.first?.tab.id }
                ),
                SynthesisSite(
                    name: "stashed tab lastModified",
                    edit: { json in
                        try Fixture.edit(&json, element: 0, of: "stashedTabs") { stash in
                            try Fixture.edit(&stash, object: "tab") { $0["lastModified"] = nil }
                        }
                    }
                ),
                SynthesisSite(
                    name: "absent composeTabs",
                    edit: { $0["composeTabs"] = nil },
                    synthesizedID: { $0.composeTabs.first?.id }
                ),
                SynthesisSite(
                    name: "empty composeTabs",
                    edit: { $0["composeTabs"] = [Any]() },
                    synthesizedID: { $0.composeTabs.first?.id }
                ),
                SynthesisSite(
                    name: "malformed composeTabs",
                    edit: { $0["composeTabs"] = "not an array" },
                    synthesizedID: { $0.composeTabs.first?.id }
                )
            ]

            for site in sites {
                WorkspaceFileDecodeCache.shared.removeAllForTesting()
                var json = try Fixture.jsonObject(revision: 1)
                try site.edit(&json)
                let document = try Fixture.data(json)

                let first = try Fixture.decode(document)
                let second = try Fixture.decode(document)

                XCTAssertEqual(DigestStats.current, DigestStats(misses: 2), site.name)
                if let synthesizedID = site.synthesizedID {
                    XCTAssertNotEqual(synthesizedID(first), synthesizedID(second), site.name)
                }
            }

            WorkspaceFileDecodeCache.shared.removeAllForTesting()
            let legacy = Data(#"{"name":"Legacy","repoPaths":[]}"#.utf8)
            let onMainActor = try Fixture.decode(legacy)
            let onMainActorElsewhere = try Fixture.decode(legacy, at: Fixture.otherURL)
            let detached = try await Task.detached {
                try DigestDecodeFixture.decode(legacy)
            }.value

            let decodes = [onMainActor, onMainActorElsewhere, detached]
            XCTAssertEqual(Set(decodes.map(\.id)).count, 3)
            XCTAssertEqual(Set(decodes.compactMap { $0.composeTabs.first?.id }).count, 3)
            XCTAssertEqual(DigestStats.current, DigestStats(misses: 3))
        }

        /// Two concurrent cold misses on the same bytes both store their decode; the second store
        /// must replace the first rather than charge the digest twice.
        func testRepeatedDigestStoreChargesOneEntry() {
            let model = Fixture.model(revision: 1)
            for _ in 0 ..< 2 {
                WorkspaceFileDecodeCache.shared.storeDecodedForTesting(
                    workspace: model,
                    normalizationRequiresSave: false,
                    digest: "repeated-digest",
                    inputByteCount: 1024
                )
            }

            XCTAssertEqual(DigestStats.current, DigestStats(entries: 1, orderCount: 1, inputBytes: 1024))
        }

        /// Repairs that choose an existing active tab or drop a stashed duplicate are deterministic,
        /// so their result is shared, and every hit still reports that the document needs saving.
        func testDeterministicRepairIsCachedWithItsSaveFlag() throws {
            var json = try Fixture.jsonObject(revision: 1)
            json["activeComposeTabID"] = Fixture.missingTabID.uuidString
            let activeTab = try XCTUnwrap((json["composeTabs"] as? [[String: Any]])?.first)
            var stashes = try XCTUnwrap(json["stashedTabs"] as? [[String: Any]])
            var duplicateStash = stashes[0]
            duplicateStash["id"] = Fixture.duplicateStashID.uuidString
            duplicateStash["tab"] = activeTab
            stashes.append(duplicateStash)
            json["stashedTabs"] = stashes
            let document = try Fixture.data(json)

            let first = try Fixture.decode(document)
            let second = try Fixture.decode(document)

            for decoded in [first, second] {
                XCTAssertEqual(decoded.activeComposeTabID, Fixture.firstTabID)
                XCTAssertEqual(decoded.stashedTabs.map(\.id), [Fixture.stashID])
                XCTAssertTrue(decoded.normalizationRequiresSave)
            }
            XCTAssertEqual(
                DigestStats.current,
                DigestStats(entries: 1, orderCount: 1, inputBytes: document.count, hits: 1, misses: 1)
            )
        }
    }
#endif
