import Foundation
import RepoPromptDomainRuntime

// MARK: - Authority-classified run execution hooks

// `AgentModeRunService.Hooks` is the host-supplied callback surface used by the
// run service, the terminal commit barrier, and the provider runners. Each hook
// group below is classified by the authority it belongs to, so the reusable
// execution boundary stays explicit about ownership:
//
// - Canonical lifecycle/durable settlement stays owned by the domain layer
//   (`DomainAgentRunSessionStore`); `TerminalSettlementHooks` only adapts into
//   that authority and must remain exactly-once per run attempt ownership.
// - Presentation, binding-observation, queued-work recovery, and persistence
//   hooks are host projections. They must never become backend authority: a
//   headless host may implement them as no-ops without changing run semantics.
// - `AgentTabSession` remains at broader app-host orchestration
//   hooks because the app is the only adopter today. Terminal settlement does
//   not receive that type: `bindTerminalSession(_:)` partially applies the
//   exact originating object into an `AgentTabSession`-neutral capability value.

extension AgentModeRunService {
    /// Token/usage accounting projection for non-Codex turns.
    ///
    /// Authority: usage accounting (host-side projection of provider activity).
    struct UsageAccountingHooks {
        let estimateRuntimeTokens: (String) -> Int
        let addUserInputTokensToActiveNonCodexTurn: (Int, AgentTabSession) -> Void
        let startNonCodexTurnAccountingIfNeeded: (
            _ session: AgentTabSession,
            _ providerMessage: String,
            _ startingSubmissionID: UUID?
        ) -> Void
        let finalizeNonCodexTurnUsage: (AgentTabSession, Int?, Int?, Int?) -> Void
    }

    /// Attachment file lifecycle for one turn (reserve → consume → finalize).
    ///
    /// Authority: persistence/durable turn resources.
    struct AttachmentLifecycleHooks {
        let reserveAttachmentsForTurn: ([AgentImageAttachment], AgentTabSession) -> UUID?
        let markAttachmentsConsumed: (AgentTabSession, UUID?) -> Void
        let stageConsumedAttachmentFilesForDeferredCleanup: ([AgentImageAttachment], AgentTabSession) -> Void
        let consumeDeferredAttachmentCleanup: (AgentTabSession, Bool) -> Void
        let finalizeAttachmentsForTurn: (AgentTabSession, UUID?, DomainAgentRunAttachmentTurnDisposition) -> Void
    }

    /// UI-only callbacks. Never authoritative for run lifecycle decisions.
    ///
    /// Authority: presentation projection.
    struct RunPresentationHooks {
        let setAgentRunActive: (AgentTabSession, Bool) -> Void
        let requestUIRefresh: (UUID, Bool) -> Void
        let notifyAgentTurnComplete: (AgentTabSession) -> Void
    }

    /// Session binding/run-state observation invoked from the central run
    /// execution routing points. Not UI-only: alongside presentation binding
    /// updates, the app host also observes MCP-controlled session state from
    /// this callback, so it is classified as host binding observation rather
    /// than pure presentation.
    ///
    /// Authority: host binding/state observation projection. Never
    /// authoritative for run lifecycle decisions.
    struct RunBindingObservationHooks {
        let updateBindings: (AgentTabSession) -> Void
    }

    /// Recovery of queued, undelivered user work when a run settles before
    /// delivery (restoring queued steering text back into the host composer).
    ///
    /// Authority: queued-work recovery projection.
    struct QueuedWorkRecoveryHooks {
        let restoreDraftText: (_ tabID: UUID, _ text: String, _ message: String, _ strategy: DraftRestorationStrategy) -> Void
        /// Returns unsent submissions to the composer: their text above the current draft and their
        /// attachments ahead of any staged since, skipping attachments already staged.
        let restoreUnsentSubmissions: (
            _ session: AgentTabSession,
            _ draftText: String,
            _ images: [AgentImageAttachment],
            _ taggedFiles: [AgentTaggedFileAttachment],
            _ message: String
        ) -> Void
        /// Removes the transcript item of a submission that was queued but never sent.
        let removeUnsentUserItem: (_ session: AgentTabSession, _ itemID: UUID) -> Void
    }

    /// Host persistence scheduling for session/tab state.
    ///
    /// Authority: persistence projection.
    struct RunPersistenceHooks {
        let scheduleSave: (AgentTabSession) -> Void
    }

    /// Transcript projection of provider stream events and terminal finalization.
    ///
    /// Authority: transcript projection.
    struct TranscriptProjectionHooks {
        let handleHeadlessStreamResult: (AIStreamResult, AgentTabSession, UUID, UUID) async -> Void
        let finalizeStreamingItems: (AgentTabSession) -> Void
        let finalizePendingToolCalls: (AgentTabSession, AgentSessionRunState) -> Void
        let finalizePendingToolCallsWithUpperBound: (AgentTabSession, AgentSessionRunState, Int?) -> Void
        let flushPendingAssistantDelta: (AgentTabSession) -> Void
        let clearPendingAssistantDelta: (AgentTabSession) -> Void
    }

    /// Provider-facing input assembly (messages, handoff payloads).
    ///
    /// Authority: provider capability inputs.
    struct ProviderInputAssemblyHooks {
        let buildHeadlessAgentMessage: (AgentTabSession, String, UUID, [AgentImageAttachment]) -> AgentMessage
        /// Augment queued steering text with skill context, tagged files, and attachment rendering before submit.
        let augmentUserMessageForProviderSend: (
            _ text: String,
            _ attachments: [AgentImageAttachment],
            _ taggedFileAttachments: [AgentTaggedFileAttachment],
            _ session: AgentTabSession?
        ) async -> String
        /// Stages a transcript handoff for fresh-session resume recovery.
        let stageResumeRecoveryHandoffIfNeeded: (_ session: AgentTabSession) async -> Void
        /// Prepends a staged handoff payload to provider-facing text.
        let prependPendingHandoffIfNeeded: (_ text: String, _ session: AgentTabSession) -> String
        /// Records whether a staged handoff payload was accepted by the provider send attempt.
        let recordPendingHandoffSendOutcome: (_ session: AgentTabSession, _ didSend: Bool) -> Void
    }

    /// Cancellation of pending approvals/questions/reviews when a run settles.
    ///
    /// Authority: approval/interaction brokerage.
    struct RunInteractionHooks {
        let cancelPendingQuestion: (AgentTabSession) -> Void
        let cancelPendingApproval: (AgentTabSession) -> Void
        let cancelPendingApplyEditsReview: (AgentTabSession, String) -> Void
        let cancelPendingWorktreeMergeReview: (AgentTabSession, String) -> Void
    }

    /// Adapter into the canonical durable terminal settlement authority
    /// (`DomainAgentRunSessionStore` behind the host's publication surface).
    ///
    /// Authority: canonical lifecycle command/event adaptation. The terminal
    /// commit barrier drives these exactly once per settled run attempt.
    struct TerminalSettlementHooks {
        let prepareTerminalPublication: (AgentTabSession) -> Void
        let makeTerminalPublicationEnvelope: (
            AgentTabSession,
            AgentRunOwnership,
            AgentSessionRunState,
            UUID?,
            DomainAgentRunSnapshot.FailureReason?
        ) -> AgentRunTerminalPublicationEnvelope?
        let publishTerminalCommit: (
            AgentTabSession,
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult
    }

    /// Continuation of a settled or steered run (follow-up starts, MCP wakes).
    ///
    /// Authority: lifecycle command issuance back into the host.
    struct RunContinuationHooks {
        let startFollowUpRun: (AgentTabSession, AgentQueuedInstruction, AgentRunStartupTicket?) -> Void
        /// Wakes MCP waiters once a steering instruction has actually been delivered to the provider.
        let signalMCPInstructionDelivered: (_ session: AgentTabSession) async -> Void
    }

    /// Composite host callback surface for run execution, grouped by authority.
    struct Hooks {
        let usage: UsageAccountingHooks
        let attachments: AttachmentLifecycleHooks
        let presentation: RunPresentationHooks
        let bindingObservation: RunBindingObservationHooks
        let queuedWorkRecovery: QueuedWorkRecoveryHooks
        let persistence: RunPersistenceHooks
        let transcript: TranscriptProjectionHooks
        let providerInput: ProviderInputAssemblyHooks
        let interactions: RunInteractionHooks
        let terminalSettlement: TerminalSettlementHooks
        let continuation: RunContinuationHooks
    }
}

// MARK: - Exact session partial application for terminal settlement

extension AgentModeRunService.Hooks {
    /// Binds the terminal settlement surface to the exact originating object.
    ///
    /// This is the app-host composition edge: the returned value retains that
    /// object directly and never re-resolves it through the tab dictionary.
    @MainActor
    func bindTerminalSession(
        _ session: AgentTabSession
    ) -> AgentRunTerminalSessionBinding {
        let tabID = session.tabID
        return AgentRunTerminalSessionBinding(
            tabID: tabID,
            lifecycle: session.runLifecycle,
            hooks: .init(
                flushPendingAssistantDelta: {
                    transcript.flushPendingAssistantDelta(session)
                },
                finalizeStreamingItems: {
                    transcript.finalizeStreamingItems(session)
                },
                finalizePendingToolCalls: { terminalState in
                    transcript.finalizePendingToolCalls(session, terminalState)
                },
                finalizeNonCodexTurnUsage: {
                    usage.finalizeNonCodexTurnUsage(session, nil, nil, nil)
                },
                cancelPendingInteractions: { reviewReason in
                    interactions.cancelPendingQuestion(session)
                    interactions.cancelPendingApproval(session)
                    interactions.cancelPendingApplyEditsReview(session, reviewReason)
                    interactions.cancelPendingWorktreeMergeReview(session, reviewReason)
                },
                finalizeAttachments: { reservationID, disposition in
                    attachments.finalizeAttachmentsForTurn(session, reservationID, disposition)
                },
                setAgentRunInactive: {
                    presentation.setAgentRunActive(session, false)
                },
                prepareTerminalPublication: {
                    terminalSettlement.prepareTerminalPublication(session)
                },
                makeTerminalPublicationEnvelope: { ownership, terminalState, expectedRunID, failureReason in
                    terminalSettlement.makeTerminalPublicationEnvelope(
                        session,
                        ownership,
                        terminalState,
                        expectedRunID,
                        failureReason
                    )
                },
                updateBindings: {
                    bindingObservation.updateBindings(session)
                },
                notifyAgentTurnComplete: {
                    presentation.notifyAgentTurnComplete(session)
                },
                scheduleSave: {
                    persistence.scheduleSave(session)
                },
                publishTerminalCommit: { revision, successorKind in
                    await terminalSettlement.publishTerminalCommit(
                        session,
                        revision,
                        successorKind
                    )
                },
                admitQueuedFollowUp: {
                    session.admitStartIfFree(submissionID: session.pendingInstructions.first?.submissionID)
                },
                startFollowUpRun: { instruction, admission in
                    continuation.startFollowUpRun(session, instruction, admission)
                },
                returnQueuedFollowUpsToComposer: {
                    returnQueuedFollowUpsToComposer(session)
                }
            ),
            validatesOwnership: { ownership, expectedRunID in
                session.isCurrentRunAttemptForCurrentBinding(
                    ownership,
                    expectedRunID: expectedRunID
                )
            },
            providerDrainGeneration: {
                session.providerTerminalDrainGeneration
            },
            terminalTurnID: {
                session.items.last(where: { $0.kind == .user })?.id
            },
            queuedFollowUp: {
                session.pendingInstructions.first
            },
            setFollowUpPending: { pending in
                session.mcpFollowUpRunPending = pending
            },
            removeFirstQueuedFollowUp: {
                guard !session.pendingInstructions.isEmpty else { return nil }
                return session.pendingInstructions.removeFirst()
            },
            appendError: { errorText in
                session.appendItem(
                    AgentChatItem.error(
                        errorText,
                        sequenceIndex: session.nextSequenceIndex
                    )
                )
            },
            finishActiveState: { ownership, terminalState, source in
                session.agentTask = nil
                session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                session.setRunningStatus(nil, source: nil)
                session.waitingPrompt = nil
                session.runState = terminalState
                _ = session.endRunAttempt(ifCurrent: ownership, source: source)
            },
            retainProcessRunIdentity: { runID, terminalTurnID in
                AgentModeProcessRunIdentity.retainProcessRunID(
                    runID,
                    inTranscriptTurnID: terminalTurnID,
                    for: session
                )
            },
            sourceItemsRevision: {
                session.sourceItemsRevision
            },
            assistantDeltaFlushGeneration: {
                session.assistantDeltaFlushGeneration
            },
            latestFailureText: {
                AgentTranscriptIO.latestErrorText(
                    from: session.transcript,
                    latestTurnOnly: true
                ) ?? AgentTranscriptIO.latestErrorText(
                    from: session.transcript,
                    latestTurnOnly: false
                )
            }
        )
    }

    /// Gives queued follow-ups that will not start back to the user, once their run's terminal
    /// commit has published without a successor for them.
    @MainActor
    private func returnQueuedFollowUpsToComposer(_ session: AgentTabSession) {
        // A newer run owns whatever is queued now, and drains it itself.
        guard !session.runState.isActive else { return }
        let returned = session.pendingInstructions
        session.pendingInstructions.removeAll()
        let constituentIDs = returned.flatMap(\.constituentSubmissionIDs)
        session.removeQueuedUserInputTokenEstimates(
            forSubmissions: Array(Set(constituentIDs + returned.compactMap(\.submissionID)))
        )
        // Each entry gives back what its user typed, and every submission it stands for
        // gives back the attachments that left the composer with it; those are
        // referenced only by the submission's unsent item, so they are taken before
        // the item is removed.
        let draftText = returned
            .map { $0.restorationDraftText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        var images: [AgentImageAttachment] = []
        var taggedFiles: [AgentTaggedFileAttachment] = []
        for itemID in constituentIDs {
            guard let item = session.items.first(where: { $0.id == itemID }) else { continue }
            for image in item.attachments where !images.contains(where: { $0.id == image.id }) {
                images.append(image)
            }
            for file in item.taggedFileAttachments
                where !taggedFiles.contains(where: { $0.relativePath == file.relativePath })
            {
                taggedFiles.append(file)
            }
        }
        if !draftText.isEmpty || !images.isEmpty || !taggedFiles.isEmpty {
            queuedWorkRecovery.restoreUnsentSubmissions(
                session,
                draftText,
                images,
                taggedFiles,
                "Restored queued messages that could not start after the run ended"
            )
        }
        for itemID in constituentIDs {
            queuedWorkRecovery.removeUnsentUserItem(session, itemID)
        }
        // The flag was raised for these follow-ups. A start that owns it, or a newer
        // start's ticket, keeps it for itself.
        if session.mcpPendingStartOwner == nil, session.unresolvedStartupTicket == nil {
            session.mcpFollowUpRunPending = false
        }
        bindingObservation.updateBindings(session)
        persistence.scheduleSave(session)
    }
}
