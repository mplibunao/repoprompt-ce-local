import Foundation

@MainActor
extension AgentModeViewModel {
    func nonCodexContextUsageEstimator(for agent: AgentProviderKind) -> (any ContextUsageEstimating)? {
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            claudeContextUsageEstimator
        case .codexExec, .openCode, .cursor, .grokBuild:
            nil
        }
    }

    func applyCodexNativeContextUsage(_ usage: AgentContextUsage, session: TabSession) {
        session.codexContextUsage = usage
        _ = codexContextUsageEstimator.ingestNativeContextUsage(usage, session: session)
    }

    func refreshCodexContextUsageSnapshot(for session: TabSession) {
        _ = codexContextUsageEstimator.ingestNativeContextUsage(session.codexContextUsage, session: session)
    }

    func clearContextUsageSnapshot(for session: TabSession) {
        session.contextUsageSnapshot = nil
        session.contextCompactedAt = nil
    }

    func startNonCodexTurnAccountingIfNeeded(for session: TabSession, initialMessage: String, submissionID: UUID?) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        if session.activeNonCodexTurnTokenAccumulator != nil {
            finalizeNonCodexTurnUsageIfNeeded(for: session, promptTokens: nil, completionTokens: nil, contextUsedTokens: nil)
        }
        estimator.beginTurn(session: session, initialMessage: initialMessage, submissionID: submissionID)
    }

    func addUserInputTokensToActiveNonCodexTurn(_ tokens: Int, for session: TabSession) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        estimator.addUserInputTokens(tokens, session: session)
    }

    func addToolInputTokens(_ payload: String?, for session: TabSession) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        estimator.addToolInputPayload(payload, session: session)
    }

    func addToolOutputTokens(_ payload: String?, for session: TabSession) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        estimator.addToolOutputPayload(payload, session: session)
    }

    func finalizeNonCodexTurnUsageIfNeeded(
        for session: TabSession,
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?
    ) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        let didAppend = estimator.finalizeTurn(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            contextUsedTokens: contextUsedTokens,
            session: session
        )
        if didAppend {
            scheduleSave(for: session.tabID)
        }
    }

    /// A newly reported capacity can leave the snapshot unchanged (two capacities capped to the same
    /// window), so it is saved on its own rather than through the snapshot-changed result.
    func scheduleSaveIfContextCapacityChanged(from previous: AgentContextWindowCapacity?, session: TabSession) {
        guard session.contextWindowCapacity != previous else { return }
        scheduleSave(for: session.tabID)
    }

    nonisolated static func contextUsageFromClaudeProviderTokens(
        _ usage: [AgentTokenUsagePersist],
        modelContextWindow: Int?
    ) -> AgentContextUsage? {
        guard !usage.isEmpty else { return nil }
        // Without a known positive window there is no ceiling, as in live validation: a fixed
        // fallback would discard valid occupancy restored from larger-window sessions.
        let maxContextTokens = modelContextWindow.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
        // Only trust exact stream-derived context snapshots (contextUsedTokens).
        // Do NOT fall back to promptTokens — those are billed-turn aggregates that
        // include internal tool sub-steps and cause inflated context estimates.
        // A compaction fence ends the scan: occupancy recorded before it describes
        // the old context, so usage stays pending until a later row measures it.
        for turn in usage.reversed() {
            if turn.contextCompacted {
                return AgentContextUsage(
                    modelContextWindow: modelContextWindow,
                    lastTotalTokens: nil,
                    totalTotalTokens: nil,
                    awaitingPostCompactionUsage: true
                )
            }
            if let contextUsed = turn.contextUsedTokens,
               contextUsed > 0,
               contextUsed <= maxContextTokens
            {
                return AgentContextUsage(
                    modelContextWindow: modelContextWindow,
                    lastTotalTokens: contextUsed,
                    totalTotalTokens: contextUsed
                )
            }
        }
        guard modelContextWindow != nil else { return nil }
        return AgentContextUsage(
            modelContextWindow: modelContextWindow,
            lastTotalTokens: nil,
            totalTotalTokens: nil
        )
    }
}
