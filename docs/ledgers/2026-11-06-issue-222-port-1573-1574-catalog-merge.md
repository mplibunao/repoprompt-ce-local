# Run ledger: upstream PRs 1573 and 1574 against the distribution's catalog batch patch

Request: #222 · Plan: `port-1573-1574-catalog-comparison-2026-11-06.md` (local)

The run compared upstream PR 1573 (commit `34a2c301f`, which includes closed upstream PR 1568's commit) and upstream PR 1574 (commit `4d98038bc`) with the distribution's own catalog batch patch from #240, chose whether to port, adapt, or stop, and measured the distribution's batch path on the debug app. Branch `port/1573-incremental-catalog-updates`, started from `main` at `c4b5abfed` and rebased onto `403c210a8`. The run was unattended, and the coordinating thread answered questions.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Compare and decide | done | orchestrator, with explore agents, Context Builder, and a design critique | |
| 2. Run the existing focused suites | done | orchestrator | |
| 3. Measure the batch path and re-run the #213 reproduction on the debug app | done | pair · Orchestrate 3/4: catalog measurement | |
| 4. Record and commit this ledger | done | orchestrator | `docs: record why upstream 1573 and 1574 aren't ported for issue 222` |

## 1. Compare and decide

- Decision: **stop**. No source change and no pull request. Source: approved plan, under the task brief's rule that a port which would replace local work stops with a written comparison.
- Decision: 1573's store half is already on `main` through #240. `buildRootCatalogShardPatch` dedupes and sorts only the batch, binary-searches the shard's sort orders, and run-merges each edited array once, reusing arrays without edits (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:9404–9711`). It builds no whole-root ID map per patch and merges the code-map list in catalog order without re-sorting. Upstream's merge (`mergeRootCatalogShardRecords`) reaches the same goal with a different algorithm and re-derives search entries and projection files from the whole output array. Upstream still allows one effective edit per patch, and `main` allows 4,096 (`:3407`). Source: orchestrator judgment from code reads on both sides.
- Decision: 1574's rule is already on `main`. Unchanged upserts, including a nested add's unchanged ancestor folders, and verified modification-only deltas are no-ops that don't count toward the cap (`:9426`, `:9588–9600`, `:9649–9651`). Source: code read.
- Decision: 1573's path-index half, which is closed upstream PR 1568's commit, conflicts with `main` and is rejected. Upstream's materialized patch walks every entry, sums every entry's key bytes, and rebuilds the whole index synchronously on the store actor when its single overlay passes twice a fresh index's cost (upstream `Search/PathSearchIndex.swift:665–758`; store `:9338`). `main` appends one overlay segment built from the batch's changed entries (`Search/PathSearchIndex.swift:657`) and rebases off the actor. Porting upstream's version would bring back root-sized work on the actor that #240 removed. Upstream bounds query fan-out to one overlay. `main` lets overlays build to 32 payloads, or more while a rebase is in flight, before folding them. Source: orchestrator judgment, confirmed by the design critique's spot-check of both files.
- Decision: no adaptation of the remaining differences. Upstream compares five path strings by UTF-8 bytes (`isByteIdentical(to:)`), where `main` uses synthesized `Equatable` and Swift's canonical-equivalence `String ==`. Upstream's merge also checks path ownership, managed-only exclusions, parent-chain cycles, and retained children of absent folders. These are stricter at the boundary, but no route that delivers a byte-different, canonically equal record to the patch builder is established: ingress reuses the existing record for a canonically equal path (ledger `docs/ledgers/2026-10-19-issue-222-catalog-shard-batch-patch.md`, line 61). Upstream's tests assume its one-overlay ownership and synchronous compaction, so none are copied. Source: approved plan.
- Decision: upstream PR 1568, which 1573's notes name as a prerequisite, was closed unmerged. Its commit is squashed into 1573's merge, so there was nothing separate to find. Source: upstream PR state and history in the reference clone.
- Evidence: #350 (upstream 1626), which landed during the run, changes two lines in `Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+DirectoryEnumeration.swift`. Nothing under `Sources/RepoPrompt/Infrastructure/WorkspaceContext/` changed between `c4b5abfed` and `403c210a8`, so the comparison holds on the new `main`.
- Evidence: the Context Builder planning draft claimed that upstream's `testMaterializedDeltaParityAt200001Files` asserts no timing. It asserts under 8 s and under half the authoritative build's time (upstream `Tests/RepoPromptTests/WorkspaceContext/WorkspaceRootCatalogAdmissibilityTests.swift:957–958`), so that correction was rejected.
- Note: the run paused for the build 69 production release. The release restarted the RepoPrompt MCP bridge, so the planning call and later RepoPrompt calls ran over the CLI.

## 2. Run the existing focused suites

- Evidence: on `403c210a8`, `make dev-test FILTER=WorkspaceSearchServiceTests` ran 17 tests with 0 failures, and `make dev-test FILTER=PathSearchIndexRecoveryTests` ran 3 with 0 failures. They include `testCatalogBatchPatchMatchesAuthoritativeCatalog`, `testInvalidCatalogBatchFallsBackWithoutPartialPublication`, `testPathIndexRebaseKeepsNewerOverlaysAndDiscardsStaleResult`, `testPathIndexRebaseInFlightAtUnloadDoesNotReachReloadedRoot`, `testProjectedPatchWithExplicitPathsMatchesFreshIndex`, and `testMaterializedOverlayRebasePreservesSearchResults`.
- Decision: no tests added, because no executable contract changed. Source: approved plan.

## 3. Measure the batch path and re-run the #213 reproduction

Debug app built from this branch at `403c210a8` (bundle provenance checked before each attempt), on an arm64 Mac, 2026-11-06. Scratch roots were generated under the home directory, outside every checkout, and removed afterwards. The DEBUG diagnostics are described in `docs/testing.md` ("Catalog shard patch measurement").

### Cap comparison

- Method: a 100,000-file root (500 folders of 200 one-line files). Each burst renamed 1, 2, 4, 16, or 64 staged files into existing folders, so a batch's effective edits equal its file count, and each burst was reversed before the next. Two modes: cap override 1, which is upstream's one-edit limit applied to the distribution's own patch code (not a benchmark of upstream's implementation), and the release cap of 4,096. Each size had 3 warm-up pairs and 10 measured pairs, alternating which mode ran first, with comparison mode `next` on release-cap and size-1 attempts. All 130 attempts were valid, all on one root lifetime.
- Evidence (milliseconds; P95 is nearest-rank over 10, so it is the largest):

| Size | Mode | Outcome | Patch timed total med / P95 | Rebuild med / P95 | Canonical apply med / P95 | Parity |
|---:|---|---|---|---|---|---|
| 1 | cap 1 | 10 patched | 6.00 / 8.02 | 1,727 / 1,782 (comparison) | 19.8 / 22.8 | 10/10 |
| 1 | release | 10 patched | 6.35 / 7.70 | 1,756 / 1,926 (comparison) | 18.6 / 20.5 | 10/10 |
| 2 | cap 1 | 10 rebuilt, `patchThresholdExceeded` | – | 1,995 / 2,079 (forced) | 2,000 / 2,083 | – |
| 2 | release | 10 patched | 7.56 / 11.35 | 1,981 / 2,109 (comparison) | 22.9 / 28.7 | 10/10 |
| 4 | cap 1 | 10 rebuilt, `patchThresholdExceeded` | – | 1,927 / 2,134 (forced) | 1,931 / 2,139 | – |
| 4 | release | 10 patched | 7.78 / 9.22 | 1,984 / 2,067 (comparison) | 22.7 / 29.4 | 10/10 |
| 16 | cap 1 | 10 rebuilt, `patchThresholdExceeded` | – | 1,964 / 2,262 (forced) | 1,971 / 2,269 | – |
| 16 | release | 10 patched | 8.63 / 9.38 | 2,064 / 2,285 (comparison) | 26.8 / 45.2 | 10/10 |
| 64 | cap 1 | 10 rebuilt, `patchThresholdExceeded` | – | 1,915 / 2,089 (forced) | 1,931 / 2,106 | – |
| 64 | release | 10 patched | 9.71 / 13.09 | 1,883 / 2,081 (comparison) | 34.9 / 40.5 | 10/10 |

- Notes:
  - The patch timed total is the sum of the five DEBUG-timed phases (normalize, locate, derive, merge copy, path-index segment). A forced rebuild's time covers the rebuild path including publication. A comparison rebuild's time covers only building the authoritative shard. Canonical apply isn't end-to-end latency.
  - Each add carried 3 inputs (the file and its 2 unchanged ancestor folders), all counted as no-ops.
  - The merge copy was 75–98% of the patch's timed total (6.2–7.9 ms median at this root size). The batch-dependent phases grew with the batch: locate went from 45 µs to 1,256 µs, and the path-index segment from 64 µs to 633 µs.
  - The cap rule from `docs/investigations/catalog-shard-batch-patch-2026-10-20.md` passed at sizes 2–64: the patch median was 0.4–0.5% of the paired rebuild median, and every patch P95 was below the rebuild P95.
  - `path_index_build_count` didn't change on any release-cap or size-1 attempt and rose by 1 on each forced rebuild.
  - Only the size-1 series reached the 32-payload rebase trigger: one off-actor rebase started and installed, with a 784 ms build. At sizes 2–64 each cap-1 rebuild published a fresh index, so overlays peaked at 5 payloads. Those rows don't cover deep overlay history.
- Evidence: the result for this run's question is that with upstream's one-edit limit, a batch of 2 to 64 files costs about 2 s of store-actor time on a 100,000-file root, whatever the batch size. On `main` the same batch patches in about 20–35 ms of canonical apply.
- Note: another thread relaunched the shared debug app with its own build partway through the first cap series. That series was discarded. The run waited for the app to go idle (no agent session, no queued lifecycle job), relaunched this build, and restarted from the first warm-up. Source: orchestrator judgment, under the brief's idle-check rule.

### #213 reproduction

- Method: following investigation §4, on a fresh root, the generator created a folder of 200 one-line files every 100 ms and deleted the oldest folder every 2 s, until 2,750 live folders (550,000 files) existed. A second root held one idle file. Release cap, comparison off. Bounds: 10 minutes of generation, then 10 minutes of drain.
- Evidence:
  - Generation: 2,896 folders created and 146 deleted in 293 s, offering about 1,979 files per second. 31 late ticks were skipped, not caught up.
  - The store applied at most 320,367 files and never reached 550,000. Outstanding publications rose to 232 during generation, and 90 were still outstanding when the drain bound ended the run, the oldest 724 s old. Ingress didn't drain.
  - Applied publications per second by minute: 1.27, 0.60, 0.36, 0.28, 0.22, 0.27, 0.37, 0.35, 0.25, 0.24, 0.25, 0.18, 0.13, 0.14. Applied files per minute fell from about 46,000 to 12,000 during generation.
  - 303 of 306 batches patched. The other 3 had 4,422 to 5,025 effective edits, above the cap, and rebuilt in 6.4–6.8 s each, with 8.3–12.4 s of canonical apply.
  - Batches of 1,001 to 4,096 effective edits had median mutation passes of 133, 151, 186, 229, and 240 ms in the 0–50k, 50–100k, 100–200k, 200–300k, and 300–400k applied-file bands. The merge copy median rose from 1.9 to 29.7 ms across the same bands.
  - All 28 `file_search` freshness probes, 14 that had to find a file and 14 that had to find it absent, timed out at the 30 s freshness wait. All 29 idle-file reads succeeded, with a maximum of 2.0 s.
  - Path-index rebases: 47 started and 47 installed off the actor, with no discards; the longest build was 8.0 s.
  - Process samples (two 8 s samples, shares of store-actor samples):
    - At about 27,000 applied files: ingress 34% (most of it the per-file eligibility checks #242 tracks), `makeFileTreePresentation` 25%, `appliedIndexRootSnapshot` 15% (from `WorkspaceFilesViewModel.handleHiddenSessionRootAppliedIndexEvent`), `files(inRoot:)` 14% (from `TokenCountingViewModel`), `searchCatalogSnapshot` 9%, and the shard patch 3%.
    - At about 100,000–115,000 applied files: `makeFileTreePresentation` 41%, `appliedIndexRootSnapshot` 28%, `files(inRoot:)` 24%, ingress 6%. The shard patch didn't appear.
- Decision: #222's third Done-when still fails on `403c210a8`. The backlog grew, applying slowed as the root grew, and freshness probes timed out. The shard patch isn't the cause: as in October, the whole-root consumers that #241 tracks fill the store actor. Source: this measurement.
- Deferred:
  - Closing #222's third Done-when depends on #241, with #242 relevant early in a burst, followed by a full-scale reproduction that reaches and drains 550,000 applied files with correct probes and no sustained backlog growth. Upstream PR 1481 (upstream commit `7d5f19bbd`, merged 2026-10-25, after #241 was filed) removes the whole-root snapshot from hidden-session index events and keeps a catalog language inventory for token recounts. Those two paths took 52% of the second sample, so 1481 is a port candidate for #241. #241's statement that the paths are unchanged upstream predates 1481. Source: orchestrator judgment.
  - Under this load, the watcher delivered batches above 4,096 effective edits, which the October matrix couldn't produce. That makes it possible to measure whether patching still beats rebuilding above the current cap, a question for #222's cap rather than for this run.
- Evidence: this run doesn't change #241. No source changed, and the reproduction re-measured the four consumers on the current `main`.

### Cleanup

- Evidence: the measurement agent reset the diagnostics in both scratch windows to cap override 0, comparison off, and sample limit 0. It deleted both scratch workspaces with `close_window` before deleting their files, then removed the generated roots and driver scripts. It left the debug app running this build and didn't stop or launch the production app. After its workspace was deleted, one scratch window stayed listed as an empty "Default (no workspace loaded)" window.

## Parked decisions

- How should this ledger reach `main`? The brief and the coordinating thread decided to commit it on this branch and not open a pull request. `CONTRIBUTING.md` commits ledgers so later agents can read them in the checkout, and a ledger on a local branch doesn't reach them. Options: (a) a docs-only pull request that contains only this ledger. (b) Carry it in the pull request of the next change to #222 or #241. (c) Leave it on the branch. Recommendation: (a). The branch isn't pushed, because deleting a remote branch needs explicit approval (`AGENTS.md`, "Commit preflight"). Blocks: nothing in this run.
