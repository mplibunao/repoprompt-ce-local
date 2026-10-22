import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainContextRevisionTests: XCTestCase {
    func testWorkingEditToOneTabAdvancesOnlyThatTabsContextRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domain-context-revision-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "context-revision",
            storageDirectory: storageRoot,
            eventDirectory: root.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        let workspaceID = UUID()
        let edited = DomainContextIdentity(workspaceID: workspaceID, contextID: UUID())
        let untouched = DomainContextIdentity(workspaceID: workspaceID, contextID: UUID())
        let fileURL = storageRoot
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: "revisions", id: workspaceID),
                isDirectory: true
            )
            .appendingPathComponent("workspace.json")
        func document(editedPrompt: String) throws -> DomainWorkspaceDocument {
            let object: [String: Any] = [
                "id": workspaceID.uuidString,
                "schemaVersion": 1,
                "name": "revisions",
                "repoPaths": [root.path],
                "isSystemWorkspace": false,
                "isHiddenInMenus": false,
                "activeComposeTabID": edited.contextID.uuidString,
                "composeTabs": [
                    ["id": edited.contextID.uuidString, "name": "Edited", "prompt": editedPrompt, "selectedPaths": []],
                    ["id": untouched.contextID.uuidString, "name": "Untouched", "prompt": "", "selectedPaths": []]
                ]
            ]
            return try DomainWorkspaceDocument.decode(
                documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                fileURL: fileURL
            )
        }
        let initial = try document(editedPrompt: "")
        let created = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .createWorkspace(initial)
        ))
        XCTAssertEqual(created.disposition, .applied, created.diagnostic ?? "")
        let editedBeforeSnapshot = await runtime.contextStore.snapshot(edited)
        let untouchedBeforeSnapshot = await runtime.contextStore.snapshot(untouched)
        let editedBefore = try XCTUnwrap(editedBeforeSnapshot).revisions
        let untouchedBefore = try XCTUnwrap(untouchedBeforeSnapshot).revisions

        // Direct-headless prompt and selection writes send the tab's expected revision, which the
        // authority admits only when the edit changes exactly one tab.
        let replacement = try document(editedPrompt: "changed")
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            expectedContextRevision: editedBefore.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(replacement)
        ))

        XCTAssertEqual(outcome.disposition, .applied, outcome.diagnostic ?? "")
        let editedAfterSnapshot = await runtime.contextStore.snapshot(edited)
        let untouchedAfterSnapshot = await runtime.contextStore.snapshot(untouched)
        let nextWorking = editedBefore.workingRevision + 1
        XCTAssertEqual(
            try XCTUnwrap(editedAfterSnapshot).revisions,
            DomainRevisionState(
                workingRevision: nextWorking,
                savedRevision: editedBefore.savedRevision,
                dirtyRevision: nextWorking
            )
        )
        XCTAssertEqual(try XCTUnwrap(untouchedAfterSnapshot).revisions, untouchedBefore)
    }
}
