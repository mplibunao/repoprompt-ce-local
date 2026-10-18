# Investigation: RepoPrompt CE agents no longer enforce work-repository guardrails

> Investigation report, observed 2026-07-28 on the RepoPrompt CE 1.1.0 Tip build. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary
RepoPrompt CE's bundled-Codex change (upstream PR 612, 2026-07-23) moved the Codex runtime to an app-private `CODEX_HOME`. Codex 0.145.0 only runs repo-level PreToolUse hooks when the effective CODEX_HOME carries per-hook `[hooks.state]` `trusted_hash` approval entries, and silently fails OPEN without them. MP's approvals live in `~/.codex/config.toml` and were never migrated, so a private work repository's command guardrails are silently disabled in every RP Agent Mode session. Confirmed via six-probe differential bisection with minimal repro of both failure and fix.

## Symptoms
- The work repository blocks destructive commands through a repository-level Codex PreToolUse hook.
- Previously, RepoPrompt CE Agent Mode (Codex-backed) sessions in the work repository had these guardrails active.
- Agents now report the guardrails are NOT functioning in RepoPrompt-created agent sessions.
- Timing coincides with RepoPrompt CE (and the Tip builds channel) bundling/vendoring the Codex app server into the app bundle instead of using the system-installed codex-cli.

## Environment / Known Facts
- MP runs the official RepoPrompt CE app on the Tip update channel (no local builds since 2026-07-24).
- Local checkout `main` fast-forwarded to `upstream/main` @ `30549a11` on 2026-07-28 (this investigation).
- Upstream recently landed vendored Codex: `Vendor/Codex/manifest.json`, `Scripts/codex_runtime_artifact.py`, `Scripts/codex_vendor_guardrails.sh`, `AppBundle/CodexV8JIT.entitlements` ("Fix bundled Codex JIT entitlements (upstream PR 647)").
- The work repository is the known environment-sensitive repository, with repository-level Codex hooks at its root.

## Hypotheses
1. The bundled Codex app server binary/runtime differs in version or behavior from the system codex-cli, and no longer loads repo-level `.codex` hooks / guardrail config (dropped feature, changed discovery, or changed defaults).
2. The bundled runtime launches with a different environment (PATH, cwd, config home) so PATH shims or wrapper scripts that intercepted guarded commands are no longer on PATH inside agent shells.
3. RP's app-server launch code changed which config directories are passed/honored (e.g., CODEX_HOME or project config discovery) when switching to the bundled runtime.

## Background / Prior Research
<!-- Phase 1.5 explore agent findings land here -->

### Local machine evidence (orchestrator, 2026-07-28)
- Installed app: `/Applications/RepoPrompt CE.app`, version 1.1.0, build 31.12.0 (Tip channel).
- Bundled runtime: `Contents/Resources/BundledRuntimes/Codex/<arch>/` with `bin/codex`, `bin/codex-code-mode-host`, `codex-resources/zsh`, `codex-path/rg`, `codex-package.json` (layoutVersion 1, entrypoint bin/codex, pathDir codex-path).
- **Bundled codex version: `codex-cli 0.145.0` — IDENTICAL to system codex (0.145.0).**
- Implication: version drift is ruled out. Regression vector must be launch-time differences: environment (PATH shims), config discovery (CODEX_HOME / repo-root trust), cwd, or sandbox/exec policy flags passed by RP to the bundled app-server.
- `~/.codex/config.toml` marks the work repository trusted.

### Explore agent: git archaeology (2026-07-28)
- Vendoring introduced `4fd888ed` (2026-07-22, "Bundle pinned Codex runtime artifact"), merged `d9af842f` 2026-07-23 via upstream PR 605. Bundled runtime staged into `RepoPrompt.app/Contents/Resources/BundledRuntimes/Codex/<target>/` (`Scripts/package_app.sh:306-312`).
- **Bundled runtime made authoritative** `f6ab144a` + hardening `6d1c50af`, merged `49aad5b7` 2026-07-23 via upstream PR 612.
- Resolution order (`CodexRuntimeAuthority.swift`):
  1. Explicit override `REPOPROMPT_CODEX_EXECUTABLE` (lines 179-190); must be absolute, executable, version >= bundled (269-307); invalid override **fails closed** (no fallback).
  2. Bundled runtime per-arch (192-258), returns bundled `bin/codex` (260-267).
  3. **No PATH fallback** (contract at lines 5-11); `additionalPathHints` deliberately ignored (`CodexProviderHelpers.swift:63-74`).
- Env + executable resolved once at app-server start: `CodexAppServerClient.swift:454-493`; launched with `app-server` arg at 1380-1402.
- Bundled version updated to 0.145.0 in `3b8d3165` (upstream PR 635); JIT entitlements fix `2eb8b38a` (upstream PR 647).
- **No GUI setting to prefer system codex** — only the env override; settings UI only warns about invalid overrides (`CLIProvidersSettingsView.swift:1599-1603`).
- Timing fits regression: MP moved to Tip channel 2026-07-24, immediately after bundling became authoritative upstream.

### Explore agent: work-repository guardrails mechanism (2026-07-28)
The work repository blocks destructive commands through a repository-level Codex PreToolUse hook. A nonzero hook exit denies the command.

What the RepoPrompt finding depends on:
- **The Codex runtime must discover and honor the repository-level PreToolUse hooks** for the session's project root.
- **Multi-root caveat**: the hooks bind only when the work repository is the first workspace root or the bound worktree; sessions where it is a secondary root don't run them.
- The hooks and their policy predate the regression and didn't change during it.

Safe probe: a harmless command that the guardrails deny when the hook runs, and that does nothing when it doesn't, makes a zero-risk canary.

## Investigator Findings

Pair phase intentionally skipped: Phase 1.5 research plus live differential probes (below) resolved the root cause empirically; a code-reading pair would have added nothing beyond the context builder's source analysis.

### Live differential probes (orchestrator, 2026-07-28)

All probes ask the agent to run the canary: a harmless command that the work repository's guardrails DENY when the hook runs.

| # | Surface | CODEX_HOME | Result |
|---|---------|------------|--------|
| 1 | RP CE Agent Mode explore session (bundled codex, work repository first root) | RP private: `~/Library/Application Support/RepoPrompt CE/Codex/Release/home` | **EXECUTED — hooks dead** |
| 2 | Terminal `codex exec` in the work repository (system codex 0.145.0) | default `~/.codex` | **BLOCKED** by PreToolUse hook |
| 3 | Terminal `codex exec`, same repo | RP private home | **EXECUTED — hooks dead** |
| 4 | Terminal `codex exec`, same repo | scratch home: auth + work-repository trust entry only | **EXECUTED — hooks dead** (trust alone insufficient) |
| 5 | Terminal `codex exec`, same repo | scratch home: auth + trust + copied `[hooks.state]` trusted_hash entries | **BLOCKED** — minimal repro of the fix |
| 6 | Terminal `codex exec` from a Codex worktree checkout of the work repository | same as row 5 | **BLOCKED** — hook approval resolves through the main repo; no per-worktree approval needed |

Probe 1 also captured the RP session child environment:
- `CODEX_HOME=~/Library/Application Support/RepoPrompt CE/Codex/Release/home`
- `CODEX_SQLITE_HOME=.../Codex/Release/sqlite`, `CODEX_SANDBOX=seatbelt`, `CODEX_CI=1`
- `HOME=~` intact, along with the rest of the environment the guardrails need.

### The gating mechanism: codex `[hooks.state]` approval hashes

Codex 0.145.0 runs repo-level `.codex/config.toml` hooks only when the effective CODEX_HOME's `config.toml` records a per-hook approval hash. The user's `~/.codex/config.toml` holds one such entry per repository PreToolUse hook:

```toml
[hooks.state."<absolute path to the work repository>/.codex/config.toml:pre_tool_use:<n>:0"]
trusted_hash = "sha256:<hash>"
```

These were recorded when MP approved the hooks in a terminal codex session. Without a matching entry, codex **silently skips the hook (fails open)** — no prompt, no warning, in both `codex exec` and app-server sessions.

RP's private home config (`.../Codex/Release/home/config.toml`) contains project trust entries (including the work repository) and CE-provisioned MCP/code-mode settings, but **no `[hooks.state]` section** — hence probe 1/3 fail-open.

### CE-side source evidence (context builder + spot checks)
- `CodexRuntimeAuthority.StatePaths.environment` (`CodexRuntimeAuthority.swift:22-27`) unconditionally injects the isolated `CODEX_HOME`/`CODEX_SQLITE_HOME`; applies to bundled runtime AND `REPOPROMPT_CODEX_EXECUTABLE` overrides — so pointing RP at the system binary would NOT restore hook state.
- `CodexAppServerClient.prepareRuntimeForLaunch()` (~430-565) merges these overrides into a login-shell-derived child env before spawning `codex ... app-server`.
- `CodexIntegrationConfiguration` writes only CE-owned keys (RepoPromptCE MCP server, tool_output_token_limit, code_mode) into the isolated config; it preserves unrelated TOML already present but migrates nothing from `~/.codex` (no projects trust, no hooks.state).
- Introduced in `f6ab144a` ("feat: make bundled Codex the runtime authority", merged 2026-07-23 via upstream PR 612): the same commit switched executable authority AND `configDirectoryURL()` from `~/.codex` to the app-private home. `git log -S CODEX_HOME` shows no earlier occurrence.
- App-server request contract (`Scripts/Fixtures/codex-app-server-contract.json`) has no parameter for project config, trust, or hooks — CE relies wholly on codex-side implicit discovery from the effective CODEX_HOME.

## Investigation Log

### Phase 1 - Initial assessment
**Hypothesis:** Bundled Codex runtime is the regression vector.
**Findings:** Upstream sync 664252eb..30549a11 (17 commits) includes bundled-Codex maintenance commits; vendoring infrastructure exists (Vendor/Codex, codex_runtime_artifact.py). Local `main` fast-forwarded to `upstream/main` @ `30549a11` (user request).
**Conclusion:** Needs archaeology on when bundling landed and how binary resolution changed.

### Phase 1.5 - External fact gathering (2 explore agents + local checks)
**Findings:** See Background section. Bundled == system codex 0.145.0 (version drift eliminated); bundling authoritative since upstream PR 612 (2026-07-23); guardrails = a repository-level Codex PreToolUse hook.

### Phase 2 - Context builder
**Findings:** CE-side proof that `f6ab144a` introduced both runtime authority AND CODEX_HOME isolation in one change; CE migrates no user config; app-server protocol carries no trust/hook params. Ranked isolated-CODEX_HOME-hides-trust as top hypothesis (partially right — the hidden state turned out to be hooks.state approvals, not project trust).

### Phase 3/4 - Live differential probes (pair skipped)
**Hypothesis:** Something in the private CODEX_HOME content gates hook loading.
**Findings:** Six-probe bisection (see Investigator Findings) isolated `[hooks.state]` trusted_hash entries as the sole gating variable; trust alone insufficient; worktrees inherit main-repo approval.
**Conclusion:** Root cause CONFIRMED with minimal repro.

## Root Cause

RepoPrompt CE's bundled-Codex transition (upstream PR 612, `f6ab144a`, 2026-07-23) redirected the Codex runtime's `CODEX_HOME` from `~/.codex` to an app-private directory (`~/Library/Application Support/RepoPrompt CE/Codex/<Build>/home`). Codex 0.145.0 gates repo-level `.codex/config.toml` PreToolUse hooks on per-hook `[hooks.state]` `trusted_hash` approval entries stored in the effective CODEX_HOME's config.toml, and **silently skips (fails open) any hook without a matching approval**. MP's hook approvals live in `~/.codex/config.toml`; CE neither migrates them into the private home nor surfaces any approval flow. Every RP Agent Mode session since the Tip-channel switch (2026-07-24) therefore runs work-repository commands with guardrail hooks silently disabled.

Confirmed by minimal reproduction: adding the work repository's `[hooks.state]` entries to an otherwise equivalent CODEX_HOME flips the probe from fail-open to BLOCKED (probes 4 vs 5); worktree checkouts inherit main-repo approval (probe 6).

## Eliminated hypotheses
- **Codex version drift**: bundled and system are both 0.145.0; terminal probe with default home blocks correctly (probe 2).
- **Project trust missing in private home**: private config trusts the work repository; trust-only scratch home still fails open (probe 4).
- **A broken guardrail install**: probe 1's environment was intact, and the same guardrails blocked the canary wherever the hook was approved (probes 2, 5, and 6).
- **PATH interception loss**: the guardrails run from the hook, not from PATH shims.
- **Daemon mode / upstream issue 554 recurrence**: CE spawns plain `app-server` per session; upstream issue 554 failed closed (start failure), not open.
- **`REPOPROMPT_CODEX_EXECUTABLE` as a fix**: external overrides receive the same isolated state paths (`CodexRuntimeAuthority.swift`).
- **code_mode suppressing hooks**: superseded — probe 5 blocks with no code_mode change; the gating variable is hooks.state alone.

## Recommendations

### 1. Immediate mitigation (user-side, no code) — needs MP go because it touches the live app home
1. Quiesce RP Agent Mode (no running Codex sessions; ideally quit RepoPrompt CE).
2. Back up `~/Library/Application Support/RepoPrompt CE/Codex/Release/home/config.toml`.
3. **Upsert (never blind-append)** ALL `[hooks.state]` tables for the work repository from `~/.codex/config.toml` into the private config. Validate no duplicate table headers.
4. Relaunch RepoPrompt CE, start a fresh correctly-rooted session (work repository as first root or primary bound worktree).
5. Verify: the canary must be BLOCKED in an RP agent session.
- Debug home (`.../Codex/Debug/home`) needs the same treatment if local builds resume.
- `REPOPROMPT_CODEX_EXECUTABLE` is NOT a fix (same isolated home). Do not copy SQLite state or the whole user config.

### 2. Keep it from silently regressing
- Small sync script in the personal toolkit that upserts hook-approval entries for an explicit repo allowlist from `~/.codex/config.toml` into the RP private home(s), fail-closed on missing/malformed source entries. Re-run + re-probe after: hook definition changes (hash drift!), codex upgrades, RP updates, repo relocation/reclone, Debug/Release switch.
- Re-run the canary in an RP session after each of those changes: approval entries alone don't prove the hook runs.

### 3. Upstream (repoprompt/repoprompt-ce)
**FILED 2026-07-28: upstream issue 665** (bug, area:agent-mode, provider:codex); a local implementation plan was written, ticket-first — awaiting maintainer signal. Original framing: CODEX_HOME isolation silently drops user hook approvals → security-critical PreToolUse hooks fail OPEN in Agent Mode with no warning.

**Protocol evidence (checked 2026-07-28 against installed codex 0.145.0 `app-server generate-json-schema`):** the v2 app-server protocol already exposes everything needed, client-side only:
- `hooks/list` (params: `cwds`, defaults to session cwd) returns per-hook `HookMetadata`: `eventName`, `source` (`user`/`project`/`system`/...), `sourcePath`, `key`, `currentHash`, `enabled`, and **`trustStatus`: `managed` | `untrusted` | `trusted` | `modified`**. Codex computes hash + staleness itself — no client-side hash reimplementation needed; `modified` = stale approval.
- `hook/started` / `hook/completed` notifications during turns (positive attestation that a hook actually ran).
- **No trust-mutation method exists** — approval recording stays a config write (`[hooks.state."<key>"] trusted_hash`), which the client can perform in its own CODEX_HOME using `key` + `currentHash` from `hooks/list`.

Proposed fix (DECIDED 2026-07-28: MP rejected warn-only/visibility-only preflight as a non-fix; the proposal is the approval flow or nothing):
- **Hook approval flow in Agent Mode**: after thread start, call `hooks/list`; on hooks with `trustStatus` `untrusted`/`modified`, offer an approval interaction (repo, hook command, hash); on approval CE writes the `[hooks.state]` entry into its private home using codex-reported `key`/`currentHash`, then restarts/refreshes the session so hooks are active. Implementable without codex-side changes. Requires adding `hooks/list` to the declared contract fixture.
- Auto-seeding from `~/.codex` only as an opt-in, repo-scoped bridge — not wholesale config copying.

**Scope caveat — user-level (global) hooks**: `HookSource` includes `user`, i.e. hooks declared in the CODEX_HOME's own config.toml. Under CE's private home, the user's `~/.codex/config.toml` is never read, so user-global hooks are not "untrusted" — they are **invisible**; `hooks/list` cannot warn about them. That gap is part of the broader "isolated home severs user codex config" story and belongs in the upstream issue narrative (fixable only by import/migration UX, not by detection).

## Preventive Measures
- Any future CODEX_HOME/state isolation change in CE must be checked against security-relevant user state (hooks.state, trust) — add to the fork's upstream-sync drift watch.
- After codex-cli upgrades, re-run the guardrail canary in an RP session (hook gating semantics are codex-side and can change).
- Hook-state approval keys embed absolute paths of the main checkout's `.codex/config.toml`; worktrees inherit (verified on 0.145.0) but reclones/moves do not.
