import Foundation

#if DEBUG
    import os

    /// Debug-only, opt-in instrumentation for workspace/window restore and Agent activation hot paths.
    ///
    /// Enable in debug builds with either:
    /// - `defaults write com.repoprompt.RepoPrompt enableWorkspaceRestorePerfLogging -bool YES`
    /// - `RP_WORKSPACE_RESTORE_PERF_LOGGING=1`
    ///
    /// This file is compiled behind `#if DEBUG`; release builds do not include the logger,
    /// and call sites are also wrapped in `#if DEBUG` to avoid production overhead.
    enum WorkspaceRestorePerfLog {
        private static let logger = Logger(subsystem: "com.repoprompt.restore", category: "workspace-restore")
        private static let defaultsKey = "enableWorkspaceRestorePerfLogging"
        private static let environmentKey = "RP_WORKSPACE_RESTORE_PERF_LOGGING"
        private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
        private static let bufferLimit = 2000
        private static let bufferLock = NSLock()
        private static var processOverrideEnabled: Bool?
        private static var recentMetricLines: [String] = []
        private static var timedEventTotals: [String: TimedEventTotal] = [:]

        private struct TimedEventTotal {
            var count = 0
            var totalMS = 0.0
            var maxMS = 0.0
            var totalBytes = 0
        }

        static var isEnabled: Bool {
            if let override = debugProcessOverrideEnabled {
                return override
            }
            return defaultsEnabled || environmentEnabled
        }

        static var defaultsEnabled: Bool {
            UserDefaults.standard.bool(forKey: defaultsKey)
        }

        static var environmentEnabled: Bool {
            let rawValue = ProcessInfo.processInfo.environment[environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return rawValue.map { enabledEnvironmentValues.contains($0) } ?? false
        }

        static var debugProcessOverrideEnabled: Bool? {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return processOverrideEnabled
        }

        static func timestampMSIfEnabled() -> Double? {
            guard isEnabled else { return nil }
            return timestampMS()
        }

        static func timestampMS() -> Double {
            CFAbsoluteTimeGetCurrent() * 1000
        }

        static func elapsedMS(since startMS: Double) -> Double {
            timestampMS() - startMS
        }

        static func formatMS(_ value: Double) -> String {
            String(format: "%.1fms", value)
        }

        static func formatElapsedMS(since startMS: Double) -> String {
            formatMS(elapsedMS(since: startMS))
        }

        static func shortID(_ id: UUID?) -> String {
            id?.uuidString.prefix(8).description ?? "nil"
        }

        @MainActor
        private static var agentActivationTrueCount = 0

        @MainActor
        static func nextAgentActivationTrueCount() -> Int {
            agentActivationTrueCount += 1
            return agentActivationTrueCount
        }

        static func log(_ message: @autoclosure () -> String) {
            guard isEnabled else { return }
            let renderedMessage = message()
            appendRecentMetricLine(renderedMessage)
            logger.debug("\(renderedMessage, privacy: .public)")
        }

        static func event(_ name: String, fields: [String: String] = [:]) {
            log(renderEvent(name, fields: fields))
        }

        /// Logs `name` with `duration` and `bytes` fields and adds them to the per-name totals in
        /// `debugStateSnapshot`. The totals keep an exact count after the line buffer drops lines.
        static func timedEvent(
            _ name: String,
            durationMS: Double,
            bytes: Int,
            fields: [String: String] = [:]
        ) {
            guard isEnabled else { return }
            bufferLock.lock()
            var total = timedEventTotals[name, default: TimedEventTotal()]
            total.count += 1
            total.totalMS += durationMS
            total.maxMS = max(total.maxMS, durationMS)
            total.totalBytes += bytes
            timedEventTotals[name] = total
            bufferLock.unlock()
            var payload = fields
            payload["duration"] = formatMS(durationMS)
            payload["bytes"] = "\(bytes)"
            event(name, fields: payload)
        }

        static func setDebugProcessOverrideEnabled(_ enabled: Bool?) {
            bufferLock.lock()
            processOverrideEnabled = enabled
            bufferLock.unlock()
        }

        static func clearRecentMetrics() {
            bufferLock.lock()
            recentMetricLines.removeAll(keepingCapacity: true)
            timedEventTotals.removeAll()
            bufferLock.unlock()
        }

        static func recentMetricLinesSnapshot(limit requestedLimit: Int) -> [String] {
            let limit = max(1, min(requestedLimit, bufferLimit))
            bufferLock.lock()
            let lines = Array(recentMetricLines.suffix(limit))
            bufferLock.unlock()
            return lines
        }

        static func debugStateSnapshot(lineLimit: Int) -> [String: Any] {
            let lines = recentMetricLinesSnapshot(limit: lineLimit)
            bufferLock.lock()
            let totals = timedEventTotals
            bufferLock.unlock()
            return [
                "enabled": isEnabled,
                "defaults_enabled": defaultsEnabled,
                "environment_enabled": environmentEnabled,
                "process_override_enabled": debugProcessOverrideEnabled ?? NSNull(),
                "line_count": lines.count,
                "buffer_limit": bufferLimit,
                "lines": lines,
                "timed_event_totals": totals.mapValues { total in
                    [
                        "count": total.count,
                        "total_ms": (total.totalMS * 10).rounded() / 10,
                        "max_ms": (total.maxMS * 10).rounded() / 10,
                        "total_bytes": total.totalBytes
                    ] as [String: Any]
                }
            ]
        }

        private static func appendRecentMetricLine(_ message: String) {
            let line = "t+\(formatMS(timestampMS())) \(message)"
            bufferLock.lock()
            recentMetricLines.append(line)
            if recentMetricLines.count > bufferLimit {
                recentMetricLines.removeFirst(recentMetricLines.count - bufferLimit)
            }
            bufferLock.unlock()
        }

        private static func renderEvent(_ name: String, fields: [String: String]) -> String {
            guard !fields.isEmpty else { return name }
            let suffix = fields.keys.sorted().map { key in
                "\(key)=\(sanitize(fields[key] ?? ""))"
            }.joined(separator: " ")
            return "\(name) \(suffix)"
        }

        private static func sanitize(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: " ", with: "_")
        }
    }
#endif
