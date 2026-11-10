import Combine
import Foundation

struct AgentExecutionLocationProps: Equatable {
    let tabID: UUID
    let selection: AgentModeViewModel.InitialStartLocation
    let indicator: AgentWorktreeIndicator?
    let isInitialSelection: Bool
    let isEnabled: Bool
    let isOperationInProgress: Bool
    let requiresActiveRunConfirmation: Bool
    let disabledReason: String?
}

struct AgentStatusPillsSnapshot: Equatable {
    let currentTabID: UUID?
    let selectedWorkflow: AgentWorkflowDefinition?
    let stagedSlashCommand: AgentStagedSlashCommandProps?
    let selectedAgent: AgentProviderKind
    let autoEditPermissionGuidance: AgentModeViewModel.AutoEditPermissionGuidance?
    let runState: AgentSessionRunState
    let autoEditEnabled: Bool
    let interviewFirst: Bool
    let executionLocation: AgentExecutionLocationProps?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?
    /// Changes when the current tab's Agent session or its worktree bindings change. The context
    /// drawer refreshes on it; it isn't binding authority.
    let contextLookupIdentity: AgentWorkspaceLookupContextIdentity

    static let empty = AgentStatusPillsSnapshot(
        currentTabID: nil,
        selectedWorkflow: nil,
        stagedSlashCommand: nil,
        selectedAgent: .claudeCode,
        autoEditPermissionGuidance: nil,
        runState: .idle,
        autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
        interviewFirst: false,
        executionLocation: nil,
        activeAgentSessionID: nil,
        activeRunID: nil,
        contextLookupIdentity: AgentWorkspaceLookupContextSource(activeAgentSessionID: nil, worktreeBindings: []).identity
    )
}

@MainActor
final class AgentStatusPillsUIStore: ObservableObject {
    @Published private(set) var snapshot: AgentStatusPillsSnapshot
    @Published private(set) var revision: UInt64 = 0

    init(snapshot: AgentStatusPillsSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func update(_ nextSnapshot: AgentStatusPillsSnapshot) {
        guard snapshot != nextSnapshot else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("statusPills", published: false)
            #endif
            return
        }
        snapshot = nextSnapshot
        revision &+= 1
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                "statusPills",
                published: true,
                details: [
                    "revision": String(revision),
                    "runState": String(describing: snapshot.runState),
                    "tabID": AgentModePerfDiagnostics.shortID(snapshot.currentTabID)
                ]
            )
        #endif
    }
}
