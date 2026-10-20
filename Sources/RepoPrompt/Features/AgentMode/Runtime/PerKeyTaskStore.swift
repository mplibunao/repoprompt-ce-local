import Foundation

@MainActor
final class PerKeyTaskStore<Key: Hashable> {
    private var tasks: [Key: (token: UUID, task: Task<Void, Never>)] = [:]

    func hasTask(for key: Key) -> Bool {
        tasks[key] != nil
    }

    /// Stores `task` under `key`, cancelling any task already stored there. A task that
    /// removes its own entry when it finishes passes the same token to `remove(_:ifToken:)`,
    /// so a replaced task that finishes late can't remove its successor.
    func set(_ key: Key, token: UUID = UUID(), task: Task<Void, Never>) {
        cancel(key)
        tasks[key] = (token, task)
    }

    func remove(_ key: Key) {
        _ = tasks.removeValue(forKey: key)
    }

    func remove(_ key: Key, ifToken token: UUID) {
        guard tasks[key]?.token == token else { return }
        tasks.removeValue(forKey: key)
    }

    func cancel(_ key: Key) {
        guard let entry = tasks.removeValue(forKey: key) else { return }
        entry.task.cancel()
    }

    func cancelAll() {
        let activeTasks = tasks.values.map(\.task)
        tasks.removeAll()
        for task in activeTasks {
            task.cancel()
        }
    }
}
