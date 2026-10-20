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
            authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
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
            authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
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
            authority: .init(ownsCommit: { true }, didWriteTab: { _ in })
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
final class ManageSelectionSliceValidationTests: XCTestCase {
    func testMalformedSliceFailsTheCallAndLeavesSelectionUnchanged() async throws {
        let fixture = try await makeSelectionFixture(name: "malformed-slice")
        defer { fixture.cleanup() }
        let seed = StoredSelection(
            selectedPaths: [fixture.fileA.path],
            slices: [fixture.fileA.path: [LineRange(start: 1, end: 2), LineRange(start: 4, end: 6)]]
        )
        try await fixture.seedCanonical(seed)
        _ = try fixture.installContext(selection: seed)
        let seedRevision = fixture.selectionRevision
        fixture.window.mcpServer.setRequestMetadataOverrideForTesting(fixture.metadata)
        defer { fixture.window.mcpServer.setRequestMetadataOverrideForTesting(nil) }
        let tools = await fixture.window.mcpServer.windowMCPToolCatalogService.tools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.manageSelection })

        let missingEnd: Value = .array([.object([
            "path": .string(fixture.fileA.path),
            "ranges": .array([.object(["start_line": .int(5)])])
        ])])
        // Removing a slice whose ranges end up empty clears every slice of the file.
        let nonObjectRange: Value = .array([.object([
            "path": .string(fixture.fileA.path),
            "ranges": .array([.int(7)])
        ])])
        let validSibling: Value = .array([.string(fixture.fileB.path)])
        let missingEndMessage = "Invalid selection inputs: Invalid slice range for path '\(fixture.fileA.path)': end_line is required; expected ranges: [{start_line, end_line}]."
        let rows: [(label: String, args: [String: Value], message: String)] = [
            ("add beside a valid path", ["op": .string("add"), "paths": validSibling, "slices": missingEnd, "strict": .bool(false)], missingEndMessage),
            ("strict add beside a valid path", ["op": .string("add"), "paths": validSibling, "slices": missingEnd, "strict": .bool(true)], missingEndMessage),
            ("remove from a sliced file", ["op": .string("remove"), "slices": missingEnd, "strict": .bool(false)], missingEndMessage),
            ("get", ["op": .string("get"), "slices": missingEnd], missingEndMessage),
            (
                "remove a non-object range",
                ["op": .string("remove"), "slices": nonObjectRange, "strict": .bool(false)],
                "Invalid selection inputs: Invalid slice range for path '\(fixture.fileA.path)': each range must be an object; expected ranges: [{start_line, end_line}]."
            )
        ]

        for row in rows {
            do {
                _ = try await tool(row.args)
                XCTFail("Expected invalid params: \(row.label)")
            } catch let error as MCPError {
                if case let .invalidParams(message) = error {
                    XCTAssertEqual(message, row.message, row.label)
                } else {
                    XCTFail("Expected MCPError.invalidParams for \(row.label), got \(error)")
                }
            } catch {
                XCTFail("Expected MCPError.invalidParams for \(row.label), got \(error)")
            }
            XCTAssertEqual(fixture.canonicalSelection, seed, row.label)
            XCTAssertEqual(fixture.boundContext?.selection, seed, row.label)
            XCTAssertEqual(fixture.selectionRevision, seedRevision, row.label)
        }
    }

    func testValidRangeIsPublishedCanonically() async throws {
        let fixture = try await makeSelectionFixture(name: "valid-slice", gitBacked: true)
        defer { fixture.cleanup() }
        try (1 ... 10).map { "// line \($0)" }.joined(separator: "\n")
            .write(to: fixture.fileA, atomically: true, encoding: .utf8)
        let seed = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(seed)
        _ = try fixture.installContext(selection: seed)
        fixture.window.mcpServer.setRequestMetadataOverrideForTesting(fixture.metadata)
        defer { fixture.window.mcpServer.setRequestMetadataOverrideForTesting(nil) }
        let tools = await fixture.window.mcpServer.windowMCPToolCatalogService.tools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.manageSelection })

        _ = try await tool([
            "op": .string("add"),
            "slices": .array([.object([
                "path": .string(fixture.fileA.path),
                "ranges": .array([.object(["start_line": .int(3), "end_line": .int(7), "description": .string("focus")])])
            ])])
        ])
        let getResult = try await tool(["op": .string("get"), "view": .string("files")])
        let reply = try JSONDecoder().decode(ToolResultDTOs.SelectionReply.self, from: JSONEncoder().encode(getResult))

        XCTAssertEqual(fixture.canonicalSelection?.slices, [fixture.fileA.path: [LineRange(start: 3, end: 7, description: "focus")]])
        XCTAssertEqual(reply.fileSlices?.map(\.ranges), [[ToolResultDTOs.LineRangeDTO(startLine: 3, endLine: 7, description: "focus")]])
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
        window.workspaceManager.contentGateway.shownComposeTab(identity)?.selection
    }

    var boundContext: MCPServerViewModel.TabContextSnapshot? {
        window.mcpServer.tabContextByConnectionID[connectionID]
    }

    var selectionRevision: UInt64 {
        window.workspaceManager.selectionRevisionForMCP(workspaceID: workspaceID, tabID: tabID)
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
        let tab = try XCTUnwrap(window.workspaceManager.contentGateway.shownComposeTab(identity))
        return MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspaceID,
            promptText: tab.promptText,
            selection: selection,
            selectionRevision: selectionRevision,
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
