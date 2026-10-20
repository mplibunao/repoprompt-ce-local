@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceDuplicateCleanupTests: XCTestCase {
        private var fixture: RuntimeBackedWorkspaceFixture!
        private var agentWorkspaceRoot: URL!
        private var chatWorkspaceRoot: URL!

        private var storageRoot: URL {
            fixture.storageRoot
        }

        override func setUp() async throws {
            try await super.setUp()
            fixture = try await RuntimeBackedWorkspaceFixture(name: "WorkspaceDuplicateCleanupTests")
            agentWorkspaceRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            chatWorkspaceRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentWorkspaceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentWorkspaceRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)
        }

        override func tearDown() async throws {
            await fixture.tearDown()
            fixture = nil
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            try await super.tearDown()
        }

        func testProjectionKeepsPendingInactiveSelectionUntilItsOwnDocumentChanges() async throws {
            let inactiveTab = ComposeTabState(
                name: "Inactive",
                selection: StoredSelection(selectedPaths: ["/tmp/old.swift"])
            )
            let activeTab = ComposeTabState(name: "Active")
            let workspace = WorkspaceModel(
                name: "Selection",
                repoPaths: ["/tmp/pending-inactive-selection-root"],
                composeTabs: [activeTab, inactiveTab],
                activeComposeTabID: activeTab.id
            )
            try fixture.writeWorkspace(workspace)
            try fixture.writeLegacyIndex([workspace])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "inactive-selection")
            let peer = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -791)
            let (manager, bridge) = await fixture.makeProjectedManager(windowID: -790, runtime: runtime)
            if manager.activeWorkspaceID != workspace.id {
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: workspace.id, saveState: false)
                XCTAssertTrue(switched.didSwitch)
            }

            let identity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: inactiveTab.id)
            let expectedSelection = StoredSelection(selectedPaths: ["/tmp/new.swift"])
            XCTAssertTrue(manager.editHeldTab(identity) { tab in
                tab.selection = expectedSelection
                return true
            })

            let unrelated = WorkspaceModel(name: "Other", repoPaths: ["/tmp/other"])
            let outcome = try await peer.create(unrelated, fileURL: fixture.workspaceFileURL(for: unrelated))
            XCTAssertEqual(outcome.disposition, .applied)
            let unrelatedSequence = await runtime.workspaceStore.snapshot().publicationSequence
            let unrelatedProjected = await bridge.waitUntilProjected(through: unrelatedSequence)
            XCTAssertTrue(unrelatedProjected)
            XCTAssertEqual(manager.contentGateway.shownComposeTab(identity)?.selection, expectedSelection)

            let current = try XCTUnwrap(manager.workspace(withID: workspace.id))
            let savedURL = try await manager.saveWorkspaceToFileAsync(current)
            let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: savedURL))
            XCTAssertEqual(saved.composeTabs.first { $0.id == inactiveTab.id }?.selection, expectedSelection)

            let remoteSelection = StoredSelection(selectedPaths: ["/tmp/remote.swift"])
            var remote = saved
            let tabIndex = try XCTUnwrap(remote.composeTabs.firstIndex { $0.id == inactiveTab.id })
            remote.composeTabs[tabIndex].selection = remoteSelection
            let baselineSnapshot = await peer.canonicalWorkspaceSnapshot(workspace.id)
            let baseline = try XCTUnwrap(baselineSnapshot)
            let remoteOutcome = try await peer.replaceWorking(
                remote,
                fileURL: savedURL,
                expectedWorkspaceRevision: baseline.revisions.workingRevision
            )
            XCTAssertEqual(remoteOutcome.disposition, .applied)
            let remoteSequence = await runtime.workspaceStore.snapshot().publicationSequence
            let remoteProjected = await bridge.waitUntilProjected(through: remoteSequence)
            XCTAssertTrue(remoteProjected)
            XCTAssertEqual(manager.contentGateway.shownComposeTab(identity)?.selection, remoteSelection)
        }

        func testAuthoritativeRetirementSurvivesReloadPreservesSidecarsAndUnhideRestoresDetection() async throws {
            let mergedPromptID = UUID()
            let duplicateTabID = UUID()
            let duplicateAgentSessionID = UUID()
            let duplicateChatSessionID = UUID()
            let canonical = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 200),
                name: "Canonical",
                repoPaths: ["/tmp/shared-workspace-root"],
                lastUsed: Date(timeIntervalSince1970: 200)
            )
            let duplicate = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 100),
                name: "User Hidden Duplicate",
                repoPaths: canonical.repoPaths,
                lastUsed: Date(timeIntervalSince1970: 100),
                selectedMetaPromptIDs: [mergedPromptID],
                isHiddenInMenus: true,
                composeTabs: [
                    ComposeTabState(
                        id: duplicateTabID,
                        name: "Recovered history",
                        activeChatSessionID: duplicateChatSessionID,
                        activeAgentSessionID: duplicateAgentSessionID
                    )
                ],
                activeComposeTabID: duplicateTabID
            )
            try fixture.writeWorkspace(canonical)
            try fixture.writeWorkspace(duplicate)
            try fixture.writeLegacyIndex([canonical, duplicate])

            let chatsDirectory = sidecarWorkspaceDirectory(for: duplicate, root: chatWorkspaceRoot)
                .appendingPathComponent("Chats", isDirectory: true)
            let agentSessionsDirectory = sidecarWorkspaceDirectory(for: duplicate, root: agentWorkspaceRoot)
                .appendingPathComponent("AgentSessions", isDirectory: true)
            let chatSidecarURL = chatsDirectory.appendingPathComponent(
                "ChatSession-\(duplicateChatSessionID.uuidString).json"
            )
            let agentSidecarURL = agentSessionsDirectory.appendingPathComponent(
                "AgentSession-\(duplicateAgentSessionID.uuidString).json"
            )
            try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: agentSessionsDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(ChatSession(
                id: duplicateChatSessionID,
                workspaceID: duplicate.id,
                composeTabID: duplicateTabID,
                name: "Recovered Oracle history",
                messages: [
                    StoredMessage(
                        isUser: false,
                        rawText: "Recovered transcript content",
                        sequenceIndex: 0
                    )
                ]
            )).write(to: chatSidecarURL, options: .atomic)
            try JSONEncoder().encode(AgentSession(
                id: duplicateAgentSessionID,
                workspaceID: duplicate.id,
                composeTabID: duplicateTabID,
                name: "Recovered Agent history",
                itemCount: 7
            )).write(to: agentSidecarURL, options: .atomic)

            let runtime = try await fixture.makeRuntime(profileIdentifier: "workspace-duplicate-retirement")
            let bootstrappedSnapshot = await runtime.workspaceStore.snapshot()
            let bootstrappedWorkspaceIDs = Set(bootstrappedSnapshot.workspaces.map(\.document.workspaceID))
            XCTAssertEqual(bootstrappedWorkspaceIDs, Set([canonical.id, duplicate.id]))
            let authorityClient = DomainWorkspaceAuthorityClient(
                store: runtime.workspaceStore,
                windowID: -781
            )
            let canonicalSnapshot = try XCTUnwrap(bootstrappedSnapshot.workspaces.first {
                $0.document.workspaceID == canonical.id
            })
            let materializeOutcome = try await authorityClient.replaceWorking(
                canonical,
                fileURL: fixture.workspaceFileURL(for: canonical),
                expectedWorkspaceRevision: canonicalSnapshot.revisions.workingRevision
            )
            XCTAssertTrue(
                materializeOutcome.disposition == .applied
                    || materializeOutcome.disposition == .unchanged
                    || materializeOutcome.disposition == .deduplicated
            )

            let manager = fixture.makeManager(
                windowID: -781,
                domainWorkspaceAuthorityClient: authorityClient
            )
            let backupDirectory = storageRoot.appendingPathComponent("cleanup-backups", isDirectory: true)
            manager.setDuplicateCleanupBackupDirectoryForTesting(backupDirectory)
            await manager.awaitInitialized()
            let presentationBridge = DomainWorkspacePresentationBridge(
                workspaceManager: manager,
                client: authorityClient
            )
            presentationBridge.start()
            defer { presentationBridge.stop() }
            let initialProjectionSequence = await (runtime.workspaceStore.snapshot()).publicationSequence
            let projectedInitial = await presentationBridge.waitUntilProjected(through: initialProjectionSequence)
            XCTAssertTrue(projectedInitial)

            let canonicalIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == canonical.id })
            let projectedCanonical = manager.workspaces[canonicalIndex]
            var mismatchedCanonical = projectedCanonical
            mismatchedCanonical.currentPromptText = "Uncommitted cleanup attempt"
            manager.workspaces[canonicalIndex] = mismatchedCanonical
            let authoritySnapshot = await authorityClient.snapshot()
            let canonicalBeforeLocalSave = try XCTUnwrap(authoritySnapshot.workspaces.first {
                $0.document.workspaceID == canonical.id
            })
            // The echo of a working commit the window submitted from its copy.
            let echoOperationID = UUID()
            manager.registerCopySourcedSubmissionForTesting(
                echoOperationID,
                workspaceID: canonical.id,
                digest: canonicalBeforeLocalSave.document.contentDigest
            )
            let suppressedOlderEcho = presentationBridge.suppressSelfEchoForTesting(DomainWorkspaceEvent(
                runtimeID: runtime.identity.runtimeID,
                sequence: authoritySnapshot.publicationSequence,
                catalogRevision: authoritySnapshot.catalogRevision,
                kind: .workingStateCommitted,
                workspaceID: canonical.id,
                contextID: nil,
                operationID: echoOperationID,
                origin: .appPresentation(windowID: -781),
                revisions: canonicalBeforeLocalSave.revisions,
                timestamp: Date(),
                diagnostic: nil
            ))
            XCTAssertTrue(suppressedOlderEcho)
            XCTAssertEqual(
                manager.workspace(withID: canonical.id)?.currentPromptText,
                mismatchedCanonical.currentPromptText,
                "An older accepted self-echo must not overwrite a newer local edit."
            )
            let baselineAfterOlderEcho = manager.debugDomainAuthorityBaseline(for: canonical.id)
            XCTAssertEqual(baselineAfterOlderEcho.revisions, canonicalBeforeLocalSave.revisions)
            XCTAssertEqual(baselineAfterOlderEcho.digest, canonicalBeforeLocalSave.document.contentDigest)

            let projectionClient = DomainWorkspaceAuthorityClient(
                store: runtime.workspaceStore,
                windowID: -790
            )
            let projectionSnapshot = await projectionClient.snapshot()
            let projectionDuplicate = try XCTUnwrap(projectionSnapshot.workspaces.first {
                $0.document.workspaceID == duplicate.id
            })
            var projectionTrigger = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: projectionDuplicate.document.documentBytes,
                fileURL: projectionDuplicate.document.fileURL
            )
            projectionTrigger.currentPromptText = "Unrelated projection trigger"
            let projectionOutcome = try await projectionClient.save(
                projectionTrigger,
                fileURL: projectionDuplicate.document.fileURL,
                expectedWorkspaceRevision: projectionDuplicate.revisions.workingRevision,
                expectedContentDigest: projectionDuplicate.document.contentDigest
            )
            XCTAssertTrue(
                projectionOutcome.disposition == .applied
                    || projectionOutcome.disposition == .unchanged
                    || projectionOutcome.disposition == .deduplicated
            )
            let projectionSequence = await (runtime.workspaceStore.snapshot()).publicationSequence
            let projectedTrigger = await presentationBridge.waitUntilProjected(through: projectionSequence)
            XCTAssertTrue(projectedTrigger)
            XCTAssertEqual(
                manager.workspace(withID: canonical.id)?.currentPromptText,
                mismatchedCanonical.currentPromptText,
                "An unrelated projection must not reapply an older accepted self-echo."
            )

            _ = try await manager.saveWorkspaceToFileAsync(
                mismatchedCanonical,
                preserveDiskRepoPathsIfUnchangedSinceBaseline: false
            )
            let canonicalAfterLocalSave = try await authoritativeWorkspace(canonical.id, in: runtime)
            XCTAssertEqual(
                canonicalAfterLocalSave.currentPromptText,
                mismatchedCanonical.currentPromptText,
                "The preserved local edit must save from the advanced authority baseline."
            )

            // Runtime and the manager bootstrapped both records; now make the retired legacy index
            // stale. Cleanup must re-plan from DomainRuntime rather than making it authoritative.
            try fixture.writeLegacyIndex([canonical])

            XCTAssertEqual(
                manager.duplicateWorkspaceGroups().count,
                1,
                "A user-hidden, unretired workspace must remain detectable as a duplicate."
            )
            if manager.activeWorkspaceID != canonical.id {
                let canonicalSwitch = try await manager.requestWorkspaceSwitch(
                    to: XCTUnwrap(manager.workspace(withID: canonical.id)),
                    saveState: false,
                    reason: "duplicateCleanupTestSetup"
                )
                XCTAssertTrue(canonicalSwitch.didSwitch)
            }
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }

            let cleanup = await manager.consolidateDuplicateWorkspaces()
            XCTAssertEqual(cleanup.groupsDetected, 1)
            XCTAssertEqual(cleanup.groupsConsolidated, 1)
            XCTAssertEqual(cleanup.retiredWorkspaceIDs, [duplicate.id])
            XCTAssertTrue(cleanup.skipped.isEmpty, "Unexpected skips: \(cleanup.skipped)")
            XCTAssertEqual(cleanup.backupURL?.deletingLastPathComponent(), backupDirectory)
            XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(cleanup.backupURL).path))

            let locallyRetired = try XCTUnwrap(manager.workspace(withID: duplicate.id))
            XCTAssertTrue(locallyRetired.isHiddenInMenus)
            XCTAssertEqual(locallyRetired.consolidatedIntoWorkspaceID, canonical.id)
            let staleHideResult = try await manager.setWorkspaceHiddenFromSnapshot(
                duplicate,
                hidden: true
            )
            XCTAssertEqual(staleHideResult.consolidatedIntoWorkspaceID, canonical.id)
            var rejectedStaleOrdinaryUnhide = false
            do {
                _ = try await manager.setWorkspaceHiddenFromSnapshot(
                    duplicate,
                    hidden: false
                )
            } catch {
                rejectedStaleOrdinaryUnhide = true
            }
            XCTAssertTrue(rejectedStaleOrdinaryUnhide)
            XCTAssertEqual(
                manager.workspace(withID: duplicate.id)?.consolidatedIntoWorkspaceID,
                canonical.id
            )
            let staleManager = fixture.makeManager(windowID: -789)
            await staleManager.awaitInitialized()
            let staleSwitch = await staleManager.switchWorkspace(
                to: duplicate,
                saveState: false,
                reason: "staleRetiredRecoveryTest"
            )
            XCTAssertFalse(staleSwitch.didSwitch)
            XCTAssertNotEqual(staleManager.activeWorkspaceID, duplicate.id)
            XCTAssertEqual(
                staleManager.workspace(withID: duplicate.id)?.consolidatedIntoWorkspaceID,
                canonical.id
            )

            let staleIndexEntries = try legacyIndexEntries()
            XCTAssertEqual(staleIndexEntries.map(\.id), [canonical.id])

            let authorityInventory = await manager.loadWorkspaceSummarySnapshot()
            let authorityUserInventory = authorityInventory.filter { !$0.isSystemWorkspace }
            XCTAssertEqual(Set(authorityUserInventory.map(\.workspaceID)), Set([canonical.id, duplicate.id]))
            let defaultInventory = WindowRoutingService.workspaceInventory(
                authorityInventory,
                authorityIncompleteWorkspaceIDs: manager.pendingConsolidatedRestoreIDs,
                includeHidden: false
            )
            XCTAssertEqual(defaultInventory.filter { !$0.isSystemWorkspace }.map(\.id), [canonical.id])
            let recoveryInventory = WindowRoutingService.workspaceInventory(
                authorityInventory,
                authorityIncompleteWorkspaceIDs: manager.pendingConsolidatedRestoreIDs,
                includeHidden: true
            )
            let inventoryRetired = try XCTUnwrap(recoveryInventory.first { $0.id == duplicate.id })
            XCTAssertTrue(inventoryRetired.isHidden)
            XCTAssertEqual(inventoryRetired.summary.consolidatedIntoWorkspaceID, canonical.id)

            let markedSwitch = await manager.requestWorkspaceSwitch(toWorkspaceID: inventoryRetired.id)
            XCTAssertFalse(markedSwitch.didSwitch)

            let authoritativeCanonical = try await authoritativeWorkspace(
                canonical.id,
                in: runtime
            )
            XCTAssertTrue(authoritativeCanonical.selectedMetaPromptIDs.contains(mergedPromptID))
            let mergedTab = try XCTUnwrap(authoritativeCanonical.composeTabs.first {
                $0.id == duplicateTabID
            })
            XCTAssertEqual(mergedTab.activeAgentSessionID, duplicateAgentSessionID)
            XCTAssertEqual(mergedTab.activeChatSessionID, duplicateChatSessionID)

            let canonicalChatSidecarURL = sidecarWorkspaceDirectory(for: canonical, root: chatWorkspaceRoot)
                .appendingPathComponent("Chats", isDirectory: true)
                .appendingPathComponent(chatSidecarURL.lastPathComponent)
            let canonicalAgentSidecarURL = sidecarWorkspaceDirectory(for: canonical, root: agentWorkspaceRoot)
                .appendingPathComponent("AgentSessions", isDirectory: true)
                .appendingPathComponent(agentSidecarURL.lastPathComponent)
            let migratedChat = try JSONDecoder().decode(
                ChatSession.self,
                from: Data(contentsOf: canonicalChatSidecarURL)
            )
            let migratedAgent = try JSONDecoder().decode(
                AgentSession.self,
                from: Data(contentsOf: canonicalAgentSidecarURL)
            )
            XCTAssertEqual(migratedChat.workspaceID, canonical.id)
            XCTAssertEqual(migratedChat.composeTabID, duplicateTabID)
            XCTAssertEqual(migratedChat.messages.map(\.rawText), ["Recovered transcript content"])
            XCTAssertEqual(migratedAgent.workspaceID, canonical.id)
            XCTAssertEqual(migratedAgent.composeTabID, duplicateTabID)
            XCTAssertEqual(migratedAgent.name, "Recovered Agent history")
            XCTAssertEqual(migratedAgent.effectiveItemCount, 7)

            let authoritativeRetired = try await authoritativeWorkspace(
                duplicate.id,
                in: runtime
            )
            XCTAssertTrue(authoritativeRetired.isHiddenInMenus)
            XCTAssertEqual(authoritativeRetired.consolidatedIntoWorkspaceID, canonical.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: chatSidecarURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: agentSidecarURL.path))

            let retiredProjectionSequence = await (runtime.workspaceStore.snapshot()).publicationSequence
            let projectedRetirement = await presentationBridge.waitUntilProjected(through: retiredProjectionSequence)
            XCTAssertTrue(projectedRetirement)
            let unrelated = WorkspaceModel(
                name: "Unrelated projection trigger",
                repoPaths: ["/tmp/unrelated-projection-trigger"]
            )
            let unrelatedOutcome = try await authorityClient.create(
                unrelated,
                fileURL: fixture.workspaceFileURL(for: unrelated)
            )
            XCTAssertEqual(unrelatedOutcome.disposition, .applied)
            let unrelatedProjectionSequence = await (runtime.workspaceStore.snapshot()).publicationSequence
            let projectedUnrelated = await presentationBridge.waitUntilProjected(through: unrelatedProjectionSequence)
            XCTAssertTrue(projectedUnrelated)
            XCTAssertEqual(
                manager.workspace(withID: duplicate.id)?.consolidatedIntoWorkspaceID,
                canonical.id,
                "A later projection must not resurrect the bridge's pre-retirement model."
            )

            // Make the reload assertion start false, so the wait proves the authority projection
            // completed instead of passing immediately on the already-projected retirement.
            manager.applyWorkspaceHiddenStateInMemory(
                workspaceID: duplicate.id,
                hidden: false,
                consolidatedIntoWorkspaceID: nil,
                dateModified: Date()
            )
            XCTAssertEqual(
                manager.workspace(withID: duplicate.id)?.consolidatedIntoWorkspaceID,
                canonical.id,
                "A stale hidden-state fan-out must not erase a newer retirement marker."
            )
            let retiredIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == duplicate.id })
            manager.workspaces[retiredIndex].consolidatedIntoWorkspaceID = nil
            manager.reloadWorkspacesFromDisk()
            let reloadDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while manager.workspace(withID: duplicate.id)?.consolidatedIntoWorkspaceID != canonical.id,
                  ContinuousClock.now < reloadDeadline
            {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(manager.workspace(withID: duplicate.id)?.consolidatedIntoWorkspaceID, canonical.id)
            XCTAssertTrue(manager.duplicateWorkspaceGroups().isEmpty)

            let projectedRetired = try XCTUnwrap(manager.workspace(withID: duplicate.id))
            let restoreGate = WorkspaceDuplicateCleanupSuspensionGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, _ in
                guard workspaceID == duplicate.id else { return }
                await restoreGate.wait()
            }
            let restoreTask = Task { @MainActor in
                try await manager.setWorkspaceHidden(
                    workspaceID: inventoryRetired.id,
                    expectedConsolidatedIntoWorkspaceID: inventoryRetired.summary.consolidatedIntoWorkspaceID,
                    hidden: false
                )
            }
            let pendingDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !manager.pendingConsolidatedRestoreIDs.contains(duplicate.id),
                  ContinuousClock.now < pendingDeadline
            {
                await Task.yield()
            }
            XCTAssertTrue(manager.pendingConsolidatedRestoreIDs.contains(duplicate.id))
            let blockedSwitch = await manager.requestWorkspaceSwitch(to: projectedRetired)
            XCTAssertFalse(blockedSwitch.didSwitch)
            await restoreGate.open()
            let restored = try await restoreTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            XCTAssertFalse(restored.isHiddenInMenus)
            XCTAssertNil(restored.consolidatedIntoWorkspaceID)
            XCTAssertFalse(manager.pendingConsolidatedRestoreIDs.contains(duplicate.id))
            var rejectedStaleRetiredHide = false
            do {
                _ = try await manager.setWorkspaceHidden(
                    workspaceID: inventoryRetired.id,
                    expectedConsolidatedIntoWorkspaceID: inventoryRetired.summary.consolidatedIntoWorkspaceID,
                    hidden: true
                )
            } catch {
                rejectedStaleRetiredHide = true
            }
            XCTAssertTrue(rejectedStaleRetiredHide)
            XCTAssertNil(manager.workspace(withID: duplicate.id)?.consolidatedIntoWorkspaceID)

            let authoritativeRestored = try await authoritativeWorkspace(
                duplicate.id,
                in: runtime
            )
            XCTAssertFalse(authoritativeRestored.isHiddenInMenus)
            XCTAssertNil(authoritativeRestored.consolidatedIntoWorkspaceID)
            XCTAssertEqual(manager.duplicateWorkspaceGroups().count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: chatSidecarURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: agentSidecarURL.path))
        }

        func testConcurrentAuthorityUpdateWinsInsteadOfBeingOverwrittenByCleanup() async throws {
            let mergedPromptID = UUID()
            let canonical = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 200),
                name: "Canonical",
                repoPaths: ["/tmp/concurrent-cleanup-root"],
                lastUsed: Date(timeIntervalSince1970: 200)
            )
            let duplicate = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 100),
                name: "Duplicate",
                repoPaths: canonical.repoPaths,
                lastUsed: Date(timeIntervalSince1970: 100),
                selectedMetaPromptIDs: [mergedPromptID]
            )
            try fixture.writeWorkspace(canonical)
            try fixture.writeWorkspace(duplicate)
            try fixture.writeLegacyIndex([canonical, duplicate])

            let configuration = DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "workspace-duplicate-concurrent-save-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            )
            let runtime = MCPDomainRuntime(configuration: configuration, runtimeID: UUID())
            let competingRuntime = MCPDomainRuntime(configuration: configuration, runtimeID: UUID())
            try await runtime.start()
            try await competingRuntime.start()
            defer {
                Task {
                    _ = await runtime.shutdown()
                    _ = await competingRuntime.shutdown()
                }
            }

            let managerClient = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -782)
            let externalClient = DomainWorkspaceAuthorityClient(store: competingRuntime.workspaceStore, windowID: -783)
            let manager = fixture.makeManager(windowID: -782, domainWorkspaceAuthorityClient: managerClient)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("cleanup-backups", isDirectory: true)
            )
            await manager.awaitInitialized()
            let presentationBridge = DomainWorkspacePresentationBridge(
                workspaceManager: manager,
                client: managerClient
            )
            presentationBridge.start()
            defer {
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                presentationBridge.stop()
            }
            let initialSnapshot = await runtime.workspaceStore.snapshot()
            let projectedInitial = await presentationBridge.waitUntilProjected(
                through: initialSnapshot.publicationSequence
            )
            XCTAssertTrue(projectedInitial)
            if manager.activeWorkspaceID != canonical.id {
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: canonical.id, saveState: false)
                XCTAssertTrue(switched.didSwitch)
            }

            let externalPrompt = "Concurrent authority winner"
            // The merge goes out with the copy's save because the window shows the canonical
            // workspace. Another runtime commits the canonical workspace once that save's
            // preparation finishes.
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, remainingRetryCount in
                guard workspaceID == canonical.id, remainingRetryCount == 1 else { return }
                do {
                    let before = await externalClient.snapshot()
                    let authoritative = try XCTUnwrap(before.workspaces.first {
                        $0.document.workspaceID == canonical.id
                    })
                    var externalWinner = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                        documentBytes: authoritative.document.documentBytes,
                        fileURL: authoritative.document.fileURL
                    )
                    externalWinner.currentPromptText = externalPrompt
                    externalWinner.dateModified = Date(timeIntervalSince1970: 300)
                    let outcome = try await externalClient.save(
                        externalWinner,
                        fileURL: authoritative.document.fileURL,
                        expectedWorkspaceRevision: authoritative.revisions.workingRevision,
                        expectedContentDigest: authoritative.document.contentDigest
                    )
                    XCTAssertTrue(
                        outcome.disposition == .applied
                            || outcome.disposition == .unchanged
                            || outcome.disposition == .deduplicated
                    )
                } catch {
                    XCTFail("Failed to install concurrent authority winner: \(error)")
                }
            }

            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }

            let cleanup = await manager.consolidateDuplicateWorkspaces()
            XCTAssertEqual(cleanup.groupsDetected, 1)
            XCTAssertEqual(cleanup.groupsConsolidated, 0)
            XCTAssertTrue(cleanup.retiredWorkspaceIDs.isEmpty)
            XCTAssertTrue(cleanup.skipped.contains {
                $0.workspaceID == duplicate.id && $0.reason.hasPrefix("persist_failed:")
            }, "Unexpected skips: \(cleanup.skipped)")

            let authoritativeCanonical = try await authoritativeWorkspace(canonical.id, in: runtime)
            XCTAssertEqual(authoritativeCanonical.currentPromptText, externalPrompt)
            XCTAssertFalse(authoritativeCanonical.selectedMetaPromptIDs.contains(mergedPromptID))
            XCTAssertEqual(manager.workspace(withID: canonical.id), authoritativeCanonical)

            let finalSnapshot = await runtime.workspaceStore.snapshot()
            let finalCanonical = try XCTUnwrap(finalSnapshot.workspaces.first {
                $0.document.workspaceID == canonical.id
            })
            let managerBaseline = manager.debugDomainAuthorityBaseline(for: canonical.id)
            XCTAssertEqual(managerBaseline.revisions, finalCanonical.revisions)
            XCTAssertEqual(managerBaseline.digest, finalCanonical.document.contentDigest)
            XCTAssertEqual(managerBaseline.health, finalCanonical.health)

            let authoritativeDuplicate = try await authoritativeWorkspace(duplicate.id, in: runtime)
            XCTAssertNil(authoritativeDuplicate.consolidatedIntoWorkspaceID)
            XCTAssertFalse(authoritativeDuplicate.isHiddenInMenus)
            XCTAssertEqual(manager.duplicateWorkspaceGroups().count, 1)

            let competingSnapshot = await externalClient.snapshot()
            let competingDuplicate = try XCTUnwrap(competingSnapshot.workspaces.first {
                $0.document.workspaceID == duplicate.id
            })
            var externallyRetired = duplicate
            externallyRetired.isHiddenInMenus = true
            externallyRetired.consolidatedIntoWorkspaceID = canonical.id
            externallyRetired.dateModified = Date(timeIntervalSince1970: 400)
            let retirementOutcome = try await externalClient.save(
                externallyRetired,
                fileURL: competingDuplicate.document.fileURL,
                expectedWorkspaceRevision: competingDuplicate.revisions.workingRevision,
                expectedContentDigest: competingDuplicate.document.contentDigest
            )
            XCTAssertTrue(
                retirementOutcome.disposition == .applied
                    || retirementOutcome.disposition == .unchanged
                    || retirementOutcome.disposition == .deduplicated
            )

            let retiredSnapshot = await externalClient.snapshot()
            let retiredDuplicate = try XCTUnwrap(retiredSnapshot.workspaces.first {
                $0.document.workspaceID == duplicate.id
            })
            let reservedSavedOperationID = UUID()
            _ = try await externalClient.replaceWorking(
                externallyRetired,
                fileURL: retiredDuplicate.document.fileURL,
                expectedWorkspaceRevision: retiredDuplicate.revisions.workingRevision,
                operationID: reservedSavedOperationID
            )
            let restoreSnapshot = await externalClient.snapshot()
            let restoreBaseline = try XCTUnwrap(restoreSnapshot.workspaces.first {
                $0.document.workspaceID == duplicate.id
            })
            var incompleteWorkingRestore = duplicate
            incompleteWorkingRestore.currentPromptText = "Exact incomplete restore"
            let incompleteRestore = try await externalClient.saveFailClosed(
                incompleteWorkingRestore,
                fileURL: restoreBaseline.document.fileURL,
                expectedWorkspaceRevision: restoreBaseline.revisions.workingRevision,
                expectedContentDigest: restoreBaseline.document.contentDigest,
                operationIDs: DomainWorkspaceSaveOperationIDs(
                    working: UUID(),
                    saved: reservedSavedOperationID
                )
            )
            XCTAssertTrue(incompleteRestore.workingCommitted)
            XCTAssertEqual(incompleteRestore.saved?.errorCode, .operationIDCollision)

            let staleRuntimeSnapshot = await managerClient.snapshot()
            let staleRuntimeDuplicate = try XCTUnwrap(staleRuntimeSnapshot.workspaces.first {
                $0.document.workspaceID == duplicate.id
            })
            XCTAssertNil(staleRuntimeDuplicate.document.metadata.consolidatedIntoWorkspaceID)
            var staleRename = duplicate
            staleRename.name = "Stale rename"
            let staleRenameOutcome = try await managerClient.save(
                staleRename,
                fileURL: staleRuntimeDuplicate.document.fileURL,
                expectedWorkspaceRevision: staleRuntimeDuplicate.revisions.workingRevision,
                expectedContentDigest: staleRuntimeDuplicate.document.contentDigest
            )
            XCTAssertEqual(staleRenameOutcome.disposition, .conflict)
            XCTAssertEqual(staleRenameOutcome.errorCode, .stateConflict)
            let preservedSnapshot = await managerClient.snapshot()
            let preservedIncomplete = try XCTUnwrap(preservedSnapshot.workspaces.first {
                $0.document.workspaceID == duplicate.id
            })

            let refreshedStaleRenameOutcome = try await managerClient.save(
                staleRename,
                fileURL: preservedIncomplete.document.fileURL,
                expectedWorkspaceRevision: preservedIncomplete.revisions.workingRevision,
                expectedContentDigest: preservedIncomplete.document.contentDigest
            )
            XCTAssertEqual(refreshedStaleRenameOutcome.disposition, .conflict)
            XCTAssertEqual(refreshedStaleRenameOutcome.errorCode, .stateConflict)

            let finalPreservedSnapshot = await managerClient.snapshot()
            let finalPreservedIncomplete = try XCTUnwrap(finalPreservedSnapshot.workspaces.first {
                $0.document.workspaceID == duplicate.id
            })
            XCTAssertNotNil(finalPreservedIncomplete.revisions.dirtyRevision)
            let preservedWorking = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: finalPreservedIncomplete.document.documentBytes
            )
            XCTAssertEqual(preservedWorking.currentPromptText, incompleteWorkingRestore.currentPromptText)
            let stillRetiredOnDisk = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: Data(contentsOf: finalPreservedIncomplete.document.fileURL)
            )
            XCTAssertEqual(stillRetiredOnDisk.consolidatedIntoWorkspaceID, canonical.id)
        }

        /// A canonical workspace the window doesn't show takes the merge at exactly the revision cleanup
        /// read. When another writer commits after that read, its document stays and cleanup
        /// reports the refused save.
        func testCleanupKeepsACommitToAnUnshownCanonicalMadeAfterItsRead() async throws {
            let canonical = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_200),
                name: "Unshown Canonical",
                repoPaths: ["/tmp/duplicate-cleanup-unshown-winner-root"],
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_200)
            )
            let duplicate = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_100),
                name: "Unshown Duplicate",
                repoPaths: canonical.repoPaths,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_100)
            )
            let other = WorkspaceModel(name: "Unshown Other", repoPaths: ["/tmp/duplicate-cleanup-unshown-winner-other-root"])
            for workspace in [other, canonical, duplicate] {
                try fixture.writeWorkspace(workspace)
            }
            try fixture.writeLegacyIndex([other, canonical, duplicate])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "duplicate-cleanup-unshown-winner")
            let otherWriter = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -799)
            let (manager, _) = await fixture.makeProjectedManager(windowID: -798, runtime: runtime)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("unshown-winner-backups", isDirectory: true)
            )
            if manager.activeWorkspaceID != other.id {
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: other.id, saveState: false)
                XCTAssertTrue(switched.didSwitch, "The window must show a workspace outside the group")
            }
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }
            let winnerPrompt = "Committed after the read"
            var committedWinner = false
            manager.contentGateway.commitSubmissionWillBeginHandlerForTesting = { workspaceID in
                guard workspaceID == canonical.id, !committedWinner else { return }
                committedWinner = true
                do {
                    let read = await otherWriter.canonicalWorkspaceSnapshot(canonical.id)
                    let snapshot = try XCTUnwrap(read)
                    var winner = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                        documentBytes: snapshot.document.documentBytes,
                        fileURL: snapshot.document.fileURL
                    )
                    winner.currentPromptText = winnerPrompt
                    let outcome = try await otherWriter.replaceWorking(
                        winner,
                        fileURL: snapshot.document.fileURL,
                        expectedWorkspaceRevision: snapshot.revisions.workingRevision
                    )
                    XCTAssertEqual(outcome.disposition, .applied)
                } catch {
                    XCTFail("The other writer's commit failed: \(error)")
                }
            }
            addTeardownBlock { @MainActor in
                manager.contentGateway.commitSubmissionWillBeginHandlerForTesting = nil
            }

            let cleanup = await manager.consolidateDuplicateWorkspaces()

            XCTAssertTrue(committedWinner)
            XCTAssertEqual(cleanup.groupsConsolidated, 0)
            XCTAssertTrue(cleanup.retiredWorkspaceIDs.isEmpty)
            XCTAssertTrue(cleanup.skipped.contains {
                $0.workspaceID == duplicate.id && $0.reason.hasPrefix("persist_failed:")
            }, "Unexpected skips: \(cleanup.skipped)")
            let stored = try await authoritativeWorkspace(canonical.id, in: runtime)
            XCTAssertEqual(stored.currentPromptText, winnerPrompt)
        }

        /// Each retirement checks that the catalog still lists the canonical workspace. When another
        /// window deletes the canonical while one duplicate's retirement is in flight, the next
        /// duplicate stays visible and isn't marked consolidated into the deleted workspace. Here
        /// one projection both removes the canonical and answers the first retirement, so the next
        /// check runs right after that projection.
        func testRetirementAfterTheCanonicalIsDeletedKeepsTheNextDuplicate() async throws {
            let roots = ["/tmp/duplicate-cleanup-deleted-canonical-root"]
            let canonical = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_300),
                name: "Deleted Canonical",
                repoPaths: roots,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_300)
            )
            let firstDuplicate = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_200),
                name: "Deleted Canonical Duplicate A",
                repoPaths: roots,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_200)
            )
            let secondDuplicate = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_100),
                name: "Deleted Canonical Duplicate B",
                repoPaths: roots,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_100)
            )
            let shown = WorkspaceModel(name: "Deleted Canonical Shown", repoPaths: ["/tmp/duplicate-cleanup-deleted-canonical-shown-root"])
            for workspace in [shown, canonical, firstDuplicate, secondDuplicate] {
                try fixture.writeWorkspace(workspace)
            }
            try fixture.writeLegacyIndex([shown, canonical, firstDuplicate, secondDuplicate])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "duplicate-cleanup-deleted-canonical")
            let otherWindow = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -7401)
            let (manager, bridge) = await fixture.makeProjectedManager(windowID: -7400, runtime: runtime)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("deleted-canonical-backups", isDirectory: true)
            )
            if manager.activeWorkspaceID != shown.id {
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: shown.id, saveState: false)
                XCTAssertTrue(switched.didSwitch, "The window must show a workspace outside the group")
            }
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }
            let duplicateIDs: Set<UUID> = [firstDuplicate.id, secondDuplicate.id]
            // The window projects nothing from the deletion until the authority has answered the
            // first retirement.
            let projectionGate = WorkspaceDuplicateCleanupSuspensionGate()
            var holdsProjection = false
            var firstRetirementID: UUID?
            bridge.eventConsumptionWillBeginHandlerForTesting = { _ in
                if holdsProjection { await projectionGate.wait() }
            }
            manager.contentGateway.commitSubmissionWillBeginHandlerForTesting = { workspaceID in
                guard duplicateIDs.contains(workspaceID), firstRetirementID == nil else { return }
                firstRetirementID = workspaceID
                do {
                    let beforeDeletion = await runtime.workspaceStore.snapshot()
                    let caughtUp = await bridge.waitUntilProjected(through: beforeDeletion.publicationSequence)
                    XCTAssertTrue(caughtUp)
                    holdsProjection = true
                    let read = await otherWindow.canonicalWorkspaceSnapshot(canonical.id)
                    let snapshot = try XCTUnwrap(read)
                    let catalog = await runtime.workspaceStore.snapshot()
                    let deletion = await otherWindow.delete(
                        workspaceID: canonical.id,
                        expectedCatalogRevision: catalog.catalogRevision,
                        expectedWorkspaceRevision: snapshot.revisions.workingRevision
                    )
                    XCTAssertEqual(deletion.disposition, .applied)
                } catch {
                    XCTFail("The other window's deletion failed: \(error)")
                }
            }
            manager.contentGateway.commitResultWillReturnHandlerForTesting = { workspaceID in
                guard workspaceID == firstRetirementID, holdsProjection else { return }
                holdsProjection = false
                await projectionGate.open()
            }
            addTeardownBlock { @MainActor in
                manager.contentGateway.commitSubmissionWillBeginHandlerForTesting = nil
                manager.contentGateway.commitResultWillReturnHandlerForTesting = nil
                bridge.eventConsumptionWillBeginHandlerForTesting = nil
                await projectionGate.open()
            }

            let cleanup = await manager.consolidateDuplicateWorkspaces()

            let firstRetired = try XCTUnwrap(firstRetirementID)
            let nextID = try XCTUnwrap(duplicateIDs.subtracting([firstRetired]).first)
            XCTAssertEqual(cleanup.groupsConsolidated, 0)
            XCTAssertFalse(cleanup.retiredWorkspaceIDs.contains(nextID))
            XCTAssertTrue(cleanup.skipped.contains {
                $0.workspaceID == nextID && $0.reason.hasPrefix("persist_failed:")
            }, "Unexpected skips: \(cleanup.skipped)")
            let next = try await authoritativeWorkspace(nextID, in: runtime)
            XCTAssertNil(next.consolidatedIntoWorkspaceID)
            XCTAssertFalse(next.isHiddenInMenus)
        }

        func testDuplicateMergeLoadsOnlySelectedGroupAndPreservesUnmergedTabs() async throws {
            let sharedRoots = ["/tmp/duplicate-merge-shared-root"]
            let canonicalTab = ComposeTabState(
                name: "Canonical plan",
                selection: StoredSelection(selectedPaths: ["/tmp/duplicate-merge-shared-root/a.swift"]),
                promptText: "Canonical prompt"
            )
            let canonicalStash = StashedTab(tab: ComposeTabState(name: "Canonical stash", promptText: "Parked in canonical"))
            let canonical = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_200),
                name: "Merge Canonical",
                repoPaths: sharedRoots,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_200),
                composeTabs: [canonicalTab],
                activeComposeTabID: canonicalTab.id,
                stashedTabs: [canonicalStash]
            )
            let duplicatePlan = ComposeTabState(
                name: "Duplicate plan",
                isPinned: true,
                selection: StoredSelection(
                    selectedPaths: ["/tmp/duplicate-merge-shared-root/b.swift"],
                    slices: ["/tmp/duplicate-merge-shared-root/c.swift": [LineRange(start: 2, end: 8)]]
                ),
                promptText: "Duplicate prompt"
            )
            let duplicateNotes = ComposeTabState(name: "Duplicate notes", promptText: "Second duplicate tab")
            let duplicateStash = StashedTab(tab: ComposeTabState(name: "Duplicate stash", promptText: "Parked in duplicate"))
            let duplicate = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_100),
                name: "Merge Duplicate",
                repoPaths: sharedRoots,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_100),
                composeTabs: [duplicatePlan, duplicateNotes],
                activeComposeTabID: duplicatePlan.id,
                stashedTabs: [duplicateStash]
            )
            let bystanderTab = ComposeTabState(name: "Bystander", promptText: "Not in the group")
            let bystander = WorkspaceModel(
                name: "Merge Bystander",
                repoPaths: ["/tmp/duplicate-merge-bystander-root"],
                composeTabs: [bystanderTab],
                activeComposeTabID: bystanderTab.id,
                stashedTabs: [StashedTab(tab: ComposeTabState(name: "Bystander stash"))]
            )
            let shown = WorkspaceModel(name: "Merge Shown", repoPaths: ["/tmp/duplicate-merge-shown-root"])
            for workspace in [shown, canonical, duplicate, bystander] {
                try fixture.writeWorkspace(workspace)
            }
            try fixture.writeLegacyIndex([shown, canonical, duplicate, bystander])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "duplicate-merge-selected-group")
            let (manager, _) = await fixture.makeProjectedManager(windowID: -794, runtime: runtime)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("merge-backups", isDirectory: true)
            )
            if manager.activeWorkspaceID != shown.id {
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: shown.id, saveState: false)
                XCTAssertTrue(switched.didSwitch, "The window must show a workspace outside the group")
            }
            let bystanderURL = fixture.workspaceFileURL(for: bystander)
            let bystanderBytes = try Data(contentsOf: bystanderURL)
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }
            manager.contentGateway.resetDebugLoadSnapshot()

            let cleanup = await manager.consolidateDuplicateWorkspaces()

            XCTAssertEqual(cleanup.groupsConsolidated, 1, "Unexpected skips: \(cleanup.skipped)")
            XCTAssertEqual(cleanup.retiredWorkspaceIDs, [duplicate.id])
            let merged = try await authoritativeWorkspace(canonical.id, in: runtime)
            XCTAssertEqual(merged.composeTabs, canonical.composeTabs + duplicate.composeTabs)
            XCTAssertEqual(merged.stashedTabs, canonical.stashedTabs + duplicate.stashedTabs)
            let retired = try await authoritativeWorkspace(duplicate.id, in: runtime)
            XCTAssertEqual(retired.consolidatedIntoWorkspaceID, canonical.id)
            XCTAssertTrue(retired.isHiddenInMenus)
            XCTAssertEqual(retired.composeTabs, duplicate.composeTabs)
            XCTAssertEqual(retired.stashedTabs, duplicate.stashedTabs)

            // The backup writes dates as ISO 8601 whole seconds, so it is compared by tab content.
            let backupDecoder = JSONDecoder()
            backupDecoder.dateDecodingStrategy = .iso8601
            let backup = try backupDecoder.decode(
                WorkspaceDuplicateCleanupBackup.self,
                from: Data(contentsOf: XCTUnwrap(cleanup.backupURL))
            )
            let backupGroup = try XCTUnwrap(backup.groups.first)
            XCTAssertEqual(backup.groups.count, 1)
            func tabContent(_ workspace: WorkspaceModel) -> [String] {
                (workspace.composeTabs + workspace.stashedTabs.map(\.tab)).map {
                    "\($0.id.uuidString) \($0.promptText) \($0.selection.selectedPaths)"
                }
            }
            XCTAssertEqual(tabContent(backupGroup.canonicalBeforeMerge), tabContent(canonical))
            XCTAssertEqual(backupGroup.duplicatesBeforeDelete.map(tabContent), [tabContent(duplicate)])

            XCTAssertEqual(try Data(contentsOf: bystanderURL), bystanderBytes)
            let loads = manager.contentGateway.debugLoadSnapshot()
            let decodedWorkspaceIDs = Set(loads.countsByWorkspaceID.keys.filter { loads.counts(for: $0).decodes > 0 })
            XCTAssertEqual(decodedWorkspaceIDs, [canonical.id, duplicate.id])
        }

        /// A canonical workspace the window shows takes the merge in its copy, so an edit the copy
        /// hasn't published yet stays and reaches the merged document.
        func testShownCanonicalMergeKeepsTheCopysUnpublishedEdit() async throws {
            let activeTab = ComposeTabState(name: "Active")
            let inactiveTab = ComposeTabState(name: "Inactive", promptText: "Saved prompt")
            let canonical = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_200),
                name: "Shown Canonical",
                repoPaths: ["/tmp/duplicate-cleanup-shown-canonical-root"],
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_200),
                composeTabs: [activeTab, inactiveTab],
                activeComposeTabID: activeTab.id
            )
            let duplicateTab = ComposeTabState(name: "Duplicate", promptText: "Duplicate prompt")
            let duplicate = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_100),
                name: "Shown Canonical Duplicate",
                repoPaths: canonical.repoPaths,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_100),
                composeTabs: [duplicateTab],
                activeComposeTabID: duplicateTab.id
            )
            try fixture.writeWorkspace(canonical)
            try fixture.writeWorkspace(duplicate)
            try fixture.writeLegacyIndex([canonical, duplicate])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "duplicate-cleanup-shown-canonical")
            let (manager, _) = await fixture.makeProjectedManager(windowID: -795, runtime: runtime)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("shown-canonical-backups", isDirectory: true)
            )
            if manager.activeWorkspaceID != canonical.id {
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: canonical.id, saveState: false)
                XCTAssertTrue(switched.didSwitch)
            }
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }
            let identity = WorkspaceSelectionIdentity(workspaceID: canonical.id, tabID: inactiveTab.id)
            XCTAssertTrue(manager.editHeldTab(identity) { tab in
                tab.promptText = "Unsaved prompt"
                return true
            })

            let cleanup = await manager.consolidateDuplicateWorkspaces()

            XCTAssertEqual(cleanup.groupsConsolidated, 1, "Unexpected skips: \(cleanup.skipped)")
            XCTAssertEqual(cleanup.retiredWorkspaceIDs, [duplicate.id])
            XCTAssertEqual(manager.contentGateway.shownComposeTab(identity)?.promptText, "Unsaved prompt")
            let mergedCanonical = try await authoritativeWorkspace(canonical.id, in: runtime)
            XCTAssertEqual(mergedCanonical.composeTabs.first { $0.id == inactiveTab.id }?.promptText, "Unsaved prompt")
            XCTAssertTrue(mergedCanonical.composeTabs.contains { $0.id == duplicateTab.id })
        }

        /// Cleanup routes its merge by what the window shows when it commits. A canonical workspace
        /// the window starts showing after cleanup read it takes the merge in its copy, so an edit
        /// made there since stays and reaches the merged document.
        func testCanonicalShownAfterTheReadKeepsTheCopysEdit() async throws {
            let activeTab = ComposeTabState(name: "Active")
            let inactiveTab = ComposeTabState(name: "Inactive", promptText: "Saved prompt")
            let canonical = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_200),
                name: "Late Shown Canonical",
                repoPaths: ["/tmp/duplicate-cleanup-late-shown-root"],
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_200),
                composeTabs: [activeTab, inactiveTab],
                activeComposeTabID: activeTab.id
            )
            let duplicate = WorkspaceModel(
                dateModified: Date(timeIntervalSinceReferenceDate: 700_000_100),
                name: "Late Shown Duplicate",
                repoPaths: canonical.repoPaths,
                lastUsed: Date(timeIntervalSinceReferenceDate: 700_000_100)
            )
            let other = WorkspaceModel(name: "Late Shown Other", repoPaths: ["/tmp/duplicate-cleanup-late-shown-other-root"])
            for workspace in [other, canonical, duplicate] {
                try fixture.writeWorkspace(workspace)
            }
            try fixture.writeLegacyIndex([other, canonical, duplicate])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "duplicate-cleanup-late-shown-canonical")
            let (manager, _) = await fixture.makeProjectedManager(windowID: -796, runtime: runtime)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("late-shown-backups", isDirectory: true)
            )
            if manager.activeWorkspaceID != other.id {
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: other.id, saveState: false)
                XCTAssertTrue(switched.didSwitch, "The window must show a workspace outside the group")
            }
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }
            let identity = WorkspaceSelectionIdentity(workspaceID: canonical.id, tabID: inactiveTab.id)
            // Cleanup reads the duplicate for the merge after it read the canonical document. The
            // window shows the canonical workspace and edits it during that read.
            manager.contentGateway.canonicalReadWillBeginHandlerForTesting = { workspaceID, source in
                guard workspaceID == duplicate.id,
                      source == "duplicateCleanupMerge",
                      manager.activeWorkspaceID != canonical.id
                else { return }
                _ = await manager.requestWorkspaceSwitch(toWorkspaceID: canonical.id, saveState: false)
                _ = manager.editHeldTab(identity) { tab in
                    tab.promptText = "Edited after the read"
                    return true
                }
            }
            addTeardownBlock { @MainActor in
                manager.contentGateway.canonicalReadWillBeginHandlerForTesting = nil
            }

            let cleanup = await manager.consolidateDuplicateWorkspaces()

            XCTAssertEqual(manager.activeWorkspaceID, canonical.id, "The duplicate's read must show the canonical workspace")
            XCTAssertEqual(cleanup.groupsConsolidated, 1, "Unexpected skips: \(cleanup.skipped)")
            XCTAssertEqual(cleanup.retiredWorkspaceIDs, [duplicate.id])
            XCTAssertEqual(manager.contentGateway.shownComposeTab(identity)?.promptText, "Edited after the read")
            let mergedCanonical = try await authoritativeWorkspace(canonical.id, in: runtime)
            XCTAssertEqual(mergedCanonical.composeTabs.first { $0.id == inactiveTab.id }?.promptText, "Edited after the read")
        }

        func testWorkspaceRetirementMarkerRoundTripsAndDefaultsToNil() throws {
            let canonicalID = UUID()
            let retired = WorkspaceModel(
                name: "Retired",
                repoPaths: ["/tmp/retired"],
                isHiddenInMenus: true,
                consolidatedIntoWorkspaceID: canonicalID
            )
            let roundTripped = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: JSONEncoder().encode(retired)
            )
            XCTAssertEqual(roundTripped.consolidatedIntoWorkspaceID, canonicalID)
            XCTAssertEqual(roundTripped, retired)

            let ordinary = WorkspaceModel(name: "Ordinary", repoPaths: ["/tmp/ordinary"])
            let legacyCompatible = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: JSONEncoder().encode(ordinary)
            )
            XCTAssertNil(legacyCompatible.consolidatedIntoWorkspaceID)
        }

        func testBothSidecarFamiliesPreflightBeforeEitherWrites() async throws {
            let canonical = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 200),
                name: "Canonical preflight target",
                repoPaths: ["/tmp/sidecar-preflight-root"],
                lastUsed: Date(timeIntervalSince1970: 200)
            )
            let duplicate = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 100),
                name: "Duplicate preflight source",
                repoPaths: canonical.repoPaths,
                lastUsed: Date(timeIntervalSince1970: 100)
            )
            try fixture.writeWorkspace(canonical)
            try fixture.writeWorkspace(duplicate)
            try fixture.writeLegacyIndex([canonical, duplicate])

            let sourceAgentDirectory = sidecarWorkspaceDirectory(for: duplicate, root: agentWorkspaceRoot)
                .appendingPathComponent("AgentSessions", isDirectory: true)
            let sourceChatDirectory = sidecarWorkspaceDirectory(for: duplicate, root: chatWorkspaceRoot)
                .appendingPathComponent("Chats", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceAgentDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sourceChatDirectory, withIntermediateDirectories: true)

            let sessionID = UUID()
            let agentFilename = "AgentSession-\(sessionID.uuidString).json"
            let sourceAgentURL = sourceAgentDirectory.appendingPathComponent(agentFilename)
            try JSONEncoder().encode(AgentSession(
                id: sessionID,
                workspaceID: duplicate.id,
                name: "Prepared only"
            )).write(to: sourceAgentURL, options: .atomic)
            let invalidChatURL = sourceChatDirectory
                .appendingPathComponent("ChatSession-\(UUID().uuidString).json")
            try Data("not-json".utf8).write(to: invalidChatURL, options: .atomic)

            let manager = fixture.makeManager(windowID: -786)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("preflight-backups", isDirectory: true)
            )
            await manager.awaitInitialized()

            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }

            let cleanup = await manager.consolidateDuplicateWorkspaces()
            XCTAssertEqual(cleanup.groupsDetected, 1)
            XCTAssertEqual(cleanup.groupsConsolidated, 0)
            XCTAssertTrue(cleanup.retiredWorkspaceIDs.isEmpty)
            XCTAssertTrue(cleanup.skipped.contains {
                $0.workspaceID == duplicate.id && $0.reason.hasPrefix("sidecar_preflight_failed:")
            })

            let destinationAgentURL = sidecarWorkspaceDirectory(for: canonical, root: agentWorkspaceRoot)
                .appendingPathComponent("AgentSessions", isDirectory: true)
                .appendingPathComponent(agentFilename)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationAgentURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAgentURL.path))
            XCTAssertNotNil(manager.workspace(withID: duplicate.id))
            XCTAssertEqual(manager.duplicateWorkspaceGroups().count, 1)

            try FileManager.default.removeItem(at: invalidChatURL)
            try FileManager.default.removeItem(at: sourceAgentURL)
            let pendingSessionID = UUID()
            let pendingWriteEntered = WorkspaceDuplicateCleanupSuspensionGate()
            let releasePendingWrite = WorkspaceDuplicateCleanupSuspensionGate()
            await AgentSessionDataService.shared.test_setBeforeSessionWriteHook { url in
                guard url.lastPathComponent == "AgentSession-\(pendingSessionID.uuidString).json" else { return }
                await pendingWriteEntered.open()
                await releasePendingWrite.wait()
            }
            let pendingSave = Task {
                try await AgentSessionDataService.shared.saveAgentSession(
                    AgentSession(
                        id: pendingSessionID,
                        workspaceID: duplicate.id,
                        name: "Pending new source"
                    ),
                    for: duplicate
                )
            }
            await pendingWriteEntered.wait()

            let pendingCleanup = await manager.consolidateDuplicateWorkspaces()
            XCTAssertEqual(pendingCleanup.groupsDetected, 1)
            XCTAssertEqual(pendingCleanup.groupsConsolidated, 0)
            XCTAssertTrue(pendingCleanup.retiredWorkspaceIDs.isEmpty)
            XCTAssertTrue(pendingCleanup.skipped.contains {
                $0.workspaceID == duplicate.id && $0.reason.hasPrefix("sidecar_migration_failed:")
            })
            XCTAssertNotNil(manager.workspace(withID: duplicate.id))

            await releasePendingWrite.open()
            _ = try await pendingSave.value
            await AgentSessionDataService.shared.test_setBeforeSessionWriteHook(nil)
        }

        func testChatCommitFailureWithdrawsTheAlreadyCommittedAgentBatch() async throws {
            let canonical = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 200),
                name: "Canonical rollback target",
                repoPaths: ["/tmp/sidecar-rollback-root"],
                lastUsed: Date(timeIntervalSince1970: 200)
            )
            let duplicate = WorkspaceModel(
                id: UUID(),
                dateModified: Date(timeIntervalSince1970: 100),
                name: "Duplicate rollback source",
                repoPaths: canonical.repoPaths,
                lastUsed: Date(timeIntervalSince1970: 100)
            )
            try fixture.writeWorkspace(canonical)
            try fixture.writeWorkspace(duplicate)
            try fixture.writeLegacyIndex([canonical, duplicate])

            let sourceAgentDirectory = sidecarWorkspaceDirectory(for: duplicate, root: agentWorkspaceRoot)
                .appendingPathComponent("AgentSessions", isDirectory: true)
            let sourceChatDirectory = sidecarWorkspaceDirectory(for: duplicate, root: chatWorkspaceRoot)
                .appendingPathComponent("Chats", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceAgentDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sourceChatDirectory, withIntermediateDirectories: true)

            let agentSessionID = UUID()
            let agentFilename = "AgentSession-\(agentSessionID.uuidString).json"
            let sourceAgentURL = sourceAgentDirectory.appendingPathComponent(agentFilename)
            try JSONEncoder().encode(AgentSession(
                id: agentSessionID,
                workspaceID: duplicate.id,
                name: "Withdrawn on chat failure"
            )).write(to: sourceAgentURL, options: .atomic)

            let chatSessionID = UUID()
            try sidecarData(
                sessionID: chatSessionID,
                workspaceID: duplicate.id,
                name: "Blocked chat"
            ).write(
                to: sourceChatDirectory
                    .appendingPathComponent("ChatSession-\(chatSessionID.uuidString).json"),
                options: .atomic
            )

            // A regular file where the canonical Chats folder belongs passes Chat preflight -- which
            // reads the source and probes individual destination files -- and then fails the Chat
            // commit. That is the exact ordering that used to leave the Agent copy published.
            let canonicalChatDirectory = sidecarWorkspaceDirectory(for: canonical, root: chatWorkspaceRoot)
            try FileManager.default.createDirectory(
                at: canonicalChatDirectory,
                withIntermediateDirectories: true
            )
            try Data("blocked".utf8).write(
                to: canonicalChatDirectory.appendingPathComponent("Chats"),
                options: .atomic
            )

            let manager = fixture.makeManager(windowID: -787)
            manager.setDuplicateCleanupBackupDirectoryForTesting(
                storageRoot.appendingPathComponent("rollback-backups", isDirectory: true)
            )
            await manager.awaitInitialized()

            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            defer { WindowStatesManager.shared.allWindows = previousWindows }

            let cleanup = await manager.consolidateDuplicateWorkspaces()
            XCTAssertEqual(cleanup.groupsDetected, 1)
            XCTAssertEqual(cleanup.groupsConsolidated, 0)
            XCTAssertTrue(cleanup.retiredWorkspaceIDs.isEmpty)
            XCTAssertTrue(cleanup.skipped.contains {
                $0.workspaceID == duplicate.id && $0.reason.hasPrefix("sidecar_migration_failed:")
            })

            let destinationAgentDirectory = sidecarWorkspaceDirectory(for: canonical, root: agentWorkspaceRoot)
                .appendingPathComponent("AgentSessions", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: destinationAgentDirectory.appendingPathComponent(agentFilename).path
            ))
            if let indexData = try? Data(
                contentsOf: destinationAgentDirectory.appendingPathComponent("AgentSessionIndex.json")
            ) {
                XCTAssertFalse(
                    String(decoding: indexData, as: UTF8.self).contains(agentSessionID.uuidString)
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAgentURL.path))
            XCTAssertNotNil(manager.workspace(withID: duplicate.id))
            XCTAssertEqual(manager.duplicateWorkspaceGroups().count, 1)
        }

        func testFailClosedSaveReportsAWorkingOnlyCommit() async throws {
            let canonicalID = UUID()
            let canonical = WorkspaceModel(
                id: canonicalID,
                name: "Phase-aware canonical",
                repoPaths: ["/tmp/phase-aware-save"]
            )
            let workspace = WorkspaceModel(
                id: UUID(),
                name: "Phase-aware save",
                repoPaths: ["/tmp/phase-aware-save"],
                isHiddenInMenus: true,
                consolidatedIntoWorkspaceID: canonicalID
            )
            try fixture.writeWorkspace(canonical)
            try fixture.writeWorkspace(workspace)
            try fixture.writeLegacyIndex([canonical, workspace])

            let configuration = DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "workspace-phase-aware-save-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("phase-runtime", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("phase-events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("phase-tmp", isDirectory: true),
                externalReloadInterval: nil
            )
            let runtime = MCPDomainRuntime(configuration: configuration, runtimeID: UUID())
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -784)
            let initialSnapshot = await client.snapshot()
            let initial = try XCTUnwrap(initialSnapshot.workspaces.first {
                $0.document.workspaceID == workspace.id
            })
            let reservedSavedOperationID = UUID()
            let reservation = try await client.replaceWorking(
                workspace,
                fileURL: initial.document.fileURL,
                expectedWorkspaceRevision: initial.revisions.workingRevision,
                operationID: reservedSavedOperationID
            )
            XCTAssertTrue(
                reservation.disposition == .applied
                    || reservation.disposition == .unchanged
                    || reservation.disposition == .deduplicated
            )

            var updated = workspace
            updated.currentPromptText = "Durable working update"
            updated.isHiddenInMenus = false
            updated.consolidatedIntoWorkspaceID = nil
            let outcome = try await client.saveFailClosed(
                updated,
                fileURL: initial.document.fileURL,
                expectedWorkspaceRevision: reservation.after?.workingRevision
                    ?? reservation.workspace?.revisions.workingRevision
                    ?? initial.revisions.workingRevision,
                expectedContentDigest: reservation.resultingDigest
                    ?? reservation.workspace?.document.contentDigest
                    ?? initial.document.contentDigest,
                operationIDs: DomainWorkspaceSaveOperationIDs(
                    working: UUID(),
                    saved: reservedSavedOperationID
                )
            )

            XCTAssertTrue(outcome.workingCommitted)
            XCTAssertEqual(outcome.saved?.errorCode, .operationIDCollision)
            let afterSnapshot = await client.snapshot()
            let after = try XCTUnwrap(afterSnapshot.workspaces.first {
                $0.document.workspaceID == workspace.id
            })
            XCTAssertNotNil(after.revisions.dirtyRevision)
            let authoritative = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: after.document.documentBytes
            )
            XCTAssertEqual(authoritative.currentPromptText, updated.currentPromptText)
            XCTAssertFalse(authoritative.isHiddenInMenus)
            XCTAssertNil(authoritative.consolidatedIntoWorkspaceID)

            let savedRetiredBytes = try Data(contentsOf: after.document.fileURL)
            let stillRetiredOnDisk = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: savedRetiredBytes
            )
            XCTAssertTrue(stillRetiredOnDisk.isHiddenInMenus)
            XCTAssertEqual(stillRetiredOnDisk.consolidatedIntoWorkspaceID, canonicalID)
            try FileManager.default.removeItem(at: after.document.fileURL)

            let secondClient = DomainWorkspaceAuthorityClient(
                store: runtime.workspaceStore,
                windowID: -787
            )
            let secondManager = fixture.makeManager(
                windowID: -787,
                domainWorkspaceAuthorityClient: secondClient
            )
            await secondManager.awaitInitialized()
            let secondBridge = DomainWorkspacePresentationBridge(
                workspaceManager: secondManager,
                client: secondClient
            )
            secondBridge.start()
            defer { secondBridge.stop() }
            let secondSequence = await (runtime.workspaceStore.snapshot()).publicationSequence
            let secondProjected = await secondBridge.waitUntilProjected(through: secondSequence)
            XCTAssertTrue(secondProjected)

            let secondInventory = await secondManager.loadWorkspaceSummarySnapshot()
            let secondTarget = try XCTUnwrap(secondInventory.first { $0.workspaceID == workspace.id })
            XCTAssertNil(secondTarget.consolidatedIntoWorkspaceID)
            XCTAssertTrue(secondManager.pendingConsolidatedRestoreIDs.contains(workspace.id))
            XCTAssertNil(secondManager.workspace(withID: workspace.id)?.consolidatedIntoWorkspaceID)
            XCTAssertTrue(secondManager.duplicateWorkspaceGroups().isEmpty)
            let secondSwitch = await secondManager.requestWorkspaceSwitch(toWorkspaceID: secondTarget.workspaceID)
            XCTAssertFalse(secondSwitch.didSwitch)
            secondBridge.stop()

            try savedRetiredBytes.write(to: after.document.fileURL, options: .atomic)

            _ = await runtime.shutdown()

            let restartedRuntime = MCPDomainRuntime(configuration: configuration, runtimeID: UUID())
            try await restartedRuntime.start()
            defer { Task { _ = await restartedRuntime.shutdown() } }

            let restartedSnapshot = await restartedRuntime.workspaceStore.snapshot()
            let restartedRow = try XCTUnwrap(restartedSnapshot.workspaces.first {
                $0.document.workspaceID == workspace.id
            })
            XCTAssertNotNil(restartedRow.revisions.dirtyRevision)
            let restartedWorking = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: restartedRow.document.documentBytes
            )
            XCTAssertNil(restartedWorking.consolidatedIntoWorkspaceID)

            let restartedClient = DomainWorkspaceAuthorityClient(
                store: restartedRuntime.workspaceStore,
                windowID: -788
            )
            let restartedManager = fixture.makeManager(
                windowID: -788,
                domainWorkspaceAuthorityClient: restartedClient
            )
            await restartedManager.awaitInitialized()
            let restartedBridge = DomainWorkspacePresentationBridge(
                workspaceManager: restartedManager,
                client: restartedClient
            )
            restartedBridge.start()
            defer { restartedBridge.stop() }
            let restartedSequence = await (restartedRuntime.workspaceStore.snapshot()).publicationSequence
            let restartedProjected = await restartedBridge.waitUntilProjected(through: restartedSequence)
            XCTAssertTrue(restartedProjected)

            let restartedInventory = await restartedManager.loadWorkspaceSummarySnapshot()
            let restartedTarget = try XCTUnwrap(restartedInventory.first { $0.workspaceID == workspace.id })
            XCTAssertNil(restartedTarget.consolidatedIntoWorkspaceID)
            XCTAssertTrue(restartedManager.pendingConsolidatedRestoreIDs.contains(workspace.id))
            XCTAssertNil(restartedManager.workspace(withID: workspace.id)?.consolidatedIntoWorkspaceID)
            XCTAssertTrue(restartedManager.duplicateWorkspaceGroups().isEmpty)
            let restartedSwitch = await restartedManager.requestWorkspaceSwitch(toWorkspaceID: restartedTarget.workspaceID)
            XCTAssertFalse(restartedSwitch.didSwitch)

            let restoreCompletionSnapshot = await restartedClient.snapshot()
            let restoreCompletionBaseline = try XCTUnwrap(restoreCompletionSnapshot.workspaces.first {
                $0.document.workspaceID == workspace.id
            })
            let restoreCompletion = try await restartedClient.saveFailClosed(
                restartedWorking,
                fileURL: restoreCompletionBaseline.document.fileURL,
                expectedWorkspaceRevision: restoreCompletionBaseline.revisions.workingRevision,
                expectedContentDigest: restoreCompletionBaseline.document.contentDigest
            )
            XCTAssertTrue(
                restoreCompletion.finalOutcome?.disposition == .applied
                    || restoreCompletion.finalOutcome?.disposition == .unchanged
                    || restoreCompletion.finalOutcome?.disposition == .deduplicated
            )

            let staleActivationClient = DomainWorkspaceAuthorityClient(
                store: restartedRuntime.workspaceStore,
                windowID: -791
            )
            let staleActivationManager = fixture.makeManager(
                windowID: -791,
                domainWorkspaceAuthorityClient: staleActivationClient
            )
            await staleActivationManager.awaitInitialized()
            let staleActivationTarget = try XCTUnwrap(
                staleActivationManager.workspace(withID: workspace.id)
            )
            XCTAssertNil(staleActivationTarget.consolidatedIntoWorkspaceID)

            let reservedRetirementSaveID = UUID()
            let retirementReservation = try await restartedClient.replaceWorking(
                restartedWorking,
                fileURL: restoreCompletionBaseline.document.fileURL,
                expectedWorkspaceRevision: restoreCompletion.finalOutcome?.after?.workingRevision
                    ?? restoreCompletionBaseline.revisions.workingRevision,
                operationID: reservedRetirementSaveID
            )
            let retirementBaselineSnapshot = await restartedClient.snapshot()
            let retirementBaseline = try XCTUnwrap(retirementBaselineSnapshot.workspaces.first {
                $0.document.workspaceID == workspace.id
            })
            var incompleteRetirement = restartedWorking
            incompleteRetirement.isHiddenInMenus = true
            incompleteRetirement.consolidatedIntoWorkspaceID = canonicalID
            let retirement = try await restartedClient.saveFailClosed(
                incompleteRetirement,
                fileURL: retirementBaseline.document.fileURL,
                expectedWorkspaceRevision: retirementReservation.after?.workingRevision
                    ?? retirementBaseline.revisions.workingRevision,
                expectedContentDigest: retirementReservation.resultingDigest
                    ?? retirementBaseline.document.contentDigest,
                operationIDs: DomainWorkspaceSaveOperationIDs(
                    working: UUID(),
                    saved: reservedRetirementSaveID
                )
            )
            XCTAssertTrue(retirement.workingCommitted)
            XCTAssertEqual(retirement.saved?.errorCode, .operationIDCollision)

            let staleActivation = await staleActivationManager.switchWorkspace(
                to: staleActivationTarget,
                saveState: false,
                reason: "workingOnlyRetirementActivationTest"
            )
            XCTAssertFalse(staleActivation.didSwitch)
            XCTAssertNotEqual(staleActivationManager.activeWorkspaceID, workspace.id)
        }

        func testSidecarMigrationRejectsAliasingAndStaleDestinations() throws {
            let fileManager = FileManager.default
            let aliasRoot = storageRoot.appendingPathComponent("sidecar-alias", isDirectory: true)
            let physicalRoot = storageRoot.appendingPathComponent("sidecar-physical", isDirectory: true)
            let physicalFolder = physicalRoot.appendingPathComponent("AgentSessions", isDirectory: true)
            try fileManager.createDirectory(at: physicalFolder, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: aliasRoot, withDestinationURL: physicalRoot)

            XCTAssertThrowsError(try WorkspaceSessionSidecarMigration.validateDistinctSessionFolders(
                source: physicalFolder,
                destination: aliasRoot.appendingPathComponent("AgentSessions", isDirectory: true)
            )) { error in
                guard case WorkspaceSessionSidecarMigrationError.aliasedSessionFolders = error else {
                    return XCTFail("Expected aliased session folders, got \(error)")
                }
            }

            let absentSessionID = UUID()
            let absentCanonicalID = UUID()
            let absentSource = storageRoot.appendingPathComponent("absent-source", isDirectory: true)
            let absentDestination = storageRoot.appendingPathComponent("absent-destination", isDirectory: true)
            try fileManager.createDirectory(at: absentSource, withIntermediateDirectories: true)
            let absentFilename = "AgentSession-\(absentSessionID.uuidString).json"
            let absentSourceURL = absentSource.appendingPathComponent(absentFilename)
            let absentSourceData = try sidecarData(
                sessionID: absentSessionID,
                workspaceID: UUID(),
                name: "Prepared absent"
            )
            try absentSourceData.write(to: absentSourceURL, options: .atomic)
            let absentCopies = try WorkspaceSessionSidecarMigration.prepareCopies(
                from: absentSource,
                to: absentDestination,
                filenamePrefix: "AgentSession-",
                canonicalWorkspaceID: absentCanonicalID
            )
            let absentBatch = WorkspaceSessionSidecarPreparedBatch(
                sourceFolder: absentSource,
                destinationFolder: absentDestination,
                filenamePrefix: "AgentSession-",
                copies: absentCopies
            )
            try Data("source changed after prepare".utf8).write(to: absentSourceURL, options: .atomic)
            XCTAssertThrowsError(try WorkspaceSessionSidecarMigration.commitPreparedBatch(absentBatch)) { error in
                guard case WorkspaceSessionSidecarMigrationError.sourceChanged = error else {
                    return XCTFail("Expected changed source, got \(error)")
                }
            }
            try absentSourceData.write(to: absentSourceURL, options: .atomic)
            try fileManager.createDirectory(at: absentDestination, withIntermediateDirectories: true)
            let appearedURL = absentDestination.appendingPathComponent(absentFilename)
            let appearedData = Data("appeared after prepare".utf8)
            try appearedData.write(to: appearedURL, options: .atomic)
            XCTAssertThrowsError(try WorkspaceSessionSidecarMigration.commitPreparedBatch(absentBatch)) { error in
                guard case WorkspaceSessionSidecarMigrationError.destinationChanged = error else {
                    return XCTFail("Expected changed absent destination, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: appearedURL), appearedData)

            let changedSessionID = UUID()
            let changedSource = storageRoot.appendingPathComponent("changed-source", isDirectory: true)
            let changedDestination = storageRoot.appendingPathComponent("changed-destination", isDirectory: true)
            try fileManager.createDirectory(at: changedSource, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: changedDestination, withIntermediateDirectories: true)
            let changedFilename = "AgentSession-\(changedSessionID.uuidString).json"
            let preparedExistingData = try sidecarData(
                sessionID: changedSessionID,
                workspaceID: UUID(),
                name: "Prepared existing"
            )
            try preparedExistingData.write(
                to: changedSource.appendingPathComponent(changedFilename),
                options: .atomic
            )
            let changedURL = changedDestination.appendingPathComponent(changedFilename)
            try preparedExistingData.write(to: changedURL, options: .atomic)
            let changedCopies = try WorkspaceSessionSidecarMigration.prepareCopies(
                from: changedSource,
                to: changedDestination,
                filenamePrefix: "AgentSession-",
                canonicalWorkspaceID: UUID()
            )
            let changedBatch = WorkspaceSessionSidecarPreparedBatch(
                sourceFolder: changedSource,
                destinationFolder: changedDestination,
                filenamePrefix: "AgentSession-",
                copies: changedCopies
            )
            let interveningData = try sidecarData(
                sessionID: changedSessionID,
                workspaceID: UUID(),
                name: "Changed after prepare"
            )
            try interveningData.write(to: changedURL, options: .atomic)
            XCTAssertThrowsError(try WorkspaceSessionSidecarMigration.commitPreparedBatch(changedBatch)) { error in
                guard case WorkspaceSessionSidecarMigrationError.destinationChanged = error else {
                    return XCTFail("Expected changed existing destination, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: changedURL), interveningData)
        }

        private func authoritativeWorkspace(
            _ workspaceID: UUID,
            in runtime: MCPDomainRuntime
        ) async throws -> WorkspaceModel {
            let snapshot = await runtime.workspaceStore.snapshot()
            let authoritative = try XCTUnwrap(snapshot.workspaces.first {
                $0.document.workspaceID == workspaceID
            })
            return try JSONDecoder().decode(
                WorkspaceModel.self,
                from: authoritative.document.documentBytes
            )
        }

        private func legacyIndexEntries() throws -> [WorkspaceIndexEntry] {
            try JSONDecoder().decode(
                [WorkspaceIndexEntry].self,
                from: Data(contentsOf: storageRoot.appendingPathComponent("workspacesIndex.json"))
            )
        }

        private func sidecarWorkspaceDirectory(
            for workspace: WorkspaceModel,
            root: URL
        ) -> URL {
            root.appendingPathComponent(
                WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id),
                isDirectory: true
            )
        }

        private func sidecarData(
            sessionID: UUID,
            workspaceID: UUID,
            name: String
        ) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: [
                    "id": sessionID.uuidString,
                    "workspaceID": workspaceID.uuidString,
                    "name": name
                ],
                options: [.sortedKeys]
            )
        }
    }

    private actor WorkspaceDuplicateCleanupSuspensionGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
#endif
