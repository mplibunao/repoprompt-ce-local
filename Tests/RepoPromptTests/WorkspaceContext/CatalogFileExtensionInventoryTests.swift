import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CatalogFileExtensionInventoryTests: XCTestCase {
    func testHeavyRecountUsesAllLoadedLanguageInventoryWithoutEnumeratingFiles() async throws {
        let directory = try makeTemporaryDirectory()
        let primaryURL = directory.appendingPathComponent("primary", isDirectory: true)
        let sessionURL = directory.appendingPathComponent("session", isDirectory: true)
        try writeFixtures(["main.SWIFT", "script.py", "README", "unknown.zzz"], in: primaryURL)
        try writeFixtures(["app.ts", "more.py"], in: sessionURL)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let primary = try await store.loadRoot(path: primaryURL.path)
        let session = try await store.loadRoot(path: sessionURL.path, kind: .sessionWorktree)
        addTeardownBlock {
            await store.unloadRoot(id: primary.id)
            await store.unloadRoot(id: session.id)
        }
        // The languages the recount found when it enumerated every loaded root's files.
        let primaryFiles = await store.files(inRoot: primary.id)
        let sessionFiles = await store.files(inRoot: session.id)
        let expectedLanguages = Set((primaryFiles + sessionFiles).compactMap {
            SyntaxManager.shared.extensionToLanguage[($0.name as NSString).pathExtension.lowercased()]
        })
        XCTAssertFalse(expectedLanguages.isEmpty)

        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let git = GitViewModel(fileManager: manager, gitContextRefreshIntervalNanoseconds: 0)
        let counter = TokenCountingViewModel()
        counter.suspendAutomaticRecounts()
        counter.configure(
            fileManager: manager,
            gitViewModel: git,
            getPromptText: { "" },
            getSelectedInstructionsText: { "" },
            getSettings: {
                .init(
                    fileTreeOption: .none,
                    codeMapUsage: .none,
                    filePathDisplayOption: .relative,
                    includeFilesInClipboard: false,
                    duplicateUserInstructionsAtTop: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    codeMapsGloballyDisabled: true
                )
            },
            getCopyContext: {
                .init(
                    includeFiles: false,
                    includeUserPrompt: false,
                    includeMetaPrompts: false,
                    includeFileTree: false,
                    fileTreeMode: .none,
                    codeMapUsage: .none,
                    gitInclusion: .none,
                    duplicateUserInstructionsAtTop: false
                )
            },
            getStoredSelection: { StoredSelection() }
        )
        addTeardownBlock {
            await counter.stopTokenCountUpdateTimer()
        }
        await store.resetFilesInRootRequestCountForTesting()

        await counter.forceImmediateRecount()

        XCTAssertEqual(counter.scannedLanguages, expectedLanguages)
        let enumerations = await store.fileEnumerationRequestCountForTesting()
        XCTAssertEqual(enumerations, 0)
        let extensions = await store.allLoadedFileExtensions()
        XCTAssertEqual(extensions, ["swift", "py", "ts", "", "zzz"])
        // The counter holds both weakly, and a released one ends the recount early.
        withExtendedLifetime((manager, git)) {}
    }

    func testInventoryTracksDiscoverableCatalogMembership() async throws {
        let directory = try makeTemporaryDirectory()
        let primaryURL = directory.appendingPathComponent("primary", isDirectory: true)
        let sessionURL = directory.appendingPathComponent("session", isDirectory: true)
        try writeFixtures(
            ["First.SWIFT", "second.swift", "Makefile", "notes.zzz", "nested/script.py", "nested/deep/guide.md"],
            in: primaryURL
        )
        try writeFixtures(["lib.py", "tool.rs"], in: sessionURL)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let primary = try await store.loadRoot(path: primaryURL.path)
        let session = try await store.loadRoot(path: sessionURL.path, kind: .sessionWorktree)
        addTeardownBlock {
            await store.unloadRoot(id: primary.id)
            await store.unloadRoot(id: session.id)
        }
        await assertInventory(of: store, equals: ["swift", "", "zzz", "py", "md", "rs"])

        // Adding a file the catalog already has counts nothing; a later removal would otherwise leave "swift".
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: primary.id,
            deltas: [.fileAdded("First.SWIFT")]
        )
        await assertInventory(of: store, equals: ["swift", "", "zzz", "py", "md", "rs"])

        try writeFixtures(["added.ts"], in: primaryURL)
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: primary.id,
            deltas: [.fileAdded("added.ts")]
        )
        await assertInventory(of: store, equals: ["swift", "", "zzz", "py", "md", "rs", "ts"])

        try FileManager.default.removeItem(at: primaryURL.appendingPathComponent("second.swift"))
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: primary.id,
            deltas: [.fileRemoved("second.swift")]
        )
        await assertInventory(of: store, equals: ["swift", "", "zzz", "py", "md", "rs", "ts"])

        try FileManager.default.removeItem(at: primaryURL.appendingPathComponent("First.SWIFT"))
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: primary.id,
            deltas: [.fileRemoved("First.SWIFT")]
        )
        await assertInventory(of: store, equals: ["", "zzz", "py", "md", "rs", "ts"])

        // The subtree holds the only .md file and the primary root's only .py file; the session root keeps "py".
        try FileManager.default.removeItem(at: primaryURL.appendingPathComponent("nested"))
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: primary.id,
            deltas: [.folderRemoved("nested")]
        )
        await assertInventory(of: store, equals: ["", "zzz", "py", "rs", "ts"])

        await store.unloadRoot(id: primary.id)
        await assertInventory(of: store, equals: ["py", "rs"])
        await store.unloadRoot(id: session.id)
        await assertInventory(of: store, equals: [])
    }

    func testManagedOnlyTransitionsDoNotCorruptInventory() async throws {
        let directory = try makeTemporaryDirectory()
        let rootURL = directory.appendingPathComponent("root", isDirectory: true)
        try writeFixtures(["main.swift"], in: rootURL)
        let gitignoreURL = rootURL.appendingPathComponent(".gitignore")
        try "*.toml\n".write(to: gitignoreURL, atomically: true, encoding: .utf8)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
        }
        let before = await store.allLoadedFileExtensions()
        XCTAssertFalse(before.contains("toml"))
        let configURL = rootURL.appendingPathComponent("config.toml")

        // A write to an ignored file makes it managed-only, which doesn't make it discoverable.
        try writeFixtures(["config.toml"], in: rootURL)
        for _ in 0 ..< 2 {
            _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "config.toml")
            await assertInventory(of: store, equals: before)
        }

        // The catalog preflight rejects a file-system add for the ignored file.
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: root.id,
            deltas: [.fileAdded("config.toml")]
        )
        await assertInventory(of: store, equals: before)

        // Removing a managed-only file takes back no count. No discoverable file has "toml", so a decrement here
        // fails the missing-key assertion.
        try FileManager.default.removeItem(at: configURL)
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: root.id,
            deltas: [.fileRemoved("config.toml")]
        )
        let removedRecord = await store.file(rootID: root.id, relativePath: "config.toml")
        XCTAssertNil(removedRecord)
        await assertInventory(of: store, equals: before)

        try writeFixtures(["config.toml"], in: rootURL)
        _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "config.toml")
        await assertInventory(of: store, equals: before)
        let managedRecord = await store.file(rootID: root.id, relativePath: "config.toml")
        let managedFile = try XCTUnwrap(managedRecord)

        // Without the ignore rule, the next write promotes the same record, and a repeated write counts nothing.
        try "".write(to: gitignoreURL, atomically: true, encoding: .utf8)
        _ = try await store.refreshFileSystemSettings(
            rootID: root.id,
            respectRepoIgnore: true,
            respectCursorignore: true,
            skipSymlinks: true,
            enableHierarchicalIgnores: true
        )
        for _ in 0 ..< 2 {
            _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "config.toml")
            let discoverable = await store.files(inRoot: root.id).filter { $0.name == "config.toml" }
            XCTAssertEqual(discoverable.map(\.id), [managedFile.id])
            await assertInventory(of: store, equals: before.union(["toml"]))
        }

        // A second count from either promotion would leave "toml" behind after the removal.
        try FileManager.default.removeItem(at: configURL)
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: root.id,
            deltas: [.fileRemoved("config.toml")]
        )
        await assertInventory(of: store, equals: before)
    }

    /// Checks the inventory against `expected` and against the extensions of the files that `files(inRoot:)`
    /// returns for every root in `roots()`, which is how token counting found them before the inventory.
    private func assertInventory(
        of store: WorkspaceFileContextStore,
        equals expected: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let inventory = await store.allLoadedFileExtensions()
        var enumerated = Set<String>()
        for root in await store.roots() {
            for record in await store.files(inRoot: root.id) {
                enumerated.insert((record.name as NSString).pathExtension.lowercased())
            }
        }
        XCTAssertEqual(inventory, expected, "inventory", file: file, line: line)
        XCTAssertEqual(enumerated, expected, "extensions of the enumerated files", file: file, line: line)
    }

    private func writeFixtures(_ relativePaths: [String], in directory: URL) throws {
        for relativePath in relativePaths {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "fixture\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("CatalogFileExtensionInventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
