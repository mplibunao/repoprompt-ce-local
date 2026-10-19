// MARK: - DEBUG Workspace Content Load Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        /// Reports which workspace documents one window's content gateway loaded and decoded, per
        /// workspace and per caller source. `reset: true` clears the counts after reading them.
        func debugWorkspaceContentLoadSnapshotPayload(
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
            let reset = debugBool(arguments, "reset") ?? false

            let snapshot: WorkspaceContentLoadSnapshot? = await MainActor.run {
                guard let window = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                let gateway = window.workspaceManager.contentGateway
                let snapshot = gateway.debugLoadSnapshot()
                if reset { gateway.resetDebugLoadSnapshot() }
                return snapshot
            }
            guard let snapshot else {
                return debugDiagnosticsError(
                    op: op,
                    code: "no_window",
                    message: "No RepoPrompt window matched window_id \(windowID)."
                )
            }
            return debugDiagnosticsResult(Self.debugWorkspaceContentLoadPayload(
                snapshot,
                op: op,
                windowID: windowID,
                reset: reset
            ))
        }

        nonisolated static func debugWorkspaceContentLoadPayload(
            _ snapshot: WorkspaceContentLoadSnapshot,
            op: String,
            windowID: Int,
            reset: Bool
        ) -> [String: Any] {
            let workspaces = snapshot.countsByWorkspaceID
                .sorted { $0.key.uuidString < $1.key.uuidString }
                .map { workspaceID, countsBySource -> [String: Any] in
                    let total = snapshot.counts(for: workspaceID)
                    return [
                        "workspace_id": workspaceID.uuidString,
                        "loads": total.loads,
                        "decodes": total.decodes,
                        "sources": countsBySource
                            .sorted { $0.key < $1.key }
                            .map { source, counts -> [String: Any] in
                                ["source": source, "loads": counts.loads, "decodes": counts.decodes]
                            }
                    ]
                }
            let totals = snapshot.countsByWorkspaceID.keys.map(snapshot.counts(for:))
            return [
                "ok": true,
                "op": op,
                "window_id": windowID,
                "reset": reset,
                "workspaces": workspaces,
                "total_loads": totals.reduce(0) { $0 + $1.loads },
                "total_decodes": totals.reduce(0) { $0 + $1.decodes }
            ]
        }
    }
#endif
