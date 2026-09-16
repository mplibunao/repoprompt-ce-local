import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class MCPOracleCompletionPolicyTests: XCTestCase {
        func testOracleEndpointsSelectExplicitCompletionPolicies() async throws {
            let fixture = try await MCPOracleCompletionPolicyFixture.make(name: "endpoint-policy")
            addTeardownBlock { await fixture.cleanup() }

            var observedPolicies: [OracleResponseCompletionPolicy] = []
            fixture.window.mcpServer.setOracleChatSendOverrideForTesting { _, _, _, completionPolicy in
                observedPolicies.append(completionPolicy)
                return [
                    "chat_id": .string("policy-test"),
                    "response": .string("ok")
                ]
            }
            defer {
                fixture.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
            }

            try await ServerNetworkManager.$currentConnectionID.withValue(fixture.connectionID) {
                _ = try await fixture.window.mcpServer.executeOracleSendForTesting(args: [
                    "message": .string("strict"),
                    "mode": .string("chat"),
                    "new_chat": .bool(true)
                ])
                _ = try await fixture.window.mcpServer.executeAskOracleForTesting(args: [
                    "message": .string("interactive"),
                    "mode": .string("chat"),
                    "new_chat": .bool(true)
                ])
            }

            XCTAssertEqual(observedPolicies, [.contextBuilderStrict, .interactive])
        }

        func testOracleSendAdapterForwardsStrictPolicyWithoutInteractiveWatchdog() async throws {
            let fixture = try await MCPOracleCompletionPolicyFixture.make(name: "adapter-policy")
            addTeardownBlock { await fixture.cleanup() }
            let strictActivity = expectation(description: "strict content observed")

            let execution = Task { @MainActor in
                try await ServerNetworkManager.$currentConnectionID.withValue(fixture.connectionID) {
                    try await fixture.window.mcpServer.executeOracleSendForTesting(args: [
                        "message": .string("strict adapter"),
                        "mode": .string("chat"),
                        "new_chat": .bool(true)
                    ])
                }
            }

            await fixture.stream.waitUntilReady()
            let sessionID = try XCTUnwrap(fixture.window.oracleViewModel.currentSessionID)
            let queryID = try XCTUnwrap(fixture.window.oracleViewModel.activeQueryId(for: sessionID))
            let observerID = fixture.window.oracleViewModel.addMessageLifecycleActivityObserver(for: queryID) { event in
                if event.kind == .streamActivity {
                    strictActivity.fulfill()
                }
            }
            defer {
                fixture.window.oracleViewModel.removeMessageLifecycleActivityObserver(
                    for: queryID,
                    observerID: observerID
                )
            }

            await fixture.stream.yield(ChatStreamOutput(
                text: "adapter answer",
                reasoning: nil,
                tokens: ChatTokenInfo()
            ))
            await fulfillment(of: [strictActivity], timeout: 1)
            XCTAssertFalse(fixture.window.oracleViewModel.hasStreamInactivityWatchdogForTesting(for: queryID))

            await fixture.stream.yield(ChatStreamOutput(
                text: "",
                reasoning: nil,
                tokens: ChatTokenInfo(),
                terminalOutcome: .completed
            ))
            await fixture.stream.finish()
            let result = try await execution.value
            guard case let .object(reply) = result else {
                return XCTFail("Expected object reply")
            }
            XCTAssertEqual(reply["response"]?.stringValue, "adapter answer")

            let interactiveActivity = expectation(description: "interactive content observed")
            let startedInteractiveQueryID = await fixture.window.oracleViewModel.sendMessage(
                "interactive control",
                sessionID: sessionID,
                overrideModel: fixture.model,
                overrideMode: .chat,
                selectionOverride: StoredSelection(),
                overrideAIMessage: AIMessage(systemPrompt: "system", userMessage: "interactive control"),
                completionPolicy: .interactive
            )
            let interactiveQueryID = try XCTUnwrap(startedInteractiveQueryID)
            let interactiveObserverID = fixture.window.oracleViewModel.addMessageLifecycleActivityObserver(
                for: interactiveQueryID
            ) { event in
                if event.kind == .streamActivity {
                    interactiveActivity.fulfill()
                }
            }
            defer {
                fixture.window.oracleViewModel.removeMessageLifecycleActivityObserver(
                    for: interactiveQueryID,
                    observerID: interactiveObserverID
                )
            }
            await fixture.stream.waitUntilReady()
            await fixture.stream.yield(ChatStreamOutput(
                text: "interactive answer",
                reasoning: nil,
                tokens: ChatTokenInfo()
            ))
            await fulfillment(of: [interactiveActivity], timeout: 1)
            XCTAssertTrue(
                fixture.window.oracleViewModel.hasStreamInactivityWatchdogForTesting(for: interactiveQueryID),
                "The control proves the DEBUG observation detects the interactive watchdog"
            )
            await fixture.stream.yield(ChatStreamOutput(
                text: "",
                reasoning: nil,
                tokens: ChatTokenInfo(),
                terminalOutcome: .completed
            ))
            await fixture.stream.finish()
            let interactiveResponse = try await fixture.window.oracleViewModel
                .waitForContextBuilderCompletion(interactiveQueryID)
            XCTAssertEqual(interactiveResponse, "interactive answer")
        }

        func testPreRegistrationCancellationSettlesBeforeProviderCompletion() async throws {
            let fixture = try await MCPOracleCompletionPolicyFixture.make(name: "strict-cancellation-race")
            addTeardownBlock { await fixture.cleanup() }
            let startedQueryID = await fixture.window.oracleViewModel.sendMessage(
                "pending strict wait",
                sessionID: fixture.sessionID,
                overrideModel: fixture.model,
                overrideMode: .chat,
                selectionOverride: StoredSelection(),
                overrideAIMessage: AIMessage(systemPrompt: "system", userMessage: "pending strict wait"),
                completionPolicy: .contextBuilderStrict
            )
            let queryID = try XCTUnwrap(startedQueryID)
            await fixture.stream.waitUntilReady()
            XCTAssertEqual(fixture.window.oracleViewModel.activeQueryId(for: fixture.sessionID), queryID)

            let cancelled = expectation(description: "pre-registration strict waiter cancelled")
            let waiter = Task {
                do {
                    _ = try await fixture.window.oracleViewModel.waitForContextBuilderCompletion(queryID)
                    XCTFail("Expected cancellation")
                } catch is CancellationError {
                    cancelled.fulfill()
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
            waiter.cancel()
            await fulfillment(of: [cancelled], timeout: 1)
            XCTAssertEqual(fixture.window.oracleViewModel.activeQueryId(for: fixture.sessionID), queryID)

            await fixture.stream.finish()
            await fixture.window.oracleViewModel.cancelAIResponse(
                in: fixture.sessionID,
                skipPartialParseAndSave: true
            )
        }

        func testRegisteredStrictWaiterCancellationSettlesBeforeProviderCompletion() async throws {
            let fixture = try await MCPOracleCompletionPolicyFixture.make(name: "registered-strict-cancellation")
            addTeardownBlock { await fixture.cleanup() }
            let startedQueryID = await fixture.window.oracleViewModel.sendMessage(
                "registered strict wait",
                sessionID: fixture.sessionID,
                overrideModel: fixture.model,
                overrideMode: .chat,
                selectionOverride: StoredSelection(),
                overrideAIMessage: AIMessage(systemPrompt: "system", userMessage: "registered strict wait"),
                completionPolicy: .contextBuilderStrict
            )
            let queryID = try XCTUnwrap(startedQueryID)
            await fixture.stream.waitUntilReady()
            XCTAssertEqual(fixture.window.oracleViewModel.activeQueryId(for: fixture.sessionID), queryID)

            let cancelled = expectation(description: "registered strict waiter cancelled")
            let waiter = Task {
                do {
                    _ = try await fixture.window.oracleViewModel.waitForContextBuilderCompletion(queryID)
                    XCTFail("Expected cancellation")
                } catch is CancellationError {
                    cancelled.fulfill()
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
            let registrationObserved = expectation(description: "strict waiter registered in finalisation hub")
            let registrationProbe = Task {
                while !Task.isCancelled {
                    if await fixture.window.oracleViewModel.hasFinalisationWaiterForTesting(for: queryID) {
                        registrationObserved.fulfill()
                        return
                    }
                    await Task.yield()
                }
            }
            await fulfillment(of: [registrationObserved], timeout: 1)
            registrationProbe.cancel()
            let waiterWasRegistered = await fixture.window.oracleViewModel
                .hasFinalisationWaiterForTesting(for: queryID)
            XCTAssertTrue(
                waiterWasRegistered,
                "Cancellation must exercise a waiter already registered in the finalisation hub"
            )

            waiter.cancel()
            await fulfillment(of: [cancelled], timeout: 1)
            let waiterRemainsRegistered = await fixture.window.oracleViewModel
                .hasFinalisationWaiterForTesting(for: queryID)
            XCTAssertFalse(waiterRemainsRegistered)
            XCTAssertEqual(fixture.window.oracleViewModel.activeQueryId(for: fixture.sessionID), queryID)

            await fixture.stream.finish()
            await fixture.window.oracleViewModel.cancelAIResponse(
                in: fixture.sessionID,
                skipPartialParseAndSave: true
            )
        }
    }

    @MainActor
    private struct MCPOracleCompletionPolicyFixture {
        let window: WindowState
        let root: URL
        let storageRoot: URL
        let workspaceID: UUID
        let tabID: UUID
        let connectionID: UUID
        let sessionID: UUID
        let model: AIModel
        let stream: OracleControlledStream
        let previousShowModelPresets: Bool

        static func make(name: String) async throws -> Self {
            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPOracleCompletionPolicyTests-storage-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            await ChatDataService.test_setWorkspaceRootOverride(storageRoot)
            let previousShowModelPresets = GlobalSettingsStore.shared.mcpShowModelPresets()
            GlobalSettingsStore.shared.setMCPShowModelPresets(false, commit: false)
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            WindowStatesManager.shared.registerWindowState(window)
            await window.workspaceManager.awaitInitialized()

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPOracleCompletionPolicyTests-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let workspace = window.workspaceManager.createWorkspace(
                name: name,
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: name)
            let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
            let createdTab = await window.promptManager.createBackgroundComposeTab(
                strategy: .blank,
                name: "Oracle policy"
            )
            let tab = try XCTUnwrap(createdTab)
            await window.promptManager.switchComposeTab(tab.id)
            let model = AIModel.openaiCustom(name: "oracle-policy-test")
            window.apiSettingsViewModel.isOpenAIKeyValid = true
            window.promptManager.planningModelName = model.rawValue
            await window.oracleViewModel.startNewChatSession()
            let sessionID = try XCTUnwrap(window.oracleViewModel.currentSessionID)
            let stream = OracleControlledStream()
            window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, _ in
                await stream.makeStream()
            }
            let connectionID = UUID()
            let runID = UUID()
            let selection = StoredSelection()
            let snapshot = MCPServerViewModel.TabContextSnapshot(
                tabID: tab.id,
                windowID: window.windowID,
                workspaceID: workspaceID,
                promptText: tab.promptText,
                selection: selection,
                selectionRevision: window.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspaceID,
                    tabID: tab.id
                ),
                selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
                selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
                tabName: tab.name,
                runID: runID,
                explicitlyBound: false
            )
            window.mcpServer.tabContextByConnectionID[connectionID] = snapshot
            window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: connectionID,
                clientName: "oracle-policy-test",
                windowID: window.windowID,
                runPurpose: .unknown
            ))

            return Self(
                window: window,
                root: root,
                storageRoot: storageRoot,
                workspaceID: workspaceID,
                tabID: tab.id,
                connectionID: connectionID,
                sessionID: sessionID,
                model: model,
                stream: stream,
                previousShowModelPresets: previousShowModelPresets
            )
        }

        func cleanup() async {
            window.mcpServer.setRequestMetadataOverrideForTesting(nil)
            window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            window.beginClose()
            WindowStatesManager.shared.unregisterWindowState(window)
            GlobalSettingsStore.shared.setMCPShowModelPresets(previousShowModelPresets, commit: false)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }
#endif
