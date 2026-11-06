import Foundation
@testable import RepoPromptApp
import XCTest

/// Issue #4: a provider lane that is receiving data reports transport activity, which renews the
/// Context Builder inactivity budget, only while its completion is pending.
@MainActor
final class ProviderTransportActivityTests: XCTestCase {
    func testPendingCompletionOrdersReportedActivityBeforeTerminalOutput() async throws {
        let cases: [(label: String, outcome: AIProviderCompletionOutcome, terminalType: String, stopReason: String?)] = [
            ("completed", .completed, "message_stop", nil),
            ("incomplete", .incomplete(reason: "max_tokens"), AIStreamResult.incompleteType, "max_tokens")
        ]
        let answer = "  first block\nsecond block\n"
        for testCase in cases {
            let label = testCase.label
            let reporter = Locked<ProviderPendingCompletionStream.ReportActivity?>(nil)
            // The completion settles as soon as it reports, so an activity result that isn't yielded
            // during the report lands after settlement output or not at all. With no throttle
            // interval, only settlement can stop a later report from yielding.
            let stream = ProviderPendingCompletionStream.make(minimumActivityInterval: .zero) { report in
                reporter.withValue { $0 = report }
                report()
                return AICompletionResult(
                    text: answer,
                    promptTokens: 3,
                    completionTokens: 5,
                    cost: 0.01,
                    completionOutcome: testCase.outcome
                )
            }
            var iterator = stream.makeAsyncIterator()

            let activity = try await iterator.next()
            XCTAssertEqual(activity?.type, AIStreamResult.transportActivityType, label)
            let content = try await iterator.next()
            XCTAssertEqual(content?.type, "content", label)
            XCTAssertEqual(content?.text, answer, label)
            reporter.withValue { $0 }?()
            let terminal = try await iterator.next()
            XCTAssertEqual(terminal?.type, testCase.terminalType, label)
            XCTAssertEqual(terminal?.stopReason, testCase.stopReason, label)
            XCTAssertEqual(terminal?.promptTokens, 3, label)
            XCTAssertEqual(terminal?.completionTokens, 5, label)
            XCTAssertEqual(terminal?.cost, 0.01, label)
            reporter.withValue { $0 }?()
            let end = try await iterator.next()
            XCTAssertNil(end, "\(label): output followed the terminal result")
        }
    }

    func testPendingCompletionFailureStopsActivityAndPreservesError() async throws {
        let reporter = Locked<ProviderPendingCompletionStream.ReportActivity?>(nil)
        let stream = ProviderPendingCompletionStream.make(minimumActivityInterval: .zero) { report in
            reporter.withValue { $0 = report }
            report()
            throw AIProviderError.invalidResponse(detail: "child exited 1")
        }
        var iterator = stream.makeAsyncIterator()
        let activity = try await iterator.next()
        XCTAssertEqual(activity?.type, AIStreamResult.transportActivityType)

        do {
            let event = try await iterator.next()
            XCTFail("expected the completion's error, got \(String(describing: event?.type))")
        } catch let AIProviderError.invalidResponse(detail) {
            XCTAssertEqual(detail, "child exited 1")
        } catch {
            XCTFail("expected the completion's error, got \(error)")
        }
        reporter.withValue { $0 }?()
        let end = try await iterator.next()
        XCTAssertNil(end, "the stream yielded output after its completion failed")
    }

    func testConsumerCancellationCancelsPendingRequest() async {
        let completion = ControlledCompletion()
        addTeardownBlock { completion.release() }
        let stream = ProviderPendingCompletionStream.make { _ in try await completion.wait() }
        let consumed = Locked<ConsumedStream?>(nil)
        let consumer = Task {
            let result = await ConsumedStream.consume(stream)
            consumed.withValue { $0 = result }
        }
        // The completion starts on the first pull, so the consumer is now inside that pull.
        let started = await Self.waitUntil { completion.isStarted }
        XCTAssertTrue(started, "the first pull never started the completion")

        consumer.cancel()
        let returned = await Self.waitUntil { consumed.withValue { $0 } != nil }
        XCTAssertTrue(returned, "the cancelled pull waited for the completion to return")
        let result = consumed.withValue { $0 }
        XCTAssertEqual(result?.eventTypes, [])
        XCTAssertTrue(
            result?.error is CancellationError,
            "the cancelled pull ended with \(String(describing: result?.error)) instead of cancellation"
        )
        let cancelled = await Self.waitUntil { completion.wasCancelled }
        XCTAssertTrue(cancelled, "the consumer's cancellation didn't reach the completion")
    }

    func testConsumerCancelledBeforeFirstPullStartsNoRequest() async {
        let started = Locked(false)
        let stream = ProviderPendingCompletionStream.make { report in
            started.withValue { $0 = true }
            report()
            return AICompletionResult(text: "answer")
        }
        let consumer = Task { () -> ConsumedStream in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ConsumedStream.consume(stream)
        }
        let result = await consumer.value

        XCTAssertEqual(result.eventTypes, [], "a consumer cancelled before its first pull received output")
        // The stream may end normally here; it must not deliver an answer or another error.
        XCTAssertTrue(
            result.error == nil || result.error is CancellationError,
            String(describing: result.error)
        )
        XCTAssertFalse(started.withValue { $0 }, "a consumer cancelled before its first pull started the completion")
    }

    func testReleasingStartedStreamCancelsPendingRequest() async throws {
        let completion = ControlledCompletion()
        addTeardownBlock { completion.release() }
        var stream: AsyncThrowingStream<AIStreamResult, Error>? = ProviderPendingCompletionStream.make { report in
            report()
            return try await completion.wait()
        }
        var iterator = stream?.makeAsyncIterator()
        stream = nil
        let activity = try await iterator?.next()
        XCTAssertEqual(activity?.type, AIStreamResult.transportActivityType, "the first pull didn't start the completion")
        XCTAssertFalse(completion.wasCancelled)

        iterator = nil
        let cancelled = await Self.waitUntil { completion.wasCancelled }
        XCTAssertTrue(cancelled, "releasing the started stream left its completion running")
    }

    func testReceivedBytesThrottleUsesInclusiveInterval() {
        var throttle = ProviderTransportActivityThrottle()
        let origin = ContinuousClock.now

        XCTAssertTrue(throttle.shouldEmit(at: origin), "the first receipt")
        XCTAssertFalse(throttle.shouldEmit(at: origin.advanced(by: .seconds(-3))), "an older receipt")
        // Had the older receipt moved the last emission back, this receipt would emit.
        XCTAssertFalse(throttle.shouldEmit(at: origin.advanced(by: .seconds(2))))
        XCTAssertFalse(throttle.shouldEmit(at: origin.advanced(by: .milliseconds(4999))))
        // Had a suppressed receipt moved the last emission forward, the boundary would not emit.
        XCTAssertTrue(throttle.shouldEmit(at: origin.advanced(by: .seconds(5))), "the inclusive boundary")
        XCTAssertFalse(throttle.shouldEmit(at: origin.advanced(by: .milliseconds(9999))))
        XCTAssertTrue(throttle.shouldEmit(at: origin.advanced(by: .seconds(10))))
    }

    func testCustomOpenAIKeepaliveReportsActivityBeforeContent() async throws {
        let host = "keepalive-\(UUID().uuidString.lowercased()).invalid"
        let answerGate = GatedKeepaliveSSEURLProtocol.register(host: host)
        addTeardownBlock { GatedKeepaliveSSEURLProtocol.unregister(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedKeepaliveSSEURLProtocol.self]
        let provider = CustomOpenAIProvider(
            baseURL: "https://\(host)/v1",
            apiKey: "key",
            defaultModel: "keepalive-model",
            streamingHttpClient: DefaultHTTPClient(configuration: configuration)
        )
        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "system", userMessage: "question"),
            model: .customProvider(name: "keepalive", provider: "keepalive", model: "keepalive-model"),
            maxTokens: nil
        )
        let received = Locked<[AIStreamResult]>([])
        let end = Locked<(ended: Bool, error: Error?)>((false, nil))
        let consumer = Task {
            var failure: Error?
            do {
                for try await event in stream {
                    received.withValue { $0.append(event) }
                }
            } catch {
                failure = error
            }
            end.withValue { $0 = (true, failure) }
        }
        addTeardownBlock { consumer.cancel() }

        // Only the keepalive comment has arrived, so it alone must produce the activity.
        let reported = await Self.waitUntil { received.withValue { !$0.isEmpty } }
        XCTAssertTrue(reported, "the keepalive comment didn't report activity")
        XCTAssertEqual(received.withValue { $0.map(\.type) }, [AIStreamResult.transportActivityType])

        answerGate.open()
        let ended = await Self.waitUntil { end.withValue { $0.ended } }
        XCTAssertTrue(ended, "the stream didn't end after the answer arrived")
        XCTAssertNil(end.withValue { $0.error })
        let answer = received.withValue { $0 }.filter { $0.type != AIStreamResult.transportActivityType }
        XCTAssertEqual(answer.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(answer.first?.text, "answer")
    }
}

private extension ProviderTransportActivityTests {
    /// Polls a condition another task makes true; the timeout bounds a broken stream.
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await clock.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// What a consumer saw: the result types in order, then the error that ended the stream, if any.
private struct ConsumedStream {
    var eventTypes: [String] = []
    var error: Error?

    static func consume(_ stream: AsyncThrowingStream<AIStreamResult, Error>) async -> ConsumedStream {
        var consumed = ConsumedStream()
        do {
            for try await event in stream {
                consumed.eventTypes.append(event.type)
            }
        } catch {
            consumed.error = error
        }
        return consumed
    }
}

/// A completion that ignores cancellation: it records that its task was cancelled but stays pending
/// until the test releases it, then throws `CancellationError`. It also records when it starts
/// waiting.
private final class ControlledCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AICompletionResult, Error>?
    private var started = false
    private var cancelled = false
    private var released = false

    var isStarted: Bool {
        lock.withLock { started }
    }

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func wait() async throws -> AICompletionResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AICompletionResult, Error>) in
                let releasedBeforeWaiting = lock.withLock { () -> Bool in
                    started = true
                    if released {
                        return true
                    }
                    self.continuation = continuation
                    return false
                }
                if releasedBeforeWaiting {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            // Runs at once when the task was cancelled before the wait began.
            lock.withLock { cancelled = true }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<AICompletionResult, Error>? in
            released = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

/// Serves a streaming chat completion in two parts: a keepalive comment as soon as loading starts,
/// then the answer once the test opens the gate registered for the request's host.
private final class GatedKeepaliveSSEURLProtocol: URLProtocol {
    private static let keepalive = Data(": keep-alive\n\n".utf8)
    private static let answer = Data("""
    data: {"choices":[{"delta":{"content":"answer"},"index":0,"finish_reason":null}]}

    data: [DONE]

    """.utf8)
    private static let gates = Locked<[String: AnswerGate]>([:])

    private var gate: AnswerGate?
    /// Set and read only on the loading thread, where `stopLoading` and `deliverAnswer` both run.
    private var stopped = false

    static func register(host: String) -> AnswerGate {
        let gate = AnswerGate()
        gates.withValue { $0[host] = gate }
        return gate
    }

    static func unregister(host: String) {
        gates.withValue { $0.removeValue(forKey: host) }?.cancel()
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let gate = url.host.flatMap({ host in Self.gates.withValue { $0[host] } }),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        self.gate = gate
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.keepalive)
        // The loading system expects client calls on the thread, and in the run-loop mode, that
        // started loading.
        let thread = Thread.current
        let modes = [RunLoop.current.currentMode?.rawValue ?? RunLoop.Mode.default.rawValue]
        gate.whenOpen { [weak self] in
            guard let self else { return }
            perform(#selector(deliverAnswer), on: thread, with: nil, waitUntilDone: false, modes: modes)
        }
    }

    override func stopLoading() {
        stopped = true
        gate?.cancel()
    }

    @objc private func deliverAnswer() {
        // A delivery the gate released before the stop can still arrive after it.
        guard !stopped else { return }
        client?.urlProtocol(self, didLoad: Self.answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Holds one response's answer until the test opens it.
    final class AnswerGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var delivery: (() -> Void)?

        func open() {
            let delivery = lock.withLock { () -> (() -> Void)? in
                isOpen = true
                defer { self.delivery = nil }
                return self.delivery
            }
            delivery?()
        }

        /// Runs `delivery` when the gate opens, or at once when it is already open.
        func whenOpen(_ delivery: @escaping () -> Void) {
            let deliverNow = lock.withLock { () -> Bool in
                if isOpen {
                    return true
                }
                self.delivery = delivery
                return false
            }
            if deliverNow {
                delivery()
            }
        }

        /// Drops a delivery the gate hasn't released.
        func cancel() {
            lock.withLock { delivery = nil }
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
