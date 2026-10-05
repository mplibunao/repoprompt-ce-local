import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// Joining an established agent run requires that run's session token or a newly armed
    /// run-owned pending policy. Matching process ancestry alone is refused before the connection
    /// can route, bind a window, or serve tools, and the refused client is told why.
    ///
    /// Four connection identities: C1 consumes the run's one-shot policy; C2 carries a fresh token
    /// with the same ancestry and no pending policy; C3 reconnects with C1's token; C4 carries a
    /// fresh token admitted by a newly installed pending policy.
    @MainActor
    final class PersistedMCPRoutingIdentityTests: XCTestCase {
        func testExpectedPIDAloneRejectsEstablishedRunJoin() async throws {
            try await withEstablishedRun { run in
                // Missing and different tokens are both PID-only claims.
                for sessionKey in [nil, run.c2Token] {
                    let second = await run.apply(run.c2, sessionKey: sessionKey)
                    XCTAssertEqual(second.outcome, "rejected:\(BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason)")
                    XCTAssertEqual(second.runID, run.runID, "The refusal names the matched run for diagnostics only.")
                    XCTAssertTrue(second.restrictedTools.isEmpty)
                    XCTAssertEqual(second.purpose, .unknown)
                    XCTAssertNil(second.windowID)
                    await run.assertUnrouted(run.c2)
                    await run.assertOwner(run.c1)
                }
                let refusals = await run.refusalEventCount()
                XCTAssertEqual(refusals, 2, "Each refusal records one bounded diagnostic event.")
            }
        }

        func testSameTokenReconnectPreservesRunPolicy() async throws {
            try await withEstablishedRun { run in
                _ = await run.apply(run.c2, sessionKey: run.c2Token)
                await run.assertOwner(run.c1)

                let reconnect = await run.apply(run.c3, sessionKey: run.c1Token)
                XCTAssertEqual(reconnect.outcome, "fallback", "Token reconnect keeps the fallback path's outward outcome.")
                await run.assertOwner(run.c3)
            }
        }

        func testFreshPendingPolicyAdmitsNewConnection() async throws {
            try await withEstablishedRun { run in
                _ = await run.apply(run.c2, sessionKey: run.c2Token)

                await run.installRunPolicy()
                let explicit = await run.apply(run.c4, sessionKey: run.c4Token)
                XCTAssertEqual(explicit.outcome, "applied")
                XCTAssertEqual(explicit.runID, run.runID)
                await run.assertOwner(run.c4)
                let pending = await run.manager.debugPendingPolicySnapshot(for: run.clientName)
                XCTAssertFalse(pending.contains { $0.runID == run.runID }, "The new one-shot policy is consumed exactly once.")
            }
        }

        func testPeerTicketRoutesToItsRunPastAnotherRunsWaitingPolicy() async throws {
            try await withEstablishedRun { run in
                let peer = try await run.establishPeerRun()
                await run.installRunPolicy()

                // This process descends from the fixture run's expected agent PID, so without its
                // ticket the connection would match the fixture run's waiting policy.
                let peerReconnect = await run.apply(peer.reconnectID, sessionKey: peer.token)
                XCTAssertEqual(peerReconnect.outcome, "fallback")
                let peerRunID = await run.manager.runIDForConnection(peer.reconnectID)
                XCTAssertEqual(peerRunID, peer.runID)
                let waiting = await run.pendingPolicyCount()
                XCTAssertEqual(waiting, 1, "The fixture run's policy still waits for its own helper.")

                let respawn = await run.apply(run.c4, sessionKey: run.c4Token)
                XCTAssertEqual(respawn.outcome, "applied")
                await run.assertOwner(run.c4)
                let remaining = await run.pendingPolicyCount()
                XCTAssertEqual(remaining, 0, "The fixture run's helper consumes it exactly once.")
            }
        }

        func testConnectionWithoutLiveRunTicketKeepsWaitingPolicyPath() async throws {
            try await withEstablishedRun { run in
                await run.installRunPolicy()

                // C2 claims a process unrelated to the run, first with no ticket and then with a
                // ticket no live run owns.
                for sessionKey in [nil, run.c2Token] {
                    let unrelated = await run.apply(
                        run.c2,
                        sessionKey: sessionKey,
                        clientPid: ExpectedPIDRunFixture.unrelatedHelperPID
                    )
                    XCTAssertEqual(unrelated.outcome, "rejected:ownership_timeout")
                    await run.assertUnrouted(run.c2)
                }
                let respawn = await run.apply(run.c4, sessionKey: run.c4Token)
                XCTAssertEqual(respawn.outcome, "applied", "The waiting policy is left for the run's own helper.")
            }
        }

        func testTicketOwnersWaitingPolicyKeepsItsConsumption() async throws {
            try await withEstablishedRun { run in
                await run.installRunPolicy()

                let reconnect = await run.apply(run.c3, sessionKey: run.c1Token)
                XCTAssertEqual(reconnect.outcome, "applied", "A run's own helper consumes its run's waiting policy.")
                await run.assertOwner(run.c3)
                let remaining = await run.pendingPolicyCount()
                XCTAssertEqual(remaining, 0)
            }
        }

        func testRejectedHandshakeDoesNotAutoBindWindow() async throws {
            try await withEstablishedRun { run in
                let enabledWindowIDs = WindowStatesManager.shared.allWindows
                    .filter(\.mcpServer.windowToolsEnabled)
                    .map(\.windowID)
                XCTAssertEqual(
                    enabledWindowIDs,
                    [run.window.windowID],
                    "Exactly one MCP-enabled window makes any unbound connection eligible for automatic binding."
                )

                let handshake = try await run.handshake(run.c2, sessionToken: run.c2Token)
                XCTAssertNotNil(handshake.error)
                _ = try await handshake.client.request(method: "tools/list", params: [:])

                await run.assertUnrouted(run.c2)
                await run.assertOwner(run.c1)
            }
        }

        func testRejectedConnectionCannotListOrCallTools() async throws {
            try await withEstablishedRun { run in
                let catalogReady = await MCPToolCatalogReadiness.shared.awaitReady(windowID: run.window.windowID, timeout: 5)
                XCTAssertTrue(catalogReady, "An admitted connection on this window would receive a usable catalog.")

                let handshake = try await run.handshake(run.c2, sessionToken: run.c2Token)
                let refusal = try XCTUnwrap(handshake.error)

                let tools = try await handshake.client.request(method: "tools/list", params: [:])
                XCTAssertEqual(try JSONRPCErrorBody(tools)?.message, refusal.message)
                for toolName in ["apply_edits", "read_file"] {
                    let call = try await handshake.client.request(
                        method: "tools/call",
                        params: ["name": toolName, "arguments": ["path": "README.md"]]
                    )
                    XCTAssertEqual(try JSONRPCErrorBody(call)?.message, refusal.message, "\(toolName) must not execute.")
                }
                await run.assertUnrouted(run.c2)
                await run.assertOwner(run.c1)
            }
        }

        func testRejectedHandshakeReportsReasonAndRemedy() async throws {
            try await withEstablishedRun { run in
                let handshake = try await run.handshake(run.c2, sessionToken: run.c2Token)
                let refusal = try XCTUnwrap(handshake.error)
                let sessionName = try XCTUnwrap(run.sessionName)

                XCTAssertNotEqual(refusal.code, MCPError.connectionClosed.code, "SDK clients decode -32000 as a bare connection close.")
                XCTAssertTrue(refusal.message.contains(BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason))
                XCTAssertTrue(refusal.message.contains("agent session \"\(sessionName)\""))
                XCTAssertTrue(refusal.message.contains("no session ticket"))
                XCTAssertTrue(refusal.message.contains("start a new agent session"))
                XCTAssertTrue(refusal.message.contains("do not need to restart"))
            }
        }

        func testBootstrapReadinessDoesNotOverrideRoutingRejection() async throws {
            try await withEstablishedRun { run in
                let bootstrapReadiness = await run.manager.debugBootstrapPolicyAdmissionStatus(
                    bootstrapClientName: run.clientName,
                    connectionID: run.c2,
                    sessionKey: run.c2Token,
                    clientPid: Int(getpid())
                )
                let initializeReadiness = await run.manager.debugAgentPolicyAdmissionStatus(
                    clientName: run.clientName,
                    connectionID: run.c2,
                    sessionKey: run.c2Token,
                    clientPid: Int(getpid())
                )
                XCTAssertEqual(bootstrapReadiness, "ready")
                XCTAssertEqual(initializeReadiness, "ready")

                let handshake = try await run.handshake(run.c2, sessionToken: run.c2Token)
                XCTAssertNotNil(handshake.error, "Readiness lets policy evaluation proceed; it does not admit the connection.")
                await run.assertUnrouted(run.c2)
                await run.assertOwner(run.c1)
            }
        }

        // MARK: - Tool requests during admission

        // The MCP server dispatches requests concurrently, so a client can pipeline tool requests
        // behind an `initialize` whose admission is still being decided.

        func testToolRequestsPipelinedDuringRefusedJoinAdmissionNeverRun() async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                let admission = try await Self.pipelineToolRequestsDuringAdmission(
                    on: run.c2,
                    sessionToken: run.c2Token,
                    approving: true,
                    in: run
                )

                for response in admission.pipelined {
                    XCTAssertEqual(response?.message, Self.admissionPendingMessage)
                }
                let refusal = try XCTUnwrap(admission.initializeError)
                XCTAssertTrue(refusal.message.contains(BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason))
                XCTAssertEqual(executions.startedTools(on: run.c2), [])
                await run.assertUnrouted(run.c2)
                await run.assertOwner(run.c1)
            }
        }

        func testToolRequestsPipelinedBeforeAdmittedInitializeAreRefused() async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                await run.installRunPolicy()
                let admission = try await Self.pipelineToolRequestsDuringAdmission(
                    on: run.c4,
                    sessionToken: run.c4Token,
                    approving: true,
                    in: run
                )

                for response in admission.pipelined {
                    XCTAssertEqual(response?.message, Self.admissionPendingMessage)
                }
                XCTAssertNil(admission.initializeError)
                XCTAssertEqual(executions.startedTools(on: run.c4), [])
                await run.assertOwner(run.c4)
                let tools = try await admission.client.request(method: "tools/list", params: [:])
                XCTAssertNil(try JSONRPCErrorBody(tools), "Once admitted, the connection is served.")
            }
        }

        func testToolRequestsPipelinedBeforeDeniedInitializeAreRefused() async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                let admission = try await Self.pipelineToolRequestsDuringAdmission(
                    on: run.c2,
                    sessionToken: run.c2Token,
                    approving: false,
                    in: run
                )

                for response in admission.pipelined {
                    XCTAssertEqual(response?.message, Self.admissionPendingMessage)
                }
                XCTAssertEqual(admission.initializeError?.code, MCPError.connectionClosed.code)
                let afterDenial = try await admission.client.request(method: "tools/list", params: [:])
                XCTAssertEqual(
                    try JSONRPCErrorBody(afterDenial)?.message,
                    Self.admissionPendingMessage,
                    "A connection no initialize has admitted stays refused."
                )
                XCTAssertEqual(executions.startedTools(on: run.c2), [])
                await run.assertUnrouted(run.c2)
            }
        }

        /// An admitted connection reaches admission again only through an `initialize` that raced the
        /// admitted one, so the fence is observed while another `initialize` admits the connection.
        func testToolCallWhileAdmissionFenceIsInstalledIsRefused() async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                await run.installRunPolicy()
                let fence = AdmissionBarrier()
                let fences = BarrierSequence([fence])
                let client = try await run.connect(
                    run.c4,
                    sessionToken: run.c4Token,
                    admissionFenceHook: { _ = await fences.hold() }
                )
                let fenced = HeldInitialize(on: client, in: run, heldBy: fence)
                try await fenced.held()
                let admitted = try await run.initialize(client)
                XCTAssertNil(admitted)
                await run.assertOwner(run.c4)

                let call = try await client.request(method: "tools/call", params: Self.readFileCall)
                XCTAssertEqual(try JSONRPCErrorBody(call)?.message, Self.admissionPendingMessage)
                XCTAssertEqual(executions.startedTools(on: run.c4), [])

                let rejoined = try await fenced.finish(approving: true).get()
                XCTAssertNil(rejoined, "The connection's own session token rejoins its run.")
                let afterSettlement = try await client.request(method: "tools/list", params: [:])
                XCTAssertNil(try JSONRPCErrorBody(afterSettlement))
                await run.assertOwner(run.c4)
            }
        }

        func testToolRequestsBeforeAnyInitializeAreRefused() async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                let client = try await run.connect(run.c2, sessionToken: run.c2Token)

                let tools = try await client.request(method: "tools/list", params: [:])
                let call = try await client.request(method: "tools/call", params: Self.readFileCall)
                for response in [tools, call] {
                    XCTAssertEqual(try JSONRPCErrorBody(response)?.message, Self.admissionPendingMessage)
                }
                XCTAssertEqual(executions.startedTools(on: run.c2), [])
                await run.assertUnrouted(run.c2)
            }
        }

        func testOverlappingInitializeDeniedFirstKeepsToolsClosedUntilTheOtherIsAdmitted() async throws {
            try await assertOverlappingInitializeSequence(schedule: .deniedThenAdmitted)
        }

        func testOverlappingInitializeAdmittedFirstKeepsToolsClosedUntilTheOtherSettles() async throws {
            try await assertOverlappingInitializeSequence(schedule: .admittedThenDenied)
        }

        /// The refused join's routing decision predates the admission, so once it settles it fails
        /// only its own `initialize`.
        func testRunJoinRefusalDecidedBeforeALaterAdmissionLeavesToolsOpen() async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                let decided = AdmissionBarrier()
                let client = try await run.connect(
                    run.c2,
                    sessionToken: run.c2Token,
                    admissionDecidedHook: { admission in
                        if case .establishedRunJoinRefused = admission {
                            _ = await decided.hold()
                        }
                    }
                )
                let refusedJoin = HeldInitialize(on: client, in: run, heldBy: decided)
                try await refusedJoin.held()

                await run.installRunPolicy()
                let admitted = try await run.initialize(client)
                XCTAssertNil(admitted)
                await run.assertOwner(run.c2)

                let refusal = try await refusedJoin.finish(approving: true).get()
                XCTAssertTrue(
                    refusal?.message.contains(BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason) == true,
                    "The refused join still fails its own initialize."
                )
                let tools = try await client.request(method: "tools/list", params: [:])
                XCTAssertNil(try JSONRPCErrorBody(tools))
                let call = try await client.request(method: "tools/call", params: Self.readFileCall)
                XCTAssertNil(try JSONRPCErrorBody(call))
                XCTAssertEqual(executions.startedTools(on: run.c2), ["read_file"])
                await run.assertOwner(run.c2)
            }
        }

        func testDeniedReinitializeKeepsRunJoinRefusal() async throws {
            try await withEstablishedRun { run in
                let approvals = ApprovalSequence([true, false])
                let client = try await run.connect(run.c2, sessionToken: run.c2Token) { _, _ in
                    await approvals.next()
                }
                let joinAttempt = try await run.initialize(client)
                let refusal = try XCTUnwrap(joinAttempt)
                let denied = try await run.initialize(client)
                XCTAssertEqual(denied?.code, MCPError.connectionClosed.code)

                let tools = try await client.request(method: "tools/list", params: [:])
                XCTAssertEqual(try JSONRPCErrorBody(tools)?.message, refusal.message)
                await run.assertUnrouted(run.c2)
            }
        }

        // MARK: - Recovery and cleanup

        func testRefusedConnectionRecoversOnSameSocketThroughNewRunPolicy() async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                let client = try await run.connect(run.c2, sessionToken: run.c2Token)
                let refusal = try await run.initialize(client)
                XCTAssertNotNil(refusal)
                await run.assertUnrouted(run.c2)

                await run.installRunPolicy()
                let readmission = try await run.initialize(client)
                XCTAssertNil(readmission, "The same socket's next initialize consumes the new run-owned policy.")
                await run.assertOwner(run.c2)

                let tools = try await client.request(method: "tools/list", params: [:])
                let advertised = try Self.toolNames(in: tools)
                XCTAssertFalse(advertised.contains("apply_edits"), "The run's restriction still hides apply_edits.")
                XCTAssertTrue(advertised.contains("workspace_context"))
                let allowed = try await client.request(
                    method: "tools/call",
                    params: ["name": "workspace_context", "arguments": [String: Any]()]
                )
                XCTAssertNil(try JSONRPCErrorBody(allowed))
                XCTAssertFalse(try Self.isToolError(allowed))
                _ = try await client.request(
                    method: "tools/call",
                    params: ["name": "apply_edits", "arguments": ["path": "README.md", "search": "a", "replace": "b"]]
                )
                XCTAssertEqual(executions.startedTools(on: run.c2), ["workspace_context"], "The restricted tool never runs.")
            }
        }

        func testFixtureCleanupKeepsOtherSessionsRouting() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let manager = ServerNetworkManager.shared
                let clientName = AgentProviderKind.openCodeMCPClientID
                let sentinelToken = "routing-identity-sentinel-\(UUID().uuidString)"
                // No window uses this ID, so closing the fixture window leaves the sentinel untouched.
                let sentinelWindowID = Int(Int32.max)
                await manager.debugSeedRoutingSessionForTesting(
                    clientName: clientName,
                    sessionToken: sentinelToken,
                    windowID: sentinelWindowID,
                    runID: UUID()
                )
                var fixtureTokens: Set<String> = []
                var fixtureError: Error?
                do {
                    try await ExpectedPIDRunFixture.withEstablishedRun(
                        lease: lease,
                        sessionName: "Routing identity fixture session"
                    ) { run in
                        await run.installRunPolicy()
                        let admitted = try await run.handshake(run.c4, sessionToken: run.c4Token)
                        XCTAssertNil(admitted.error)
                        fixtureTokens = run.sessionTokens
                        let during = await manager.debugRoutingSessionTokens(for: clientName)
                        XCTAssertTrue(during.liveRunAffinities.contains(run.c4Token), "The fixture leaves routing for cleanup.")
                    }
                } catch {
                    fixtureError = error
                }
                let after = await manager.debugRoutingSessionTokens(for: clientName)
                await manager.debugRemoveRoutingSessionsForTesting([sentinelToken])
                if let fixtureError {
                    throw fixtureError
                }

                for tokens in [after.records, after.lastWindows, after.liveRunAffinities] {
                    XCTAssertTrue(tokens.contains(sentinelToken), "Another session's routing survives fixture cleanup.")
                    XCTAssertTrue(tokens.isDisjoint(with: fixtureTokens))
                }
            }
        }

        // MARK: - Fixture

        private static let admissionPendingMessage = MCPError
            .invalidRequest(BootstrapHandshakeAdmission.admissionPendingMessage)
            .errorDescription

        /// Holds `connectionID`'s `initialize` at its approval step, sends `tools/list` and a
        /// `tools/call` behind it, then lets admission finish with `approving`.
        private static func pipelineToolRequestsDuringAdmission(
            on connectionID: UUID,
            sessionToken: String,
            approving: Bool,
            in run: ExpectedPIDRunFixture
        ) async throws -> (pipelined: [JSONRPCErrorBody?], initializeError: JSONRPCErrorBody?, client: PersistentMCPTestSocketClient) {
            let barrier = AdmissionBarrier()
            let client = try await run.connect(connectionID, sessionToken: sessionToken) { _, _ in
                await barrier.hold()
            }
            let initialize = HeldInitialize(on: client, in: run, heldBy: barrier)
            try await initialize.held()
            let pipelined: [JSONRPCErrorBody?]
            let readFileCall = readFileCall
            do {
                async let toolList = client.request(method: "tools/list", params: [:])
                async let toolCall = client.request(method: "tools/call", params: readFileCall)
                pipelined = try await [JSONRPCErrorBody(toolList), JSONRPCErrorBody(toolCall)]
            } catch {
                await initialize.finish(approving: false)
                throw error
            }
            let initializeError = try await initialize.finish(approving: approving).get()
            return (pipelined, initializeError, client)
        }

        /// The settlement order of the two overlapping `initialize` attempts — both schedules
        /// settle the second attempt first — not the order the requests were created.
        private enum OverlappingInitializeSchedule {
            case deniedThenAdmitted
            case admittedThenDenied
        }

        /// The shared sequence behind the two overlapping-initialize tests: overlap two held
        /// `initialize` approvals, settle the second attempt before the first in the order the
        /// schedule names, and verify tools stay fenced while the first attempt is still pending.
        private func assertOverlappingInitializeSequence(schedule: OverlappingInitializeSchedule) async throws {
            try await withEstablishedRun { run in
                let executions = run.recordToolExecutions()
                await run.installRunPolicy()
                let attempts = try await Self.overlappingInitializes(on: run.c4, sessionToken: run.c4Token, in: run)

                switch schedule {
                case .deniedThenAdmitted:
                    let denied = try await attempts.second.finish(approving: false).get()
                    XCTAssertEqual(denied?.code, MCPError.connectionClosed.code)
                case .admittedThenDenied:
                    let admitted = try await attempts.second.finish(approving: true).get()
                    XCTAssertNil(admitted)
                    await run.assertOwner(run.c4)
                }

                let whileFirstPending = try await attempts.client.request(method: "tools/call", params: Self.readFileCall)
                XCTAssertEqual(try JSONRPCErrorBody(whileFirstPending)?.message, Self.admissionPendingMessage)

                switch schedule {
                case .deniedThenAdmitted:
                    let admitted = try await attempts.first.finish(approving: true).get()
                    XCTAssertNil(admitted)
                    await run.assertOwner(run.c4)
                    let afterAdmission = try await attempts.client.request(method: "tools/list", params: [:])
                    XCTAssertNil(try JSONRPCErrorBody(afterAdmission))
                case .admittedThenDenied:
                    let denied = try await attempts.first.finish(approving: false).get()
                    XCTAssertEqual(denied?.code, MCPError.connectionClosed.code)
                    let afterDenial = try await attempts.client.request(method: "tools/list", params: [:])
                    XCTAssertNil(try JSONRPCErrorBody(afterDenial), "The admitted initialize still stands.")
                    await run.assertOwner(run.c4)
                }
                XCTAssertEqual(executions.startedTools(on: run.c4), [])
            }
        }

        /// Two `initialize` requests on one socket, each held at its own approval.
        private static func overlappingInitializes(
            on connectionID: UUID,
            sessionToken: String,
            in run: ExpectedPIDRunFixture
        ) async throws -> (client: PersistentMCPTestSocketClient, first: HeldInitialize, second: HeldInitialize) {
            let firstApproval = AdmissionBarrier()
            let secondApproval = AdmissionBarrier()
            let approvals = BarrierSequence([firstApproval, secondApproval])
            let client = try await run.connect(connectionID, sessionToken: sessionToken) { _, _ in
                await approvals.hold()
            }
            let first = HeldInitialize(on: client, in: run, heldBy: firstApproval)
            try await first.held()
            let second = HeldInitialize(on: client, in: run, heldBy: secondApproval)
            try await second.held()
            return (client, first, second)
        }

        private static let readFileCall: [String: Any] = ["name": "read_file", "arguments": ["path": "README.md"]]

        private static func toolNames(in response: PersistentMCPTestRPCResponse) throws -> [String] {
            let result = try XCTUnwrap(resultObject(in: response))
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }

        private static func isToolError(_ response: PersistentMCPTestRPCResponse) throws -> Bool {
            try XCTUnwrap(resultObject(in: response))["isError"] as? Bool ?? false
        }

        private static func resultObject(in response: PersistentMCPTestRPCResponse) throws -> [String: Any]? {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return object["result"] as? [String: Any]
        }

        private func withEstablishedRun(_ body: (ExpectedPIDRunFixture) async throws -> Void) async throws {
            try await ExpectedPIDRunFixture.withEstablishedRun(sessionName: "Routing identity fixture session", body)
        }
    }

    // MARK: - Shared run fixture

    /// One established agent run whose expected agent PID is this process's real parent, so
    /// connections from this process match its ancestry without spawning a provider.
    @MainActor
    final class ExpectedPIDRunFixture {
        let manager = ServerNetworkManager.shared
        let clientName = AgentProviderKind.openCodeMCPClientID
        let runID = UUID()
        let restrictedTools: Set<String>
        let window: WindowState
        let tabID: UUID?
        let sessionName: String?
        let c1 = UUID()
        let c2 = UUID()
        let c3 = UUID()
        let c4 = UUID()
        let c1Token = "routing-identity-c1-\(UUID().uuidString)"
        let c2Token = "routing-identity-c2-\(UUID().uuidString)"
        let c4Token = "routing-identity-c4-\(UUID().uuidString)"
        let cleanup: FixtureCleanup
        private var peerTokens: Set<String> = []

        /// Session tokens this fixture's connections carry. Cleanup removes routing state for these
        /// alone, so other sessions' routing survives the fixture.
        var sessionTokens: Set<String> {
            peerTokens.union([c1Token, c2Token, c4Token])
        }

        private init(
            window: WindowState,
            tabID: UUID?,
            sessionName: String?,
            restrictedTools: Set<String>,
            cleanup: FixtureCleanup
        ) {
            self.window = window
            self.tabID = tabID
            self.sessionName = sessionName
            self.restrictedTools = restrictedTools
            self.cleanup = cleanup
        }

        /// Establishes C1 as the run's owner in one MCP-enabled window and settles every piece of
        /// shared state the run touched, all inside the shared-MCP lease.
        static func withEstablishedRun(
            sessionName: String,
            restrictedTools: Set<String> = ["apply_edits"],
            _ body: (ExpectedPIDRunFixture) async throws -> Void
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                try await withEstablishedRun(
                    lease: lease,
                    sessionName: sessionName,
                    restrictedTools: restrictedTools,
                    body
                )
            }
        }

        /// The same run inside a shared-MCP lease the caller already holds.
        static func withEstablishedRun(
            lease _: MCPSharedServerTestLease.Ownership,
            sessionName: String,
            restrictedTools: Set<String> = ["apply_edits"],
            _ body: (ExpectedPIDRunFixture) async throws -> Void
        ) async throws {
            let cleanup = FixtureCleanup()
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            var run: ExpectedPIDRunFixture?
            try await cleanup.perform(
                operation: {
                    try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                    let window = try await makeWindow(cleanup: cleanup)
                    let established = try await establish(
                        in: window,
                        sessionName: sessionName,
                        restrictedTools: restrictedTools,
                        cleanup: cleanup
                    )
                    run = established
                    try await body(established)
                },
                afterCleanup: {
                    if let run {
                        await run.assertSettled()
                    }
                    XCTAssertEqual(GlobalSettingsStore.shared.mcpAutoStart(), previousAutoStart)
                }
            )
        }

        private static func makeWindow(cleanup: FixtureCleanup) async throws -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            cleanup.add {
                _ = await window.mcpServer.setWindowToolsEnabled(false)
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            WindowStatesManager.shared.registerWindowState(window)
            await window.workspaceManager.awaitInitialized()
            try await window.mcpServer.requireServerReadyForAgentBootstrap()
            return window
        }

        /// Installs the run in `window` and lets C1 consume its one-shot policy. With a session name,
        /// the run is bound to a compose tab of that name, as an Agent Mode session is.
        static func establish(
            in window: WindowState,
            sessionName: String?,
            restrictedTools: Set<String> = ["apply_edits"],
            cleanup: FixtureCleanup,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> ExpectedPIDRunFixture {
            var tabID: UUID?
            if let sessionName {
                let tab = ComposeTabState(id: UUID(), name: sessionName)
                var workspace = WorkspaceModel(name: "Routing identity fixture", repoPaths: [])
                workspace.isEphemeral = true
                workspace.composeTabs = [tab]
                workspace.activeComposeTabID = tab.id
                let workspaceID = workspace.id
                cleanup.add {
                    window.workspaceManager.workspaces.removeAll { $0.id == workspaceID }
                }
                window.workspaceManager.workspaces.append(workspace)
                tabID = tab.id
            }
            let run = ExpectedPIDRunFixture(
                window: window,
                tabID: tabID,
                sessionName: sessionName,
                restrictedTools: restrictedTools,
                cleanup: cleanup
            )
            let manager = run.manager
            let clientName = run.clientName
            let runID = run.runID
            let windowID = window.windowID
            let connectionIDs = [run.c1, run.c2, run.c3, run.c4]
            cleanup.add {
                for connectionID in connectionIDs {
                    await manager.debugRemoveConnection(connectionID)
                    window.mcpServer.removeTabContext(
                        forConnectionID: connectionID,
                        clientName: clientName,
                        windowID: nil,
                        runID: nil
                    )
                }
                await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
                await manager.debugRemoveRoutingSessionsForTesting(run.sessionTokens)
                await MCPRoutingWaiter.cleanup(runID: runID)
            }
            cleanup.add {
                await manager.clearExpectedAgentPID(getppid(), for: clientName, runID: runID)
            }
            await manager.registerExpectedAgentPID(getppid(), for: clientName, runID: runID)
            await run.installRunPolicy()

            let initial = await run.apply(run.c1, sessionKey: run.c1Token)
            XCTAssertEqual(initial.outcome, "applied", file: file, line: line)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pending.contains { $0.runID == runID }, "The initial one-shot policy is consumed.", file: file, line: line)
            await run.assertOwner(run.c1, file: file, line: line)
            return run
        }

        func installRunPolicy() async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: restrictedTools,
                oneShot: true,
                reason: "Expected-PID run affinity regression",
                ttl: 60,
                tabID: tabID,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
        }

        func apply(
            _ connectionID: UUID,
            sessionKey: String?,
            clientPid: Int = Int(getpid())
        ) async -> (restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, windowID: Int?, outcome: String, runID: UUID?) {
            await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: clientPid,
                sessionKey: sessionKey
            )
        }

        /// Pending policies installed for this run that no connection has consumed.
        func pendingPolicyCount() async -> Int {
            await manager.debugPendingPolicySnapshot(for: clientName).count { $0.runID == runID }
        }

        /// launchd's PID: a helper claiming it never descends from this run's expected agent PID.
        static let unrelatedHelperPID = 1

        /// Establishes another agent session's run beside this one: a second compose tab in this
        /// session's workspace, whose owner consumed the peer run's policy with its own session
        /// ticket from a process unrelated to this run.
        func establishPeerRun(file: StaticString = #filePath, line: UInt = #line) async throws -> PeerRun {
            let peer = PeerRun()
            let manager = manager
            let clientName = clientName
            let window = window
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { workspace in
                    workspace.composeTabs.contains { $0.id == tabID }
                },
                file: file,
                line: line
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                ComposeTabState(id: peer.tabID, name: "Routing identity peer session")
            )
            peerTokens.insert(peer.token)
            cleanup.add {
                for connectionID in [peer.ownerID, peer.reconnectID] {
                    await manager.debugRemoveConnection(connectionID)
                    window.mcpServer.removeTabContext(
                        forConnectionID: connectionID,
                        clientName: clientName,
                        windowID: nil,
                        runID: nil
                    )
                }
                await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: peer.runID)
                await manager.cleanupRunRoutingState(for: peer.runID, windowID: window.windowID)
            }
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: restrictedTools,
                oneShot: true,
                reason: "Routing identity peer run",
                ttl: 60,
                tabID: peer.tabID,
                runID: peer.runID,
                purpose: .agentModeRun
            )
            let initial = await apply(peer.ownerID, sessionKey: peer.token, clientPid: Self.unrelatedHelperPID)
            XCTAssertEqual(initial.outcome, "applied", file: file, line: line)
            XCTAssertEqual(initial.runID, peer.runID, file: file, line: line)
            return peer
        }

        /// Sends `initialize` from this process over a real socket through the production bootstrap
        /// registration, approval, policy-admission, and refusal path. Approval is granted, so any
        /// refusal comes from routing.
        func handshake(_ connectionID: UUID, sessionToken: String) async throws -> FixtureHandshake {
            let client = try await connect(connectionID, sessionToken: sessionToken)
            return try await FixtureHandshake(client: client, error: initialize(client))
        }

        /// Opens a real bootstrap socket for `connectionID` from this process and starts it through
        /// the production registration path; `approval` answers each of its `initialize` requests.
        func connect(
            _ connectionID: UUID,
            sessionToken: String,
            admissionFenceHook: (@Sendable () async -> Void)? = nil,
            admissionDecidedHook: (@Sendable (BootstrapHandshakeAdmission) async -> Void)? = nil,
            approval: @escaping ServerNetworkManager.ConnectionApprovalHandler = { _, _ in true }
        ) async throws -> PersistentMCPTestSocketClient {
            let (client, connectionManager) = try BootstrapTestConnectionFactory.make(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientName: clientName,
                clientPid: Int(getpid()),
                observedKernelPeerPID: Int(getpid()),
                parentManager: manager
            )
            let manager = manager
            cleanup.add {
                client.close()
                await connectionManager.stop()
                await manager.debugRemoveConnection(connectionID)
            }
            if let admissionFenceHook {
                await connectionManager.debugSetAdmissionFenceHook(admissionFenceHook)
            }
            if let admissionDecidedHook {
                await connectionManager.debugSetAdmissionDecidedHook(admissionDecidedHook)
            }
            let previousApproval = await manager.debugReplaceConnectionApprovalHandlerForTesting(approval)
            cleanup.add {
                _ = await manager.debugReplaceConnectionApprovalHandlerForTesting(previousApproval)
            }
            let started = await manager.debugRegisterAndStartBootstrapConnectionForTesting(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                clientName: clientName,
                manager: connectionManager
            )
            XCTAssertTrue(started)
            return client
        }

        /// Sends `initialize` on `client`; nil when RepoPrompt admits it.
        func initialize(_ client: PersistentMCPTestSocketClient) async throws -> JSONRPCErrorBody? {
            let response = try await client.request(
                method: "initialize",
                params: [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": ["name": clientName, "version": "persisted-routing-identity-test"]
                ]
            )
            return try JSONRPCErrorBody(response)
        }

        /// Records every tool execution that starts while the fixture is active.
        func recordToolExecutions() -> ToolExecutionLog {
            let log = ToolExecutionLog()
            MCPToolExecutionTracer.setTestSink { log.record($0) }
            cleanup.add { MCPToolExecutionTracer.setTestSink(nil) }
            return log
        }

        /// Refusals of this run recorded in the DEBUG run-routing history.
        func refusalEventCount() async -> Int {
            let history = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 500)
            let events = history["events"] as? [[String: Any]] ?? []
            return events.count { event in
                event["event"] as? String == "policy_rejected"
                    && (event["fields"] as? [String: String])?["reason"]
                    == BootstrapHandshakeAdmission.expectedPIDWithoutPendingPolicyReason
            }
        }

        /// The connection owns the run: it is the window's run route and carries the run's policy.
        func assertOwner(_ connectionID: UUID, file: StaticString = #filePath, line: UInt = #line) async {
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), connectionID, file: file, line: line)
            let cachedRunID = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(cachedRunID, runID, file: file, line: line)
            let policy = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(policy.restrictedTools, restrictedTools, file: file, line: line)
            XCTAssertEqual(policy.purpose, .agentModeRun, file: file, line: line)
            XCTAssertEqual(policy.windowID, window.windowID, file: file, line: line)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertEqual(runPolicy?.restrictedTools, restrictedTools, file: file, line: line)
        }

        /// The connection holds no run route, run policy, or window binding.
        func assertUnrouted(_ connectionID: UUID, file: StaticString = #filePath, line: UInt = #line) async {
            let cachedRunID = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(cachedRunID, file: file, line: line)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionID], file: file, line: line)
            let selectedWindow = await manager.selectedWindow(for: connectionID)
            XCTAssertNil(selectedWindow, file: file, line: line)
            XCTAssertEqual(
                window.mcpServer.connectionBindingSnapshot(forConnection: connectionID).bindingKind,
                .unbound,
                file: file,
                line: line
            )
            let policy = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertTrue(policy.restrictedTools.isEmpty, file: file, line: line)
            XCTAssertTrue(policy.additionalTools.isEmpty, file: file, line: line)
            XCTAssertEqual(policy.purpose, .unknown, file: file, line: line)
        }

        /// After cleanup, nothing this run installed remains in shared MCP state.
        func assertSettled(file: StaticString = #filePath, line: UInt = #line) async {
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pending.contains { $0.runID == runID }, file: file, line: line)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy, file: file, line: line)
            for connectionID in [c1, c2, c3, c4] {
                let registered = await manager.debugContainsConnection(connectionID)
                XCTAssertFalse(registered, file: file, line: line)
                let cachedRunID = await manager.debugCachedRunID(for: connectionID)
                XCTAssertNil(cachedRunID, file: file, line: line)
            }
            // With no expected agent PID or pending policy left, this process no longer looks like
            // an agent helper awaiting admission.
            let admission = await manager.debugAgentPolicyAdmissionStatus(
                clientName: clientName,
                connectionID: UUID(),
                clientPid: Int(getpid())
            )
            XCTAssertEqual(admission, "notRequired", file: file, line: line)
            XCTAssertNil(WindowStatesManager.shared.window(withID: window.windowID), file: file, line: line)
            let routing = await manager.debugRoutingSessionTokens(for: clientName)
            for tokens in [routing.records, routing.lastWindows, routing.liveRunAffinities] {
                XCTAssertTrue(tokens.isDisjoint(with: sessionTokens), file: file, line: line)
            }
        }
    }

    /// Tool executions observed through the execution tracer, by connection.
    final class ToolExecutionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var startedToolsByConnection: [UUID: [String]] = [:]

        func record(_ event: MCPToolExecutionTraceEvent) {
            guard event.phase == .started else { return }
            lock.withLock {
                startedToolsByConnection[event.connectionID, default: []].append(event.toolName)
            }
        }

        func startedTools(on connectionID: UUID) -> [String] {
            lock.withLock { startedToolsByConnection[connectionID] ?? [] }
        }
    }

    /// Answers successive `initialize` approvals in order.
    actor ApprovalSequence {
        private var answers: [Bool]

        init(_ answers: [Bool]) {
            self.answers = answers
        }

        func next() -> Bool {
            answers.isEmpty ? false : answers.removeFirst()
        }
    }

    /// Holds one bootstrap admission open until the test decides it.
    actor AdmissionBarrier {
        enum Entry: Equatable {
            case holding
            case initializeFinished
            case timedOut
        }

        private var entry: Entry?
        private var entryWaiters: [CheckedContinuation<Entry, Never>] = []
        private var decision: Bool?
        private var decisionWaiter: CheckedContinuation<Bool, Never>?

        /// Called where the admission is held; answers once the test releases the barrier.
        func hold() async -> Bool {
            record(.holding)
            if let decision {
                return decision
            }
            return await withCheckedContinuation { decisionWaiter = $0 }
        }

        /// The first of: the admission reaching the barrier, its `initialize` finishing without
        /// reaching it, or the entry deadline passing.
        func entered() async -> Entry {
            if let entry {
                return entry
            }
            return await withCheckedContinuation { entryWaiters.append($0) }
        }

        func record(_ event: Entry) {
            guard entry == nil else { return }
            entry = event
            for waiter in entryWaiters {
                waiter.resume(returning: event)
            }
            entryWaiters.removeAll()
        }

        func release(approving approved: Bool) {
            guard decision == nil else { return }
            decision = approved
            decisionWaiter?.resume(returning: approved)
            decisionWaiter = nil
        }
    }

    /// Holds successive `initialize` approvals at their own barriers, in order, and denies any
    /// approval beyond them.
    actor BarrierSequence {
        private var barriers: [AdmissionBarrier]

        init(_ barriers: [AdmissionBarrier]) {
            self.barriers = barriers
        }

        func hold() async -> Bool {
            guard !barriers.isEmpty else { return false }
            return await barriers.removeFirst().hold()
        }
    }

    /// One `initialize` on a test socket whose admission waits at an `AdmissionBarrier`. Every way
    /// out releases the barrier and joins the `initialize`, and fixture cleanup does the same, so a
    /// failed test reports instead of stalling the shared MCP lease.
    @MainActor
    final class HeldInitialize {
        enum EntryError: Error {
            case admissionNotHeld(entry: AdmissionBarrier.Entry, initialize: String)
        }

        private static let entryDeadline: Duration = .seconds(10)

        private let barrier: AdmissionBarrier
        private let response: Task<Result<JSONRPCErrorBody?, Error>, Never>
        private let deadline: Task<Void, Never>

        init(on client: PersistentMCPTestSocketClient, in run: ExpectedPIDRunFixture, heldBy barrier: AdmissionBarrier) {
            self.barrier = barrier
            response = Task {
                let outcome: Result<JSONRPCErrorBody?, Error>
                do {
                    outcome = try await .success(run.initialize(client))
                } catch {
                    outcome = .failure(error)
                }
                await barrier.record(.initializeFinished)
                return outcome
            }
            deadline = Task {
                guard await (try? Task.sleep(for: Self.entryDeadline)) != nil else { return }
                await barrier.record(.timedOut)
            }
            run.cleanup.add { [self] in
                await finish(approving: false)
            }
        }

        /// Returns once the admission waits at the barrier. Otherwise releases it, joins the
        /// `initialize`, and throws with how it ended.
        func held() async throws {
            let entry = await barrier.entered()
            guard entry == .holding else {
                let outcome = await finish(approving: false)
                throw EntryError.admissionNotHeld(entry: entry, initialize: String(describing: outcome))
            }
        }

        /// Releases the barrier with `approving` and returns the `initialize` outcome.
        @discardableResult
        func finish(approving: Bool) async -> Result<JSONRPCErrorBody?, Error> {
            deadline.cancel()
            await barrier.release(approving: approving)
            return await response.value
        }
    }

    struct FixtureHandshake {
        let client: PersistentMCPTestSocketClient
        let error: JSONRPCErrorBody?
    }

    /// Another agent session's run in the fixture window, routed by its own session ticket.
    struct PeerRun {
        let tabID = UUID()
        let runID = UUID()
        let token = "routing-identity-peer-\(UUID().uuidString)"
        let ownerID = UUID()
        let reconnectID = UUID()
    }

    struct JSONRPCErrorBody: Equatable {
        let code: Int
        let message: String

        /// Nil when the response carries a result instead of an error.
        init?(_ response: PersistentMCPTestRPCResponse) throws {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard let error = object["error"] as? [String: Any] else { return nil }
            code = try XCTUnwrap((error["code"] as? NSNumber)?.intValue)
            message = try XCTUnwrap(error["message"] as? String)
        }
    }

    /// Cleanup steps run in reverse registration order. Each step is registered before the shared
    /// state it restores is changed, so a failure part-way through a test still settles it.
    @MainActor
    final class FixtureCleanup {
        private var steps: [@MainActor () async -> Void] = []

        func add(_ step: @escaping @MainActor () async -> Void) {
            steps.append(step)
        }

        /// Runs `operation`, then always awaits the registered cleanup steps and `afterCleanup`
        /// before returning or rethrowing: a failing operation still settles the fixture, and
        /// `afterCleanup` observes the settled state before the original error surfaces.
        func perform(
            operation: @MainActor () async throws -> Void,
            afterCleanup: @MainActor () async -> Void = {}
        ) async throws {
            let result: Result<Void, Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await run()
            await afterCleanup()
            try result.get()
        }

        func run() async {
            while let step = steps.popLast() {
                await step()
            }
        }
    }
#endif
