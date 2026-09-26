import Foundation

extension AgentModeViewModel {
    func makeComposerProps(tabID explicitTabID: UUID? = nil) -> AgentComposerProps {
        let tabID = explicitTabID ?? currentTabID
        let session = tabID.flatMap { sessions[$0] }
        let isMCPControlled = isMCPControlled(tabID: tabID)
        let isCodexRunActive: Bool = {
            guard selectedAgent == .codexExec, let tabID else { return false }
            return isTabRunning(tabID)
        }()
        let cancelTarget: AgentRunCancelTarget? = {
            guard let tabID,
                  let session,
                  session.runState.isActive,
                  session.runState != .waitingForUser,
                  session.runID != nil
            else { return nil }
            return makeRunCancelTarget(tabID: tabID, session: session)
        }()
        let submitTarget = makeComposerSubmitTarget(tabID: tabID, session: session)
        let acpControls = acpModelParameterControls(session: session)
        let acpRunLocksModelControls = session?.runState.isActive == true && !acpControls.isEmpty
        return AgentComposerProps(
            currentTabID: tabID,
            submitTarget: submitTarget,
            attachments: AgentAttachmentStripSnapshot(
                scopeTabID: tabID,
                imageAttachments: pendingImageAttachments,
                taggedFileAttachments: pendingTaggedFileAttachments
            ),
            runState: runState,
            cancelTarget: cancelTarget,
            isAgentBusy: isAgentBusy,
            isWaitingForInstruction: isWaitingForInstruction,
            canUseLinkedAgentSession: hasLinkedAgentSession(for: tabID),
            isCurrentTabMCPControlled: isMCPControlled,
            areModelControlsDisabled: isMCPControlled || acpRunLocksModelControls,
            providerControls: activeProviderControlsBinding,
            isCodexRunActive: isCodexRunActive,
            hasAvailableAgentProviders: hasAvailableAgentProviders,
            canSendWithCurrentProvider: canSendWithCurrentProvider,
            unavailableSelectedAgentMessage: unavailableSelectedAgentMessage,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            selectedModelDisplayName: selectedModelDisplayName,
            selectedReasoningEffortRaw: selectedReasoningEffortRaw,
            selectedReasoningEffortDisplayName: selectedReasoningEffortDisplayName,
            acpModelParameterControls: acpControls,
            availableAgents: availableAgents,
            isProviderPickerLockedForCurrentTab: isProviderPickerLocked(tabID: tabID),
            isAgentPickerDisabledForPendingStartup: session?.hasPendingStartup ?? false,
            lockedAgentSelectionMessage: lockedAgentSelectionMessage(tabID: tabID),
            autoEditEnabled: autoEditEnabled,
            stagedSlashCommand: stagedSlashCommandProps(tabID: tabID),
            draftRestorationEvent: draftRestorationEvent.map(AgentDraftRestorationProps.init),
            fileTagLookupContextIdentity: agentWorkspaceLookupContextIdentity(tabID: tabID, session: session)
        )
    }

    private func acpModelParameterControls(session: TabSession?) -> [AgentComposerModelParameterControlProps] {
        guard let providerID = selectedAgent.acpProviderID else { return [] }
        // Pure projection over the held demand-scoped observation (OpenCode) or the static
        // catalogue (Cursor). Never launch discovery from here. While the OpenCode observation
        // is loading/failed/has no usable parameters, or its discovery authority does not
        // resolve (no key), there is no parameter set: live controls are omitted, saved pins
        // stay visible as saved-intent controls, and model selection, permissions, and
        // submission stay usable. Every returned choice renders, including a one-option menu.
        let parameterSet = ACPModelParameterResolver.parameterSet(
            providerID: providerID,
            selectedModelRaw: selectedModelRaw,
            openCodeKey: providerID == .openCode
                ? openCodeParameterDiscoveryKey(session: session, modelRaw: selectedModelRaw)
                : nil,
            openCodeParameters: openCodeModelParameterObservation
        )
        let persistedSelections = session?.acpModelParameterSelections ?? []
        let pinControls = ACPModelParameterResolver.pinControls(
            providerID: providerID,
            selectedModelRaw: selectedModelRaw,
            parameterSet: parameterSet,
            persistedSelections: persistedSelections
        )
        // Saved OpenCode intent must stay visible whenever its kind has no usable definition:
        // metadata loading, failed, or reporting no parameters, a kind the live set does not
        // advertise, or an ambiguous kind. The pin still blocks the next run, so omitting its
        // control would strand it with no way to clear or replace it.
        return pinControls.compactMap { control -> AgentComposerModelParameterControlProps? in
            guard let definition = control.definition else {
                guard providerID == .openCode, let saved = control.saved else { return nil }
                return savedIntentOnlyControl(for: saved)
            }
            guard let selectedChoice = ACPModelParameterResolver.composerSelectedChoice(
                definition: definition,
                saved: control.saved,
                providerID: providerID
            ) else { return nil }
            return AgentComposerModelParameterControlProps(
                providerID: providerID,
                kind: definition.kind,
                baseModelRaw: control.baseModelRaw,
                configID: definition.configID,
                displayName: definition.displayName,
                selectedValueRaw: selectedChoice.rawValue,
                selectedDisplayName: selectedChoice.displayName,
                choices: definition.choices,
                openCodeDiscoveryKey: providerID == .openCode ? openCodeModelParameterObservation?.key : nil,
                hasLiveDefinition: true
            )
        }
    }

    /// Composer recovery control from saved OpenCode intent alone: no live definition, no
    /// invented choices, and the saved raw value verbatim. The only honest actions are clearing
    /// the pin or waiting for discovery to succeed. Cursor never needs this — its static
    /// catalogue always resolves for a known model.
    private func savedIntentOnlyControl(
        for selection: ACPModelParameterSelection
    ) -> AgentComposerModelParameterControlProps {
        AgentComposerModelParameterControlProps(
            providerID: .openCode,
            kind: selection.kind,
            baseModelRaw: selection.baseModelRaw,
            configID: selection.configID,
            displayName: selection.kind.recoveryDisplayName,
            selectedValueRaw: selection.valueRaw,
            selectedDisplayName: selection.valueRaw,
            choices: [],
            openCodeDiscoveryKey: openCodeModelParameterObservation?.key,
            hasLiveDefinition: false
        )
    }

    func makeComposerSubmitTarget(tabID: UUID?, session: TabSession?) -> AgentComposerSubmitTarget? {
        guard let tabID else { return nil }
        let resolvedSession = session ?? self.session(for: tabID)
        let expectedInitialStartLocation = initialStartLocationProps(tabID: tabID)?.selection
        if workspaceSwitchInFlight, (expectedInitialStartLocation ?? .local) == .local {
            return nil
        }
        guard !resolvedSession.isComposerSubmissionInFlight,
              !resolvedSession.isPreparingInitialWorktree,
              !resolvedSession.isChangingExecutionLocation
        else { return nil }
        let expectedSourceAgentSessionID = composerSourceAgentSessionID(tabID: tabID, session: resolvedSession)
        let hasLinkedSession = hasLinkedAgentSession(for: tabID)
        let route: AgentComposerSubmitTarget.Route
        if hasLinkedSession {
            guard expectedSourceAgentSessionID != nil else { return nil }
            route = .existingAgentSession
        } else {
            guard expectedSourceAgentSessionID == nil else { return nil }
            guard !resolvedSession.runState.isActive,
                  resolvedSession.runID == nil,
                  resolvedSession.activeRunAttemptID == nil
            else { return nil }
            route = .createAgentSessionFromSourceTab
        }

        let expectedRunState = resolvedSession.runState
        let expectedRunID = resolvedSession.runID
        let expectedRunAttemptID = resolvedSession.activeRunAttemptID
        guard !expectedRunState.isActive || expectedRunID != nil else { return nil }
        return AgentComposerSubmitTarget(
            tabID: tabID,
            route: route,
            expectedSourceTabSessionIdentity: ObjectIdentifier(resolvedSession),
            expectedSourceAgentSessionID: expectedSourceAgentSessionID,
            expectedPersistentBindingIdentity: resolvedSession.persistentSessionBindingIdentity,
            expectedBindingTransitionGeneration: resolvedSession.bindingTransitionGeneration,
            expectedRunState: expectedRunState,
            expectedRunID: expectedRunID,
            expectedRunAttemptID: expectedRunAttemptID,
            expectedSubmissionToken: resolvedSession.composerSubmissionToken,
            expectedInitialStartLocation: expectedInitialStartLocation
        )
    }

    func syncComposerUIState(tabID: UUID? = nil) {
        #if DEBUG
            test_syncComposerCallCount += 1
        #endif
        reconcileOpenCodeModelParameterObservation()
        ui.composer.update(makeComposerProps(tabID: tabID))
    }

    func syncComposerUIStateIfCurrent(_ session: TabSession) {
        guard session.tabID == currentTabID else { return }
        syncComposerUIState()
    }

    func syncAllActiveUIState(tabID: UUID? = nil) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncAllActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event("ui.syncAllActiveUIState", tabID: tabID)
        #endif
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
        syncRuntimeMetricsUIState()
        // Sidebar revision should publish only on sidebar-relevant changes (session
        // list, sort, search, visible count). `syncSidebarUIState()` still republishes
        // the snapshot when those inputs differ; callers that truly need to force a
        // sidebar revision bump (e.g. sessions/sessionIndex/run-state mutations) call
        // `syncSidebarUIState(refresh: true)` directly.
        syncSidebarUIState()
        syncTranscriptUIState()
        syncRunInteractionUIState()
    }

    func syncActiveUIState(tabID: UUID? = nil, invalidation: ActiveUIInvalidation) {
        guard !invalidation.isEmpty else { return }
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event(
                "ui.syncActiveUIState",
                tabID: tabID,
                fields: [
                    "composer": String(invalidation.contains(.composer)),
                    "status": String(invalidation.contains(.statusPills)),
                    "runtime": String(invalidation.contains(.runtimeMetrics)),
                    "transcript": String(invalidation.contains(.transcript)),
                    "run": String(invalidation.contains(.runInteraction))
                ]
            )
        #endif
        if invalidation.contains(.composer) {
            syncComposerUIState(tabID: tabID)
        }
        if invalidation.contains(.statusPills) {
            syncStatusPillsUIState()
        }
        if invalidation.contains(.runtimeMetrics) {
            syncRuntimeMetricsUIState()
        }
        if invalidation.contains(.transcript) {
            syncTranscriptUIState()
        }
        if invalidation.contains(.runInteraction) {
            syncRunInteractionUIState()
        }
    }
}
