# Context Builder planning response stall on Codex CLI Oracle (2026-09-11)

> Investigation report, observed 2026-09-11 on the packaged release app with bundled Codex CLI 0.153.4. It records what was true then. Where it disagrees with a current document, the current document is right.

Local triage report, read-only against the running production app. No debug app was launched, no reproduction was attempted against production, no Oracle settings were changed.

## Report

External Codex Desktop agent in the work workspace's window, `context_builder` with `response_type: plan`, `export_response: true`, 51-file selection, Oracle `CLI GPT-5.6 Sol High`.

1. `context_builder` returned: "Follow-up response stalled for 600.3s with no streaming/finalization activity during Oracle response streaming. Last event: waiting for Oracle stream activity."
2. Same-chat recovery via `oracle_send` (`mode: plan`, `export_response: true`, `new_chat: false`) returned: "The Context Builder query was finalized by the interactive inactivity watchdog."

## Evidence sources

- Caller session log (the calling Codex Desktop agent's session log): tool-result timestamps and durations for both calls.
- RepoPrompt CE's own Codex home (`~/Library/Application Support/RepoPrompt CE/Codex/Release/home/sessions/2026/09/11/`): one rollout per Oracle turn, originator `repoprompt`, bundled Codex CLI 0.153.4, model `gpt-5.6-sol`, effort high, reasoning summary auto.
- The preserved chat file in the work workspace's folder: three messages, saved 05:47:55.
- Source on `main` (worktree at merge e62b9ff): `ContextBuilderFollowUpFinalizationMonitor.swift`, `OracleViewModel.swift`, `OracleViewModel+MCP.swift`, `AIQueriesService.swift`, `CodexCLIProvider.swift`, `CodexNativeSessionController.swift`.

Unified log (`log show`) had no RepoPrompt entries for the window; the release build does not log Oracle activity there.

## Correlated timeline (UTC)

| Time | Component | Event |
| --- | --- | --- |
| 05:25:13 | Codex (RP home) | Turn 1 starts in a new Codex thread. Payload: developer 21,222 + 2,264 + 271 chars, user 32,009 chars (instructions), user 602,307 chars (selected files). Context window 258,400 tokens. |
| 05:25:15 | RepoPrompt | Follow-up stream open; Context Builder finalization monitor starts (10-minute inactivity ceiling). |
| 05:30:49 | Codex | `token_count` with rate limits only (no token usage, no items). Consistent with a fresh HTTP response after Codex's stream idle timeout and reconnect. Weekly quota near its limit. |
| 05:35:13 | RepoPrompt | Monitor fires at 600.3 s with zero activity events. `cancelStreaming`. `context_builder` returns the stall error. Rollout has no `turn_aborted`. |
| 05:36:12 | Codex | Turn 2 (recovery `oracle_send`) starts another new thread. Same shape: user 32,009 + 603,080 chars (the full selection is re-sent). |
| 05:41:47 | Codex | `token_count`, rate limits only. Reconnect 1. |
| 05:47:25 | Codex | `token_count`, rate limits only. Reconnect 2. Codex emits error notification "Reconnecting... 2/5" (`willRetry`). |
| 05:47:25–05:47:45 | RepoPrompt | `CodexCLIProvider` yields the notification as `AIStreamResult(type: "status", text: "Reconnecting... 2/5")`. `AIQueriesService` buffers any non-empty `text` as content regardless of `type`. The assistant message content becomes `Reconnecting... 2/5`; `hasSeenNonReasoningText` is set; the interactive stream-inactivity watchdog re-arms with the 10-second post-content grace. |
| ~05:47:55 | RepoPrompt | Watchdog fires; `finalizeAIResponse(outcome: .interactiveWatchdog)`; chat saved with the 19-character assistant message; `waitForContextBuilderCompletion` throws `interactiveWatchdogFinalization`; `oracle_send` returns after 703 s. Rollout has no `turn_aborted`. |
| 05:49:21 | Caller | Native fallback export written. |

The gap between request and each `token_count` is 5 m 34 s, 5 m 35 s, 5 m 38 s across three attempts in two turns. That regularity matches Codex's stream idle timeout (default 300 s) plus reconnect time: the backend accepted each request, returned headers, and streamed no bytes for five minutes, three times in a row. No reasoning item, no assistant item, no `turn/completed`, and no `turn/failed` exists in either rollout.

## Root cause

Two layers.

**Provider stall (primary, external).** GPT-5.6 Sol at high effort returned nothing for the ~600 KB planning request across three connection attempts over 22 minutes. RepoPrompt's stream saw no text, no reasoning, and no completion. Whether the cause was load, the request size (roughly 150k+ input tokens against a 258k window), or quota pressure (the weekly quota was near its limit) cannot be determined from the client side.

**RepoPrompt handling (secondary, ours).**

1. `CodexCLIProvider` forwards Codex's retriable error notifications ("Reconnecting... n/5") as `AIStreamResult(type: "status", text:)`. `AIQueriesService.sendPrompt` treats every non-empty `text` as assistant content, so the status string is written into the message, the UI, and the saved chat, and it counts as first content for the interactive watchdog. That watchdog then applies the 10-second post-content grace to a stream that is, by Codex's own account, waiting on a reconnect. This is what turned the recovery into "finalized by the interactive inactivity watchdog" and left `Reconnecting... 2/5` as the only assistant message.
2. The MCP `oracle_send` path (`OracleViewModel+MCP.swift`, `tool_chatSend`) calls `sendMessage` with the default `.interactive` completion policy and then waits with `waitForContextBuilderCompletion`. The Context Builder follow-up path uses `.contextBuilderStrict`, which disables the interactive watchdog and relies on the 10-minute monitor instead. So a same-chat recovery through `oracle_send` runs under a stricter, 10-second watchdog than the call it is recovering.
3. The Context Builder finalization monitor counts only `OracleMessageLifecycleActivityEvent`s. `CodexCLIProvider` drops `.livenessActivity` (`continue`) and the app never emits transport activity for Codex, so a Codex turn that is alive but silent, or reconnecting, looks identical to a dead one. The 600-second ceiling therefore cuts the turn during Codex's own retry budget (5 attempts, roughly 5.5 minutes each).
4. Neither rollout contains `turn_aborted`, while another RepoPrompt-originated rollout today does, so it is not established that `cancelStreaming` interrupted the Codex turns. The shared Oracle app-server (already running before both calls) may have kept retrying after both calls returned. At 06:50 that process held no established network connections, so nothing is retrying now; whether the interrupt landed or Codex exhausted its retries on its own is not established. Confirming it needs `thread/read` against that app-server.

## Answers to the handoff questions

- Why the first call reported a stall and the recovery reported a watchdog finalization: different watchdogs. The first ran under the Context Builder monitor (10-minute inactivity, zero events). The recovery ran under the interactive stream watchdog, tripped by the reconnect status text being treated as content.
- Does finalized state or watchdog ownership survive into the recovery: no. The recovery created a new query id, a new Codex thread, and a new assistant message. Nothing from turn 1 leaked into turn 2.
- Did a partial or completed provider response exist but go undelivered: no. Both rollouts show zero assistant or reasoning items. There was nothing to deliver.
- Same-chat recovery reliability: unreliable while defects 1 and 2 stand. Any Codex reconnect during a same-chat `oracle_send` will be finalized after 10 seconds with the reconnect banner as the answer. Recovery also re-sends the full selection (600 KB), so it repeats the same heavy request.
- Abandoned work after timeout: possibly. See root cause item 4.
- Workspace prompt showing older instructions: expected. Context Builder writes to the compose tab's prompt only through `copyAgentOutputToPromptIfEmpty`; the follow-up instructions passed to `context_builder` are sent as the Oracle message and never stored in the workspace prompt.

## Why no live reproduction

The failure is a backend stall, not a deterministic client path. Reproducing it would mean sending another ~600 KB GPT-5.6 high request from production while the weekly quota is near its limit and production is in use. The RepoPrompt-side defects (status text as content, watchdog policy mismatch, liveness not counted) are deterministic and unit-testable without production: `OracleViewModel` and `ContextBuilderFollowUpFinalizationMonitor` already have injectable stream and clock seams.

## Proposed fixes and regression tests

1. **Status is not content.** Map `type: "status"` results to transport activity (`ChatStreamOutput(isTransportActivity: true)`) or a dedicated status field in `AIQueriesService`, and surface the text through the session UI state rather than the message body. Test: a stream yielding `status` then silence leaves the message content empty, sets no `hasSeenNonReasoningText`, and does not fire the interactive watchdog inside the post-content grace.
2. **MCP `oracle_send` uses the Context Builder completion policy** when it waits with `waitForContextBuilderCompletion`. Test: `tool_chatSend` sets `completionPolicies[queryId] == .contextBuilderStrict`, so the interactive watchdog is never scheduled for MCP-driven sends.
3. **Codex liveness and reconnect notifications reset the Context Builder inactivity clock.** Emit transport activity for `.livenessActivity` and for retriable error notifications so the monitor distinguishes "silent but retrying" from "dead". Test: monitor receives transport-only events every 30 s for 15 minutes without firing; fires once events stop for 10 minutes.
4. **Verify interrupt delivery on cancel.** After `cancelStreaming`, `thread/read` should show the turn interrupted; if `turn/interrupt` is not reaching the shared Oracle app-server, fix `reconcileAndInterruptCurrentTurn`. Test on the packaged debug runtime once issue #66 lets it run beside production.

## Upstream triage (2026-09-11, upstream main at 4b2b914d)

- Upstream issue 803 (open, filed 2026-08-12, MP added evidence 2026-09-08) is the 600 s inactivity cutoff: only the OpenAI provider emits transport activity, every other lane shows zero events during a silent reasoning phase, and the timeout path discards the stream. It matches defect 3 here and the first call's failure exactly. Not fixed upstream: the monitor constant, the dropped `.livenessActivity`, and the OpenAI-only transport activity are unchanged on upstream main. Distribution PR #39 already softens the destructive half (preserve a partial answer on timeout); it would not have helped here because no partial existed.
- No upstream issue or pull request mentions the reconnect banner becoming assistant content, the `status` result type being treated as text, or the `oracle_send` completion-policy mismatch. Upstream main still yields `AIStreamResult(type: "status", text:)` from the Codex provider, still buffers any non-empty `text` in `AIQueriesService`, and still sends MCP chats with the default `.interactive` policy. Defects 1 and 2 are unreported and unfixed upstream.
- The `rpce-issue-creator` skill searched only the distribution's own tracker; an upstream-triage step was added on branch `chore/issue-creator-upstream-triage`.

## Distribution issue drafts

The report drafted one distribution issue and one comment, both since filed with the drafted text:

- Draft 1 became #68, "Codex reconnect status text is saved as assistant content and trips the 10 s inactivity watchdog", covering defects 1 and 2.
- Draft 2 was withdrawn because #4 ("Oracle response finalization loss on long replays") already tracks upstream issue 803. Its evidence on defect 3 and on the unconfirmed turn interrupt was posted on #4 as a comment on 2026-09-11, with added acceptance criteria: Codex liveness and reconnect notifications reset the inactivity clock, progress and errors name the provider state, and a cancelled Codex follow-up shows its turn interrupted.
