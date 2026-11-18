import Foundation

struct AgentCodexHookReviewHook: Hashable {
    let key: String
    let eventName: String
    /// The raw `source` Codex reports, such as `user` or `project`.
    let source: String
    let sourcePath: String
    let currentHash: String
    let enabled: Bool
    let trustStatus: CodexHookTrustStatus
    let commandOrHandler: String?
    let matcher: String?

    init(metadata: CodexHookMetadata) {
        key = metadata.key
        eventName = metadata.eventName
        source = metadata.source
        sourcePath = metadata.sourcePath
        currentHash = metadata.currentHash
        enabled = metadata.enabled
        trustStatus = metadata.trustStatus
        commandOrHandler = metadata.commandOrHandler
        matcher = metadata.matcher
    }

    /// How the review card and the MCP interaction name the hook's source. A review holds only
    /// `user` and `project` hooks, so any other source is shown raw.
    var sourceLabel: String {
        switch source {
        case "user":
            "Global (user)"
        case "project":
            "Project (project)"
        default:
            source
        }
    }

    /// How the review card and the MCP interaction show the matcher: the exact string, `""` for an
    /// empty one, and a note when Codex reported none.
    var matcherDisplay: String {
        switch matcher {
        case .none:
            "Not provided by Codex"
        case "":
            "\"\""
        case let .some(matcher):
            matcher
        }
    }

    var trustCandidate: CodexHookTrustCandidate {
        CodexHookTrustCandidate(key: key, currentHash: currentHash)
    }
}

struct AgentCodexHookReviewRequest: Identifiable, Hashable {
    enum Phase: String, Hashable {
        case reviewRequired
        case discovering
        case submitting
        case discoveryFailed
        case writeFailed
        case verificationFailed

        var allowsTrustDecision: Bool {
            self == .reviewRequired || self == .writeFailed || self == .verificationFailed
        }

        var allowsContinueWithoutHooks: Bool {
            allowsTrustDecision || self == .discoveryFailed
        }

        var allowsDiscoveryRetry: Bool {
            self == .discoveryFailed
        }

        var isResolving: Bool {
            self == .discovering || self == .submitting
        }
    }

    let id: UUID
    let executionCWD: String
    let hooks: [AgentCodexHookReviewHook]
    let warnings: [String]
    var phase: Phase
    var errorMessage: String?
    let detectedAt: Date
    let gateGeneration: UInt64

    init(
        tabID: UUID,
        runAttemptID: UUID?,
        runID: UUID?,
        executionCWD: String,
        hooks: [AgentCodexHookReviewHook],
        warnings: [String] = [],
        phase: Phase,
        errorMessage: String? = nil,
        detectedAt: Date = Date(),
        gateGeneration: UInt64
    ) {
        let trimmedCWD = executionCWD.trimmingCharacters(in: .whitespacesAndNewlines)
        let standardizedCWD = trimmedCWD.hasPrefix("/")
            ? URL(fileURLWithPath: trimmedCWD).standardizedFileURL.path
            : "<execution-cwd-unavailable>"
        let sortedHooks = hooks.sorted { lhs, rhs in
            let lhsKey = CodexHookUTF8Identity(lhs.key)
            let rhsKey = CodexHookUTF8Identity(rhs.key)
            if lhsKey == rhsKey {
                return CodexHookUTF8Identity(lhs.currentHash).lexicographicallyPrecedes(
                    CodexHookUTF8Identity(rhs.currentHash)
                )
            }
            return lhsKey.lexicographicallyPrecedes(rhsKey)
        }
        let attemptSeed = runAttemptID?.uuidString
            ?? runID?.uuidString
            ?? "gate-generation-\(gateGeneration)"
        var identityComponents = [
            Self.lengthPrefixed("codex-hook-review"),
            Self.lengthPrefixed(tabID.uuidString),
            Self.lengthPrefixed(attemptSeed),
            Self.lengthPrefixed(standardizedCWD)
        ]
        if sortedHooks.isEmpty {
            identityComponents.append(Self.lengthPrefixed("discovery-failure"))
        } else {
            for hook in sortedHooks {
                identityComponents.append(Self.lengthPrefixed(hook.key))
                identityComponents.append(Self.lengthPrefixed(hook.currentHash))
            }
        }

        id = StableUserInteractionIdentity.uuid(from: identityComponents.joined(separator: "|"))
        self.executionCWD = standardizedCWD
        self.hooks = sortedHooks
        self.warnings = warnings
        self.phase = phase
        self.errorMessage = errorMessage
        self.detectedAt = detectedAt
        self.gateGeneration = gateGeneration
    }

    var trustCandidates: [CodexHookTrustCandidate] {
        hooks.map(\.trustCandidate)
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

enum AgentCodexHookReviewDecision: Equatable {
    case approveSelected(hookKeys: [String])
    case approveAll
    case continueWithoutHooks
    case retryDiscovery
}

struct AgentCodexHookGateAudit: Equatable {
    enum Status: String, Equatable {
        case approvedAll
        case approvedSelected
        case continuedWithoutHooks
        case resolvedExternally
    }

    let status: Status
    let approvedCount: Int
    let skippedCount: Int?
    let resolvedAt: Date
    let interactionID: UUID
}

enum AgentCodexHookReviewResolutionError: Error, LocalizedError, Equatable {
    case noPendingReview
    case staleRequest(currentID: UUID)
    case busy
    case invalidDecision
    case invalidSelection
    case staleController
    case strictModeRequiresApproval

    var errorDescription: String? {
        switch self {
        case .noPendingReview:
            "No Codex hook review is pending."
        case .staleRequest:
            "The Codex hook inventory changed. Review the current interaction and retry."
        case .busy:
            "A Codex hook operation is already in progress."
        case .invalidDecision:
            "That decision is not available for the current Codex hook review phase."
        case .invalidSelection:
            "Approve Selected requires one or more unique hook keys from the current review."
        case .staleController:
            "The Codex controller binding changed. Start the turn again to review the current Codex hooks."
        case .strictModeRequiresApproval:
            "Codex hook approval strict mode requires approving every global and project hook in the current review before continuing."
        }
    }
}
