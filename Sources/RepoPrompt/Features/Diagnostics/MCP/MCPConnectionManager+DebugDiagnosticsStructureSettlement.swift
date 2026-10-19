// MARK: - DEBUG MCP Structure Settlement Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugMCPStructureSettlementSnapshotPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 1 ... Int.max) {
            case let .value(parsed):
                windowID = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`window_id` must be a positive integer."
                )
            }

            // The registry keeps a closed window's entries while their providers still run, and
            // the main actor is slowest exactly when a stall is being sampled, so the window
            // lookup runs only to tell an empty registry from a mistyped window ID. The registry
            // is read again after the lookup so an entry admitted during it is still reported.
            let snapshot = debugCodeStructureSettlementSnapshot(windowID: windowID)
            if snapshot.activeCount > 0 {
                return debugStructureSettlementSnapshotResult(op: op, windowID: windowID, snapshot: snapshot)
            }

            let windowExists = await MainActor.run {
                WindowStatesManager.shared.hasWindow(id: windowID)
            }
            let latestSnapshot = debugCodeStructureSettlementSnapshot(windowID: windowID)
            guard windowExists || latestSnapshot.activeCount > 0 else {
                return debugDiagnosticsError(
                    op: op,
                    code: "no_window",
                    message: "No RepoPrompt window matched window_id \(windowID)."
                )
            }

            return debugStructureSettlementSnapshotResult(op: op, windowID: windowID, snapshot: latestSnapshot)
        }

        private nonisolated func debugStructureSettlementSnapshotResult(
            op: String,
            windowID: Int,
            snapshot: MCPCodeStructureSettlementRegistry.Snapshot
        ) -> CallTool.Result {
            debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "window_id": windowID,
                "active_count": snapshot.activeCount,
                "detached_count": snapshot.detachedCount,
                "released_count": snapshot.releasedCount
            ])
        }
    }
#endif
