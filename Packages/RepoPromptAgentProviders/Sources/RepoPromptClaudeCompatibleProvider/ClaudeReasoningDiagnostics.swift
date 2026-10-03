import Foundation

enum ClaudeReasoningExtractionFeature {
    static let isEnabled = false
}

#if DEBUG
    /// A package-owned, per-process diagnostic namespace. It never shares the app profile's
    /// temporary root, so a debug build's log can neither land in nor fall back to production state.
    enum ClaudeReasoningDebugLog {
        static let fileURL = logFileURL(
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        private static let lock = NSLock()

        static func logFileURL(temporaryDirectory: URL, processID: Int32) -> URL {
            temporaryDirectory
                .appendingPathComponent("RepoPromptClaudeCompatibleProvider-Debug", isDirectory: true)
                .appendingPathComponent(String(processID), isDirectory: true)
                .appendingPathComponent("claude-reasoning-debug.log", isDirectory: false)
        }

        static func emit(_ line: String) {
            print(line)
            append(line)
        }

        static func append(_ line: String) {
            append(line, to: fileURL)
        }

        /// Best effort: a failed write is dropped rather than redirected anywhere else.
        static func append(_ line: String, to fileURL: URL) {
            lock.lock()
            defer { lock.unlock() }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let payload = "\(timestamp) \(line)\n"
            guard let data = payload.data(using: .utf8) else { return }
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
#endif
