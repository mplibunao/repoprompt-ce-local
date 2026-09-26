import Foundation

/// One accepted start submitted while its session was inactive, tracked from acceptance until
/// the provider owns the run or the start is rejected, cancelled, or superseded.
///
/// The ticket is runtime-only and holds no authority over terminal status: settlement stays
/// with `AgentRunTerminalCommitBarrier`. It exists so accepted-but-undispatched work can be
/// identified and cancelled before provider dispatch, and so late startup work can recognize
/// that it no longer owns the session it captured.
///
/// A session holds at most one unresolved ticket, owned by the first inactive submission.
/// Later submissions made while it is unresolved keep their existing FIFO behavior. They only
/// register their tasks, and Codex followers their dispatch-gate tickets, so an explicit
/// cancellation of the head start can withdraw them too.
@MainActor
final class AgentRunStartupTicket {
    /// Lets a queued submission's task reach its own handle, so the task can become the head's
    /// task if the submission is promoted.
    final class DispatchTaskHandle {
        var task: Task<Void, Never>?
    }

    enum Phase: String, Equatable {
        case queued
        case preparing
        /// The start is inside the run service. `beginRunAttempt` binds ownership only in this
        /// phase, so an unrelated attempt that begins while the start is queued cannot claim it.
        case dispatching
        /// Codex accepted the first native dispatch, or another provider's runner took on
        /// lifecycle responsibility for the run.
        case accepted
        case rejected
        case cancelled
        case superseded

        var isResolved: Bool {
            switch self {
            case .queued, .preparing, .dispatching:
                false
            case .accepted, .rejected, .cancelled, .superseded:
                true
            }
        }
    }

    /// Session identity captured when the submission was accepted. The start stays valid only
    /// while the session still presents this identity.
    struct Capture: Equatable {
        let binding: AgentPersistentSessionBindingIdentity?
        let bindingTransitionGeneration: UInt64
        /// `nil` when the session had no MCP control at acceptance; activation checks then do
        /// not apply. The activation generation also covers registration replacement, which
        /// only happens inside the same activation.
        let mcpActivationID: UUID?
        let mcpActivationGeneration: UInt64
    }

    let startupID = UUID()
    /// Run identity reserved at acceptance, so a cancellation before any runner assigns an ID
    /// settles under this start rather than under the previous run's ID.
    let reservedRunID = UUID()
    private(set) var capture: Capture
    private(set) var phase: Phase = .queued
    private(set) var optimisticUserItemID: UUID?
    private(set) var ownership: AgentRunOwnership?
    /// The run ID this start settled on when ownership was bound: `reservedRunID`, or the ID of
    /// a warm Codex controller the start adopted.
    private(set) var boundRunID: UUID?
    private(set) var task: Task<Void, Never>?
    private(set) var dispatchGateTicket: UInt64?
    private(set) var followerDispatchGateTickets: [UInt64] = []
    private var followerTasksByID: [UUID: Task<Void, Never>] = [:]
    /// Receives the submission a cancellation or supersession withdraws at the moment the ticket
    /// resolves, so its per-submission state goes before any other work can run.
    var onWithdrawal: ((_ submissionIDs: [UUID]) -> Void)?
    /// The follower promoted to head after this start resolved. It carries the queued work this
    /// ticket held, so work queued behind this start answers to it from then on.
    private(set) var successor: AgentRunStartupTicket?

    /// The ticket now heading the queue this start belonged to.
    var currentHead: AgentRunStartupTicket {
        successor?.currentHead ?? self
    }

    /// Tasks of queued followers that have not finished yet.
    var followerTasks: [Task<Void, Never>] {
        Array(followerTasksByID.values)
    }

    var isUnresolved: Bool {
        !phase.isResolved
    }

    var turnEpoch: AgentRunTurnEpoch? {
        ownership?.turnEpoch
    }

    init(capture: Capture) {
        self.capture = capture
    }

    func bindOptimisticUserItem(_ itemID: UUID) {
        guard optimisticUserItemID == nil else { return }
        optimisticUserItemID = itemID
    }

    /// Attaches the task currently carrying this start. A start deferred for hydration moves
    /// from its hydration task to its dispatch task, so the latest task replaces the earlier one.
    func attachTask(_ task: Task<Void, Never>, dispatchGateTicket: UInt64? = nil) {
        self.task = task
        if let dispatchGateTicket {
            attachDispatchGateTicket(dispatchGateTicket)
        }
        // A ticket invalidated before its task existed still has to stop that task.
        if phase.isResolved {
            task.cancel()
        }
    }

    func attachDispatchGateTicket(_ dispatchGateTicket: UInt64) {
        self.dispatchGateTicket = dispatchGateTicket
    }

    func registerFollower(dispatchGateTicket: UInt64) {
        guard isUnresolved else { return }
        followerDispatchGateTickets.append(dispatchGateTicket)
    }

    func registerFollower(task: Task<Void, Never>, id: UUID) {
        guard isUnresolved else { return }
        followerTasksByID[id] = task
    }

    /// A follower registers with the head it was queued behind; if that head handed its queue to
    /// a successor, the follower is tracked there instead.
    func followerFinished(id: UUID) {
        followerTasksByID.removeValue(forKey: id)
        successor?.followerFinished(id: id)
    }

    /// Hands the queue behind this resolved start to `successor`, the follower promoted to head.
    /// The promoted follower leaves the queue, since its task becomes the successor's own; the
    /// followers still behind it, with their tasks and later dispatch-gate tickets, move over so
    /// cancelling the successor withdraws them too.
    func transferQueuedWork(
        to successor: AgentRunStartupTicket,
        promotedFollowerID: UUID,
        promotedDispatchGateTicket: UInt64
    ) {
        guard successor !== self else { return }
        // A queue only moves forward. A target already linked into this queue's chain, either way,
        // would close a loop that `currentHead` never leaves.
        guard !successor.chainReaches(self), !chainReaches(successor) else {
            assertionFailure("A startup queue cannot be handed back into its own chain")
            return
        }
        self.successor = successor
        followerTasksByID.removeValue(forKey: promotedFollowerID)
        for followerTicket in followerDispatchGateTickets where followerTicket > promotedDispatchGateTicket {
            successor.registerFollower(dispatchGateTicket: followerTicket)
        }
        followerDispatchGateTickets.removeAll()
        for (id, task) in followerTasksByID {
            successor.registerFollower(task: task, id: id)
        }
        followerTasksByID.removeAll()
    }

    private func chainReaches(_ ticket: AgentRunStartupTicket) -> Bool {
        var node: AgentRunStartupTicket? = self
        while let current = node {
            if current === ticket { return true }
            node = current.successor
        }
        return false
    }

    func markPreparing() {
        guard phase == .queued else { return }
        phase = .preparing
    }

    func markDispatching() {
        guard phase == .queued || phase == .preparing else { return }
        phase = .dispatching
    }

    /// Binds the attempt this start created or adopted. Bind-once: a second attempt can never
    /// become the owner of the same start. Cancellation may bind after resolving the ticket,
    /// when it claims ownership for a start that never reached a runner.
    @discardableResult
    func bindOwnership(_ ownership: AgentRunOwnership, runID: UUID?) -> Bool {
        guard self.ownership == nil else { return false }
        self.ownership = ownership
        boundRunID = runID
        return true
    }

    /// Resolves the ticket exactly once. Later resolutions are ignored, so a late outcome of
    /// cancelled work cannot relabel it.
    @discardableResult
    func resolve(_ resolution: Phase) -> Bool {
        precondition(resolution.isResolved, "AgentRunStartupTicket.resolve requires a resolved phase")
        guard isUnresolved else { return false }
        phase = resolution
        if resolution == .cancelled || resolution == .superseded {
            onWithdrawal?([optimisticUserItemID].compactMap(\.self))
        }
        return true
    }

    /// A start on a session without a persistent binding installs that binding itself. That one
    /// transition belongs to this start and must not invalidate it.
    func adoptBindingInstalledByStartup(
        binding: AgentPersistentSessionBindingIdentity?,
        bindingTransitionGeneration: UInt64
    ) {
        guard capture.binding == nil else { return }
        capture = Capture(
            binding: binding,
            bindingTransitionGeneration: bindingTransitionGeneration,
            mcpActivationID: capture.mcpActivationID,
            mcpActivationGeneration: capture.mcpActivationGeneration
        )
    }
}
