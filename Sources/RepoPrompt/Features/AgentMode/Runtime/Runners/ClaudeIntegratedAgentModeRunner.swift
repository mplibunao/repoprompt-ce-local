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

    /// Adopts a turn Claude Code started by itself as a new attempt on the existing process run. It
    /// sends nothing and adds no user row. Returns false when the turn is no longer waiting in
    /// `listener`'s handoff or the inbox can't be reserved.
    func adoptProviderTurn(
        session: AgentTabSession,
        listener: ClaudeControllerEventListener,
        turnID: UUID
    ) -> Bool {
        guard let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session),
              session.claudeController != nil,
              listener.pendingProviderTurnID == turnID,
              listener.subscription == nil,
              listener.isCurrent(),
              let subscription = listener.reserve()
        else { return false }
        let ownership = session.beginRunAttempt(source: "claudeNative.providerInitiated")
        session.claudeTerminalAnchor = (ownership, .none)
        session.beginProviderInitiatedTurnAccounting()
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()
        session.clearClaudeTurnBookkeeping()
        session.claudeExpectedTurnIDs = [turnID]
        session.claudeProviderOutputBoundary = (ownership.attemptID, session.nextSequenceIndex)
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
        // No bootstrap lease covers this attempt. A stopped or failed attempt ends its process, so
        // the process run's MCP routing goes with it. A completed attempt keeps the live route.
        session.installRunAttemptTerminalResources(ownership: ownership) { [weak session, claudeCoordinator] terminalState in
            {
                guard let session, terminalState == .cancelled || terminalState == .failed else { return }
                await claudeCoordinator.cleanupProviderRun(session: session, runID: runID)
            }
        }
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)
        hooks.persistence.scheduleSave(session)

        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else {
                listener.close(subscription, returningTail: false)
                return
            }
            defer { listener.release(subscription) }
            await claudeCoordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
            let outcome = await consumeEvents(
                subscription,
                session: session,
                runID: runID,
                runAttemptID: ownership.attemptID
            )
            listener.close(subscription, returningTail: true)
            let terminalState: AgentSessionRunState
            let errorText: String?
            switch outcome {
            case .completed:
                (terminalState, errorText) = (.completed, nil)
            case .cancelled:
                (terminalState, errorText) = (.cancelled, nil)
            case let .failed(message, _):
                (terminalState, errorText) = (.failed, message)
            }
            await finalize(
                session: session,
                runID: runID,
                ownership: ownership,
                attachmentReservationID: nil,
                terminalState: terminalState,
                errorText: errorText,
                notifyTurnComplete: terminalState == .completed,
                shouldShutdownSession: terminalState == .failed
            )
        }
        return true
    }

    /// Starts a host run. `preparedEvents` is the event inbox the host start reserved before its
    /// preparation. Without it, or when its listener was replaced, the run reserves one now. Returns false, having
    /// started nothing, when another attempt holds the inbox.
    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        submissionID: UUID?,
        preparedEvents: ClaudeAttemptEventReservation? = nil,
        makeLease: (_ runID: UUID) -> MCPBootstrapLease
    ) async -> Bool {
        let runID = session.claudeController.flatMap { _ in
            AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        } ?? AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        var reservation = preparedEvents
        if let prepared = reservation,
           !prepared.listener.isCurrent() || prepared.listener.subscription !== prepared.subscription
        {
            prepared.listener.release(prepared.subscription)
            reservation = nil
        }
        guard let reservation = reservation ?? claudeCoordinator.reserveEvents(for: session) else {
            return false
        }
        let listener = reservation.listener
        let subscription = reservation.subscription
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

        let lease = makeLease(runID)
        let ownership = session.beginRunAttempt(source: "claudeNative")
        session.claudeProviderOutputBoundary = (ownership.attemptID, session.nextSequenceIndex)
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
        session.clearClaudeTurnBookkeeping()
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)

        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else {
                listener.close(subscription, returningTail: false)
                return
            }
            defer { listener.release(subscription) }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    listener.close(subscription, returningTail: true)
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

                    session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
                    switch await self.consumeEvents(
                        subscription,
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

                // Unread events go back to the listener before the terminal commit, so a turn
                // Claude Code started after this run's answer becomes its own attempt.
                listener.close(subscription, returningTail: true)
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
                            && (nativeFailureMetadata?.shouldShutdownSession == true || listener.runtimeFailure != nil)
                    )
                }
            } onCancel: {}
        }
        return true
    }

    private func consumeEvents(
        _ subscription: ClaudeAttemptEventSubscription,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        typealias TurnStatus = ClaudeNativeProcessSessionController.TurnStatus
        func strongest(_ current: TurnStatus, _ next: TurnStatus) -> TurnStatus {
            switch (current, next) {
            case (.failed, _), (_, .failed): .failed
            case (.cancelled, _), (_, .cancelled): .cancelled
            default: .completed
            }
        }
        func outcome(_ status: TurnStatus) -> ConsumeEventsOutcome {
            switch status {
            case .completed: .completed
            case .cancelled: .cancelled
            case .failed: .failed(errorText: nil, shouldShutdownSession: false)
            }
        }

        var exitedDueToAttemptMismatch = false
        // Keyed answers can settle this run's unprotected inputs across separate events. Keep
        // their strongest outcome until the run's last unprotected input is answered.
        var unprotectedTurnStatus: TurnStatus = .completed
        // A completion answered one of this attempt's own inputs or adopted turns.
        var answeredUnprotected = false
        // The host inputs accepted when this attempt first read a turn Claude Code started after
        // the attempt's own work began. A host input accepted later supersedes that provider work.
        var hostTurnIDsAtFirstSuccessor: Set<UUID>?
        // Outcomes of turns answered while steering protected them, in case the steering is
        // released and the attempt ends on them.
        var completedProtectedStatuses: [UUID: TurnStatus] = [:]
        var releasedProtectedTurnIDs: Set<UUID> = []
        // Host inputs whose registration marker this attempt has read. A provider start read while
        // an accepted input's marker is still unread started before Claude Code could read that input.
        var markedHostTurnIDs: Set<UUID> = []
        // A provider turn's output began a segment that a later host input's output must not share.
        var providerOutputSinceBoundary = false
        // A released steer leaves the attempt nothing more to wait for once a turn it protected
        // has already been answered and no other input or steering is outstanding.
        func settlesAfterReleasedSteering() -> Bool {
            releasedProtectedTurnIDs.contains { completedProtectedStatuses[$0] != nil }
                && session.claudeExpectedTurnIDs.isEmpty
                && session.pendingClaudeSteeringInstructions.isEmpty
                && session.claudeSteeringFlushTask == nil
        }

        eventLoop: while let item = await subscription.next() {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                exitedDueToAttemptMismatch = true
                break eventLoop
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }

            let event: NativeAgentRuntimeEvent
            switch item {
            case let .native(nativeEvent):
                event = nativeEvent
            case let .steeringReleased(protectedIDs, endsAttempt):
                // The attempt can't settle on the work the steer protected.
                if endsAttempt {
                    return .failed(errorText: nil, shouldShutdownSession: true)
                }
                releasedProtectedTurnIDs.formUnion(protectedIDs)
                for id in protectedIDs {
                    if let status = completedProtectedStatuses[id] {
                        unprotectedTurnStatus = strongest(unprotectedTurnStatus, status)
                    }
                }
                if settlesAfterReleasedSteering() {
                    return outcome(unprotectedTurnStatus)
                }
                continue eventLoop
            case .settlementRecheck:
                if settlesAfterReleasedSteering() {
                    return outcome(unprotectedTurnStatus)
                }
                continue eventLoop
            }

            if let knownHostTurnIDs = hostTurnIDsAtFirstSuccessor,
               !session.claudeAcceptedHostTurnIDs.subtracting(knownHostTurnIDs).isEmpty
            {
                // A newly accepted host input supersedes the provider work read before it.
                session.claudeLiveSuccessorTurnIDs.removeAll()
                hostTurnIDsAtFirstSuccessor = session.claudeAcceptedHostTurnIDs
                answeredUnprotected = false
                unprotectedTurnStatus = .completed
                completedProtectedStatuses.removeAll()
                releasedProtectedTurnIDs.removeAll()
            }

            switch event {
            case let .providerTurnStarted(turnID):
                // Each provider turn's output starts its own segment, including a turn registered as
                // a predecessor before this attempt read its start.
                hooks.transcript.beginClaudeProviderOutputSegment(session)
                session.claudeProviderOutputBoundary = (runAttemptID, session.nextSequenceIndex)
                providerOutputSinceBoundary = true
                let hasLivePredecessor = !session.claudeExpectedTurnIDs.isEmpty
                    || answeredUnprotected
                    || !session.pendingClaudeSteeringInstructions.isEmpty
                    || session.claudeSteeringFlushTask != nil
                let precedesUnmarkedInput = !session.claudeAcceptedHostTurnIDs.isSubset(of: markedHostTurnIDs)
                // The adopted turn and turns registered before a host send are expected already.
                guard session.claudeExpectedTurnIDs.insert(turnID).inserted else { continue eventLoop }
                session.claudeSupersedingProtectedTurnIDs.insert(turnID)
                session.pendingSupersedingTurnCompletions += 1
                // A predecessor's outcome never becomes the attempt's, and it doesn't hold the attempt open.
                if hasLivePredecessor, !precedesUnmarkedInput {
                    if hostTurnIDsAtFirstSuccessor == nil {
                        hostTurnIDsAtFirstSuccessor = session.claudeAcceptedHostTurnIDs
                    }
                    session.claudeLiveSuccessorTurnIDs.insert(turnID)
                }
            case let .inputRegistered(turnID):
                markedHostTurnIDs.insert(turnID)
                // The host input's output starts its own segment, so its final-only reply can't
                // replace the output of a provider turn that started before it.
                if providerOutputSinceBoundary, session.claudeAcceptedHostTurnIDs.contains(turnID) {
                    providerOutputSinceBoundary = false
                    hooks.transcript.beginClaudeProviderOutputSegment(session)
                    session.claudeProviderOutputBoundary = (runAttemptID, session.nextSequenceIndex)
                }
            case let .stream(result):
                #if DEBUG
                    if ClaudeReasoningExtractionFeature.isEnabled, result.type == "reasoning" {
                        let text = result.reasoning ?? result.text ?? ""
                        reasoningDebug("stream reasoning run=\(runID.uuidString) attempt=\(runAttemptID.uuidString) tab=\(session.tabID.uuidString) len=\(text.count) snippet=\(reasoningDebugSnippet(text))")
                    }
                #endif
                await hooks.transcript.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .runtimeInit(status):
                claudeCoordinator.observeRuntimeInit(status, session: session)
                if status.isRepoPromptServerFailed {
                    return .failed(
                        errorText: ClaudeAgentModeCoordinator.mcpInitializationFailureMessage(sessionID: status.sessionID),
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
                    _ = session.dismissClaudeApproval(requestID: requestID)
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
                let protectedTurnIDs = Set(turnIDs)
                    .intersection(session.claudeExpectedTurnIDs)
                    .intersection(session.claudeSupersedingProtectedTurnIDs)
                let answersSuccessor = !session.claudeLiveSuccessorTurnIDs.isDisjoint(with: turnIDs)
                guard let settlement = Self.settleCompletedTurnIDs(
                    turnIDs,
                    session: session,
                    waitForAllUnprotected: keyed,
                    previouslyAnsweredUnprotected: answeredUnprotected,
                    liveSuccessorTurnIDs: session.claudeLiveSuccessorTurnIDs
                ) else {
                    // Stale completion from a previous cancelled run attempt; ignore.
                    continue eventLoop
                }
                session.claudeLiveSuccessorTurnIDs.subtract(turnIDs)
                for id in protectedTurnIDs {
                    completedProtectedStatuses[id] = turnStatus
                }
                if settlement.answeredUnprotected {
                    answeredUnprotected = true
                }
                if settlement.answeredUnprotected || answersSuccessor {
                    if hostTurnIDsAtFirstSuccessor == nil, !protectedTurnIDs.isEmpty {
                        hostTurnIDsAtFirstSuccessor = session.claudeAcceptedHostTurnIDs
                    }
                    unprotectedTurnStatus = strongest(unprotectedTurnStatus, turnStatus)
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
                return outcome(unprotectedTurnStatus)
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
            errorText: ClaudeAgentModeCoordinator.unexpectedStreamEndMessage,
            shouldShutdownSession: false
        )
    }

    /// Retires every matched input of one completion before deciding whether the run ends, so a
    /// grouped answer is a single boundary. Returns nil when the completion matches no expected
    /// input. The run ends once the completion answers an unprotected input and, for keyed
    /// answers, no other unprotected input is still expected; positional answers keep their
    /// first-unprotected boundary. A turn Claude Code started by itself that the attempt read after
    /// its own work began holds the run open until it is answered too; when that answer comes
    /// after the run's own (`previouslyAnsweredUnprotected`), it ends the run.
    static func settleCompletedTurnIDs(
        _ turnIDs: [UUID],
        session: AgentTabSession,
        waitForAllUnprotected: Bool,
        previouslyAnsweredUnprotected: Bool = false,
        liveSuccessorTurnIDs: Set<UUID> = []
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
        let steeringPending = !session.pendingClaudeSteeringInstructions.isEmpty || session.claudeSteeringFlushTask != nil
        guard answeredUnprotected || previouslyAnsweredUnprotected,
              liveSuccessorTurnIDs.isDisjoint(with: session.claudeExpectedTurnIDs),
              answeredUnprotected || !steeringPending,
              !previouslyAnsweredUnprotected || otherUnprotected.isEmpty,
              !waitForAllUnprotected || otherUnprotected.isEmpty
        else {
            return (terminal: false, answeredUnprotected: answeredUnprotected)
        }
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        return (terminal: true, answeredUnprotected: answeredUnprotected)
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
            terminalAnchor: session.terminalAnchor(for: ownership),
            prepareProviderState: { [claudeCoordinator] in
                session.clearClaudeTurnBookkeeping()
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
