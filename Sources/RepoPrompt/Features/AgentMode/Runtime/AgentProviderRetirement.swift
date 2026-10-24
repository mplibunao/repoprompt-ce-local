import Foundation
import os

/// Why a live session's provider runtime is being retired.
enum AgentProviderRetirementReason {
    /// `agent_manage stop_session` on a session with no active run. It ignores the idle setting and
    /// ends the process's background work.
    case explicitStop
    /// An idle timer whose deadline passed.
    case automaticIdle(anchor: ContinuousClock.Instant)

    var isAutomatic: Bool {
        if case .automaticIdle = self { return true }
        return false
    }

    var logValue: String {
        isAutomatic ? "automatic_idle" : "explicit_stop"
    }
}

/// Work that keeps a live session's provider runtime attached. The raw value is the wire value
/// `agent_manage stop_session` reports and the value idle-retirement logs print.
enum AgentProviderRetirementBlocker: String {
    case terminalCommit = "terminal_commit"
    case activeRun = "active_run"
    case pendingStart = "pending_start"
    case interaction
    case queuedInstructions = "queued_instructions"
    case bindingTransition = "binding_transition"
    case mcpWork = "mcp_work"
    /// Claude's idle timer only: a resume transfer is pending and no controller is attached.
    case resumeTransfer = "resume_transfer"
    case missingProviderSessionID = "missing_provider_session_id"
    case providerBusy = "provider_busy"
    /// Claude's idle timer only: a live Claude background task, under the keep-alive cap. The timer
    /// logs it when it keeps the process; `retireProviderIfIdle` never returns it.
    case backgroundTasks = "background_tasks"
    /// Automatic retirement only: the ACP runtime can't reload a saved conversation.
    case resumeUnsupported = "resume_unsupported"
}

/// What `AgentModeViewModel.retireProviderIfIdle` did.
enum AgentProviderRetirementResult {
    /// A retirement of this session's runtime is under way, newly started or joined. The task
    /// finishes when the provider's shutdown of the captured runtime and its captured cleanup finish.
    case retiring(Task<Void, Never>)
    /// No runtime is attached and no retirement of it is registered.
    case alreadyGone
    /// Nothing was retired.
    case blocked(AgentProviderRetirementBlocker)
    /// The session, or the runtime the check captured, stopped being current before retirement began.
    case superseded
}

/// The clock idle retirement reads and sleeps on. Production uses `ContinuousClock`, which keeps
/// counting while the Mac sleeps.
struct AgentProviderIdleClock {
    let now: @MainActor () -> ContinuousClock.Instant
    let sleepUntil: @MainActor (_ deadline: ContinuousClock.Instant) async throws -> Void

    static var continuous: AgentProviderIdleClock {
        AgentProviderIdleClock(
            now: { ContinuousClock.now },
            sleepUntil: { deadline in try await Task.sleep(until: deadline, clock: .continuous) }
        )
    }
}

enum AgentProviderRetirement {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ProviderRetirement")

    /// One retirement decision or completion. Carries identifiers only, never conversation content.
    static func log(
        _ event: String,
        provider: String,
        tabID: UUID,
        runID: UUID?,
        controllerID: ObjectIdentifier?,
        reason: AgentProviderRetirementReason
    ) {
        let controller = controllerID.map { String(describing: $0) } ?? "none"
        logger.notice(
            "Provider retirement \(event, privacy: .public) provider=\(provider, privacy: .public) tab=\(tabID.uuidString, privacy: .public) run=\(runID?.uuidString ?? "none", privacy: .public) controller=\(controller, privacy: .public) reason=\(reason.logValue, privacy: .public)"
        )
    }

    /// The busy checks every provider shares. Provider probes and queues are checked by each
    /// provider. Both steering queues are read: only the selected provider fills its own.
    @MainActor
    static func sharedBlocker(
        for session: AgentTabSession,
        hasActiveMCPTools: (UUID) -> Bool,
        hasActiveChildAgentRunWaits: (UUID) -> Bool
    ) -> AgentProviderRetirementBlocker? {
        if session.terminalCommitInProgress {
            return .terminalCommit
        }
        if session.activeRunOwnership != nil || session.runState.isActive || session.agentTask != nil {
            return .activeRun
        }
        if session.unresolvedStartupTicket != nil
            || session.mcpPendingStartOwner != nil
            || session.mcpFollowUpRunPending
            || session.isComposerSubmissionInFlight
            || session.mcpEpochPreparation != nil
        {
            return .pendingStart
        }
        if session.hasBindingBlockingInteraction {
            return .interaction
        }
        if !session.pendingInstructions.isEmpty
            || session.pendingSupersedingTurnCompletions > 0
            || !session.pendingClaudeSteeringInstructions.isEmpty
            || session.claudeSteeringFlushTask != nil
            || !session.pendingACPSteeringInstructions.isEmpty
            || session.acpSteeringFlushTask != nil
        {
            return .queuedInstructions
        }
        if session.bindingTransitionInProgress
            || session.worktreeBindingTransitionInProgress
            || session.isChangingExecutionLocation
            || session.isPreparingInitialWorktree
        {
            return .bindingTransition
        }
        if let runID = session.runID,
           hasActiveMCPTools(runID) || hasActiveChildAgentRunWaits(runID)
        {
            return .mcpWork
        }
        return nil
    }

    /// Waits up to `timeout` for `task` and reports whether it finished. The wait never cancels
    /// `task`, and a caller cancelled while waiting returns at once with the task still running.
    @MainActor
    static func wait(
        for task: Task<Void, Never>,
        timeout: Duration,
        clock: AgentProviderIdleClock
    ) async -> Bool {
        let finished = WaitOutcome()
        let deadline = clock.now() + timeout
        let sleeper = Task { @MainActor in try await clock.sleepUntil(deadline) }
        // Owns nothing: it ends when the retirement does and only wakes the sleeper early.
        Task { @MainActor in
            await task.value
            finished.value = true
            sleeper.cancel()
        }
        // `onCancel` runs off the main actor, so it only cancels the sleeper and reads no state.
        await withTaskCancellationHandler {
            _ = try? await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        return finished.value
    }

    /// A Boolean the observer task sets; a captured `var` can't be mutated from a task closure.
    @MainActor
    private final class WaitOutcome {
        var value = false
    }
}
