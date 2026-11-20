#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class AgentTranscriptProjectionBuilderTests: XCTestCase {
        override func tearDown() {
            AgentTranscriptDebugInstrumentation.reset()
            super.tearDown()
        }

        func testConclusionRowKeepsSourceStreamingFlag() {
            struct State {
                let label: String
                let replies: [AgentChatItem]
                let expectedKind: AgentTranscriptRenderBlockKind
                let expectedStreaming: Bool
            }

            let replyID = Self.fixtureID(5)
            let requestAndToolCall = [
                Self.user("Check the configuration flag.", id: Self.fixtureID(1), sequenceIndex: 0),
                Self.toolCall(id: Self.fixtureID(2), invocationID: Self.fixtureID(100), sequenceIndex: 1),
                Self.toolResult(id: Self.fixtureID(3), invocationID: Self.fixtureID(100), sequenceIndex: 2)
            ]
            let substantiveOpener = Self.assistant(
                "The configuration sets the flag to true.",
                id: Self.fixtureID(4),
                sequenceIndex: 3
            )
            func reply(_ text: String, isStreaming: Bool) -> AgentChatItem {
                Self.assistant(text, id: replyID, sequenceIndex: 4, isStreaming: isStreaming)
            }

            let states: [State] = [
                .init(
                    label: "single substantive streaming reply",
                    replies: [reply(
                        "The configuration sets the flag to true, which enables the new projection path for every",
                        isStreaming: true
                    )],
                    expectedKind: .conclusion,
                    expectedStreaming: true
                ),
                .init(
                    label: "short streaming reply after a substantive opener",
                    replies: [substantiveOpener, reply("It also enables the", isStreaming: true)],
                    expectedKind: .standaloneAssistant,
                    expectedStreaming: true
                ),
                .init(
                    label: "streaming reply extended to end in a period",
                    replies: [substantiveOpener, reply("It also enables the cache.", isStreaming: true)],
                    expectedKind: .conclusion,
                    expectedStreaming: true
                ),
                .init(
                    label: "finished reply",
                    replies: [substantiveOpener, reply("It also enables the cache.", isStreaming: false)],
                    expectedKind: .conclusion,
                    expectedStreaming: false
                )
            ]

            var firstBlockID: String?
            for state in states {
                let transcript = Self.preparedTranscript(from: requestAndToolCall + state.replies, terminalState: .running)
                let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
                guard let block = projection.workingBlocks.first(where: { $0.rows.contains { $0.id == replyID } }),
                      let row = block.rows.first(where: { $0.id == replyID })
                else {
                    XCTFail("\(state.label): no projected row has the reply's ID")
                    continue
                }
                XCTAssertEqual(block.kind, state.expectedKind, state.label)
                XCTAssertEqual(row.isStreaming, state.expectedStreaming, state.label)
                if let firstBlockID {
                    XCTAssertEqual(block.id, firstBlockID, state.label)
                } else {
                    firstBlockID = block.id
                }
            }
        }

        func testInPlaceChangeToCompletedTurnReprojectsOnlyThatTurn() {
            struct Change {
                let label: String
                let changedItemID: UUID
                let setUp: (inout AgentChatItem) -> Void
                let apply: (inout [AgentChatItem]) -> Void
            }

            let conclusionID = Self.firstTurnConclusionID
            let changes: [Change] = [
                .init(
                    label: "assistant text rewritten",
                    changedItemID: conclusionID,
                    setUp: { _ in },
                    apply: { items in
                        Self.update(&items, id: conclusionID) { $0.text = "The configuration sets the flag to false." }
                    }
                ),
                .init(
                    label: "pending tool call finalized",
                    changedItemID: Self.firstTurnPendingCallID,
                    setUp: { _ in },
                    apply: { items in
                        // Limit the walk to the items up to the pending call. It doesn't check whether a
                        // call already has a result, so it would also rewrite the answered calls after it.
                        let pendingCallSequenceIndex = items.first { $0.id == Self.firstTurnPendingCallID }?.sequenceIndex ?? 0
                        let finalizedCount = AgentTranscriptIO.finalizePendingToolCalls(
                            in: &items,
                            terminalState: .completed,
                            includeExplicitRepoPromptToolCalls: false,
                            maxSequenceIndexExclusive: pendingCallSequenceIndex + 1,
                            nonToolBoundary: Int.max
                        )
                        XCTAssertEqual(finalizedCount, 1, "pending tool call finalized")
                    }
                ),
                .init(
                    label: "tool result JSON and error flag rewritten",
                    changedItemID: Self.firstTurnToolResultID,
                    setUp: { _ in },
                    apply: { items in
                        Self.update(&items, id: Self.firstTurnToolResultID) {
                            $0.toolResultJSON = #"{"output":"permission denied"}"#
                            $0.text = #"{"output":"permission denied"}"#
                            $0.toolIsError = true
                        }
                    }
                ),
                .init(
                    label: "conclusion stops streaming",
                    changedItemID: conclusionID,
                    setUp: { $0.isStreaming = true },
                    apply: { items in
                        Self.update(&items, id: conclusionID) { $0.isStreaming = false }
                    }
                )
            ]

            for change in changes {
                var items = Self.completedTurnItems()
                Self.update(&items, id: change.changedItemID, change.setUp)
                let warm = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: Self.preparedTranscript(from: items, terminalState: .completed),
                    turnCaches: [:]
                )

                change.apply(&items)
                let changedTranscript = Self.preparedTranscript(from: items, terminalState: .completed)
                let (cached, cacheHitCounts) = Self.buildWithCachesRecordingCacheHits(
                    from: changedTranscript,
                    turnCaches: warm.updatedTurnCaches
                )

                XCTAssertEqual(cacheHitCounts, [2], change.label)
                Self.assertProjectedRow(change.changedItemID, in: cached.projection, matchesSourceIn: items, change.label)
                XCTAssertEqual(
                    cached.projection,
                    AgentTranscriptProjectionBuilder.build(from: changedTranscript),
                    change.label
                )
            }
        }

        func testUnchangedCompletedTurnsReuseCachesAcrossTranscriptRebuilds() throws {
            let replyID = Self.fixtureID(43)
            func items(reply: String) -> [AgentChatItem] {
                Self.completedTurnItems() + [
                    Self.user("Write the release notes.", id: Self.fixtureID(40), sequenceIndex: 11),
                    Self.toolCall(
                        id: Self.fixtureID(41),
                        invocationID: Self.fixtureID(140),
                        sequenceIndex: 12,
                        argsJSON: #"{"command":"git log"}"#
                    ),
                    Self.toolResult(
                        id: Self.fixtureID(42),
                        invocationID: Self.fixtureID(140),
                        sequenceIndex: 13,
                        resultJSON: #"{"output":"2 commits"}"#
                    ),
                    Self.assistant(reply, id: replyID, sequenceIndex: 14, isStreaming: true)
                ]
            }

            // The incremental import compacts its result, so every transcript here is compacted,
            // as production imports are.
            let warmTranscript = Self.preparedTranscript(
                from: items(reply: "The release notes cover"),
                terminalState: .running,
                compact: true
            )
            let warm = AgentTranscriptProjectionBuilder.buildWithCaches(from: warmTranscript, turnCaches: [:])
            let extendedItems = items(reply: "The release notes cover the flag and the cache")
            let incrementalTranscript = try XCTUnwrap(AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
                existingTranscript: warmTranscript,
                items: extendedItems,
                earliestChangedIndex: extendedItems.count - 1,
                terminalState: .running
            ))
            let cases: [(label: String, transcript: AgentTranscript)] = [
                ("incremental import", Self.prepared(incrementalTranscript)),
                (
                    "rebuilt from items",
                    Self.preparedTranscript(from: extendedItems, terminalState: .running, compact: true)
                )
            ]

            for testCase in cases {
                let (cached, cacheHitCounts) = Self.buildWithCachesRecordingCacheHits(
                    from: testCase.transcript,
                    turnCaches: warm.updatedTurnCaches
                )
                XCTAssertEqual(cacheHitCounts, [3], testCase.label)
                XCTAssertEqual(
                    cached.projection,
                    AgentTranscriptProjectionBuilder.build(from: testCase.transcript),
                    testCase.label
                )
            }
        }

        // MARK: - Fixtures

        private static let firstTurnPendingCallID = fixtureID(11)
        private static let firstTurnToolResultID = fixtureID(13)
        private static let firstTurnConclusionID = fixtureID(14)

        /// Three completed turns. The first has a pending tool call, an answered tool call, and a
        /// conclusion, the items that in-place repairs and reconciliations change.
        private static func completedTurnItems() -> [AgentChatItem] {
            [
                user("Check the configuration flag.", id: fixtureID(10), sequenceIndex: 0),
                toolCall(
                    id: firstTurnPendingCallID,
                    invocationID: fixtureID(110),
                    sequenceIndex: 1,
                    argsJSON: #"{"command":"git status"}"#
                ),
                toolCall(id: fixtureID(12), invocationID: fixtureID(111), sequenceIndex: 2),
                toolResult(id: firstTurnToolResultID, invocationID: fixtureID(111), sequenceIndex: 3),
                assistant("The configuration sets the flag to true.", id: firstTurnConclusionID, sequenceIndex: 4),
                user("Check the cache setting.", id: fixtureID(20), sequenceIndex: 5),
                toolCall(
                    id: fixtureID(21),
                    invocationID: fixtureID(120),
                    sequenceIndex: 6,
                    argsJSON: #"{"command":"cat cache.json"}"#
                ),
                toolResult(
                    id: fixtureID(22),
                    invocationID: fixtureID(120),
                    sequenceIndex: 7,
                    resultJSON: #"{"output":"cache = on"}"#
                ),
                assistant("The cache setting is on.", id: fixtureID(23), sequenceIndex: 8),
                user("Summarize both settings.", id: fixtureID(30), sequenceIndex: 9),
                assistant("Both the flag and the cache are on.", id: fixtureID(31), sequenceIndex: 10)
            ]
        }

        private static func update(_ items: inout [AgentChatItem], id: UUID, _ body: (inout AgentChatItem) -> Void) {
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                XCTFail("no fixture item has ID \(id)")
                return
            }
            body(&items[index])
        }

        /// Builds with `turnCaches` and returns the `cacheHitCount` of each build the debug
        /// instrumentation reported. It resets the instrumentation before returning, so the
        /// caller's later uncached builds aren't recorded.
        private static func buildWithCachesRecordingCacheHits(
            from transcript: AgentTranscript,
            turnCaches: [UUID: AgentTranscriptTurnProjectionCache]
        ) -> (result: AgentTranscriptProjectionBuildResult, cacheHitCounts: [Int]) {
            var cacheHitCounts: [Int] = []
            AgentTranscriptDebugInstrumentation.configure(.init(projectionBuildHandler: { metrics in
                cacheHitCounts.append(metrics.cacheHitCount)
            }))
            let result = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: turnCaches)
            AgentTranscriptDebugInstrumentation.reset()
            return (result, cacheHitCounts)
        }

        private static func assertProjectedRow(
            _ id: UUID,
            in projection: AgentTranscriptProjection,
            matchesSourceIn items: [AgentChatItem],
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard let source = items.first(where: { $0.id == id }),
                  let row = (projection.workingRows + projection.archivedRows).first(where: { $0.id == id })
            else {
                XCTFail("\(label): no source item and projected row both have ID \(id)", file: file, line: line)
                return
            }
            XCTAssertEqual(row.kind, source.kind, label, file: file, line: line)
            XCTAssertEqual(row.text, source.text, label, file: file, line: line)
            XCTAssertEqual(row.toolResultJSON, source.toolResultJSON, label, file: file, line: line)
            XCTAssertEqual(row.toolIsError, source.toolIsError, label, file: file, line: line)
            XCTAssertEqual(row.isStreaming, source.isStreaming, label, file: file, line: line)
        }

        /// Imports chat items the way a full rebuild does, then refreshes completed turns'
        /// grouped-history caches as `buildTranscriptPresentation` does before it builds.
        private static func preparedTranscript(
            from items: [AgentChatItem],
            terminalState: AgentSessionRunState,
            compact: Bool = false
        ) -> AgentTranscript {
            prepared(AgentTranscriptIO.buildTranscript(from: items, terminalState: terminalState, compact: compact))
        }

        private static func prepared(_ transcript: AgentTranscript) -> AgentTranscript {
            AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: transcript)
        }

        private static func fixtureID(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }

        private static func timestamp(forSequenceIndex sequenceIndex: Int) -> Date {
            Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(sequenceIndex))
        }

        private static func user(_ text: String, id: UUID, sequenceIndex: Int) -> AgentChatItem {
            AgentChatItem(
                id: id,
                timestamp: timestamp(forSequenceIndex: sequenceIndex),
                kind: .user,
                text: text,
                sequenceIndex: sequenceIndex
            )
        }

        private static func assistant(
            _ text: String,
            id: UUID,
            sequenceIndex: Int,
            isStreaming: Bool = false
        ) -> AgentChatItem {
            AgentChatItem(
                id: id,
                timestamp: timestamp(forSequenceIndex: sequenceIndex),
                kind: .assistant,
                text: text,
                sequenceIndex: sequenceIndex,
                isStreaming: isStreaming
            )
        }

        private static func toolCall(
            id: UUID,
            invocationID: UUID,
            sequenceIndex: Int,
            toolName: String = "Bash",
            argsJSON: String = #"{"command":"cat config.json"}"#
        ) -> AgentChatItem {
            AgentChatItem(
                id: id,
                timestamp: timestamp(forSequenceIndex: sequenceIndex),
                kind: .toolCall,
                text: "Using tool: \(toolName)",
                toolName: toolName,
                toolInvocationID: invocationID,
                toolArgsJSON: argsJSON,
                sequenceIndex: sequenceIndex
            )
        }

        private static func toolResult(
            id: UUID,
            invocationID: UUID,
            sequenceIndex: Int,
            toolName: String = "Bash",
            resultJSON: String = #"{"output":"flag = true"}"#,
            isError: Bool = false
        ) -> AgentChatItem {
            AgentChatItem(
                id: id,
                timestamp: timestamp(forSequenceIndex: sequenceIndex),
                kind: .toolResult,
                text: resultJSON,
                toolName: toolName,
                toolInvocationID: invocationID,
                toolResultJSON: resultJSON,
                toolIsError: isError,
                sequenceIndex: sequenceIndex
            )
        }
    }
#endif
