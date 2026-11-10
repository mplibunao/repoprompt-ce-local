# Run ledger: steer-wait and window-readiness test flakes

Request: #184, #274 · Plan: `test-flakes-175-171-184-274-2026-11-06.md`

Make the #184 steer-wait test independent of a 1 s wall-clock race, and make the #274 tests (three `MCPWorkspaceScopedCursorModelParameterTests` cases, `BindContextRoutingAuthorityTests/testNewWindowSwitchReusesPreferredWindowAlreadyShowingWorkspace`, `ClaudeIdleShutdownTests/testBusySessionKeepsProcessUntilWorkClears`, and `MCPExportWatchdogIntegrationTests/testPromptAppendKeepsTabStateWrittenWhileItCommits`) pass under CPU load, each with its cause named. #274 may end partial, with evidence.

Base: `main` at `c4b5abfed`. The same run produced two sibling pull requests with their own ledgers: #175 in `docs/ledgers/2026-11-06-issue-175-bounded-admission-waits.md` and #171 (#352) in `docs/ledgers/2026-11-06-issue-171-compaction-cancel-publication.md`.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Deterministic steer wait (#184); window readiness for the cursor and bind-context tests (#274) | done | Codex GPT-6.1 Sol · Orchestrate 4/5: steer wait + window readiness (#184, #274) | `test(mcp): settle Agent Mode's workspace switch before cursor-parameter starts`; `test(mcp): complete the steer-wait run inside the wait hook`; `test(mcp): wait for routing eligibility before each window-reuse case` |
| 2. Claude startup join and prompt-append diagnosis (#274) | partial | Codex GPT-6.1 Sol · Orchestrate 5/5: Claude join + prompt-append diagnosis (#274) | `test(agent-mode): tear down each Claude idle protection case before the next`; `test(agent-mode): give the Claude idle test's turn startup one 30 s budget` |

## Decisions made before the run

- Decision: fix test timing without weakening what each test proves; a product bug gets a product fix after its producer is attributed. Source: user.
- Decision: the #184 test completes the new run inside the service's `beginAgentRunWait` hook, which runs after the wait cursor is captured from the new registration and before the store wait, with a 60 s service timeout and no `timed_out` or `expired` metadata allowed. Source: approved plan.
- Decision: window fixtures wait for readiness using state tests can already read (`hasPendingWorkspaceSwitchDiscard`, `workspaceSwitchInFlight`, `activeSessionLoadInProgressTabID`, manager flags), with no new accessor in `Sources/`. `hasPendingWorkspaceSwitchDiscard` covers the gap between the synchronous switch notification and the scheduled handler. Source: design critique of the plan.
- Decision: XCTest's file and line for a thrown error is wherever the main thread was when the failure was recorded, so the `GitViewModel.swift:495`, `TokenCountingViewModel.swift:287`, and `WorkspaceFilesViewModel.swift:11304` locations in #274's reports aren't the throwers; each of those lines can't throw. Source: approved plan, from code reads on 2026-11-06.

## 1. Deterministic steer wait; window readiness for the cursor and bind-context tests

- Decision: this item ran on a Codex agent (GPT-6.1 Sol, extra-high reasoning) rather than the default Claude pair role, because the Claude Code provider's Opus model had hit its usage limit for several hours. Source: orchestrator judgment.
- Cause, cursor tests: with temporary probes at the start boundaries, all three cursor tests caught `MCPError.invalidParams` with `workspace_switch_in_flight` from `requireSettledWorkspaceForStart`, with `Task.isCancelled` false and Agent Mode's pending-discard, switching, and tab-loading flags still set: `agent_run start` ran before Agent Mode's scheduled workspace-switch handling settled. XCTest still reported the failure as `CancellationError()`; why it rendered a different error than the one thrown wasn't established. With the fixture settled, every probed start boundary completed. Source: implementing agent's probes, 2026-11-06.
- Decision: the cursor and steer fixtures activate Agent Mode before switching. A new workspace is normalized to one blank compose tab, so `handleWorkspaceSwitch` doesn't take its empty-tabs branch; only the active tab's load clears `workspaceSwitchInFlight`, and that load doesn't run while Agent Mode is hidden. Source: implementing agent's judgment, correcting the plan's empty-tabs assumption.
- Decision: the item uses only existing helpers plus the new readiness helpers in `MCPWindowTestSupport`, not the #175 branch's bounded-task helpers, so this pull request doesn't depend on that one. Source: implementing agent's judgment.
- Cause, bind-context test: not reproduced alone or in its suite under load, before or after the change, so the original blocker in full runs stays unconfirmed. The fix makes the test wait for the router's eligibility conditions (initialized, not switching, not closing, not restoring, showing the target) on both target windows before each preference case, which rules out the 88-versus-89 shape that a briefly ineligible lower-ID window produces.
- Decision: refactor pass applied two changes, the shared `MCPWindowTestSupport.activateWorkspaceForAgentStart` used by both window fixtures and a scoped comment on which `MCPWindowTestSupport` helpers need the shared-server lease; and declined one, replacing the steer suite's existing `queuedStartEventually` with `startupTestEventually`, because that duplication predates this change. Source: refactor review.
- Decision: the steer suite's `makeWindow` change and the cursor suite's window teardown stay in the commits for their files rather than separate commits; splitting hunks inside one file risked an intermediate commit that doesn't build. Source: orchestrator judgment.
- Evidence: 20 of 20 loaded runs alone for each of the three cursor tests (baseline 0, 6, and 5 of 10 passing), the #184 test, and the bind-context test; 3 of 3 loaded runs of each whole suite (cursor 72 tests, steer 51, bind-context 33). Mutations, each reverted: the steer wait using the expired prior registration fails on `expired` status and metadata; focused-before-selected and highest-ID routing each fail the exact window-ID assertions. Review: no actionable findings.

## 2. Claude startup join and prompt-append diagnosis

- Decision: this item also ran on a Codex agent (GPT-6.1 Sol, extra-high reasoning), for the same reason as item 1. Source: orchestrator judgment.
- Cause, Claude idle test: the recorded failure was "Timed out joining a task" at the 5 s join on the turn's startup ticket (`Fixture.sendTurn`, line 473 at `c39e0593e`). That ticket's task awaits only the prior terminal commit, session and MCP preparation, message augmentation, the initial thread context, and the run service's hand-off to the Claude runner; provider send and routing run in the separate `session.agentTask`, so the plan's step reorder wasn't needed and the join order is unchanged. The original timeout didn't reproduce (baseline 10 of 10 alone under load), so which await was slow isn't established. Two confirmed fixture defects that plausibly add to load in full runs were fixed: every protection case's fixture stayed alive until XCTest teardown, and a `try?` loop dropped errors. Source: read-only trace and the implementing agent's work, 2026-11-06.
- Decision: one 30 s budget across submit, startup join, and provider delivery, with `.accepted` checks and diagnostics; per-case teardown that shuts down the fake provider, joins the runner, releases installed protection on failure, and stops the table if cleanup can't finish. Source: approved plan, with the reorder dropped on the trace's evidence.
- Decision: a refactor review suggested making the shared helpers in `AgentRunStartupTestSupport.swift` return their completion results so the Claude teardown doesn't repeat ticket joins; declined in this pull request because the #175 pull request rewrites that file, and the change would conflict at landing. Source: orchestrator judgment. Deferred: revisit after #175 lands.
- Deferred, prompt-append test: no fix. 20 of 20 focused runs passed under ten load processes, and checkpoints across 24 instrumented runs showed the same workspace and editor-tab identity, the live editor's text read after `willCommit`, and the right appended text and connection generation, with no writer replacing the edit. The single recorded failure stays unexplained; #274 stays open for it.
- Evidence: the Claude test passed 20 of 20 alone and 3 of 3 whole-suite runs under ten load processes; the intermediate commit's suite passed too. Review: one finding (a cleanup timeout let the table continue), fixed; the follow-up had none.
- Observation: under ten load processes the `MCPExportWatchdogIntegrationTests` suite failed 1 of 3 runs, each time in `testPromptSetBumpsWorkspaceStateVersionOnlyWhenTextChanges` at line 124 (state version 24 or 23 where 22 was expected), before and after this item's change. Nothing in this pull request touches that test or its code path.

## Evidence conventions

- Focused runs go through `./conductor test --filter <regex>`; each attempt is counted from the job log's `Test Case '…' passed|failed` lines, not the job's exit code.
- "Under load" means five `yes > /dev/null` processes (about half of the machine's 10 cores) for the duration of a batch, on top of whatever the other worktrees were building (1-minute load 6 to 27 during the baseline).
- Baseline before any change, at `c4b5abfed`, 10 loaded runs of each test alone:

  | Test | Failures |
  |---|---|
  | `MCPWorkspaceScopedCursorModelParameterTests/testAgentRunSuccessfulStartStagesLegacyComposerAliasWithCanonicalSpeedSelection` | 10 of 10, `CancellationError()`, some after 0.13 s |
  | `MCPWorkspaceScopedCursorModelParameterTests/testSettingsPinnedCursorEffortAndSpeedReachRoleLabelRun` | 4 of 10 |
  | `MCPWorkspaceScopedCursorModelParameterTests/testAgentRunStartRoleLabelInheritsStoredPinAndExplicitOverrides` | 5 of 10 |
  | `BindContextRoutingAuthorityTests/testNewWindowSwitchReusesPreferredWindowAlreadyShowingWorkspace` | 0 of 10 |
  | `ClaudeIdleShutdownTests/testBusySessionKeepsProcessUntilWorkClears` | 0 of 10 |
  | `MCPExportWatchdogIntegrationTests/testPromptAppendKeepsTabStateWrittenWhileItCommits` | 0 of 10 |
  | `AgentRunMCPToolServiceSteerResumeTests/testSteerWaitReplacesExpiredPriorRunHandleBeforeWaiting` | 0 of 10 |

  The three tests that never failed alone have recorded failures only from full runs (`pr-ready` or candidate lanes) on a loaded machine.
