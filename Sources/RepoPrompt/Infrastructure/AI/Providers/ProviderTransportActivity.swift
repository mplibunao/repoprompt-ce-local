import Foundation

/// Transport-activity results for provider streams.
///
/// A Context Builder follow-up renews its inactivity budget only from stream activity. A provider
/// that receives data before it has answer text reports that receipt as a `transport_activity`
/// result. Activity comes only from received data, so a lane that goes silent still exhausts the
/// budget.
enum ProviderTransportActivity {
    /// Minimum spacing between activity results derived from received data.
    static let receivedBytesMinimumInterval: Duration = .seconds(5)

    static func result() -> AIStreamResult {
        AIStreamResult(type: AIStreamResult.transportActivityType, text: nil)
    }
}

/// Spaces activity results derived from received data. It isn't synchronized: confine it to one
/// task or guard it with a lock.
struct ProviderTransportActivityThrottle {
    let minimumInterval: Duration
    private var lastEmission: ContinuousClock.Instant?

    init(minimumInterval: Duration = ProviderTransportActivity.receivedBytesMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    /// The first receipt emits, and so does a receipt at least `minimumInterval` after the last
    /// emission. A suppressed receipt, including one older than the last emission, leaves the
    /// last emission unchanged.
    mutating func shouldEmit(at now: ContinuousClock.Instant) -> Bool {
        if let lastEmission, now < lastEmission.advanced(by: minimumInterval) {
            return false
        }
        lastEmission = now
        return true
    }
}

/// Streams a buffered completion, with the activity it reports while it is pending.
///
/// The completion starts on the consumer's first pull and receives a reporter that any thread may
/// call. Each report the throttle lets through yields a `transport_activity` result. Settlement
/// closes the reporter before it yields anything else, so every activity result precedes the
/// completion's `content` and terminal result, or its error, and later reports are ignored. An
/// `.incomplete` outcome ends with `AIStreamResult.incompleteType` and its reason instead of
/// `message_stop`.
///
/// Cancelling the consuming task, or releasing a started stream and its iterator, cancels a
/// completion that hasn't settled, without waiting for it to return. A consumer cancelled during a
/// pull gets `CancellationError`. One cancelled before its first pull starts nothing, and its
/// stream may end without an error. Only one task may consume the stream.
enum ProviderPendingCompletionStream {
    typealias ReportActivity = @Sendable () -> Void
    typealias Complete = @Sendable (_ reportActivity: @escaping ReportActivity) async throws -> AICompletionResult

    static func make(complete: @escaping Complete) -> AsyncThrowingStream<AIStreamResult, Error> {
        let iterator = PendingCompletionIterator(complete: complete)
        // `AsyncThrowingStream(unfolding:)` never calls this closure for a consumer that is
        // already cancelled, so the iterator also starts nothing for it.
        return AsyncThrowingStream(unfolding: { try await iterator.next() })
    }
}

/// Owns the pending completion behind one outer stream. Only that stream's consuming task calls
/// `next()`, one call at a time.
private final class PendingCompletionIterator: @unchecked Sendable {
    typealias Events = AsyncThrowingStream<AIStreamResult, Error>
    typealias Complete = ProviderPendingCompletionStream.Complete

    private enum State {
        case notStarted
        case started(events: Events.AsyncIterator, producer: Task<Void, Never>)
        case finished
    }

    private let complete: Complete
    private var state = State.notStarted

    init(complete: @escaping Complete) {
        self.complete = complete
    }

    deinit {
        // Releasing the stream releases this iterator, which cancels a completion still pending.
        if case let .started(_, producer) = state {
            producer.cancel()
        }
    }

    func next() async throws -> AIStreamResult? {
        var events: Events.AsyncIterator
        let producer: Task<Void, Never>
        switch state {
        case .finished:
            return nil
        case let .started(current, task):
            events = current
            producer = task
        case .notStarted:
            try Task.checkCancellation()
            (events, producer) = start()
            state = .started(events: events, producer: producer)
        }

        let event: AIStreamResult?
        do {
            // Cancelling the consuming task here terminates `events`, which cancels the producer
            // and ends this wait without joining the completion.
            event = try await events.next()
        } catch {
            state = .finished
            throw error
        }
        // A pull that cancellation reached reports the cancellation instead of an event or a
        // normal end.
        if Task.isCancelled {
            producer.cancel()
            state = .finished
            throw CancellationError()
        }
        guard let event else {
            state = .finished
            return nil
        }
        state = .started(events: events, producer: producer)
        return event
    }

    private func start() -> (Events.AsyncIterator, Task<Void, Never>) {
        let (events, continuation) = Events.makeStream()
        let output = PendingCompletionOutput(continuation: continuation)
        let complete = complete
        let producer = Task {
            do {
                let completion = try await complete { output.reportActivity() }
                output.settle(with: completion)
            } catch {
                output.fail(with: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return (events.makeAsyncIterator(), producer)
    }
}

/// The pending completion's output. A report yields under the lock only while activity is open,
/// and settlement closes activity under the same lock before it yields anything, so no activity
/// result can follow settlement output.
private final class PendingCompletionOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    private var throttle = ProviderTransportActivityThrottle()
    private var activityOpen = true

    init(continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) {
        self.continuation = continuation
    }

    func reportActivity() {
        lock.withLock {
            guard activityOpen, throttle.shouldEmit(at: .now) else { return }
            if case .terminated = continuation.yield(ProviderTransportActivity.result()) {
                activityOpen = false
            }
        }
    }

    func settle(with completion: AICompletionResult) {
        closeActivity()
        continuation.yield(AIStreamResult(type: "content", text: completion.text))
        continuation.yield(Self.terminalResult(for: completion))
        continuation.finish()
    }

    func fail(with error: Error) {
        closeActivity()
        continuation.finish(throwing: error)
    }

    private func closeActivity() {
        lock.withLock { activityOpen = false }
    }

    private static func terminalResult(for completion: AICompletionResult) -> AIStreamResult {
        switch completion.completionOutcome {
        case .completed:
            AIStreamResult(
                type: "message_stop",
                text: nil,
                promptTokens: completion.promptTokens,
                completionTokens: completion.completionTokens,
                cost: completion.cost
            )
        case let .incomplete(reason):
            AIStreamResult(
                type: AIStreamResult.incompleteType,
                text: nil,
                promptTokens: completion.promptTokens,
                completionTokens: completion.completionTokens,
                cost: completion.cost,
                stopReason: reason
            )
        }
    }
}
