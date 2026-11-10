import Foundation

/// Tracks which Agent Mode input each Claude Code result answers on one process's transport.
///
/// The controller actor owns and mutates this value. Matching by identity turns on only after
/// `system/init` reports a Claude Code version that echoes input UUIDs on its output and results;
/// until then the controller settles results in send order with `takeFirst()`, and the matching
/// operations (`observeActivity`, `resolve`, and the interrupt methods) don't apply. A resolved
/// input leaves this value at once, so a completion the controller defers until the idle signal
/// keeps the targets resolved here even when another input is sent in between.
struct ClaudeNativeTurnCorrelation {
    enum CorrelationError: Error {
        /// An identity field has the wrong type or a malformed UUID, a plural list exceeds
        /// `maxGroupSize`, or the singular identity contradicts the plural list.
        case invalidInputIdentity
        /// A result can't be matched to the host inputs it has to answer.
        case missingAnswerIdentity
    }

    struct Resolution {
        /// The execution the result closed. When it closed none, this is a fresh ID that matches
        /// no execution or interrupt.
        let executionID: UUID
        /// Host inputs the result answers, in the order the result lists them.
        let inputIDs: [UUID]
        /// The closed execution's ID when Claude Code started it without a known host input. It's
        /// the ID `providerTurnID` reported while the execution ran.
        let providerTurnID: UUID?
        /// Whether an interrupt requested during this execution applies to it.
        let interrupted: Bool
    }

    /// Whose run a main-thread message's output belongs to.
    enum OutputOwner {
        /// An outstanding host input.
        case host
        /// A turn Claude Code started itself that hasn't picked up a host input.
        case provider
    }

    /// The first Claude Code version that echoes input UUIDs, when it also reports `lifecycleCapability`.
    static let minimumMatchingVersion = [2, 1, 292]
    static let lifecycleCapability = "msg_lifecycle_v1"
    /// Checked before duplicates are removed, so the work per result stays bounded.
    static let maxGroupSize = 64

    private struct Execution {
        let id: UUID
        /// Claude Code started this execution without a known host input, for example to report
        /// a finished background task.
        let providerInitiated: Bool
        var inputIDs: Set<UUID>
        /// Inputs Claude Code queued itself. They identify a provider-initiated execution but
        /// never settle host input.
        var observedForeignInputIDs: Set<UUID> = []
    }

    private struct Interrupt {
        let token: UUID
        var executionID: UUID?
        /// Set when the interrupt can no longer bind to an execution observed after it.
        var cancellationDisarmed = false
    }

    private(set) var enabled = false
    /// Host inputs in send order, compacted from `head`; `outstanding` decides membership.
    private var order: [UUID] = []
    private var head = 0
    private var outstanding: Set<UUID> = []
    private var execution: Execution?
    /// Unstamped deltas belong to the last main-thread message, which may differ from the
    /// execution's owner after a foreign message.
    private var messageHasHostOwner = false
    private var interrupt: Interrupt?

    var hasOutstanding: Bool {
        !outstanding.isEmpty
    }

    /// Whether output from the current main-thread message belongs to an outstanding host input.
    var ownsOutput: Bool {
        guard messageHasHostOwner, let execution else { return false }
        return !execution.inputIDs.isDisjoint(with: outstanding)
    }

    /// Whether output from the current main-thread message belongs to a turn Claude Code started
    /// itself. Once that turn picks up a host input, its output follows the host input instead.
    var ownsProviderOutput: Bool {
        guard let execution else { return false }
        return execution.providerInitiated && execution.inputIDs.isEmpty
    }

    /// The owner of output from the current main-thread message, or nil when no run owns it.
    var outputOwner: OutputOwner? {
        if ownsOutput {
            return .host
        }
        return ownsProviderOutput ? .provider : nil
    }

    /// The current execution's ID when Claude Code started it without a known host input. It stays
    /// the same if the execution picks up a host input.
    var providerTurnID: UUID? {
        guard let execution, execution.providerInitiated else { return nil }
        return execution.id
    }

    /// Reads a `system/init` payload. Once matching is on it stays on for this transport.
    mutating func observeInit(_ payload: [String: Any]) {
        guard !enabled,
              let version = payload["claude_code_version"] as? String,
              let capabilities = payload["capabilities"] as? [String],
              capabilities.contains(Self.lifecycleCapability),
              let components = Self.versionComponents(version)
        else { return }
        enabled = !components.lexicographicallyPrecedes(Self.minimumMatchingVersion)
    }

    /// Inputs registered before `system/init` turns matching on are answered by identity afterward.
    mutating func register(_ id: UUID) {
        outstanding.insert(id)
        order.append(id)
    }

    /// Records main-thread execution evidence and returns whose run the frame's output belongs to.
    /// Every frame's output belongs to the host while matching is off.
    @discardableResult
    mutating func observeActivity(_ payload: [String: Any]) throws -> OutputOwner? {
        guard enabled else { return .host }
        let ids = try Self.inputIDs(payload)
        if let ids {
            let known = Set(ids).intersection(outstanding)
            guard !known.isEmpty else {
                // A foreign identity can start or identify provider work. It can't re-identify a
                // running host execution or bind that execution's interrupt.
                if execution == nil {
                    execution = Execution(id: UUID(), providerInitiated: true, inputIDs: [])
                }
                if execution?.providerInitiated == true, execution?.inputIDs.isEmpty == true {
                    execution?.observedForeignInputIDs.formUnion(ids)
                    bindInterruptToObservedExecution()
                }
                messageHasHostOwner = false
                return outputOwner
            }
            messageHasHostOwner = true
            if execution == nil {
                execution = Execution(id: UUID(), providerInitiated: false, inputIDs: known)
            } else {
                // Claude Code can pick up queued inputs into the execution that is already running.
                execution?.inputIDs.formUnion(known)
            }
        } else if execution == nil {
            execution = Execution(id: UUID(), providerInitiated: true, inputIDs: [])
        }
        bindInterruptToObservedExecution()
        return outputOwner
    }

    /// Starts tracking an interrupt request. An accepted input isn't execution evidence, so an
    /// interrupt requested before any activity binds to the first execution observed after it,
    /// unless its acknowledgement or timeout arrives first.
    mutating func beginInterrupt() -> UUID {
        let token = UUID()
        interrupt = Interrupt(token: token, executionID: execution?.id)
        return token
    }

    /// False once a result has closed the execution, or a newer interrupt has replaced this one.
    func isInterruptPending(_ token: UUID) -> Bool {
        interrupt?.token == token
    }

    /// An acknowledgement that arrives before any execution evidence keeps the interrupt open, so
    /// an abort report can still retire it, but it can no longer cancel work that starts later.
    mutating func acknowledgeInterrupt(_ token: UUID) {
        if interrupt?.token == token, interrupt?.executionID == nil {
            interrupt?.cancellationDisarmed = true
        }
    }

    /// A timeout or failed request doesn't prove Claude Code ignored the interrupt, so the token
    /// stays open for an abort report but cancels no execution.
    mutating func abandonInterrupt(_ token: UUID) {
        guard interrupt?.token == token else { return }
        interrupt?.executionID = nil
        interrupt?.cancellationDisarmed = true
    }

    /// Matches an outer `result` to the host inputs it answers. Validation finishes before any
    /// state changes, so a thrown error leaves every input outstanding.
    mutating func resolve(_ payload: [String: Any]) throws -> Resolution {
        let ids = try Self.inputIDs(payload) ?? []
        // A session-level error before any execution evidence answers no particular input; failing
        // the transport is the only way to stop accepted inputs from waiting forever. A pending
        // interrupt explains the same result as the aborted turn.
        if ids.isEmpty, execution == nil, hasOutstanding, payload["is_error"] as? Bool == true, interrupt == nil {
            throw CorrelationError.missingAnswerIdentity
        }
        let matched = ids.filter { outstanding.contains($0) }
        if let execution, ids.isEmpty || !matched.isEmpty {
            // An answer has to name every host input already observed in the execution it closes.
            let answering = execution.inputIDs.intersection(outstanding)
            guard answering.isSubset(of: matched) else { throw CorrelationError.missingAnswerIdentity }
        }
        // A provider-initiated execution closes on its observed foreign identity; an unrelated
        // late result can't close a different execution.
        let answersProviderExecution = execution.map {
            $0.providerInitiated && $0.inputIDs.isEmpty && !$0.observedForeignInputIDs.isDisjoint(with: ids)
        } ?? false
        let closesExecution = ids.isEmpty || !matched.isEmpty || answersProviderExecution
        let executionID = closesExecution ? (execution?.id ?? matched.first ?? UUID()) : UUID()
        if closesExecution {
            bindInterrupt(to: executionID)
        }
        let interrupted = interrupt?.executionID == executionID
        let closedProviderTurnID = closesExecution ? providerTurnID : nil
        if closesExecution {
            execution = nil
            messageHasHostOwner = false
            interrupt = nil
        }
        for id in matched {
            outstanding.remove(id)
        }
        compact()
        return Resolution(
            executionID: executionID,
            inputIDs: matched,
            providerTurnID: closedProviderTurnID,
            interrupted: interrupted
        )
    }

    /// Positional settlement: removes and returns the oldest outstanding input.
    mutating func takeFirst() -> UUID? {
        guard let id = order[head...].first(where: { outstanding.contains($0) }) else { return nil }
        outstanding.remove(id)
        compact()
        return id
    }

    /// For transport retirement only: returns the unresolved inputs in send order, then the running
    /// provider execution's ID, and resets everything, including matching and any interrupt, for
    /// the next process.
    mutating func drain() -> [UUID] {
        let ids = order[head...].filter { outstanding.contains($0) } + (providerTurnID.map { [$0] } ?? [])
        self = Self()
        return ids
    }

    /// Reads `user_message_uuid` and `user_message_uuids`. Returns nil when the payload carries no
    /// identity: both fields missing or null, or an empty plural with no singular.
    static func inputIDs(_ payload: [String: Any]) throws -> [UUID]? {
        let singular: UUID?
        if let raw = payload["user_message_uuid"], !(raw is NSNull) {
            guard let text = raw as? String, let id = UUID(uuidString: text) else {
                throw CorrelationError.invalidInputIdentity
            }
            singular = id
        } else {
            singular = nil
        }
        guard let raw = payload["user_message_uuids"], !(raw is NSNull) else {
            return singular.map { [$0] }
        }
        guard let values = raw as? [String], values.count <= maxGroupSize else {
            throw CorrelationError.invalidInputIdentity
        }
        if values.isEmpty {
            guard singular == nil else { throw CorrelationError.invalidInputIdentity }
            return nil
        }
        var ids: [UUID] = []
        var seen: Set<UUID> = []
        for value in values {
            guard let id = UUID(uuidString: value) else { throw CorrelationError.invalidInputIdentity }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        // The singular field names the last input of the group, so it can't stand in for a
        // different or malformed plural list.
        if let singular, singular != ids.last {
            throw CorrelationError.invalidInputIdentity
        }
        return ids
    }

    private mutating func bindInterruptToObservedExecution() {
        bindInterrupt(to: execution?.id)
    }

    private mutating func bindInterrupt(to executionID: UUID?) {
        if interrupt?.executionID == nil, interrupt?.cancellationDisarmed == false {
            interrupt?.executionID = executionID
        }
    }

    private mutating func compact() {
        while head < order.count, !outstanding.contains(order[head]) {
            head += 1
        }
        if head > 4, head >= order.count / 2 {
            order.removeFirst(head)
            head = 0
        }
    }

    /// Accepts exactly three components of ASCII digits, such as `2.1.292`.
    private static func versionComponents(_ version: String) -> [Int]? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == minimumMatchingVersion.count else { return nil }
        var parts: [Int] = []
        for component in components {
            guard component.allSatisfy({ $0.isASCII && $0.isNumber }), let part = Int(component) else {
                return nil
            }
            parts.append(part)
        }
        return parts
    }
}
