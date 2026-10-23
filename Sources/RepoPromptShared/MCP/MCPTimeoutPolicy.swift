import Foundation

public struct MCPToolCallDeadlineEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ordinaryPromptExportV1 = "ordinary_prompt_export_v1"
    }

    public enum TimeoutMode: String, Codable, Sendable {
        case ordinaryDefault = "default"
        case explicitFinite = "explicit_finite"
        case explicitUnbounded = "explicit_unbounded"
    }

    public let kind: Kind
    public let expiresAtUnixMilliseconds: Int64?
    public let timeoutMode: TimeoutMode

    private enum CodingKeys: String, CodingKey {
        case kind
        case expiresAtUnixMilliseconds = "expires_at_unix_milliseconds"
        case timeoutMode = "timeout_mode"
    }

    public init(
        kind: Kind,
        expiresAtUnixMilliseconds: Int64? = nil,
        timeoutMode: TimeoutMode = .ordinaryDefault
    ) {
        self.kind = kind
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.timeoutMode = timeoutMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        expiresAtUnixMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .expiresAtUnixMilliseconds
        )
        timeoutMode = try container.decodeIfPresent(TimeoutMode.self, forKey: .timeoutMode)
            ?? .ordinaryDefault
        if timeoutMode == .ordinaryDefault, expiresAtUnixMilliseconds == nil {
            throw DecodingError.keyNotFound(
                CodingKeys.expiresAtUnixMilliseconds,
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Default export metadata requires an expiration"
                )
            )
        }
    }
}

/// RepoPrompt CE-owned timeout policy for MCP execution, delivery, and caller-driven defaults.
/// Caller-supplied timeout values remain dynamic; these constants only define CE defaults and guards.
public enum MCPTimeoutPolicy {
    public static let boundedToolExecutionDeadlineSeconds = 30
    public static let boundedToolExecutionDeadline: Duration = .seconds(boundedToolExecutionDeadlineSeconds)

    public static let promptExportAdmissionHeadroomSeconds = 25
    public static let promptExportExecutionDeadlineSeconds = 240
    public static let promptExportExecutionDeadline: Duration = .seconds(
        promptExportExecutionDeadlineSeconds
    )

    /// macOS Finder Trash can legitimately retain synchronous post-move work after the source
    /// path disappears. Keep destructive file_actions bounded, but allow that system tail to
    /// settle as an applied mutation instead of reporting a false cancellation.
    public static let fileActionTrashExecutionDeadlineSeconds = 60
    public static let fileActionTrashExecutionDeadline: Duration = .seconds(
        fileActionTrashExecutionDeadlineSeconds
    )

    /// The time an edit call may spend on work outside its review: routing, freshness, preview, write,
    /// and reply. Review time counts inside the same fixed limit, so a review that ends near the limit
    /// leaves the write little time.
    public static let applyEditsWorkAllowanceSeconds: TimeInterval = 120
    public static let applyEditsExecutionDeadline: Duration = .seconds(
        applyEditsWorkAllowanceSeconds + applyEditsApprovalTimeoutSeconds
    )

    /// One budget, counted from the call's arrival, for a call to a window-exclusive tool to pass its
    /// connection lane, the window's exclusive lease, and the checks before its provider starts.
    public static let windowExclusiveAdmissionTimeoutSeconds = 20
    public static let windowExclusiveAdmissionTimeout: Duration = .seconds(
        windowExclusiveAdmissionTimeoutSeconds
    )

    public static let workspaceFreshnessWaitTimeoutSeconds = 30
    public static let workspaceFreshnessWaitTimeout: Duration = .seconds(workspaceFreshnessWaitTimeoutSeconds)

    /// Mutation preflight must settle before the ordinary bounded tool watchdog so a blocked
    /// workspace barrier can return a retryable result instead of racing connection teardown.
    public static let mutationPreflightFreshnessWaitTimeoutSeconds = 20
    public static let mutationPreflightFreshnessWaitTimeout: Duration = .seconds(
        mutationPreflightFreshnessWaitTimeoutSeconds
    )

    /// An ingress freshness wait inside a 30-second bounded tool call must settle before the
    /// ordinary bounded tool watchdog, so a backed-up ingress queue returns a retryable freshness
    /// reply instead of a watchdog timeout that detaches the provider. The 20-second bound reserves
    /// ten seconds of the deadline for the work the watchdog has already counted when the wait
    /// starts (domain admission, request resolution, and the Git-artifact preflight), but does not
    /// bound that work.
    public static let boundedToolFreshnessWaitTimeoutSeconds = 20
    public static let boundedToolFreshnessWaitTimeout: Duration = .seconds(
        boundedToolFreshnessWaitTimeoutSeconds
    )

    /// An explicit path request that has to wait for another mutation of the same root to finish
    /// its codemap fence gives up after this bound and returns the retryable freshness reply. The
    /// fence it waited on stays in place.
    public static let codemapFenceWaitTimeoutSeconds = 20
    public static let codemapFenceWaitTimeout: Duration = .seconds(codemapFenceWaitTimeoutSeconds)

    public static let workspaceReadinessWaitTimeoutSeconds = 30
    public static let workspaceReadinessWaitTimeout: Duration = .seconds(workspaceReadinessWaitTimeoutSeconds)

    /// Root-catalog authority fence for a single MCP file-tool call. Shorter than
    /// `workspaceReadinessWaitTimeout` because catalog admissibility excludes search-index
    /// construction: this window covers only the filesystem crawl. It stays well inside
    /// `boundedToolExecutionDeadline` so a crawl that overruns surfaces as an explicit
    /// retryable readiness error rather than racing the tool watchdog.
    public static let fileToolAuthorityReadinessWaitTimeoutSeconds = 5
    public static let fileToolAuthorityReadinessWaitTimeout: Duration = .seconds(
        fileToolAuthorityReadinessWaitTimeoutSeconds
    )

    /// Context Builder freezes roots once for an entire discovery run, so paying a longer
    /// wait once is cheaper than failing a run that would have resolved.
    public static let contextBuilderAuthorityReadinessWaitTimeoutSeconds = 10
    public static let contextBuilderAuthorityReadinessWaitTimeout: Duration = .seconds(
        contextBuilderAuthorityReadinessWaitTimeoutSeconds
    )

    public static let workspaceSwitchToolExecutionDeadlineSeconds = 120
    public static let workspaceSwitchToolExecutionDeadline: Duration = .seconds(
        workspaceSwitchToolExecutionDeadlineSeconds
    )

    /// Allows the 120-second workspace-switch window, 5-second cleanup grace, and 25 seconds of transport margin.
    public static let postStdinHalfCloseBridgeDrainDeadlineSeconds = 150

    public static let boundedToolCancellationCleanupGraceSeconds = 5
    public static let boundedToolCancellationCleanupGrace: Duration = .seconds(boundedToolCancellationCleanupGraceSeconds)

    public static let bootstrapReplacementPredecessorStopGraceSeconds = 5
    public static let bootstrapReplacementPredecessorStopGrace: Duration = .seconds(
        bootstrapReplacementPredecessorStopGraceSeconds
    )

    public static let promptExportResponseDeliveryAllowanceSeconds = 30
    public static let promptExportResponseDeliveryAllowance: Duration = .seconds(
        promptExportResponseDeliveryAllowanceSeconds
    )
    public static let promptExportReservedEnvelopeArgumentKey = "_repoprompt_execution_envelope"
    public static let promptExportReservedProviderAndCleanupSeconds =
        promptExportExecutionDeadlineSeconds
            + boundedToolCancellationCleanupGraceSeconds
            + promptExportResponseDeliveryAllowanceSeconds
    public static let promptExportTotalEnvelopeSeconds =
        promptExportAdmissionHeadroomSeconds + promptExportReservedProviderAndCleanupSeconds

    public static let responseSendDeadlineSeconds = promptExportResponseDeliveryAllowanceSeconds
    public static let responseSendDeadline: Duration = .seconds(responseSendDeadlineSeconds)
    public static let transportWriteStallTimeoutSeconds: TimeInterval = .init(responseSendDeadlineSeconds)

    public static let codexServerActiveTimeoutSeconds = 10000

    /// Default CLI-side deadline for ordinary tool responses.
    public static let cliDefaultToolCallTimeoutSeconds: TimeInterval = 300
    /// Long-running tools whose provider/run cancellation contract is authoritative.
    public static let cliDefaultUnboundedToolNames: Set<String> = [
        "ask_oracle",
        "context_builder"
    ]
    /// Extra time after a caller-requested server-side wait for response encoding
    /// and transport delivery before the CLI cancels the request.
    public static let cliSemanticWaitResponseMarginSeconds: TimeInterval = .init(responseSendDeadlineSeconds)

    public static let agentLifecycleDefaultWaitSeconds: TimeInterval = 120
    public static let askUserDefaultTimeoutSeconds: TimeInterval = 300
    public static let nextUserInstructionDefaultWaitSeconds: TimeInterval = 600
    public static let applyEditsApprovalTimeoutSeconds: TimeInterval = 300
    public static let worktreeMergeApprovalTimeoutSeconds: TimeInterval = 600
}
