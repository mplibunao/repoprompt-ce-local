import Foundation

/// The listener and the inbox it reserved for one run attempt.
typealias ClaudeAttemptEventReservation = (listener: ClaudeControllerEventListener, subscription: ClaudeAttemptEventSubscription)

/// What a run attempt reads from its inbox.
enum ClaudeAttemptEvent {
    /// An event from the Claude controller's stream.
    case native(NativeAgentRuntimeEvent)
    /// A steer ended without its input being accepted, so the provider work it protected can
    /// settle the attempt again. `endsAttempt` is true when the attempt can't settle on that work:
    /// Claude Code may have received the input, or the process the work ran in was stopped and
    /// nothing replaced it.
    case steeringReleased(protectedIDs: Set<UUID>, endsAttempt: Bool)
    /// The attempt should check again whether it can settle.
    case settlementRecheck
}

/// One run attempt's inbox. The listener appends to it, and only the attempt's consumer reads it.
/// Cancelling the consumer's wait leaves unread events in place for `close()` to return.
@MainActor
final class ClaudeAttemptEventSubscription {
    /// Reads compact the array once this many events have been read, so a long attempt doesn't
    /// shift the whole buffer on every read.
    private static let compactionThreshold = 256

    private var events: [ClaudeAttemptEvent] = []
    /// Index of the oldest unread event.
    private var head = 0
    /// Each wait has its own ID, so a cancellation handler that runs late can't release a later wait.
    private var waiter: (id: UInt64, continuation: CheckedContinuation<ClaudeAttemptEvent?, Never>)?
    private var lastWaiterID: UInt64 = 0
    private(set) var isClosed = false
    /// The transport ended. Reads drain what's buffered, then return `nil`.
    private var isFinished = false
    private var inputHandoffDepth = 0

    func append(_ event: ClaudeAttemptEvent) {
        guard !isClosed else { return }
        events.append(event)
        deliverIfWaiting()
    }

    /// The next event, or `nil` once the inbox is closed, finished and drained, or the calling
    /// task is cancelled.
    func next() async -> ClaudeAttemptEvent? {
        guard !Task.isCancelled, !isClosed else { return nil }
        if inputHandoffDepth == 0 {
            if let event = takeFirst() {
                return event
            }
            if isFinished {
                return nil
            }
        }
        guard waiter == nil else {
            assertionFailure("An attempt inbox has one reader")
            return nil
        }
        lastWaiterID &+= 1
        let id = lastWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = (id, $0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseWaiter(id) }
        }
    }

    /// Holds delivery while the coordinator sends input, so a completion that arrives during the
    /// send reaches the attempt only after the session has recorded the input's ID. Events keep
    /// buffering meanwhile. Calls nest.
    func beginInputHandoff() {
        inputHandoffDepth += 1
    }

    func endInputHandoff() {
        guard inputHandoffDepth > 0 else {
            assertionFailure("endInputHandoff() without beginInputHandoff()")
            return
        }
        inputHandoffDepth -= 1
        deliverIfWaiting()
    }

    /// The transport behind this inbox ended.
    func finish() {
        isFinished = true
        deliverIfWaiting()
    }

    /// A replacement transport now delivers to this inbox. An earlier `finish()` no longer applies.
    func attachTransport() {
        guard !isClosed else { return }
        isFinished = false
    }

    /// Drops unread controller events from a transport that was replaced. Steering and recheck
    /// events stay, because they come from the coordinator and belong to the attempt.
    func discardTransportEvents() {
        events = events[head...].filter { event in
            if case .native = event {
                return false
            }
            return true
        }
        head = 0
    }

    /// Turns Claude Code started by itself whose start is still unread in this inbox.
    var bufferedProviderTurnIDs: Set<UUID> {
        Set(events[head...].compactMap { event in
            guard case let .native(.providerTurnStarted(turnID)) = event else { return nil }
            return turnID
        })
    }

    /// Claude permission request IDs still unread in this inbox.
    var bufferedApprovalIDs: [String] {
        events[head...].compactMap { event in
            guard case let .native(native) = event else { return nil }
            return native.claudeApprovalRequestID
        }
    }

    /// Replaces an unread approval request with its cancellation. The attempt then never shows a
    /// request that was already answered.
    func cancelBufferedApproval(_ id: String) {
        for index in head ..< events.count {
            guard case let .native(native) = events[index], native.claudeApprovalRequestID == id else { continue }
            events[index] = .native(.approvalCancelled(requestID: id))
        }
    }

    /// Closes the inbox and returns its unread events in order. A waiting reader gets `nil`.
    @discardableResult
    func close() -> [ClaudeAttemptEvent] {
        guard !isClosed else { return [] }
        isClosed = true
        let unread = Array(events[head...])
        events.removeAll()
        head = 0
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: nil)
        }
        return unread
    }

    private func deliverIfWaiting() {
        guard inputHandoffDepth == 0, let waiter else { return }
        if let event = takeFirst() {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
        } else if isFinished {
            self.waiter = nil
            waiter.continuation.resume(returning: nil)
        }
    }

    private func releaseWaiter(_ id: UInt64) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }

    private func takeFirst() -> ClaudeAttemptEvent? {
        guard head < events.count else { return nil }
        let event = events[head]
        head += 1
        if head == events.count {
            events.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= Self.compactionThreshold, head * 2 >= events.count {
            events.removeFirst(head)
            head = 0
        }
        return event
    }
}

/// Reads one Claude controller's event stream for the life of its process and hands the events to
/// at most one run attempt at a time. While no attempt holds the inbox, a provider-started turn and
/// the events after it wait in a handoff for the attempt that adopts them, and every other event
/// goes to `onIdleEvent` without being kept, so a later host run never reads earlier idle output.
/// While an attempt holds the inbox, every event goes into it, because a lost start, permission
/// request, tool result, or completion would leave work without an owner.
@MainActor
final class ClaudeControllerEventListener {
    /// The coordinator's request to adopt `pendingProviderTurnID`. Retirement cancels it.
    var adoptionTask: Task<Void, Never>?
    /// The first runtime failure seen while idle on this installation. The coordinator reports a
    /// failure only while this is `nil`, and `install` clears it.
    var runtimeFailure: String?
    /// The installation whose `runtimeFailure` was ready to report while the listener wasn't
    /// current. The coordinator reports it once the listener is current again.
    var heldFailureInstallation: UUID?
    private(set) var subscription: ClaudeAttemptEventSubscription?
    /// The provider turn waiting in the handoff for an attempt to adopt it.
    private(set) var pendingProviderTurnID: UUID?
    /// Provider turns that started and haven't completed.
    private(set) var providerTurnIDs: Set<UUID> = []
    /// Provider turns the current transport started, completed or not.
    private(set) var transportProviderTurnIDs: Set<UUID> = []
    /// Claude permission requests the current transport raised that nobody answered or cancelled
    /// yet, in arrival order: unread in the inbox or the handoff, shown by an attempt, or held.
    var openApprovalIDs: [String] {
        heldEvents.reduce(into: routedOpenApprovalIDs) { ids, event in
            if let id = event.claudeApprovalRequestID {
                if !ids.contains(id) {
                    ids.append(id)
                }
            } else if case let .approvalCancelled(id) = event {
                ids.removeAll { $0 == id }
            }
        }
    }

    private(set) var isRetired = false

    /// Whether the session, binding, and process run this listener was created for are still current.
    let isCurrent: @MainActor () -> Bool
    /// A provider turn started while no attempt holds the inbox. Its events wait in the handoff.
    var onProviderTurn: (@MainActor (UUID) -> Void)?
    /// An event arrived while no attempt holds the inbox and no provider turn waits for adoption.
    var onIdleEvent: (@MainActor (NativeAgentRuntimeEvent) -> Void)?
    /// The current installation's stream ended. Receives that installation's witness.
    var onStreamEnd: (@MainActor (UUID) async -> Void)?
    /// `isBusy` changed.
    var onBusyChanged: (@MainActor () -> Void)?

    private var readerTask: Task<Void, Never>?
    private var installationID = UUID()
    private var controllerID: ObjectIdentifier?
    private var generation: UInt64?
    private var handoff: [NativeAgentRuntimeEvent] = []
    /// Events of the current installation that arrived while the listener wasn't current, as during
    /// a binding transition. They're routed in order once it is current again.
    private var heldEvents: [NativeAgentRuntimeEvent] = []
    /// The current installation's stream ended while the listener wasn't current.
    private var heldStreamEnd: UUID?
    /// The open permission requests among the routed events.
    private var routedOpenApprovalIDs: [String] = []
    private var publishedBusy = false
    /// Inboxes closed with their tail returned whose attempts haven't finished terminal
    /// publication. The next adoption waits for all of them.
    private var publishingInboxes: [ClaudeAttemptEventSubscription] = []
    private var publicationWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var lastPublicationWaiterID: UInt64 = 0

    init(isCurrent: @escaping @MainActor () -> Bool) {
        self.isCurrent = isCurrent
    }

    /// Provider work is waiting for adoption or still running, or a held event started it and
    /// hasn't been routed yet.
    var isBusy: Bool {
        pendingProviderTurnID != nil || !providerTurnIDs.isEmpty || heldEvents.contains(where: \.startsProviderTurn)
    }

    /// Identifies the current installation, so a callback can tell after an `await` whether the
    /// transport it started for was replaced.
    var installationWitness: UUID {
        installationID
    }

    func hasInstallation(_ id: UUID) -> Bool {
        installationID == id
    }

    func matches(controller: any NativeAgentRuntimeControlling, handle: NativeAgentRuntimeEventStreamHandle) -> Bool {
        controllerID == ObjectIdentifier(controller) && generation == handle.generation
    }

    /// Starts reading `handle`'s stream, unless this controller and stream generation are already
    /// installed. A reserved inbox keeps its reservation and reopens if the previous transport
    /// finished it. Events the previous transport already delivered stay; call `detachTransport()`
    /// first to drop them.
    func install(controller: any NativeAgentRuntimeControlling, handle: NativeAgentRuntimeEventStreamHandle) {
        guard !isRetired else { return }
        let identity = ObjectIdentifier(controller)
        guard controllerID != identity || generation != handle.generation else { return }
        // Events the replaced transport delivered while the listener was current still count.
        routeHeldEvents()
        heldEvents.removeAll()
        heldStreamEnd = nil
        // A new installation ID first, so an event the old reader already holds is rejected.
        let installation = UUID()
        installationID = installation
        readerTask?.cancel()
        controllerID = identity
        generation = handle.generation
        runtimeFailure = nil
        heldFailureInstallation = nil
        subscription?.attachTransport()
        readerTask = Task { [weak self] in
            for await event in handle.stream {
                guard let self, reads(installation) else { return }
                receive(event)
            }
            guard let self, reads(installation) else { return }
            guard isCurrent() else {
                heldStreamEnd = installation
                return
            }
            await onStreamEnd?(installation)
        }
    }

    /// Routes one controller event. The reader calls this for each event of the current
    /// installation. While the listener isn't current the event is held, not routed.
    func receive(_ event: NativeAgentRuntimeEvent) {
        guard !isRetired else { return }
        guard isCurrent() else {
            heldEvents.append(event)
            return
        }
        routeHeldEvents()
        process(event)
    }

    /// Routes what arrived while the listener wasn't current, once it is current again: a binding
    /// transition that ended without replacing the binding leaves it current.
    func resumeHeldEvents() {
        guard !isRetired, isCurrent() else { return }
        routeHeldEvents()
        if heldEvents.isEmpty, let installation = heldStreamEnd, installation == installationID {
            heldStreamEnd = nil
            Task { [weak self] in
                guard let self, reads(installation) else { return }
                await onStreamEnd?(installation)
            }
        }
    }

    /// The coordinator couldn't handle `installation`'s stream end because the listener stopped
    /// being current meanwhile. It's handled once the listener is current again.
    func holdStreamEnd(_ installation: UUID) {
        guard !isRetired, installation == installationID else { return }
        heldStreamEnd = installation
    }

    /// A permission request the coordinator answered.
    func approvalAnswered(_ id: String) {
        routedOpenApprovalIDs.removeAll { $0 == id }
    }

    /// A permission request the coordinator cancelled. An unread request becomes its cancellation.
    /// The attempt may already have taken the request from its inbox without showing it yet, so
    /// otherwise the cancellation follows in the inbox.
    func withdrawApproval(_ id: String) {
        let unreadInInbox = subscription?.bufferedApprovalIDs.contains(id) == true
        cancelBufferedApproval(id)
        approvalAnswered(id)
        if !unreadInInbox {
            subscription?.append(.native(.approvalCancelled(requestID: id)))
        }
    }

    /// Reserves the inbox for one attempt. A waiting handoff moves into it, so the attempt that
    /// reserves first owns that provider turn. Returns `nil` while another attempt holds the inbox.
    func reserve() -> ClaudeAttemptEventSubscription? {
        guard !isRetired, subscription == nil else { return nil }
        routeHeldEvents()
        let inbox = ClaudeAttemptEventSubscription()
        subscription = inbox
        if pendingProviderTurnID != nil {
            pendingProviderTurnID = nil
            for event in handoff {
                inbox.append(.native(event))
            }
            handoff.removeAll()
            publishBusyIfChanged()
        }
        return inbox
    }

    /// Ends an attempt's hold on the inbox. With `returningTail`, the unread controller events are
    /// routed again in order, so a provider turn the attempt didn't read can start the next
    /// attempt, and that adoption waits until `terminalPublished(for:)` reports this attempt's
    /// publication. Without it the unread events are dropped, for an attempt that will never
    /// publish.
    func close(_ inbox: ClaudeAttemptEventSubscription, returningTail: Bool) {
        guard subscription === inbox else {
            inbox.close()
            return
        }
        subscription = nil
        let unread = inbox.close()
        guard returningTail, !isRetired, isCurrent() else { return }
        publishingInboxes.append(inbox)
        for case let .native(event) in unread {
            route(event)
        }
        publishBusyIfChanged()
    }

    /// Ends a reservation whose attempt has nothing left to publish, or that no attempt read: its
    /// unread events are routed again and no adoption waits on it.
    func release(_ inbox: ClaudeAttemptEventSubscription) {
        close(inbox, returningTail: true)
        terminalPublished(for: inbox)
    }

    /// The attempt that held `inbox` finished its terminal publication.
    func terminalPublished(for inbox: ClaudeAttemptEventSubscription) {
        guard let index = publishingInboxes.firstIndex(where: { $0 === inbox }) else { return }
        publishingInboxes.remove(at: index)
        if publishingInboxes.isEmpty {
            resumePublicationWaiters()
        }
    }

    /// Returns once every attempt closed with its tail returned has finished terminal
    /// publication, or when the listener retires or the calling task is cancelled.
    func awaitTerminalPublication() async {
        // A resumed waiter runs after `terminalPublished` returns, and another attempt can close
        // in between, so the fence is checked again after every wake.
        while !publishingInboxes.isEmpty, !Task.isCancelled {
            lastPublicationWaiterID &+= 1
            let id = lastPublicationWaiterID
            await withTaskCancellationHandler {
                await withCheckedContinuation { publicationWaiters[id] = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in self?.resumePublicationWaiter(id) }
            }
        }
    }

    /// The transport behind the reserved attempt is being replaced. The reservation stays; the
    /// retired transport's reader stops, and its unread events, handoff, and provider turns are dropped.
    func detachTransport() {
        clearTransportState()
        subscription?.discardTransportEvents()
        publishBusyIfChanged()
    }

    /// Stops the listener permanently. It cancels the adoption and the reader, closes the inbox,
    /// drops the handoff, and releases publication waiters. A retired listener installs and
    /// reserves nothing.
    func retire() {
        isRetired = true
        adoptionTask?.cancel()
        adoptionTask = nil
        clearTransportState()
        subscription?.close()
        subscription = nil
        publishingInboxes.removeAll()
        resumePublicationWaiters()
        publishBusyIfChanged()
    }

    /// Claude permission request IDs waiting unread in the inbox, the handoff, or the held events.
    var bufferedApprovalIDs: [String] {
        (subscription?.bufferedApprovalIDs ?? [])
            + handoff.compactMap(\.claudeApprovalRequestID)
            + heldEvents.compactMap(\.claudeApprovalRequestID)
    }

    /// Replaces an unread approval request, in the inbox, the handoff, or the held events, with its
    /// cancellation.
    func cancelBufferedApproval(_ id: String) {
        subscription?.cancelBufferedApproval(id)
        for index in handoff.indices where handoff[index].claudeApprovalRequestID == id {
            handoff[index] = .approvalCancelled(requestID: id)
        }
        for index in heldEvents.indices where heldEvents[index].claudeApprovalRequestID == id {
            heldEvents[index] = .approvalCancelled(requestID: id)
        }
    }

    private func clearTransportState() {
        installationID = UUID()
        readerTask?.cancel()
        readerTask = nil
        controllerID = nil
        generation = nil
        handoff.removeAll()
        heldEvents.removeAll()
        heldStreamEnd = nil
        heldFailureInstallation = nil
        pendingProviderTurnID = nil
        providerTurnIDs.removeAll()
        transportProviderTurnIDs.removeAll()
        routedOpenApprovalIDs.removeAll()
    }

    /// The reader keeps reading while the listener isn't current, so a transition that leaves the
    /// binding in place loses nothing. A replaced installation or a retired listener stops it.
    private func reads(_ installation: UUID) -> Bool {
        !Task.isCancelled && installationID == installation && !isRetired
    }

    private func process(_ event: NativeAgentRuntimeEvent) {
        switch event {
        case let .providerTurnStarted(turnID):
            providerTurnIDs.insert(turnID)
            transportProviderTurnIDs.insert(turnID)
        case let .turnsCompleted(turnIDs, _):
            providerTurnIDs.subtract(turnIDs)
        case let .turnCompleted(turnID, _):
            providerTurnIDs.remove(turnID)
        case .approvalRequest:
            if let id = event.claudeApprovalRequestID, !routedOpenApprovalIDs.contains(id) {
                routedOpenApprovalIDs.append(id)
            }
        case let .approvalCancelled(id):
            routedOpenApprovalIDs.removeAll { $0 == id }
        default:
            break
        }
        route(event)
        publishBusyIfChanged()
    }

    private func routeHeldEvents() {
        while !heldEvents.isEmpty, !isRetired, isCurrent() {
            process(heldEvents.removeFirst())
        }
    }

    private func route(_ event: NativeAgentRuntimeEvent) {
        // `close` routes a whole tail, and a callback can retire the listener partway through it.
        guard !isRetired, isCurrent() else { return }
        if let subscription {
            subscription.append(.native(event))
        } else if pendingProviderTurnID != nil {
            handoff.append(event)
        } else if case let .providerTurnStarted(turnID) = event {
            pendingProviderTurnID = turnID
            handoff.append(event)
            onProviderTurn?(turnID)
        } else {
            onIdleEvent?(event)
        }
    }

    private func publishBusyIfChanged() {
        guard publishedBusy != isBusy else { return }
        publishedBusy = isBusy
        onBusyChanged?()
    }

    private func resumePublicationWaiters() {
        let waiters = publicationWaiters.values
        publicationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumePublicationWaiter(_ id: UInt64) {
        publicationWaiters.removeValue(forKey: id)?.resume()
    }
}

private extension NativeAgentRuntimeEvent {
    var startsProviderTurn: Bool {
        if case .providerTurnStarted = self {
            return true
        }
        return false
    }

    var claudeApprovalRequestID: String? {
        guard case let .approvalRequest(request) = self, case let .claudeControl(id) = request.requestID else { return nil }
        return id
    }
}
