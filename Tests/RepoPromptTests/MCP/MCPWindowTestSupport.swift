import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Window and service fixtures for suites that exercise the process-wide
    /// `WindowState.sharedMCPService`.
    ///
    /// Callers hold `MCPSharedServerTestLease` for the whole test. The lease is not re-entrant, so
    /// these helpers never acquire it. Constructing another `MCPService` would rewire the
    /// process-wide controller and dashboard hooks for every later test.
    @MainActor
    enum MCPWindowTestSupport {
        enum FixtureError: Error, CustomStringConvertible {
            case pendingApprovalAtSetup(String)
            case missingSeedSnapshot

            var description: String {
                switch self {
                case let .pendingApprovalAtSetup(clientID):
                    "The shared MCP service already has a pending approval for \(clientID)."
                case .missingSeedSnapshot:
                    "A new state subscription did not receive the current snapshot within the timeout."
                }
            }
        }

        static func makeWindowWithoutAutoStart() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
            return WindowState()
        }

        static func tearDown(_ window: WindowState) async {
            window.mcpServer.setBeforeWindowToolRegistrationForTesting(nil)
            window.mcpServer.setAfterWindowToolRegistrationBeforeRetentionForTesting(nil)
            window.mcpServer.setBootstrapReadinessCheckpointForTesting(nil)
            // The disable reclaims this window's exact registration handle before teardown.
            _ = await window.mcpServer.setWindowToolsEnabled(false)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }

        /// Polls a condition that another task makes true; the timeout bounds a broken fixture.
        static func waitUntil(
            timeout: Duration = .seconds(5),
            _ condition: @MainActor () async -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() { return true }
                try? await clock.sleep(for: .milliseconds(5))
            }
            return await condition()
        }

        /// Runs `body` against the shared service and restores the service state a test may change.
        ///
        /// The lease restores transport state only. This fixture refuses to start while an approval is
        /// already pending, and on every exit restores the captured diagnostics and clears any pending
        /// identity the test set.
        static func withSharedServiceState<T>(
            lease _: MCPSharedServerTestLease.Ownership,
            _ body: (MCPService) async throws -> T
        ) async throws -> T {
            let service = WindowState.sharedMCPService
            let baseline = try await currentSnapshot(of: service)
            if let pendingClientID = baseline.pendingClientID {
                throw FixtureError.pendingApprovalAtSetup(pendingClientID)
            }
            let result: Result<T, Error>
            do { result = try await .success(body(service)) } catch { result = .failure(error) }
            await service.setPendingApprovalForTesting(nil)
            await service.updateDiagnostics(baseline.diagnostics)
            return try result.get()
        }

        /// Reads the current snapshot through the replay every new subscriber receives.
        static func currentSnapshot(of service: MCPService) async throws -> MCPService.Snapshot {
            let (subscriptionID, stream) = await service.subscribeToStateUpdates()
            let snapshots = await readSnapshots(from: stream, limit: 1)
            await service.unsubscribeFromStateUpdates(id: subscriptionID)
            guard let snapshot = snapshots?.first else { throw FixtureError.missingSeedSnapshot }
            return snapshot
        }

        /// Reads `stream` until it finishes or delivers `limit` snapshots, or returns nil at the timeout.
        ///
        /// Cancelling the reader ends its iteration, and both tasks are joined before returning, so a
        /// stream that never delivers or never finishes fails the caller instead of holding the lease.
        /// The caller still owns its subscription and unsubscribes it.
        static func readSnapshots(
            from stream: AsyncStream<MCPService.Snapshot>,
            limit: Int = .max,
            timeout: Duration = .seconds(5)
        ) async -> [MCPService.Snapshot]? {
            let reader = Task { () -> [MCPService.Snapshot]? in
                var snapshots: [MCPService.Snapshot] = []
                for await snapshot in stream {
                    snapshots.append(snapshot)
                    if snapshots.count == limit { return snapshots }
                }
                return Task.isCancelled ? nil : snapshots
            }
            let deadline = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                reader.cancel()
            }
            let snapshots = await reader.value
            deadline.cancel()
            await deadline.value
            return snapshots
        }

        /// Makes `context`'s fixture workspace current in its window and loads its compose tabs.
        static func activateWorkspace(_ context: PersistentMCPTestContext, reason: String) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await activateWorkspace(workspace, in: context.window, reason: reason)
        }

        /// Makes `workspace` current in `window` and loads its compose tabs.
        static func activateWorkspace(_ workspace: WorkspaceModel, in window: WindowState, reason: String) async {
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: reason
            )
            window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        }

        /// The tool result's text blocks, joined by newlines.
        nonisolated static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let object = try responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any], response.rawJSON)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]], response.rawJSON)
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        /// Decodes a JSON-RPC response and asserts that it answers its own request without a JSON-RPC error.
        nonisolated static func responseObject(from response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, response.id)
            XCTAssertNil(object["error"])
            return object
        }
    }
#endif
