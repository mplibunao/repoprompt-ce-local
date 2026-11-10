@testable import RepoPromptApp
import XCTest

final class CodexNativeSessionControllerInterruptTests: XCTestCase {
    func testActiveTurnMismatchParserMatrix() {
        let rows: [(description: String, expectedTurnID: String?)] = [
            ("turn/interrupt failed: expected active turn id `turn-old` but found `turn-new`", "turn-new"),
            ("network failed", nil),
            ("expected active turn id `old` but found ``", nil),
            ("expected active turn id `old` but found turn-new", nil)
        ]

        for row in rows {
            XCTAssertEqual(
                CodexNativeSessionController.activeTurnMismatchActualTurnID(fromErrorDescription: row.description),
                row.expectedTurnID,
                row.description
            )
        }
    }

    func testResolvedInterruptTurnIDMatrix() {
        XCTAssertNil(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .refreshed(nil)
            )
        )
        XCTAssertNil(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .refreshed(" \t\n")
            )
        )
        XCTAssertEqual(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .failed
            ),
            "stale-turn"
        )
        XCTAssertEqual(
            CodexNativeSessionController.resolvedInterruptTurnID(
                cachedTurnID: "stale-turn",
                refreshResult: .refreshed("fresh-turn")
            ),
            "fresh-turn"
        )
    }
}

#if DEBUG
    /// On a Codex runtime of 0.164.0 or newer, the controller resumes a thread with `excludeTurns`
    /// and reads turn metadata as newest-first `thread/turns/list` pages of at most 32 turns, so a
    /// thread's full history never crosses the app-server transport. Older runtimes keep the
    /// full-history resume.
    final class CodexBoundedThreadSnapshotTests: XCTestCase {
        func testResumeRequestGatesPaginationWithoutChangingIdentityOrPath() async throws {
            for bounded in [false, true] {
                let log = RequestLog()
                let controller = makeController(log: log) { _, params, _ in
                    XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                    XCTAssertEqual(params?["path"] as? String, "/fixture/rollout.jsonl")
                    XCTAssertNil(params?["baseInstructions"])
                    if bounded {
                        XCTAssertEqual(params?["excludeTurns"] as? Bool, true)
                        let page = try XCTUnwrap(params?["initialTurnsPage"] as? [String: Any])
                        XCTAssertEqual(page["itemsView"] as? String, "notLoaded")
                        XCTAssertEqual(page["sortDirection"] as? String, "desc")
                        XCTAssertEqual(page["limit"] as? Int, 32)
                        return Self.response(page: Self.page())
                    }
                    XCTAssertNil(params?["excludeTurns"])
                    XCTAssertNil(params?["initialTurnsPage"])
                    return Self.response()
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: bounded ? 164 : 149, patch: 0))
                let result = try await controller.test_resumeThreadBinding(existing: .init(
                    conversationID: "thread-fixture", rolloutPath: "/fixture/rollout.jsonl", model: nil, reasoningEffort: nil
                ))
                XCTAssertEqual((result["thread"] as? [String: Any])?["id"] as? String, "thread-fixture")
                XCTAssertEqual(log.methods, ["thread/resume"], "bounded: \(bounded)")
            }
        }

        func testRichReadUsesOneBoundedMetadataPageAndLegacyKeepsExistingRead() async throws {
            for bounded in [false, true] {
                let log = RequestLog()
                let controller = makeController(log: log) { method, params, timeout in
                    XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                    switch method {
                    case "thread/read":
                        XCTAssertEqual(params?["includeTurns"] as? Bool, !bounded)
                        return Self.response(
                            active: true,
                            turns: bounded ? [] : [["id": "active-from-read", "status": "inProgress", "items": []]]
                        )
                    case "thread/turns/list":
                        XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                        XCTAssertEqual(params?["limit"] as? Int, 32)
                        XCTAssertNil(params?["cursor"])
                        XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 2)
                        return Self.page(turns: [["id": "active-from-read", "status": "inProgress", "itemsView": "notLoaded"]])
                    default:
                        throw CodexAppServerClient.ClientError.invalidResponse
                    }
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: bounded ? 164 : 149, patch: 0))
                controller.test_installThreadState(threadID: "thread-fixture", routingTurnID: "cached-old-turn")
                let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
                XCTAssertEqual(log.methods, bounded ? ["thread/read", "thread/turns/list"] : ["thread/read"])
                XCTAssertEqual(snapshot.conversationID, "thread-fixture")
                XCTAssertEqual(snapshot.currentTurnID, "active-from-read")
                XCTAssertEqual(snapshot.activeTurnIDs, ["active-from-read"])
                XCTAssertTrue(snapshot.hasActiveTurn)
                XCTAssertTrue(snapshot.hasCompleteTurnMetadata)
            }

            // When the read's timeout runs out before the page request, the read fails as a timeout
            // and requests no page.
            let log = RequestLog()
            let controller = makeController(log: log) { _, _, _ in
                try await Task.sleep(for: .milliseconds(20))
                return Self.response(active: true)
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            do {
                _ = try await controller.readThreadSnapshot(includeTurns: true, timeout: 0.005)
                XCTFail("Expected the bounded read to time out")
            } catch {
                XCTAssertTrue(CodexAppServerClient.isTimeoutError(error), "\(error)")
            }
            XCTAssertEqual(log.methods, ["thread/read"])
        }

        func testMetadataOnlyReadDoesNotFetchTurns() async throws {
            let log = RequestLog()
            let controller = makeController(log: log) { _, params, _ in
                XCTAssertEqual(params?["includeTurns"] as? Bool, false)
                return Self.response()
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            _ = try await controller.readThreadSnapshot(includeTurns: false, timeout: 2)
            XCTAssertEqual(log.methods, ["thread/read"])
        }

        func testDescendingPagePreservesNewestFailureAndActiveRoutingWithoutItemAuthority() {
            let result = Self.response(page: Self.page(turns: [
                ["id": "active-new", "status": "inProgress", "itemsView": "notLoaded", "items": []],
                ["id": "active-old", "status": "inProgress", "itemsView": "notLoaded"],
                ["id": "failed-new", "status": "failed", "error": ["message": "new failure"]],
                ["id": "completed-old", "status": "completed"]
            ], nextCursor: "older"))
            let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(result, fallbackEffort: "high")
            XCTAssertEqual(snapshot.activeTurnIDs, ["active-old", "active-new"])
            XCTAssertEqual(snapshot.currentTurnID, "active-new")
            XCTAssertEqual(snapshot.latestTerminalTurnID, "failed-new")
            XCTAssertEqual(snapshot.latestTurnStatus, .failed)
            XCTAssertEqual(snapshot.latestTurnFailure?.message, "new failure")
            XCTAssertEqual(snapshot.reasoningEffort, "high")
            XCTAssertTrue(snapshot.hasActiveTurn)
            XCTAssertFalse(snapshot.hasCompleteTurnMetadata)
            XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems)
            XCTAssertTrue(snapshot.activeToolItems.isEmpty)
        }

        func testInterruptExhaustsThirtyThreeTurnMetadataAndRejectsSecondActiveAcrossPages() async throws {
            for secondActive in [false, true] {
                let log = RequestLog()
                let controller = makeController(log: log) { method, params, timeout in
                    XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                    XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 5)
                    switch method {
                    case "thread/read":
                        XCTAssertEqual(params?["includeTurns"] as? Bool, false)
                        return Self.response(active: true)
                    case "thread/turns/list":
                        XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                        XCTAssertEqual(params?["limit"] as? Int, 32)
                        guard let cursor = params?["cursor"] else {
                            let completed: [[String: Any]] = (1 ... 31).map { ["id": "completed-\($0)", "status": "completed"] }
                            return Self.page(turns: [["id": "active", "status": "inProgress"]] + completed, nextCursor: "older")
                        }
                        XCTAssertEqual(cursor as? String, "older")
                        return Self.page(
                            turns: [["id": "oldest", "status": secondActive ? "inProgress" : "completed"]],
                            nextCursor: secondActive ? "must-not-fetch" : nil
                        )
                    case "turn/interrupt":
                        XCTAssertEqual(params?["turnId"] as? String, "active")
                        return [:]
                    default:
                        throw CodexAppServerClient.ClientError.invalidResponse
                    }
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                controller.test_installThreadState(threadID: "thread-fixture")
                do {
                    let receipt = try await controller.reconcileAndInterruptCurrentTurn()
                    XCTAssertFalse(secondActive)
                    XCTAssertEqual(receipt.interruptedTurnID, "active")
                } catch let CodexTurnInterruptError.noUniqueActiveTurn(_, observed) {
                    XCTAssertTrue(secondActive)
                    XCTAssertEqual(observed, ["active", "oldest"])
                }
                let reads = ["thread/read", "thread/turns/list", "thread/turns/list"]
                XCTAssertEqual(log.methods, secondActive ? reads : reads + ["turn/interrupt"], "second active: \(secondActive)")
            }
        }

        func testOrdinarySnapshotStillStopsAfterOnePartialMetadataPage() async throws {
            let log = RequestLog()
            let controller = makeController(log: log) { method, params, _ in
                if method == "thread/read" {
                    return Self.response(active: true)
                }
                XCTAssertNil(params?["cursor"], "Only Stop may exhaust metadata")
                return Self.page(turns: [["id": "active", "status": "inProgress"]], nextCursor: "older")
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
            XCTAssertEqual(log.methods, ["thread/read", "thread/turns/list"])
            XCTAssertEqual(snapshot.activeTurnIDs, ["active"])
            XCTAssertFalse(snapshot.hasCompleteTurnMetadata)
            XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems)
        }

        func testInterruptRejectsCursorCyclesMalformedPagesAndUnknownStatuses() async throws {
            let variants = [
                "cycle", "bad-cursor", "empty-cursor", "bad-data", "unknown-status", "page-over-limit", "thread-rebound"
            ]
            for variant in variants {
                let log = RequestLog()
                let box = ControllerBox()
                let controller = makeController(log: log) { method, _, _ in
                    if method == "thread/read" {
                        return Self.response(active: true)
                    }
                    // Each page would otherwise prove that `active` is the only active turn.
                    let active: [String: Any] = ["id": "active", "status": "inProgress"]
                    var page = Self.page(turns: [active])
                    switch variant {
                    case "cycle":
                        page["nextCursor"] = "older"
                    case "bad-cursor":
                        page["nextCursor"] = 123
                    case "empty-cursor":
                        page["nextCursor"] = ""
                    case "bad-data":
                        page["data"] = [["status": "completed"]]
                    case "unknown-status":
                        page["data"] = [active, ["id": "future-turn", "status": "futureStatus"]]
                    case "page-over-limit":
                        let completed: [[String: Any]] = (1 ... 32).map { ["id": "completed-\($0)", "status": "completed"] }
                        page["data"] = [active] + completed
                    case "thread-rebound":
                        box.controller?.test_installThreadState(threadID: "other-thread")
                    default:
                        break
                    }
                    return page
                }
                box.controller = controller
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                controller.test_installThreadState(threadID: "thread-fixture")
                do {
                    _ = try await controller.reconcileAndInterruptCurrentTurn()
                    XCTFail("\(variant) authorized an interrupt")
                } catch CodexAppServerClient.ClientError.invalidResponse {}
                let pageRequests = Array(repeating: "thread/turns/list", count: variant == "cycle" ? 2 : 1)
                XCTAssertEqual(log.methods, ["thread/read"] + pageRequests, variant)
            }

            // A lifecycle turn that appears during the reads and differs from the turn the pages
            // found blocks the interrupt.
            let log = RequestLog()
            let box = ControllerBox()
            let controller = makeController(log: log) { method, _, _ in
                if method == "thread/read" {
                    return Self.response(active: true)
                }
                box.controller?.test_installThreadState(threadID: "thread-fixture", authoritativeTurnID: "other-turn")
                return Self.page(turns: [["id": "active", "status": "inProgress"]])
            }
            box.controller = controller
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture")
            do {
                _ = try await controller.reconcileAndInterruptCurrentTurn()
                XCTFail("lifecycle-appeared authorized an interrupt")
            } catch let error as CodexTurnInterruptError {
                XCTAssertEqual(error, .reconciliationFailed(expectedTurnID: "active", authoritativeTurnID: "other-turn"))
            }
            XCTAssertEqual(log.methods, ["thread/read", "thread/turns/list"])
        }

        func testInterruptPaginationHonorsSharedDeadlineAndCancellationWithoutInterrupt() async throws {
            for cancel in [false, true] {
                var options = CodexNativeSessionController.Options.agentModeDefault()
                options.requestTimeout = cancel ? 5 : 0.005
                let log = RequestLog()
                let controller = makeController(options: options, log: log) { method, _, _ in
                    if method == "thread/read" {
                        return Self.response(active: true)
                    }
                    if cancel {
                        withUnsafeCurrentTask { $0?.cancel() }
                    } else {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    return Self.page(turns: [["id": "active", "status": "inProgress"]], nextCursor: "older")
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                controller.test_installThreadState(threadID: "thread-fixture")
                let task = Task { try await controller.reconcileAndInterruptCurrentTurn() }
                do {
                    _ = try await task.value
                    XCTFail("Expected cancellation or timeout")
                } catch is CancellationError {
                    XCTAssertTrue(cancel)
                } catch {
                    XCTAssertFalse(cancel)
                    XCTAssertTrue(CodexAppServerClient.isTimeoutError(error), "\(error)")
                }
                XCTAssertFalse(log.methods.contains("turn/interrupt"), "cancel: \(cancel)")
            }
        }

        func testResumeRejectsWrongIdentityAndMalformedInitialPage() async throws {
            for variant in ["wrong-thread", "malformed-page"] {
                let log = RequestLog()
                let controller = makeController(log: log) { _, _, _ in
                    variant == "wrong-thread"
                        ? ["thread": ["id": "different-thread"], "initialTurnsPage": Self.page()]
                        : Self.response(page: ["data": "invalid"])
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                do {
                    _ = try await controller.test_resumeThreadBinding(existing: .init(
                        conversationID: "thread-fixture", rolloutPath: nil, model: nil, reasoningEffort: nil
                    ))
                    XCTFail("\(variant) was accepted")
                } catch CodexAppServerClient.ClientError.invalidResponse {}
                XCTAssertEqual(log.methods, ["thread/resume"], "\(variant) requested a fallback page")
            }

            // A thread without its own identity goes back unchanged, and the binding check rejects it
            // with the same error as any resume response that doesn't identify a thread.
            for variant in ["nested-id", "coerced-id"] {
                let log = RequestLog()
                let controller = makeController(log: log) { _, _, _ in
                    let thread: [String: Any] = variant == "nested-id"
                        ? ["nested": ["id": "thread-fixture"]]
                        : ["id": 123]
                    return ["thread": thread, "initialTurnsPage": Self.page()]
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                let result = try await controller.test_resumeThreadBinding(existing: .init(
                    conversationID: variant == "coerced-id" ? "123" : "thread-fixture",
                    rolloutPath: nil,
                    model: nil,
                    reasoningEffort: nil
                ))
                XCTAssertEqual(log.methods, ["thread/resume"], "\(variant) requested a fallback page")
                try await controller.test_beginBindingSession()
                do {
                    _ = try await controller.test_completeThreadBinding(response: result, request: .resume, fallbackEffort: nil)
                    XCTFail("\(variant) was bound")
                } catch {
                    XCTAssertEqual(
                        error as? CodexSessionControllerError,
                        .threadBindingResponseMissingThreadID(.resume),
                        variant
                    )
                }
            }
        }

        func testResumeMissingOrNullInitialPageUsesOneBoundedFallbackBeforeBinding() async throws {
            for nullPage in [false, true] {
                let log = RequestLog()
                let controller = makeController(log: log) { method, params, timeout in
                    XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                    if method == "thread/resume" {
                        XCTAssertEqual(params?["excludeTurns"] as? Bool, true)
                        var response = Self.response(active: true)
                        if nullPage {
                            response["initialTurnsPage"] = NSNull()
                        }
                        return response
                    }
                    XCTAssertNil(params?["cursor"])
                    XCTAssertEqual(params?["limit"] as? Int, 32)
                    XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                    XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 5)
                    return Self.page(turns: [["id": "resumed-active", "status": "inProgress"]], nextCursor: "older")
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                try await controller.test_beginBindingSession()
                let result = try await controller.test_resumeThreadBinding(existing: .init(
                    conversationID: "thread-fixture", rolloutPath: nil, model: nil, reasoningEffort: nil
                ))
                XCTAssertEqual(log.methods, ["thread/resume", "thread/turns/list"], "null page: \(nullPage)")
                let reference = try await controller.test_completeThreadBinding(
                    response: result,
                    request: .resume,
                    fallbackEffort: nil
                )
                XCTAssertEqual(reference.conversationID, "thread-fixture")
                XCTAssertEqual(controller.test_routingCurrentTurnID, "resumed-active")
            }
        }

        func testResumeFallbackHonorsOriginalDeadlineAndCancellation() async throws {
            for cancel in [false, true] {
                let log = RequestLog()
                let controller = makeController(log: log) { _, _, _ in
                    if cancel {
                        withUnsafeCurrentTask { $0?.cancel() }
                    } else {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    return Self.response()
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                let task = Task {
                    try await controller.test_resumeThreadBinding(existing: .init(
                        conversationID: "thread-fixture", rolloutPath: nil, model: nil, reasoningEffort: nil
                    ), timeout: cancel ? 5 : 0.005)
                }
                do {
                    _ = try await task.value
                    XCTFail("Expected cancellation or timeout")
                } catch is CancellationError {
                    XCTAssertTrue(cancel)
                } catch {
                    XCTAssertFalse(cancel)
                    XCTAssertTrue(CodexAppServerClient.isTimeoutError(error), "\(error)")
                }
                XCTAssertEqual(log.methods, ["thread/resume"], "cancel: \(cancel)")
            }
        }

        func testNativeToolProbeRestoresExactFullCurrentTurnEvidenceIncludingTerminalItems() async throws {
            for itemStatus in ["inProgress", "completed"] {
                let log = RequestLog()
                let controller = makeController(log: log) { method, params, timeout in
                    XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                    switch method {
                    case "thread/read":
                        XCTAssertEqual(params?["includeTurns"] as? Bool, false)
                        return Self.response(active: true)
                    case "thread/turns/list":
                        XCTAssertEqual(params?["limit"] as? Int, 1)
                        XCTAssertEqual(params?["itemsView"] as? String, "full")
                        XCTAssertEqual(params?["sortDirection"] as? String, "desc")
                        XCTAssertNil(params?["cursor"])
                        XCTAssertLessThanOrEqual(try XCTUnwrap(timeout), 2)
                        return Self.page(turns: [[
                            "id": "active-probe", "status": "inProgress", "itemsView": "full",
                            "items": [
                                ["id": "call_probe", "type": "dynamicToolCall", "tool": "offline_probe_wait", "status": itemStatus],
                                ["id": "command-a", "type": "commandExecution", "processId": "123", "status": "inProgress"],
                                ["id": "command-b", "type": "commandExecution", "processId": "123", "status": "completed"]
                            ]
                        ]], nextCursor: "older-turns")
                    default:
                        throw CodexAppServerClient.ClientError.invalidResponse
                    }
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                controller.test_installThreadState(threadID: "thread-fixture")
                let snapshot = try await controller.readNativeToolProbeSnapshot(expectedTurnID: "active-probe", timeout: 2)
                XCTAssertEqual(log.methods, ["thread/read", "thread/turns/list"])
                XCTAssertEqual(snapshot.currentTurnID, "active-probe")
                XCTAssertNil(snapshot.latestTerminalTurnID, "The probe reads only the current turn, not earlier terminal turns")
                XCTAssertNil(snapshot.latestTurnStatus)
                XCTAssertTrue(snapshot.hasAuthoritativeActiveTurnItems)
                XCTAssertFalse(snapshot.hasCompleteTurnMetadata, "Older turns are omitted, but the active turn's items are complete")
                let item = try XCTUnwrap(snapshot.activeToolItems.first)
                XCTAssertEqual(item.turnID, "active-probe")
                XCTAssertEqual(item.itemID, "call_probe")
                XCTAssertNotNil(item.invocationID)
                XCTAssertEqual(
                    snapshot.activeToolItems.filter { $0.kind == .commandExecution }.map(\.itemID),
                    ["command-a", "command-b"],
                    "The coordinator's process-ID ambiguity check needs every command, finished ones included"
                )
                XCTAssertEqual(item.kind, .dynamicToolCall)
                XCTAssertEqual(item.status, itemStatus == "inProgress" ? .inProgress : .terminal)
            }
        }

        func testNativeToolProbeRejectsWrongTurnPartialOrMalformedItemAuthority() async throws {
            let variants = [
                "wrong-turn", "summary", "notLoaded", "missing-view", "missing-items", "malformed-item", "terminal-turn",
                "multiple-turns"
            ]
            for variant in variants {
                let log = RequestLog()
                let controller = makeController(log: log) { method, _, _ in
                    if method == "thread/read" {
                        return Self.response(active: true)
                    }
                    var turn: [String: Any] = [
                        "id": variant == "wrong-turn" ? "other-active" : "active-probe",
                        "status": variant == "terminal-turn" ? "completed" : "inProgress",
                        "itemsView": "full",
                        "items": [["id": "call_probe", "type": "commandExecution", "status": "inProgress", "processId": "123"]]
                    ]
                    switch variant {
                    case "summary", "notLoaded": turn["itemsView"] = variant
                    case "missing-view": turn["itemsView"] = nil
                    case "missing-items": turn["items"] = nil
                    case "malformed-item": turn["items"] = [["type": "commandExecution", "processId": "123"]]
                    default: break
                    }
                    let turns: [[String: Any]] = variant == "multiple-turns"
                        ? [turn, ["id": "other-active", "status": "inProgress", "itemsView": "full", "items": []]]
                        : [turn]
                    return Self.page(turns: turns)
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
                controller.test_installThreadState(threadID: "thread-fixture")
                let snapshot = try await controller.readNativeToolProbeSnapshot(expectedTurnID: "active-probe", timeout: 2)
                XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems, variant)
                XCTAssertEqual(log.methods, ["thread/read", "thread/turns/list"], "\(variant) fetched more history")
            }
        }

        func testNativeToolProbeKeepsIdleThreadsMetadataOnlyAndOlderRuntimeRichRead() async throws {
            for bounded in [false, true] {
                let log = RequestLog()
                let controller = makeController(log: log) { method, params, _ in
                    switch method {
                    case "thread/read":
                        XCTAssertEqual(params?["includeTurns"] as? Bool, !bounded)
                        return Self.response()
                    case "thread/turns/list":
                        XCTAssertEqual(params?["itemsView"] as? String, "notLoaded")
                        XCTAssertEqual(params?["limit"] as? Int, 32)
                        return Self.page(turns: [["id": "latest-completed", "status": "completed", "itemsView": "notLoaded"]])
                    default:
                        throw CodexAppServerClient.ClientError.invalidResponse
                    }
                }
                controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: bounded ? 164 : 149, patch: 0))
                controller.test_installThreadState(threadID: "thread-fixture")
                let snapshot = try await controller.readNativeToolProbeSnapshot(expectedTurnID: "prior-active", timeout: 2)
                XCTAssertEqual(log.methods, bounded ? ["thread/read", "thread/turns/list"] : ["thread/read"])
                XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems)
                XCTAssertFalse(snapshot.hasActiveTurn)
            }
        }

        func testLifecycleAuthoritativeInterruptDoesNotNeedHistoryUniquenessProbe() async throws {
            let log = RequestLog()
            let controller = makeController(log: log) { _, params, _ in
                XCTAssertEqual(params?["threadId"] as? String, "thread-fixture")
                XCTAssertEqual(params?["turnId"] as? String, "lifecycle-active")
                return [:]
            }
            controller.test_configureSnapshotRuntime(version: .init(major: 0, minor: 164, patch: 0))
            controller.test_installThreadState(threadID: "thread-fixture", authoritativeTurnID: "lifecycle-active")
            let receipt = try await controller.reconcileAndInterruptCurrentTurn()
            XCTAssertEqual(receipt.interruptedTurnID, "lifecycle-active")
            XCTAssertEqual(log.methods, ["turn/interrupt"], "The lifecycle turn needs no history read")
        }

        // MARK: - Fixture

        /// Records the method of every request the controller sends. The request executor is
        /// `@Sendable` and runs outside the test's isolation, so the log is lock-protected.
        private final class RequestLog: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [String] = []

            func record(_ method: String) {
                lock.withLock { recorded.append(method) }
            }

            var methods: [String] {
                lock.withLock { recorded }
            }
        }

        /// Lets a request executor reach the controller it serves. The controller exists only after
        /// its initializer receives the executor, so the test sets the box afterwards.
        private final class ControllerBox: @unchecked Sendable {
            weak var controller: CodexNativeSessionController?
        }

        private func makeController(
            options: CodexNativeSessionController.Options? = nil,
            log: RequestLog = RequestLog(),
            request: @escaping @Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any]
        ) -> CodexNativeSessionController {
            CodexNativeSessionController(
                client: CodexAppServerClient(),
                runID: UUID(),
                tabID: UUID(),
                windowID: 1,
                workspacePaths: .uniform(NSTemporaryDirectory()),
                options: options,
                requestExecutor: { method, params, timeout in
                    log.record(method)
                    return try await request(method, params, timeout)
                }
            )
        }

        private static func response(
            page: [String: Any]? = nil,
            active: Bool = false,
            turns: [[String: Any]] = []
        ) -> [String: Any] {
            var result: [String: Any] = [
                "thread": ["id": "thread-fixture", "status": ["type": active ? "active" : "idle"], "turns": turns]
            ]
            result["initialTurnsPage"] = page
            return result
        }

        private static func page(turns: [[String: Any]] = [], nextCursor: String? = nil) -> [String: Any] {
            ["data": turns, "nextCursor": nextCursor.map { $0 as Any } ?? NSNull()]
        }
    }
#endif
