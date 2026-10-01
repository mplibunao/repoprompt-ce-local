import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

#if DEBUG
    /// A Codex approval may be answered only with a decision its request offered, only by an answer
    /// issued for that request, and every overlapping approval must receive its own answer.
    @MainActor
    final class CodexApprovalDecisionConstraintTests: XCTestCase {
        private var storageRoot: URL!
        private var fixtures: [Fixture] = []

        private static let rule = ["git", "status"]
        private static let amendmentEntry: [String: Any] = [
            "acceptWithExecpolicyAmendment": ["execpolicy_amendment": rule]
        ]

        override func setUp() async throws {
            try await super.setUp()
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexApprovalDecisionConstraintTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            for fixture in fixtures {
                fixture.session.runState = .idle
                fixture.session.codexController = nil
            }
            fixtures.removeAll()
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            storageRoot = nil
            try await super.tearDown()
        }

        // MARK: - Request parsing and presentation

        func testOfferedDecisionsAreTheOnlyDecisionsPresented() throws {
            let ruleJSON = try XCTUnwrap(AgentExecpolicyAmendment.json(for: Self.rule))
            let cases: [(
                label: String,
                params: [String: Any],
                constraint: AgentApprovalDecisionConstraint,
                presented: [AgentApprovalDecision],
                unsupported: String?
            )] = [
                ("terminal input", ["availableDecisions": ["accept", "cancel"]], .offered([.accept, .cancel]), [.cancel, .accept], nil),
                (
                    // A proposed rule that is not offered must not add a remember choice.
                    "proposal without offered amendment",
                    ["proposedExecpolicyAmendment": Self.rule, "availableDecisions": ["accept", "cancel"]],
                    .offered([.accept, .cancel]),
                    [.cancel, .accept],
                    nil
                ),
                (
                    "command with amendment",
                    ["proposedExecpolicyAmendment": Self.rule, "availableDecisions": ["accept", Self.amendmentEntry, "cancel"] as [Any]],
                    .offered([.accept, .acceptWithExecpolicyAmendment, .cancel], execpolicyAmendment: Self.rule),
                    [.cancel, .acceptWithExecpolicyAmendment(ruleJSON), .accept],
                    nil
                ),
                (
                    "amendment only",
                    ["availableDecisions": [Self.amendmentEntry]],
                    .offered([.acceptWithExecpolicyAmendment], execpolicyAmendment: Self.rule),
                    [.acceptWithExecpolicyAmendment(ruleJSON)],
                    nil
                ),
                (
                    "network approval",
                    [
                        "availableDecisions": [
                            "accept",
                            "acceptForSession",
                            ["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "example.com", "action": "allow"]]],
                            "cancel"
                        ] as [Any]
                    ],
                    .offered([.accept, .acceptForSession, .cancel]),
                    [.cancel, .acceptForSession, .accept],
                    "applyNetworkPolicyAmendment"
                ),
                (
                    "malformed amendment beside usable decisions",
                    ["availableDecisions": ["accept", ["acceptWithExecpolicyAmendment": [String: Any]()], "cancel"] as [Any]],
                    .offered([.accept, .cancel]),
                    [.cancel, .accept],
                    "acceptWithExecpolicyAmendment (malformed)"
                ),
                (
                    "unknown entries",
                    ["availableDecisions": [42, "acceptOnce", "cancel"] as [Any]],
                    .offered([.cancel]),
                    [.cancel],
                    "unrecognized value, acceptOnce"
                )
            ]

            for testCase in cases {
                let request = try XCTUnwrap(Self.parse(testCase.params), testCase.label)
                XCTAssertEqual(request.decisionConstraint, testCase.constraint, testCase.label)
                XCTAssertEqual(request.presentedDecisions, testCase.presented, testCase.label)
                XCTAssertEqual(
                    request.details.first(where: { $0.label == "Unsupported Offered Decisions" })?.value,
                    testCase.unsupported,
                    testCase.label
                )
            }
        }

        func testRequestWithoutOfferedDecisionsKeepsLegacyChoices() throws {
            let cases: [(label: String, method: String, params: [String: Any], alwaysAllow: AgentApprovalDecision?)] = [
                ("absent", "item/commandExecution/requestApproval", [:], .acceptForSession),
                ("null", "item/commandExecution/requestApproval", ["availableDecisions": NSNull()], .acceptForSession),
                ("file change", "item/fileChange/requestApproval", [:], .acceptForSession),
                ("amendment", "item/commandExecution/requestApproval", ["proposedExecpolicyAmendment": Self.rule], nil)
            ]

            for testCase in cases {
                let request = try XCTUnwrap(Self.parse(testCase.params, method: testCase.method), testCase.label)
                XCTAssertEqual(request.decisionConstraint, .unrestricted, testCase.label)
                let alwaysAllow = try testCase.alwaysAllow
                    ?? .acceptWithExecpolicyAmendment(XCTUnwrap(request.proposedExecpolicyAmendmentJSON, testCase.label))
                XCTAssertEqual(request.presentedDecisions, [.decline, alwaysAllow, .accept], testCase.label)
            }
        }

        func testMalformedOrUnusableOfferIsRefusedInsteadOfWidened() {
            let malformedAmendment = "availableDecisions offers only decisions RepoPrompt cannot send "
                + "(acceptWithExecpolicyAmendment (malformed))"
            let cases: [(label: String, offer: Any, reason: String)] = [
                ("scalar", "accept", "availableDecisions is not a list"),
                ("object", ["accept": true], "availableDecisions is not a list"),
                ("empty", [Any](), "availableDecisions is empty"),
                (
                    "only unsupported",
                    [["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "example.com", "action": "deny"]]]],
                    "availableDecisions offers only decisions RepoPrompt cannot send (applyNetworkPolicyAmendment)"
                ),
                (
                    "amendment named as a string",
                    ["acceptWithExecpolicyAmendment"],
                    "availableDecisions offers only decisions RepoPrompt cannot send (acceptWithExecpolicyAmendment)"
                ),
                ("amendment without a rule", [["acceptWithExecpolicyAmendment": [String: Any]()]], malformedAmendment),
                (
                    "amendment rule as text",
                    [["acceptWithExecpolicyAmendment": ["execpolicy_amendment": "git status"]]],
                    malformedAmendment
                ),
                (
                    "amendment rule with a non-string",
                    [["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["git", 1] as [Any]]]],
                    malformedAmendment
                ),
                (
                    "empty amendment rule",
                    [["acceptWithExecpolicyAmendment": ["execpolicy_amendment": [String]()]]],
                    malformedAmendment
                )
            ]

            for testCase in cases {
                let params = Self.baseParams.merging(["availableDecisions": testCase.offer]) { _, new in new }
                XCTAssertEqual(
                    CodexNativeSessionController.parseApprovalDecisionOffer(from: params, kind: .commandExecution),
                    .unusable(reason: testCase.reason),
                    testCase.label
                )
                XCTAssertNil(Self.parse(["availableDecisions": testCase.offer]), testCase.label)
            }
        }

        func testConflictingSpellingsNeverWidenTheOffer() throws {
            let conflicting = "availableDecisions is declared more than once with different values"
            let acceptOrCancel = ["accept", "cancel"]
            let conflictingRule: [String: Any] = [
                "acceptWithExecpolicyAmendment": ["execpolicy_amendment": Self.rule, "execpolicyAmendment": ["git"]]
            ]
            let refused: [(label: String, params: [String: Any], reason: String)] = [
                ("list beside null alias", ["availableDecisions": acceptOrCancel, "available_decisions": NSNull()], conflicting),
                ("null beside list alias", ["availableDecisions": NSNull(), "available_decisions": acceptOrCancel], conflicting),
                (
                    "narrow list beside wider alias",
                    ["availableDecisions": acceptOrCancel, "available_decisions": ["accept", "acceptForSession", "decline", "cancel"]],
                    conflicting
                ),
                (
                    "only an amendment with conflicting rules",
                    ["availableDecisions": [conflictingRule]],
                    "availableDecisions offers only decisions RepoPrompt cannot send (acceptWithExecpolicyAmendment (malformed))"
                )
            ]
            for testCase in refused {
                let params = Self.baseParams.merging(testCase.params) { _, new in new }
                XCTAssertEqual(
                    CodexNativeSessionController.parseApprovalDecisionOffer(from: params, kind: .commandExecution),
                    .unusable(reason: testCase.reason),
                    testCase.label
                )
                XCTAssertNil(Self.parse(testCase.params), testCase.label)
            }

            let identical = try XCTUnwrap(Self.parse(["availableDecisions": acceptOrCancel, "available_decisions": acceptOrCancel]))
            XCTAssertEqual(identical.decisionConstraint, .offered([.accept, .cancel]))

            let amendmentBesideOthers = try XCTUnwrap(
                Self.parse(["availableDecisions": ["accept", conflictingRule, "cancel"] as [Any]])
            )
            XCTAssertEqual(amendmentBesideOthers.decisionConstraint, .offered([.accept, .cancel]))
            XCTAssertEqual(amendmentBesideOthers.presentedDecisions, [.cancel, .accept])
        }

        func testFileChangeApprovalNeverPresentsCommandAmendment() throws {
            let method = "item/fileChange/requestApproval"
            let commandOnly = "acceptWithExecpolicyAmendment (command approvals only)"
            let params = Self.baseParams.merging(["availableDecisions": [Self.amendmentEntry]]) { _, new in new }

            XCTAssertEqual(
                CodexNativeSessionController.parseApprovalDecisionOffer(from: params, kind: .fileChange),
                .unusable(reason: "availableDecisions offers only decisions RepoPrompt cannot send (\(commandOnly))")
            )
            XCTAssertNil(Self.parse(["availableDecisions": [Self.amendmentEntry]], method: method))

            let request = try XCTUnwrap(
                Self.parse(["availableDecisions": ["accept", Self.amendmentEntry, "cancel"] as [Any]], method: method)
            )
            XCTAssertEqual(request.kind, .fileChange)
            XCTAssertEqual(request.decisionConstraint, .offered([.accept, .cancel]))
            XCTAssertEqual(request.presentedDecisions, [.cancel, .accept])
            XCTAssertEqual(request.details.first(where: { $0.label == "Unsupported Offered Decisions" })?.value, commandOnly)
        }

        // MARK: - Response boundary

        func testRejectedDecisionSendsNothingAndKeepsTheRequestPending() async throws {
            let fixture = makeFixture()
            let acceptOrCancel: [Any] = ["accept", "cancel"]
            let cases: [(label: String, params: [String: Any], decision: AgentApprovalDecision, result: AgentApprovalSubmissionResult)] = [
                ("decline", ["availableDecisions": acceptOrCancel], .decline, .decisionNotOffered(offered: [.accept, .cancel])),
                (
                    "session approval",
                    ["availableDecisions": acceptOrCancel],
                    .acceptForSession,
                    .decisionNotOffered(offered: [.accept, .cancel])
                ),
                (
                    "amendment",
                    ["availableDecisions": acceptOrCancel],
                    .acceptWithExecpolicyAmendment(#"["git","status"]"#),
                    .decisionNotOffered(offered: [.accept, .cancel])
                ),
                (
                    // The requested decision is checked before serialization, so a malformed
                    // amendment cannot become the offered session-wide approval.
                    "malformed amendment where session approval is offered",
                    ["availableDecisions": ["acceptForSession", "cancel"]],
                    .acceptWithExecpolicyAmendment("git status"),
                    .decisionNotOffered(offered: [.acceptForSession, .cancel])
                ),
                (
                    "malformed amendment where the amendment is offered",
                    ["availableDecisions": ["accept", Self.amendmentEntry, "cancel"] as [Any]],
                    .acceptWithExecpolicyAmendment("git status"),
                    .invalidAmendment
                ),
                (
                    "malformed amendment without offered decisions",
                    ["proposedExecpolicyAmendment": Self.rule],
                    .acceptWithExecpolicyAmendment("git status"),
                    .invalidAmendment
                )
            ]

            for (index, testCase) in cases.enumerated() {
                let request = try XCTUnwrap(Self.parse(testCase.params, serverRequestID: index + 1), testCase.label)
                fixture.session.pendingApproval = request
                fixture.session.runState = .waitingForApproval

                let result = fixture.viewModel.resolveApprovalDecision(
                    tabID: fixture.session.tabID,
                    requestID: request.id,
                    decision: testCase.decision
                )

                XCTAssertEqual(result, testCase.result, testCase.label)
                XCTAssertEqual(fixture.session.pendingApproval, request, testCase.label)
                XCTAssertEqual(fixture.session.runState, .waitingForApproval, testCase.label)
            }

            let lastRequest = try XCTUnwrap(fixture.session.pendingApproval)
            XCTAssertTrue(
                fixture.viewModel.submitApprovalDecision(
                    tabID: fixture.session.tabID,
                    requestID: lastRequest.id,
                    decision: .cancel
                )
            )
            XCTAssertNil(fixture.session.pendingApproval)
            try await fixture.awaitResponses(count: 1)
            XCTAssertEqual(fixture.responses, [Response(id: .int(cases.count), decision: "cancel")])
        }

        func testOfferedAmendmentIsSentOnlyWhenItMatchesExactly() async throws {
            let fixture = makeFixture()
            let request = try XCTUnwrap(
                Self.parse(["availableDecisions": ["accept", Self.amendmentEntry, "cancel"] as [Any]], serverRequestID: 5)
            )
            fixture.session.pendingApproval = request
            fixture.session.runState = .waitingForApproval

            for broaderOrDifferent in [#"["git"]"#, #"["git","status","--short"]"#, #"["status","git"]"#] {
                XCTAssertEqual(
                    fixture.viewModel.resolveApprovalDecision(
                        tabID: fixture.session.tabID,
                        requestID: request.id,
                        decision: .acceptWithExecpolicyAmendment(broaderOrDifferent)
                    ),
                    .amendmentNotOffered,
                    broaderOrDifferent
                )
                XCTAssertEqual(fixture.session.pendingApproval, request, broaderOrDifferent)
            }

            XCTAssertTrue(
                fixture.viewModel.submitApprovalDecision(
                    tabID: fixture.session.tabID,
                    requestID: request.id,
                    decision: .acceptWithExecpolicyAmendment(#"[ "git", "status" ]"#)
                )
            )
            try await fixture.awaitResponses(count: 1)
            let response = try XCTUnwrap(fixture.controller.serverRequestResponses.first)
            XCTAssertEqual(response.id, .int(5))
            let decision = try XCTUnwrap(response.result["decision"] as? [String: Any])
            let amendment = try XCTUnwrap(decision["acceptWithExecpolicyAmendment"] as? [String: Any])
            XCTAssertEqual(amendment["execpolicy_amendment"] as? [String], Self.rule)
            XCTAssertEqual(fixture.controller.serverRequestResponses.count, 1)
        }

        func testRequestWithoutOfferedDecisionsStillAcceptsDecline() async throws {
            let fixture = makeFixture()
            let request = try XCTUnwrap(Self.parse([:], serverRequestID: 7))
            fixture.session.pendingApproval = request
            fixture.session.runState = .waitingForApproval

            XCTAssertTrue(
                fixture.viewModel.submitApprovalDecision(
                    tabID: fixture.session.tabID,
                    requestID: request.id,
                    decision: .decline
                )
            )

            try await fixture.awaitResponses(count: 1)
            XCTAssertEqual(fixture.responses, [Response(id: .int(7), decision: "decline")])
        }

        func testACPApprovalWithoutControllerStaysPending() {
            let fixture = makeFixture()
            let request = AgentApprovalRequest(
                requestID: .acp("permission-1"),
                method: "session/request_permission",
                kind: .commandExecution,
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "item-1"
            )
            fixture.session.pendingApproval = request
            fixture.session.runState = .waitingForApproval
            XCTAssertNil(fixture.session.acpController)

            XCTAssertEqual(
                fixture.viewModel.resolveApprovalDecision(tabID: fixture.session.tabID, requestID: request.id, decision: .accept),
                .providerUnavailable
            )
            XCTAssertEqual(fixture.session.pendingApproval, request)
            XCTAssertEqual(fixture.session.runState, .waitingForApproval)
        }

        // MARK: - Request identity and overlapping approvals

        func testOverlappingApprovalsAreQueuedAndAnsweredInArrivalOrder() async throws {
            let fixture = makeFixture()
            let first = try XCTUnwrap(Self.parse(["availableDecisions": ["accept", "cancel"]], serverRequestID: 1, itemID: "item-1"))
            let second = try XCTUnwrap(Self.parse(["availableDecisions": ["accept", "cancel"]], serverRequestID: 2, itemID: "item-2"))
            fixture.session.runState = .running

            for request in [first, second, first] {
                await fixture.coordinator.test_handleCodexNativeEvent(.approvalRequest(request), session: fixture.session)
            }

            XCTAssertEqual(fixture.session.pendingApproval, first)
            XCTAssertEqual(fixture.session.queuedApprovalRequests, [second])
            XCTAssertEqual(fixture.session.runState, .waitingForApproval)

            XCTAssertTrue(fixture.viewModel.submitApprovalDecision(tabID: fixture.session.tabID, requestID: first.id, decision: .accept))
            XCTAssertEqual(fixture.session.pendingApproval, second)
            XCTAssertEqual(fixture.session.queuedApprovalRequests, [])
            XCTAssertEqual(fixture.session.runState, .waitingForApproval)

            XCTAssertTrue(fixture.viewModel.submitApprovalDecision(tabID: fixture.session.tabID, requestID: second.id, decision: .cancel))
            XCTAssertNil(fixture.session.pendingApproval)
            XCTAssertEqual(fixture.session.runState, .running)

            try await fixture.awaitResponses(count: 2)
            XCTAssertEqual(fixture.responses, [
                Response(id: .int(1), decision: "accept"),
                Response(id: .int(2), decision: "cancel")
            ])
        }

        func testAnswerForAnEarlierApprovalDoesNotAnswerTheNextOne() async throws {
            let fixture = makeFixture()
            let first = try XCTUnwrap(Self.parse([:], serverRequestID: 1, itemID: "item-1"))
            let second = try XCTUnwrap(Self.parse([:], serverRequestID: 2, itemID: "item-2"))
            fixture.session.runState = .running
            await fixture.coordinator.test_handleCodexNativeEvent(.approvalRequest(first), session: fixture.session)
            await fixture.coordinator.test_handleCodexNativeEvent(.approvalRequest(second), session: fixture.session)
            XCTAssertTrue(fixture.viewModel.submitApprovalDecision(tabID: fixture.session.tabID, requestID: first.id, decision: .accept))

            // A second click on the card rendered for the first approval arrives after the second
            // approval took its place.
            XCTAssertFalse(fixture.viewModel.submitApprovalDecision(tabID: fixture.session.tabID, requestID: first.id, decision: .decline))
            XCTAssertEqual(
                fixture.coordinator.submitApprovalDecision(session: fixture.session, requestID: first.id, decision: .decline),
                .staleRequest
            )

            XCTAssertEqual(fixture.session.pendingApproval, second)
            try await fixture.awaitResponses(count: 1)
            await Task.yield()
            XCTAssertEqual(fixture.responses, [Response(id: .int(1), decision: "accept")])
        }

        func testTurnChangeClearsQueuedApprovalsWithoutAnsweringThem() async throws {
            let fixture = makeFixture()
            let first = try XCTUnwrap(Self.parse([:], serverRequestID: 1, itemID: "item-1"))
            let second = try XCTUnwrap(Self.parse([:], serverRequestID: 2, itemID: "item-2"))
            fixture.session.runState = .running
            await fixture.coordinator.test_handleCodexNativeEvent(.approvalRequest(first), session: fixture.session)
            await fixture.coordinator.test_handleCodexNativeEvent(.approvalRequest(second), session: fixture.session)
            XCTAssertEqual(fixture.session.queuedApprovalRequests, [second])

            // Codex resolves its own outstanding requests when the turn ends; the session must drop
            // both rather than surface the queued one afterwards.
            await fixture.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-2"), session: fixture.session)

            XCTAssertNil(fixture.session.pendingApproval)
            XCTAssertEqual(fixture.session.queuedApprovalRequests, [])
            XCTAssertFalse(fixture.viewModel.submitApprovalDecision(tabID: fixture.session.tabID, requestID: second.id, decision: .accept))

            let next = try XCTUnwrap(Self.parse(["turnId": "turn-2"], serverRequestID: 3, itemID: "item-3"))
            await fixture.coordinator.test_handleCodexNativeEvent(.approvalRequest(next), session: fixture.session)
            XCTAssertEqual(fixture.session.pendingApproval, next)
            XCTAssertEqual(fixture.session.queuedApprovalRequests, [])
            XCTAssertTrue(fixture.viewModel.submitApprovalDecision(tabID: fixture.session.tabID, requestID: next.id, decision: .accept))
            XCTAssertNil(fixture.session.pendingApproval)

            try await fixture.awaitResponses(count: 1)
            await Task.yield()
            XCTAssertEqual(fixture.responses, [Response(id: .int(3), decision: "accept")])
        }

        // MARK: - Fixture

        private struct Response: Equatable {
            let id: CodexAppServerRequestID
            let decision: String?
        }

        @MainActor
        private final class Fixture {
            let viewModel: AgentModeViewModel
            let session: AgentModeViewModel.TabSession
            let controller: StartupTestCodexController

            init(viewModel: AgentModeViewModel, session: AgentModeViewModel.TabSession, controller: StartupTestCodexController) {
                self.viewModel = viewModel
                self.session = session
                self.controller = controller
            }

            var coordinator: CodexAgentModeCoordinator {
                viewModel.test_codexCoordinator
            }

            var responses: [Response] {
                controller.serverRequestResponses.map { Response(id: $0.id, decision: $0.result["decision"] as? String) }
            }

            func awaitResponses(count: Int) async throws {
                let reached = await startupTestWaitBounded { self.controller.serverRequestResponses.count >= count }
                XCTAssertTrue(reached, "expected \(count) approval responses, saw \(controller.serverRequestResponses.count)")
            }
        }

        private func makeFixture() -> Fixture {
            let controller = StartupTestCodexController(gatesStartup: false)
            let viewModel = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                testWorkspaceDirectory: storageRoot,
                codexControllerFactory: { _, _, _, _, _, _ in controller }
            )
            let session = startupTestCodexSession()
            session.codexController = controller
            viewModel.test_installLiveSession(session)
            let fixture = Fixture(viewModel: viewModel, session: session, controller: controller)
            fixtures.append(fixture)
            return fixture
        }

        private static let baseParams: [String: Any] = [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "itemId": "item-1",
            "command": "cat",
            "startedAtMs": 1
        ]

        private static func parse(
            _ params: [String: Any],
            method: String = "item/commandExecution/requestApproval",
            serverRequestID: Int = 1,
            itemID: String = "item-1"
        ) -> AgentApprovalRequest? {
            var merged = baseParams.merging(params) { _, new in new }
            merged["itemId"] = itemID
            return CodexNativeSessionController.parseApprovalRequest(
                requestID: .int(serverRequestID),
                method: method,
                params: merged,
                activeThreadID: "thread-1",
                currentTurnID: "turn-1"
            )
        }
    }
#endif
