import Foundation
@testable import RepoPromptApp
import XCTest

/// The listener and its tasks all run on the main actor, one job at a time. A task that waits on
/// the listener fulfills an expectation just before it suspends, so once the test resumes from
/// that expectation the task is already waiting.
@MainActor
final class ClaudeControllerEventListenerTests: XCTestCase {
    private typealias Event = NativeAgentRuntimeEvent

    func testCancellingAnAttemptWaitDoesNotStopTheReader() async throws {
        let listener = ClaudeControllerEventListener(isCurrent: { true })
        let adoptionRequests = Recorder<UUID>()
        let providerTurnArrived = expectation(description: "a provider turn reaches the listener")
        listener.onProviderTurn = { turnID in
            adoptionRequests.values.append(turnID)
            providerTurnArrived.fulfill()
        }
        let events = install(listener, generation: 1)
        let inbox = try XCTUnwrap(listener.reserve())
        let firstRead = expectation(description: "the attempt read its first event")
        let attempt = Task { @MainActor in
            _ = await inbox.next()
            firstRead.fulfill()
            return await self.describe(inbox.next())
        }
        events.yield(output("host"))
        await fulfillment(of: [firstRead], timeout: 5)

        attempt.cancel()
        let afterCancel = await value(of: attempt, "the cancelled wait returns")
        XCTAssertEqual(afterCancel, "end")
        listener.close(inbox, returningTail: true)
        listener.terminalPublished(for: inbox)

        let providerTurnID = UUID()
        events.yield(.providerTurnStarted(turnID: providerTurnID))
        await fulfillment(of: [providerTurnArrived], timeout: 5)
        XCTAssertEqual(adoptionRequests.values, [providerTurnID])
        listener.retire()
    }

    func testClosingAnAttemptPassesItsUnreadProviderTurnToTheNextAttempt() async throws {
        let listener = ClaudeControllerEventListener(isCurrent: { true })
        let idleEvents = Recorder<String>()
        let adoptionRequests = Recorder<UUID>()
        listener.onIdleEvent = { idleEvents.values.append(self.describe(.native($0))) }
        listener.onProviderTurn = { adoptionRequests.values.append($0) }
        let hostTurnID = UUID()
        let providerTurnID = UUID()
        let first = try XCTUnwrap(listener.reserve())
        // The attempt reads only its own answer from these events. The output after it and the
        // turn Claude Code starts by itself stay unread.
        for event: Event in [
            output("host"),
            .turnCompleted(turnID: hostTurnID, status: .completed),
            output("late host"),
            .providerTurnStarted(turnID: providerTurnID),
            output("provider")
        ] {
            listener.receive(event)
        }
        let firstRead = await read(first)
        let secondRead = await read(first)
        XCTAssertEqual([firstRead, secondRead], ["output:host", "completed:\(hostTurnID)"])

        listener.close(first, returningTail: true)
        XCTAssertEqual(idleEvents.values, ["output:late host"])
        XCTAssertEqual(adoptionRequests.values, [providerTurnID])
        XCTAssertEqual(listener.pendingProviderTurnID, providerTurnID)

        let adopted = try XCTUnwrap(listener.reserve())
        XCTAssertNil(listener.pendingProviderTurnID)
        let adoptedFirst = await read(adopted)
        let adoptedSecond = await read(adopted)
        XCTAssertEqual([adoptedFirst, adoptedSecond], ["providerStart:\(providerTurnID)", "output:provider"])
        listener.retire()
    }

    func testAdoptionWaitsForTheClosedAttemptsPublication() async throws {
        let listener = ClaudeControllerEventListener(isCurrent: { true })
        let closed = try XCTUnwrap(listener.reserve())
        listener.close(closed, returningTail: true)
        let order = Recorder<String>()
        let adoptionWaiting = expectation(description: "the adoption waits for publication")
        let adoption = Task { @MainActor in
            adoptionWaiting.fulfill()
            await listener.awaitTerminalPublication()
            order.values.append("adoption")
        }
        await fulfillment(of: [adoptionWaiting], timeout: 5)
        order.values.append("published")
        listener.terminalPublished(for: closed)
        _ = await value(of: adoption, "the adoption proceeds after publication")
        XCTAssertEqual(order.values, ["published", "adoption"])
        listener.retire()
    }

    func testReplacingTheTransportKeepsTheInboxAndAdmitsOnlyTheReplacementsEvents() async throws {
        let listener = ClaudeControllerEventListener(isCurrent: { true })
        let controller = makeController()
        let streamEnds = Recorder<UUID>()
        let replacementEnded = expectation(description: "the replacement's stream end is reported")
        // A report for the retired stream fails the `streamEnds` assertion below rather than
        // raising inside an async callback.
        replacementEnded.assertForOverFulfill = false
        listener.onStreamEnd = { installation in
            streamEnds.values.append(installation)
            replacementEnded.fulfill()
        }
        let providerTurnReceived = expectation(description: "the retired transport's provider turn is received")
        listener.onBusyChanged = { [unowned listener] in
            if listener.isBusy {
                providerTurnReceived.fulfill()
            }
        }
        let retired = install(listener, controller: controller, generation: 1)
        let inbox = try XCTUnwrap(listener.reserve())
        retired.yield(output("old read"))
        let oldRead = await read(inbox)
        XCTAssertEqual(oldRead, "output:old read")
        retired.yield(output("old unread"))
        retired.yield(.providerTurnStarted(turnID: UUID()))
        await fulfillment(of: [providerTurnReceived], timeout: 5)

        // The retired reader is still waiting on its stream when this arrives, so that reader is
        // the one that must reject it.
        retired.yield(output("stale"))
        retired.finish()
        inbox.finish()
        listener.detachTransport()
        XCTAssertFalse(listener.isBusy)
        let replacement = install(listener, controller: controller, generation: 2)
        let replacementInstallation = listener.installationWitness
        replacement.yield(output("fresh"))

        let replacementRead = await read(inbox)
        XCTAssertEqual(replacementRead, "output:fresh")
        XCTAssertTrue(listener.subscription === inbox)
        replacement.finish()
        await fulfillment(of: [replacementEnded], timeout: 5)
        XCTAssertEqual(streamEnds.values, [replacementInstallation])
        listener.retire()
    }

    func testRetirementReleasesTheAttemptPublicationWaitersAndReader() async throws {
        let listener = ClaudeControllerEventListener(isCurrent: { true })
        let (stream, events) = AsyncStream.makeStream(of: Event.self)
        let readerStopped = expectation(description: "the reader stops reading")
        events.onTermination = { _ in readerStopped.fulfill() }
        listener.install(controller: makeController(), handle: NativeAgentRuntimeEventStreamHandle(generation: 1, stream: stream))
        let previous = try XCTUnwrap(listener.reserve())
        listener.close(previous, returningTail: true)
        let inbox = try XCTUnwrap(listener.reserve())
        events.yield(output("running"))
        let running = await read(inbox)
        XCTAssertEqual(running, "output:running")

        let waiting = expectation(description: "the attempt, the adoption, and a publication waiter are waiting")
        waiting.expectedFulfillmentCount = 3
        let attempt = Task { @MainActor in
            waiting.fulfill()
            return await self.describe(inbox.next())
        }
        let adoption = Task { @MainActor in
            waiting.fulfill()
            await listener.awaitTerminalPublication()
        }
        listener.adoptionTask = adoption
        let publicationWaiter = Task { @MainActor in
            waiting.fulfill()
            await listener.awaitTerminalPublication()
            return "returned"
        }
        await fulfillment(of: [waiting], timeout: 5)
        listener.retire()

        await fulfillment(of: [readerStopped], timeout: 5)
        let attemptEnd = await value(of: attempt, "the attempt's wait returns")
        XCTAssertEqual(attemptEnd, "end")
        let publicationWaitEnd = await value(of: publicationWaiter, "the publication wait returns")
        XCTAssertEqual(publicationWaitEnd, "returned")
        XCTAssertTrue(adoption.isCancelled)
        XCTAssertNil(listener.adoptionTask)
        XCTAssertNil(listener.reserve())
    }

    func testBufferedApprovalRequestsAreReplacedByCancellations() async throws {
        let listener = ClaudeControllerEventListener(isCurrent: { true })
        let inbox = try XCTUnwrap(listener.reserve())
        listener.receive(approval("in-inbox"))
        listener.receive(output("after"))
        XCTAssertEqual(listener.bufferedApprovalIDs, ["in-inbox"])
        listener.cancelBufferedApproval("in-inbox")
        XCTAssertEqual(listener.bufferedApprovalIDs, [])
        let inboxFirst = await read(inbox)
        let inboxSecond = await read(inbox)
        XCTAssertEqual([inboxFirst, inboxSecond], ["approvalCancelled:in-inbox", "output:after"])
        listener.close(inbox, returningTail: false)

        let providerTurnID = UUID()
        listener.receive(.providerTurnStarted(turnID: providerTurnID))
        listener.receive(approval("in-handoff"))
        XCTAssertEqual(listener.bufferedApprovalIDs, ["in-handoff"])
        listener.cancelBufferedApproval("in-handoff")
        XCTAssertEqual(listener.bufferedApprovalIDs, [])
        let adopted = try XCTUnwrap(listener.reserve())
        let adoptedFirst = await read(adopted)
        let adoptedSecond = await read(adopted)
        XCTAssertEqual([adoptedFirst, adoptedSecond], ["providerStart:\(providerTurnID)", "approvalCancelled:in-handoff"])
        listener.retire()
    }

    func testInputHandoffHoldsDeliveryUntilTheSendIsRecorded() async throws {
        let listener = ClaudeControllerEventListener(isCurrent: { true })
        let inbox = try XCTUnwrap(listener.reserve())
        let turnID = UUID()
        let order = Recorder<String>()
        inbox.beginInputHandoff()
        listener.receive(.turnCompleted(turnID: turnID, status: .completed))
        let attemptReading = expectation(description: "the attempt reads during the send")
        let attempt = Task { @MainActor in
            attemptReading.fulfill()
            let event = await self.describe(inbox.next())
            order.values.append("delivered \(event)")
        }
        await fulfillment(of: [attemptReading], timeout: 5)
        order.values.append("input ID recorded")
        inbox.endInputHandoff()
        _ = await value(of: attempt, "the attempt receives the completion")
        XCTAssertEqual(order.values, ["input ID recorded", "delivered completed:\(turnID)"])
        listener.retire()
    }

    // MARK: - Helpers

    @MainActor
    private final class Recorder<Value> {
        var values: [Value] = []
    }

    /// A controller used only for its identity. No process starts.
    private func makeController() -> ClaudeNativeProcessSessionController {
        ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false")
        )
    }

    private func install(
        _ listener: ClaudeControllerEventListener,
        controller: ClaudeNativeProcessSessionController? = nil,
        generation: UInt64
    ) -> AsyncStream<Event>.Continuation {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        listener.install(
            controller: controller ?? makeController(),
            handle: NativeAgentRuntimeEventStreamHandle(generation: generation, stream: stream)
        )
        return continuation
    }

    /// Awaits `task`, failing the test instead of hanging when it doesn't finish.
    private func value<T>(of task: Task<T, Never>, _ description: String) async -> T? {
        let finished = expectation(description: description)
        let result = Recorder<T>()
        Task { @MainActor in
            await result.values.append(task.value)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        return result.values.first
    }

    /// Reads the next event from `inbox`, failing the test instead of hanging when none arrives.
    private func read(_ inbox: ClaudeAttemptEventSubscription) async -> String? {
        await value(of: Task { @MainActor in await self.describe(inbox.next()) }, "the inbox delivers an event")
    }

    private func output(_ text: String) -> Event {
        .stream(AIStreamResult(type: "content", text: text))
    }

    private func approval(_ id: String) -> Event {
        .approvalRequest(AgentApprovalRequest(
            requestID: .claudeControl(id),
            method: "can_use_tool",
            kind: .commandExecution,
            threadID: "",
            turnID: "",
            itemID: id
        ))
    }

    private func describe(_ event: ClaudeAttemptEvent?) -> String {
        guard let event else { return "end" }
        guard case let .native(native) = event else { return "coordinator event" }
        switch native {
        case let .stream(result):
            return "output:\(result.text ?? "")"
        case let .providerTurnStarted(turnID):
            return "providerStart:\(turnID)"
        case let .turnCompleted(turnID, _):
            return "completed:\(turnID)"
        case .approvalRequest:
            return "approval"
        case let .approvalCancelled(requestID):
            return "approvalCancelled:\(requestID)"
        default:
            return "other"
        }
    }
}
