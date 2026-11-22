import Foundation

/// How a runtime-metrics sync changes the live selection that `AgentRuntimeMetricsUIStore` retains.
enum AgentRuntimeLiveSelectionUpdate: Equatable {
    /// The caller has no selection information.
    case unchanged
    /// A fresh observation of the current tab's selection.
    case replace(AgentContextSelectionSummary)
    /// No target tab or no selection snapshot.
    case clear
}

@MainActor
final class AgentRuntimeMetricsUIStore: ObservableObject {
    let runtimeVM = AgentRuntimeSidebarViewModel()
    @Published private(set) var revision: Int = 0

    private struct LiveSelectionObservation {
        let fileCount: Int?
        let summary: AgentContextSelectionSummary?

        var explicitFileCount: Int? {
            summary?.totalExplicitFileCount ?? fileCount
        }
    }

    private struct SelectionToolItemKey: Equatable {
        let itemID: UUID
        let toolResultJSON: String?

        init(_ item: AgentChatItem) {
            itemID = item.id
            toolResultJSON = item.toolResultJSON
        }
    }

    private var liveSelectionTabID: UUID?
    private var retainedLiveSelection: LiveSelectionObservation?
    private var lastManageSelectionItemKey: SelectionToolItemKey?
    private var lastWorkspaceContextItemKey: SelectionToolItemKey?

    /// A nil live count and summary mean this update carries no new selection observation: the
    /// store keeps the last one it was given for `tabID` until the tab changes, `clearLiveSelection()`
    /// runs, a newer observation arrives, or a newly arrived selection tool result reports a
    /// different file count.
    func update(
        transcriptSnapshot: AgentTranscriptAnalyticsSnapshot,
        codexUsage: AgentContextUsage?,
        liveSelectedFileCount: Int?,
        liveSelectionSummary: AgentContextSelectionSummary? = nil,
        tabID: UUID? = nil,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String
    ) {
        if tabID != liveSelectionTabID {
            liveSelectionTabID = tabID
            retainedLiveSelection = nil
        }
        endRetentionIfNewSelectionToolResultDisagrees(transcriptSnapshot)
        if liveSelectedFileCount != nil || liveSelectionSummary != nil {
            retainedLiveSelection = LiveSelectionObservation(
                fileCount: liveSelectedFileCount,
                summary: liveSelectionSummary
            )
        }

        let previousSnapshot = runtimeVM.snapshot
        runtimeVM.update(
            snapshot: transcriptSnapshot,
            codexUsage: codexUsage,
            liveSelectedFileCount: retainedLiveSelection?.fileCount,
            liveSelectionSummary: retainedLiveSelection?.summary,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw
        )
        let didPublish = runtimeVM.snapshot != previousSnapshot
        if didPublish {
            revision &+= 1
        }
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                "runtimeMetrics",
                published: didPublish,
                details: [
                    "revision": String(revision),
                    "usedTokens": runtimeVM.snapshot.usedTokens.map(String.init) ?? "nil",
                    "estimatedTranscriptTokens": runtimeVM.snapshot.estimatedTranscriptTokens.map(String.init) ?? "nil",
                    "selectionFileCount": runtimeVM.snapshot.selectionFileCount.map(String.init) ?? "nil",
                    "selectionSliceRanges": runtimeVM.snapshot.selectionSummary.map { String($0.sliceRangeCount) } ?? "nil",
                    "updatedAtChanged": String(runtimeVM.snapshot.updatedAt != previousSnapshot.updatedAt)
                ]
            )
        #endif
    }

    /// Drops the retained live selection without publishing; the next `update` publishes the result.
    func clearLiveSelection() {
        retainedLiveSelection = nil
    }

    /// Some writes change a tab's stored selection without a selection-coordinator event, so a
    /// selection tool result that arrived since the previous update and disagrees with the
    /// retained file count ends retention. Items are compared by ID and result JSON, never by
    /// timestamp, and an item already seen never ends it.
    private func endRetentionIfNewSelectionToolResultDisagrees(
        _ transcriptSnapshot: AgentTranscriptAnalyticsSnapshot
    ) {
        let manageSelectionItem = transcriptSnapshot.latestManageSelectionItem
        let workspaceContextItem = transcriptSnapshot.latestWorkspaceContextItem
        let manageSelectionItemKey = manageSelectionItem.map(SelectionToolItemKey.init)
        let workspaceContextItemKey = workspaceContextItem.map(SelectionToolItemKey.init)
        defer {
            lastManageSelectionItemKey = manageSelectionItemKey
            lastWorkspaceContextItemKey = workspaceContextItemKey
        }
        guard let retainedFileCount = retainedLiveSelection?.explicitFileCount else { return }

        var newToolFileCounts: [Int] = []
        if let manageSelectionItem,
           manageSelectionItemKey != lastManageSelectionItemKey,
           let files = ToolJSON.decodeResult(
               ToolResultDTOs.SelectionReply.self,
               from: manageSelectionItem.toolResultJSON
           )?.files
        {
            newToolFileCounts.append(files.count)
        }
        if let workspaceContextItem,
           workspaceContextItemKey != lastWorkspaceContextItemKey,
           let selection = ToolJSON.decodeResult(
               ToolResultDTOs.PromptContextDTO.self,
               from: workspaceContextItem.toolResultJSON
           )?.selection
        {
            newToolFileCounts.append(selection.files.count)
        }
        if newToolFileCounts.contains(where: { $0 != retainedFileCount }) {
            retainedLiveSelection = nil
        }
    }
}
