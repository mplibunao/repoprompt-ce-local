import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSessionLifecycleAuthorityContractTests: XCTestCase {
    /// A projection that changes only a protected tab's selection and timestamp isn't protected.
    /// One that also drops the tab's session binding keeps the binding and the tab's own timestamp,
    /// and takes the projection's selection.
    func testProjectionProtectsAPinnedTabOnlyFromChangesBesidesItsSelection() {
        let authority = AgentSessionLifecycleAuthority()
        let sessionID = UUID()
        let local = ComposeTabState(
            name: "Pinned",
            lastModified: Date(timeIntervalSinceReferenceDate: 1),
            isPinned: true,
            activeAgentSessionID: sessionID,
            selection: StoredSelection(selectedPaths: ["/tmp/pinned/a.swift"])
        )
        let shown = WorkspaceModel(name: "Shown", repoPaths: [], composeTabs: [local], activeComposeTabID: local.id)
        let claim = AgentSessionLifecycleAuthority.ProtectionClaim(
            identity: .init(
                workspaceID: shown.id,
                tabID: local.id,
                sessionID: sessionID,
                persistentBindingGeneration: nil,
                bindingTransitionGeneration: 0
            ),
            tab: local,
            isLive: false,
            isActive: true,
            isPinned: true,
            hasActiveRun: false
        )
        var selectionOnly = shown
        selectionOnly.composeTabs[0].selection = StoredSelection(selectedPaths: ["/tmp/pinned/b.swift"])
        selectionOnly.composeTabs[0].lastModified = Date(timeIntervalSinceReferenceDate: 2)

        let unprotected = authority.reconcileProjection(
            projectedWorkspace: selectionOnly,
            currentWorkspace: shown,
            claims: [claim]
        )

        XCTAssertFalse(unprotected.isProtected)
        XCTAssertEqual(unprotected.workspace, selectionOnly)

        var unbound = selectionOnly
        unbound.composeTabs[0].activeAgentSessionID = nil

        let protected = authority.reconcileProjection(projectedWorkspace: unbound, currentWorkspace: shown, claims: [claim])

        XCTAssertTrue(protected.isProtected)
        let kept = protected.workspace?.composeTabs.first
        XCTAssertEqual(kept?.activeAgentSessionID, sessionID)
        XCTAssertEqual(kept?.selection, selectionOnly.composeTabs[0].selection)
        XCTAssertEqual(kept?.lastModified, local.lastModified)
    }

    func testAlreadySavedWorkspaceIsAdmittedWhenBindingIsCurrent() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
    }

    func testPersistedTargetWorkspaceIsAdmittedWhenBindingIsCurrent() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: workspaceID,
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
    }

    func testRejectedPersistenceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .rejected(reason: "save rejected"),
                targetWorkspaceID: UUID(),
                bindingStillCurrent: true
            ),
            .rollback(.workspacePersistenceRejected)
        )
    }

    func testStaleBindingRollsBackAfterAcceptedPersistence() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: false
            ),
            .rollback(.sessionIdentityChanged)
        )
    }

    func testPersistedDifferentWorkspaceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: UUID(),
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .rollback(.workspaceChanged)
        )
    }
}
