import Foundation
import Logging
import MCP
import RepoPromptShared

// MARK: - Proxy Session

/// The helper's retry delays for reaching its app: every 0.5 s plus jitter for the first 60 s after
/// the first failure, while the app may be restarting, then exponential backoff from 1 s to 30 s,
/// with no overall limit. A session keeps one schedule from its first failure on.
private struct MCPProxyRetrySchedule: Sendable {
    private(set) var attempt = 0
    private var firstFailureAt: Date?

    /// Records one failed attempt and returns how long to wait before the next one.
    mutating func delayAfterFailure(now: Date = Date()) -> TimeInterval {
        let aggressiveDelay = 0.5
        let aggressivePhaseDuration = 60.0
        let backoffBase = 1.0
        let maxDelay = 30.0

        attempt += 1
        let firstFailureAt = firstFailureAt ?? now
        self.firstFailureAt = firstFailureAt
        guard now.timeIntervalSince(firstFailureAt) >= aggressivePhaseDuration else {
            return aggressiveDelay + Double.random(in: 0 ... 0.1)
        }
        let backoffAttempt = attempt - Int(aggressivePhaseDuration / aggressiveDelay)
        let expDelay = min(maxDelay, backoffBase * pow(2.0, Double(max(0, backoffAttempt - 1))))
        return min(maxDelay, expDelay + Double.random(in: 0 ... (0.2 * expDelay)))
    }

    func elapsedSinceFirstFailure(now: Date = Date()) -> TimeInterval {
        firstFailureAt.map { now.timeIntervalSince($0) } ?? 0
    }
}

/// What the offline loop and the attachment worker share while the helper answers the client
/// itself. The loop reads the condition for each answer and checks for a handoff at each frame
/// boundary; the worker waits for the client's initialize result before its first attempt and
/// requests the handoff when it has an admitted candidate or a terminal failure.
private final class MCPProxyAttachmentState: @unchecked Sendable {
    private let lock = NSLock()
    private var condition: MCPAppConnectionMessages.Condition
    private var initializeResultDelivered = false
    private var initializeResultWaiter: CheckedContinuation<Void, Never>?
    private var initializeResultWaitCancelled = false
    private var handoffRequested = false

    init(condition: MCPAppConnectionMessages.Condition) {
        self.condition = condition
    }

    func connectionMessage(identity: MCPFilesystemIdentity) -> String {
        MCPAppConnectionMessages.offlineText(for: lock.withLock { condition }, identity: identity)
    }

    func setCondition(_ condition: MCPAppConnectionMessages.Condition) {
        lock.withLock { self.condition = condition }
    }

    var hasDeliveredInitializeResult: Bool {
        lock.withLock { initializeResultDelivered }
    }

    func markInitializeResultDelivered() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            initializeResultDelivered = true
            defer { initializeResultWaiter = nil }
            return initializeResultWaiter
        }
        waiter?.resume()
    }

    /// Returns once the client has its initialize result. Supports one waiter.
    func waitForInitializeResult() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    guard !initializeResultDelivered, !initializeResultWaitCancelled else { return true }
                    initializeResultWaiter = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                initializeResultWaitCancelled = true
                defer { initializeResultWaiter = nil }
                return initializeResultWaiter
            }
            waiter?.resume()
        }
        try Task.checkCancellation()
    }

    var isHandoffRequested: Bool {
        lock.withLock { handoffRequested }
    }

    func requestHandoff() {
        lock.withLock { handoffRequested = true }
    }
}

/// One client's MCP session through the helper, from the first connection attempt to its end.
///
/// The app is tried first, before stdin is read. When it can't be reached, the offline loop owns
/// stdin and stdout and answers the client with `MCPOfflineResponder`, while one attachment worker
/// keeps trying the app on `MCPProxyRetrySchedule`. Once the app admits the session's replayed
/// `initialize`, the loop stops at a frame boundary and the bridge takes over with the unread
/// bytes. A disconnect after that takes the reconnect loop, which replays the session as before.
struct MCPProxySession {
    /// Client state that lives as long as the helper process and survives every reconnect.
    struct Client: Sendable {
        let sessionToken: String
        let identityCache: ClientIdentityCache
        let initializeReplayState: MCPInitializeReplayState
        let outstandingRequestReplayState: MCPOutstandingRequestReplayState
        let bridgeLedger: JSONRPCBridgeLedger
    }

    enum Phase: Equatable, Sendable {
        /// The offline loop answers the client while the worker retries the app.
        case offlineStartup
        /// The app accepted a connection attempt and is deciding whether to admit the client.
        case awaitingAdmission
        /// The app admitted the replayed `initialize`. The offline loop hands the client to the
        /// bridge at its next frame boundary.
        case attachmentReady
        /// The bridge relays between the client and the app.
        case connected
    }

    typealias RetryWait = @Sendable (TimeInterval) async throws -> Void
    typealias PhaseObserver = @Sendable (Phase) -> Void

    private struct AttachmentCandidate {
        let proxy: BootstrapSocketProxy
        let bufferedServerFrames: Data
        let schedule: MCPProxyRetrySchedule
    }

    private enum AttachmentWorkerOutcome {
        case ready(AttachmentCandidate)
        case failed(CLIRuntimeError)
        case cancelled
    }

    private enum InitialConnection {
        case accepted(BootstrapSocketProxy)
        case offline(MCPAppConnectionMessages.Condition)
    }

    private static let toolsListChangedNotification = Data(
        "{\"jsonrpc\":\"2.0\",\"method\":\"\(ToolListChangedNotification.name)\"}\n".utf8
    )

    private let client: Client
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let socketURL: URL
    private let identity: MCPFilesystemIdentity
    private let serverVersion: String
    private let faultRule: JSONRPCBridgeFaultRule?
    private let logMessage: @Sendable (Logger.Level, String) -> Void
    private let retryWait: RetryWait
    private let onPhaseChange: PhaseObserver?

    /// Runs one proxy session until it ends.
    ///
    /// - Parameters:
    ///   - identity: Which app the helper serves, for the offline answers and messages.
    ///   - serverVersion: The `serverInfo.version` of an offline initialize result.
    ///   - logMessage: Receives the session's log lines at the level it emits them.
    ///   - retryWait: Waits between connection attempts. It must throw when cancelled.
    ///   - onPhaseChange: Called as the session moves between the phases it reports.
    /// - Returns: Why the session ended. Cancellation ends it as `.hostDisconnected(.taskCancelled)`.
    static func run(
        client: Client,
        stdinFD: Int32 = STDIN_FILENO,
        stdoutFD: Int32 = STDOUT_FILENO,
        stderrFD: Int32 = STDERR_FILENO,
        socketURL: URL,
        identity: MCPFilesystemIdentity,
        serverVersion: String,
        faultRule: JSONRPCBridgeFaultRule? = nil,
        logMessage: @escaping @Sendable (Logger.Level, String) -> Void = { _, _ in },
        retryWait: @escaping RetryWait,
        onPhaseChange: PhaseObserver? = nil
    ) async -> CLIRuntimeError {
        let session = MCPProxySession(
            client: client,
            stdinFD: stdinFD,
            stdoutFD: stdoutFD,
            stderrFD: stderrFD,
            socketURL: socketURL,
            identity: identity,
            serverVersion: serverVersion,
            faultRule: faultRule,
            logMessage: logMessage,
            retryWait: retryWait,
            onPhaseChange: onPhaseChange
        )
        var ending: CLIRuntimeError
        do {
            try await session.runUntilEnded()
        } catch {
            ending = runtimeError(for: error, logMessage: logMessage)
        }
        // A cancelled write or socket read surfaces as a transport failure; cancellation is the cause.
        if Task.isCancelled, case .connectionFailed = ending {
            ending = .hostDisconnected(.taskCancelled)
        }
        session.reportRefusal(ending)
        return ending
    }

    /// The runtime error that a failed connection or session part ends with.
    static func runtimeError(
        for error: Swift.Error,
        logMessage: @Sendable (Logger.Level, String) -> Void
    ) -> CLIRuntimeError {
        if let runtimeError = error as? CLIRuntimeError {
            return runtimeError
        }
        if error is CancellationError {
            return .hostDisconnected(.taskCancelled)
        }
        guard let socketError = error as? SocketProxyError else {
            return .connectionFailed(underlying: error)
        }
        switch socketError {
        case .approvalDenied:
            return .approvalDenied
        case .hostDisconnected:
            return .hostDisconnected(.stdinClosed)
        case let .stdoutBrokenPipe(bytesWritten, totalBytes):
            logMessage(.debug, "BootstrapSocketProxy: stdout bridge broken_pipe bytes_written=\(bytesWritten) total_bytes=\(totalBytes)")
            return .hostDisconnected(.stdoutBrokenPipe(bytesWritten: bytesWritten, totalBytes: totalBytes))
        case let .terminatedByServer(reason, message):
            return .terminatedByServer(CLIServerTerminationProvenance(reason: reason, message: message))
        default:
            return .connectionFailed(underlying: socketError)
        }
    }

    private func runUntilEnded() async throws -> Never {
        var schedule = MCPProxyRetrySchedule()
        switch try await connectInitially(schedule: &schedule) {
        case let .accepted(proxy):
            onPhaseChange?(.connected)
            try await runConnectionLoop(schedule: schedule) {
                try await runConnection(proxy) {
                    try await proxy.runAcceptedBridge(initialStdinBytes: Data(), initialSocketBytes: Data())
                }
            }
        case let .offline(condition):
            let (candidate, unreadStdinBytes) = try await runOfflineStartup(condition: condition, schedule: schedule)
            try await runConnectionLoop(schedule: candidate.schedule) {
                try await runConnection(candidate.proxy) {
                    try await attach(candidate, unreadStdinBytes: unreadStdinBytes)
                }
            }
        }
    }

    // MARK: Initial connection

    /// Tries the app before reading stdin, so a reachable app serves the session from its first
    /// frame. The first-attempt rule decides whether a failure goes offline, retries once, or ends
    /// the session.
    private func connectInitially(schedule: inout MCPProxyRetrySchedule) async throws -> InitialConnection {
        var retried = false
        while true {
            _ = try await client.bridgeLedger.beginConnection()
            let proxy = await makeProxy(replayInitializationOnStart: false)
            let failure: CLIRuntimeError
            do {
                try await proxy.connectAndAccept()
                return .accepted(proxy)
            } catch {
                await proxy.stop()
                failure = Self.runtimeError(for: error, logMessage: logMessage)
            }

            let protocolActiveFailure = await client.bridgeLedger.recordConnectionFailure(
                CLIProxyRuntimePolicy.failureReason(for: failure)
            )
            guard !protocolActiveFailure else {
                throw failure
            }
            switch CLIProxyRuntimePolicy.firstAttemptDisposition(after: failure) {
            case .terminal:
                throw failure
            case .offline:
                return .offline(CLIProxyRuntimePolicy.connectionCondition(for: failure))
            case .retryOnce:
                guard !retried else {
                    return .offline(CLIProxyRuntimePolicy.connectionCondition(for: failure))
                }
                retried = true
                let delay = schedule.delayAfterFailure()
                logMessage(.debug, "MCPProxySession: first connection failed (\(failure)); retrying once in \(delay)s")
                try await waitForRetry(delay)
            }
        }
    }

    // MARK: Offline startup and attachment

    /// Answers the client locally until the attachment worker has an admitted candidate.
    ///
    /// - Returns: The candidate, and the stdin bytes the offline loop read but did not consume.
    private func runOfflineStartup(
        condition: MCPAppConnectionMessages.Condition,
        schedule: MCPProxyRetrySchedule
    ) async throws -> (AttachmentCandidate, Data) {
        onPhaseChange?(.offlineStartup)
        let attachment = MCPProxyAttachmentState(condition: condition)
        let worker = Task {
            await runAttachmentWorker(attachment: attachment, schedule: schedule)
        }

        let loopResult: Result<MCPProxyStdinPump.Result, Swift.Error>
        do {
            loopResult = try await .success(withTaskCancellationHandler {
                try await runOfflineLoop(attachment: attachment)
            } onCancel: {
                worker.cancel()
            })
        } catch {
            loopResult = .failure(error)
        }

        // The loop hands off only after the worker has published its outcome.
        if case let .success(.handoff(unreadBytes)) = loopResult, !Task.isCancelled {
            switch await worker.value {
            case let .ready(candidate):
                return (candidate, unreadBytes)
            case let .failed(failure):
                throw failure
            case .cancelled:
                break
            }
        }

        // The worker and any candidate it holds end before the session does, so no attempt
        // outlives it and no socket stays open.
        worker.cancel()
        if case let .ready(candidate) = await worker.value {
            await candidate.proxy.stop()
        }
        switch loopResult {
        case .success(.stdinClosed):
            throw CLIRuntimeError.hostDisconnected(.stdinClosed)
        case .success(.handoff):
            throw CLIRuntimeError.hostDisconnected(.taskCancelled)
        case let .failure(error):
            throw error
        }
    }

    /// Answers each client frame before reading the next, so no local request is outstanding at a
    /// frame boundary and the handoff never leaves work behind in the ledger.
    private func runOfflineLoop(attachment: MCPProxyAttachmentState) async throws -> MCPProxyStdinPump.Result {
        let originalStdoutFlags: Int32
        do {
            originalStdoutFlags = try NonBlockingFDWriter.setNonBlocking(fd: stdoutFD)
        } catch let writeError as NonBlockingFDWriteError {
            throw BootstrapSocketProxy.mapStdoutWriteError(writeError)
        }
        // The bridge sets stdout's flags for itself, so the loop restores them before handing off.
        defer {
            try? NonBlockingFDWriter.restoreFlags(fd: stdoutFD, flags: originalStdoutFlags)
        }

        let ledger = client.bridgeLedger
        var responder = MCPOfflineResponder(identity: identity, serverVersion: serverVersion)
        return try await MCPProxyStdinPump.run(
            stdinFD: stdinFD,
            initialBytes: Data(),
            ledger: ledger,
            identityCache: client.identityCache,
            shouldHandOff: { attachment.isHandoffRequested }
        ) { frame in
            let prepared = try await ledger.prepare(frame: frame, direction: .clientToServer)
            let outcome: MCPOfflineResponder.Outcome
            do {
                outcome = try responder.respond(
                    to: frame,
                    connectionMessage: attachment.connectionMessage(identity: identity)
                )
            } catch {
                await ledger.abort(prepared, reason: "offline_response_encoding_failed")
                throw error
            }
            // Only a validated initialize and its initialized notification are kept for the
            // replay into the app. A locally answered request is never kept, so it can't run in
            // the app later.
            if outcome.recordsClientFrameForReplay {
                await client.initializeReplayState.recordForwardedClientFrame(frame)
            }
            try await ledger.commit(prepared)
            if let response = outcome.response {
                try await deliverLocalResponse(response, attachment: attachment)
            }
        }
    }

    private func deliverLocalResponse(_ response: Data, attachment: MCPProxyAttachmentState) async throws {
        let stdoutFD = stdoutFD
        let prepared = try await JSONRPCBridgeDelivery.forward(
            frame: response,
            direction: .serverToClient,
            ledger: client.bridgeLedger,
            faultRule: faultRule
        ) { framed in
            try BootstrapSocketProxy.writeClientFrame(framed, stdoutFD: stdoutFD)
        }
        guard let delivered = prepared.deliveryFrame else { return }
        await client.initializeReplayState.recordDeliveredServerFrame(delivered)
        await client.outstandingRequestReplayState.recordDeliveredServerFrame(delivered, prepared: prepared)
        if !attachment.hasDeliveredInitializeResult,
           case let .success(plan) = await client.initializeReplayState.replayPlan(),
           plan.initializeResultFingerprint != nil
        {
            attachment.markInitializeResultDelivered()
        }
    }

    /// Makes every connection attempt while the offline loop answers the client. A failed
    /// candidate is not a failure of the client's connection, so attempts leave the ledger alone.
    private func runAttachmentWorker(
        attachment: MCPProxyAttachmentState,
        schedule: MCPProxyRetrySchedule
    ) async -> AttachmentWorkerOutcome {
        var schedule = schedule
        do {
            // The replay needs the client's initialize and the result it received.
            try await attachment.waitForInitializeResult()
            while true {
                try await retryWait(schedule.delayAfterFailure())
                let proxy = await makeProxy(replayInitializationOnStart: true)
                do {
                    try await proxy.connectAndAccept()
                    attachment.setCondition(.awaitingApproval)
                    onPhaseChange?(.awaitingAdmission)
                    // No deadline: admission can wait on a person approving the client.
                    let bufferedServerFrames = try await proxy.replayInitialize(timeout: nil)
                    attachment.requestHandoff()
                    onPhaseChange?(.attachmentReady)
                    return .ready(AttachmentCandidate(
                        proxy: proxy,
                        bufferedServerFrames: bufferedServerFrames,
                        schedule: schedule
                    ))
                } catch {
                    await proxy.stop()
                    if Task.isCancelled {
                        return .cancelled
                    }
                    let failure = Self.runtimeError(for: error, logMessage: logMessage)
                    guard CLIProxyRuntimePolicy.shouldRetry(after: failure) else {
                        attachment.requestHandoff()
                        return .failed(failure)
                    }
                    attachment.setCondition(CLIProxyRuntimePolicy.connectionCondition(for: failure))
                    logMessage(.debug, "MCPProxySession: attachment attempt \(schedule.attempt) failed: \(failure)")
                }
            }
        } catch {
            return .cancelled
        }
    }

    /// Moves the client from the offline loop to the bridge on an admitted candidate.
    ///
    /// Nothing here writes to the socket before the bridge owns it, so a candidate that fails right
    /// after admission fails inside the bridge, with the client's bytes and the catalog refresh
    /// already in the bridge's hands.
    private func attach(_ candidate: AttachmentCandidate, unreadStdinBytes: Data) async throws {
        // Every local request was answered before the next frame was read, so nothing is pending
        // or unreplayable; `beginConnection` ends the session if that ever fails to hold.
        _ = try await client.bridgeLedger.beginConnection()
        // The client sent this before every unread byte, so it goes first.
        let lateInitialized = await candidate.proxy.takeLateInitializedNotification() ?? Data()
        onPhaseChange?(.connected)
        // The client listed an empty catalog offline. The app sends its own `list_changed` only
        // from routing and readiness paths, so the helper sends one to make the client re-list.
        try await candidate.proxy.runAcceptedBridge(
            initialStdinBytes: lateInitialized + unreadStdinBytes,
            initialSocketBytes: Self.toolsListChangedNotification + candidate.bufferedServerFrames
        )
    }

    // MARK: Connected session and reconnects

    /// Runs `firstConnection`, then reconnects after each failure the ledger allows, replaying the
    /// initialized session into the new connection.
    private func runConnectionLoop(
        schedule: MCPProxyRetrySchedule,
        firstConnection: () async throws -> Never
    ) async throws -> Never {
        var schedule = schedule
        var connectionCount = 0
        while true {
            do {
                connectionCount += 1
                if connectionCount == 1 {
                    try await firstConnection()
                } else {
                    try await reconnect()
                }
            } catch {
                let failure = Self.runtimeError(for: error, logMessage: logMessage)
                // Reconnection is legal while the ledger can prove there is no pending transaction,
                // response in delivery, or unreplayable active work.
                let protocolActiveFailure = await client.bridgeLedger.recordConnectionFailure(
                    CLIProxyRuntimePolicy.failureReason(for: failure)
                )
                guard !protocolActiveFailure, CLIProxyRuntimePolicy.shouldRetry(after: failure) else {
                    throw failure
                }
                // A cancelled session's bridge can end as a socket failure; it is not a reason to retry.
                if Task.isCancelled {
                    throw CLIRuntimeError.hostDisconnected(.taskCancelled)
                }
                let delay = schedule.delayAfterFailure()
                logMessage(.warning, "Bootstrap connection lost (\(failure)). Retrying in \(String(format: "%.1f", delay))s (attempt \(schedule.attempt), elapsed \(String(format: "%.0f", schedule.elapsedSinceFirstFailure()))s)")
                try await waitForRetry(delay)
            }
        }
    }

    private func reconnect() async throws -> Never {
        let replayInitialization = await client.bridgeLedger.snapshot().hasForwardedProtocolFrame
        if replayInitialization {
            switch await client.initializeReplayState.replayPlan() {
            case .success:
                break
            case let .failure(reason):
                let terminalReason = await client.bridgeLedger.terminalizeConnection(reason: reason.terminalReason)
                throw CLIRuntimeError.connectionFailed(
                    underlying: JSONRPCBridgeLedgerError.terminal(terminalReason)
                )
            }
        }

        _ = try await client.bridgeLedger.beginConnection()
        let proxy = await makeProxy(replayInitializationOnStart: replayInitialization)
        try await runConnection(proxy) {
            try await proxy.start()
        }
    }

    /// Runs one accepted connection and closes its socket when it ends. A connection that ends
    /// without an error ended because the client closed stdin.
    private func runConnection(
        _ proxy: BootstrapSocketProxy,
        _ body: () async throws -> Void
    ) async throws -> Never {
        do {
            try await body()
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
        // The bridge also ends without an error when its task is cancelled.
        if Task.isCancelled {
            throw CLIRuntimeError.hostDisconnected(.taskCancelled)
        }
        logMessage(.debug, "Bootstrap socket proxy stopped cleanly")
        throw CLIRuntimeError.hostDisconnected(.stdinClosed)
    }

    // MARK: Helpers

    private func makeProxy(replayInitializationOnStart: Bool) async -> BootstrapSocketProxy {
        // The handshake names the client by its MCP clientInfo.name once the helper has seen an
        // initialize, else by the parent process.
        let clientName = await client.identityCache.currentName()
            ?? CLIEventLogger.detectClientName()
            ?? ProcessInfo.processInfo.processName
        return BootstrapSocketProxy(
            socketURL: socketURL,
            sessionToken: client.sessionToken,
            clientName: clientName,
            identityCache: client.identityCache,
            initializeReplayState: client.initializeReplayState,
            outstandingRequestReplayState: client.outstandingRequestReplayState,
            replayInitializationOnStart: replayInitializationOnStart,
            bridgeLedger: client.bridgeLedger,
            faultRule: faultRule,
            stdinFD: stdinFD,
            stdoutFD: stdoutFD,
            stderrFD: stderrFD
        )
    }

    private func waitForRetry(_ delay: TimeInterval) async throws {
        do {
            try await retryWait(delay)
        } catch {
            throw CLIRuntimeError.hostDisconnected(.taskCancelled)
        }
    }

    /// The client already received an initialize result, so when the app refuses the session its
    /// reason goes to stderr here, as well as into the terminal record through the error.
    private func reportRefusal(_ ending: CLIRuntimeError) {
        guard case let .connectionFailed(underlying) = ending,
              case let .initializeReplayRejected(_, message) = underlying as? SocketProxyError
        else {
            return
        }
        let line = "RepoPrompt MCP: \(MCPAppConnectionMessages.sessionRefused(appMessage: message, identity: identity))\n"
        BestEffortStderrWriter.writeNonBlocking(Data(line.utf8), to: stderrFD)
    }
}
