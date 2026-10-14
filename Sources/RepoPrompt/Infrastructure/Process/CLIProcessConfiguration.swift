import Foundation

struct CLIProcessConfiguration {
    static func resolvedWorkingDirectory(_ workingDirectory: String?) -> String {
        workingDirectory ?? FileManager.default.temporaryDirectory.path
    }

    var command: String
    /// Working directory for the CLI process. Defaults to temp directory to avoid macOS security popups.
    var workingDirectory: String
    var environment: [String: String]
    var additionalPaths: [String]
    var commandSuffix: [String]
    var enableDebugLogging: Bool
    var logCollector: CLIProcessLogCollector?
    /// Optional: explicit basenames we prefer to resolve to (e.g., ["claude", "codex"]).
    /// If omitted, the resolver will prefer `command` and otherwise behave as before.
    var resolveCandidates: [String]?
    /// Controls whether command resolution queries the user's shell before or after PATH search.
    var shellLookupMode: CommandPathResolver.ShellLookupMode
    /// Limit how many bytes from child stdout/stderr we retain (per stream).
    var captureStdoutTailBytes: Int
    var captureStderrTailBytes: Int
    /// Limit how many bytes of stdin we sample for logs (0 disables sampling).
    var logStdinSampleBytes: Int
    /// After the root child exits, how long the runner waits between checks of an output pipe
    /// that has not reached EOF.
    var outputDrainCheckInterval: TimeInterval = 5
    var testHooks: CLIProcessRunnerTestHooks?

    init(
        command: String = "claude",
        workingDirectory: String? = nil, // nil → temp directory to avoid macOS security popups
        environment: [String: String] = [:],
        additionalPaths: [String] = CLINativePathDefaults.defaultAdditionalPaths,
        commandSuffix: [String] = [],
        enableDebugLogging: Bool = false,
        logCollector: CLIProcessLogCollector? = nil,
        resolveCandidates: [String]? = nil,
        shellLookupMode: CommandPathResolver.ShellLookupMode = .preferShell,
        captureStdoutTailBytes: Int = 0,
        captureStderrTailBytes: Int = 256 * 1024,
        logStdinSampleBytes: Int = 0
    ) {
        self.command = command
        self.workingDirectory = Self.resolvedWorkingDirectory(workingDirectory)
        self.environment = environment
        self.additionalPaths = additionalPaths
        self.commandSuffix = commandSuffix
        self.enableDebugLogging = enableDebugLogging
        self.logCollector = logCollector
        self.resolveCandidates = resolveCandidates
        self.shellLookupMode = shellLookupMode
        self.captureStdoutTailBytes = captureStdoutTailBytes
        self.captureStderrTailBytes = captureStderrTailBytes
        self.logStdinSampleBytes = logStdinSampleBytes
    }
}

/// Ordering and observation points inside `CLIProcessRunner` for tests. Production configurations
/// leave `testHooks` nil.
struct CLIProcessRunnerTestHooks {
    enum OutputChannel: Equatable {
        case stdout
        case stderr
    }

    enum RetirementReason: Equatable {
        case idle
        case cancelled
        case deadline
    }

    enum DrainEvent: Equatable {
        case started
        case checked(channel: OutputChannel, bufferedBytes: Int?, retired: Bool, reason: RetirementReason?)
        case finished
    }

    /// Runs on an output reader's own thread before its first read. Nothing else runs on that
    /// thread, so a test may block here to hold the reader back. A test that blocks a reader must
    /// also release it from a teardown block: a reader that never finishes keeps the run, and the
    /// runner's permit, held for the rest of the test process.
    var beforeOutputReaderStarts: (@Sendable (OutputChannel) -> Void)?
    var onDrainEvent: (@Sendable (DrainEvent) -> Void)?
    /// Runs right after the runner closes its stdout and stderr handles once the root child has
    /// exited normally, before it waits for the readers.
    var afterOutputHandlesClosed: (@Sendable () -> Void)?
}
