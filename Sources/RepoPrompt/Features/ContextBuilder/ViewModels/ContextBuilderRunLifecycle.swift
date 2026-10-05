import Foundation

enum ContextBuilderRunOrigin: Equatable {
    case ui
    case mcp(controlToken: UUID)

    var isMCP: Bool {
        if case .mcp = self { return true }
        return false
    }
}

enum ContextBuilderRunTerminalOutcome: Equatable {
    case completed
    case cancelled
    case failed(String)

    var runState: AgentRunState {
        switch self {
        case .completed:
            .completed
        case .cancelled:
            .cancelled
        case let .failed(message):
            .failed(message)
        }
    }
}

enum ContextBuilderRunWaiterResolution: Equatable {
    case snapshot
    case cancellationError
}

struct ContextBuilderRunCancellationSettlementPolicy: Equatable {
    let waiterResolution: ContextBuilderRunWaiterResolution
    let saveHistory: Bool
}

enum ContextBuilderRunCancellationState: Equatable {
    case none
    case requested
    case deferredUntilFinalContextCommitCompletes
    case applied
}

enum ContextBuilderRunCancellationDisposition: Equatable {
    case settleImmediately
    case deferredUntilFinalContextCommitCompletes
    case alreadyRequested
    case terminal
}

enum ContextBuilderResponseDeliveryDrainOutcome: Equatable {
    case drained
    case peerEOFDetached
    case detachedAfterResponseDeliveryDrained
    case failed

    var succeeded: Bool {
        self != .failed
    }

    var transportAlreadyClosed: Bool {
        self == .peerEOFDetached || self == .detachedAfterResponseDeliveryDrained
    }
}

@MainActor
enum ContextBuilderResponseDeliveryDrainResolver {
    static func resolve(
        initiallyDetached: Bool,
        awaitDrain: @MainActor () async -> Bool,
        isAuthoritativeDetached: @MainActor () -> Bool,
        awaitTeardownPublication: @MainActor () async -> MCPServerViewModel.ContextBuilderTeardownPublicationOutcome
    ) async -> ContextBuilderResponseDeliveryDrainOutcome {
        if !initiallyDetached, await awaitDrain() { return .drained }

        let publication = await awaitTeardownPublication()
        guard publication.completedDiscoveryCanCommit,
              isAuthoritativeDetached()
        else { return .failed }
        return publication == .peerEOFDetached
            ? .peerEOFDetached
            : .detachedAfterResponseDeliveryDrained
    }
}

/// Coordinates successful child-connection finalization. Each tab-context snapshot must be
/// positively committed before transport termination can trigger connection-backed cleanup.
/// Termination completion is joined before connection/run mappings are removed.
@MainActor
enum ContextBuilderChildConnectionFinalizer {
    typealias AwaitResponseDeliveryDrain = @MainActor (_ connectionID: UUID) async -> Bool
    typealias RequestTermination = @MainActor (_ connectionID: UUID) -> Task<Void, Never>
    typealias CommitContext = @MainActor (_ connectionID: UUID) async -> Bool
    typealias BeforeTerminationRequest = @MainActor () async -> Void
    typealias BeforeTerminationJoin = @MainActor () async -> Void
    typealias CleanupMapping = @MainActor (_ connectionID: UUID) -> Void

    static func finalize(
        connectionIDs: [UUID],
        awaitResponseDeliveryDrain: AwaitResponseDeliveryDrain,
        commitContext: CommitContext,
        beforeTerminationRequest: BeforeTerminationRequest,
        requestTermination: RequestTermination,
        beforeTerminationJoin: BeforeTerminationJoin,
        cleanupMapping: CleanupMapping
    ) async -> Bool {
        for connectionID in connectionIDs {
            guard await awaitResponseDeliveryDrain(connectionID) else { return false }
            guard await commitContext(connectionID) else { return false }
        }

        await beforeTerminationRequest()
        let terminationTasks = connectionIDs.map(requestTermination)
        await beforeTerminationJoin()
        for task in terminationTasks {
            await task.value
        }

        for connectionID in connectionIDs {
            cleanupMapping(connectionID)
        }
        return true
    }
}

struct ContextBuilderResolvedRunAuthority {
    let configuration: ContextBuilderMCPRunConfiguration
    let agentKind: AgentProviderKind
    let modelRaw: String

    /// The frozen model-parameter pin (e.g. an OpenCode effort level) for the run's resolved
    /// agent+model, captured at run admission. The run never re-reads the chooser or profile
    /// after awaited startup work.
    let modelParameterSelections: [ACPModelParameterSelection]

    init(
        configuration: ContextBuilderMCPRunConfiguration,
        agentKind: AgentProviderKind,
        modelRaw: String,
        modelParameterSelections: [ACPModelParameterSelection] = []
    ) {
        self.configuration = configuration
        self.agentKind = agentKind
        self.modelRaw = modelRaw
        self.modelParameterSelections = modelParameterSelections
    }
}

struct ContextBuilderRunBehavior: Equatable {
    let tokenBudget: Int
    let enhancementMode: PromptEnhancementMode
    let questionTimeoutSeconds: TimeInterval
    let allowClarifyingQuestions: Bool
    let automaticFollowUp: ContextBuilderFollowUpType?

    static func ui(
        settings: ContextBuilderBehaviorSettings,
        selectedFollowUp: ContextBuilderFollowUpType
    ) -> ContextBuilderRunBehavior {
        ContextBuilderRunBehavior(
            tokenBudget: ContextBuilderBudgetResolver.resolveUIBudget(behaviorSettings: settings),
            enhancementMode: settings.enhancementMode,
            questionTimeoutSeconds: settings.questionTimeoutSeconds,
            allowClarifyingQuestions: settings.allowUIClarifyingQuestions,
            automaticFollowUp: settings.followUpAnalysisEnabled ? selectedFollowUp : nil
        )
    }

    static func mcp(
        settings: ContextBuilderBehaviorSettings,
        wantsResponse: Bool,
        targetIsActive: Bool
    ) -> ContextBuilderRunBehavior {
        ContextBuilderRunBehavior(
            tokenBudget: ContextBuilderBudgetResolver.resolveMCPBudget(
                wantsResponse: wantsResponse,
                behaviorSettings: settings
            ),
            enhancementMode: settings.enhancementMode,
            questionTimeoutSeconds: settings.questionTimeoutSeconds,
            allowClarifyingQuestions: targetIsActive && settings.allowMCPClarifyingQuestions,
            automaticFollowUp: nil
        )
    }
}

enum ContextBuilderRunError: LocalizedError {
    case missingRunBehavior

    var errorDescription: String? {
        switch self {
        case .missingRunBehavior:
            "Context Builder run behavior was not captured at run start."
        }
    }
}

/// Bounds on the two startup phases a run waits on without being able to finish them itself:
/// the window's MCP readiness and the provider's MCP connection being routed to the run.
/// Payload preparation is not covered.
///
/// Reaching a bound publishes the run's failure and starts its teardown. What that guarantees is
/// independence from the provider: the run's tail runs and its tab is given back without waiting
/// for a provider start or disposal still in progress, which stay owned by the run's record until
/// they finish. The tail's own steps are still awaited first, among them delivery of the run's
/// finalization progress report.
struct ContextBuilderStartupPolicy {
    /// Longest one run waits to join the window's MCP readiness.
    let readinessTimeout: Duration
    /// `noConnectionTimeout` bounds the wait for the provider's first matching MCP connection and
    /// `observedConnectionGrace` the wait from that connection to its committed route, so a run
    /// waits at most their sum from the moment its routing wait is enrolled.
    let routingWait: MCPRoutingWaitPolicy
    /// Monotonic time source for both bounds.
    let clock: MCPRoutingWaitClock

    static let standard = ContextBuilderStartupPolicy(
        readinessTimeout: .seconds(30),
        routingWait: MCPRoutingWaitPolicy(
            noConnectionTimeout: .seconds(30),
            observedConnectionGrace: .seconds(10)
        ),
        clock: .continuous()
    )
}

/// A run's provider start, owned by the run's record so that the run can end without waiting
/// for it.
///
/// The run's execution waits for the provider's stream through ``stream()``, and that wait ends
/// as soon as the execution is cancelled or the record's teardown begins. Neither ends the start
/// itself: a provider may ignore cancellation while it initializes. Whatever the start produces
/// after its run has ended is kept here, unconsumed, until teardown has disposed the provider.
@MainActor
final class ContextBuilderProviderStart {
    typealias Stream = AsyncThrowingStream<AIStreamResult, Error>

    private var task: Task<Void, Never>?
    private var result: Result<Stream, Error>?
    private var waiter: CheckedContinuation<Stream, Error>?
    private var isDetachedFromRun = false
    private(set) var isFinished = false
    /// Whether the start's result has been handed to the run's execution. Until it has, nothing
    /// consumes the provider's stream.
    private(set) var hasDeliveredResult = false

    init(_ operation: @escaping @MainActor () async throws -> Stream) {
        task = Task { @MainActor in
            let result: Result<Stream, Error>
            do {
                result = try await .success(operation())
            } catch {
                result = .failure(error)
            }
            self.finish(with: result)
        }
    }

    /// The provider's stream, or the error its start ended with, for the start's one consumer.
    ///
    /// The waiter is registered, resumed, and withdrawn on the main actor only, and each of those
    /// takes it first, so it is resumed exactly once whichever of the result and a cancellation
    /// comes first. A result delivered before a cancellation arrives is still returned, so the
    /// caller checks cancellation and the run's ownership before it uses the stream.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled or the start is detached
    ///   from its run before the result is delivered.
    func stream() async throws -> Stream {
        precondition(
            waiter == nil && !hasDeliveredResult,
            "ContextBuilderProviderStart supports exactly one stream consumer."
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || isDetachedFromRun {
                    continuation.resume(throwing: CancellationError())
                } else if let result {
                    self.result = nil
                    hasDeliveredResult = true
                    continuation.resume(with: result)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.endWait()
            }
        }
    }

    /// Ends the run's claim on the start: its wait, if any, ends now, and a result that arrives
    /// later is kept instead of delivered.
    func detachFromRun() {
        isDetachedFromRun = true
        task?.cancel()
        endWait()
    }

    func waitUntilFinished() async {
        await task?.value
    }

    /// Releases a result nothing consumed. Called once the provider that produced it is disposed.
    func discardUnconsumedResult() {
        result = nil
    }

    private func endWait() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: CancellationError())
    }

    private func finish(with result: Result<Stream, Error>) {
        isFinished = true
        guard !isDetachedFromRun, let waiter else {
            self.result = result
            return
        }
        self.waiter = nil
        hasDeliveredResult = true
        waiter.resume(with: result)
    }
}

struct ContextBuilderMCPRunConfiguration {
    let identity: WorkspaceSelectionIdentity
    let nestedTabContext: MCPServerViewModel.TabContextSnapshot
    let providerWorkspacePath: String
    let runBehavior: ContextBuilderRunBehavior
    let responseType: String?
    let planningModelRaw: String?
    let isSystemWorkspace: Bool

    var effectiveTokenBudget: Int {
        runBehavior.tokenBudget
    }
}

@MainActor
final class ContextBuilderRunRecord {
    enum ProviderActivity {
        case firstEvent(type: String)
        case firstRepoPromptTool(name: String)
    }

    struct TeardownPayload {
        let provider: HeadlessAgentProvider?
        let providerStart: ContextBuilderProviderStart?
        let executionTask: Task<Void, Never>?
    }

    let runID: UUID
    let tabID: UUID
    let session: ContextBuilderAgentViewModel.TabSession
    let ownership: AgentRunOwnership
    let origin: ContextBuilderRunOrigin
    let agentKind: AgentProviderKind
    let modelRaw: String
    let modelParameterSelections: [ACPModelParameterSelection]
    let progressReporter: ContextBuilderMCPProgressReporter?
    let activityReporter: ContextBuilderMCPActivityReporter?
    let workspaceContext: ContextBuilderWorkspaceContext?
    let mcpConfiguration: ContextBuilderMCPRunConfiguration?
    /// Working directory for the run's provider, fixed at admission so that startup never reads
    /// whichever workspace the window shows by then.
    let providerWorkspacePath: String?

    var output = ContextBuilderAssistantOutputAccumulator()
    var executionTask: Task<Void, Never>?
    var previewPublicationTask: Task<Void, Never>?
    var lastPublishedPreview: String?
    var finalContextConnectionIDForDiagnostics: UUID?
    var restoreConfiguration: (() -> Void)?

    private(set) var committedTabSnapshot: MCPServerViewModel.ContextBuilderCommittedTabSnapshot?
    private var continuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>?
    private var provider: HeadlessAgentProvider?
    private var providerStart: ContextBuilderProviderStart?
    private(set) var finalContextCommitClaimed = false
    private(set) var cancellationState = ContextBuilderRunCancellationState.none
    private(set) var deferredCancellationSettlementPolicy: ContextBuilderRunCancellationSettlementPolicy?
    private(set) var terminalOutcome: ContextBuilderRunTerminalOutcome?
    private(set) var teardownStartedAt: Date?
    private(set) var teardownFinishedAt: Date?
    private(set) var providerDisposalFinished = false
    private var isAwaitingProviderStartToDispose = false
    private var hasStoppedAwaitingProviderStart = false
    private(set) var executionTaskFinished = false
    private var teardownSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var executionSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var didBeginProviderStreamProgress = false
    private var didReportRoutingConfirmed = false
    private var didObserveProviderEventAfterRouting = false
    private var didObserveRepoPromptToolAfterRouting = false

    init(
        runID: UUID,
        tabID: UUID,
        session: ContextBuilderAgentViewModel.TabSession,
        ownership: AgentRunOwnership,
        origin: ContextBuilderRunOrigin,
        agentKind: AgentProviderKind,
        modelRaw: String,
        modelParameterSelections: [ACPModelParameterSelection] = [],
        workspaceContext: ContextBuilderWorkspaceContext? = nil,
        mcpConfiguration: ContextBuilderMCPRunConfiguration? = nil,
        providerWorkspacePath: String? = nil,
        continuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>? = nil,
        restoreConfiguration: (() -> Void)? = nil,
        progressReporter: ContextBuilderMCPProgressReporter? = nil,
        activityReporter: ContextBuilderMCPActivityReporter? = nil
    ) {
        self.runID = runID
        self.tabID = tabID
        self.session = session
        self.ownership = ownership
        self.origin = origin
        self.agentKind = agentKind
        self.modelRaw = modelRaw
        self.modelParameterSelections = modelParameterSelections
        self.workspaceContext = workspaceContext
        self.mcpConfiguration = mcpConfiguration
        self.providerWorkspacePath = mcpConfiguration?.providerWorkspacePath
            ?? workspaceContext?.providerWorkspacePath
            ?? providerWorkspacePath
        self.continuation = continuation
        self.restoreConfiguration = restoreConfiguration
        self.progressReporter = progressReporter
        self.activityReporter = activityReporter
    }

    func reportProgress(_ phase: ContextBuilderMCPProgressPhase) async {
        await progressReporter?(phase)
    }

    func reportRoutingProgress(_ phase: ContextBuilderMCPProgressPhase) async {
        guard !didBeginProviderStreamProgress else { return }
        if phase == .routingConfirmed {
            didReportRoutingConfirmed = true
        }
        await reportProgress(phase)
    }

    func beginProviderStreamProgress() async {
        guard !didBeginProviderStreamProgress else { return }
        didBeginProviderStreamProgress = true
        if !didReportRoutingConfirmed {
            didReportRoutingConfirmed = true
            await reportProgress(.routingConfirmed)
        }
        await reportProgress(.waitingForProviderStreamEvent)
    }

    func captureProviderActivity(_ result: AIStreamResult) -> [ProviderActivity] {
        var activity: [ProviderActivity] = []
        if !didObserveProviderEventAfterRouting {
            didObserveProviderEventAfterRouting = true
            activity.append(.firstEvent(type: result.type))
        }
        if !didObserveRepoPromptToolAfterRouting,
           result.type == "tool_call",
           let toolName = result.toolName,
           MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(toolName)
        {
            didObserveRepoPromptToolAfterRouting = true
            activity.append(
                .firstRepoPromptTool(
                    name: MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
                )
            )
        }
        return activity
    }

    func reportProviderActivity(_ activity: [ProviderActivity]) async {
        for item in activity {
            switch item {
            case let .firstEvent(type):
                await reportProgress(.providerStreamActive)
                await activityReporter?(
                    .providerStreamActive,
                    "First discovery provider event received: \(type)"
                )
            case let .firstRepoPromptTool(name):
                await activityReporter?(
                    .providerStreamActive,
                    "First nested RepoPrompt MCP tool request observed: \(name)"
                )
            }
        }
    }

    var isTerminal: Bool {
        terminalOutcome != nil
    }

    var hasDeferredCancellationPending: Bool {
        cancellationState == .deferredUntilFinalContextCommitCompletes
    }

    var isTeardownPending: Bool {
        teardownStartedAt != nil && teardownFinishedAt == nil
    }

    /// Whether the run's execution has yet to receive the result of its provider start. Until it
    /// has, no consumer holds the provider's stream.
    var isAwaitingProviderStartResult: Bool {
        providerStart?.hasDeliveredResult == false
    }

    @discardableResult
    func claimFinalContextCommit() -> Bool {
        guard terminalOutcome == nil,
              cancellationState == .none,
              !finalContextCommitClaimed
        else { return false }
        finalContextCommitClaimed = true
        return true
    }

    func requestCancellation(
        deferredSettlementPolicy: ContextBuilderRunCancellationSettlementPolicy
    ) -> ContextBuilderRunCancellationDisposition {
        guard terminalOutcome == nil else { return .terminal }
        guard cancellationState == .none else { return .alreadyRequested }

        if finalContextCommitClaimed {
            cancellationState = .deferredUntilFinalContextCommitCompletes
            deferredCancellationSettlementPolicy = deferredSettlementPolicy
            return .deferredUntilFinalContextCommitCompletes
        }
        cancellationState = .requested
        return .settleImmediately
    }

    func consumeDeferredCancellationAtSafeBoundary() -> ContextBuilderRunCancellationSettlementPolicy? {
        consumeDeferredCancellation()
    }

    /// A closing tab, a closing window, and a terminating app cannot wait indefinitely for a
    /// final-context operation that ignored cancellation. The caller must synchronously revoke
    /// registry publication authority before yielding again. Ordinary cancellation remains
    /// governed by `consumeDeferredCancellationAtSafeBoundary()`.
    func consumeDeferredCancellationForClose() -> ContextBuilderRunCancellationSettlementPolicy? {
        consumeDeferredCancellation()
    }

    private func consumeDeferredCancellation() -> ContextBuilderRunCancellationSettlementPolicy? {
        guard terminalOutcome == nil,
              cancellationState == .deferredUntilFinalContextCommitCompletes,
              let deferredCancellationSettlementPolicy
        else { return nil }
        cancellationState = .applied
        return deferredCancellationSettlementPolicy
    }

    @discardableResult
    func claimTerminal(_ outcome: ContextBuilderRunTerminalOutcome) -> Bool {
        guard terminalOutcome == nil else { return false }
        terminalOutcome = outcome
        return true
    }

    func installProvider(_ provider: HeadlessAgentProvider) -> Bool {
        guard terminalOutcome == nil, teardownStartedAt == nil, self.provider == nil else {
            return false
        }
        self.provider = provider
        return true
    }

    /// Starts `operation` as the run's provider start and makes the record its owner. Refused
    /// once the run is terminal or its teardown has begun, as ``installProvider(_:)`` is: no
    /// teardown would be left to dispose what the start produces.
    func beginProviderStart(
        _ operation: @escaping @MainActor () async throws -> ContextBuilderProviderStart.Stream
    ) -> ContextBuilderProviderStart? {
        guard terminalOutcome == nil, teardownStartedAt == nil, providerStart == nil else {
            return nil
        }
        let start = ContextBuilderProviderStart(operation)
        providerStart = start
        return start
    }

    func installCommittedTabSnapshot(
        _ snapshot: MCPServerViewModel.ContextBuilderCommittedTabSnapshot
    ) -> Bool {
        guard snapshot.nestedRunID == runID,
              snapshot.identity.tabID == tabID,
              committedTabSnapshot == nil
        else { return false }
        committedTabSnapshot = snapshot
        return true
    }

    func takeContinuation() -> CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>? {
        defer { continuation = nil }
        return continuation
    }

    func takeConfigurationRestoration() -> (() -> Void)? {
        defer { restoreConfiguration = nil }
        return restoreConfiguration
    }

    func beginTeardown(at date: Date = Date()) -> TeardownPayload? {
        guard teardownStartedAt == nil else { return nil }
        teardownStartedAt = date
        let payload = TeardownPayload(
            provider: provider,
            providerStart: providerStart,
            executionTask: executionTask
        )
        provider = nil
        providerStart = nil
        payload.providerStart?.detachFromRun()
        return payload
    }

    func markProviderDisposalFinished() {
        providerDisposalFinished = true
        finishTeardownIfReady()
    }

    /// Teardown has disposed the provider once and now waits for a provider start that was still
    /// running, so that it can dispose what that start leaves behind.
    func markAwaitingProviderStartToDispose() {
        isAwaitingProviderStartToDispose = true
        finishTeardownIfReady()
    }

    func markExecutionTaskFinished() {
        executionTaskFinished = true
        executionTask = nil
        let waiters = executionSettlementWaiters
        executionSettlementWaiters.removeAll()
        waiters.forEach { $0.resume() }
        finishTeardownIfReady()
    }

    /// Waits until the run's execution has ended or its teardown has stopped waiting for it,
    /// without waiting for the provider's disposal. Teardown is what ends this wait, and every
    /// run that reaches a terminal state is given one.
    func awaitExecutionSettlement() async {
        if executionTaskFinished { return }
        await withCheckedContinuation { continuation in
            if executionTaskFinished {
                continuation.resume()
            } else {
                executionSettlementWaiters.append(continuation)
            }
        }
    }

    /// Provider disposal remains the process-family and launch-config-lease authority while a tab
    /// or window closes or the app terminates. Once the grace period expires, none of them need
    /// also wait for an outer run task that ignored cancellation after the provider has
    /// independently begun teardown.
    func stopAwaitingExecutionTaskForClose() {
        markExecutionTaskFinished()
    }

    /// A closing window and a terminating app join the provider's first disposal, which ends
    /// whatever the provider had started by then. Once the grace period expires, they need not
    /// also wait for a provider start that ignores cancellation. The disposal that follows such a
    /// start has not happened and is not reported as finished; teardown counts as settled without
    /// it.
    func stopAwaitingProviderStartForClose() {
        hasStoppedAwaitingProviderStart = true
        finishTeardownIfReady()
    }

    func awaitTeardownSettlement() async {
        if teardownFinishedAt != nil { return }
        await withCheckedContinuation { continuation in
            if teardownFinishedAt != nil {
                continuation.resume()
            } else {
                teardownSettlementWaiters.append(continuation)
            }
        }
    }

    private func finishTeardownIfReady() {
        let providerSettled = providerDisposalFinished
            || (isAwaitingProviderStartToDispose && hasStoppedAwaitingProviderStart)
        guard providerSettled, executionTaskFinished, teardownFinishedAt == nil else { return }
        teardownFinishedAt = Date()
        let waiters = teardownSettlementWaiters
        teardownSettlementWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
final class ContextBuilderRunRegistry {
    private var recordsByRunID: [UUID: ContextBuilderRunRecord] = [:]
    private var activeRunIDByTabID: [UUID: UUID] = [:]

    @discardableResult
    func register(_ record: ContextBuilderRunRecord) -> Bool {
        guard recordsByRunID[record.runID] == nil,
              activeRunIDByTabID[record.tabID] == nil
        else {
            return false
        }
        recordsByRunID[record.runID] = record
        activeRunIDByTabID[record.tabID] = record.runID
        return true
    }

    func record(runID: UUID) -> ContextBuilderRunRecord? {
        recordsByRunID[runID]
    }

    func activeRecord(tabID: UUID) -> ContextBuilderRunRecord? {
        guard let runID = activeRunIDByTabID[tabID] else { return nil }
        return recordsByRunID[runID]
    }

    func records(tabID: UUID) -> [ContextBuilderRunRecord] {
        recordsByRunID.values.filter { $0.tabID == tabID }
    }

    func retainedRecordsSnapshot() -> [ContextBuilderRunRecord] {
        Array(recordsByRunID.values)
    }

    func acceptsEvents(from record: ContextBuilderRunRecord, currentSession: ContextBuilderAgentViewModel.TabSession?) -> Bool {
        recordsByRunID[record.runID] === record &&
            activeRunIDByTabID[record.tabID] == record.runID &&
            currentSession === record.session &&
            !record.isTerminal &&
            record.session.activeRunOwnership == record.ownership
    }

    @discardableResult
    func releaseActiveSlot(for record: ContextBuilderRunRecord) -> Bool {
        guard activeRunIDByTabID[record.tabID] == record.runID else { return false }
        activeRunIDByTabID.removeValue(forKey: record.tabID)
        return true
    }

    @discardableResult
    func removeAfterTeardown(_ record: ContextBuilderRunRecord) -> Bool {
        guard recordsByRunID[record.runID] === record,
              record.teardownFinishedAt != nil
        else {
            return false
        }
        recordsByRunID.removeValue(forKey: record.runID)
        return true
    }
}
