@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Prompt tab operations act on the workspace the window shows, in a runtime-backed window
    /// whose catalog holds another workspace.
    @MainActor
    final class PromptShownWorkspaceTabTests: XCTestCase {
        private var fixture: RuntimeBackedWorkspaceFixture!

        override func setUp() async throws {
            try await super.setUp()
            fixture = try await RuntimeBackedWorkspaceFixture(name: "PromptShownWorkspaceTabTests")
        }

        override func tearDown() async throws {
            await fixture.tearDown()
            fixture = nil
            try await super.tearDown()
        }

        /// After duplicate consolidation another workspace can hold a compose tab with a stashed
        /// tab's ID. Restoring the stashed tab must still restore and activate the shown copy.
        func testRestoringStashedTabIgnoresSameIDTabInAnotherWorkspace() async throws {
            let tabID = UUID()
            let current = ComposeTabState(name: "Current", promptText: "Current prompt")
            let shown = WorkspaceModel(
                name: "Alpha Shown",
                repoPaths: [fixture.storageRoot.appendingPathComponent("shown-root").path],
                composeTabs: [current],
                activeComposeTabID: current.id,
                stashedTabs: [StashedTab(tab: ComposeTabState(id: tabID, name: "Archived", promptText: "Stashed copy"))]
            )
            let elsewhere = ComposeTabState(id: tabID, name: "Archived", promptText: "Parked copy")
            let parked = WorkspaceModel(
                name: "Parked",
                repoPaths: [fixture.storageRoot.appendingPathComponent("parked-root").path],
                lastUsed: Date(timeIntervalSinceReferenceDate: 690_000_000),
                composeTabs: [elsewhere],
                activeComposeTabID: elsewhere.id
            )
            try fixture.writeWorkspace(shown)
            try fixture.writeWorkspace(parked)
            try fixture.writeLegacyIndex([shown, parked])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "prompt-shown-tab")
            let (manager, _) = await fixture.makeProjectedManager(windowID: -7302, runtime: runtime)
            XCTAssertEqual(manager.activeWorkspaceID, shown.id, "The window must show the other workspace")
            let prompt = manager.promptViewModel

            let restored = await prompt.restoreStashedComposeTab(containingTabID: tabID)

            XCTAssertEqual(restored?.promptText, "Stashed copy")
            XCTAssertEqual(prompt.activeComposeTabID, tabID)
            let shownAfter = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(shownAfter.composeTabs.map(\.id), [current.id, tabID])
            XCTAssertEqual(shownAfter.stashedTabs, [])
        }

        func testAgentAdmissionSettlesInTheCanonicalDocumentAfterTheWindowStopsShowingTheWorkspace() async throws {
            for row in AdmissionAfterSwitchRow.allCases {
                try await assertAdmissionSettlesCanonically(row)
            }
        }

        /// How the admission's own save ends. The window then stops showing the admission's
        /// workspace before the admission decides, and the switch publishes the provisional tab.
        private enum AdmissionAfterSwitchRow: String, CaseIterable {
            /// The save is refused, so the admission is rejected and its tab must leave the
            /// canonical document, because the window no longer has a copy of the workspace.
            case refusedSave
            /// The save stores the tab, so the admission is created and the canonical tab keeps its
            /// session.
            case acceptedSave
        }

        private func assertAdmissionSettlesCanonically(_ row: AdmissionAfterSwitchRow) async throws {
            let message = row.rawValue
            let current = ComposeTabState(name: "Current", promptText: "Current prompt")
            let admission = WorkspaceModel(
                name: "Alpha Admission",
                repoPaths: [fixture.storageRoot.appendingPathComponent("admission-root-\(row)").path],
                composeTabs: [current],
                activeComposeTabID: current.id
            )
            let other = WorkspaceModel(
                name: "Other",
                repoPaths: [fixture.storageRoot.appendingPathComponent("other-root-\(row)").path],
                lastUsed: Date(timeIntervalSinceReferenceDate: 690_000_000)
            )
            try fixture.writeWorkspace(admission)
            try fixture.writeWorkspace(other)
            try fixture.writeLegacyIndex([admission, other])
            let runtime = try await fixture.makeRuntime(profileIdentifier: "prompt-admission-\(row)")
            let windowID = row == .refusedSave ? -7303 : -7304
            let (manager, _) = await fixture.makeProjectedManager(windowID: windowID, runtime: runtime)
            XCTAssertEqual(manager.activeWorkspaceID, admission.id, "\(message): the window must show the admission's workspace")
            let prompt = manager.promptViewModel
            func canonicalAdmission() async throws -> WorkspaceModel {
                let snapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(admission.id)
                return try JSONDecoder().decode(WorkspaceModel.self, from: XCTUnwrap(snapshot).document.documentBytes)
            }
            defer {
                manager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
                prompt.setAgentAdmissionPersistenceReceiptHandlerForTesting(nil)
            }
            if row == .refusedSave {
                // The admission's own save is refused without writing, so the receipt has no commit.
                manager.setWorkspacePersistenceOutcomeOverrideForTesting(.rejected(reason: "test_rejection"))
            }
            var publishedTabID: UUID?
            prompt.setAgentAdmissionPersistenceReceiptHandlerForTesting { identity, _ in
                manager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
                let switched = await manager.requestWorkspaceSwitch(toWorkspaceID: other.id)
                XCTAssertTrue(switched.didSwitch, message)
                let published = try? await canonicalAdmission()
                publishedTabID = published?.composeTabs.first { $0.id == identity.tabID }?.id
            }

            let sessionID = UUID()
            let result = try await prompt.createDurableBackgroundAgentSessionTab(
                name: "Provisional",
                sessionID: sessionID,
                expectedWorkspaceID: admission.id,
                lifecycleAuthority: AgentSessionLifecycleAuthority()
            )

            let provisionalTabID = try XCTUnwrap(publishedTabID, "\(message): the switch must publish the provisional tab")
            let stored = try await canonicalAdmission()
            XCTAssertFalse(stored.stashedTabs.contains { $0.tab.activeAgentSessionID == sessionID }, message)
            switch (row, result) {
            case (.refusedSave, .rejected):
                XCTAssertEqual(stored.composeTabs.map(\.id), [current.id], message)
            case let (.acceptedSave, .created(tab, _, _)):
                XCTAssertEqual(tab.id, provisionalTabID, message)
                XCTAssertEqual(stored.composeTabs.map(\.id), [current.id, provisionalTabID], message)
                XCTAssertEqual(stored.composeTabs.last?.activeAgentSessionID, sessionID, message)
            default:
                XCTFail("\(message): unexpected admission result \(result)")
            }
        }
    }
#endif
