import Foundation
import RepoPromptCodeMapCore

/// Root-local derived graph authority. Overlay generations are freshness metadata; queries always
/// pin the latest immutable commit and destructive safety is enforced independently by fences.
actor WorkspaceCodemapSelectionGraph {
    private struct CandidateBuild {
        let snapshot: WorkspaceCodemapGraphCommittedSnapshot
        let changedFileCount: Int
        /// Sources whose edges and unresolved records the candidate rebuilt.
        let affectedSourceIDs: Set<UUID>
        let resync: Bool
        /// Ordering comparisons performed while building the candidate.
        let comparisonCount: UInt64
        /// Items visited while building the candidate (IDs, postings, references, and scans).
        let visitCount: UInt64
        /// Entries copied or shifted to derive the candidate's storage from its base.
        let copiedEntryCount: UInt64
        /// Terraform calls whose declarations the candidate changed.
        let changedCallKeys: Set<TerraformCallKey>
        /// Terraform call subscriptions the candidate adds, by subscribing file.
        let addedCallSubscriptions: [UUID: [TerraformCallKey]]

        var affectedSourceCount: Int {
            affectedSourceIDs.count
        }
    }

    private enum CandidateBuildOutcome {
        case success(CandidateBuild)
        case failure(WorkspaceCodemapGraphApplyRejection)
        case cancelled
    }

    /// The derived fences one fence request or commit adds. It stores at most the fence capacity the
    /// graph has left and refuses the first new entry past it, so the work done before a
    /// capacity revocation is proportional to the capacity, even for a call label thousands of
    /// files share.
    private struct DerivedFenceBuilder {
        private let existing: Set<WorkspaceCodemapGraphDerivedFence>
        private let capacity: Int
        private(set) var added: Set<WorkspaceCodemapGraphDerivedFence> = []

        /// Fails when the capacity is already negative.
        init?(existing: Set<WorkspaceCodemapGraphDerivedFence>, capacity: Int) {
            guard capacity >= 0 else { return nil }
            self.existing = existing
            self.capacity = capacity
        }

        /// Adds a fence the graph doesn't hold yet. Returns false when it would exceed the capacity.
        mutating func insert(_ fence: WorkspaceCodemapGraphDerivedFence) -> Bool {
            if existing.contains(fence) || added.contains(fence) { return true }
            guard added.count < capacity else { return false }
            added.insert(fence)
            return true
        }
    }

    private let rootEpoch: WorkspaceCodemapRootEpoch
    private let graphPolicy: WorkspaceCodemapGraphPolicy
    private let applyBuildHook: @Sendable () async -> Void
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let reconciliationWaiter: @Sendable (UInt64) async -> Void

    private var repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken?
    private var committedSnapshot: WorkspaceCodemapGraphCommittedSnapshot?
    private var appliedGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 0)
    private var observedGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 0)
    private var graphRevision: UInt64 = 0
    private var fenceIdentities: Set<WorkspaceCodemapGraphFenceIdentity> = []
    /// Files hidden while a fenced Terraform call file still holds the binding their links use.
    /// They count against the same capacity as `fenceIdentities`.
    private var derivedFences: Set<WorkspaceCodemapGraphDerivedFence> = []
    private var safetyCounter: UInt64 = 0
    private var revocationReason: WorkspaceCodemapGraphRevocationReason?
    private var activeApply = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []
    private var shuttingDown = false
    private var activeCandidateTask: Task<CandidateBuildOutcome, Never>?
    #if DEBUG
        private var debugLastAffectedSourceIDs: Set<UUID> = []
    #endif

    private var reconciling = false
    private var reconciliationAttempt = 0
    private var reconciliationStartedUptimeNanoseconds: UInt64?
    private var reconciliationNeedsFollowingPass = false
    private var reconciliationCycleID: UUID?
    private var reconciliationDeadlineTask: Task<Void, Never>?

    private var successfulCommitCount: UInt64 = 0
    private var resyncCommitCount: UInt64 = 0
    private var rejectedApplyCount: UInt64 = 0
    private var lastCommittedUptimeNanoseconds: UInt64?
    private var lastCommitIntervalMilliseconds: UInt64?
    private var statusContinuations: [
        UUID: AsyncStream<WorkspaceCodemapGraphIncrementalAccounting>.Continuation
    ] = [:]
    private var materializedQueryResultCount: UInt64 = 0
    private var diffPullCount: UInt64 = 0
    private var resyncPullCount: UInt64 = 0
    private var revokedPullCount: UInt64 = 0
    private var lastChangedFileCount = 0
    private var lastAffectedSourceCount = 0
    private var totalChangedFileCount: UInt64 = 0
    private var totalAffectedSourceCount: UInt64 = 0
    private var currentQueryCount: UInt64 = 0
    private var pendingQueryCount: UInt64 = 0
    private var partialCoverageQueryCount: UInt64 = 0
    private var reconciliationStartedCount: UInt64 = 0
    private var reconciliationCoalescedCount: UInt64 = 0
    private var reconciliationCommittedCount: UInt64 = 0
    private var reconciliationRetryCount: UInt64 = 0
    private var reconciliationRevokedCount: UInt64 = 0
    private var receiptValidationCount: UInt64 = 0
    private var receiptRejectionCount: UInt64 = 0
    private var applyStartedUptimeNanoseconds: UInt64?
    private var lastApplyDurationMilliseconds: UInt64?
    private var maximumApplyDurationMilliseconds: UInt64?
    private var highFanoutApplyCount: UInt64 = 0
    private var lastCandidateComparisonCount: UInt64 = 0
    private var lastCandidateVisitCount: UInt64 = 0
    private var maximumDiffCandidateVisitCount: UInt64 = 0
    private var lastCandidateCopiedEntryCount: UInt64 = 0
    private var maximumDiffCandidateCopiedEntryCount: UInt64 = 0
    private var totalCandidateCopiedEntryCount: UInt64 = 0
    private var totalCandidateComparisonCount: UInt64 = 0
    private var totalCandidateVisitCount: UInt64 = 0
    private var totalApplyDurationMilliseconds: UInt64 = 0
    private var reconciliationExpiryHandler: (@Sendable () async -> Void)?

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken? = nil,
        graphPolicy: WorkspaceCodemapGraphPolicy = .initial,
        applyBuildHook: @escaping @Sendable () async -> Void = {},
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        reconciliationWaiter: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.rootEpoch = rootEpoch
        self.repositoryAuthority = repositoryAuthority
        self.graphPolicy = graphPolicy
        self.applyBuildHook = applyBuildHook
        self.uptimeNanoseconds = uptimeNanoseconds
        self.reconciliationWaiter = reconciliationWaiter
    }

    func installReconciliationExpiryHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        reconciliationExpiryHandler = handler
    }

    func observe(
        generation: WorkspaceCodemapSelectionGraphContributionGeneration
    ) {
        if generation > observedGeneration {
            observedGeneration = generation
            publishAccounting()
        }
    }

    func apply(
        _ changes: WorkspaceCodemapGraphChangesDisposition
    ) async -> WorkspaceCodemapGraphApplyDisposition {
        await acquireApplyLane()
        applyStartedUptimeNanoseconds = uptimeNanoseconds()
        defer {
            recordApplyDuration()
            releaseApplyLane()
            publishAccounting()
        }

        switch changes {
        case .diff: diffPullCount &+= 1
        case .resync: resyncPullCount &+= 1
        case .revoked: revokedPullCount &+= 1
        case .unchanged: break
        }

        if let revocationReason { return .revoked(revocationReason) }
        if shuttingDown { return .cancelled }

        switch changes {
        case let .unchanged(generation):
            observe(generation: generation)
            return .unchanged(generation: generation)
        case let .revoked(reason):
            revoke(reason)
            return .revoked(reason)
        case let .diff(changedSlots, removed, coverage, generation):
            observe(generation: generation)
            guard generation > appliedGeneration else {
                if generation == appliedGeneration { return .unchanged(generation: generation) }
                rejectedApplyCount &+= 1
                return .rejected(.staleGeneration)
            }
            guard let base = committedSnapshot else {
                rejectedApplyCount &+= 1
                return .rejected(.generationContinuity)
            }
            return await buildAndCommit(
                base: base,
                slots: changedSlots,
                removed: removed,
                coverage: coverage,
                generation: generation,
                schemaVersion: base.schemaVersion,
                policyVersion: base.policyVersion,
                authority: base.repositoryAuthority,
                resync: false
            )
        case let .resync(checkpoint, generation):
            observe(generation: generation)
            guard checkpoint.generation == generation else {
                rejectedApplyCount &+= 1
                return .rejected(.invalidCheckpoint)
            }
            return await buildAndCommit(
                base: nil,
                slots: checkpoint.slots,
                removed: [],
                coverage: checkpoint.coverage,
                generation: generation,
                schemaVersion: checkpoint.schemaVersion,
                policyVersion: checkpoint.policyVersion,
                authority: checkpoint.repositoryAuthority,
                resync: true
            )
        }
    }

    private func buildAndCommit(
        base: WorkspaceCodemapGraphCommittedSnapshot?,
        slots: [WorkspaceCodemapGraphSlot],
        removed: [WorkspaceCodemapGraphRemoval],
        coverage: WorkspaceCodemapGraphCatalogCoverage,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32,
        authority: WorkspaceCodemapRepositoryAuthorityToken,
        resync: Bool
    ) async -> WorkspaceCodemapGraphApplyDisposition {
        guard coverage.rootEpoch == rootEpoch,
              slots.allSatisfy({ $0.rootEpoch == rootEpoch }),
              removed.allSatisfy({ $0.rootEpoch == rootEpoch })
        else {
            rejectedApplyCount &+= 1
            return .rejected(.rootEpochMismatch)
        }
        if let currentAuthority = repositoryAuthority, currentAuthority != authority {
            rejectedApplyCount &+= 1
            return .rejected(.repositoryAuthorityMismatch)
        }
        guard schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion else {
            rejectedApplyCount &+= 1
            return .rejected(.schemaMismatch)
        }
        guard policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion else {
            rejectedApplyCount &+= 1
            return .rejected(.policyMismatch)
        }
        guard let watermark = coverage.catalogWatermark else {
            rejectedApplyCount &+= 1
            return .rejected(.invalidCheckpoint)
        }
        if let oldWatermark = committedSnapshot?.catalogWatermark,
           oldWatermark.catalogGeneration > watermark.catalogGeneration
        {
            rejectedApplyCount &+= 1
            return .rejected(.catalogWatermarkRegression)
        }

        let baseRevision = graphRevision
        let (nextRevision, revisionOverflow) = baseRevision.addingReportingOverflow(1)
        guard !revisionOverflow else {
            revoke(.accountingOverflow)
            return .revoked(.accountingOverflow)
        }
        let policy = graphPolicy
        let capturedRootEpoch = rootEpoch
        await applyBuildHook()
        guard !shuttingDown, revocationReason == nil else { return .cancelled }
        let candidateTask = Task.detached(priority: .utility) {
            Self.makeCandidate(
                base: resync ? nil : base,
                changedSlots: slots,
                removed: removed,
                rootEpoch: capturedRootEpoch,
                authority: authority,
                watermark: watermark,
                coverage: coverage,
                generation: generation,
                schemaVersion: schemaVersion,
                policyVersion: policyVersion,
                nextRevision: nextRevision,
                graphPolicy: policy,
                resync: resync
            )
        }
        activeCandidateTask = candidateTask
        let build = await candidateTask.value
        activeCandidateTask = nil

        guard !shuttingDown else { return .cancelled }
        if let revocationReason { return .revoked(revocationReason) }
        guard graphRevision == baseRevision else {
            rejectedApplyCount &+= 1
            return .rejected(.generationContinuity)
        }
        switch build {
        case .cancelled:
            return .cancelled
        case let .failure(rejection):
            rejectedApplyCount &+= 1
            return .rejected(rejection)
        case let .success(candidate):
            let destructiveFileIDs = Set(removed.filter(\.reason.requiresSafetyFence).map(\.fileID))
            let destructiveIdentities = Set(destructiveFileIDs.map {
                WorkspaceCodemapGraphFenceIdentity(fileID: $0, slot: base?.slotsByFileID[$0])
            })
            let newFenceIdentities = destructiveIdentities.subtracting(fenceIdentities)
            // Deriving fences is part of applying the candidate, so its work counts as candidate visits.
            var fenceVisits: UInt64 = 0
            guard var fenceBuilder = derivedFenceBuilder(addingIdentityCount: newFenceIdentities.count),
                  newFenceIdentities.allSatisfy({
                      Self.deriveFences(for: $0, in: base, into: &fenceBuilder, visits: &fenceVisits)
                  }),
                  deriveFencesForCallChanges(candidate, into: &fenceBuilder, visits: &fenceVisits)
            else {
                revoke(.fenceCapacityExceeded)
                return .revoked(.fenceCapacityExceeded)
            }
            let newDerivedFences = fenceBuilder.added
            let visitCount = candidate.visitCount &+ fenceVisits
            if !newFenceIdentities.isEmpty || !newDerivedFences.isEmpty {
                let (nextCounter, overflow) = safetyCounter.addingReportingOverflow(1)
                guard !overflow else {
                    revoke(.safetyCounterExhausted)
                    return .revoked(.safetyCounterExhausted)
                }
                fenceIdentities.formUnion(newFenceIdentities)
                derivedFences.formUnion(newDerivedFences)
                safetyCounter = nextCounter
            }
            repositoryAuthority = authority
            committedSnapshot = candidate.snapshot
            appliedGeneration = generation
            if observedGeneration < generation { observedGeneration = generation }
            graphRevision = candidate.snapshot.graphRevision
            successfulCommitCount &+= 1
            lastChangedFileCount = candidate.changedFileCount
            lastAffectedSourceCount = candidate.affectedSourceCount
            #if DEBUG
                debugLastAffectedSourceIDs = candidate.affectedSourceIDs
            #endif
            totalChangedFileCount &+= UInt64(candidate.changedFileCount)
            totalAffectedSourceCount &+= UInt64(candidate.affectedSourceCount)
            lastCandidateComparisonCount = candidate.comparisonCount
            lastCandidateVisitCount = visitCount
            lastCandidateCopiedEntryCount = candidate.copiedEntryCount
            totalCandidateCopiedEntryCount &+= candidate.copiedEntryCount
            totalCandidateComparisonCount &+= candidate.comparisonCount
            totalCandidateVisitCount &+= visitCount
            if !resync {
                maximumDiffCandidateVisitCount = max(maximumDiffCandidateVisitCount, visitCount)
                maximumDiffCandidateCopiedEntryCount = max(
                    maximumDiffCandidateCopiedEntryCount,
                    candidate.copiedEntryCount
                )
            }
            if candidate.affectedSourceCount >= graphPolicy.candidateOverflowThreshold {
                highFanoutApplyCount &+= 1
            }
            if resync {
                resyncCommitCount &+= 1
                if reconciling { reconciliationCommittedCount &+= 1 }
            }
            let committedAt = uptimeNanoseconds()
            if let previous = lastCommittedUptimeNanoseconds, committedAt >= previous {
                lastCommitIntervalMilliseconds = (committedAt - previous) / 1_000_000
            }
            lastCommittedUptimeNanoseconds = committedAt
            if reconciling, resync {
                reconciling = false
                reconciliationAttempt = 0
                reconciliationStartedUptimeNanoseconds = nil
                cancelReconciliationDeadline()
                if reconciliationNeedsFollowingPass {
                    reconciliationNeedsFollowingPass = false
                    reconciling = true
                    reconciliationAttempt = 1
                    reconciliationStartedUptimeNanoseconds = uptimeNanoseconds()
                    scheduleReconciliationDeadline()
                }
            }
            return .committed(
                revision: graphRevision,
                appliedGeneration: generation,
                changedFileCount: candidate.changedFileCount,
                affectedSourceCount: candidate.affectedSourceCount,
                resync: resync
            )
        }
    }

    func latestSnapshot() -> WorkspaceCodemapGraphLatestSnapshotDisposition {
        if let revocationReason { return .revoked(revocationReason) }
        guard let snapshot = committedSnapshot,
              let receipt = WorkspaceCodemapGraphSnapshotReceipt(
                  snapshotID: snapshot.snapshotID,
                  graphRevision: snapshot.graphRevision,
                  rootEpoch: snapshot.rootEpoch,
                  repositoryAuthority: snapshot.repositoryAuthority,
                  catalogWatermark: snapshot.catalogWatermark,
                  appliedGeneration: snapshot.appliedGeneration,
                  safetyCounter: safetyCounter,
                  schemaVersion: snapshot.schemaVersion,
                  policyVersion: snapshot.policyVersion
              )
        else { return .pending }
        let freshness: WorkspaceCodemapGraphSnapshotFreshness = observedGeneration > appliedGeneration
            ? .updatesPending(observedGeneration: observedGeneration)
            : .current
        return .ready(WorkspaceCodemapGraphPinnedSnapshot(
            snapshot: snapshot,
            receipt: receipt,
            freshness: freshness,
            reconciling: reconciling,
            fenceIdentities: fenceIdentities,
            derivedFences: derivedFences
        ))
    }

    func automaticSelectionLatest(
        _ query: WorkspaceCodemapAutomaticSelectionGraphQuery
    ) -> WorkspaceCodemapAutomaticSelectionGraphDisposition {
        guard query.rootEpoch == rootEpoch else {
            return .revoked(.repositoryAuthorityChanged)
        }
        if Task.isCancelled { return .cancelled }
        switch latestSnapshot() {
        case .pending:
            pendingQueryCount &+= 1
            publishAccounting()
            return .pending
        case let .revoked(reason):
            return .revoked(reason)
        case let .ready(pinned):
            recordQuery(pinned)
            let snapshot = pinned.snapshot
            let groupedSeeds = Dictionary(grouping: query.sources, by: \.fileID)
            let sourceIDs = Set(groupedSeeds.keys)
            let orderedSourceIDs = groupedSeeds.keys.sorted {
                Self.fileIDPrecedes($0, $1, snapshot: snapshot)
            }
            var sources: [WorkspaceCodemapAutomaticSelectionGraphSource] = []
            var targetIDs = Set<UUID>()
            var resolutionCount = 0
            var referenceFailureCount = 0

            for fileID in orderedSourceIDs {
                let seeds = groupedSeeds[fileID] ?? []
                let requestedGenerations = Set(seeds.map(\.requestGeneration))
                let requestedGeneration = requestedGenerations.min() ?? 0
                let slot = snapshot.slotsByFileID[fileID]
                let state: WorkspaceCodemapAutomaticSelectionGraphSourceState = if requestedGenerations.count != 1 {
                    .staleGeneration(
                        expected: requestedGeneration,
                        committed: slot?.requestGeneration
                    )
                } else if pinned.isFenced(fileID) {
                    .fenced
                } else if let slot {
                    if slot.requestGeneration != requestedGeneration ||
                        slot.pathGeneration != requestedGeneration
                    {
                        .staleGeneration(
                            expected: requestedGeneration,
                            committed: slot.requestGeneration
                        )
                    } else {
                        switch slot.state {
                        case .pending:
                            .pending
                        case .contributed, .empty:
                            .covered
                        case .terminalArtifact, .terminalExcluded:
                            .excluded
                        }
                    }
                } else {
                    .notIndexed
                }
                sources.append(.init(
                    fileID: fileID,
                    requestGeneration: requestedGeneration,
                    state: state
                ))
                guard state == .covered else { continue }
                let edges = (snapshot.outgoingEdgesBySource[fileID] ?? []).filter {
                    !pinned.isFenced($0.targetFileID)
                }
                let (nextResolutionCount, resolutionOverflow) = resolutionCount.addingReportingOverflow(edges.count)
                guard !resolutionOverflow else { return .budget(.accountingOverflow) }
                resolutionCount = nextResolutionCount
                for edge in edges where !sourceIDs.contains(edge.targetFileID) {
                    targetIDs.insert(edge.targetFileID)
                }
                let failures = snapshot.unresolvedBySource[fileID]?.count ?? 0
                let (nextFailureCount, failureOverflow) = referenceFailureCount.addingReportingOverflow(failures)
                guard !failureOverflow else { return .budget(.accountingOverflow) }
                referenceFailureCount = nextFailureCount
            }

            if resolutionCount > query.maximumResolutionCount {
                return .budget(.resolutionLimit(
                    attempted: resolutionCount,
                    limit: query.maximumResolutionCount
                ))
            }
            if referenceFailureCount > query.maximumReferenceFailureCount {
                return .budget(.referenceFailureLimit(
                    attempted: referenceFailureCount,
                    limit: query.maximumReferenceFailureCount
                ))
            }

            let orderedTargetIDs = targetIDs.sorted {
                Self.fileIDPrecedes($0, $1, snapshot: snapshot)
            }
            if orderedTargetIDs.count > query.maximumTargetCount {
                return .budget(.targetLimit(
                    attempted: orderedTargetIDs.count,
                    limit: query.maximumTargetCount
                ))
            }
            var byteCount = 0
            var targets: [WorkspaceCodemapAutomaticSelectionGraphTarget] = []
            targets.reserveCapacity(orderedTargetIDs.count)
            for fileID in orderedTargetIDs {
                guard let node = snapshot.nodesByFileID[fileID],
                      let slot = snapshot.slotsByFileID[fileID],
                      slot.requestGeneration == node.requestGeneration,
                      slot.pathGeneration == node.pathGeneration
                else { continue }
                let (withFixedOverhead, fixedOverflow) = byteCount.addingReportingOverflow(64)
                let (withPath, pathOverflow) = withFixedOverhead.addingReportingOverflow(
                    node.standardizedRelativePath.utf8.count
                )
                guard !fixedOverflow, !pathOverflow else { return .budget(.accountingOverflow) }
                byteCount = withPath
                targets.append(.init(
                    fileID: fileID,
                    requestGeneration: node.requestGeneration,
                    standardizedRelativePath: node.standardizedRelativePath
                ))
            }
            if byteCount > query.maximumByteCount {
                return .budget(.byteLimit(attempted: byteCount, limit: query.maximumByteCount))
            }
            return .ready(.init(
                rootEpoch: rootEpoch,
                receipt: pinned.receipt,
                coverage: snapshot.coverage,
                freshness: pinned.freshness,
                reconciling: pinned.reconciling,
                sources: sources,
                targets: targets,
                resolutionCount: resolutionCount,
                referenceFailureCount: referenceFailureCount,
                materializedByteCount: byteCount
            ))
        }
    }

    func traverseLatest(
        _ query: WorkspaceCodemapGraphStructureQuery
    ) throws -> WorkspaceCodemapGraphStructureRootResult {
        try Task.checkCancellation()
        guard !query.seedFileIDs.isEmpty else {
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: .unavailable,
                coverage: committedSnapshot?.coverage,
                updatesPending: observedGeneration > appliedGeneration,
                reconciling: reconciling,
                receipt: nil,
                seeds: [],
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: [.emptySeeds]
            )
        }
        switch latestSnapshot() {
        case .pending:
            pendingQueryCount &+= 1
            publishAccounting()
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: .pending,
                coverage: nil,
                updatesPending: true,
                reconciling: reconciling,
                receipt: nil,
                seeds: query.seedFileIDs.map {
                    WorkspaceCodemapGraphStructureSeed(
                        fileID: $0,
                        standardizedRelativePath: nil,
                        state: .pending
                    )
                },
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: [.graphPending]
            )
        case let .revoked(reason):
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: .unavailable,
                coverage: committedSnapshot?.coverage,
                updatesPending: false,
                reconciling: false,
                receipt: nil,
                seeds: query.seedFileIDs.map {
                    WorkspaceCodemapGraphStructureSeed(
                        fileID: $0,
                        standardizedRelativePath: committedSnapshot?.slotsByFileID[$0]?.standardizedRelativePath,
                        state: .notIndexed
                    )
                },
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: [.graphRevoked(reason)]
            )
        case let .ready(pinned):
            recordQuery(pinned)
            return try traverse(query, pinned: pinned)
        }
    }

    private func traverse(
        _ query: WorkspaceCodemapGraphStructureQuery,
        pinned: WorkspaceCodemapGraphPinnedSnapshot
    ) throws -> WorkspaceCodemapGraphStructureRootResult {
        let snapshot = pinned.snapshot
        let orderedSeedIDs = Set(query.seedFileIDs).sorted {
            Self.fileIDPrecedes($0, $1, snapshot: snapshot)
        }
        var issues: [WorkspaceCodemapGraphStructureIssue] = []
        var seeds: [WorkspaceCodemapGraphStructureSeed] = []
        var usableSeedIDs: [UUID] = []
        for fileID in orderedSeedIDs {
            let slot = snapshot.slotsByFileID[fileID]
            let path = snapshot.nodesByFileID[fileID]?.standardizedRelativePath
                ?? slot?.standardizedRelativePath
            let state: WorkspaceCodemapStructureSeedState
            if pinned.isFenced(fileID) {
                state = .notIndexed
                issues.append(.seedFenced(fileID))
            } else if snapshot.nodesByFileID[fileID] != nil {
                state = .covered
                usableSeedIDs.append(fileID)
            } else if let slot {
                switch slot.state {
                case .pending:
                    state = .pending
                    issues.append(.seedPending(fileID))
                case .terminalExcluded:
                    state = .excluded
                    issues.append(.seedExcluded(fileID))
                case .terminalArtifact:
                    state = .notIndexed
                    issues.append(.seedNotIndexed(fileID))
                case .contributed, .empty:
                    state = .notIndexed
                    issues.append(.seedNotIndexed(fileID))
                }
            } else {
                state = .notIndexed
                issues.append(.seedNotIndexed(fileID))
            }
            seeds.append(WorkspaceCodemapGraphStructureSeed(
                fileID: fileID,
                standardizedRelativePath: path,
                state: state
            ))
        }

        if case .updatesPending = pinned.freshness { issues.append(.updatesPending) }
        if pinned.reconciling { issues.append(.watcherGapReconciling) }
        if !snapshot.coverage.isComplete { issues.append(.indexing) }

        guard !usableSeedIDs.isEmpty else {
            let hasPending = seeds.contains { $0.state == .pending } || !snapshot.coverage.isComplete
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: hasPending ? .pending : .unavailable,
                coverage: snapshot.coverage,
                updatesPending: pinned.freshness != .current,
                reconciling: pinned.reconciling,
                receipt: pinned.receipt,
                seeds: seeds,
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: issues
            )
        }

        let (deadlineDelta, deadlineOverflow) = graphPolicy.requestDeadlineMilliseconds
            .multipliedReportingOverflow(by: 1_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let (candidateDeadline, deadlineAdditionOverflow) = now.addingReportingOverflow(deadlineDelta)
        let deadline = deadlineOverflow || deadlineAdditionOverflow ? UInt64.max : candidateDeadline
        let maximumDepth = query.direction == nil ? 0 : query.maximumDepth
        var nodesByFileID: [UUID: WorkspaceCodemapGraphStructureNode] = [:]
        var queue: [UUID] = []
        var queueIndex = 0
        var graphBytes: UInt64 = 0
        var droppedNodeCount = 0
        var truncated = false
        var deadlineReached = false

        func nodeByteCount(_ node: WorkspaceCodemapGraphSnapshotNode) -> UInt64? {
            guard let pathBytes = UInt64(exactly: node.standardizedRelativePath.utf8.count) else { return nil }
            let (value, overflow) = pathBytes.addingReportingOverflow(96)
            return overflow ? nil : value
        }

        for fileID in usableSeedIDs {
            guard let snapshotNode = snapshot.nodesByFileID[fileID],
                  !pinned.isFenced(fileID)
            else { continue }
            guard nodesByFileID.count < query.budget.maximumNodeCount,
                  let nodeBytes = nodeByteCount(snapshotNode),
                  graphBytes <= query.budget.maximumGraphByteCount,
                  nodeBytes <= query.budget.maximumGraphByteCount - graphBytes
            else {
                droppedNodeCount += 1
                truncated = true
                continue
            }
            graphBytes += nodeBytes
            nodesByFileID[fileID] = WorkspaceCodemapGraphStructureNode(
                fileID: fileID,
                standardizedRelativePath: snapshotNode.standardizedRelativePath,
                depth: 0,
                isSeed: true,
                reachedBy: []
            )
            queue.append(fileID)
        }

        var emittedEdges = Set<WorkspaceCodemapGraphStructureEdge>()
        traversal: while queueIndex < queue.count {
            try Task.checkCancellation()
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                deadlineReached = true
                break
            }
            let currentID = queue[queueIndex]
            queueIndex += 1
            guard let currentNode = nodesByFileID[currentID], currentNode.depth < maximumDepth else { continue }

            var neighbors: [(evidence: WorkspaceCodemapGraphEdgeEvidence, fileID: UUID, reachedBy: WorkspaceCodemapStructureTraversalReachDirection)] = []
            switch query.direction {
            case .none:
                break
            case .referencedDefinitions:
                neighbors = (snapshot.outgoingEdgesBySource[currentID] ?? []).map {
                    ($0, $0.targetFileID, .referencedDefinitions)
                }
            case .referrers:
                neighbors = snapshot.reverseEdges(target: currentID).map {
                    ($0, $0.sourceFileID, .referrers)
                }
            case .both:
                neighbors = (snapshot.outgoingEdgesBySource[currentID] ?? []).map {
                    ($0, $0.targetFileID, .referencedDefinitions)
                } + snapshot.reverseEdges(target: currentID).map {
                    ($0, $0.sourceFileID, .referrers)
                }
            }
            neighbors.sort { lhs, rhs in
                if lhs.fileID != rhs.fileID {
                    return Self.fileIDPrecedes(lhs.fileID, rhs.fileID, snapshot: snapshot)
                }
                if lhs.reachedBy != rhs.reachedBy {
                    return lhs.reachedBy.rawValue < rhs.reachedBy.rawValue
                }
                return Self.edgePrecedes(lhs.evidence, rhs.evidence, nodes: snapshot.nodesByFileID)
            }

            for neighbor in neighbors {
                try Task.checkCancellation()
                guard !pinned.isFenced(neighbor.fileID),
                      !pinned.isFenced(neighbor.evidence.sourceFileID),
                      !pinned.isFenced(neighbor.evidence.targetFileID),
                      let snapshotNode = snapshot.nodesByFileID[neighbor.fileID]
                else { continue }

                let nextDepth = currentNode.depth + 1
                if let existing = nodesByFileID[neighbor.fileID] {
                    if existing.depth == nextDepth, !existing.reachedBy.contains(neighbor.reachedBy) {
                        var reachedBy = existing.reachedBy
                        reachedBy.insert(neighbor.reachedBy)
                        nodesByFileID[neighbor.fileID] = WorkspaceCodemapGraphStructureNode(
                            fileID: existing.fileID,
                            standardizedRelativePath: existing.standardizedRelativePath,
                            depth: existing.depth,
                            isSeed: existing.isSeed,
                            reachedBy: reachedBy
                        )
                    }
                } else {
                    guard nodesByFileID.count < query.budget.maximumNodeCount,
                          let nodeBytes = nodeByteCount(snapshotNode),
                          graphBytes <= query.budget.maximumGraphByteCount,
                          nodeBytes <= query.budget.maximumGraphByteCount - graphBytes
                    else {
                        droppedNodeCount += 1
                        truncated = true
                        break traversal
                    }
                    graphBytes += nodeBytes
                    nodesByFileID[neighbor.fileID] = WorkspaceCodemapGraphStructureNode(
                        fileID: neighbor.fileID,
                        standardizedRelativePath: snapshotNode.standardizedRelativePath,
                        depth: nextDepth,
                        isSeed: false,
                        reachedBy: [neighbor.reachedBy]
                    )
                    queue.append(neighbor.fileID)
                }

                let edge = WorkspaceCodemapGraphStructureEdge(
                    sourceFileID: neighbor.evidence.sourceFileID,
                    targetFileID: neighbor.evidence.targetFileID,
                    symbols: neighbor.evidence.matchedNames,
                    ambiguous: neighbor.evidence.ambiguous
                )
                if !emittedEdges.contains(edge) {
                    let symbolBytes = edge.symbols.reduce(0) { $0 + $1.utf8.count }
                    guard emittedEdges.count < query.budget.maximumEdgeCount,
                          let payloadBytes = UInt64(exactly: 128 + symbolBytes),
                          graphBytes <= query.budget.maximumGraphByteCount,
                          payloadBytes <= query.budget.maximumGraphByteCount - graphBytes
                    else {
                        truncated = true
                        break traversal
                    }
                    graphBytes += payloadBytes
                    emittedEdges.insert(edge)
                }
            }
        }

        let orderedNodes = nodesByFileID.values.sorted {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.standardizedRelativePath != $1.standardizedRelativePath {
                return Self.utf8Precedes($0.standardizedRelativePath, $1.standardizedRelativePath)
            }
            return $0.fileID.uuidString < $1.fileID.uuidString
        }
        let orderedEdges = emittedEdges.sorted {
            let leftSource = snapshot.nodesByFileID[$0.sourceFileID]?.standardizedRelativePath ?? ""
            let rightSource = snapshot.nodesByFileID[$1.sourceFileID]?.standardizedRelativePath ?? ""
            if leftSource != rightSource { return Self.utf8Precedes(leftSource, rightSource) }
            let leftTarget = snapshot.nodesByFileID[$0.targetFileID]?.standardizedRelativePath ?? ""
            let rightTarget = snapshot.nodesByFileID[$1.targetFileID]?.standardizedRelativePath ?? ""
            if leftTarget != rightTarget { return Self.utf8Precedes(leftTarget, rightTarget) }
            return $0.symbols.lexicographicallyPrecedes($1.symbols, by: Self.utf8Precedes)
        }
        let visitedIDs = Set(nodesByFileID.keys)
        var unresolved: [WorkspaceCodemapGraphStructureUnresolved] = []
        for sourceID in visitedIDs.sorted(by: { Self.fileIDPrecedes($0, $1, snapshot: snapshot) }) {
            for record in snapshot.unresolvedBySource[sourceID] ?? [] {
                unresolved.append(WorkspaceCodemapGraphStructureUnresolved(
                    sourceFileID: sourceID,
                    referencedName: record.referencedName,
                    reason: record.reason
                ))
            }
        }
        unresolved.sort { lhs, rhs in
            if lhs.sourceFileID != rhs.sourceFileID {
                return Self.fileIDPrecedes(lhs.sourceFileID, rhs.sourceFileID, snapshot: snapshot)
            }
            if lhs.referencedName != rhs.referencedName {
                return Self.utf8Precedes(lhs.referencedName, rhs.referencedName)
            }
            return String(describing: lhs.reason) < String(describing: rhs.reason)
        }

        if truncated { issues.append(.sizeLimit) }
        if deadlineReached { issues.append(.deadline) }
        let hasPartialIssue = !issues.isEmpty || unresolved.contains { $0.reason == .notIndexedYet }
        return WorkspaceCodemapGraphStructureRootResult(
            rootEpoch: rootEpoch,
            status: hasPartialIssue ? .partial : .ok,
            coverage: snapshot.coverage,
            updatesPending: pinned.freshness != .current,
            reconciling: pinned.reconciling,
            receipt: pinned.receipt,
            seeds: seeds,
            nodes: orderedNodes,
            edges: orderedEdges,
            unresolved: unresolved,
            truncation: truncated ? WorkspaceCodemapGraphStructureTruncation(
                droppedNodeCount: droppedNodeCount
            ) : nil,
            issues: issues
        )
    }

    func fenceFiles(
        fileIDs: Set<UUID>,
        reason: WorkspaceCodemapGraphFenceReason
    ) -> WorkspaceCodemapGraphFenceDisposition {
        guard let repositoryAuthority else { return .rejected(.repositoryAuthorityMismatch) }
        return fenceFiles(authority: repositoryAuthority, fileIDs: fileIDs, reason: reason)
    }

    func fenceFiles(
        authority: WorkspaceCodemapRepositoryAuthorityToken,
        fileIDs: Set<UUID>,
        reason _: WorkspaceCodemapGraphFenceReason
    ) -> WorkspaceCodemapGraphFenceDisposition {
        guard !fileIDs.isEmpty else { return .rejected(.emptyFileIDs) }
        guard let currentAuthority = repositoryAuthority else {
            return .rejected(.repositoryAuthorityMismatch)
        }
        guard currentAuthority == authority else { return .rejected(.repositoryAuthorityMismatch) }
        let requestedIdentities = Set(fileIDs.compactMap { fileID -> WorkspaceCodemapGraphFenceIdentity? in
            let currentSlot = committedSnapshot?.slotsByFileID[fileID]
            if currentSlot == nil, fenceIdentities.contains(where: { $0.fileID == fileID }) {
                return nil
            }
            return WorkspaceCodemapGraphFenceIdentity(fileID: fileID, slot: currentSlot)
        })
        let newFenceIdentities = requestedIdentities.subtracting(fenceIdentities)
        var derivationVisits: UInt64 = 0
        let snapshot = committedSnapshot
        guard var fenceBuilder = derivedFenceBuilder(addingIdentityCount: newFenceIdentities.count),
              newFenceIdentities.allSatisfy({
                  Self.deriveFences(for: $0, in: snapshot, into: &fenceBuilder, visits: &derivationVisits)
              })
        else {
            revoke(.fenceCapacityExceeded)
            return .revoked(.fenceCapacityExceeded)
        }
        let newDerivedFences = fenceBuilder.added
        guard !newFenceIdentities.isEmpty else { return .fenced(safetyCounter: safetyCounter) }
        let (nextCounter, overflow) = safetyCounter.addingReportingOverflow(1)
        guard !overflow else {
            revoke(.safetyCounterExhausted)
            return .revoked(.safetyCounterExhausted)
        }
        fenceIdentities.formUnion(newFenceIdentities)
        derivedFences.formUnion(newDerivedFences)
        safetyCounter = nextCounter
        publishAccounting()
        return .fenced(safetyCounter: safetyCounter)
    }

    func revalidate(
        _ receipt: WorkspaceCodemapGraphSnapshotReceipt,
        affectedFileIDs: Set<UUID>
    ) -> WorkspaceCodemapGraphReceiptDisposition {
        defer { publishAccounting() }
        receiptValidationCount &+= 1
        if let revocationReason {
            receiptRejectionCount &+= 1
            return .revoked(revocationReason)
        }
        guard receipt.rootEpoch == rootEpoch else {
            receiptRejectionCount &+= 1
            return .invalid(.rootEpochMismatch)
        }
        guard receipt.repositoryAuthority == repositoryAuthority else {
            receiptRejectionCount &+= 1
            return .invalid(.repositoryAuthorityMismatch)
        }
        guard receipt.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion else {
            receiptRejectionCount &+= 1
            return .invalid(.schemaMismatch)
        }
        guard receipt.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion else {
            receiptRejectionCount &+= 1
            return .invalid(.policyMismatch)
        }
        let fencedIdentityFileIDs = Set(fenceIdentities.map(\.fileID)).union(derivedFences.map(\.dependentFileID))
        if receipt.safetyCounter != safetyCounter,
           !affectedFileIDs.isDisjoint(with: fencedIdentityFileIDs)
        {
            receiptRejectionCount &+= 1
            return .invalid(.fencedFileOverlap)
        }
        let freshness: WorkspaceCodemapGraphSnapshotFreshness = observedGeneration > appliedGeneration
            ? .updatesPending(observedGeneration: observedGeneration)
            : .current
        return .valid(freshness)
    }

    /// A builder for the derived fences that accompany `count` new fence identities, or nil when the
    /// identities alone exceed the fence capacity.
    private func derivedFenceBuilder(addingIdentityCount count: Int) -> DerivedFenceBuilder? {
        DerivedFenceBuilder(
            existing: derivedFences,
            capacity: graphPolicy.maximumFencedFileIDCount - fenceIdentities.count - derivedFences.count - count
        )
    }

    /// Fences the files whose child references bind through a Terraform call the fenced file declares
    /// in `snapshot`, the snapshot `identity` was captured from. The derivation is one level deep.
    /// Every dependent examined is a visit. Returns false when the fences exceed the capacity.
    private static func deriveFences(
        for identity: WorkspaceCodemapGraphFenceIdentity,
        in snapshot: WorkspaceCodemapGraphCommittedSnapshot?,
        into fences: inout DerivedFenceBuilder,
        visits: inout UInt64
    ) -> Bool {
        guard let snapshot,
              let node = snapshot.nodesByFileID[identity.fileID],
              let facts = terraformFacts(
                  path: node.standardizedRelativePath,
                  contribution: node.contribution,
                  visits: &visits
              )
        else { return true }
        for key in WorkspaceTerraformCodeMapGraphProjection.callBindings(facts: facts).keys {
            for dependent in snapshot.terraformCallDependents[key] ?? [] {
                visits &+= 1
                guard dependent != identity.fileID else { continue }
                guard fences.insert(WorkspaceCodemapGraphDerivedFence(dependentFileID: dependent, parent: identity))
                else { return false }
            }
        }
        return true
    }

    /// A commit can give a file links through a call declaration whose file is still fenced: every
    /// subscriber of a call whose declarations changed, such as one a pending call file just
    /// resolved, and every new subscriber. Those files are fenced too. Every declaration and every
    /// dependent and parent pair examined is a visit. Returns false when the fences exceed the capacity.
    private func deriveFencesForCallChanges(
        _ candidate: CandidateBuild,
        into fences: inout DerivedFenceBuilder,
        visits: inout UInt64
    ) -> Bool {
        guard !fenceIdentities.isEmpty else { return true }
        let snapshot = candidate.snapshot
        func fence(_ dependents: some Sequence<UUID>, of key: TerraformCallKey) -> Bool {
            guard let bindings = snapshot.terraformCallsByKey[key] else { return true }
            var parents: [WorkspaceCodemapGraphFenceIdentity] = []
            for declaringFileID in bindings.keys {
                visits &+= 1
                parents += liveFenceIdentities(of: declaringFileID, in: snapshot)
            }
            guard !parents.isEmpty else { return true }
            for dependent in dependents {
                for parent in parents {
                    visits &+= 1
                    guard parent.fileID != dependent else { continue }
                    guard fences.insert(WorkspaceCodemapGraphDerivedFence(dependentFileID: dependent, parent: parent))
                    else { return false }
                }
            }
            return true
        }
        for key in candidate.changedCallKeys {
            guard fence(snapshot.terraformCallDependents[key] ?? [], of: key) else { return false }
        }
        for (dependent, keys) in candidate.addedCallSubscriptions {
            for key in keys {
                guard fence([dependent], of: key) else { return false }
            }
        }
        return true
    }

    /// The fence identities that still cover `fileID` in `snapshot`. An identity covers the file when
    /// it was captured from the file's current slot, or while the file had no slot. Two set lookups
    /// find both, so the cost doesn't depend on how many other files are fenced.
    private func liveFenceIdentities(
        of fileID: UUID,
        in snapshot: WorkspaceCodemapGraphCommittedSnapshot
    ) -> [WorkspaceCodemapGraphFenceIdentity] {
        let slot = snapshot.slotsByFileID[fileID]
        var candidates = [WorkspaceCodemapGraphFenceIdentity(fileID: fileID, slot: slot)]
        if slot != nil {
            candidates.append(WorkspaceCodemapGraphFenceIdentity(fileID: fileID, slot: nil))
        }
        return candidates.filter(fenceIdentities.contains)
    }

    func beginWatcherGapReconciliation() -> WorkspaceCodemapGraphReconciliationDisposition {
        guard let repositoryAuthority else { return .revoked(.repositoryAuthorityChanged) }
        return beginWatcherGapReconciliation(authority: repositoryAuthority)
    }

    func beginWatcherGapReconciliation(
        authority: WorkspaceCodemapRepositoryAuthorityToken
    ) -> WorkspaceCodemapGraphReconciliationDisposition {
        if let revocationReason { return .revoked(revocationReason) }
        guard repositoryAuthority == authority else {
            revoke(.repositoryAuthorityChanged)
            return .revoked(.repositoryAuthorityChanged)
        }
        if reconciling {
            reconciliationNeedsFollowingPass = true
            reconciliationCoalescedCount &+= 1
            publishAccounting()
            return .coalesced(attempt: reconciliationAttempt)
        }
        reconciling = true
        reconciliationAttempt = 1
        reconciliationStartedCount &+= 1
        reconciliationStartedUptimeNanoseconds = uptimeNanoseconds()
        scheduleReconciliationDeadline()
        publishAccounting()
        return .started(attempt: reconciliationAttempt)
    }

    func recordWatcherGapReconciliationFailure() -> WorkspaceCodemapGraphReconciliationDisposition {
        guard let repositoryAuthority else { return .revoked(.repositoryAuthorityChanged) }
        return recordWatcherGapReconciliationFailure(authority: repositoryAuthority)
    }

    func recordWatcherGapReconciliationFailure(
        authority: WorkspaceCodemapRepositoryAuthorityToken
    ) -> WorkspaceCodemapGraphReconciliationDisposition {
        if let revocationReason { return .revoked(revocationReason) }
        guard repositoryAuthority == authority else {
            revoke(.repositoryAuthorityChanged)
            return .revoked(.repositoryAuthorityChanged)
        }
        if !reconciling {
            reconciling = true
            reconciliationAttempt = 1
            reconciliationStartedUptimeNanoseconds = uptimeNanoseconds()
            reconciliationStartedCount &+= 1
            scheduleReconciliationDeadline()
        } else {
            reconciliationAttempt += 1
            reconciliationRetryCount &+= 1
        }
        let elapsedMilliseconds: UInt64 = reconciliationStartedUptimeNanoseconds.map { started in
            let now = uptimeNanoseconds()
            return now >= started ? (now - started) / 1_000_000 : 0
        } ?? 0
        if reconciliationAttempt >= graphPolicy.maximumReconciliationAttemptCount ||
            elapsedMilliseconds >= graphPolicy.maximumReconciliationWallClockMilliseconds
        {
            reconciliationRevokedCount &+= 1
            revoke(.reconciliationFailed)
            return .revoked(.reconciliationFailed)
        }
        publishAccounting()
        return .failedRetryable(attempt: reconciliationAttempt)
    }

    func incrementalAccounting() -> WorkspaceCodemapGraphIncrementalAccounting {
        let reconciliationDeadline = reconciliationStartedUptimeNanoseconds.flatMap { started in
            let milliseconds = graphPolicy.maximumReconciliationWallClockMilliseconds
            let (nanoseconds, multiplyOverflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
            let (deadline, addOverflow) = started.addingReportingOverflow(nanoseconds)
            return multiplyOverflow || addOverflow ? UInt64.max : deadline
        }
        return WorkspaceCodemapGraphIncrementalAccounting(
            graphRevision: graphRevision,
            coverage: committedSnapshot?.coverage,
            appliedGeneration: appliedGeneration,
            observedGeneration: observedGeneration,
            safetyCounter: safetyCounter,
            fencedFileCount: fenceIdentities.count + derivedFences.count,
            updatesPending: observedGeneration > appliedGeneration,
            reconciling: reconciling,
            reconciliationAttempt: reconciling ? reconciliationAttempt : nil,
            reconciliationDeadlineUptimeNanoseconds: reconciliationDeadline,
            activeApply: activeApply,
            successfulCommitCount: successfulCommitCount,
            resyncCommitCount: resyncCommitCount,
            rejectedApplyCount: rejectedApplyCount,
            lastCommittedUptimeNanoseconds: lastCommittedUptimeNanoseconds,
            lastCommitIntervalMilliseconds: lastCommitIntervalMilliseconds,
            revocationReason: revocationReason,
            diffPullCount: diffPullCount,
            resyncPullCount: resyncPullCount,
            revokedPullCount: revokedPullCount,
            lastChangedFileCount: lastChangedFileCount,
            lastAffectedSourceCount: lastAffectedSourceCount,
            totalChangedFileCount: totalChangedFileCount,
            totalAffectedSourceCount: totalAffectedSourceCount,
            currentQueryCount: currentQueryCount,
            pendingQueryCount: pendingQueryCount,
            partialCoverageQueryCount: partialCoverageQueryCount,
            reconciliationStartedCount: reconciliationStartedCount,
            reconciliationCoalescedCount: reconciliationCoalescedCount,
            reconciliationCommittedCount: reconciliationCommittedCount,
            reconciliationRetryCount: reconciliationRetryCount,
            reconciliationRevokedCount: reconciliationRevokedCount,
            receiptValidationCount: receiptValidationCount,
            receiptRejectionCount: receiptRejectionCount,
            lastApplyDurationMilliseconds: lastApplyDurationMilliseconds,
            maximumApplyDurationMilliseconds: maximumApplyDurationMilliseconds,
            highFanoutApplyCount: highFanoutApplyCount,
            lastCandidateComparisonCount: lastCandidateComparisonCount,
            lastCandidateVisitCount: lastCandidateVisitCount,
            maximumDiffCandidateVisitCount: maximumDiffCandidateVisitCount,
            lastCandidateCopiedEntryCount: lastCandidateCopiedEntryCount,
            maximumDiffCandidateCopiedEntryCount: maximumDiffCandidateCopiedEntryCount,
            totalCandidateCopiedEntryCount: totalCandidateCopiedEntryCount,
            totalCandidateComparisonCount: totalCandidateComparisonCount,
            totalCandidateVisitCount: totalCandidateVisitCount,
            totalApplyDurationMilliseconds: totalApplyDurationMilliseconds,
            observedToAppliedGenerationLag: observedGeneration.rawValue >= appliedGeneration.rawValue
                ? observedGeneration.rawValue - appliedGeneration.rawValue
                : 0
        )
    }

    func statusUpdates() -> AsyncStream<WorkspaceCodemapGraphIncrementalAccounting> {
        let id = UUID()
        return AsyncStream<WorkspaceCodemapGraphIncrementalAccounting>(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            statusContinuations[id] = continuation
            continuation.yield(incrementalAccounting())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeStatusContinuation(id) }
            }
        }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    private func publishAccounting() {
        let accounting = incrementalAccounting()
        for continuation in statusContinuations.values {
            continuation.yield(accounting)
        }
    }

    #if DEBUG
        func hasActiveCandidateBuildForTesting() -> Bool {
            activeCandidateTask != nil
        }

        /// The sources the last commit re-resolved.
        func lastAffectedSourceIDsForTesting() -> Set<UUID> {
            debugLastAffectedSourceIDs
        }
    #endif

    func shutdown(reason: WorkspaceCodemapGraphRevocationReason = .rootUnloaded) async {
        shuttingDown = true
        revoke(reason)
        if let activeCandidateTask {
            activeCandidateTask.cancel()
            await activeCandidateTask.value
            self.activeCandidateTask = nil
        }
    }

    private func acquireApplyLane() async {
        while activeApply {
            await withCheckedContinuation { applyWaiters.append($0) }
        }
        activeApply = true
        publishAccounting()
    }

    private func releaseApplyLane() {
        activeApply = false
        publishAccounting()
        let waiters = applyWaiters
        applyWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func revoke(_ reason: WorkspaceCodemapGraphRevocationReason) {
        revocationReason = reason
        reconciling = false
        cancelReconciliationDeadline()
        activeCandidateTask?.cancel()
        publishAccounting()
    }

    private func recordQuery(_ pinned: WorkspaceCodemapGraphPinnedSnapshot) {
        defer { publishAccounting() }
        switch pinned.freshness {
        case .current: currentQueryCount &+= 1
        case .updatesPending: pendingQueryCount &+= 1
        }
        if !pinned.snapshot.coverage.isComplete { partialCoverageQueryCount &+= 1 }
    }

    private func recordApplyDuration() {
        guard let started = applyStartedUptimeNanoseconds else { return }
        let finished = uptimeNanoseconds()
        let duration = finished >= started ? (finished - started) / 1_000_000 : 0
        lastApplyDurationMilliseconds = duration
        maximumApplyDurationMilliseconds = max(maximumApplyDurationMilliseconds ?? 0, duration)
        totalApplyDurationMilliseconds &+= duration
        applyStartedUptimeNanoseconds = nil
    }

    private func scheduleReconciliationDeadline() {
        cancelReconciliationDeadline()
        let cycleID = UUID()
        reconciliationCycleID = cycleID
        let milliseconds = graphPolicy.maximumReconciliationWallClockMilliseconds
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let wait = overflow ? UInt64.max : nanoseconds
        reconciliationDeadlineTask = Task { [weak self, reconciliationWaiter] in
            await reconciliationWaiter(wait)
            guard !Task.isCancelled else { return }
            await self?.expireReconciliation(cycleID: cycleID)
        }
    }

    private func cancelReconciliationDeadline() {
        reconciliationDeadlineTask?.cancel()
        reconciliationDeadlineTask = nil
        reconciliationCycleID = nil
    }

    private func expireReconciliation(cycleID: UUID) async {
        guard reconciling, reconciliationCycleID == cycleID, revocationReason == nil else { return }
        reconciliationRevokedCount &+= 1
        revoke(.reconciliationFailed)
        await reconciliationExpiryHandler?()
    }

    // MARK: - Candidate construction

    /// Accumulates the retained-size delta of a diff. The size model is additive per retained
    /// item, so a diff only prices the items it removes and inserts.
    private struct CandidateSizeDelta {
        var removedBytes: UInt64 = 0
        var addedBytes: UInt64 = 0
        var removedPostings: UInt64 = 0
        var addedPostings: UInt64 = 0
        var removedEdges: UInt64 = 0
        var addedEdges: UInt64 = 0
        var overflow = false

        mutating func remove(bytes: UInt64?) {
            guard let next = WorkspaceCodemapSelectionGraph.checkedAdd(removedBytes, bytes) else {
                overflow = true
                return
            }
            removedBytes = next
        }

        mutating func add(bytes: UInt64?) {
            guard let next = WorkspaceCodemapSelectionGraph.checkedAdd(addedBytes, bytes) else {
                overflow = true
                return
            }
            addedBytes = next
        }
    }

    private enum CandidateSizeOutcome {
        case size(WorkspaceCodemapGraphSizeAccounting)
        case overflow
        case cancelled
    }

    private static func makeCandidate(
        base: WorkspaceCodemapGraphCommittedSnapshot?,
        changedSlots: [WorkspaceCodemapGraphSlot],
        removed: [WorkspaceCodemapGraphRemoval],
        rootEpoch: WorkspaceCodemapRootEpoch,
        authority: WorkspaceCodemapRepositoryAuthorityToken,
        watermark: WorkspaceCodemapGraphIndexCatalogToken,
        coverage: WorkspaceCodemapGraphCatalogCoverage,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32,
        nextRevision: UInt64,
        graphPolicy: WorkspaceCodemapGraphPolicy,
        resync: Bool
    ) -> CandidateBuildOutcome {
        guard !Task.isCancelled else { return .cancelled }
        // A resync rebuilds from the checkpoint alone. A diff derives the next snapshot from the
        // base through persistent storage: every map update copies only its trie path, and every
        // step below is bounded by the diff and the postings/edges it reaches. The base snapshot
        // (possibly pinned by readers) is never mutated.
        let incrementalBase = resync ? nil : base
        let oldSlots = incrementalBase?.slotsByFileID ?? PersistentHashMap()
        var slots = oldSlots
        var comparisons: UInt64 = 0
        var visits: UInt64 = 0
        var copies: UInt64 = 0
        var candidateIDs = Set<UUID>()
        candidateIDs.reserveCapacity(removed.count + changedSlots.count)
        for removal in removed {
            guard !Task.isCancelled else { return .cancelled }
            slots.removeValue(forKey: removal.fileID)
            candidateIDs.insert(removal.fileID)
        }
        for slot in changedSlots {
            guard !Task.isCancelled else { return .cancelled }
            slots[slot.fileID] = slot
            candidateIDs.insert(slot.fileID)
        }
        visits &+= UInt64(candidateIDs.count)
        let changedIDs = candidateIDs.filter { oldSlots[$0] != slots[$0] }

        let baseNodes = incrementalBase?.nodesByFileID ?? PersistentHashMap()
        let baseDefinitions = incrementalBase?.definitionPostings ?? PersistentHashMap()
        let baseReferences = incrementalBase?.referencePostings ?? PersistentHashMap()
        let baseCalls = incrementalBase?.terraformCallsByKey ?? PersistentHashMap()
        let baseCallDependents = incrementalBase?.terraformCallDependents ?? PersistentHashMap()
        var nodes = baseNodes
        var definitions = baseDefinitions
        var references = baseReferences
        var outgoing = incrementalBase?.outgoingEdgesBySource ?? PersistentHashMap()
        var reverse = incrementalBase?.reverseEdgesByTarget ?? PersistentHashMap()
        var unresolved = incrementalBase?.unresolvedBySource ?? PersistentHashMap()
        var calls = baseCalls
        var callDependents = baseCallDependents

        guard let terraform = prepareTerraformCandidate(
            changedIDs: changedIDs,
            baseNodes: baseNodes,
            slots: slots,
            calls: &calls,
            callDependents: &callDependents,
            visits: &visits,
            copies: &copies
        ) else { return .cancelled }
        let terraformFactsByFileID = terraform.factsByFileID
        let changedCallKeys = terraform.changedCallKeys
        let changedDependentKeys = terraform.changedDependentKeys
        let addedCallSubscriptions = terraform.addedCallSubscriptions
        let finalCalls = terraform.finalCalls
        let subscriberIDs = terraform.subscriberIDs
        typealias Projection = WorkspaceTerraformCodeMapGraphProjection
        func projection(_ fileID: UUID, _ facts: Projection.Facts) -> WorkspaceCodemapGraphNodeProjection {
            visits &+= UInt64(facts.definitions.count + facts.references.count)
            return Projection.projection(
                fileID: fileID,
                facts: facts,
                candidateOverflowThreshold: graphPolicy.candidateOverflowThreshold,
                bindings: { finalCalls[$0] },
                comparisons: &comparisons
            )
        }

        var changedDefinitionNames = Set<String>()
        var changedReferenceNames = Set<String>()
        var removedDefinitionIDsByName: [String: [UUID]] = [:]
        var removedReferenceIDsByName: [String: [UUID]] = [:]
        var insertedDefinitionIDsByName: [String: [UUID]] = [:]
        var insertedReferenceIDsByName: [String: [UUID]] = [:]
        for fileID in changedIDs {
            guard !Task.isCancelled else { return .cancelled }
            if let oldNode = nodes.removeValue(forKey: fileID) {
                for name in oldNode.definitionKeys {
                    changedDefinitionNames.insert(name)
                    removedDefinitionIDsByName[name, default: []].append(fileID)
                }
                for name in oldNode.referenceKeys {
                    changedReferenceNames.insert(name)
                    removedReferenceIDsByName[name, default: []].append(fileID)
                }
            }
            guard let slot = slots[fileID],
                  let node = snapshotNode(
                      from: slot,
                      projection: terraformFactsByFileID[fileID].map { projection(fileID, $0) }
                  )
            else { continue }
            nodes[fileID] = node
            for name in node.definitionKeys {
                changedDefinitionNames.insert(name)
                insertedDefinitionIDsByName[name, default: []].append(fileID)
            }
            for name in node.referenceKeys {
                changedReferenceNames.insert(name)
                insertedReferenceIDsByName[name, default: []].append(fileID)
            }
        }
        // A file's definitions don't depend on call bindings, so reprojecting an unchanged file
        // moves only the reference keys that differ.
        var reprojectedIDs = Set<UUID>()
        for fileID in subscriberIDs {
            guard !Task.isCancelled else { return .cancelled }
            guard let oldNode = nodes[fileID],
                  let facts = terraformFacts(
                      path: oldNode.standardizedRelativePath,
                      contribution: oldNode.contribution,
                      visits: &visits
                  )
            else { continue }
            let newProjection = projection(fileID, facts)
            guard newProjection != oldNode.projection else { continue }
            let node = WorkspaceCodemapGraphSnapshotNode(
                fileID: oldNode.fileID,
                standardizedRelativePath: oldNode.standardizedRelativePath,
                requestGeneration: oldNode.requestGeneration,
                pathGeneration: oldNode.pathGeneration,
                contribution: oldNode.contribution,
                projection: newProjection
            )
            nodes[fileID] = node
            reprojectedIDs.insert(fileID)
            let oldKeys = Set(oldNode.referenceKeys)
            let newKeys = Set(node.referenceKeys)
            visits &+= UInt64(oldKeys.count + newKeys.count)
            for name in oldKeys.subtracting(newKeys) {
                changedReferenceNames.insert(name)
                removedReferenceIDsByName[name, default: []].append(fileID)
            }
            for name in newKeys.subtracting(oldKeys) {
                changedReferenceNames.insert(name)
                insertedReferenceIDsByName[name, default: []].append(fileID)
            }
        }
        let finalNodes = nodes

        /// Posting sets are updated per changed ID; a hub name's set is never walked or copied whole.
        func updatePostings(
            _ postings: inout PersistentHashMap<String, PersistentHashSet<UUID>>,
            names: Set<String>,
            removedIDsByName: [String: [UUID]],
            insertedIDsByName: [String: [UUID]]
        ) -> Bool {
            for name in names {
                guard !Task.isCancelled else { return false }
                var set = postings[name] ?? []
                for fileID in removedIDsByName[name] ?? [] {
                    set.remove(fileID)
                    visits &+= 1
                }
                for fileID in insertedIDsByName[name] ?? [] {
                    set.insert(fileID)
                    visits &+= 1
                }
                copies &+= UInt64(set.takeCopiedEntryCount())
                if set.isEmpty {
                    postings.removeValue(forKey: name)
                } else {
                    postings[name] = set
                }
            }
            return true
        }
        guard updatePostings(
            &definitions,
            names: changedDefinitionNames,
            removedIDsByName: removedDefinitionIDsByName,
            insertedIDsByName: insertedDefinitionIDsByName
        ), updatePostings(
            &references,
            names: changedReferenceNames,
            removedIDsByName: removedReferenceIDsByName,
            insertedIDsByName: insertedReferenceIDsByName
        ) else { return .cancelled }

        // A source's evidence can change only when its own contribution or projection changed or a
        // definition candidate set it references changed. Referrers are enumerated from the postings,
        // which is inherent: a new definer of a name gains an edge from every referrer of that name.
        var affectedSources = changedIDs.union(reprojectedIDs)
        for name in changedDefinitionNames {
            for fileID in incrementalBase?.referencePostings[name] ?? [] {
                affectedSources.insert(fileID)
            }
            for fileID in references[name] ?? [] {
                affectedSources.insert(fileID)
            }
        }
        if incrementalBase?.coverage.isComplete != coverage.isComplete {
            // A completeness transition changes missing/not-indexed-yet evidence globally.
            for fileID in nodes.keys {
                affectedSources.insert(fileID)
            }
        }
        visits &+= UInt64(affectedSources.count)

        // Remove old evidence only for affected sources, including its reverse adjacency entries.
        var delta = CandidateSizeDelta()
        var removedSourcesByTarget: [UUID: [UUID]] = [:]
        for source in affectedSources {
            guard !Task.isCancelled else { return .cancelled }
            if let evidenceList = outgoing.removeValue(forKey: source) {
                delta.removedEdges &+= UInt64(evidenceList.count)
                visits &+= UInt64(evidenceList.count)
                for evidence in evidenceList {
                    removedSourcesByTarget[evidence.targetFileID, default: []].append(source)
                    // Each evidence value is retained by both adjacency directions.
                    delta.remove(bytes: evidenceBytes(evidence))
                    delta.remove(bytes: evidenceBytes(evidence))
                }
            }
            if let records = unresolved.removeValue(forKey: source) {
                visits &+= UInt64(records.count)
                for record in records {
                    delta.remove(bytes: unresolvedBytes(record))
                }
            }
        }
        for (target, sources) in removedSourcesByTarget {
            guard !Task.isCancelled else { return .cancelled }
            guard var bySource = reverse[target] else { continue }
            for source in sources {
                bySource.removeValue(forKey: source)
            }
            copies &+= UInt64(bySource.takeCopiedEntryCount())
            if bySource.isEmpty {
                reverse.removeValue(forKey: target)
            } else {
                reverse[target] = bySource
            }
        }

        // Re-resolve only sources whose own contribution or referenced definition candidates changed.
        let edgeOrder: (WorkspaceCodemapGraphEdgeEvidence, WorkspaceCodemapGraphEdgeEvidence) -> Bool = {
            edgePrecedes($0, $1, nodes: finalNodes)
        }
        var insertedEvidenceByTarget: [UUID: [WorkspaceCodemapGraphEdgeEvidence]] = [:]
        for source in affectedSources {
            guard !Task.isCancelled else { return .cancelled }
            guard let node = nodes[source] else { continue }
            var namesByTarget: [UUID: Set<String>] = [:]
            var candidateCountByTarget: [UUID: UInt64] = [:]
            var sourceUnresolved: [WorkspaceCodemapGraphUnresolvedRecord] = []
            /// Resolves the posting `key` and records `name` as the evidence. A nil key, a Terraform
            /// reference through a call nothing declares, resolves like an undefined name.
            func resolve(key: String?, name: String) {
                let candidates = key.flatMap { definitions[$0] } ?? []
                guard !candidates.isEmpty else {
                    sourceUnresolved.append(.init(
                        sourceFileID: source,
                        referencedName: name,
                        reason: coverage.isComplete ? .missing : .notIndexedYet
                    ))
                    return
                }
                guard candidates.count <= graphPolicy.candidateOverflowThreshold else {
                    sourceUnresolved.append(.init(
                        sourceFileID: source,
                        referencedName: name,
                        reason: .tooCommon
                    ))
                    return
                }
                visits &+= UInt64(candidates.count)
                let candidateCount = UInt64(candidates.count)
                for target in candidates {
                    namesByTarget[target, default: []].insert(name)
                    // A name with one definer proves the edge on its own, so the edge keeps the
                    // smallest candidate count among its matched names.
                    candidateCountByTarget[target] = min(candidateCountByTarget[target] ?? candidateCount, candidateCount)
                }
            }
            if let projection = node.projection {
                visits &+= UInt64(projection.references.count + projection.unresolved.count)
                for reference in projection.references {
                    resolve(key: reference.key, name: reference.evidence)
                }
                sourceUnresolved += projection.unresolved
            } else {
                visits &+= UInt64(node.contribution.sortedUniqueReferences.count)
                for name in node.contribution.sortedUniqueReferences {
                    resolve(key: name, name: name)
                }
            }
            var sourceEvidence: [WorkspaceCodemapGraphEdgeEvidence] = []
            sourceEvidence.reserveCapacity(namesByTarget.count)
            for (target, names) in namesByTarget {
                let count = candidateCountByTarget[target] ?? 0
                let evidence = WorkspaceCodemapGraphEdgeEvidence(
                    sourceFileID: source,
                    targetFileID: target,
                    matchedNames: names.sorted { lhs, rhs in
                        comparisons &+= 1
                        return utf8Precedes(lhs, rhs)
                    },
                    candidateCount: count,
                    ambiguous: count > 1
                )
                sourceEvidence.append(evidence)
                insertedEvidenceByTarget[target, default: []].append(evidence)
                delta.addedEdges &+= 1
                delta.add(bytes: evidenceBytes(evidence))
                delta.add(bytes: evidenceBytes(evidence))
            }
            if !sourceEvidence.isEmpty {
                sourceEvidence.sort { lhs, rhs in
                    comparisons &+= 1
                    return edgeOrder(lhs, rhs)
                }
                copies &+= UInt64(sourceEvidence.count)
                outgoing[source] = sourceEvidence
            }
            if !sourceUnresolved.isEmpty {
                // Referenced names are unique per source, so the name alone is a total order here;
                // the reason tie-break is retained for parity with historical snapshots.
                sourceUnresolved.sort {
                    comparisons &+= 1
                    if $0.referencedName != $1.referencedName {
                        return utf8Precedes($0.referencedName, $1.referencedName)
                    }
                    return String(describing: $0.reason) < String(describing: $1.reason)
                }
                for record in sourceUnresolved {
                    delta.add(bytes: unresolvedBytes(record))
                }
                copies &+= UInt64(sourceUnresolved.count)
                unresolved[source] = sourceUnresolved
            }
        }
        for (target, insertedEvidence) in insertedEvidenceByTarget {
            guard !Task.isCancelled else { return .cancelled }
            var bySource = reverse[target] ?? PersistentHashMap()
            for evidence in insertedEvidence {
                bySource[evidence.sourceFileID] = evidence
            }
            visits &+= UInt64(insertedEvidence.count)
            copies &+= UInt64(bySource.takeCopiedEntryCount())
            reverse[target] = bySource
        }

        // Price the diff. Node, slot, and posting deltas come from the changed IDs and names only.
        for fileID in changedIDs {
            if let old = baseNodes[fileID] { delta.remove(bytes: nodeBytes(old)) }
            if let new = nodes[fileID] { delta.add(bytes: nodeBytes(new)) }
            if let old = oldSlots[fileID] { delta.remove(bytes: slotBytes(old)) }
            if let new = slots[fileID] { delta.add(bytes: slotBytes(new)) }
        }
        for fileID in reprojectedIDs {
            if let old = baseNodes[fileID] { delta.remove(bytes: nodeBytes(old)) }
            if let new = nodes[fileID] { delta.add(bytes: nodeBytes(new)) }
        }
        // Each call declaration and subscription is one membership in the postings budget.
        for key in changedCallKeys {
            if let old = baseCalls[key] {
                delta.removedPostings &+= UInt64(old.count)
                delta.remove(bytes: callBindingBytes(key: key, bindings: old, visits: &visits))
            }
            if let new = calls[key] {
                delta.addedPostings &+= UInt64(new.count)
                delta.add(bytes: callBindingBytes(key: key, bindings: new, visits: &visits))
            }
        }
        for key in changedDependentKeys {
            if let old = baseCallDependents[key] {
                delta.removedPostings &+= UInt64(old.count)
                delta.remove(bytes: callKeyBytes(key, memberCount: old.count))
            }
            if let new = callDependents[key] {
                delta.addedPostings &+= UInt64(new.count)
                delta.add(bytes: callKeyBytes(key, memberCount: new.count))
            }
        }
        for name in changedDefinitionNames.union(changedReferenceNames) {
            let oldCount = (baseDefinitions[name]?.count ?? 0) + (baseReferences[name]?.count ?? 0)
            let newCount = (definitions[name]?.count ?? 0) + (references[name]?.count ?? 0)
            if oldCount > 0 {
                delta.removedPostings &+= UInt64(oldCount)
                delta.remove(bytes: postingBytes(name: name, fileIDCount: oldCount))
            }
            if newCount > 0 {
                delta.addedPostings &+= UInt64(newCount)
                delta.add(bytes: postingBytes(name: name, fileIDCount: newCount))
            }
        }

        let size: WorkspaceCodemapGraphSizeAccounting
        if let baseSize = incrementalBase?.sizeAccounting,
           let incremental = applying(delta, to: baseSize, nodeCount: nodes.count)
        {
            size = incremental
        } else {
            // Resyncs (and any inconsistent delta) recount the whole candidate conservatively.
            visits &+= UInt64(
                nodes.count + slots.count + definitions.count + references.count + calls.count + callDependents.count
            )
            switch fullSize(
                slots: slots,
                nodes: nodes,
                definitions: definitions,
                references: references,
                outgoing: outgoing,
                reverse: reverse,
                unresolved: unresolved,
                calls: calls,
                callDependents: callDependents,
                visits: &visits
            ) {
            case let .size(value): size = value
            case .overflow: return .failure(.accountingOverflow)
            case .cancelled: return .cancelled
            }
        }
        let limits = graphPolicy.graphSizePolicy
        if size.nodes > limits.maxNodes { return .failure(.graphSize(.limitExceeded(dimension: .nodes, attempted: size.nodes, limit: limits.maxNodes))) }
        if size.postings > limits.maxPostings { return .failure(.graphSize(.limitExceeded(dimension: .postings, attempted: size.postings, limit: limits.maxPostings))) }
        if size.edges > limits.maxEdges { return .failure(.graphSize(.limitExceeded(dimension: .edges, attempted: size.edges, limit: limits.maxEdges))) }
        if size.bytes > limits.maxBytes { return .failure(.graphSize(.limitExceeded(dimension: .bytes, attempted: size.bytes, limit: limits.maxBytes))) }

        // Account every trie entry the persistent maps copied or shifted for this candidate.
        copies &+= UInt64(slots.takeCopiedEntryCount())
        copies &+= UInt64(nodes.takeCopiedEntryCount())
        copies &+= UInt64(definitions.takeCopiedEntryCount())
        copies &+= UInt64(references.takeCopiedEntryCount())
        copies &+= UInt64(outgoing.takeCopiedEntryCount())
        copies &+= UInt64(reverse.takeCopiedEntryCount())
        copies &+= UInt64(unresolved.takeCopiedEntryCount())
        copies &+= UInt64(calls.takeCopiedEntryCount())
        copies &+= UInt64(callDependents.takeCopiedEntryCount())

        let snapshot = WorkspaceCodemapGraphCommittedSnapshot(
            snapshotID: UUID(),
            graphRevision: nextRevision,
            rootEpoch: rootEpoch,
            repositoryAuthority: authority,
            catalogWatermark: watermark,
            coverage: coverage,
            appliedGeneration: generation,
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            slotsByFileID: slots,
            nodesByFileID: nodes,
            definitionPostings: definitions,
            referencePostings: references,
            outgoingEdgesBySource: outgoing,
            reverseEdgesByTarget: reverse,
            unresolvedBySource: unresolved,
            terraformCallsByKey: calls,
            terraformCallDependents: callDependents,
            sizeAccounting: size
        )
        return .success(CandidateBuild(
            snapshot: snapshot,
            changedFileCount: changedIDs.count,
            affectedSourceIDs: affectedSources,
            resync: resync,
            comparisonCount: comparisons,
            visitCount: visits,
            copiedEntryCount: copies,
            changedCallKeys: changedCallKeys,
            addedCallSubscriptions: addedCallSubscriptions
        ))
    }

    /// The Terraform phase of a candidate build. Call bindings and subscriptions follow the changed raw
    /// contributions into `calls` and `callDependents`. A call key changes only when one of its
    /// declarations does, so a rename that keeps a file in its folder reprojects no subscriber. Returns
    /// the new facts of the changed files, the call keys whose bindings or subscribers changed, the
    /// complete binding index the projections read, and the unchanged files subscribed to a changed
    /// call, which the caller reprojects. Returns nil when the build is cancelled.
    private static func prepareTerraformCandidate(
        changedIDs: Set<UUID>,
        baseNodes: PersistentHashMap<UUID, WorkspaceCodemapGraphSnapshotNode>,
        slots: PersistentHashMap<UUID, WorkspaceCodemapGraphSlot>,
        calls: inout PersistentHashMap<TerraformCallKey, PersistentHashMap<UUID, TerraformCallBinding>>,
        callDependents: inout PersistentHashMap<TerraformCallKey, PersistentHashSet<UUID>>,
        visits: inout UInt64,
        copies: inout UInt64
    ) -> (
        factsByFileID: [UUID: WorkspaceTerraformCodeMapGraphProjection.Facts],
        changedCallKeys: Set<TerraformCallKey>,
        changedDependentKeys: Set<TerraformCallKey>,
        addedCallSubscriptions: [UUID: [TerraformCallKey]],
        finalCalls: PersistentHashMap<TerraformCallKey, PersistentHashMap<UUID, TerraformCallBinding>>,
        subscriberIDs: Set<UUID>
    )? {
        typealias Projection = WorkspaceTerraformCodeMapGraphProjection
        var factsByFileID: [UUID: Projection.Facts] = [:]
        var changedCallKeys = Set<TerraformCallKey>()
        var changedDependentKeys = Set<TerraformCallKey>()
        var addedCallSubscriptions: [UUID: [TerraformCallKey]] = [:]
        for fileID in changedIDs {
            guard !Task.isCancelled else { return nil }
            let oldFacts = baseNodes[fileID].flatMap {
                terraformFacts(path: $0.standardizedRelativePath, contribution: $0.contribution, visits: &visits)
            }
            let newFacts = slots[fileID].flatMap { slot in
                slot.state.contribution.flatMap {
                    terraformFacts(path: slot.standardizedRelativePath, contribution: $0, visits: &visits)
                }
            }
            guard oldFacts != nil || newFacts != nil else { continue }
            factsByFileID[fileID] = newFacts
            let oldBindings = oldFacts.map { Projection.callBindings(facts: $0) } ?? [:]
            let newBindings = newFacts.map { Projection.callBindings(facts: $0) } ?? [:]
            visits &+= UInt64(oldBindings.count + newBindings.count)
            for key in Set(oldBindings.keys).union(newBindings.keys) where oldBindings[key] != newBindings[key] {
                var bindings = calls[key] ?? PersistentHashMap()
                bindings[fileID] = newBindings[key]
                visits &+= 1
                copies &+= UInt64(bindings.takeCopiedEntryCount())
                calls[key] = bindings.isEmpty ? nil : bindings
                changedCallKeys.insert(key)
            }
            let oldDependencyKeys = Set(oldFacts.map(Projection.callDependencyKeys) ?? [])
            let newDependencyKeys = Set(newFacts.map(Projection.callDependencyKeys) ?? [])
            visits &+= UInt64(oldDependencyKeys.count + newDependencyKeys.count)
            for key in oldDependencyKeys.symmetricDifference(newDependencyKeys) {
                var members = callDependents[key] ?? []
                if newDependencyKeys.contains(key) {
                    members.insert(fileID)
                    addedCallSubscriptions[fileID, default: []].append(key)
                } else {
                    members.remove(fileID)
                }
                visits &+= 1
                copies &+= UInt64(members.takeCopiedEntryCount())
                callDependents[key] = members.isEmpty ? nil : members
                changedDependentKeys.insert(key)
            }
        }

        // Projections read the candidate's complete binding index, so an unchanged file whose call
        // changed is reprojected too. An unchanged file has the same subscriptions in the base and the
        // candidate, so the candidate's subscribers are both the old and the new ones.
        let finalCalls = calls
        var subscriberIDs = Set<UUID>()
        for key in changedCallKeys {
            let members = callDependents[key] ?? []
            visits &+= UInt64(members.count)
            for fileID in members where !changedIDs.contains(fileID) {
                subscriberIDs.insert(fileID)
            }
        }
        return (
            factsByFileID: factsByFileID,
            changedCallKeys: changedCallKeys,
            changedDependentKeys: changedDependentKeys,
            addedCallSubscriptions: addedCallSubscriptions,
            finalCalls: finalCalls,
            subscriberIDs: subscriberIDs
        )
    }

    /// Every walk over Terraform tuples or call-index memberships counts its items as visits before
    /// filtering. Work that grows with an index raises the bounded-work counters.
    private static func terraformFacts(
        path: String,
        contribution: CodeMapSelectionGraphContribution,
        visits: inout UInt64
    ) -> WorkspaceTerraformCodeMapGraphProjection.Facts? {
        guard let facts = WorkspaceTerraformCodeMapGraphProjection.facts(path: path, contribution: contribution) else {
            return nil
        }
        visits &+= UInt64(facts.definitions.count + facts.references.count)
        return facts
    }

    private static func applying(
        _ delta: CandidateSizeDelta,
        to base: WorkspaceCodemapGraphSizeAccounting,
        nodeCount: Int
    ) -> WorkspaceCodemapGraphSizeAccounting? {
        guard !delta.overflow,
              base.postings >= delta.removedPostings,
              base.edges >= delta.removedEdges,
              let postings = checkedAdd(base.postings - delta.removedPostings, delta.addedPostings),
              let edges = checkedAdd(base.edges - delta.removedEdges, delta.addedEdges),
              let removedEdgeBytes = checkedMultiply(delta.removedEdges, 96),
              let removedPostingBytes = checkedMultiply(delta.removedPostings, 24),
              let removedTotal = checkedAdd(checkedAdd(delta.removedBytes, removedEdgeBytes), removedPostingBytes),
              base.bytes >= removedTotal,
              let addedEdgeBytes = checkedMultiply(delta.addedEdges, 96),
              let addedPostingBytes = checkedMultiply(delta.addedPostings, 24),
              let addedTotal = checkedAdd(checkedAdd(delta.addedBytes, addedEdgeBytes), addedPostingBytes),
              let bytes = checkedAdd(base.bytes - removedTotal, addedTotal),
              let nodes = UInt64(exactly: nodeCount)
        else { return nil }
        return WorkspaceCodemapGraphSizeAccounting(nodes: nodes, postings: postings, edges: edges, bytes: bytes)
    }

    /// Conservative accounting for every retained immutable collection. Contributions appear in
    /// both slots and nodes by design, and both adjacency directions retain edge evidence.
    private static func fullSize(
        slots: PersistentHashMap<UUID, WorkspaceCodemapGraphSlot>,
        nodes: PersistentHashMap<UUID, WorkspaceCodemapGraphSnapshotNode>,
        definitions: PersistentHashMap<String, PersistentHashSet<UUID>>,
        references: PersistentHashMap<String, PersistentHashSet<UUID>>,
        outgoing: PersistentHashMap<UUID, [WorkspaceCodemapGraphEdgeEvidence]>,
        reverse: PersistentHashMap<UUID, PersistentHashMap<UUID, WorkspaceCodemapGraphEdgeEvidence>>,
        unresolved: PersistentHashMap<UUID, [WorkspaceCodemapGraphUnresolvedRecord]>,
        calls: PersistentHashMap<TerraformCallKey, PersistentHashMap<UUID, TerraformCallBinding>>,
        callDependents: PersistentHashMap<TerraformCallKey, PersistentHashSet<UUID>>,
        visits: inout UInt64
    ) -> CandidateSizeOutcome {
        var postingCount: UInt64 = 0
        var edgeCount: UInt64 = 0
        var byteCount: UInt64 = 0
        func charge(_ bytes: UInt64?) -> Bool {
            guard let next = checkedAdd(byteCount, bytes) else { return false }
            byteCount = next
            return true
        }
        func count(_ value: Int, into total: inout UInt64) -> Bool {
            guard let next = checkedAdd(total, UInt64(exactly: value)) else { return false }
            total = next
            return true
        }
        for node in nodes.values {
            guard !Task.isCancelled else { return .cancelled }
            guard charge(nodeBytes(node)) else { return .overflow }
        }
        for slot in slots.values {
            guard !Task.isCancelled else { return .cancelled }
            guard charge(slotBytes(slot)) else { return .overflow }
        }
        for (name, fileIDs) in definitions {
            guard !Task.isCancelled else { return .cancelled }
            let postingTotal = fileIDs.count + (references[name]?.count ?? 0)
            guard count(fileIDs.count, into: &postingCount),
                  charge(postingBytes(name: name, fileIDCount: postingTotal))
            else { return .overflow }
        }
        for (name, fileIDs) in references {
            guard !Task.isCancelled else { return .cancelled }
            guard count(fileIDs.count, into: &postingCount) else { return .overflow }
            guard definitions[name] == nil else { continue }
            guard charge(postingBytes(name: name, fileIDCount: fileIDs.count)) else { return .overflow }
        }
        for evidenceList in outgoing.values {
            guard !Task.isCancelled else { return .cancelled }
            guard count(evidenceList.count, into: &edgeCount) else { return .overflow }
            for evidence in evidenceList {
                guard charge(evidenceBytes(evidence)) else { return .overflow }
            }
        }
        for bySource in reverse.values {
            guard !Task.isCancelled else { return .cancelled }
            for evidence in bySource.values {
                guard charge(evidenceBytes(evidence)) else { return .overflow }
            }
        }
        for records in unresolved.values {
            guard !Task.isCancelled else { return .cancelled }
            for record in records {
                guard charge(unresolvedBytes(record)) else { return .overflow }
            }
        }
        for (key, bindings) in calls {
            guard !Task.isCancelled else { return .cancelled }
            guard count(bindings.count, into: &postingCount),
                  charge(callBindingBytes(key: key, bindings: bindings, visits: &visits))
            else { return .overflow }
        }
        for (key, members) in callDependents {
            guard !Task.isCancelled else { return .cancelled }
            guard count(members.count, into: &postingCount),
                  charge(callKeyBytes(key, memberCount: members.count))
            else { return .overflow }
        }
        guard charge(checkedMultiply(edgeCount, 96)),
              charge(checkedMultiply(postingCount, 24)),
              let nodeCount = UInt64(exactly: nodes.count)
        else { return .overflow }
        return .size(WorkspaceCodemapGraphSizeAccounting(
            nodes: nodeCount,
            postings: postingCount,
            edges: edgeCount,
            bytes: byteCount
        ))
    }

    private static func nodeBytes(_ node: WorkspaceCodemapGraphSnapshotNode) -> UInt64? {
        guard let pathBytes = UInt64(exactly: node.standardizedRelativePath.utf8.count),
              let definitionBytes = checkedStringBytes(node.contribution.sortedUniqueDefinitions),
              let referenceBytes = checkedStringBytes(node.contribution.sortedUniqueReferences)
        else { return nil }
        let bytes = checkedAdd(checkedAdd(checkedAdd(192, pathBytes), definitionBytes), referenceBytes)
        guard let projection = node.projection else { return bytes }
        return checkedAdd(bytes, projectionBytes(projection))
    }

    /// A projection retains its keys, evidence, call keys, and withheld references beside the raw
    /// contribution.
    private static func projectionBytes(_ projection: WorkspaceCodemapGraphNodeProjection) -> UInt64? {
        var bytes = checkedStringBytes(projection.definitionKeys)
        for reference in projection.references {
            bytes = checkedAdd(bytes, checkedStringBytes([reference.key ?? "", reference.evidence]))
        }
        for key in projection.callDependencyKeys {
            bytes = checkedAdd(bytes, checkedStringBytes([key.folder, key.call]))
        }
        for record in projection.unresolved {
            bytes = checkedAdd(bytes, unresolvedBytes(record))
        }
        return bytes
    }

    /// Priced like a posting: fixed overhead, the key's strings, and 16 bytes per member file ID.
    private static func callKeyBytes(_ key: TerraformCallKey, memberCount: Int) -> UInt64? {
        guard let folderBytes = UInt64(exactly: key.folder.utf8.count),
              let callBytes = UInt64(exactly: key.call.utf8.count),
              let count = UInt64(exactly: memberCount)
        else { return nil }
        return checkedAdd(checkedAdd(checkedAdd(64, folderBytes), callBytes), checkedMultiply(count, 16))
    }

    /// Walks every declaration of the call to price its source. Each declaration walked is a visit.
    private static func callBindingBytes(
        key: TerraformCallKey,
        bindings: PersistentHashMap<UUID, TerraformCallBinding>,
        visits: inout UInt64
    ) -> UInt64? {
        var bytes = callKeyBytes(key, memberCount: bindings.count)
        for binding in bindings.values {
            visits &+= 1
            bytes = checkedAdd(bytes, UInt64(exactly: binding.source.literalValue?.utf8.count ?? 0))
        }
        return bytes
    }

    private static func slotBytes(_ slot: WorkspaceCodemapGraphSlot) -> UInt64? {
        let contribution = slot.state.contribution
        guard let pathBytes = UInt64(exactly: slot.standardizedRelativePath.utf8.count),
              let definitionBytes = checkedStringBytes(contribution?.sortedUniqueDefinitions ?? []),
              let referenceBytes = checkedStringBytes(contribution?.sortedUniqueReferences ?? [])
        else { return nil }
        return checkedAdd(checkedAdd(checkedAdd(192, pathBytes), definitionBytes), referenceBytes)
    }

    private static func postingBytes(name: String, fileIDCount: Int) -> UInt64? {
        guard let nameBytes = UInt64(exactly: name.utf8.count),
              let count = UInt64(exactly: fileIDCount)
        else { return nil }
        return checkedAdd(checkedAdd(64, nameBytes), checkedMultiply(count, 16))
    }

    private static func evidenceBytes(_ evidence: WorkspaceCodemapGraphEdgeEvidence) -> UInt64? {
        checkedAdd(128, checkedStringBytes(evidence.matchedNames))
    }

    private static func unresolvedBytes(_ record: WorkspaceCodemapGraphUnresolvedRecord) -> UInt64? {
        checkedAdd(96, UInt64(exactly: record.referencedName.utf8.count))
    }

    private static func snapshotNode(
        from slot: WorkspaceCodemapGraphSlot,
        projection: WorkspaceCodemapGraphNodeProjection?
    ) -> WorkspaceCodemapGraphSnapshotNode? {
        guard let contribution = slot.state.contribution else { return nil }
        return WorkspaceCodemapGraphSnapshotNode(
            fileID: slot.fileID,
            standardizedRelativePath: slot.standardizedRelativePath,
            requestGeneration: slot.requestGeneration,
            pathGeneration: slot.pathGeneration,
            contribution: contribution,
            projection: projection
        )
    }

    private static func checkedAdd(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        guard let lhs, let rhs else { return nil }
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }

    private static func checkedStringBytes(_ strings: [String]) -> UInt64? {
        var result: UInt64 = 0
        for string in strings {
            guard let count = UInt64(exactly: string.utf8.count),
                  let withPayload = checkedAdd(result, count),
                  let withOverhead = checkedAdd(withPayload, 16)
            else { return nil }
            result = withOverhead
        }
        return result
    }

    private static func fileIDPrecedes(
        _ lhs: UUID,
        _ rhs: UUID,
        snapshot: WorkspaceCodemapGraphCommittedSnapshot
    ) -> Bool {
        fileIDPrecedes(lhs, rhs, nodes: snapshot.nodesByFileID)
    }

    private static func fileIDPrecedes(
        _ lhs: UUID,
        _ rhs: UUID,
        nodes: PersistentHashMap<UUID, WorkspaceCodemapGraphSnapshotNode>
    ) -> Bool {
        let left = nodes[lhs]?.standardizedRelativePath ?? ""
        let right = nodes[rhs]?.standardizedRelativePath ?? ""
        if left != right { return utf8Precedes(left, right) }
        return WorkspaceCodemapGraphOrdering.uuidPrecedes(lhs, rhs)
    }

    private static func edgePrecedes(
        _ lhs: WorkspaceCodemapGraphEdgeEvidence,
        _ rhs: WorkspaceCodemapGraphEdgeEvidence,
        nodes: PersistentHashMap<UUID, WorkspaceCodemapGraphSnapshotNode>
    ) -> Bool {
        if lhs.sourceFileID != rhs.sourceFileID { return fileIDPrecedes(lhs.sourceFileID, rhs.sourceFileID, nodes: nodes) }
        if lhs.targetFileID != rhs.targetFileID { return fileIDPrecedes(lhs.targetFileID, rhs.targetFileID, nodes: nodes) }
        return lhs.matchedNames.lexicographicallyPrecedes(rhs.matchedNames, by: utf8Precedes)
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        WorkspaceCodemapGraphOrdering.utf8Precedes(lhs, rhs)
    }
}

private extension WorkspaceCodemapGraphSlotState {
    var contribution: CodeMapSelectionGraphContribution? {
        switch self {
        case let .contributed(value), let .empty(value): value
        case .pending, .terminalArtifact, .terminalExcluded: nil
        }
    }
}
