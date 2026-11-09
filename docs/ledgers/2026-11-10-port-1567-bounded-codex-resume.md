# Run ledger: Port upstream PR 1567, bounded Codex resume history

Request: none · Plan: `port-1567-oversized-codex-resume-2026-11-10.md`

Re-implement upstream PR 1567 (squash commit `d17409d48`, closing upstream issue 1562) by hand: on Codex app-server 0.164.0 or newer, resume a thread without its full history, read ordinary snapshots as one 32-turn metadata page, page to the end only for Stop, and load full items only for the watchdog's native-tool probe of the latest active turn.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Wire contract: fixture, schema test, doc note | done | engineer · Orchestrate 1/3: port 1567 wire contract | `fix(codex): declare bounded thread history in the app-server contract` |
| 2. Snapshot model and bounded resume | done | pair · Orchestrate 2/3: port 1567 snapshot model and bounded resume | `fix(codex): resume Codex threads without loading their full history` |
| 3. Reads, native-tool probe, and Stop | done | pair · Orchestrate 3/3: port 1567 reads, probe, and Stop | `fix(codex): bound Codex snapshot reads and page Stop's active-turn check` |
| 4. Checks and integration hand-off | done | orchestrator | `docs: record the port 1567 run ledger` |
| 5. Live check and pull request | pending | | |

## 1. Wire contract: fixture, schema test, doc note

- Decision: the `thread/resume` and new `thread/turns/list` fixture entries re-type upstream's two hunks. A JSON comparison against upstream's entries shows them identical. `path` joins `thread/resume`'s `maySend` because the controller already sends it. Source: approved plan.
- Decision: the fixture floor stays 0.159.0, and the schema-gate doc's count sentence and version-contract bullets stay unchanged, because #357 edits those lines. The new "Bounded thread history" section sits after "Bounded contract". Source: approved plan.
- Evidence: `make conductor-selftest` passes. `Scripts/check_codex_app_server_schema.py` against throwaway installs of Codex CLI 0.159.0 and 0.164.0 prints "Checked: 46 methods, 207 parameter paths, 111 response paths" for both. A `git merge-tree` of the three files against #357's head (`221bd0d09`) is clean. The implementing agent's review and the refactor review found nothing.
- Deferred: once #357 lands, the doc's count sentence understates the projection. Update it when this branch is next rebased onto `main`.

## 2. Snapshot model and bounded resume

- Decision: the runtime gate, 32-turn page, `hasCompleteTurnMetadata`, page parsing and item-authority rules, validators, and the bounded resume sequence follow upstream, with the plan's adaptations: identity through `threadIdentity(in:)`, and a deadline error worded "timed out after" with a nil code, so `CodexAppServerClient.isTimeoutError` classifies it and hook-trust restoration's fresh-thread fallback doesn't trigger on it. Source: approved plan.
- Decision: a resume response with no thread identity is returned unchanged, so each caller rejects it with its existing error (`threadBindingResponseMissingThreadID(.resume)` at startup, `invalidResponse` in hook-trust restoration). A response naming a different thread throws `invalidResponse` on every runtime. Source: approved plan.
- Decision: the single-turn condition for native-tool item authority counts the page's own turns, which is the plan's wording, where upstream counts the parsed turns. The two agree whenever the page has a `data` array. Source: implementing agent's judgment, accepted by the review.
- Decision: the tests assert "only `thread/resume` sent" and "one fallback page" from a lock-protected request log, because a check inside the request closure can't catch a missing or repeated request. Source: implementing agent's judgment.
- Evidence: five ported tests in `CodexBoundedThreadSnapshotTests` pass, as do `CodexNativeSessionControllerInterruptTests` (2) and `CodexThreadBindingReadinessTests` (9); `make dev-format`, `make dev-lint`, and `make dev-swift-build PRODUCT=RepoPrompt` pass. The implementing agent's review, its follow-up, and the refactor review found nothing.

## 3. Reads, native-tool probe, and Stop

- Decision: on 0.164.0 or newer, an ordinary rich snapshot is `thread/read` without turns plus one 32-turn metadata page. The watchdog's native-tool probe instead fetches a `limit: 1, itemsView: full` page, and only while the thread is active, so a completed turn is never hydrated. Stop keeps its lifecycle shortcut. Otherwise it pages every turn's metadata inside one 5-second budget shared with `turn/interrupt`, and doesn't send `turn/interrupt` after a repeated cursor, a malformed page, an unknown turn status, a thread change, cancellation, or an exhausted budget. Source: approved plan and upstream.
- Decision: the bounded read's deadline check uses `remainingControlPlaneTimeout`, so its error is classified as a timeout, where upstream's own message isn't. Source: approved plan.
- Decision: the `unknown-status` case puts a known active turn beside the unknown one, so a missing status check would send an interrupt rather than fail differently. Every test asserts the exact request sequence except the Stop deadline case, which asserts a timeout and no `turn/interrupt`, because under load the 5 ms budget can run out before the first page request. Source: implementing agent's judgment.
- Evidence: `CodexBoundedThreadSnapshotTests` (15 tests and the plan's `page-over-limit`, `thread-rebound`, `lifecycle-appeared`, and bounded-read timeout variants), `CodexNativeSessionControllerInterruptTests` (2), `CodexThreadBindingReadinessTests` (9), `CodexStartupSettlementTests` (10), and `CodexMCPRoutingReadinessTests` (6) pass. A throwaway mutation check removed four behaviors (the unknown-status rejection, the lifecycle recheck, metadata-only idle probes, the read's deadline check) from a scratch copy of the controller, and each failed exactly its own test. The implementing agent's review, its follow-up, and the refactor review found nothing.
- Deferred: `refreshActiveTurnForInterruptIfPossible` has no caller, so its new coverage guard has no test.

## 4. Checks and integration hand-off

- Evidence: on the branch tip after item 3, `make dev-format` doesn't change any file. `make dev-codex-schema-check` (Codex CLI 0.166.0) and `Scripts/check_codex_app_server_schema.py` pinned to 0.159.0 and 0.164.0 each print "Checked: 46 methods, 207 parameter paths, 111 response paths". `git merge-tree` against the heads of #357 (`221bd0d09`) and #355 (`68d0517f0`) is clean. The `pr-ready` result is in the pull request description.
- Decision: the branch is pushed before its debug-app run, and the live check runs on the integrated debug build after it's rebuilt with this branch, because work threads in this run don't build or relaunch the debug app. Source: the dog-food run's rules.

## Live reproduction before the port

- Decision: the second workload round ran 100 shell calls instead of the plan's repeat of 48. Codex stores at most 65,536 bytes of each command's output in the rollout, so the first 48 calls produced a 3,243,747-byte legacy resume response, and another 48 would have stayed under the 8,388,608-byte line limit. Source: orchestrator judgment from the measured per-item cap.
- Evidence (2026-11-10, integrated debug build `c0c21c70d`, bundled Codex 0.164.0): a Codex Agent Mode session (session A) recorded a marker phrase, then ran 48 and 100 separate shell calls that each printed 262,144 bytes. A standalone Codex 0.164.0 app-server, given only a scratch copy of the session's rollout, answered a legacy `thread/resume` with 9,852,640 bytes (two turns) and a bounded resume (`excludeTurns`, 32-turn `notLoaded` page) with 37,073 bytes, for the same thread ID.
- Evidence: after stopping session A's agent process, a follow-up message asking for the marker failed with "Codex native resume failed: Request timed out after 120.0s". No new rollout appeared, and session A's rollout didn't change.

## Run decisions

- Decision: base `main`, not stacked on #355 or #357. No symbol this port uses comes from either. #357 only activates the bounded paths for the bundled runtime by moving it to 0.164.0. Source: approved plan.
- Decision: items 1 and 2 run concurrently because they don't share a file. Item 3 follows item 2's commit because both edit the controller. Source: orchestrator judgment.
- Decision: each item's review loop and refactor review serve as the independent review and separate refactor pass that `CONTRIBUTING.md` step 4 asks for. Source: `CONTRIBUTING.md`.
- Decision: the run ledger is a separate `docs:` commit after the port commits. Source: orchestrator judgment, following earlier port ledgers.
