@testable import RepoPromptApp
import RepoPromptDomainRuntime
@_spi(TestSupport) import RepoPromptShared
import XCTest

#if DEBUG
    /// Drives the real owning stores against two isolated profile roots. Each profile resolves through
    /// the shared root override, which is how every store finds its profile, and opts in to the debug
    /// isolation policy that XCTest leaves off by default.
    @MainActor
    final class DebugProfilePersistenceIsolationTests: XCTestCase {
        private var fixtureRoot: URL!
        private var originalStoragePath: String?
        private var originalAutoRestore: Any?
        private var originalMCPAutoStart = false
        private var managers: [WorkspaceManagerViewModel] = []

        private var debugRoot: URL {
            fixtureRoot.appendingPathComponent("debug-home/Library/Application Support/RepoPrompt CE Debug", isDirectory: true)
        }

        private var releaseRoot: URL {
            fixtureRoot.appendingPathComponent("release-home/Library/Application Support/RepoPrompt CE", isDirectory: true)
        }

        private var externalStorage: URL {
            fixtureRoot.appendingPathComponent("external-storage", isDirectory: true)
        }

        override func setUp() async throws {
            try await super.setUp()
            fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("DebugProfilePersistenceIsolationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: externalStorage, withIntermediateDirectories: true)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            originalAutoRestore = UserDefaults.standard.object(forKey: "shouldAutoRestoreFromDownloadsV2")
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        }

        override func tearDown() async throws {
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            WorkspaceStoragePaths.test_setIsolatesDebugProfile(nil)
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(nil)
            restoreDefault(originalStoragePath, forKey: "GlobalCustomStorageURL")
            restoreDefault(originalAutoRestore, forKey: "shouldAutoRestoreFromDownloadsV2")
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try? FileManager.default.removeItem(at: fixtureRoot)
            try await super.tearDown()
        }

        // MARK: - Paired sentinels through the owning stores

        func testOwningStoresKeepPairedMarkersInTheirOwnProfileAcrossRestart() async throws {
            let profiles = [
                PairedProfile(
                    identity: .repoPromptCE(.debug),
                    root: debugRoot,
                    isolates: true,
                    marker: UUID(),
                    date: Date(timeIntervalSince1970: 1_900_000_000)
                ),
                PairedProfile(
                    identity: .repoPromptCE(.release),
                    root: releaseRoot,
                    isolates: false,
                    marker: UUID(),
                    date: Date(timeIntervalSince1970: 1_900_000_600)
                )
            ]
            var written: [URL: WrittenMarkers] = [:]
            for profile in profiles {
                written[profile.root] = try await writeMarkers(for: profile)
            }

            for profile in profiles {
                let other = try XCTUnwrap(profiles.first { $0.root != profile.root })
                try await assertMarkersReadBack(for: profile, written: XCTUnwrap(written[profile.root]))
                try assertProfileFiles(under: profile.root, contain: profile.marker, exclude: other.marker)
            }
        }

        // MARK: - Saved storage overrides

        func testIsolatedDebugIgnoresSavedGlobalStorageAndSkipsExternalIndexEntries() async throws {
            let savedGlobalPath = externalStorage.path
            UserDefaults.standard.set(savedGlobalPath, forKey: "GlobalCustomStorageURL")
            useProfile(debugRoot, isolates: true)
            let workspaces = debugRoot.appendingPathComponent("Workspaces", isDirectory: true)

            let inRoot = WorkspaceModel(name: "In Root", repoPaths: [fixtureRoot.path])
            let insideCustomFolder = workspaces.appendingPathComponent("inside-custom", isDirectory: true)
            let insideCustom = WorkspaceModel(name: "Inside Custom", repoPaths: [fixtureRoot.path], customStoragePath: insideCustomFolder)
            let externalFolder = externalStorage.appendingPathComponent("external-workspace", isDirectory: true)
            let external = WorkspaceModel(name: "External", repoPaths: [fixtureRoot.path], customStoragePath: externalFolder)
            let redirected = WorkspaceModel(name: "Global Redirect", repoPaths: [fixtureRoot.path])
            try writeWorkspace(
                inRoot,
                to: workspaces.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: inRoot.name, id: inRoot.id))
            )
            try writeWorkspace(insideCustom, to: insideCustomFolder)
            try writeWorkspace(external, to: externalFolder)
            try writeIndex([inRoot, insideCustom, external], in: workspaces)
            try writeWorkspace(
                redirected,
                to: externalStorage.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: redirected.name, id: redirected.id))
            )
            try writeIndex([redirected], in: externalStorage)
            let externalBefore = try fileContents(under: externalStorage)

            let manager = makeManager(windowID: -8101)
            await manager.awaitInitialized()

            XCTAssertEqual(Set(manager.workspaces.map(\.id)), [inRoot.id, insideCustom.id])
            XCTAssertEqual(manager.effectiveWorkspaceStorageRoot.standardizedFileURL, workspaces.standardizedFileURL)
            XCTAssertEqual(manager.ignoredGlobalCustomStoragePath, savedGlobalPath)
            XCTAssertEqual(
                manager.workspaceDirectory(for: external).standardizedFileURL,
                workspaces.appendingPathComponent(manager.directoryName(for: external)).standardizedFileURL
            )

            XCTAssertThrowsError(try manager.updateGlobalStoragePath(fixtureRoot.appendingPathComponent("relocated"))) { error in
                XCTAssertEqual(error as? WorkspaceStorageIsolationError, .customStorageUnavailable)
            }
            XCTAssertThrowsError(try manager.resetGlobalStorageToDefault()) { error in
                XCTAssertEqual(error as? WorkspaceStorageIsolationError, .customStorageUnavailable)
            }
            XCTAssertEqual(UserDefaults.standard.string(forKey: "GlobalCustomStorageURL"), savedGlobalPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("relocated").path))

            // A create rebuilds the index from loaded workspaces; the refused entry must survive it.
            let created = manager.createWorkspace(name: "Created In Debug", repoPaths: [fixtureRoot.path])
            let rebuiltIndex = try await waitForIndex(in: workspaces, toContain: created.id)
            XCTAssertNil(created.customStoragePath)
            XCTAssertEqual(
                Set(rebuiltIndex.map(\.id)),
                [inRoot.id, insideCustom.id, external.id, created.id]
            )
            XCTAssertEqual(
                rebuiltIndex.first { $0.id == external.id }?.customStoragePath?.standardizedFileURL,
                externalFolder.standardizedFileURL
            )
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: manager.workspaceFileURL(for: created).path
            ))
            XCTAssertTrue(manager.workspaceFileURL(for: created).path.hasPrefix(workspaces.path + "/"))
            XCTAssertEqual(try fileContents(under: externalStorage), externalBefore)
        }

        func testIsolatedDebugNeverRestoresTheDownloadsBackupAndKeepsThePreference() async throws {
            UserDefaults.standard.set(true, forKey: "shouldAutoRestoreFromDownloadsV2")
            useProfile(debugRoot, isolates: true)
            let manager = makeManager(windowID: -8102)
            await manager.awaitInitialized()

            do {
                try await manager.restoreUserDataFromDownloadsFolder()
                XCTFail("The isolated debug profile must not import the shared Downloads backup")
            } catch {
                XCTAssertEqual(error as? WorkspaceStorageIsolationError, .customStorageUnavailable)
            }
            XCTAssertTrue(manager.shouldAutoRestoreFromDownloads)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "shouldAutoRestoreFromDownloadsV2") as? Bool, true)
        }

        func testChatAndAgentSessionStoresRefuseExternalWorkspaceBacking() async throws {
            useProfile(debugRoot, isolates: true)
            let externalFolder = externalStorage.appendingPathComponent("external-workspace", isDirectory: true)
            let sessionsFolder = externalFolder.appendingPathComponent("AgentSessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
            let existingSession = AgentSession(name: "External Session")
            try JSONEncoder().encode(existingSession).write(
                to: sessionsFolder.appendingPathComponent("AgentSession-\(existingSession.id.uuidString).json")
            )
            let workspace = WorkspaceModel(name: "External", repoPaths: [fixtureRoot.path], customStoragePath: externalFolder)
            let externalBefore = try fileContents(under: externalStorage)

            await assertIsolationRejection {
                _ = try await ChatDataService().saveChatSession(ChatSession(name: "Rejected Chat"), for: workspace)
            }
            await assertIsolationRejection {
                _ = try await AgentSessionDataService().saveAgentSession(
                    AgentSession(name: "Rejected Session"),
                    for: workspace,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: 0
                )
            }
            await assertIsolationRejection {
                _ = try await AgentSessionDataService().listAgentSessions(for: workspace)
            }
            XCTAssertThrowsError(
                try WorkspaceSessionSidecarMigration.workspaceDirectory(
                    for: workspace,
                    root: debugRoot.appendingPathComponent("Workspaces", isDirectory: true)
                )
            ) { error in
                XCTAssertEqual(error as? WorkspaceStorageIsolationError, .customStorageUnavailable)
            }
            XCTAssertEqual(try fileContents(under: externalStorage), externalBefore)
        }

        func testSessionStoresRefuseSessionFoldersLinkedIntoProduction() async throws {
            useProfile(debugRoot, isolates: true)
            let workspace = WorkspaceModel(name: "Linked", repoPaths: [fixtureRoot.path])
            let directoryName = WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id)
            let debugFolder = debugRoot.appendingPathComponent("Workspaces", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            let productionFolder = releaseRoot.appendingPathComponent("Workspaces", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: debugFolder, withIntermediateDirectories: true)
            for name in ["Chats", "AgentSessions"] {
                let target = productionFolder.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try Data(#"{"marker":"production"}"#.utf8).write(to: target.appendingPathComponent("sentinel.json"))
                try FileManager.default.createSymbolicLink(
                    at: debugFolder.appendingPathComponent(name, isDirectory: true),
                    withDestinationURL: target
                )
            }
            let chats = debugFolder.appendingPathComponent("Chats", isDirectory: true)
            let agentSessions = debugFolder.appendingPathComponent("AgentSessions", isDirectory: true)
            let productionBefore = try fileContents(under: releaseRoot)

            await assertStorageRejection(naming: chats) {
                _ = try await ChatDataService().saveChatSession(ChatSession(name: "Linked Chat"), for: workspace)
            }
            await assertStorageRejection(naming: chats) {
                _ = try await ChatDataService().listChatSessions(for: workspace)
            }
            await assertStorageRejection(naming: agentSessions) {
                _ = try await AgentSessionDataService().saveAgentSession(
                    AgentSession(name: "Linked Session"),
                    for: workspace,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: 0
                )
            }
            await assertStorageRejection(naming: agentSessions) {
                _ = try await AgentSessionDataService().listAgentSessions(for: workspace)
            }
            XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore)
        }

        func testLegacyWorkspaceLoadersRefuseDocumentsLinkedIntoProduction() async throws {
            useProfile(debugRoot, isolates: true)
            let workspaces = debugRoot.appendingPathComponent("Workspaces", isDirectory: true)
            let productionWorkspaces = releaseRoot.appendingPathComponent("Workspaces", isDirectory: true)
            let kept = WorkspaceModel(name: "Kept", repoPaths: [fixtureRoot.path])
            let linkedFolder = WorkspaceModel(name: "Linked Folder", repoPaths: [fixtureRoot.path])
            let linkedDocument = WorkspaceModel(name: "Linked Document", repoPaths: [fixtureRoot.path])
            func folder(_ workspace: WorkspaceModel, in root: URL) -> URL {
                root.appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
            }
            try writeWorkspace(kept, to: folder(kept, in: workspaces))
            for workspace in [kept, linkedFolder, linkedDocument] {
                var production = workspace
                production.name = "Production \(workspace.name)"
                production.activePresetID = UUID()
                try writeWorkspace(production, to: folder(workspace, in: productionWorkspaces))
            }
            // Neither index entry names a custom location: one generated folder is a link into
            // production, and the other is a real folder whose document is.
            try link(folder(linkedFolder, in: workspaces), to: folder(linkedFolder, in: productionWorkspaces))
            try link(
                folder(linkedDocument, in: workspaces).appendingPathComponent("workspace.json"),
                to: folder(linkedDocument, in: productionWorkspaces).appendingPathComponent("workspace.json")
            )
            try writeIndex([kept, linkedFolder, linkedDocument], in: workspaces)
            let productionBefore = try fileContents(under: releaseRoot)

            let manager = makeManager(windowID: -8103)
            await manager.awaitInitialized()
            XCTAssertEqual(manager.workspaces.map(\.id), [kept.id])
            let initialSnapshot = await manager.loadWorkspaceSnapshotFromDisk()
            XCTAssertEqual(initialSnapshot.map(\.id), [kept.id])

            // The loaded workspace's document is then replaced by a link to production's copy.
            let keptDocument = folder(kept, in: workspaces).appendingPathComponent("workspace.json")
            try FileManager.default.removeItem(at: keptDocument)
            try link(keptDocument, to: folder(kept, in: productionWorkspaces).appendingPathComponent("workspace.json"))
            manager.reloadPresetsFromDisk()
            await manager.test_waitForDiskReloads()
            XCTAssertNil(manager.workspaces.first(where: { $0.id == kept.id })?.activePresetID)
            manager.reloadWorkspacesFromDisk()
            await manager.test_waitForDiskReloads()
            XCTAssertFalse(
                manager.workspaces.contains { $0.name.hasPrefix("Production") },
                "\(manager.workspaces.map(\.name))"
            )
            let linkedSnapshot = await manager.loadWorkspaceSnapshotFromDisk()
            XCTAssertTrue(linkedSnapshot.isEmpty, "\(linkedSnapshot.map(\.name))")

            let created = manager.createWorkspace(name: "Created In Debug", repoPaths: [fixtureRoot.path])
            let rebuiltIndex = try await waitForIndex(in: workspaces, toContain: created.id)
            XCTAssertTrue(
                Set(rebuiltIndex.map(\.id)).isSuperset(of: [kept.id, linkedFolder.id, linkedDocument.id]),
                "\(rebuiltIndex.map(\.name))"
            )
            XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore)
        }

        func testSessionFilesLinkedIntoProductionAreRefused() async throws {
            let workspace = WorkspaceModel(name: "Session Files", repoPaths: [fixtureRoot.path])
            useProfile(releaseRoot, isolates: false)
            let productionChat = try await ChatDataService().saveChatSession(
                ChatSession(name: "Production Chat"),
                for: workspace
            )
            let productionSession = try await saveIndexedAgentSession(named: "Production Session", for: workspace)
            let productionIndex = productionSession.deletingLastPathComponent()
                .appendingPathComponent("AgentSessionIndex.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: productionIndex.path))

            // The debug session folders are real; only the files inside them link to production.
            let debugFolder = debugRoot.appendingPathComponent("Workspaces", isDirectory: true)
                .appendingPathComponent(
                    WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
            let chatLink = debugFolder.appendingPathComponent("Chats/\(productionChat.lastPathComponent)")
            let sessionLink = debugFolder.appendingPathComponent("AgentSessions/\(productionSession.lastPathComponent)")
            let indexLink = debugFolder.appendingPathComponent("AgentSessions/AgentSessionIndex.json")
            try link(chatLink, to: productionChat)
            try link(sessionLink, to: productionSession)
            try link(indexLink, to: productionIndex)
            useProfile(debugRoot, isolates: true)
            let productionBefore = try fileContents(under: releaseRoot)

            await assertStorageRejection(naming: chatLink) {
                _ = try await ChatDataService().loadChatSession(from: chatLink)
            }
            await assertStorageRejection(naming: chatLink) {
                _ = try await ChatDataService().loadChatSessionStub(from: chatLink)
            }
            await assertStorageRejection(naming: sessionLink) {
                _ = try await AgentSessionDataService().loadAgentSession(from: sessionLink)
            }
            let metas = await (try? AgentSessionDataService().listAgentSessionsMeta(for: workspace)) ?? []
            XCTAssertFalse(metas.contains { $0.name == "Production Session" }, "\(metas.map(\.name))")
            XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: indexLink.path), productionIndex.path)
        }

        func testPartitionFolderLinkedIntoProductionIsRefused() async throws {
            let rootPath = fixtureRoot.appendingPathComponent("repository", isDirectory: true).path
            let scope = PartitionScope(workspaceID: UUID())
            useProfile(releaseRoot, isolates: false)
            try await PartitionStore().save(
                forRoot: rootPath,
                scope: scope,
                data: PartitionStore.PartitionData(
                    version: 1,
                    files: ["production.swift": PartitionStore.StoredSlices(ranges: [], fileModificationTime: nil)],
                    updatedAt: nil
                )
            )
            let productionPartitions = releaseRoot.appendingPathComponent("Partitions", isDirectory: true)
            let repositoryFolder = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(at: productionPartitions, includingPropertiesForKeys: nil).first
            )
            useProfile(debugRoot, isolates: true)
            let folderLink = debugRoot.appendingPathComponent("Partitions", isDirectory: true)
                .appendingPathComponent(repositoryFolder.lastPathComponent, isDirectory: true)
            try link(folderLink, to: repositoryFolder)
            let productionBefore = try fileContents(under: releaseRoot)

            let loaded = await PartitionStore().load(forRoot: rootPath, scope: scope)
            XCTAssertTrue(loaded.files.isEmpty, "\(loaded.files.keys)")
            await assertStorageRejection(naming: folderLink) {
                try await PartitionStore().save(forRoot: rootPath, scope: scope, data: .empty())
            }
            XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore)
        }

        func testWorkflowFilesLinkedIntoProductionAreNotRead() throws {
            let productionWorkflow = releaseRoot.appendingPathComponent("Workflows/shared.md")
            try FileManager.default.createDirectory(
                at: productionWorkflow.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("---\nid: \(UUID().uuidString)\nname: Production Workflow\n---\nProduction body\n".utf8)
                .write(to: productionWorkflow)
            useProfile(debugRoot, isolates: true)
            let workflowLink = debugRoot.appendingPathComponent("Workflows/shared.md")
            try link(workflowLink, to: productionWorkflow)

            AgentWorkflowStore.shared.refresh()
            let names = AgentWorkflowStore.shared.customWorkflows.map(\.displayName)
            try FileManager.default.removeItem(at: workflowLink)
            AgentWorkflowStore.shared.refresh()

            XCTAssertFalse(names.contains("Production Workflow"), "\(names)")
        }

        func testHistoryScannerSkipsWorkspaceFoldersLinkedIntoProduction() async throws {
            let workspace = WorkspaceModel(name: "History", repoPaths: [fixtureRoot.path])
            useProfile(releaseRoot, isolates: false)
            _ = try await saveIndexedAgentSession(named: "Production Session", for: workspace)
            let directoryName = WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id)
            let productionFolder = releaseRoot.appendingPathComponent("Workspaces/\(directoryName)", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: productionFolder.appendingPathComponent("AgentSessions/AgentSessionIndex.json").path
            ))
            useProfile(debugRoot, isolates: true)
            try link(debugRoot.appendingPathComponent("Workspaces/\(directoryName)", isDirectory: true), to: productionFolder)
            let productionBefore = try fileContents(under: releaseRoot)

            let results = try await HistorySessionScanner(applicationSupportRoot: debugRoot).scanAllWorkspacesRefreshing()

            XCTAssertTrue(results.allSatisfy(\.records.isEmpty), "\(results.map(\.workspaceName))")
            XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore)
        }

        func testGitDataLinkedIntoProductionIsNeitherPurgedNorRemoved() async throws {
            useProfile(debugRoot, isolates: true)
            let workspaceDirectory = debugRoot.appendingPathComponent("Workspaces/Git Data", isDirectory: true)
            let productionGitData = releaseRoot.appendingPathComponent("Workspaces/Git Data/_git_data", isDirectory: true)
            let legacySnapshot = productionGitData.appendingPathComponent("diff-snapshots/legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: legacySnapshot, withIntermediateDirectories: true)
            try Data(#"{"marker":"production"}"#.utf8).write(to: legacySnapshot.appendingPathComponent("manifest.json"))
            try Data("legacy".utf8).write(to: productionGitData.appendingPathComponent("CURRENT"))
            let gitDataLink = workspaceDirectory.appendingPathComponent("_git_data", isDirectory: true)
            try link(gitDataLink, to: productionGitData)
            let productionBefore = try fileContents(under: releaseRoot)

            _ = await GitDiffDataMaintenance.shared.runOnWorkspaceOpen(workspaceDirectory: workspaceDirectory)
            _ = await GitDiffDataMaintenance.shared.deleteSnapshotsForTabs(
                workspaceDirectory: workspaceDirectory,
                tabIDs: [UUID()]
            )
            let removed = await GitDiffDataMaintenance.shared.deleteAllGitData(workspaceDirectory: workspaceDirectory)

            XCTAssertFalse(removed)
            XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: gitDataLink.path), productionGitData.path)
        }

        func testDefaultMergePreviewDestinationPublishesArtifactsInsideTheDebugProfile() async throws {
            let repository = try ReviewGitRepositoryFixture(name: "MergePreviewDestination")
            defer { repository.cleanup() }
            let repo = try repository.makeRepository(named: "repo", files: ["notes.txt": "one\n"])
            try repository.write("two\n", to: "notes.txt", at: repo)
            try repository.stage("notes.txt", at: repo)
            try repository.commit("Second commit", at: repo)

            useProfile(releaseRoot, isolates: false)
            XCTAssertEqual(
                AgentModeViewModel.worktreeMergePreviewDirectory(requested: nil, workspaceManager: nil),
                FileManager.default.temporaryDirectory
            )

            useProfile(debugRoot, isolates: true)
            let manager = makeManager(windowID: -8111)
            await manager.awaitInitialized()
            let workspace = manager.createWorkspace(name: "Merge Preview", repoPaths: [repo.path])
            manager.activeWorkspace = workspace
            XCTAssertNil(workspace.customStoragePath)
            // Neither directory override is present: no requested directory and no custom storage
            // path, with and without an active workspace.
            let destinations = [
                AgentModeViewModel.worktreeMergePreviewDirectory(requested: nil, workspaceManager: manager),
                AgentModeViewModel.worktreeMergePreviewDirectory(requested: nil, workspaceManager: nil)
            ]
            for directory in destinations {
                let manifest: GitDiffSnapshotManifest
                do {
                    manifest = try await GitDiffSnapshotPublisher.shared.publish(
                        workspaceDirectory: directory,
                        repoURL: repo,
                        mode: .standard,
                        compareSpec: .revspec("HEAD~1..HEAD"),
                        compareDisplay: "merge-preview:HEAD~1..HEAD",
                        compareInput: nil,
                        scope: .all,
                        selectedAbsolutePaths: [],
                        contextLines: 3,
                        detectRenames: false,
                        snapshotIDOverride: nil
                    )
                } catch {
                    XCTFail("Publishing the merge preview into \(directory.path) failed: \(error)")
                    continue
                }
                let gitData = GitDiffSnapshotStore().gitDataRoot(workspaceDirectory: directory)
                XCTAssertFalse(manifest.snapshotID.isEmpty)
                XCTAssertTrue(FileManager.default.fileExists(atPath: gitData.path), gitData.path)
                XCTAssertTrue(
                    MCPFilesystemPathContainment.resolvesStrictlyInside(gitData, root: debugRoot),
                    gitData.path
                )
            }
        }

        // MARK: - Composition

        func testCompositionIgnoresSavedCustomStorageOnlyForIsolatedDebug() throws {
            let suiteName = "DebugProfilePersistenceIsolationTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(externalStorage.path, forKey: "GlobalCustomStorageURL")

            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugRoot)
            let debug = AppDomainRuntimeComposition.makeConfiguration(
                identity: .repoPromptCE(.debug),
                isolatesDebugProfile: true,
                defaults: defaults
            )
            XCTAssertEqual(debug.storageDirectory.standardizedFileURL, debugRoot.standardizedFileURL)
            XCTAssertEqual(
                debug.workspaceStorageDirectory.standardizedFileURL,
                debugRoot.appendingPathComponent("Workspaces", isDirectory: true).standardizedFileURL
            )
            XCTAssertEqual(
                debug.temporaryDirectory.standardizedFileURL,
                MCPFilesystemIdentity.repoPromptCE(.debug).temporaryRootURL().standardizedFileURL
            )
            XCTAssertTrue(debug.enforcesWorkspaceStorageBoundary)
            let migratedValues = debug.legacyRuntimeDefaults.values.compactMap { try? JSONDecoder().decode(String.self, from: $0) }
            XCTAssertFalse(migratedValues.contains(externalStorage.path))

            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(releaseRoot)
            let release = AppDomainRuntimeComposition.makeConfiguration(
                identity: .repoPromptCE(.release),
                isolatesDebugProfile: false,
                defaults: defaults
            )
            XCTAssertEqual(release.storageDirectory.standardizedFileURL, releaseRoot.standardizedFileURL)
            XCTAssertEqual(release.workspaceStorageDirectory.standardizedFileURL, externalStorage.standardizedFileURL)
            XCTAssertFalse(release.enforcesWorkspaceStorageBoundary)
            XCTAssertEqual(defaults.string(forKey: "GlobalCustomStorageURL"), externalStorage.path)
        }

        func testAppAdapterSelectsTheCompiledDebugFlavor() {
            XCTAssertEqual(MCPFilesystemConstants.identity, .repoPromptCE(.debug))
            XCTAssertEqual(MCPFilesystemConstants.identity.applicationSupportDirectoryName, "RepoPrompt CE Debug")
        }

        // MARK: - Logs and prompt stores

        func testCodexStateFollowsTheDebugProfileInInjectedAndDefaultModes() {
            let injectedParent = fixtureRoot.appendingPathComponent("injected-support", isDirectory: true)
            let injected = CodexRuntimeAuthority.statePaths(applicationSupportURL: injectedParent)
            XCTAssertEqual(
                injected.codexHome.standardizedFileURL,
                injectedParent.appendingPathComponent("RepoPrompt CE Debug/Codex/Debug/home", isDirectory: true).standardizedFileURL
            )

            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugRoot)
            let defaultPaths = CodexRuntimeAuthority.statePaths()
            XCTAssertEqual(
                defaultPaths.codexHome.standardizedFileURL,
                debugRoot.appendingPathComponent("Codex/Debug/home", isDirectory: true).standardizedFileURL
            )
            XCTAssertEqual(
                defaultPaths.sqliteHome.standardizedFileURL,
                debugRoot.appendingPathComponent("Codex/Debug/sqlite", isDirectory: true).standardizedFileURL
            )
        }

        func testSavedPromptStoresKeepTheReleaseLocationAndMoveDebugIntoItsProfile() {
            let release = PromptStorage.defaultSupportDirectoryURL(identity: .repoPromptCE(.release))
            XCTAssertEqual(
                release.path,
                NSHomeDirectory() + "/Library/Application Support/com.pvncher.repoprompt"
            )

            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugRoot)
            XCTAssertEqual(
                PromptStorage.defaultSupportDirectoryURL().standardizedFileURL,
                debugRoot.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true).standardizedFileURL
            )

            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(nil)
            let sandboxed = PromptStorage.defaultSupportDirectoryURL().standardizedFileURL
            XCTAssertTrue(sandboxed.path.hasSuffix("/RepoPrompt CE Debug/com.pvncher.repoprompt"), sandboxed.path)
            XCTAssertNotEqual(sandboxed.path, release.standardizedFileURL.path)
        }

        // MARK: - Early launch gate

        func testLauncherRejectsAProductionAliasWithoutCreatingState() throws {
            let production = fixtureRoot.appendingPathComponent("production/RepoPrompt CE", isDirectory: true)
            try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
            try Data("production".utf8).write(to: production.appendingPathComponent("sentinel.json"))
            let alias = fixtureRoot.appendingPathComponent("debug-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: production)
            let productionBefore = try fileContents(under: production)
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(alias)

            let failure = RepoPromptApplicationLauncher.profileIsolationFailure(
                identity: .repoPromptCE(.debug),
                productionStateRoots: [production]
            )
            let releaseFailure = RepoPromptApplicationLauncher.profileIsolationFailure(
                identity: .repoPromptCE(.release),
                productionStateRoots: [production]
            )

            guard case let .overlapsProduction(location)? = failure as? MCPProfileIsolationError else {
                return XCTFail("Expected an overlapsProduction failure, got \(String(describing: failure))")
            }
            XCTAssertEqual(location.standardizedFileURL.path, alias.standardizedFileURL.path)
            XCTAssertNil(releaseFailure)
            XCTAssertEqual(try fileContents(under: production), productionBefore)

            let clean = fixtureRoot.appendingPathComponent("clean-debug", isDirectory: true)
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(clean)
            XCTAssertNil(RepoPromptApplicationLauncher.profileIsolationFailure(
                identity: .repoPromptCE(.debug),
                productionStateRoots: [production]
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
        }

        func testLauncherRejectsDeclaredStoreFilesLinkedIntoProduction() throws {
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugRoot)
            let runtimeRoot = DomainRuntimeConfiguration.runtimeRootDirectory(
                storageDirectory: debugRoot,
                profileIdentifier: "default"
            )
            let runtimeRelative = String(
                runtimeRoot.standardizedFileURL.path.dropFirst(debugRoot.standardizedFileURL.path.count + 1)
            )
            // Each declared destination is linked into production on its own, so the failure names it.
            let rows: [(debug: String, production: String, isDirectory: Bool)] = [
                ("Settings/globalSettings.json", "Settings/globalSettings.json", false),
                ("Settings/Backups", "Settings/Backups", true),
                ("Presets/workflowPresets.json", "Presets/workflowPresets.json", false),
                ("Presets/modelPresets.json", "Presets/modelPresets.json", false),
                ("Presets/Backups", "Presets/Backups", true),
                ("Diagnostics/identity-transition-v1.json", "Diagnostics/identity-transition-v1.json", false),
                ("Codex/Debug/home/config.toml", "Codex/Release/home/config.toml", false),
                ("MCP/mcp-routing_debug.json", "MCP/mcp-routing.json", false),
                ("MCP/mcp-config_debug.json", "MCP/mcp-config.json", false),
                ("Workspaces/workspacesIndex.json", "Workspaces/workspacesIndex.json", false),
                ("DomainRuntime/v1/agent-sessions.json", "DomainRuntime/v1/agent-sessions.json", false),
                ("\(runtimeRelative)/workspace-catalog.json", "\(runtimeRelative)/workspace-catalog.json", false),
                ("\(runtimeRelative)/settings/runtime-policy.json", "\(runtimeRelative)/settings/runtime-policy.json", false)
            ]
            for row in rows {
                let target = releaseRoot.appendingPathComponent(row.production, isDirectory: row.isDirectory)
                try makeSentinel(at: target, isDirectory: row.isDirectory)
                let linkURL = debugRoot.appendingPathComponent(row.debug, isDirectory: row.isDirectory)
                try link(linkURL, to: target)
                let productionBefore = try fileContents(under: releaseRoot)

                let failure = RepoPromptApplicationLauncher.profileIsolationFailure(
                    identity: .repoPromptCE(.debug),
                    productionStateRoots: [releaseRoot]
                )

                if case let .overlapsProduction(location)? = failure as? MCPProfileIsolationError {
                    XCTAssertEqual(location.standardizedFileURL.path, linkURL.standardizedFileURL.path, row.debug)
                } else {
                    XCTFail("\(row.debug): expected overlapsProduction, got \(String(describing: failure))")
                }
                XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore, row.debug)
                try FileManager.default.removeItem(at: linkURL)
            }
            XCTAssertNil(RepoPromptApplicationLauncher.profileIsolationFailure(
                identity: .repoPromptCE(.debug),
                productionStateRoots: [releaseRoot]
            ))
        }

        func testPromptStoresRefusePromptFilesLinkedToTheReleasePrompts() async throws {
            let releasePrompts = fixtureRoot.appendingPathComponent(
                "release-home/Library/Application Support/com.pvncher.repoprompt",
                isDirectory: true
            )
            let (releaseSaved, releaseBuilder) = try seedReleasePromptFiles(in: releasePrompts)
            // The debug prompt folder is real; only the files inside it link to the release copies.
            let debugPrompts = debugRoot.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
            let savedLink = debugPrompts.appendingPathComponent("SavedPrompts.json")
            let builderLink = debugPrompts.appendingPathComponent("ContextBuilderPrompts.json")
            try link(savedLink, to: releaseSaved)
            try link(builderLink, to: releaseBuilder)
            useProfile(debugRoot, isolates: true)
            let releaseBefore = try fileContents(under: releasePrompts)

            let storage = PromptStorage()
            if case let .success(prompts) = storage.loadPrompts() {
                XCTFail("The debug prompt store read the release prompts: \(prompts.map(\.title))")
            }
            let mutation = storage.mutatePrompts { prompts in
                let startingTitles = prompts.map(\.title)
                prompts.append(StoredPromptRecord(id: UUID(), title: "Debug", content: "debug prompt"))
                return (startingTitles, true)
            }
            if case let .success(result) = mutation {
                XCTFail("The prompt mutation started from \(result.value)")
            }
            assertStorageRejection(naming: savedLink, mutation.map { _ in () })
            let saved = await savePrompts(
                [StoredPromptRecord(id: UUID(), title: "Debug", content: "debug prompt")],
                using: storage
            )
            assertStorageRejection(naming: savedLink, saved)

            ContextBuilderPromptStorage.shared.loadPrompts()
            await drainMainQueue()
            XCTAssertFalse(ContextBuilderPromptStorage.shared.prompts.contains { $0.title == "Release" })
            ContextBuilderPromptStorage.shared.savePrompts([ContextBuilderPrompt(title: "Debug", content: "debug prompt")])
            ContextBuilderPromptStorage.shared.loadPrompts()
            await drainMainQueue()

            XCTAssertEqual(try fileContents(under: releasePrompts), releaseBefore)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: savedLink.path), releaseSaved.path)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: builderLink.path), releaseBuilder.path)
        }

        func testLauncherRejectsNestedManagedDirectoriesLinkedIntoProduction() throws {
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(debugRoot)
            for (debugPath, productionPath) in [
                ("DomainRuntime/v1", "DomainRuntime/v1"),
                ("Codex/Debug/home", "Codex/Release/home")
            ] {
                let target = releaseRoot.appendingPathComponent(productionPath, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try Data(#"{"marker":"production"}"#.utf8).write(to: target.appendingPathComponent("sentinel.json"))
                let link = debugRoot.appendingPathComponent(debugPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: link.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                let productionBefore = try fileContents(under: releaseRoot)

                let failure = RepoPromptApplicationLauncher.profileIsolationFailure(
                    identity: .repoPromptCE(.debug),
                    productionStateRoots: [releaseRoot]
                )

                guard case let .overlapsProduction(location)? = failure as? MCPProfileIsolationError else {
                    XCTFail("Expected overlapsProduction for \(debugPath), got \(String(describing: failure))")
                    continue
                }
                XCTAssertTrue(
                    MCPFilesystemPathContainment.isSameOrDescendant(location.standardizedFileURL, of: link.standardizedFileURL),
                    location.path
                )
                XCTAssertEqual(try fileContents(under: releaseRoot), productionBefore)
                try FileManager.default.removeItem(at: link)
            }
            XCTAssertNil(RepoPromptApplicationLauncher.profileIsolationFailure(
                identity: .repoPromptCE(.debug),
                productionStateRoots: [releaseRoot]
            ))
        }

        func testPromptStoresAndLauncherRefuseAPromptFolderLinkedToTheReleasePrompts() async throws {
            let releaseHome = fixtureRoot.appendingPathComponent("release-home", isDirectory: true)
            let releasePrompts = releaseHome
                .appendingPathComponent("Library/Application Support/com.pvncher.repoprompt", isDirectory: true)
            _ = try seedReleasePromptFiles(in: releasePrompts)
            try FileManager.default.createDirectory(at: debugRoot, withIntermediateDirectories: true)
            let link = debugRoot.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: releasePrompts)
            useProfile(debugRoot, isolates: true)
            let releaseBefore = try fileContents(under: releasePrompts)

            let failure = RepoPromptApplicationLauncher.profileIsolationFailure(
                identity: .repoPromptCE(.debug),
                productionStateRoots: MCPFilesystemIdentity.productionStateRoots(
                    homeDirectory: releaseHome,
                    temporaryDirectory: fixtureRoot.appendingPathComponent("release-tmp", isDirectory: true)
                )
            )
            if case let .overlapsProduction(location)? = failure as? MCPProfileIsolationError {
                XCTAssertEqual(location.lastPathComponent, link.lastPathComponent)
            } else {
                XCTFail("Expected overlapsProduction, got \(String(describing: failure))")
            }

            let storage = PromptStorage()
            if case let .success(prompts) = storage.loadPrompts() {
                XCTFail("The debug prompt store read the release prompts: \(prompts.map(\.title))")
            }
            let mutation = storage.mutatePrompts { prompts in
                prompts.append(StoredPromptRecord(id: UUID(), title: "Debug", content: "debug prompt"))
                return ((), true)
            }
            assertStorageRejection(naming: link, mutation.map { _ in () })
            let saved = await savePrompts(
                [StoredPromptRecord(id: UUID(), title: "Debug", content: "debug prompt")],
                using: storage
            )
            assertStorageRejection(naming: link, saved)
            // The store's serial queue runs the load after the save, so both have finished here.
            ContextBuilderPromptStorage.shared.savePrompts([ContextBuilderPrompt(title: "Debug", content: "debug prompt")])
            ContextBuilderPromptStorage.shared.loadPrompts()

            XCTAssertEqual(try fileContents(under: releasePrompts), releaseBefore)
        }

        // MARK: - Helpers

        private struct PairedProfile {
            let identity: MCPFilesystemIdentity
            let root: URL
            let isolates: Bool
            let marker: UUID
            let date: Date

            var workspaceName: String {
                "Paired \(marker.uuidString)"
            }
        }

        private struct WrittenMarkers {
            let chatURL: URL
            let agentSessionURL: URL
            let domainWorkspaceID: UUID
            let domainWorkingName: String
        }

        private func useProfile(_ root: URL, isolates: Bool) {
            MCPFilesystemIdentity.test_setApplicationSupportRootOverride(root)
            WorkspaceStoragePaths.test_setIsolatesDebugProfile(isolates)
        }

        /// Seeds the release prompt directory with one saved-prompt and one context-builder record,
        /// returning both file URLs for tests that link individual files into the debug profile.
        private func seedReleasePromptFiles(in directory: URL) throws -> (saved: URL, builder: URL) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let saved = directory.appendingPathComponent("SavedPrompts.json")
            let builder = directory.appendingPathComponent("ContextBuilderPrompts.json")
            try JSONEncoder().encode([StoredPromptRecord(id: UUID(), title: "Release", content: "release prompt")])
                .write(to: saved)
            try JSONEncoder().encode([ContextBuilderPrompt(title: "Release", content: "release prompt")])
                .write(to: builder)
            return (saved: saved, builder: builder)
        }

        /// Bridges the prompt store's completion-callback save into an awaited result.
        private func savePrompts(
            _ prompts: [StoredPromptRecord],
            using storage: PromptStorage
        ) async -> Result<Void, Error> {
            await withCheckedContinuation { continuation in
                storage.savePrompts(prompts) {
                    continuation.resume(returning: $0)
                }
            }
        }

        private func writeMarkers(for profile: PairedProfile) async throws -> WrittenMarkers {
            useProfile(profile.root, isolates: profile.isolates)
            let workspacesRoot = profile.root.appendingPathComponent("Workspaces", isDirectory: true)

            let settings = GlobalSettingsFileStore(now: { profile.date })
            XCTAssertEqual(settings.fileURL, profile.root.appendingPathComponent("Settings/globalSettings.json"))
            try settings.save(settings.loadOrCreateDefault())

            let presets = PresetFileStore(now: { profile.date })
            XCTAssertEqual(presets.workflowFileURL, profile.root.appendingPathComponent("Presets/workflowPresets.json"))
            try presets.saveWorkflowPresets(.init(copyVisibility: [profile.marker: true]))

            let windowSessionURL = WindowSessionStore.sessionFileURL()
            XCTAssertEqual(windowSessionURL, profile.root.appendingPathComponent("windowSessions.json"))
            await WindowSessionDiskWriter(fileURL: windowSessionURL).writeImmediately(WindowSessionSnapshot(
                version: 1,
                windows: [WindowSessionEntry(
                    windowKind: .standard,
                    workspaceID: profile.marker,
                    workspaceName: profile.workspaceName,
                    isSystemWorkspace: false,
                    isEphemeral: false,
                    primaryRepoPath: fixtureRoot.path,
                    lastFocused: true,
                    workspaceInstanceNumber: nil
                )]
            ))

            let workspace = WorkspaceModel(id: profile.marker, name: profile.workspaceName, repoPaths: [fixtureRoot.path])
            let chatURL = try await ChatDataService().saveChatSession(
                ChatSession(name: profile.marker.uuidString),
                for: workspace
            )
            XCTAssertTrue(chatURL.path.hasPrefix(workspacesRoot.path + "/"), chatURL.path)
            let agentSessionURL = try await AgentSessionDataService().saveAgentSession(
                AgentSession(name: profile.marker.uuidString, savedAt: profile.date),
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
            XCTAssertTrue(agentSessionURL.path.hasPrefix(workspacesRoot.path + "/"), agentSessionURL.path)

            let (domainWorkspaceID, domainWorkingName) = try await writeDomainWorkingJournal(for: profile)
            return WrittenMarkers(
                chatURL: chatURL,
                agentSessionURL: agentSessionURL,
                domainWorkspaceID: domainWorkspaceID,
                domainWorkingName: domainWorkingName
            )
        }

        /// Creates a workspace and then leaves an unsaved working revision, so a restart must
        /// recover the committed working journal from this profile only.
        private func writeDomainWorkingJournal(for profile: PairedProfile) async throws -> (UUID, String) {
            let configuration = domainConfiguration(for: profile)
            XCTAssertEqual(configuration.storageDirectory.standardizedFileURL, profile.root.standardizedFileURL)
            XCTAssertEqual(configuration.enforcesWorkspaceStorageBoundary, profile.isolates)
            let runtime = MCPDomainRuntime(configuration: configuration)
            try await runtime.start()
            let workspaceID = UUID()
            let fileURL = configuration.workspaceStorageDirectory
                .appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: profile.workspaceName, id: workspaceID))
                .appendingPathComponent("workspace.json")
            let createdDocument = try domainDocument(workspaceID: workspaceID, name: profile.workspaceName, fileURL: fileURL)
            let created = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                origin: .standalone,
                command: .createWorkspace(createdDocument)
            ))
            XCTAssertEqual(created.disposition, .applied, created.diagnostic ?? "")
            let workingName = "\(profile.workspaceName) working"
            let workingDocument = try domainDocument(workspaceID: workspaceID, name: workingName, fileURL: fileURL)
            let working = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedWorkspaceRevision: created.after?.workingRevision,
                origin: .standalone,
                command: .replaceWorkingDocument(workingDocument)
            ))
            XCTAssertEqual(working.disposition, .applied, working.diagnostic ?? "")
            _ = await runtime.shutdown()
            return (workspaceID, workingName)
        }

        private func assertMarkersReadBack(for profile: PairedProfile, written: WrittenMarkers) async throws {
            useProfile(profile.root, isolates: profile.isolates)

            XCTAssertEqual(try GlobalSettingsFileStore().load().updatedAt, profile.date)
            XCTAssertEqual(try PresetFileStore().loadWorkflowDocument().copyVisibility, [profile.marker: true])
            let windowSession = await WindowSessionDiskWriter(fileURL: WindowSessionStore.sessionFileURL()).load()
            XCTAssertEqual(windowSession?.windows.map(\.workspaceID), [profile.marker])
            let chat = try await ChatDataService().loadChatSession(from: written.chatURL)
            XCTAssertEqual(chat.name, profile.marker.uuidString)
            let agentSession = try await AgentSessionDataService().loadAgentSession(from: written.agentSessionURL)
            XCTAssertEqual(agentSession.name, profile.marker.uuidString)

            let runtime = MCPDomainRuntime(configuration: domainConfiguration(for: profile))
            try await runtime.start()
            let snapshot = await runtime.workspaceStore.snapshot()
            _ = await runtime.shutdown()
            XCTAssertEqual(snapshot.health, .writable)
            XCTAssertEqual(snapshot.workspaces.map(\.document.workspaceID), [written.domainWorkspaceID])
            XCTAssertEqual(snapshot.workspaces.first?.document.metadata.name, written.domainWorkingName)
            XCTAssertNotNil(snapshot.workspaces.first?.revisions.dirtyRevision)
        }

        private func domainConfiguration(for profile: PairedProfile) -> DomainRuntimeConfiguration {
            AppDomainRuntimeComposition.makeConfiguration(
                identity: profile.identity,
                isolatesDebugProfile: profile.isolates,
                defaults: UserDefaults(suiteName: "DebugProfilePersistenceIsolationTests-empty-\(UUID().uuidString)")!
            )
        }

        private func domainDocument(workspaceID: UUID, name: String, fileURL: URL) throws -> DomainWorkspaceDocument {
            let contextID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
            let object: [String: Any] = [
                "id": workspaceID.uuidString,
                "schemaVersion": 1,
                "name": name,
                "repoPaths": [fixtureRoot.path],
                "isSystemWorkspace": false,
                "isHiddenInMenus": false,
                "activeComposeTabID": contextID.uuidString,
                "composeTabs": [[
                    "id": contextID.uuidString,
                    "name": "Context",
                    "prompt": "",
                    "selectedPaths": []
                ]]
            ]
            return try DomainWorkspaceDocument.decode(
                documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                fileURL: fileURL
            )
        }

        /// Every file a store wrote under one profile is searched for the other profile's marker,
        /// so a store that ignored the resolver and wrote to a fixed location would surface here.
        private func assertProfileFiles(under root: URL, contain marker: UUID, exclude otherMarker: UUID) throws {
            let contents = try fileContents(under: root)
            XCTAssertFalse(contents.isEmpty)
            let joinedPaths = contents.keys.joined(separator: "\n")
            XCTAssertFalse(joinedPaths.contains(otherMarker.uuidString), joinedPaths)
            for (path, data) in contents {
                let text = String(decoding: data, as: UTF8.self)
                XCTAssertFalse(text.contains(otherMarker.uuidString), path)
            }
            let ownMarkerFiles = contents.filter { String(decoding: $0.value, as: UTF8.self).contains(marker.uuidString) }
            XCTAssertTrue(ownMarkerFiles.keys.contains { $0.hasSuffix("Presets/workflowPresets.json") })
            XCTAssertTrue(ownMarkerFiles.keys.contains { $0.hasSuffix("windowSessions.json") })
        }

        private func fileContents(under root: URL) throws -> [String: Data] {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return [:] }
            var contents: [String: Data] = [:]
            for case let url as URL in enumerator
                where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            {
                contents[url.path] = try Data(contentsOf: url)
            }
            return contents
        }

        private func writeWorkspace(_ workspace: WorkspaceModel, to folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: folder.appendingPathComponent("workspace.json"))
        }

        private func writeIndex(_ workspaces: [WorkspaceModel], in root: URL) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let entries = workspaces.map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: false,
                    isHiddenInMenus: false
                )
            }
            try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("workspacesIndex.json"))
        }

        /// Index publication runs on a background task after the workspace file is flushed.
        private func waitForIndex(in root: URL, toContain id: UUID) async throws -> [WorkspaceIndexEntry] {
            let indexURL = root.appendingPathComponent("workspacesIndex.json")
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let data = try? Data(contentsOf: indexURL),
                   let entries = try? JSONDecoder().decode([WorkspaceIndexEntry].self, from: data),
                   entries.contains(where: { $0.id == id })
                {
                    return entries
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("The workspace index never listed \(id)")
            return []
        }

        private func assertIsolationRejection(
            _ operation: () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("Expected the isolated debug profile to refuse external backing", file: file, line: line)
            } catch {
                XCTAssertEqual(
                    error as? WorkspaceStorageIsolationError,
                    .customStorageUnavailable,
                    String(describing: error),
                    file: file,
                    line: line
                )
            }
        }

        /// Saves a session in the current profile and lists it, which writes its index, then waits
        /// for the index reconciliation that listing schedules, so a later snapshot of that profile
        /// does not race a background index write.
        private func saveIndexedAgentSession(named name: String, for workspace: WorkspaceModel) async throws -> URL {
            let service = AgentSessionDataService()
            let sessionURL = try await service.saveAgentSession(
                AgentSession(name: name),
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
            _ = try await service.listAgentSessionsMeta(for: workspace)
            let folder = sessionURL.deletingLastPathComponent()
            let deadline = Date().addingTimeInterval(10)
            while await service.test_isMetadataIndexReconciliationScheduled(forAgentSessionsFolder: folder) {
                guard Date() < deadline else {
                    XCTFail("The index reconciliation for \(folder.path) did not finish")
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return sessionURL
        }

        private func link(_ link: URL, to target: URL) throws {
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }

        private func makeSentinel(at url: URL, isDirectory: Bool) throws {
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data(#"{"marker":"production"}"#.utf8).write(to: url.appendingPathComponent("sentinel.json"))
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(#"{"marker":"production"}"#.utf8).write(to: url)
            }
        }

        /// Store loads publish on the main queue; waiting for one hop observes what they published.
        private func drainMainQueue() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        /// A refusal names the location it refused, so the link to remove can be found.
        private func assertStorageRejection(
            naming location: URL,
            _ operation: () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("Expected the isolated debug profile to refuse \(location.path)", file: file, line: line)
            } catch {
                assertNames(location, in: error, file: file, line: line)
            }
        }

        private func assertStorageRejection(
            naming location: URL,
            _ result: Result<Void, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard case let .failure(error) = result else {
                return XCTFail("Expected the isolated debug profile to refuse \(location.path)", file: file, line: line)
            }
            assertNames(location, in: error, file: file, line: line)
        }

        private func assertNames(_ location: URL, in error: Error, file: StaticString, line: UInt) {
            XCTAssertTrue(
                error.localizedDescription.contains(location.standardizedFileURL.path),
                error.localizedDescription,
                file: file,
                line: line
            )
        }

        private func restoreDefault(_ value: Any?, forKey key: String) {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        private func makeManager(windowID: Int) -> WorkspaceManagerViewModel {
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let aiQueriesService = AIQueriesService(keyManager: keyManager)
            let fileManager = WorkspaceFilesViewModel()
            let apiSettings = APISettingsViewModel(
                aiQueriesService: aiQueriesService,
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: fileManager,
                apiSettingsViewModel: apiSettings,
                windowID: windowID,
                settingsManager: WindowSettingsManager(windowID: windowID)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: prompt,
                domainWorkspaceAuthorityClient: nil,
                workspaceActivityCoordinator: WindowStatesManager.shared.workspaceActivityCoordinator,
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return manager
        }
    }
#endif
