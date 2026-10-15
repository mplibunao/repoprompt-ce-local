import Darwin
import Foundation
import os

/// Separate diagnostic logger for deadlock debugging (independent of config.enableDebugLogging)
enum ProcessDiagnostics {
    static var enableLogging = false

    static func log(_ message: String) {
        guard enableLogging else { return }
        print("[ProcessDiagnostics] \(message)")
    }
}

/// Actor to coordinate gate release and prevent double-release
private actor GateReleaseCoordinator {
    private var released = false

    func markReleased() -> Bool {
        if released { return false }
        released = true
        return true
    }
}

/// Resumes a timed group wait exactly once, from whichever of its events fires first.
private final class GroupWaitResumption: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(finished: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: finished)
    }
}

/// Global cache: remember the absolute path to a command once we've
/// successfully launched it at least once. This avoids repeating
/// interactive-shell lookups (which are relatively expensive).
private actor ResolvedCommandCache {
    static let shared = ResolvedCommandCache()
    private var map: [String: String] = [:] // command -> absolute path
    func get(for command: String) -> String? {
        map[command]
    }

    func put(_ path: String, for command: String) {
        map[command] = path
    }

    func invalidate(_ command: String? = nil) {
        if let command { map.removeValue(forKey: command) } else { map.removeAll() }
    }
}

/// Diagnostics logger for lifecycle gate operations
enum LifecycleGateDiagnostics {
    static var enableLogging = false

    static func log(_ message: String) {
        guard enableLogging else { return }
        print("[LifecycleGate] \(message)")
    }
}

enum CLIProcessRunnerError: Error, LocalizedError {
    case commandNotFound(String)
    case spawnFailed(String)
    case inputEncodingFailed
    case inputWriteFailed(String)
    case waitFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandNotFound(command):
            "Command not found: \(command)"
        case let .spawnFailed(message):
            message
        case .inputEncodingFailed:
            "Failed to encode input for process"
        case let .inputWriteFailed(message):
            message
        case let .waitFailed(message):
            "waitpid failed: \(message)"
        }
    }
}

final class CLIProcessRunner {
    struct Result {
        let stdout: Data
        let stderr: Data
        let status: Int32
        let timedOut: Bool
    }

    enum OutputFlagMode {
        case auto(CLIOutputFormat)
        case none
        case custom([String])
    }

    enum StreamEvent {
        case stdout(Data)
        case stderr(Data)
        case terminated(status: Int32, timedOut: Bool)
    }

    /// How the wait for the root child ended, and when.
    private struct RootExit {
        let status: Int32
        let timedOut: Bool
        let time: DispatchTime
    }

    private enum EntryPoint: String {
        case run
        case runStreaming
    }

    private static let processLogger = Logger(subsystem: "com.repoprompt.process", category: "CLIProcessRunner")
    /// How often the drain rechecks, once the caller's deadline has passed, a pipe whose reader has
    /// not yet read its backlog. It sets only how soon that pipe is retired, never whether bytes are kept.
    private static let backlogCheckInterval: TimeInterval = 0.05

    let config: CLIProcessConfiguration
    private let registry = ProcessRegistry()
    private let gate: TaskSemaphore

    init(config: CLIProcessConfiguration, concurrencyLimit: Int = 1) {
        self.config = config
        gate = TaskSemaphore(max(concurrencyLimit, 1))
    }

    @inline(__always)
    private func cancelEarlyReleasingGate(phase: String) async throws {
        if Task.isCancelled {
            ProcessDiagnostics.log("🛑 [CANCEL] \(phase); releasing gate")
            await gate.release()
            throw CancellationError()
        }
    }

    /// Stops input and, while the root child is unreaped, asks it to exit. Returns whether it sent
    /// SIGTERM. Once the root has been reaped, its PID and process-group ID may belong to another
    /// process, and `signalProcessGroupOrPID` falls back to the PID when the group is gone, so
    /// nothing is signaled.
    @discardableResult
    private func terminateChild(_ p: RunnerProcess) -> Bool {
        // Stop input without releasing the writer's descriptor. The output readers stop at EOF
        // or when the drain retires their pipes.
        p.input.retire()
        return p.reap.signalIfUnreaped {
            ProcessTermination.signalProcessGroupOrPID(
                pid: p.pid,
                processGroupID: p.processGroupID,
                signal: SIGTERM,
                logger: { [weak self] message in self?.log(message) }
            )
        }
    }

    @inline(__always)
    private static func isRunnableExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return access(path, X_OK) == 0
    }

    func run(
        args: [String],
        stdin: String?,
        outputMode: OutputFlagMode = .auto(.json),
        timeout: TimeInterval?,
        additionalEnvironment: [String: String] = [:],
        additionalRemovedKeys: Set<String> = [],
        cancelChildOnTaskCancellation: Bool = false
    ) async throws -> Result {
        try await gate.withPermit { [self] in
            let environment = await resolvedEnvironment(
                additionalEnvironment: additionalEnvironment,
                additionalRemovedKeys: additionalRemovedKeys
            )
            // Prefer a previously successful absolute path for this command.
            let resolvedCommand: String = await {
                if let cached = await ResolvedCommandCache.shared.get(for: config.command),
                   Self.isRunnableExecutable(cached)
                {
                    log("Using cached command path for \(config.command): \(cached)")
                    return cached
                }
                log("Resolving command: \(config.command)")
                return CommandPathResolver.resolve(
                    config.command,
                    environment: environment,
                    additionalPaths: config.additionalPaths,
                    logger: { [weak self] message in
                        self?.log(message)
                    },
                    preferredBasenames: (config.resolveCandidates?.isEmpty == false ? config.resolveCandidates : [config.command]),
                    shellLookupMode: config.shellLookupMode
                )
            }()
            let workingDirectory = CommandPathResolver.expandPath(config.workingDirectory, environment: environment)
            log("Using working directory: \(workingDirectory)")
            var arguments = config.commandSuffix + args
            switch outputMode {
            case let .auto(format):
                if let existing = arguments.firstIndex(of: "--output-format") {
                    let valueIndex = arguments.index(after: existing)
                    if valueIndex < arguments.count {
                        arguments[valueIndex] = format.rawValue
                    } else {
                        arguments.append(format.rawValue)
                    }
                } else {
                    arguments.append(contentsOf: format.tokens)
                }
            case .none:
                break
            case let .custom(tokens):
                arguments.append(contentsOf: tokens)
            }
            var resolvedIsDirectory: ObjCBool = false
            if resolvedCommand.contains("/"),
               FileManager.default.fileExists(atPath: resolvedCommand, isDirectory: &resolvedIsDirectory),
               resolvedIsDirectory.boolValue
            {
                log("Resolved command is a directory; refusing to execute: \(resolvedCommand)")
                throw CLIProcessRunnerError.commandNotFound(resolvedCommand)
            }
            if config.enableDebugLogging {
                let sensitiveFlags: Set = [
                    "--append-system-prompt",
                    "--system-prompt",
                    "--prompt"
                ]
                let sanitizedArgs = arguments.enumerated().map { index, arg -> String in
                    if index > 0, sensitiveFlags.contains(arguments[index - 1]) {
                        return "<redacted>"
                    }
                    if arg.contains("<file_map>")
                        || arg.contains("<user_instructions>")
                        || arg.contains("<discover_instructions>")
                        || arg.contains("<metadata>")
                        || arg.contains("\n")
                        || arg.count > 120
                    {
                        return "<redacted>"
                    }
                    return arg
                }
                log("Launching \(resolvedCommand) with arguments: \(sanitizedArgs)")
            } else {
                log("Launching \(resolvedCommand)")
            }
            let spawned: SpawnedProcess
            do {
                spawned = try ProcessLauncher.spawn(
                    command: resolvedCommand,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory
                )
            } catch let launcherError as ProcessLauncherError {
                log("Failed to spawn \(resolvedCommand): \(launcherError)")
                throw mapLauncherError(launcherError, command: resolvedCommand, workingDirectory: workingDirectory)
            } catch {
                log("Failed to launch \(resolvedCommand): \(error)")
                throw error
            }
            let launchTime = DispatchTime.now()
            let process = try await adoptPipes(of: spawned, command: resolvedCommand)
            let overallDeadline = timeout.map { launchTime + $0 }
            // Use AsyncScope.withCleanup to ensure cleanup completes before gate is released
            return try await AsyncScope.withCleanup {
                await registry.add(process)
            } cleanup: {
                await cleanupProcess(pid: process.pid)
            } operation: {
                // 1) Immediately start draining child output (prevents cross‑pipe back‑pressure)
                let group = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()
                let beforeOutputReaderStarts = config.testHooks?.beforeOutputReaderStarts

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    Self.readOutput(
                        process.stdout,
                        channel: .stdout,
                        pid: process.pid,
                        beforeStart: beforeOutputReaderStarts
                    ) { chunk in
                        stdoutData.append(chunk)
                    }
                }

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    Self.readOutput(
                        process.stderr,
                        channel: .stderr,
                        pid: process.pid,
                        beforeStart: beforeOutputReaderStarts
                    ) { chunk in
                        stderrData.append(chunk)
                    }
                }

                // 2) Feed stdin concurrently, in chunks
                startInput(stdin, to: process)

                // 3) Wait asynchronously for termination
                let waitTask = Self.startRootWait(for: process, timeout: timeout) { [weak self] warning in
                    self?.log(warning)
                }

                // 4) Drain the readers, then report.
                let finish = { [self] () async throws -> Result in
                    let waited = await waitAndDrain(
                        process,
                        waitTask: waitTask,
                        readers: group,
                        entryPoint: .run,
                        command: resolvedCommand,
                        overallDeadline: overallDeadline
                    )
                    let exit = try waited.get()
                    if cancelChildOnTaskCancellation {
                        try Task.checkCancellation()
                    }
                    if !stdoutData.isEmpty {
                        config.logCollector?.appendDataSection(title: "STDOUT", data: stdoutData)
                    }
                    if !stderrData.isEmpty {
                        config.logCollector?.appendDataSection(title: "STDERR", data: stderrData)
                    }
                    log("Process \(process.pid) exited with status \(exit.status) (timed out: \(exit.timedOut))")
                    // On success, memorize the absolute path for next time.
                    if exit.status == 0, !exit.timedOut, resolvedCommand.contains("/"),
                       Self.isRunnableExecutable(resolvedCommand)
                    {
                        await ResolvedCommandCache.shared.put(resolvedCommand, for: config.command)
                    }
                    return Result(stdout: stdoutData, stderr: stderrData, status: exit.status, timedOut: exit.timedOut)
                }
                guard cancelChildOnTaskCancellation else {
                    return try await finish()
                }
                // The handler also covers the drain, so cancelling the task ends a drain that a
                // process outside the child's group is holding open.
                return try await withTaskCancellationHandler(operation: finish, onCancel: {
                    process.drain.cancel()
                    terminateChild(process)
                    waitTask.cancel()
                })
            }
        }
    }

    func runStreaming(
        args: [String],
        stdin: String?,
        outputMode: OutputFlagMode = .auto(.streamJson),
        timeout: TimeInterval?,
        additionalEnvironment: [String: String] = [:],
        additionalRemovedKeys: Set<String> = [],
        onProcessStarted: (@Sendable (pid_t) async -> Void)? = nil,
        onProcessTerminated: (@Sendable (pid_t) async -> Void)? = nil
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        // Hold the permit for the entire lifetime of the child process
        ProcessDiagnostics.log("🔵 [GATE] Acquiring gate...")
        guard await gate.acquire() else { throw CancellationError() }
        ProcessDiagnostics.log("🟢 [GATE] Acquired")

        // If the caller cancelled before we even start heavy work, bail out now.
        try await cancelEarlyReleasingGate(phase: "after acquiring gate")

        let environment = await resolvedEnvironment(
            additionalEnvironment: additionalEnvironment,
            additionalRemovedKeys: additionalRemovedKeys
        )

        // Cancellation can happen while we were building environment; check again.
        try await cancelEarlyReleasingGate(phase: "after env/compose")
        let resolvedCommand: String = await {
            if let cached = await ResolvedCommandCache.shared.get(for: config.command),
               Self.isRunnableExecutable(cached)
            {
                log("Using cached command path for \(config.command): \(cached)")
                return cached
            }
            log("Resolving command: \(config.command)")
            return CommandPathResolver.resolve(
                config.command,
                environment: environment,
                additionalPaths: config.additionalPaths,
                logger: { [weak self] message in
                    self?.log(message)
                },
                preferredBasenames: (config.resolveCandidates?.isEmpty == false ? config.resolveCandidates : [config.command]),
                shellLookupMode: config.shellLookupMode
            )
        }()

        // Command resolution (which can spawn an interactive shell) finished; check again.
        try await cancelEarlyReleasingGate(phase: "after command resolve")

        let workingDirectory = CommandPathResolver.expandPath(config.workingDirectory, environment: environment)
        log("Using working directory: \(workingDirectory)")
        var arguments = config.commandSuffix + args
        switch outputMode {
        case let .auto(format):
            if let existing = arguments.firstIndex(of: "--output-format") {
                let valueIndex = arguments.index(after: existing)
                if valueIndex < arguments.count {
                    arguments[valueIndex] = format.rawValue
                } else {
                    arguments.append(format.rawValue)
                }
            } else {
                arguments.append(contentsOf: format.tokens)
            }
        case .none:
            break
        case let .custom(tokens):
            arguments.append(contentsOf: tokens)
        }
        var resolvedIsDirectory: ObjCBool = false
        if resolvedCommand.contains("/"),
           FileManager.default.fileExists(atPath: resolvedCommand, isDirectory: &resolvedIsDirectory),
           resolvedIsDirectory.boolValue
        {
            log("Resolved command is a directory; refusing to execute: \(resolvedCommand)")
            await gate.release()
            throw CLIProcessRunnerError.commandNotFound(resolvedCommand)
        }
        if config.enableDebugLogging {
            let sensitiveFlags: Set = [
                "--append-system-prompt",
                "--system-prompt",
                "--prompt"
            ]
            let sanitizedArgs = arguments.enumerated().map { index, arg -> String in
                if index > 0, sensitiveFlags.contains(arguments[index - 1]) {
                    return "<redacted>"
                }
                if arg.contains("<file_map>")
                    || arg.contains("<user_instructions>")
                    || arg.contains("<discover_instructions>")
                    || arg.contains("<metadata>")
                    || arg.contains("\n")
                    || arg.count > 120
                {
                    return "<redacted>"
                }
                return arg
            }
            log("Launching \(resolvedCommand) with arguments: \(sanitizedArgs)")
        } else {
            log("Launching \(resolvedCommand)")
        }
        // Absolutely last chance before we actually spawn the child process.
        try await cancelEarlyReleasingGate(phase: "pre-spawn")

        let spawned: SpawnedProcess
        do {
            spawned = try ProcessLauncher.spawn(
                command: resolvedCommand,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
        } catch let launcherError as ProcessLauncherError {
            log("Failed to spawn \(resolvedCommand): \(launcherError)")
            ProcessDiagnostics.log("🔴 [GATE] Releasing after spawn failure")
            await gate.release()
            throw mapLauncherError(launcherError, command: resolvedCommand, workingDirectory: workingDirectory)
        } catch {
            log("Failed to launch \(resolvedCommand): \(error)")
            ProcessDiagnostics.log("🔴 [GATE] Releasing after launch failure")
            await gate.release()
            throw error
        }

        let launchTime = DispatchTime.now()
        let process: RunnerProcess
        do {
            process = try await adoptPipes(of: spawned, command: resolvedCommand)
        } catch {
            ProcessDiagnostics.log("🔴 [GATE] Releasing after pipe adoption failure")
            await gate.release()
            throw error
        }
        let overallDeadline = timeout.map { launchTime + $0 }

        await registry.add(process)
        await onProcessStarted?(process.pid)

        let collector = config.logCollector

        return AsyncThrowingStream { continuation in
            ProcessDiagnostics.log("🎬 [STREAM] Stream started for pid=\(process.pid)")

            // (A) Start draining output immediately (prevents cross‑pipe back‑pressure)
            let group = DispatchGroup()
            let stdoutTailLimit = config.captureStdoutTailBytes
            let stderrTailLimit = config.captureStderrTailBytes
            var stdoutTail = Data()
            var stderrTail = Data()
            let beforeOutputReaderStarts = config.testHooks?.beforeOutputReaderStarts

            let gateCoordinator = GateReleaseCoordinator()

            // A reader whose consumer has gone away stops yielding but keeps reading to EOF, so
            // the child never blocks on a full pipe or dies of SIGPIPE because its consumer left.
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var consumerGone = false
                Self.readOutput(
                    process.stdout,
                    channel: .stdout,
                    pid: process.pid,
                    beforeStart: beforeOutputReaderStarts
                ) { chunk in
                    appendTail(&stdoutTail, chunk: chunk, limit: stdoutTailLimit)
                    if !consumerGone, case .terminated = continuation.yield(.stdout(chunk)) {
                        consumerGone = true
                    }
                }
            }

            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                var consumerGone = false
                Self.readOutput(
                    process.stderr,
                    channel: .stderr,
                    pid: process.pid,
                    beforeStart: beforeOutputReaderStarts
                ) { chunk in
                    appendTail(&stderrTail, chunk: chunk, limit: stderrTailLimit)
                    if !consumerGone, case .terminated = continuation.yield(.stderr(chunk)) {
                        consumerGone = true
                    }
                }
            }

            // (B) Feed stdin concurrently, in chunks
            startInput(stdin, to: process)

            let waitTask = Self.startRootWait(for: process, timeout: timeout) { warning in
                ProcessDiagnostics.log(warning)
            }

            // Detached so its lifetime outlives this closure and it always releases the permit
            let _ = Task.detached { [self, gateCoordinator] in
                let waited = await waitAndDrain(
                    process,
                    waitTask: waitTask,
                    readers: group,
                    entryPoint: .runStreaming,
                    command: resolvedCommand,
                    overallDeadline: overallDeadline
                )

                if !stdoutTail.isEmpty {
                    collector?.appendDataSection(title: "STDOUT", data: stdoutTail)
                }
                if !stderrTail.isEmpty {
                    collector?.appendDataSection(title: "STDERR", data: stderrTail)
                }
                switch waited {
                case let .success(exit):
                    // On success, memorize the absolute path for next time.
                    if exit.status == 0, !exit.timedOut, resolvedCommand.contains("/"),
                       Self.isRunnableExecutable(resolvedCommand)
                    {
                        await ResolvedCommandCache.shared.put(resolvedCommand, for: config.command)
                    }
                    continuation.yield(.terminated(status: exit.status, timedOut: exit.timedOut))
                    continuation.finish()
                    ProcessDiagnostics.log("✅ [STREAM] Finished normally for pid=\(process.pid)")
                case let .failure(error):
                    ProcessDiagnostics.log("❌ [ERROR] Wait failed for pid=\(process.pid): \(error)")
                    continuation.finish(throwing: error)
                }
                ProcessDiagnostics.log("🧹 [CLEANUP] Cleaning up pid=\(process.pid)")
                if await cleanupProcess(pid: process.pid) {
                    await onProcessTerminated?(process.pid)
                }
                ProcessDiagnostics.log("🔴 [GATE] Releasing gate for pid=\(process.pid)")
                if await gateCoordinator.markReleased() {
                    await gate.release()
                    ProcessDiagnostics.log("🎉 [GATE] Released for pid=\(process.pid)")
                } else {
                    ProcessDiagnostics.log("⚠️ [GATE] Double-release prevented for pid=\(process.pid)")
                }
            }

            continuation.onTermination = { [self, gateCoordinator, process, group] reason in
                if case .cancelled = reason {
                    ProcessDiagnostics.log("🛑 [CANCEL] Cancelled pid=\(process.pid)")
                    // A cancelled run's drain does not wait on unread output. Ask the child to exit
                    // and proactively complete cleanup ourselves.
                    process.drain.cancel()
                    let signaled = terminateChild(process)

                    // Fast-path cleanup: escalate through the process group without reaping, so the
                    // finalizer's wait task stays the child's only reaper. Then stop the readers,
                    // join them briefly, and release the gate. A root reaped before the cancellation
                    // is not escalated. An escalation that has started continues through the group
                    // only, and stops once the group is gone.
                    Task.detached { [self, gateCoordinator] in
                        if signaled {
                            await ProcessTermination.terminateProcessGroup(
                                processGroupID: process.processGroupID
                            ) { msg in
                                ProcessDiagnostics.log(msg)
                            }
                        }
                        process.stdout.retire()
                        process.stderr.retire()

                        if await !Self.waitForGroup(group, until: .now() + 2.0, drain: nil) {
                            ProcessDiagnostics.log("⏰ [GROUP] Timeout waiting for reader threads for pid=\(process.pid)")
                        }
                        if await cleanupProcess(pid: process.pid) {
                            await onProcessTerminated?(process.pid)
                        }

                        if await gateCoordinator.markReleased() {
                            ProcessDiagnostics.log("🟠 [CANCEL] Releasing gate (onTermination) pid=\(process.pid)")
                            await gate.release()
                        } else {
                            ProcessDiagnostics.log("⚠️ [GATE] Double-release prevented (onTermination) pid=\(process.pid)")
                        }
                    }
                } else {
                    // Normal finish: the finalizer drains the readers and releases the gate.
                }

                // Safety net: if gate hasn't been released within 15 seconds, force release.
                Task { [self, gateCoordinator] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if await gateCoordinator.markReleased() {
                        ProcessDiagnostics.log("🚨 [WATCHDOG] DEADLOCK! Force releasing gate for pid=\(process.pid)")
                        await gate.release()
                    }
                }
            }
        }
    }

    func cancelAll() async {
        // Do not steal cleanup ownership from the finalizers; just request termination.
        let processes = await registry.current()
        var signaled: [RunnerProcess] = []
        for process in processes {
            // A cancelled run's drain does not wait on unread output. Stop further input and ask
            // the child to exit; each run's finalizer reaps it and drains its readers. A root
            // already reaped is not signaled or escalated: its IDs may belong to another process.
            process.drain.cancel()
            if terminateChild(process) {
                signaled.append(process)
            }
        }
        for process in signaled {
            // The streaming wait task remains the sole waitpid owner. Escalate only through the
            // process group so a promptly-exited root cannot leave TERM-ignoring descendants
            // alive or race a second destructive reap.
            guard let processGroupID = process.processGroupID else {
                log("Cannot escalate process \(process.pid) cancellation without a process group")
                continue
            }
            await ProcessTermination.terminateProcessGroup(
                processGroupID: processGroupID,
                logger: { [weak self] message in self?.log(message) }
            )
        }
    }

    private func resolvedEnvironment(
        additionalEnvironment: [String: String] = [:],
        additionalRemovedKeys: Set<String> = []
    ) async -> [String: String] {
        var overrides = config.environment
        // Runtime environment variables take highest priority.
        for (key, value) in additionalEnvironment {
            overrides[key] = value
        }
        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .cliRunner,
                overrides: overrides,
                additionalRemovedKeys: additionalRemovedKeys,
                enableDebugLogging: config.enableDebugLogging
            )
        )
        return result.environment
    }

    private func log(_ message: String) {
        config.logCollector?.append(message)
        if config.enableDebugLogging {
            print("[CLIProcessRunner] \(message)")
        }
    }

    @discardableResult
    private func cleanupProcess(pid: pid_t) async -> Bool {
        guard let process = await registry.remove(pid: pid) else { return false }
        // Only each endpoint's owner closes it. Retiring one its owner already closed is a no-op.
        process.input.retire()
        process.stdout.retire()
        process.stderr.retire()
        return true
    }

    /// Moves the child's pipes into endpoints the runner owns. Runs before the child is registered,
    /// so no reader, writer, or cancellation path has seen the pipes yet. On failure the child is
    /// terminated and reaped here, because no wait task exists for it.
    private func adoptPipes(of spawned: SpawnedProcess, command: String) async throws -> RunnerProcess {
        var adopted: [PipeEndpoint] = []
        do {
            guard let stdinHandle = spawned.stdin else {
                throw PipeEndpointError.duplicateFailed(errno: EBADF)
            }
            let input = try PipeEndpoint(adopting: stdinHandle, role: .input)
            adopted.append(input)
            let stdout = try PipeEndpoint(adopting: spawned.stdout, role: .output)
            adopted.append(stdout)
            let stderr = try PipeEndpoint(adopting: spawned.stderr, role: .output)
            return RunnerProcess(
                pid: spawned.pid,
                processGroupID: spawned.processGroupID,
                input: input,
                stdout: stdout,
                stderr: stderr,
                drain: DrainControl(),
                reap: RootReapState()
            )
        } catch {
            for endpoint in adopted {
                endpoint.close()
            }
            // Adoption closes each handle it adopts, and closing one twice is harmless.
            spawned.stdin?.closeFile()
            spawned.stdout.closeFile()
            spawned.stderr.closeFile()
            let errnoValue = (error as? PipeEndpointError)?.errnoValue ?? EIO
            let reason = String(cString: strerror(errnoValue))
            let basename = (command as NSString).lastPathComponent
            Self.processLogger.error(
                "Pipe adoption failed for \(basename, privacy: .public) pid \(spawned.pid, privacy: .public): errno \(errnoValue, privacy: .public)"
            )
            log("Failed to adopt the pipes of \(command): \(reason)")
            _ = await ProcessTermination.terminateAndReap(
                pid: spawned.pid,
                processGroupID: spawned.processGroupID,
                logger: { [weak self] message in self?.log(message) }
            )
            throw CLIProcessRunnerError.spawnFailed("Failed to adopt the pipes of \(command): \(reason)")
        }
    }

    /// Feeds `stdin` to the child on the writer's own thread, or closes stdin at once when there is
    /// none. Nothing waits for the writer, which closes the endpoint itself: once the endpoint is
    /// retired, its writes fail at once.
    private func startInput(_ stdin: String?, to process: RunnerProcess) {
        guard let stdin, !stdin.isEmpty, let data = stdin.data(using: .utf8) else {
            process.input.close()
            return
        }
        if config.logStdinSampleBytes > 0, let collector = config.logCollector,
           let (sample, truncated) = makeUTF8Sample(from: data, limit: config.logStdinSampleBytes)
        {
            let suffix = truncated ? "…" : ""
            collector.appendSection(title: "STDIN (sample)", content: sample + suffix)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.writeInput(data, to: process.input, pid: process.pid)
        }
    }

    /// Starts the root child's only reaper. The task marks the root reaped as soon as its wait
    /// returns: from then on the PID may be reused, so cancellation stops signaling it.
    private static func startRootWait(
        for process: RunnerProcess,
        timeout: TimeInterval?,
        logger: @escaping @Sendable (String) -> Void
    ) -> Task<RootExit, Error> {
        Task.detached {
            defer { process.reap.markReaped() }
            // Use async, cooperative waiting to avoid blocking the pool
            let (status, timedOut) = try await waitForTerminationAsync(
                pid: process.pid,
                processGroupID: process.processGroupID,
                timeout: timeout,
                logger: logger
            )
            return RootExit(status: status, timedOut: timedOut, time: .now())
        }
    }

    /// Reads an output pipe on its owner thread until EOF or retirement, handing each chunk to
    /// `deliver`, then closes the endpoint. `read(2)` returns as soon as any bytes are available, so
    /// no bytes are held inside a pending call when the drain retires the pipe.
    private static func readOutput(
        _ endpoint: PipeEndpoint,
        channel: CLIProcessRunnerTestHooks.OutputChannel,
        pid: pid_t,
        beforeStart: (@Sendable (CLIProcessRunnerTestHooks.OutputChannel) -> Void)?,
        deliver: (Data) -> Void
    ) {
        beforeStart?(channel)
        defer { endpoint.close() }
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let countsTowardBacklog = endpoint.nextReadCountsTowardBacklog()
            let count = Darwin.read(endpoint.fd, buffer, capacity)
            if count > 0 {
                endpoint.recordRead(count, countsTowardBacklog: countsTowardBacklog)
                deliver(Data(bytes: buffer, count: count))
                continue
            }
            // 0 is EOF, or a read of the retired endpoint's /dev/null.
            guard count < 0 else { return }
            let failure = errno
            if failure == EINTR { continue }
            // A read issued while retire() runs can fail with EBADF; that is an ordinary stop.
            if endpoint.isOpen {
                let channelName = "\(channel)"
                processLogger.error(
                    "\(channelName, privacy: .public) read for pid \(pid, privacy: .public) failed: errno \(failure, privacy: .public)"
                )
            }
            return
        }
    }

    /// Writes the child's stdin on its owner thread in 64 KiB chunks, then closes the endpoint.
    /// Once the endpoint is retired, the current write fails with EPIPE (or EBADF while retire()
    /// runs) and the loop stops.
    private static func writeInput(_ data: Data, to input: PipeEndpoint, pid: pid_t) {
        defer { input.close() }
        let chunkSize = 64 * 1024
        var offset = 0
        while offset < data.count, input.isOpen {
            let end = min(offset + chunkSize, data.count)
            do {
                try FDWriteSupport.writeAll(data.subdata(in: offset ..< end), to: input.fd)
            } catch {
                switch error as? FDWriteError {
                case .brokenPipe?:
                    break // The child closed stdin, or the endpoint was retired.
                default:
                    // Any other failure on a still-open blocking pipe points to a runner bug.
                    if input.isOpen {
                        let errnoValue = (error as? FDWriteError)?.errnoValue ?? 0
                        processLogger.error(
                            "stdin write for pid \(pid, privacy: .public) failed: errno \(errnoValue, privacy: .public)"
                        )
                    }
                }
                return
            }
            offset = end
        }
    }

    /// Waits for the root child, then drains its output. A failed wait cancels the drain, because
    /// the child's state is unknown. A root that timed out is drained as if the caller's deadline
    /// had already passed.
    private func waitAndDrain(
        _ process: RunnerProcess,
        waitTask: Task<RootExit, Error>,
        readers: DispatchGroup,
        entryPoint: EntryPoint,
        command: String,
        overallDeadline: DispatchTime?
    ) async -> Swift.Result<RootExit, Error> {
        let waited: Swift.Result<RootExit, Error>
        do {
            waited = try await .success(waitTask.value)
        } catch {
            waited = .failure(error)
        }
        let rootExit = try? waited.get()
        if rootExit == nil {
            process.drain.cancel()
        }
        await drainOutputs(
            process,
            readers: readers,
            entryPoint: entryPoint,
            command: command,
            rootExitTime: rootExit?.time,
            overallDeadline: rootExit?.timedOut == true ? .now() : overallDeadline
        )
        return waited
    }

    /// Waits for the output readers after the root child has exited, then logs one drain record.
    ///
    /// stdin is retired first, and each output pipe's unread bytes are recorded as its backlog: the
    /// root child's output that its reader has yet to read. If a reader is still running, a process
    /// in the child's group may hold its pipe, so the group is cleaned up. The readers then get until
    /// EOF. Each time the wait ends early, a still-open output pipe is retired at once when the drain
    /// is cancelled, when it holds no unread bytes, or when the caller's overall deadline has passed
    /// and its reader has read its backlog. A pipe with unread bytes otherwise stays open: its reader
    /// is behind, not stuck. `overallDeadline` is nil when the caller passed no timeout.
    private func drainOutputs(
        _ process: RunnerProcess,
        readers: DispatchGroup,
        entryPoint: EntryPoint,
        command: String,
        rootExitTime: DispatchTime?,
        overallDeadline: DispatchTime?
    ) async {
        let onDrainEvent = config.testHooks?.onDrainEvent
        var retirements: [String] = []
        var backlogHolds: [CLIProcessRunnerTestHooks.OutputChannel: (checks: Int, firstUnread: Int)] = [:]
        func emit(_ event: CLIProcessRunnerTestHooks.DrainEvent) {
            switch event {
            case let .checked(channel, bufferedBytes, true, reason?):
                retirements.append("\(channel) \(reason) unread=\(bufferedBytes.map(String.init) ?? "unknown")")
            case let .heldForBacklog(channel, unreadBacklog):
                let hold = backlogHolds[channel]
                backlogHolds[channel] = ((hold?.checks ?? 0) + 1, hold?.firstUnread ?? unreadBacklog)
            default:
                break
            }
            onDrainEvent?(event)
        }

        process.input.retire()
        process.stdout.recordBacklog()
        process.stderr.recordBacklog()
        emit(.started)

        // When both readers are already at EOF, no process in the group holds a pipe, so the group
        // is left alone. Its ID is the reaped root's PID, which the system may reuse.
        let groupCleanupRan = !Self.hasFinished(readers)
        if groupCleanupRan {
            await ProcessTermination.terminateProcessGroupAfterRootReap(
                processGroupID: process.processGroupID,
                logger: { [weak self] message in self?.log(message) }
            )
        }

        let outputs: [(CLIProcessRunnerTestHooks.OutputChannel, PipeEndpoint)] = [
            (.stdout, process.stdout),
            (.stderr, process.stderr)
        ]
        var checks = 0
        while true {
            let now = DispatchTime.now()
            let waitDeadline = if let overallDeadline, now >= overallDeadline {
                // Past the deadline, a pipe stays open only until its reader has read its backlog.
                // Those bytes are already in the pipe, so the reader needs only scheduling time.
                now + min(config.outputDrainCheckInterval, Self.backlogCheckInterval)
            } else {
                min(now + config.outputDrainCheckInterval, overallDeadline ?? .distantFuture)
            }
            if await Self.waitForGroup(readers, until: waitDeadline, drain: process.drain) {
                break
            }
            checks += 1
            let deadlinePassed = overallDeadline.map { DispatchTime.now() >= $0 } ?? false
            for (channel, endpoint) in outputs {
                let bufferedBytes = endpoint.bufferedByteCount()
                // nil from an endpoint that is no longer open: it reached EOF or was retired.
                if bufferedBytes == nil, !endpoint.isOpen { continue }
                let unreadBacklog = endpoint.unreadBacklog ?? 0
                let reason: CLIProcessRunnerTestHooks.RetirementReason? = if process.drain.isCancelled {
                    .cancelled
                } else if deadlinePassed, unreadBacklog == 0 {
                    // The reader has read every byte the pipe held when the drain started.
                    .deadline
                } else if bufferedBytes == 0 {
                    // Nothing is pending, so nothing the root child wrote is lost. A process
                    // outside the group holds the pipe open.
                    .idle
                } else {
                    nil
                }
                if reason == nil, deadlinePassed {
                    emit(.heldForBacklog(channel: channel, unreadBacklog: unreadBacklog))
                }
                if reason != nil {
                    endpoint.retire()
                }
                emit(.checked(channel: channel, bufferedBytes: bufferedBytes, retired: reason != nil, reason: reason))
            }
            // With every output at EOF or retired, no reader can block in a syscall, so what is
            // left of the wait is ordinary scheduling.
            if !process.stdout.isOpen, !process.stderr.isOpen {
                await Self.waitForGroup(readers)
                break
            }
        }
        emit(.finished)

        // The drain time runs from root exit to readers done. A failed wait has no exit time.
        let drainTime = rootExitTime.map { exitTime -> String in
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= exitTime.uptimeNanoseconds ? now - exitTime.uptimeNanoseconds : 0
            return " drainMs=\(elapsed / 1_000_000)"
        } ?? ""
        let basename = (command as NSString).lastPathComponent
        let retired = retirements.joined(separator: ", ")
        // A pipe that the deadline would have retired, kept open until its reader read its backlog.
        let heldForBacklog = outputs.compactMap { channel, _ in
            backlogHolds[channel].map { "\(channel) checks=\($0.checks) unreadBacklog=\($0.firstUnread)" }
        }.joined(separator: ", ")
        let cancelled = process.drain.isCancelled
        Self.processLogger.notice(
            "drain \(entryPoint.rawValue, privacy: .public) \(basename, privacy: .public) pid=\(process.pid, privacy: .public)\(drainTime, privacy: .public) groupCleanup=\(groupCleanupRan, privacy: .public) checks=\(checks, privacy: .public) cancelled=\(cancelled, privacy: .public) retired=[\(retired, privacy: .public)] heldForBacklog=[\(heldForBacklog, privacy: .public)]"
        )
    }

    private func mapLauncherError(
        _ error: ProcessLauncherError,
        command: String,
        workingDirectory: String?
    ) -> CLIProcessRunnerError {
        switch error {
        case let .pipeCreationFailed(label, errnoValue):
            let message = String(cString: strerror(errnoValue))
            return .spawnFailed("Failed to create \(label) pipe for process startup: \(message)")
        case let .descriptorConfigurationFailed(label, fd, underlying):
            let message = String(cString: strerror(underlying.errnoValue))
            return .spawnFailed("Failed to configure \(label) pipe descriptor \(fd) for process startup: \(message)")
        case let .spawnFileActionsFailed(operation, errnoValue):
            let message = String(cString: strerror(errnoValue))
            return .spawnFailed("Failed to configure spawn file actions (\(operation)) for \(command): \(message)")
        case let .changeDirectoryFailed(path, errnoValue):
            let message = String(cString: strerror(errnoValue))
            return .spawnFailed("Unable to set working directory to \(path): \(message)")
        case let .spawnAttributesFailed(operation, errnoValue):
            let message = String(cString: strerror(errnoValue))
            if let workingDirectory {
                return .spawnFailed("Failed to configure spawn attributes (\(operation)) for \(command) in \(workingDirectory): \(message)")
            }
            return .spawnFailed("Failed to configure spawn attributes (\(operation)) for \(command): \(message)")
        case let .spawnFailed(errnoValue):
            if errnoValue == ENOENT {
                return .commandNotFound(command)
            }
            let message = String(cString: strerror(errnoValue))
            if let workingDirectory {
                return .spawnFailed("Failed to launch \(command) in \(workingDirectory): \(message)")
            }
            return .spawnFailed("Failed to launch \(command): \(message)")
        }
    }

    // MARK: - Async helpers

    /// Async wrapper around DispatchGroup.wait() to avoid blocking in async contexts
    private static func waitForGroup(_ group: DispatchGroup) async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) {
                continuation.resume()
            }
        }
    }

    /// Waits for `group` until `deadline`, or until `drain` is cancelled, and returns whether the
    /// group finished. The wait resumes once, from whichever of the group's notify, the deadline
    /// timer, or the drain's wake-up fires first, so it returns on time even when the group never
    /// finishes.
    private static func waitForGroup(
        _ group: DispatchGroup,
        until deadline: DispatchTime,
        drain: DrainControl?
    ) async -> Bool {
        if hasFinished(group) { return true }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumption = GroupWaitResumption(continuation)
            group.notify(queue: .global()) { resumption.resume(finished: true) }
            DispatchQueue.global().asyncAfter(deadline: deadline) { resumption.resume(finished: false) }
            // registerWakeUp declines when the drain is already cancelled; the wait then ends now.
            if let drain, !drain.registerWakeUp({ resumption.resume(finished: false) }) {
                resumption.resume(finished: false)
            }
        }
        drain?.clearWakeUp()
        return finished
    }

    /// Non-blocking check; kept synchronous because `DispatchGroup.wait` is unavailable from async
    /// contexts.
    private static func hasFinished(_ group: DispatchGroup) -> Bool {
        group.wait(timeout: .now()) == .success
    }

    // MARK: - Cooperative process termination (no blocking sleeps)

    private static func waitForTerminationAsync(
        pid: pid_t,
        processGroupID: pid_t?,
        timeout: TimeInterval?,
        logger: (String) -> Void
    ) async throws -> (Int32, Bool) {
        do {
            let (exitCode, timedOut) = try await ProcessTermination.waitForTermination(
                pid: pid,
                processGroupID: processGroupID,
                timeout: timeout,
                logger: logger
            )
            return (exitCode, timedOut)
        } catch let terminationError as ProcessTerminationError {
            switch terminationError {
            case let .childOwnershipLost(pid):
                throw CLIProcessRunnerError.waitFailed(
                    "waitpid reported ECHILD for sole-reaper child \(pid)"
                )
            case let .waitFailed(message):
                throw CLIProcessRunnerError.waitFailed(message)
            }
        }
    }
}
