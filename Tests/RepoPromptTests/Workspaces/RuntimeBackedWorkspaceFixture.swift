@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// A temporary workspace storage root that the global storage setting points at, with helpers
    /// that write workspace documents into it and build a domain runtime, workspace managers, and
    /// presentation bridges over it. A test creates one in `setUp` and calls `tearDown()` from its
    /// own `tearDown`, which closes the managers, bridges, and runtimes it made and restores the
    /// global settings.
    @MainActor
    final class RuntimeBackedWorkspaceFixture {
        let storageRoot: URL
        private let originalMCPAutoStart: Bool
        private let originalStoragePath: String?
        private var managers: [WorkspaceManagerViewModel] = []
        private var bridges: [DomainWorkspacePresentationBridge] = []
        private var runtimes: [MCPDomainRuntime] = []

        init(name: String) async throws {
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        func tearDown() async {
            bridges.forEach { $0.stop() }
            bridges.removeAll()
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
            for runtime in runtimes {
                _ = await runtime.shutdown()
            }
            runtimes.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            try? FileManager.default.removeItem(at: storageRoot)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
        }

        func workspaceFileURL(for workspace: WorkspaceModel) -> URL {
            workspaceFileURL(workspaceID: workspace.id, name: workspace.name)
        }

        func workspaceFileURL(workspaceID: UUID, name: String) -> URL {
            storageRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: name, id: workspaceID),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
        }

        func writeWorkspace(_ workspace: WorkspaceModel) throws {
            try writeWorkspaceDocument(
                JSONEncoder().encode(workspace),
                workspaceID: workspace.id,
                name: workspace.name
            )
        }

        /// Writes raw document bytes, for documents the app's own encoder would never produce.
        func writeWorkspaceDocument(_ bytes: Data, workspaceID: UUID, name: String) throws {
            let fileURL = workspaceFileURL(workspaceID: workspaceID, name: name)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: fileURL, options: .atomic)
        }

        func writeLegacyIndex(_ workspaces: [WorkspaceModel]) throws {
            let entries = workspaces.map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
            try JSONEncoder().encode(entries).write(
                to: storageRoot.appendingPathComponent("workspacesIndex.json"),
                options: .atomic
            )
        }

        /// A started runtime whose workspace catalog is this fixture's storage root.
        func makeRuntime(profileIdentifier: String) async throws -> MCPDomainRuntime {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "\(profileIdentifier)-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            runtimes.append(runtime)
            try await runtime.start()
            return runtime
        }

        func makeManager(
            windowID: Int,
            domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient? = nil
        ) -> WorkspaceManagerViewModel {
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
                domainWorkspaceAuthorityClient: domainWorkspaceAuthorityClient,
                workspaceActivityCoordinator: WorkspaceActivityCoordinator(),
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return manager
        }

        /// A runtime-backed manager for one window whose bridge has finished its initial projection.
        func makeProjectedManager(
            windowID: Int,
            runtime: MCPDomainRuntime
        ) async -> (manager: WorkspaceManagerViewModel, bridge: DomainWorkspacePresentationBridge) {
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: windowID)
            let manager = makeManager(windowID: windowID, domainWorkspaceAuthorityClient: client)
            await manager.awaitInitialized()
            let bridge = DomainWorkspacePresentationBridge(workspaceManager: manager, client: client)
            bridges.append(bridge)
            bridge.start()
            await bridge.awaitInitialProjection()
            return (manager, bridge)
        }
    }
#endif
