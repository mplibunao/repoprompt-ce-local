import RepoPromptShared
import XCTest

/// `docs/porting.md` requires upstream ports of the Orchestrate and Optimize prompts to keep the text these tests check.
final class WorkflowPromptRunRecordTests: XCTestCase {
    private static let renderCases: [(label: String, variant: WorkflowPromptVariant, includeSessionCleanupGuidance: Bool)] = [
        ("mcp, cleanup guidance on", .mcp, true),
        ("mcp, cleanup guidance off", .mcp, false),
        ("cli, cleanup guidance on", .cli, true),
        ("cli, cleanup guidance off", .cli, false),
        ("agent, cleanup guidance on", .agent, true),
        ("agent, cleanup guidance off", .agent, false)
    ]

    func testOrchestrateRecordsRunsInLedgerAndLeavesPlanDeletionToUser() {
        for testCase in Self.renderCases {
            let prompt = RepoPromptWorkflowPrompts.render(
                id: .orchestrate,
                variant: testCase.variant,
                includeSessionCleanupGuidance: testCase.includeSessionCleanupGuidance
            )

            XCTAssertTrue(prompt.contains("Record the item in the run ledger"), testCase.label)
            XCTAssertTrue(prompt.contains("Is the work done, so I can delete"), testCase.label)
            XCTAssertFalse(prompt.contains("living checklist"), testCase.label)
            XCTAssertFalse(prompt.contains("- [x] Item 1:"), testCase.label)
            XCTAssertFalse(prompt.contains("in the export file"), testCase.label)
            XCTAssertEqual(
                prompt.contains("Export cleanup never covers the run's plan"),
                testCase.includeSessionCleanupGuidance,
                testCase.label
            )
        }
    }

    func testOptimizeWritesScoreboardInLedgers() {
        for testCase in Self.renderCases {
            let prompt = RepoPromptWorkflowPrompts.render(
                id: .optimize,
                variant: testCase.variant,
                includeSessionCleanupGuidance: testCase.includeSessionCleanupGuidance
            )

            XCTAssertTrue(prompt.contains("docs/ledgers/<YYYY-MM-DD>-optimize-<slug>.md"), testCase.label)
            XCTAssertTrue(prompt.contains("Rejected candidates"), testCase.label)
            XCTAssertFalse(prompt.contains("prompt-exports/optimize-"), testCase.label)
        }
    }
}
