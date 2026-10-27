# Run ledger: bound-connection prompt freshness

Request: #296 · Plan: `docs/plans/issue-296-bound-prompt-freshness-2026-10-28.md` (local, not committed)

Make an MCP connection bound to a compose tab read and change that tab's current prompt, so that after `context_builder` commits a prompt into a background tab the caller's `prompt get` and `prompt export` return it, and a stale connection's `prompt append` keeps newer text.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Bound prompt reads use the tab's current prompt | done | pair · #296 item 1: bound prompt reads | `fix(mcp): read a bound tab's current prompt instead of the connection's copy` |
| 2. Bound prompt changes start from the tab's current prompt | pending | | |
| 3. Validation and pull request | pending | | |

## Decisions from planning

- Each ordinary reader (`prompt get`, `prompt export`, `workspace_context` snapshot and export, the `context_builder` seed) captures the exact bound tab's current prompt at the point it builds its reply: the editor's live text when the tab is active, the stored text otherwise. The capture goes into a copy; the connection's cached snapshot is never written by a read. Source: approved plan.
- Ordinary `prompt set`, `append`, and `clear` start from the same capture, taken after `MCPDomainMutationCommitContext.willCommit()` inside `updateCurrentTabContext`, adapting upstream PR 1511's behavior rather than porting its separate API. Source: user.
- Run-owned contexts (Agent Mode runs, the Context Builder child connection) keep today's behavior, including editor publications reaching a run bound to the active tab. Source: user.
- When the exact bound tab can't be captured during a call, reads and prompt changes fail with "The bound tab is no longer available for <tool>", upstream's wording. Closing a tab already purges its bindings, so this covers only a close during an in-flight call. Source: user.
- `oracle_send` packaging is unchanged: its packaged prompt is used only with `use_tab_prompt`, which `ask_oracle` and `oracle_send` reject. Source: approved plan.
- Meta-prompt IDs, tab names, and MCP tool descriptions are unchanged. Source: approved plan.
- Tests: the required background Context Builder regression, a stale two-connection append regression, the Context Builder seed test, the active-tab unsaved-editor-text test without token counts, the exact-owner and missing-tab test, and an extension of the sticky-binding test. Source: user.

## 1. Bound prompt reads use the tab's current prompt

- Decision: `refreshingPromptText(in:toolName:)` in `MCPServerViewModel+TabContext.swift` returns a copy with only the prompt replaced, through `collectMCPTabContextComposeSnapshot`; `prompt get`, `exportPrompt`, the `workspace_context` snapshot, and the `context_builder` seed each call it once, and `selectionRefreshedContext` stays selection-only because it also feeds mutations. Source: approved plan.
- Decision: `workspace_context export` passes the tool name `prompt` to the capture, because `executePromptBody` serves both tools and its routing already uses `prompt`. Source: agent judgment, accepted.
- Decision: the Context Builder regression drives the real tool over the socket through the DEBUG synthetic seam, with a test provider that reports routing to `MCPRoutingWaiter` and seeded provider readiness, the recipe of the tests commit `dbd9eeee6` removed. These tests write a workspace Agent Models profile into the sandboxed test settings store, keyed to a new workspace ID. Source: approved plan.
- Decision: `testPromptAndWorkspaceSnapshotUseUnstoredEditorText` holds the active tab's snapshot publication with `beginApplyingTabContext` on a second tab plus `setSnapshotsSuspended`, and asserts the connection's copy is still stale before the reads; without that, a debounced publication could reach the copy and the test could pass without the fix. Source: review finding.
- Decision: refactors from the refactor analysis: `prepareProtectedExportFixture` reuses `bindTab`, a suite-local `withLeasedFixture` wraps the new tests' lease, fixture, and cleanup, and `exportPrompt` takes a `TabContextSnapshot`. No separate refactor plan was generated, because the analysis already named each change and the behavior to keep. Source: refactor analysis; orchestrator judgment.
- Evidence: on the unmodified code the Context Builder regression failed only at its stale reads (`prompt get` returned `""`; the export's user instructions were empty), and the seed, editor-text, and binding tests failed at their stale-prompt assertions. With the fix: the four tests pass; `MCPExportWatchdogIntegrationTests` 49/49, `BindContextRoutingAuthorityTests` 10/10, `ContextBuilderSelectionTransactionTests` 6/6, `ContextBuilderWindowAdmissionTests` 7/7; `make dev-format` no changes; `make dev-lint` pass. One first-run failure of `BindContextRoutingAuthorityTests/testNewWindowSwitchReusesPreferredWindowAlreadyShowingWorkspace` with `CancellationError()` is the intermittent failure tracked in #274; it makes no prompt reads and passed on rerun.
- Evidence: the correctness review took two rounds; round one could not publish diff artifacts ("review target election is deferred until discovery completes") and reviewed the changed files as they stand; round two reviewed the exact patch and found nothing. The refactor analysis took two rounds; the second found nothing. Follow-ups ran as new `context_builder` calls because `ask_oracle` refuses a chat started by an earlier run of the same session.
- Behavior change: a read on the active tab now returns unsaved editor text immediately; before, it returned the connection's copy until a snapshot publication refreshed it.

## Parked decisions

- File a follow-up issue so run-owned prompts stop taking editor publications (today the snapshot mirror overwrites a run's prompt when the user edits the active tab)? Options: file it, or drop it. Recommendation: file it. Blocks: nothing.
