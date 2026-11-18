import Darwin
import Foundation
import RepoPromptShared

/// Reads the client's newline-delimited frames from stdin for whichever part of the proxy owns
/// the client right now: the bridge to the app, or the offline loop that answers locally.
///
/// Ownership moves between them only at a frame boundary. A run that is asked to hand off
/// returns every byte it read but did not consume, in order, so the next owner processes them
/// before it reads stdin again and no frame is lost, split, or delivered twice.
enum MCPProxyStdinPump {
    enum Result: Equatable {
        /// Stdin reached EOF or hung up with no partial frame left.
        case stdinClosed
        /// The owner asked to stop. The bytes are complete frames not yet consumed, followed by
        /// any partial trailing frame.
        case handoff(unreadBytes: Data)
    }

    /// - Parameters:
    ///   - initialBytes: Unread bytes from the previous owner, consumed before stdin is read.
    ///   - shouldHandOff: Runs at each frame boundary, before a frame is taken and before each
    ///     read of stdin, and returns true to stop there. The owner may also do its own boundary
    ///     work in it, such as writing replies. A frame already passed to `consumeFrame` always
    ///     finishes first.
    ///   - consumeFrame: Receives each complete frame with its trailing newline.
    /// - Throws: Host-input and ledger errors, owner and consumer errors, and `CancellationError`.
    static func run(
        stdinFD: Int32,
        initialBytes: Data,
        ledger: JSONRPCBridgeLedger,
        identityCache: ClientIdentityCache,
        shouldHandOff: () async throws -> Bool = { false },
        consumeFrame: (Data) async throws -> Void
    ) async throws -> Result {
        let flags = fcntl(stdinFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(stdinFD, F_SETFL, flags | O_NONBLOCK)
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        var pending = initialBytes
        var hasCachedIdentity = false

        // Returns true when the owner asked to hand off before the next complete frame.
        func consumeCompleteFrames() async throws -> Bool {
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                if try await shouldHandOff() {
                    return true
                }
                let message = Data(pending[..<newline])
                pending = Data(pending[(newline + 1)...])

                // The bootstrap handshake after a reconnect names the client from its first initialize.
                if !hasCachedIdentity, let name = extractMCPClientName(from: message) {
                    hasCachedIdentity = true
                    await identityCache.setIfEmpty(name)
                }

                var payload = message
                payload.append(UInt8(ascii: "\n"))
                try await consumeFrame(payload)
            }
            return false
        }

        if try await consumeCompleteFrames() {
            return .handoff(unreadBytes: pending)
        }

        while true {
            try Task.checkCancellation()
            if try await shouldHandOff() {
                return .handoff(unreadBytes: pending)
            }

            var pfd = pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0)
            // The one-second timeout bounds how long a cancellation or a requested handoff waits
            // while the client sends nothing.
            let pollResult = poll(&pfd, 1, 1000)

            if pollResult < 0 {
                try validateCLIHostInputPollResult(pollResult, errno: errno)
                continue
            }
            if pollResult == 0 {
                continue
            }

            let revents = Int32(pfd.revents)
            if revents & (POLLERR | POLLNVAL) != 0 {
                debugLog("MCPProxyStdinPump: stdin error - host disconnected")
                throw SocketProxyError.hostDisconnected
            }
            let sawHangup = revents & POLLHUP != 0
            if revents & POLLIN == 0 {
                if sawHangup {
                    debugLog("MCPProxyStdinPump: stdin hangup after draining input")
                    try await BootstrapSocketProxy.requireCleanBridgeStop(
                        ledger: ledger,
                        direction: .clientToServer,
                        pendingByteCount: pending.count,
                        reason: "stdin_hangup"
                    )
                    return .stdinClosed
                }
                continue
            }

            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(stdinFD, ptr.baseAddress!, ptr.count)
            }

            if bytesRead < 0 {
                try validateCLIHostInputReadResult(bytesRead, errno: errno)
                continue
            }
            if bytesRead == 0 {
                debugLog("MCPProxyStdinPump: stdin EOF after draining input")
                try await BootstrapSocketProxy.requireCleanBridgeStop(
                    ledger: ledger,
                    direction: .clientToServer,
                    pendingByteCount: pending.count,
                    reason: "stdin_eof"
                )
                return .stdinClosed
            }

            pending.append(contentsOf: buffer[0 ..< bytesRead])
            debugLog("MCPProxyStdinPump: read \(bytesRead) bytes from stdin, pending=\(pending.count)")

            if try await consumeCompleteFrames() {
                return .handoff(unreadBytes: pending)
            }

            if sawHangup {
                debugLog("MCPProxyStdinPump: stdin hangup after consuming complete frames")
                try await BootstrapSocketProxy.requireCleanBridgeStop(
                    ledger: ledger,
                    direction: .clientToServer,
                    pendingByteCount: pending.count,
                    reason: "stdin_hangup"
                )
                return .stdinClosed
            }
        }
    }

    /// The `clientInfo.name` of an MCP `initialize` request, or nil for any other frame.
    private static func extractMCPClientName(from data: Data) -> String? {
        // A substring check skips the JSON parse for every frame that cannot be an initialize.
        guard let str = String(data: data, encoding: .utf8),
              str.contains("\"initialize\""),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              method == "initialize",
              let params = json["params"] as? [String: Any],
              let clientInfo = params["clientInfo"] as? [String: Any],
              let name = clientInfo["name"] as? String
        else {
            return nil
        }

        debugLog("Extracted MCP client name from initialize: \(name)")
        return name
    }
}
