# Run ledger: port upstream PRs 1645 and 1649, transcript responsiveness

Request: port upstream PR 1645 (`04343e7da`) and upstream PR 1649 (`9523cb8d6`), with the visibility signal from upstream PR 1164 (`75d023ff5`) and upstream PR 1166 (`70e5e8b38`) · Plan: a local `rp-deep-plan` plan, not committed

Stop Markdown compilation and non-editable text replacement in windows that are not on screen, and put each Agent Mode transcript row behind an equatable input boundary so a streaming delta redraws only the streaming reply. Measure settled-row work and main-thread time per streamed chunk before and after.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. B: DEBUG render probe and baseline measurements | done | pair · Orchestrate 1/5: B probe and baseline (v3) | `perf(agent-mode): add a DEBUG render probe for transcript rows` |
| 2. V: window presentation visibility signal | done | engineer · Orchestrate 2/5: V window presentation visibility | `perf(agent-mode): track whether each window is on screen` |
| 3. M: hidden Markdown compile and replacement gating | done | pair · Orchestrate 3/5: M hidden Markdown gating (v2) | `perf(markdown): defer Markdown rendering in windows that aren't on screen` |
| 4. R: equatable transcript row boundary and final measurements | done | pair · Orchestrate 4/5: R equatable rows and final measurements | `perf(agent-mode): redraw only the streaming reply in transcripts` |
| 5. F: targeted binding snapshot, only if the counter triggers it | done | pair · Orchestrate 5/5: F targeted binding snapshot | `perf(agent-mode): build a targeted binding snapshot for one session's lookup` |

## Run setup

- Decision: the run uses the debug app's RepoPrompt server, which runs an integrated build of `main` plus the open distribution pull requests, and validates live on that build after a coordinator-requested rebuild. Source: user (dog-food run rules).
- Decision: items run in sequence, one fresh agent each, because each item changes the source state the measurement harness compiles. Source: orchestrator judgment.
- Decision: the optional live stress-harness comparison (a debug app launched with `-RP_AGENT_CHAT_STRESS`) is skipped; the hosted harness gives the before-and-after numbers. Source: user.
- Run environment: agent sessions started through MCP follow the debug app's Sub-Agent permission policy, and the debug build keeps that setting in memory only. Until the policy was set to Inherit, new Claude Code sessions launched in the default permission mode and stopped on approval prompts, so two item 1 sessions were replaced; one item 3 session was replaced after a debug-app rebuild ended it. None of this changed the work.

## 1. B: DEBUG render probe and baseline measurements

- Decision: the probe lives at `Sources/RepoPrompt/Features/Diagnostics/AgentMode/AgentTranscriptTailRenderProbe.swift`, not upstream's `Infrastructure/UI/Markdown/`, because the ownership map puts debug-only Agent Mode instrumentation under `Features/Diagnostics/AgentMode`. It adds a Markdown compile event and per-window counters (`ui.transcriptRender.window.<id>.<counter>`) that upstream lacks. Source: approved plan.
- Decision: the per-window counters also count Chat Markdown in the same window. Live checks read them per window and must not attribute them all to Agent Mode. Source: the item's review.
- Decision: the measurement harness is a local, untracked XCTest file that skips unless `RPCE_RUN_SCALE_TESTS` is set. It hosts `AgentModeDetailWithSidebarView`, the production parent of the chat detail view, so the status pills and context pill render too. Source: agent judgment.
- Decision: the rich workload gives its rich body to rows that render a native text view (the turn's opener, settled conclusions, the narration's settled answer) as well as the user message. On `main`, user rows without a URL render as SwiftUI `Text`, and an assistant row longer than 10 lines that isn't recent renders a `Text` preview, so the plan's workload as written had no settled native rich rows to witness. Source: agent judgment, checked against `CollapsibleUserMessage.swift` and `AgentMessageBubble.swift`.
- Decision: perf diagnostics stay on for every measured run, at B and after, so the context-pill body counter can be read per chunk. Source: agent judgment.
- Evidence: `make dev-swift-build PRODUCT=RepoPrompt`, `AgentTranscriptDebugInstrumentationTests` (1 test), `EnhancedMarkdownBareURLTests` (13), `make dev-format` and `make dev-lint` pass. A validity run at 10 turns passed every gate (witnesses, calibration, non-empty cohorts, one publication per chunk, no unattributed native events) and showed settled-row work at B.
- Evidence, baseline at the probe commit, debug build, Codex delta route with explicit flushes: 18 of 18 scenarios valid (2 workloads × 3 sizes × 3 size orders, 8 measured chunks each after 1 warm-up, 144 chunks), none rerun. Medians per streamed chunk:

  | Metric | Rich, 10 / 40 / 200 turns | Narration, 10 / 40 / 200 turns |
  | --- | --- | --- |
  | Older-row bubble bodies | 123 / 177 / 177 | 41 / 59 / 59 |
  | Active-turn settled bodies | 12 | 5 |
  | Native updates per mounted settled view | 3, each a full replacement | 1, a full replacement |
  | Block builds | 120 / 168 / 168 | 41 / 57 / 57 |
  | Host layouts | 4 | 3 |
  | Main-thread CPU, ms | 312 / 330 / 370 | 63 / 69 / 77 |
  | Settle wall time, ms (includes a 0.22 s quiet window) | 321 / 334 / 373 | 312 / 322 / 340 |
  | Binding snapshot builds | 3 | alternating 0 and 3 |

  Counts level off above 40 turns because compaction keeps 59 older rows on screen; CPU still grows with session size. The harness's own driver intervals take about 1 ms, so main-thread CPU is the timing that captures the work. Another worktree's test job held the shared heavy slot before sampling started, and no other checkout's compiler or test process used CPU during sampling.
- Review: the correctness review found nothing. Refactor gate: one optional finding, to let the probe choose each event's counter instead of the call site, declined because the four event-and-counter pairs are fixed and each sits in one place.
- Finding for item 5: during streaming, every unsuppressed publication calls `syncRuntimeMetricsUIState()`, which rebuilds the runtime context snapshot without the selection summary and count, so the context pill takes its binding-provider fallback on every body. That fallback builds the persistent binding snapshot three times per pill body, and the pill body runs on most streamed chunks. This meets the plan's trigger for the targeted binding snapshot.
- Finding for item 3: at B, every native update of a settled rich text view replaces its storage, because the installed attributed string never compares equal to the requested one.
- Finding for item 4: the plan's designated settled user row needs a native text view. A user row renders one (`PlainProseTextView`) only when its text contains an http(s) URL or a long message is expanded.

## 2. V: window presentation visibility signal

- Decision: termination relies on the existing observation suppression, which includes the window manager's terminating flag, so nothing publishes while the app quits; observers aren't removed then and `WindowStateManager.swift` is unchanged. This matches how `WindowState`'s focus observers behave at termination and upstream PR 1166, which doesn't touch the manager. `beginClose` removes the observers and cancels the pending sample. Source: orchestrator judgment, on the item's review finding that the plan's lifecycle row asked for observer removal at termination.
- Decision: no notification-driven show-and-minimize test. The lifecycle test uses real windows that are never ordered on screen, as planned; real occlusion is checked live. Source: approved plan.
- Evidence: `WindowPresentationVisibilityPolicyTests` and `WindowPresentationVisibilityLifecycleTests` (1 test each), `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-format` (no changes) and `make dev-lint` pass.
- Review: the item's review ended with no actionable findings after the termination decision. Refactor gate: one optional finding, to move the existing focus task's cancellation into `removeFocusObservers()`, declined because it reworks pre-existing focus code this port doesn't otherwise change.

## 3. M: hidden Markdown compile and replacement gating

- Decision: `AttributedTextView` compares the installed storage with the requested string and, when they differ, with a copy of the requested string after `fixAttributes(in:)`. Installing an attributed string gives every character of a paragraph the paragraph style of its first character, and compiled Markdown leaves the end of a code block or list item with a different style or none, so before this change installed storage never equalled the requested string and every update of a code or prose view replaced it. The normalized copy equalled installed storage for rich, code, prose, table and plain samples, before and after layout. On a 78K-character document the comparison averages about 8.6 ms against about 141 ms for a replacement plus measurement. Source: agent judgment, within the plan's rule that equal content never replaces storage and without the content cache the plan rejects.
- Decision: recompiled tables still compare unequal, because each compile creates new table objects, and replace as before. `MarkdownTextView` keeps its compiled output and doesn't recompile unchanged text, so settled rows and unchanged reveals don't reach this case. Fixing it would need table-aware comparison or a content cache. Source: agent judgment.
- Decision: the hidden-compile test sets visibility through the environment on a hosting wrapper rather than through `WindowState`, whose wiring item 2's tests cover; it also shows that a mounted `MarkdownTextView` receives a visibility change although its custom `==` reports equal. Tests 1 and 3 render the caller's own string rather than a copy of installed storage, so they would catch the equality miss. Source: agent judgment.
- Evidence: `MarkdownPresentationUpdateTests` (4), `EnhancedMarkdownBareURLTests` (13), `AgentTranscriptDebugInstrumentationTests` (1), `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-format` and `make dev-lint` pass. Deliberate breaks each failed the expected test: a plain `isEqual` comparison, dropping `|| isEditable`, removing the visibility `onChange`, removing the visibility gate or guards, and a string-only comparison.
- Effect on measurements: the comparison fix also stops replacements when a visible settled view receives unchanged content, so some of the drop in native replacements between the baseline and the final revision comes from this item, not from the row boundary.
- Review: the item's review approved the production change; one test finding was fixed (an attribute-only change must replace storage exactly once) and one declined (restoring the previous probe sink, since each test owns the sink while it runs). Refactor gate: no findings.

## 4. R: equatable transcript row boundary and final measurements

- Decision: the measurement campaign also ran at M, before the row boundary, so the drop from item 3's comparison fix is separate from the row boundary's. Source: orchestrator judgment; the plan measured only B and the final revision.
- Decision: six row-boundary tests instead of the plan's seven. The provider-route test is dropped: its Codex half is covered by the tail test's single publication and exact tail text, and its Claude half protects provider admission, which this change doesn't touch and whose lowest faithful layer is the view model. The Bash update moved into the changed-inputs test, so the tail test checks one contract (`testTailDeltaKeepsSettledRowsUnchanged`). Source: agent judgment under `rpce-test-quality`.
- Decision: no tests for the approval, payload, edit, context-builder or routing inputs, which have no consumer observable without clicking; a test that only counts re-renders would restate the inputs' synthesized equality. Source: agent judgment.
- Decision: the designated settled user row's text contains a URL, because on `main` a user row renders a native text view only then or when a long message is expanded. Source: orchestrator, from item 1's finding.
- Decision: theme, font, window focus and window visibility stay environment values, not row inputs, as the plan and upstream have it. The item's agent first reported that focus didn't reach a settled row's footer, and the orchestrator briefly decided to make focus a row input; the agent then traced the report to its own diagnostic, whose footer a republish had cleared. With the footer kept on the session, focus reached the settled footer through the environment, so the change was reverted. `testThemeFontAndFocusStillUpdateMountedRows` fails when the footer ignores the environment value. Source: approved plan, confirmed by the test.
- Decision: the harness's one sign-in action construction gained an `ownerID:` argument, its only change after the baseline. Source: approved plan ("compatibility adjustments recorded in the ledger").
- Evidence: the six `AgentTranscriptRowBoundaryTests`, both window suites, `MarkdownPresentationUpdateTests`, `EnhancedMarkdownBareURLTests`, `AgentTranscriptDebugInstrumentationTests` and `AgentTranscriptActivationRepaintRemountPolicyTests` pass (28 tests), as do the product build, `make dev-format` and `make dev-lint`. Each row test failed under a deliberate break of what it protects: row equality always false, a cancel that reads the active run at click time, a handoff that forwards the defaults instead of the submitted selection, a login equality that ignores revision, a dropped footer, Bash entry or recent membership, and a footer that ignores the focus environment value.
- Review: the item's review and its follow-up found nothing actionable. Refactor gate: one optional finding, to pass recent-assistant membership to the bubble as a Boolean rather than a singleton set, declined because the plan keeps upstream's set-shaped bubble input to ease later ports.
- Evidence, final measurements: the campaign ran at M and at R with the baseline's harness (one compatibility line changed), workloads, sizes, orders and warm-up. Each revision had 18 of 18 scenarios valid, 144 measured chunks, none rerun. At R every measured chunk had 0 settled bubble bodies, 0 native update, replacement or make calls on mounted settled views, exactly 1 presentation publication, and the exact tail text and marker; the committed tail test checks the designated user row's native identity and selection. Per chunk at 40 and 200 turns, rich / narration:

  | Per chunk | Baseline | M | R |
  | --- | --- | --- | --- |
  | Older-row bubble bodies | 177 / 59 | 177 / 59 | 0 / 0 |
  | Active-turn settled bodies | 12 / 5 | 12 / 5 | 0 / 0 |
  | Native updates per mounted settled view | 3 / 1 | 3 / 1 | 0 / 0 |
  | Native replacements per mounted settled view | 3 / 1 | 0 / 0 | 0 / 0 |
  | Block builds | 168 / 57 | 168 / 57 | 168 / 57 |
  | Host layouts | 4 / 3 | 4 / 3 | 4 / 3 |

  In the rich workload, R also cut the streaming row's own bodies from 3 to 1 per chunk and its native updates from 4 to 2. Main-thread CPU per chunk, median of round medians, in ms:

  | Workload, turns | Baseline | M | R |
  | --- | --- | --- | --- |
  | Rich, 10 | 311.7 | 311.5 | 254.2 |
  | Rich, 40 | 330.1 | 326.0 | 262.3 |
  | Rich, 200 | 369.5 | 372.8 | 295.1 |
  | Narration, 10 | 63.2 | 47.9 | 38.3 |
  | Narration, 40 | 69.0 | 57.0 | 38.2 |
  | Narration, 200 | 77.1 | 109.9 | 81.7 |

  Rich: R's round ranges are under 3.5 ms wide and don't overlap the baseline's at any size. Narration: R is 25–31 ms below the baseline at 10 and 40 turns, more than M's 8–22 ms run-to-run spread, but each revision had one campaign; at 200 turns R is 4.6 ms above the baseline, so no gain is claimed there. The M run had the highest machine load (user CPU 21–58% against 19–43% at the baseline and 18–46% at R), which fits its high narration figure at 200 turns. Item 3's comparison fix (baseline to M) removed settled replacements but left CPU within run-to-run spread; the CPU drop comes from the row boundary (M to R). The binding snapshot counter is unchanged at R: 3 builds per rich chunk.
- Observed, not explained, same at every revision: in the rich workload about 200 ms of main-thread work per chunk happens after the last event the harness records.
- Deferred, predates this change: a streaming reply that is its turn's conclusion is projected as not streaming, so it loses streaming cadence and segmentation (#372); a completed turn's cached projection ignores item content, so an in-place change to an item in that turn can render stale (#373).

## 5. F: targeted binding snapshot

- Decision: the targeted snapshot runs, because the plan's rule triggers it: the binding snapshot counter showed 3 full builds per rich streamed chunk at the baseline, at M and at R. Source: approved plan.
- Decision: it stays, because it measurably shrinks the materialized snapshot and authority is unchanged. A throwaway debug-build measurement (21 batches of 100 calls, medians) gave, full against targeted: with 1,000 unrelated compose tabs and a target holding 500 selection paths, 5,010 entries built against 6 and 823 µs against 444 µs per lookup; with 1,001 session-index entries added, 6,011 against 7 and 845 against 441 µs; with 21 compose tabs, 5 stashed and 300 index entries, 430 against 7 and 42 against 17 µs. The remaining time is the scan of every carrier, which this change keeps because the distribution lacks upstream's per-session indexes. Source: approved plan's keep-or-omit rule.
- Decision: the claimed-or-conflicting derivation moved into one helper that both builders call, so their conflict rules can't drift apart. The DEBUG counter still counts only full builds. Source: agent judgment.
- Decision: the materialization test uses 3 unrelated tabs instead of the plan's 1,000, because any unrelated tab tells the two paths apart, and drops the plan's "selection data is not copied" clause, which can't be observed because the snapshot stores only IDs. One authority case was added that the plan didn't list, an earlier persisted tab sharing the target's tab ID that claims another session; it is the only case that catches a single-pass version. Source: agent judgment under `rpce-test-quality`.
- Evidence: the 2 new `AgentWorktreeBindingSnapshotTests` and 16 existing binding and authority suites pass (277 tests). Deliberate breaks each failed the expected test: dropping other sessions' claims, collapsing to a single pass, and pointing the scalar lookup back at the full snapshot. `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-format` and `make dev-lint` pass.
- Review: the item's review and the refactor gate found nothing.
- Deferred: the root cause, the runtime metrics sync clearing the context pill's selection summary and count on every publication so the pill looks up bindings on most streamed chunks, is #374.

## Branch review, cleanup and validation

- Decision: the local measurement harness and its raw output were deleted from the worktree before the branch review; the committed tests keep its contracts. Source: approved plan.
- Review: an independent review of the whole branch, on a different model family from the implementing agents, found one should-fix. The window visibility lifecycle test asserted only changes caused by attaching a window, so it passed with every visibility subscription removed, while in the app a window sampled before it was ordered on screen would stay hidden and its Markdown would never compile. Fixed in `test(agent-mode): check that visibility notifications schedule a sample`: a DEBUG count of scheduled samples, and checks that a window notification and an app notification for the attached window each schedule a sample while notifications for an unrelated window, after detaching and after close schedule none. With the subscriptions removed, the new checks fail.
- Cleanup: a separate cleanup pass moved the claim collection both binding snapshot builders repeated into one helper and shared some test teardown and helpers, with every assertion unchanged (`refactor(agent-mode): share binding claim collection and test helpers`). Three refactor suggestions from the items' gates stayed declined.
- Evidence: after the cleanup, `make dev-format` changed nothing and `make dev-lint` passes.
