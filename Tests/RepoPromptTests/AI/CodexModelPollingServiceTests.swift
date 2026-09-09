import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexModelPollingServiceTests: XCTestCase {
    private let storageKey = "CodexDynamicModelRecords"
    private var priorLiveModels: [CodexAppServerClient.RemoteModel] = []
    private var priorStoredData: Data?

    override func setUp() {
        super.setUp()
        priorLiveModels = AgentCodexModelRegistry.shared.currentLiveModels()
        priorStoredData = UserDefaults.standard.data(forKey: storageKey)
    }

    override func tearDown() {
        _ = AgentCodexModelRegistry.shared.updateLiveModels(priorLiveModels)
        if let priorStoredData {
            UserDefaults.standard.set(priorStoredData, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        _ = CodexDynamicModelStore.load()
        super.tearDown()
    }

    func testConcurrentRefreshCallersJoinOnePhysicalListing() async {
        let client = BlockingCodexModelClient()
        let service = CodexModelPollingService(client: client)
        let first = Task { await service.refreshNow() }
        let firstListingStarted = await client.reachesCallCount(1, within: .seconds(2))
        XCTAssertTrue(firstListingStarted)

        let secondStarted = expectation(description: "second refresh caller started")
        let second = Task {
            secondStarted.fulfill()
            await service.refreshNow()
        }
        await fulfillment(of: [secondStarted], timeout: 2)

        let duplicateListingStarted = await client.reachesCallCount(2, within: .seconds(1))
        XCTAssertFalse(duplicateListingStarted, "Concurrent refresh callers must join the existing listing")

        await client.succeed(with: [remoteModel("gpt-6-astra", effort: "ultra")])
        let callersCompleted = await completes([first, second], within: .seconds(2))
        XCTAssertTrue(callersCompleted, "Joined refresh callers did not complete after the listing resolved")

        if !callersCompleted {
            first.cancel()
            second.cancel()
            await client.failOutstanding()
            await first.value
            await second.value
        }

        let finalCallCount = await client.callCount()
        let pendingListingCount = await client.pendingListingCount()
        let snapshot = await service.latestSnapshot()
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(pendingListingCount, 0)
        XCTAssertEqual(snapshot?.models.map(\.id), ["gpt-6-astra"])
    }

    func testFailurePreservesLastValidSnapshotAndRepeatedRefreshIsIdempotent() async {
        let model = remoteModel("gpt-6-astra", effort: "ultra")
        let client = ScriptedCodexModelClient(steps: [
            .success([model]),
            .success([model]),
            .failure(.listingFailed)
        ])
        let service = CodexModelPollingService(client: client)

        await service.refreshNow()
        let first = await service.latestSnapshot()
        await service.refreshNow()
        let repeated = await service.latestSnapshot()
        await service.refreshNow()
        let failed = await service.latestSnapshot()

        XCTAssertEqual(repeated?.fetchedAt, first?.fetchedAt)
        XCTAssertEqual(failed, first)
        XCTAssertEqual(AgentCodexModelRegistry.shared.currentLiveModels().map(\.id), ["gpt-6-astra"])
        XCTAssertEqual(CodexDynamicModelStore.load().map(\.id), ["gpt-6-astra"])
    }

    func testSuccessfulRemovalAndReappearancePublishOnlyCurrentRecords() async {
        let model = remoteModel("gpt-6-astra", effort: "ultra")
        let client = ScriptedCodexModelClient(steps: [
            .success([model]),
            .success([]),
            .success([model])
        ])
        let service = CodexModelPollingService(client: client)

        await service.refreshNow()
        XCTAssertEqual(CodexDynamicModelStore.load().map(\.id), ["gpt-6-astra"])

        await service.refreshNow()
        XCTAssertTrue(AgentCodexModelRegistry.shared.currentLiveModels().isEmpty)
        XCTAssertTrue(CodexDynamicModelStore.load().isEmpty)

        await service.refreshNow()
        XCTAssertEqual(AgentCodexModelRegistry.shared.currentLiveModels().map(\.id), ["gpt-6-astra"])
        XCTAssertEqual(CodexDynamicModelStore.load().map(\.id), ["gpt-6-astra"])
    }

    func testPublishedSnapshotBuildsRegistryOptionsAndProviderParametersFromCurrentRecords() async throws {
        let model = remoteModel("gpt-6-astra", effort: "ultra")
        let publishedRecords = CodexDynamicModelStore.canonicalRecords(from: [model])
        let cacheCases: [(name: String, models: [CodexAppServerClient.RemoteModel]?)] = [
            ("empty", nil),
            ("stale exact Fast", [remoteModel("gpt-6-astra-fast-ultra", effort: "high")])
        ]

        for cacheCase in cacheCases {
            _ = AgentCodexModelRegistry.shared.updateLiveModels([])
            if let cachedModels = cacheCase.models {
                CodexDynamicModelStore.save(cachedModels)
                XCTAssertEqual(CodexDynamicModelStore.load().map(\.id), ["gpt-6-astra-fast-ultra"])
            } else {
                UserDefaults.standard.removeObject(forKey: storageKey)
                XCTAssertTrue(CodexDynamicModelStore.load().isEmpty)
            }

            let service = CodexModelPollingService(
                client: ScriptedCodexModelClient(steps: [.success([model])])
            )
            await service.refreshNow()
            let latestSnapshot = await service.latestSnapshot()
            let snapshot = try XCTUnwrap(latestSnapshot, cacheCase.name)
            XCTAssertEqual(snapshot.models.map(\.id), ["gpt-6-astra"], cacheCase.name)
            XCTAssertEqual(CodexDynamicModelStore.load(), publishedRecords, cacheCase.name)

            let options = AgentCodexModelRegistry.shared.resolvedOptions(
                staticOptions: [],
                preferredLiveModels: snapshot.models
            )
            XCTAssertEqual(
                options.map(\.rawValue),
                ["default", "gpt-6-astra-ultra", "gpt-6-astra-fast-ultra"],
                cacheCase.name
            )
            let standardID = try XCTUnwrap(
                options.first(where: { $0.rawValue == "gpt-6-astra-ultra" })?.rawValue,
                cacheCase.name
            )
            let fastID = try XCTUnwrap(
                options.first(where: { $0.rawValue == "gpt-6-astra-fast-ultra" })?.rawValue,
                cacheCase.name
            )

            let standard = CodexExecAgentProvider.codexModelCLIArgs(
                selectedModelString: standardID
            )
            XCTAssertEqual(standard.modelArgs, ["--model", "gpt-6-astra"], cacheCase.name)
            XCTAssertEqual(standard.configArgs, ["-c", "model_reasoning_effort=ultra"], cacheCase.name)
            XCTAssertEqual(standard.specifier.appServerModelParam, "gpt-6-astra", cacheCase.name)
            XCTAssertEqual(standard.specifier.appServerEffortParam, "ultra", cacheCase.name)
            XCTAssertNil(standard.specifier.appServerServiceTierParam, cacheCase.name)

            let fast = CodexExecAgentProvider.codexModelCLIArgs(
                selectedModelString: fastID
            )
            XCTAssertEqual(fast.modelArgs, ["--model", "gpt-6-astra"], cacheCase.name)
            XCTAssertEqual(
                fast.configArgs,
                ["-c", "model_reasoning_effort=ultra", "-c", "service_tier=fast"],
                cacheCase.name
            )
            XCTAssertEqual(fast.specifier.appServerModelParam, "gpt-6-astra", cacheCase.name)
            XCTAssertEqual(fast.specifier.appServerEffortParam, "ultra", cacheCase.name)
            XCTAssertEqual(fast.specifier.appServerServiceTierParam, "fast", cacheCase.name)
        }
    }

    private func completes(_ tasks: [Task<Void, Never>], within timeout: Duration) async -> Bool {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let completionTask = Task {
            for task in tasks {
                await task.value
            }
            continuation.yield(true)
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            continuation.yield(false)
        }
        defer {
            completionTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
        for await completed in stream {
            return completed
        }
        return false
    }
}

private enum CodexModelPollingTestError: Error {
    case listingFailed
}

private actor ScriptedCodexModelClient: CodexModelListingClient {
    private var steps: [Result<[CodexAppServerClient.RemoteModel], CodexModelPollingTestError>]

    init(steps: [Result<[CodexAppServerClient.RemoteModel], CodexModelPollingTestError>]) {
        self.steps = steps
    }

    func listModels(limit _: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        guard !steps.isEmpty else { throw CodexModelPollingTestError.listingFailed }
        return try steps.removeFirst().get()
    }

    func stop() async {}
}

private actor BlockingCodexModelClient: CodexModelListingClient {
    private var listingCallCount = 0
    private var continuations: [UUID: CheckedContinuation<[CodexAppServerClient.RemoteModel], Error>] = [:]
    private var callCountObservers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var terminalResult: Result<[CodexAppServerClient.RemoteModel], CodexModelPollingTestError>?

    func listModels(limit _: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        let id = UUID()
        listingCallCount += 1
        publishCallCount()
        if let terminalResult {
            return try terminalResult.get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelListing(id) }
        }
    }

    func stop() async {}

    func callCount() -> Int {
        listingCallCount
    }

    func pendingListingCount() -> Int {
        continuations.count
    }

    func succeed(with models: [CodexAppServerClient.RemoteModel]) {
        terminalResult = .success(models)
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: models)
        }
    }

    func failOutstanding() {
        terminalResult = .failure(.listingFailed)
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CodexModelPollingTestError.listingFailed)
        }
    }

    func reachesCallCount(_ expected: Int, within timeout: Duration) async -> Bool {
        if listingCallCount >= expected { return true }

        let stream = callCountUpdates()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await count in stream where count >= expected {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let reached = await group.next() ?? false
            group.cancelAll()
            return reached
        }
    }

    private func callCountUpdates() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        callCountObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeCallCountObserver(id) }
        }
        continuation.yield(listingCallCount)
        return stream
    }

    private func publishCallCount() {
        for continuation in callCountObservers.values {
            continuation.yield(listingCallCount)
        }
    }

    private func removeCallCountObserver(_ id: UUID) {
        callCountObservers.removeValue(forKey: id)
    }

    private func cancelListing(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private func remoteModel(_ id: String, effort: String) -> CodexAppServerClient.RemoteModel {
    CodexAppServerClient.RemoteModel(
        id: id,
        model: id,
        displayName: id,
        description: "",
        isDefault: false,
        supportedReasoningEfforts: [.init(reasoningEffort: effort, description: "")],
        defaultReasoningEffort: effort
    )
}
