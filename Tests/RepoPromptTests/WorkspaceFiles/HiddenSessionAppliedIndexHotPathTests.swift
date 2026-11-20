import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class HiddenSessionAppliedIndexHotPathTests: XCTestCase {
    func testHiddenSessionEventsUseBoundedRecordLookups() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ordinaryURL = directory.appendingPathComponent("ordinary", isDirectory: true)
        let hiddenURL = directory.appendingPathComponent("hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        try "let first = 1\n".write(to: hiddenURL.appendingPathComponent("first.swift"), atomically: true, encoding: .utf8)
        try "let second = 2\n".write(to: hiddenURL.appendingPathComponent("second.swift"), atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let ordinary = try await store.loadRoot(path: ordinaryURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: ordinary.id)
        }
        let hidden = try await store.loadRoot(path: hiddenURL.path, kind: .sessionWorktree)
        addTeardownBlock {
            await store.unloadRoot(id: hidden.id)
        }
        let firstRecord = await store.file(rootID: hidden.id, relativePath: "first.swift")
        let secondRecord = await store.file(rootID: hidden.id, relativePath: "second.swift")
        let first = try XCTUnwrap(firstRecord)
        let second = try XCTUnwrap(secondRecord)
        let modifiedFileIDs = [first.id, second.id]
        let ordinaryLifetime = try await store.rootLifetimeIDForTesting(rootID: ordinary.id)
        let hiddenLifetime = try await store.rootLifetimeIDForTesting(rootID: hidden.id)
        let viewModel = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let emptyEvent = WorkspaceAppliedIndexBatchEvent(
            rootID: hidden.id, rootPath: hidden.fullPath, generation: 1, rootLifetimeID: hiddenLifetime
        )
        let modifiedEvent = WorkspaceAppliedIndexBatchEvent(
            rootID: hidden.id, rootPath: hidden.fullPath, generation: 2, rootLifetimeID: hiddenLifetime,
            modifiedFileIDs: modifiedFileIDs
        )
        await store.resetFilesInRootRequestCountForTesting()
        await store.resetAppliedIndexRecordLookupDiagnosticsForTesting()

        for event in [
            WorkspaceAppliedIndexBatchEvent(
                rootID: ordinary.id, rootPath: ordinary.fullPath, generation: 1, rootLifetimeID: ordinaryLifetime
            ),
            WorkspaceAppliedIndexBatchEvent(
                rootID: hidden.id, rootPath: ordinary.fullPath, generation: 1, rootLifetimeID: hiddenLifetime
            ),
            emptyEvent,
            emptyEvent,
            modifiedEvent,
            modifiedEvent
        ] {
            await viewModel.applyWorkspaceAppliedIndexEventForTesting(event)
        }

        let enumerations = await store.fileEnumerationRequestCountForTesting()
        let diagnostics = await store.appliedIndexRecordLookupDiagnosticsForTesting()
        XCTAssertEqual(enumerations, 0)
        XCTAssertEqual(diagnostics.rootSnapshots, 0)
        XCTAssertEqual(diagnostics.lookupRequests, 2)
        XCTAssertEqual(diagnostics.requestedRecords, 2)

        let lookupResult = await store.appliedIndexRecordLookup(rootID: hidden.id, fileIDs: modifiedFileIDs, folderIDs: [])
        let snapshotResult = await store.appliedIndexRootSnapshot(rootID: hidden.id)
        let lookup = try XCTUnwrap(lookupResult)
        let snapshot = try XCTUnwrap(snapshotResult)
        let modifiedIDs = Set(modifiedFileIDs)
        let expected = Dictionary(uniqueKeysWithValues: snapshot.files.compactMap { file in
            guard modifiedIDs.contains(file.id), file.rootID == hidden.id else { return nil as (UUID, WorkspaceFileRecord)? }
            return (file.id, file)
        })
        XCTAssertEqual(lookup.filesByID, expected)
        XCTAssertEqual(Set(lookup.filesByID.keys), modifiedIDs)
        XCTAssertTrue(lookup.foldersByID.isEmpty)
    }
}
