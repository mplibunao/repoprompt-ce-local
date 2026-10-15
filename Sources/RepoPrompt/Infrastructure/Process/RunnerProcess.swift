import Darwin
import Foundation

/// A child launched by `CLIProcessRunner`, holding the pipe endpoints the runner owns.
///
/// The runner's finalizer and cancellation fast path capture this record when they are created
/// instead of looking it up in the registry, because the fast path can remove the entry first.
// Explicit so the compiler checks the record where it crosses into detached tasks and @Sendable
// closures.
// swiftformat:disable:next redundantSendable
struct RunnerProcess: Sendable {
    let pid: pid_t
    let processGroupID: pid_t?
    let input: PipeEndpoint
    let stdout: PipeEndpoint
    let stderr: PipeEndpoint
    let drain: DrainControl
    let reap: RootReapState
}

/// Whether the runner has reaped a root child. Once it has, the system may give the child's PID,
/// which is also its process-group ID, to another process, so cancellation stops signaling it.
final class RootReapState: @unchecked Sendable {
    private let lock = NSLock()
    private var reaped = false

    /// Called by the wait task as soon as its wait for the root child returns.
    func markReaped() {
        lock.withLock { reaped = true }
    }

    /// Runs `send` only while the root is unreaped, and returns what it returns: whether the signal
    /// was sent. Returns false without running `send` once the root is reaped. The lock is held
    /// across `send`, so `markReaped()` cannot return while a signal decided before it is still
    /// being sent.
    func signalIfUnreaped(_ send: () -> Bool) -> Bool {
        lock.withLock {
            guard !reaped else { return false }
            return send()
        }
    }
}

/// Lets cancellation end a run's post-exit output drain early.
///
/// The cancellation is sticky, because a run can be cancelled before its drain starts: both
/// streaming consumers cancel the runner at `message_stop` while the child is still running.
final class DrainControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var wakeUp: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Marks the drain cancelled and fires the current wait's wake-up, if one is registered.
    func cancel() {
        let pendingWakeUp = lock.withLock { () -> (@Sendable () -> Void)? in
            cancelled = true
            defer { wakeUp = nil }
            return wakeUp
        }
        pendingWakeUp?()
    }

    /// Registers the wake-up for one wait. Returns false, registering nothing, when the drain is
    /// already cancelled; the wait then ends at once instead of suspending.
    func registerWakeUp(_ wakeUp: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.wakeUp = wakeUp
            return true
        }
    }

    /// Removes the wake-up once its wait has resumed.
    func clearWakeUp() {
        lock.withLock { wakeUp = nil }
    }
}
