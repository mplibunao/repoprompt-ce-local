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

    /// Runs on the main actor for the reason given on `testUncommittedEditRefreshesGraphWithoutArtifactDemand`.
    @MainActor
    func testTerraformManifestLifecycleProducesIdenticalGraph() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                "projects/demo/compute.tf": Self.workerCall(source: "../../modules/worker"),
                "projects/demo/outputs.tf": "output \"endpoint\" {\n  value = module.worker[0].endpoint\n}\n",
                "projects/prod/compute.tf": Self.workerCall(source: "../../modules/worker"),
                "modules/worker/main.tf": "resource \"null_resource\" \"worker\" {\n  triggers = { project = var.project_id }\n}\n",
                "modules/worker/variables.tf": "variable \"project_id\" {\n  type = string\n}\n",
                "modules/worker/outputs.tf": "output \"endpoint\" {\n  value = null_resource.worker.id\n}\n",
                "modules/other/outputs.tf": "output \"endpoint\" {\n  value = \"other\"\n}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }

        // Cold: real parsing reaches the graph as folder-scoped links.
        let coldLoad = try await store.loadRoot(path: rootURL.path)
        let engine = try fixture.runtime().bindingEngine()
        let coldRun = try await waitForGraphCompletion(engine: engine, rootID: coldLoad.id)
        let cold = try await PathKeyedGraph(requireReadySnapshot(engine: engine, rootEpoch: coldRun.rootEpoch).snapshot)
        XCTAssertEqual(cold.links, [
            "modules/worker/main.tf -> modules/worker/variables.tf",
            "modules/worker/outputs.tf -> modules/worker/main.tf",
            "projects/demo/compute.tf -> modules/worker/main.tf",
            "projects/demo/compute.tf -> modules/worker/outputs.tf",
            "projects/demo/compute.tf -> modules/worker/variables.tf",
            "projects/demo/outputs.tf -> modules/worker/outputs.tf",
            "projects/demo/outputs.tf -> projects/demo/compute.tf",
            "projects/prod/compute.tf -> modules/worker/main.tf",
            "projects/prod/compute.tf -> modules/worker/outputs.tf",
            "projects/prod/compute.tf -> modules/worker/variables.tf"
        ])
        XCTAssertEqual(cold.unresolved, [])

        // Warm: reloading the unchanged root rebuilds every contribution from the manifest and parses nothing.
        let buildsAfterCold = fixture.builtSourceTexts.values.count
        let envelopeHitsAfterCold = await engine.accounting().counters.graphIndexEnvelopeHits
        await store.unloadRoot(id: coldLoad.id)
        let warmLoad = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: warmLoad.id) }
        let warmRun = try await waitForGraphCompletion(
            engine: engine,
            rootID: warmLoad.id,
            excluding: coldRun.rootEpoch
        )
        let warm = try await PathKeyedGraph(requireReadySnapshot(engine: engine, rootEpoch: warmRun.rootEpoch).snapshot)
        XCTAssertEqual(fixture.builtSourceTexts.values.count, buildsAfterCold)
        let envelopeHitsAfterWarm = await engine.accounting().counters.graphIndexEnvelopeHits
        XCTAssertEqual(envelopeHitsAfterWarm - envelopeHitsAfterCold, UInt64(cold.contributions.count))
        XCTAssertEqual(warm, cold)

        // Live edit: pointing demo's call at another module moves its links, and those of the unchanged
        // sibling that reads the call's output.
        try repository.write(Self.workerCall(source: "../../modules/other"), to: "projects/demo/compute.tf", at: rootURL)
        await store.replayObservedFileSystemDeltas(
            rootID: warmLoad.id,
            deltas: [.fileModified("projects/demo/compute.tf", Date())]
        )
        let edited = try await waitForGraph(engine: engine, rootEpoch: warmRun.rootEpoch) {
            $0.contributions["projects/demo/compute.tf"] != cold.contributions["projects/demo/compute.tf"]
        }
        XCTAssertEqual(edited.targets(of: "projects/demo/compute.tf"), ["modules/other/outputs.tf"])
        XCTAssertEqual(
            edited.targets(of: "projects/demo/outputs.tf"),
            ["modules/other/outputs.tf", "projects/demo/compute.tf"]
        )
        XCTAssertEqual(edited.unresolved, [PathKeyedGraph.Unresolved(
            source: "projects/demo/compute.tf",
            name: #"terraform "projects/demo"::module."worker" input "project_id" -> "modules/other"::var."project_id""#,
            reason: .missing
        )])

        // Moving the output file into another stack keeps its artifact, drops the old folder's links, and
        // resolves it through the new folder's call.
        let buildsBeforeMove = fixture.builtSourceTexts.values.count
        try FileManager.default.moveItem(
            at: rootURL.appendingPathComponent("projects/demo/outputs.tf"),
            to: rootURL.appendingPathComponent("projects/prod/outputs.tf")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: warmLoad.id,
            deltas: [.fileRemoved("projects/demo/outputs.tf"), .fileAdded("projects/prod/outputs.tf")]
        )
        let moved = try await waitForGraph(engine: engine, rootEpoch: warmRun.rootEpoch) {
            $0.contributions["projects/demo/outputs.tf"] == nil && $0.contributions["projects/prod/outputs.tf"] != nil
        }
        XCTAssertEqual(fixture.builtSourceTexts.values.count, buildsBeforeMove)
        XCTAssertEqual(moved.contributions["projects/prod/outputs.tf"], cold.contributions["projects/demo/outputs.tf"])
        XCTAssertEqual(
            moved.targets(of: "projects/prod/outputs.tf"),
            ["modules/worker/outputs.tf", "projects/prod/compute.tf"]
        )
        // An edge left from the removed file would name its file ID here, not a path.
        XCTAssertEqual(moved.referrers(of: "projects/demo/compute.tf"), [])
        XCTAssertEqual(moved.referrers(of: "modules/other/outputs.tf"), ["projects/demo/compute.tf"])
    }

    private static func workerCall(source: String) -> String {
        "module \"worker\" {\n  source     = \"\(source)\"\n  project_id = \"demo\"\n}\n"
    }

    /// Waits until the root's committed graph covers every file and satisfies `condition`.
    private func waitForGraph(
        engine: WorkspaceCodemapBindingEngine,
        rootEpoch: WorkspaceCodemapRootEpoch,
        until condition: (PathKeyedGraph) -> Bool
    ) async throws -> PathKeyedGraph {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            if let pinned = try? await requireReadySnapshot(engine: engine, rootEpoch: rootEpoch),
               pinned.snapshot.coverage.isComplete
            {
                let graph = PathKeyedGraph(pinned.snapshot)
                if condition(graph) { return graph }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GraphWaitError.timedOut
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
        afterCompletedRunCount: UInt64? = nil,
        excluding excludedRootEpoch: WorkspaceCodemapRootEpoch? = nil
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: {
                $0.rootEpoch.rootID == rootID && $0.rootEpoch != excludedRootEpoch
            }),
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

/// A committed graph keyed by path instead of file ID, so graphs from two loads of a root compare.
private struct PathKeyedGraph: Equatable {
    struct Edge: Hashable {
        let source: String
        let target: String
        let matchedNames: [String]
        let candidateCount: UInt64
        let ambiguous: Bool
    }

    struct Unresolved: Hashable {
        let source: String
        let name: String
        let reason: WorkspaceCodemapGraphUnresolvedReason
    }

    let contributions: [String: CodeMapSelectionGraphContribution]
    let edges: Set<Edge>
    let unresolved: Set<Unresolved>

    init(_ snapshot: WorkspaceCodemapGraphCommittedSnapshot) {
        var paths: [UUID: String] = [:]
        var contributions: [String: CodeMapSelectionGraphContribution] = [:]
        for (fileID, node) in snapshot.nodesByFileID {
            paths[fileID] = node.standardizedRelativePath
            contributions[node.standardizedRelativePath] = node.contribution
        }
        let path = { (fileID: UUID) in paths[fileID] ?? fileID.uuidString }
        self.contributions = contributions
        edges = Set(snapshot.outgoingEdgesBySource.values.joined().map {
            Edge(
                source: path($0.sourceFileID),
                target: path($0.targetFileID),
                matchedNames: $0.matchedNames,
                candidateCount: $0.candidateCount,
                ambiguous: $0.ambiguous
            )
        })
        unresolved = Set(snapshot.unresolvedBySource.values.joined().map {
            Unresolved(source: path($0.sourceFileID), name: $0.referencedName, reason: $0.reason)
        })
    }

    /// Every edge as `source -> target`.
    var links: Set<String> {
        Set(edges.map { "\($0.source) -> \($0.target)" })
    }

    func targets(of source: String) -> [String] {
        edges.filter { $0.source == source }.map(\.target).sorted()
    }

    func referrers(of target: String) -> [String] {
        edges.filter { $0.target == target }.map(\.source).sorted()
    }
}
