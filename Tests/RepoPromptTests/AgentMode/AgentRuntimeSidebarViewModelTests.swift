import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRuntimeSidebarViewModelTests: XCTestCase {
    func testStaleLiveZeroDoesNotMaskNewerManageSelectionCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: 0,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 0)

        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)
    }

    func testUnavailableSelectionCountDoesNotReusePreviousContextCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertNil(store.runtimeVM.snapshot.selectionFileCount)
    }

    func testNewerManageSelectionWinsOverOlderWorkspaceContextSelectionCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let olderWorkspaceContext = try makeWorkspaceContextItem(
            fileCount: 0,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let newerManageSelection = try makeManageSelectionItem(
            fileCount: 8,
            timestamp: Date(timeIntervalSince1970: 200)
        )

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(
                latestWorkspaceContextItem: olderWorkspaceContext,
                latestManageSelectionItem: newerManageSelection
            ),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 8)
        XCTAssertEqual(store.runtimeVM.snapshot.selectionTokens, 80)
    }

    func testFreshLiveZeroRemainsAuthoritativeAfterToolDerivedCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        let snapshot = AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem)
        store.update(
            transcriptSnapshot: snapshot,
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)

        store.update(
            transcriptSnapshot: snapshot,
            codexUsage: nil,
            liveSelectedFileCount: 0,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 0)
        XCTAssertNil(store.runtimeVM.snapshot.selectionTokens)
    }

    func testLiveSelectionCountMismatchSuppressesStaleToolSelectionTokens() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: 2,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 2)
        XCTAssertNil(store.runtimeVM.snapshot.selectionTokens)
    }

    func testLiveSlicedSelectionSuppressesSameCountToolSelectionTokens() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 1)
        let liveSummary = AgentContextExportResolver.selectionSummary(
            for: StoredSelection(
                selectedPaths: ["Sources/File0.swift"],
                slices: ["Sources/File0.swift": [LineRange(start: 4, end: 8)]],
                codemapAutoEnabled: false
            )
        )
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            liveSelectionSummary: liveSummary,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 1)
        XCTAssertEqual(store.runtimeVM.snapshot.selectionSummary, liveSummary)
        XCTAssertNil(store.runtimeVM.snapshot.selectionTokens)
    }

    func testClaudeFableSelectionFallsBackToOneMillionTokenContextWindow() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )

        XCTAssertNil(store.runtimeVM.snapshot.contextWindowTokens)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)
    }

    func testClaudeOpus48BaseAndEncodedSelectionsFallBackToOneMillionTokenContextWindow() {
        let store = AgentRuntimeMetricsUIStore()

        for selectedModelRaw in ["claude-opus-4-8", "claude-opus-4-8:xhigh"] {
            store.update(
                transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
                codexUsage: nil,
                liveSelectedFileCount: nil,
                selectedAgent: .claudeCode,
                selectedModelRaw: selectedModelRaw
            )

            XCTAssertNil(store.runtimeVM.snapshot.contextWindowTokens)
            XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000, selectedModelRaw)
        }
    }

    func testEncodedClaudeEffortSelectionResolvesContextWindowFallback() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "opus[1m]:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5:max"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "sonnet:high"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testGLMSlotSelectionsUseBackendContextWindowFallback() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "sonnet"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "sonnet:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "opus:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "haiku"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testCustomSlotMappingUsesBackendContextWindowFallback() {
        let restore = installTemporaryCustomSlotMapping()
        defer { restore() }

        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .customClaudeCompatible,
            selectedModelRaw: "sonnet:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .customClaudeCompatible,
            selectedModelRaw: "haiku"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .kimiCode,
            selectedModelRaw: "kimi-code:xhigh"
        )
        XCTAssertNil(store.runtimeVM.snapshot.effectiveContextWindowTokens, "An unknown backend window stays unknown")
    }

    func testProviderReportedContextWindowWinsOverModelFallback() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: 250_000,
                lastTotalTokens: 1000,
                totalTotalTokens: nil
            ),
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.contextWindowTokens, 250_000)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 250_000)
    }

    func testItemsUpdateWithoutSelectedAgentResolvesExactRawsOnly() {
        let viewModel = AgentRuntimeSidebarViewModel()

        // Without an agent, an exact model raw still resolves its context window.
        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-fable-5")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-sonnet-5")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        // Encoded selections need the agent to disambiguate the specifier
        // grammar; without one the window stays unknown rather than guessed.
        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-fable-5:xhigh")
        XCTAssertNil(viewModel.snapshot.effectiveContextWindowTokens)

        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-sonnet-5:xhigh")
        XCTAssertNil(viewModel.snapshot.effectiveContextWindowTokens)

        // Supplying the agent unlocks encoded-raw resolution on the items path.
        viewModel.update(
            items: [],
            codexUsage: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5:xhigh"
        )
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        viewModel.update(
            items: [],
            codexUsage: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5:xhigh"
        )
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)
    }

    private func installTemporaryCustomSlotMapping() -> () -> Void {
        let defaults = UserDefaults.standard
        let store = ClaudeCodeCompatibleBackendStore.shared
        let configsKey = ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        let configuredKey = store.configuredDefaultsKey(for: .custom)
        let previousConfigs = defaults.data(forKey: configsKey)
        let previousConfigured = defaults.object(forKey: configuredKey)

        store.saveConfig(ClaudeCodeCompatibleBackendConfig(
            id: .custom,
            isEnabled: true,
            displayName: "CC Custom GLM",
            baseURL: "https://example.test/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "custom-fast",
                sonnet: "glm-5.2[1m]",
                opus: "glm-5.2"
            ))
        ))
        _ = store.setConfigured(true, for: .custom)

        return {
            if let previousConfigs {
                defaults.set(previousConfigs, forKey: configsKey)
            } else {
                defaults.removeObject(forKey: configsKey)
            }
            if let previousConfigured {
                defaults.set(previousConfigured, forKey: configuredKey)
            } else {
                defaults.removeObject(forKey: configuredKey)
            }
        }
    }

    private func makeManageSelectionItem(fileCount: Int, timestamp: Date = Date()) throws -> AgentChatItem {
        let files = makeSelectedFiles(fileCount: fileCount)
        let reply = ToolResultDTOs.SelectionReply(
            files: files,
            totalTokens: fileCount * 10,
            status: "Selection • add • \(fileCount) files"
        )
        let data = try JSONEncoder().encode(reply)
        let json = String(decoding: data, as: UTF8.self)
        return AgentChatItem(
            timestamp: timestamp,
            kind: .toolResult,
            text: json,
            toolName: "manage_selection",
            toolResultJSON: json
        )
    }

    private func makeWorkspaceContextItem(fileCount: Int, timestamp: Date = Date()) throws -> AgentChatItem {
        let files = makeSelectedFiles(fileCount: fileCount)
        let selection = ToolResultDTOs.SelectedFilesReply(
            files: files,
            totalTokens: fileCount * 10,
            fileSlices: nil,
            summary: nil
        )
        let reply = ToolResultDTOs.PromptContextDTO(
            prompt: "",
            selection: selection,
            fileBlocks: nil,
            codeStructure: nil,
            fileTree: nil,
            tokenStats: nil,
            userTokenStats: nil,
            tokenStatsNote: nil,
            copyPreset: nil,
            copyPresets: nil
        )
        let data = try JSONEncoder().encode(reply)
        let json = String(decoding: data, as: UTF8.self)
        return AgentChatItem(
            timestamp: timestamp,
            kind: .toolResult,
            text: json,
            toolName: "workspace_context",
            toolResultJSON: json
        )
    }

    private func makeSelectedFiles(fileCount: Int) -> [ToolResultDTOs.SelectedFileInfo] {
        (0 ..< fileCount).map { index in
            ToolResultDTOs.SelectedFileInfo(
                path: "Sources/File\(index).swift",
                tokens: 10,
                renderMode: "full",
                ranges: nil,
                isAuto: false,
                codemapOrigin: nil,
                copyPreset: nil
            )
        }
    }
}

/// An unknown Claude window must not act as a 200K ceiling. A launch-time
/// `CLAUDE_CODE_AUTO_COMPACT_WINDOW` cap sizes the displayed window only and never rejects a reading.
/// The model's own capacity is kept per provider and base model, bounds every reading, and the
/// window is recomputed from it whenever the cap or the identity changes.
@MainActor
final class ClaudeContextWindowResolutionTests: XCTestCase {
    private func makeEstimator() -> ClaudeContextUsageEstimator {
        ClaudeContextUsageEstimator(tokenEstimator: { _ in 0 }, contextUsageBuilder: { usage, window in
            AgentModeViewModel.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: window)
        })
    }

    private func makeSession(
        agent: AgentProviderKind = .claudeCode,
        model: String = "claude-fable-5",
        autoCompactWindow: Int? = nil
    ) -> AgentTabSession {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = agent
        session.selectedModelRaw = model
        session.claudeAutoCompactWindowTokens = autoCompactWindow
        return session
    }

    func testUsageValidationUsesOnlyKnownCapacity() {
        let estimator = makeEstimator()

        // An unknown window imposes no ceiling on live or finalized readings.
        let unknown = makeSession(model: "claude-unlisted-model")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, modelContextWindow: nil, session: unknown)
        XCTAssertNil(unknown.codexContextUsage?.modelContextWindow)
        XCTAssertEqual(unknown.codexContextUsage?.lastTotalTokens, 250_000)
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: nil, completionTokens: nil, contextUsedTokens: 260_000, session: unknown))
        XCTAssertEqual(unknown.providerTokenUsageByTurn.last?.contextUsedTokens, 260_000)
        XCTAssertEqual(unknown.codexContextUsage?.lastTotalTokens, 260_000)

        // A window the provider reported earlier still rejects an impossible reading.
        let reported = makeSession(model: "claude-unlisted-model")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 150_000, modelContextWindow: 200_000, session: reported)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, modelContextWindow: nil, session: reported)
        XCTAssertEqual(reported.codexContextUsage?.lastTotalTokens, 150_000)

        // A compatible backend's catalog window is known before the provider reports one.
        let compatible = makeSession(agent: .claudeCodeGLM, model: "sonnet")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: compatible)
        XCTAssertEqual(compatible.codexContextUsage?.modelContextWindow, 1_000_000)
        XCTAssertNil(compatible.codexContextUsage?.lastTotalTokens)
    }

    func testRebuildUsesOnlyKnownCapacity() {
        let rows = [AgentTokenUsagePersist(promptTokens: 0, completionTokens: 0, contextUsedTokens: 350_000)]
        let restored = AgentModeViewModel.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: nil)
        XCTAssertEqual(restored?.lastTotalTokens, 350_000)
        XCTAssertNil(restored?.modelContextWindow)
        XCTAssertEqual(
            AgentModeViewModel.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: 0)?.lastTotalTokens,
            350_000,
            "A non-positive window is unknown, as in live validation"
        )

        XCTAssertNil(
            AgentModeViewModel.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: 200_000)?.lastTotalTokens,
            "A known window still bounds restored rows"
        )
    }

    func testAutoCompactWindowControlsDenominatorNotOccupancy() {
        let estimator = makeEstimator()

        // Runtime init recomputes the window before any usage report.
        let runtimeInitCases: [(
            label: String,
            model: String,
            autoCompactWindow: Int,
            restored: AgentContextUsage?,
            expectedWindow: Int,
            expectedTokens: Int?
        )] = [
            ("cap below the model window", "claude-fable-5", 400_000, nil, 400_000, nil),
            ("cap above the model window uses the model window", "sonnet", 1_000_000, nil, 200_000, nil),
            ("unknown model window leaves the cap", "claude-unlisted-model", 400_000, nil, 400_000, nil),
            (
                "restored uncapped window is capped on the next init",
                "claude-fable-5",
                400_000,
                AgentContextUsage(modelContextWindow: 1_000_000, lastTotalTokens: 90000, totalTotalTokens: 90000),
                400_000,
                90000
            )
        ]
        for testCase in runtimeInitCases {
            let session = makeSession(model: testCase.model, autoCompactWindow: testCase.autoCompactWindow)
            session.codexContextUsage = testCase.restored
            ClaudeContextUsageEstimator.reconcileContextWindow(session: session, createsUsage: true)
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, testCase.expectedWindow, testCase.label)
            XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, testCase.expectedTokens, testCase.label)
        }

        // After the first response Claude reports the model's full window; the cap stays the
        // denominator, and occupancy above the cap is a valid reading, not an impossible one.
        let session = makeSession(autoCompactWindow: 400_000)
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: 120_000, modelContextWindow: 1_000_000, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 120_000)

        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 450_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 450_000)
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: nil, completionTokens: nil, contextUsedTokens: 460_000, session: session))
        XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 460_000)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 460_000)

        // The cap describes a Claude-native process, so only those providers apply it. A provider
        // switch clears it, so each provider gets the cap its own runtime init would report.
        for (agent, applies) in [(AgentProviderKind.claudeCodeGLM, true), (.openCode, false), (.codexExec, false)] {
            session.selectedAgent = agent
            session.claudeAutoCompactWindowTokens = 400_000
            XCTAssertEqual(session.activeClaudeAutoCompactWindowTokens, applies ? 400_000 : nil, agent.rawValue)
        }
    }

    func testDrawerTokenPillShowsCountWithoutAGuessedDenominator() {
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.tokenSummaryText(usedTokens: 12300, contextWindowTokens: nil), "12.3K tokens")
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.tokenSummaryText(usedTokens: 12300, contextWindowTokens: 400_000), "12.3K / 400.0K")
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.budgetText(usedPercent: nil), "Context window unknown")
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.budgetText(usedPercent: 3.1), "3% of budget")
    }

    /// One completed turn: Claude reports the model's full 1M window only in the turn's result.
    private func completeTurn(_ estimator: ClaudeContextUsageEstimator, _ session: AgentTabSession, used: Int) {
        _ = estimator.ingestUsageSignal(promptTokens: used, completionTokens: 10, contextUsedTokens: used, modelContextWindow: nil, session: session)
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: nil, modelContextWindow: 1_000_000, session: session)
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: used, completionTokens: 10, contextUsedTokens: nil, session: session))
    }

    private func sidebarWindow(_ session: AgentTabSession) -> Int? {
        AgentRuntimeSidebarViewModel.ContextSnapshot(
            contextWindowTokens: session.codexContextUsage?.modelContextWindow,
            selectedAgent: session.selectedAgent,
            selectedModelRaw: session.selectedModelRaw
        ).effectiveContextWindowTokens
    }

    func testCapChangesRecomputeFromStoredCapacity() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-unlisted-model", autoCompactWindow: 400_000)
        completeTurn(estimator, session, used: 120_000)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.contextWindowCapacity?.tokens, 1_000_000, "The model's window is stored, not the cap")

        let capChanges: [(label: String, cap: Int?, window: Int)] = [
            ("raising the cap", 600_000, 600_000),
            ("removing the cap", nil, 1_000_000)
        ]
        for change in capChanges {
            session.claudeAutoCompactWindowTokens = change.cap
            XCTAssertTrue(ClaudeContextUsageEstimator.reconcileContextWindow(session: session, createsUsage: true), change.label)
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, change.window, change.label)
            XCTAssertEqual(session.contextUsageSnapshot?.window, change.window, change.label)
            XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 120_000, "\(change.label) keeps occupancy")
        }
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 500_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 500_000, "A valid reading above the former cap is kept")
    }

    func testCapacityBoundsReportsWithoutPromptBackfill() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-unlisted-model", autoCompactWindow: 400_000)
        completeTurn(estimator, session, used: 120_000)

        // Applied in order to one session with a 1M capacity and a 400K cap.
        let reports: [(label: String, prompt: Int?, used: Int?, expected: Int)] = [
            ("occupancy above the cap is valid", nil, 450_000, 450_000),
            ("occupancy above the capacity is rejected", nil, 1_200_000, 450_000),
            ("rejected occupancy is not backfilled by a smaller prompt count", 2000, 1_200_000, 450_000),
            ("a prompt-only count above the capacity is rejected", 1_250_000, nil, 450_000),
            ("a plausible prompt-only count still counts", 300_000, nil, 300_000)
        ]
        for report in reports {
            _ = estimator.ingestUsageSignal(
                promptTokens: report.prompt,
                completionTokens: 10,
                contextUsedTokens: report.used,
                modelContextWindow: nil,
                session: session
            )
            XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, report.expected, report.label)
        }
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: 300_000, completionTokens: 10, contextUsedTokens: 1_300_000, session: session))
        XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 450_000, "The impossible result reading is not persisted")
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
    }

    func testFinalizationRejectsOccupancyAboveNewCapacity() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-unlisted-model")
        // The turn streams 1.2M while the capacity is still unknown.
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 1_200_000, "Precondition: an unknown capacity bounds nothing")
        // Its result then establishes a 1M capacity without its own occupancy.
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: nil, modelContextWindow: 1_000_000, session: session)
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens, "The carried reading exceeds the new capacity")

        XCTAssertFalse(
            estimator.finalizeTurn(promptTokens: nil, completionTokens: nil, contextUsedTokens: nil, session: session),
            "An impossible reading alone is not usage"
        )
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: 1000, completionTokens: 10, contextUsedTokens: nil, session: session))
        XCTAssertNil(session.providerTokenUsageByTurn.last?.contextUsedTokens, "The streamed reading is not persisted")
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens)
        XCTAssertNil(session.codexContextUsage?.totalTotalTokens)
    }

    func testCapacitySurvivesCompactionAndRebuild() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-unlisted-model", autoCompactWindow: 400_000)
        completeTurn(estimator, session, used: 390_000)

        estimator.ingestSystemSignal("Context compacted", session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)

        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_100_000, modelContextWindow: nil, session: session)
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens, "The capacity still bounds readings while pending")
        XCTAssertEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 60000, modelContextWindow: nil, session: session)
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: 60000, completionTokens: 10, contextUsedTokens: nil, session: session))
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 60000)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000, "The rebuild keeps the capped window")
        XCTAssertEqual(ClaudeContextUsageEstimator.verifiedCapacity(reported: nil, session: session), 1_000_000)
    }

    func testCapacityAndCapFollowProviderAndBaseModel() {
        let estimator = makeEstimator()
        // A 1M model capped at 400K.
        let session = makeSession(model: "claude-fable-5:high", autoCompactWindow: 400_000)
        completeTurn(estimator, session, used: 150_000)
        XCTAssertEqual(
            session.contextWindowCapacity,
            AgentContextWindowCapacity(tokens: 1_000_000, agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "claude-fable-5")
        )
        XCTAssertEqual(sidebarWindow(session), 400_000)

        session.selectedModelRaw = "claude-fable-5:xhigh"
        XCTAssertEqual(session.identityValidContextWindowCapacity, 1_000_000, "Effort does not change capacity")

        // A 200K model is sized at once, before any usage event: 150K is 75% of it, not 38% of 400K.
        session.selectedModelRaw = "sonnet"
        XCTAssertNil(session.identityValidContextWindowCapacity, "Another model's capacity is not this model's")
        XCTAssertEqual(sidebarWindow(session), 200_000)
        XCTAssertEqual(session.contextUsageSnapshot?.window, 200_000)
        XCTAssertEqual(session.claudeAutoCompactWindowTokens, 400_000, "A model switch keeps the process's cap")

        session.selectedModelRaw = "claude-fable-5"
        XCTAssertEqual(sidebarWindow(session), 400_000, "The remembered model's capacity applies again")

        // Claude's figures neither size nor bound another provider's usage.
        session.selectedAgent = .kimiCode
        XCTAssertNil(session.claudeAutoCompactWindowTokens, "The cap described the previous provider's process")
        XCTAssertNil(session.identityValidContextWindowCapacity, "Another provider's capacity is not this provider's")
        XCTAssertNil(session.codexContextUsage?.modelContextWindow, "Kimi has no known window for this model")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 1_200_000, "Claude's capacity does not bound Kimi's reading")

        session.selectedAgent = .claudeCode
        session.contextWindowCapacity = AgentContextWindowCapacity(
            tokens: 0,
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: AgentContextWindowCapacity.modelKey(forRaw: session.selectedModelRaw)
        )
        XCTAssertNil(session.identityValidContextWindowCapacity, "A stored non-positive capacity is not a capacity")
    }

    #if DEBUG
        func testRuntimeInitReappliesCapAndKeepsProvenance() throws {
            let viewModel = AgentModeViewModel(
                testWindowID: -973,
                testWorkspacePath: FileManager.default.currentDirectoryPath,
                codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Context-window tests must not start a Codex session") },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }
            )
            let session = viewModel.session(for: UUID())
            defer { session.saveDebounceTask?.cancel() }
            session.selectedAgent = .claudeCode
            session.selectedModelRaw = "claude-unlisted-model"
            let estimator = viewModel.claudeContextUsageEstimator
            func runtimeInit(cap: Int?) -> Bool {
                viewModel.claudeCoordinator.observeRuntimeInit(
                    .init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: cap),
                    session: session
                )
            }
            _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: 90000, modelContextWindow: 1_000_000, session: session)
            estimator.ingestSystemSignal("Context compacted", session: session)
            let beforeInit = try XCTUnwrap(session.contextUsageSnapshot)
            XCTAssertEqual(beforeInit.source, .compactionSignal)

            XCTAssertTrue(runtimeInit(cap: 400_000))
            XCTAssertFalse(runtimeInit(cap: 400_000), "A repeated cap changes nothing")
            var expectedSnapshot = beforeInit
            expectedSnapshot.window = 400_000
            XCTAssertEqual(session.contextUsageSnapshot, expectedSnapshot, "Only the window changes; provenance and compaction time stay")
            XCTAssertEqual(
                session.codexContextUsage,
                AgentContextUsage(modelContextWindow: 400_000, lastTotalTokens: nil, totalTotalTokens: nil, awaitingPostCompactionUsage: true)
            )

            viewModel.clearChat(tabID: session.tabID)
            XCTAssertNil(session.claudeAutoCompactWindowTokens, "Clear Chat tears down the process the cap described")
            XCTAssertNil(session.codexContextUsage)
            XCTAssertEqual(session.contextWindowCapacity?.tokens, 1_000_000, "Clearing content does not change the model")
            XCTAssertTrue(runtimeInit(cap: 400_000), "The next process repeats the cap, and it must still apply")
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        }
    #endif
}
