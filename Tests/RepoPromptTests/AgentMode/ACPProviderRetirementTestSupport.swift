import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// A scripted ACP agent for tests that release and restart ACP processes. Every process it
    /// starts appends to one record file, so a test can follow requests across process
    /// replacement. Each conversation's prompts are kept in a store that outlives the process, and
    /// `session/load` of a stored conversation records what it recovered.
    final class StartupTestACPPeer: @unchecked Sendable {
        /// One line of the record file.
        struct Record: Equatable {
            /// The request method, or `start` and `exit` for the process's own lifecycle.
            let event: String
            let pid: Int32
            let sessionID: String?
            /// For `session/prompt`, the text the agent received.
            let text: String?
            /// For `session/load`, the prompts the stored conversation holds, or nil when it is unknown.
            let history: [String]?
        }

        let scriptURL: URL
        let recordURL: URL
        let storeURL: URL

        /// Writes the agent into `directory`, which the caller owns and deletes.
        init(directory: URL) throws {
            scriptURL = directory.appendingPathComponent("scripted_acp_agent.py")
            recordURL = directory.appendingPathComponent("record.jsonl")
            storeURL = directory.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
            try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        /// A Cursor provider over this agent. Cursor needs no MCP routing before its prompt.
        /// `loadSession` is the capability the agent advertises; `failLoad` answers every
        /// `session/load` with "session not found"; `failNew` fails every `session/new`.
        func provider(loadSession: Bool = true, failLoad: Bool = false, failNew: Bool = false) -> StartupTestACPProvider {
            var environment = [
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_STORE_DIR": storeURL.path,
                "ACP_LOAD_SESSION": loadSession ? "1" : "0"
            ]
            if failLoad { environment["ACP_FAIL_LOAD"] = "1" }
            if failNew { environment["ACP_FAIL_NEW"] = "1" }
            return StartupTestACPProvider(commandPath: scriptURL.path, environment: environment)
        }

        var records: [Record] {
            guard let data = try? Data(contentsOf: recordURL),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = object["event"] as? String,
                      let pid = object["pid"] as? Int
                else { return nil }
                return Record(
                    event: event,
                    pid: Int32(pid),
                    sessionID: object["sessionId"] as? String,
                    text: object["text"] as? String,
                    history: object["history"] as? [String]
                )
            }
        }

        /// Every process the agent started, in start order.
        var startedPIDs: [Int32] {
            records.filter { $0.event == "start" }.map(\.pid)
        }

        func hasExited(_ pid: Int32) -> Bool {
            records.contains { $0.event == "exit" && $0.pid == pid }
        }

        /// Kills every process the agent started that has not recorded its exit, so a failed test
        /// leaves none behind. Only processes this record names are signalled.
        func killUnexitedProcesses() {
            for pid in startedPIDs where !hasExited(pid) {
                kill(pid, SIGKILL)
            }
        }

        private static let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import signal
        import sys

        record_path = os.environ["ACP_RECORD_PATH"]
        store_dir = os.environ["ACP_STORE_DIR"]
        load_supported = os.environ.get("ACP_LOAD_SESSION", "1") == "1"
        fail_load = os.environ.get("ACP_FAIL_LOAD") == "1"
        fail_new = os.environ.get("ACP_FAIL_NEW") == "1"
        pid = os.getpid()
        new_sessions = 0

        def record(entry):
            entry["pid"] = pid
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry) + "\n")

        def finish(*_):
            record({"event": "exit"})
            os._exit(0)

        signal.signal(signal.SIGTERM, finish)

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result or {}
            print(json.dumps(payload), flush=True)

        def stored(session_id):
            path = os.path.join(store_dir, session_id + ".json")
            if not os.path.exists(path):
                return None
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)

        def store(session_id, history):
            with open(os.path.join(store_dir, session_id + ".json"), "w", encoding="utf-8") as handle:
                json.dump(history, handle)

        record({"event": "start"})
        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            if "id" not in request or "method" not in request:
                continue
            method = request["method"]
            params = request.get("params") or {}
            if method == "initialize":
                record({"event": method})
                respond(request["id"], {"agentCapabilities": {"loadSession": load_supported}, "authMethods": []})
            elif method == "session/new":
                record({"event": method})
                if fail_new:
                    respond(request["id"], error={"code": -32603, "message": "session/new failed"})
                    continue
                new_sessions += 1
                session_id = "session-%d-%d" % (pid, new_sessions)
                store(session_id, [])
                respond(request["id"], {"sessionId": session_id})
            elif method == "session/load":
                session_id = params.get("sessionId")
                history = stored(session_id)
                record({"event": method, "sessionId": session_id, "history": history})
                if fail_load or history is None:
                    respond(request["id"], error={"code": -32602, "message": "session not found: " + str(session_id)})
                    continue
                respond(request["id"], {})
            elif method == "session/prompt":
                session_id = params.get("sessionId")
                text = "\n".join(block.get("text", "") for block in params.get("prompt", []) if block.get("type") == "text")
                record({"event": method, "sessionId": session_id, "text": text})
                history = stored(session_id) or []
                history.append(text)
                store(session_id, history)
                respond(request["id"], {"stopReason": "end_turn"})
            else:
                respond(request["id"], {})
        finish()
        """#
    }

    /// Cursor's provider identity over `StartupTestACPPeer`. A stored conversation ID selects
    /// `session/load`, as the real ACP providers do.
    struct StartupTestACPProvider: ACPAgentProvider {
        let providerID: ACPProviderID = .cursor
        let commandPath: String
        let environment: [String: String]

        func support(for _: ACPRunRequest) async -> ACPSupportResult {
            .supported
        }

        func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
            ACPLaunchConfiguration(
                providerID: providerID,
                command: commandPath,
                arguments: [],
                environment: environment,
                workingDirectory: request.workspacePath,
                additionalPathHints: [],
                enableDebugLogging: false
            )
        }

        func makeSessionConfiguration(
            for request: ACPRunRequest,
            mcpServer _: RepoPromptMCPServerConfiguration
        ) throws -> ACPSessionConfiguration {
            let workingDirectory = request.workspacePath ?? FileManager.default.temporaryDirectory.path
            let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mode: ACPSessionConfiguration.Mode = if let resume, !resume.isEmpty {
                .load(existingSessionID: resume)
            } else {
                .new
            }
            return ACPSessionConfiguration(mode: mode, workingDirectory: workingDirectory, mcpServers: [])
        }

        func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
            [["type": "text", "text": message.userMessage]]
        }

        func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
            []
        }

        func normalizeError(_ error: Error) -> Error {
            error
        }
    }
#endif
