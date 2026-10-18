# Investigation: Upstream sync — local patch branch vs upstream/main (2026-07-20)

> Investigation report, observed 2026-07-20 on upstream `main` at `feb0ac92`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/porting.md](../porting.md), Procedure.

## Summary
Of the five local fixes on the local patch branch, upstream/main (`feb0ac92`) has superseded two and made one redundant-in-practice: the Codex wire-key fix (superseded by merged upstream PR 450 / `dbf69f55` — MP's own PR), the MCP retry-backoff drain (superseded by upstream PR 517's explicit proxy-race settlement `05ae21c6`+`6b677465`, which closed upstream issue 513), and the test-only selected-scope fixture change (overlapping upstream test rework `494e4e84`; drop from runtime builds). The two selection patches (bounded mirror tail and waiter invalidation — upstream PR 472 still open upstream) remain required and cherry-pick onto `feb0ac92` with only a trivially reconcilable test-ledger conflict. Rebuild plan: new branch from `feb0ac92` + the two selection patches only.

## Symptoms / Task
- The local patch branch carries 5 personal fixes; upstream `repoprompt/repoprompt-ce` main has advanced 146 commits past the branch base.
- Need to determine per-patch: superseded / conflicting / still required, then rebuild on updated upstream main (recent PRs include performance improvements).

## Background / Prior Research
- **Prior audit (2026-07-15)**: `docs/investigations/mp-patches-vs-latest-release-2026-07-15.md` audited all 5 patches against `v1.0.29` (`fe68009b`) and then-current `upstream/main` (`f7b899d9`). Verdict then: all 4 runtime fixes missing upstream; the test-setup patch test-only.
- **Branch state (2026-07-20, after `git fetch upstream --tags`)**:
  - The local patch branch tracks `upstream/main`, ahead 5 / behind 146.
  - `upstream/main` = `feb0ac92` ("Merge upstream PR 591 … context-builder-phase-settlement").
  - No new release tag since `v1.0.29`.
  - `git cherry` against `upstream/main`: all 5 commits `+` (no exact patch-ID equivalents upstream — but see content-level supersession below).
- **The 5 local patches** (base `dd8a14ed`):
  1. Wire-key patch — fix: update Codex app-server text payload key (`text_elements` wire key)
  2. Mirror-tail patch — fix: bound selection mirror tail (WorkspaceSelectionCoordinator)
  3. Waiter patch — fix: release auto-selection mirror waiters (MCPReadFileAutoSelectionCoordinator; depends on the mirror-tail patch)
  4. Test-setup patch — fix: synchronize selected-scope test setup (test-only, MCPCodeStructureWorktreeTests)
  5. Retry-drain patch — fix: drain MCP retry backoff on cancellation (upstream issue 513) (MCPRetryBackoffWait helper + main.swift call site)
- **Upstream delta on affected paths since prior audit (`f7b899d9..feb0ac92`)**:
  - `CodexNativeSessionController.swift` +26 / tests +48 — includes merged **`dbf69f55` "fix: update Codex app-server text payload key"** (the exact ledger-free refined equivalent named in the prior audit) and `b06ce05f` merge. Upstream now emits `text_elements` (line ~1651). → the wire-key patch likely SUPERSEDED.
  - `Sources/RepoPromptMCP/main.swift` +136 — **`05ae21c6` "Avoid MCP proxy task teardown abort"**, **`6b677465` "Harden MCP proxy pre-cancellation handling"**, `7a832f0c` "Validate Codex MCP provisioning before child process start". Upstream still has a direct `Task.sleep(for: .seconds(delay))` at main.swift:2392; no `MCPRetryBackoffWait.swift` upstream. → relationship to the retry-drain patch NEEDS SEMANTIC ANALYSIS (superseded vs conflicting vs complementary).
  - `MCPCodeStructureWorktreeTests.swift` +54 — **`494e4e84` "test(mcp): stabilize selected scope budget setup"** → relationship to the test-setup patch needs check.
  - **`WorkspaceSelectionCoordinator.swift` and `MCPReadFileAutoSelectionCoordinator.swift` (+ their tests): ZERO upstream changes** since prior audit → the mirror-tail patch + the waiter patch still required, low textual conflict risk.
- Topic branches feeding the patches: `bugfix/codex-app-server-text-payload-key`, `bugfix/selection-mirror-wedge` and a local rebase of it, a local retry-backoff branch, `bugfix/514-fail-closed-child-mcp-provisioning`, `bugfix/526-context-builder-typed-responses` (upstream issue 526→upstream PR 529 merged upstream previously).
- Related upstream artifacts to verify: upstream PR 472 (selection mirror), upstream issue 513 / upstream PR 517 (retry backoff), provenance of `dbf69f55` / `05ae21c6` / `494e4e84` / `7a832f0c`.

## Investigator Findings
<!-- Protocol note: no separate pair session was needed — the context_builder+oracle audit and the explore agent's GitHub archaeology answered every open question; orchestrator spot-checks confirmed the load-bearing claims. -->

### Per-patch verdict matrix (vs upstream/main `feb0ac92`)

| Patch | Upstream overlap | Verdict | Confidence | Key evidence |
| --- | --- | --- | --- | --- |
| Wire-key patch: Codex `text_elements` wire key | `dbf69f55` merged via **upstream PR 450 (author: MP)** | **SUPERSEDED — drop** | High | `git grep text_elements upstream/main` hits `CodexNativeSessionController.swift:1651`; upstream PR 450 merged as `0c9eb511` |
| Mirror-tail patch: bounded selection mirror tail | None — `WorkspaceSelectionCoordinator.swift` + tests unchanged upstream since `f7b899d9`; **upstream PR 472 still open** | **STILL REQUIRED — carry first** | High | `git merge-tree` dry-run: conflict only in `Scripts/Fixtures/test-suite-contract-ledger.tsv` (3 added rows); source/tests clean |
| Waiter patch: context-owned waiter invalidation | None — `MCPReadFileAutoSelectionCoordinator.swift` + tests unchanged upstream; upstream PR 472 still open | **STILL REQUIRED — carry after the mirror-tail patch** (dependency order) | High | `git merge-tree` dry-run: fully clean (its 2 ledger rows auto-merge) |
| Test-setup patch: selected-scope test fixture (test-only) | `494e4e84` merged via upstream PR 488 reworked the same test (availability retries + diagnostics; different concern: canonical fixture authority vs transient-root retries) | **DROP from runtime build** (optionally reconcile later as test-only work) | High | Prior audit already classified it optional test-only; both patches edit the same assertion area → medium reconcile cost, zero runtime value |
| Retry-drain patch: MCP retry-backoff cancellation drain | **upstream PR 517 merged (`05ae21c6` + `6b677465`), closed upstream issue 513** — replaces `MCPService.run()`'s `withThrowingTaskGroup` with lock-protected first-settlement race over three explicit Tasks | **SUPERSEDED — drop provisionally** | Medium-high | Upstream `main.swift:2181-2184` awaits `killSignalTask.value`, `watchdogTask.value`, `transportTask.value` before returning → the retry `Task.sleep` necessarily resumes, throws cancellation, and unwinds before teardown. The implicated task-group teardown boundary no longer exists. Upstream `MCPServiceProxyRaceTests` cover loser draining and pre-cancelled entry. Residual risk: upstream tests don't drive the real `runTransport` retry sleep; see Recommendations for validation. |

### Oracle retry-crash reasoning
- The local retry-drain patch and upstream PR 517 address the same teardown-crash class at different levels: local drains only the retry sleep in an owned nested task; upstream owns the whole transport operation as an explicit `Task`, cancels it, and awaits settlement before the race returns.
- Once `transportTask.value` returns, the direct retry sleep has already unwound — the retry-drain patch establishes no independent runtime invariant on `feb0ac92`. Carrying it would not conflict but is speculative defense-in-depth; dropping maximizes convergence with upstream (the user's stated preference).

### GitHub provenance (explore agent, verified against local merge commits)
- Upstream PR 450 (Codex payload key, **MP**) → merged `0c9eb511` / commit `dbf69f55`.
- Upstream PR 517 (proxy teardown, by an outside contributor, with commits authored by a maintainer) → merged `feb4f3eb`; **closed upstream issue 513**.
- Upstream PR 488 (a contributor's perf/manifest + test stabilization) → merged `46ea3a32`, includes `494e4e84`.
- Upstream PR 532 (fail-closed Codex MCP provisioning, **MP**) → merged `56097581` — local branch `bugfix/514-fail-closed-child-mcp-provisioning` is upstream now.
- Upstream PR 472 (selection mirror wedge, MP) → **still open**; no successor commits touch either selection coordinator file on upstream/main.

### Performance work in `f7b899d9..feb0ac92` (motivates rebasing now)
- `ab83f6af` Speed up Context Builder selection handoff (upstream PR 591)
- `4b8170b7` Fix agent message bubble line counting performance (upstream PR 584)
- `629cf45f` perf(mcp): bound progress delivery backpressure (upstream PR 578)
- `877f4eb8` perf(codemap): bound manifest reconciliation work + `46ea3a32` (upstream PR 488)
- `a607a9cd`/`c7bda0d9` Avoid global manifest scans for access refreshes (upstream PR 552, production CPU spikes)
- `0cf54d87` perf(codemap): batch manifest writer mutations (upstream PR 487)

## Investigation Log

### Phase 1 — Assessment & git triage (orchestrator)
**Hypothesis:** Some of the 5 patches are now redundant given 146 new upstream commits.
**Findings:** See Background — 3 of 5 patches have upstream activity in their exact files; 2 selection patches untouched upstream.
**Evidence:** `git cherry`, `git diff --stat f7b899d9..upstream/main -- <affected paths>`, `git grep text_elements upstream/main`, upstream log on affected files.
**Conclusion:** Codex wire-key fix likely superseded; retry-backoff and test-only patch need semantic comparison; selection pair still required.

### Phase 2-4 — Context builder + oracle audit + verification (orchestrator)
**Hypothesis:** upstream PR 517 supersedes the retry-drain patch; upstream `494e4e84` overlaps the test-setup patch; selection pair still needed.
**Findings:** All confirmed — see Investigator Findings matrix.
**Evidence:** the oracle audit; explore-agent GitHub verification; orchestrator spot-checks (`upstream/main:main.swift:2181-2184` child-task draining; `git merge-tree` dry-runs).
**Conclusion:** Carry only the mirror-tail patch + the waiter patch.

### Phase 5 — Rebuild execution (2026-07-20)
- New local build branch from `feb0ac92`; cherry-picked the mirror-tail patch (ledger conflict resolved as union: upstream rows + 3 carried `WorkspaceSelectionCoordinatorTests` rows) and the waiter patch (clean, ledger auto-merged).
- Contribution preflight `commit` mode passed before each commit; `push` mode passed from a pristine detached worktree; branch pushed to the fork.
- Coordinated validation via conductor daemon (all passed):
  - Debug package build (`ALLOW_ADHOC_SIGNING=1`, matching the ad-hoc-signed running app): packaged successfully; staged into `DebugApps/RepoPrompt.app`; running app instance untouched (no liveApp lane).
  - `WorkspaceSelectionCoordinatorTests`: 27/27 passed.
  - `MCPReadFileAutoSelectionCoordinatorTests`: 19/19 passed (includes carried replacement-lane test).
  - `MCPServiceProxyRaceTests` (upstream PR 517 coverage): 4/4 passed with our patches applied — no interference between upstream teardown rework and the selection patches.
  - `verify-ledger`: our 5 carried rows reconcile; reports `missing=10 stale=1` in `AgentContextExportResolverTests`/`CodemapPresentationTests` — verified pre-existing on pristine upstream `feb0ac92` (methods exist in upstream tests but not upstream's ledger; the stale row is upstream's). Inherited upstream debt, not introduced by this branch; left for upstream to fix.
- Not done pending explicit user approval: relaunching the visible debug app onto the new build (kills the live MCP session).

## Root Cause
Not a defect investigation — a reconciliation audit. Net state: upstream absorbed MP's Codex wire-key fix (upstream PR 450) and provisioning fix (upstream PR 532), and independently fixed the MCP teardown crash differently (upstream PR 517), leaving only the two selection-mirror patches (open upstream PR 472) as genuinely local value.

## Recommendations
1. Build the replacement branch from `upstream/main` `feb0ac92`: cherry-pick the mirror-tail patch (resolve the `test-suite-contract-ledger.tsv` conflict as a union — keep upstream rows, append the 3 rows for the carried `WorkspaceSelectionCoordinatorTests` methods), then the waiter patch (clean).
2. Drop the wire-key, retry-drain, and test-setup patches from the runtime patch stack.
3. Validate: coordinated build, focused suites (`WorkspaceSelectionCoordinatorTests`, `MCPReadFileAutoSelectionCoordinatorTests`, `MCPServiceProxyRaceTests`, `MCPProxyTerminalRecordTests`), ledger verification per `docs/testing.md`.
4. Retry-crash residual risk closure (optional): run a release-build stress harness that cancels `MCPService.run()` while `runTransport` is suspended in its retry sleep (before sleep / suspended / resuming) across caller-cancel, kill-signal, and watchdog paths. If unmodified `feb0ac92` passes, dropping the retry-drain patch is permanent; if the crash reproduces, re-add `MCPRetryBackoffWait` from its local topic branch.
5. Keep the old local patch branch untouched as the rollback point until the new build survives daily use.

## Preventive Measures
- Re-run this audit whenever upstream merges into files the patch stack touches: `git fetch upstream && git diff --stat <last-audit-tip> upstream/main -- <affected paths>` is the cheap trigger.
- Keep each local fix on its own `bugfix/*` topic branch with an upstream PR (this is what made supersession detection trivial for upstream PRs 450, 532, and 517).
- Track upstream PR 472; when it merges in any form, re-audit the two selection patches for supersession the same way.
