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

        // MARK: - Fixtures

        /// Imports chat items the way a full rebuild does, then refreshes completed turns'
        /// grouped-history caches as `buildTranscriptPresentation` does before it builds.
        private static func preparedTranscript(
            from items: [AgentChatItem],
            terminalState: AgentSessionRunState
        ) -> AgentTranscript {
            prepared(AgentTranscriptIO.buildTranscript(from: items, terminalState: terminalState, compact: false))
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
