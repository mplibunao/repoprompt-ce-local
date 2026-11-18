import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class MCPOfflineResponderTests: XCTestCase {
    private let identity = MCPFilesystemIdentity.repoPromptCE(.debug)
    private let serverVersion = "9.9.9-test"
    private let connectionMessage = "OFFLINE-CONNECTION-MESSAGE"

    private func initializeFrame(id: String = "1", protocolVersion: String = "2025-06-18") -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"method":"initialize","params":{"protocolVersion":"\(protocolVersion)",\
        "capabilities":{},"clientInfo":{"name":"offline-test-client","version":"1"}}}
        """
    }

    private func makeResponder(initializeAnswered: Bool = false) -> MCPOfflineResponder {
        MCPOfflineResponder(
            identity: identity,
            serverVersion: serverVersion,
            initializeAnswered: initializeAnswered
        )
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// Sends one frame and checks the response (`nil` for none) and the replay-record flag together.
    private func assertRespond(
        _ responder: inout MCPOfflineResponder,
        _ frame: String,
        expectedResponse: String?,
        records: Bool,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let outcome = try responder.respond(to: Data(frame.utf8), connectionMessage: connectionMessage)
        XCTAssertEqual(outcome.recordsClientFrameForReplay, records, "\(label): replay record", file: file, line: line)
        guard let expectedResponse else {
            XCTAssertNil(outcome.response, "\(label): expected no response", file: file, line: line)
            return
        }
        let response = try XCTUnwrap(outcome.response, "\(label): expected a response", file: file, line: line)
        XCTAssertEqual(response.last, UInt8(ascii: "\n"), "\(label): newline-terminated", file: file, line: line)
        XCTAssertEqual(
            response.filter { $0 == UInt8(ascii: "\n") }.count, 1,
            "\(label): one line", file: file, line: line
        )
        let actual = try JSONSerialization.jsonObject(with: response)
        let expected = try json(expectedResponse)
        XCTAssertTrue(
            (actual as AnyObject).isEqual(expected),
            "\(label): \(String(decoding: response, as: UTF8.self))",
            file: file,
            line: line
        )
    }

    private func errorResponse(id: String, code: Int, message: String, detail: String? = nil) -> String {
        let data = detail.map { #","data":{"detail":"\#($0)"}"# } ?? ""
        return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"\#(data)}}"#
    }

    private func malformedRequest(id: String) -> String {
        errorResponse(
            id: id, code: -32600,
            message: "Invalid Request: A request needs a string method and a string or integer id",
            detail: "A request needs a string method and a string or integer id"
        )
    }

    func testOfflineResponderFollowsProtocolTable() throws {
        let notInitialized = errorResponse(
            id: "1", code: -32600,
            message: "Invalid Request: MCP session is not initialized.",
            detail: "MCP session is not initialized."
        )

        // Rows that need no prior state each get a fresh responder.
        let freshRows: [(label: String, frame: String, response: String?, records: Bool)] = [
            (
                "ping before initialize",
                #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
                false
            ),
            (
                "string id stays a string",
                #"{"jsonrpc":"2.0","id":"1","method":"ping"}"#,
                #"{"jsonrpc":"2.0","id":"1","result":{}}"#,
                false
            ),
            (
                "server/discover before initialize",
                #"{"jsonrpc":"2.0","id":"d-1","method":"server/discover"}"#,
                errorResponse(
                    id: #""d-1""#, code: -32601,
                    message: "Method not found: Unknown method: server/discover",
                    detail: "Unknown method: server/discover"
                ),
                false
            ),
            ("tools/list before initialize", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, notInitialized, false),
            ("prompts/list before initialize", #"{"jsonrpc":"2.0","id":1,"method":"prompts/list"}"#, notInitialized, false),
            ("resources/list before initialize", #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#, notInitialized, false),
            (
                "resources/templates/list before initialize",
                #"{"jsonrpc":"2.0","id":1,"method":"resources/templates/list"}"#,
                notInitialized,
                false
            ),
            (
                "tools/call before initialize",
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"apply_edits"}}"#,
                notInitialized,
                false
            ),
            (
                "prompts/get reports the connection message",
                #"{"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"x"}}"#,
                errorResponse(id: "1", code: -32001, message: "Server error: OFFLINE-CONNECTION-MESSAGE"),
                false
            ),
            (
                "resources/read reports the connection message",
                #"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"repoprompt://instructions"}}"#,
                errorResponse(id: "1", code: -32001, message: "Server error: OFFLINE-CONNECTION-MESSAGE"),
                false
            ),
            (
                "unknown request",
                #"{"jsonrpc":"2.0","id":1,"method":"completion/complete"}"#,
                errorResponse(
                    id: "1", code: -32601,
                    message: "Method not found: Unknown method: completion/complete",
                    detail: "Unknown method: completion/complete"
                ),
                false
            ),
            (
                "initialized before initialize is not recorded",
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                nil,
                false
            ),
            (
                "initialize with a null id",
                #"{"jsonrpc":"2.0","id":null,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
                malformedRequest(id: "null"),
                false
            ),
            ("request object without a method", #"{"jsonrpc":"2.0","id":42}"#, malformedRequest(id: "42"), false),
            (
                "request object with a non-string method",
                #"{"jsonrpc":"2.0","id":"x","method":5}"#,
                malformedRequest(id: #""x""#),
                false
            ),
            ("object without id or method", "{}", nil, false),
            ("response from the client", #"{"jsonrpc":"2.0","id":99,"result":{}}"#, nil, false),
            ("not JSON", "not json", nil, false)
        ]
        for row in freshRows {
            var responder = makeResponder()
            try assertRespond(&responder, row.frame, expectedResponse: row.response, records: row.records, row.label)
        }

        // A rejected first initialize leaves the responder uninitialized and records nothing.
        let invalidParams = errorResponse(
            id: "1", code: -32602,
            message: "Invalid params: Invalid initialize parameters",
            detail: "Invalid initialize parameters"
        )
        var responder = makeResponder()
        try assertRespond(
            &responder, #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
            expectedResponse: invalidParams, records: false, "initialize without params"
        )
        try assertRespond(
            &responder,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":5}}"#,
            expectedResponse: invalidParams, records: false, "initialize with malformed params"
        )
        try assertRespond(
            &responder, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            expectedResponse: notInitialized, records: false, "still uninitialized after invalid initialize"
        )

        // A batch never initializes: each request member is refused, notifications get nothing.
        func batchRefusal(ids: [String]) -> String {
            "[" + ids.map {
                errorResponse(
                    id: $0, code: -32600,
                    message: "Invalid Request: Batch requests are not supported",
                    detail: "Batch requests are not supported"
                )
            }.joined(separator: ",") + "]"
        }
        try assertRespond(
            &responder,
            "[\(initializeFrame()),{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}]",
            expectedResponse: batchRefusal(ids: ["1"]), records: false, "batch with initialize"
        )
        try assertRespond(
            &responder, #"[{"jsonrpc":"2.0","id":5},{"jsonrpc":"2.0","id":null,"method":"ping"},{"jsonrpc":"2.0","id":9,"result":{}}]"#,
            expectedResponse: batchRefusal(ids: ["5", "null"]), records: false, "batch with malformed members"
        )
        try assertRespond(
            &responder, #"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#,
            expectedResponse: nil, records: false, "notification-only batch"
        )
        try assertRespond(
            &responder, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            expectedResponse: notInitialized, records: false, "still uninitialized after batch"
        )

        // The first valid initialize is answered and recorded, whatever failed before it.
        let instructionsJSON = try String(
            decoding: JSONEncoder().encode(MCPAppConnectionMessages.offlineInstructions(identity: identity)),
            as: UTF8.self
        )
        let initializeResult = """
        {"jsonrpc":"2.0","id":7,"result":{"protocolVersion":"2025-06-18",\
        "capabilities":{"prompts":{"listChanged":false},"resources":{"subscribe":false,"listChanged":false},\
        "tools":{"listChanged":true}},\
        "serverInfo":{"name":"RepoPrompt CE Debug","version":"9.9.9-test"},\
        "instructions":\(instructionsJSON)}}
        """
        try assertRespond(
            &responder, initializeFrame(id: "7"),
            expectedResponse: initializeResult, records: true, "first valid initialize"
        )
        try assertRespond(
            &responder, initializeFrame(id: "8"),
            expectedResponse: errorResponse(
                id: "8", code: -32600,
                message: "Invalid Request: Server is already initialized",
                detail: "Server is already initialized"
            ), records: false, "second initialize"
        )

        // After initialize: discovery is empty, calls fail with the message and never record.
        let afterInitialize: [(label: String, frame: String, response: String?, records: Bool)] = [
            ("initialized after initialize", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, nil, true),
            (
                "tools/list",
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#,
                false
            ),
            (
                "prompts/list",
                #"{"jsonrpc":"2.0","id":3,"method":"prompts/list"}"#,
                #"{"jsonrpc":"2.0","id":3,"result":{"prompts":[]}}"#,
                false
            ),
            (
                "resources/list",
                #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#,
                #"{"jsonrpc":"2.0","id":4,"result":{"resources":[]}}"#,
                false
            ),
            (
                "resources/templates/list",
                #"{"jsonrpc":"2.0","id":5,"method":"resources/templates/list"}"#,
                #"{"jsonrpc":"2.0","id":5,"result":{"resourceTemplates":[]}}"#,
                false
            ),
            (
                "tools/call fails and is not recorded",
                #"{"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"apply_edits","arguments":{}}}"#,
                #"{"jsonrpc":"2.0","id":"call-1","result":{"content":[{"type":"text","text":"OFFLINE-CONNECTION-MESSAGE"}],"isError":true}}"#,
                false
            ),
            (
                "tools/call with a numeric id",
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"anything"}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"OFFLINE-CONNECTION-MESSAGE"}],"isError":true}}"#,
                false
            ),
            ("cancellation", #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#, nil, false),
            ("other notification", #"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#, nil, false)
        ]
        for row in afterInitialize {
            try assertRespond(
                &responder, row.frame,
                expectedResponse: row.response, records: row.records, row.label
            )
        }

        // A responder created for a client that already has its result starts initialized.
        var resumed = makeResponder(initializeAnswered: true)
        try assertRespond(
            &resumed, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            expectedResponse: #"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#, records: false,
            "resumed responder lists tools"
        )
    }

    /// The offline loop delivers each reply through the same ledger as connected traffic, so a reply
    /// the ledger rejects ends the session, and a request left without a reply blocks attachment.
    func testOfflineRepliesCompleteTheirRequestsInTheBridgeLedger() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "offline-responder-ledger-test")
        _ = try await ledger.beginConnection()
        var responder = makeResponder()
        let frames = [
            initializeFrame(id: "1"),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"s-3","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"apply_edits"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"x"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"completion/complete"}"#,
            #"{"jsonrpc":"2.0","id":42}"#,
            #"{"jsonrpc":"2.0","id":43,"method":5}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#,
            initializeFrame(id: "7"),
            "[\(initializeFrame(id: "8")),{\"jsonrpc\":\"2.0\",\"id\":9},{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}]"
        ]
        for frame in frames {
            let clientFrame = Data((frame + "\n").utf8)
            let preparedRequest = try await ledger.prepare(frame: clientFrame, direction: .clientToServer)
            let outcome = try responder.respond(to: clientFrame, connectionMessage: connectionMessage)
            try await ledger.commit(preparedRequest)
            if let response = outcome.response {
                let preparedResponse = try await ledger.prepare(frame: response, direction: .serverToClient)
                try await ledger.commit(preparedResponse)
            }
            let snapshot = await ledger.snapshot()
            XCTAssertNil(snapshot.terminalReason, frame)
            XCTAssertEqual(snapshot.activeRequestCount, 0, "request left open after: \(frame)")
            XCTAssertEqual(snapshot.pendingTransactionCount, 0, frame)
        }
        // Attaching to the app starts a connection generation, which a ledger with open work refuses.
        _ = try await ledger.beginConnection()
    }

    func testOfflineInitializeMatchesAppSDKHandshake() async throws {
        let versions = Version.supported.sorted() + ["1999-01-01"]
        for version in versions {
            let frame = Data(initializeFrame(protocolVersion: version).utf8)

            var responder = makeResponder()
            let offline = try responder.respond(to: frame, connectionMessage: connectionMessage)
            let offlineResult = try XCTUnwrap(
                try (JSONSerialization.jsonObject(with: XCTUnwrap(offline.response)) as? [String: Any])?["result"],
                "offline result for \(version)"
            )

            let appResult = try await appServerResult(toInitializeFrame: frame)

            let offlineFingerprint = MCPInitializeReplayState.initializeCompatibilityFingerprint(offlineResult)
            XCTAssertNotNil(offlineFingerprint, "fingerprint for \(version)")
            XCTAssertEqual(
                offlineFingerprint,
                MCPInitializeReplayState.initializeCompatibilityFingerprint(appResult),
                "offline initialize must be compatible with the app's for requested version \(version)"
            )
        }
    }

    /// Drives an SDK server built the way the app builds its own, over an in-memory transport.
    private func appServerResult(toInitializeFrame frame: Data) async throws -> Any {
        let server = MCP.Server(
            name: "RepoPrompt CE Debug",
            version: "0.0",
            capabilities: MCPAppServerCapabilities.value
        )
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        try await clientTransport.connect()
        defer {
            Task {
                await server.stop()
                await clientTransport.disconnect()
            }
        }

        let messages = await clientTransport.receive()
        try await clientTransport.send(frame)
        let reply = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                var iterator = messages.makeAsyncIterator()
                return try await iterator.next()
            }
            // Only a guard against hanging the suite if the SDK server never answers.
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        let data = try XCTUnwrap(reply, "the SDK server did not answer initialize")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["result"], "SDK reply: \(String(decoding: data, as: UTF8.self))")
    }
}
