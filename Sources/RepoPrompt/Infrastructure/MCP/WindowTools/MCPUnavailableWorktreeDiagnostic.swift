import Foundation

/// A refusal for an Agent session worktree binding whose folder is confirmed missing.
///
/// It lives for one tool call and renders the error text an agent reads. It holds the binding so
/// tests can compare identity, but the text it renders never contains an absolute path.
struct MCPUnavailableWorktreeDiagnostic: Equatable, Sendable {
    /// The routed tab that hit the missing worktree.
    struct RouteContext: Equatable, Sendable {
        let tabName: String
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

    func attachingRouteContext(from snapshot: MCPServerViewModel.TabContextSnapshot) -> MCPUnavailableWorktreeDiagnostic {
        MCPUnavailableWorktreeDiagnostic(
            binding: binding,
            routeContext: RouteContext(tabName: snapshot.tabName, windowID: snapshot.windowID)
        )
    }

    /// The refusal: the routed tab, when there is one, and the worktree that is missing from disk.
    var summary: String {
        guard let routeContext else {
            return "The Agent Mode session's worktree\(labelSuffix) is missing from disk."
        }
        return "\(subject(for: routeContext)) can't be used: its Agent Mode worktree\(labelSuffix) is missing from disk."
    }

    /// What the calling agent can do next.
    var recovery: String {
        "Retrying won't help. Tell the user so they can switch to another tab."
    }

    var message: String {
        "\(summary) \(recovery)"
    }

    /// The tab's name, or just its window when the name is withheld as unsafe to show.
    private func subject(for routeContext: RouteContext) -> String {
        if let tabName = safeIdentity(routeContext.tabName) {
            return "Tab '\(tabName)' (window \(routeContext.windowID))"
        }
        return "A tab in window \(routeContext.windowID)"
    }

    /// The worktree's quoted label with a leading space, or nothing when no safe label exists.
    private var labelSuffix: String {
        let label = [binding.visualLabel, binding.worktreeName, binding.branch, binding.worktreeID]
            .lazy
            .compactMap(safeIdentity)
            .first
        return label.map { " '\($0)'" } ?? ""
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
    static func displayValue(_ value: String) -> String? {
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
