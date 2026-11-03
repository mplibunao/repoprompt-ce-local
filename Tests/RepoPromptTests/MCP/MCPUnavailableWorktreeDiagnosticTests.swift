@testable import RepoPromptApp
import XCTest

final class MCPUnavailableWorktreeDiagnosticTests: XCTestCase {
    private static let logicalRootPath = "/Volumes/rp-diagnostic-test/logical/app"
    private static let worktreeRootPath = "/Volumes/rp-diagnostic-test/worktrees/app-wt"
    private static let refusalTail = ", but that worktree's folder is missing or is not a directory. No canonical checkout was used."

    /// The refusal names the tab and the worktree, but a tab name or label that is a path, or that
    /// contains the binding's own paths, never reaches the text; the next usable value replaces it.
    /// Displayed values have control characters replaced and quotes and backslashes escaped.
    func testRefusalOmitsPathValuedNamesAndEscapesDisplayedValues() throws {
        let contextID = try XCTUnwrap(UUID(uuidString: "8B5D1C40-0E1B-4E0F-9C55-3A1B2C3D4E5F"))
        let tab = "Tab 'Feature tab' (context_id '\(contextID.uuidString)', window 7)"
        let contextOnly = "Context '\(contextID.uuidString)' in window 7"
        let session = "has an Agent Mode session bound to"
        let defaultWorktree = "worktree 'app-wt' (worktree_id 'wt-1') for root 'app-root'"

        let rows: [(label: String, tabName: String, binding: AgentSessionWorktreeBinding, expected: String)] = [
            (
                "absolute tab name",
                "/Users/someone/project",
                Self.binding(),
                "\(contextOnly) \(session) \(defaultWorktree)"
            ),
            (
                "tab name that is a path once line breaks are trimmed",
                "\n  /Users/someone/project",
                Self.binding(),
                "\(contextOnly) \(session) \(defaultWorktree)"
            ),
            (
                "home-relative tab name",
                "~/project",
                Self.binding(),
                "\(contextOnly) \(session) \(defaultWorktree)"
            ),
            (
                "file URL tab name, any case",
                "File:///Users/someone/project",
                Self.binding(),
                "\(contextOnly) \(session) \(defaultWorktree)"
            ),
            (
                "absolute visual label",
                "Feature tab",
                Self.binding(visualLabel: Self.worktreeRootPath),
                "\(tab) \(session) \(defaultWorktree)"
            ),
            (
                "home-relative visual label",
                "Feature tab",
                Self.binding(visualLabel: "~/worktrees/app-wt"),
                "\(tab) \(session) \(defaultWorktree)"
            ),
            (
                "file URL visual label",
                "Feature tab",
                Self.binding(visualLabel: "file://host/app-wt"),
                "\(tab) \(session) \(defaultWorktree)"
            ),
            (
                "visual label containing the logical root path",
                "Feature tab",
                Self.binding(visualLabel: "copy of \(Self.logicalRootPath)"),
                "\(tab) \(session) \(defaultWorktree)"
            ),
            (
                "worktree name containing the worktree path",
                "Feature tab",
                Self.binding(worktreeName: "wt at \(Self.worktreeRootPath)"),
                "\(tab) \(session) worktree 'feature/app' (worktree_id 'wt-1') for root 'app-root'"
            ),
            (
                "every label and the worktree ID are paths",
                "Feature tab",
                Self.binding(worktreeName: nil, branch: nil, worktreeID: Self.worktreeRootPath),
                "\(tab) \(session) a worktree for root 'app-root'"
            ),
            (
                "root name that is a path",
                "Feature tab",
                Self.binding(logicalRootName: Self.logicalRootPath),
                "\(tab) \(session) worktree 'app-wt' (worktree_id 'wt-1') for root 'app'"
            ),
            (
                "control characters, quotes, and backslashes",
                "Bob's \"tab\"\tnew\nline\u{1B}\\end",
                Self.binding(visualLabel: "it's \"wt\"\r\\x"),
                "Tab 'Bob\\'s \\\"tab\\\" new line \\\\end' (context_id '\(contextID.uuidString)', window 7) "
                    + "\(session) worktree 'it\\'s \\\"wt\\\" \\\\x' (worktree_id 'wt-1') for root 'app-root'"
            )
        ]

        for row in rows {
            let diagnostic = MCPUnavailableWorktreeDiagnostic(
                binding: row.binding,
                routeContext: .init(tabName: row.tabName, contextID: contextID, windowID: 7)
            )
            XCTAssertEqual(diagnostic.summary, row.expected + Self.refusalTail, row.label)
        }
    }

    private static func binding(
        visualLabel: String? = nil,
        worktreeName: String? = "app-wt",
        branch: String? = "feature/app",
        worktreeID: String = "wt-1",
        logicalRootName: String? = "app-root"
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repository-1",
            repoKey: logicalRootPath,
            logicalRootPath: logicalRootPath,
            logicalRootName: logicalRootName,
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            worktreeName: worktreeName,
            branch: branch,
            visualLabel: visualLabel,
            source: "test"
        )
    }
}
