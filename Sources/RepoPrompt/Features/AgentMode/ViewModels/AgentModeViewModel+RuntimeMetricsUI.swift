import Foundation

@MainActor
extension AgentModeViewModel {
    /// Only the detail view, which reads the current tab's canonical selection, passes `.replace` or `.clear`.
    func syncRuntimeMetricsUIState(liveSelection: AgentRuntimeLiveSelectionUpdate = .unchanged) {
        #if DEBUG
            test_syncRuntimeMetricsCallCount += 1
        #endif
        let liveSelectionSummary: AgentContextSelectionSummary?
        switch liveSelection {
        case .unchanged:
            liveSelectionSummary = nil
        case let .replace(summary):
            liveSelectionSummary = summary
        case .clear:
            ui.runtimeMetrics.clearLiveSelection()
            liveSelectionSummary = nil
        }
        ui.runtimeMetrics.update(
            transcriptSnapshot: activeTranscriptAnalyticsSnapshot,
            codexUsage: contextUsage,
            liveSelectedFileCount: liveSelectionSummary?.totalExplicitFileCount,
            liveSelectionSummary: liveSelectionSummary,
            tabID: currentTabID,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw
        )
    }
}
