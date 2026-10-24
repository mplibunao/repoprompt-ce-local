// MARK: - DEBUG Stuck MCP Call Injector

import Foundation
import MCP

#if DEBUG
    /// Holds MCP tool calls for the `mcp_stuck_call_scenario` diagnostics op, so a capped window and its
    /// automatic recovery can be driven on the debug app. A scenario targets one window and one hook and
    /// holds at most its capture limit of calls there, two unless it is armed with one. A held call doesn't observe cancellation, so it outlives
    /// its deadline and grace the way a stuck call does. Held calls continue when the scenario is released
    /// or cleared, when its window closes, or after its auto-release delay.
    final class MCPStuckToolScenarioRegistry: @unchecked Sendable {
        enum Hook: String, CaseIterable {
            /// `read_file`, after its reply is built and its selection intent is enqueued.
            case readFile = "read_file"
            /// A read's automatic selection, before the window's selection worker applies it.
            case readFileAutoSelection = "read_file_auto_selection"
            /// `prompt` set, append, and clear, after the tab resolves and before the change commits.
            case prompt
        }

        struct Status {
            let scenarioID: UUID
            let windowID: Int
            let hook: Hook
            let captureLimit: Int
            let capturedCount: Int
            let heldCount: Int
            let isReleased: Bool
            let armedAge: Duration
            let autoReleaseAfter: Duration
        }

        enum ArmError: Error, Equatable {
            /// A scenario for this window and hook can still capture calls.
            case alreadyArmed(scenarioID: UUID)
        }

        static let shared = MCPStuckToolScenarioRegistry()
        static let maximumCaptureLimit = 2
        static let defaultAutoReleaseAfter = Duration.seconds(300)
        static let maximumAutoReleaseAfter = Duration.seconds(600)

        private struct Scenario {
            let windowID: Int
            let hook: Hook
            let armedAt: ContinuousClock.Instant
            let autoReleaseAfter: Duration
            let captureLimit: Int
            var capturedCount = 0
            var held: [CheckedContinuation<Void, Never>] = []
            var isReleased = false
            var autoRelease: Task<Void, Never>?

            var isCapturing: Bool {
                !isReleased && capturedCount < captureLimit
            }
        }

        private let lock = NSLock()
        private let clock = ContinuousClock()
        private var scenarios: [UUID: Scenario] = [:]

        func arm(
            windowID: Int,
            hook: Hook,
            autoReleaseAfter: Duration,
            captureLimit: Int = maximumCaptureLimit
        ) throws -> UUID {
            let scenarioID = UUID()
            try lock.withLock {
                if let existing = capturingScenarioID(windowID: windowID, hook: hook) {
                    throw ArmError.alreadyArmed(scenarioID: existing)
                }
                scenarios[scenarioID] = Scenario(
                    windowID: windowID,
                    hook: hook,
                    armedAt: clock.now,
                    autoReleaseAfter: autoReleaseAfter,
                    captureLimit: captureLimit
                )
            }
            let autoRelease = Task { [weak self] in
                try? await Task.sleep(for: autoReleaseAfter)
                guard !Task.isCancelled else { return }
                self?.release(scenarioID: scenarioID)
            }
            let stillArmed = lock.withLock {
                guard scenarios[scenarioID]?.isReleased == false else { return false }
                scenarios[scenarioID]?.autoRelease = autoRelease
                return true
            }
            if !stillArmed {
                autoRelease.cancel()
            }
            return scenarioID
        }

        /// Runs on the caller's actor, so a hook site with nothing armed returns without suspending.
        func holdIfArmed(
            windowID: Int,
            hook: Hook,
            isolation: isolated (any Actor)? = #isolation
        ) async {
            guard lock.withLock({ capturingScenarioID(windowID: windowID, hook: hook) }) != nil else { return }
            await withCheckedContinuation(isolation: isolation) { (continuation: CheckedContinuation<Void, Never>) in
                let captured = lock.withLock {
                    guard let scenarioID = capturingScenarioID(windowID: windowID, hook: hook) else { return false }
                    scenarios[scenarioID]?.capturedCount += 1
                    scenarios[scenarioID]?.held.append(continuation)
                    return true
                }
                if !captured {
                    continuation.resume()
                }
            }
        }

        func status() -> [Status] {
            let now = clock.now
            return lock.withLock {
                scenarios.map { scenarioID, scenario in
                    Status(
                        scenarioID: scenarioID,
                        windowID: scenario.windowID,
                        hook: scenario.hook,
                        captureLimit: scenario.captureLimit,
                        capturedCount: scenario.capturedCount,
                        heldCount: scenario.held.count,
                        isReleased: scenario.isReleased,
                        armedAge: scenario.armedAt.duration(to: now),
                        autoReleaseAfter: scenario.autoReleaseAfter
                    )
                }
                .sorted { $0.armedAge > $1.armedAge }
            }
        }

        /// Lets the scenario's held calls continue and stops it capturing. Returns false for an unknown ID.
        @discardableResult
        func release(scenarioID: UUID) -> Bool {
            finish(scenarioID: scenarioID, removing: false)
        }

        /// Releases the scenario and forgets it.
        @discardableResult
        func clear(scenarioID: UUID) -> Bool {
            finish(scenarioID: scenarioID, removing: true)
        }

        func releaseWindow(_ windowID: Int) {
            let scenarioIDs = lock.withLock {
                scenarios.filter { $0.value.windowID == windowID }.map(\.key)
            }
            for scenarioID in scenarioIDs {
                clear(scenarioID: scenarioID)
            }
        }

        private func finish(scenarioID: UUID, removing: Bool) -> Bool {
            let finished: (held: [CheckedContinuation<Void, Never>], autoRelease: Task<Void, Never>?)? = lock.withLock {
                guard var scenario = scenarios[scenarioID] else { return nil }
                let held = scenario.held
                let autoRelease = scenario.autoRelease
                scenario.held = []
                scenario.isReleased = true
                scenario.autoRelease = nil
                scenarios[scenarioID] = removing ? nil : scenario
                return (held, autoRelease)
            }
            guard let finished else { return false }
            finished.autoRelease?.cancel()
            finished.held.forEach { $0.resume() }
            return true
        }

        /// Callers hold the lock.
        private func capturingScenarioID(windowID: Int, hook: Hook) -> UUID? {
            scenarios.first { $0.value.windowID == windowID && $0.value.hook == hook && $0.value.isCapturing }?.key
        }
    }

    extension ServerNetworkManager {
        func debugMCPStuckCallScenarioPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let registry = MCPStuckToolScenarioRegistry.shared
            switch debugString(arguments, "action") {
            case "arm"?:
                let windowID: Int
                switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 1 ... Int.max) {
                case let .value(parsed):
                    windowID = parsed
                case .defaulted, .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be a positive integer.")
                }
                guard let hook = debugString(arguments, "hook").flatMap(MCPStuckToolScenarioRegistry.Hook.init(rawValue:)) else {
                    let hooks = MCPStuckToolScenarioRegistry.Hook.allCases.map(\.rawValue).joined(separator: ", ")
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`hook` must be one of: \(hooks).")
                }
                let maximumSeconds = Int(MCPStuckToolScenarioRegistry.maximumAutoReleaseAfter.components.seconds)
                let autoReleaseSeconds: Int
                switch debugBoundedInt(
                    arguments,
                    "auto_release_seconds",
                    defaultValue: Int(MCPStuckToolScenarioRegistry.defaultAutoReleaseAfter.components.seconds),
                    range: 1 ... maximumSeconds
                ) {
                case let .value(parsed), let .defaulted(parsed):
                    autoReleaseSeconds = parsed
                case .invalid:
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "`auto_release_seconds` must be an integer from 1 to \(maximumSeconds)."
                    )
                }
                let captureLimit: Int
                switch debugBoundedInt(
                    arguments,
                    "capture_limit",
                    defaultValue: MCPStuckToolScenarioRegistry.maximumCaptureLimit,
                    range: 1 ... MCPStuckToolScenarioRegistry.maximumCaptureLimit
                ) {
                case let .value(parsed), let .defaulted(parsed):
                    captureLimit = parsed
                case .invalid:
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "`capture_limit` must be an integer from 1 to \(MCPStuckToolScenarioRegistry.maximumCaptureLimit)."
                    )
                }
                let windowExists = await MainActor.run { WindowStatesManager.shared.hasWindow(id: windowID) }
                guard windowExists else {
                    return debugDiagnosticsError(op: op, code: "no_window", message: "No RepoPrompt window matched window_id \(windowID).")
                }
                do {
                    let scenarioID = try registry.arm(
                        windowID: windowID,
                        hook: hook,
                        autoReleaseAfter: .seconds(autoReleaseSeconds),
                        captureLimit: captureLimit
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": "arm",
                        "scenario_id": scenarioID.uuidString,
                        "window_id": windowID,
                        "hook": hook.rawValue,
                        "capture_limit": captureLimit,
                        "auto_release_seconds": autoReleaseSeconds
                    ])
                } catch let MCPStuckToolScenarioRegistry.ArmError.alreadyArmed(existing) {
                    return debugDiagnosticsError(
                        op: op,
                        code: "already_armed",
                        message: "Scenario \(existing.uuidString) can still capture \(hook.rawValue) calls in window \(windowID). Release or clear it first."
                    )
                } catch {
                    return debugDiagnosticsError(op: op, code: "arm_failed", message: error.localizedDescription)
                }
            case "status"?:
                let scenarios: [[String: Any]] = registry.status().map { status in
                    [
                        "scenario_id": status.scenarioID.uuidString,
                        "window_id": status.windowID,
                        "hook": status.hook.rawValue,
                        "capture_limit": status.captureLimit,
                        "captured_count": status.capturedCount,
                        "held_count": status.heldCount,
                        "released": status.isReleased,
                        "armed_age_ms": status.armedAge.mcpMilliseconds,
                        "auto_release_seconds": Int(status.autoReleaseAfter.components.seconds)
                    ]
                }
                return debugDiagnosticsResult(["ok": true, "op": op, "action": "status", "scenarios": scenarios])
            case let action? where action == "release" || action == "clear":
                guard let scenarioID = debugString(arguments, "scenario_id").flatMap(UUID.init(uuidString:)) else {
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`scenario_id` must be a scenario UUID.")
                }
                let found = action == "release"
                    ? registry.release(scenarioID: scenarioID)
                    : registry.clear(scenarioID: scenarioID)
                guard found else {
                    return debugDiagnosticsError(op: op, code: "unknown_scenario", message: "No scenario matched scenario_id \(scenarioID.uuidString).")
                }
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "action": action,
                    "scenario_id": scenarioID.uuidString
                ])
            default:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`action` must be arm, status, release, or clear."
                )
            }
        }
    }
#endif
