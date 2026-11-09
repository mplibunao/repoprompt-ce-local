# Run ledger: port upstream PR 1481 (whole-root reads)

Request: #241 and #222, referred to without closing them · Plan: a local `rp-deep-plan` plan, not committed

Re-implement upstream PR 1481 (upstream commit `7d5f19bbd`) by hand, so that two of the four per-publication consumers that #241 names stop reading the whole root on the `WorkspaceFileContextStore` actor: the hidden-session applied-index handler and token counting's language scan. Measure sampled store work before and after on a matched pair of integrated debug builds.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Confirm the load bodies and measure B | done | orchestrator | |
| 2. Store extension inventory and token recount | done | pair · Orchestrate 2/4 (two cancelled for permissions, then resume 2) | `perf(workspace-context): count file extensions instead of enumerating roots for token recounts` |
| 3. Hidden-session applied-index handler | pending | | |
| 4. Byte-based candidate filenames | pending | | |
| 5. Validate, push, hand off for integration | pending | | |
| 6. Measure A and open the pull request | pending | | |

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

## Parked decisions
