import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderNestedSelectionFrozenReviewTests: XCTestCase {
    func testNestedSetReusesFrozenReviewContextWithoutWatchdogDetachment() async throws {
        let fixture = try await makeSelectionFixture(name: "frozen-review", gitBacked: true)
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
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
        let target = try XCTUnwrap(workspaceContext.reviewTargetResolution.availableTarget)
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
        try await fixture.window.mcpServer.validateContextBuilderGitArtifactSelection(
            metadata: fixture.metadata,
            target: target
        )
        let completion = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
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
            isStillCurrent: { true }
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
            isStillCurrent: { true }
        )

        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, newer)
        XCTAssertEqual(fixture.canonicalSelection, newer)
    }

    private func makeFixture(name: String) async throws -> Fixture {
        try await makeSelectionFixture(name: name)
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
