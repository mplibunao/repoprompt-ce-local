import Foundation
import RepoPromptShared

/// Every text in which the helper tells a person or an agent that it cannot reach its app.
///
/// The offline responder, the exec and interactive modes, and the socket error descriptions all
/// take their wording from here, so a fact about the failure and its remedy is stated the same way
/// on each surface. Each text names the app (`RepoPrompt CE` or `RepoPrompt CE Debug`), because the
/// two run side by side and a client configured for one cannot tell from the helper's name which
/// one is missing. Callers pass an explicit identity; production code passes
/// `MCPFilesystemConstants.identity`.
enum MCPAppConnectionMessages {
    /// Why the helper has no working connection to its app.
    enum Condition: Equatable, Sendable {
        /// The bootstrap socket is missing or refuses connections. The app may not be running, or its
        /// MCP Server may be switched off; the socket alone cannot tell which.
        case unavailable
        /// The app accepted the socket and is waiting for a person to approve this client.
        case awaitingApproval
        /// The app refused this client's connection request.
        case approvalDenied
        /// The operating system refused access to the socket, typically inside a sandbox.
        case socketPermissionDenied(errno: Int32)
        /// The app accepted the socket but did not answer the bootstrap handshake in time.
        case bootstrapTimeout
        /// Any other transport or bootstrap failure, with the failure's own diagnostic.
        case transportFailure(reason: String)

        /// True while the helper keeps trying without the client doing anything. A client that is
        /// waiting on approval, or was refused, is told what to do instead.
        fileprivate var helperReconnects: Bool {
            switch self {
            case .unavailable, .socketPermissionDenied, .bootstrapTimeout, .transportFailure:
                true
            case .awaitingApproval, .approvalDenied:
                false
            }
        }
    }

    static let reconnectNotice = "This helper reconnects automatically."

    /// The cause and remedy, for exec and interactive output and for error descriptions.
    static func text(for condition: Condition, identity: MCPFilesystemIdentity) -> String {
        let app = identity.appDisplayName
        switch condition {
        case .unavailable:
            return "Cannot connect to \(app). The app is not running or its MCP Server is disabled. "
                + "Start \(app) and enable MCP Server in Settings > MCP, then retry."
        case .awaitingApproval:
            return "\(app) is running and waiting for you to approve this client. "
                + "Approve it in \(app), then retry."
        case .approvalDenied:
            return "Connection approval denied. Your connection request was rejected by \(app). "
                + "Check the MCP approval dialog in \(app)."
        case let .socketPermissionDenied(errno):
            return "Cannot connect to \(app): permission denied on its MCP socket (errno \(errno)). "
                + "If this client runs in a sandbox, for example Codex, disable the sandbox "
                + "or grant it Unix socket access, then retry."
        case .bootstrapTimeout:
            return "\(app) did not respond to the bootstrap handshake. "
                + "It accepted the socket connection too slowly or is wedged. "
                + "If it recently crashed under the debugger, restart it and try again."
        case let .transportFailure(reason):
            return "Cannot connect to \(app) (\(reason)). It may be busy or restarting; retry shortly."
        }
    }

    /// The description of a failed `connect(2)` to the app's socket, chosen by its `errno`.
    static func connectFailure(errno: Int32, identity: MCPFilesystemIdentity) -> String {
        if errno == EPERM || errno == EACCES {
            return text(for: .socketPermissionDenied(errno: errno), identity: identity)
        } else if errno == ENOENT || errno == ECONNREFUSED {
            return text(for: .unavailable, identity: identity)
        }
        return "Failed to connect: \(errno)"
    }

    /// The text the helper returns to its client while it has no working connection: the same cause
    /// and remedy, plus the reconnect notice when the helper is retrying on its own.
    static func offlineText(for condition: Condition, identity: MCPFilesystemIdentity) -> String {
        let base = text(for: condition, identity: identity)
        return condition.helperReconnects ? "\(base) \(reconnectNotice)" : base
    }

    /// The `instructions` of an `initialize` result the helper answers itself. They say nothing about
    /// the catalog, routing, policy, or Code Maps, which depend on the app, so they stay accurate
    /// after the helper attaches.
    static func offlineInstructions(identity: MCPFilesystemIdentity) -> String {
        "RepoPrompt tools require \(identity.appDisplayName) with MCP Server enabled. "
            + "\(reconnectNotice) "
            + "If your client does not refresh its tool list after the app starts, start a new client session."
    }

    static func waitingForApp(attempt: Int, identity: MCPFilesystemIdentity) -> String {
        "Waiting for \(identity.appDisplayName) (attempt \(attempt))..."
    }

    static func retryingStalledBootstrap(attempt: Int, identity: MCPFilesystemIdentity) -> String {
        "Retrying stalled \(identity.appDisplayName) bootstrap handshake (attempt \(attempt))..."
    }
}
