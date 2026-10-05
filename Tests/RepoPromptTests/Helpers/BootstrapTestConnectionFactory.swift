import Darwin
import Foundation
@testable import RepoPromptApp

#if DEBUG
    /// Builds the two ends of a bootstrap MCP connection over a socket pair, so a test can put the
    /// server end through production registration without a listening socket. Nothing is started
    /// or registered here, and the caller owns closing both ends.
    @MainActor
    enum BootstrapTestConnectionFactory {
        static func make(
            connectionID: UUID,
            sessionToken: String,
            clientName: String,
            clientPid: Int,
            observedKernelPeerPID: Int,
            parentManager: ServerNetworkManager
        ) throws -> (client: PersistentMCPTestSocketClient, connectionManager: BootstrapSocketConnectionManager) {
            var socketFDs = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                throw PersistentMCPTestSocketClient.ClientError.posix(operation: "socketpair", code: errno)
            }
            // A write on the client end after the app closed its end must fail that request, not
            // end the test process with SIGPIPE.
            var noSigPipe: Int32 = 1
            guard Darwin.setsockopt(
                socketFDs[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            ) == 0 else {
                let code = errno
                Darwin.close(socketFDs[0])
                Darwin.close(socketFDs[1])
                throw PersistentMCPTestSocketClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
            }
            let client = PersistentMCPTestSocketClient(fd: socketFDs[0])
            do {
                let connectionManager = try BootstrapSocketConnectionManager(
                    connectionID: connectionID,
                    sessionToken: sessionToken,
                    clientPid: clientPid,
                    observedKernelPeerPID: observedKernelPeerPID,
                    clientName: clientName,
                    purpose: .unknown,
                    codeMapsDisabled: false,
                    connectedFD: socketFDs[1],
                    parentManager: parentManager
                )
                return (client, connectionManager)
            } catch {
                client.close()
                Darwin.close(socketFDs[1])
                throw error
            }
        }
    }
#endif
