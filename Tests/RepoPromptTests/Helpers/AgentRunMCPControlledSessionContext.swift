import Foundation
import MCP
@testable import RepoPromptApp

@MainActor
final class AgentRunMCPControlledSessionContext {
    let window: WindowState
    let sessionID: UUID
    let session: AgentModeViewModel.TabSession
    let service: AgentRunMCPToolService
    private let workspaceRootURL: URL

    private init(
        window: WindowState,
        sessionID: UUID,
        session: AgentModeViewModel.TabSession,
        service: AgentRunMCPToolService,
        workspaceRootURL: URL
    ) {
        self.window = window
        self.sessionID = sessionID
        self.session = session
        self.service = service
        self.workspaceRootURL = workspaceRootURL
    }

    static func make(
        workspaceNamePrefix: String,
        workspaceSwitchReason: String,
        clientName: String,
        unusedStartRunMessage: String,
        bindWorkspaceComposeTab: Bool = false
    ) async throws -> AgentRunMCPControlledSessionContext {
        let settings = GlobalSettingsStore.shared
        let previousAutoStart = settings.mcpAutoStart()
        settings.setMCPAutoStart(false, commit: false)
        defer { settings.setMCPAutoStart(previousAutoStart, commit: false) }

        // The workspace's root is an empty directory outside any repository. A root inside a git
        // checkout makes the process-wide Code Map engine index that checkout in the background,
        // and closing the window does not end that work.
        let workspaceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("AgentRunMCPControlledSessionContext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)

        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "\(workspaceNamePrefix) \(UUID().uuidString.prefix(8))",
                repoPaths: [workspaceRootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: workspaceSwitchReason
            )
            guard let activeWorkspace = window.workspaceManager.activeWorkspace else {
                throw MCPError.internalError("Expected active ephemeral workspace")
            }
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let sessionID = UUID()
            let session: AgentModeViewModel.TabSession
            if bindWorkspaceComposeTab {
                // Binding the workspace's own compose tab records the session in the workspace, as
                // a real session is recorded; a detached tab keeps the binding in the runtime
                // only, so work gated on the workspace's view of the session, such as transcript
                // sync, skips it.
                guard let tabID = activeWorkspace.activeComposeTabID else {
                    throw MCPError.internalError("Expected an active compose tab")
                }
                session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
                guard window.agentModeViewModel.test_installPersistentSessionBinding(
                    sessionID: sessionID,
                    on: session,
                    compareAndSetInWorkspaceID: activeWorkspace.id
                ) != nil else {
                    throw MCPError.internalError("Expected the compose tab binding to install")
                }
            } else {
                session = await window.agentModeViewModel.ensureSessionReady(tabID: UUID())
                _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
            }
            try await window.agentModeViewModel.mcpActivateControlContext(
                forTabID: session.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                startPending: true
            )

            let windowID = window.windowID
            let service = AgentRunMCPToolService(
                toolName: MCPWindowToolName.agentRun,
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: UUID(),
                        clientName: clientName,
                        windowID: windowID
                    )
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                    throw MCPError.internalError(unusedStartRunMessage)
                }
            )
            return AgentRunMCPControlledSessionContext(
                window: window,
                sessionID: sessionID,
                session: session,
                service: service,
                workspaceRootURL: workspaceRootURL
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: workspaceRootURL)
            throw error
        }
    }

    func cleanup() async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: workspaceRootURL)
    }
}
