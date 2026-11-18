import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

/// Whole proxy sessions through `MCPProxySession.run`, over pipes, against a fake app that listens
/// on a temporary bootstrap socket only when a test starts it.
final class MCPProxyOfflineStartupTests: XCTestCase {
    private let identity = MCPFilesystemIdentity.repoPromptCE(.debug)

    func testUnavailableAppAnswersLocallyWithoutWaitingForRetry() async throws {
        for identity in [MCPFilesystemIdentity.repoPromptCE(.release), .repoPromptCE(.debug)] {
            let label = identity.appDisplayName
            let harness = try makeHarness(identity: identity)
            harness.start()

            // The retry gate stays closed, so none of these answers can depend on a retry.
            let initialize = try await harness.initializeOffline()
            let serverInfo = (initialize["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
            XCTAssertEqual(serverInfo?["name"] as? String, identity.appDisplayName, label)

            let list = try await harness.client.request(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
            let tools = (list["result"] as? [String: Any])?["tools"] as? [Any]
            XCTAssertEqual(tools?.count, 0, label)

            let call = try await harness.client.request(toolCall(id: 2, name: "read_file"))
            XCTAssertTrue(isErrorResult(call), label)
            XCTAssertEqual(
                resultText(call),
                MCPAppConnectionMessages.offlineText(for: .unavailable, identity: identity),
                label
            )

            _ = try await harness.retryGate.started.first(where: { $0 == 1 }, "the worker's first retry wait")
            harness.client.closeStdin()
            let ending = try await harness.finish()
            assertHostDisconnected(ending, .stdinClosed, label)
            XCTAssertEqual(harness.retryGate.counts.cancelled, 1, "\(label): the blocked retry wait was cancelled")
        }
    }

    /// A socket file with no listener is an app that is starting or busy. The first attempt retries it
    /// once, so an Agent Mode run doesn't lose its tools to a transient refusal, and only once, so
    /// the client never waits on an app that isn't coming.
    func testRefusedFirstConnectionGetsExactlyOneRetry() async throws {
        for appStartsListening in [false, true] {
            let label = appStartsListening ? "the app starts listening before the retry" : "the app stays unreachable"
            let harness = try makeHarness(identity: identity)
            try FakeApp(socketURL: harness.socketURL).stopListening()
            harness.start()

            // The helper reads no stdin until its first attempt ends, so this wait is the retry.
            _ = try await harness.retryGate.started.first(where: { $0 == 1 }, "\(label): the first attempt's retry wait")
            var app: FakeApp?
            if appStartsListening {
                unlink(harness.socketURL.path)
                app = try harness.startFakeApp()
            }
            // Releases this wait only. The offline worker waits after the client's initialize
            // result, so every later wait finds the gate closed.
            harness.retryGate.open()
            harness.retryGate.close()

            if let app {
                let connection = try await app.accept()
                _ = try await connection.acceptBootstrap()
                _ = try await harness.phases.first(where: { $0 == .connected }, "\(label): the session served by the app")
                XCTAssertFalse(connection.peerHasClosed(), label)
            } else {
                // A second retry would hold this answer behind the closed gate.
                let initialize = try await harness.initializeOffline()
                let serverInfo = (initialize["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
                XCTAssertEqual(serverInfo?["name"] as? String, identity.appDisplayName, label)
                _ = try await harness.retryGate.started.first(where: { $0 == 2 }, "\(label): the worker's first retry wait")
            }

            harness.client.closeStdin()
            let ending = try await harness.finish()
            assertHostDisconnected(ending, .stdinClosed, label)
            XCTAssertEqual(harness.retryGate.counts.started, app == nil ? 2 : 1, "\(label): the retry waits")
        }
    }

    func testLateAppAdmissionRefreshesToolsOnTheSameClient() async throws {
        let harness = try makeHarness(identity: identity)
        harness.start()
        _ = try await harness.initializeOffline()

        let app = try harness.startFakeApp()
        harness.retryGate.open()
        let connection = try await app.accept()
        _ = try await connection.acceptBootstrap()
        let replayed = try await connection.readMessage()
        XCTAssertEqual(replayed["method"] as? String, "initialize")

        // The app holds its answer to the replayed initialize, as it does while a person decides.
        let waiting = try await harness.client.request(toolCall(id: 1, name: "read_file"))
        XCTAssertTrue(isErrorResult(waiting))
        XCTAssertEqual(
            resultText(waiting),
            MCPAppConnectionMessages.offlineText(for: .awaitingApproval, identity: identity)
        )

        try connection.send(appInitializeResult(for: replayed))
        let initialized = try await connection.readMessage()
        XCTAssertEqual(initialized["method"] as? String, "notifications/initialized")
        let changed = try await harness.client.readMessage()
        XCTAssertEqual(changed["method"] as? String, ToolListChangedNotification.name)

        try harness.client.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let listRequest = try await connection.readMessage()
        XCTAssertEqual(listRequest["method"] as? String, "tools/list")
        try connection.send([
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["tools": [["name": "get_file_tree", "inputSchema": ["type": "object"]]]]
        ])
        let list = try await harness.client.readMessage()
        let toolNames = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(toolNames, ["get_file_tree"])

        try harness.client.send(toolCall(id: 3, name: "get_file_tree"))
        let callRequest = try await connection.readMessage()
        XCTAssertEqual(callRequest["id"] as? Int, 3)
        XCTAssertEqual((callRequest["params"] as? [String: Any])?["name"] as? String, "get_file_tree")
        try connection.send(["jsonrpc": "2.0", "id": 3, "result": ["content": [["type": "text", "text": "tree from the app"]]]])
        let call = try await harness.client.readMessage()
        XCTAssertFalse(isErrorResult(call))
        XCTAssertEqual(resultText(call), "tree from the app")

        harness.client.closeStdin()
        let ending = try await harness.finish()
        assertHostDisconnected(ending, .stdinClosed)
    }

    func testHandoffPreservesCompleteAndPartialUnreadFrames() async throws {
        try await assertHandoffFromOfflineLoopToBridge(label: "offline loop to bridge")
        try await assertHandoffFromBridgeToOfflineLoop(label: "bridge to offline loop after a socket failure")
    }

    /// Frames A to D, as one chunk holding A, B, C, and the head of D, and the rest of D.
    private func handoffFrames() throws -> (chunk: Data, restOfD: Data) {
        let frameD = try jsonLine(toolCall(id: 13, name: "get_file_tree"))
        let splitIndex = frameD.count / 2
        var chunk = Data()
        try chunk.append(jsonLine(toolCall(id: 10, name: "read_file")))
        try chunk.append(jsonLine(toolCall(id: 11, name: "file_search")))
        try chunk.append(jsonLine(["jsonrpc": "2.0", "id": 12, "method": "tools/list"]))
        chunk.append(frameD.prefix(splitIndex))
        return (chunk, Data(frameD.suffix(from: splitIndex)))
    }

    private func assertHandoffFromOfflineLoopToBridge(label: String) async throws {
        let harness = try makeHarness(identity: identity)
        harness.start()
        _ = try await harness.initializeOffline()

        let app = try harness.startFakeApp()
        harness.retryGate.open()
        let connection = try await app.accept()
        _ = try await connection.acceptBootstrap()
        let replayed = try await connection.readMessage()

        // A full stdout pipe holds the offline loop inside its reply to frame A, so the handoff
        // falls between A and B with B, C, and the head of D already read from stdin.
        let fillerByteCount = try harness.client.fillStdoutPipe()
        let (chunk, restOfD) = try handoffFrames()
        try harness.client.sendRaw(chunk)

        _ = try await harness.trace.first(where: { event in
            event.phase == "frame_prepared" && event.direction == .serverToClient && event.id == .number(10)
        }, "the offline reply to frame A")
        try connection.send(appInitializeResult(for: replayed))
        _ = try await harness.phases.first(where: { $0 == .attachmentReady }, "attachment readiness")
        try await harness.client.discardStdout(byteCount: fillerByteCount)

        let localReply = try await harness.client.readMessage()
        XCTAssertEqual(localReply["id"] as? Int, 10, label)
        XCTAssertTrue(isErrorResult(localReply), label)
        let changed = try await harness.client.readMessage()
        XCTAssertEqual(changed["method"] as? String, ToolListChangedNotification.name, label)

        var appFrames: [[String: Any]] = []
        for _ in 0 ..< 3 {
            try await appFrames.append(connection.readMessage())
        }
        try harness.client.sendRaw(restOfD)
        try await appFrames.append(connection.readMessage())
        XCTAssertEqual(appFrames.map { $0["method"] as? String }, ["notifications/initialized", "tools/call", "tools/list", "tools/call"], label)
        XCTAssertEqual(appFrames.map { $0["id"] as? Int }, [nil, 11, 12, 13], label)

        for id in [11, 12, 13] {
            try connection.send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": "app \(id)"]]]])
        }
        var clientIDs: [Int?] = []
        for _ in 0 ..< 3 {
            try await clientIDs.append(harness.client.readMessage()["id"] as? Int)
        }
        XCTAssertEqual(clientIDs, [11, 12, 13], label)

        harness.client.closeStdin()
        let ending = try await harness.finish()
        assertHostDisconnected(ending, .stdinClosed, label)
        let laterAppFrames = try await connection.readRemainingMessages()
        XCTAssertTrue(laterAppFrames.isEmpty, "\(label): the app received a frame twice: \(laterAppFrames)")
    }

    private func assertHandoffFromBridgeToOfflineLoop(label: String) async throws {
        let harness = try makeHarness(identity: identity)
        _ = try await harness.connectDirectly()

        // The ledger holds the bridge inside its forwarding of frame A while the app quits, so the
        // bridge's stdin pump stops between A and B with B, C, and the head of D already read.
        harness.ledgerHold.arm { event in
            event.phase == "frame_prepared" && event.direction == .clientToServer && event.id == .number(10)
        }
        let (chunk, restOfD) = try handoffFrames()
        try harness.client.sendRaw(chunk)
        _ = try await harness.ledgerHold.reached.first(where: { _ in true }, "the bridge forwarding frame A")
        harness.quitApp()
        harness.ledgerHold.release()

        // A is a read held for the app's return. The offline loop answers the rest.
        let unavailable = MCPAppConnectionMessages.offlineText(for: .unavailable, identity: identity)
        let replyB = try await harness.client.readMessage()
        XCTAssertEqual(replyB["id"] as? Int, 11, label)
        XCTAssertEqual(resultText(replyB), unavailable, label)
        let replyC = try await harness.client.readMessage()
        XCTAssertEqual(replyC["id"] as? Int, 12, label)
        XCTAssertEqual(((replyC["result"] as? [String: Any])?["tools"] as? [Any])?.count, 0, label)
        try harness.client.sendRaw(restOfD)
        let replyD = try await harness.client.readMessage()
        XCTAssertEqual(replyD["id"] as? Int, 13, label)
        XCTAssertEqual(resultText(replyD), unavailable, label)

        harness.client.closeStdin()
        let ending = try await harness.finish()
        assertHostDisconnected(ending, .stdinClosed, label)
        let laterClientFrames = try await harness.client.readRemainingMessages()
        XCTAssertTrue(laterClientFrames.isEmpty, "\(label): the client received \(laterClientFrames)")
    }

    func testOutageKeepsTheAppsToolsListedAndCallsGetNamedErrorUntilReturn() async throws {
        let harness = try makeHarness(identity: identity)
        let firstConnection = try await harness.connectDirectly()
        try await listAppTools(id: 1, harness: harness, connection: firstConnection)

        // Quitting, the app announces that its tools changed, answers the client's re-list with
        // part of its catalog, and closes. The client must get every tool back from the helper, so
        // its next call reaches the helper instead of failing in the client as an unknown tool.
        try firstConnection.send(["jsonrpc": "2.0", "method": ToolListChangedNotification.name])
        let appChanged = try await harness.client.readMessage()
        XCTAssertEqual(appChanged["method"] as? String, ToolListChangedNotification.name)
        try harness.client.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let relist = try await firstConnection.readMessage()
        XCTAssertEqual(relist["id"] as? Int, 2)
        try firstConnection.send(["jsonrpc": "2.0", "id": 2, "result": quittingAppToolListResult])
        let partialList = try await harness.client.readMessage()
        XCTAssertEqual(partialList["result"] as? NSDictionary, quittingAppToolListResult as NSDictionary)
        harness.quitApp()
        _ = try await harness.phases.first(where: { $0 == .outage }, "the outage")
        // The retry gate stays closed, so these answers can't depend on a reconnect attempt.
        let helperChanged = try await harness.client.readMessage()
        XCTAssertEqual(helperChanged["method"] as? String, ToolListChangedNotification.name)
        let list = try await harness.client.request(["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        XCTAssertEqual(list["result"] as? NSDictionary, appToolListResult as NSDictionary)
        let call = try await harness.client.request(toolCall(id: 5, name: "apply_edits"))
        XCTAssertTrue(isErrorResult(call))
        XCTAssertEqual(resultText(call), MCPAppConnectionMessages.offlineText(for: .unavailable, identity: identity))

        let connection = try await harness.attachToFakeApp()
        try harness.client.send(toolCall(id: 6, name: "get_file_tree"))
        let forwarded = try await connection.readMessage()
        XCTAssertEqual(forwarded["id"] as? Int, 6, "the returned app received another frame first: \(forwarded)")
        try connection.send(["jsonrpc": "2.0", "id": 6, "result": ["content": [["type": "text", "text": "tree from the app"]]]])
        let result = try await harness.client.readMessage()
        XCTAssertEqual(resultText(result), "tree from the app")

        harness.client.closeStdin()
        let ending = try await harness.finish()
        assertHostDisconnected(ending, .stdinClosed)
        let laterAppFrames = try await connection.readRemainingMessages()
        XCTAssertTrue(laterAppFrames.isEmpty, "the returned app received \(laterAppFrames)")
    }

    func testReadInFlightAtOutageReplaysWhenAppReturnsWithinGrace() async throws {
        let harness = try makeHarness(identity: identity)
        harness.start()
        _ = try await harness.initializeOffline()
        let firstConnection = try await harness.attachToFakeApp()
        harness.retryGate.close()

        try harness.client.send(toolCall(id: 7, name: "read_file", arguments: ["path": "a.txt"]))
        try harness.client.send(toolCall(id: 9, name: "read_file", arguments: ["path": "b.txt"]))
        let inFlight = try await [firstConnection.readMessage(), firstConnection.readMessage()]
        XCTAssertEqual(inFlight.map { $0["id"] as? Int }, [7, 9])
        harness.quitApp()
        _ = try await harness.phases.first(where: { $0 == .outage }, "the outage")
        // The grace wait stays blocked for the rest of the test.
        _ = try await harness.graceGate.started.first(where: { $0 == 1 }, "the grace wait")
        // A held request the client cancels is not replayed.
        try harness.client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 9]])
        _ = try await harness.trace.first(where: { event in
            event.phase == "frame_committed" && event.method == "notifications/cancelled"
        }, "the cancellation")

        // The handshake the new connection receives is the one recorded from local frames.
        let app = try harness.startFakeApp()
        harness.retryGate.open()
        let connection = try await app.accept()
        _ = try await connection.acceptBootstrap()
        let replayed = try await connection.readMessage()
        XCTAssertEqual(replayed["method"] as? String, "initialize")
        try connection.send(appInitializeResult(for: replayed))
        let initialized = try await connection.readMessage()
        XCTAssertEqual(initialized["method"] as? String, "notifications/initialized")
        let read = try await connection.readMessage()
        XCTAssertEqual(read["id"] as? Int, 7)
        XCTAssertEqual((read["params"] as? [String: Any])?["name"] as? String, "read_file")

        try connection.send(["jsonrpc": "2.0", "id": 7, "result": ["content": [["type": "text", "text": "a.txt from the app"]]]])
        let changed = try await harness.client.readMessage()
        XCTAssertEqual(changed["method"] as? String, ToolListChangedNotification.name)
        let result = try await harness.client.readMessage()
        XCTAssertEqual(result["id"] as? Int, 7)
        XCTAssertEqual(resultText(result), "a.txt from the app")

        harness.client.closeStdin()
        let ending = try await harness.finish()
        assertHostDisconnected(ending, .stdinClosed)
        let laterClientFrames = try await harness.client.readRemainingMessages()
        XCTAssertTrue(laterClientFrames.isEmpty, "the client received more than one result: \(laterClientFrames)")
        let laterAppFrames = try await connection.readRemainingMessages()
        XCTAssertTrue(laterAppFrames.isEmpty, "the returned app received \(laterAppFrames)")
    }

    func testRequestsInFlightAtOutageAreAnsweredLocallyAfterGrace() async throws {
        let harness = try makeHarness(identity: identity)
        harness.start()
        _ = try await harness.initializeOffline()
        let firstConnection = try await harness.attachToFakeApp()
        harness.retryGate.close()
        try await listAppTools(id: 3, harness: harness, connection: firstConnection)

        try harness.client.send(toolCall(id: 7, name: "read_file", arguments: ["path": "a.txt"]))
        try harness.client.send(["jsonrpc": "2.0", "id": 9, "method": "tools/list"])
        let inFlight = try await [firstConnection.readMessage(), firstConnection.readMessage()]
        XCTAssertEqual(inFlight.map { $0["id"] as? Int }, [7, 9])
        harness.quitApp()
        _ = try await harness.phases.first(where: { $0 == .outage }, "the outage")
        _ = try await harness.graceGate.started.first(where: { $0 == 1 }, "the grace wait")

        // The helper's list_changed comes first. Then a held call gets the named error, and a held
        // list gets the tools the app listed.
        let changed = try await harness.client.readMessage()
        XCTAssertEqual(changed["method"] as? String, ToolListChangedNotification.name)
        harness.graceGate.open()
        let expired = try await harness.client.readMessage()
        XCTAssertEqual(expired["id"] as? Int, 7)
        XCTAssertTrue(isErrorResult(expired))
        XCTAssertEqual(resultText(expired), MCPAppConnectionMessages.offlineText(for: .unavailable, identity: identity))
        let expiredList = try await harness.client.readMessage()
        XCTAssertEqual(expiredList["id"] as? Int, 9)
        XCTAssertEqual(expiredList["result"] as? NSDictionary, appToolListResult as NSDictionary)

        // Requests held for replay go to the app before anything the client sends next.
        let connection = try await harness.attachToFakeApp()
        try harness.client.send(toolCall(id: 8, name: "get_file_tree"))
        let next = try await connection.readMessage()
        XCTAssertEqual(next["id"] as? Int, 8, "the returned app received \(next)")
        try connection.send(["jsonrpc": "2.0", "id": 8, "result": ["content": [["type": "text", "text": "tree from the app"]]]])
        _ = try await harness.client.readMessage()

        harness.client.closeStdin()
        let ending = try await harness.finish()
        assertHostDisconnected(ending, .stdinClosed)
        let laterAppFrames = try await connection.readRemainingMessages()
        XCTAssertTrue(laterAppFrames.isEmpty, "the returned app received \(laterAppFrames)")
    }

    func testLocallyAnsweredCallsAreNeverReplayedIntoTheApp() async throws {
        let harness = try makeHarness(identity: identity)
        harness.start()
        _ = try await harness.initializeOffline()

        let offlineMutation = try await harness.client.request(
            toolCall(id: 5, name: "apply_edits", arguments: ["path": "offline.txt", "rewrite": "offline"])
        )
        XCTAssertTrue(isErrorResult(offlineMutation))
        // A read is the kind of request the helper replays after a reconnect, so it would surface
        // here first if local answers were queued for replay.
        let offlineRead = try await harness.client.request(toolCall(id: 6, name: "read_file", arguments: ["path": "offline.txt"]))
        XCTAssertTrue(isErrorResult(offlineRead))

        let connection = try await harness.attachToFakeApp()

        try harness.client.send(toolCall(id: 5, name: "apply_edits", arguments: ["path": "online.txt", "rewrite": "online"]))
        let forwarded = try await connection.readMessage()
        XCTAssertEqual(forwarded["id"] as? Int, 5)
        let arguments = (forwarded["params"] as? [String: Any])?["arguments"] as? [String: Any]
        XCTAssertEqual(arguments?["path"] as? String, "online.txt")
        try connection.send(["jsonrpc": "2.0", "id": 5, "result": ["content": [["type": "text", "text": "edited online.txt"]]]])
        let result = try await harness.client.readMessage()
        XCTAssertEqual(resultText(result), "edited online.txt")

        harness.client.closeStdin()
        let ending = try await harness.finish()
        assertHostDisconnected(ending, .stdinClosed)
        let laterAppFrames = try await connection.readRemainingMessages()
        XCTAssertTrue(laterAppFrames.isEmpty, "the app received more than the online call: \(laterAppFrames)")
    }

    func testRejectedOrIncompatibleAttachmentNeverForwardsTools() async throws {
        enum Refusal {
            case appError
            case incompatibleResult
            case termination
        }
        let refusal = "Agent session 'Build fixes' already admitted another client."
        let terminationMessage = "Connection terminated by user from MCP dashboard"
        let cases: [(label: String, kind: Refusal, respond: (FakeAppConnection, [String: Any]) throws -> Void)] = [
            ("app refuses the session", .appError, { connection, request in
                try connection.send([
                    "jsonrpc": "2.0",
                    "id": request["id"] ?? NSNull(),
                    "error": ["code": -32600, "message": refusal]
                ])
            }),
            ("app answers with another protocol version", .incompatibleResult, { connection, request in
                try connection.send(appInitializeResult(for: request, protocolVersion: "2024-11-05"))
            }),
            ("app terminates the connection during admission, then closes it", .termination, { connection, _ in
                try connection.send([
                    "jsonrpc": "2.0",
                    "method": RepoPromptControlMethod.terminate,
                    "params": [
                        "reason": TerminationReason.userBootFromDashboard.rawValue,
                        "message": terminationMessage,
                        "requestedAt": ISO8601DateFormatter().string(from: Date())
                    ]
                ])
                connection.shutdownWrite()
            })
        ]

        for testCase in cases {
            let label = testCase.label
            let harness = try makeHarness(identity: identity)
            harness.start()
            _ = try await harness.initializeOffline()

            let app = try harness.startFakeApp()
            harness.retryGate.open()
            let connection = try await app.accept()
            _ = try await connection.acceptBootstrap()
            let replayed = try await connection.readMessage()
            let waiting = try await harness.client.request(toolCall(id: 1, name: "apply_edits"))
            XCTAssertEqual(
                resultText(waiting),
                MCPAppConnectionMessages.offlineText(for: .awaitingApproval, identity: identity),
                label
            )

            try testCase.respond(connection, replayed)
            let ending = try await harness.finish()
            XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: ending), label)

            let laterAppFrames = try await connection.readRemainingMessages()
            XCTAssertTrue(laterAppFrames.isEmpty, "\(label): the app received \(laterAppFrames)")
            let laterClientFrames = try await harness.client.readRemainingMessages()
            XCTAssertTrue(laterClientFrames.isEmpty, "\(label): the client received \(laterClientFrames)")

            switch (testCase.kind, ending) {
            case let (.appError, .connectionFailed(underlying)):
                guard case let .initializeReplayRejected(code, message) = underlying as? SocketProxyError else {
                    XCTFail("\(label): expected the app's refusal, got \(underlying)")
                    continue
                }
                XCTAssertEqual(code, -32600, label)
                XCTAssertEqual(message, refusal, label)
                let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
                    sessionToken: "offline-startup-test",
                    localPID: 1,
                    initialParentPID: 2,
                    ledgerSnapshot: harness.ledger.snapshot(),
                    runtimeError: ending,
                    fallbackReason: "unexpected_fallback"
                )
                XCTAssertEqual(record.reason, "mcp_session_resume_initialize_replay_rejected", label)
                XCTAssertEqual(record.initiator, .app, label)
                XCTAssertTrue(record.errorDescription?.contains(refusal) == true, label)
                let stderr = try await harness.readStderr()
                XCTAssertTrue(
                    stderr.contains(MCPAppConnectionMessages.sessionRefused(appMessage: refusal, identity: identity)),
                    "\(label): stderr was \(stderr)"
                )
            case let (.incompatibleResult, .connectionFailed(underlying)):
                XCTAssertEqual(
                    underlying as? JSONRPCBridgeLedgerError,
                    .terminal("mcp_session_resume_initialize_replay_result_mismatch"),
                    label
                )
                let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
                    sessionToken: "offline-startup-test",
                    localPID: 1,
                    initialParentPID: 2,
                    ledgerSnapshot: harness.ledger.snapshot(),
                    runtimeError: ending,
                    fallbackReason: "unexpected_fallback"
                )
                XCTAssertEqual(record.reason, "mcp_session_resume_initialize_replay_result_mismatch", label)
            case let (.termination, .terminatedByServer(provenance)):
                XCTAssertEqual(provenance.reason, .userBootFromDashboard, label)
                XCTAssertEqual(provenance.message, terminationMessage, label)
            default:
                XCTFail("\(label): unexpected ending \(ending)")
            }
        }
    }

    func testOfflineEOFStopsRetryAndPreservesTerminalProvenance() async throws {
        // A closed pipe reaches the pump as a hangup or as a zero-byte read, depending on timing,
        // and the reason names which one it saw.
        let cases: [(label: String, trailingBytes: Data, expectedReasons: Set<String>)] = [
            ("clean EOF", Data(), [CLIHostDisconnectProvenance.Reason.stdinClosed.rawValue]),
            (
                "EOF inside a frame",
                Data(#"{"jsonrpc":"2.0","id":9,"#.utf8),
                ["stdin_eof_with_incomplete_frame", "stdin_hangup_with_incomplete_frame"]
            )
        ]

        for testCase in cases {
            let label = testCase.label
            let harness = try makeHarness(identity: identity)
            harness.start()
            _ = try await harness.initializeOffline()
            _ = try await harness.retryGate.started.first(where: { $0 == 1 }, "the worker's first retry wait")

            if !testCase.trailingBytes.isEmpty {
                try harness.client.sendRaw(testCase.trailingBytes)
            }
            harness.client.closeStdin()
            let ending = try await harness.finish()

            XCTAssertEqual(harness.retryGate.counts.started, 1, "\(label): no later attempt")
            XCTAssertEqual(harness.retryGate.counts.cancelled, 1, "\(label): the worker's wait was cancelled")
            XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: ending), label)
            let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
                sessionToken: "offline-startup-test",
                localPID: 1,
                initialParentPID: 2,
                ledgerSnapshot: harness.ledger.snapshot(),
                runtimeError: ending,
                fallbackReason: "unexpected_fallback"
            )
            XCTAssertTrue(testCase.expectedReasons.contains(record.reason), "\(label): \(record.reason)")
            XCTAssertEqual(record.initiator, .host, label)
        }
    }

    func testCancellationClosesAnAttachmentCandidateBeforeReturning() async throws {
        let harness = try makeHarness(identity: identity)
        harness.start()
        _ = try await harness.initializeOffline()

        let app = try harness.startFakeApp()
        harness.retryGate.open()
        let connection = try await app.accept()
        _ = try await connection.acceptBootstrap()
        let replayed = try await connection.readMessage()
        XCTAssertEqual(replayed["method"] as? String, "initialize")

        harness.cancel()
        let ending = try await harness.finish()

        assertHostDisconnected(ending, .taskCancelled)
        XCTAssertTrue(connection.peerHasClosed(), "the candidate socket was still open when the session returned")
        XCTAssertEqual(harness.retryGate.counts.started, 1, "no attempt after cancellation")
    }

    // MARK: - Helpers

    /// Lists the client's tools through the bridge, with the app answering `appToolListResult`.
    private func listAppTools(
        id: Int,
        harness: ProxyHarness,
        connection: FakeAppConnection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try harness.client.send(["jsonrpc": "2.0", "id": id, "method": "tools/list"])
        let request = try await connection.readMessage()
        XCTAssertEqual(request["method"] as? String, "tools/list", file: file, line: line)
        try connection.send(["jsonrpc": "2.0", "id": id, "result": appToolListResult])
        let list = try await harness.client.readMessage()
        XCTAssertEqual(list["result"] as? NSDictionary, appToolListResult as NSDictionary, file: file, line: line)
    }

    private func makeHarness(identity: MCPFilesystemIdentity) throws -> ProxyHarness {
        let harness = try ProxyHarness(identity: identity)
        addTeardownBlock {
            await harness.tearDown()
        }
        return harness
    }

    private func assertHostDisconnected(
        _ ending: CLIRuntimeError,
        _ reason: CLIHostDisconnectProvenance.Reason,
        _ label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .hostDisconnected(provenance) = ending else {
            return XCTFail("\(label): expected host disconnect \(reason.rawValue), got \(ending)", file: file, line: line)
        }
        XCTAssertEqual(provenance.reason, reason, label, file: file, line: line)
    }
}

// MARK: - Frames

/// The app's answer to `tools/list`, with a field this helper's SDK doesn't define, as a newer app
/// may send.
private let appToolListResult: [String: Any] = [
    "tools": [
        ["name": "get_file_tree", "inputSchema": ["type": "object"], "futureField": ["kept": true]],
        ["name": "apply_edits", "inputSchema": ["type": "object"]]
    ]
]

/// What an app that is quitting answers a re-list with: part of its catalog.
private let quittingAppToolListResult: [String: Any] = [
    "tools": [["name": "get_file_tree", "inputSchema": ["type": "object"]]]
]

private func toolCall(id: Int, name: String, arguments: [String: Any] = [:]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
}

/// Encoded as the app and MCP clients write frames, with slashes unescaped, so method names such
/// as `repoprompt/control/terminate` appear literally.
private func jsonLine(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
}

private func resultText(_ message: [String: Any]) -> String? {
    let content = (message["result"] as? [String: Any])?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String
}

private func isErrorResult(_ message: [String: Any]) -> Bool {
    (message["result"] as? [String: Any])?["isError"] as? Bool == true
}

/// The result the app gives a replayed initialize, built with the app's own capabilities so its
/// compatibility fingerprint matches the offline answer unless the protocol version differs.
private func appInitializeResult(
    for request: [String: Any],
    protocolVersion: String? = nil
) throws -> [String: Any] {
    let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String ?? Version.latest
    let result = Initialize.Result(
        protocolVersion: protocolVersion ?? requested,
        capabilities: MCPAppServerCapabilities.value,
        serverInfo: MCP.Server.Info(name: "Fake App", version: "1"),
        instructions: "Fake app instructions"
    )
    let resultObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
    return ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": resultObject]
}

// MARK: - Fixture

private enum FixtureError: Error, CustomStringConvertible {
    case timedOut(String)
    case closed(String)
    case unexpected(String)
    case posix(String, Int32)

    var description: String {
        switch self {
        case let .timedOut(what): "timed out waiting for \(what)"
        case let .closed(what): "\(what) closed"
        case let .unexpected(what): what
        case let .posix(call, code): "\(call) failed with errno \(code)"
        }
    }
}

/// Runs blocking descriptor I/O on a dispatch thread so the session's tasks keep the cooperative pool.
private func offPool<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try body() })
        }
    }
}

/// Events in arrival order, with waits that also see events that already arrived.
private final class EventLog<Event>: @unchecked Sendable {
    private struct Waiter {
        let predicate: (Event) -> Bool
        let continuation: CheckedContinuation<Event, Error>
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var waiters: [UUID: Waiter] = [:]

    func append(_ event: Event) {
        let matched: [CheckedContinuation<Event, Error>] = lock.withLock {
            events.append(event)
            let ids = waiters.filter { $0.value.predicate(event) }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in matched {
            continuation.resume(returning: event)
        }
    }

    /// The timeout only keeps a broken session from hanging the suite; ordering comes from the events.
    func first(
        where predicate: @escaping (Event) -> Bool,
        timeout: TimeInterval = 10,
        _ what: String
    ) async throws -> Event {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let existing: Event? = lock.withLock {
                if let event = events.first(where: predicate) {
                    return event
                }
                waiters[id] = Waiter(predicate: predicate, continuation: continuation)
                return nil
            }
            if let existing {
                continuation.resume(returning: existing)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expire(id, what)
            }
        }
    }

    private func expire(_ id: UUID, _ what: String) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.continuation.resume(throwing: FixtureError.timedOut(what))
    }
}

/// Stands in for the session's retry wait. Closed, it blocks every wait until it opens or the
/// waiting task is cancelled.
private final class RetryGate: @unchecked Sendable {
    let started = EventLog<Int>()
    private let lock = NSLock()
    private var isOpen = false
    private var startedCount = 0
    private var cancelledCount = 0
    private var blocked: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledBeforeBlocking: Set<UUID> = []

    var counts: (started: Int, cancelled: Int) {
        lock.withLock { (startedCount, cancelledCount) }
    }

    func wait() async throws {
        let id = UUID()
        let ordinal = lock.withLock {
            startedCount += 1
            return startedCount
        }
        started.append(ordinal)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resume: Result<Void, Error>? = lock.withLock {
                    if cancelledBeforeBlocking.remove(id) != nil {
                        cancelledCount += 1
                        return .failure(CancellationError())
                    }
                    if isOpen {
                        return .success(())
                    }
                    blocked[id] = continuation
                    return nil
                }
                if let resume {
                    continuation.resume(with: resume)
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                if let continuation = blocked.removeValue(forKey: id) {
                    cancelledCount += 1
                    return continuation
                }
                cancelledBeforeBlocking.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func open() {
        let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
            isOpen = true
            defer { blocked.removeAll() }
            return Array(blocked.values)
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// Makes later waits block again until the next `open`.
    func close() {
        lock.withLock { isOpen = false }
    }
}

/// Holds the ledger, and with it the session's frame handling, inside the first trace event a test
/// arms it for, until the test releases it.
private final class LedgerHold: @unchecked Sendable {
    let reached = EventLog<MCPResponseDeliveryTraceEvent>()
    private let lock = NSLock()
    private var predicate: ((MCPResponseDeliveryTraceEvent) -> Bool)?
    private let released = DispatchSemaphore(value: 0)

    func arm(_ predicate: @escaping (MCPResponseDeliveryTraceEvent) -> Bool) {
        lock.withLock { self.predicate = predicate }
    }

    /// Runs inside the ledger. The wait's timeout only keeps a broken test from hanging the suite.
    func pass(_ event: MCPResponseDeliveryTraceEvent) {
        let matched = lock.withLock { () -> Bool in
            guard let predicate, predicate(event) else { return false }
            self.predicate = nil
            return true
        }
        guard matched else { return }
        reached.append(event)
        _ = released.wait(timeout: .now() + 10)
    }

    func release() {
        released.signal()
    }
}

/// Newline-delimited reads from one descriptor, with a deadline on each read.
private final class LineReader: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) {
        self.fd = fd
    }

    func readLine(timeout: TimeInterval, _ what: String) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer = Data(buffer[(newline + 1)...])
                return line
            }
            guard try fill(until: deadline, what) else {
                throw FixtureError.closed(what)
            }
        }
    }

    func discard(byteCount: Int, timeout: TimeInterval, _ what: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < byteCount {
            guard try fill(until: deadline, what) else {
                throw FixtureError.closed(what)
            }
        }
        buffer = Data(buffer.dropFirst(byteCount))
    }

    /// Every remaining line, once the writer has closed its end.
    func readRemainingLines(timeout: TimeInterval, _ what: String) throws -> [Data] {
        let deadline = Date().addingTimeInterval(timeout)
        while try fill(until: deadline, what) {}
        let lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        buffer.removeAll()
        return lines
    }

    /// Returns false at EOF.
    private func fill(until deadline: Date, _ what: String) throws -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw FixtureError.timedOut(what)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 0.2) * 1000) + 1)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw FixtureError.posix("poll", errno)
            }
            if ready == 0 {
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EAGAIN || errno == EINTR {
                    continue
                }
                throw FixtureError.posix("read", errno)
            }
            if count == 0 {
                return false
            }
            buffer.append(contentsOf: chunk[0 ..< count])
            return true
        }
    }
}

private func parseMessage(_ line: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw FixtureError.unexpected("not a JSON object: \(String(decoding: line, as: UTF8.self))")
    }
    return object
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    var written = 0
    while written < data.count {
        let count = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress!.advanced(by: written), data.count - written)
        }
        if count < 0 {
            if errno == EINTR {
                continue
            }
            throw FixtureError.posix("write", errno)
        }
        written += count
    }
}

/// The MCP client's side of the helper's stdin and stdout.
private final class ClientPipes: @unchecked Sendable {
    let stdinRead: Int32
    let stdoutWrite: Int32
    private var stdinWrite: Int32
    private var stdoutWriteOwnedByTest: Int32
    private let stdoutRead: Int32
    private let reader: LineReader

    init() throws {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw FixtureError.posix("pipe", errno) }
        stdinRead = input[0]
        stdinWrite = input[1]
        stdoutRead = output[0]
        stdoutWrite = output[1]
        stdoutWriteOwnedByTest = output[1]
        reader = LineReader(fd: output[0])
    }

    func send(_ object: [String: Any]) throws {
        try sendRaw(jsonLine(object))
    }

    func sendRaw(_ data: Data) throws {
        try writeAll(data, to: stdinWrite)
    }

    func readMessage(timeout: TimeInterval = 10) async throws -> [String: Any] {
        let reader = reader
        let line = try await offPool { try reader.readLine(timeout: timeout, "a client frame") }
        return try parseMessage(line)
    }

    func request(_ object: [String: Any]) async throws -> [String: Any] {
        try send(object)
        return try await readMessage()
    }

    func closeStdin() {
        guard stdinWrite >= 0 else { return }
        Darwin.close(stdinWrite)
        stdinWrite = -1
    }

    /// Fills the stdout pipe so the helper's next write blocks until the test reads.
    ///
    /// - Returns: The number of filler bytes now ahead of the helper's output.
    func fillStdoutPipe() throws -> Int {
        let flags = fcntl(stdoutWrite, F_GETFL)
        guard flags >= 0, fcntl(stdoutWrite, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw FixtureError.posix("fcntl", errno)
        }
        var total = 0
        // Writes no larger than PIPE_BUF are all-or-nothing, so single bytes top the pipe off exactly.
        for chunkSize in [512, 1] {
            let filler = [UInt8](repeating: UInt8(ascii: "x"), count: chunkSize)
            while true {
                let count = Darwin.write(stdoutWrite, filler, filler.count)
                if count > 0 {
                    total += count
                    continue
                }
                if count < 0, errno == EAGAIN {
                    break
                }
                throw FixtureError.posix("write", errno)
            }
        }
        return total
    }

    func discardStdout(byteCount: Int) async throws {
        let reader = reader
        try await offPool { try reader.discard(byteCount: byteCount, timeout: 10, "stdout filler") }
    }

    /// Every client frame still unread, once the session has ended and can't write more.
    func readRemainingMessages() async throws -> [[String: Any]] {
        if stdoutWriteOwnedByTest >= 0 {
            Darwin.close(stdoutWriteOwnedByTest)
            stdoutWriteOwnedByTest = -1
        }
        let reader = reader
        return try await offPool { try reader.readRemainingLines(timeout: 10, "remaining client frames") }
            .map(parseMessage)
    }

    func close() {
        closeStdin()
        Darwin.close(stdinRead)
        if stdoutWriteOwnedByTest >= 0 {
            Darwin.close(stdoutWriteOwnedByTest)
            stdoutWriteOwnedByTest = -1
        }
        Darwin.close(stdoutRead)
    }
}

/// The app's end of the bootstrap socket.
private final class FakeApp: @unchecked Sendable {
    private let socketURL: URL
    private var listenFD: Int32
    private let lock = NSLock()
    private var connections: [FakeAppConnection] = []

    init(socketURL: URL) throws {
        self.socketURL = socketURL
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.posix("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw FixtureError.unexpected("socket path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { cString in
                _ = strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), cString)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw FixtureError.posix("bind/listen", code)
        }
        listenFD = fd
    }

    func accept(timeout: TimeInterval = 10) async throws -> FakeAppConnection {
        let listenFD = lock.withLock { self.listenFD }
        let fd = try await offPool { () throws -> Int32 in
            let deadline = Date().addingTimeInterval(timeout)
            while deadline.timeIntervalSinceNow > 0 {
                var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 200)
                if ready < 0, errno != EINTR {
                    throw FixtureError.posix("poll", errno)
                }
                guard ready > 0 else { continue }
                let fd = Darwin.accept(listenFD, nil, nil)
                if fd >= 0 {
                    return fd
                }
                if errno != EINTR, errno != EAGAIN {
                    throw FixtureError.posix("accept", errno)
                }
            }
            throw FixtureError.timedOut("a connection to the fake app")
        }
        let connection = FakeAppConnection(fd: fd)
        lock.withLock { connections.append(connection) }
        return connection
    }

    /// Stops listening and leaves the socket file behind, as an app that died without cleaning up
    /// does: connecting to the file is refused.
    func stopListening() {
        lock.withLock {
            guard listenFD >= 0 else { return }
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    func close() {
        stopListening()
        unlink(socketURL.path)
        for connection in lock.withLock({ connections }) {
            connection.close()
        }
    }
}

private final class FakeAppConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private let reader: LineReader

    init(fd: Int32) {
        self.fd = fd
        reader = LineReader(fd: fd)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads the helper's bootstrap request and accepts it.
    func acceptBootstrap() async throws -> [String: Any] {
        let request = try await readMessage()
        var accepted = try JSONEncoder().encode(MCPBootstrapResponse(type: "accepted"))
        accepted.append(0x0A)
        try writeAll(accepted, to: fd)
        return request
    }

    func readMessage(timeout: TimeInterval = 10) async throws -> [String: Any] {
        let reader = reader
        let line = try await offPool { try reader.readLine(timeout: timeout, "a frame at the fake app") }
        return try parseMessage(line)
    }

    func send(_ object: [String: Any]) throws {
        try writeAll(jsonLine(object), to: fd)
    }

    /// Every frame the helper sent and the test has not read, up to the helper closing the socket.
    func readRemainingMessages() async throws -> [[String: Any]] {
        let reader = reader
        return try await offPool { try reader.readRemainingLines(timeout: 10, "remaining app frames") }
            .map(parseMessage)
    }

    /// Closes the app's sending side, as an app does when it drops the connection.
    func shutdownWrite() {
        lock.withLock {
            guard fd >= 0 else { return }
            Darwin.shutdown(fd, SHUT_WR)
        }
    }

    /// True when the helper has already closed its end: reading finds EOF without waiting.
    func peerHasClosed() -> Bool {
        var byte: UInt8 = 0
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return false }
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 {
                return true
            }
            if count < 0 {
                return errno == ECONNRESET
            }
        }
    }

    func close() {
        lock.withLock {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// One session under test: its pipes, ledger, retry gate, and observed phases.
private final class ProxyHarness: @unchecked Sendable {
    let identity: MCPFilesystemIdentity
    let socketURL: URL
    let client: ClientPipes
    let retryGate = RetryGate()
    let graceGate = RetryGate()
    let ledgerHold: LedgerHold
    let phases = EventLog<MCPProxySession.Phase>()
    let trace: EventLog<MCPResponseDeliveryTraceEvent>
    let ledger: JSONRPCBridgeLedger
    private let stderrRead: Int32
    private var stderrWrite: Int32
    private let lock = NSLock()
    private var sessionTask: Task<CLIRuntimeError, Never>?
    private var fakeApps: [FakeApp] = []

    init(identity: MCPFilesystemIdentity) throws {
        self.identity = identity
        // Short enough for sun_path, and never one of the app's real sockets.
        socketURL = URL(fileURLWithPath: "/tmp/rpce-offline-\(UUID().uuidString.prefix(8)).sock")
        client = try ClientPipes()
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&errorPipe) == 0 else { throw FixtureError.posix("pipe", errno) }
        stderrRead = errorPipe[0]
        stderrWrite = errorPipe[1]
        let trace = EventLog<MCPResponseDeliveryTraceEvent>()
        self.trace = trace
        let ledgerHold = LedgerHold()
        self.ledgerHold = ledgerHold
        ledger = JSONRPCBridgeLedger(connectionID: "offline-startup-test", traceSink: { event in
            trace.append(event)
            ledgerHold.pass(event)
        })
    }

    func start() {
        let sessionClient = MCPProxySession.Client(
            sessionToken: "offline-startup-test",
            identityCache: ClientIdentityCache(),
            initializeReplayState: MCPInitializeReplayState(),
            outstandingRequestReplayState: MCPOutstandingRequestReplayState(),
            bridgeLedger: ledger
        )
        let stdinFD = client.stdinRead
        let stdoutFD = client.stdoutWrite
        let stderrFD = stderrWrite
        let socketURL = socketURL
        let identity = identity
        let retryGate = retryGate
        let graceGate = graceGate
        let phases = phases
        let task = Task {
            await MCPProxySession.run(
                client: sessionClient,
                stdinFD: stdinFD,
                stdoutFD: stdoutFD,
                stderrFD: stderrFD,
                socketURL: socketURL,
                identity: identity,
                serverVersion: "9.9.9-test",
                retryWait: { _ in try await retryGate.wait() },
                graceWait: { _ in try await graceGate.wait() },
                onPhaseChange: { phase in phases.append(phase) }
            )
        }
        lock.withLock { sessionTask = task }
    }

    private static let initializeRequest: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "offline-startup-test", "version": "1"]
        ]
    ]
    private static let initializedNotification: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]

    /// Sends `initialize` and `notifications/initialized` while the app is away.
    func initializeOffline() async throws -> [String: Any] {
        let response = try await client.request(Self.initializeRequest)
        guard response["result"] != nil else {
            throw FixtureError.unexpected("offline initialize failed: \(response)")
        }
        try client.send(Self.initializedNotification)
        return response
    }

    /// Starts the fake app, then the session, which reaches the app on its first attempt, and
    /// completes the client's handshake through the bridge.
    func connectDirectly() async throws -> FakeAppConnection {
        let app = try startFakeApp()
        start()
        let connection = try await app.accept()
        _ = try await connection.acceptBootstrap()
        try client.send(Self.initializeRequest)
        let initialize = try await connection.readMessage()
        try connection.send(appInitializeResult(for: initialize))
        let response = try await client.readMessage()
        guard response["result"] != nil else {
            throw FixtureError.unexpected("initialize through the app failed: \(response)")
        }
        try client.send(Self.initializedNotification)
        let initialized = try await connection.readMessage()
        guard initialized["method"] as? String == "notifications/initialized" else {
            throw FixtureError.unexpected("expected notifications/initialized, got \(initialized)")
        }
        return connection
    }

    func startFakeApp() throws -> FakeApp {
        let app = try FakeApp(socketURL: socketURL)
        lock.withLock { fakeApps.append(app) }
        return app
    }

    /// Quits every fake app: its connections and listener close and its socket file goes away.
    func quitApp() {
        let apps = lock.withLock { () -> [FakeApp] in
            defer { fakeApps.removeAll() }
            return fakeApps
        }
        for app in apps {
            app.close()
        }
    }

    /// Starts the fake app, admits the replayed initialize, and returns once the client has the
    /// helper's `list_changed`.
    func attachToFakeApp() async throws -> FakeAppConnection {
        let app = try startFakeApp()
        retryGate.open()
        let connection = try await app.accept()
        _ = try await connection.acceptBootstrap()
        let replayed = try await connection.readMessage()
        guard replayed["method"] as? String == "initialize" else {
            throw FixtureError.unexpected("expected the replayed initialize, got \(replayed)")
        }
        try connection.send(appInitializeResult(for: replayed))
        let initialized = try await connection.readMessage()
        guard initialized["method"] as? String == "notifications/initialized" else {
            throw FixtureError.unexpected("expected notifications/initialized, got \(initialized)")
        }
        let changed = try await client.readMessage()
        guard changed["method"] as? String == ToolListChangedNotification.name else {
            throw FixtureError.unexpected("expected list_changed, got \(changed)")
        }
        return connection
    }

    func cancel() {
        lock.withLock { sessionTask }?.cancel()
    }

    func finish(timeout: TimeInterval = 15) async throws -> CLIRuntimeError {
        guard let task = lock.withLock({ sessionTask }) else {
            throw FixtureError.unexpected("session not started")
        }
        let ending = EventLog<CLIRuntimeError>()
        Task { await ending.append(task.value) }
        return try await ending.first(where: { _ in true }, timeout: timeout, "the session to end")
    }

    func readStderr() async throws -> String {
        let write = lock.withLock { () -> Int32 in
            defer { stderrWrite = -1 }
            return stderrWrite
        }
        if write >= 0 {
            Darwin.close(write)
        }
        let reader = LineReader(fd: stderrRead)
        let lines = try await offPool { try reader.readRemainingLines(timeout: 10, "stderr") }
        return lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    func tearDown() async {
        cancel()
        _ = try? await finish()
        for app in lock.withLock({ fakeApps }) {
            app.close()
        }
        unlink(socketURL.path)
        client.close()
        let write = lock.withLock { stderrWrite }
        if write >= 0 {
            Darwin.close(write)
        }
        Darwin.close(stderrRead)
    }
}
