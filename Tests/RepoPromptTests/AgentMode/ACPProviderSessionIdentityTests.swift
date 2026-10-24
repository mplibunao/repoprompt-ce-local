import Foundation
@testable import RepoPromptApp
import XCTest

final class ACPProviderSessionIdentityTests: XCTestCase {
    func testCursorNewSessionPublishesRuntimeIDAsVerifiedLoadID() async throws {
        let workspace = try makeTemporaryDirectory()
        let peer = try StartupTestACPPeer(directory: makeTemporaryDirectory())
        let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        let provider = peer.provider(runtimeSessionID: "cursor-runtime-id")
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        let stream = await controller.currentEventsStream()

        let bootstrap = try await controller.bootstrap()
        XCTAssertEqual(bootstrap.sessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)

        try await controller.prompt(AgentMessage(userMessage: "Hello Cursor"), request: request)
        let messageStop = await firstMessageStop(in: stream)
        await controller.shutdown()

        XCTAssertEqual(messageStop?.providerSessionID, "cursor-runtime-id")
    }

    func testOpenCodeColdResumeUsesPersistedSessionIDForLoad() async throws {
        let workspace = try makeTemporaryDirectory()
        let peer = try StartupTestACPPeer(directory: makeTemporaryDirectory())
        try peer.storeConversation("persisted-session-id")
        let request = makeRunRequest(
            agentKind: .openCode,
            workspacePath: workspace.path,
            resumeSessionID: "persisted-session-id"
        )
        let controller = try ACPAgentSessionController(provider: peer.provider(providerID: .openCode), runRequest: request)

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)
        XCTAssertEqual(peer.loadedSessionIDs, ["persisted-session-id"])
    }

    func testGenericLoadFailureFallbackInvalidatesStaleResumeID() async throws {
        let workspace = try makeTemporaryDirectory()
        let peer = try StartupTestACPPeer(directory: makeTemporaryDirectory())
        let request = makeRunRequest(
            agentKind: .cursor,
            workspacePath: workspace.path,
            resumeSessionID: "stale-session-id"
        )
        let provider = peer.provider(failLoad: true, runtimeSessionID: "fresh-runtime-id")
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertTrue(bootstrap.didFallbackToNewSessionAfterLoadFailure)
        XCTAssertEqual(bootstrap.invalidatedResumeSessionID, "stale-session-id")
        XCTAssertEqual(bootstrap.sessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)
        XCTAssertEqual(peer.loadedSessionIDs, ["stale-session-id"])
    }

    /// A runtime that doesn't advertise `loadSession` opens a new conversation for a saved one
    /// instead of failing the run, without sending a `session/load` it can't answer.
    func testUnsupportedLoadFallsBackWithoutSendingSessionLoad() async throws {
        let workspace = try makeTemporaryDirectory()
        let peer = try StartupTestACPPeer(directory: makeTemporaryDirectory())
        let request = makeRunRequest(
            agentKind: .openCode,
            workspacePath: workspace.path,
            resumeSessionID: "saved-session-id"
        )
        let provider = peer.provider(providerID: .openCode, loadSession: false, runtimeSessionID: "fresh-runtime-id")
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertFalse(bootstrap.loadSessionSupported)
        XCTAssertTrue(bootstrap.didFallbackToNewSessionAfterLoadFailure)
        XCTAssertEqual(bootstrap.invalidatedResumeSessionID, "saved-session-id")
        XCTAssertEqual(bootstrap.sessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)
        // Shutdown's session/cancel may or may not reach the record before the agent exits.
        let methods = peer.requestMethods
        XCTAssertFalse(methods.contains("session/load"), "\(methods)")
        XCTAssertEqual(methods.count(where: { $0 == "session/new" }), 1, "\(methods)")
    }

    func testProviderSessionIdentityNormalizesEmptyIDs() {
        let identity = ACPProviderSessionIdentity(
            providerID: .cursor,
            runtimeSessionID: " cursor-runtime-id ",
            loadSessionID: "  ",
            loadSessionIDConfidence: .verified
        )

        XCTAssertEqual(identity.runtimeSessionID, "cursor-runtime-id")
        XCTAssertNil(identity.loadSessionID)
        XCTAssertEqual(identity.loadSessionIDConfidence, .unavailable)
    }

    private func makeRunRequest(
        agentKind: AgentProviderKind,
        workspacePath: String,
        resumeSessionID: String? = nil
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: agentKind,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "ACPProviderSessionIdentityTests")
    }

    private func firstMessageStop(in stream: AsyncStream<NormalizedAgentRuntimeEvent>) async -> AIStreamResult? {
        for await event in stream {
            switch event {
            case let .stream(result) where result.type == "message_stop":
                return result
            case .terminal:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
