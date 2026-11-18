import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

/// Answers one client frame on behalf of an app the helper cannot reach.
///
/// The responder does no I/O and keeps one bit of state, whether it has answered an `initialize`.
/// It never executes or queues a request: a `tools/call` always fails with the connection message,
/// so a call made while the app is away cannot run later when the app returns. It is a protocol
/// table, not a second implementation of the app's tools, catalog, or instructions.
struct MCPOfflineResponder {
    struct Outcome: Equatable {
        /// The newline-terminated frame to write to the client, if the input calls for one.
        var response: Data?
        /// True when the caller must pass the client frame to
        /// `MCPInitializeReplayState.recordForwardedClientFrame` so a later attachment can replay
        /// the session's handshake into the app. It is set only for a first valid `initialize` and
        /// for the `notifications/initialized` that follows it.
        var recordsClientFrameForReplay = false
    }

    private let identity: MCPFilesystemIdentity
    private let serverVersion: String
    private var initializeAnswered: Bool

    /// - Parameter initializeAnswered: Pass `true` when the client already has an initialize result,
    ///   as when the helper answers again after the app disconnects mid-session.
    init(identity: MCPFilesystemIdentity, serverVersion: String, initializeAnswered: Bool = false) {
        self.identity = identity
        self.serverVersion = serverVersion
        self.initializeAnswered = initializeAnswered
    }

    /// - Parameters:
    ///   - frame: One complete client frame, with or without its trailing newline.
    ///   - connectionMessage: Why the app is unreachable right now, for the requests that report it.
    mutating func respond(to frame: Data, connectionMessage: String) throws -> Outcome {
        // A frame that is not a JSON object or array has no id to answer. The ledger accounts for
        // it as an invalid client message.
        guard let root = try? JSONSerialization.jsonObject(with: frame, options: [.fragmentsAllowed]) else {
            return Outcome()
        }
        if let batch = root as? [Any] {
            return try Outcome(response: Self.answerBatch(batch))
        }
        guard let object = root as? [String: Any] else { return Outcome() }
        return try respond(to: object, connectionMessage: connectionMessage)
    }

    // MARK: - Single messages

    private mutating func respond(to object: [String: Any], connectionMessage: String) throws -> Outcome {
        guard !Self.isClientResponse(object) else { return Outcome() }
        guard object.keys.contains("id") else {
            return notificationOutcome(method: object["method"] as? String)
        }
        guard let method = object["method"] as? String,
              let id = JSONRPCBridgeID.parseJSONValue(object["id"]), id != .null
        else {
            return try Outcome(response: Self.encodeFrame(Self.malformedRequestRefusal(for: object)))
        }
        return try requestOutcome(id: id, method: method, params: object["params"], connectionMessage: connectionMessage)
    }

    /// The ledger keeps the id of any client object that carries one open until a response with that
    /// id is delivered, even when the object is not a valid request. Without an answer, the open id
    /// would count as unreplayable work and block the helper's later attachment to the app.
    private static func malformedRequestRefusal(for object: [String: Any]) -> Envelope {
        Envelope(
            id: JSONRPCBridgeID.parseJSONValue(object["id"]) ?? .null,
            body: .error(.invalidRequest("A request needs a string method and a string or integer id"))
        )
    }

    /// A result or error marks the object as a response, which the ledger correlates and the helper
    /// never answers.
    private static func isClientResponse(_ object: [String: Any]) -> Bool {
        object.keys.contains("result") || object.keys.contains("error")
    }

    private func notificationOutcome(method: String?) -> Outcome {
        // The helper never waits for `notifications/initialized` before answering, so only its
        // replay copy matters. Cancellations are accounted for by the ledger; nothing reaches the app.
        Outcome(recordsClientFrameForReplay: method == Self.initializedNotificationName && initializeAnswered)
    }

    private mutating func requestOutcome(
        id: JSONRPCBridgeID,
        method: String,
        params: Any?,
        connectionMessage: String
    ) throws -> Outcome {
        switch method {
        case Initialize.name:
            return try initializeOutcome(id: id, params: params)
        case Ping.name:
            return try reply(id: id, result: Empty())
        case "server/discover":
            return try fail(id: id, .methodNotFound("Unknown method: \(method)"))
        case ListTools.name:
            return try initializedReply(id: id, result: ListTools.Result(tools: []))
        case ListPrompts.name:
            return try initializedReply(id: id, result: ListPrompts.Result(prompts: []))
        case ListResources.name:
            return try initializedReply(id: id, result: ListResources.Result(resources: []))
        case ListResourceTemplates.name:
            return try initializedReply(id: id, result: ListResourceTemplates.Result(templates: []))
        case CallTool.name:
            let result = CallTool.Result(
                content: [.text(text: connectionMessage, annotations: nil, _meta: nil)],
                isError: true
            )
            return try initializedReply(id: id, result: result)
        case GetPrompt.name, ReadResource.name:
            return try fail(id: id, .serverError(code: Self.connectionUnavailableCode, message: connectionMessage))
        default:
            return try fail(id: id, .methodNotFound("Unknown method: \(method)"))
        }
    }

    private mutating func initializeOutcome(id: JSONRPCBridgeID, params: Any?) throws -> Outcome {
        guard !initializeAnswered else {
            return try fail(id: id, .invalidRequest("Server is already initialized"))
        }
        guard let parameters = Self.decodeInitializeParameters(params) else {
            return try fail(id: id, .invalidParams("Invalid initialize parameters"))
        }
        let result = Initialize.Result(
            protocolVersion: Version.supported.contains(parameters.protocolVersion)
                ? parameters.protocolVersion
                : Version.latest,
            capabilities: MCPAppServerCapabilities.value,
            serverInfo: MCP.Server.Info(name: identity.appDisplayName, version: serverVersion),
            instructions: MCPAppConnectionMessages.offlineInstructions(identity: identity)
        )
        var outcome = try reply(id: id, result: result)
        // Set only after the result encoded, so a failed first attempt leaves a later one possible.
        initializeAnswered = true
        outcome.recordsClientFrameForReplay = true
        return outcome
    }

    private func initializedReply(id: JSONRPCBridgeID, result: some Encodable) throws -> Outcome {
        guard initializeAnswered else {
            return try fail(id: id, .invalidRequest("MCP session is not initialized."))
        }
        return try reply(id: id, result: result)
    }

    private func reply(id: JSONRPCBridgeID, result: some Encodable) throws -> Outcome {
        try Outcome(response: Self.encodeFrame(Envelope(id: id, body: .result(result))))
    }

    private func fail(id: JSONRPCBridgeID, _ error: MCPError) throws -> Outcome {
        try Outcome(response: Self.encodeFrame(Envelope(id: id, body: .error(error))))
    }

    // MARK: - Batches

    /// A batch never initializes the session, because the replay cache cannot represent one. Each
    /// member that carries an id and is not a response gets `-32600`; notification and response
    /// members get nothing.
    private static func answerBatch(_ batch: [Any]) throws -> Data? {
        guard !batch.isEmpty else {
            return try encodeFrame(Envelope(id: .null, body: .error(.invalidRequest("Empty batch"))))
        }
        var responses: [Envelope] = []
        for member in batch {
            guard let object = member as? [String: Any],
                  !isClientResponse(object),
                  object.keys.contains("id")
            else { continue }
            let id = JSONRPCBridgeID.parseJSONValue(object["id"]) ?? .null
            responses.append(Envelope(id: id, body: .error(.invalidRequest("Batch requests are not supported"))))
        }
        return responses.isEmpty ? nil : try encodeFrame(responses)
    }

    // MARK: - Encoding

    /// The JSON-RPC server-error code the SDK uses for a transport that cannot deliver.
    private static let connectionUnavailableCode = -32001

    private static let initializedNotificationName = InitializedNotification.name

    private static func decodeInitializeParameters(_ params: Any?) -> Initialize.Parameters? {
        guard let params = params as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: params)
        else { return nil }
        return try? JSONDecoder().decode(Initialize.Parameters.self, from: data)
    }

    private static func encodeFrame(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var frame = try encoder.encode(value)
        frame.append(UInt8(ascii: "\n"))
        return frame
    }

    /// A JSON-RPC response. The id is encoded from `JSONRPCBridgeID`, never through the SDK's `ID`,
    /// which turns a null id into an empty string and would let a string and a number collide.
    private struct Envelope: Encodable {
        enum Body {
            case result(any Encodable)
            case error(MCPError)
        }

        let id: JSONRPCBridgeID
        let body: Body

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, result, error
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("2.0", forKey: .jsonrpc)
            switch id {
            case let .number(value): try container.encode(value, forKey: .id)
            case let .string(value): try container.encode(value, forKey: .id)
            case .null: try container.encodeNil(forKey: .id)
            }
            switch body {
            case let .result(result): try container.encode(result, forKey: .result)
            case let .error(error): try container.encode(error, forKey: .error)
            }
        }
    }
}
