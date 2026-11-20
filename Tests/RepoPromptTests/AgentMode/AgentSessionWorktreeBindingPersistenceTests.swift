@testable import RepoPromptApp
import XCTest

final class AgentSessionWorktreeBindingPersistenceTests: XCTestCase {
    func testOldAgentSessionJSONDecodesWithEmptyWorktreeBindings() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000101",
          "serializationVersion": 4,
          "name": "Legacy Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.serializationVersion, 4)
        XCTAssertTrue(decoded.worktreeBindings.isEmpty)
        XCTAssertTrue(decoded.worktreeMergeOperations.isEmpty)
    }

    func testAgentSessionRoundTripsWorktreeBindingsAsCurrentVersion() throws {
        let binding = makeBinding()
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000102")),
            name: "Bound Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            autoEditEnabled: false,
            worktreeBindings: [binding]
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(encodedString.contains("worktreeBindings"), encodedString)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 8)
        XCTAssertEqual(decoded.worktreeBindings, [binding])
    }

    func testDataServiceStubAndMetadataExposeWorktreeBindingSummaries() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let binding = makeBinding()
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000103"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000104"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 20),
            itemCount: 3,
            autoEditEnabled: true,
            worktreeBindings: [binding]
        )

        let fileURL = try await service.saveAgentSession(session, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: 3)
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let metadata = try await service.listAgentSessionsMeta(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Metadata Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        XCTAssertNil(stub.transcript)
        XCTAssertTrue(stub.items.isEmpty)
        XCTAssertEqual(stub.worktreeBindings, [binding])

        let summary = binding.summary
        XCTAssertEqual(metadata.first?.worktreeBindingSummaries, [summary])
        XCTAssertEqual(sidebar.entriesBySessionID[sessionID]?.worktreeBindingSummaries, [summary])
        XCTAssertEqual(sidebar.preferredSessionIDByTabID[tabID], sessionID)
    }

    func testDataServiceStubAndFullRestorePreserveCodexResumeReference() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000106"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000107"))
        let conversationID = "019f775c-4070-7200-b41c-933196989588"
        let rolloutPath = "/Users/example/.codex/sessions/legacy-rollout.jsonl"
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Legacy Codex Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 30),
            itemCount: 2,
            agentKind: AgentProviderKind.codexExec.rawValue,
            codexConversationID: conversationID,
            codexRolloutPath: rolloutPath
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 2
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let restored = try await service.loadAgentSession(from: fileURL)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Legacy Codex Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        XCTAssertNil(stub.transcript)
        XCTAssertTrue(stub.items.isEmpty)
        XCTAssertEqual(stub.codexConversationID, conversationID)
        XCTAssertEqual(stub.codexRolloutPath, rolloutPath)
        XCTAssertEqual(restored.codexConversationID, conversationID)
        XCTAssertEqual(restored.codexRolloutPath, rolloutPath)
        XCTAssertEqual(sidebar.preferredSessionIDByTabID[tabID], sessionID)
    }

    /// The model's capacity is persisted beside, not instead of, the effective window, and one
    /// unreadable capacity must not fail a session file on either load path.
    func testContextCapacitySurvivesFullAndHeaderLoads() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000108"))
        let capacity = AgentContextWindowCapacity(tokens: 1_000_000, agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "claude-fable-5")
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Capacity Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 40),
            agentKind: AgentProviderKind.claudeCode.rawValue,
            agentModel: "claude-fable-5",
            codexContextWindow: 400_000,
            contextWindowCapacity: capacity
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])

        let records: [(label: String, record: Any?, expected: AgentContextWindowCapacity?)] = [
            ("valid", payload["contextWindowCapacity"], capacity),
            ("missing", nil, nil),
            ("null", NSNull(), nil),
            ("malformed value", "bogus", nil),
            ("malformed fields", ["tokens": "many"], nil)
        ]
        for record in records {
            payload["contextWindowCapacity"] = record.record
            try JSONSerialization.data(withJSONObject: payload).write(to: fileURL)
            let loads = try await [
                ("header", service.loadAgentSessionStub(from: fileURL)),
                ("full", service.loadAgentSession(from: fileURL))
            ]
            for (route, loaded) in loads {
                let label = "\(record.label), \(route) load"
                XCTAssertEqual(loaded.id, sessionID, label)
                XCTAssertEqual(loaded.codexContextWindow, 400_000, label)
                XCTAssertEqual(loaded.contextWindowCapacity, record.expected, label)
            }
        }
    }

    func testLegacyMetadataIndexRecordsDecodeWithEmptyWorktreeBindingSummaries() throws {
        let payload = """
        {
          "schemaVersion": 1,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000105",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000105.json",
              "name": "Indexed Legacy Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """

        let decoded = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries.first?.worktreeBindingSummaries, [])
        XCTAssertEqual(decoded.entries.first?.activeWorktreeMergeSummaries, [])
        XCTAssertEqual(decoded.entries.first?.agentSessionMeta().worktreeBindingSummaries, [])
        XCTAssertEqual(decoded.entries.first?.agentSessionMeta().activeWorktreeMergeSummaries, [])
    }

    private func makeBinding() -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_repo-main_wt-feature",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            logicalRootPath: "/Users/example/dev/repo",
            logicalRootName: "repo",
            worktreeID: "wt_feature123",
            worktreeRootPath: "/Users/example/dev/.repoprompt-worktrees/repo/rp-agent-feature",
            worktreeName: "rp-agent-feature",
            branch: "feature/worktree-bindings",
            head: "abcdef1234567890",
            visualLabel: "feature",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionWorktreeBindingPersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Worktree Binding Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
