@testable import RepoPromptApp
import XCTest

final class WorkspaceSearchServiceTests: XCTestCase {
    func testHeldRootLoadEventMakesOldReadyIndexStaleFromStoreGeneration() async throws {
        let rootA = try makeTemporaryRoot(name: "HeldCatalogEventRootA")
        let rootB = try makeTemporaryRoot(name: "HeldCatalogEventRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/SharedRaceTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/SharedRaceTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let eventGate = TestAsyncGate()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await eventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == rootB.path else { return }
            await eventGate.wait()
        }

        let recordB = try await store.loadRoot(path: rootB.path)
        await eventGate.waitUntilEntered()
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)

        let result = await service.search("SharedRaceTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertTrue(result.isStale)
        XCTAssertEqual(result.indexedGeneration, snapshotA.generation)
        XCTAssertEqual(result.snapshotGeneration, snapshotA.generation)
        XCTAssertEqual(result.observedGeneration, currentGeneration)
        XCTAssertEqual(result.results.map(\.rootID), [recordA.id])
        XCTAssertFalse(result.results.contains { $0.rootID == recordB.id })
    }

    func testReleasingRootLoadEventConvergesToReadyNonStaleIndex() async throws {
        let rootA = try makeTemporaryRoot(name: "ReleasedCatalogEventRootA")
        let rootB = try makeTemporaryRoot(name: "ReleasedCatalogEventRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/SharedRaceTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/SharedRaceTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let eventGate = TestAsyncGate()
        let commitSignal = TestAsyncSignal()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await eventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == rootB.path else { return }
            await eventGate.wait()
        }

        let recordB = try await store.loadRoot(path: rootB.path)
        await eventGate.waitUntilEntered()
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == currentGeneration else { return }
            await commitSignal.signal()
        }
        await eventGate.open()
        await commitSignal.wait()

        let result = await service.search("SharedRaceTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.indexedGeneration, currentGeneration)
        XCTAssertEqual(result.snapshotGeneration, currentGeneration)
        XCTAssertNil(result.pendingGeneration)
        XCTAssertEqual(result.observedGeneration, currentGeneration)
        XCTAssertEqual(Set(result.results.map(\.rootID)), [recordA.id, recordB.id])
    }

    func testManagedOnlyMaterializationConvergesFreshnessWithoutBecomingSearchable() async throws {
        let root = try makeTemporaryRoot(name: "ManagedOnlySearchFreshness")
        let visibleURL = root.appendingPathComponent("Sources/VisibleTarget.swift")
        let ignoredURL = root.appendingPathComponent("HiddenIgnoredTarget.ignored")
        let secondIgnoredURL = root.appendingPathComponent("SecondHiddenTarget.ignored")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        try write("visible", to: visibleURL)
        try write("hidden", to: ignoredURL)
        try write("second hidden", to: secondIgnoredURL)

        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        var initialSnapshot: WorkspaceSearchCatalogSnapshot? = await store.searchCatalogSnapshot(
            rootScope: .visibleWorkspace
        )
        let initialGeneration = try XCTUnwrap(initialSnapshot).generation
        XCTAssertFalse(try XCTUnwrap(initialSnapshot).files.contains { $0.standardizedFullPath == ignoredURL.path })
        let initialStoreWork = await store.storeWorkDiagnosticsSnapshot()
        let initialRootShard = try XCTUnwrap(
            initialStoreWork.rootCatalogShards.roots.first { $0.rootID == rootRecord.id }
        )
        let appliedIndexStream = await store.appliedIndexEvents()
        var appliedIndexIterator = appliedIndexStream.makeAsyncIterator()

        let service = WorkspaceSearchService()
        let generationCommitted = expectation(description: "projection-neutral catalog generation committed")
        let neutralEventGate = TestAsyncGate()
        let finalRebuildCommitted = TestAsyncSignal()
        addTeardownBlock {
            await service.setProjectionNeutralGenerationDidCommitHandler(nil)
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await neutralEventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        try await service.rebuildIndex(from: XCTUnwrap(initialSnapshot))
        initialSnapshot = nil
        let initialSearchWork = await service.workDiagnosticsSnapshot()
        await service.setProjectionNeutralGenerationDidCommitHandler { _ in
            generationCommitted.fulfill()
        }

        let materialization = try await store.materializeExplicitlyRequestedFile(
            ignoredURL.path,
            rootScope: .visibleWorkspace
        )
        guard case let .materialized(file) = materialization else {
            return XCTFail("Expected ignored file to materialize as a managed-only record")
        }
        XCTAssertEqual(file.standardizedFullPath, ignoredURL.path)
        let materializedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        XCTAssertNotEqual(materializedGeneration, initialGeneration)

        await fulfillment(of: [generationCommitted], timeout: 2)
        await service.setProjectionNeutralGenerationDidCommitHandler(nil)

        let visibleResult = await service.search("VisibleTarget", limit: 10)
        XCTAssertTrue(visibleResult.isIndexReady)
        XCTAssertFalse(visibleResult.isStale)
        XCTAssertEqual(visibleResult.indexedGeneration, materializedGeneration)
        XCTAssertEqual(visibleResult.snapshotGeneration, materializedGeneration)
        XCTAssertNil(visibleResult.pendingGeneration)
        XCTAssertEqual(visibleResult.observedGeneration, materializedGeneration)
        XCTAssertEqual(visibleResult.results.map(\.standardizedFullPath), [visibleURL.path])

        let ignoredResult = await service.search("HiddenIgnoredTarget", limit: 10)
        XCTAssertTrue(ignoredResult.isIndexReady)
        XCTAssertFalse(ignoredResult.isStale)
        XCTAssertEqual(ignoredResult.indexedGeneration, materializedGeneration)
        XCTAssertTrue(ignoredResult.results.isEmpty)
        let searchDiagnostics = await service.diagnostics
        XCTAssertEqual(searchDiagnostics?.generation, materializedGeneration)

        let finalSearchWork = await service.workDiagnosticsSnapshot()
        XCTAssertEqual(finalSearchWork.rebuildCount, initialSearchWork.rebuildCount)
        let finalStoreWork = await store.storeWorkDiagnosticsSnapshot()
        let finalRootShard = try XCTUnwrap(
            finalStoreWork.rootCatalogShards.roots.first { $0.rootID == rootRecord.id }
        )
        XCTAssertEqual(finalRootShard.buildCount, initialRootShard.buildCount)
        XCTAssertEqual(finalRootShard.authoritativeRebuildCount, initialRootShard.authoritativeRebuildCount)
        XCTAssertEqual(finalRootShard.lastAppliedIndexGeneration, initialRootShard.lastAppliedIndexGeneration)
        XCTAssertEqual(
            finalRootShard.fallbackReasonCounts[.fullResync, default: 0],
            initialRootShard.fallbackReasonCounts[.fullResync, default: 0]
        )

        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .generationAdvancedWithoutProjectionChange else { return }
            await neutralEventGate.wait()
        }
        let secondMaterialization = try await store.materializeExplicitlyRequestedFile(
            secondIgnoredURL.path,
            rootScope: .visibleWorkspace
        )
        guard case .materialized = secondMaterialization else {
            return XCTFail("Expected second ignored file to materialize as a managed-only record")
        }
        await neutralEventGate.waitUntilEntered()

        let sentinelRelativePath = "AppliedIndexSentinel.swift"
        try write("sentinel", to: root.appendingPathComponent(sentinelRelativePath))
        await store.replayObservedFileSystemDeltas(
            rootID: rootRecord.id,
            deltas: [.fileAdded(sentinelRelativePath)]
        )
        let finalGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == finalGeneration else { return }
            await finalRebuildCommitted.signal()
        }

        let firstAppliedIndexValue = await appliedIndexIterator.next()
        let firstAppliedIndexEvent = try XCTUnwrap(firstAppliedIndexValue)
        XCTAssertFalse(firstAppliedIndexEvent.requiresFullResync)
        XCTAssertEqual(
            firstAppliedIndexEvent.upsertedFiles.map(\.standardizedRelativePath),
            [sentinelRelativePath]
        )

        await neutralEventGate.open()
        await finalRebuildCommitted.wait()

        let sentinelResult = await service.search("AppliedIndexSentinel", limit: 10)
        XCTAssertTrue(sentinelResult.isIndexReady)
        XCTAssertFalse(sentinelResult.isStale)
        XCTAssertEqual(sentinelResult.indexedGeneration, finalGeneration)
        XCTAssertEqual(sentinelResult.results.map(\.standardizedRelativePath), [sentinelRelativePath])
        let secondIgnoredResult = await service.search("SecondHiddenTarget", limit: 10)
        XCTAssertTrue(secondIgnoredResult.results.isEmpty)

        let postAppliedStoreWork = await store.storeWorkDiagnosticsSnapshot()
        let postAppliedRootShard = try XCTUnwrap(
            postAppliedStoreWork.rootCatalogShards.roots.first { $0.rootID == rootRecord.id }
        )
        XCTAssertEqual(postAppliedRootShard.buildCount, finalRootShard.buildCount + 1)
        XCTAssertEqual(postAppliedRootShard.patchCount, finalRootShard.patchCount + 1)
        XCTAssertEqual(postAppliedRootShard.authoritativeRebuildCount, finalRootShard.authoritativeRebuildCount)
        XCTAssertEqual(postAppliedRootShard.fallbackCount, finalRootShard.fallbackCount)
        XCTAssertEqual(postAppliedRootShard.fallbackReasonCounts, finalRootShard.fallbackReasonCounts)
        XCTAssertEqual(postAppliedRootShard.lastAppliedIndexGeneration, firstAppliedIndexEvent.generation)
        XCTAssertFalse(postAppliedRootShard.deltaStateDirty)
    }

    func testRemovedRootCannotBeResurrectedByDelayedLoadRefresh() async throws {
        let rootA = try makeTemporaryRoot(name: "DelayedLoadRemovalRootA")
        let rootB = try makeTemporaryRoot(name: "DelayedLoadRemovalRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/SharedRaceTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/SharedRaceTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let eventGate = TestAsyncGate()
        let commitSignal = TestAsyncSignal()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await eventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == rootB.path else { return }
            await eventGate.wait()
        }

        let recordB = try await store.loadRoot(path: rootB.path)
        await eventGate.waitUntilEntered()
        await store.unloadRoot(id: recordB.id)
        let finalGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == finalGeneration else { return }
            await commitSignal.signal()
        }
        await eventGate.open()
        await commitSignal.wait()

        let result = await service.search("SharedRaceTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.indexedGeneration, finalGeneration)
        XCTAssertEqual(result.snapshotGeneration, finalGeneration)
        XCTAssertEqual(result.observedGeneration, finalGeneration)
        XCTAssertEqual(result.results.map(\.rootID), [recordA.id])
        XCTAssertFalse(result.results.contains { $0.rootID == recordB.id })
        let indexedPathCount = await service.indexedPathCount
        XCTAssertEqual(indexedPathCount, 1)
    }

    func testExpiredRootLifetimeCannotCommitAfterSamePathReload() async throws {
        let root = try makeTemporaryRoot(name: "ExpiredLifetimeReloadRoot")
        let oldOnlyFile = root.appendingPathComponent("Sources/OldOnly.swift")
        let refreshTriggerFile = root.appendingPathComponent("Sources/RefreshTrigger.swift")
        try write("old", to: oldOnlyFile)

        let store = WorkspaceFileContextStore()
        let oldRoot = try await store.loadRoot(path: root.path)
        let oldSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let oldFileIDs = Set(oldSnapshot.entries.map(\.id))
        let service = WorkspaceSearchService()
        let triggerEventGate = TestAsyncGate()
        let staleRebuildGate = TestAsyncGate()
        let unloadEventGate = TestAsyncGate()
        let reloadEventGate = TestAsyncGate()
        let commitSignal = TestAsyncSignal()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await service.setAutomaticRebuildDidStartHandler(nil)
            await service.setAutomaticRebuildDidCommitHandler(nil)
            await triggerEventGate.open()
            await staleRebuildGate.open()
            await unloadEventGate.open()
            await reloadEventGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: oldSnapshot)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .appliedIndex, event.rootID == oldRoot.id else { return }
            await triggerEventGate.wait()
        }

        try write("trigger", to: refreshTriggerFile)
        await store.replayObservedFileSystemDeltas(
            rootID: oldRoot.id,
            deltas: [.fileAdded("Sources/RefreshTrigger.swift")]
        )
        await triggerEventGate.waitUntilEntered()
        let staleGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidStartHandler { generation in
            guard generation == staleGeneration else { return }
            await staleRebuildGate.wait()
        }
        await triggerEventGate.open()
        await staleRebuildGate.waitUntilEntered()

        await service.setCatalogChangeWillHandleHandler { event in
            if event.kind == .rootUnloaded, event.rootID == oldRoot.id {
                await unloadEventGate.wait()
            } else if event.kind == .rootLoaded, event.rootPath == root.path {
                await reloadEventGate.wait()
            }
        }
        await store.unloadRoot(id: oldRoot.id)
        await unloadEventGate.waitUntilEntered()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources"))
        try write("new", to: root.appendingPathComponent("Sources/NewOnly.swift"))
        let newRoot = try await store.loadRoot(path: root.path)
        let newGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == newGeneration else { return }
            await commitSignal.signal()
        }

        await staleRebuildGate.open()
        await commitSignal.wait()
        await unloadEventGate.open()
        await reloadEventGate.waitUntilEntered()

        let result = await service.search("Only", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.indexedGeneration, newGeneration)
        XCTAssertEqual(result.snapshotGeneration, newGeneration)
        XCTAssertEqual(result.observedGeneration, newGeneration)
        XCTAssertNotEqual(newRoot.id, oldRoot.id)
        XCTAssertEqual(result.results.map(\.rootID), [newRoot.id])
        XCTAssertEqual(result.results.map(\.standardizedRelativePath), ["Sources/NewOnly.swift"])
        XCTAssertTrue(Set(result.results.map(\.id)).isDisjoint(with: oldFileIDs))
        XCTAssertFalse(result.results.contains { $0.standardizedRelativePath == "Sources/OldOnly.swift" })
    }

    func testVisibleWorkspaceFreshnessIgnoresOutOfScopeRootTopology() async throws {
        let visibleRoot = try makeTemporaryRoot(name: "VisibleScopePrimaryRoot")
        let gitDataRoot = try makeTemporaryRoot(name: "VisibleScopeGitDataRoot")
        let sessionRoot = try makeTemporaryRoot(name: "VisibleScopeSessionRoot")
        let supplementalRoot = try makeTemporaryRoot(name: "VisibleScopeSupplementalRoot")
        let barrierRoot = try makeTemporaryRoot(name: "VisibleScopeBarrierRoot")
        try write("visible", to: visibleRoot.appendingPathComponent("Sources/VisibleScopeTarget.swift"))
        try write("git", to: gitDataRoot.appendingPathComponent("GitScopeTarget.swift"))
        try write("session", to: sessionRoot.appendingPathComponent("SessionScopeTarget.swift"))
        try write("supplemental", to: supplementalRoot.appendingPathComponent("SupplementalScopeTarget.swift"))
        try write("barrier", to: barrierRoot.appendingPathComponent("BarrierScopeTarget.swift"))

        let store = WorkspaceFileContextStore()
        let visibleRecord = try await store.loadRoot(path: visibleRoot.path)
        let visibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        let barrierGate = TestAsyncGate()
        addTeardownBlock {
            await service.setCatalogChangeWillHandleHandler(nil)
            await barrierGate.open()
            await service.stopKeepingFresh()
        }

        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: visibleSnapshot)
        await service.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == barrierRoot.path else { return }
            await barrierGate.wait()
        }

        let gitDataRecord = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let sessionRecord = try await store.loadRoot(path: sessionRoot.path, kind: .sessionWorktree)
        let supplementalRecord = try await store.loadRoot(path: supplementalRoot.path, kind: .supplementalSystem)
        let barrierRecord = try await store.loadRoot(path: barrierRoot.path, kind: .supplementalSystem)
        await barrierGate.waitUntilEntered()

        let visibleGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let result = await service.search("ScopeTarget", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(visibleGeneration, visibleSnapshot.generation)
        XCTAssertEqual(result.indexedGeneration, visibleSnapshot.generation)
        XCTAssertEqual(result.snapshotGeneration, visibleSnapshot.generation)
        XCTAssertNil(result.pendingGeneration)
        XCTAssertEqual(result.observedGeneration, visibleSnapshot.generation)
        XCTAssertEqual(result.results.map(\.rootID), [visibleRecord.id])
        let excludedRootIDs = Set([
            gitDataRecord.id,
            sessionRecord.id,
            supplementalRecord.id,
            barrierRecord.id
        ])
        XCTAssertTrue(Set(result.results.map(\.rootID)).isDisjoint(with: excludedRootIDs))
    }

    func testSearchCatalogChangeEventsFollowCatalogAuthorityChanges() async throws {
        let rootA = try makeTemporaryRoot(name: "CatalogChangeRootA")
        let rootB = try makeTemporaryRoot(name: "CatalogChangeRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/Alpha.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/Beta.swift"))

        let store = WorkspaceFileContextStore()
        let stream = await store.searchCatalogChangeEvents()
        var iterator = stream.makeAsyncIterator()

        let recordA = try await store.loadRoot(path: rootA.path)
        let loadedAValue = await iterator.next()
        let loadedA = try XCTUnwrap(loadedAValue)
        XCTAssertEqual(loadedA.kind, .rootLoaded)
        XCTAssertEqual(loadedA.rootID, recordA.id)
        XCTAssertEqual(loadedA.rootPath, recordA.standardizedFullPath)
        XCTAssertNotNil(loadedA.rootLifetimeID)
        XCTAssertEqual(loadedA.rootAppliedIndexGeneration, 0)

        try write("delta", to: rootA.appendingPathComponent("Sources/Delta.swift"))
        await store.replayObservedFileSystemDeltas(
            rootID: recordA.id,
            deltas: [.fileAdded("Sources/Delta.swift")]
        )
        let appliedValue = await iterator.next()
        let applied = try XCTUnwrap(appliedValue)
        XCTAssertEqual(applied.kind, .appliedIndex)
        XCTAssertEqual(applied.rootID, recordA.id)
        XCTAssertEqual(applied.rootLifetimeID, loadedA.rootLifetimeID)
        XCTAssertEqual(applied.rootAppliedIndexGeneration, 1)

        await store.unloadRoot(id: recordA.id)
        let unloadedAValue = await iterator.next()
        let unloadedA = try XCTUnwrap(unloadedAValue)
        XCTAssertEqual(unloadedA.kind, .rootUnloaded)
        XCTAssertEqual(unloadedA.rootID, recordA.id)
        XCTAssertEqual(unloadedA.rootLifetimeID, loadedA.rootLifetimeID)

        let recordB = try await store.loadRoot(path: rootB.path)
        let loadedBValue = await iterator.next()
        let loadedB = try XCTUnwrap(loadedBValue)
        XCTAssertEqual(loadedB.kind, .rootLoaded)
        XCTAssertEqual(loadedB.rootID, recordB.id)
    }

    func testCanceledRootLoadPublishesNoRootLoadedEvent() async throws {
        let canceledRoot = try makeTemporaryRoot(name: "CanceledCatalogChangeRoot")
        let sentinelRoot = try makeTemporaryRoot(name: "CatalogChangeSentinelRoot")
        try write("canceled", to: canceledRoot.appendingPathComponent("Sources/Canceled.swift"))
        try write("sentinel", to: sentinelRoot.appendingPathComponent("Sources/Sentinel.swift"))

        let store = WorkspaceFileContextStore()
        let stream = await store.searchCatalogChangeEvents()
        var iterator = stream.makeAsyncIterator()
        let loadGate = TestAsyncGate()
        let loadEntered = expectation(description: "root load entered")
        await store.setRootLoadWillStartHandler { _ in
            loadEntered.fulfill()
            await loadGate.wait()
        }

        let loadTask = Task {
            try await store.loadRoot(
                path: canceledRoot.path,
                cancelUnderlyingLoadOnCallerCancellation: true
            )
        }
        await fulfillment(of: [loadEntered], timeout: 2)
        loadTask.cancel()
        await store.cancelRootLoad(path: canceledRoot.path)
        await loadGate.open()
        do {
            _ = try await loadTask.value
            XCTFail("Expected the root load to be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await store.setRootLoadWillStartHandler(nil)

        let sentinel = try await store.loadRoot(path: sentinelRoot.path)
        let firstEventValue = await iterator.next()
        let firstEvent = try XCTUnwrap(firstEventValue)
        XCTAssertEqual(firstEvent.kind, .rootLoaded)
        XCTAssertEqual(firstEvent.rootID, sentinel.id)
    }

    func testStoppedFreshnessBindingMarksOldReadyIndexStaleAtQueryTime() async throws {
        let rootA = try makeTemporaryRoot(name: "StoppedFreshnessRootA")
        let rootB = try makeTemporaryRoot(name: "StoppedFreshnessRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/AlphaTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/BetaTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        await service.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)
        await service.stopKeepingFresh()

        let recordB = try await store.loadRoot(path: rootB.path)
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        XCTAssertNotEqual(currentGeneration, snapshotA.generation)

        let result = await service.search("Target", limit: 10)
        XCTAssertTrue(result.isIndexReady)
        XCTAssertTrue(result.isStale)
        XCTAssertEqual(result.indexedGeneration, snapshotA.generation)
        XCTAssertEqual(result.snapshotGeneration, snapshotA.generation)
        XCTAssertNil(result.pendingGeneration)
        XCTAssertEqual(result.observedGeneration, currentGeneration)
        XCTAssertEqual(result.results.map(\.rootID), [recordA.id])
        XCTAssertFalse(result.results.contains { $0.rootID == recordB.id })

        let zeroLimitResult = await service.search("Target", limit: 0)
        XCTAssertTrue(zeroLimitResult.isIndexReady)
        XCTAssertTrue(zeroLimitResult.isStale)
        XCTAssertEqual(zeroLimitResult.observedGeneration, currentGeneration)
        XCTAssertTrue(zeroLimitResult.results.isEmpty)
    }

    func testManualRebuildReconcilesNewerBoundCatalogDemand() async throws {
        let rootA = try makeTemporaryRoot(name: "ManualRebuildRootA")
        let rootB = try makeTemporaryRoot(name: "ManualRebuildRootB")
        try write("alpha", to: rootA.appendingPathComponent("Sources/Alpha.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/Beta.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let service = WorkspaceSearchService()
        await service.startKeepingFresh(
            with: store,
            rootScope: .visibleWorkspace,
            debounceNanoseconds: 10_000_000_000
        )
        await service.rebuildIndex(from: snapshotA)

        _ = try await store.loadRoot(path: rootB.path)
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        await service.rebuildIndex(from: snapshotA)

        let indexedGeneration = await service.indexedGeneration
        let pendingGeneration = await service.pendingGeneration
        XCTAssertTrue(
            indexedGeneration == currentGeneration || pendingGeneration == currentGeneration,
            "The stale manual snapshot must not erase demand for the authoritative generation"
        )
        await service.stopKeepingFresh()
    }

    func testWorkspaceSearchServiceSearchesSingleRootCatalog() async throws {
        let root = try makeTemporaryRoot(name: "SingleRootSearch")
        try write("view model", to: root.appendingPathComponent("Sources/App/Search/SearchViewModel.swift"))
        try write("tests", to: root.appendingPathComponent("Tests/SearchViewModelTests.swift"))
        try write("readme", to: root.appendingPathComponent("README.md"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        let service = WorkspaceSearchService()
        let indexedGeneration = await service.rebuildIndex(from: snapshot)
        let serviceIndexedGeneration = await service.indexedGeneration
        let indexedPathCount = await service.indexedPathCount
        XCTAssertEqual(indexedGeneration, snapshot.generation)
        XCTAssertEqual(serviceIndexedGeneration, snapshot.generation)
        XCTAssertEqual(indexedPathCount, 3)

        let filenameResult = await service.search("SearchViewModel", limit: 10)
        XCTAssertTrue(filenameResult.isIndexReady)
        XCTAssertEqual(filenameResult.indexedGeneration, snapshot.generation)
        XCTAssertEqual(Set(filenameResult.results.map(\.standardizedRelativePath)), [
            "Sources/App/Search/SearchViewModel.swift",
            "Tests/SearchViewModelTests.swift"
        ])

        let subpathResult = await service.search("App SearchViewModel", limit: 10)
        XCTAssertEqual(subpathResult.results.map(\.standardizedRelativePath), ["Sources/App/Search/SearchViewModel.swift"])
    }

    func testWorkspaceSearchServiceSearchesMultiRootCatalog() async throws {
        let rootA = try makeTemporaryRoot(name: "AlphaRootSearch")
        let rootB = try makeTemporaryRoot(name: "BetaRootSearch")
        try write("alpha", to: rootA.appendingPathComponent("Sources/AlphaTarget.swift"))
        try write("shared alpha", to: rootA.appendingPathComponent("Shared/SharedTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/BetaTarget.swift"))
        try write("shared beta", to: rootB.appendingPathComponent("Shared/SharedTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(snapshot.diagnostics.rootCount, 2)
        XCTAssertEqual(snapshot.diagnostics.fileCount, 4)

        let service = WorkspaceSearchService()
        await service.prepareIndex(from: snapshot)

        let sharedResult = await service.search("SharedTarget", limit: 10)
        XCTAssertEqual(Set(sharedResult.results.map(\.rootID)), [recordA.id, recordB.id])
        XCTAssertEqual(sharedResult.results.count(where: { $0.standardizedRelativePath == "Shared/SharedTarget.swift" }), 2)

        let rootQualifiedResult = await service.search("\(rootB.lastPathComponent) BetaTarget", limit: 10)
        XCTAssertEqual(rootQualifiedResult.results.map(\.rootID), [recordB.id])
        XCTAssertEqual(rootQualifiedResult.results.map(\.standardizedRelativePath), ["Sources/BetaTarget.swift"])
    }

    func testCatalogBatchPatchMatchesAuthoritativeCatalog() async throws {
        // Seeded session-worktree roots publish a projected path index, so every shape runs on both kinds.
        for usesProjectedPathIndex in [false, true] {
            try await assertCatalogBatchShapesMatchAuthoritative(usesProjectedPathIndex: usesProjectedPathIndex)
        }
    }

    private func assertCatalogBatchShapesMatchAuthoritative(usesProjectedPathIndex: Bool) async throws {
        let variant = usesProjectedPathIndex ? "projected path index" : "materialized path index"
        let rootURL = try makeTemporaryRoot(name: "CatalogBatchPatchParity")
        for path in [
            "Sources/Feature/Deep/Existing.swift",
            "Sources/Feature/Deep/Sibling.md",
            "Sources/Replace.swift",
            "Sources/Modified.swift",
            "Docs/Old/Notes.md",
            "Docs/Old/Nested/Deeper.swift",
            "Docs/Gone/Gone.swift",
            "Docs/Keep.md"
        ] {
            try write(path, to: rootURL.appendingPathComponent(path))
        }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        if usesProjectedPathIndex {
            let paths = await store.files(inRoot: root.id).map(\.standardizedRelativePath)
            let snapshot = try await WorkspaceRootSeedTestSupport.snapshot(paths: paths.map { ($0, "100644") })
            let installed = await store.installProjectedPathIndexForTesting(rootID: root.id, snapshot: snapshot)
            XCTAssertTrue(installed, variant)
        }
        await store.setRootCatalogShardPatchCapOverride(64)
        await store.setRootCatalogShardPatchComparisonMode(.on)
        let queries = ["Added", "Inner", "Deeper", "Notes", "Replace", "Mixed", "Keep", "Gone", "*.swift"]

        struct BatchShape {
            let label: String
            let effectiveEditCount: Int
            let noOpCount: Int
            let sharesRecordArrays: Bool
            let apply: () async throws -> Void
        }
        let shapes = [
            // Each added file republishes its three ancestor folders, so nine folder upserts collapse to no-ops.
            BatchShape(
                label: "multi-file add in one nested folder",
                effectiveEditCount: 3,
                noOpCount: 9,
                sharesRecordArrays: false
            ) {
                let paths = [
                    "Sources/Feature/Deep/AddedA.swift",
                    "Sources/Feature/Deep/AddedB.swift",
                    "Sources/Feature/Deep/AddedC.md"
                ]
                for path in paths {
                    try self.write(path, to: rootURL.appendingPathComponent(path))
                }
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: paths.map { .fileAdded($0) })
            },
            BatchShape(label: "files in new nested folders", effectiveEditCount: 4, noOpCount: 6, sharesRecordArrays: false) {
                let paths = ["Sources/NewArea/Inner/One.swift", "Sources/NewArea/Inner/Two.swift"]
                for path in paths {
                    try self.write(path, to: rootURL.appendingPathComponent(path))
                }
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: paths.map { .fileAdded($0) })
            },
            BatchShape(label: "folder removal with descendants", effectiveEditCount: 4, noOpCount: 0, sharesRecordArrays: false) {
                try FileManager.default.removeItem(at: rootURL.appendingPathComponent("Docs/Old"))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.folderRemoved("Docs/Old")])
            },
            // The store never rewrites a record under its ID, so modifications match the shard's records.
            BatchShape(label: "modifications", effectiveEditCount: 0, noOpCount: 3, sharesRecordArrays: true) {
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [
                    .fileModified("Sources/Modified.swift", nil),
                    .fileModified("Sources/Feature/Deep/Existing.swift", nil),
                    .folderModified("Sources/Feature/Deep", nil)
                ])
            },
            BatchShape(label: "republished add", effectiveEditCount: 0, noOpCount: 2, sharesRecordArrays: true) {
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Sources/Modified.swift")])
            },
            // The store never reuses a path's ID after a removal, so the shard is held through the
            // removal and the re-add, and then receives the re-add alone.
            BatchShape(label: "same-path replacement", effectiveEditCount: 2, noOpCount: 1, sharesRecordArrays: false) {
                let url = rootURL.appendingPathComponent("Sources/Replace.swift")
                await store.holdRootCatalogShardBatchesForTesting(rootID: root.id)
                try FileManager.default.removeItem(at: url)
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileRemoved("Sources/Replace.swift")])
                try self.write("replaced", to: url)
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded("Sources/Replace.swift")])
                let held = await store.takeHeldRootCatalogShardBatchesForTesting(rootID: root.id)
                XCTAssertEqual(held.count, 2)
                let readd = try XCTUnwrap(held.last)
                let staged = await store.applyAppliedIndexEventToStagedRootCatalogShardForTesting(readd)
                XCTAssertTrue(staged)
            },
            BatchShape(label: "mixed", effectiveEditCount: 4, noOpCount: 4, sharesRecordArrays: false) {
                try self.write("mixed", to: rootURL.appendingPathComponent("Sources/Feature/Deep/Mixed.swift"))
                try FileManager.default.removeItem(at: rootURL.appendingPathComponent("Docs/Keep.md"))
                try FileManager.default.removeItem(at: rootURL.appendingPathComponent("Docs/Gone"))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [
                    .fileAdded("Sources/Feature/Deep/Mixed.swift"),
                    .fileRemoved("Docs/Keep.md"),
                    .folderRemoved("Docs/Gone"),
                    .fileModified("Sources/Modified.swift", nil)
                ])
            }
        ]

        for shape in shapes {
            let label = "\(variant): \(shape.label)"
            let before = try await catalogShardDebugRoot(store, rootID: root.id)
            let previousContents = await store.rootCatalogShardContentsForTesting(rootID: root.id)
            try await shape.apply()

            let after = try await catalogShardDebugRoot(store, rootID: root.id)
            XCTAssertEqual(after.batches.totalObservedSampleCount, before.batches.totalObservedSampleCount + 1, label)
            let sample = try XCTUnwrap(after.batches.samples.last, label)
            XCTAssertEqual(sample.outcome, .patched, label)
            XCTAssertNil(sample.fallbackReason, label)
            XCTAssertEqual(sample.effectiveEditCount, shape.effectiveEditCount, label)
            XCTAssertEqual(sample.noOpCount, shape.noOpCount, label)
            XCTAssertEqual(sample.comparison?.parityMatched, true, label)
            XCTAssertEqual(after.patchCount, before.patchCount + 1, label)
            XCTAssertEqual(after.authoritativeRebuildCount, before.authoritativeRebuildCount, label)
            XCTAssertEqual(after.fallbackCount, before.fallbackCount, label)
            // A full path-index build would mean the patch fell back to rebuilding the index.
            XCTAssertEqual(after.pathIndexBuildCount, before.pathIndexBuildCount, label)
            XCTAssertEqual(after.lastAppliedIndexGeneration, sample.appliedIndexGeneration, label)

            let published = await store.rootCatalogShardContentsForTesting(rootID: root.id, pathQueries: queries)
            let authoritative = await store.authoritativeRootCatalogShardContentsForTesting(
                rootID: root.id,
                pathQueries: queries
            )
            XCTAssertNotNil(published?.pathMatches, label)
            XCTAssertEqual(published?.projectionIndexResolvesEveryFile, true, label)
            XCTAssertEqual(published, authoritative, label)
            if shape.sharesRecordArrays {
                let previous = try XCTUnwrap(previousContents, label)
                let current = try XCTUnwrap(published, label)
                XCTAssertEqual(sample.mergeCopiedElementCount, 0, label)
                XCTAssertTrue(Self.sharesStorage(previous.files, current.files), label)
                XCTAssertTrue(Self.sharesStorage(previous.entries, current.entries), label)
                XCTAssertTrue(Self.sharesStorage(previous.folders, current.folders), label)
            }
        }
    }

    func testInvalidCatalogBatchFallsBackWithoutPartialPublication() async throws {
        let rootURL = try makeTemporaryRoot(name: "CatalogBatchPatchFallback")
        for path in ["Sources/Alpha.swift", "Sources/Beta.swift", "Docs/Guide.md"] {
            try write(path, to: rootURL.appendingPathComponent(path))
        }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await store.setRootCatalogShardPatchCapOverride(64)
        let files = await store.files(inRoot: root.id)
        let alpha = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Alpha.swift" })
        let beta = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Beta.swift" })
        // The store holds one record per ID and never moves an ID to another path, so this record,
        // alpha's ID at another path, isn't the store's.
        let alphaElsewhere = WorkspaceFileRecord(
            id: alpha.id,
            rootID: root.id,
            name: alpha.name,
            relativePath: "Sources/Moved/Alpha.swift",
            fullPath: rootURL.appendingPathComponent("Sources/Moved/Alpha.swift").path,
            parentFolderID: alpha.parentFolderID
        )

        struct InvalidBatch {
            let label: String
            let reason: WorkspaceFileContextStore.RootCatalogShardFallbackReason
            let stagedRoot: WorkspaceRootRecord?
            let event: (UInt64) -> WorkspaceAppliedIndexBatchEvent
        }
        let batches = [
            // Conflicting records under one ID, and an ID the shard holds at another path, both stop at
            // the guard that every upsert is the store's current record.
            InvalidBatch(
                label: "same-ID upserts, one of them at another path",
                reason: .patchApplicationBackstop,
                stagedRoot: nil
            ) {
                WorkspaceAppliedIndexBatchEvent(
                    rootID: root.id,
                    rootPath: root.standardizedFullPath,
                    generation: $0,
                    upsertedFiles: [alpha, alphaElsewhere]
                )
            },
            InvalidBatch(label: "a removed ID without its path", reason: .patchApplicationBackstop, stagedRoot: nil) {
                WorkspaceAppliedIndexBatchEvent(
                    rootID: root.id,
                    rootPath: root.standardizedFullPath,
                    generation: $0,
                    removedFileIDs: [beta.id]
                )
            },
            InvalidBatch(
                label: "a changed root record",
                reason: .unsafeOrAmbiguousBatch,
                stagedRoot: WorkspaceRootRecord(id: root.id, name: "RenamedRoot", fullPath: root.fullPath, kind: root.kind)
            ) {
                WorkspaceAppliedIndexBatchEvent(
                    rootID: root.id,
                    rootPath: root.standardizedFullPath,
                    generation: $0,
                    upsertedFiles: [alpha]
                )
            }
        ]

        for batch in batches {
            let before = try await catalogShardDebugRoot(store, rootID: root.id)
            let generation = try XCTUnwrap(before.lastAppliedIndexGeneration, batch.label) + 1
            let staged = await store.applyAppliedIndexEventToStagedRootCatalogShardForTesting(
                batch.event(generation),
                stagedRoot: batch.stagedRoot
            )
            XCTAssertTrue(staged, batch.label)

            let after = try await catalogShardDebugRoot(store, rootID: root.id)
            XCTAssertEqual(
                after.fallbackReasonCounts[batch.reason, default: 0],
                before.fallbackReasonCounts[batch.reason, default: 0] + 1,
                batch.label
            )
            XCTAssertEqual(after.patchCount, before.patchCount, batch.label)
            XCTAssertEqual(after.authoritativeRebuildCount, before.authoritativeRebuildCount + 1, batch.label)
            XCTAssertEqual(after.lastAppliedIndexGeneration, generation, batch.label)
            let sample = try XCTUnwrap(after.batches.samples.last, batch.label)
            XCTAssertEqual(sample.outcome, .rebuilt, batch.label)
            XCTAssertEqual(sample.fallbackReason, batch.reason, batch.label)

            let published = await store.rootCatalogShardContentsForTesting(rootID: root.id, pathQueries: ["Alpha", "Beta"])
            let authoritative = await store.authoritativeRootCatalogShardContentsForTesting(
                rootID: root.id,
                pathQueries: ["Alpha", "Beta"]
            )
            XCTAssertNotNil(published, batch.label)
            XCTAssertEqual(published, authoritative, batch.label)
        }
    }

    func testPathIndexRebaseKeepsNewerOverlaysAndDiscardsStaleResult() async throws {
        let rootURL = try makeTemporaryRoot(name: "PathIndexRebaseStale")
        // Files are added to an existing folder, so each add is a single-edit patch and one overlay payload.
        try write("seed", to: rootURL.appendingPathComponent("Added/Seed.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        await store.setRootCatalogShardPatchCapOverride(1)
        var addedFileCount = 0
        func addFiles(_ count: Int) async throws {
            for _ in 0 ..< count {
                addedFileCount += 1
                let path = "Added/File\(addedFileCount).swift"
                try write("added", to: rootURL.appendingPathComponent(path))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(path)])
            }
        }
        let queries = ["File", "Seed", "*.swift"]
        func assertPublishedMatchesAuthoritative(_ label: String) async {
            let published = await store.rootCatalogShardContentsForTesting(rootID: root.id, pathQueries: queries)
            let authoritative = await store.authoritativeRootCatalogShardContentsForTesting(
                rootID: root.id,
                pathQueries: queries
            )
            XCTAssertNotNil(published?.pathMatches, label)
            XCTAssertEqual(published, authoritative, label)
        }
        let threshold = WorkspaceFileContextStore.pathIndexRebaseOverlayPayloadThreshold

        // (a) Two patches land while the base builds. The install keeps them as its only overlays.
        let firstBuild = TestAsyncGate()
        addTeardownBlock { await firstBuild.open() }
        await store.setPathIndexRebaseBuildHandlerForTesting { _ in await firstBuild.wait() }
        let fullIndexBuildCount = try await catalogShardDebugRoot(store, rootID: root.id).pathIndexBuildCount
        try await addFiles(threshold)
        let firstFlightTask = await store.pathIndexRebaseFlightTaskForTesting(rootID: root.id)
        let firstFlight = try XCTUnwrap(firstFlightTask)
        await firstBuild.waitUntilEntered()
        try await addFiles(2)
        // A snapshot cached while the base builds holds the pre-rebase index.
        let cachedDuringBuild = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(cachedDuringBuild.rootPathIndexes.map(\.overlayPayloadCount), [threshold + 2])
        await firstBuild.open()
        await firstFlight.value
        // The install drops that snapshot without a catalog change, so the next one has the rebased index.
        let afterInstall = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(afterInstall.rootPathIndexes.map(\.overlayPayloadCount), [2])

        var debugRoot = try await catalogShardDebugRoot(store, rootID: root.id)
        XCTAssertEqual(debugRoot.pathIndexRebase.startCount, 1)
        XCTAssertEqual(debugRoot.pathIndexRebase.installCount, 1)
        XCTAssertEqual(debugRoot.pathIndexRebase.discardCounts, [:])
        XCTAssertEqual(debugRoot.pathIndexRebase.overlayPayloadCount, 2)
        XCTAssertEqual(debugRoot.pathIndexRebase.maxOverlayPayloadCount, threshold + 2)
        // The rebased base was built off the actor, so it isn't counted as a full path-index build.
        XCTAssertEqual(debugRoot.pathIndexBuildCount, fullIndexBuildCount)
        await assertPublishedMatchesAuthoritative("installed rebase")

        // (b) A rebuild while the base builds replaces the captured base, so the result is discarded.
        let secondBuild = TestAsyncGate()
        addTeardownBlock { await secondBuild.open() }
        await store.setPathIndexRebaseBuildHandlerForTesting { _ in await secondBuild.wait() }
        try await addFiles(threshold - 2)
        let secondFlightTask = await store.pathIndexRebaseFlightTaskForTesting(rootID: root.id)
        let secondFlight = try XCTUnwrap(secondFlightTask)
        await secondBuild.waitUntilEntered()
        // A cap of zero admits no edits, so the next add rebuilds the shard from the store's records.
        await store.setRootCatalogShardPatchCapOverride(0)
        try await addFiles(1)
        let rebuildCount = try await catalogShardDebugRoot(store, rootID: root.id).authoritativeRebuildCount
        XCTAssertEqual(rebuildCount, debugRoot.authoritativeRebuildCount + 1)
        // The rebuilt index gathers as many overlays as the capture had, so only its base tells them apart.
        await store.setRootCatalogShardPatchCapOverride(1)
        try await addFiles(threshold)
        await secondBuild.open()
        await secondFlight.value

        debugRoot = try await catalogShardDebugRoot(store, rootID: root.id)
        XCTAssertEqual(debugRoot.pathIndexRebase.startCount, 2)
        XCTAssertEqual(debugRoot.pathIndexRebase.installCount, 1)
        XCTAssertEqual(debugRoot.pathIndexRebase.discardCounts, [.stale: 1])
        XCTAssertEqual(debugRoot.pathIndexRebase.overlayPayloadCount, threshold)
        await assertPublishedMatchesAuthoritative("discarded rebase")
    }

    func testFolderRemovalVisitsOnlyItsSubtree() async throws {
        let rootURL = try makeTemporaryRoot(name: "FolderRemovalSubtree")
        let removedFiles = ["Removed/Top.swift", "Removed/Nested/Inner.swift", "Removed/Nested/Notes.md"]
        // A sibling whose name extends the removed folder's, and an unrelated subtree many times larger.
        let unrelatedFolders = (0 ..< 8).map { "Unrelated/Group\($0)" }
        let keptFiles = ["Kept.swift", "RemovedSibling/Keep.swift"]
            + unrelatedFolders.flatMap { folder in (0 ..< 25).map { "\(folder)/File\($0).swift" } }
        for path in removedFiles + keptFiles {
            try write(path, to: rootURL.appendingPathComponent(path))
        }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let before = try await catalogShardDebugRoot(store, rootID: root.id).folderSubtreeTraversals

        try FileManager.default.removeItem(at: rootURL.appendingPathComponent("Removed"))
        await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.folderRemoved("Removed")])

        let files = await store.files(inRoot: root.id).map(\.standardizedRelativePath)
        XCTAssertEqual(files, keptFiles.sorted())
        let folders = await store.folders(inRoot: root.id).map(\.standardizedRelativePath)
        XCTAssertEqual(folders, (["", "RemovedSibling", "Unrelated"] + unrelatedFolders).sorted())
        // The removal and its CodeMap invalidation each visit the three files and two folders removed.
        let after = try await catalogShardDebugRoot(store, rootID: root.id).folderSubtreeTraversals
        XCTAssertEqual(after.folderRemovalCount - before.folderRemovalCount, 1)
        XCTAssertEqual(after.folderRemovalVisitedRecordCount - before.folderRemovalVisitedRecordCount, 5)
        XCTAssertEqual(after.codemapInvalidationCount - before.codemapInvalidationCount, 1)
        XCTAssertEqual(after.codemapInvalidationVisitedRecordCount - before.codemapInvalidationVisitedRecordCount, 5)
    }

    private func catalogShardDebugRoot(
        _ store: WorkspaceFileContextStore,
        rootID: UUID
    ) async throws -> WorkspaceFileContextStore.RootCatalogShardGenerationDebugSnapshot {
        let work = await store.storeWorkDiagnosticsSnapshot()
        return try XCTUnwrap(work.rootCatalogShards.roots.first { $0.rootID == rootID })
    }

    private static func sharesStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        lhs.withUnsafeBufferPointer { lhsBuffer in
            rhs.withUnsafeBufferPointer { rhsBuffer in lhsBuffer.baseAddress == rhsBuffer.baseAddress }
        }
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try makeTestDirectory(name: name)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor TestAsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            if isSignaled {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }
}

private actor TestAsyncGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isOpen = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                openContinuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }
}
