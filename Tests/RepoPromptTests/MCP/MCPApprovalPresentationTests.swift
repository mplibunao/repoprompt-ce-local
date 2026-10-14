import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Root notifications for MCP approval presentation.
    ///
    /// The root shell observes `ContentViewModel` but reads the approval identity and overlay
    /// visibility from the window's `MCPServerViewModel`, so the root model has to announce changes
    /// to that pair. It must announce only those: forwarding every MCP update would redraw the root
    /// for ordinary dashboard and diagnostics activity.
    ///
    /// Each test drives the process-wide service under `MCPSharedServerTestLease`. Publications of the
    /// root model's own routing properties are counted and subtracted, and the remaining root events
    /// are attributed to approval.
    @MainActor
    final class MCPApprovalPresentationTests: XCTestCase {
        /// Every approval transition notifies the root after the child holds the new pair, including a
        /// new identity while the overlay is already visible.
        func testApprovalSnapshotsInvalidateRootWithCurrentState() async throws {
            try await withPresentationFixture { fixture in
                let service = fixture.service
                let server = fixture.server
                let stages: [(label: String, expected: ApprovalPair, stimulus: @MainActor () async -> Void)] = [
                    ("identity A", ApprovalPair("approval-presentation-a", true), {
                        await service.setPendingApprovalForTesting("approval-presentation-a")
                    }),
                    ("identity B while visible", ApprovalPair("approval-presentation-b", true), {
                        await service.setPendingApprovalForTesting("approval-presentation-b")
                    }),
                    ("overlay hidden", ApprovalPair("approval-presentation-b", false), {
                        server.isApprovalOverlayVisible = false
                    }),
                    ("identity cleared", ApprovalPair(nil, false), {
                        await service.setPendingApprovalForTesting(nil)
                    })
                ]
                for stage in stages {
                    fixture.recorder.reset()
                    await stage.stimulus()
                    await settle(stage.label) { ApprovalPair(server) == stage.expected }
                    XCTAssertGreaterThanOrEqual(
                        fixture.recorder.approvalEvents, 1,
                        "\(stage.label): the root was not notified of the approval change."
                    )
                    XCTAssertEqual(
                        fixture.recorder.pairAtLastRootEvent, stage.expected,
                        "\(stage.label): the last root notification did not see the completed pair."
                    )
                }
            }
        }

        /// The initial pair and snapshots that leave the pair unchanged do not notify the root, whether
        /// or not a request is visible.
        func testSeedAndNonApprovalSnapshotsDoNotInvalidateRoot() async throws {
            try await withPresentationFixture { fixture in
                let service = fixture.service
                let server = fixture.server
                let recorder = fixture.recorder

                let drained = await Self.drainMainRunLoop()
                XCTAssertTrue(drained, "The main run loop did not reach the sentinel.")
                XCTAssertEqual(recorder.approvalEvents, 0, "Construction announced the initial approval pair.")

                recorder.reset()
                for marker in ["approval-presentation-idle-1", "approval-presentation-idle-2"] {
                    await service.updateDiagnostics(MCPDiagnostics(listenerStateDescription: marker))
                    await settle(marker) { server.diagnostics.listenerStateDescription == marker }
                }
                XCTAssertEqual(recorder.approvalEvents, 0, "Idle diagnostics snapshots notified the root.")

                let visible = ApprovalPair("approval-presentation-visible", true)
                await service.setPendingApprovalForTesting(visible.clientID)
                await settle("visible request") { ApprovalPair(server) == visible }
                recorder.reset()
                let marker = "approval-presentation-visible-diagnostics"
                await service.updateDiagnostics(MCPDiagnostics(listenerStateDescription: marker))
                await settle(marker) { server.diagnostics.listenerStateDescription == marker }
                XCTAssertEqual(ApprovalPair(server), visible)
                XCTAssertEqual(recorder.approvalEvents, 0, "A diagnostics snapshot during a visible request notified the root.")
            }
        }

        // MARK: - Fixture

        private struct Fixture {
            let service: MCPService
            let server: MCPServerViewModel
            let recorder: RootNotificationRecorder
        }

        /// Builds one window and its root model, attaching the recorder before the first suspension so it
        /// sees every queued delivery. On every exit it cancels the recorder, tears down and unregisters
        /// the window, then lets the shared fixture restore the service state and the lease.
        private func withPresentationFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                try await MCPWindowTestSupport.withSharedServiceState(lease: lease) { service in
                    try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                    let window = MCPWindowTestSupport.makeWindowWithoutAutoStart()
                    WindowStatesManager.shared.registerWindowState(window)
                    let root = ContentViewModel(state: window)
                    let recorder = RootNotificationRecorder(root: root, server: window.mcpServer)

                    let result: Result<Void, Error>
                    do {
                        try await body(Fixture(service: service, server: window.mcpServer, recorder: recorder))
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    recorder.cancel()
                    await MCPWindowTestSupport.tearDown(window)
                    // The root model owns the subscription under test, so it must outlive the body.
                    withExtendedLifetime(root) {}
                    try result.get()
                }
            }
        }

        /// Waits for a stimulus's published state, then for the main run loop to deliver the root
        /// notifications that the completed setters queued.
        private func settle(
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ condition: @MainActor () -> Bool
        ) async {
            let reached = await MCPWindowTestSupport.waitUntil { condition() }
            XCTAssertTrue(reached, "\(label): the window did not publish the expected state.", file: file, line: line)
            let drained = await Self.drainMainRunLoop()
            XCTAssertTrue(drained, "\(label): the main run loop did not reach the sentinel.", file: file, line: line)
        }

        /// Returns once a block scheduled now on the main run loop has run. Run-loop blocks run in order,
        /// so every `receive(on: RunLoop.main)` delivery queued before this call has run too.
        private static func drainMainRunLoop() async -> Bool {
            let sentinel = RunLoopSentinel()
            RunLoop.main.perform { MainActor.assumeIsolated { sentinel.reached = true } }
            return await MCPWindowTestSupport.waitUntil { sentinel.reached }
        }
    }

    private struct ApprovalPair: Equatable {
        var clientID: String?
        var isVisible: Bool

        init(_ clientID: String?, _ isVisible: Bool) {
            self.clientID = clientID
            self.isVisible = isVisible
        }

        @MainActor
        init(_ server: MCPServerViewModel) {
            self.init(server.pendingClientID, server.isApprovalOverlayVisible)
        }
    }

    @MainActor
    private final class RunLoopSentinel {
        var reached = false
    }

    /// Counts root notifications and the root's own routing publications, and records the child's
    /// approval pair at each root notification, which is the state a redraw would read.
    @MainActor
    private final class RootNotificationRecorder {
        private(set) var rootEvents = 0
        private(set) var routeEvents = 0
        private(set) var pairAtLastRootEvent: ApprovalPair?
        private var cancellables = Set<AnyCancellable>()

        /// Root notifications not explained by the root's routing properties.
        var approvalEvents: Int {
            rootEvents - routeEvents
        }

        init(root: ContentViewModel, server: MCPServerViewModel) {
            root.objectWillChange
                .sink { [weak self] _ in
                    self?.rootEvents += 1
                    self?.pairAtLastRootEvent = ApprovalPair(server)
                }
                .store(in: &cancellables)
            root.$rootRoute.dropFirst()
                .sink { [weak self] _ in self?.routeEvents += 1 }
                .store(in: &cancellables)
            root.$workspaceEntryTab.dropFirst()
                .sink { [weak self] _ in self?.routeEvents += 1 }
                .store(in: &cancellables)
            root.$onboardingViewModel.dropFirst()
                .sink { [weak self] _ in self?.routeEvents += 1 }
                .store(in: &cancellables)
        }

        func reset() {
            rootEvents = 0
            routeEvents = 0
            pairAtLastRootEvent = nil
        }

        func cancel() {
            cancellables.removeAll()
        }
    }
#endif
