import Foundation
@testable import RepoPromptApp

actor OracleControlledStream {
    private var continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    func makeStream() -> (
        id: ChatStreamID,
        stream: AsyncThrowingStream<ChatStreamOutput, Error>
    ) {
        var installedContinuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?
        let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
            installedContinuation = continuation
        }
        continuation = installedContinuation
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return (UUID(), stream)
    }

    func waitUntilReady() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    func yield(_ output: ChatStreamOutput) {
        continuation?.yield(output)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}
