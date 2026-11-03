import Foundation

/// A refusal for an Agent session worktree binding whose folder is confirmed missing.
///
/// It lives for one tool call and renders the error text an agent reads. It holds the binding so
/// tests can compare identity, but the text it renders never contains an absolute path.
struct MCPUnavailableWorktreeDiagnostic: Equatable, Sendable {
    /// The routed tab that hit the missing worktree.
    struct RouteContext: Equatable, Sendable {
        let tabName: String
        let contextID: UUID
        let windowID: Int
    }

    let binding: AgentSessionWorktreeBinding
    let routeContext: RouteContext?

    init(binding: AgentSessionWorktreeBinding, routeContext: RouteContext? = nil) {
        self.binding = binding
        self.routeContext = routeContext
    }

    /// Returns a diagnostic for the first binding whose worktree folder the runtime validator
    /// reports missing or not a directory. An empty or malformed path is not evidence that a
    /// folder disappeared, so it returns `nil` and the caller keeps its generic failure.
    static func classify(_ bindings: [AgentSessionWorktreeBinding]) -> MCPUnavailableWorktreeDiagnostic? {
        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)
            return nil
        } catch let error as AgentWorktreeRuntimeWorkspaceError {
            guard AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(
                error.binding.worktreeRootPath
            ) != nil else { return nil }
            return MCPUnavailableWorktreeDiagnostic(binding: error.binding)
        } catch {
            return nil
        }
    }

    func attachingRouteContext(_ routeContext: RouteContext) -> MCPUnavailableWorktreeDiagnostic {
        MCPUnavailableWorktreeDiagnostic(binding: binding, routeContext: routeContext)
    }

    /// The refusal: which tab, which worktree, and that no canonical checkout was used.
    var summary: String {
        "\(subject) \(sessionVerb) bound to \(worktreePhrase)\(rootPhrase), but that worktree's folder is missing or is not a directory. No canonical checkout was used."
    }

    /// What the calling agent can do next.
    var recovery: String {
        let selectTab: String
        let listArguments: String
        if let windowID = routeContext?.windowID {
            selectTab = "Ask the user to select another tab in this window"
            listArguments = "list this window's tabs with {\"op\":\"list\",\"window_id\":\(windowID)}"
        } else {
            selectTab = "Ask the user to select another tab"
            listArguments = "list tabs with {\"op\":\"list\"}"
        }
        return "Retrying won't help. \(selectTab); calls without a tab argument use the window's active tab. A connection bound to this tab stays bound when the visible tab changes. If bind_context is available to you, bind another tab with {\"op\":\"bind\",\"context_id\":\"<context_id>\"}, and \(listArguments) to find its context_id."
    }

    var message: String {
        "\(summary) \(recovery)"
    }

    private var subject: String {
        guard let routeContext else { return "The addressed Agent Mode session" }
        let contextID = routeContext.contextID.uuidString
        if let tabName = Self.displayValue(routeContext.tabName) {
            return "Tab '\(tabName)' (context_id '\(contextID)', window \(routeContext.windowID))"
        }
        return "Context '\(contextID)' in window \(routeContext.windowID)"
    }

    private var sessionVerb: String {
        routeContext == nil ? "is" : "has an Agent Mode session"
    }

    private var worktreePhrase: String {
        let label = [binding.visualLabel, binding.worktreeName, binding.branch, binding.worktreeID]
            .lazy
            .compactMap(safeIdentity)
            .first
        guard let label else { return "a worktree" }
        guard let worktreeID = safeIdentity(binding.worktreeID), worktreeID != label else {
            return "worktree '\(label)'"
        }
        return "worktree '\(label)' (worktree_id '\(worktreeID)')"
    }

    private var rootPhrase: String {
        let rootLabel = safeIdentity(binding.logicalRootName)
            ?? safeIdentity((binding.logicalRootPath as NSString).lastPathComponent)
        return rootLabel.map { " for root '\($0)'" } ?? ""
    }

    /// A display value that is safe to show: non-empty after sanitizing, and not a path.
    private func safeIdentity(_ value: String?) -> String? {
        guard let value, let display = Self.displayValue(value) else { return nil }
        if display.hasPrefix("/") || display.hasPrefix("~") || display.lowercased().hasPrefix("file:") {
            return nil
        }
        let bindingPaths = [binding.logicalRootPath, binding.worktreeRootPath]
            .flatMap { [$0, AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0)] }
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        if bindingPaths.contains(where: { value.contains($0) }) {
            return nil
        }
        return display
    }

    /// Replaces line breaks and control characters with spaces, escapes quotes and backslashes,
    /// and trims the result. Returns `nil` when nothing is left.
    private static func displayValue(_ value: String) -> String? {
        var output = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                output.append(" ")
            } else {
                if scalar == "\\" || scalar == "'" || scalar == "\"" {
                    output.append("\\")
                }
                output.append(scalar)
            }
        }
        let trimmed = String(output).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
