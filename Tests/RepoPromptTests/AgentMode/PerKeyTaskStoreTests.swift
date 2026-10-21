@testable import RepoPromptApp
import XCTest

@MainActor
final class PerKeyTaskStoreTests: XCTestCase {
    func testReplacedTaskCannotRemoveItsSuccessor() async {
        let store = PerKeyTaskStore<String>()
        let key = "tab"

        // Shaped like an idle timer: the task removes its own entry once its sleep ends,
        // which a replacement's cancellation makes happen at once.
        let replacedToken = UUID()
        let replaced = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3600))
            store.remove(key, ifToken: replacedToken)
        }
        store.set(key, token: replacedToken, task: replaced)

        let successor = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(3600))
        }
        store.set(key, token: UUID(), task: successor)
        XCTAssertTrue(replaced.isCancelled)
        replaced.cancel()
        await replaced.value

        XCTAssertTrue(store.hasTask(for: key))
        store.cancel(key)
        XCTAssertTrue(successor.isCancelled)
        XCTAssertFalse(store.hasTask(for: key))
        successor.cancel()
        await successor.value
    }
}
