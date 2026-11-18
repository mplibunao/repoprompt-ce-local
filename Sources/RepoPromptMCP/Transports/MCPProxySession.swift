import Foundation
import Logging
import MCP
import RepoPromptShared

// MARK: - Proxy Session

/// The helper's retry delays for reaching its app: every 0.5 s plus jitter for the first 60 s after
/// the first failure, while the app may be restarting, then exponential backoff from 1 s to 30 s,
/// with no overall limit. A session keeps one schedule from its first failure on.
private struct MCPProxyRetrySchedule: Sendable {
    /// How long attempts stay frequent after the first failure, because the app may be restarting.
    static let aggressivePhaseDuration: TimeInterval = 60

    private(set) var attempt = 0
    private var firstFailureAt: Date?

    /// Records one failed attempt and returns how long to wait before the next one.
    mutating func delayAfterFailure(now: Date = Date()) -> TimeInterval {
        let aggressiveDelay = 0.5
        let backoffBase = 1.0
        let maxDelay = 30.0

        attempt += 1
        let firstFailureAt = firstFailureAt ?? now
        self.firstFailureAt = firstFailureAt
        guard now.timeIntervalSince(firstFailureAt) >= Self.aggressivePhaseDuration else {
            return aggressiveDelay + Double.random(in: 0 ... 0.1)
        }
        let backoffAttempt = attempt - Int(Self.aggressivePhaseDuration / aggressiveDelay)
        let expDelay = min(maxDelay, backoffBase * pow(2.0, Double(max(0, backoffAttempt - 1))))
        return min(maxDelay, expDelay + Double.random(in: 0 ... (0.2 * expDelay)))
    }
}

/// What the offline loop and the attachment worker share while the helper answers the client
/// itself. The loop reads the condition for each answer and checks for a handoff and the end of
/// the outage grace at each frame boundary; the worker waits for the client's initialize result
/// before its first attempt and requests the handoff when it has an admitted candidate or a
/// terminal failure.
private final class MCPProxyAttachmentState: @unchecked Sendable {
    private let lock = NSLock()
    private var condition: MCPAppConnectionMessages.Condition
    private var initializeResultDelivered: Bool
    private var initializeResultWaiter: CheckedContinuation<Void, Never>?
    private var initializeResultWaitCancelled = false
    private var handoffRequested = false
    private var graceEnded = false

    init(condition: MCPAppConnectionMessages.Condition, initializeResultDelivered: Bool) {
        self.condition = condition
        self.initializeResultDelivered = initializeResultDelivered
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

    /// Records that the grace for requests held at the disconnect ran out.
    func endGrace() {
        lock.withLock { graceEnded = true }
    }

    /// True once, at the first check after the grace ran out.
    func takeGraceEnd() -> Bool {
        lock.withLock {
            defer { graceEnded = false }
            return graceEnded
        }
    }
}

/// One client's MCP session through the helper, from the first connection attempt to its end.
///
/// The app is tried first, before stdin is read. When it can't be reached, the offline loop owns
/// stdin and stdout and answers the client with `MCPOfflineResponder`, while one attachment worker
/// keeps trying the app on `MCPProxyRetrySchedule`. Once the app admits the session's replayed
/// `initialize`, the loop stops at a frame boundary and the bridge takes over with the unread
/// bytes. When the app goes away after that and the ledger allows a reconnect, the bridge hands
/// the client back to the offline loop the same way, and the same worker reconnects.
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
        /// The app went away mid-session. The offline loop answers the client while the worker
        /// reconnects.
        case outage
    }

    typealias RetryWait = @Sendable (TimeInterval) async throws -> Void
    typealias PhaseObserver = @Sendable (Phase) -> Void

    /// How long requests the app received but never answered wait for it to return after it goes
    /// away mid-session, before the client gets an error for each: the retry schedule's window for
    /// an app that is restarting.
    static let outageGracePeriod = MCPProxyRetrySchedule.aggressivePhaseDuration

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

    /// How the offline loop takes the client over.
    private struct OfflineEntry {
        /// True when the app went away mid-session, false when it wasn't reachable at startup.
        let isOutage: Bool
        let condition: MCPAppConnectionMessages.Condition
        /// Client bytes the previous owner of stdin read but did not consume.
        let unreadStdinBytes: Data
    }

    /// Where the client's handshake stands when the offline loop takes it over.
    private enum Handshake: Equatable {
        /// The client hasn't sent an `initialize` the session can replay.
        case notStarted
        /// The app went away before answering the client's `initialize`.
        case awaitingResult(initializeFrame: Data)
        /// The client has its initialize result.
        case initialized
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
    private let graceWait: RetryWait
    private let onPhaseChange: PhaseObserver?

    /// Runs one proxy session until it ends.
    ///
    /// - Parameters:
    ///   - identity: Which app the helper serves, for the offline answers and messages.
    ///   - serverVersion: The `serverInfo.version` of an offline initialize result.
    ///   - logMessage: Receives the session's log lines at the level it emits them.
    ///   - retryWait: Waits between connection attempts. It must throw when cancelled.
    ///   - graceWait: Waits out `outageGracePeriod` after the app goes away mid-session with
    ///     requests unanswered. It must throw when cancelled.
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
        graceWait: @escaping RetryWait,
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
            graceWait: graceWait,
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
        // One schedule for the whole session, from its first failure on.
        var schedule = MCPProxyRetrySchedule()
        var entry: OfflineEntry
        switch try await connectInitially(schedule: &schedule) {
        case let .accepted(proxy):
            onPhaseChange?(.connected)
            let interruption = try await runConnection(proxy) {
                try await proxy.runAcceptedBridge(initialStdinBytes: Data(), initialSocketBytes: Data())
            }
            entry = try await outageEntry(after: interruption)
        case let .offline(condition):
            entry = OfflineEntry(isOutage: false, condition: condition, unreadStdinBytes: Data())
        }
        while true {
            let (candidate, unreadStdinBytes) = try await runOffline(entry, schedule: schedule)
            schedule = candidate.schedule
            let interruption = try await runConnection(candidate.proxy) {
                try await attach(candidate, unreadStdinBytes: unreadStdinBytes)
            }
            entry = try await outageEntry(after: interruption)
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
            let proxy = await makeProxy()
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

    // MARK: Offline phase and attachment

    /// Decides, through the ledger as before the offline loop existed, whether the session survives
    /// its app going away mid-session.
    ///
    /// - Returns: How the offline loop takes the client over while the worker reconnects.
    private func outageEntry(after interruption: MCPProxyBridgeInterruption) async throws -> OfflineEntry {
        let failure = Self.runtimeError(for: interruption.underlying, logMessage: logMessage)
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
        logMessage(.warning, "Bootstrap connection lost (\(failure)). Answering the client locally while reconnecting")
        return OfflineEntry(isOutage: true, condition: .unavailable, unreadStdinBytes: interruption.unreadStdinBytes)
    }

    /// Answers the client locally until the attachment worker has an admitted candidate.
    ///
    /// - Returns: The candidate, and the stdin bytes the offline loop read but did not consume.
    private func runOffline(
        _ entry: OfflineEntry,
        schedule: MCPProxyRetrySchedule
    ) async throws -> (AttachmentCandidate, Data) {
        let handshake = try await handshake(for: entry)
        onPhaseChange?(entry.isOutage ? .outage : .offlineStartup)
        let attachment = MCPProxyAttachmentState(
            condition: entry.condition,
            initializeResultDelivered: handshake == .initialized
        )
        let worker = Task {
            await runAttachmentWorker(attachment: attachment, schedule: schedule)
        }
        // Requests the app received but never answered wait for it to return, for a while.
        let heldRequests = entry.isOutage ? await client.outstandingRequestReplayState.replayFrames() : []
        let grace: Task<Void, Never>? = if !heldRequests.isEmpty {
            Task { [graceWait] in
                do {
                    try await graceWait(Self.outageGracePeriod)
                    attachment.endGrace()
                } catch {}
            }
        } else {
            nil
        }

        let loopResult: Result<MCPProxyStdinPump.Result, Swift.Error>
        do {
            loopResult = try await .success(withTaskCancellationHandler {
                try await runOfflineLoop(
                    attachment: attachment,
                    handshake: handshake,
                    unreadStdinBytes: entry.unreadStdinBytes
                )
            } onCancel: {
                worker.cancel()
                grace?.cancel()
            })
        } catch {
            loopResult = .failure(error)
        }
        grace?.cancel()
        await grace?.value

        // The loop hands off only after the worker has published its outcome.
        if case let .success(.handoff(unreadBytes)) = loopResult, !Task.isCancelled {
            switch await worker.value {
            case let .ready(candidate):
                return (candidate, unreadBytes)
            case let .failed(failure):
                // A replay the app can't resume also ends the ledger, so the terminal record
                // names the replay's reason rather than a generic ledger failure.
                if case let .connectionFailed(underlying) = failure,
                   case let .terminal(reason) = underlying as? JSONRPCBridgeLedgerError
                {
                    await client.bridgeLedger.terminalizeConnection(reason: reason)
                }
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

    /// Where the client's handshake stands, from what the session recorded for replay.
    private func handshake(for entry: OfflineEntry) async throws -> Handshake {
        guard entry.isOutage else { return .notStarted }
        switch await client.initializeReplayState.replayPlan() {
        case let .success(plan):
            return plan.initializeResultFingerprint == nil
                ? .awaitingResult(initializeFrame: plan.initializeFrame)
                : .initialized
        case let .failure(reason):
            // A session that exchanged frames with the app without a replayable handshake can't
            // be resumed in another connection.
            guard await client.bridgeLedger.snapshot().hasForwardedProtocolFrame else {
                return .notStarted
            }
            let terminalReason = await client.bridgeLedger.terminalizeConnection(reason: reason.terminalReason)
            throw CLIRuntimeError.connectionFailed(underlying: JSONRPCBridgeLedgerError.terminal(terminalReason))
        }
    }

    /// Answers each client frame before reading the next, so no local request is outstanding at a
    /// frame boundary and the handoff never leaves work behind in the ledger. Requests held since
    /// the app went away stay active until the app returns or the grace ends.
    private func runOfflineLoop(
        attachment: MCPProxyAttachmentState,
        handshake: Handshake,
        unreadStdinBytes: Data
    ) async throws -> MCPProxyStdinPump.Result {
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
        // The remembered list changes only while the bridge relays, so it stays the same while the loop runs.
        let appToolList = await client.outstandingRequestReplayState.rememberedToolListResult()
        var responder = MCPOfflineResponder(
            identity: identity,
            serverVersion: serverVersion,
            initializeAnswered: handshake == .initialized,
            appToolList: appToolList
        )
        if case let .awaitingResult(initializeFrame) = handshake {
            // The app went away before answering the client's initialize. Answering it here, as at
            // startup, gives the worker a handshake it can replay; held for the app instead, it
            // would hold the worker too, which never starts before the client has its result.
            let outcome = try responder.respond(
                to: initializeFrame,
                connectionMessage: attachment.connectionMessage(identity: identity)
            )
            if let response = outcome.response {
                try await deliverLocalFrame(response, attachment: attachment)
            }
            // A rejected initialize stays the session's cached handshake, which the app can never
            // admit, so the worker would never start. End the session instead of answering forever.
            guard attachment.hasDeliveredInitializeResult else {
                let reason = await ledger.terminalizeConnection(
                    reason: MCPInitializeReplayUnavailableReason.missingInitializeResponseFingerprint.terminalReason
                )
                throw CLIRuntimeError.connectionFailed(underlying: JSONRPCBridgeLedgerError.terminal(reason))
            }
        }
        // A list is remembered only once the app has relayed one, so this runs only in an outage.
        // The client may hold part of the catalog from the app's last answer; announcing a change
        // makes it re-list from the helper. It goes out before any answer to a held request, which
        // waits for a frame boundary.
        if appToolList != nil {
            try await deliverLocalFrame(Self.toolsListChangedNotification, attachment: attachment)
        }
        return try await MCPProxyStdinPump.run(
            stdinFD: stdinFD,
            initialBytes: unreadStdinBytes,
            ledger: ledger,
            identityCache: client.identityCache,
            shouldHandOff: {
                // Held requests wait for the app only until the grace ends, even when the worker
                // became ready since the last boundary.
                if attachment.takeGraceEnd() {
                    try await answerHeldRequests(attachment: attachment)
                }
                return attachment.isHandoffRequested
            }
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
            // A held request the client cancels leaves replay too. Only the cancellations the
            // ledger committed are applied, one at a time, so the replay cache never reads a frame
            // differently from the ledger, and nothing in the frame is recorded for replay.
            for message in prepared.messages
                where message.kind == .notification && message.method == CancelledNotification.name
            {
                guard let cancelledID = message.id, cancelledID != .null else {
                    continue
                }
                await client.outstandingRequestReplayState.recordClientCancellation(for: cancelledID)
            }
            if let response = outcome.response {
                try await deliverLocalFrame(response, attachment: attachment)
            }
        }
    }

    /// Answers each request the app received but never answered, once the grace for its return
    /// ran out. The delivered answer takes the request out of replay, so it never runs later.
    private func answerHeldRequests(attachment: MCPProxyAttachmentState) async throws {
        let replayState = client.outstandingRequestReplayState
        let appToolList = await replayState.rememberedToolListResult()
        for frame in await replayState.replayFrames() {
            guard let response = try MCPOfflineResponder.unavailableResponse(
                toForwardedRequest: frame,
                connectionMessage: attachment.connectionMessage(identity: identity),
                appToolList: appToolList
            ) else {
                continue
            }
            try await deliverLocalFrame(response, attachment: attachment)
        }
    }

    /// Writes a frame the helper sends on the app's behalf to the client, through the ledger as
    /// the bridge writes the app's frames.
    private func deliverLocalFrame(_ frame: Data, attachment: MCPProxyAttachmentState) async throws {
        let stdoutFD = stdoutFD
        let prepared = try await JSONRPCBridgeDelivery.forward(
            frame: frame,
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

    /// Makes every connection attempt while the offline loop answers the client, at startup and
    /// after an outage. A failed candidate is not a failure of the client's connection, so attempts
    /// leave the ledger alone.
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
                let proxy = await makeProxy()
                do {
                    try await proxy.connectAndAccept()
                    attachment.setCondition(.awaitingApproval)
                    onPhaseChange?(.awaitingAdmission)
                    let bufferedServerFrames = try await proxy.replayInitialize()
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
    /// The app receives, in order, the client's late `initialized` notification, the requests held
    /// since it went away, and then the client's unread bytes through the bridge. A candidate that
    /// fails before its bridge starts takes the same way back to the offline loop as one that fails
    /// inside it.
    private func attach(_ candidate: AttachmentCandidate, unreadStdinBytes: Data) async throws {
        // Every local request was answered before the next frame was read, so nothing is pending
        // or unreplayable; `beginConnection` ends the session if that ever fails to hold.
        _ = try await client.bridgeLedger.beginConnection()
        do {
            try await candidate.proxy.writeLateInitializedNotification()
            try await candidate.proxy.replayOutstandingRequests()
        } catch where CLIProxyRuntimePolicy.isRecoverableAppSideFailure(error) {
            throw MCPProxyBridgeInterruption(underlying: error, unreadStdinBytes: unreadStdinBytes)
        }
        onPhaseChange?(.connected)
        // The client's catalog is empty or stale. The app sends its own `list_changed` only from
        // routing and readiness paths, so the helper sends one to make the client re-list.
        try await candidate.proxy.runAcceptedBridge(
            initialStdinBytes: unreadStdinBytes,
            initialSocketBytes: Self.toolsListChangedNotification + candidate.bufferedServerFrames
        )
    }

    // MARK: Connected session

    /// Runs one accepted connection and closes its socket when it ends.
    ///
    /// - Returns: The interruption, when the app side failed in a way the session may recover from.
    /// - Throws: Any other failure. A connection that ends without one ended because the client
    ///   closed stdin.
    private func runConnection(
        _ proxy: BootstrapSocketProxy,
        _ body: () async throws -> Void
    ) async throws -> MCPProxyBridgeInterruption {
        await client.outstandingRequestReplayState.beginAttachment()
        do {
            try await body()
        } catch let interruption as MCPProxyBridgeInterruption {
            await proxy.stop()
            return interruption
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

    private func makeProxy() async -> BootstrapSocketProxy {
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
