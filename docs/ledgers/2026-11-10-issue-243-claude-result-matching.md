# Run ledger: Claude Code result matching (issue 243, part 1)

Request: #243 · Plan: `issue-243-provider-started-turns-2026-11-10.md`

Port upstream PR 1564 (match Claude Code results to the input they answer) to `main`, plus upstream PR 1565's provider-execution tracking, which here feeds only the idle probe. This is the first of two pull requests for #243. It references the issue without closing it.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Codec UUID and turn correlation type (plan items 1.1, 1.2) | done | pair (Claude Code Opus) · Orchestrate 1/2: codec UUID + turn correlation | `feat(claude): encode an optional uuid on Claude Code user messages`, `feat(claude): add a turn correlation for Claude Code results` |
| 2. Controller and runner settlement by identity (plan item 1.3) | done | pair (Claude Code Opus) · Orchestrate 2/2: controller + runner settlement, then engineer (Codex GPT-6.1) · Refactor: item B controller settlement | `fix(claude): settle Claude Code results by the input they answer` |
| 3. Validation and handoff (plan item 1.4) | pending | | |

## 1. Codec UUID and turn correlation type

- Decision: `ClaudeNativeTurnCorrelation` includes upstream PR 1565's provider-initiated execution tracking (`providerTurnID`) but not its provider output ownership. So activity from a provider-started turn doesn't own output, and `resolve` and `drain` return host IDs only. Source: approved plan (PR 1 and PR 2 file tables).
- Decision: `resolve` returns a named `Resolution` struct instead of upstream's labeled tuple, so the second pull request can add the provider ID as a field. Source: agent judgment, accepted.
- Decision: version parsing accepts exactly three numeric components. Upstream's `Int(_:)` also accepted signs such as `+2`. Source: approved plan ("a valid three-part version").
- Decision: declined the refactor review's one suggestion, reading `order[head]` directly in `takeFirst()` instead of searching from `head`. The search is cheap at these sizes and keeps positional settlement correct if the compaction invariant changes. Source: orchestrator judgment.
- Evidence: `make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.ClaudeSDKProtocolCodecTests` passed (1 test), and `make dev-test FILTER=ClaudeNativeTurnCorrelationTests` passed (6 tests). `make dev-format` left every file unchanged, and `make dev-lint` passed. The agent's correctness review ended with no findings after one test fix: the 64-entry cap case now uses a literal count instead of the production constant.

## 2. Controller and runner settlement by identity

- Decision: keep upstream's deferral rule, which defers only results that settle host inputs. A provider-only result clears `providerTurnID` when it arrives, so the idle probe can read idle between that result and Claude Code's idle signal. The turn has finished by then. Source: orchestrator judgment.
- Decision: the controller reports a correlation failure and stops processing that frame within the same actor turn, before the transport shuts down. Upstream schedules the report. Here a stdout close right after the bad frame could replace the restart message with the unexpected-exit error, and processing the rest of the frame after the correlation drained would settle by position. Source: review finding.
- Decision: `sendUserMessage` also refuses while the controller is shutting down. Source: approved plan ("reject a missing or shutting-down transport").
- Decision: `interruptTurn` stays one method. Upstream splits out a running-turn variant for a configuration-transport test hook that this repository doesn't have. Source: agent judgment, accepted.
- Decision: the ownership filter leaves out upstream's `harness_empty_output_reprompt_candidate` result type, which nothing in this repository emits. Source: agent judgment, accepted.
- Decision: one runner helper, `settleCompletedTurnIDs`, serves the event loop and tests. Source: approved plan.
- Decision (refactor gate): `emitOrDeferCompletion(_:)` now holds the idle-deferral rule for positional and matched completions, `interruptTurn` has one catch block, and `clearTurnIDQueue()` became `resetTurnCorrelation()`. Declined removing the frame-local ownership value in `handleStreamPayload`: it's `observeActivity`'s return value, which the second pull request widens with provider output ownership. Source: refactor review, orchestrator judgment.
- Evidence: `ClaudeNativeTurnCorrelationTests` passed (13 tests after the refactor). Before the refactor, that suite plus `ClaudeNativeApprovalAndResumeTests`, `ClaudeIdleShutdownTests`, `AgentRunStartupTicketTests`, `AgentRunStartupSnapshotTests`, `AgentRunMCPToolServiceSteerResumeTests`, and `AgentManageStopSessionTests` passed together (105 tests). After it, `ClaudeNativeApprovalAndResumeTests` passed again (4 tests). `make dev-swift-build PRODUCT=RepoPrompt` succeeded, and `make dev-format` and `make dev-lint` passed. The agent injected one targeted regression per new controller or runner test and saw each test fail.
- Evidence: the raw event logs of this run's Claude Code 2.1.319 agent sessions show `permissionMode: bypassPermissions`. While inputs were unstamped, none of their frames had a `user_message_uuid` field.
- Deferred: suppose a provider-started turn's first activity has no input UUID but its result has the notification's UUID. The execution then remains open, and `idleProbe()` reports busy until the next host turn closes it, which also bypasses the 120-minute background-task cap. Upstream PR 1565 has the same rule. The live check shows how Claude Code stamps a wake-up turn.
- Deferred: the shutdown scheduled after a correlation failure isn't tied to the failed process, so it could stop a replacement process that started first. The existing protocol-failure shutdown is scheduled the same way. A fix needs process generations.

## 3. Validation and handoff

- Evidence: on the branch tip after the three commits, `make dev-provider-test` passed (11 tests). `ClaudeNativeTurnCorrelationTests`, `ClaudeNativeApprovalAndResumeTests`, `ClaudeIdleShutdownTests`, `AgentRunStartupTicketTests`, `AgentRunStartupSnapshotTests`, `AgentRunMCPToolServiceSteerResumeTests`, and `AgentManageStopSessionTests` passed together (106 tests). `make dev-swift-build PRODUCT=RepoPrompt` succeeded, and `make dev-lint` passed.
- Decision: the debug-app run uses a shared debug build that merges this branch with the other open pull requests. A separate integration process rebuilds it after this branch is pushed, because this run doesn't build or relaunch the shared debug app. `pr-ready` follows the live check. Source: the run's operating rules.
