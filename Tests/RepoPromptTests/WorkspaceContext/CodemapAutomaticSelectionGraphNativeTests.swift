import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapAutomaticSelectionGraphNativeTests: XCTestCase {
    func testUnrelatedGitIndexChurnDoesNotRestartGraphPage() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let indexURL = rootURL.appendingPathComponent(".git/index")
        let authorityCaptures = CodemapLockedValues<Int>()
        let fixture = try CodemapStoreFixture(
            name: #function,
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterFirstAuthorityCapture: {
                    let shouldChurn = !authorityCaptures.values.isEmpty
                    authorityCaptures.append(1)
                    if shouldChurn {
                        try? FileManager.default.setAttributes(
                            [.modificationDate: Date()],
                            ofItemAtPath: indexURL.path
                        )
                    }
                }
            )
        )
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            repository.cleanup()
        }

        let engine = try fixture.runtime().bindingEngine()
        let rootAccounting = try await waitForGraphCompletion(
            engine: engine,
            rootID: loaded.id
        )

        XCTAssertEqual(rootAccounting.phase, .complete)
        XCTAssertEqual(rootAccounting.retryAttempt, 0)
        XCTAssertNil(rootAccounting.retry)
        XCTAssertEqual(rootAccounting.progress.counts.processedCandidateCount, 2)
        XCTAssertGreaterThan(authorityCaptures.values.count, 1)
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.counters.graphIndexRetries, 0)
    }

    func testNestedRepositoryGraphUsesValidatedWorktreeBytesAndCompletesWithoutRetry() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let relativePath = "Nested/Sources/Feature.swift"
        let rootURL = try repository.makeRepository(
            named: "outer",
            files: [relativePath: "struct OuterBlobOnly { let value: Int }\n"]
        )
        let nestedRoot = rootURL.appendingPathComponent("Nested", isDirectory: true)
        try repository.initializeRepository(at: nestedRoot)
        try repository.write(
            "struct NestedWorktreeOnly { let value: Int }\n",
            to: "Sources/Feature.swift",
            at: nestedRoot
        )
        try repository.stage("Sources/Feature.swift", at: nestedRoot)
        try repository.commit("Nested worktree content", at: nestedRoot)

        let outerBlob = try repository.runGit(["show", "HEAD:\(relativePath)"], at: rootURL)
        let worktreeBytes = try String(
            contentsOf: rootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        XCTAssertTrue(outerBlob.contains("OuterBlobOnly"))
        XCTAssertTrue(worktreeBytes.contains("NestedWorktreeOnly"))

        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            repository.cleanup()
        }

        let files = await store.files(inRoot: loaded.id)
        let nestedFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == relativePath
        })
        let engine = try fixture.runtime().bindingEngine()
        let rootAccounting = try await waitForGraphCompletion(
            engine: engine,
            rootID: loaded.id
        )

        XCTAssertEqual(rootAccounting.phase, .complete)
        XCTAssertEqual(rootAccounting.retryAttempt, 0)
        XCTAssertNil(rootAccounting.retry)
        XCTAssertNotNil(rootAccounting.progress.catalogCompletion)
        XCTAssertEqual(rootAccounting.progress.counts.transientCount, 0)
        XCTAssertEqual(rootAccounting.progress.counts.terminalExcludedCount, 0)

        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.counters.graphIndexRetries, 0)
        let pinned = try await requireReadySnapshot(engine: engine, rootEpoch: rootAccounting.rootEpoch)

        XCTAssertTrue(pinned.snapshot.coverage.isComplete)
        XCTAssertEqual(pinned.snapshot.coverage.pendingCount, 0)
        XCTAssertEqual(pinned.snapshot.coverage.terminalExcludedCount, 0)
        let node = try XCTUnwrap(pinned.snapshot.nodesByFileID[nestedFile.id])
        XCTAssertTrue(node.contribution.sortedUniqueDefinitions.contains("NestedWorktreeOnly"))
        XCTAssertFalse(node.contribution.sortedUniqueDefinitions.contains("OuterBlobOnly"))
        guard case .contributed = pinned.snapshot.slotsByFileID[nestedFile.id]?.state else {
            return XCTFail("Nested source should contribute to the completed graph")
        }
        XCTAssertFalse(pinned.snapshot.slotsByFileID.values.contains { slot in
            if case .terminalExcluded(.repositoryBoundary) = slot.state { return true }
            return false
        })
        XCTAssertTrue(fixture.builtSourceTexts.values.contains { $0.contains("NestedWorktreeOnly") })
        XCTAssertFalse(fixture.builtSourceTexts.values.contains { $0.contains("OuterBlobOnly") })
    }

    /// Runs on the main actor because XCTest can drop an off-main assertion failure that it hasn't
    /// recorded by the time an async test returns.
    @MainActor
    func testUncommittedEditRefreshesGraphWithoutArtifactDemand() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let editedPath = "Sources/Shared.swift"
        let referencingPath = "Sources/Client.swift"
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                editedPath: "struct SharedModel { let id: Int }\nstruct OldMarker { let flag: Bool }\n",
                referencingPath: "struct Client { let model: SharedModel }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            repository.cleanup()
        }

        let files = await store.files(inRoot: loaded.id)
        let editedFile = try XCTUnwrap(files.first { $0.standardizedRelativePath == editedPath })
        let referencingFile = try XCTUnwrap(files.first { $0.standardizedRelativePath == referencingPath })
        let engine = try fixture.runtime().bindingEngine()
        let initialAccounting = try await waitForGraphCompletion(engine: engine, rootID: loaded.id)
        let initial = try await requireReadySnapshot(engine: engine, rootEpoch: initialAccounting.rootEpoch)
        let initialSlot = try XCTUnwrap(initial.snapshot.slotsByFileID[editedFile.id])
        XCTAssertTrue(definitions(in: initial, fileID: editedFile.id).contains("OldMarker"))
        XCTAssertTrue(hasEdge(in: initial, from: referencingFile.id, to: editedFile.id, named: "SharedModel"))
        let completedRunCount = await engine.accounting().counters.graphIndexCoveragesCompleted

        // Edit without committing, then replay the watcher event. The test reads the graph directly:
        // an artifact demand would clear the path's shadow by itself and mask a missing refresh.
        try repository.write(
            "struct SharedModel { let id: Int }\nstruct NewMarker { let flag: Bool }\n",
            to: editedPath,
            at: rootURL
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(editedPath, Date())]
        )

        let refreshedAccounting = try await waitForGraphCompletion(
            engine: engine,
            rootID: loaded.id,
            afterCompletedRunCount: completedRunCount
        )
        let refreshed = try await requireReadySnapshot(engine: engine, rootEpoch: refreshedAccounting.rootEpoch)
        let refreshedSlot = refreshed.snapshot.slotsByFileID[editedFile.id]
        XCTAssertGreaterThan(
            refreshed.snapshot.appliedGeneration.rawValue,
            initial.snapshot.appliedGeneration.rawValue
        )
        XCTAssertTrue(refreshed.snapshot.coverage.isComplete)
        XCTAssertEqual(refreshed.snapshot.coverage.pendingCount, 0)
        XCTAssertGreaterThan(refreshedSlot?.pathGeneration ?? 0, initialSlot.pathGeneration)
        guard case .contributed = refreshedSlot?.state else {
            return XCTFail(
                "The edited file should contribute after a later completed run; observed \(String(describing: refreshedSlot?.state)) at path generation \(String(describing: refreshedSlot?.pathGeneration))"
            )
        }
        let refreshedDefinitions = definitions(in: refreshed, fileID: editedFile.id)
        XCTAssertTrue(refreshedDefinitions.contains("NewMarker"))
        XCTAssertFalse(refreshedDefinitions.contains("OldMarker"))
        XCTAssertTrue(hasEdge(in: refreshed, from: referencingFile.id, to: editedFile.id, named: "SharedModel"))
    }

    private func requireReadySnapshot(
        engine: WorkspaceCodemapBindingEngine,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async throws -> WorkspaceCodemapGraphPinnedSnapshot {
        let maybeGraph = await engine.selectionGraph(rootEpoch: rootEpoch)
        let graph = try XCTUnwrap(maybeGraph)
        switch await graph.latestSnapshot() {
        case let .ready(snapshot):
            return snapshot
        case .pending:
            throw GraphWaitError.snapshotNotReady
        case let .revoked(reason):
            throw GraphWaitError.snapshotRevoked(String(describing: reason))
        }
    }

    private func definitions(in pinned: WorkspaceCodemapGraphPinnedSnapshot, fileID: UUID) -> [String] {
        pinned.snapshot.nodesByFileID[fileID]?.contribution.sortedUniqueDefinitions ?? []
    }

    private func hasEdge(
        in pinned: WorkspaceCodemapGraphPinnedSnapshot,
        from sourceFileID: UUID,
        to targetFileID: UUID,
        named name: String
    ) -> Bool {
        (pinned.snapshot.outgoingEdgesBySource[sourceFileID] ?? []).contains {
            $0.targetFileID == targetFileID && $0.matchedNames.contains(name)
        }
    }

    private func waitForGraphCompletion(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID,
        afterCompletedRunCount: UInt64? = nil
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: { $0.rootEpoch.rootID == rootID }),
               root.phase == .complete,
               afterCompletedRunCount.map({ accounting.counters.graphIndexCoveragesCompleted > $0 }) ?? true
            {
                return root
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GraphWaitError.timedOut
    }
}

private enum GraphWaitError: Error {
    case timedOut
    case snapshotNotReady
    case snapshotRevoked(String)
}
