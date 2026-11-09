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
