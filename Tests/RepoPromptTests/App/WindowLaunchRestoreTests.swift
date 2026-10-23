import Combine
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Launch restore of a saved multi-window session through the shared `WindowStatesManager`.
    @MainActor
    final class WindowLaunchRestoreTests: XCTestCase {
        /// Every window a test registers, closed by the teardown that `beginLaunchRestore()` adds.
        private var registeredWindows: [WindowState] = []
        /// Every restore hold a test installs, opened by that teardown so no restore task hangs.
        private var restoreHolds: [WindowRestoreHold] = []

        override func setUp() {
            super.setUp()
            AppWindowOpener.shared.resetForTesting()
        }

        override func tearDown() {
            AppWindowOpener.shared.resetForTesting()
            super.tearDown()
        }

        func testLaunchRestoreOpensEveryRemainingEntryOneAtATime() async throws {
            let workspaces = try await makeSavedWorkspaces(count: 3)
            let savedIDs = Set(workspaces.map(\.id))
            let windowStates = try beginLaunchRestore()
            var openedHolds: [WindowRestoreHold] = []
            let opener = installOpener {
                let window = self.makeWindow()
                openedHolds.append(self.holdRestore(of: window, onlyFor: savedIDs))
                self.register(window)
            }
            let firstWindow = makeWindow()
            let firstHold = holdRestore(of: firstWindow, onlyFor: savedIDs)
            register(firstWindow)

            windowStates.finishRestoreSessionLoadForTesting(entries: workspaces.map(entry(for:)))
            let firstTarget = try await waitForHold(firstHold, "the first window's restore")
            XCTAssertEqual(firstTarget, workspaces[0].id)

            var restoringHold = firstHold
            for index in 1 ..< workspaces.count {
                XCTAssertEqual(opener.requestCount, index - 1, "windows requested while window \(index) was restoring")
                await restoringHold.open()
                try await waitUntil("the driver's window \(index + 1) to reach its restore hold") {
                    guard openedHolds.count == index else { return false }
                    return await openedHolds[index - 1].workspaceID != nil
                }
                restoringHold = openedHolds[index - 1]
                let target = await restoringHold.workspaceID
                XCTAssertEqual(target, workspaces[index].id, "window \(index + 1)'s restore target")
            }
            await restoringHold.open()
            try await waitUntil("every restore attempt to return") {
                windowStates.allWindows.allSatisfy { !$0.isWorkspaceRestoreInFlight }
            }

            XCTAssertEqual(opener.requestCount, workspaces.count - 1)
            XCTAssertEqual(
                windowStates.allWindows.map(\.workspaceManager.activeWorkspaceID),
                workspaces.map { $0.id as UUID? }
            )
        }

        func testWindowOpenedForAnotherCallerTakesNoEntry() async throws {
            let workspaces = try await makeSavedWorkspaces(count: 2)
            let windowStates = try beginLaunchRestore()
            let opener = installOpener {
                self.register(self.makeWindow())
            }
            let firstWindow = makeWindow()
            let firstHold = holdRestore(of: firstWindow, onlyFor: Set(workspaces.map(\.id)))
            register(firstWindow)
            windowStates.finishRestoreSessionLoadForTesting(entries: workspaces.map(entry(for:)))
            _ = try await waitForHold(firstHold, "the first window's restore")

            // A routed MCP request opens a window while the second saved entry is still queued.
            let callerWindow = try await windowStates.openNewMainWindow()
            XCTAssertFalse(callerWindow.isWorkspaceRestoreInFlight, "the caller's window took a saved entry")

            await firstHold.open()
            try await waitUntil("the driver to open and restore a window for the second entry") {
                windowStates.allWindows.count == 3
                    && windowStates.allWindows.allSatisfy { !$0.isWorkspaceRestoreInFlight }
            }

            XCTAssertEqual(opener.requestCount, 2, "one window for the caller and one for the second entry")
            let restoredWindows = windowStates.allWindows.filter { $0 !== callerWindow }
            XCTAssertEqual(
                restoredWindows.map(\.workspaceManager.activeWorkspaceID),
                workspaces.map { $0.id as UUID? }
            )
            let callerWorkspaceID = callerWindow.workspaceManager.activeWorkspaceID
            XCTAssertFalse(
                workspaces.contains { $0.id == callerWorkspaceID },
                "the caller's window restored a saved workspace"
            )
        }

        func testDockWindowTakesNoEntryOnceTheDriverStarts() async throws {
            let workspaces = try await makeSavedWorkspaces(count: 3)
            let savedIDs = Set(workspaces.map(\.id))
            let windowStates = try beginLaunchRestore()
            // One hold per window the opener registers, in request order.
            var openedHolds: [WindowRestoreHold] = []
            let opener = installOpener {
                let window = self.makeWindow()
                openedHolds.append(self.holdRestore(of: window, onlyFor: savedIDs))
                self.register(window)
            }
            let firstWindow = makeWindow()
            let firstHold = holdRestore(of: firstWindow, onlyFor: savedIDs)
            register(firstWindow)
            windowStates.finishRestoreSessionLoadForTesting(entries: workspaces.map(entry(for:)))
            _ = try await waitForHold(firstHold, "the first window's restore")
            await firstHold.open()
            try await waitUntil("the driver's first window to reach its restore hold") {
                guard openedHolds.count == 1 else { return false }
                return await openedHolds[0].workspaceID != nil
            }

            // Dock > New Window while the driver's window restores and the third entry is queued.
            AppWindowOpener.shared.requestMainWindowFromDock()
            let dockWindow = try XCTUnwrap(registeredWindows.last)
            XCTAssertFalse(dockWindow.isWorkspaceRestoreInFlight, "the Dock window took a saved entry")

            await openedHolds[0].open()
            try await waitUntil("the driver to open a window for the third entry") {
                guard openedHolds.count == 3 else { return false }
                return await openedHolds[2].workspaceID != nil
            }
            let thirdTarget = await openedHolds[2].workspaceID
            XCTAssertEqual(thirdTarget, workspaces[2].id)
            await openedHolds[2].open()
            try await waitUntil("every restore attempt to return") {
                windowStates.allWindows.allSatisfy { !$0.isWorkspaceRestoreInFlight }
            }

            XCTAssertEqual(opener.requestCount, 3, "two windows for saved entries and one for the Dock")
            XCTAssertEqual(windowStates.allWindows.count, workspaces.count + 1)
            let restoredWindows = windowStates.allWindows.filter { $0 !== dockWindow }
            XCTAssertEqual(
                restoredWindows.map(\.workspaceManager.activeWorkspaceID),
                workspaces.map { $0.id as UUID? }
            )
            XCTAssertFalse(
                savedIDs.contains { $0 == dockWindow.workspaceManager.activeWorkspaceID },
                "the Dock window restored a saved workspace"
            )
        }

        func testCaptureKeepsEverySavedEntryDuringRestore() async throws {
            let workspaces = try await makeSavedWorkspaces(count: 2)
            let order = [workspaces[0], workspaces[1], workspaces[0]]
            let savedIDs = order.map { $0.id as UUID? }
            let windowStates = try beginLaunchRestore()
            // Records the driver's requests without opening a window, so a capture can see a
            // request outstanding; the test then registers the window that satisfies it.
            let opener = installOpener()

            windowStates.finishRestoreSessionLoadForTesting(entries: order.map(entry(for:)))
            XCTAssertEqual(captureIDs(), savedIDs, "with entries queued before any window registered")

            for (index, workspace) in order.enumerated() {
                if index > 0 {
                    try await waitUntil("the driver to request window \(index + 1)") {
                        opener.requestCount == index
                    }
                    XCTAssertEqual(captureIDs(), savedIDs, "with the driver's request for window \(index + 1) outstanding")
                }
                let window = makeWindow()
                register(window)
                try await waitUntil("window \(index + 1)'s restore attempt to return") {
                    !window.isWorkspaceRestoreInFlight
                }
                XCTAssertEqual(window.workspaceManager.activeWorkspaceID, workspace.id)
                XCTAssertEqual(captureIDs(), savedIDs, "after \(index + 1) restores returned")
            }
        }

        // MARK: - Fixture

        /// Creates saved workspaces on disk, so a new window's catalog contains them.
        private func makeSavedWorkspaces(count: Int) async throws -> [WorkspaceModel] {
            let persister = makeWindow()
            await persister.workspaceManager.awaitInitialized()
            let announcements = WorkspaceListChangeCounter()
            let workspaces = (1 ... count).map {
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
            // Workspace creation persists on a background task and then announces the new catalog.
            // Windows created after every announcement load the workspaces and get no late reload,
            // which could put a restoring window back on the workspace it showed before.
            try await waitUntil("the saved workspaces' creation to be announced") {
                announcements.count >= count
            }
            return workspaces
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
                AppWindowOpener.shared.resetForTesting()
                for hold in self.restoreHolds {
                    await hold.open()
                }
                for window in self.registeredWindows {
                    window.beginClose()
                    await window.tearDown()
                    windowStates.unregisterWindowState(window)
                }
            }
            return windowStates
        }

        /// Stands in for SwiftUI's `openWindow` and counts requests. `body` runs synchronously for
        /// each request and may register a window in the same call.
        private func installOpener(_ body: @escaping () -> Void = {}) -> OpenRequestCounter {
            let counter = OpenRequestCounter()
            AppWindowOpener.shared.installForTesting {
                counter.requestCount += 1
                body()
            }
            return counter
        }

        private func makeWindow() -> WindowState {
            MCPWindowTestSupport.makeWindowWithoutAutoStart()
        }

        private func register(_ window: WindowState) {
            registeredWindows.append(window)
            WindowStatesManager.shared.registerWindowState(window)
        }

        /// Holds `window`'s restore once its switch to one of `workspaceIDs` holds the activation
        /// lease, before the switch begins.
        private func holdRestore(of window: WindowState, onlyFor workspaceIDs: Set<UUID>) -> WindowRestoreHold {
            let hold = WindowRestoreHold()
            restoreHolds.append(hold)
            window.workspaceManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting { workspaceID in
                guard workspaceIDs.contains(workspaceID) else { return }
                await hold.enterAndWait(workspaceID: workspaceID)
            }
            return hold
        }

        private func waitForHold(_ hold: WindowRestoreHold, _ description: String) async throws -> UUID? {
            try await waitUntil("\(description) to reach its hold") {
                await hold.workspaceID != nil
            }
            return await hold.workspaceID
        }

        private func captureIDs() -> [UUID?] {
            WindowStatesManager.shared.captureCurrentSessionForTesting().windows.map(\.workspaceID)
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

    @MainActor
    private final class OpenRequestCounter {
        var requestCount = 0
    }

    /// Counts `.workspaceListDidChange` posts from its creation on. A workspace manager posts one
    /// after a created workspace reaches disk, and every other open window reloads its catalog when
    /// it receives one. A reload that starts before a window's restore switch commits applies the
    /// workspace that was active when it started, so tests create their windows after the posts.
    @MainActor
    final class WorkspaceListChangeCounter {
        private(set) var count = 0
        private var subscription: AnyCancellable?

        init() {
            // Workspace managers post on the main actor.
            subscription = NotificationCenter.default.publisher(for: .workspaceListDidChange)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.count += 1 }
                }
        }
    }

    /// Holds one restore attempt at its first matching activation until opened.
    actor WindowRestoreHold {
        private(set) var workspaceID: UUID?
        private var isOpen = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait(workspaceID: UUID) async {
            guard self.workspaceID == nil else { return }
            self.workspaceID = workspaceID
            guard !isOpen else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func open() {
            isOpen = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
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
