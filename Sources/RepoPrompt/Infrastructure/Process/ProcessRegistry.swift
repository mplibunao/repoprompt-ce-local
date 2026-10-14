import Darwin

actor ProcessRegistry {
    private var children: [pid_t: RunnerProcess] = [:]

    func add(_ process: RunnerProcess) {
        children[process.pid] = process
    }

    func remove(pid: pid_t) -> RunnerProcess? {
        children.removeValue(forKey: pid)
    }

    func current() -> [RunnerProcess] {
        Array(children.values)
    }
}
