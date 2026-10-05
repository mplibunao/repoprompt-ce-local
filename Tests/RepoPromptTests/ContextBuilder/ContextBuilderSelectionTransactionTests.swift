import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderNestedSelectionFrozenReviewTests: XCTestCase {
    private enum InitialReviewResolution: Equatable {
        case available
        case deferred
        case unavailable
    }

    func testNestedSetReusesAvailableReviewContextWithoutWatchdogDetachment() async throws {
        try await assertNestedSetReusesFrozenReviewContext(name: "available-review", initialResolution: .available)
    }

    func testNestedSetReusesDeferredReviewContextWithoutWatchdogDetachment() async throws {
        try await assertNestedSetReusesFrozenReviewContext(name: "deferred-review", initialResolution: .deferred)
    }

    func testNestedSetReusesUnavailableReviewContextWithoutWatchdogDetachment() async throws {
        try await assertNestedSetReusesFrozenReviewContext(name: "unavailable-review", initialResolution: .unavailable)
    }

    private func assertNestedSetReusesFrozenReviewContext(
        name: String,
        initialResolution: InitialReviewResolution
    ) async throws {
        let fixture = try await makeSelectionFixture(name: name, gitBacked: true)
        defer { fixture.cleanup() }
        let source = switch initialResolution {
        case .available:
            StoredSelection(selectedPaths: [fixture.fileA.path])
        case .deferred:
            StoredSelection()
        case .unavailable:
            StoredSelection(selectedPaths: [fixture.root.appendingPathComponent("Missing.swift").path])
        }
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)

        var parentContext = try fixture.makeContext(selection: source)
        parentContext.activeAgentSessionID = UUID()
        parentContext.worktreeBindingState = .hydrated([])
        let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
        let workspaceContext = try await ContextBuilderWorkspaceContext.resolve(
            from: parentContext,
            workspaceRepoPaths: [fixture.root.path],
            workspaceDirectoryPath: fixture.window.workspaceManager.workspaceDirectory(for: workspace).path,
            store: fixture.window.promptManager.workspaceFileContextStore
        )
        let unavailableReason: ContextBuilderReviewTargetUnavailableReason?
        switch workspaceContext.reviewTargetResolution {
        case .available where initialResolution == .available:
            unavailableReason = nil
        case .deferred where initialResolution == .deferred:
            unavailableReason = nil
        case let .unavailable(reason) where initialResolution == .unavailable:
            unavailableReason = reason
        case .available, .deferred, .unavailable:
            return XCTFail("Unexpected initial review-target resolution")
        }
        fixture.window.mcpServer.tabContextByConnectionID[fixture.connectionID] =
            workspaceContext.nestedDiscoveryTabContext(runID: fixture.runID)
        fixture.window.mcpServer.setRequestMetadataOverrideForTesting(fixture.metadata)

        let legacyFreezeGate = ContextBuilderTestGate()
        fixture.window.mcpServer.setContextBuilderBeforeLegacySelectionReviewFreezeForTesting {
            await legacyFreezeGate.wait()
        }
        defer {
            fixture.window.mcpServer.setContextBuilderBeforeLegacySelectionReviewFreezeForTesting(nil)
            fixture.window.mcpServer.setRequestMetadataOverrideForTesting(nil)
        }

        let tools = await fixture.window.mcpServer.windowMCPToolCatalogService.tools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.manageSelection })
        let clock = ContinuousClock()
        let origin = clock.now
        let environment = MCPToolExecutionWatchdogEnvironment(
            now: { origin.duration(to: clock.now) },
            sleep: { try await Task.sleep(for: $0) }
        )
        do {
            _ = try await MCPToolExecutionWatchdog.execute(
                deadline: .seconds(1),
                cancellationGrace: .milliseconds(100),
                cleanupDisposition: .detachAndSettle,
                environment: environment
            ) {
                try await tool([
                    "op": .string("set"),
                    "paths": .array([.string(fixture.fileB.path)]),
                    "mode": .string("full")
                ])
            }
        } catch {
            await legacyFreezeGate.open()
            return XCTFail("nested manage_selection failed: \(error)")
        }
        await legacyFreezeGate.open()

        let legacyFreezeWasEntered = await legacyFreezeGate.entered
        XCTAssertFalse(legacyFreezeWasEntered)
        XCTAssertEqual(fixture.canonicalSelection, discovered)
        let finalContext = try XCTUnwrap(fixture.boundContext)
        if let unavailableReason {
            do {
                _ = try await workspaceContext.authorizeFinalReviewSelection(
                    finalContext.selection,
                    workspaceID: fixture.workspaceID,
                    tabID: fixture.tabID,
                    selectionRevision: finalContext.selectionRevision,
                    store: fixture.window.promptManager.workspaceFileContextStore
                )
                return XCTFail("Expected final review authorization to retain the initial rejection")
            } catch let error as ContextBuilderReviewTargetUnavailableReason {
                XCTAssertEqual(error, unavailableReason)
            }
            return
        }
        let authorization = try await workspaceContext.authorizeFinalReviewSelection(
            finalContext.selection,
            workspaceID: fixture.workspaceID,
            tabID: fixture.tabID,
            selectionRevision: finalContext.selectionRevision,
            store: fixture.window.promptManager.workspaceFileContextStore
        )
        let expectedOrigin: ContextBuilderReviewElectionOrigin = initialResolution == .available
            ? .initiallyAvailable
            : .deferred
        XCTAssertEqual(authorization.electionOrigin, expectedOrigin)
        let completion = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            authority: .unconditional
        )
        XCTAssertEqual(completion.outcome, .committed)
        XCTAssertEqual(completion.committedTab?.tab.selection, discovered)
    }
}

@MainActor
final class ContextBuilderSelectionTransactionTests: XCTestCase {
    func testContextBuilderToolMutationPublishesCanonicalSelectionImmediately() async throws {
        let fixture = try await makeFixture(name: "immediate")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        let verification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertTrue(verification?.isVerified == true)
        XCTAssertEqual(verification?.canonicalSelection, discovered)
        XCTAssertEqual(fixture.canonicalSelection, discovered)
        XCTAssertEqual(fixture.boundContext?.selection, discovered)
    }

    func testSuccessfulEarlierToolMutationSurvivesLaterDiscoveryFailure() async throws {
        let fixture = try await makeFixture(name: "failure")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )
        fixture.window.mcpServer.removeTabContext(
            forConnectionID: fixture.connectionID,
            clientName: nil,
            windowID: fixture.window.windowID,
            runID: fixture.runID
        )
        let failedCommit = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            authority: .unconditional
        )

        guard case .missingFinalContext = failedCommit.outcome else {
            return XCTFail("Expected the failed discovery to have no terminal context")
        }
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testContextBuilderAndOrdinaryAgentMutationsUseSameCanonicalPath() async throws {
        let fixture = try await makeFixture(name: "shared-path")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let first = StoredSelection(selectedPaths: [fixture.fileB.path])
        let second = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)

        let contextBuilderContext = try fixture.installContext(selection: source)
        let firstVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: contextBuilderContext.withSelection(first)),
            metadata: fixture.metadata,
            mutated: true
        )
        let ordinaryAgentContext = try XCTUnwrap(fixture.boundContext)
        let secondVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: ordinaryAgentContext.withSelection(second)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(firstVerification?.canonicalSelection, first)
        XCTAssertEqual(secondVerification?.canonicalSelection, second)
        XCTAssertEqual(fixture.canonicalSelection, second)
    }

    func testDeferredUISnapshotCannotClobberImmediateCanonicalPublication() async throws {
        let fixture = try await makeFixture(name: "ui-fence")
        defer { fixture.cleanup() }
        await fixture.window.promptManager.switchComposeTab(fixture.tabID)
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(
            fixture.window.selectionCoordinator.selectionForActiveUISnapshot(
                source,
                tabID: fixture.tabID
            ),
            discovered,
            "A UI snapshot queued before the tool mutation must not revoke canonical selection"
        )
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testOraclePackagingObservesImmediateCanonicalContextBuilderSelection() async throws {
        let fixture = try await makeFixture(name: "oracle-packaging")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        let stabilized = await fixture.window.mcpServer.stabilizedVirtualContext(for: context)
        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: stabilized.tabID,
            sourceWorkspaceID: stabilized.workspaceID,
            sourceSelectionRevision: stabilized.selectionRevision,
            sourceAgentSessionID: stabilized.activeAgentSessionID,
            sourceAgentRunID: stabilized.runID,
            promptText: stabilized.promptText,
            selection: stabilized.selection,
            lookupContext: stabilized.frozenLookupContext,
            reviewGitContext: .automaticOnly(base: "HEAD"),
            provenance: .direct
        )

        XCTAssertEqual(packaging.selection, discovered)
        XCTAssertFalse(packaging.selection.selectedPaths.contains(fixture.fileA.path))
    }

    func testTerminalCommitPreservesNewerCanonicalSelection() async throws {
        let fixture = try await makeFixture(name: "terminal-fence")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let newer = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)
        let staleRunContext = try fixture.installContext(selection: source)

        _ = await fixture.window.selectionCoordinator.persistSelection(
            newer,
            for: fixture.identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        fixture.window.mcpServer.tabContextByConnectionID[fixture.connectionID] = staleRunContext

        let result = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            authority: .unconditional
        )

        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, newer)
        XCTAssertEqual(fixture.canonicalSelection, newer)
    }

    /// A run that loses its tab while the commit is suspended at its last step before the write
    /// writes nothing. The run still owns the tab at every earlier check, so only the check made
    /// in the turn of the write can refuse it.
    func testCommitWritesNothingForRunThatLostItsTabBeforeTheWrite() async throws {
        let fixture = try await makeFixture(name: "authority-before-write")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let revisionBefore = fixture.selectionRevision
        _ = try fixture.installContext(selection: discovered)

        let run = CommittingRun()
        let result = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            authority: run.authority,
            progressReporter: { phase in
                run.reportedPhases.append(phase)
                if phase == .tabContextCommit {
                    run.ownsTab = false
                }
            }
        )

        XCTAssertEqual(run.reportedPhases.last, .tabContextCommit, "The run lost its tab at the last step before the write")
        XCTAssertEqual(result.outcome, .staleOrNoLongerCurrent)
        XCTAssertNil(result.committedTab)
        XCTAssertTrue(run.receipts.isEmpty)
        XCTAssertEqual(fixture.canonicalSelection, source)
        XCTAssertEqual(fixture.selectionRevision, revisionBefore)
    }

    /// A run that loses its tab in the turn that writes the tab is still told what was written,
    /// and the commit reports that exact receipt instead of reporting the run as stale.
    func testCommitKeepsItsReceiptWhenRunLosesItsTabAtTheWrite() async throws {
        let fixture = try await makeFixture(name: "authority-at-write")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        _ = try fixture.installContext(selection: discovered)

        let run = CommittingRun()
        run.losesTabAtTheWrite = true
        let result = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            authority: run.authority
        )

        XCTAssertFalse(run.ownsTab)
        XCTAssertEqual(run.receipts.count, 1)
        let receipt = try XCTUnwrap(run.receipts.first)
        XCTAssertEqual(receipt.identity, fixture.identity)
        XCTAssertEqual(receipt.nestedRunID, fixture.runID)
        XCTAssertEqual(receipt.tab.selection, discovered)
        XCTAssertEqual(receipt.selectionRevision, fixture.selectionRevision)
        XCTAssertEqual(result.outcome, .committed)
        let committed = try XCTUnwrap(result.committedTab)
        XCTAssertEqual(committed.identity, receipt.identity)
        XCTAssertEqual(committed.nestedRunID, receipt.nestedRunID)
        XCTAssertEqual(committed.tab, receipt.tab)
        XCTAssertEqual(committed.selectionRevision, receipt.selectionRevision)
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    /// A commit based on a selection revision the tab has not reached writes the tab and then
    /// cannot confirm that the tab holds the run's selection. The run is handed exactly what the
    /// tab now holds, in the turn of the write, and the commit fails with that same receipt.
    func testCommitThatCannotConfirmItsSelectionFailsWithReceiptOfWhatWasStored() async throws {
        let fixture = try await makeFixture(name: "unconfirmed-revision")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let tabBefore = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
        let revisionBefore = fixture.selectionRevision
        var context = try fixture.makeContext(selection: discovered)
        context.selectionRevision = revisionBefore + 1
        context.promptText = "Prompt written by the run"
        fixture.window.mcpServer.tabContextByConnectionID[fixture.connectionID] = context

        let run = CommittingRun()
        var storedAtTheWrite: ComposeTabState?
        run.onReceipt = { storedAtTheWrite = fixture.window.workspaceManager.composeTab(for: fixture.identity) }
        let result = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            authority: run.authority
        )

        // The write happened: the prompt is the run's, and the selection the commit could not
        // confirm is still the tab's own.
        let stored = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
        XCTAssertNotEqual(stored, tabBefore)
        XCTAssertEqual(stored.promptText, "Prompt written by the run")
        XCTAssertEqual(stored.selection, source)
        XCTAssertEqual(fixture.selectionRevision, revisionBefore)

        XCTAssertTrue(run.ownsTab)
        XCTAssertEqual(run.receipts.count, 1)
        let receipt = try XCTUnwrap(run.receipts.first)
        XCTAssertEqual(receipt.identity, fixture.identity)
        XCTAssertEqual(receipt.nestedRunID, fixture.runID)
        XCTAssertEqual(receipt.tab, stored)
        XCTAssertEqual(receipt.tab, storedAtTheWrite, "The receipt was handed over in the turn of the write")
        XCTAssertEqual(receipt.selectionRevision, revisionBefore)

        guard case .failed = result.outcome else {
            XCTFail("A write the commit could not confirm was reported as \(result.outcome)")
            return
        }
        let committed = try XCTUnwrap(result.committedTab)
        XCTAssertEqual(committed.identity, receipt.identity)
        XCTAssertEqual(committed.nestedRunID, receipt.nestedRunID)
        XCTAssertEqual(committed.tab, receipt.tab)
        XCTAssertEqual(committed.selectionRevision, receipt.selectionRevision)
    }

    private func makeFixture(name: String) async throws -> Fixture {
        try await makeSelectionFixture(name: name)
    }
}

/// Stands in for the run a final-context commit acts for, so a test decides when that run stops
/// owning its tab and sees the receipts it is handed.
@MainActor
private final class CommittingRun {
    var ownsTab = true
    var losesTabAtTheWrite = false
    var receipts: [MCPServerViewModel.ContextBuilderCommittedTabSnapshot] = []
    var reportedPhases: [ContextBuilderMCPProgressPhase] = []
    /// Runs in the turn that hands the run a receipt.
    var onReceipt: (@MainActor () -> Void)?

    var authority: MCPServerViewModel.ContextBuilderCommitAuthority {
        .init(
            ownsCommit: { self.ownsTab },
            didWriteTab: { receipt in
                self.receipts.append(receipt)
                self.onReceipt?()
                if self.losesTabAtTheWrite {
                    self.ownsTab = false
                }
            }
        )
    }
}

private extension MCPServerViewModel.ContextBuilderCommitAuthority {
    /// A run that owns its tab throughout and has no use for its receipt.
    static var unconditional: Self {
        .init(ownsCommit: { true }, didWriteTab: { _ in })
    }
}

@MainActor
private func makeSelectionFixture(name: String, gitBacked: Bool = false) async throws -> Fixture {
    let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
    GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
    let window = WindowState()
    GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
    WindowStatesManager.shared.registerWindowState(window)
    await window.workspaceManager.awaitInitialized()

    let reviewRepository = try gitBacked ? ReviewGitRepositoryFixture(name: name) : nil
    let root: URL
    if let reviewRepository {
        root = try reviewRepository.makeRepository(
            named: name,
            files: ["A.swift": "// A.swift", "B.swift": "// B.swift", "C.swift": "// C.swift"]
        )
    } else {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderSelectionTransactionTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A.swift", "B.swift", "C.swift"] {
            try "// \(name)".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
    let files = ["A.swift", "B.swift", "C.swift"].map { root.appendingPathComponent($0) }
    let workspace = window.workspaceManager.createWorkspace(name: name, repoPaths: [root.path], ephemeral: true)
    await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: name)
    let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
    let backgroundTab = await window.promptManager.createBackgroundComposeTab(
        strategy: .blank,
        name: "Transaction \(name)"
    )
    let tabID = try XCTUnwrap(backgroundTab?.id)
    return Fixture(
        window: window,
        root: root,
        workspaceID: workspaceID,
        tabID: tabID,
        fileA: files[0],
        fileB: files[1],
        fileC: files[2],
        reviewRepository: reviewRepository
    )
}

@MainActor
private struct Fixture {
    let window: WindowState
    let root: URL
    let workspaceID: UUID
    let tabID: UUID
    let fileA: URL
    let fileB: URL
    let fileC: URL
    let reviewRepository: ReviewGitRepositoryFixture?
    let connectionID = UUID()
    let runID = UUID()

    var identity: WorkspaceSelectionIdentity {
        .init(workspaceID: workspaceID, tabID: tabID)
    }

    var metadata: MCPServerViewModel.RequestMetadata {
        .init(
            connectionID: connectionID,
            clientName: "selection-transaction-test",
            windowID: window.windowID,
            runPurpose: .discoverRun
        )
    }

    var canonicalSelection: StoredSelection? {
        window.workspaceManager.composeTab(for: identity)?.selection
    }

    var selectionRevision: UInt64 {
        window.workspaceManager.selectionRevisionForMCP(workspaceID: workspaceID, tabID: tabID)
    }

    var boundContext: MCPServerViewModel.TabContextSnapshot? {
        window.mcpServer.tabContextByConnectionID[connectionID]
    }

    func seedCanonical(_ selection: StoredSelection) async throws {
        _ = await window.selectionCoordinator.persistSelection(
            selection,
            for: identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        XCTAssertEqual(canonicalSelection, selection)
    }

    func installContext(selection: StoredSelection) throws -> MCPServerViewModel.TabContextSnapshot {
        let context = try makeContext(selection: selection)
        window.mcpServer.tabContextByConnectionID[connectionID] = context
        return context
    }

    func makeContext(selection: StoredSelection) throws -> MCPServerViewModel.TabContextSnapshot {
        let tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        return MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspaceID,
            promptText: tab.promptText,
            selection: selection,
            selectionRevision: window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: tabID
            ),
            selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
            tabName: tab.name,
            runID: runID,
            explicitlyBound: false
        )
    }

    func cleanup() {
        window.beginClose()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: root)
    }
}

private extension MCPServerViewModel.TabContextSnapshot {
    func withSelection(_ selection: StoredSelection) -> Self {
        var copy = self
        copy.selection = selection
        return copy
    }
}
