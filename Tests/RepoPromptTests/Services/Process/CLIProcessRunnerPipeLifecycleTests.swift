import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// The test methods are main-actor isolated because XCTest silently drops some failures that an
/// async test records off the main thread.
final class CLIProcessRunnerPipeLifecycleTests: XCTestCase {
    @MainActor
    func testFinishedChildOutputSurvivesDelayedReaders() async throws {
        for entryPoint in EntryPoint.allCases {
            let label = entryPoint.rawValue
            let directory = try makeTestDirectory()
            // Each payload fits in a pipe buffer, so the child finishes writing and exits while
            // both readers are still held back.
            let expectedStdout = Data((0 ..< 512).map { "stdout line \($0)\n" }.joined().utf8)
            let expectedStderr = Data((0 ..< 512).map { "stderr line \($0)\n" }.joined().utf8)
            try expectedStdout.write(to: directory.appendingPathComponent("stdout.txt"))
            try expectedStderr.write(to: directory.appendingPathComponent("stderr.txt"))

            let gate = ReaderGate()
            addTeardownBlock { gate.open(by: .teardown) }
            var config = Self.configuration(command: "/bin/sh", workingDirectory: directory)
            // The runner releases the readers itself when its drain starts, which follows the root
            // child's exit.
            config.testHooks = CLIProcessRunnerTestHooks(
                beforeOutputReaderStarts: { channel in gate.park(channel) },
                onDrainEvent: { event in
                    if event == .started { gate.open(by: .drainStarted) }
                }
            )
            let script = """
            cat "$1/stdout.txt"
            cat "$1/stderr.txt" >&2
            """
            let deadlockBound = gate.openAfterDeadlockBound()

            let output = Locked(RunOutput())
            try await Self.collect(
                entryPoint,
                runner: CLIProcessRunner(config: config),
                args: ["-c", script, "sh", directory.path],
                timeout: 30,
                into: output
            )
            deadlockBound.cancel()
            let result = output.withValue { $0 }

            XCTAssertEqual(gate.parkedChannels, [.stdout, .stderr], "\(label): both readers must be held back")
            XCTAssertEqual(gate.opener, .drainStarted, "\(label): the runner never released the held readers")
            XCTAssertEqual(result.stdout, expectedStdout, "issue 157 [\(label)]: stdout written before exit was lost")
            XCTAssertEqual(result.stderr, expectedStderr, "issue 157 [\(label)]: stderr written before exit was lost")
            XCTAssertEqual(result.status, 0, label)
            if entryPoint == .runStreaming {
                XCTAssertEqual(result.terminationCount, 1, label)
                XCTAssertEqual(result.eventsAfterTermination, 0, "\(label): output arrived after .terminated")
            }
        }
    }

    @MainActor
    func testIdleEscapedHolderIsRetiredWithRealStatus() async throws {
        let payload = Data((0 ..< 256).map { "payload line \($0)\n" }.joined().utf8)
        let fixture = try makeEscapedHolderFixture(payload: payload)
        let holder = fixture.holder

        let gate = ReaderGate()
        addTeardownBlock { gate.open(by: .teardown) }
        let events = Locked([CLIProcessRunnerTestHooks.DrainEvent]())
        var config = fixture.config
        config.outputDrainCheckInterval = 0.1
        // stdout stays unread until a check has seen its unread bytes and kept the pipe open.
        config.testHooks = CLIProcessRunnerTestHooks(
            beforeOutputReaderStarts: { channel in
                if channel == .stdout { gate.park(channel) }
            },
            onDrainEvent: { event in
                events.withValue { $0.append(event) }
                if case let .checked(.stdout, bufferedBytes?, false, _) = event, bufferedBytes > 0 {
                    gate.open(by: .unreadStdoutKept)
                }
            }
        )
        let deadlockBound = gate.openAfterDeadlockBound()

        let result = try await CLIProcessRunner(config: config).run(
            args: ["-e", Self.escapedHolderScript, fixture.directory.path, "sleep"],
            stdin: nil,
            outputMode: .none,
            timeout: 30
        )
        let holderAlive = holder.isAlive
        deadlockBound.cancel()

        XCTAssertEqual(gate.opener, .unreadStdoutKept, "no check kept stdout open while it held unread bytes")
        XCTAssertEqual(result.stdout, payload, "the root child's stdout was lost")
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
        XCTAssertNotNil(holder.pid, "the root child never recorded its holder")
        XCTAssertTrue(holderAlive, "the result waited for the escaped holder to exit")

        let checks = events.withValue { $0 }
        XCTAssertEqual(
            checks.filter { $0.channel == .stderr },
            [.checked(channel: .stderr, bufferedBytes: 0, retired: true, reason: .idle)],
            "stderr holds nothing, so the first check retires it"
        )
        let stdoutChecks = checks.filter { $0.channel == .stdout }
        XCTAssertEqual(
            stdoutChecks.first,
            .checked(channel: .stdout, bufferedBytes: payload.count, retired: false, reason: nil)
        )
        XCTAssertEqual(stdoutChecks.last, .checked(channel: .stdout, bufferedBytes: 0, retired: true, reason: .idle))
        XCTAssertTrue(
            stdoutChecks.dropLast().allSatisfy { $0.retirementReason == nil },
            "stdout was retired while it held unread bytes: \(stdoutChecks)"
        )
    }

    @MainActor
    func testCallerTimeoutBoundsDrainWhileEscapedHolderKeepsWriting() async throws {
        for entryPoint in EntryPoint.allCases {
            let label = entryPoint.rawValue
            let payload = Data((0 ..< 256).map { "payload line \($0)\n" }.joined().utf8)
            let fixture = try makeEscapedHolderFixture(payload: payload)
            let holder = fixture.holder

            let gate = ReaderGate()
            addTeardownBlock { gate.open(by: .teardown) }
            let events = Locked([CLIProcessRunnerTestHooks.DrainEvent]())
            var config = fixture.config
            config.outputDrainCheckInterval = 0.1
            // stdout stays unread until a check past the caller's deadline holds it open, so the
            // deadline arrives while the root child's output is still in the pipe: the same order
            // as a child that exits just before the timeout. The holder keeps writing, so stdout
            // never goes idle and only the deadline can retire it. A runner that retires stdout
            // unread releases the reader at the retirement, so the test fails at once.
            config.testHooks = CLIProcessRunnerTestHooks(
                beforeOutputReaderStarts: { channel in
                    if channel == .stdout { gate.park(channel) }
                },
                onDrainEvent: { event in
                    events.withValue { $0.append(event) }
                    if case .heldForBacklog(.stdout, _) = event {
                        gate.open(by: .heldForBacklog)
                    }
                    if event.channel == .stdout, event.retirementReason != nil {
                        gate.open(by: .stdoutRetired)
                    }
                }
            )
            let deadlockBound = gate.openAfterDeadlockBound()

            let output = Locked(RunOutput())
            try await Self.collect(
                entryPoint,
                runner: CLIProcessRunner(config: config),
                args: ["-e", Self.escapedHolderScript, fixture.directory.path, "write"],
                timeout: 3,
                into: output
            )
            let holderAlive = holder.isAlive
            deadlockBound.cancel()
            let result = output.withValue { $0 }
            let recorded = events.withValue { $0 }

            XCTAssertEqual(gate.opener, .heldForBacklog, "\(label): the deadline did not hold stdout for its unread backlog")
            XCTAssertEqual(result.stdout.prefix(payload.count), payload, "\(label): the deadline dropped the root child's stdout")
            XCTAssertTrue(
                result.stdout.dropFirst(payload.count).allSatisfy { $0 == UInt8(ascii: ".") },
                "\(label): only the holder's bytes may follow the payload"
            )
            XCTAssertEqual(result.status, 3, label)
            XCTAssertEqual(result.timedOut, false, label)
            XCTAssertNotNil(holder.pid, "\(label): the root child never recorded its holder")
            XCTAssertTrue(holderAlive, "\(label): the result waited for the escaped holder to exit")
            let firstHold = recorded.lazy.compactMap { event -> Int? in
                if case let .heldForBacklog(.stdout, unreadBacklog) = event { unreadBacklog } else { nil }
            }.first
            XCTAssertGreaterThanOrEqual(firstHold ?? 0, payload.count, "\(label): \(recorded)")
            let stdoutChecks = recorded.filter { $0.channel == .stdout }
            XCTAssertEqual(stdoutChecks.last?.retirementReason, .deadline, "\(label): \(stdoutChecks)")
            XCTAssertTrue(
                stdoutChecks.dropLast().allSatisfy { $0.retirementReason == nil },
                "\(label): stdout was retired before its reader read the backlog: \(stdoutChecks)"
            )
        }
    }

    @MainActor
    func testSameGroupHolderIsTerminatedAtRootExit() async throws {
        let directory = try makeTestDirectory()
        let holder = Holder(directory: directory)
        addTeardownBlock { holder.terminate() }

        let events = Locked([CLIProcessRunnerTestHooks.DrainEvent]())
        var config = Self.configuration(command: "/bin/sh", workingDirectory: directory)
        // The first check would come only at the caller's 10 s deadline, so a drain without
        // checks was ended by the process-group cleanup.
        config.outputDrainCheckInterval = 30
        config.testHooks = CLIProcessRunnerTestHooks(
            onDrainEvent: { event in events.withValue { $0.append(event) } }
        )
        // Without job control, the background sleep stays in the child's process group and
        // inherits its stdout and stderr. It outlives the check interval, so only the group
        // cleanup can end the drain before a check.
        let script = """
        printf payload
        sleep 60 &
        echo $! > "$1/holder.pid"
        """

        let output = Locked(RunOutput())
        try await Self.collect(
            .runStreaming,
            runner: CLIProcessRunner(config: config),
            args: ["-c", script, "sh", directory.path],
            timeout: 10,
            into: output
        )
        let result = output.withValue { $0 }

        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "payload")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            events.withValue { $0 },
            [.started, .finished],
            "the drain checked the held pipes instead of ending at the group cleanup"
        )
        let pid = try XCTUnwrap(holder.pid, "the child never recorded its holder")
        // The killed holder is reparented to launchd, which reaps it shortly after it dies.
        let holderGone = await Self.waitUntil(timeout: .seconds(2)) { kill(pid, 0) == -1 }
        XCTAssertTrue(holderGone, "the same-group holder survived the drain")
    }

    @MainActor
    func testCancelAllEndsDrainHeldOpenByEscapedWriterAndFreesPermit() async throws {
        for ordering in CancelOrdering.allCases {
            let label = ordering.rawValue
            let fixture = try makeEscapedHolderFixture(payload: Data("payload\n".utf8))
            let holder = fixture.holder

            let events = Locked([CLIProcessRunnerTestHooks.DrainEvent]())
            var config = fixture.config
            // With no caller timeout, the first check comes at 30 s, so only the drain's sticky
            // cancellation and its wake-up can end the drain sooner.
            config.outputDrainCheckInterval = 30
            config.testHooks = CLIProcessRunnerTestHooks(
                onDrainEvent: { event in events.withValue { $0.append(event) } }
            )
            let runner = CLIProcessRunner(config: config)
            let clock = ContinuousClock()
            let launched = clock.now
            let output = Locked(RunOutput())
            var args = ["-e", Self.escapedHolderScript, fixture.directory.path, "write"]
            if ordering == .beforeDrain {
                args.append("linger")
            }
            let held = Task { [args] in
                try await Self.collect(.runStreaming, runner: runner, args: args, timeout: nil, into: output)
            }

            switch ordering {
            case .duringDrain:
                let drainStarted = await Self.waitUntil(timeout: .seconds(10)) {
                    events.withValue { $0.contains(.started) }
                }
                XCTAssertTrue(drainStarted, "\(label): the drain never started")
            case .beforeDrain:
                // The holder has escaped once its PID is recorded, and the root then lingers for
                // 30 s, so the drain cannot start before cancelAll() reaches the live root.
                let holderEscaped = await Self.waitUntil(timeout: .seconds(10)) { holder.pid != nil }
                XCTAssertTrue(holderEscaped, "\(label): the root never recorded its holder")
                XCTAssertFalse(events.withValue { $0.contains(.started) }, "\(label): the drain started early")
            }
            await runner.cancelAll()
            try await held.value
            let elapsed = launched.duration(to: clock.now)

            XCTAssertLessThan(
                elapsed,
                .seconds(10),
                "\(label): cancelAll() did not end the drain before its first check"
            )
            // A cancelled drain still reports the root's real status: its own exit, or SIGTERM.
            let expectedStatus: Int32 = ordering == .duringDrain ? 3 : 128 + SIGTERM
            XCTAssertEqual(output.withValue { $0.status }, expectedStatus, label)
            let recorded = events.withValue { $0 }
            for channel in [CLIProcessRunnerTestHooks.OutputChannel.stdout, .stderr] {
                XCTAssertEqual(
                    recorded.last { $0.channel == channel }?.retirementReason,
                    .cancelled,
                    "\(label) \(channel): \(recorded)"
                )
            }

            // The permit is free once a second launch on the same runner is admitted.
            let admitted = Locked(false)
            let second = Task {
                _ = try await runner.run(args: ["-e", "exit 0"], stdin: nil, outputMode: .none, timeout: 10)
                admitted.withValue { $0 = true }
            }
            let secondFinished = await Self.waitUntil(timeout: .seconds(5)) { admitted.withValue { $0 } }
            second.cancel()
            XCTAssertTrue(secondFinished, "\(label): the cancelled run kept the runner's permit")
        }
    }

    @MainActor
    func testStreamingDeliversOutputBeforeChildExits() async throws {
        let directory = try makeTestDirectory()
        let releaseFile = directory.appendingPathComponent("release")
        addTeardownBlock { FileManager.default.createFile(atPath: releaseFile.path, contents: nil) }
        // The child polls for the release file itself and gives up after about 30 s, so a failed
        // test never leaves it running.
        let script = """
        printf ready
        i=0
        while [ ! -e "$1" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
        """
        let output = Locked(RunOutput())
        let runner = CLIProcessRunner(config: Self.configuration(command: "/bin/sh", workingDirectory: directory))
        let consumer = Task {
            try await Self.collect(
                .runStreaming,
                runner: runner,
                args: ["-c", script, "sh", releaseFile.path],
                timeout: 60,
                into: output
            )
        }

        let deliveredBeforeExit = await Self.waitUntil(timeout: .seconds(5)) {
            output.withValue { String(decoding: $0.stdout, as: UTF8.self).contains("ready") }
        }
        XCTAssertTrue(deliveredBeforeExit, "issue 157: stdout reached the consumer only after the child exited")

        FileManager.default.createFile(atPath: releaseFile.path, contents: nil)
        try await consumer.value
        XCTAssertEqual(output.withValue { $0.status }, 0)
    }
}

private extension CLIProcessRunnerPipeLifecycleTests {
    enum EntryPoint: String, CaseIterable {
        case run
        case runStreaming
    }

    /// When `cancelAll()` reaches a run whose drain an escaped holder keeps open. Both streaming
    /// consumers call it at `message_stop`, while the root is still running.
    enum CancelOrdering: String, CaseIterable {
        case duringDrain
        case beforeDrain
    }

    struct RunOutput {
        var stdout = Data()
        var stderr = Data()
        var status: Int32?
        var timedOut: Bool?
        var terminationCount = 0
        var eventsAfterTermination = 0
    }

    /// The root child prints the payload in `$dir/stdout.txt` and forks a holder that leaves the
    /// process group and keeps stdout and stderr open for about 30 s. The holder sleeps, or with
    /// mode "write" writes a byte to stdout every 50 ms, ignoring SIGPIPE. The root waits until the
    /// holder has left the group, records the holder's PID in `$dir/holder.pid`, and exits 3. With
    /// a third argument "linger", the root first sleeps for 30 s.
    static let escapedHolderScript = #"""
    use strict;
    use POSIX ();
    my ($dir, $mode, $root) = @ARGV;
    open(my $in, '<', "$dir/stdout.txt") or die "open: $!";
    my $payload = do { local $/; <$in> };
    close $in;
    syswrite(STDOUT, $payload);
    pipe(my $left_r, my $left_w) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        close $left_r;
        setpgrp(0, 0) or POSIX::_exit(1);
        $SIG{PIPE} = 'IGNORE';
        syswrite($left_w, "x");
        close $left_w;
        if ($mode eq 'write') {
            for (1 .. 600) { syswrite(STDOUT, "."); select(undef, undef, undef, 0.05); }
        } else {
            sleep 30;
        }
        POSIX::_exit(0);
    }
    close $left_w;
    sysread($left_r, my $byte, 1) == 1 or die "the holder did not leave the group";
    open(my $out, '>', "$dir/holder.pid") or die "open: $!";
    print $out $pid;
    close $out;
    sleep 30 if defined $root && $root eq 'linger';
    exit 3;
    """#

    /// A temporary directory holding `escapedHolderScript`'s payload, the holder that script
    /// records there, and a perl configuration that runs in the directory.
    struct EscapedHolderFixture {
        let directory: URL
        let holder: Holder
        let config: CLIProcessConfiguration
    }

    /// Skips without `/usr/bin/perl`. The holder is killed at teardown.
    func makeEscapedHolderFixture(payload: Data, name: String = #function) throws -> EscapedHolderFixture {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"),
            "the escaped-holder fixture needs /usr/bin/perl"
        )
        let directory = try makeTestDirectory(name: name)
        try payload.write(to: directory.appendingPathComponent("stdout.txt"))
        let holder = Holder(directory: directory)
        addTeardownBlock { holder.terminate() }
        return EscapedHolderFixture(
            directory: directory,
            holder: holder,
            config: Self.configuration(command: "/usr/bin/perl", workingDirectory: directory)
        )
    }

    static func configuration(command: String, workingDirectory: URL) -> CLIProcessConfiguration {
        CLIProcessConfiguration(
            command: command,
            workingDirectory: workingDirectory.path,
            environment: ProcessInfo.processInfo.environment,
            additionalPaths: [],
            shellLookupMode: .disabled
        )
    }

    static func collect(
        _ entryPoint: EntryPoint,
        runner: CLIProcessRunner,
        args: [String],
        timeout: TimeInterval?,
        into output: Locked<RunOutput>
    ) async throws {
        switch entryPoint {
        case .run:
            let result = try await runner.run(args: args, stdin: nil, outputMode: .none, timeout: timeout)
            output.withValue {
                $0.stdout = result.stdout
                $0.stderr = result.stderr
                $0.status = result.status
                $0.timedOut = result.timedOut
            }
        case .runStreaming:
            let stream = try await runner.runStreaming(args: args, stdin: nil, outputMode: .none, timeout: timeout)
            for try await event in stream {
                output.withValue {
                    if $0.terminationCount > 0 { $0.eventsAfterTermination += 1 }
                    switch event {
                    case let .stdout(chunk):
                        $0.stdout.append(chunk)
                    case let .stderr(chunk):
                        $0.stderr.append(chunk)
                    case let .terminated(status, timedOut):
                        $0.status = status
                        $0.timedOut = timedOut
                        $0.terminationCount += 1
                    }
                }
            }
        }
    }

    /// Polls a condition that another thread makes true; the timeout bounds a broken fixture.
    static func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await clock.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private extension CLIProcessRunnerTestHooks.DrainEvent {
    var channel: CLIProcessRunnerTestHooks.OutputChannel? {
        if case let .checked(channel, _, _, _) = self { channel } else { nil }
    }

    var retirementReason: CLIProcessRunnerTestHooks.RetirementReason? {
        if case let .checked(_, _, true, reason) = self { reason } else { nil }
    }
}

/// A holder process whose PID the test's child records in `holder.pid`.
private struct Holder {
    let pidFile: URL

    init(directory: URL) {
        pidFile = directory.appendingPathComponent("holder.pid")
    }

    var pid: pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isAlive: Bool {
        pid.map { kill($0, 0) == 0 } ?? false
    }

    func terminate() {
        if let pid { kill(pid, SIGKILL) }
    }
}

/// Holds output readers inside `beforeOutputReaderStarts` until something opens it, and records
/// what opened it first.
private final class ReaderGate: @unchecked Sendable {
    enum Opener: Equatable {
        case drainStarted
        case unreadStdoutKept
        case heldForBacklog
        case stdoutRetired
        case deadlockBound
        case teardown
    }

    private let condition = NSCondition()
    private var parked: Set<CLIProcessRunnerTestHooks.OutputChannel> = []
    private var firstOpener: Opener?

    var parkedChannels: Set<CLIProcessRunnerTestHooks.OutputChannel> {
        condition.withLock { parked }
    }

    var opener: Opener? {
        condition.withLock { firstOpener }
    }

    func park(_ channel: CLIProcessRunnerTestHooks.OutputChannel) {
        condition.withLock {
            parked.insert(channel)
            while firstOpener == nil {
                condition.wait()
            }
        }
    }

    func open(by opener: Opener) {
        condition.withLock {
            if firstOpener == nil { firstOpener = opener }
            condition.broadcast()
        }
    }

    /// Opens the gate after 10 s unless cancelled, so a runner that never releases its readers
    /// fails the test instead of hanging it.
    func openAfterDeadlockBound() -> Task<Void, Never> {
        Task { [self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            open(by: .deadlockBound)
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}
