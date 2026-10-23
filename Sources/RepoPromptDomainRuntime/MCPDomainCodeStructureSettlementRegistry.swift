import Foundation

/// Owns same-window settlement state for detach-disposition tools outside ordinary lane accounting.
///
/// The fenced tools are `get_code_structure`, `read_file`, `get_file_tree`, and the prompt
/// mutations (`prompt` set, append, clear, and select_preset, and `workspace_context`
/// select_preset); `file_actions` detaches without a lease. Every admitted
/// provider receives an invocation-scoped lease. Completion, cleanup-grace expiry, and external
/// cancellation transition that lease under this registry's single lock. A blocking lease fences
/// later same-window detach-disposition calls for a bounded recovery horizon. After that horizon,
/// one still-running provider may remain tracked without blocking; its exact lease still owns completion.
///
/// A call that reaches a capped window recovers it: every call in the window that outlived its caller is
/// quarantined, its late publication is revoked, and the call runs. Quarantined leases stay tracked and
/// leave the registry only on their exact completion, but they no longer fence the window. A window may
/// have `outstandingRecoveryLimitPerWindow` recoveries whose calls have not all finished, and the app
/// `quarantinedCallLimit` quarantined calls; past either limit the cap rejects calls as it did before.
package final class MCPCodeStructureSettlementRegistry: @unchecked Sendable {
    package static let recoveryHorizon = Duration.seconds(30)
    package static let releasedProviderLimit = 1
    package static let outstandingRecoveryLimitPerWindow = 2
    package static let quarantinedCallLimit = 8

    package init() {}

    package enum BusyReason: Equatable, Sendable {
        case detached
        case abandoned
        case settling
        case releasedProviderLimitReached
    }

    package struct BusyContext: Equatable, Sendable {
        package let reason: BusyReason
        package let originToolName: String
        package let originInvocationID: UUID
        package let originConnectionID: UUID
        package let detachedAge: Duration
        package let recoveryAfter: Duration?
        package let handlerPhase: String?
        package let releasedProviderCount: Int
        package let blockingProviderCount: Int
        package let quarantine: QuarantineUsage
    }

    /// How much quarantine capacity is in use, counted when it was read.
    package struct QuarantineUsage: Equatable, Sendable {
        package let windowQuarantinedCount: Int
        /// Recoveries in the window with at least one quarantined call still running.
        package let windowOutstandingRecoveryCount: Int
        package let appQuarantinedCount: Int

        package init(windowQuarantinedCount: Int, windowOutstandingRecoveryCount: Int, appQuarantinedCount: Int) {
            self.windowQuarantinedCount = windowQuarantinedCount
            self.windowOutstandingRecoveryCount = windowOutstandingRecoveryCount
            self.appQuarantinedCount = appQuarantinedCount
        }
    }

    /// One call a recovery quarantined.
    package struct QuarantinedCall: Equatable, Sendable {
        package let invocationID: UUID
        package let connectionID: UUID
        package let toolName: String
        package let state: String
        package let handlerPhase: String?
        package let blockingAge: Duration?
        /// False when a protected mutation's commit had already begun, so the call may still apply it.
        package let revocationWon: Bool
    }

    /// A recovery the admitting call triggered, with the capacity in use after it.
    package struct Recovery: Equatable, Sendable {
        package let recoveryID: UUID
        /// Ordered by when each call started blocking, oldest first.
        package let quarantinedCalls: [QuarantinedCall]
        package let quarantine: QuarantineUsage
    }

    package enum Admission: Sendable {
        case admitted(Slot)
        case busy(BusyContext)
    }

    package enum CompletionDirective: Equatable, Sendable {
        case deliver
        case deferred
        case settleDetached
        case settleAbandoned
        case settleForceDisconnected
        case ignored
    }

    package enum GraceExpiryDirective: Equatable, Sendable {
        case detach
        case forceDisconnect
        case settled
    }

    package enum DetachActivationDirective: Equatable, Sendable {
        case activated
        case settled(MCPToolExecutionSettlement)
        case notActivated
    }

    package enum CancellationDirective: Equatable, Sendable {
        case abandoned(MCPToolExecutionSettlement?)
        case alreadyDetached
        case forceDisconnect(MCPToolExecutionSettlement?)
        case settled
    }

    package enum EarlyExitDisposition: Equatable, Sendable {
        case released
        case retained
        case alreadySettled
    }

    package struct Snapshot: Equatable, Sendable {
        package let activeCount: Int
        package let detachedCount: Int
        /// Released by the recovery horizon and not quarantined, so counted against the released-provider limit.
        package let releasedCount: Int
        package let quarantinedCount: Int

        package init(activeCount: Int, detachedCount: Int, releasedCount: Int = 0, quarantinedCount: Int = 0) {
            self.activeCount = activeCount
            self.detachedCount = detachedCount
            self.releasedCount = releasedCount
            self.quarantinedCount = quarantinedCount
        }
    }

    /// One lease as the DEBUG settlement snapshot reports it.
    package struct LeaseDiagnostics: Equatable, Sendable {
        package let leaseID: UUID
        package let invocationID: UUID
        package let connectionID: UUID
        package let toolName: String
        /// `reserved`, `detaching`, `detached`, `abandoned`, or `force_disconnecting`.
        package let state: String
        package let admissionAge: Duration
        package let blockingAge: Duration?
        package let isReleased: Bool
        /// Whether the provider returned while its lease was still detaching.
        package let providerCompleted: Bool
        package let handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?
        package let handlerPhaseAge: Duration?
        /// Set for a protected mutation: what it may claim was applied when the snapshot was taken.
        package let mutationState: DomainProtectedMutationState?
        /// Set while the lease is quarantined: the recovery that quarantined it, how long ago, and whether
        /// its revocation won. A lost revocation means a protected mutation's commit had already begun.
        package let recoveryID: UUID?
        package let quarantineAge: Duration?
        package let revocationWon: Bool?
    }

    package struct Diagnostics: Equatable, Sendable {
        package let counts: Snapshot
        package let blockingCount: Int
        package let quarantine: QuarantineUsage
        /// Ordered by admission, oldest first.
        package let leases: [LeaseDiagnostics]
    }

    package final class Slot: @unchecked Sendable {
        package let windowID: Int
        package let leaseID: UUID
        package let connectionID: UUID
        package let invocationID: UUID
        /// Set when this call's admission recovered a capped window.
        package let recovery: Recovery?

        private weak var registry: MCPCodeStructureSettlementRegistry?

        fileprivate init(
            registry: MCPCodeStructureSettlementRegistry,
            windowID: Int,
            leaseID: UUID,
            connectionID: UUID,
            invocationID: UUID,
            recovery: Recovery?
        ) {
            self.registry = registry
            self.windowID = windowID
            self.leaseID = leaseID
            self.connectionID = connectionID
            self.invocationID = invocationID
            self.recovery = recovery
        }

        package func recordCompletion(_ settlement: MCPToolExecutionSettlement) -> CompletionDirective {
            registry?.recordCompletion(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID,
                settlement: settlement
            ) ?? .ignored
        }

        package func resolveGraceExpiry(now: Duration) -> GraceExpiryDirective {
            registry?.resolveGraceExpiry(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID,
                now: now
            ) ?? .settled
        }

        package func activateDetach() -> DetachActivationDirective {
            registry?.activateDetach(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID
            ) ?? .notActivated
        }

        package func cancel(now: Duration) -> CancellationDirective {
            registry?.cancel(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID,
                now: now
            ) ?? .settled
        }

        @discardableResult
        package func closeBeforeExecutionExit() -> EarlyExitDisposition {
            registry?.closeBeforeExecutionExit(
                windowID: windowID,
                leaseID: leaseID,
                invocationID: invocationID
            ) ?? .alreadySettled
        }

        deinit {
            #if DEBUG
                registry?.assertLeaseReleased(
                    windowID: windowID,
                    leaseID: leaseID,
                    invocationID: invocationID
                )
            #endif
        }
    }

    fileprivate enum State: Equatable {
        case reserved
        case detaching(MCPToolExecutionSettlement?)
        case detached
        case abandoned
        case forceDisconnecting
    }

    private struct Quarantine {
        let recoveryID: UUID
        let since: Duration
        let revocationWon: Bool
    }

    private struct Entry {
        let leaseID: UUID
        let connectionID: UUID
        let invocationID: UUID
        let toolName: String
        let handlerPhaseRecorder: MCPToolExecutionHandlerPhaseRecorder?
        let commitState: DomainMutationCommitState?
        let fence: MCPDomainInvocationFence?
        let admittedAt: Duration
        var state: State
        var blockingSince: Duration?
        var isReleased: Bool
        var quarantine: Quarantine?

        var blocksAdmission: Bool {
            state.blocksAdmission && !isReleased && quarantine == nil
        }

        var holdsReleasedSlot: Bool {
            isReleased && quarantine == nil
        }

        /// The call outlived its caller: its deadline passed or its request was cancelled.
        var isEscaped: Bool {
            state.blocksAdmission && quarantine == nil
        }

        /// Revokes the call's fence or commit arbiter and reports whether the revocation won. It loses only
        /// when a protected mutation's commit had already begun; a fence revocation always wins. Neither
        /// revocation calls back into the registry, so the registry may call this under its lock.
        @discardableResult
        func revoke(origin: MCPToolExecutionCancellationOrigin) -> Bool {
            fence?.revoke(origin: origin)
            return commitState?.revoke(origin: origin) ?? true
        }
    }

    private struct BusyCandidate {
        let reason: BusyReason
        let entry: Entry
        let detachedAge: Duration
        let recoveryAfter: Duration?
        let releasedProviderCount: Int
        let blockingProviderCount: Int
        let quarantine: QuarantineUsage
    }

    private struct RecoveryCandidate {
        let recoveryID: UUID
        let entries: [Entry]
        let quarantine: QuarantineUsage
        let now: Duration
    }

    private enum AdmissionDecision {
        case admitted(leaseID: UUID, recovery: RecoveryCandidate?)
        case busy(BusyCandidate)
    }

    private let lock = NSLock()
    private var entriesByWindowID: [Int: [UUID: Entry]] = [:]
    /// Per window, each outstanding recovery and the leases it quarantined that have not completed.
    private var recoveriesByWindowID: [Int: [UUID: Set<UUID>]] = [:]
    private var drainWaitersByWindowID: [Int: [CheckedContinuation<Void, Never>]] = [:]

    /// Admits a call into the window, or recovers the window when it is capped. `commitState` and `fence`
    /// are the call's revocation handles; recovery and window close revoke whichever one it has.
    package func admit(
        windowID: Int,
        connectionID: UUID,
        invocationID: UUID,
        toolName: String,
        now: Duration,
        handlerPhaseRecorder: MCPToolExecutionHandlerPhaseRecorder? = nil,
        commitState: DomainMutationCommitState? = nil,
        fence: MCPDomainInvocationFence? = nil
    ) -> Admission {
        let decision: AdmissionDecision = lock.withLock {
            var entries = entriesByWindowID[windowID, default: [:]]
            var recovery: RecoveryCandidate?
            let blockingEntries = entries.values.filter(\.blocksAdmission)
            if !blockingEntries.isEmpty {
                let releasedProviderCount = entries.values.count(where: \.holdsReleasedSlot)
                let origin = Self.oldestEntry(in: blockingEntries)
                let blockingSince = origin.blockingSince
                precondition(blockingSince != nil, "Blocking settlement entry requires an origin timestamp")
                let age = Self.elapsed(since: blockingSince!, now: now)

                if releasedProviderCount + blockingEntries.count > Self.releasedProviderLimit {
                    let escaped = entries.values.filter(\.isEscaped)
                    guard recoveryFits(windowID: windowID, quarantining: escaped.count) else {
                        return .busy(BusyCandidate(
                            reason: .releasedProviderLimitReached,
                            entry: origin,
                            detachedAge: age,
                            recoveryAfter: nil,
                            releasedProviderCount: releasedProviderCount,
                            blockingProviderCount: blockingEntries.count,
                            quarantine: quarantineUsage(windowID: windowID)
                        ))
                    }
                    let recoveryID = UUID()
                    var quarantined: [Entry] = []
                    for var entry in escaped {
                        // Revoked before the lock is released: admission and dispatch are separate steps, so a
                        // call admitted after this recovery could otherwise publish before these calls are revoked.
                        let revocationWon = entry.revoke(origin: .windowRecovery)
                        entry.quarantine = Quarantine(recoveryID: recoveryID, since: now, revocationWon: revocationWon)
                        entries[entry.leaseID] = entry
                        quarantined.append(entry)
                    }
                    recoveriesByWindowID[windowID, default: [:]][recoveryID] = Set(quarantined.map(\.leaseID))
                    recovery = RecoveryCandidate(
                        recoveryID: recoveryID,
                        entries: quarantined,
                        quarantine: quarantineUsage(windowID: windowID),
                        now: now
                    )
                } else {
                    let recoveryAfter = max(.zero, Self.recoveryHorizon - age)
                    guard recoveryAfter == .zero else {
                        return .busy(BusyCandidate(
                            reason: Self.busyReason(for: blockingEntries),
                            entry: origin,
                            detachedAge: age,
                            recoveryAfter: recoveryAfter,
                            releasedProviderCount: releasedProviderCount,
                            blockingProviderCount: blockingEntries.count,
                            quarantine: quarantineUsage(windowID: windowID)
                        ))
                    }

                    entries[origin.leaseID]?.isReleased = true
                }
            }

            let leaseID = UUID()
            entries[leaseID] = Entry(
                leaseID: leaseID,
                connectionID: connectionID,
                invocationID: invocationID,
                toolName: toolName,
                handlerPhaseRecorder: handlerPhaseRecorder,
                commitState: commitState,
                fence: fence,
                admittedAt: now,
                state: .reserved,
                blockingSince: nil,
                isReleased: false,
                quarantine: nil
            )
            entriesByWindowID[windowID] = entries
            return .admitted(leaseID: leaseID, recovery: recovery)
        }

        // Handler-phase recorders take their own lock, so they are read after the registry lock is released.
        switch decision {
        case let .admitted(leaseID, recovery):
            return .admitted(Slot(
                registry: self,
                windowID: windowID,
                leaseID: leaseID,
                connectionID: connectionID,
                invocationID: invocationID,
                recovery: recovery.map(Self.recovery(from:))
            ))
        case let .busy(candidate):
            return .busy(BusyContext(
                reason: candidate.reason,
                originToolName: candidate.entry.toolName,
                originInvocationID: candidate.entry.invocationID,
                originConnectionID: candidate.entry.connectionID,
                detachedAge: candidate.detachedAge,
                recoveryAfter: candidate.recoveryAfter,
                handlerPhase: candidate.entry.handlerPhaseRecorder?.snapshot()?.phase.rawValue,
                releasedProviderCount: candidate.releasedProviderCount,
                blockingProviderCount: candidate.blockingProviderCount,
                quarantine: candidate.quarantine
            ))
        }
    }

    package func snapshot(windowID: Int) -> Snapshot {
        lock.withLock {
            Self.counts(of: Array(entriesByWindowID[windowID, default: [:]].values))
        }
    }

    /// Revokes the late publication of every call in a closing window. The leases stay until each call
    /// completes, and the window's quarantined calls keep counting toward the app-wide limit.
    package func revokeWindow(windowID: Int) {
        lock.withLock {
            for entry in entriesByWindowID[windowID, default: [:]].values {
                entry.revoke(origin: .windowClosed)
            }
        }
    }

    /// Revokes the late publication of a closing connection's calls. Teardown cancels their providers
    /// directly, which doesn't reach the watchdog's revocation, so this runs before that cancellation.
    package func revokeConnection(_ connectionID: UUID) {
        lock.withLock {
            for entries in entriesByWindowID.values {
                for entry in entries.values where entry.connectionID == connectionID {
                    entry.revoke(origin: .connectionClosed)
                }
            }
        }
    }

    /// Reports every lease in the window for DEBUG diagnostics. Recorders are read after the
    /// registry lock is released; they take only their own lock.
    package func diagnostics(windowID: Int, now: Duration) -> Diagnostics {
        let (entries, quarantine) = lock.withLock {
            (Array(entriesByWindowID[windowID, default: [:]].values), quarantineUsage(windowID: windowID))
        }
        let leases = entries
            .sorted { lhs, rhs in
                lhs.admittedAt == rhs.admittedAt
                    ? lhs.invocationID.uuidString < rhs.invocationID.uuidString
                    : lhs.admittedAt < rhs.admittedAt
            }
            .map { entry in
                let handlerPhase = entry.handlerPhaseRecorder?.snapshot()
                let handlerPhaseAge = handlerPhase.flatMap { phase in
                    entry.handlerPhaseRecorder.map { recorder in
                        max(.zero, now - recorder.origin - .milliseconds(phase.elapsedMilliseconds))
                    }
                }
                return LeaseDiagnostics(
                    leaseID: entry.leaseID,
                    invocationID: entry.invocationID,
                    connectionID: entry.connectionID,
                    toolName: entry.toolName,
                    state: entry.state.diagnosticName,
                    admissionAge: Self.elapsed(since: entry.admittedAt, now: now),
                    blockingAge: entry.blockingSince.map { Self.elapsed(since: $0, now: now) },
                    isReleased: entry.isReleased,
                    providerCompleted: entry.state.providerCompleted,
                    handlerPhase: handlerPhase,
                    handlerPhaseAge: handlerPhaseAge,
                    mutationState: entry.commitState?.replyState,
                    recoveryID: entry.quarantine?.recoveryID,
                    quarantineAge: entry.quarantine.map { Self.elapsed(since: $0.since, now: now) },
                    revocationWon: entry.quarantine?.revocationWon
                )
            }
        return Diagnostics(
            counts: Self.counts(of: entries),
            blockingCount: entries.count(where: \.blocksAdmission),
            quarantine: quarantine,
            leases: leases
        )
    }

    /// Reports whether an already-released provider plus current blockers still
    /// exhaust the bounded zombie capacity. This is observational only; leases
    /// remain owned and transitioned by the existing admission/completion paths.
    package func hasReleasedProviderLimitBlockage(windowID: Int) -> Bool {
        lock.withLock {
            let entries = entriesByWindowID[windowID, default: [:]]
            let blockingCount = entries.values.count(where: \.blocksAdmission)
            let releasedCount = entries.values.count(where: \.holdsReleasedSlot)
            return blockingCount > 0
                && releasedCount + blockingCount > Self.releasedProviderLimit
        }
    }

    package func awaitDrained(windowID: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard entriesByWindowID[windowID]?.isEmpty == false else { return true }
                drainWaitersByWindowID[windowID, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func recordCompletion(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        settlement: MCPToolExecutionSettlement
    ) -> CompletionDirective {
        transition(windowID: windowID, leaseID: leaseID, invocationID: invocationID) { entry in
            switch entry.state {
            case .reserved:
                return (.remove, .deliver)
            case .detaching:
                entry.state = .detaching(settlement)
                return (.retain(entry), .deferred)
            case .detached:
                return (.remove, .settleDetached)
            case .abandoned:
                return (.remove, .settleAbandoned)
            case .forceDisconnecting:
                return (.remove, .settleForceDisconnected)
            }
        } ?? .ignored
    }

    private func resolveGraceExpiry(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        now: Duration
    ) -> GraceExpiryDirective {
        lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return .settled }

            switch entry.state {
            case .reserved:
                let otherUnsettled = entries.values.contains {
                    $0.leaseID != leaseID && $0.blocksAdmission
                }
                entry.blockingSince = now
                if otherUnsettled {
                    entry.state = .forceDisconnecting
                    entries[leaseID] = entry
                    entriesByWindowID[windowID] = entries
                    return .forceDisconnect
                }
                entry.state = .detaching(nil)
                entries[leaseID] = entry
                entriesByWindowID[windowID] = entries
                return .detach
            case .detaching, .detached:
                return .detach
            case .abandoned:
                return .settled
            case .forceDisconnecting:
                return .forceDisconnect
            }
        }
    }

    private func activateDetach(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID
    ) -> DetachActivationDirective {
        let result: (DetachActivationDirective, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (.notActivated, []) }

            guard case let .detaching(settlement) = entry.state else {
                return (.notActivated, [])
            }
            if let settlement {
                removeEntry(leaseID, windowID: windowID, from: &entries)
                return (
                    .settled(settlement),
                    storeEntriesAndTakeWaiters(entries, windowID: windowID)
                )
            }
            entry.state = .detached
            entries[leaseID] = entry
            entriesByWindowID[windowID] = entries
            return (.activated, [])
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    private func cancel(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        now: Duration
    ) -> CancellationDirective {
        let result: (CancellationDirective, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (.settled, []) }

            switch entry.state {
            case .reserved:
                entry.state = .abandoned
                entry.blockingSince = now
                entries[leaseID] = entry
                entriesByWindowID[windowID] = entries
                return (.abandoned(nil), [])

            case let .detaching(settlement):
                if let settlement {
                    removeEntry(leaseID, windowID: windowID, from: &entries)
                    let waiters = storeEntriesAndTakeWaiters(entries, windowID: windowID)
                    return (.abandoned(settlement), waiters)
                }
                entry.state = .abandoned
                entries[leaseID] = entry
                entriesByWindowID[windowID] = entries
                return (.abandoned(nil), [])

            case .detached:
                return (.alreadyDetached, [])

            case .abandoned:
                return (.abandoned(nil), [])

            case .forceDisconnecting:
                return (.forceDisconnect(nil), [])
            }
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    private func closeBeforeExecutionExit(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID
    ) -> EarlyExitDisposition {
        let result: (EarlyExitDisposition, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  let entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (.alreadySettled, []) }

            guard case .reserved = entry.state else {
                return (.retained, [])
            }
            removeEntry(leaseID, windowID: windowID, from: &entries)
            return (
                .released,
                storeEntriesAndTakeWaiters(entries, windowID: windowID)
            )
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    private enum Mutation {
        case retain(Entry)
        case remove
    }

    private func transition<Result>(
        windowID: Int,
        leaseID: UUID,
        invocationID: UUID,
        mutation: (inout Entry) -> (Mutation, Result)
    ) -> Result? {
        let result: (Result?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard var entries = entriesByWindowID[windowID],
                  var entry = entries[leaseID],
                  entry.invocationID == invocationID
            else { return (nil, []) }

            let (entryMutation, value) = mutation(&entry)
            switch entryMutation {
            case let .retain(updated):
                entries[leaseID] = updated
            case .remove:
                removeEntry(leaseID, windowID: windowID, from: &entries)
            }
            return (
                value,
                storeEntriesAndTakeWaiters(entries, windowID: windowID)
            )
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    /// Removes a lease on its exact completion. A quarantined lease refunds its recovery once every call
    /// that recovery quarantined has completed. Callers hold the lock.
    private func removeEntry(_ leaseID: UUID, windowID: Int, from entries: inout [UUID: Entry]) {
        guard let quarantine = entries.removeValue(forKey: leaseID)?.quarantine else { return }
        var recoveries = recoveriesByWindowID[windowID, default: [:]]
        recoveries[quarantine.recoveryID]?.remove(leaseID)
        if recoveries[quarantine.recoveryID]?.isEmpty == true {
            recoveries.removeValue(forKey: quarantine.recoveryID)
        }
        recoveriesByWindowID[windowID] = recoveries.isEmpty ? nil : recoveries
    }

    /// A recovery quarantines every escaped call in the window or none of them, so a population over the
    /// app-wide limit stays blocked rather than being split. Callers hold the lock.
    private func recoveryFits(windowID: Int, quarantining count: Int) -> Bool {
        recoveriesByWindowID[windowID, default: [:]].count < Self.outstandingRecoveryLimitPerWindow
            && appQuarantinedCount() + count <= Self.quarantinedCallLimit
    }

    private func appQuarantinedCount() -> Int {
        recoveriesByWindowID.values.reduce(0) { total, recoveries in
            total + recoveries.values.reduce(0) { $0 + $1.count }
        }
    }

    private func quarantineUsage(windowID: Int) -> QuarantineUsage {
        let recoveries = recoveriesByWindowID[windowID, default: [:]]
        return QuarantineUsage(
            windowQuarantinedCount: recoveries.values.reduce(0) { $0 + $1.count },
            windowOutstandingRecoveryCount: recoveries.count,
            appQuarantinedCount: appQuarantinedCount()
        )
    }

    private static func counts(of entries: [Entry]) -> Snapshot {
        Snapshot(
            activeCount: entries.count,
            detachedCount: entries.count { $0.state.isZombie },
            releasedCount: entries.count(where: \.holdsReleasedSlot),
            quarantinedCount: entries.count { $0.quarantine != nil }
        )
    }

    private static func recovery(from candidate: RecoveryCandidate) -> Recovery {
        let calls = candidate.entries
            .sorted { lhs, rhs in
                let lhsSince = lhs.blockingSince ?? lhs.admittedAt
                let rhsSince = rhs.blockingSince ?? rhs.admittedAt
                return lhsSince == rhsSince
                    ? lhs.invocationID.uuidString < rhs.invocationID.uuidString
                    : lhsSince < rhsSince
            }
            .map { entry in
                QuarantinedCall(
                    invocationID: entry.invocationID,
                    connectionID: entry.connectionID,
                    toolName: entry.toolName,
                    state: entry.state.diagnosticName,
                    handlerPhase: entry.handlerPhaseRecorder?.snapshot()?.phase.rawValue,
                    blockingAge: entry.blockingSince.map { elapsed(since: $0, now: candidate.now) },
                    revocationWon: entry.quarantine?.revocationWon ?? true
                )
            }
        return Recovery(
            recoveryID: candidate.recoveryID,
            quarantinedCalls: calls,
            quarantine: candidate.quarantine
        )
    }

    private func storeEntriesAndTakeWaiters(
        _ entries: [UUID: Entry],
        windowID: Int
    ) -> [CheckedContinuation<Void, Never>] {
        if entries.isEmpty {
            entriesByWindowID.removeValue(forKey: windowID)
            return drainWaitersByWindowID.removeValue(forKey: windowID) ?? []
        }
        entriesByWindowID[windowID] = entries
        return []
    }

    private static func busyReason(for entries: [Entry]) -> BusyReason {
        if entries.contains(where: {
            if case .abandoned = $0.state { return true }
            return false
        }) {
            return .abandoned
        }
        if entries.contains(where: \.state.isZombie) {
            return .detached
        }
        return .settling
    }

    private static func oldestEntry(in entries: [Entry]) -> Entry {
        precondition(!entries.isEmpty, "Busy settlement context requires an originating entry")
        return entries.min { lhs, rhs in
            let lhsBlockingSince = lhs.blockingSince
            let rhsBlockingSince = rhs.blockingSince
            precondition(
                lhsBlockingSince != nil && rhsBlockingSince != nil,
                "Blocking settlement entries require origin timestamps"
            )
            if lhsBlockingSince == rhsBlockingSince {
                return lhs.invocationID.uuidString < rhs.invocationID.uuidString
            }
            return lhsBlockingSince! < rhsBlockingSince!
        }!
    }

    private static func elapsed(since start: Duration, now: Duration) -> Duration {
        max(.zero, now - start)
    }

    #if DEBUG
        private func assertLeaseReleased(
            windowID: Int,
            leaseID: UUID,
            invocationID: UUID
        ) {
            let leaked = lock.withLock {
                entriesByWindowID[windowID]?[leaseID]?.invocationID == invocationID
            }
            assert(!leaked, "Leaked get_code_structure settlement lease \(invocationID)")
        }
    #endif
}

private extension MCPCodeStructureSettlementRegistry.State {
    var isZombie: Bool {
        switch self {
        case .detaching, .detached, .abandoned:
            true
        case .reserved, .forceDisconnecting:
            false
        }
    }

    var blocksAdmission: Bool {
        switch self {
        case .reserved:
            false
        case .detaching, .detached, .abandoned, .forceDisconnecting:
            true
        }
    }

    var diagnosticName: String {
        switch self {
        case .reserved: "reserved"
        case .detaching: "detaching"
        case .detached: "detached"
        case .abandoned: "abandoned"
        case .forceDisconnecting: "force_disconnecting"
        }
    }

    var providerCompleted: Bool {
        if case .detaching(.some) = self { return true }
        return false
    }
}
