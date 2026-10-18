# Investigation: upstream PR 472 vs upstream main parity + tip release channel (2026-07-24)

> Investigation report, observed 2026-07-24 on upstream `main` at `cebd7e64`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

## Summary
1. **Upstream has NOT solved the issue upstream PR 472 fixes.** Upstream issue 457 (selection-mirror wedge) is still open; no upstream commit or PR (including the adjacent upstream PR 520 mutation-ingress work and the recent MCP-reliability wave) adds either of upstream PR 472's two guarantees. The local build's ONLY delta vs upstream/main is the upstream PR 472 fix — everything else (incl. Upstream PR 568) has merged. Dropping the local build means re-accepting the upstream issue 457 wedge until upstream PR 472 lands.
2. **Tip Builds** is an official opt-in rolling update channel (upstream PR 442, live since 2026-07-10): every merge to `main` that passes CI is signed, notarized, and published to `repoprompt/repoprompt-ce-tip-updates`; the app's Sparkle updater pulls from that feed when Settings → General → Updates → Update Channel is set to "Tip Builds". Switching to Tip is the natural replacement for the local build — once upstream PR 472 merges.

## Questions
1. Is the issue upstream PR 472 addresses (selection mirror wedge recovery, upstream issue 457) already solved in current upstream main? Can MP drop the local build (`release/mp-patches-*`) and run the official version?
2. What is the "tip release" — how does it work, where is it configured, what code/issues/PRs define it?

## Known context (from the personal toolkit's RepoPrompt CE notes)
- Local fork checkout; build branch pattern `release/mp-patches-*`.
- Patch ledger (as of last update):
  - Upstream PR 568 (worktree-bound Codex app-server startup fix, upstream issue 554) — was OPEN; MP reports it just merged upstream. VERIFY.
  - Upstream PR 472 (selection mirror wedge recovery, upstream issue 457, local branch `bugfix/selection-mirror-wedge`) — OPEN; the only remaining local patch. mp-patches also carries follow-on commits "bound selection mirror tail" and "release auto-selection mirror waiters".
- Merged-and-dropped history: upstream PRs 450 and 532 (v1.1.0, 2026-07-21), upstream PR 529 (2026-07-13).
- Upstream is undergoing big changes (e.g., bundling the codex app server); PRs may be superseded/stale.

## Background / Prior Research

### A. GitHub state of upstream PR 472 / upstream issue 457 (explore agent, gh, 2026-07-24)
- **Upstream PR 472** ("Fix selection mirror wedge recovery"): **OPEN**, base `main`, head `bugfix/selection-mirror-wedge`, mergeability **CONFLICTING** (`DIRTY`). Last updated 2026-07-11. Commits: `d8d47126` (bound selection mirror tail), `57a3f408` (release auto-selection mirror waiters), `37047b39` (synchronize selected-scope test setup). Last review: copilot bot, 2026-07-10; no human review since.
- **Upstream issue 457** ("manage_selection mutations wedge a whole window at the 30s contract via the uncancellable, un-timed selection-mirror task chain"): **OPEN**. Closing reference: upstream PR 472. No commit/PR has closed it.
- **No independent upstream fix**: searched upstream main 2026-07-03→07-24 for selection mirror / wedge / auto-selection / waiters / WorkspaceFileContextStore mirror; also checked commits touching `WorkspaceSelectionCoordinator.swift`, `MCPReadFileAutoSelectionCoordinator.swift`, `WorkspaceFileContextStore.swift`. `MCPReadFileAutoSelectionCoordinator.swift` (one of upstream PR 472's two implementation files) has **zero upstream-main commits in the period**.
- Adjacent but not a supersession: **upstream PR 520** ("Fix Oracle selection packaging and mutation ingress stalls", merged 2026-07-12, merge commit `dcc6a511`) — canonical selection packaging + ingress stalls; closed upstream issues 515 and 390, did not touch the auto-selection coordinator, not an upstream issue 457 fix.
- **Upstream PR 568** (worktree-bound Codex app-server startup, upstream issue 554): **MERGED 2026-07-22**, merge commit `6834a541`.

### B. Local build vs upstream/main (explore agent, git, 2026-07-24)
- Current build branch: `release/mp-patches-2026-07-20`, head `bbe19ad2` (merge of `bugfix/codex-worktree-app-server-start`). Behind upstream/main by **109 commits**.
- `upstream/main` = `cebd7e64`.
- **Local-only commits: exactly two** — `23e31e27` "fix: release auto-selection mirror waiters" and `6fa4cde7` "fix: bound selection mirror tail" (the upstream PR 472 content, +513/−94 across coordinator + tests). Everything else in the build branch is reachable from upstream.
- Ancestor checks: `bugfix/codex-worktree-app-server-start` **IS** in upstream/main (landed as true merge `6834a541`); `bugfix/selection-mirror-wedge` (head `2ca83e97`) is **NOT**, and no squash-equivalent subject exists.
- Recent upstream themes (last ~3 weeks): (1) **bundled pinned/signed Codex runtime is now the runtime authority** (`4fd888ed`, `f6ab144a`, `97a2489b`, `89a0e235`, …) — external codex install no longer primary; (2) Codex app-server lifecycle hardening (bounded liveness/control, spawn-failure classification); (3) CodeMap perf/architecture overhaul (Tree-sitter upgrade, Dart removed); (4) **Context Builder & MCP reliability: routing/settlement/cancellation/selection-handoff race fixes, bounded MCP cleanup** — territory adjacent to upstream issue 457, needs code-level check; (5) releases v1.0.29/v1.0.30/v1.1.0 + release tooling hardening.

### C. Tip release channel (explore agent, gh + upstream/main code, 2026-07-24)
- **"Tip Builds"** = opt-in rolling channel: signed + notarized builds of the latest `main` commit that passed CI. Introduced by **upstream PR 442** (merged 2026-07-10); follow-ups: upstream PR 467 (build-number fix), upstream PR 497 (fail-closed unsigned appcasts), upstream PR 537 (distinct Tip update UI), upstream PR 555/upstream issue 547 (restore Sentry in Tip builds), upstream PR 571 (authenticated release lookup).
- **App config**: Settings → General → **Updates** tab → Software Updates → **Update Channel** segmented picker (`LicenseUpdatesSettingsView.swift:46-68`). Channel enum `UpdateChannel` (`Sources/RepoPrompt/App/Sparkle/UpdateChannel.swift:4-8`), UserDefaults key `RepoPromptUpdateChannel`, values `stable`|`tip`, default **Stable**. Switching resets Sparkle update cycle (`SparkleUpdateManager.swift:598-613`).
- **Publish flow**: `.github/workflows/main-tip.yml` ("Publish Tip") triggers on successful **CI** completion on `main` (merge → CI green → tip build; not merge → build directly). Stages: secret-free staging → Developer ID signing + notarization + Sparkle EdDSA signing (env `tip-release`) → packaged smoke → publish via `Scripts/main_tip_release.sh`.
- **Destination**: separate repo `repoprompt/repoprompt-ce-tip-updates`; tag `tip-<12-char-sha>`; assets zip/dmg/appcast.xml/SHA256SUMS/manifests. Version scheme `<stable-build>.<commits/100>.<commits%100>` (e.g. `28.7.95`) so tip sorts between stable builds.
- **Feeds** (`docs/releasing.md:162-167`): stable `…/repoprompt-ce-updates/releases/latest/download/appcast.xml`; tip `…/repoprompt-ce-tip-updates/releases/latest/download/appcast.xml`. Both validated against the CE Sparkle signing key; unsigned tip appcasts fail closed.
- Cadence evidence: first tip `tip-3f11c3ac0125` (2026-07-10); latest `tip-81e9e06b548b` (**2026-07-24**, today) — actively publishing.

## Investigator Findings

Pair phase skipped: Phase 1.5 external research + context-builder oracle pass answered both questions; the oracle's verdict was then verified directly against `upstream/main` file contents (below). No disjoint hypothesis remained.

### Oracle verdict (over upstream PR 472 preimages + upstream PR 520 per-file diffs)
Upstream `main` (`cebd7e64`) still contains both halves of the upstream issue 457 wedge; upstream PR 472 remains necessary:
1. **Inner tail unbounded**: pre-upstream PR 472 `enqueueSelectionMirror` awaits the internal mirror task's `.value`, each task awaits the previous tail's `.value`, no timeout, request cancellation doesn't release the internal tail. One parked `applySelectionMirrorAttempt` head-of-line blocks every successor; `manage_selection` then dies at the 30s MCP contract, window-wide.
2. **Outer waiters unreleasable**: mirror waiters carry no originating `ContextKey`, `invalidate(context:)` can't cancel them, workers have no task handle/generation, a parked invalidated worker occupies the tab's mirror lane and blocks replacement contexts.
3. **Upstream PR 520 doesn't supersede**: it bounds the `WorkspaceFileContextStore` filesystem-ingress wait, but that wait sits *after* the auto-selection mirror drain in `MCPSelectionToolProvider.executeManageSelectionAttempt` — a blocked mirror tail wedges before upstream PR 520's timeout is ever reached.

## Investigation Log

### Verification — upstream/main code inspection (orchestrator, `git show`/`git diff`, 2026-07-24)
**Hypothesis:** oracle claims could be preimage-based artifacts rather than true upstream state.
**Findings:** confirmed against `upstream/main` blobs directly.
**Evidence:**
- `git show upstream/main:Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift` — `enqueueSelectionMirror` (line 614) still `await predecessor?.value` (624/666) + `await task.value` (655), **no** `MCPSelectionMirrorWaitSignal` / `mcpSelectionMirrorTimeout` anywhere in the file. Patched working tree has both (lines 162-210, 10s default).
- `git diff upstream/main -- .../MCPReadFileAutoSelectionCoordinator.swift` = +68/−20: upstream `SequenceWaiter` lacks `contextKey`; no `cancelMirrorWaiters(for:)` on invalidate; `mirrorWorkers` is a bare `Set<TabMirrorKey>` with no task handle; no worker-generation ownership guard on lane advancement.
**Conclusion:** Confirmed — both upstream PR 472 mechanisms absent upstream; upstream issue 457 wedge reproducible by design on upstream/main, stable v1.1.0, and current tip builds.

## Root Cause / Answers

**Q1 — Can the local build be dropped?** Not without re-accepting upstream issue 457. The delta is now exactly one patch: `release/mp-patches-2026-07-20` carries only `6fa4cde7` + `23e31e27` (the upstream PR 472 fix) beyond upstream; upstream PR 568 merged 2026-07-22 (`6834a541`). The build branch is 109 commits behind upstream/main, so staying on it also means missing the bundled-Codex-runtime work, app-server lifecycle hardening, CodeMap perf overhaul, and MCP-reliability fixes.

**Q2 — Tip release**: see Background section C for the full mechanism (channel enum `UpdateChannel`, UserDefaults key `RepoPromptUpdateChannel`, Settings → General → Updates picker, `.github/workflows/main-tip.yml` publish-on-green-CI, feed `repoprompt-ce-tip-updates/releases/latest/download/appcast.xml`, tags `tip-<sha>`). Actively publishing (latest tip dated 2026-07-24). Note: tip builds are official signed/notarized builds — but they do NOT contain upstream PR 472 either.

## Recommendations
1. **Rebase upstream PR 472 onto current upstream/main and push** — it is `CONFLICTING`/`DIRTY` (untouched since 2026-07-11; conflicts most likely from upstream PR 520's `WorkspaceSelectionCoordinator`/`WorkspaceFileContextStore` changes and 109 commits of drift). Getting it merged is the exit ramp from local builds entirely. After rebase, revalidate the five upstream PR 472 contract tests (`testMCPMirrorTimeoutBoundsUncooperativeTailAndRepairsLatestSelection`, `testMCPMirrorTimeoutRepairsCanonicalSelectionAfterCancelledApplyReturns`, `testNewMCPMirrorCancelsSupersededApply`, `testInvalidationCancelsParkedMirrorWaiterAndReclaimsWorker`, `testReplacementContextMirroredDrainCompletesWhileInvalidatedWorkerIsParked`).
2. **Once upstream PR 472 merges: switch to the official app on the Tip channel** and retire the local build + `release/mp-patches-*` maintenance. Until then, either keep the local build (needs a fresh sync — it's 109 commits behind) or switch early and accept the wedge risk.
3. Migration mechanics (investigated 2026-07-24, follow-up explores into dotfiles + codebase):
   - Official app **already installed** at `/Applications/RepoPrompt CE.app` by the owner's machine configuration. No change to it was needed. Release MCP launcher already exists: `~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli` → official app binary.
   - **Shared** between debug/official (file-backed, same App Support root): workspaces, chat/session history, `Settings/globalSettings.json`, window sessions. **Not shared**: `UserDefaults` (bundle IDs differ: `com.pvncher.repoprompt.ce.debug` vs `.ce`) — update channel, onboarding markers, last-used model reset to defaults; and **API keys** (debug ephemeral / separate keychain domain `….debug.keychain` vs `….developer-id.keychain.v2`) — must re-enter.
   - MCP rewiring: the toolkit's strict MCP config (used by `clm`) points at `repoprompt_ce_cli_debug`; change to `…/repoprompt_ce_cli`. Also the debug entries in `~/.claude.json`. Release PATH CLI: `rpce-cli` (Settings → MCP Server → CLI Tools).
   - Coexistence: separate sockets (`repoprompt-ce-D-7.sock` vs `repoprompt-ce-7.sock`), but shared workspace files — don't run both apps concurrently.
   - Watch: if darwin-rebuild's homebrew activation upgrades casks, a rebuild may overwrite a Sparkle-updated tip build with latest stable; Sparkle re-offers the tip update afterward (self-healing).

## Preventive Measures
- Patch ledger in the personal toolkit's RepoPrompt CE notes updated this session: upstream PR 568 row dropped to merged history (verified via merge commit, not assumption); upstream PR 472 row annotated with the conflict state.
- The tip channel makes "stay current without rebuilding" viable long-term; the remaining discipline is keeping the ledger at zero open rows.
