@testable import RepoPromptApp
import XCTest

final class MCPUnavailableWorktreeDiagnosticTests: XCTestCase {
    private static let logicalRootPath = "/Volumes/rp-diagnostic-test/logical/app"
    private static let worktreeRootPath = "/Volumes/rp-diagnostic-test/worktrees/app-wt"
    private static let recovery = "Retrying won't help. Tell the user so they can switch to another tab."

    /// The refusal names the tab and the worktree label, but a tab name or label that is a path, or that
    /// contains the binding's own paths, never reaches the text; the next usable value replaces it, and a
    /// tab name with none leaves only its window. The label comes from the visual label, then the worktree
    /// name, then the branch, then the worktree ID. Displayed values have control characters replaced and
    /// quotes and backslashes escaped.
    func testRefusalOmitsPathValuedNamesAndEscapesDisplayedValues() {
        let tab = "Tab 'Feature tab' (window 7) can't be used: its Agent Mode worktree"
        let windowOnly = "A tab in window 7 can't be used: its Agent Mode worktree"
        let missing = "is missing from disk."

        let rows: [(label: String, tabName: String, binding: AgentSessionWorktreeBinding, expected: String)] = [
            (
                "absolute tab name",
                "/Users/someone/project",
                Self.binding(),
                "\(windowOnly) 'app-wt' \(missing)"
            ),
            (
                "tab name that is a path once line breaks are trimmed",
                "\n  /Users/someone/project",
                Self.binding(),
                "\(windowOnly) 'app-wt' \(missing)"
            ),
            (
                "home-relative tab name",
                "~/project",
                Self.binding(),
                "\(windowOnly) 'app-wt' \(missing)"
            ),
            (
                "file URL tab name, any case",
                "File:///Users/someone/project",
                Self.binding(),
                "\(windowOnly) 'app-wt' \(missing)"
            ),
            (
                "visual label comes first",
                "Feature tab",
                Self.binding(visualLabel: "Visual label"),
                "\(tab) 'Visual label' \(missing)"
            ),
            (
                "absolute visual label",
                "Feature tab",
                Self.binding(visualLabel: Self.worktreeRootPath),
                "\(tab) 'app-wt' \(missing)"
            ),
            (
                "home-relative visual label",
                "Feature tab",
                Self.binding(visualLabel: "~/worktrees/app-wt"),
                "\(tab) 'app-wt' \(missing)"
            ),
            (
                "file URL visual label",
                "Feature tab",
                Self.binding(visualLabel: "file://host/app-wt"),
                "\(tab) 'app-wt' \(missing)"
            ),
            (
                "visual label containing the logical root path",
                "Feature tab",
                Self.binding(visualLabel: "copy of \(Self.logicalRootPath)"),
                "\(tab) 'app-wt' \(missing)"
            ),
            (
                "worktree name containing the worktree path falls back to the branch",
                "Feature tab",
                Self.binding(worktreeName: "wt at \(Self.worktreeRootPath)"),
                "\(tab) 'feature/app' \(missing)"
            ),
            (
                "worktree ID is the last fallback",
                "Feature tab",
                Self.binding(worktreeName: nil, branch: nil),
                "\(tab) 'wt-1' \(missing)"
            ),
            (
                "every label and the worktree ID are paths",
                "Feature tab",
                Self.binding(worktreeName: nil, branch: nil, worktreeID: Self.worktreeRootPath),
                "\(tab) \(missing)"
            ),
            (
                "control characters, quotes, and backslashes",
                "Bob's \"tab\"\tnew\nline\u{1B}\\end",
                Self.binding(visualLabel: "it's \"wt\"\r\\x"),
                "Tab 'Bob\\'s \\\"tab\\\" new line \\\\end' (window 7) can't be used: "
                    + "its Agent Mode worktree 'it\\'s \\\"wt\\\" \\\\x' \(missing)"
            )
        ]

        for row in rows {
            let diagnostic = MCPUnavailableWorktreeDiagnostic(
                binding: row.binding,
                routeContext: .init(tabName: row.tabName, windowID: 7)
            )
            XCTAssertEqual(diagnostic.summary, row.expected, row.label)
        }
    }

    /// The decided agent-facing text: a summary naming the tab (when routed) and the missing worktree,
    /// then a recovery that tells the agent to have the user switch tabs.
    func testMessageIsTheSummaryFollowedByTheRecoveryWithAndWithoutARoutedTab() {
        let binding = Self.binding(visualLabel: "rpce-332")

        let routed = MCPUnavailableWorktreeDiagnostic(
            binding: binding,
            routeContext: .init(tabName: "rpce-332 stale worktree", windowID: 9)
        )
        XCTAssertEqual(
            routed.summary,
            "Tab 'rpce-332 stale worktree' (window 9) can't be used: its Agent Mode worktree 'rpce-332' is missing from disk."
        )
        XCTAssertEqual(routed.recovery, Self.recovery)
        XCTAssertEqual(routed.message, "\(routed.summary) \(Self.recovery)")

        let unrouted = MCPUnavailableWorktreeDiagnostic(binding: binding)
        XCTAssertEqual(unrouted.summary, "The Agent Mode session's worktree 'rpce-332' is missing from disk.")
        XCTAssertEqual(unrouted.message, "\(unrouted.summary) \(Self.recovery)")

        let unlabeled = MCPUnavailableWorktreeDiagnostic(
            binding: Self.binding(worktreeName: nil, branch: nil, worktreeID: Self.worktreeRootPath)
        )
        XCTAssertEqual(unlabeled.summary, "The Agent Mode session's worktree is missing from disk.")
    }

    private static func binding(
        visualLabel: String? = nil,
        worktreeName: String? = "app-wt",
        branch: String? = "feature/app",
        worktreeID: String = "wt-1"
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repository-1",
            repoKey: logicalRootPath,
            logicalRootPath: logicalRootPath,
            logicalRootName: "app-root",
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            worktreeName: worktreeName,
            branch: branch,
            visualLabel: visualLabel,
            source: "test"
        )
    }
}
