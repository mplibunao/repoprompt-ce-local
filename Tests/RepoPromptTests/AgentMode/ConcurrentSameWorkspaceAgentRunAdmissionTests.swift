import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class ConcurrentSameWorkspaceAgentRunAdmissionTests: XCTestCase {
        private lazy var cleanup = AdmissionTestCleanup()
        private var holdsSuiteGate = false

        override func setUp() async throws {
            try await super.setUp()
            try await AdmissionTestSuiteGate.shared.acquire()
            holdsSuiteGate = true
        }

        override func tearDown() async throws {
            var cleanupError: (any Error)?
            do {
                try await cleanup.run("per-test cleanup")
            } catch is StartupTestStepTimeout {
                // Already recorded, naming the cleanup step and the state it left behind.
            } catch {
                cleanupError = error
            }
            // XCTest keeps every test case alive until the run ends, so let go of the registry and the
            // closed windows and runtimes it remembers; a timed-out step that still holds it keeps it.
            cleanup = AdmissionTestCleanup()
            // Release the suite gate however cleanup ended, so one failed teardown can't stall later tests.
            if holdsSuiteGate {
                holdsSuiteGate = false
                await AdmissionTestSuiteGate.shared.release()
            }
            try await super.tearDown()
            if let cleanupError {
                throw cleanupError
            }
        }

        /// After the released persistence path is seen to finish, activation would follow within
        /// milliseconds if its readiness join were missing; this window leaves headroom for a loaded
        /// machine without making the suite slow.
        private static let prematureActivationWindowSeconds: TimeInterval = 1

        private enum DefaultPersistencePath: String {
            case manager
            case bridge
        }

        /// The initial Default activation joins both Default persistence owners. Each subcase releases
        /// one owner, waits for that owner's own sign of completion, and requires the activation to
        /// stay absent while the other is held, so removing either join fails one subcase.
        func testInitialDefaultPersistenceCompletesBeforeActivation() async throws {
            try await assertActivationWaitsForHeldDefaultPersistence(releasing: .manager, holding: .bridge)
            try await assertActivationWaitsForHeldDefaultPersistence(releasing: .bridge, holding: .manager)
        }

        private func assertActivationWaitsForHeldDefaultPersistence(
            releasing released: DefaultPersistencePath,
            holding held: DefaultPersistencePath
        ) async throws {
            let subcase = "\(released.rawValue) released, \(held.rawValue) held"
            let runtime = try makeIsolatedRuntime(
                container: makeTemporaryDirectory(named: "DefaultPersistenceOrdering"),
                profileIdentifier: "default-persistence-ordering",
                cleanup: cleanup
            ).runtime
            try await cleanup.step("starting the runtime (\(subcase))") {
                try await runtime.start()
            }

            let window = makeAdmissionWindow(runtime: runtime, cleanup: cleanup)
            let managerPersistenceGate = makeSaveGate("manager Default persistence gate (\(subcase))")
            let bridgePersistenceGate = makeSaveGate("bridge Default persistence gate (\(subcase))")
            window.workspaceManager.setDefaultWorkspaceCreationWillBeginHandlerForTesting { _ in
                await managerPersistenceGate.enterFirstAndWait()
            }
            window.setDomainWorkspaceDefaultCreationWillBeginHandlerForTesting { _ in
                await bridgePersistenceGate.enterFirstAndWait()
            }
            cleanup.onRelease {
                window.workspaceManager.setDefaultWorkspaceCreationWillBeginHandlerForTesting(nil)
                window.setDomainWorkspaceDefaultCreationWillBeginHandlerForTesting(nil)
            }
            let gates: [DefaultPersistencePath: AdmissionSaveGate] = [
                .manager: managerPersistenceGate,
                .bridge: bridgePersistenceGate
            ]

            try await waitUntil("both Default persistence paths to reach their gates (\(subcase))") {
                let managerEntered = await managerPersistenceGate.hasEntered()
                let bridgeEntered = await bridgePersistenceGate.hasEntered()
                return managerEntered && bridgeEntered
            }
            let systemWorkspace = try XCTUnwrap(
                window.workspaceManager.workspaces.first(where: \.isSystemWorkspace),
                subcase
            )
            XCTAssertNil(window.workspaceManager.activeWorkspace, subcase)
            let canonicalBeforeActivation = await runtime.workspaceStore.canonicalWorkspaceSnapshot(systemWorkspace.id)
            XCTAssertNil(canonicalBeforeActivation, subcase)

            await gates[released]?.open()
            switch released {
            case .manager:
                try await waitUntil("manager Default persistence to become canonical (\(subcase))") {
                    await runtime.workspaceStore.canonicalWorkspaceSnapshot(systemWorkspace.id) != nil
                }
            case .bridge:
                try await cleanup.step("the bridge's initial Default projection (\(subcase))") {
                    await window.awaitInitialDomainWorkspaceProjectionForTesting()
                }
            }
            // Only the initial activation switch, which completes initialization, joins both owners.
            // Once the bridge has projected, its projection adopts the canonical Default as the active
            // workspace without that switch, so the active workspace counts as a sign of activation
            // only while the bridge is held.
            let activatedEarly = await startupTestWaitBounded(
                seconds: Self.prematureActivationWindowSeconds
            ) {
                window.workspaceManager.isInitialized
                    || (held == .bridge && window.workspaceManager.activeWorkspace != nil)
            }
            XCTAssertFalse(
                activatedEarly,
                "Default's initial activation ran while \(held.rawValue) persistence was still held (\(subcase)): "
                    + "isInitialized=\(window.workspaceManager.isInitialized), "
                    + "activeWorkspace=\(window.workspaceManager.activeWorkspace?.name ?? "nil")"
            )

            await gates[held]?.open()
            try await cleanup.step("workspace manager initialization (\(subcase))") {
                await window.workspaceManager.awaitInitialized()
            }

            XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, systemWorkspace.id, subcase)
            let canonicalAfterActivation = await runtime.workspaceStore.canonicalWorkspaceSnapshot(systemWorkspace.id)
            let canonical = try XCTUnwrap(canonicalAfterActivation, subcase)
            XCTAssertEqual(canonical.health, .writable, subcase)
            try await cleanup.run("cleanup after the \(subcase) subcase")
        }

        func testSixOverlappingAgentRunStartsPersistUniqueIdentitiesAndDispatchProvidersExactlyOnce() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let initialTabIDs = Set(initialTabs.map(\.id))
            let initialActiveTabID = initialWorkspace.activeComposeTabID
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let coordinatorBaseline = coordinator.snapshot()
            let saveGate = makeSaveGate("first durable admission save gate")
            let providerRecorder = AdmissionProviderRecorder(expectedCount: 6)
            cleanup.onRelease { await providerRecorder.releaseAll() }
            fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                savedWorkspaceID,
                _,
                _ in
                guard savedWorkspaceID == workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await saveGate.enterFirstAndWait()
            }
            defer {
                fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }

            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder,
                validateBeforeProviderDispatch: { pair in
                    let canonicalSnapshot = await fixture.runtime.workspaceStore
                        .canonicalWorkspaceSnapshot(workspaceID)
                    let canonical = try XCTUnwrap(canonicalSnapshot)
                    let canonicalWorkspace = try JSONDecoder().decode(
                        WorkspaceModel.self,
                        from: canonical.document.documentBytes
                    )
                    guard canonicalWorkspace.composeTabs.containsIdentity(pair) else {
                        throw AdmissionTestError.fixtureSetup(
                            "provider reached dispatch before canonical identity \(pair)"
                        )
                    }
                    let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                        at: fixture.workspaceFileURL,
                        scheduleNormalizationWriteback: false
                    )
                    guard savedWorkspace.composeTabs.containsIdentity(pair) else {
                        throw AdmissionTestError.fixtureSetup(
                            "provider reached dispatch before disk identity \(pair)"
                        )
                    }
                }
            )
            let tasks = (0 ..< 6).map { index in
                Task { @MainActor in
                    try await service.execute(args: [
                        "op": .string("start"),
                        "message": .string("overlapping durable admission \(index)"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                }
            }
            tasks.forEach { cleanup.onCancelAndJoin($0) }

            do {
                try await waitUntil("first durable admission save to reach the gate") {
                    await saveGate.hasEntered()
                }
                do {
                    try await waitUntil("five same-workspace starts to queue") {
                        coordinator.snapshot().activeAdmissionCount == coordinatorBaseline.activeAdmissionCount + 1
                            && coordinator.waiterCount(for: workspaceID) == 5
                    }
                } catch {
                    throw AdmissionTestError.fixtureSetup(
                        "coordinator did not reach six-way overlap: baseline=\(coordinatorBaseline) current=\(coordinator.snapshot()) workspaceWaiters=\(coordinator.waiterCount(for: workspaceID))"
                    )
                }
                let heldWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                XCTAssertEqual(
                    Set(heldWorkspace.composeTabs.map(\.id)).subtracting(initialTabIDs).count,
                    1,
                    "Queued siblings must not append provisional tabs before acquiring the workspace admission."
                )
                let providerCountWhileSaveBlocked = await providerRecorder.count()
                XCTAssertEqual(
                    providerCountWhileSaveBlocked,
                    0,
                    "No provider may start before the first durable save gate opens."
                )

                await saveGate.open()
                try await waitUntil("all six providers to overlap") {
                    await providerRecorder.count() == 6
                }

                let observations = await providerRecorder.observations()
                let acceptedPairs = observations.map { AdmissionIdentityPair(tabID: $0.tabID, sessionID: $0.sessionID) }
                XCTAssertEqual(observations.count, 6)
                XCTAssertEqual(Set(acceptedPairs).count, 6)
                XCTAssertEqual(Set(observations.compactMap(\.lifecycleIdentity)).count, 6)
                XCTAssertTrue(observations.allSatisfy { $0.lifecycleIdentity?.workspaceID == workspaceID })

                let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                XCTAssertEqual(projectedWorkspace.activeComposeTabID, initialActiveTabID)
                assertExactAdmissionState(
                    in: projectedWorkspace.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )
                assertExactAdmissionState(
                    in: fixture.window.promptManager.currentComposeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )
                for observation in observations {
                    let live = try XCTUnwrap(
                        try fixture.window.agentModeViewModel.authoritativeLiveSession(for: observation.sessionID)
                    )
                    XCTAssertEqual(live.tabID, observation.tabID)
                    XCTAssertEqual(live.activeAgentSessionID, observation.sessionID)
                }

                let canonicalSnapshot = await fixture.runtime.workspaceStore
                    .canonicalWorkspaceSnapshot(workspaceID)
                let canonical = try XCTUnwrap(canonicalSnapshot)
                XCTAssertEqual(canonical.health, .writable)
                let canonicalWorkspace = try JSONDecoder().decode(
                    WorkspaceModel.self,
                    from: canonical.document.documentBytes
                )
                assertExactAdmissionState(
                    in: canonicalWorkspace.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )
                let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                    at: fixture.workspaceFileURL,
                    scheduleNormalizationWriteback: false
                )
                assertExactAdmissionState(
                    in: savedWorkspace.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )

                await providerRecorder.releaseAll()
                let values = try await startupTestTaskResults(tasks, "the six overlapping starts")
                let responsePairs = try values.map { value -> AdmissionIdentityPair in
                    let object = try XCTUnwrap(value.objectValue)
                    let session = try XCTUnwrap(object["session"]?.objectValue)
                    return try AdmissionIdentityPair(
                        tabID: XCTUnwrap(session["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))),
                        sessionID: XCTUnwrap(object["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
                    )
                }
                XCTAssertEqual(Set(responsePairs), Set(acceptedPairs))
                let providerAttemptCounts = await providerRecorder.attemptCounts()
                XCTAssertEqual(providerAttemptCounts, Dictionary(
                    uniqueKeysWithValues: acceptedPairs.map { ($0, 1) }
                ))

                try await fixture.closeWindowAndRuntime()
                try await fixture.withFreshRuntime(generation: 2) { restarted in
                    let restartedCatalog = await restarted.workspaceStore.snapshot()
                    let restartedSnapshot = await restarted.workspaceStore
                        .canonicalWorkspaceSnapshot(workspaceID)
                    let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                    XCTAssertEqual(restartedCatalog.health, .writable)
                    XCTAssertEqual(restartedWorkspace.health, .writable)
                    let restartedModel = try JSONDecoder().decode(
                        WorkspaceModel.self,
                        from: restartedWorkspace.document.documentBytes
                    )
                    assertExactAdmissionState(
                        in: restartedModel.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: acceptedPairs
                    )
                }
                XCTAssertEqual(coordinator.snapshot(), coordinatorBaseline)
            } catch {
                await saveGate.open()
                await providerRecorder.releaseAll()
                let taskErrors = await cancelAndCollectErrors(tasks)
                throw AdmissionTestError.fixtureSetup(
                    "\(error); taskErrors=\(taskErrors)"
                )
            }
        }

        func testSecondWindowRefreshesCanonicalAdmissionBeforePersistingItsOwnTarget() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let peer = try await fixture.makePeerWindow()
            let stalePeerWorkspace = try XCTUnwrap(
                peer.workspaceManager.workspace(withID: fixture.workspaceID)
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let coordinatorBaseline = coordinator.snapshot()
            let saveGate = makeSaveGate("first window admission save gate")
            fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                guard workspaceID == fixture.workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await saveGate.enterFirstAndWait()
            }
            defer {
                fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil)
            }
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let firstService = makeAgentRunStartService(
                window: fixture.window,
                recorder: firstRecorder
            )
            let secondRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let secondService = makeAgentRunStartService(window: peer, recorder: secondRecorder)
            var peerRefreshObserved = false
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                peerRefreshObserved = true
                XCTAssertEqual(
                    coordinator.snapshot().activeAdmissionCount,
                    coordinatorBaseline.activeAdmissionCount + 1,
                    "The peer refresh must run while its admission lease is active."
                )
                XCTAssertEqual(
                    coordinator.waiterCount(for: workspaceID),
                    0,
                    "The peer must leave the queue before reading canonical state."
                )
                return await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            }
            let firstTask = Task { @MainActor in
                try await firstService.execute(args: [
                    "op": .string("start"),
                    "message": .string("first window canonical admission"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(firstTask)
            var secondTask: Task<Value, Error>?
            do {
                try await waitUntil("first window admission to hold the workspace lease") {
                    await saveGate.hasEntered()
                }
                XCTAssertFalse(peerRefreshObserved)
                peer.promptManager.loadComposeTabsFromWorkspace(stalePeerWorkspace)

                let queuedTask = Task { @MainActor in
                    try await secondService.execute(args: [
                        "op": .string("start"),
                        "message": .string("second window canonical admission"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                }
                secondTask = queuedTask
                cleanup.onCancelAndJoin(queuedTask)
                try await waitUntil("peer admission to queue behind the first window") {
                    coordinator.waiterCount(for: fixture.workspaceID) == 1
                }
                XCTAssertFalse(peerRefreshObserved)
                let peerProviderCountWhileQueued = await secondRecorder.count()
                XCTAssertEqual(peerProviderCountWhileQueued, 0)

                await saveGate.open()
                _ = try await startupTestTaskResults([firstTask, queuedTask], "both windows' starts")
            } catch {
                await saveGate.open()
                let taskErrors = await cancelAndCollectErrors([firstTask] + [secondTask].compactMap(\.self))
                throw AdmissionTestError.fixtureSetup("\(error); taskErrors=\(taskErrors)")
            }

            XCTAssertTrue(peerRefreshObserved)
            let firstObservations = await firstRecorder.observations()
            let firstObservation = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(
                tabID: firstObservation.tabID,
                sessionID: firstObservation.sessionID
            )
            let secondObservations = await secondRecorder.observations()
            let secondObservation = try XCTUnwrap(secondObservations.first)
            let secondPair = AdmissionIdentityPair(
                tabID: secondObservation.tabID,
                sessionID: secondObservation.sessionID
            )

            let firstAttemptCounts = await firstRecorder.attemptCounts()
            let secondAttemptCounts = await secondRecorder.attemptCounts()
            XCTAssertEqual(firstAttemptCounts[firstPair], 1)
            XCTAssertEqual(secondAttemptCounts[secondPair], 1)
            let canonicalSnapshotValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalSnapshot = try XCTUnwrap(canonicalSnapshotValue)
            let canonical = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalSnapshot.document.documentBytes
            )
            XCTAssertTrue(canonical.composeTabs.containsIdentity(firstPair))
            XCTAssertTrue(canonical.composeTabs.containsIdentity(secondPair))
            XCTAssertEqual(Set([firstPair, secondPair]).count, 2)
        }

        func testCanonicalAdmissionRefreshReResolvesWorkspaceAfterReorder() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let peer = try await fixture.makePeerWindow()
            let staleWorkspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: fixture.window, recorder: firstRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("canonical identity before peer reorder"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])
            let firstObservations = await firstRecorder.observations()
            let first = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(tabID: first.tabID, sessionID: first.sessionID)
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex { $0.id == fixture.workspaceID })
            peer.workspaceManager.workspaces[peerIndex] = staleWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(staleWorkspace)

            let gate = makeHandoffGate("peer canonical-refresh gate")
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let secondRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: peer, recorder: secondRecorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("peer admission after reorder"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(task)
            try await waitUntil("the peer's start", enters: gate, producer: task)
            let target = peer.workspaceManager.workspaces.remove(at: peerIndex)
            peer.workspaceManager.workspaces.append(target)
            let unrelatedBefore = Array(peer.workspaceManager.workspaces.dropLast())
            await gate.open()
            _ = try await startupTestTaskResult(task, "the peer's start after reorder")

            XCTAssertEqual(Array(peer.workspaceManager.workspaces.dropLast()), unrelatedBefore)
            let refreshed = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            XCTAssertTrue(refreshed.composeTabs.containsIdentity(firstPair))
            let secondProviderCount = await secondRecorder.count()
            XCTAssertEqual(secondProviderCount, 1)
        }

        func testCanonicalAdmissionRefreshMergesIntoReplacementWorkspaceAfterAuthorityRead() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let peer = try await fixture.makePeerWindow()
            let staleWorkspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: fixture.window, recorder: firstRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("canonical identity before local replacement"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])
            let firstObservations = await firstRecorder.observations()
            let first = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(tabID: first.tabID, sessionID: first.sessionID)
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex { $0.id == fixture.workspaceID })
            peer.workspaceManager.workspaces[peerIndex] = staleWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(staleWorkspace)

            let gate = makeHandoffGate("peer canonical-refresh gate")
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let secondRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: peer, recorder: secondRecorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("peer admission after replacement"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(task)
            try await waitUntil("the peer's start", enters: gate, producer: task)
            let replacementTab = ComposeTabState(name: "Replacement-local tab")
            var replacement = staleWorkspace
            replacement.name = "Replacement-local workspace"
            replacement.composeTabs = [replacementTab]
            replacement.activeComposeTabID = replacementTab.id
            peer.workspaceManager.workspaces[peerIndex] = replacement
            await gate.open()
            _ = try await startupTestTaskResult(task, "the peer's start after replacement")

            let refreshed = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            XCTAssertEqual(refreshed.name, replacement.name)
            XCTAssertTrue(refreshed.composeTabs.contains { $0.id == replacementTab.id })
            XCTAssertTrue(refreshed.composeTabs.containsIdentity(firstPair))
            let secondProviderCount = await secondRecorder.count()
            XCTAssertEqual(secondProviderCount, 1)
        }

        func testCanonicalAdmissionRefreshRejectsWorkspaceRemovedDuringAuthorityRead() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let manager = fixture.window.workspaceManager
            let canonicalBeforeValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalBefore = try XCTUnwrap(canonicalBeforeValue)
            let canonicalModelBefore = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalBefore.document.documentBytes
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let provisionalCountBefore = coordinator.snapshot().provisionalSessionCount
            let gate = makeHandoffGate("canonical-refresh gate")
            manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let recorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: fixture.window, recorder: recorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("removed while reading authority"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(task)
            try await waitUntil("the start", enters: gate, producer: task)
            manager.workspaces.removeAll { $0.id == fixture.workspaceID }
            await gate.open()
            do {
                _ = try await startupTestTaskResult(task, "the start whose target was removed")
                XCTFail("A removed target must reject before provisional publication.")
            } catch let error as StartupTestStepError {
                XCTAssertTrue(
                    error.underlying.localizedDescription.contains("disappeared"),
                    String(describing: error.underlying)
                )
            }

            let providerCount = await recorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot().provisionalSessionCount, provisionalCountBefore)
            XCTAssertFalse(manager.workspaces.contains { $0.id == fixture.workspaceID })
            let canonicalAfterValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalAfter = try XCTUnwrap(canonicalAfterValue)
            let canonicalModelAfter = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalAfter.document.documentBytes
            )
            // A save scheduled before the removal can still rewrite chat selection, expanded folders,
            // or save timestamps. Those writes are unrelated to admission, so compare only the persisted
            // agent identity the refusal must leave unchanged.
            XCTAssertEqual(canonicalModelAfter.id, canonicalModelBefore.id)
            XCTAssertEqual(canonicalModelAfter.composeTabs.map(\.id), canonicalModelBefore.composeTabs.map(\.id))
            XCTAssertEqual(
                canonicalModelAfter.composeTabs.map(\.activeAgentSessionID),
                canonicalModelBefore.composeTabs.map(\.activeAgentSessionID)
            )
            XCTAssertEqual(
                canonicalModelAfter.composeTabs.map(\.isPinned),
                canonicalModelBefore.composeTabs.map(\.isPinned)
            )
            XCTAssertEqual(canonicalModelAfter.activeComposeTabID, canonicalModelBefore.activeComposeTabID)
            XCTAssertEqual(
                canonicalModelAfter.stashedTabs.map(\.tab.id),
                canonicalModelBefore.stashedTabs.map(\.tab.id)
            )
            XCTAssertEqual(
                canonicalModelAfter.stashedTabs.map(\.tab.activeAgentSessionID),
                canonicalModelBefore.stashedTabs.map(\.tab.activeAgentSessionID)
            )
            XCTAssertEqual(
                canonicalModelAfter.stashedTabs.map(\.tab.isPinned),
                canonicalModelBefore.stashedTabs.map(\.tab.isPinned)
            )
        }

        func testCanonicalAdmissionRefreshHonorsCancellationDuringAuthorityRead() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let manager = fixture.window.workspaceManager
            let workspaceBefore = try XCTUnwrap(manager.workspace(withID: fixture.workspaceID))
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let provisionalCountBefore = coordinator.snapshot().provisionalSessionCount
            let gate = makeHandoffGate("canonical-refresh gate")
            manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let recorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: fixture.window, recorder: recorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("cancelled while reading authority"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(task)
            try await waitUntil("the start", enters: gate, producer: task)
            task.cancel()
            await gate.open()
            try await assertCancelled(
                task,
                "the start cancelled during canonical refresh",
                "Cancellation during canonical refresh must prevent admission."
            )

            let providerCount = await recorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot().provisionalSessionCount, provisionalCountBefore)
            let workspaceAfter = try XCTUnwrap(manager.workspace(withID: fixture.workspaceID))
            XCTAssertEqual(workspaceAfter.composeTabs.map(\.id), workspaceBefore.composeTabs.map(\.id))
            XCTAssertEqual(
                workspaceAfter.composeTabs.map(\.activeAgentSessionID),
                workspaceBefore.composeTabs.map(\.activeAgentSessionID)
            )
            XCTAssertEqual(workspaceAfter.stashedTabs, workspaceBefore.stashedTabs)
        }

        func testCanonicalAdmissionRefreshReconcilesStashedIdentityBeforeCreatingUniqueTab() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let peer = try await fixture.makePeerWindow()
            let stalePeerWorkspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: fixture.window, recorder: firstRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("canonical identity moved to stash"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])
            let firstObservations = await firstRecorder.observations()
            let firstObservation = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(
                tabID: firstObservation.tabID,
                sessionID: firstObservation.sessionID
            )
            let canonicalValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalSnapshot = try XCTUnwrap(canonicalValue)
            var canonical = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalSnapshot.document.documentBytes
            )
            let movedIndex = try XCTUnwrap(canonical.composeTabs.firstIndex { $0.id == firstPair.tabID })
            let moved = canonical.composeTabs.remove(at: movedIndex)
            canonical.stashedTabs.append(StashedTab(tab: moved))
            if canonical.activeComposeTabID == moved.id {
                canonical.activeComposeTabID = canonical.composeTabs.first?.id
            }
            let stashedSnapshot = try WorkspaceManagerViewModel.replacingWorkspaceProjectionForTesting(
                canonical,
                in: canonicalSnapshot
            )
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            peer.workspaceManager.workspaces[peerIndex] = stalePeerWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(stalePeerWorkspace)
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { _ in
                stashedSnapshot
            }
            defer { peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }

            let peerRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: peer, recorder: peerRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("new tab after stashed identity refresh"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])

            let refreshed = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            XCTAssertTrue(refreshed.stashedTabs.map(\.tab).containsIdentity(firstPair))
            XCTAssertFalse(refreshed.composeTabs.containsIdentity(firstPair))
            let allTabIDs = refreshed.composeTabs.map(\.id) + refreshed.stashedTabs.map(\.tab.id)
            XCTAssertEqual(Set(allTabIDs).count, allTabIDs.count)
            let peerProviderCount = await peerRecorder.count()
            XCTAssertEqual(peerProviderCount, 1)
        }

        func testAgentRunRefusalUsesReasonSpecificRetryGuidance() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let manager = fixture.window.workspaceManager
            let canonicalValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonical = try XCTUnwrap(canonicalValue)
            let workspace = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonical.document.documentBytes
            )
            let nonCanonical = try WorkspaceManagerViewModel.replacingWorkspaceProjectionForTesting(
                workspace,
                in: canonical,
                health: .degradedReadOnly(reason: "admission test")
            )
            let unsaved = try WorkspaceManagerViewModel.replacingWorkspaceProjectionForTesting(
                workspace,
                in: canonical,
                revisions: DomainRevisionState(
                    workingRevision: canonical.revisions.workingRevision + 1,
                    savedRevision: canonical.revisions.savedRevision,
                    dirtyRevision: canonical.revisions.workingRevision + 1
                )
            )
            let persistentGuidance = "Inspect the workspace state or the existing session instead of retrying this call."
            let transientGuidance = "Retry this call after the workspace finishes saving."
            let cases: [(DomainWorkspaceSnapshot?, AgentAdmissionRefusalReason, String)] = [
                (nil, .canonicalWorkspaceUnavailable, persistentGuidance),
                (nonCanonical, .nonCanonicalWorkspaceState, persistentGuidance),
                (unsaved, .unsavedWorkspaceChanges, transientGuidance)
            ]
            let recorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let service = makeAgentRunStartService(window: fixture.window, recorder: recorder)
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }

            for (snapshot, reason, expectedGuidance) in cases {
                manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { _ in snapshot }
                do {
                    _ = try await service.execute(args: [
                        "op": .string("start"),
                        "message": .string("canonical health refusal"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                    XCTFail("Canonical health failure must reject Agent admission.")
                } catch {
                    XCTAssertTrue(
                        error.localizedDescription.contains("(reason: \(reason.rawValue))"),
                        error.localizedDescription
                    )
                    XCTAssertTrue(
                        error.localizedDescription.contains(expectedGuidance),
                        error.localizedDescription
                    )
                    let rejectedGuidance = reason == .unsavedWorkspaceChanges
                        ? persistentGuidance
                        : transientGuidance
                    XCTAssertFalse(
                        error.localizedDescription.contains(rejectedGuidance),
                        error.localizedDescription
                    )
                }
            }

            let providerCount = await recorder.count()
            XCTAssertEqual(providerCount, 0)
        }

        func testAgentRunStartDuringLaunchRestoreIsRefusedUntilTheRestoreSettles() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let leaseHold = makeSaveGate("restore activation-lease hold")
            let restoreHold = makeSaveGate("restore root-hydration hold")
            let window = fixture.window
            let manager = window.workspaceManager
            let windowStates = WindowStatesManager.shared
            cleanup.onRelease {
                manager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting(nil)
                manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
                if windowStates.isRestoreSessionLoadPending {
                    windowStates.finishRestoreSessionLoadForTesting(entries: [])
                }
            }
            let restoredWorkspace = try XCTUnwrap(manager.activeWorkspace)
            let systemWorkspace = try XCTUnwrap(manager.workspaces.first(where: \.isSystemWorkspace))
            // A relaunched window registers on the system workspace while the saved window
            // session is still loading.
            let resetResult = await manager.switchWorkspace(
                to: systemWorkspace,
                saveState: false,
                reason: "launchRestoreAdmission.reset"
            )
            XCTAssertTrue(resetResult.didSwitch, resetResult.message ?? "")
            try await waitUntil("Agent Mode to handle the reset") {
                !window.agentModeViewModel.hasPendingWorkspaceSwitchDiscard
            }
            windowStates.beginRestoreSessionLoadForTesting()

            let recorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let service = makeAgentRunStartService(window: window, recorder: recorder)
            let startArgs: [String: Value] = [
                "op": .string("start"),
                "message": .string("start during launch restore"),
                "detach": .bool(true),
                "timeout": .int(0)
            ]
            func assertStartRefusedAsSwitchInFlight(_ phase: String) async {
                do {
                    let admitted = try await service.execute(args: startArgs)
                    XCTFail("agent_run start was admitted \(phase): \(admitted)")
                } catch let MCPError.invalidParams(message) {
                    XCTAssertEqual(
                        message,
                        AgentRunMCPToolService.workspaceSwitchPendingStartRejectionMessage,
                        phase
                    )
                } catch {
                    XCTFail("Expected the retryable switch rejection \(phase), got \(error)")
                }
            }

            await assertStartRefusedAsSwitchInFlight("before the saved window session loaded")

            // Hold the restore twice: before its switch begins, where only the window's restore
            // entry refuses a start, and after the restored workspace became active, which is
            // where an admitted run would later be discarded by Agent Mode's switch teardown.
            manager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting { workspaceID in
                guard workspaceID == restoredWorkspace.id else { return }
                await leaseHold.enterFirstAndWait()
            }
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == restoredWorkspace.id else { return }
                await restoreHold.enterFirstAndWait()
            }
            guard windowStates.allWindows.map(\.windowID) == [window.windowID] else {
                return XCTFail("The loaded session hands its entry to the first registered window, which must be this one.")
            }
            windowStates.finishRestoreSessionLoadForTesting(entries: [
                makeRestoreEntry(workspaceID: restoredWorkspace.id, workspaceName: restoredWorkspace.name)
            ])
            try await waitUntil("the restore to hold before its switch begins") {
                await leaseHold.hasEntered()
            }
            XCTAssertFalse(manager.isSwitchingWorkspace)
            await assertStartRefusedAsSwitchInFlight("before the restore's switch began")
            await leaseHold.open()
            try await waitUntil("the restore to hold with its workspace active") {
                await restoreHold.hasEntered()
            }
            XCTAssertEqual(manager.activeWorkspaceID, restoredWorkspace.id)

            await assertStartRefusedAsSwitchInFlight("while the restore was switching the window")
            let providerCountDuringRestore = await recorder.count()
            XCTAssertEqual(providerCountDuringRestore, 0)

            await restoreHold.open()

            // A caller retries on the retryable rejection; once Agent Mode has handled the
            // restored workspace, the start is admitted and the restore no longer discards it.
            var unexpectedError: Error?
            try await waitUntil("a start to be admitted after the restore settles") {
                do {
                    _ = try await service.execute(args: startArgs)
                    return true
                } catch let MCPError.invalidParams(message)
                    where message == AgentRunMCPToolService.workspaceSwitchPendingStartRejectionMessage
                {
                    return false
                } catch {
                    unexpectedError = error
                    return true
                }
            }
            XCTAssertNil(unexpectedError)
            XCTAssertEqual(manager.activeWorkspaceID, restoredWorkspace.id)
            let admittedRuns = await recorder.observations()
            XCTAssertEqual(admittedRuns.count, 1)
            let admittedTabID = try XCTUnwrap(admittedRuns.first?.tabID)
            XCTAssertNotNil(window.agentModeViewModel.session(for: admittedTabID, createIfNeeded: false))
        }

        func testStartGateRefusesWhileASwitchIsPendingOnASettledWindow() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let window = fixture.window
            let manager = window.workspaceManager
            manager.registerSwitchSessionProvider(ConfirmationRequiringSwitchSessionProvider())
            let systemWorkspace = manager.workspaces.first(where: \.isSystemWorkspace)
            let manualSwitch = Task { () -> WorkspaceSwitchResult? in
                guard let systemWorkspace else { return nil }
                return await manager.requestWorkspaceSwitch(to: systemWorkspace, saveState: false)
            }
            cleanup.onRelease {
                if let confirmation = manager.pendingSwitchConfirmation {
                    manager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
                }
            }
            cleanup.onCancelAndJoin(manualSwitch)
            // Agent Mode handles the fixture's own activation first, so below only the switch
            // under test refuses starts.
            try await waitUntil("Agent Mode to handle the fixture's activation") {
                !window.agentModeViewModel.hasPendingWorkspaceSwitchDiscard
            }

            // A manual switch waiting at its confirmation dialog.
            try await waitUntil("the manual switch to ask for confirmation") {
                manager.pendingSwitchConfirmation != nil
            }
            XCTAssertThrowsError(try AgentRunMCPToolService.requireSettledWorkspaceForStart(in: window))
            let confirmation = try XCTUnwrap(manager.pendingSwitchConfirmation)
            manager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
            let declinedSwitch = try await startupTestTaskResult(manualSwitch, "the declined manual switch")
            XCTAssertEqual(declinedSwitch?.didSwitch, false)

            // A switch notification Agent Mode hasn't handled. The window still has a workspace,
            // so this handler returns without discarding.
            let unhandled = window.agentModeViewModel.test_receiveWorkspaceSwitchNotification(nil)
            XCTAssertThrowsError(try AgentRunMCPToolService.requireSettledWorkspaceForStart(in: window))
            await window.agentModeViewModel.test_handleWorkspaceSwitch(nil, owner: unhandled)
            XCTAssertNoThrow(try AgentRunMCPToolService.requireSettledWorkspaceForStart(in: window))
        }

        func testPendingSwitchDiscardLastsUntilTheLatestNotificationIsHandled() async {
            let viewModel = AgentModeViewModel(
                testWindowID: 10801,
                codexControllerFactory: { _, _, _, _, _, _ in
                    StartupTestCodexController(gatesStartup: false)
                }
            )
            XCTAssertFalse(viewModel.hasPendingWorkspaceSwitchDiscard)

            // Each notification's handler runs in its own task, so handlers can finish in any order.
            let first = viewModel.test_receiveWorkspaceSwitchNotification(nil)
            XCTAssertTrue(viewModel.hasPendingWorkspaceSwitchDiscard)
            let second = viewModel.test_receiveWorkspaceSwitchNotification(nil)
            let latest = viewModel.test_receiveWorkspaceSwitchNotification(nil)
            await viewModel.test_handleWorkspaceSwitch(nil, owner: first)
            XCTAssertTrue(
                viewModel.hasPendingWorkspaceSwitchDiscard,
                "a superseded handler settled a newer notification"
            )
            await viewModel.test_handleWorkspaceSwitch(nil, owner: latest)
            XCTAssertFalse(
                viewModel.hasPendingWorkspaceSwitchDiscard,
                "the latest notification's handler finished without settling it"
            )
            await viewModel.test_handleWorkspaceSwitch(nil, owner: second)
            XCTAssertFalse(
                viewModel.hasPendingWorkspaceSwitchDiscard,
                "a superseded handler that finished late reopened the pending discard"
            )
        }

        func testRestoreEntryStaysInFlightUntilItsRestoreFinishes() async throws {
            let runtime = try makeIsolatedRuntime(
                container: makeTemporaryDirectory(named: "RestoreEntryInFlight"),
                profileIdentifier: "restore-entry-in-flight",
                cleanup: cleanup
            ).runtime
            try await cleanup.step("starting the runtime") {
                try await runtime.start()
            }
            let window = makeAdmissionWindow(runtime: runtime, cleanup: cleanup)
            // A launch restore can hand a window its entry before the window's workspace manager
            // has initialized, and a later entry replaces one that hasn't been applied yet.
            guard !window.workspaceManager.isInitialized else {
                return XCTFail("The workspace manager initialized before the restore entries were handed over.")
            }
            XCTAssertFalse(window.isWorkspaceRestoreInFlight)
            var replacedEntryCompletions = 0
            var restoreFinished = false
            window.applyWindowRestoreEntry(makeRestoreEntry(workspaceID: UUID())) { replacedEntryCompletions += 1 }
            window.applyWindowRestoreEntry(makeRestoreEntry(workspaceID: UUID())) { restoreFinished = true }
            XCTAssertEqual(replacedEntryCompletions, 1)
            XCTAssertTrue(window.isWorkspaceRestoreInFlight, "the replacing entry was not counted")

            try await cleanup.step("workspace manager initialization") {
                await window.workspaceManager.awaitInitialized()
            }
            try await waitUntil("the replacing entry's restore to finish") { restoreFinished }
            XCTAssertFalse(window.isWorkspaceRestoreInFlight, "the finished restore was still counted")
        }

        func testCanonicalAdmissionRefreshRejectsDuplicateTabIDWithoutMutationOrDispatch() async throws {
            let runtime = try makeIsolatedRuntime(
                container: makeTemporaryDirectory(named: "MalformedCanonicalIdentity"),
                profileIdentifier: "malformed-canonical-admission",
                cleanup: cleanup
            ).runtime
            let authority = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -882)
            // The full-window fixture runs Oracle chat-session writers and switches to the workspace,
            // which schedules saves this test never awaits, so the whole-model comparison below would
            // depend on their timing. The manager-only fixture has no Oracle and never activates the
            // target, so background saves, which resolve the active workspace, cannot reach it.
            let manager = makeManagerFixture(
                coordinator: WorkspaceAgentAdmissionCoordinator(),
                domainWorkspaceAuthorityClient: authority
            ).manager
            cleanup.onClose { manager.prepareForWindowClose() }
            try await cleanup.step("starting the runtime") {
                try await runtime.start()
            }

            var tab = ComposeTabState(name: "Admission")
            tab.activeChatSessionID = UUID()
            let workspace = WorkspaceModel(
                name: "Malformed canonical admission",
                repoPaths: [],
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
            let workspaceFileURL = manager.workspaceFileURL(for: workspace)
            try await createCommittedWorkspace(workspace, authority: authority, fileURL: workspaceFileURL)
            let canonicalValue = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
            let canonicalSnapshot = try XCTUnwrap(canonicalValue)
            // Admission refuses an unhealthy or unsaved snapshot before it checks tab identity, so the
            // malformed copy below must inherit a writable, saved state.
            guard canonicalSnapshot.health == .writable, canonicalSnapshot.revisions.dirtyRevision == nil else {
                throw AdmissionTestError.fixtureSetup("canonical workspace was not writable and saved")
            }
            manager.workspaces = [workspace]
            guard manager.activeWorkspaceID != workspace.id else {
                throw AdmissionTestError.fixtureSetup("target workspace became active during setup")
            }
            let workspaceBefore = try XCTUnwrap(manager.workspace(withID: workspace.id))
            var malformed = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalSnapshot.document.documentBytes
            )
            // The canonical tab carries an agent identity the local tab lacks, so a refresh that wrote
            // to the local model before refusing would fail the whole-model comparison below.
            var duplicate = try XCTUnwrap(malformed.composeTabs.first)
            duplicate.activeAgentSessionID = UUID()
            malformed.composeTabs[0] = duplicate
            malformed.stashedTabs.append(StashedTab(tab: duplicate))
            let malformedSnapshot = try WorkspaceManagerViewModel.replacingWorkspaceProjectionForTesting(
                malformed,
                in: canonicalSnapshot
            )
            manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { _ in malformedSnapshot }
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            var operationRan = false

            do {
                try await manager.withAgentSessionAdmission(
                    workspaceID: workspace.id,
                    admissionID: UUID(),
                    refreshCanonicalState: true
                ) {
                    operationRan = true
                }
                XCTFail("Malformed canonical tab identity must reject admission.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("(reason: tab_identity_mismatch)"))
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "Inspect the workspace state or the existing session instead of retrying this call."
                    )
                )
            }

            XCTAssertFalse(operationRan)
            XCTAssertEqual(manager.workspace(withID: workspace.id), workspaceBefore)
            XCTAssertNil(
                manager.activeWorkspaceID,
                "A workspace-list reload from another manager activated a workspace; that is not an admission mutation."
            )
        }

        func testCanonicalAdmissionRefreshReportsLocalComposeAndStashDuplicateAsLocalState() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let manager = fixture.window.workspaceManager
            let canonicalValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalSnapshot = try XCTUnwrap(canonicalValue)
            let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            var local = manager.workspaces[workspaceIndex]
            let duplicate = ComposeTabState(name: "Local compose-and-stash duplicate")
            local.composeTabs.append(duplicate)
            local.stashedTabs.append(StashedTab(tab: duplicate))
            manager.workspaces[workspaceIndex] = local
            manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { _ in canonicalSnapshot }
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            var operationRan = false

            do {
                try await manager.withAgentSessionAdmission(
                    workspaceID: fixture.workspaceID,
                    admissionID: UUID(),
                    refreshCanonicalState: true
                ) {
                    operationRan = true
                }
                XCTFail("A local compose-and-stash duplicate must reject admission.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("(reason: local_tab_identity_conflict)"))
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "The in-memory workspace contains the same tab identity in both compose and stash."
                    )
                )
                XCTAssertFalse(
                    error.localizedDescription.contains("The canonical workspace contains conflicting tab identities."),
                    error.localizedDescription
                )
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "Inspect the workspace state or the existing session instead of retrying this call."
                    )
                )
            }

            XCTAssertFalse(operationRan)
        }

        func testRetainedRecoveryKeepsPeerProvisionalFenceUntilRecoveryTerminates() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let peer = try await fixture.makePeerWindow()
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let workspaceID = fixture.workspaceID
            let sessionID = UUID()
            let initiatingOwnerID = UUID()
            let recoveryID = UUID()
            let gate = makeHandoffGate("retained recovery gate")
            XCTAssertTrue(coordinator.reserveProvisionalSession(
                workspaceID: workspaceID,
                sessionID: sessionID,
                ownerID: initiatingOwnerID
            ))
            cleanup.onRelease {
                coordinator.releaseProvisionalSession(
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    ownerID: initiatingOwnerID
                )
            }
            fixture.window.workspaceManager.retainProvisionalAgentAdmissionRecovery(
                recoveryID: recoveryID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                reservationOwnerID: recoveryID
            ) {
                await gate.enterAndWait()
                return .complete(.localOnly)
            }
            try await waitUntil("the retained recovery to enter \(gate.name)") {
                await gate.hasEntered()
            }

            coordinator.releaseProvisionalSession(
                workspaceID: workspaceID,
                sessionID: sessionID,
                ownerID: initiatingOwnerID
            )
            XCTAssertTrue(peer.workspaceManager.hasActiveProvisionalAgentSession(
                workspaceID: workspaceID,
                sessionID: sessionID
            ))
            XCTAssertEqual(coordinator.snapshot().retainedRecoveryCount, baseline.retainedRecoveryCount + 1)

            await gate.open()
            try await waitUntil("retained recovery to release the process-shared reservation") {
                let snapshot = coordinator.snapshot()
                return snapshot.retainedRecoveryCount == baseline.retainedRecoveryCount
                    && snapshot.provisionalSessionCount == baseline.provisionalSessionCount
            }
            XCTAssertFalse(peer.workspaceManager.hasActiveProvisionalAgentSession(
                workspaceID: workspaceID,
                sessionID: sessionID
            ))
        }

        func testSecondWindowCannotStartPublishedProvisionalSessionBeforeAcceptance() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let peer = try await fixture.makePeerWindow()
            let providerGate = makeHandoffGate("provider dispatch gate")
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            var provisionalPair: AdmissionIdentityPair?
            let firstService = makeAgentRunStartService(
                window: fixture.window,
                recorder: firstRecorder,
                validateBeforeProviderDispatch: { pair in
                    provisionalPair = pair
                    await providerGate.enterAndWait()
                }
            )
            let firstTask = Task { @MainActor in
                try await firstService.execute(args: [
                    "op": .string("start"),
                    "message": .string("publish provisional cross-window target"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(firstTask)
            try await waitUntil("the first window's start", enters: providerGate, producer: firstTask)
            let pair = try XCTUnwrap(provisionalPair)

            let publishedSnapshotValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let publishedSnapshot = try XCTUnwrap(publishedSnapshotValue)
            let publishedWorkspace = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: publishedSnapshot.document.documentBytes
            )
            XCTAssertTrue(publishedWorkspace.composeTabs.containsIdentity(pair))
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            peer.workspaceManager.workspaces[peerIndex] = publishedWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(publishedWorkspace)

            XCTAssertNil(
                try peer.agentModeViewModel.mcpSettledLiveSessionForStop(sessionID: pair.sessionID),
                "A peer must not stop a durably published session while its shared reservation is active."
            )

            do {
                _ = try await peer.agentModeViewModel.mcpResolveOrCreateSessionTarget(
                    tabID: pair.tabID,
                    sessionID: pair.sessionID,
                    createIfNeeded: true,
                    sessionName: nil,
                    expectedWorkspaceID: fixture.workspaceID
                )
                XCTFail("A second window must not resolve another window's provisional target.")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("still provisional in another window"),
                    "Unexpected provisional-fence error: \(error)"
                )
            }
            let providerCountBeforeAcceptance = await firstRecorder.count()
            XCTAssertEqual(providerCountBeforeAcceptance, 0)

            await providerGate.open()
            _ = try await startupTestTaskResult(firstTask, "the first window's start after acceptance")
            let firstAttemptCounts = await firstRecorder.attemptCounts()
            XCTAssertEqual(firstAttemptCounts[pair], 1)

            let accepted = try await peer.agentModeViewModel.mcpResolveOrCreateSessionTarget(
                tabID: pair.tabID,
                sessionID: pair.sessionID,
                createIfNeeded: true,
                sessionName: nil,
                expectedWorkspaceID: fixture.workspaceID
            )
            XCTAssertEqual(accepted.tabID, pair.tabID)
            XCTAssertEqual(accepted.sessionID, pair.sessionID)
            XCTAssertNil(accepted.recoveryClaim)
            let stoppable = try XCTUnwrap(
                try peer.agentModeViewModel.mcpSettledLiveSessionForStop(sessionID: pair.sessionID)
            )
            XCTAssertEqual(stoppable.tabID, pair.tabID)
        }

        func testAgentAdmissionsForDistinctDurableWorkspacesOverlap() async throws {
            let fixture = try await DistinctDurableAdmissionFixture.make(cleanup: cleanup)
            let first = fixture.first
            let second = fixture.second
            let initialTabsByWorkspace = try Dictionary(uniqueKeysWithValues: [first, second].map { context in
                try (
                    context.workspaceID,
                    XCTUnwrap(context.window.workspaceManager.activeWorkspace).composeTabs
                )
            })
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let firstGate = makeSaveGate("workspace A admission save gate")
            let secondGate = makeSaveGate("workspace B admission save gate")
            let providerRecorder = AdmissionProviderRecorder(expectedCount: 2)
            cleanup.onRelease { await providerRecorder.releaseAll() }
            first.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                guard workspaceID == first.workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await firstGate.enterFirstAndWait()
            }
            second.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                guard workspaceID == second.workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await secondGate.enterFirstAndWait()
            }
            defer {
                first.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                second.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            let firstService = makeAgentRunStartService(
                window: first.window,
                recorder: providerRecorder
            )
            let secondService = makeAgentRunStartService(
                window: second.window,
                recorder: providerRecorder
            )
            let firstTask = Task { @MainActor in
                try await firstService.execute(args: [
                    "op": .string("start"),
                    "message": .string("distinct workspace A"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            let secondTask = Task { @MainActor in
                try await secondService.execute(args: [
                    "op": .string("start"),
                    "message": .string("distinct workspace B"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(firstTask)
            cleanup.onCancelAndJoin(secondTask)

            do {
                try await waitUntil("workspace A admission save to block") {
                    await firstGate.hasEntered()
                }
                try await waitUntil("workspace B admission save to overlap workspace A") {
                    await secondGate.hasEntered()
                }
                XCTAssertEqual(
                    coordinator.snapshot(),
                    .init(
                        activeAdmissionCount: baseline.activeAdmissionCount + 2,
                        waiterCount: baseline.waiterCount,
                        trackedWorkspaceCount: baseline.trackedWorkspaceCount + 2,
                        provisionalSessionCount: baseline.provisionalSessionCount + 2,
                        retainedRecoveryCount: baseline.retainedRecoveryCount
                    )
                )

                await firstGate.open()
                await secondGate.open()
                try await waitUntil("both distinct-workspace providers to overlap") {
                    await providerRecorder.count() == 2
                }
                let observations = await providerRecorder.observations()
                XCTAssertEqual(
                    Set(observations.compactMap { $0.lifecycleIdentity?.workspaceID }),
                    Set([first.workspaceID, second.workspaceID])
                )
                let observationsByWorkspace = Dictionary(
                    uniqueKeysWithValues: observations.compactMap { observation in
                        observation.lifecycleIdentity.map { ($0.workspaceID, observation) }
                    }
                )
                for context in [first, second] {
                    let observation = try XCTUnwrap(observationsByWorkspace[context.workspaceID])
                    let pair = AdmissionIdentityPair(
                        tabID: observation.tabID,
                        sessionID: observation.sessionID
                    )
                    let initialTabs = try XCTUnwrap(initialTabsByWorkspace[context.workspaceID])
                    let projected = try XCTUnwrap(context.window.workspaceManager.activeWorkspace)
                    assertExactAdmissionState(
                        in: projected.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                    assertExactAdmissionState(
                        in: context.window.promptManager.currentComposeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                    let canonicalSnapshot = await context.runtime.workspaceStore
                        .canonicalWorkspaceSnapshot(context.workspaceID)
                    let canonical = try XCTUnwrap(canonicalSnapshot)
                    let canonicalWorkspace = try JSONDecoder().decode(
                        WorkspaceModel.self,
                        from: canonical.document.documentBytes
                    )
                    assertExactAdmissionState(
                        in: canonicalWorkspace.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                    let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                        at: context.workspaceFileURL,
                        scheduleNormalizationWriteback: false
                    )
                    assertExactAdmissionState(
                        in: saved.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                }

                await providerRecorder.releaseAll()
                let values = try await startupTestTaskResults(
                    [firstTask, secondTask],
                    "both distinct-workspace starts"
                )
                let responseIDs = Set(values.compactMap {
                    $0.objectValue?["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                })
                XCTAssertEqual(responseIDs, Set(observations.map(\.sessionID)))
                XCTAssertEqual(coordinator.snapshot(), baseline)

                try await fixture.closeWindowsAndRuntime()
                for context in [first, second] {
                    try await fixture.withFreshRuntime(for: context, generation: 2) { restarted in
                        let observation = try XCTUnwrap(observationsByWorkspace[context.workspaceID])
                        let pair = AdmissionIdentityPair(
                            tabID: observation.tabID,
                            sessionID: observation.sessionID
                        )
                        let initialTabs = try XCTUnwrap(initialTabsByWorkspace[context.workspaceID])
                        let restartedSnapshot = await restarted.workspaceStore
                            .canonicalWorkspaceSnapshot(context.workspaceID)
                        let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                        let restartedModel = try JSONDecoder().decode(
                            WorkspaceModel.self,
                            from: restartedWorkspace.document.documentBytes
                        )
                        assertExactAdmissionState(
                            in: restartedModel.composeTabs,
                            initialTabs: initialTabs,
                            acceptedPairs: [pair]
                        )
                    }
                }
            } catch {
                await firstGate.open()
                await secondGate.open()
                await providerRecorder.releaseAll()
                let taskErrors = await cancelAndCollectErrors([firstTask, secondTask])
                throw AdmissionTestError.fixtureSetup(
                    "\(error); taskErrors=\(taskErrors)"
                )
            }
        }

        func testTypedAdmissionRejectionLeavesNoIdentityAcrossRestartAndDispatchesNoProvider() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let initialTabIDs = Set(initialTabs.map(\.id))
            let provisionalIdentity = ProvisionalAdmissionIdentityRecorder()
            let beforeSaveToken = fixture.window.workspaceManager.addBeforeSaveListener { workspace in
                guard workspace.id == workspaceID,
                      let tab = workspace.composeTabs.first(where: {
                          !initialTabIDs.contains($0.id) && $0.activeAgentSessionID != nil
                      }), let sessionID = tab.activeAgentSessionID
                else { return }
                provisionalIdentity.record(.init(tabID: tab.id, sessionID: sessionID))
            }
            let providerRecorder = AdmissionProviderRecorder(
                expectedCount: 1,
                blockProviders: false
            )
            let lifecycleEvents = AdmissionLifecycleEventRecorder()
            AgentSessionLifecycleAuthority.setEventObserverForTesting { lifecycleEvents.record($0) }
            fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(
                .rejected(
                    reason: "authority_revision_conflict",
                    category: .authorityRevisionConflict
                )
            )
            defer {
                fixture.window.workspaceManager.removeBeforeSaveListener(beforeSaveToken)
                fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
                AgentSessionLifecycleAuthority.setEventObserverForTesting(nil)
            }
            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder
            )

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("reject this durable admission"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
                XCTFail("A typed authority conflict must reject before provider dispatch.")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("workspace binding was not durably accepted"),
                    error.localizedDescription
                )
            }

            let rejectionEvent = try XCTUnwrap(lifecycleEvents.snapshot().last { event in
                event.caller == .agentRunStart
                    && event.decision == .rejected
                    && event.reason == AgentSessionLifecycleAuthority.RejectionReason
                    .workspacePersistenceRejected.rawValue
            })
            XCTAssertEqual(
                rejectionEvent.workspaceSaveResult,
                WorkspacePersistenceFailureCategory.authorityRevisionConflict.rawValue
            )
            XCTAssertEqual(
                WorkspacePersistenceFailureCategory.classify(reason: rejectionEvent.workspaceSaveResult),
                .authorityRevisionConflict
            )

            let rejectedPair = try XCTUnwrap(provisionalIdentity.value())
            let providerCount = await providerRecorder.count()
            XCTAssertEqual(providerCount, 0)
            let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            assertExactAdmissionState(
                in: projectedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(projectedWorkspace.composeTabs.containsIdentity(rejectedPair))
            assertExactAdmissionState(
                in: fixture.window.promptManager.currentComposeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(fixture.window.promptManager.currentComposeTabs.containsIdentity(rejectedPair))
            XCTAssertNil(
                try fixture.window.agentModeViewModel.authoritativeLiveSession(
                    for: rejectedPair.sessionID
                )
            )

            let canonicalSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            let canonicalWorkspace = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonical.document.documentBytes
            )
            XCTAssertEqual(canonical.health, .writable)
            assertExactAdmissionState(
                in: canonicalWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(canonicalWorkspace.composeTabs.containsIdentity(rejectedPair))
            let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceFileURL,
                scheduleNormalizationWriteback: false
            )
            assertExactAdmissionState(
                in: savedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(savedWorkspace.composeTabs.containsIdentity(rejectedPair))

            fixture.window.workspaceManager.removeBeforeSaveListener(beforeSaveToken)
            fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
            try await fixture.closeWindowAndRuntime()
            try await fixture.withFreshRuntime(generation: 2) { restarted in
                let restartedSnapshot = await restarted.workspaceStore
                    .canonicalWorkspaceSnapshot(workspaceID)
                let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                XCTAssertEqual(restartedWorkspace.health, .writable)
                let restartedModel = try JSONDecoder().decode(
                    WorkspaceModel.self,
                    from: restartedWorkspace.document.documentBytes
                )
                assertExactAdmissionState(
                    in: restartedModel.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: []
                )
                XCTAssertFalse(restartedModel.composeTabs.containsIdentity(rejectedPair))
            }
        }

        func testQueuedAgentRunCancellationMutatesNoDurableStateAndDispatchesNoProvider() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let providerRecorder = AdmissionProviderRecorder(
                expectedCount: 1,
                blockProviders: false
            )
            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            cleanup.onRelease { holder.release() }
            let startTask = Task { @MainActor in
                try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("cancel while queued"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            cleanup.onCancelAndJoin(startTask)
            try await waitUntil("agent_run.start to queue behind the workspace holder") {
                coordinator.waiterCount(for: workspaceID) == 1
            }
            startTask.cancel()
            try await assertCancelled(
                startTask,
                "the queued start after cancellation",
                "A queued cancelled start must throw CancellationError."
            )
            holder.release()

            let providerCount = await providerRecorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot(), baseline)
            let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            assertExactAdmissionState(
                in: projectedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            assertExactAdmissionState(
                in: fixture.window.promptManager.currentComposeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            let canonicalSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            let canonicalWorkspace = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonical.document.documentBytes
            )
            assertExactAdmissionState(
                in: canonicalWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceFileURL,
                scheduleNormalizationWriteback: false
            )
            assertExactAdmissionState(
                in: savedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )

            try await fixture.closeWindowAndRuntime()
            try await fixture.withFreshRuntime(generation: 2) { restarted in
                let restartedSnapshot = await restarted.workspaceStore
                    .canonicalWorkspaceSnapshot(workspaceID)
                let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                let restartedModel = try JSONDecoder().decode(
                    WorkspaceModel.self,
                    from: restartedWorkspace.document.documentBytes
                )
                assertExactAdmissionState(
                    in: restartedModel.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: []
                )
            }
        }

        func testUnexpectedQueuePhaseFailureCancelsAndJoinsAgentRunStartBeforeRethrowingOriginalError() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make(cleanup: cleanup)
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let providerRecorder = AdmissionProviderRecorder(
                expectedCount: 1,
                blockProviders: false
            )
            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            cleanup.onRelease { holder.release() }
            let terminationProbe = AdmissionStartTaskTerminationProbe()
            let startTask = Task { @MainActor in
                do {
                    let value = try await service.execute(args: [
                        "op": .string("start"),
                        "message": .string("unexpected queue-phase failure"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                    await terminationProbe.recordTermination()
                    return value
                } catch {
                    await terminationProbe.recordTermination()
                    throw error
                }
            }
            cleanup.onCancelAndJoin(startTask)
            let sentinelID = UUID()

            do {
                do {
                    try await waitUntil("agent_run.start to queue before an unexpected queue-phase failure") {
                        coordinator.waiterCount(for: workspaceID) == 1
                    }
                    throw AdmissionTestError.queuePhaseSentinel(sentinelID)
                } catch {
                    let queuePhaseError = error
                    startTask.cancel()
                    holder.release()
                    // The cancelled start's own error is expected; only joining it matters here.
                    try await cleanup.step("joining the start cancelled after a queue-phase failure") {
                        _ = await startTask.result
                    }
                    throw queuePhaseError
                }
            } catch let AdmissionTestError.queuePhaseSentinel(observedID) {
                XCTAssertEqual(observedID, sentinelID)
            }

            let terminationCount = await terminationProbe.terminationCount()
            XCTAssertEqual(terminationCount, 1)
            let providerCount = await providerRecorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot(), baseline)
            let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            assertExactAdmissionState(
                in: projectedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            assertExactAdmissionState(
                in: fixture.window.promptManager.currentComposeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
        }

        func testSameWorkspaceAdmissionsAcquireInFIFOOrderAndTeardownEmpty() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holderID = UUID()
            let queuedIDs = (0 ..< 5).map { _ in UUID() }
            let recorder = AdmissionOrderRecorder()

            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: holderID
            )
            cleanup.onRelease { holder.release() }
            var queuedTasks: [Task<UUID, Error>] = []
            for (index, admissionID) in queuedIDs.enumerated() {
                let queuedTask = Task {
                    let lease = try await coordinator.acquire(
                        workspaceID: workspaceID,
                        admissionID: admissionID
                    )
                    await recorder.append(admissionID)
                    lease.release()
                    return admissionID
                }
                queuedTasks.append(queuedTask)
                cleanup.onCancelAndJoin(queuedTask)
                try await waitUntil("waiter \(index + 1) to enqueue") {
                    coordinator.waiterCount(for: workspaceID) == index + 1
                }
            }

            XCTAssertEqual(coordinator.activeCount(for: workspaceID), 1)
            XCTAssertTrue(holder.release())
            XCTAssertFalse(holder.release(), "Lease release must be idempotent.")
            let admittedIDs = try await startupTestTaskResults(queuedTasks, "the five queued admissions")
            XCTAssertEqual(admittedIDs, queuedIDs)

            let recordedOrder = await recorder.values()
            XCTAssertEqual(recordedOrder, queuedIDs)
            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 0,
                    waiterCount: 0,
                    trackedWorkspaceCount: 0,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
        }

        func testQueuedCancellationNeverAcquiresAndLeavesNoCoordinatorState() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            cleanup.onRelease { holder.release() }
            let cancelledID = UUID()
            let cancelledTask = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: cancelledID
                )
            }
            cleanup.onCancelAndJoin(cancelledTask)
            try await waitUntil("cancelled waiter to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 1
            }

            cancelledTask.cancel()
            try await assertCancelled(
                cancelledTask,
                "the cancelled queued admission",
                "A cancelled queued admission must not acquire a lease."
            )

            XCTAssertEqual(coordinator.waiterCount(for: workspaceID), 0)
            holder.release()
            XCTAssertEqual(coordinator.snapshot().trackedWorkspaceCount, 0)
        }

        func testCancellingFirstQueuedWaiterPreservesNextWaiterHandoff() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            cleanup.onRelease { holder.release() }
            let waiterA = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: UUID()
                )
            }
            cleanup.onCancelAndJoin(waiterA)
            try await waitUntil("first waiter to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 1
            }
            let waiterB = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: UUID()
                )
            }
            cleanup.onCancelAndJoin(waiterB)
            try await waitUntil("both waiters to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 2
            }

            waiterA.cancel()
            try await assertCancelled(
                waiterA,
                "the cancelled first waiter",
                "The cancelled first waiter must not acquire a lease."
            )

            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 1,
                    waiterCount: 1,
                    trackedWorkspaceCount: 1,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
            holder.release()
            let waiterBLease = try await startupTestTaskResult(waiterB, "the second waiter's handoff")
            waiterBLease.release()
            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 0,
                    waiterCount: 0,
                    trackedWorkspaceCount: 0,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
        }

        func testCancellationAfterHandoffReleasesBeforeReturning() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            cleanup.onRelease { holder.release() }
            let handoffGate = makeHandoffGate("post-handoff gate")
            let handedOffID = UUID()
            coordinator.setDidResumeAfterHandoffHandlerForTesting { _, admissionID in
                guard admissionID == handedOffID else { return }
                await handoffGate.enterAndWait()
            }
            cleanup.onRelease { coordinator.setDidResumeAfterHandoffHandlerForTesting(nil) }

            let handedOffTask = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: handedOffID
                )
            }
            cleanup.onCancelAndJoin(handedOffTask)
            try await waitUntil("handoff waiter to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 1
            }
            holder.release()
            try await waitUntil("the handed-off admission", enters: handoffGate, producer: handedOffTask)
            handedOffTask.cancel()
            await handoffGate.open()

            try await assertCancelled(
                handedOffTask,
                "the admission cancelled after handoff",
                "Cancellation after handoff must reject the acquisition."
            )

            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 0,
                    waiterCount: 0,
                    trackedWorkspaceCount: 0,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
        }

        func testDistinctWorkspaceAdmissionsOverlap() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceA = UUID()
            let workspaceB = UUID()

            let leaseA = try await coordinator.acquire(
                workspaceID: workspaceA,
                admissionID: UUID()
            )
            let leaseB = try await coordinator.acquire(
                workspaceID: workspaceB,
                admissionID: UUID()
            )

            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 2,
                    waiterCount: 0,
                    trackedWorkspaceCount: 2,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
            leaseA.release()
            leaseB.release()
            XCTAssertEqual(coordinator.snapshot().trackedWorkspaceCount, 0)
        }

        func testManagerAdmissionHelperReleasesLeaseWhenOperationThrows() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let fixture = makeManagerFixture(coordinator: coordinator)
            defer { fixture.manager.prepareForWindowClose() }

            do {
                _ = try await fixture.manager.withAgentSessionAdmission(
                    workspaceID: UUID(),
                    admissionID: UUID()
                ) {
                    throw AdmissionTestError.expected
                }
                XCTFail("The controlled operation must throw.")
            } catch AdmissionTestError.expected {}

            XCTAssertEqual(coordinator.snapshot().trackedWorkspaceCount, 0)
        }

        func testAgentAdmissionSaveRetriesOnceThenPersistsNewestState() async throws {
            let root = try makeTemporaryDirectory(named: "RetrySuccess")
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makePersistentWorkspaceFixture(root: root)
            defer {
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                fixture.manager.prepareForWindowClose()
            }
            fixture.manager.resetWorkspaceSaveDiagnosticsForTesting()
            fixture.manager.markWorkspaceDirty()
            fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                remainingRetryCount in
                guard remainingRetryCount == 1 else { return }
                await MainActor.run {
                    guard let index = fixture.manager.workspaces.firstIndex(where: {
                        $0.id == workspaceID
                    }) else { return }
                    fixture.manager.workspaces[index].currentPromptText = "newest state"
                    fixture.manager.markWorkspaceDirty()
                }
            }

            let outcome = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspace.id,
                source: WorkspaceSaveSource("agentSessionLifecycleAdmissionTest")
            )

            guard case .persisted = outcome else {
                return XCTFail("The one allowed recapture must persist: \(outcome)")
            }
            XCTAssertEqual(
                fixture.manager.workspaceSaveDiagnosticsForTesting(
                    workspaceID: fixture.workspace.id
                ).attemptCount,
                2
            )
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.manager.workspaceFileURL(for: fixture.workspace),
                scheduleNormalizationWriteback: false
            )
            XCTAssertEqual(saved.currentPromptText, "newest state")
        }

        func testAgentAdmissionSaveReportsLocalRetryExhaustionAfterTwoAttempts() async throws {
            let root = try makeTemporaryDirectory(named: "RetryExhaustion")
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makePersistentWorkspaceFixture(root: root)
            defer {
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                fixture.manager.prepareForWindowClose()
            }
            fixture.manager.resetWorkspaceSaveDiagnosticsForTesting()
            fixture.manager.markWorkspaceDirty()
            fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                await MainActor.run {
                    guard let index = fixture.manager.workspaces.firstIndex(where: {
                        $0.id == workspaceID
                    }) else { return }
                    var workspace = fixture.manager.workspaces[index]
                    workspace.currentPromptText = (workspace.currentPromptText ?? "") + "x"
                    fixture.manager.workspaces[index] = workspace
                    fixture.manager.markWorkspaceDirty()
                }
            }

            let outcome = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspace.id,
                source: WorkspaceSaveSource("agentSessionLifecycleAdmissionTest")
            )

            XCTAssertEqual(
                outcome,
                .rejected(
                    reason: "workspace_save_failed",
                    category: .localSavePreparationRetryExhausted
                )
            )
            XCTAssertEqual(
                outcome.normalizedFailureCategory,
                .localSavePreparationRetryExhausted
            )
            XCTAssertEqual(
                fixture.manager.workspaceSaveDiagnosticsForTesting(
                    workspaceID: fixture.workspace.id
                ).attemptCount,
                2
            )
            XCTAssertNil(
                fixture.manager.debugLastSavedVersionForWorkspace(fixture.workspace.id)
            )
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.manager.workspaceFileURL(for: fixture.workspace).path
            ))
        }

        func testNormalizedFailureLeavesRemainDistinct() {
            let reasonCases: [(String, WorkspacePersistenceFailureCategory)] = [
                ("local_save_retry_exhausted", .localSavePreparationRetryExhausted),
                ("authority_revision_conflict", .authorityRevisionConflict),
                ("authority_external_conflict", .authorityExternalConflict),
                ("workspace_not_writable", .authorityReadOnly),
                ("lock_timed_out", .lockTimedOut),
                ("cancelled", .cancelled),
                ("persistence_failure", .persistenceFailure),
                ("workspace_changed", .workspaceChanged),
                ("durability_uncertain", .durabilityUncertain)
            ]
            XCTAssertEqual(Set(reasonCases.map(\.1)).count, reasonCases.count)
            for (reason, expected) in reasonCases {
                XCTAssertEqual(
                    WorkspacePersistenceOutcome.rejected(reason: reason)
                        .normalizedFailureCategory,
                    expected
                )
            }

            let domainCases: [(DomainCommandErrorCode, WorkspacePersistenceFailureCategory)] = [
                (.stateConflict, .authorityRevisionConflict),
                (.workspaceExternalConflict, .authorityExternalConflict),
                (.runtimeReadOnlyDegraded, .authorityReadOnly),
                (.workspaceReadOnlyDegraded, .authorityReadOnly),
                (.lockTimedOut, .lockTimedOut),
                (.cancelled, .cancelled),
                (.workspaceUnavailable, .workspaceChanged),
                (.persistenceFailure, .persistenceFailure)
            ]
            for (domainCode, expected) in domainCases {
                XCTAssertEqual(
                    WorkspacePersistenceFailureCategory.classify(
                        domainErrorCode: domainCode
                    ),
                    expected
                )
            }
        }

        private func makeAgentRunStartService(
            window: WindowState,
            recorder: AdmissionProviderRecorder,
            validateBeforeProviderDispatch: ((AdmissionIdentityPair) async throws -> Void)? = nil
        ) -> AgentRunMCPToolService {
            var service = AgentRunMCPToolService(
                toolName: MCPWindowToolName.agentRun,
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: nil,
                        clientName: "same-workspace-admission-test",
                        windowID: window.windowID
                    )
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { target, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _, _, _ in
                    let sessionID = try XCTUnwrap(target.sessionID)
                    let pair = AdmissionIdentityPair(tabID: target.tabID, sessionID: sessionID)
                    try await validateBeforeProviderDispatch?(pair)
                    try await recorder.recordAndWait(
                        .init(
                            tabID: target.tabID,
                            sessionID: sessionID,
                            lifecycleIdentity: target.lifecycleIdentity
                        )
                    )
                    let session = agentModeVM.session(for: target.tabID)
                    return AgentExternalMCPRunStarter.StartOutcome(
                        snapshot: AgentRunMCPSnapshot(
                            sessionID: sessionID,
                            tabID: target.tabID,
                            sessionName: "Concurrent admission",
                            agentRaw: agentRaw,
                            agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                            modelRaw: modelRaw,
                            reasoningEffortRaw: reasoningEffortRaw,
                            status: .running,
                            statusText: "Provider admitted",
                            latestAssistantPreview: nil,
                            interaction: nil,
                            transcriptItemCount: 0,
                            updatedAt: Date(),
                            parentSessionID: session.parentSessionID,
                            failureReason: nil,
                            worktreeBindings: [],
                            activeWorktreeMerges: []
                        ),
                        delivery: .startedRun
                    )
                }
            )
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let sourceTabID = try XCTUnwrap(workspace.activeComposeTabID)
                let selectionRevision = targetWindow.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspace.id,
                    tabID: sourceTabID
                )
                let snapshot = AgentRunOracleReviewLaunchSnapshot(
                    route: .explicitWindowActiveCompose,
                    windowID: targetWindow.windowID,
                    workspaceID: workspace.id,
                    tabID: sourceTabID,
                    selectionRevision: selectionRevision,
                    promptText: "",
                    selection: StoredSelection(),
                    sourceAgentSessionID: nil,
                    routedRunID: nil
                )
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: snapshot,
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: sourceTabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Synthetic durable admission fixture")
                    ))
                )
            }
            return service
        }

        private func assertExactAdmissionState(
            in tabs: [ComposeTabState],
            initialTabs: [ComposeTabState],
            acceptedPairs: [AdmissionIdentityPair],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let expectedTabIDs = Set(initialTabs.map(\.id))
                .union(acceptedPairs.map(\.tabID))
            XCTAssertEqual(tabs.count, expectedTabIDs.count, file: file, line: line)
            XCTAssertEqual(Set(tabs.map(\.id)), expectedTabIDs, file: file, line: line)

            let initialPairs = initialTabs.compactMap { tab in
                tab.activeAgentSessionID.map {
                    AdmissionIdentityPair(tabID: tab.id, sessionID: $0)
                }
            }
            let expectedPairs = Set(initialPairs + acceptedPairs)
            let actualPairs = tabs.compactMap { tab in
                tab.activeAgentSessionID.map {
                    AdmissionIdentityPair(tabID: tab.id, sessionID: $0)
                }
            }
            XCTAssertEqual(actualPairs.count, expectedPairs.count, file: file, line: line)
            XCTAssertEqual(Set(actualPairs), expectedPairs, file: file, line: line)
        }

        /// Polls `condition` as a bounded test step. The bound covers the whole poll, so a condition
        /// evaluation that never returns fails the step too.
        private func waitUntil(
            _ description: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            condition: @escaping @MainActor () async -> Bool
        ) async throws {
            try await cleanup.step("waiting for \(description)", file: file, line: line) {
                while await !condition() {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
        }

        /// Waits for `producer` to enter `gate`. A producer that fails before entering surfaces its
        /// own error at once, and one that succeeds without entering fails as an unexpected completion,
        /// so an admission that failed early is reported as that failure, not as a gate never reached.
        private func waitUntil<T, Failure: Error>(
            _ producerName: String,
            enters gate: AdmissionHandoffGate,
            producer: Task<T, Failure>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            var completion: Result<T, Failure>?
            // Awaiting a task's result can't be cancelled, so this observer lives until the producer
            // finishes; cleanup cancels and joins the producer.
            Task { completion = await producer.result }
            try await cleanup.step(
                "waiting for \(producerName) to enter \(gate.name)",
                file: file,
                line: line
            ) {
                while await !gate.hasEntered() {
                    switch completion {
                    case let .failure(error)?:
                        throw error
                    case .success?:
                        throw AdmissionTestError.unexpectedCompletion(
                            "\(producerName) finished without entering \(gate.name)"
                        )
                    case nil:
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                }
            }
        }

        /// Joins `task`, bounded, and requires it to end in `CancellationError`. Any other error,
        /// including a timed-out join, propagates.
        private func assertCancelled(
            _ task: Task<some Any, some Error>,
            _ step: String,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            do {
                _ = try await startupTestTaskResult(task, step, file: file, line: line)
                XCTFail(message, file: file, line: line)
            } catch let error as StartupTestStepError where error.underlying is CancellationError {}
        }

        /// Cancels `tasks` and joins them, bounded, returning each one's error so a failing test can
        /// report what its producers saw. Callers release their holds first.
        private func cancelAndCollectErrors(
            _ tasks: [Task<Value, Error>],
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> [String] {
            tasks.forEach { $0.cancel() }
            do {
                return try await startupTestAwaitResult(
                    "joining the starts cancelled after a failure",
                    file: file,
                    line: line
                ) {
                    var errors: [String] = []
                    for task in tasks {
                        if case let .failure(error) = await task.result {
                            errors.append(String(describing: error))
                        }
                    }
                    return errors
                }
            } catch {
                return [String(describing: error)]
            }
        }

        /// A gate opened by this test's cleanup before anything is joined, so a failed test never
        /// leaves a production hook parked on it.
        private func makeSaveGate(_ name: String) -> AdmissionSaveGate {
            let gate = AdmissionSaveGate(name)
            cleanup.onRelease { await gate.open() }
            return gate
        }

        private func makeHandoffGate(_ name: String) -> AdmissionHandoffGate {
            let gate = AdmissionHandoffGate(name)
            cleanup.onRelease { await gate.open() }
            return gate
        }

        private func makePersistentWorkspaceFixture(
            root: URL
        ) -> (manager: WorkspaceManagerViewModel, workspace: WorkspaceModel) {
            let fixture = makeManagerFixture(
                coordinator: WorkspaceAgentAdmissionCoordinator()
            )
            let tab = ComposeTabState(name: "Admission")
            let workspace = WorkspaceModel(
                name: "Admission",
                repoPaths: [],
                customStoragePath: root,
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
            fixture.manager.workspaces = [workspace]
            fixture.manager.activeWorkspace = workspace
            fixture.prompt.loadComposeTabsFromWorkspace(workspace)
            return (fixture.manager, workspace)
        }

        private func makeManagerFixture(
            coordinator: WorkspaceAgentAdmissionCoordinator,
            domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient? = nil
        ) -> (
            manager: WorkspaceManagerViewModel,
            prompt: PromptViewModel
        ) {
            let fileManager = WorkspaceFilesViewModel()
            let keyManager = KeyManager(
                secureService: SecureKeysService(
                    secureStorage: TestSecureStorageBackend()
                )
            )
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: fileManager,
                apiSettingsViewModel: apiSettings,
                windowID: -882,
                settingsManager: WindowSettingsManager(windowID: -882)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: prompt,
                domainWorkspaceAuthorityClient: domainWorkspaceAuthorityClient,
                workspaceAgentAdmissionCoordinator: coordinator,
                performInitialWorkspaceActivation: false
            )
            return (manager, prompt)
        }

        private func makeTemporaryDirectory(named name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConcurrentSameWorkspaceAgentRunAdmissionTests-\(name)-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        }

        private func makeRestoreEntry(workspaceID: UUID, workspaceName: String? = nil) -> WindowSessionEntry {
            WindowSessionEntry(
                windowKind: .standard,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                isSystemWorkspace: false,
                isEphemeral: false,
                primaryRepoPath: nil,
                lastFocused: true,
                workspaceInstanceNumber: nil
            )
        }
    }

    @MainActor
    private struct DurableAdmissionWindow {
        let window: WindowState
        let runtime: MCPDomainRuntime
        let authorityRoot: URL
        let workspaceID: UUID
        let workspaceFileURL: URL
    }

    @MainActor
    private final class DistinctDurableAdmissionFixture {
        let first: DurableAdmissionWindow
        let second: DurableAdmissionWindow
        private let cleanup: AdmissionTestCleanup

        private init(
            first: DurableAdmissionWindow,
            second: DurableAdmissionWindow,
            cleanup: AdmissionTestCleanup
        ) {
            self.first = first
            self.second = second
            self.cleanup = cleanup
        }

        /// Registers each runtime, window, and the storage override with `cleanup` as soon as it
        /// exists, so a setup step that fails or times out still leaves them to be undone.
        static func make(cleanup: AdmissionTestCleanup) async throws -> DistinctDurableAdmissionFixture {
            let container = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConcurrentSameWorkspaceAgentRunAdmissionTests-Distinct-\(UUID().uuidString)",
                isDirectory: true
            )
            let authorityRoot = container.appendingPathComponent("state", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: true)
            } catch {
                try? FileManager.default.removeItem(at: container)
                throw error
            }
            let storageOverride = AdmissionWorkspaceStorageOverride(authorityRoot: authorityRoot)
            cleanup.onRestore { storageOverride.restore() }
            let firstAuthorityRoot = authorityRoot.appendingPathComponent("authority-A", isDirectory: true)
            let secondAuthorityRoot = authorityRoot.appendingPathComponent("authority-B", isDirectory: true)
            let firstRuntime = makeRuntime(authorityRoot: firstAuthorityRoot, label: "A", cleanup: cleanup)
            let secondRuntime = makeRuntime(authorityRoot: secondAuthorityRoot, label: "B", cleanup: cleanup)
            try await cleanup.step("starting the workspace A runtime") {
                try await firstRuntime.start()
            }
            try await cleanup.step("starting the workspace B runtime") {
                try await secondRuntime.start()
            }
            let firstWindow = makeAdmissionWindow(runtime: firstRuntime, cleanup: cleanup)
            let secondWindow = makeAdmissionWindow(runtime: secondRuntime, cleanup: cleanup)
            try await cleanup.step("workspace A window initialization") {
                await firstWindow.workspaceManager.awaitInitialized()
            }
            try await cleanup.step("workspace B window initialization") {
                await secondWindow.workspaceManager.awaitInitialized()
            }
            let first = try await makeDurableWindow(
                firstWindow,
                runtime: firstRuntime,
                authorityRoot: firstAuthorityRoot,
                label: "A",
                cleanup: cleanup
            )
            let second = try await makeDurableWindow(
                secondWindow,
                runtime: secondRuntime,
                authorityRoot: secondAuthorityRoot,
                label: "B",
                cleanup: cleanup
            )
            return DistinctDurableAdmissionFixture(first: first, second: second, cleanup: cleanup)
        }

        func withFreshRuntime<T>(
            for context: DurableAdmissionWindow,
            generation: UInt64,
            operation: (MCPDomainRuntime) async throws -> T
        ) async throws -> T {
            let restarted = MCPDomainRuntime(
                configuration: .init(
                    mode: .app,
                    profileIdentifier: "distinct-workspace-admission",
                    storageDirectory: context.authorityRoot,
                    eventDirectory: context.authorityRoot.appendingPathComponent("events-restart", isDirectory: true),
                    temporaryDirectory: context.authorityRoot.appendingPathComponent("tmp-restart", isDirectory: true),
                    externalReloadInterval: nil
                ),
                runtimeID: UUID(),
                lifecycleGeneration: generation
            )
            return try await withStartedRuntime(restarted, generation: generation, cleanup: cleanup, operation)
        }

        func closeWindowsAndRuntime() async throws {
            try await cleanup.step("closing both windows and runtimes before the restart check") {
                await self.cleanup.close(self.second.window)
                await self.cleanup.close(self.first.window)
                await self.cleanup.shutDown(self.second.runtime)
                await self.cleanup.shutDown(self.first.runtime)
            }
        }

        private static func makeRuntime(
            authorityRoot: URL,
            label: String,
            cleanup: AdmissionTestCleanup
        ) -> MCPDomainRuntime {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "distinct-workspace-admission",
                storageDirectory: authorityRoot,
                eventDirectory: authorityRoot.appendingPathComponent("events-\(label)", isDirectory: true),
                temporaryDirectory: authorityRoot.appendingPathComponent("tmp-\(label)", isDirectory: true),
                externalReloadInterval: nil
            ))
            cleanup.onClose { await cleanup.shutDown(runtime) }
            return runtime
        }

        private static func makeDurableWindow(
            _ window: WindowState,
            runtime: MCPDomainRuntime,
            authorityRoot: URL,
            label: String,
            cleanup: AdmissionTestCleanup
        ) async throws -> DurableAdmissionWindow {
            let originalTab = ComposeTabState(name: "Distinct durable foreground \(label)")
            let workspace = WorkspaceModel(
                name: "Distinct durable admission \(label) \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                composeTabs: [originalTab],
                activeComposeTabID: originalTab.id
            )
            let workspaceFileURL = window.workspaceManager.workspaceFileURL(for: workspace)
            try await cleanup.step("committing workspace \(label)") {
                try await createCommittedWorkspace(
                    workspace,
                    authority: DomainWorkspaceAuthorityClient(
                        store: runtime.workspaceStore,
                        windowID: window.windowID
                    ),
                    fileURL: workspaceFileURL
                )
            }
            // A sibling window can publish a catalog projection while this synthetic workspace is
            // being created, so establish the local projection from the workspace just committed.
            if !window.workspaceManager.workspaces.contains(where: { $0.id == workspace.id }) {
                window.workspaceManager.workspaces.append(workspace)
            }
            let storedWorkspace = try XCTUnwrap(
                window.workspaceManager.workspaces.first { $0.id == workspace.id }
            )
            try await cleanup.step("activating workspace \(label)") {
                try await activateDurableWorkspace(
                    storedWorkspace,
                    in: window,
                    reason: "distinctWorkspaceAdmissionAcceptance"
                )
            }
            _ = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: workspaceFileURL,
                scheduleNormalizationWriteback: false
            )
            return DurableAdmissionWindow(
                window: window,
                runtime: runtime,
                authorityRoot: authorityRoot,
                workspaceID: workspace.id,
                workspaceFileURL: workspaceFileURL
            )
        }
    }

    @MainActor
    private final class DurableAgentAdmissionFixture {
        let authorityRoot: URL
        let runtime: MCPDomainRuntime
        let window: WindowState
        let workspaceID: UUID
        let workspaceFileURL: URL
        private let cleanup: AdmissionTestCleanup
        private var peerWindows: [WindowState] = []

        private init(
            authorityRoot: URL,
            runtime: MCPDomainRuntime,
            window: WindowState,
            workspaceID: UUID,
            workspaceFileURL: URL,
            cleanup: AdmissionTestCleanup
        ) {
            self.authorityRoot = authorityRoot
            self.runtime = runtime
            self.window = window
            self.workspaceID = workspaceID
            self.workspaceFileURL = workspaceFileURL
            self.cleanup = cleanup
        }

        /// Registers the runtime, the window, and the storage override with `cleanup` as soon as
        /// each exists, so a setup step that fails or times out still leaves them to be undone.
        static func make(cleanup: AdmissionTestCleanup) async throws -> DurableAgentAdmissionFixture {
            let container = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConcurrentSameWorkspaceAgentRunAdmissionTests-Durable-\(UUID().uuidString)",
                isDirectory: true
            )
            let (authorityRoot, runtime) = try makeIsolatedRuntime(
                container: container,
                profileIdentifier: "same-workspace-admission",
                cleanup: cleanup
            )
            try await cleanup.step("starting the durable fixture runtime") {
                try await runtime.start()
            }
            let window = makeAdmissionWindow(runtime: runtime, cleanup: cleanup)
            try await cleanup.step("durable fixture window initialization") {
                await window.workspaceManager.awaitInitialized()
            }
            let originalTab = ComposeTabState(name: "Durable foreground")
            let workspace = WorkspaceModel(
                name: "Concurrent durable admission \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                composeTabs: [originalTab],
                activeComposeTabID: originalTab.id
            )
            let workspaceFileURL = window.workspaceManager.workspaceFileURL(for: workspace)
            try await cleanup.step("committing the durable fixture workspace") {
                try await createCommittedWorkspace(
                    workspace,
                    authority: DomainWorkspaceAuthorityClient(
                        store: runtime.workspaceStore,
                        windowID: window.windowID
                    ),
                    fileURL: workspaceFileURL
                )
            }
            // Catalog projection and fixture creation are independent publications; the test
            // window must expose the workspace that the authority has already committed.
            if !window.workspaceManager.workspaces.contains(where: { $0.id == workspace.id }) {
                window.workspaceManager.workspaces.append(workspace)
            }
            let storedWorkspace = try XCTUnwrap(
                window.workspaceManager.workspaces.first { $0.id == workspace.id }
            )
            try await cleanup.step("activating the durable fixture workspace") {
                try await activateDurableWorkspace(
                    storedWorkspace,
                    in: window,
                    reason: "sameWorkspaceAdmissionAcceptance"
                )
            }
            let canonicalSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            guard canonical.health == .writable else {
                throw AdmissionTestError.fixtureSetup("canonical workspace was not writable")
            }
            return DurableAgentAdmissionFixture(
                authorityRoot: authorityRoot,
                runtime: runtime,
                window: window,
                workspaceID: workspace.id,
                workspaceFileURL: workspaceFileURL,
                cleanup: cleanup
            )
        }

        private func makeFreshRuntime(generation: UInt64) -> MCPDomainRuntime {
            MCPDomainRuntime(
                configuration: .init(
                    mode: .app,
                    profileIdentifier: "same-workspace-admission",
                    storageDirectory: authorityRoot,
                    eventDirectory: authorityRoot.appendingPathComponent("events-restart", isDirectory: true),
                    temporaryDirectory: authorityRoot.appendingPathComponent("tmp-restart", isDirectory: true),
                    externalReloadInterval: nil
                ),
                runtimeID: UUID(),
                lifecycleGeneration: generation
            )
        }

        func makePeerWindow() async throws -> WindowState {
            let peer = makeAdmissionWindow(runtime: runtime, cleanup: cleanup)
            peerWindows.append(peer)
            try await cleanup.step("peer window initialization") {
                await peer.workspaceManager.awaitInitialized()
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while peer.workspaceManager.workspace(withID: workspaceID) == nil {
                guard clock.now < deadline else {
                    throw AdmissionTestError.timedOut("peer window workspace projection")
                }
                await Task.yield()
            }
            let workspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: workspaceID))
            try await cleanup.step("activating the workspace in the peer window") {
                try await activateDurableWorkspace(
                    workspace,
                    in: peer,
                    reason: "sameWorkspacePeerAdmissionAcceptance"
                )
            }
            return peer
        }

        func withFreshRuntime<T>(
            generation: UInt64,
            operation: (MCPDomainRuntime) async throws -> T
        ) async throws -> T {
            try await withStartedRuntime(
                makeFreshRuntime(generation: generation),
                generation: generation,
                cleanup: cleanup,
                operation
            )
        }

        func closeWindowAndRuntime() async throws {
            try await cleanup.step("closing the fixture windows and runtime before the restart check") {
                for peer in self.peerWindows.reversed() {
                    await self.cleanup.close(peer)
                }
                await self.cleanup.close(self.window)
                await self.cleanup.shutDown(self.runtime)
            }
        }
    }

    /// Builds a runtime whose storage directory is `container/state`, without starting it, and points
    /// workspace storage at `container/state/Workspaces`. Both are registered with `cleanup` before
    /// anything else can fail: the runtime shuts down at cleanup, and only after that are the storage
    /// setting restored and `container` deleted. Callers start the runtime themselves.
    @MainActor
    private func makeIsolatedRuntime(
        container: URL,
        profileIdentifier: String,
        cleanup: AdmissionTestCleanup
    ) throws -> (authorityRoot: URL, runtime: MCPDomainRuntime) {
        let authorityRoot = container.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: true)
        let storageOverride = AdmissionWorkspaceStorageOverride(authorityRoot: authorityRoot)
        cleanup.onRestore { storageOverride.restore() }
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: profileIdentifier,
            storageDirectory: authorityRoot,
            eventDirectory: authorityRoot.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: authorityRoot.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        cleanup.onClose { await cleanup.shutDown(runtime) }
        return (authorityRoot, runtime)
    }

    /// Makes and registers a window on `runtime` without auto-starting MCP, and closes it at cleanup.
    @MainActor
    private func makeAdmissionWindow(runtime: MCPDomainRuntime, cleanup: AdmissionTestCleanup) -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState(domainRuntime: runtime)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        cleanup.onClose { await cleanup.close(window) }
        return window
    }

    /// Starts `runtime`, runs `operation` against it, and shuts it down, bounding both lifecycle
    /// steps. The shutdown is registered with `cleanup` first, so an operation that throws, or a step
    /// that times out, still leaves the runtime to be shut down before storage is restored.
    @MainActor
    private func withStartedRuntime<T>(
        _ runtime: MCPDomainRuntime,
        generation: UInt64,
        cleanup: AdmissionTestCleanup,
        _ operation: (MCPDomainRuntime) async throws -> T
    ) async throws -> T {
        cleanup.onClose { await cleanup.shutDown(runtime) }
        try await cleanup.step("starting the restarted runtime (generation \(generation))") {
            try await runtime.start()
        }
        let result = try await operation(runtime)
        try await cleanup.step("shutting down the restarted runtime (generation \(generation))") {
            await cleanup.shutDown(runtime)
        }
        return result
    }

    @MainActor
    private func createCommittedWorkspace(
        _ workspace: WorkspaceModel,
        authority: DomainWorkspaceAuthorityClient,
        fileURL: URL
    ) async throws {
        let creation = try await authority.create(workspace, fileURL: fileURL)
        guard creation.disposition == .applied else {
            throw AdmissionTestError.fixtureSetup("explicit workspace creation did not commit")
        }
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: fileURL)
    }

    @MainActor
    private func activateDurableWorkspace(
        _ workspace: WorkspaceModel,
        in window: WindowState,
        reason: String
    ) async throws {
        let manager = window.workspaceManager
        if manager.activeWorkspaceID == workspace.id {
            // Initial authority projection can select the fixture target before setup requests it.
            // Reset through the system workspace so every test exercises the complete switch path.
            let systemWorkspace = try XCTUnwrap(
                manager.workspaces.first { $0.isSystemWorkspace && $0.id != workspace.id }
            )
            let resetResult = await manager.switchWorkspace(
                to: systemWorkspace,
                saveState: false,
                reason: "\(reason).reset"
            )
            guard resetResult.didSwitch else {
                throw AdmissionTestError.fixtureSetup(
                    resetResult.message ?? "system workspace reset did not complete"
                )
            }
        }

        let switchResult = await manager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: reason
        )
        guard switchResult.didSwitch else {
            throw AdmissionTestError.fixtureSetup(
                switchResult.message ?? "durable workspace did not become active"
            )
        }
        let activeWorkspace = try XCTUnwrap(manager.activeWorkspace)
        guard activeWorkspace.id == workspace.id else {
            throw AdmissionTestError.fixtureSetup("durable workspace activation selected the wrong target")
        }
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        // Finish the scheduled chat writes before tests record their workspace baseline.
        await window.oracleViewModel.loadSessionsFromWorkspace()
    }

    private final class AdmissionWorkspaceStorageOverride {
        private let defaults: UserDefaults
        private let priorStoragePath: String?
        private let cleanupRoot: URL
        private var isRestored = false

        init(authorityRoot: URL, defaults: UserDefaults = .standard) {
            self.defaults = defaults
            priorStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            cleanupRoot = authorityRoot.deletingLastPathComponent()
            defaults.set(
                authorityRoot.appendingPathComponent("Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
        }

        func restore() {
            guard !isRestored else { return }
            isRestored = true
            if let priorStoragePath {
                defaults.set(priorStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                defaults.removeObject(forKey: "GlobalCustomStorageURL")
            }
            try? FileManager.default.removeItem(at: cleanupRoot)
        }

        deinit {
            restore()
        }
    }

    private struct AdmissionIdentityPair: Hashable {
        let tabID: UUID
        let sessionID: UUID
    }

    private extension [ComposeTabState] {
        func containsIdentity(_ pair: AdmissionIdentityPair) -> Bool {
            contains { tab in
                tab.id == pair.tabID && tab.activeAgentSessionID == pair.sessionID
            }
        }
    }

    private final class AdmissionLifecycleEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentSessionLifecycleAuthority.Event] = []

        func record(_ event: AgentSessionLifecycleAuthority.Event) {
            lock.withLock { events.append(event) }
        }

        func snapshot() -> [AgentSessionLifecycleAuthority.Event] {
            lock.withLock { events }
        }
    }

    private final class ProvisionalAdmissionIdentityRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: AdmissionIdentityPair?

        func record(_ pair: AdmissionIdentityPair) {
            lock.withLock {
                if captured == nil {
                    captured = pair
                }
            }
        }

        func value() -> AdmissionIdentityPair? {
            lock.withLock { captured }
        }
    }

    private actor AdmissionProviderRecorder: AdmissionParking {
        struct Observation {
            let tabID: UUID
            let sessionID: UUID
            let lifecycleIdentity: AgentSessionLifecycleAuthority.Identity?
        }

        var parkedCallers = AdmissionParkedCallers()
        private let expectedCount: Int
        private let blockProviders: Bool
        private var values: [Observation] = []
        private var counts: [AdmissionIdentityPair: Int] = [:]
        private var isReleased = false

        init(expectedCount: Int, blockProviders: Bool = true) {
            self.expectedCount = expectedCount
            self.blockProviders = blockProviders
        }

        func recordAndWait(_ observation: Observation) async throws {
            let pair = AdmissionIdentityPair(tabID: observation.tabID, sessionID: observation.sessionID)
            counts[pair, default: 0] += 1
            guard counts[pair] == 1 else {
                throw AdmissionTestError.duplicateProviderDispatch(pair)
            }
            guard values.count < expectedCount else {
                throw AdmissionTestError.excessProviderDispatch(expectedCount)
            }
            values.append(observation)
            guard blockProviders, !isReleased else { return }
            switch await park(seconds: admissionHoldSeconds) {
            case .released:
                return
            case .timedOut:
                let message = "provider dispatch was held for \(admissionHoldSeconds) s without releaseAll()"
                XCTFail(message)
                throw AdmissionTestError.timedOut(message)
            case .cancelled:
                throw CancellationError()
            }
        }

        func count() -> Int {
            values.count
        }

        func observations() -> [Observation] {
            values
        }

        func attemptCounts() -> [AdmissionIdentityPair: Int] {
            counts
        }

        func releaseAll() {
            isReleased = true
            parkedCallers.resumeAll(with: .released)
        }
    }

    /// Holds only the first caller to enter, until `open()` or its bound; later callers pass
    /// straight through.
    private actor AdmissionSaveGate: AdmissionParking {
        let name: String
        var parkedCallers = AdmissionParkedCallers()
        private var didEnter = false
        private var isOpen = false

        init(_ name: String) {
            self.name = name
        }

        func enterFirstAndWait() async {
            guard !didEnter else { return }
            didEnter = true
            guard !isOpen else { return }
            await holdHook(on: name)
        }

        func hasEntered() -> Bool {
            didEnter
        }

        func open() {
            isOpen = true
            parkedCallers.resumeAll(with: .released)
        }
    }

    /// Reports one session that needs confirmation, so a manual switch waits at its dialog.
    @MainActor
    private final class ConfirmationRequiringSwitchSessionProvider: WorkspaceSwitchSessionProvider {
        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            [WorkspaceSwitchSessionItem(
                id: "admission-test",
                count: 1,
                singularLabel: "test session",
                pluralLabel: "test sessions"
            )]
        }

        func cancelSwitchSessions() async {}
    }

    private enum AdmissionTestError: Error {
        case expected
        case queuePhaseSentinel(UUID)
        case timedOut(String)
        case fixtureSetup(String)
        case unexpectedCompletion(String)
        case duplicateProviderDispatch(AdmissionIdentityPair)
        case excessProviderDispatch(Int)
    }

    private actor AdmissionStartTaskTerminationProbe {
        private var count = 0

        func recordTermination() {
            count += 1
        }

        func terminationCount() -> Int {
            count
        }
    }

    private actor AdmissionOrderRecorder {
        private var recorded: [UUID] = []

        func append(_ id: UUID) {
            recorded.append(id)
        }

        func values() -> [UUID] {
            recorded
        }
    }

    /// Holds every caller that enters until `open()` or its bound, and records that one entered.
    /// Opening records no entry; a caller that enters after `open()` records one and passes through.
    private actor AdmissionHandoffGate: AdmissionParking {
        let name: String
        var parkedCallers = AdmissionParkedCallers()
        private var entered = false
        private var isOpen = false

        init(_ name: String) {
            self.name = name
        }

        func enterAndWait() async {
            entered = true
            guard !isOpen else { return }
            await holdHook(on: name)
        }

        func hasEntered() -> Bool {
            entered
        }

        func open() {
            isOpen = true
            parkedCallers.resumeAll(with: .released)
        }
    }

    /// Serializes the suite's tests within one process, in arrival order.
    private actor AdmissionTestSuiteGate: AdmissionParking {
        static let shared = AdmissionTestSuiteGate()

        var parkedCallers = AdmissionParkedCallers()
        private var isHeld = false

        /// A timed-out or cancelled acquirer leaves the queue without the gate, so its test's
        /// `tearDown` has nothing to release.
        func acquire() async throws {
            guard isHeld else {
                isHeld = true
                return
            }
            switch await park(seconds: admissionSuiteGateSeconds) {
            case .released:
                return
            case .timedOut:
                throw AdmissionTestError.timedOut(
                    "acquiring the admission suite gate: an earlier test held it for \(admissionSuiteGateSeconds) s"
                )
            case .cancelled:
                throw CancellationError()
            }
        }

        /// Hands the gate to the earliest waiter, or frees it when nobody waits.
        func release() {
            if !parkedCallers.resumeFirst(with: .released) {
                isHeld = false
            }
        }
    }

    /// Failure guards that bound a hang, set far above the suite's observed run time.
    private let admissionHoldSeconds: TimeInterval = 30
    private let admissionSuiteGateSeconds: TimeInterval = 60
    private let admissionCleanupSeconds: TimeInterval = 30

    /// How a caller parked on an admission gate was let go.
    private enum AdmissionParkOutcome: Sendable {
        case released
        case timedOut
        case cancelled
    }

    /// The callers parked on one admission gate, in arrival order. A caller is removed before it is
    /// resumed, so whichever of release, its timeout, or its cancellation reaches it first wins and
    /// the others find nothing to resume.
    private struct AdmissionParkedCallers {
        private struct Caller {
            let id: UUID
            let continuation: CheckedContinuation<AdmissionParkOutcome, Never>
            let timeout: Task<Void, Never>
        }

        private var callers: [Caller] = []

        mutating func add(
            id: UUID,
            continuation: CheckedContinuation<AdmissionParkOutcome, Never>,
            timeout: Task<Void, Never>
        ) {
            callers.append(Caller(id: id, continuation: continuation, timeout: timeout))
        }

        mutating func resume(_ id: UUID, with outcome: AdmissionParkOutcome) {
            guard let index = callers.firstIndex(where: { $0.id == id }) else { return }
            Self.resume(callers.remove(at: index), with: outcome)
        }

        /// Resumes the earliest caller and reports whether there was one.
        mutating func resumeFirst(with outcome: AdmissionParkOutcome) -> Bool {
            guard !callers.isEmpty else { return false }
            Self.resume(callers.removeFirst(), with: outcome)
            return true
        }

        mutating func resumeAll(with outcome: AdmissionParkOutcome) {
            let resumed = callers
            callers.removeAll()
            resumed.forEach { Self.resume($0, with: outcome) }
        }

        private static func resume(_ caller: Caller, with outcome: AdmissionParkOutcome) {
            caller.timeout.cancel()
            caller.continuation.resume(returning: outcome)
        }
    }

    /// An actor whose callers park in `parkedCallers`. Keeping the bookkeeping inside each gate's
    /// own isolation is what lets a gate check its state and park a caller without an `open()`
    /// slipping in between.
    private protocol AdmissionParking: Actor {
        var parkedCallers: AdmissionParkedCallers { get set }
    }

    extension AdmissionParking {
        /// Parks the caller until it is released, `seconds` pass, or its task is cancelled. A caller
        /// already cancelled when it arrives doesn't park.
        func park(seconds: TimeInterval) async -> AdmissionParkOutcome {
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    let timeout = Task {
                        do {
                            try await Task.sleep(for: .seconds(seconds))
                        } catch {
                            return
                        }
                        self.resumeParked(id, with: .timedOut)
                    }
                    parkedCallers.add(id: id, continuation: continuation, timeout: timeout)
                }
            } onCancel: {
                Task { await self.resumeParked(id, with: .cancelled) }
            }
        }

        func resumeParked(_ id: UUID, with outcome: AdmissionParkOutcome) {
            parkedCallers.resume(id, with: outcome)
        }

        /// Holds a production hook, which can't throw, until the gate opens. A timeout records a
        /// failure naming the gate and then lets the hook go, so the held work and the test's cleanup
        /// can finish; the recorded failure keeps that release from passing as an `open()`.
        func holdHook(on gateName: String) async {
            if await park(seconds: admissionHoldSeconds) == .timedOut {
                XCTFail("\(gateName) held its caller for \(admissionHoldSeconds) s without being opened")
            }
        }
    }

    /// What one test must undo, in the order that keeps cleanup bounded and safe. Holds are released
    /// first so parked work can finish. Test tasks and steps are then cancelled; within one bound, test
    /// tasks are joined, windows and runtimes closed newest first, and any step still running joined
    /// last, since closing is often what lets a stuck setup step finish. Storage overrides are restored
    /// last, and only when that bound was met: restoring the global storage setting under a runtime
    /// that may still be writing would send its writes somewhere else.
    @MainActor
    private final class AdmissionTestCleanup {
        /// Restores skipped after a cleanup timeout, kept for the rest of the process so the storage
        /// override's deinit can't restore under a runtime that may still be writing.
        private static var restoresLeftInPlace: [@MainActor () -> Void] = []

        private var releases: [@MainActor () async -> Void] = []
        private var cancellations: [() -> Void] = []
        private var joins: [@MainActor () async -> Void] = []
        private var closes: [@MainActor () async -> Void] = []
        private var restores: [@MainActor () -> Void] = []
        private var stepJoins: [@MainActor () async -> Void] = []
        /// Each window close or runtime shutdown, kept with its owner for as long as the registry
        /// lives: a step that timed out and resumes later still finds its close done, and a newer
        /// object can't reuse an identifier here.
        private var finishing: [ObjectIdentifier: (owner: AnyObject, task: Task<Void, Never>)] = [:]

        /// Undoes a hold, such as opening a gate or removing a hook, before anything is joined.
        func onRelease(_ release: @escaping @MainActor () async -> Void) {
            releases.append(release)
        }

        func onCancelAndJoin(_ task: Task<some Any, some Error>) {
            cancellations.append { task.cancel() }
            joins.append { _ = await task.result }
        }

        func onClose(_ close: @escaping @MainActor () async -> Void) {
            closes.append(close)
        }

        func onRestore(_ restore: @escaping @MainActor () -> Void) {
            restores.append(restore)
        }

        /// Runs `operation` as a labelled test step bounded like `startupTestAwaitResult`, in a task
        /// that stays registered here: a step that timed out may still be writing, so cleanup has to
        /// cancel and join it before any storage override is restored.
        func step<T: Sendable>(
            _ name: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ operation: @escaping @MainActor () async throws -> T
        ) async throws -> T {
            let task = Task { @MainActor in try await operation() }
            cancellations.append { task.cancel() }
            stepJoins.append { _ = await task.result }
            return try await startupTestTaskResult(task, name, file: file, line: line)
        }

        /// Closes and unregisters `window` once. A later call waits for that same close, so a close
        /// that a timed-out test step left running still has to finish before storage is restored.
        func close(_ window: WindowState) async {
            await once(for: window) {
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
        }

        /// Shuts `runtime` down once; a later call waits for that same shutdown.
        func shutDown(_ runtime: MCPDomainRuntime) async {
            await once(for: runtime) {
                _ = await runtime.shutdown()
            }
        }

        private func once(for owner: AnyObject, _ operation: @escaping @MainActor () async -> Void) async {
            let key = ObjectIdentifier(owner)
            let task = finishing[key]?.task ?? Task { await operation() }
            finishing[key] = (owner, task)
            await task.value
        }

        /// Runs and forgets everything registered so far, so a test can also clean up between
        /// subcases.
        func run(_ step: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            let releases = releases
            let cancellations = cancellations
            let joins = joins
            let closes = closes
            let restores = restores
            let stepJoins = stepJoins
            self.releases = []
            self.cancellations = []
            self.joins = []
            self.closes = []
            self.restores = []
            self.stepJoins = []

            for release in releases {
                await release()
            }
            cancellations.forEach { $0() }
            do {
                try await startupTestAwaitResult(
                    "\(step): joining test tasks, closing windows and runtimes, and joining unfinished steps "
                        + "(the storage override and any window not yet closed are left in place)",
                    seconds: admissionCleanupSeconds,
                    file: file,
                    line: line
                ) {
                    for join in joins {
                        await join()
                    }
                    for close in closes.reversed() {
                        await close()
                    }
                    for join in stepJoins {
                        await join()
                    }
                }
            } catch {
                Self.restoresLeftInPlace.append(contentsOf: restores)
                throw error
            }
            for restore in restores.reversed() {
                restore()
            }
        }
    }
#endif
