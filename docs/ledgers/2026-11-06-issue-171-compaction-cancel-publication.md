# Run ledger: settle the store before the compaction-cancellation baseline

Request: #171 · Plan: `test-flakes-175-171-184-274-2026-11-06.md`

Make `AgentRunStartupSnapshotTests.testCompactionFailureAfterCancellationKeepsTheCancellation` deterministic. It read its store baseline before the running snapshot of the held `/compact` had reached the store, so the baseline was sometimes `nil` and the final read `running`.

Base: `main` at `c4b5abfed`. The same run produced two sibling pull requests with their own ledgers: #175 in `docs/ledgers/2026-11-06-issue-175-bounded-admission-waits.md` and #184/#274 (#354) in `docs/ledgers/2026-11-06-issue-184-steer-wait-and-window-readiness.md`.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Make the #171 test take its baseline after the store settles | done | Codex GPT-6.1 Sol · Orchestrate 3/5: publish no-epoch cancellation (#171) | `test(agent-mode): wait for the compaction's running snapshot before the cancellation baseline` |

## 1. Make the #171 test take its baseline after the store settles

- Decision: this item ran on a Codex agent (GPT-6.1 Sol, extra-high reasoning) rather than the default Claude pair role, because the Claude Code provider's Opus model had hit its usage limit for several hours. Source: orchestrator judgment.
- Cause: `beginCodexCompaction` sets the session running without a turn epoch, and `handleObservedMCPStateChange` sends the running snapshot to `AgentRunSessionStore` from an unstructured task. Cancelling such an attempt publishes nothing to the store: `makeTerminalPublicationEnvelope` returns nil without a turn epoch and `publishTerminalCommit` rejects the missing envelope. So the store's only write is that running snapshot, and when it landed after the test's baseline read, the baseline was `nil` and the final read `running`. `agent_run poll` reports the live state when the stored snapshot is nonterminal (`currentSnapshot` in `AgentRunMCPToolService.swift`), so the stale store value isn't what a client sees. Source: code trace, 2026-11-06.
- Decision: the fix is test-only. The test publishes the session's observed state and waits, bounded, until the store holds `running` before cancelling, then takes the baseline and requires one to exist. Source: orchestrator judgment; #171's acceptance allows a baseline taken after pending writes settle.
- Decision: a product change was tried first and dropped. It captured a publication for an attempt without a turn epoch on the terminal commit revision and sent the cancellation through `AgentRunSessionStore.signalSnapshot`, so the store held `cancelled` when `cancelRun` returned and a parked store waiter woke. The pull request's review bot pointed out a regression: the stored cancellation sits in the same pre-epoch projection that a later `/compact` under the same MCP activation uses, `acceptedSnapshot` rejects every running snapshot over a stored terminal, and `poll` would then report the old `cancelled` while the second compaction ran, where it used to report the live `running`. Doing it correctly would need a projection reset in the store, and four debug-app attempts couldn't make the original store gap visible to an MCP client (below). Source: orchestrator judgment, on the review bot's finding.
- Evidence, live (for the dropped product change): on a debug app built with it, a Codex session (GPT-6 Luna, low) finished a turn, its stored terminal expired after 300 s, and a `/compact` steer started the compaction (`poll`: `running`, "Compacting context…"). An `agent_run wait` started then returned at once, with the prior `completed` or with `expired`, including after `agent_manage resume_session`, so no MCP wait parked on the attempt. `steer` itself doesn't wait for control-plane commands.
- Evidence: before the change, the test failed 1 of 10 runs alone under five busy-loop processes, with the issue's assertion at `AgentRunStartupSnapshotTests.swift:147`. After it, 20 of 20 passed under the same load; the suite passed 21 of 21. With the compaction failure path made to restore the prior state after cancellation (temporary), the test failed: "the failed request restored the result before the cancellation". `make dev-format` and `make dev-lint` passed; review found nothing.
- Decision: the successor test also checks that a failed compaction leaves the successor's MCP cursor and stored running snapshot alone. Source: implementing agent's judgment.

## Parked decisions

- Should an issue be filed for two observations from the debug-app runs? (1) After a cancelled compaction without a turn epoch, the run store keeps a stale `running` snapshot that schedules no expiry, and a store waiter on that cursor isn't woken; `poll` is unaffected. (2) `agent_run wait` returns `expired` while a `/compact` that an MCP client steered after its handle expired is still running, even after `agent_manage resume_session`, so the client can't wait on it. Options: file one issue with both, file two, or leave them unrecorded. Recommendation: one issue; neither has shown a user-facing failure yet, and they share the no-epoch compaction path. Blocks: nothing.

## Evidence conventions

- Focused runs go through `./conductor test --filter <regex>`; each attempt is counted from the job log's `Test Case '…' passed|failed` lines, not the job's exit code.
- "Under load" means five `yes > /dev/null` processes for the duration of a batch, on top of whatever the other worktrees were building.
