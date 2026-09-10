@testable import RepoPromptApp
import XCTest

final class AgentSessionColdRestoreRunStateTests: XCTestCase {
    /// Recovery attributes a persisted `completed` run to the dispatch that minted its session, which
    /// only holds while a crash cannot leave a session looking completed: every active state is
    /// rewritten to `idle` on the cold-restore read, and terminal states pass through untouched.
    func testColdRestoredLastRunStateRawRewritesOnlyActiveStates() {
        for active in [
            AgentSessionRunState.running,
            .waitingForUser,
            .waitingForQuestion,
            .waitingForApproval
        ] {
            XCTAssertEqual(
                AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(active.rawValue),
                AgentSessionRunState.idle.rawValue,
                active.rawValue
            )
        }
        for terminal in [
            AgentSessionRunState.idle,
            .completed,
            .cancelled,
            .failed
        ] {
            XCTAssertEqual(
                AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(terminal.rawValue),
                terminal.rawValue,
                terminal.rawValue
            )
        }
        XCTAssertNil(AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(nil))
        XCTAssertEqual(
            AgentSessionRestoreSupport.coldRestoredLastRunStateRaw("futureRunState"),
            "futureRunState"
        )
    }
}
