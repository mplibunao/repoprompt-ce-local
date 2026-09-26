import Foundation
import RepoPromptDomainRuntime

/// Exact-object-bound capabilities used by the terminal settlement spine.
///
/// This value carries no concrete app session class and performs no lookup by
/// `tabID`. The app host partially applies its exact session at the
/// run/settlement edge, while the terminal barrier operates only on this
/// capability surface and `AgentRunAttemptLifecycle`. Attachment finalization
/// is expressed in provider-neutral domain command vocabulary; the bound app
/// hook remains the attachment persistence authority that applies it.
@MainActor
struct AgentRunTerminalSessionBinding {
    struct Hooks {
        let flushPendingAssistantDelta: @MainActor () -> Void
        let finalizeStreamingItems: @MainActor () -> Void
        let finalizePendingToolCalls: @MainActor (AgentSessionRunState) -> Void
        let finalizeNonCodexTurnUsage: @MainActor () -> Void
        let cancelPendingInteractions: @MainActor (_ reviewReason: String) -> Void
        let finalizeAttachments: @MainActor (UUID?, DomainAgentRunAttachmentTurnDisposition) -> Void
        let setAgentRunInactive: @MainActor () -> Void
        let prepareTerminalPublication: @MainActor () -> Void
        let makeTerminalPublicationEnvelope: @MainActor (
            AgentRunOwnership,
            AgentSessionRunState,
            UUID?,
            DomainAgentRunSnapshot.FailureReason?
        ) -> AgentRunTerminalPublicationEnvelope?
        let updateBindings: @MainActor () -> Void
        let notifyAgentTurnComplete: @MainActor () -> Void
        let scheduleSave: @MainActor () -> Void
        let publishTerminalCommit: @MainActor (
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult
        /// Admits the queued follow-up this commit will start, before its publication suspends, so
        /// a start arriving meanwhile is refused. Returns `nil` when the session is not free.
        let admitQueuedFollowUp: @MainActor () -> AgentRunStartupTicket?
        /// Starts a queued follow-up, under the admission taken for it if there is one.
        let startFollowUpRun: @MainActor (AgentQueuedInstruction, AgentRunStartupTicket?) -> Void
        /// Hands queued follow-ups that will not start back to the user: their text returns to the
        /// composer, and their transcript items and estimates go.
        let returnQueuedFollowUpsToComposer: @MainActor () -> Void
    }

    let tabID: UUID
    let lifecycle: AgentRunAttemptLifecycle
    let hooks: Hooks

    private let ownershipValidator: @MainActor (AgentRunOwnership, UUID?) -> Bool
    private let providerDrainGenerationProvider: @MainActor () -> UInt64
    private let terminalTurnIDProvider: @MainActor () -> UUID?
    private let queuedFollowUpProvider: @MainActor () -> AgentQueuedInstruction?
    private let followUpPendingSetter: @MainActor (Bool) -> Void
    private let firstQueuedFollowUpRemover: @MainActor () -> AgentQueuedInstruction?
    private let errorAppender: @MainActor (String) -> Void
    private let activeStateFinisher: @MainActor (AgentRunOwnership, AgentSessionRunState, String) -> Void
    private let processRunIdentityRetainer: @MainActor (UUID, UUID) -> Void
    private let sourceItemsRevisionProvider: @MainActor () -> Int
    private let assistantDeltaFlushGenerationProvider: @MainActor () -> UInt64
    private let latestFailureTextProvider: @MainActor () -> String?

    init(
        tabID: UUID,
        lifecycle: AgentRunAttemptLifecycle,
        hooks: Hooks,
        validatesOwnership: @escaping @MainActor (AgentRunOwnership, UUID?) -> Bool,
        providerDrainGeneration: @escaping @MainActor () -> UInt64,
        terminalTurnID: @escaping @MainActor () -> UUID?,
        queuedFollowUp: @escaping @MainActor () -> AgentQueuedInstruction?,
        setFollowUpPending: @escaping @MainActor (Bool) -> Void,
        removeFirstQueuedFollowUp: @escaping @MainActor () -> AgentQueuedInstruction?,
        appendError: @escaping @MainActor (String) -> Void,
        finishActiveState: @escaping @MainActor (AgentRunOwnership, AgentSessionRunState, String) -> Void,
        retainProcessRunIdentity: @escaping @MainActor (UUID, UUID) -> Void,
        sourceItemsRevision: @escaping @MainActor () -> Int,
        assistantDeltaFlushGeneration: @escaping @MainActor () -> UInt64,
        latestFailureText: @escaping @MainActor () -> String?
    ) {
        self.tabID = tabID
        self.lifecycle = lifecycle
        self.hooks = hooks
        ownershipValidator = validatesOwnership
        providerDrainGenerationProvider = providerDrainGeneration
        terminalTurnIDProvider = terminalTurnID
        queuedFollowUpProvider = queuedFollowUp
        followUpPendingSetter = setFollowUpPending
        firstQueuedFollowUpRemover = removeFirstQueuedFollowUp
        errorAppender = appendError
        activeStateFinisher = finishActiveState
        processRunIdentityRetainer = retainProcessRunIdentity
        sourceItemsRevisionProvider = sourceItemsRevision
        assistantDeltaFlushGenerationProvider = assistantDeltaFlushGeneration
        latestFailureTextProvider = latestFailureText
    }

    func validatesOwnership(_ ownership: AgentRunOwnership, expectedRunID: UUID?) -> Bool {
        ownershipValidator(ownership, expectedRunID)
    }

    var providerDrainGeneration: UInt64 {
        providerDrainGenerationProvider()
    }

    var terminalTurnID: UUID? {
        terminalTurnIDProvider()
    }

    var queuedFollowUp: AgentQueuedInstruction? {
        queuedFollowUpProvider()
    }

    func setFollowUpPending(_ pending: Bool) {
        followUpPendingSetter(pending)
    }

    @discardableResult
    func removeFirstQueuedFollowUp() -> AgentQueuedInstruction? {
        firstQueuedFollowUpRemover()
    }

    func appendError(_ text: String) {
        errorAppender(text)
    }

    func finishActiveState(
        ownership: AgentRunOwnership,
        terminalState: AgentSessionRunState,
        source: String
    ) {
        activeStateFinisher(ownership, terminalState, source)
    }

    func retainProcessRunIdentity(_ runID: UUID, terminalTurnID: UUID) {
        processRunIdentityRetainer(runID, terminalTurnID)
    }

    var sourceItemsRevision: Int {
        sourceItemsRevisionProvider()
    }

    var assistantDeltaFlushGeneration: UInt64 {
        assistantDeltaFlushGenerationProvider()
    }

    var latestFailureText: String? {
        latestFailureTextProvider()
    }
}
