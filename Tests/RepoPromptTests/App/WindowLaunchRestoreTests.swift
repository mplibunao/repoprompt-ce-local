@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Launch restore of a saved multi-window session through the shared `WindowStatesManager`.
    @MainActor
    final class WindowLaunchRestoreTests: XCTestCase {
        /// Every window a test registers, closed by the teardown that `beginLaunchRestore()` adds.
        private var registeredWindows: [WindowState] = []

        override func setUp() {
            super.setUp()
            AppWindowOpener.shared.resetForTesting()
        }

        override func tearDown() {
            AppWindowOpener.shared.resetForTesting()
            super.tearDown()
        }

        func testCaptureKeepsEverySavedEntryDuringRestore() async throws {
            let (first, second) = try await makeSavedWorkspaces()
            let saved = [entry(for: first), entry(for: second), entry(for: first)]
            let savedIDs = saved.map(\.workspaceID)
            let windowStates = try beginLaunchRestore()

            windowStates.finishRestoreSessionLoadForTesting(entries: saved)
            XCTAssertEqual(captureIDs(), savedIDs, "entries queued before any window registered")

            for (index, workspace) in [first, second, first].enumerated() {
                let window = makeRegisteredWindow()
                try await waitForRestoreToReturn(window)
                XCTAssertEqual(window.workspaceManager.activeWorkspaceID, workspace.id)
                XCTAssertEqual(captureIDs(), savedIDs, "after \(index + 1) restores returned")
            }
        }

        // MARK: - Fixture

        /// Creates two saved workspaces on disk, so a new window's catalog contains them.
        private func makeSavedWorkspaces() async throws -> (WorkspaceModel, WorkspaceModel) {
            let persister = makeWindow()
            await persister.workspaceManager.awaitInitialized()
            let workspaces = ["First", "Second"].map {
                persister.workspaceManager.createWorkspace(name: "Launch Restore \($0) \(UUID().uuidString)", repoPaths: [])
            }
            // Teardown blocks run in reverse order, so this runs after every window has closed.
            addTeardownBlock { @MainActor in
                for workspace in workspaces {
                    let outcome = await persister.workspaceManager.deleteWorkspaceAsync(workspace)
                    XCTAssertEqual(outcome, .deleted)
                }
                persister.beginClose()
                await persister.tearDown()
            }
            // Workspace creation persists on a background task.
            try await waitUntil("the saved workspaces to reach disk") {
                let onDisk = await persister.workspaceManager.loadWorkspaceSnapshotFromDisk().map(\.id)
                return workspaces.allSatisfy { onDisk.contains($0.id) }
            }
            return (workspaces[0], workspaces[1])
        }

        /// Puts the shared manager in the launch state, before the saved session has loaded.
        private func beginLaunchRestore() throws -> WindowStatesManager {
            let windowStates = WindowStatesManager.shared
            guard windowStates.allWindows.isEmpty else {
                throw LaunchRestoreFixtureError.windowsAlreadyRegistered(windowStates.allWindows.map(\.windowID))
            }
            windowStates.beginRestoreSessionLoadForTesting()
            addTeardownBlock { @MainActor in
                // Reset before closing: closing a restoring window wakes the launch restore.
                windowStates.resetLaunchRestoreForTesting()
                for window in self.registeredWindows {
                    window.beginClose()
                    await window.tearDown()
                    windowStates.unregisterWindowState(window)
                }
            }
            return windowStates
        }

        private func makeWindow() -> WindowState {
            MCPWindowTestSupport.makeWindowWithoutAutoStart()
        }

        private func makeRegisteredWindow() -> WindowState {
            let window = makeWindow()
            registeredWindows.append(window)
            WindowStatesManager.shared.registerWindowState(window)
            return window
        }

        private func captureIDs() -> [UUID?] {
            WindowStatesManager.shared.captureCurrentSessionForTesting().windows.map(\.workspaceID)
        }

        private func waitForRestoreToReturn(_ window: WindowState) async throws {
            try await waitUntil("window \(window.windowID)'s restore attempt to return") {
                !window.isWorkspaceRestoreInFlight
            }
        }

        private func entry(for workspace: WorkspaceModel) -> WindowSessionEntry {
            WindowSessionEntry(
                windowKind: .standard,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                isSystemWorkspace: false,
                isEphemeral: false,
                primaryRepoPath: nil,
                lastFocused: false,
                workspaceInstanceNumber: nil
            )
        }

        private func waitUntil(
            _ description: String,
            timeout: Duration = .seconds(10),
            _ condition: @MainActor () async -> Bool
        ) async throws {
            guard await MCPWindowTestSupport.waitUntil(timeout: timeout, condition) else {
                throw LaunchRestoreFixtureError.timedOut(description)
            }
        }
    }

    private enum LaunchRestoreFixtureError: Error, CustomStringConvertible {
        case windowsAlreadyRegistered([Int])
        case timedOut(String)

        var description: String {
            switch self {
            case let .windowsAlreadyRegistered(windowIDs):
                "Another test left windows \(windowIDs) registered with the shared manager."
            case let .timedOut(description):
                "Timed out waiting for \(description)."
            }
        }
    }
#endif
