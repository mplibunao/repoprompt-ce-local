import Foundation

/// Stops one structure-backed tool call from publishing a read's automatic selection after the call
/// lost its caller: its deadline passed, its request was cancelled, its connection or window closed, or
/// a capped window quarantined it. Each selection intent carries the fence of the read that produced it, and the
/// selection write skips intents whose fence is revoked. A protected mutation has no fence; its commit
/// arbiter (`DomainMutationCommitState`) is revoked at the same points instead.
package final class MCPDomainInvocationFence: @unchecked Sendable {
    /// The fence of the tool call running in this task. The MCP host sets it around the provider, and
    /// the read side-effect emitter sets it again inside the shared effect it submits.
    @TaskLocal package static var current: MCPDomainInvocationFence?

    private let lock = NSLock()
    private var origin: MCPToolExecutionCancellationOrigin?

    package init() {}

    /// The first revocation's origin, or nil while the call may still publish.
    package var revocationOrigin: MCPToolExecutionCancellationOrigin? {
        lock.withLock { origin }
    }

    package var isRevoked: Bool {
        revocationOrigin != nil
    }

    /// Synchronous and idempotent, so the watchdog and the settlement registry can call it while holding
    /// their own locks. A later revocation keeps the first origin.
    package func revoke(origin: MCPToolExecutionCancellationOrigin) {
        lock.withLock {
            if self.origin == nil {
                self.origin = origin
            }
        }
    }
}
