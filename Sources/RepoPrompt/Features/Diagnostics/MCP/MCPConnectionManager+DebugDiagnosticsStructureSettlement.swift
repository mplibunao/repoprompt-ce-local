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
            let diagnostics = debugCodeStructureSettlementDiagnostics(windowID: windowID)
            if diagnostics.counts.activeCount > 0 {
                return debugStructureSettlementSnapshotResult(op: op, windowID: windowID, diagnostics: diagnostics)
            }

            let windowExists = await MainActor.run {
                WindowStatesManager.shared.hasWindow(id: windowID)
            }
            let latestDiagnostics = debugCodeStructureSettlementDiagnostics(windowID: windowID)
            guard windowExists || latestDiagnostics.counts.activeCount > 0 else {
                return debugDiagnosticsError(
                    op: op,
                    code: "no_window",
                    message: "No RepoPrompt window matched window_id \(windowID)."
                )
            }

            return debugStructureSettlementSnapshotResult(op: op, windowID: windowID, diagnostics: latestDiagnostics)
        }

        private nonisolated func debugStructureSettlementSnapshotResult(
            op: String,
            windowID: Int,
            diagnostics: MCPCodeStructureSettlementRegistry.Diagnostics
        ) -> CallTool.Result {
            let leases: [[String: Any]] = diagnostics.leases.map { lease in
                var entry: [String: Any] = [
                    "lease_id": lease.leaseID.uuidString,
                    "invocation_id": lease.invocationID.uuidString,
                    "connection_id": lease.connectionID.uuidString,
                    "tool": lease.toolName,
                    "state": lease.state,
                    "admission_age_ms": lease.admissionAge.mcpMilliseconds,
                    "released": lease.isReleased,
                    "provider_completed": lease.providerCompleted
                ]
                if let blockingAge = lease.blockingAge {
                    entry["blocking_age_ms"] = blockingAge.mcpMilliseconds
                }
                if let handlerPhase = lease.handlerPhase {
                    entry["handler_phase"] = handlerPhase.phase.rawValue
                    entry["handler_phase_transition"] = handlerPhase.transition.rawValue
                }
                if let handlerPhaseAge = lease.handlerPhaseAge {
                    entry["handler_phase_age_ms"] = handlerPhaseAge.mcpMilliseconds
                }
                if let mutationState = lease.mutationState {
                    entry["mutation_state"] = mutationState.rawValue
                }
                return entry
            }
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "window_id": windowID,
                "active_count": diagnostics.counts.activeCount,
                "detached_count": diagnostics.counts.detachedCount,
                "released_count": diagnostics.counts.releasedCount,
                "blocking_count": diagnostics.blockingCount,
                "leases": leases
            ])
        }
    }
#endif
