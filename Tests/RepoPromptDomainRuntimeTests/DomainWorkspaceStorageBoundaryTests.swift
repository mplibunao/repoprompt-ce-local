import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceStorageBoundaryTests: XCTestCase {
    private static let boundaryReason = "workspace_storage_boundary_violation"

    func testDisabledBoundaryKeepsExternallyStoredWorkspaceLoadable() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        try fixture.writeDocument(workspaceID: workspaceID, name: "external", to: fixture.externalDocumentURL)
        try fixture.writeLegacyIndex([(workspaceID, "external", fixture.externalDirectory)])

        let bootstrap = await fixture.coordinator(enforcing: false).bootstrap()

        XCTAssertEqual(bootstrap.workspaces.map(\.document.workspaceID), [workspaceID])
        XCTAssertTrue(bootstrap.unavailableWorkspaces.isEmpty)
        XCTAssertEqual(bootstrap.health, .writable)
    }

    func testBoundaryRejectsExternalIndexEntryAtBootstrapAndPreservesItsBytes() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        try fixture.writeDocument(workspaceID: workspaceID, name: "external", to: fixture.externalDocumentURL)
        try fixture.writeLegacyIndex([(workspaceID, "external", fixture.externalDirectory)])
        let indexBytes = try Data(contentsOf: fixture.legacyIndexURL)
        let documentBytes = try Data(contentsOf: fixture.externalDocumentURL)

        let bootstrap = await fixture.coordinator(enforcing: true).bootstrap()

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.workspaceID), [workspaceID])
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.reason), [Self.boundaryReason])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(try Data(contentsOf: fixture.legacyIndexURL), indexBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.externalDocumentURL), documentBytes)
        XCTAssertNil(fixture.runtimeFile(named: "workspace-catalog.json"))
    }

    func testBoundaryRejectsInRootPathThatResolvesOutsideThroughASymlink() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        try fixture.writeDocument(workspaceID: workspaceID, name: "linked", to: fixture.externalDocumentURL)
        let linked = fixture.workspaceDirectory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.externalDirectory)
        try fixture.writeLegacyIndex([(workspaceID, "linked", linked)])

        let bootstrap = await fixture.coordinator(enforcing: true).bootstrap()

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.reason), [Self.boundaryReason])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
    }

    func testBoundaryAdmitsWorkspacesStoredInsideTheRoot() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let defaultID = UUID()
        let customInsideID = UUID()
        let customInside = fixture.workspaceDirectory.appendingPathComponent("custom-inside", isDirectory: true)
        try fixture.writeDocument(
            workspaceID: defaultID,
            name: "default",
            to: fixture.defaultDocumentURL(workspaceID: defaultID, name: "default")
        )
        try fixture.writeDocument(
            workspaceID: customInsideID,
            name: "inside",
            to: customInside.appendingPathComponent("workspace.json")
        )
        try fixture.writeLegacyIndex([(defaultID, "default", nil), (customInsideID, "inside", customInside)])

        let bootstrap = await fixture.coordinator(enforcing: true).bootstrap()

        XCTAssertEqual(
            Set(bootstrap.workspaces.map(\.document.workspaceID)),
            [defaultID, customInsideID]
        )
        XCTAssertTrue(bootstrap.unavailableWorkspaces.isEmpty)
        XCTAssertEqual(bootstrap.health, .writable)
    }

    func testBoundaryRejectsExternalCatalogEntryAndRefusesReloadAndRefresh() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        try await fixture.createExternallyStoredWorkspace(workspaceID: workspaceID)
        let catalogURL = try XCTUnwrap(fixture.runtimeFile(named: "workspace-catalog.json"))
        let catalogBytes = try Data(contentsOf: catalogURL)
        let documentBytes = try Data(contentsOf: fixture.externalDocumentURL)
        let enforcing = fixture.coordinator(enforcing: true)

        let bootstrap = await enforcing.bootstrap()
        let reloaded = await enforcing.reloadWorkspace(workspaceID: workspaceID, fileURL: fixture.externalDocumentURL)
        let refreshed = await enforcing.refreshWorkspace(
            workspaceID: workspaceID,
            fallbackFileURL: fixture.externalDocumentURL
        )

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.workspaceID), [workspaceID])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertNil(reloaded)
        XCTAssertNil(refreshed?.workspace)
        XCTAssertEqual(refreshed?.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.externalDocumentURL), documentBytes)
    }

    func testBoundaryRejectsExternalJournalRecoveredWithoutACatalogEntry() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        try await fixture.createExternallyStoredWorkspace(workspaceID: workspaceID)
        // Recreates the crash window between the journal commit and catalog publication, which
        // bootstrap recovers by scanning the runtime-owned journal directory.
        try FileManager.default.removeItem(at: XCTUnwrap(fixture.runtimeFile(named: "workspace-catalog.json")))
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        let journalBytes = try Data(contentsOf: journalURL)

        let bootstrap = await fixture.coordinator(enforcing: true).bootstrap()

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.workspaceID), [workspaceID])
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.reason), [Self.boundaryReason])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
    }

    func testBoundaryRejectsProductionJournalForACatalogedLocalWorkspace() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        let localDocumentURL = fixture.defaultDocumentURL(workspaceID: workspaceID, name: "local")
        _ = try await fixture.persistCreated(
            fixture.document(workspaceID: workspaceID, name: "local", fileURL: localDocumentURL),
            coordinator: fixture.coordinator(enforcing: true)
        )
        // A journal copied from production keeps production's document URL for the same workspace,
        // while the catalog entry and the document stay inside this profile.
        try fixture.writeDocument(workspaceID: workspaceID, name: "production", to: fixture.externalDocumentURL)
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        journal["fileURL"] = fixture.externalDocumentURL.absoluteString
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: journalURL)
        let journalBytes = try Data(contentsOf: journalURL)
        let productionBytes = try Data(contentsOf: fixture.externalDocumentURL)
        let enforcing = fixture.coordinator(enforcing: true)

        let bootstrap = await enforcing.bootstrap()
        let reloaded = await enforcing.reloadWorkspace(workspaceID: workspaceID, fileURL: localDocumentURL)
        let refreshed = await enforcing.refreshWorkspace(workspaceID: workspaceID, fallbackFileURL: localDocumentURL)

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.workspaceID), [workspaceID])
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.reason), [Self.boundaryReason])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertNil(reloaded)
        XCTAssertNil(refreshed?.workspace)
        XCTAssertEqual(refreshed?.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.externalDocumentURL), productionBytes)
    }

    func testCatalogAbsentRefreshReportsTheBoundaryForAnOutOfBoundFallback() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        try fixture.writeDocument(workspaceID: workspaceID, name: "external", to: fixture.externalDocumentURL)
        let documentBytes = try Data(contentsOf: fixture.externalDocumentURL)

        let refreshed = await fixture.coordinator(enforcing: true).refreshWorkspace(
            workspaceID: workspaceID,
            fallbackFileURL: fixture.externalDocumentURL
        )

        XCTAssertNil(fixture.runtimeFile(named: "workspace-catalog.json"))
        XCTAssertNil(refreshed?.workspace)
        XCTAssertEqual(refreshed?.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(try Data(contentsOf: fixture.externalDocumentURL), documentBytes)
    }

    func testCorruptIndexUnderTheBoundaryIsPreservedAndBlocksMutation() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        try Data("{ not a workspace index".utf8).write(to: fixture.legacyIndexURL)
        let indexBytes = try Data(contentsOf: fixture.legacyIndexURL)
        let workspaceID = UUID()
        let newDocumentURL = fixture.defaultDocumentURL(workspaceID: workspaceID, name: "new")
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()

        let snapshot = await runtime.workspaceStore.snapshot()
        let outcome = try await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .createWorkspace(fixture.document(workspaceID: workspaceID, name: "new", fileURL: newDocumentURL))
        ))
        _ = await runtime.shutdown()

        // An unreadable index is preserved as read-only state, never read as an empty catalog.
        XCTAssertEqual(snapshot.health, .degradedReadOnly(reason: "workspace_index_decode_failed"))
        XCTAssertEqual(outcome.disposition, .readOnly)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyIndexURL), indexBytes)
        XCTAssertNil(fixture.runtimeFile(named: "workspace-catalog.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDocumentURL.path))
    }

    func testFutureVersionJournalUnderTheBoundaryIsPreservedAndBlocksMutation() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()
        let (created, fileURL) = try await fixture.createInRootWorkspace(in: runtime, name: "inside")
        let workspaceID = try XCTUnwrap(created.workspace?.document.workspaceID)
        _ = await runtime.shutdown()
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        journal["version"] = 99
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: journalURL)
        let journalBytes = try Data(contentsOf: journalURL)
        let documentBytes = try Data(contentsOf: fileURL)

        let restarted = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await restarted.start()
        let snapshot = await restarted.workspaceStore.snapshot()
        let outcome = try await restarted.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(workspaceID: workspaceID, name: "edited", fileURL: fileURL))
        ))
        _ = await restarted.shutdown()

        // A journal from a newer build keeps its workspace visible but read-only, never reset.
        XCTAssertEqual(snapshot.workspaces.map(\.document.workspaceID), [workspaceID])
        XCTAssertEqual(snapshot.workspaces.first?.health, .degradedReadOnly(reason: "future_working_journal"))
        XCTAssertEqual(outcome.disposition, .readOnly)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: fileURL), documentBytes)
    }

    func testJournalLinkedIntoProductionIsRefusedAndPreserved() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let (workspaceID, created, fileURL) = try await createLocalWorkspace(in: fixture)
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        let productionJournal = try linkIntoProduction(journalURL, in: fixture)
        let productionBefore = try contents(of: fixture.production)

        let bootstrap = await fixture.coordinator(enforcing: true).bootstrap()
        let restarted = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await restarted.start()
        let outcome = try await restarted.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(workspaceID: workspaceID, name: "edited", fileURL: fileURL))
        ))
        _ = await restarted.shutdown()

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.reason), [Self.boundaryReason])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertNotEqual(outcome.disposition, .applied)
        XCTAssertEqual(try contents(of: fixture.production), productionBefore)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: journalURL.path), productionJournal.path)
    }

    func testWorkspaceLockLinkedIntoProductionRefusesTheMutationAndIsPreserved() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let (workspaceID, created, fileURL) = try await createLocalWorkspace(in: fixture)
        // The catalog, document, and journal stay local and valid; only the workspace lock links
        // to a production lock that does not exist yet, so opening it would create it.
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        let lockURL = journalURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("locks/workspace-\(workspaceID.uuidString).lock")
        let productionLock = try linkIntoProduction(lockURL, in: fixture, keepingTarget: false)
        let journalBytes = try Data(contentsOf: journalURL)
        let documentBytes = try Data(contentsOf: fileURL)
        let productionBefore = try contents(of: fixture.production)

        let bootstrap = await fixture.coordinator(enforcing: true).bootstrap()
        let restarted = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await restarted.start()
        let outcome = try await restarted.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(fixture.document(workspaceID: workspaceID, name: "edited", fileURL: fileURL))
        ))
        _ = await restarted.shutdown()

        // Bootstrap takes no workspace lock, so the workspace loads writable and the mutation
        // reaches persistence, where taking the lock is refused.
        XCTAssertEqual(bootstrap.health, .writable)
        XCTAssertEqual(bootstrap.workspaces.map(\.document.workspaceID), [workspaceID])
        XCTAssertEqual(outcome.disposition, .failed)
        XCTAssertEqual(outcome.errorCode, .persistenceFailure)
        XCTAssertTrue(outcome.diagnostic?.contains(Self.boundaryReason) == true, outcome.diagnostic ?? "nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: productionLock.path))
        XCTAssertEqual(try contents(of: fixture.production), productionBefore)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lockURL.path), productionLock.path)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: fileURL), documentBytes)
    }

    func testRevisionLinkedIntoProductionIsRefusedBesideAValidJournal() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let (workspaceID, created, fileURL) = try await createLocalWorkspace(in: fixture)
        // The journal stays local and valid, so loading never needs the revision record's contents.
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        let revisionURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "revisions"))
        let productionRevision = try linkIntoProduction(revisionURL, in: fixture)
        let journalBytes = try Data(contentsOf: journalURL)
        let documentBytes = try Data(contentsOf: fileURL)
        let productionBefore = try contents(of: fixture.production)
        let coordinator = fixture.coordinator(enforcing: true)

        let bootstrap = await coordinator.bootstrap()
        // A save that reaches persistence directly is refused before its document commit.
        let edited = try fixture.document(workspaceID: workspaceID, name: "edited", fileURL: fileURL)
        let expectedWorkingRevision = try XCTUnwrap(created.after?.workingRevision)
        await assertBoundaryRejection {
            _ = try await coordinator.persistSaved(
                document: edited,
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: UUID(),
                contextRevisions: [:],
                contextTombstones: [:],
                operations: [],
                now: Date()
            )
        }
        let restarted = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await restarted.start()
        let snapshot = await restarted.workspaceStore.snapshot()
        let outcome = await restarted.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(edited)
        ))
        _ = await restarted.shutdown()

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.reason), [Self.boundaryReason])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(snapshot.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(outcome.disposition, .readOnly)
        XCTAssertEqual(try contents(of: fixture.production), productionBefore)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: revisionURL.path), productionRevision.path)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: fileURL), documentBytes)
    }

    func testRecoveredJournalWithRevisionLinkedIntoProductionMakesBootstrapReadOnly() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let (workspaceID, _, _) = try await createLocalWorkspace(in: fixture)
        // Dropping the catalog entry leaves only the journal, as a crash between the journal commit
        // and catalog publication would, so bootstrap reaches this workspace through recovery.
        let catalogURL = try XCTUnwrap(fixture.runtimeFile(named: "workspace-catalog.json"))
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        catalog["entries"] = []
        try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]).write(to: catalogURL)
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        let revisionURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "revisions"))
        let productionRevision = try linkIntoProduction(revisionURL, in: fixture)
        let journalBytes = try Data(contentsOf: journalURL)
        let productionBefore = try contents(of: fixture.production)

        let bootstrap = await fixture.coordinator(enforcing: true).bootstrap()

        XCTAssertTrue(bootstrap.workspaces.isEmpty)
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.workspaceID), [workspaceID])
        XCTAssertEqual(bootstrap.unavailableWorkspaces.map(\.reason), [Self.boundaryReason])
        XCTAssertEqual(bootstrap.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: revisionURL.path), productionRevision.path)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try contents(of: fixture.production), productionBefore)
    }

    func testCreateRefusesAnOrphanRevisionLinkedIntoProduction() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        // No catalog entry or journal exists for this ID, so bootstrap never reads the revision
        // record that links into production and the runtime stays writable.
        let revision = try productionLinkedRuntimeFile("revisions/\(workspaceID.uuidString).json", in: fixture)
        let productionBefore = try contents(of: fixture.production)
        let fileURL = fixture.defaultDocumentURL(workspaceID: workspaceID, name: "created")
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()
        let health = await runtime.workspaceStore.snapshot().health

        let outcome = try await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .createWorkspace(fixture.document(workspaceID: workspaceID, name: "created", fileURL: fileURL))
        ))
        _ = await runtime.shutdown()

        XCTAssertEqual(health, .writable)
        XCTAssertEqual(outcome.disposition, .failed)
        XCTAssertEqual(outcome.errorCode, .persistenceFailure)
        XCTAssertTrue(outcome.diagnostic?.contains(Self.boundaryReason) == true, outcome.diagnostic ?? "nil")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: revision.link.path), revision.target.path)
        XCTAssertEqual(try contents(of: fixture.production), productionBefore)
        try assertNothingCommitted(for: workspaceID, documentURL: fileURL, in: fixture)
    }

    // Bootstrap already turns the runtime read-only when any deletion record links outside the
    // profile, so the two deletion-record cases drive persistence directly to check its own site.

    func testCreateRefusesAPriorDeletionRecordLinkedIntoProduction() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        let deletion = try productionLinkedRuntimeFile("deletion-tombstones/\(workspaceID.uuidString).json", in: fixture)
        let productionBefore = try contents(of: fixture.production)
        let fileURL = fixture.defaultDocumentURL(workspaceID: workspaceID, name: "created")

        await assertBoundaryRejection {
            _ = try await fixture.persistCreated(
                fixture.document(workspaceID: workspaceID, name: "created", fileURL: fileURL),
                coordinator: fixture.coordinator(enforcing: true)
            )
        }

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: deletion.link.path), deletion.target.path)
        XCTAssertEqual(try contents(of: fixture.production), productionBefore)
        try assertNothingCommitted(for: workspaceID, documentURL: fileURL, in: fixture)
    }

    func testDeleteRefusesADeletionRecordLinkedIntoProduction() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let (workspaceID, created, fileURL) = try await createLocalWorkspace(in: fixture)
        let deletion = try productionLinkedRuntimeFile("deletion-tombstones/\(workspaceID.uuidString).json", in: fixture)
        let catalogURL = try XCTUnwrap(fixture.runtimeFile(named: "workspace-catalog.json"))
        let journalURL = try XCTUnwrap(fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"))
        let catalogBytes = try Data(contentsOf: catalogURL)
        let journalBytes = try Data(contentsOf: journalURL)
        let documentBytes = try Data(contentsOf: fileURL)
        let productionBefore = try contents(of: fixture.production)
        let document = try fixture.document(workspaceID: workspaceID, name: "inside", fileURL: fileURL)
        let expectedWorkspaceRevision = try XCTUnwrap(created.after?.workingRevision)
        let now = Date()
        let operation = DomainRecordedOperation(
            fingerprint: "storage-boundary-delete",
            recordedAt: now,
            outcome: DomainCommandOutcome(
                operationID: UUID(),
                disposition: .applied,
                before: created.after,
                after: nil,
                catalogRevision: 2,
                resultingDigest: nil
            )
        )

        await assertBoundaryRejection {
            _ = try await fixture.coordinator(enforcing: true).persistDeleted(
                document: document,
                expectedWorkspaceRevision: expectedWorkspaceRevision,
                expectedCatalogRevision: nil,
                operation: operation,
                now: now
            )
        }

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: deletion.link.path), deletion.target.path)
        XCTAssertEqual(try contents(of: fixture.production), productionBefore)
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBytes)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: fileURL), documentBytes)
    }

    func testMutationAgainstExternalCatalogFailsWithBoundaryReasonAndWritesNothing() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        try await fixture.createExternallyStoredWorkspace(workspaceID: UUID())
        let catalogURL = try XCTUnwrap(fixture.runtimeFile(named: "workspace-catalog.json"))
        let catalogBytes = try Data(contentsOf: catalogURL)
        let newID = UUID()
        let newDocumentURL = fixture.defaultDocumentURL(workspaceID: newID, name: "new")

        await assertBoundaryRejection {
            _ = try await fixture.persistCreated(
                fixture.document(workspaceID: newID, name: "new", fileURL: newDocumentURL),
                coordinator: fixture.coordinator(enforcing: true)
            )
        }

        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDocumentURL.path))
    }

    func testFirstMutationRefusesExternalLegacyIndexBeforeWritingMigrationArtifacts() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let externalID = UUID()
        try fixture.writeDocument(workspaceID: externalID, name: "external", to: fixture.externalDocumentURL)
        try fixture.writeLegacyIndex([(externalID, "external", fixture.externalDirectory)])
        let newID = UUID()
        let newDocumentURL = fixture.defaultDocumentURL(workspaceID: newID, name: "new")

        await assertBoundaryRejection {
            _ = try await fixture.persistCreated(
                fixture.document(workspaceID: newID, name: "new", fileURL: newDocumentURL),
                coordinator: fixture.coordinator(enforcing: true)
            )
        }

        XCTAssertNil(fixture.runtimeFile(named: "runtime-policy.json"))
        XCTAssertNil(fixture.runtimeFile(named: "workspace-catalog.json"))
        XCTAssertNil(fixture.runtimeFile(named: "manifest.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDocumentURL.path))
    }

    func testCreateOutsideTheRootIsRejectedBeforeAnyWrite() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()

        await assertBoundaryRejection {
            _ = try await fixture.persistCreated(
                fixture.document(workspaceID: workspaceID, name: "external", fileURL: fixture.externalDocumentURL),
                coordinator: fixture.coordinator(enforcing: true)
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalDocumentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeRootParent.path))
    }

    func testAgentVisibleOutcomeCarriesTheBoundaryReason() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()
        let document = try fixture.document(
            workspaceID: UUID(),
            name: "external",
            fileURL: fixture.externalDocumentURL
        )

        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        _ = await runtime.shutdown()

        XCTAssertEqual(outcome.disposition, .failed)
        XCTAssertEqual(outcome.errorCode, .persistenceFailure)
        XCTAssertTrue(
            outcome.diagnostic?.contains(Self.boundaryReason) == true,
            outcome.diagnostic ?? "nil"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalDocumentURL.path))
    }

    func testAuthorityReportsReadOnlyHealthForExternalBacking() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        try fixture.writeDocument(workspaceID: workspaceID, name: "external", to: fixture.externalDocumentURL)
        try fixture.writeLegacyIndex([(workspaceID, "external", fixture.externalDirectory)])
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()

        let snapshot = await runtime.workspaceStore.snapshot()
        _ = await runtime.shutdown()

        XCTAssertEqual(snapshot.health, .degradedReadOnly(reason: Self.boundaryReason))
        XCTAssertTrue(snapshot.workspaces.isEmpty)
    }

    func testEnforcedRuntimeWritesFormatsAnUnflaggedRuntimeReads() async throws {
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        let workspaceID = UUID()
        _ = try await fixture.persistCreated(
            fixture.document(
                workspaceID: workspaceID,
                name: "inside",
                fileURL: fixture.defaultDocumentURL(workspaceID: workspaceID, name: "inside")
            ),
            coordinator: fixture.coordinator(enforcing: true)
        )

        let unflagged = await fixture.coordinator(enforcing: false).bootstrap()
        let enforced = await fixture.coordinator(enforcing: true).bootstrap()

        XCTAssertEqual(unflagged.workspaces.map(\.document.workspaceID), [workspaceID])
        XCTAssertEqual(enforced.workspaces.map(\.document.workspaceID), [workspaceID])
        XCTAssertEqual(unflagged.health, .writable)
        XCTAssertEqual(enforced.health, .writable)
        XCTAssertEqual(unflagged.catalogRevision, enforced.catalogRevision)
    }

    #if DEBUG
        func testCancellationBeforeWorkingCommitLeavesEveryFileUnchanged() async throws {
            let fixture = try BoundaryFixture.make()
            defer { fixture.remove() }
            try fixture.seedProductionSentinel()
            let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
            try await runtime.start()
            let (created, fileURL) = try await fixture.createInRootWorkspace(in: runtime, name: "inside")
            let workspaceID = try XCTUnwrap(created.workspace?.document.workspaceID)
            let before = try fixture.fileTree()
            let gate = PersistenceGate()
            await runtime.workspaceStore.testSetBeforeWorkingPersistence { _ in
                await gate.arriveAndWaitForRelease()
            }
            let envelope = try DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedWorkspaceRevision: created.after?.workingRevision,
                origin: .standalone,
                command: .replaceWorkingDocument(
                    fixture.document(workspaceID: workspaceID, name: "cancelled edit", fileURL: fileURL)
                )
            )

            let mutation = Task { await runtime.workspaceStore.execute(envelope) }
            await gate.waitForArrival()
            mutation.cancel()
            await gate.release()
            let outcome = await mutation.value
            let after = try fixture.fileTree()
            await runtime.workspaceStore.testSetBeforeWorkingPersistence(nil)
            _ = await runtime.shutdown()

            XCTAssertEqual(outcome.disposition, .failed)
            XCTAssertEqual(outcome.errorCode, .cancelled)
            XCTAssertEqual(after, before)
            let restarted = await fixture.coordinator(enforcing: true).bootstrap()
            XCTAssertEqual(restarted.workspaces.map(\.document.metadata.name), ["inside"])
            XCTAssertEqual(restarted.workspaces.first?.revisions, created.after)
        }
    #endif

    func testFailureAfterDurableDeleteReportsPartialSuccessInsideTheProfile() async throws {
        try XCTSkipIf(getuid() == 0, "root bypasses directory permissions")
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        try fixture.seedProductionSentinel()
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()
        let (created, fileURL) = try await fixture.createInRootWorkspace(in: runtime, name: "inside")
        let workspaceID = try XCTUnwrap(created.workspace?.document.workspaceID)
        // The catalog tombstone commits first; a read-only document folder then makes the
        // artifact cleanup that follows the durable commit fail.
        let documentFolder = fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: documentFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documentFolder.path) }
        let outsideBefore = try fixture.fileTree(excluding: fixture.debugOwnedLocations)

        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .standalone,
            command: .deleteWorkspace(workspaceID: workspaceID)
        ))
        let outsideAfter = try fixture.fileTree(excluding: fixture.debugOwnedLocations)
        _ = await runtime.shutdown()

        XCTAssertEqual(outcome.disposition, .applied)
        XCTAssertNil(outcome.errorCode)
        XCTAssertTrue(
            outcome.diagnostic?.hasPrefix("artifact_cleanup_incomplete:") == true,
            outcome.diagnostic ?? "nil"
        )
        XCTAssertTrue(outcome.diagnostic?.contains("workspace document") == true, outcome.diagnostic ?? "nil")
        XCTAssertEqual(outsideAfter, outsideBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let restarted = await fixture.coordinator(enforcing: true).bootstrap()
        XCTAssertTrue(restarted.workspaces.isEmpty)
        XCTAssertEqual(restarted.deletedWorkspaceIDs, [workspaceID])
        XCTAssertEqual(restarted.health, .writable)
    }

    func testWorkingWriteFailureWritesNothingAnywhere() async throws {
        try XCTSkipIf(getuid() == 0, "root bypasses directory permissions")
        let fixture = try BoundaryFixture.make()
        defer { fixture.remove() }
        try fixture.seedProductionSentinel()
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()
        let (created, fileURL) = try await fixture.createInRootWorkspace(in: runtime, name: "inside")
        let workspaceID = try XCTUnwrap(created.workspace?.document.workspaceID)
        let journalFolder = try XCTUnwrap(
            fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals")
        ).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journalFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journalFolder.path) }
        let before = try fixture.fileTree()

        let outcome = try await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(
                fixture.document(workspaceID: workspaceID, name: "unwritable edit", fileURL: fileURL)
            )
        ))
        let after = try fixture.fileTree()
        _ = await runtime.shutdown()

        XCTAssertEqual(outcome.disposition, .failed)
        XCTAssertEqual(outcome.errorCode, .persistenceFailure)
        XCTAssertTrue(outcome.diagnostic?.contains("writeFailed") == true, outcome.diagnostic ?? "nil")
        XCTAssertEqual(after, before)
    }

    /// Creates a workspace inside the profile through an enforcing runtime and stops it, so its
    /// catalog entry, document, journal, revision record, and lock are all local.
    private func createLocalWorkspace(in fixture: BoundaryFixture) async throws -> (UUID, DomainCommandOutcome, URL) {
        let runtime = MCPDomainRuntime(configuration: fixture.configuration(enforcing: true))
        try await runtime.start()
        let (created, fileURL) = try await fixture.createInRootWorkspace(in: runtime, name: "inside")
        _ = await runtime.shutdown()
        return try (XCTUnwrap(created.workspace?.document.workspaceID), created, fileURL)
    }

    /// Replaces a runtime file with a link to the same folder and name under the fixture's
    /// production profile, moving its bytes there first unless that target should stay absent.
    @discardableResult
    private func linkIntoProduction(_ url: URL, in fixture: BoundaryFixture, keepingTarget: Bool = true) throws -> URL {
        let target = fixture.production
            .appendingPathComponent(url.deletingLastPathComponent().lastPathComponent, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if keepingTarget {
            try FileManager.default.moveItem(at: url, to: target)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return target
    }

    /// Leaves a link at a runtime-root path into the fixture's production profile, the way an
    /// existing symlink would, and returns the link and its production target.
    private func productionLinkedRuntimeFile(
        _ relativePath: String,
        in fixture: BoundaryFixture
    ) throws -> (link: URL, target: URL) {
        let link = fixture.runtimeRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"marker":"production"}"#.utf8).write(to: link)
        return try (link, linkIntoProduction(link, in: fixture))
    }

    /// A refused create commits no document, working journal, or catalog entry for the workspace.
    private func assertNothingCommitted(
        for workspaceID: UUID,
        documentURL: URL,
        in fixture: BoundaryFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentURL.path), file: file, line: line)
        XCTAssertNil(
            fixture.runtimeFile(named: "\(workspaceID.uuidString).json", in: "working-journals"),
            file: file,
            line: line
        )
        let catalogIDs: [String] = try fixture.runtimeFile(named: "workspace-catalog.json").map { url -> [String] in
            let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            return (catalog?["entries"] as? [[String: Any]] ?? []).compactMap { $0["workspaceID"] as? String }
        } ?? []
        XCTAssertFalse(catalogIDs.contains(workspaceID.uuidString), "\(catalogIDs)", file: file, line: line)
    }

    /// Every entry under a directory that holds no links, keyed by relative path.
    private func contents(of directory: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            contents[relative] = isDirectory.boolValue ? Data() : try Data(contentsOf: url)
        }
        return contents
    }

    private func assertBoundaryRejection(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected the workspace storage boundary to reject the mutation", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .invalidWorkspaceDocument(reason: Self.boundaryReason),
                file: file,
                line: line
            )
        }
    }
}

/// Holds a mutation at an authority persistence gate until the test releases it.
private actor PersistenceGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWaitForRelease() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct BoundaryFixture {
    let root: URL

    static func make() throws -> BoundaryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainWorkspaceStorageBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        let fixture = BoundaryFixture(root: root)
        try FileManager.default.createDirectory(at: fixture.workspaceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.externalDirectory, withIntermediateDirectories: true)
        return fixture
    }

    var storageDirectory: URL { root.appendingPathComponent("profile", isDirectory: true) }
    var workspaceDirectory: URL { storageDirectory.appendingPathComponent("Workspaces", isDirectory: true) }
    var externalDirectory: URL { root.appendingPathComponent("external-workspace", isDirectory: true) }
    var externalDocumentURL: URL { externalDirectory.appendingPathComponent("workspace.json") }
    var legacyIndexURL: URL { workspaceDirectory.appendingPathComponent("workspacesIndex.json") }
    var runtimeRootParent: URL { storageDirectory.appendingPathComponent("DomainRuntime", isDirectory: true) }
    var production: URL { root.appendingPathComponent("production/RepoPrompt CE", isDirectory: true) }
    var runtimeRoot: URL {
        DomainRuntimeConfiguration.runtimeRootDirectory(
            storageDirectory: storageDirectory,
            profileIdentifier: "storage-boundary"
        )
    }

    func defaultDocumentURL(workspaceID: UUID, name: String) -> URL {
        workspaceDirectory
            .appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: name, id: workspaceID), isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    func configuration(enforcing: Bool, workspaceStorageDirectory: URL? = nil) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "storage-boundary",
            storageDirectory: storageDirectory,
            workspaceStorageDirectory: workspaceStorageDirectory,
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true),
            externalReloadInterval: nil,
            enforcesWorkspaceStorageBoundary: enforcing
        )
    }

    func coordinator(enforcing: Bool, workspaceStorageDirectory: URL? = nil) -> DomainPersistenceCoordinator {
        return DomainPersistenceCoordinator(
            configuration: configuration(enforcing: enforcing, workspaceStorageDirectory: workspaceStorageDirectory),
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 42,
                mode: .standalone,
                createdAt: Date()
            )
        )
    }

    /// Writes through an unflagged runtime whose workspace root is the external directory, which is
    /// how a profile that used external workspace storage leaves its catalog and journal behind.
    func createExternallyStoredWorkspace(workspaceID: UUID) async throws {
        _ = try await persistCreated(
            document(workspaceID: workspaceID, name: "external", fileURL: externalDocumentURL),
            coordinator: coordinator(enforcing: false, workspaceStorageDirectory: externalDirectory)
        )
    }

    func persistCreated(
        _ document: DomainWorkspaceDocument,
        coordinator: DomainPersistenceCoordinator
    ) async throws -> DomainPersistenceSavedCommit {
        let revisions = DomainRevisionState(workingRevision: 1, savedRevision: 1, dirtyRevision: nil)
        let operationID = UUID()
        let now = Date()
        return try await coordinator.persistCreated(
            document: document,
            expectedCatalogRevision: nil,
            operationID: operationID,
            contextRevisions: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                ($0.identity.contextID, revisions)
            }),
            operation: DomainRecordedOperation(
                fingerprint: "storage-boundary-create",
                recordedAt: now,
                outcome: DomainCommandOutcome(
                    operationID: operationID,
                    disposition: .applied,
                    before: nil,
                    after: revisions,
                    catalogRevision: 1,
                    resultingDigest: document.contentDigest
                )
            ),
            now: now
        )
    }

    func document(workspaceID: UUID, name: String, fileURL: URL) throws -> DomainWorkspaceDocument {
        try DomainWorkspaceDocument.decode(documentBytes: documentBytes(workspaceID: workspaceID, name: name), fileURL: fileURL)
    }

    func writeDocument(workspaceID: UUID, name: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try documentBytes(workspaceID: workspaceID, name: name).write(to: url)
    }

    func writeLegacyIndex(_ entries: [(id: UUID, name: String, customStoragePath: URL?)]) throws {
        let objects: [[String: Any]] = entries.map { entry in
            var object: [String: Any] = [
                "id": entry.id.uuidString,
                "name": entry.name,
                "isSystemWorkspace": false,
                "isHiddenInMenus": false
            ]
            object["customStoragePath"] = entry.customStoragePath?.absoluteString
            return object
        }
        try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]).write(to: legacyIndexURL)
    }

    /// Finds a runtime-owned file by name anywhere under the profile's domain runtime directory.
    func runtimeFile(named name: String, in parentName: String? = nil) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: runtimeRootParent, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            if let parentName, url.deletingLastPathComponent().lastPathComponent != parentName { continue }
            return url
        }
        return nil
    }

    /// Locations a debug runtime owns in this fixture: its profile plus the event and temporary
    /// directories the fixture configuration places beside it.
    var debugOwnedLocations: [URL] {
        [
            storageDirectory,
            root.appendingPathComponent("Events", isDirectory: true),
            root.appendingPathComponent("Temporary", isDirectory: true)
        ]
    }

    func seedProductionSentinel() throws {
        let sentinel = root.appendingPathComponent("production/RepoPrompt CE/Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"marker":"production"}"#.utf8).write(to: sentinel)
    }

    func createInRootWorkspace(
        in runtime: MCPDomainRuntime,
        name: String
    ) async throws -> (DomainCommandOutcome, URL) {
        let workspaceID = UUID()
        let fileURL = defaultDocumentURL(workspaceID: workspaceID, name: name)
        let created = try await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .createWorkspace(document(workspaceID: workspaceID, name: name, fileURL: fileURL))
        ))
        XCTAssertEqual(created.disposition, .applied, created.diagnostic ?? "")
        return (created, fileURL)
    }

    /// Every directory and file under the fixture, keyed by path, so any new, removed, or
    /// rewritten entry shows up as a difference.
    func fileTree(excluding excluded: [URL] = []) throws -> [String: Data] {
        let excludedPaths = excluded.map(\.standardizedFileURL.path)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [:] }
        var tree: [String: Data] = [:]
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            if excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            tree[path] = isDirectory ? Data() : try Data(contentsOf: url)
        }
        return tree
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func documentBytes(workspaceID: UUID, name: String) throws -> Data {
        let contextID = UUID()
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": name,
            "repoPaths": [root.path],
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
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
