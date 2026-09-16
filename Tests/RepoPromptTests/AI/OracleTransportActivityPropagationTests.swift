import Foundation
@testable import RepoPromptApp
import SwiftOpenAI
import XCTest

@MainActor
final class OracleTransportActivityPropagationTests: XCTestCase {
    func testOpenAIDecodedChunkAdapterPreservesChoiceAndDeltaSemantics() throws {
        func chunk(_ object: [String: Any]) throws -> ChatCompletionChunkObject {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(ChatCompletionChunkObject.self, from: data)
        }

        let heartbeatChoice: [String: Any] = ["delta": [String: Any](), "index": 0]
        let semanticChoice: [String: Any] = ["delta": ["content": "content"], "index": 1]

        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": [heartbeatChoice]])))
        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice, semanticChoice]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": []])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["index": 0]]
        ])))

        let semanticDeltas: [[String: Any]] = [
            ["content": "content"],
            ["reasoning_content": "reasoning"],
            ["role": "assistant"],
            ["tool_calls": [[
                "index": 0,
                "id": "call-1",
                "type": "function",
                "function": ["arguments": "{}", "name": "tool"]
            ]]],
            ["function_call": ["arguments": "{}", "name": "tool"]],
            ["refusal": "refusal"]
        ]
        for delta in semanticDeltas {
            XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
                "choices": [["delta": delta, "index": 0]]
            ])))
        }

        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["delta": [String: Any](), "finish_reason": "stop", "index": 0]]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice],
            "usage": ["prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3]
        ])))
    }

    func testOpenAITransportPredicateRejectsEachSemanticFact() {
        func classifies(
            hasChoice: Bool = true,
            hasDelta: Bool = true,
            content: String? = nil,
            reasoning: String? = nil,
            role: String? = nil,
            hasToolCalls: Bool = false,
            hasFunctionCall: Bool = false,
            refusal: String? = nil,
            hasFinishReason: Bool = false,
            hasUsage: Bool = false
        ) -> Bool {
            OpenAIProvider.isTransportActivityChunk(
                hasChoice: hasChoice,
                hasDelta: hasDelta,
                content: content,
                reasoning: reasoning,
                role: role,
                hasToolCalls: hasToolCalls,
                hasFunctionCall: hasFunctionCall,
                refusal: refusal,
                hasFinishReason: hasFinishReason,
                hasUsage: hasUsage
            )
        }

        XCTAssertTrue(classifies())
        XCTAssertFalse(classifies(hasChoice: false))
        XCTAssertFalse(classifies(hasDelta: false))
        XCTAssertFalse(classifies(content: "content"))
        XCTAssertFalse(classifies(reasoning: "reasoning"))
        XCTAssertFalse(classifies(role: "assistant"))
        XCTAssertFalse(classifies(hasToolCalls: true))
        XCTAssertFalse(classifies(hasFunctionCall: true))
        XCTAssertFalse(classifies(refusal: "refusal"))
        XCTAssertFalse(classifies(hasFinishReason: true))
        XCTAssertFalse(classifies(hasUsage: true))
    }

    func testAIQueriesServiceSanitizesTransportAndStatusActivityOutput() throws {
        let activities = [
            (
                label: "canonical transport",
                result: AIStreamResult(
                    type: AIStreamResult.transportActivityType,
                    text: "ignored",
                    reasoning: "ignored",
                    promptTokens: 1,
                    completionTokens: 2,
                    cost: 3,
                    providerSessionID: "ignored",
                    cleanupHandle: ProviderConversationCleanupHandle(
                        provider: "ignored",
                        conversationID: "ignored"
                    )
                )
            ),
            (
                label: "Codex reconnect",
                result: AIStreamResult(
                    type: "status",
                    text: "Reconnecting... 2/5 <retry>",
                    reasoning: "must not leak",
                    promptTokens: 4,
                    completionTokens: 5,
                    cost: 6,
                    providerSessionID: "ignored",
                    cleanupHandle: ProviderConversationCleanupHandle(
                        provider: "ignored",
                        conversationID: "ignored"
                    )
                )
            ),
            (
                label: "ACP session title",
                result: AIStreamResult(type: "status", text: "Updated session title")
            ),
            (
                label: "Claude-compatible status",
                result: AIStreamResult(type: "status", text: "Retrying request")
            )
        ]

        for activity in activities {
            let output = try XCTUnwrap(
                AIQueriesService.transportActivityOutput(for: activity.result),
                activity.label
            )
            XCTAssertEqual(output.text, "", activity.label)
            XCTAssertNil(output.reasoning, activity.label)
            XCTAssertEqual(output.tokens, ChatTokenInfo(), activity.label)
            XCTAssertNil(output.terminalOutcome, activity.label)
            XCTAssertNil(output.cleanupHandle, activity.label)
            XCTAssertTrue(output.isTransportActivity, activity.label)
        }

        XCTAssertNil(
            AIQueriesService.transportActivityOutput(
                for: AIStreamResult(type: "content", text: "reconnecting is semantic here")
            )
        )
    }

    func testOracleStatusOnlyStreamRecordsActivityWithoutSemanticStateOrPersistence() async throws {
        let fixture = try await makeOracleStreamingFixture(name: "status-only")
        addTeardownBlock { await fixture.cleanup() }
        let activityObserved = expectation(description: "status activity observed")
        let progress = OracleProgressRecorder()

        let startedQueryID = await fixture.oracle.sendMessage(
            "prompt",
            sessionID: fixture.sessionID,
            overrideModel: fixture.model,
            overrideMode: .chat,
            selectionOverride: StoredSelection(),
            overrideAIMessage: AIMessage(systemPrompt: "system", userMessage: "prompt"),
            completionPolicy: .contextBuilderStrict,
            onProgress: { text, _ in progress.record(text) }
        )
        let queryID = try XCTUnwrap(startedQueryID)
        let observerID = fixture.oracle.addMessageLifecycleActivityObserver(for: queryID) { event in
            if event.kind == .streamActivity {
                activityObserved.fulfill()
            }
        }
        defer {
            fixture.oracle.removeMessageLifecycleActivityObserver(for: queryID, observerID: observerID)
        }

        await fixture.stream.waitUntilReady()
        try await fixture.stream.yield(XCTUnwrap(AIQueriesService.transportActivityOutput(
            for: AIStreamResult(type: "status", text: "Reconnecting... 1/5")
        )))
        await fulfillment(of: [activityObserved], timeout: 1)

        XCTAssertNotNil(fixture.oracle.lastObservedStreamActivityForTesting(for: queryID))
        XCTAssertFalse(fixture.oracle.hasSeenNonReasoningTextForTesting(for: queryID))
        XCTAssertFalse(fixture.oracle.hasStreamInactivityWatchdogForTesting(for: queryID))
        XCTAssertEqual(fixture.oracle.getChatMessage(withId: queryID)?.content, "")
        XCTAssertTrue(progress.values.isEmpty)

        await fixture.stream.yield(ChatStreamOutput(
            text: "",
            reasoning: nil,
            tokens: ChatTokenInfo(),
            terminalOutcome: .completed
        ))
        await fixture.stream.finish()

        do {
            _ = try await fixture.oracle.waitForContextBuilderCompletion(queryID)
            XCTFail("Expected transport-only completion to contain no answer")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, .emptyProcessedContent)
        }

        let reloaded = try await fixture.reloadPersistedSession()
        XCTAssertFalse(reloaded.messages.contains { !$0.isUser && $0.rawText.contains("Reconnecting") })
    }

    func testOracleStatusAroundContentPreservesExactSemanticAnswerAndPersistence() async throws {
        let fixture = try await makeOracleStreamingFixture(name: "status-content")
        addTeardownBlock { await fixture.cleanup() }
        let firstContentObserved = expectation(description: "first semantic content observed")
        let firstChunk = "Line one\n\n  Indented café 🧪\n"
        let secondChunk = "Line three reconnecting"
        let expected = firstChunk + secondChunk
        let progress = OracleProgressRecorder()

        let startedQueryID = await fixture.oracle.sendMessage(
            "prompt",
            sessionID: fixture.sessionID,
            overrideModel: fixture.model,
            overrideMode: .chat,
            selectionOverride: StoredSelection(),
            overrideAIMessage: AIMessage(systemPrompt: "system", userMessage: "prompt"),
            completionPolicy: .contextBuilderStrict,
            onProgress: { text, _ in
                progress.record(text)
                if text == firstChunk {
                    firstContentObserved.fulfill()
                }
            }
        )
        let queryID = try XCTUnwrap(startedQueryID)

        await fixture.stream.waitUntilReady()
        try await fixture.stream.yield(XCTUnwrap(AIQueriesService.transportActivityOutput(
            for: AIStreamResult(type: "status", text: "Reconnecting... 1/5")
        )))
        XCTAssertFalse(fixture.oracle.hasSeenNonReasoningTextForTesting(for: queryID))

        await fixture.stream.yield(ChatStreamOutput(
            text: firstChunk,
            reasoning: nil,
            tokens: ChatTokenInfo()
        ))
        await fulfillment(of: [firstContentObserved], timeout: 1)
        XCTAssertTrue(fixture.oracle.hasSeenNonReasoningTextForTesting(for: queryID))

        try await fixture.stream.yield(XCTUnwrap(AIQueriesService.transportActivityOutput(
            for: AIStreamResult(type: "status", text: "Retrying request")
        )))
        await fixture.stream.yield(ChatStreamOutput(
            text: secondChunk,
            reasoning: nil,
            tokens: ChatTokenInfo(),
            terminalOutcome: .completed
        ))
        await fixture.stream.finish()

        let response = try await fixture.oracle.waitForContextBuilderCompletion(queryID)
        XCTAssertEqual(response, expected)
        XCTAssertEqual(progress.values.last, expected)
        XCTAssertTrue(progress.values.allSatisfy { !$0.contains("Retrying request") })
        XCTAssertFalse(fixture.oracle.hasStreamInactivityWatchdogForTesting(for: queryID))

        let reloaded = try await fixture.reloadPersistedSession()
        XCTAssertEqual(reloaded.messages.first(where: { !$0.isUser })?.rawText, expected)
    }

    func testOraclePostContentWatchdogUsesStrictGraceBoundary() {
        let grace = OracleViewModel.postContentGrace
        let epsilon = 0.001
        let origin = Date(timeIntervalSinceReferenceDate: 0)

        for cycle in 1 ... 3 {
            let heartbeat = origin.addingTimeInterval(Double(cycle) * (grace - epsilon))
            let scheduledCheck = origin.addingTimeInterval(Double(cycle) * grace)
            XCTAssertFalse(
                OracleViewModel.shouldFireStreamInactivityWatchdog(
                    lastActivityAt: heartbeat,
                    now: scheduledCheck,
                    grace: grace
                )
            )
        }

        XCTAssertFalse(
            OracleViewModel.shouldFireStreamInactivityWatchdog(
                lastActivityAt: origin,
                now: origin.addingTimeInterval(grace),
                grace: grace
            )
        )
        XCTAssertTrue(
            OracleViewModel.shouldFireStreamInactivityWatchdog(
                lastActivityAt: origin,
                now: origin.addingTimeInterval(grace + epsilon),
                grace: grace
            )
        )
    }

    @MainActor
    func testOracleCoalescesTransportProgressWhileTrackingEveryHeartbeat() {
        let oracle = makeOracleViewModel()
        let recorder = OracleLifecycleActivityRecorder()
        let queryID = UUID()
        let observerID = oracle.addMessageLifecycleActivityObserver(for: queryID) {
            recorder.record($0)
        }
        defer {
            oracle.removeMessageLifecycleActivityObserver(
                for: queryID,
                observerID: observerID
            )
        }

        let origin = Date(timeIntervalSinceReferenceDate: 100)
        var latestActivity = origin
        for step in 0 ... 9 {
            latestActivity = origin.addingTimeInterval(Double(step) / 10.0)
            oracle.recordObservedStreamActivity(
                for: queryID,
                at: latestActivity
            )
        }

        XCTAssertEqual(recorder.kinds, [.streamActivity])
        XCTAssertEqual(
            oracle.lastObservedStreamActivityForTesting(for: queryID),
            latestActivity
        )

        oracle.recordObservedStreamActivity(
            for: queryID,
            at: origin.addingTimeInterval(1.0)
        )
        XCTAssertEqual(recorder.kinds, [.streamActivity, .streamActivity])
    }

    @MainActor
    func testOracleMapsTransportAndSemanticOutputsToExistingStreamActivity() {
        let transportOutput = ChatStreamOutput(
            text: "",
            reasoning: nil,
            tokens: ChatTokenInfo(),
            isTransportActivity: true
        )
        let emptyOutput = ChatStreamOutput(
            text: "",
            reasoning: nil,
            tokens: ChatTokenInfo()
        )
        let contentOutput = ChatStreamOutput(
            text: "hello",
            reasoning: nil,
            tokens: ChatTokenInfo()
        )
        let reasoningOutput = ChatStreamOutput(
            text: "",
            reasoning: "thinking",
            tokens: ChatTokenInfo()
        )

        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: transportOutput), .streamActivity)
        XCTAssertNil(OracleViewModel.lifecycleActivityKind(for: emptyOutput))
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: contentOutput), .streamActivity)
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: reasoningOutput), .streamActivity)
    }

    @MainActor
    private func makeOracleViewModel() -> OracleViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let fileManager = WorkspaceFilesViewModel()
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -696,
            settingsManager: WindowSettingsManager(windowID: -696)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        return OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
    }
}

@MainActor
private struct OracleStreamingFixture {
    let window: WindowState
    let storageRoot: URL
    let repositoryRoot: URL
    let workspaceID: UUID
    let sessionID: UUID
    let model: AIModel
    let stream: OracleControlledStream

    var oracle: OracleViewModel {
        window.oracleViewModel
    }

    func reloadPersistedSession() async throws -> ChatSession {
        oracle.autosaveChatHistory(for: sessionID, force: true)
        await oracle.drainTrackedAutosaves(for: workspaceID)
        let fileURL = try XCTUnwrap(oracle.sessions.first(where: { $0.id == sessionID })?.fileURL)
        return try await ChatDataService().loadChatSession(from: fileURL)
    }

    func cleanup() async {
        oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
        window.beginClose()
        WindowStatesManager.shared.unregisterWindowState(window)
        await ChatDataService.test_setWorkspaceRootOverride(nil)
        try? FileManager.default.removeItem(at: repositoryRoot)
        try? FileManager.default.removeItem(at: storageRoot)
    }
}

@MainActor
private func makeOracleStreamingFixture(name: String) async throws -> OracleStreamingFixture {
    let storageRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("OracleTransportActivityPropagationTests-storage-\(name)-\(UUID().uuidString)")
    let repositoryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("OracleTransportActivityPropagationTests-repo-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
    await ChatDataService.test_setWorkspaceRootOverride(storageRoot)

    let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
    GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
    let window = WindowState()
    GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
    WindowStatesManager.shared.registerWindowState(window)
    await window.workspaceManager.awaitInitialized()

    let workspace = window.workspaceManager.createWorkspace(
        name: name,
        repoPaths: [repositoryRoot.path],
        ephemeral: true
    )
    await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: name)
    let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
    let createdTab = await window.promptManager.createBackgroundComposeTab(
        strategy: .blank,
        name: "Oracle transport"
    )
    let tab = try XCTUnwrap(createdTab)
    await window.promptManager.switchComposeTab(tab.id)

    let model = AIModel.openaiCustom(name: "oracle-transport-test")
    window.apiSettingsViewModel.isOpenAIKeyValid = true
    window.promptManager.planningModelName = model.rawValue
    await window.oracleViewModel.startNewChatSession()
    let sessionID = try XCTUnwrap(window.oracleViewModel.currentSessionID)
    let stream = OracleControlledStream()
    window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, _ in
        await stream.makeStream()
    }

    return OracleStreamingFixture(
        window: window,
        storageRoot: storageRoot,
        repositoryRoot: repositoryRoot,
        workspaceID: workspaceID,
        sessionID: sessionID,
        model: model,
        stream: stream
    )
}

@MainActor
private final class OracleProgressRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class OracleLifecycleActivityRecorder {
    private(set) var kinds: [OracleMessageLifecycleActivityEvent.Kind] = []

    func record(_ event: OracleMessageLifecycleActivityEvent) {
        kinds.append(event.kind)
    }
}
