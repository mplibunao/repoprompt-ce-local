import Foundation

@MainActor
final class CodexIntegratedAgentModeRunner {
    private let readinessRequirement: AgentModeViewModel.MCPServerReadinessRequirement
    private let codexCoordinator: CodexAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

    init(
        readinessRequirement: @escaping AgentModeViewModel.MCPServerReadinessRequirement,
        codexCoordinator: CodexAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier
    ) {
        self.readinessRequirement = readinessRequirement
        self.codexCoordinator = codexCoordinator
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        fallbackContext: AgentTabSession.CodexFallbackSubmissionContext?
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        let ownership: AgentRunOwnership
        let createdOwnership: Bool
        if let activeOwnership = session.activeRunOwnership {
            ownership = activeOwnership
            createdOwnership = false
        } else {
            ownership = session.beginRunAttempt(source: "codex")
            createdOwnership = true
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        }
        let attachmentReservationID = hooks.attachments.reserveAttachmentsForTurn(attachments, session)
        let startupTicket = createdOwnership ? session.unresolvedStartupTicket.flatMap { ticket in
            ticket.ownership == ownership ? ticket : nil
        } : nil
        let agentTaskOwnerToken = UUID()

        let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session] in
            guard let self, let session else {
                return .cancelled
            }
            defer { session.clearAgentTask(ownedBy: agentTaskOwnerToken) }
            #if DEBUG || EDIT_FLOW_PERF
                let codexTurnMCPServerEnableState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable)
            #endif
            let readinessError: Error?
            do {
                try await readinessRequirement()
                readinessError = nil
            } catch {
                readinessError = error
            }
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable, codexTurnMCPServerEnableState)
            #endif
            let execution = await CodexIntegratedRunExecutionAdapter.execute {
                // Readiness is shared and may outlive this start's cancellation or supersession;
                // a start that no longer owns the session must not begin native setup.
                if Task.isCancelled
                    || readinessError is CancellationError
                    || startupTicket.map({ !session.isStartupTicketCurrent($0) }) == true
                {
                    self.hooks.attachments.finalizeAttachmentsForTurn(session, attachmentReservationID, .restoreToPending)
                    return .cancelled
                }
                // The run a submission joined can finish during readiness and a successor take the
                // session; everything past this point would act on that successor, so a stale
                // submission gives back only its own attachments.
                guard session.isCurrentRunAttemptForCurrentBinding(ownership) else {
                    self.hooks.attachments.finalizeAttachmentsForTurn(session, attachmentReservationID, .restoreToPending)
                    return .stale(reason: "run attempt changed during readiness")
                }
                if let readinessError {
                    return await self.rejectBeforeNativeSetup(
                        .readiness(readinessError, phase: .windowCatalog),
                        session: session,
                        ownership: ownership,
                        createdOwnership: createdOwnership,
                        attachmentReservationID: attachmentReservationID
                    )
                }
                let outcome = await self.codexCoordinator.sendCodexNativeMessage(
                    session: session,
                    text: initialMessageForRun,
                    attachments: attachments,
                    fallbackContext: fallbackContext,
                    attachmentReservationID: attachmentReservationID,
                    terminalizeRejectedSend: createdOwnership
                )
                // Explicit cancellation can terminalize the original run before its
                // suspended send observes CancellationError. Preserve the caller-level
                // cancellation signal when there is no active successor to protect.
                if case .stale = outcome, Task.isCancelled, !session.runState.isActive {
                    return .cancelled
                }
                return outcome
            }
            let outcome = execution.nativeOutcome
            // Handoff bookkeeping belongs to the attempt that sent it: a stale outcome must not
            // clear a pending handoff a newer attempt now owns.
            if outcome.didSend || session.activeRunOwnership == nil || session.activeRunOwnership == ownership {
                hooks.providerInput.recordPendingHandoffSendOutcome(session, outcome.didSend)
            }
            if execution.didStartProviderRun {
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            } else if createdOwnership, execution.shouldReleaseCreatedOwnership {
                await settleRejectedInitialAttemptIfUnsettled(
                    outcome: outcome,
                    session: session,
                    ownership: ownership,
                    attachmentReservationID: attachmentReservationID
                )
            }
            return outcome
        }
        session.installAgentTask(Task {
            await withTaskCancellationHandler {
                _ = await sendTask.value
            } onCancel: {
                sendTask.cancel()
            }
        }, ownerToken: agentTaskOwnerToken)
        return await sendTask.value
    }

    /// The first readiness check failed before any native setup. A new initial attempt this
    /// runner owns settles as failed with the precise cause; a submission into an active run is
    /// rejected without terminating that run.
    private func rejectBeforeNativeSetup(
        _ failure: CodexAgentModeCoordinator.CodexStartupFailure,
        session: AgentTabSession,
        ownership: AgentRunOwnership,
        createdOwnership: Bool,
        attachmentReservationID: UUID?
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        if createdOwnership {
            await codexCoordinator.failCodexStartupBeforeNativeSetup(
                failure,
                session: session,
                ownership: ownership,
                attachmentReservationID: attachmentReservationID
            )
        } else {
            hooks.attachments.finalizeAttachmentsForTurn(session, attachmentReservationID, .restoreToPending)
            session.appendItem(AgentChatItem.error(failure.message, sequenceIndex: session.nextSequenceIndex))
        }
        return .failed(message: failure.message)
    }

    /// A rejected initial attempt is normally settled by the coordinator. One that is somehow
    /// still current and uncommitted fails with the send's own message, so it cannot linger as a
    /// run nobody settles; cancelled and superseded attempts only release their ownership.
    private func settleRejectedInitialAttemptIfUnsettled(
        outcome: CodexAgentModeCoordinator.NativeSendOutcome,
        session: AgentTabSession,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?
    ) async {
        let source = switch outcome {
        case .cancelled: "codex.sendCancelled"
        case .stale: "codex.sendStale"
        default: "codex.sendRejected"
        }
        if case let .failed(message) = outcome,
           session.isCurrentRunAttemptForCurrentBinding(ownership),
           !session.runLifecycle.terminalCommitInProgress
        {
            await terminalCommitBarrier.commit(.init(
                binding: hooks.bindTerminalSession(session),
                ownership: ownership,
                expectedRunID: session.runID,
                terminalState: .failed,
                source: source,
                errorText: message,
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .restoreToPending,
                finalizeNonCodexUsage: false,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                providerDrainGeneration: session.providerTerminalDrainGeneration,
                providerBuffersAreDrained: { [codexCoordinator] in
                    codexCoordinator.codexTerminalBuffersAreDrained(session)
                }
            ))
            return
        }
        session.endRunAttempt(ifCurrent: ownership, source: source)
    }
}
