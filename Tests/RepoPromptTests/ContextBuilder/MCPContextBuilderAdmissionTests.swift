import Combine
import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// The order in which the `context_builder` tool handler admits a call, driven by caller
    /// connections through MCP dispatch against the window's own Context Builder view model.
    @MainActor
    final class MCPContextBuilderAdmissionTests: XCTestCase {
        /// A call for a tab that already has a run is refused before the handler binds the caller,
        /// drains the caller's read-file auto-selection, creates a provider, or changes the tab.
        ///
        /// Two callers make the refused call, one for each step that would otherwise show: a caller
        /// with no tab binding that names the tab, which an admitted call binds, and a caller bound
        /// to the tab whose earlier `read_file` left auto-selection work that an admitted call
        /// drains. The same two calls are repeated once the tab is free to show that each step is
        /// observable.
        func testSameTabRefusalPrecedesBindingAndDrain() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let server = fixture.window.mcpServer
                let slot = fixture.slots[0]
                let namesTab: [String: Any] = ["context_id": slot.tabID.uuidString, "instructions": "Find the entry point"]
                let usesBinding: [String: Any] = ["instructions": "Find the entry point"]
                let (bound, unbound, drains) = try await Self.connectCallers(to: slot, fixture: fixture, cleanup: cleanup)

                let incumbentProvider = ContextBuilderUnroutedProvider()
                fixture.providerScript = { _ in
                    fixture.providerRequests.count == 1
                        ? incumbentProvider
                        : ContextBuilderUnroutedProvider(finishesImmediately: true)
                }
                fixture.releaseOnSettle { await incumbentProvider.finish() }
                let incumbent = fixture.startMCPRun(on: slot)
                try await fixture.waitFor("the incumbent run's provider to start its turn") {
                    incumbentProvider.runID != nil
                }

                let before = Observed(fixture, slot, bound: bound, unbound: unbound, drains: drains)
                XCTAssertEqual(before.unboundBinding.bindingKind, .unbound)
                XCTAssertEqual(before.boundBinding.tabID, slot.tabID)
                XCTAssertEqual(before.activeRunID, incumbentProvider.runID)
                XCTAssertEqual(before.providerCount, 1)
                XCTAssertEqual(before.drainCount, 0)

                for (caller, arguments) in [(unbound, namesTab), (bound, usesBinding)] {
                    let refused = try await caller.callTool(
                        name: MCPWindowToolName.contextBuilder,
                        arguments: arguments,
                        timeoutSeconds: 30
                    )
                    XCTAssertTrue(
                        refused.rawJSON.contains("Context Builder is already running for this tab."),
                        refused.rawJSON
                    )
                    XCTAssertEqual(Observed(fixture, slot, bound: bound, unbound: unbound, drains: drains), before)
                }

                await incumbentProvider.finish()
                _ = try await fixture.completion(of: incumbent)
                XCTAssertNil(fixture.operationToken(slot))

                // Provider validation is skipped so that an admitted call ends promptly, either
                // at run-authority resolution or with a provider that never connects.
                let viewModel = fixture.viewModel
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    validateContextBuilderProviders: {}
                ))
                _ = try await bound.callTool(
                    name: MCPWindowToolName.contextBuilder,
                    arguments: usesBinding,
                    timeoutSeconds: 30
                )
                XCTAssertGreaterThan(drains.count, 0)
                XCTAssertNil(fixture.operationToken(slot))
                _ = try await unbound.callTool(
                    name: MCPWindowToolName.contextBuilder,
                    arguments: namesTab,
                    timeoutSeconds: 30
                )
                XCTAssertEqual(server.connectionBindingSnapshot(forConnection: unbound.connectionID).tabID, slot.tabID)
                XCTAssertNil(fixture.operationToken(slot))
            }
        }

        /// A call that is admitted and then loses its tab stops before its next step. Here the
        /// window starts closing in the main-actor turn that publishes the claim, the earliest a
        /// call can lose its tab, and the caller is already bound to the tab, so the first step the
        /// handler would take is draining that caller's read-file auto-selection.
        ///
        /// The same caller's admitted call comes first to show that its drain is observable. The
        /// lost call asks for an exported plan, so every later step the handler has would show:
        /// binding, drain, provider, tab changes, and the export file.
        func testCallThatLosesItsTabAfterTheClaimStopsBeforeDraining() async throws {
            try await ContextBuilderRunFixture.withFixture { fixture, cleanup in
                let slot = fixture.slots[0]
                let viewModel = fixture.viewModel
                let (bound, unbound, drains) = try await Self.connectCallers(to: slot, fixture: fixture, cleanup: cleanup)

                // Provider validation is skipped so that the admitted call ends promptly after
                // its drain, either at run-authority resolution or with a provider that never
                // connects.
                cleanup.add { viewModel.installRunTestHooks(nil) }
                viewModel.installRunTestHooks(.init(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    validateContextBuilderProviders: {}
                ))
                fixture.providerScript = { _ in ContextBuilderUnroutedProvider(finishesImmediately: true) }
                _ = try await bound.callTool(
                    name: MCPWindowToolName.contextBuilder,
                    arguments: ["instructions": "Find the entry point"],
                    timeoutSeconds: 30
                )
                XCTAssertGreaterThan(drains.count, 0)
                XCTAssertNil(fixture.operationToken(slot))
                try await Self.readFile(slot.fileURL, as: bound)

                let before = Observed(fixture, slot, bound: bound, unbound: unbound, drains: drains)
                let rootContentsBefore = try Self.contents(of: fixture.rootURL)
                var claims = 0
                let closesWindowAtClaim = viewModel.$tabsHeldAgainstNewRun
                    .filter { $0.contains(slot.tabID) }
                    .sink { _ in
                        claims += 1
                        viewModel.prepareForWindowClose()
                    }
                cleanup.add { closesWindowAtClaim.cancel() }

                let lost = try await bound.callTool(
                    name: MCPWindowToolName.contextBuilder,
                    arguments: [
                        "instructions": "Find the entry point",
                        "response_type": "plan",
                        "export_response": true
                    ],
                    timeoutSeconds: 30
                )
                XCTAssertEqual(claims, 1, "The call was admitted before it lost its tab")
                XCTAssertTrue(lost.rawJSON.contains("\"isError\":true"), lost.rawJSON)
                XCTAssertTrue(lost.rawJSON.contains("Tool execution was cancelled."), lost.rawJSON)
                XCTAssertEqual(Observed(fixture, slot, bound: bound, unbound: unbound, drains: drains), before)
                XCTAssertEqual(try Self.contents(of: fixture.rootURL), rootContentsBefore)
                XCTAssertEqual(viewModel.tabsHeldAgainstNewRun, [])
            }
        }

        /// Everything a refused call must leave as it found it.
        private struct Observed: Equatable {
            let unboundBinding: MCPServerViewModel.ConnectionBindingSnapshot
            let boundBinding: MCPServerViewModel.ConnectionBindingSnapshot
            let boundAutoSelectionGeneration: UInt64?
            let drainCount: Int
            let providerCount: Int
            let activeRunID: UUID?
            let operationToken: ContextBuilderRunFixture.OperationToken?
            let storedPrompt: String?
            let storedSelection: [String]?
            let selectionRevision: UInt64

            @MainActor
            init(
                _ fixture: ContextBuilderRunFixture,
                _ slot: ContextBuilderRunFixture.TabSlot,
                bound: PersistentMCPTestEndpoint,
                unbound: PersistentMCPTestEndpoint,
                drains: DrainCounter
            ) {
                let server = fixture.window.mcpServer
                unboundBinding = server.connectionBindingSnapshot(forConnection: unbound.connectionID)
                boundBinding = server.connectionBindingSnapshot(forConnection: bound.connectionID)
                boundAutoSelectionGeneration = server.tabContextByConnectionID[bound.connectionID]?
                    .readFileAutoSelectionGeneration
                drainCount = drains.count
                providerCount = fixture.providerRequests.count
                activeRunID = fixture.activeRunID(slot)
                operationToken = fixture.operationToken(slot)
                let stored = fixture.storedTab(slot)
                storedPrompt = stored?.promptText
                storedSelection = stored?.selection.selectedPaths
                selectionRevision = fixture.window.workspaceManager.selectionRevisionForMCP(
                    workspaceID: fixture.workspaceID,
                    tabID: slot.tabID
                )
            }
        }

        /// Counts drains reported from the auto-selection coordinator's own queue.
        private final class DrainCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded = 0

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }

            func record() {
                lock.lock()
                recorded += 1
                lock.unlock()
            }
        }

        /// Starts the window's server and connects the two kinds of caller: `bound`, bound to
        /// `slot` with a `read_file` whose auto-selection work an admitted call drains, and
        /// `unbound`, which has no tab binding. `drains` counts drains for `slot`.
        private static func connectCallers(
            to slot: ContextBuilderRunFixture.TabSlot,
            fixture: ContextBuilderRunFixture,
            cleanup: FixtureCleanup
        ) async throws -> (bound: PersistentMCPTestEndpoint, unbound: PersistentMCPTestEndpoint, drains: DrainCounter) {
            let server = fixture.window.mcpServer
            await fixture.startWindowServer()

            let bound = try await fixture.connectCaller("bound", cleanup: cleanup)
            let bind = try await bound.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": slot.tabID.uuidString]
            )
            XCTAssertFalse(bind.rawJSON.contains("\"isError\":true"), bind.rawJSON)
            await server.domainRoutingPublishTask?.value
            try await readFile(slot.fileURL, as: bound)
            let unbound = try await fixture.connectCaller("unbound", cleanup: cleanup)

            let drains = DrainCounter()
            let windowID = fixture.window.windowID
            cleanup.add { MCPReadFileAutoSelectionDiagnosticTracer.setTestSink(nil) }
            MCPReadFileAutoSelectionDiagnosticTracer.setTestSink { event in
                if event.kind == .drainHighWaterCaptured, event.windowID == windowID, event.tabID == slot.tabID {
                    drains.record()
                }
            }
            return (bound, unbound, drains)
        }

        private static func readFile(_ fileURL: URL, as caller: PersistentMCPTestEndpoint) async throws {
            let read = try await caller.callTool(
                name: MCPWindowToolName.readFile,
                arguments: ["path": fileURL.path]
            )
            XCTAssertFalse(read.rawJSON.contains("\"isError\":true"), read.rawJSON)
        }

        /// Every path under `directory`, so a file written anywhere in it shows.
        private static func contents(of directory: URL) throws -> Set<String> {
            try Set(FileManager.default.subpathsOfDirectory(atPath: directory.path))
        }
    }
#endif
