# Run ledger: port upstream PR 1481 (whole-root reads)

Request: #241 and #222, referred to without closing them · Plan: a local `rp-deep-plan` plan, not committed

Re-implement upstream PR 1481 (upstream commit `7d5f19bbd`) by hand, so that two of the four per-publication consumers that #241 names stop reading the whole root on the `WorkspaceFileContextStore` actor: the hidden-session applied-index handler and token counting's language scan. Measure sampled store work before and after on a matched pair of integrated debug builds.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Confirm the load bodies and measure B | done | orchestrator | |
| 2. Store extension inventory and token recount | done | pair · Orchestrate 2/4 (two cancelled for permissions, then resume 2) | `perf(workspace-context): count file extensions instead of enumerating roots for token recounts` |
| 3. Hidden-session applied-index handler | done | engineer · Orchestrate 3/4: hidden-session applied-index handler | `perf(workspace-files): look up only modified records for hidden-session index events` |
| 4. Byte-based candidate filenames | done | engineer · Orchestrate 4/4: byte-based candidate filenames | `perf(search): take candidate filenames from key bytes instead of file URLs` |
| 5. Validate, push, hand off for integration | done | orchestrator | |
| 6. Measure A and open the pull request | done | orchestrator | `docs(ledgers): record the port 1481 run and its live measurement` |

## Decisions from the approved plan

- Port only what `main` lacks. `main` already has upstream's two bulk-add optimizations (in-place `RootState` changes and the canonical-ancestor parent check, commit `bd01c5c6f`), so the bulk-add path is unchanged. Source: approved plan.
- No per-generation extension summary. The inventory is `RootState.fileExtensionCounts` alone: `files(inRoot:)`, the computation it replaces, reads the live canonical state, the ingress mutation pass doesn't suspend between a count change and the generation advance, and a summary would add a type, a dictionary and a write on every generation advance with no contract of its own. Source: approved plan.
- No DEBUG fake-disk hook and no 10,000/20,000-file timing-ratio test. Both guard the bulk-add optimization, which is already on `main` and unchanged here, and the hook would add a test bypass to production disk-presence checks. Source: approved plan.
- `RootState.fileExtensionCounts` has no default value, so every `RootState(` construction site must pass it and the compiler finds any that doesn't. Source: approved plan.
- The DEBUG phase `tokenRecount.calculate.allFiles` becomes `tokenRecount.calculate.fileExtensions`, with field `extensions` instead of `files`. Nothing reads these names. Source: approved plan.
- The second whole-root snapshot in `resyncWorkspaceAppliedIndexProjection` stays: it runs only on a resync (generation gap, `requiresFullResync`, or unresolved modification targets). Source: approved plan.

## 1. Confirm the load bodies and measure B

- Evidence: the root-load body builds a local `RootState` through `indexFolders` and `indexFiles` over awaited crawl chunks, checks cancellation, and installs it in one step. The seeded-root build (`makePendingSeededRootTopology`) is synchronous and is installed in one step with its index buffers. Item 2's scope is unchanged.
- Provenance, build B (2026-11-09, 21:52–22:10 local): the integrated build at `c8b0472f5` (`origin/main` at `403c210a8` plus the open distribution pull requests merged by the integration thread), debug app version 1.4.0 (69) from the `DebugApps` bundle, one process for every run (started 21:23:42, same PID before and after each run). macOS 26.6.2 (25G83), Swift 6.4.2. No Agent Mode session or Context Builder run in the debug app during the runs; other dog-food threads stayed off it.
- Settings: a scratch workspace in its own debug window, with generated roots in a scratch folder under the home directory; no selected files, no Git inclusion, code maps on auto with none used, default ignore settings, patch cap at the release value of 4,096, comparison off during timing. The recount events report `fileTreeMode=auto includeFileTree=true`: the plan asked for mode `.files`, which no MCP setting exposes, so both builds keep the new workspace's default. Source: orchestrator judgment.
- Method: the plan's throwaway driver (kept local) moved a staged 200-file folder into the root and out once a second for 60 s after a 16 s warm-up, read an idle file every 2 s, took a runtime snapshot every 5 s, collected `restore_perf_metrics`, and took one 8 s `sample` at 1 ms intervals starting 20 s in. Each stack under a `WorkspaceFileContextStore` entry frame was counted once, by caller. Async backtraces in `sample` show the caller, for example `handleHiddenSessionRootAppliedIndexEvent` above `appliedIndexRootSnapshot` and `allStoreFileRecords` above `files(inRoot:)`. At 1 ms, one sample is about one sampled millisecond.
- Evidence, parity burst: one 200-file addition at 100,200 files patched with 201 effective edits, and `parity_matched` was true.
- Evidence, controlled runs at 100,000 files (runs 1, 2, 3; median): every run applied 52–60 publications in its 60 s window, emitted 32–35 `tokenRecount.calculate.allFiles` events (median 0.70–0.76 s each, `files=100001`), read the idle file 28–30 times with no failure (maximum 6.0 s), and drained within 0.3 s. Samples under store entry frames:

  | Category | Run 1 | Run 2 | Run 3 | Median |
  |---|---:|---:|---:|---:|
  | Hidden-session `appliedIndexRootSnapshot` | 806 | 1,565 | 1,968 | 1,565 |
  | Token recount `allStoreFileRecords` → `files(inRoot:)` | 1,254 | 1,748 | 1,463 | 1,463 |
  | `makeFileTreePresentation` | 337 | 1,239 | 1,475 | 1,239 |
  | Search catalog merge | 135 | 378 | 605 | 378 |
  | Ingress mutation and publication | 105 | 105 | 102 | 105 |
  | `FileSystemService` eligibility under ingress | 37 | 62 | 81 | 62 |
  | Other store entry work | 0 | 7 | 14 | 7 |
  | **All store entry frames** | 2,674 | 5,104 | 5,708 | 5,104 |

  The two consumers this port removes took 77%, 65% and 60% of the store-entry samples. Run 1's capture held fewer process samples overall (30,518 against 70,278 and 76,670), so run-to-run variation is large.
- Evidence, issue 213 reproduction: the generator reached 2,750 live folders (550,000 files on disk) after 302 s. Applied publications per second by minute: 2.82, 1.00, 0.59, 0.35, 0.33, 0.69, 0.75, 0.60, 0.54, 0.55, 0.49. At the 300 s drain bound the store had applied a root of about 241,000 files, 285 publications were outstanding, and the oldest was 535 s old. All 324 idle reads succeeded (median 0.72 s, maximum 3.9 s). The first freshness probe found the newest folder in 0.3 s; all 24 later probes ended in `workspace_freshness_timeout` after 30–34 s, and none returned a wrong result. Samples under store entry frames in the two captures:

  | Category | Near 27,000 files (28,200 → 39,400 applied) | Near 100,000 files (100,200 → 101,000 applied) |
  |---|---:|---:|
  | Hidden-session `appliedIndexRootSnapshot` | 2,178 | 1,585 |
  | Token recount `files(inRoot:)` | 220 | 1,575 |
  | `makeFileTreePresentation` | 449 | 2,384 |
  | Search catalog merge | 183 | 44 |
  | Ingress mutation and publication | 940 | 106 |
  | `FileSystemService` eligibility under ingress | 1,619 | 260 |
  | Path-index rebase (detached task, beside the actor) | 1,262 | 1,084 |
  | Other store entry work | 159 | 40 |

  In the path-index rebase, `closure #1 in PathSearchIndex.init(paths:)`, the `URL(fileURLWithPath:).lastPathComponent` filename derivation that item 4 replaces, took 1,240 of 1,262 samples near 27,000 files and 922 of 1,084 near 100,000.
- Cleanup: the scratch workspace was deleted with `close_window` and the generated folders removed. The window list matches the one recorded at the start except for one empty window, which the MCP close path leaves open until the next debug-app relaunch, as an earlier run recorded.

## 2. Store extension inventory and token recount

- Decision: the first agent on this item was cancelled after it wrote the source edits, because it started before the debug app's Agent Mode providers were set to full access and stopped on every shell approval. Its replacement checks those edits against the plan, then writes the tests and runs validation and the review. Source: the dog-food run's rule for sessions started before the permission change.
- Evidence: the replacement also started in Claude Code's `default` permission mode. In the app, the mode comes from the in-memory secure store, which only the debug app's Settings can change, not from the `claudeCodePermissionMode` user default. I answered its approvals for read-only commands until the coordinator paused the run, because the prompts were reaching MP. Before the pause it reported that the store edits match Design A's mutation table and the recount edits match Design B, and it had started `Tests/RepoPromptTests/WorkspaceContext/CatalogFileExtensionInventoryTests.swift`. Both sessions are cancelled and stopped. The uncommitted source edits and the partial test file stay in the worktree for the next agent. No build or test has run yet. Source: coordinator.
- Decision: after the debug app's Sub-Agent policy was set to Inherit, a third agent took the item over from the worktree state; its session started with `bypassPermissions`. Source: coordinator.
- Decision: the count helpers are methods on `RootState` (`fileExtensionKey(of:)`, `addFileExtension(of:)`, `removeFileExtension(of:)`) rather than a store-level `removeFileExtension(_:state:)`. The counts and their bookkeeping stay with their owner, and a `RootState` method can't read `rootStatesByID` while a caller holds the stored state `inout`, which is the rule the plan set. `indexFile(managedOnly:)` uses optional chaining on `rootStatesByID[root.id]`, where the state is always present. Source: agent judgment, checked by the item review.
- Decision: the managed-only test also removes the file while it is still managed-only, before promotion, then recreates and rematerializes it. This covers the "managed-only removal: no decrement" row; the plan's step list only removed the file after promotion. Source: item review finding (round 1).
- Evidence: `make dev-format` (no changes) and `make dev-lint` pass; `CatalogFileExtensionInventoryTests` 3 of 3 and `WorkspaceSearchServiceTests` 17 of 17 pass; `make dev-swift-build PRODUCT=RepoPrompt` passes. Two throwaway mutations, both reverted, were caught. Without the promotion increment and the `removeFile` decrement, 4 assertions failed in two tests. With an unconditional `removeFile` decrement, the managed-only test stopped on the missing-key assertion.
- Review: the item's `context_builder` review found every transition in Design A correct and raised one test gap, which was fixed; the follow-up found nothing. Refactor gate: no material opportunities. The review judged that the count updates are already consolidated in `RootState` and that the mutation sites are distinct membership transitions.

## 3. Hidden-session applied-index handler

- Decision: `handleHiddenSessionRootAppliedIndexEvent` follows the plan's order. It checks the root's kind and path from `roots()`, returns for a replayed generation before any record request, and asks `appliedIndexRecordLookup` for the event's modified file IDs only. A nil lookup returns `false` without advancing the handled generation. The contiguous-generation and full-resync rule is unchanged. Source: approved plan.
- Evidence: `make dev-format` (no changes), `make dev-lint`, `HiddenSessionAppliedIndexHotPathTests` (1 of 1) and `make dev-swift-build PRODUCT=RepoPrompt` pass. The test sends an ordinary-root event, a session-root event with the wrong path, an empty event, a modification for two files, and a replay of each valid event. It asserts zero `files(inRoot:)` enumerations, zero root snapshots, two lookups for two records in total, and that the lookup returns the same records as the old filtered snapshot. No other suite drives this handler or the slice rebase it schedules, so that parity check is what guards the unchanged behavior downstream.
- Review: the item's `context_builder` review found nothing to fix. Refactor gate: no material opportunities; the change reuses the store's existing lookup.
- Deferred: `resyncWorkspaceAppliedIndexProjection` still takes a whole-root snapshot, but only on a resync, as the plan decided.

## 4. Byte-based candidate filenames

- Decision: `PathSearchIndex.init(paths:)` takes each candidate filename from the UTF-8 bytes after the key's last `/` and decodes them unchanged. An empty, `.` or `..` result falls back to the old `URL(fileURLWithPath:).lastPathComponent`, so degenerate keys keep Foundation's behavior and still build a `URL`. Matching, ranking and every API are unchanged. Source: approved plan.
- Evidence: `make dev-format` (no changes), `make dev-lint`, `PathSearchIndexRecoveryTests` (4 of 4), `WorkspaceSearchServiceTests` (17 of 17) and `make dev-swift-build PRODUCT=RepoPrompt` pass. The new table test compares UTF-8 byte arrays for plain keys, both composite key forms, composed and decomposed Unicode, a combining mark right after a slash, compatibility ideographs, percent signs, `?` and `#`, `~`, newlines and backslashes. For degenerate keys, the old `URL` result is the expected value.
- Review: the item's `context_builder` review found nothing to fix. Refactor gate: no material opportunities.

## 5. Validate, push, hand off for integration

- Evidence: the first `pr-ready` run at `abd090f1b` failed two root tests that #274 tracks as intermittent: `BindContextRoutingAuthorityTests/testNewWindowSwitchReusesPreferredWindowAlreadyShowingWorkspace` and `MCPWorkspaceScopedCursorModelParameterTests/testSettingsPinnedCursorEffortAndSpeedReachRoleLabelRun`. Another worktree's heavy jobs were running at the same time. Both passed when rerun alone on the same build, and the occurrence is recorded on #274. The second `pr-ready` run passed: Swift lint, the root tests (five bundles, `RepoPromptTests` 1,954 of 1,954), and the RepoPrompt product build.
- Evidence: after the push preflight, the branch was pushed at `abd090f1b` and handed to the integration thread for the debug-app run.

## 6. Measure A and open the pull request

- Provenance, build A (2026-11-09 23:58 to 2026-11-10 local): the integrated build at `c0c21c70d`, which is `origin/main` at `403c210a8`, the open distribution pull requests, this branch at `abd090f1b`, and `port/1644-stored-compose-publication` at `f5d40b756`. Debug app version 1.4.0 from the `DebugApps` bundle, one process for every run (started 23:47:54). The other dog-food threads were paused, and no Agent Mode session or Context Builder run was active. Same settings, roots, driver and sampling method as B.
- Decision: the aggregate B-to-A comparison is confounded, because A also merged the 1644 head. That head changes only a stored-only compose-tab update in `WorkspaceManagerViewModel`, not the store or the token-count path, so the consumer-removal result stands either way. Source: approved plan.
- Evidence, recount: on A, each recount logs `tokenRecount.calculate.fileExtensions.end` with `extensions=1` in 0.1 ms. On B it logged `allFiles.end` with `files=100001` in about 0.7 s. `txt` is the only extension in the three loaded roots (the workspace's Git data root holds no files). No `allFiles` event appears on A.
- Evidence, parity burst: patched with 201 effective edits at 100,200 files, and `parity_matched` was true.
- Evidence, controlled runs at 100,000 files (runs 1, 2, 3; median, with B's median for comparison): every run applied 51–60 publications in its 60 s window, logged 58–61 `fileExtensions` recount events (median 0.1 ms, maximum 22 ms), read the idle file 29–30 times with no failure (median 0.25–0.28 s, maximum 4.4 s), and drained within 0.4 s. Samples under store entry frames:

  | Category | Run 1 | Run 2 | Run 3 | A median | B median |
  |---|---:|---:|---:|---:|---:|
  | Hidden-session `appliedIndexRootSnapshot` | 0 | 0 | 0 | 0 | 1,565 |
  | Token recount `files(inRoot:)` | 0 | 0 | 0 | 0 | 1,463 |
  | `makeFileTreePresentation` | 1,423 | 2,879 | 2,556 | 2,556 | 1,239 |
  | Search catalog merge | 209 | 637 | 665 | 637 | 378 |
  | Ingress mutation and publication | 44 | 127 | 131 | 127 | 105 |
  | `FileSystemService` eligibility under ingress | 40 | 75 | 82 | 75 | 62 |
  | Other store entry work | 3 | 10 | 5 | 5 | 7 |
  | **All store entry frames** | 1,719 | 3,728 | 3,439 | 3,439 | 5,104 |

  No A capture holds an `allStoreFileRecords` frame, an `appliedIndexRootSnapshot` frame from any caller, or a `files(inRoot:)` frame from any caller. The median total fell from 5,104 to 3,439. The ranges overlap, though (B 2,674–5,708, A 1,719–3,728), and the comparison is confounded, so the aggregate improvement is not established. The file-tree presentation took up part of the freed time: more recounts finished per run (35–39 `calculate.end` events per run, against 22–26 on B), and each one builds the presentation.
- Evidence, issue 213 reproduction: the generator reached 2,750 live folders (550,000 files on disk) after 313 s. The store applied all 589 publications and the whole 550,000-file root, and the backlog drained 233 s after the generator stopped. On B, 285 publications were still outstanding at the 300 s drain bound, and the applied root held about 241,000 files. Outstanding publications peaked at 133, and the oldest reached 226 s just before the drain (on B, 504 and 535 s). Applied publications per second by minute: 3.70, 1.91, 0.90, 0.46, 0.55, 0.82, 0.65, 0.48, 0.44 (B: 2.82, 1.00, 0.59, 0.35, 0.33, 0.69, 0.75, 0.60, 0.54). All 226 idle reads succeeded (median 0.95 s, maximum 11.2 s; on B, median 0.72 s and maximum 3.9 s). Freshness probes: the first 9 succeeded within 0.3–14 s, up to 143 s into the run. The 12 taken from 182 s until the drain ended in `workspace_freshness_timeout` after 31–39 s. The 4 after the drain succeeded in 6–12 s. No probe returned a wrong result. These are single runs, confounded, and not tail-latency estimates.
- Evidence, reproduction captures: near 27,000 files (A 28,400 → 37,200 applied, overlapping B's 28,200 → 39,400), A had 0 samples in the hidden-session snapshot (B 2,178) and 0 in the token-recount enumeration (B 220), against 503 in `makeFileTreePresentation` (B 449), 216 in the search merge (B 183), 1,242 in ingress (B 940), 2,165 in eligibility (B 1,619), and 350 in the path-index rebase (B 1,262). The near-100,000 captures don't overlap (A 106,600 → 120,200, B 100,200 → 101,000), so they aren't compared; the A capture again had 0 samples in both removed consumers. In the path-index rebase, `closure #1 in PathSearchIndex.init(paths:)` fell from 1,240 samples to 87 near 27,000 files and from 922 to 98 near 100,000, with no `URL.init(fileURLWithPath:)` beneath it on A.
- Evidence, accounting gate: with the idle file selected in the scratch window, the recount (`selectedPaths=1`) published `fileTokens=9 fileTreeTokens=14 totalTokens=23`, and `workspace_context` showed the same numbers with the file tree `idle/idle.txt`. Its "stale … refresh pending" label describes the render's cache source; the values matched the published recount.
- Gates: every focused test passes; recounts on A log `fileExtensions` events and the extension set matches the files on disk; no A capture holds a sample in either removed consumer; project-structure and selected-file accounting are correct; both parity bursts matched; no wrong file or search result was accepted as success. The DEBUG missing-count assertion didn't fire.
- Cleanup: the patch cap override is back to the release value and comparison is off. The recount log stays on, as the debug app's defaults already had it. The scratch workspace was deleted with `close_window`, the generated folders were removed, and the window and workspace lists match the ones recorded before A.
- Deferred: the prompt-stats file tree (`makeFileTreePresentation`) is now the largest store-actor consumer per publication, and the search catalog merge still reads whole roots. #241 and #222 stay open for them.
