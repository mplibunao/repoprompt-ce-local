import Foundation

@MainActor
final class ClaudeIntegratedAgentModeRunner {
    private enum ConsumeEventsOutcome {
        case completed
        case cancelled
        case failed(errorText: String?, shouldShutdownSession: Bool)
    }

    /// Claude's native stream reports terminal cancellation and failure as values,
    /// while the shared transient execution core accepts those classifications as
    /// thrown errors. This marker is intentionally runner-local: the coordinator
    /// and native controller remain the authorities for the underlying terminal
    /// event and its provider-specific metadata.
    private struct NativeTerminalFailure: Error {}

    private let claudeCoordinator: ClaudeAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

    #if DEBUG
        private func reasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][Runner] \(message())"
            print(line)
            ClaudeReasoningDebugLog.append(line)
        }
    #else
        private func reasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private func reasoningDebugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    init(
        claudeCoordinator: ClaudeAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier
    ) {
        self.claudeCoordinator = claudeCoordinator
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        submissionID: UUID?,
        makeLease: (_ runID: UUID) -> MCPBootstrapLease
    ) async {
        let attachmentReservationID = hooks.attachments.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage, let submissionID {
            session.replaceQueuedUserInputTokenEstimate(
                forSubmission: submissionID,
                tokens: hooks.usage.estimateRuntimeTokens(initialMessageForRun)
            )
        }
        hooks.usage.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun, submissionID)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let runID = session.claudeController.flatMap { _ in
            AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        } ?? AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)
        let ownership = session.beginRunAttempt(source: "claudeNative")
        session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
            {
                switch terminalState {
                case .failed:
                    await lease.failAndRelease()
                case .cancelled:
                    await lease.cancelAndCleanup()
                default:
                    break
                }
            }
        }
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)

        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    await self.handleAcquireFailure(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }

                await self.claudeCoordinator.ensureClaudeToolTrackingIfNeeded(
                    for: session,
                    runID: runID
                )

                let providerName = session.selectedAgent.rawValue
                var didSendToProvider = false
                var nativeFailureMetadata: (errorText: String?, shouldShutdownSession: Bool)?
                let report = await DomainAgentRunExecutionCore.execute(
                    failureText: { _ in nativeFailureMetadata?.errorText ?? "" }
                ) {
                    await lease.providerInitializationStarted(provider: providerName)
                    let sendOutcome = await self.claudeCoordinator.sendClaudeNativeMessage(
                        session: session,
                        text: initialMessageForRun,
                        attachments: attachments,
                        intent: .runAttempt(ownership: ownership, runID: runID)
                    )
                    let providerInitializationOutcome = switch sendOutcome {
                    case .sent:
                        "ready"
                    case .failed:
                        Task.isCancelled ? "cancelled" : "failed"
                    case .superseded:
                        "superseded"
                    }
                    await lease.providerInitializationCompleted(
                        provider: providerName,
                        outcome: providerInitializationOutcome
                    )

                    switch sendOutcome {
                    case .sent:
                        didSendToProvider = true
                        self.hooks.providerInput.recordPendingHandoffSendOutcome(session, true)
                    case .failed:
                        nativeFailureMetadata = (errorText: nil, shouldShutdownSession: false)
                        throw NativeTerminalFailure()
                    case .superseded:
                        return .superseded
                    }

                    self.hooks.attachments.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
                    self.hooks.attachments.markAttachmentsConsumed(session, attachmentReservationID)
                    _ = await lease.releaseWhenRouted()

                    guard let events = await self.claudeCoordinator.events(for: session) else {
                        nativeFailureMetadata = (
                            errorText: "Claude native events stream not available.",
                            shouldShutdownSession: false
                        )
                        throw NativeTerminalFailure()
                    }

                    session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
                    switch await self.consumeEvents(
                        events,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID
                    ) {
                    case .completed:
                        return .completed(assistantText: nil)
                    case .cancelled:
                        throw CancellationError()
                    case let .failed(errorText, shouldShutdownSession):
                        nativeFailureMetadata = (errorText, shouldShutdownSession)
                        throw NativeTerminalFailure()
                    }
                }

                switch report.result {
                case .superseded:
                    if self.claudeCoordinator.runAttemptIsCurrent(
                        ownership,
                        runID: runID,
                        for: session
                    ) {
                        self.hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
                        let revision = await self.finalize(
                            session: session,
                            runID: runID,
                            ownership: ownership,
                            attachmentReservationID: attachmentReservationID,
                            terminalState: .cancelled,
                            errorText: nil,
                            notifyTurnComplete: false
                        )
                        if revision == nil {
                            await lease.cancelAndCleanup()
                        }
                    } else {
                        await lease.cancelAndCleanup()
                    }
                case let .terminal(outcome):
                    let terminalState: AgentSessionRunState = switch outcome.kind {
                    case .completed: .completed
                    case .cancelled: .cancelled
                    case .failed: .failed
                    }
                    if !didSendToProvider {
                        self.hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
                    }
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: terminalState,
                        errorText: outcome.kind == .failed ? nativeFailureMetadata?.errorText : nil,
                        notifyTurnComplete: outcome.kind == .completed,
                        shouldShutdownSession: outcome.kind == .failed
                            && nativeFailureMetadata?.shouldShutdownSession == true
                    )
                }
            } onCancel: {}
        }
    }

    private func consumeEvents(
        _ events: AsyncStream<NativeAgentRuntimeEvent>,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        var exitedDueToAttemptMismatch = false
        // Keyed answers can settle this run's unprotected inputs across separate events. Keep
        // their strongest outcome until the run's last unprotected input is answered.
        var unprotectedTurnStatus: ClaudeNativeProcessSessionController.TurnStatus = .completed

        eventLoop: for await event in events {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                exitedDueToAttemptMismatch = true
                break eventLoop
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }

            switch event {
            case let .stream(result):
                #if DEBUG
                    if ClaudeReasoningExtractionFeature.isEnabled, result.type == "reasoning" {
                        let text = result.reasoning ?? result.text ?? ""
                        reasoningDebug("stream reasoning run=\(runID.uuidString) attempt=\(runAttemptID.uuidString) tab=\(session.tabID.uuidString) len=\(text.count) snippet=\(reasoningDebugSnippet(text))")
                    }
                #endif
                await hooks.transcript.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .runtimeInit(status):
                // Persist provider session ID as soon as it becomes available from
                // runtime init events (initialize response or system/init stream).
                if let newSessionID = status.sessionID,
                   !newSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   newSessionID != session.providerSessionID
                {
                    session.providerSessionID = newSessionID
                    session.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
                        provider: session.selectedAgent.rawValue,
                        explicit: nil,
                        providerSessionID: newSessionID,
                        codexConversationID: session.codexConversationID,
                        codexRolloutPath: session.codexRolloutPath
                    )
                    session.isDirty = true
                    hooks.persistence.scheduleSave(session)
                }
                if status.isRepoPromptServerFailed {
                    return .failed(
                        errorText: "RepoPrompt MCP failed to initialize for Claude (session \(status.sessionID ?? "unknown")).",
                        shouldShutdownSession: true
                    )
                }
            case let .approvalRequest(request):
                if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                    session.recordRunProgress(ownership: ownership, kind: .interaction, stage: .waitingForInteraction)
                }
                session.pendingApproval = request
                session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                session.setRunningStatus(nil, source: nil)
                session.runState = .waitingForApproval
                hooks.bindingObservation.updateBindings(session)
            case let .approvalCancelled(requestID):
                if session.pendingApproval?.requestID == .claudeControl(requestID) {
                    session.pendingApproval = nil
                    if session.runState == .waitingForApproval {
                        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                        session.setRunningStatus("Thinking…", source: .transport)
                        session.runState = .running
                    }
                    hooks.bindingObservation.updateBindings(session)
                }
            case .turnCompleted, .turnsCompleted:
                let turnIDs: [UUID]
                let turnStatus: ClaudeNativeProcessSessionController.TurnStatus
                let keyed: Bool
                switch event {
                case let .turnCompleted(turnID, status):
                    (turnIDs, turnStatus, keyed) = ([turnID], status, false)
                case let .turnsCompleted(groupIDs, status):
                    (turnIDs, turnStatus, keyed) = (groupIDs, status, true)
                default:
                    preconditionFailure("Expected a Claude turn completion")
                }
                guard let settlement = Self.settleCompletedTurnIDs(
                    turnIDs,
                    session: session,
                    waitForAllUnprotected: keyed
                ) else {
                    // Stale completion from a previous cancelled run attempt; ignore.
                    continue eventLoop
                }
                if settlement.answeredUnprotected {
                    switch (unprotectedTurnStatus, turnStatus) {
                    case (.failed, _), (_, .failed):
                        unprotectedTurnStatus = .failed
                    case (.cancelled, _), (_, .cancelled):
                        unprotectedTurnStatus = .cancelled
                    default:
                        unprotectedTurnStatus = .completed
                    }
                }
                if !settlement.terminal {
                    // Keep the run alive for the superseding or remaining turns, whatever a
                    // protected predecessor reported. Old interrupted turns can land as
                    // .cancelled, .failed, or even .completed after the superseding send is
                    // already in flight.
                    if !session.runState.isActive {
                        session.runState = .running
                    }
                    hooks.presentation.setAgentRunActive(session, true)
                    hooks.bindingObservation.updateBindings(session)
                    continue eventLoop
                }
                switch unprotectedTurnStatus {
                case .completed:
                    return .completed
                case .cancelled:
                    return .cancelled
                case .failed:
                    return .failed(errorText: nil, shouldShutdownSession: false)
                }
            case let .error(message):
                session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                session.setRunningStatus(nil, source: nil)
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    #if !DEBUG
                        // Suppress known non-actionable abort side-effect errors (e.g. JSON parse
                        // errors from killed tool processes) in release builds.
                        if Self.isKnownNonActionableStreamError(trimmed) {
                            continue eventLoop
                        }
                    #endif
                    let errorItem = AgentChatItem.error(trimmed, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(errorItem)
                    hooks.bindingObservation.updateBindings(session)
                    hooks.persistence.scheduleSave(session)
                }
            }
        }

        // If we exited because the attempt changed (cancel / new attempt)
        // or the task was cancelled, this is expected — not a stream failure.
        if exitedDueToAttemptMismatch || Task.isCancelled {
            return .cancelled
        }

        // The events stream ended without a terminal turnCompleted event while this
        // attempt was still active.  This means the stream was finished or the Claude
        // process exited unexpectedly.
        return .failed(
            errorText: "Claude events stream ended unexpectedly. The run may need to be restarted.",
            shouldShutdownSession: false
        )
    }

    /// Retires every matched input of one completion before deciding whether the run ends, so a
    /// grouped answer is a single boundary. Returns nil when the completion matches no expected
    /// input. The run ends once the completion answers an unprotected input and, for keyed
    /// answers, no other unprotected input is still expected; positional answers keep their
    /// first-unprotected boundary.
    static func settleCompletedTurnIDs(
        _ turnIDs: [UUID],
        session: AgentTabSession,
        waitForAllUnprotected: Bool
    ) -> (terminal: Bool, answeredUnprotected: Bool)? {
        let matched = Set(turnIDs).intersection(session.claudeExpectedTurnIDs)
        guard !matched.isEmpty else { return nil }
        let explicitlyProtected = matched.intersection(session.claudeSupersedingProtectedTurnIDs)
        // Protection recorded only as a count covers one predecessor.
        let unscopedProtectedCount = session.claudeSupersedingProtectedTurnIDs.isEmpty
            && session.pendingSupersedingTurnCompletions > 0 ? 1 : 0
        session.claudeExpectedTurnIDs.subtract(matched)
        session.claudeSupersedingProtectedTurnIDs.subtract(matched)
        session.pendingSupersedingTurnCompletions = max(
            0,
            session.pendingSupersedingTurnCompletions - explicitlyProtected.count - unscopedProtectedCount
        )
        let answeredUnprotected = matched.count > explicitlyProtected.count + unscopedProtectedCount
        let otherUnprotected = session.claudeExpectedTurnIDs.subtracting(session.claudeSupersedingProtectedTurnIDs)
        guard answeredUnprotected, !waitForAllUnprotected || otherUnprotected.isEmpty else {
            return (terminal: false, answeredUnprotected: answeredUnprotected)
        }
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        return (terminal: true, answeredUnprotected: true)
    }

    private func handleAcquireFailure(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?
    ) async {
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "claudeNative.acquireFailure",
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: false,
            postCommit: { [claudeCoordinator] in
                claudeCoordinator.armClaudeIdleTimer(for: session)
            }
        ))
    }

    @discardableResult
    private func finalize(
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownSession: Bool = false
    ) async -> AgentRunTerminalCommitRevision? {
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: terminalState,
            source: "claudeNative.finalize",
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: { [claudeCoordinator] in
                session.pendingSupersedingTurnCompletions = 0
                session.claudeSupersedingProtectedTurnIDs.removeAll()
                session.claudeExpectedTurnIDs.removeAll()
                guard shouldShutdownSession else { return nil }
                let oldController = claudeCoordinator.prepareClaudeCancelSync(session)
                return {
                    claudeCoordinator.beginClaudeResumeTransferIfNeeded(
                        for: session,
                        oldController: oldController
                    )
                    await claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                }
            },
            // Restarts the idle timer from this terminal, whatever its publication result.
            postCommit: { [claudeCoordinator] in
                claudeCoordinator.armClaudeIdleTimer(for: session)
            }
        ))
    }

    // MARK: - Error Filtering

    /// Returns `true` when the error message is a known non-actionable abort side
    /// effect (e.g. JSON parse errors from killed tool processes, MCP AbortErrors).
    /// These are suppressed in release builds to avoid alarming users.
    private static func isKnownNonActionableStreamError(_ message: String) -> Bool {
        ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(message)
    }
}
