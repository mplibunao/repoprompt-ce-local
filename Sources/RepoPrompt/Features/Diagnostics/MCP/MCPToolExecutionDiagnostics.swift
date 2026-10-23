import Foundation
import OSLog
import RepoPromptShared

struct MCPToolExecutionTraceEvent: Equatable, CustomStringConvertible {
    enum Phase: String {
        case contractSelected = "execution_contract_selected"
        case started = "execution_started"
        case handlerCompleted = "execution_handler_completed"
        case handlerPhaseTransition = "execution_handler_phase_transition"
        case deadlineExpired = "execution_deadline_expired"
        case cancellationRequested = "execution_cancellation_requested"
        case settledDuringGrace = "execution_settled_during_grace"
        case cleanupGraceExpired = "execution_cleanup_grace_expired"
        case detachedForSettlement = "execution_detached_for_settlement"
        case detachedSettled = "execution_detached_settled"
        /// A provider whose caller cancelled it, or whose connection was force-disconnected,
        /// finally returned. `settlement` says which.
        case lateSettled = "execution_late_settled"
        case connectionForceDisconnectRequested = "connection_force_disconnect_requested"

        var isAlwaysEmitted: Bool {
            switch self {
            case .deadlineExpired, .cancellationRequested, .settledDuringGrace,
                 .cleanupGraceExpired, .detachedForSettlement, .detachedSettled,
                 .lateSettled, .connectionForceDisconnectRequested:
                true
            case .contractSelected, .started, .handlerCompleted, .handlerPhaseTransition:
                false
            }
        }

        /// Escalations a person reading the unified log should notice first.
        var isEscalation: Bool {
            switch self {
            case .cleanupGraceExpired, .detachedForSettlement, .connectionForceDisconnectRequested:
                true
            case .contractSelected, .started, .handlerCompleted, .handlerPhaseTransition,
                 .deadlineExpired, .cancellationRequested, .settledDuringGrace,
                 .detachedSettled, .lateSettled:
                false
            }
        }
    }

    let toolName: String
    let operationIdentity: MCPToolOperationIdentity
    let connectionID: UUID
    let invocationID: UUID
    let runID: UUID?
    let requestIdentity: MCPRequestTimelineIdentity?
    let contractKind: MCPToolExecutionContract.Kind
    let executionDeadlineSeconds: Double?
    let cleanupGraceSeconds: Double?
    let cleanupDisposition: MCPToolExecutionCleanupDisposition?
    let phase: Phase
    let elapsedMilliseconds: Double
    let cancellationRequested: Bool?
    let cancellationOutcome: String?
    let cancellationOrigin: MCPToolExecutionCancellationOrigin?
    let settlement: String?
    let graceOutcome: String?
    let escalationReason: String?
    let handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?
    let handlerPhaseAgeMilliseconds: Double?
    let windowID: Int?
    /// The window's settlement-registry population when the event was built; set only for
    /// always-emitted events of window-scoped calls.
    let blockingProviderCount: Int?
    let releasedProviderCount: Int?
    /// Set for protected mutations: what the call may claim was applied when the event was built.
    let mutationState: DomainProtectedMutationState?
    let mutationOperationID: String?

    init(
        toolName: String,
        operationIdentity: MCPToolOperationIdentity,
        connectionID: UUID,
        invocationID: UUID,
        runID: UUID?,
        requestIdentity: MCPRequestTimelineIdentity? = nil,
        contractKind: MCPToolExecutionContract.Kind,
        executionDeadlineSeconds: Double?,
        cleanupGraceSeconds: Double?,
        cleanupDisposition: MCPToolExecutionCleanupDisposition?,
        phase: Phase,
        elapsedMilliseconds: Double,
        cancellationRequested: Bool?,
        cancellationOutcome: String?,
        cancellationOrigin: MCPToolExecutionCancellationOrigin?,
        settlement: String?,
        graceOutcome: String?,
        escalationReason: String?,
        handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?,
        handlerPhaseAgeMilliseconds: Double?,
        windowID: Int? = nil,
        blockingProviderCount: Int? = nil,
        releasedProviderCount: Int? = nil,
        mutationState: DomainProtectedMutationState? = nil,
        mutationOperationID: String? = nil
    ) {
        self.toolName = toolName
        self.operationIdentity = operationIdentity
        self.connectionID = connectionID
        self.invocationID = invocationID
        self.runID = runID
        self.requestIdentity = requestIdentity
        self.contractKind = contractKind
        self.executionDeadlineSeconds = executionDeadlineSeconds
        self.cleanupGraceSeconds = cleanupGraceSeconds
        self.cleanupDisposition = cleanupDisposition
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
        self.cancellationRequested = cancellationRequested
        self.cancellationOutcome = cancellationOutcome
        self.cancellationOrigin = cancellationOrigin
        self.settlement = settlement
        self.graceOutcome = graceOutcome
        self.escalationReason = escalationReason
        self.handlerPhase = handlerPhase
        self.handlerPhaseAgeMilliseconds = handlerPhaseAgeMilliseconds
        self.windowID = windowID
        self.blockingProviderCount = blockingProviderCount
        self.releasedProviderCount = releasedProviderCount
        self.mutationState = mutationState
        self.mutationOperationID = mutationOperationID
    }

    var isAlwaysEmitted: Bool {
        phase.isAlwaysEmitted
    }

    var description: String {
        var fields = [
            "phase=\(phase.rawValue)",
            "tool=\(toolName)",
            "operation=\(operationIdentity.normalizedOperation)",
            "connection_id=\(connectionID.uuidString)",
            "invocation_id=\(invocationID.uuidString)",
            "contract=\(contractKind.rawValue)",
            "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds))"
        ]
        if let runID { fields.append("run_id=\(runID.uuidString)") }
        if let windowID { fields.append("window_id=\(windowID)") }
        if let requestIdentity {
            if let requestID = requestIdentity.jsonRPCRequestID {
                fields.append("request_id=\(Self.quotedClientValue("\(requestID)"))")
            }
            if let requestConnectionID = requestIdentity.connectionID {
                fields.append("request_connection_id=\(requestConnectionID)")
            }
            if let requestGeneration = requestIdentity.connectionGeneration {
                fields.append("request_generation=\(requestGeneration)")
            }
            if let requestOrdinal = requestIdentity.requestOrdinal {
                fields.append("request_ordinal=\(requestOrdinal)")
            }
        }
        if let executionDeadlineSeconds { fields.append("deadline_s=\(executionDeadlineSeconds)") }
        if let cleanupGraceSeconds { fields.append("grace_s=\(cleanupGraceSeconds)") }
        if let cleanupDisposition { fields.append("cleanup_disposition=\(cleanupDisposition.rawValue)") }
        if let cancellationRequested { fields.append("cancellation_requested=\(cancellationRequested)") }
        if let cancellationOutcome { fields.append("cancellation_outcome=\(cancellationOutcome)") }
        if let cancellationOrigin { fields.append("cancellation_origin=\(cancellationOrigin.rawValue)") }
        if let settlement { fields.append("settlement=\(settlement)") }
        if let graceOutcome { fields.append("grace_outcome=\(graceOutcome)") }
        if let escalationReason { fields.append("escalation_reason=\(escalationReason)") }
        if let handlerPhase {
            fields.append("handler_phase=\(handlerPhase.phase.rawValue)")
            fields.append("handler_phase_transition=\(handlerPhase.transition.rawValue)")
            fields.append("handler_phase_elapsed_ms=\(String(format: "%.3f", handlerPhase.elapsedMilliseconds))")
        }
        if let handlerPhaseAgeMilliseconds {
            fields.append("handler_phase_age_ms=\(String(format: "%.3f", handlerPhaseAgeMilliseconds))")
        }
        if let blockingProviderCount { fields.append("blocking_count=\(blockingProviderCount)") }
        if let releasedProviderCount { fields.append("released_count=\(releasedProviderCount)") }
        if let mutationState { fields.append("mutation_state=\(mutationState.rawValue)") }
        if let mutationOperationID { fields.append("operation_id=\(Self.quotedClientValue(mutationOperationID))") }
        return fields.joined(separator: " ")
    }

    /// Quotes a client-supplied value, escaping quotes, backslashes, and control characters and keeping
    /// at most 128 characters, so the value can't add fields to the line.
    static func quotedClientValue(_ value: String) -> String {
        let limit = 128
        var escaped = ""
        for scalar in value.unicodeScalars.prefix(limit) {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value)
                || scalar.value == 0x2028 || scalar.value == 0x2029:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        if value.unicodeScalars.count > limit {
            escaped += "..."
        }
        return "\"\(escaped)\""
    }
}

enum MCPToolExecutionTracer {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var testSink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?
    }

    private static let state = State()
    /// Release builds lose the stderr line when the app is launched normally, so escalations also
    /// go to the unified log. Every field is a tool name, phase, identifier, count, or duration, and
    /// the client-supplied request and operation IDs are quoted and escaped.
    private static let log = Logger(subsystem: "com.repoprompt.mcp", category: "ToolExecution")

    static var successTracingEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["REPOPROMPT_MCP_EXECUTION_TRACE"] == "1"
                || UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #else
            UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #endif
    }

    static func emit(_ event: MCPToolExecutionTraceEvent) {
        // Release-safe concurrency evidence ingestion (counts and bounded latency
        // aggregates only; see MCPToolConcurrencyEvidenceRecorder).
        MCPToolConcurrencyEvidenceRecorder.shared.recordExecutionTraceEvent(event)
        let sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?
        state.lock.lock()
        sink = state.testSink
        state.lock.unlock()
        sink?(event)

        if event.isAlwaysEmitted {
            log.log(
                level: event.phase.isEscalation ? .error : .default,
                "\(event.description, privacy: .public)"
            )
        }
        guard event.isAlwaysEmitted || successTracingEnabled else { return }
        guard let data = "[MCPToolExecution] \(event)\n".data(using: .utf8) else { return }
        state.lock.lock()
        defer { state.lock.unlock() }
        // Best-effort raw write; FileHandle.write raises an uncatchable ObjC
        // exception if stderr's pipe is already closed.
        BestEffortStderrWriter.write(data)
    }

    #if DEBUG
        static func setTestSink(_ sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?) {
            state.lock.lock()
            state.testSink = sink
            state.lock.unlock()
        }
    #endif
}

/// Logs settlement-cap rejections to the unified log. Every rejection in one blockage carries the
/// same oldest blocker and released count, so the first is logged and repeats at most once per
/// `repeatInterval`, with the number suppressed since the last line.
final class MCPSettlementCapRejectionLog: @unchecked Sendable {
    struct Rejection {
        let windowID: Int
        let toolName: String
        let invocationID: UUID
        let connectionID: UUID
        let busyContext: MCPCodeStructureSettlementRegistry.BusyContext
    }

    static let shared = MCPSettlementCapRejectionLog()

    private struct Entry {
        var lastLogged: ContinuousClock.Instant
        var suppressed: Int
    }

    private static let log = Logger(subsystem: "com.repoprompt.mcp", category: "ToolExecution")
    private let repeatInterval: Duration
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(repeatInterval: Duration = .seconds(30)) {
        self.repeatInterval = repeatInterval
    }

    func record(_ rejection: Rejection) {
        let context = rejection.busyContext
        let key = "\(rejection.windowID)|\(context.originInvocationID.uuidString)|\(context.releasedProviderCount)"
        let now = clock.now
        let suppressed: Int? = lock.withLock {
            entries = entries.filter { now - $0.value.lastLogged < repeatInterval * 2 }
            if var entry = entries[key], now - entry.lastLogged < repeatInterval {
                entry.suppressed += 1
                entries[key] = entry
                return nil
            }
            let suppressed = entries[key]?.suppressed ?? 0
            entries[key] = Entry(lastLogged: now, suppressed: 0)
            return suppressed
        }
        guard let suppressed else { return }
        let line = [
            "phase=settlement_cap_rejected",
            "window_id=\(rejection.windowID)",
            "tool=\(rejection.toolName)",
            "invocation_id=\(rejection.invocationID.uuidString)",
            "connection_id=\(rejection.connectionID.uuidString)",
            "origin_tool=\(context.originToolName)",
            "origin_invocation_id=\(context.originInvocationID.uuidString)",
            "origin_connection_id=\(context.originConnectionID.uuidString)",
            "origin_handler_phase=\(context.handlerPhase ?? "unreported")",
            "origin_blocking_age_ms=\(String(format: "%.3f", context.detachedAge.mcpMilliseconds))",
            "blocking_count=\(context.blockingProviderCount)",
            "released_count=\(context.releasedProviderCount)",
            "suppressed_since_last=\(suppressed)"
        ].joined(separator: " ")
        Self.log.error("[MCPToolExecution] \(line, privacy: .public)")
    }
}

extension Duration {
    var mcpSeconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    var mcpMilliseconds: Double {
        mcpSeconds * 1000
    }
}
