import Foundation
@testable import RepoPromptApp
import XCTest

/// The test methods are main-actor isolated because XCTest silently drops some failures that an
/// async test records off the main thread.
final class CLIProcessRunnerPipeLifecycleTests: XCTestCase {
    @MainActor
    func testFinishedChildOutputSurvivesDelayedReaders() async throws {
        expectIssue157Failures("issue 157: the runner closes output pipes before its readers have read them")
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
            var config = Self.shellConfiguration(workingDirectory: directory)
            // The runner releases the readers itself, at the start of its drain or, without one,
            // right after it closes the output handles. Either way the release follows the root
            // child's exit.
            config.testHooks = CLIProcessRunnerTestHooks(
                beforeOutputReaderStarts: { channel in gate.park(channel) },
                onDrainEvent: { event in
                    if event == .started { gate.open(by: .drainStarted) }
                },
                afterOutputHandlesClosed: { gate.open(by: .outputHandlesClosed) }
            )
            let script = """
            cat "$1/stdout.txt"
            cat "$1/stderr.txt" >&2
            """
            let deadlockBound = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                gate.open(by: .deadlockBound)
            }

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
            XCTAssertTrue(
                gate.opener == .drainStarted || gate.opener == .outputHandlesClosed,
                "\(label): the runner never released the held readers; opened by \(String(describing: gate.opener))"
            )
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
    func testStreamingDeliversOutputBeforeChildExits() async throws {
        expectIssue157Failures("issue 157: runStreaming delivers output only at 64 KiB boundaries or at EOF")
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
        let runner = CLIProcessRunner(config: Self.shellConfiguration(workingDirectory: directory))
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

    struct RunOutput {
        var stdout = Data()
        var stderr = Data()
        var status: Int32?
        var terminationCount = 0
        var eventsAfterTermination = 0
    }

    /// Expects the failures whose message contains "issue 157" and no others. The expectation is
    /// strict, so once the runner passes those assertions the test fails until this call is removed.
    func expectIssue157Failures(_ reason: String) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { $0.compactDescription.contains("issue 157") }
        XCTExpectFailure(reason, options: options)
    }

    static func shellConfiguration(workingDirectory: URL) -> CLIProcessConfiguration {
        CLIProcessConfiguration(
            command: "/bin/sh",
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
        timeout: TimeInterval,
        into output: Locked<RunOutput>
    ) async throws {
        switch entryPoint {
        case .run:
            let result = try await runner.run(args: args, stdin: nil, outputMode: .none, timeout: timeout)
            output.withValue {
                $0.stdout = result.stdout
                $0.stderr = result.stderr
                $0.status = result.status
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
                    case let .terminated(status, _):
                        $0.status = status
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

/// Holds output readers inside `beforeOutputReaderStarts` until something opens it, and records
/// what opened it first.
private final class ReaderGate: @unchecked Sendable {
    enum Opener: Equatable {
        case drainStarted
        case outputHandlesClosed
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
