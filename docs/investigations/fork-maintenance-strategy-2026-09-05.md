# Investigation: RepoPrompt CE fork maintenance strategy

> Investigation report, observed 2026-09-05. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [AGENTS.md](../../AGENTS.md), Branch model.

## Summary
A durable personal RepoPrompt CE distribution is feasible, but only as a **Tip-aligned release train**. Each refresh rebuilds a disposable release candidate from a soaked upstream baseline and carries a short, authority-bounded patch stack. Promotion happens only after a packaged acceptance matrix passes from both Claude Code and Codex. The promoted build is installed as the single `/Applications` app, with an app-plus-state archive for rollback.

The other options score worse on the evidence. The protected workflows are vertical slices through one Swift target, and upstream's hottest files are exactly where MP's patches live. Upstream never reverts; it rolls forward. No test in the 4,779-method suite drives the packaged app through a real provider. Cherry-picking individual commits, importing feature folders, monthly bulk merges, and freezing on `v1.4.0` each fail on one of those facts.

Run the train as a three-refresh trial with measurable exit criteria. Don't create a divergent product identity unless a real downstream product need appears.

## Task (from MP)
Assess six strategies for maintaining a stable personal RepoPrompt CE distribution:
1. Track upstream closely; short-lived stability stack of unmerged fixes (current posture).
2. Long-lived downstream fork, periodically merging all upstream.
3. Downstream fork cherry-picking individual upstream commits/PRs.
4. Downstream product line importing selected features by manual adaptation (no upstream ancestry).
5. Freeze on known-good release; accept only security/critical fixes and explicitly desired features.
6. Better hybrid.

Deliverables: executive recommendation; strategy comparison table; branch/release model; upstream-absorption process; principal risks; staged adoption plan; exit criteria.

## Interview outcomes (2026-09-05)
- Primary decision: **long-term fork viability**, not this month's firefighting.
- Upstream trajectory: unknown. Project recently went closed-source paid -> open-source; upstream focus is stability + restoring existing features. Big features (headless Linux server, chat) live in community forks not tracking main.
- Protected workflows (acceptance bar for any change entering the fork): (a) MCP orchestration from Claude Code **and Codex** (context_builder, ask_oracle, manage_selection, agent_run); (b) in-app Agent Mode sessions; (c) multi-root workspaces + worktrees. Debug build/CLI tooling is a *consequence* of maintaining, not an input.
- Public forks in scope: Fork B below (branch `sandbox`, `docs/server/getting-started.md` — headless/server) and Fork A below (many PRs, appears to stay updated).
- Signing: MP has no Apple Developer account. Debug builds use ad-hoc signing + in-memory secure storage, so settings/secrets reset across relaunches (observed). MP is open to a paid developer account if it materially improves a personal-distribution workflow.

## Symptoms (MP's characterization — to be verified, not accepted)
- Repeated regressions across Context Builder, Agent Mode, workspace/worktree routing, process cleanup, cancellation, file operations, concurrency.
- Heavy investment: reproducing/fixing defects, maintaining several upstream PRs, deterministic tests, dog-fooding packaged debug builds, fork-only diagnostics branch, rebuilding a local stability stack, ledger provenance.
- Hypothesis: app is hard to stabilize because it combines macOS lifecycle, Swift concurrency, external provider processes, MCP, multi-window/workspace, worktrees, FS ops, caching/hashing/persistence, cancellation-sensitive async; documentation/ownership may be insufficient for the behavioral surface.

### Observed during this session
- 2026-09-05: RP MCP `read_file`/`get_file_tree` in the orchestrator window returned `tool_execution_structure_settlement_busy: Window 1 reached its limit of one released cancellation-ignoring structure provider` three times in a row; `file_actions create` then hit the 30 s watchdog and was detached without creating the file. Native shell reads/writes were used as fallback. Consistent with the ledger's "structure-settlement" blocker family.

## Background / Prior Research
<!-- Phase 1.5 explore-agent findings: git archaeology, ledger digest, external forks, signing/packaging. -->

### Ledger and prior-investigation digest

Sources: the personal toolkit's RepoPrompt CE notes (371 lines, full read), their two checksummed archives (skimmed — same section skeleton, superseded chronology only), and `docs/investigations/{mp-patches-vs-latest-release-2026-07-15, upstream-sync-mp-patches-2026-07-20, pr-472-upstream-parity-and-tip-release-2026-07-24, tip-updates-not-appearing-2026-07-25, structure-settlement-velocity-bottleneck-2026-09-03, read-file-worktree-timeout-settlement-2026-08-29}.md`.

#### 1. Patch inventory (from the personal toolkit's local patch ledger)

| Patch / defect | Local branch | Upstream PR | Status | Subsystem |
| --- | --- | --- | --- | --- |
| Selection-mirror wedge recovery (upstream issue 457) | `bugfix/pr472-selection-mirror-recovery` | **Upstream PR 472** | OPEN upstream since 2026-07-11; local successor `5dce1ef7` gated but unpushed | Workspace/MCP selection (`WorkspaceSelectionCoordinator`, `MCPReadFileAutoSelectionCoordinator`) |
| Qualified multi-root `read_file` stall (upstream issue 887) | `bugfix/889-display-alias-followup-redo` | **Upstream PR 889** | OPEN upstream; corrected head `10217034` delivered; blocked on CI infra + maintainer | File ops / FS watcher / `WorkspaceFileContextStore` |
| Large prompt/workspace export watchdog (upstream issue 881) | `bugfix/881-large-export-watchdog` | **Upstream PR 898** | OPEN upstream; head `e058ee28`, all checks green | MCP server/transport (`InteractiveMCPClientSession`, `UnixSocketMCPTransport`) |
| Concurrent same-workspace Agent admission (upstream issue 882) | `bugfix/882-same-workspace-admission` | **Upstream PR 897** | OPEN upstream, `CHANGES_REQUESTED`; +2478/-80 remediation uncommitted | Agent Mode admission + domain persistence/recovery journal |
| Context Builder Claude-provider app-termination teardown (upstream issue 954) | `bugfix/context-builder-graceful-shutdown` | **Upstream PR 955** | OPEN upstream, 9 checks green, **packaged acceptance FAILED** | Agent Mode providers + process lifecycle (`WindowStateManager`, `AppDelegate` SIGTERM route) |
| Context Builder selection-construction watchdog (upstream issue 918) | `bugfix/918-context-builder-selection-watchdog` | **Upstream PR 957** | OPEN upstream, ready for review, 9 checks green | Context Builder / MCP selection |
| Cancellable physical reads (upstream issue 949) | `bugfix/949-cancellable-physical-reads` | none yet | Fork-local; green VERIFY, REVIEW/REFACTOR blocked by runtime | File ops / caching / shared read limiter |
| MCP phase-attribution diagnostics | `feature/local-rp-diagnostics` (`51ef0fa4`) | **none — fork-only, never to be PR'd** | Fork-delivered to `origin` | Diagnostics / MCP instrumentation |

- Merged upstream and dropped: upstream issue 900→upstream PR 904 (2026-08-29 squash `834b43e0`), upstream issue 554→upstream PR 568 fix (2026-07-22 merge `6834a541`), upstream PR 450 Codex text payload key + upstream PR 532 fail-closed child MCP provisioning (v1.1.0, 2026-07-21), upstream PR 529 (2026-07-13). Upstream issue 916 closed `NOT_PLANNED`; upstream issue 921 handed to a maintainer; upstream issue 830 retired after upstream PR 956 shipped a workaround.
- OBSERVED historical churn: of the original five `release/mp-patches` commits, upstream absorbed two (MP's own upstream PR 450; upstream PR 517 solved the retry-backoff crash *differently*) and reworked one test-only patch — leaving only the two upstream PR 472 selection commits as genuine local value (`upstream-sync-mp-patches-2026-07-20.md:4,89`).
- INFERRED: eight of eight ever-open rows touch either MCP tool execution, Context Builder, or process/provider lifecycle. No patch is cosmetic; all are liveness/cancellation defects in workflows MP depends on.

#### 2. Sync / stability-stack rebuilds

- OBSERVED — at least **six** distinguishable rebuilds: `release/mp-patches` (pre-07-15) → `release/mp-patches-2026-07-20` from `feb0ac92` → 07-22 emergency re-merge of upstream PR 568 (`bbe19ad2`) → `feature/local-rp-stability-stack` `afb9096e` (2026-09-03) → `682f392b` adding final upstream PR 889 → disposable `feature/local-rp-stability-rc-20260905` `1ba6b0a6`.
- OBSERVED timings: the ledger records **no per-rebuild wall clock**. Proxy data points are conductor tickets: exact-commit debug package **2m32s**, release-artifact validation **21 min**, a hung focused test ticket canceled at **9m03s**, test runs canceled at **8m55s** and **11m37s**. INFERRED: the mechanical rebuild is minutes; the cost sits in the gate chain around it, not the merge.
- OBSERVED breakage during rebases/rebuilds:
  - **Dropped patch → total perceived outage.** The 07-20 rebuild omitted upstream PR 568; on 07-22 every worktree-bound Codex agent failed. Session-store archaeology showed the failure had been continuous since 07-15, not sudden.
  - **Cherry-pick conflicts were trivial** — the only conflict was `Scripts/Fixtures/test-suite-contract-ledger.tsv`, resolved as a union (`upstream-sync-mp-patches-2026-07-20.md:78`).
  - **Semantic conflicts are the real cost.** The 2026-09-05 RC had to *exclude* the validated upstream PR 472/upstream issues 881 and 882 predecessors because they resurrect upstream-deleted tests or modify replaced authorities.
  - **Upstream deletes the coverage MP relies on.** Upstream PR 908 removed the focused registry/watchdog suite that upstream PR 822 added, leaving the production implementations unchanged (`structure-settlement…:21`); upstream PR 908 also removed the lifecycle suite relevant to upstream issue 954.
  - **Inherited upstream debt:** `verify-ledger` reported `missing=10 stale=1` on pristine upstream `feb0ac92` — pre-existing, left for upstream.

#### 3. Defect families and reproduction status

- **Structure-settlement / released-provider fence** — *reproduced deterministically, live, from a clean post-reboot baseline*; two qualified `read_file` calls escape cancellation, then every structure call is fenced. Root cause: `MCPDomainCodeStructureSettlementRegistry` (limit of one released cancellation-ignoring provider) + `MCPDomainToolExecutionWatchdog`. Hit again during this digest run.
- **`read_file.content_read` worktree stall (upstream issue 887/upstream PR 889, then upstream issue 949)** — *reproduced live repeatedly*; 12.6 KB file, 30 s+ via a session-bound worktree vs 0.00 s at the OS. Deterministic red test exists at the physical-read seam; the uninterruptible synchronous read outside the shared limiter is the identified production seam (`read-file-worktree-timeout-settlement…:6–22,148–175`).
- **`get_file_tree` provider timeout (upstream issue 949)** — *reproduced live on a clean package containing final upstream PR 889*, so not an upstream PR 889 regression; the exact blocked handler phase is **unresolved** because the app wrote phase traces to a `/dev/null` stderr (`structure-settlement…:180,209`).
- **Claude provider teardown on app quit (upstream issue 954)** — *reproduced deterministically via a controlled six-arm matrix*: Claude explicit-cancel and normal-completion pass; Claude app-quit leaves provider reparented to PID 1 with MCP child and immutable lease; all three Codex arms pass. Root cause: `WindowStateManager` shutdown snapshot, `ClaudeCodeAgentProvider.dispose()` stream-cleanup join, and a missing SIGTERM→`applicationShouldTerminate` route.
- **Selection-mirror wedge (upstream issue 457/upstream PR 472)** — *root cause confirmed by direct upstream blob inspection*, not just tests: unbounded predecessor chain in `enqueueSelectionMirror`, waiters carrying no `ContextKey` (`pr-472-upstream-parity…:48–61`). Five contract tests exist.
- **Concurrent same-workspace Agent admission (upstream issue 882)** — *deterministic red/green* across restart, two-window replay, and retry-exhaustion; six REVIEW rounds surfaced further real races (deadlock, stale marker cache).
- **Export watchdog (upstream issue 881)** — *observed live*: a completed Context Builder package could not be exported through four independent routes, each closing after ~32 s.
- **Worktree/workspace projection readiness** — *hypothesized + source-localized only*; no controlled pre-ready/post-ready reproduction run yet. This is what repeatedly wedged upstream issues 882 and 949 REVIEW gates.
- **Codex hook-approval fail-open** — *observed live via canary*; CE's app-private `CODEX_HOME` silently skips repo `.codex` PreToolUse hooks. Proposed upstream as upstream issue 665.
- **Intermittent `prompt set` watchdog stall** — *2 of 3 runs*; classified a candidate, not an accepted defect.

#### 4. Effort split (ESTIMATE — INFERRED from ledger content share, not measured)

- **Process / governance overhead ≈ 40–50%.** Every fix runs personal VERIFY → mandatory Context Builder REVIEW → *separate* REFACTOR → contribution preflight → push handshake → packaged live acceptance → stability promotion. The ledger's own chronology is dominated by gate reruns: REVIEW attempts that produced no verdict (superseded, not failed) recur in upstream PR 472, upstream issues 881, 882, 949, and 954 and the goal-doc reviews; several consumed 20+ minutes each before governed cancellation.
- **Diagnostics / test scaffolding ≈ 30–35%.** A dedicated fork-only diagnostics branch exists (`feature/local-rp-diagnostics`) with its own REVIEW cycle that accepted five P1 *diagnostics* defects — work that ships zero user-facing behavior. Patch shapes are test-heavy: upstream issue 882 at +2478/-80 over 10 files, upstream issue 881 +1023/-81, upstream issue 954 +803/-35 over 6 files.
- **Behavioral fixes ≈ 20–25%.** Production deltas are small and localized (e.g. upstream PR 472 successor = 1 source file + 1 test; upstream issue 954 SIGTERM route = 1 modified + 2 new files).
- INFERRED implication for the strategy question: the marginal cost of carrying a patch is *not* the merge — it is the upstream-contribution gate chain plus the review-infrastructure fragility around it.

#### 5. Upstream maintainer responsiveness and the Tip channel

- OBSERVED named maintainers: maintainer A (reviewer — requested changes on upstream PRs 889 and 897) and another maintainer (accepted the upstream issue 921 implementation handoff himself). MP has had five PRs merged (upstream PRs 450, 529, 532, 568, and 904; upstream PR 568 fixed upstream issue 554).
- OBSERVED slow path: **Upstream PR 472 has had no human review at all** — last review was a Copilot bot on 2026-07-10; still OPEN and `CONFLICTING` as of 2026-09-05 (~8 weeks) with only a non-actionable Copilot review (`pr-472-upstream-parity…:22`).
- OBSERVED: upstream PRs 889 and 897 both sit at `CHANGES_REQUESTED` with maintainer A's reviews **now outdated** after remediation — no re-review recorded. Upstream PR 957 is green on all nine checks and "blocked only on required human review/policy".
- OBSERVED contributor-permission ceiling: the account lacks `AddLabelsToLabelable` (cannot label its own filed upstream issues 949 and 954) and lacks admin rights to rerun failed CI jobs. Upstream PR 889's hosted run had root shard 1 canceled after **55 minutes because SwiftPM cache restore alone exceeded the 45-minute job limit** — with no rerun path short of a no-op commit.
- OBSERVED Tip mechanics: opt-in rolling channel (upstream PR 442, live 2026-07-10). Merge → CI green → sign/notarize → packaged smoke → appcast published to the separate repo `repoprompt-ce-tip-updates` as `tip-<sha12>`. **A failed CI on `main` silently skips Tip publication** (verified 2026-07-25: upstream PR 613's merge failed a test shard and Style; Publish Tip run was skipped). Passive discovery polls every 12 h and surfaces as a toolbar pill/menu item — no modal — which is why "no prompt" looked like a broken updater (`tip-updates-not-appearing-2026-07-25.md:4,104–133`).
- INFERRED: Tip is a genuine "stay current without rebuilding" path, but it never contains MP's open patches, so adopting it means re-accepting whatever is still unmerged (`pr-472-upstream-parity…:71`).

#### 6. Ad-hoc signing / secure-storage limits and their effect on dogfooding

- OBSERVED: this machine has **no valid Apple Development signing identity**. The debug app is ad-hoc signed and uses **in-memory secure storage** — API keys and secure permission changes **do not survive a relaunch**.
- OBSERVED consequence: after *every* debug launch/relaunch MP must re-verify Settings → Agent Permissions by Computer Use (Direct Agents: Codex CLI = Auto Review, Claude Code = Full Access; Sub-Agents = Inherit Provider), because ad-hoc debug settings may not persist.
- OBSERVED friction: at least two conductor package tickets failed **before compilation** solely because `ALLOW_ADHOC_SIGNING=1` was not set.
- OBSERVED: Computer Use targeted by display name auto-launches `/Applications/RepoPrompt CE.app`, recreating dual-process routing over a shared App Support directory; targeting must use the full debug bundle path. Debug and production share workspaces/sessions/`globalSettings.json` but **not** UserDefaults or the keychain domain (`pr-472-upstream-parity…:73`).
- OBSERVED: release packaging requires an explicit `SIGN_IDENTITY` and real Keychain storage — i.e. a durable personal distribution with persistent secrets requires a paid signing identity.

#### 7. Written fork policy already in the ledger (relevant to the strategy question)

- The personal toolkit's upstream-refresh policy already forbids all-or-nothing rebases: it classifies each branch independently, prefers merge over rebase for published refs, and does not count being behind `main` as a defect on its own.
- Its stability-build policy treats each local stability build as a throwaway release candidate, not a merge branch that accumulates changes: build fresh from `upstream/main`, integrate only the latest clean verified commits, and record base, diagnostics, contributions, validation, and retirement in the patch ledger.
- **Ledger retention rule**: archive a byte-identical checksummed snapshot before ~15k tokens / 25 superseded blocks; never delete snapshots. Two archives exist so far; the last prune cut the hot ledger from 23,445 words / 190 KB to ~8,700 words / 68 KB.
- **Rollback condition**: once the required fixes ship in official Tip and pass live acceptance there, revert the Toolkit MCP-selector commit, restart Codex Desktop, and return to the Tip app — i.e. the current posture is *already documented as temporary*.

### Packaging, signing, secure storage, and update channel

Sources: `Scripts/package_app.sh`, `Sources/RepoPrompt/Infrastructure/Security/{RuntimeCodeSigningPolicy,SecureKeyValueStorageBackend,SecureKeyService}.swift`, `AppBundle/*.template`, `docs/releasing.md`, `.github/workflows/{release,main-tip}.yml`.

#### 1. What actually resets in an ad-hoc debug build (OBSERVED)

**Only Keychain-backed secrets reset. Settings, workspaces, presets, and chat history do not.**

- Packaging stamps two Info.plist markers — `RepoPromptSigningMode` and `RepoPromptDebugSecureStorageBackend` (`AppBundle/Info.plist.template:17-18`) — chosen at `Scripts/package_app.sh:202-223`. Marker default is `alternate-in-memory` (`package_app.sh:143`).
- Ad-hoc debug sets `SIGNING_MODE_MARKER=debug-adhoc` (`package_app.sh:222`); the runtime maps that to `.ephemeral(.adHocDebug)` (`RuntimeCodeSigningPolicy.swift:244-245`), which selects `EphemeralSecureKeyValueStore.shared` (`SecureKeyValueStorageBackend.swift:128-129`) — a backend whose `persistsValuesAcrossLaunches` is false (`SecureKeyValueStorageBackend.swift:4`).
- The trigger is the stamped marker, not a live TeamIdentifier probe. But the one debug branch that *does* reach Keychain (`debug-apple-development` + `keychain`) additionally requires a non-ad-hoc signature with `codeIdentifier == com.pvncher.repoprompt.ce.debug` **and** `teamIdentifier == 648A27MST5` (`RuntimeCodeSigningPolicy.swift:246-261`, `277-291`). MP is not on that Apple team, so that branch can never validate for him even with a paid account.
- Auto-detected debug signing is also forced ephemeral unless `SIGN_IDENTITY` is passed explicitly (`package_app.sh:168-174`, `192-195`).
- Affected data: provider API keys via `SecureKeysService` (`SecureKeyService.swift:30-38`) and agent permission grant documents via `AgentPermissionSecureStore` (`AgentPermissionSecureStore.swift:812-828`). The packaging script states this verbatim (`package_app.sh:147-149`).
- Unaffected: `~/Library/Application Support/RepoPrompt CE/…` JSON state — global settings (`GlobalSettingsFileStore.swift:48`), workspaces/events (`AppDomainRuntimeComposition.swift:57-86`), presets (`PresetFileStore.swift:11`), chat history (`ChatHistoryManager.swift:459`). Signing mode never touches these.

#### 2. Release-configuration builds by signature type (OBSERVED)

| Signature | What the repo demands | Secrets persist? |
| --- | --- | --- |
| (a) ad-hoc release | `RELEASE_ALLOW_ADHOC_SIGNING=1`, otherwise hard fail (`package_app.sh:176-182`) | **No** — `release-candidate-adhoc` → ephemeral (`RuntimeCodeSigningPolicy.swift:242-243`) |
| (b) self-signed local cert | `LOCAL_SELF_SIGNED_RELEASE=1` + `SIGN_IDENTITY` + cert SHA-1 + SHA-256 + positive generation (`package_app.sh:155-167`) | **Yes** — dedicated Keychain service keyed by cert fingerprint + generation (`SecureKeyValueStorageBackend.swift:118-126`) |
| (c) Apple Development / Developer ID | Developer ID also needs `REPOPROMPT_PROVISIONING_PROFILE` whose app-id equals `648A27MST5.com.pvncher.repoprompt.ce` (`package_app.sh:362-371`) | **Yes for upstream's team only** — a fork's own Team ID fails `matches()` (`RuntimeCodeSigningPolicy.swift:196-204`, `277-291`) |

Hardened runtime (`--options runtime`) is applied in every configuration (`package_app.sh:444-446`). Self-signed release uses a separate team-free entitlements file that adds `disable-library-validation` (`AppBundle/RepoPrompt.local-self-signed.entitlements.template`); the Developer ID template hard-codes `__SIGNING_TEAM_ID__` (`AppBundle/RepoPrompt.entitlements.template:6-9`).

**The repo already ships a supported no-Apple-account path with full Keychain persistence:** `CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production`, or the Finder launcher `Install RepoPrompt CE Local Production.command` (`docs/releasing.md:404-478`). It mints/registers a local certificate, records it in `~/Library/Application Support/RepoPrompt CE/local-signing-identity-v1.json`, and keeps the same designated requirement and Keychain service across reinstalls. Requires a full Xcode install; rotation is explicit and does not migrate prior secrets.

#### 3. Upstream release pipeline and fork feasibility (OBSERVED)

- Three lanes (`docs/releasing.md:3-10`): unsigned ad-hoc release candidate (no secrets), **Tip** builds, and stable releases. Tip = signed+notarized builds from latest passing protected `main`, published to a *separate* repo `repoprompt-ce-tip-updates` with the same EdDSA key; users opt in at Settings → Software Updates → Update Channel (`docs/releasing.md:222-251`, `UpdateChannel.swift:4-33`). Tip `CFBundleVersion` values are minted to sort between adjacent stable builds (`docs/releasing.md:278-282`).
- Signing/notarizing runs on GitHub `macos-26` runners inside protected environments `release` and `tip-release` (`release.yml:30-342`, `docs/releasing.md:301`). Required secrets: Developer ID P12 + password, CI keychain password, provisioning profile, `notarytool` App Store Connect `.p8` key + key id + issuer id, Sparkle EdDSA private key, and two scoped update-repo tokens (`docs/releasing.md:498-512`). Notarization is `xcrun notarytool submit` then `stapler staple`/`validate` on both the app and DMG (`Scripts/release.sh:597-713`).
- **A fork cannot repoint the updater by configuration.** Both feed URLs and the expected Sparkle public key are compiled-in obfuscated constants, and `validateSparkleConfiguration()` disables updates unless the running bundle's `SUPublicEDKey` and canonicalized feed URL match one of those two entries (`SparkleUpdateManager.swift:30-34`, `70-75`, `716-736`). Running a personal update train therefore requires a source change (new feed URL + new EdDSA public key), not just a plist edit.
- Concrete fork cost for a real signed/notarized personal train: Apple Developer Program $99/yr, plus Developer ID cert + provisioning profile for a fork-owned bundle id, an App Store Connect API key, a self-generated Sparkle EdDSA key pair, a separate updates repo, and a patch to the compiled feed/key constants — carried across every upstream sync.

#### 4. Coexistence with the production app (OBSERVED)

- Debug bundle id is `com.pvncher.repoprompt.ce.debug`; release is `com.pvncher.repoprompt.ce` (`package_app.sh:97`, `108-112`). Debug and production apps coexist on disk and have separate `UserDefaults` domains and separate MCP service names (`MCPServiceName.swift:50-60`).
- **They share one Application Support root.** `"RepoPrompt CE"` is hard-coded, not derived from the bundle id (`AppDomainRuntimeComposition.swift:62`, `GlobalSettingsFileStore.swift:48`, `WindowStateManager.swift:130`). Only a few stores are flavor-partitioned (`WorkspaceDurableArtifacts-<flavor>` in `DurableArtifactSecureIO.swift:220`; code-map salt in `CodeMapArtifactRuntime.swift:208`). So settings, workspaces, and chat history are shared state between MP's debug build and the installed production app.
- A **local self-signed production build reuses the production bundle id** (`RuntimeCodeSigningPolicy.swift:228-235`), so it *replaces* `/Applications/RepoPrompt CE.app` rather than sitting beside it; the installer confirms replacement (`docs/releasing.md:407-412`). Its Keychain service is distinct from the official one, so API keys would need re-entry once.

#### 5. Build time and provenance (OBSERVED / INFERRED)

- No build-duration figures are documented in `docs/releasing.md` or `docs/testing.md`. Measured from local conductor job-log lifetimes (`~/Library/Application Support/RepoPrompt CE/Conductor/*/jobs/*.log`): a cold `swift test --filter` job that compiled 258 units took **~504 s**; another heavy job **~337 s**; light coordinated jobs 12–33 s. INFERRED: budget roughly 6–10 min for a cold package, well under a minute warm.
- Every debug package writes `Contents/Resources/RepoPromptDebugProvenance.json` with repo root, worktree, branch, commit, dirty flag, and ISO build time (`package_app.sh:391-434`); conductor reads it back at `Scripts/conductor.py:150`. That is a usable rollback/identification anchor for a personal train — it records the exact commit a bundle came from. Release lanes instead emit an artifact manifest at `.build/release/RepoPrompt-artifact-manifest.json` (`package_app.sh:103`).
- INFERRED (not verified in-app): a self-signed local production app will pass Sparkle's feed/key integrity check because its Info.plist is unmodified, but Sparkle's own update installation validates that the downloaded bundle's signing identity matches the running app's, so official updates would not install over it. Treat the self-signed lane as manual-update-only until confirmed live.

### Git archaeology: upstream cadence and churn

Measured 2026-09-05 against freshly fetched `upstream/main` (`2c4b86d0`). "8w" = `--since='8 weeks ago'`.

**1. History shape.** First commit `351e9803` (2026-05-31, "Initial RepoPrompt CE snapshot", by maintainer B). 1,589 commits total (1,219 non-merge). **1,253 of them — 79% — landed in the last 12 weeks**: this is a young, extremely hot repo, not a settled codebase.

- Commits/week (ISO week, all commits): W24 89\*, W25 112, W26 73, W27 77, W28 176, W29 159, W30 170, W31 162, W32 82, W33 39, W34 19, W35 51, W36 44\* (\*partial). Peak ~170/wk mid-Jul–early Aug; last four full weeks 19–51/wk.
- Authors: 37 names / 32 distinct emails overall; 19 distinct emails in the last 8w. In each of the top two slots, two name spellings map to one email address.
- Top 5 authors, last 8w (757 commits, alias-merged): maintainer A **471**, maintainer B **125**, a frequent outside contributor 27, sentry[bot] 25, MP 25 (another contributor 24 close behind). **Two maintainers author 79% of 8w traffic** — bus factor and review capacity both concentrate there.

**2. Release cadence.** 35 upstream tags, `v1.0.0` (2026-05-31) → `v1.4.0` (2026-08-30); `v1.0.11` was never published. Cadence decayed from near-daily to roughly biweekly: gaps 0–2d through June, 1–8d in July, then 4d (`v1.2.0`), 8d (`v1.3.0`), **18d (`v1.4.0`)**. 46 commits (40 non-merge) have landed in the 6 days since `v1.4.0`, so `main` runs well ahead of the newest stable tag. Stable tags are only one of three lanes — `docs/releasing.md:6,222–298` documents rolling **Tip Builds**: signed/notarized builds cut from latest passing protected `main` onto a separate Sparkle feed (`repoprompt-ce-tip-updates`) with immutable `tip-<shortsha>` tags. For a fork, **Tip — not the tag stream — is the real upstream heartbeat.**

**3. Churn hot-spots (8w, non-merge).** Top files by number of touching commits:

| n | file | area |
|---|---|---|
| 182 | `Scripts/Fixtures/test-suite-contract-ledger.tsv` | generated test-contract ledger |
| 61 | `Scripts/test_release_tooling.py` | release tooling |
| 50 | `Sources/.../Infrastructure/MCP/MCPConnectionManager.swift` | **MCP server** |
| 46 | `Sources/.../Features/AgentMode/ViewModels/AgentModeViewModel.swift` | **Agent Mode** |
| 43 | `Sources/.../Infrastructure/MCP/ViewModels/MCPServerViewModel.swift` | **MCP + window routing** |
| 39 | `Sources/.../AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | **Agent providers** |
| 39 | `Scripts/source_layout_guardrails.sh` | guardrails |
| 33 | `docs/releasing.md` · 33 `Tests/.../MCP/ToolCatalogSnapshotTests.swift` | release · **MCP tools** |
| 30 | `Sources/.../Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift` | **workspace routing** |
| 28 | `.github/workflows/main-tip.yml` · 24 `Package.swift` | Tip CI · build |
| 25 | `Sources/.../AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` | **Agent providers** |
| 23 | `Sources/.../Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift` | **file-system/caching** |
| 22–21 | `MCPToolExecutionWatchdogIntegrationTests`, `WorkspaceSavePreparationTests`, `AgentRunWorktreeStartTests`, `CodexNativeSessionControllerGoalConfigTests`, `CodexAgentModeCoordinatorLivenessTests`, `headless_mcp_domain_runtime_m0_contract.json` | **MCP/Agent/worktree tests** |

Directories under `Sources/` by lines changed (8w): `Features/AgentMode` 39,873 · `Infrastructure/WorkspaceContext` 39,035 · `Infrastructure/MCP` 28,921 · `Features/Diagnostics` 20,178 · `Infrastructure/AI` (providers) 16,161 · `Features/Workspaces` 6,877 · `Infrastructure/SyntaxParsing` 5,303 · `Features/Settings` 4,162 (`Features/ContextBuilder` 3,075; `Infrastructure/Persistence` 1,816).

**Every category MP patches is in the top band.** Cross-checking the fork's own diffs against this churn table: `feature/local-rp-stability-stack` touches `MCPConnectionManager.swift` (50 upstream commits), `AgentModeViewModel.swift` (46), `MCPServerViewModel.swift` (43), `WorkspaceManagerViewModel.swift` (30), `WorkspaceFileContextStore.swift` (23); `feature/local-rp-diagnostics` touches the same top three. The fork is not merely near upstream's hot path — it sits on its four hottest source files. Only Context Builder (3,075 lines) and Persistence (1,816) are comparatively quiet.

**4. Regression signal (8w, 587 non-merge commits).** `fix` 229 · `regression` 12 · `follow-up` 1 · **`revert` 0 · `hotfix` 0 · `redo` 0**. Union of all keywords: 233 (40% of commits). There are **zero reverts in the entire 1,589-commit history** (`git log --format=%s upstream/main | grep -icE '\brevert'` → 0; no body contains "This reverts commit"). Upstream never backs a change out — it rolls forward with another fix, so a fork cannot detect a bad upstream commit by watching for reverts. Rework instead shows up as fix-on-fix: of 280 first-parent landings in 8w, **72 landing pairs share a file, land ≤14 days apart, and both carry fix-shaped subjects**. Densest examples: `Fix Oracle heartbeat liveness (#696)` → 4d → `require authoritative context builder completion (#72x)` (6 shared files); `Fix bundled Codex JIT entitlements (#647)` → 13d → `Bundle Codex 0.147.0 (#748)` → 8d → `expose global skills to Codex agents (#824)`; `make agent read_file selection converge (#755)` → 5d → `Unify exact read and mutation paths (#800)`; `Fix MCP read timeout settlement (#…)` → 3d → `Fix MCP settlement across Codex turns (#…)` → 1d → `Fix file-action watchdog mutation reconciliation (#688)`. The MCP-settlement and Codex-runtime chains are exactly the seams the fork patches.

**5. Merge style — mixed, which is the worst case for cherry-picking.** Last 8w, `main`'s first-parent line carries 280 landings: **94 true merge commits + 186 squashes** (185 ending in `(#NNN)`), i.e. ~66% squash / ~34% merge. Full history: 523 landings = 223 merges + 300 squashes (267 `(#NNN)`). Squashed PRs get a new single SHA (patch-ids won't match fork commits), while merged PRs preserve branch commits — so neither `git cherry` alone nor SHA tracking is sufficient; the fork needs subject/content matching as well.

**6. Fork divergence** (`git rev-list --left-right --count upstream/main...<branch>`; `+`/`-` from `git cherry upstream/main <branch>`):

| branch | behind | ahead | merge-base (date) | cherry `+` (not upstream) | `-` (already upstream) | subject-matched |
|---|---|---|---|---|---|---|
| `feature/local-rp-stability-stack` | 29 | 32 | `42fbfc77` 2026-09-03 | 19 | 0 | 0 |
| `feature/local-rp-stability-rc-20260905` | 9 | 10 | `2527a6e8` 2026-09-04 | 6 | 0 | 0 |
| `feature/local-rp-diagnostics` | 11 | 8 | `7179f911` 2026-09-04 | 6 | 0 | 0 |
| `integration/local-patches` | **792** | 11 | `bd39cf0d` 2026-07-10 | 8 | 0 | 0 |
| `release/mp-patches-v1.0.29` | **670** | 6 | `fe68009b` 2026-07-15 | 2 | **4** | 1 |

The three active branches are near-current (merge-bases 1–2 days old) but carry **19 unique local commits** none of which exist upstream in any form — the stability-stack patches (selection-mirror ownership, qualified-read isolation, prompt-export watchdog, same-workspace agent admission, MCP workspace fencing, exact-file-identity across awaits) are pure local carry. `integration/local-patches` and `release/mp-patches-v1.0.29` are abandoned in place, 670–792 commits behind. **`release/mp-patches-v1.0.29` is the only branch with evidence of upstreaming**: 4 of its 6 commits match upstream by patch-id (Codex app-server lifecycle, worktree path separation, worktree selector scoping, Codex exit evidence) and a 5th matches by subject — that work landed upstream on 2026-07-17 as `9d09d326`/`29f34515`/`97f93398`/`b7e0e7f5`. Separately, **MP has 27 commits already merged into `upstream/main`** (most recent: `834b43e0` "Fix CLI single-shot selector routing (upstream PR 904)", 2026-08-30; `18318807` hook approval flow (upstream PR 678), 2026-08-20), so upstreaming is a demonstrated, working path for this fork — the current 19-commit backlog is the exception, not the rule.



### Upstream governance and community forks

External fact-gathering, 2026-09-05, read-only (`gh api` + GitHub web). All counts are as-of that date.

**Upstream [`repoprompt/repoprompt-ce`](https://github.com/repoprompt/repoprompt-ce) — scale and velocity**

- 902 stars, 116 forks, Apache-2.0, repo created 2026-05-12. 53 open PRs, 138 open issues (107 closed).
- Merged PRs: **126 in the last 30 days**, **307 in the last 60 days**, 517 lifetime; 140 closed-unmerged. This is a fast-moving tree, not a coasting one.
- 839 commits landed on `main` in the last 60 days. Top authors: maintainer A 537, maintainer B 126, a contributor 34, **`mplibunao` 30**, a frequent outside contributor 27, `sentry[bot]` 25, maintainer C 21, then a long tail of ≤8 commits each.
- Merge authority is concentrated: over a 100-PR sample of the 60-day merged set, `merged_by` was **maintainer A 90, maintainer C 9, one other account 1**. Maintainers A and B are the maintainer core; everyone else is a contributor whose work is merged *by* a maintainer. *(Uncertain: the sample is 100 of 307, taken sorted by updated-at, so it skews recent.)*

**Releases and channels**

- 31 releases. Latest [`v1.4.0`](https://github.com/repoprompt/repoprompt-ce/releases/tag/v1.4.0) on 2026-08-30 (6 days ago). Recent cadence: v1.1.0 07-21 → v1.1.1 07-29 → v1.1.2 07-30 → v1.2.0 08-03 → v1.3.0 08-11 → v1.4.0 08-30 — roughly **weekly-to-biweekly**, after near-daily 1.0.x patch releases through June.
- Upstream already ships a **two-channel distribution**: `.github/workflows/main-tip.yml` publishes a "Tip" build after every successful CI run on `main` (gated by `tip-rollout.json`), while `release-candidate.yml` / `release-promote.yml` + `release-rollout.json` drive staged stable rollout. Relevant to the "should MP run his own stable distribution" question: the *mechanism* for a non-stable channel already exists upstream.

**CI on PRs — [`.github/workflows/ci.yml`](https://github.com/repoprompt/repoprompt-ce/blob/main/.github/workflows/ci.yml)**

Runs on `pull_request` and pushes to `main`, all on `macos-26`, five jobs:
1. **Style** — `make guardrails`, SwiftFormat/SwiftLint (`make lint`), `make conductor-selftest`, pinned Codex CLI `0.149.0` + `make dev-codex-schema-check`, `make release-selftest`.
2. **Build and Test** — `swift build` for `RepoPrompt` and `repoprompt-mcp`, then the full XCTest suite across **4 shards** via `Scripts/ci_app_test_runner.py` (fresh HOME/TMP sandbox per suite, explicitly **no retries**).
3. **Sentry-enabled Build** — builds with `REPOPROMPT_ENABLE_SENTRY=1` and runs `SentryTelemetryPrivacyTests`.
4. **Provider Tests** — `Packages/RepoPromptAgentProviders` package tests.
5. **Secret Scan** — gitleaks over the introduced commit range.
Plus `xcode-workspace.yml` for the generated-workspace contract.

**Governance — what upstream accepts**

- [`CONTRIBUTING.md`](https://github.com/repoprompt/repoprompt-ce/blob/main/CONTRIBUTING.md) documents a hard **contribution gate**: `pr-gate.yml` / `issue-gate.yml` fire on `pull_request_target` and auto-close issues/PRs from accounts absent from the tracked [`.github/APPROVED_CONTRIBUTORS`](https://github.com/repoprompt/repoprompt-ce/blob/main/.github/APPROVED_CONTRIBUTORS) allowlist (capability `issue` or `pr`; the list was seeded from paid-customer claim forms). Maintainers approve ad hoc by replying `lgtm` / `lgtmi`. The allowlist grants **no repo access**.
- Expectations for a PR: keep it focused, understand the code (AI-assisted work explicitly welcome), no raw RP working artifacts checked in, run `make guardrails` + `make dev-lint` + focused `make dev-test FILTER=…`, `make xcode-validate` for generator changes, and **do not touch release metadata, signing identities, bundle IDs, Sparkle keys, or channels without a maintainer asking**.
- There is **no roadmap or governance doc** beyond `CONTRIBUTING.md` + `SECURITY.md` — nothing states what features upstream wants, only how to submit. Scope acceptance is implicit/maintainer-discretionary.

**MP's upstream PRs (`mplibunao`, 12 total)**

- **6 merged, 6 open, 0 closed-unmerged** — a 100% eventual-acceptance rate on everything not still in flight.
- Time-to-merge for the 6 merged: 8h, 21h, 99h, 136h, 155h, 526h → **median ≈ 118h (4.9 days)**, mean ≈ 7.3 days.
- Review state: 2 `APPROVED`, 3 `CHANGES_REQUESTED`, 7 `REVIEW_REQUIRED`. **All 3 changes-requested PRs are open and large** — upstream PR 889 (+3,827), upstream PR 898 (+8,437), upstream PR 897 (+11,162). The merged set skews smaller (upstream PR 904 +221, upstream PR 529 +611, upstream PR 532 +1,511). Size correlates with stall.

**Fork A**

- **0 ahead, 9 behind** upstream `main`; every commit in its history is an upstream commit. Pushed 2026-09-04. 2 stars.
- **0 PRs opened against upstream** (an author search returns none), though the account *is* on the approved-contributor list.
- Technique: plain **fast-forward mirror** (GitHub "Sync fork"), zero local carry, zero merge commits of its own.
- **Conclusion: not a useful model.** It is sustainable only because it maintains nothing — it is a bookmark, not a downstream distribution. It offers no evidence about carrying local patches over time.

**Fork B, branch `sandbox`**

- **189 ahead, 110 behind** upstream `main` (status: diverged). Last commit **2026-09-03T18:34:50Z**. Their `main` is 6 ahead / 370 behind — abandoned. 9 branches total (`rp-server`, `remote-foundation`, `integration/remote-foundation-standalone`, codex/* work branches).
- `docs/server/getting-started.md` describes **"RepoPrompt Server", a Linux product**: SQLite-backed Agent Mode, an **operator portal over HTTPS** (`https://127.0.0.1:9443/portal/`, password setup on first run), **mTLS HTTP**, and **MCP served over the same `RepoPromptHeadlessAuthority` the macOS app uses**. It builds **without AppKit** — a separate `RepoPromptServer` product behind `REPOPROMPT_SERVER_ONLY=1` (`make dev-server-build` / `dev-server-test`), loopback readiness on `http://127.0.0.1:9080/health/ready`, optional client-cert + HMAC-signed routes, and an optional **chat adapter** that presents a signed `AuthorizationDecision` with explicit-selection context. Subsystems touched: Agent Mode authority, state persistence, MCP transport, TLS/auth, a new web portal, and the SwiftPM target graph/packaging.
- Upstreaming: **6 PRs, "Server upstreaming (PR 1/6…6/6)"** (upstream PRs 843, 845, 848, 849, 852, and 855), opened 2026-08-19→21 — **all closed unmerged on 2026-08-28, closed by the author himself**, with no formal review submitted on the ones checked. He is on the approved list, so the gate did not close them. *(Uncertain: no maintainer comment was captured explaining the outcome; self-closure after 7–9 days of silence is the visible fact.)*
- Sync technique: exactly **one merge commit** in the recent `sandbox` history — "Absorb upstream/main into the standalone server sandbox line." (2026-08-17) — i.e. **periodic merge absorption**, not continuous rebase. It has drifted 110 commits behind since.

**Other notable forks (116 total; no fork has >2 stars)**

- Fork C, branch `dev` — **165 ahead / 102 behind**; a large series moving ACP/Codex/Claude agent authority into **Rust** ("make ACP lifecycle Rust-authoritative", provider conformance gates); last active 2026-08-31.
- Fork D — **19 ahead / 9 behind**, merging `upstream/main` every day or two; carries small preference patches (DeepSeek `deepseek-v4-flash` default, 500K context budget, hidden recommendation wizard/setup banners) plus **OpenCode 2 binary discovery for ACP launch**. Closest visible analogue to a maintained personal distribution.
- Fork E — **7 ahead / 59 behind**; **Cursor CLI ACP support** (verified Cursor agent entrypoint, bounded probe cleanup), developed through self-reviewed PRs inside the fork.
- The frequent outside contributor's fork — 1 ahead / 1,072 behind; the account contributes directly upstream (27 commits in 60 days) rather than via the fork.
- The remaining forks checked, including those of several upstream contributors, are **strictly behind with 0 unique commits** — pure mirrors.
- No fork other than Fork B carries a chat feature or a Linux/headless target; that work is unique and, so far, unlanded.

### Upstream PR 956 and the bundled Codex app-server

Scope note: this answers "can a user point CE at their own Codex again, and does that restore their `~/.codex` setup?" Short answer (OBSERVED): upstream PR 956 restores the *binary* choice only; the *config home* stays app-private in every mode.

**1. Upstream PR 956 — Allow selecting a local Codex runtime** (OBSERVED)

- Author: the frequent outside contributor, not a listed maintainer; **OPEN**, created 2026-09-05T08:01Z, updated 10:50Z; branch `feat/codex-runtime-selection` → `main`; **+535/-33 across 8 files**.
- All 8 required checks pass (Style, 4 root test shards, Sentry build, Provider Tests, Secret Scan); `mergeStateStatus: BLOCKED`. INFERRED: blocked on required human review, not CI.
- **What the toggle switches: the BINARY only, never `CODEX_HOME`.** The diff contains zero occurrences of `CODEX_HOME`, `statePaths`, or `codexHome`. Three persisted states in the new `CodexRuntimePreferences`: `bundled`, `inherited` (legacy `REPOPROMPT_CODEX_EXECUTABLE`-or-bundled), `external(path:)`; a saved choice is staged until app relaunch.
- **Where it is exposed:** Settings → CLI Providers → Codex CLI runtime picker (`CLIProvidersSettingsView.swift`, +184). Persistence is plain `UserDefaults` keys `codexRuntimeSelectionMode` / `codexRuntimeExecutablePath` — **no `app_settings` MCP key** (grep of the diff for `app_settings`/`AppSetting` returns nothing), so it is not scriptable from MCP.
- PR body, Motivation, quoted verbatim:
  > RepoPrompt bundles a known-compatible Codex build, but advanced users may already have a newer compatible Codex CLI installed. Selecting that executable allows them to use newly advertised models and capabilities without rebuilding RepoPrompt, while retaining the bundled build as the safe default.
- `docs/releasing.md` (pre-existing context line kept by the PR), quoted verbatim — this is the load-bearing sentence for MP's complaint:
  > Bundled and external runtimes both use RepoPrompt-owned `CODEX_HOME` and `CODEX_SQLITE_HOME` directories under
- **Maintainer comments: none.** Maintainers A, B, and C have not commented. The only review is the automated `chatgpt-codex-connector`, with a P1 ("Probe local Codex with the captured shell environment") and a P2 ("Avoid switching only newly created Codex clients"); the author replied that both are fixed in `71478614`, then the bot posted that it had hit Codex review usage limits.
- Rationale for bundling itself is stated in the earlier upstream PR 612 body, quoted verbatim:
  > This PR makes that runtime the application authority so user PATH drift, stale global CLIs, and mismatched config/state no longer silently influence RepoPrompt sessions.

**2. Current `upstream/main` config-home behavior** (OBSERVED, cited)

- `CODEX_HOME` and `CODEX_SQLITE_HOME` are injected from `StatePaths` — `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexRuntimeAuthority.swift:22-27`.
- The home is **app-private**, never `~/.codex`: `…/Application Support/RepoPrompt CE/Codex/{Debug|Release}/home` — `CodexRuntimeAuthority.swift:219-234`.
- Per-artifact projection into RP-launched Codex agents today:
  - **Global instructions — YES, copied.** Only `AGENTS.md` and `AGENTS.override.md` are projected from `~/.codex` into the managed home, hash-manifest tracked and fail-closed on unowned/modified destinations: `CodexGlobalInstructionsProjection.swift:72-108`, invoked from `CodexRuntimeAuthority.swift:42-48`.
  - **`~/.codex/config.toml` MCP servers — NO.** The managed `config.toml` is RP-owned and RP-written (`CodexIntegrationConfiguration.swift:105-109`, `:1256`); nothing reads the user's file. Matches open upstream issue 830.
  - **Hooks — NO import; replaced by an RP-native flow.** RP drives `hooks/list` and writes its own `hooks.state` approvals into the managed home (`CodexHookTrustService.swift:61`, `:148`); user approvals recorded in `~/.codex/config.toml` are not migrated.
  - **Skills — YES, but not via `CODEX_HOME`.** Delivered through the app-server request `skills/extraRoots/set` (`CodexNativeSessionController.swift:1205-1206`, `:1924-1925`).
- Commits since 2026-07-15 in this family: `4fd888ed` 2026-07-22 *Bundle pinned Codex runtime artifact*; `f6ab144a` 2026-07-23 *feat: make bundled Codex the runtime authority*; `89a0e235` 2026-07-23 *fix: avoid repeated external Codex probes*; `6d1c50af` 2026-07-23 *fix: harden Codex runtime authority*; `a308041d` 2026-07-23 *Fix bundled Codex release signing*; `3b8d3165` 2026-07-26 *Update bundled Codex to 0.145.0 (upstream PR 635)*; `2eb8b38a` 2026-07-27 *Fix bundled Codex JIT entitlements (upstream PR 647)*; `18318807` 2026-08-20 *Add a Codex project hook approval flow to Agent Mode (upstream PR 678)*; `1c41f62c` 2026-08-09 *Bundle Codex 0.147.0 and fix exec permissions (upstream PR 748)*; `b6ca6278` *Fix: expose global skills to Codex agents (upstream PR 824)*; `44774ffa` 2026-08-22 *Enable Codex apps with runtime 0.149.0 (upstream PR 851)*; `13e9be2d` 2026-08-30 *fix(codex): project global instructions into managed state (upstream PR 906)*.

**3. Upstream issue family** (OBSERVED)

| Issue | Reporter | State | Resolution |
| --- | --- | --- | --- |
| Upstream issue 830 MCP servers dropped from `~/.codex/config.toml` | `mplibunao` | **OPEN** | none; upstream PR 956 does not address it |
| Upstream issue 831 global `~/.codex/AGENTS.md` ignored | `mplibunao` | CLOSED 2026-08-30 | fixed by upstream PR 906 |
| Upstream issue 665 project hooks silently skipped (fail-open) | `mplibunao` | CLOSED 2026-08-20 | fixed by upstream PR 678 |
| Upstream issue 821 global skills invisible to Codex agents | maintainer C | CLOSED 2026-08-16 | fixed by upstream PR 824 |
| Upstream issue 471 nvm-installed `codex` not resolved | another user | **OPEN** | adjacent; upstream PR 956's login-shell discovery targets this class |

MP's other open CE issues are unrelated to Codex config (upstream issues 949, 954, 918, 921, 881, 882, 887, and 457).

**4. Version-skew exposure when pointing CE at a system `codex`** (OBSERVED + INFERRED)

- Floor check: `CodexRuntimeAuthority.minimumExternalVersion = bundledVersion = 0.149.0` (`CodexRuntimeAuthority.swift:9-10`). An **older** system Codex is rejected outright with a settings-visible error; a **newer** one is accepted on the version number alone.
- The contract gate is developer/CI-side only: `make codex-schema-check` → `Scripts/check_codex_app_server_schema.py` (`Makefile:134`; daemon alias `Makefile:208-209`), validating against `Scripts/Fixtures/codex-app-server-contract.json` (`schemaVersion: 1`, `minimumCodexVersion: "0.149.0"`, `experimental: true`, **45 method checks**). It shells out to whichever `codex` is on the runner's PATH, refuses anything below the floor (`check_codex_app_server_schema.py:911-920`), generates the schema bundle, and diffs the 45 request/response/enum expectations. A separate guardrail requires the string `rust-v0.149.0` in `docs/releasing.md` (`Scripts/codex_vendor_guardrails.sh:51`).
- INFERRED risk with upstream PR 956: nothing runs that 45-method contract against the user's chosen binary at runtime. A newer system Codex that renames a method, drops a param, or changes an enum passes the version floor and then fails inside Agent Mode as a runtime/protocol error rather than a settings-time rejection — i.e. upstream PR 956 moves CE from "pinned and verified" to "version-floor only," which is exactly the risk class upstream PR 612 was written to eliminate.


### Prior Codex app-server investigations and upstream PR 956 head re-check

Scope note (OBSERVED): every file under `docs/investigations/` is untracked by repo policy; the sibling report written earlier today is `codex-bundled-vs-local-appserver-2026-09-05.md` (48 KB, 03:23 UTC).

#### 1. Upstream PR 956 at current head (OBSERVED — `gh pr view/diff 956`, 2026-09-05)

- Head `7147861450afbe9b14a83fc7ff920f2e274c8576`; 5 commits from 07:58Z to 10:35Z; PR `updatedAt` 10:50:56Z. The metadata timestamp is later than the last commit, so description staleness is not visible from timestamps alone (INFERRED limit: `updatedAt` also moves on comments and labels; a body-edit audit needs the timeline API).
- 8 files: `CLIProvidersSettingsView`, `CodexAppServerClient`, `CodexIntegrationConfiguration`, `CodexProviderHelpers`, `CodexRuntimeAuthority`, new `CodexRuntimePreferences`, `CodexRuntimeAuthorityTests`, `docs/releasing.md`.
- **No `CODEX_HOME`, `codexHome`, config-home layering, or user `~/.codex/config.toml` MCP import anywhere in the diff (OBSERVED).** The single `statePaths` occurrence is the unchanged `resolveExternalOverride(_:statePaths:...)` signature context line. The 2-line `CodexIntegrationConfiguration` change does not touch `configDirectoryURL()`, which still resolves to the managed home.
- **The runtime check for an external binary is a floor only, and upstream PR 956 does not change it.** Verbatim from `CodexRuntimeAuthority.swift` (unchanged region, present on `upstream/main`):
  ```swift
  guard version >= minimumExternalVersion else {
      return .failure(.externalOverrideTooOld(actual: version, minimum: minimumExternalVersion))
  }
  ```
  with `static let minimumExternalVersion = bundledVersion` (0.149.0). No ceiling, no schema or capability probe. What upstream PR 956 adds is environment threading into the probe only: `readExternalVersion(executableURL:environment:)` now sets `process.environment = environment`, and the version cache key gains an `environment:` component.
- INFERRED: upstream PR 956 moves executable provenance into a UI-selectable preference and leaves state provenance untouched, so it restores none of the `~/.codex` features and inherits the unchecked schema-drift exposure recorded as Q5 in the bundled-vs-local report.

#### 2. Prior investigations (OBSERVED — doc summaries)

- **`repo-prompt-codex-agent-hang-2026-07-08.md`** — Codex chats and agents stuck on Thinking forever. Root cause: RepoPrompt serialized `textElements` where the generated schema uses `text_elements`; the turn ran but `turn/completed` never fired, and `turn/start` has no timeout by design. Class **(a) protocol shape, but RepoPrompt-side drift rather than a user version skew**. Fixed upstream: upstream PR 450 (merged 2026-07-16) closing upstream issue 449.
- **`codex-appserver-and-issue-triage-2026-07-12.md`** — triage of upstream issue 449/upstream PRs 450 and 472 plus an app-server died incident. Upstream issue 449 reproduced live on codex-cli 0.144.1, the then-latest stable. The died incident was CE retiring idle app-servers after 300 s plus replacement startup stalling on a local build 54 commits behind upstream `1ab555e6` (Fix Codex app-server startup stalls, shipped in 1.0.27). Classes **(a)** for upstream issue 449 and **(c)** for the stall; both fixed upstream.
- **`worktree-bound-codex-app-server-start-failure-2026-07-15.md`** — worktree-bound Codex starts fail with app-server process is not running while unbound and Claude starts succeed. Root cause: a cwd-model defect — the bound worktree path is used for the app-server process cwd, not only the thread, turn, and sandbox cwd, exposing provider bootstrap to worktree-local tooling; compounded by a diagnostic defect that collapses several transport-loss paths into `processNotRunning` with no stderr or exit status retained. Class **(c)**. Fixed upstream: upstream issue 554 closed by upstream PR 568 (merged 2026-07-22, authored by MP).
- **`codex-agent-start-failure-all-roles-2026-07-22.md`** — reported as every Codex dispatch failing. Actually upstream issue 554 running unfixed in the local build because the 2026-07-20 upstream sync dropped the upstream PR 568 branch. Restarts, a codex CLI upgrade to 0.145.0, and a reboot were all irrelevant; wire-level probes exonerated codex, node, mise, PATH, and auth. Class **(c)** plus fork-maintenance process. Resolved by merging upstream PR 568; prevention captured as a local patch ledger in the personal toolkit's RepoPrompt CE notes.
- **The issue drafts behind upstream issues 830 and 831** — not a failure investigation but the drafts for user state dropped by the app-private home. Class **(b)** by construction. Filed as upstream issue 830 (user `[mcp_servers]` from `~/.codex/config.toml`) and upstream issue 831 (global AGENTS.md). Upstream issue 831 is fixed upstream by upstream PR 906 (merged 2026-08-30); upstream issue 830 remains open.
- **`codex-fallback-strict-mode-approval-2026-08-31.md`** — three `CodexFallbackFIFOTests` failures. Root cause: a test-isolation defect, since the shared fixture reads `GlobalSettingsStore.shared` and inherits the persisted `codexHookApprovalStrictModeEnabled=true`, so the coordinator correctly rejects `.continueWithoutHooks`. Not (a), (b), or (c) — a CE test fixture defect with no app-server involvement.
- **`codex-bundled-vs-local-appserver-2026-09-05.md`** — see item 3(ii) below.

#### 3. Direct answers

**(i) No — MP never hit a Codex app-server version or protocol skew problem in the pre-bundling era.** The one protocol-shaped failure (upstream issue 449/upstream PR 450) was a RepoPrompt-side wire shape that was wrong against every codex revision: the 2026-07-12 triage verified `text_elements` unchanged from rust-v0.120.0 through v0.144.1 with no camelCase alias, and the hang reproduced on the then-latest 0.144.1, so upgrading codex could not have fixed it. The maintainer question, verbatim, was "I have never seen this issue. Is your codex cli updated to latest?" — the wrong hypothesis. Everything else was RepoPrompt-side lifecycle or environment (startup stalls fixed by `1ab555e6`, worktree cwd projection upstream issue 554/upstream PR 568, idle-retire replacement) and, after upstream PR 612, config-home isolation. The one genuine too-old-client case in the tracker is upstream issue 471, filed by another user, not MP: an nvm-installed codex missed because the non-interactive login shell skipped `.zshrc`, so CE resolved a stale binary or none and hit API 400 requires a newer version of Codex. That issue is the stated precipitating class for bundling.

**(ii) The bundled-vs-local report concluded against a toggle.** Verbatim from its summary: "The regressions blamed on \"bundling\" (global `AGENTS.md`, skills, hooks, MCP servers) are caused by the app-private `CODEX_HOME` introduced in upstream PR 612, not by which binary runs; the existing external-binary override keeps the same isolated home, so a bundled/local toggle restores none of them." Its recommendations are: make advertised model metadata round-trip, rotate the certified pin faster, keep projecting `~/.codex` state per feature, and do not ship a bundled/local toggle. Its same-day addendum partially reverses the model-latency half with live evidence: the managed home `models_cache.json` at `client_version` 0.149.0 lacks `gpt-6-astra` while `~/.codex` at 0.153.0 contains it, making a newer runtime a **necessary** but not sufficient condition; the addendum also records third-party `~/.codex` readers such as CodexBar as a regression class no per-feature bridge can fix.

**(iii) Bundling landed in two split PRs: upstream PR 605 packaged the pinned 0.144.6 artifact (2026-07-22), and upstream PR 612 made it authoritative (2026-07-23).** Motivation, verbatim from the upstream PR 612 description: "PR2 bundled a pinned Codex runtime. This PR makes that runtime the application authority so user PATH drift, stale global CLIs, and mismatched config/state no longer silently influence RepoPrompt sessions. Explicit external overrides remain available for advanced testing but must satisfy the same app-server contract." upstream PR 612 is also the change that introduced the isolated `CODEX_HOME` and `CODEX_SQLITE_HOME`.

#### 4. How the private home is composed today (OBSERVED — `git grep` on `upstream/main`)

1. `CodexRuntimeAuthority.statePaths()` builds `~/Library/Application Support/RepoPrompt CE/Codex/{Debug|Release}/{home,sqlite}` and exports `CODEX_HOME` and `CODEX_SQLITE_HOME`; bundled and external runtimes receive the same `StatePaths` by construction.
2. `Runtime.prepareState()` creates those directories and calls `CodexGlobalInstructionsProjection.prepare(ordinaryCodexHome:managedCodexHome:)` — the only read of the real `~/.codex` — projecting exactly two files, `AGENTS.override.md` and `AGENTS.md` (upstream PR 906), as atomic copies tracked by a `.repoprompt-agents-projection.json` ownership manifest.
3. Skills are never layered into the home: upstream PR 824 sends roots over the wire via `skills/extraRoots/set`, and the root is `~/.agents/skills`, not `~/.codex/skills`.
4. **MCP servers: no.** `CodexIntegrationConfiguration.configDirectoryURL()` returns the managed `codexHome`, so every `config.toml` read and write targets the private file; CE authors its own `[mcp_servers.RepoPromptCE]` block there and never reads the user `~/.codex/config.toml` (upstream issue 830, open).
5. **Hooks: project scope only, no global import.** `CodexHookTrustService` calls `hooks/list` for the execution cwd and writes `hooks.state` trusted hashes into managed config, while `CodexHookTrustModels` filters approval to `source == "project"`. Also unlayered: prompts, `rules/*.rules`, `auth.json`, profiles, memories, and sessions/history.

## Investigator Findings
<!-- Pair investigator appends here: file:line refs, evidence, conclusions. -->


## Investigator Findings: verification & release-train feasibility

### 1. Existing regression net

- **OBSERVED — current scale.** A source census at detached checkout `2b8f6304` finds **443 XCTestCase suites / 4,779 `test*` methods** under `Tests/` (477 Swift files), plus **3 suites / 7 methods** in `Packages/RepoPromptAgentProviders/Tests`. This is a static declaration count because running `swift test list` would violate this investigation's no-build/shared-machine constraint; the authoritative CI census is dynamic `swift test list` discovery (`Scripts/ci_app_test_runner.py:92-123,855-921`; `docs/testing.md:50`).
- **OBSERVED — protected-workflow coverage is broad but assembled-app coverage is not.** `docs/testing.md` explicitly distinguishes root SwiftPM/in-process/subprocess-adapter tests from live packaged smoke (`docs/testing.md:16-25`).

| Protected workflow | Existing executable coverage | Level and remaining gap |
| --- | --- | --- |
| External MCP orchestration | Context Builder frozen-worktree/nested-tool integration (`Tests/RepoPromptTests/ContextBuilder/ContextBuilderWorktreeInheritanceTests.swift:72-204`); Ask Oracle multi-root/worktree cases (`Tests/RepoPromptTests/MCP/MCPAskOracleWorktreeTests.swift:307-486`); selection persistence and multi-window routing (`Tests/RepoPromptTests/MCP/TabContextRoutingTests.swift:170-230,1965-2083`); actual headless `repoprompt-mcp` JSON-RPC process (`Tests/RepoPromptTests/MCP/DirectHeadlessProcessTests.swift:71-198`). | **OBSERVED:** unit/in-process integration, except the real headless helper process. The process test deliberately denies `context_builder`/Oracle and has no app (`DirectHeadlessProcessTests.swift:119-169`), so no packaged external-client journey reaches a real model. |
| In-app Agent Mode | Agent start/wait/steer services, Codex/Claude lifecycle, and provider adapters have focused suites; worktree-start tests explicitly use controller fakes (`Tests/RepoPromptTests/MCP/AgentRunWorktreeStartTests.swift:1101-1136`); steering is service-level (`Tests/RepoPromptTests/MCP/AgentRunMCPToolServiceSteerResumeTests.swift:8-185`). | **OBSERVED:** unit/integration. No XCTest launches a credentialed Codex or Claude provider. Some tests spawn real Git/shell/fake-provider processes, but not a real model provider. |
| Multi-root + worktrees + multi-window | Multi-window disambiguation and failure are tested (`TabContextRoutingTests.swift:208-252`); worktree inheritance, multi-root bindings, and child creation are heavily exercised (`AgentRunWorktreeStartTests.swift:1611-1768,2137-2176,4083-4112`). | **OBSERVED:** unit/in-process integration with real temporary Git repositories; no test launches the packaged `.app` or proves Finder/app lifecycle, Bonjour/socket ownership, two visible windows, and provider process cleanup together. |

- **OBSERVED — CI execution.** Hosted CI builds app/helper, discovers methods, assigns four method-count-weighted shards, then runs each suite in its own XCTest process; only silent startup timeouts get one retry and assertion failures fail immediately (`.github/workflows/ci.yml:55-100`; `Scripts/ci_app_test_runner.py:22-29`).
- **OBSERVED — the TSV premise is historical.** `Scripts/Fixtures/test-suite-contract-ledger.tsv` was deleted by `205d9787` on 2026-08-02 with the optimizer/scoreboard system. Before deletion it was initially generated by `test_suite_optimizer.py inventory`, then curated and surgically updated; `verify-ledger` compared exact live method IDs. Current CI is explicitly “not a contributor-maintained registry” (`docs/testing.md:43-50`).
- **INFERRED — fork conflict effect.** The old 3,844-line TSV was a high-churn generated scaffold plus hand-maintained metadata, so old patch stacks frequently conflicted on it; it did **not** logically guarantee a conflict for every upstream test change. Current upstream test additions/removals cannot conflict on a file that no longer exists. A cherry-pick that resurrects it is a stale-patch warning, not a test-safety feature.

### 2. Live acceptance tooling and the missing release gate

- **OBSERVED — `./conductor smoke`.** Against an already running debug app it checks `windows`, workspace switch, root tree, worktree listing, and role catalog; `--agent-run` adds one Explore start/wait (`Scripts/conductor.py:7592-7645,7666-7702`). `dev-smoke` and `dev-smoke-launch` are only aliases (`Makefile:217-221`). Doctor checks toolchain/SDK/signing/SwiftUI and CLI installation, not product journeys (`Scripts/doctor.sh:17,48-111`).
- **OBSERVED — packaged smoke.** `--packaged-app` validates helper layout, architectures, optional artifact manifest, early helper startup, an isolated Keychain/HOME, exact launched PID/socket ownership, and one `windows` round-trip (`Scripts/smoke_packaged_mcp_roundtrip.sh:101-175,231-278`). Packaged mode returns after that and cannot combine with `--agent-run` (`Scripts/conductor.py:7573-7590,8253-8265`).
- **OBSERVED — uncovered.** No existing smoke completes Context Builder or Ask Oracle, mutates and re-reads selection, steers a live session, runs both Codex and Claude, starts a worktree-bound child, proves multi-root/two-window isolation, or verifies provider teardown on app quit.
- **INFERRED — minimal packaged-runtime acceptance commands.** Run against a disposable two-root workspace and existing linked worktree; `$CLI` must be the exact candidate's embedded `repoprompt-mcp` (use `rpce-cli-debug` only for the exact debug candidate).

```bash
./conductor smoke --packaged-app "$CANDIDATE" --artifact-manifest "$MANIFEST"  # PASS: signature/layout/hash + owned socket + windows response
$CLI -e 'windows'                                                              # PASS: record two distinct test window IDs
$CLI -w "$W1" -c manage_selection -j '{"op":"set","paths":["RootA/MarkerA.txt"]}' # PASS: snapshot contains A only
$CLI -w "$W2" -c manage_selection -j '{"op":"set","paths":["RootB/MarkerB.txt"]}' # PASS: W1 remains A; W2 contains B
$CLI -w "$W1" -c context_builder -j '{"instructions":"Reply with the selected marker and root.","response_type":"question"}' # PASS: final=A/RootA, no B
$CLI -w "$W1" -c oracle_send -j '{"message":"Reply ORACLE_OK and identify the selected root."}' # PASS: terminal ORACLE_OK + reusable chat_id
$CLI -w "$W1" -c agent_run -j '{"op":"start","model_id":"codexExec","message":"Reply CODEX_OK.","detach":true}' # PASS: wait terminal CODEX_OK
$CLI -w "$W1" -c agent_run -j '{"op":"start","model_id":"claudeCode","message":"Wait for steering.","detach":true}' # PASS: returns session_id
$CLI -w "$W1" -c agent_run -j '{"op":"steer","session_id":"$CLAUDE_ID","message":"Reply CLAUDE_STEER_OK."}' # PASS: wait terminal marker
$CLI -w "$W1" -c agent_run -j '{"op":"start","model_id":"explore","worktree":"@current","message":"Report pwd and worktree marker.","detach":true}' # PASS: exact linked-worktree root/marker
$CLI -w "$W1" -c agent_manage -j '{"op":"list_sessions"}'                    # PASS: child binding/provenance exact; no orphan active run
./conductor app stop && ./conductor app launch-existing                         # PASS: long-running Claude PID+MCP descendants gone; relaunch accepts a new run
```

- The stop/relaunch arm is disruptive and therefore an operator-approved release gate. Run equivalent Context Builder/Oracle/Agent canaries once from **each** protected client (Claude Code and Codex); raw CLI alone cannot prove client-side selector/routing behavior.

### 3. Rollback artifacts and downgrade safety

- **OBSERVED — artifact identity.** Debug bundles embed repo/worktree/branch/commit/dirty/build-time provenance (`Scripts/package_app.sh:390-433`). Public release manifests bind bundle version, signing, architectures, entitlements, and executable hashes but contain no source commit (`Scripts/write_app_artifact_manifest.py:139-203`). Local production packaging is host-native, so it does not automatically write the public-universal manifest (`Scripts/package_app.sh:231-250,526-531`).
- **OBSERVED — signing continuity.** The installer keeps `local-signing-identity-v1.json`, pins certificate SHA-256 plus secure-storage generation, refuses silent replacement, and preserves prior certificate/service on rotation (`docs/releasing.md:429-472`). Its rollback is transactional only while installing; after success it deletes the prior app backup (`Scripts/install_local_production.sh:321-360`).
- **INFERRED — archive per accepted release** outside the shared state tree, e.g. `~/Library/Application Support/RepoPrompt CE Local Releases/<date>-<commit>/`: (1) `ditto` ZIP of the signed `.app`; (2) generated artifact manifest + SHA-256; (3) sidecar source provenance with commit, dirty=false, version and acceptance receipt; (4) copy of `local-signing-identity-v1.json` plus extracted designated requirement; (5) app-stopped snapshot of `~/Library/Application Support/RepoPrompt CE`, custom workspace-storage roots, and `defaults export com.pvncher.repoprompt.ce`; never export provider secrets/private keys into this folder.
- **OBSERVED — shared-state hazard.** Debug and production select different MCP service flavors (`Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPServiceName.swift:18-60`) but both hard-code the same Application Support root (`Sources/RepoPrompt/App/AppDomainRuntimeComposition.swift:57-73`; `WindowStateManager.swift:126-133`).
- **OBSERVED — downgrade behavior is mixed.** Global settings and presets preserve future-schema files and refuse saves (`GlobalSettingsFileStore.swift:97-184`; `PresetFileStore.swift:95-184`). Workspace decode accepts any `schemaVersion`, defaults/empties fields it cannot decode, and later encodes only fields known to that build (`WorkspaceModel.swift:343-487`). Agent sessions record serialization v7 but do not reject future versions (`AgentSession.swift:124-132,329-368`); loaded sessions can be normalized and rewritten (`AgentSessionDataService.swift:420-449`). Window sessions have no schema gate and decode failure simply returns nil (`WindowStateManager.swift:173-210`).
- **INFERRED — answer: no blanket safe downgrade.** An older build may ignore and later erase newer workspace/session fields, or fail restoration. Roll back **app and matching state snapshot together** unless a candidate has passed an explicit N→N-1 state replay test.
- **INFERRED — target RTO: under 10 minutes.** With the app stopped: verify archive checksum/manifest; atomically replace `/Applications/RepoPrompt CE.app`; restore matching registry/UserDefaults/Application Support snapshot when versions crossed persistence paths; verify `codesign` and the manifest; launch and run `windows` + one protected canary. Keeping the same certificate/generation preserves Keychain access. The repository needs a durable post-install rollback command; today only the failed-install transaction is automated.

### 4. Upstream-change triage signal

| Risk | Machine-readable touched-path trigger | Required gate |
| --- | --- | --- |
| Low | Docs/assets only, excluding release/architecture/acceptance docs; test-only additions with no production deletion | Review + affected prose/test check; no packaged live gate. Test deletions require coverage review. |
| Medium | Isolated UI, rendering, syntax/parser changes outside protected paths | Focused tests + full root/provider suite when shared; visual/manual check for UI. |
| High: protected runtime | `Sources/RepoPrompt/{Infrastructure/MCP,Infrastructure/WorkspaceContext,Infrastructure/AI,Features/ContextBuilder,Features/AgentMode,Features/Workspaces,App}/**`, VCS worktree code, or protected-workflow tests | Full tests + complete packaged acceptance matrix above. |
| High: protocol/state | `Sources/RepoPromptShared/MCP/MCPControlMessages.swift`, bootstrap/protocol messages, `Infrastructure/Persistence/**`, `WorkspaceModel.swift`, `WindowStateManager.swift`, settings/session stores | Client compatibility canaries + N→N-1 replay; snapshot before install. |
| High: supply/package | `Package.swift`, `Package.resolved`, `Vendor/Codex/manifest.json`, `Scripts/{package_app,install_local_production,conductor,smoke_packaged_mcp_roundtrip}*`, `AppBundle/**`, signing/entitlements | Clean package/release checks, manifest verification, real Codex canary, rollback drill. |
| Historical/stale | A patch adds or modifies deleted `Scripts/Fixtures/test-suite-contract-ledger.tsv` | Rebase/adapt the test change to dynamic discovery; do not union/resurrect the ledger. |

- **OBSERVED — Codex is a useful trigger.** `Vendor/Codex/manifest.json:1-15` pins version/tag/checksums; packaging acquires and embeds exactly that artifact (`Scripts/package_app.sh:238-254,322-327`). The pin changed **three times after initial 0.144.6** in eight weeks: 0.145.0 (07-26), 0.147.0 (08-09), 0.149.0 (08-22). Any pin, schema-floor, entitlement, or bundled-runtime-tree change needs live provider acceptance, not just unit tests.

### 5. Recurring maintenance burden

- **INFERRED assumptions.** Four sync windows/month; 30–45 minutes mechanical integration per small refresh; 1.5–3 hours full gates/packaged checks per candidate; one semantic protected-path conflict/regression every 1–2 weeks costing 3–8 hours; PR review/remediation costs 2–6 hours per active upstream-bound patch. Upstream volume is 126 merged PRs/month and recently 19–51 commits/week; six prior stack rebuilds show integration is cheap but semantic validation is not.

| Strategy | Estimated hours/month | Operational interpretation |
| --- | ---: | --- |
| 1. Track upstream + short patch stack | **20–40 h** | 4 small integrations (8–14 h), 1–2 semantic incidents (6–16 h), upstream PR shepherding/ledger (6–10 h). Lowest drift, highest continuous interruption. |
| 2. Merge all upstream monthly into long-lived fork | **20–50 h** | One merge/release gate (5–10 h) plus a large, correlated semantic-debug tail (10–30 h) and patch reconciliation (5–10 h). Similar mean, much worse variance and recovery risk. |
| 3. Cherry-pick selected upstream work | **25–55 h** | Triage 126 PRs (6–10 h), dependency/order archaeology (8–20 h), adaptations (6–15 h), acceptance (5–10 h). Mixed squash/merge history and roll-forward fixes make omission risk expensive. |
| 5. Freeze on v1.4.0; security/critical only | **3–12 h typical; 15–30 h incident month** | Monitoring + rare adaptation is cheap, but provider/macOS compatibility can force unplanned jumps across many commits. Risk accumulates rather than disappearing. |

- **OBSERVED — freezing lacks a feed.** `SECURITY.md:1-14` offers private vulnerability reporting but no supported-version policy, SLA, advisory branch, or security-only release stream. Dependencies are exact-pinned (`Package.swift:16-45`), with no Dependabot/Renovate config in `.github`; Sentry is release telemetry/symbolication, not a downstream security feed (`docs/releasing.md:527-581`).
- **INFERRED.** “Security fixes only” means MP must monitor ordinary main/Tip/releases and decide what is security-relevant. Freeze is viable as abandonment-with-break-glass, not as a maintainable security channel.

### 6. Fork-only versus upstream-bound

- **OBSERVED/INFERRED — inherently fork-only:** MCP phase-attribution diagnostics are explicitly local and instrument MP's investigation workflow (the diagnostics row under "Patch inventory" above). Personal defaults/preferences should also remain tiny leaf patches: they express MP's product choice and create upstream review noise without fixing a shared contract.
- **OBSERVED/INFERRED — upstream-bound:** selection-mirror recovery, qualified multi-root reads, export watchdog, same-workspace Agent admission, app-quit provider teardown, Context Builder selection watchdog, and cancellable physical reads all repair shared MCP/provider/worktree behavior (the patch table under "Patch inventory" above). The admission patch changes shared persistence/recovery, making permanent divergence especially costly.
- **INFERRED — submission shape:** keep diagnostics/preferences separate; upstream behavioral fixes as the smallest source delta plus the focused regression contract. Large open PRs correlate with review stall (+3,827 to +11,162 lines versus +221 to +1,511 for merged examples; "MP's upstream PRs" above). Split test/diagnostic scaffolding when the behavior remains independently reviewable, but never split protocol and its compatibility test into different releases.

### So what for a downstream fork
- The current regression net is large, but it does not make a packaged candidate dependable without a real-client, real-provider acceptance matrix.
- A stable personal distribution is feasible only as a release train with explicit candidate promotion, not as “main plus successful XCTest.”
- Every promoted app needs a paired, checksum-verified state snapshot because older builds are not universally safe readers/writers of newer state.
- Path-based triage can keep docs/UI changes cheap while forcing live gates for MCP, Agent Mode, routing, persistence, packaging, and bundled Codex changes.
- The lowest-burden credible posture is a periodically refreshed hybrid with a very short patch stack; cherry-picking and monthly bulk merges shift effort into harder diagnosis.
- Keep diagnostics and preferences fork-only; keep shared liveness, protocol, persistence, provider, and routing fixes on an upstream path in small reviewable units.

## Investigator Findings: architecture coupling & cherry-pick feasibility

Current-source references in this subsection are to `upstream/main` at `2c4b86d0` (2026-09-05), not the checked-out `bugfix/887-qualified-read-peer-stall` branch, which is 70 upstream commits behind.

### 1. Module map and enforced boundaries

- **OBSERVED — root products and compiled targets.** `Package.swift` exposes only the `RepoPrompt` app and `repoprompt-mcp` executable products. The root package separately compiles `RepoPrompt` (one-file entry shell), `RepoPromptApp`, `RepoPromptDomainRuntime`, `RepoPromptWorkspaceCore`, `RepoPromptRegexCore`, `RepoPromptCodeMapCore`, `RepoPromptMCP`, `RepoPromptShared`, `RepoPromptC`, `CSwiftPCRE2`, `TreeSitterScannerSupport`, and vendored-binary `Sparkle`; five test targets own the app and four extracted cores (`Package.swift:108-230`). External/package edges are pinned Swift logging/Markdown/service/MCP/tree-sitter/AI/schema/telemetry dependencies plus local `UniversalCharsetDetection` and `Packages/RepoPromptAgentProviders` (`Package.swift:15-67`).
- **OBSERVED — provider package.** The nested `RepoPromptAgentProviders` Swift package exposes one separately compiled Foundation-only library, `RepoPromptClaudeCompatibleProvider`, and its owner-test target (`Packages/RepoPromptAgentProviders/Package.swift:4-25`; `docs/architecture/provider-plugins.md:49-73`). Composition is static SwiftPM linkage, not dynamic plugin loading (`provider-plugins.md:7-15`).
- **OBSERVED — folder-only boundaries.** `Features/AgentMode`, `Features/ContextBuilder`, `Features/Workspaces`, `Infrastructure/MCP`, `Infrastructure/WorkspaceContext`, `Infrastructure/AI`, `Infrastructure/Persistence`, and `App` are all folders inside the single `RepoPromptApp` target at `Sources/RepoPrompt` (`Package.swift:170-174`; `source-layout.md:11-49`). Swift enforces no import boundary between them. `RepoPromptDomainRuntime` is the compiler-enforced AppKit-free domain seam; `RepoPromptShared` is the app/CLI protocol seam; the workspace/regex/CodeMap cores are narrower pure seams (`source-layout.md:50-68,90-110`).
- **OBSERVED — what source guardrails enforce.** `Scripts/source_layout_guardrails.sh` statically verifies target topology, the thin executable, internal/unexposed core targets, exact allowed dependencies, single-sourced shared MCP DTOs, pinned parser artifacts, absence of retired folders/symbols, and an AppKit/SwiftUI/Combine/`@MainActor` ban plus required authority files in `RepoPromptDomainRuntime` (`source-layout.md:154-179`; `source_layout_guardrails.sh:390-430`). Its grep/Python checks protect named structure and markers; they do not create compiler boundaries among `RepoPromptApp` folders or prove end-to-end behavior.
- **OBSERVED — what the M0 JSON enforces now.** `headless_mcp_domain_runtime_m0_contract.json` records 27 tools, 86 discriminated actions, policies, actor hops, persistence, approval, credential, and child-launch evidence. Upstream PR 908 (`dbd9eeee`) deleted `HeadlessMCPDomainRuntimeM0ContractTests`; at current upstream, `git grep` finds only the spec citation and one live check that rejects four retired flat-dependency-bag keys (`Scripts/headless_runtime_guardrails.sh:109-111`). The broad JSON inventory is therefore documentary evidence, not an executable current gate. Live schema authority is Swift `MCPDomainCanonicalToolDefinitions` (`docs/architecture/headless-mcp-runtime.md:13-23`).
- **INFERRED — module verdict.** Leaf work in an extracted core/package can be transported with its target and owner tests. Most protected-workflow changes remain vertical `RepoPromptApp` slices plus domain/shared edges; folder placement makes navigation better but does not make those features independently importable.

### 2. Coupling hot-spots

- **OBSERVED — counting method.** `git grep -w -l/-o <symbol> upstream/main -- Sources Packages`; tests/docs excluded. “Inbound” excludes the definition file, `MCPServerViewModel+*.swift` self-extensions, and comment/string-only matches. Counts are inbound files / identifier tokens, not call-graph edges.
- **OBSERVED — transport/runtime authority.** The candidate type name `MCPConnectionManager` is stale: there is no live declaration; the file says the NW/Bonjour manager was removed and execution now goes through `ServerNetworkManager` (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:324-327,450`). `ServerNetworkManager` has **47 / 166** inbound references across App (4 files), Features (20), and Infrastructure (23). **INFERRED:** freezing this file while callers evolve risks connection-generation, routing, admission, watchdog, provider-child, and shutdown disagreement across every protected workflow.
- **OBSERVED — window authority.** `WindowState` has **44 / 173** inbound references and `WindowStatesManager` **38 / 122**; they own per-window composition and the process-wide window registry (`App/WindowState.swift:109-116`; `App/WindowStateManager.swift:303-315`). **INFERRED:** stale versions can misroute multi-window requests, restore the wrong workspace/tab, or fail to terminate Agent/MCP children cleanly.
- **OBSERVED — MCP presentation coordinator.** `MCPServerViewModel` has **29 / 184** inbound references after excluding its nine extension files; 19 consumers are other MCP infrastructure files and eight are product features. It bridges app state to external MCP clients on `@MainActor` (`Infrastructure/MCP/ViewModels/MCPServerViewModel.swift:133-150`). **INFERRED:** signature-compatible drift can still send Context Builder, Oracle, selection, Git, or worktree tools through a stale tab/context snapshot.
- **OBSERVED — workspace file authority.** `WorkspaceFileContextStore` has **49 / 175** inbound references across Agent Mode, Context Builder, Prompt, Search, Workspaces, UI, MCP, and workspace infrastructure; it is an actor, but it remains inside `RepoPromptApp` (`Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:184-192`). **INFERRED:** freezing its readiness/path/root model can yield stale indexes, qualified-read stalls, or canonical-to-worktree path mistakes even when callers compile.
- **OBSERVED — narrower high-risk seams.** `AgentSessionLifecycleAuthority` has **6 / 38** inbound references across Agent Mode, Prompt, Workspaces, and MCP and explicitly forbids those layers from independently retargeting a live operation (`Features/AgentMode/Runtime/AgentSessionLifecycleAuthority.swift:5-17`). `MCPDomainRuntime` has 11 inbound source files; it composes workspace/context routing, mutation policy/journal, Agent sessions/worktree bindings, interaction, activity, credentials, and long-running tools (`Sources/RepoPromptDomainRuntime/RepoPromptDomainRuntime.swift:107-227`). Settlement/watchdog types have few direct callers because app aliases funnel them into one transport hot path (`MCPDomainCodeStructureSettlementRegistry.swift:3-14`; `MCPDomainToolExecutionWatchdog.swift:85-95`).

### 3. Cherry-pick experiment

- **OBSERVED — method and cleanup.** For each commit, `git format-patch -1 <sha> --stdout` produced a `/tmp` patch; `git apply --check` ran in detached `/tmp/rpce-cp-probe-v1.4.0` and `...-v1.3.0` worktrees. An independent rerun reproduced every result. Both worktrees and all patches were removed; `git worktree list` and path checks show no residue.

| Upstream fix | Shape / protected area | `v1.4.0` | `v1.3.0` | Semantic check |
| --- | --- | --- | --- | --- |
| `834b43e0` (2026-08-30), “Fix CLI single-shot selector routing (upstream PR 904)” | squash; `RepoPromptMCP` interactive routing | **conflicts/already present** at `InteractiveREPLSingleShotRoutingTests.swift:4` | **applies cleanly** | v1.3 lacks `establishStartupRouting`, `confirmedBinding`, and `requestRawJSON`, but the patch introduces their use and required implementation together; no external symbol gap observed. |
| `29477196` (2026-09-03), “Fix (MCP) - align context routing with active workspace (upstream PR 936)” | squash; `Infrastructure/MCP` binding/connection/tab routing | **applies cleanly** | **conflicts** at `MCPConnectionManager.swift:6502` | `connectionBindingSnapshot(forConnection:)` and `bindingCandidate(forContextID:)` exist in both tags; this is textual/source drift, not an absent dependency. |
| `caa8733e` (2026-09-03), “Fix: App hang due to expensive Codex model display name computation (upstream PR 941)” | squash; two `Features/AgentMode` files | **applies cleanly** | **applies cleanly** | Adds its cache/precomputation layer and uses APIs present at both tags; no absent referenced symbol found. |
| `2c4b86d0` (2026-09-05), true merge upstream PR 841, duplicate-workspace cleanup crash | merge; App/Workspaces/multi-window | required `format-patch -1` selected preceding `7f10a8b4` and **conflicted** at `ManageWorkspacesView.swift:371`; actual first-parent merge diff **applies cleanly** | same | `WorkspaceDuplicateGroupSummary` exists at both tags; added row/projection symbols are self-contained. `format-patch -1` does not faithfully serialize this merge, so merge-parent choice is part of the maintenance procedure. |

- **INFERRED — empirical verdict.** Small, self-contained fixes can cross one or two releases cleanly (upstream PR 941); source-local drift can require manual adaptation despite all dependencies existing (upstream PR 936); an already-landed patch reports as a conflict (upstream PR 904); and a merge SHA cannot be treated like a squash SHA (upstream PR 841). A clean `git apply --check` proves textual compatibility only, not protected-workflow correctness.

### 4. Feature-import feasibility

- **OBSERVED — new provider seam is only partly modular.** The provider-specific codec/DTO library is separately compiled, but a genuinely new family must choose native/headless/ACP runtime shape, add or reuse a package product, add infrastructure and Agent Mode bridges, add up to three adapters, extend provider/binding/factory/controller/model-catalog cases, keep settings/secrets in core, and add package plus app tests (`provider-plugins.md:235-272`). The concrete Grok ACP landing `157f3464` (2026-08-14, upstream PR 817) changed **69 files**: 27 Agent Mode, 15 Infrastructure/AI, five Settings, six other Infrastructure, one Context Builder, one DomainRuntime, one MCP executable, nine tests, and four fixture/doc/notification files.
- **INFERRED — provider import verdict.** Reusing an existing Claude-compatible backend can stay near the package/bridge seam. Importing a new provider family onto a frozen base is product integration, not module import: permissions, persistence identity, MCP policy, discovery/model catalogs, interactive steering, and headless launch must move as one behavioral slice.
- **OBSERVED — upstream headless seam.** `RepoPromptHeadlessAuthority` does not exist anywhere in upstream refs. Current upstream authority is the separately compiled `MCPDomainRuntime` actor, used in both `.app` and `.standalone` composition (`RepoPromptDomainRuntime.swift:107-227`; `DirectHeadlessMCPService.swift:138-208`; `AppDomainRuntimeComposition.swift:57-86`). Direct headless mode then adds canonical workspace adapters, provider/session coordination, protected mutations, private child endpoints/tokens, and worktree overlays (`headless-mcp-runtime.md:13-37`).
- **INFERRED — Fork B server import verdict.** The AppKit-free runtime is a valuable extraction seam, but the described Linux server adds a new product/manifest, SQLite Agent state, TLS/mTLS/HMAC, HTTPS portal, provider/chat authorization, packaging, and a divergent authority wrapper. Importing it onto a frozen base would require the matching DomainRuntime/Shared/MCP contracts and provider/persistence refactors; taking only a “server module” would create a second routing/security/state authority. This is a downstream product line or staged port, not a safe cherry-pick.

### 5. Semantic-conflict case study: upstream PR 472 / upstream issues 881 and 882

- **OBSERVED — upstream PR 472 exception.** No post-patch upstream commit replaced `WorkspaceSelectionCoordinator` or `MCPReadFileAutoSelectionCoordinator`. Earlier `5a714a9f` and `dadd4b06` (both 2026-07-11) had already made canonical selection/coordinator ingress authoritative. Upstream PR 908 (`dbd9eeee`, 2026-08-30) later deleted `WorkspaceSelectionCoordinatorTests`, `MCPReadFileAutoSelectionCoordinatorTests`, `PersistentAgentModeMCPReadFileConnectionTests`, `MCPReadSearchLatencyDiagnosticsGuardTests`, and `MCPCodeStructureWorktreeTests`. **INFERRED:** replaying the validated upstream PR 472 predecessor is unsafe mainly because it resurrects retired coverage and must reconcile current coordinator semantics—not because its two production authorities disappeared.
- **OBSERVED — upstream issue 881/upstream PR 898.** `08d65e43` and `9d5bb25c` (2026-07-28) had moved call lifecycle/watchdog/settlement and response-delivery ownership from app transport files into `RepoPromptDomainRuntime`. After the validated predecessor `d367edc5`, upstream PR 904 (`834b43e0`, 2026-08-30) removed the CLI export-specific timeout classifier in favor of shared timeout policy plus explicit startup routing, and upstream PR 936 (`29477196`, 2026-09-03) replaced context-only lookup with connection-aware binding snapshots. Upstream PR 908 deleted the settlement-registry and watchdog unit/integration suites while leaving production implementations. **INFERRED:** the export fix may remain valuable, but its old timeout/routing seams and proof cannot be transplanted unchanged.
- **OBSERVED — upstream issue 882/upstream PR 897.** `91ad453b` (2026-08-28) changed Agent/Prompt projection-removal callbacks; `5b35b388` (2026-08-30), `ef28b5f6` (2026-08-31), and `08bc7829` (2026-09-02) moved duplicate-workspace persistence/retirement through domain authority, revision/digest checks, and lifecycle validation in `WorkspaceManagerViewModel` and `DomainWorkspaceContextAuthority`. Upstream PR 908 deleted `BackgroundComposeTabAdmissionTests` and `AgentRunWorkspaceAuthorityAdmissionTests`. **INFERRED:** the old transactional admission patch targets superseded persistence/projection assumptions; it needs a new domain-authority-aware implementation and narrow recreated coverage.
- **OBSERVED — correction to the aggregate claim.** “Replaced authorities and deleted tests” is supported for the upstream issues 881 and 882 predecessor seams. For upstream PR 472, only the deleted-test/reconciliation half is supported by history.

### 6. Documentation and ownership

- **OBSERVED — architecture file dates at upstream tip.** `apple-identity-migration.md` 2026-09-01 (`5bc82b7f`); `codex-app-server-schema-gate.md` 2026-08-22 (`44774ffa`); `context-composer.md`, `settings-persistence.md`, `source-layout.md`, and `xcode-workspace.md` 2026-08-30 (`dbd9eeee`); `headless-mcp-runtime.md` 2026-08-14 (`4a41876e`); `provider-plugins.md` 2026-08-14 (`157f3464`).
- **OBSERVED — spec file dates at upstream tip.** M0 contracts/baseline, M3 evidence/read-discovery: 2026-08-30 (`dbd9eeee`); M2 context authority: 2026-08-02 (`205d9787`); M4 protected mutations: 2026-08-01 (`08dbfe6d`); M5 AI/Agent: 2026-08-12 (`0b4d738a`); M6 host extraction and M7 cutover: 2026-07-28 (`d0ff54b1`, `b267d745`); `history-query-tools.md`: 2026-07-28 (`eeaa3a24`); canonical tool-definition JSON: 2026-08-13 (`0d3b1f92`).
- **OBSERVED — ownership coverage.** There is no ADR directory/file. `source-layout.md` is a placement/ownership map; headless specs document `MCPServerViewModel` and `WorkspaceManagerViewModel`; provider/M5 docs mention `AgentModeViewModel`; M4 names the old `MCPConnectionManager` seam. There is no dedicated current authority/call-flow document for `ServerNetworkManager`, `WorkspaceFileContextStore`, or the interactions among the four hottest files.
- **INFERRED — documentation verdict.** Documentation is adequate for “where code belongs” and the extracted headless/provider contracts, but inadequate for safely predicting the behavioral blast radius of protected-workflow changes. The stale manager name and mostly unenforced M0 fixture make commit archaeology and executable acceptance evidence necessary.

### Maintainer-guidance check

- **OBSERVED — user impact/invariant and authority.** Exact workspace/tab/session/provider identity must survive routing, cancellation, persistence, and shutdown; domain identity belongs to `MCPDomainRuntime`, window presentation to `WindowState`/`MCPServerViewModel`, and file readiness/path state to `WorkspaceFileContextStore`.
- **OBSERVED — root-cause confidence.** Compiler boundaries, inbound counts, authority replacements, deleted tests, and textual patch behavior are confirmed; complete feature-port cost and latent runtime compatibility remain reasoned inferences.
- **INFERRED — state/scale/observability risk.** A stale authority can compile while silently misrouting or mis-settling work; high upstream churn multiplies that risk where tests were deleted.
- **INFERRED — recommended scope and validation boundary.** Import leaf/core fixes individually; treat protected changes as complete vertical slices and validate both app-backed and direct-headless paths plus real provider/client routing before promotion.

### So what for a downstream fork
- **OBSERVED:** The repository has real compiler-enforced cores, but most protected workflows remain coupled inside `RepoPromptApp`.
- **OBSERVED:** Cherry-picks range from clean across two releases to textual conflicts with no missing dependency; merge commits require explicit parent semantics.
- **INFERRED:** A clean patch is a triage signal, not release evidence, because routing, state, and cancellation contracts cross folders and targets.
- **INFERRED:** New providers and the community Linux server are product-integration programs, not drop-in modules for a frozen base.
- **OBSERVED:** Upstream authority replacement plus upstream PR 908 test deletion makes old validated patch stacks semantically stale; upstream PR 472 is the deleted-test exception, not a replaced-authority case.
- **INFERRED:** The safest downstream model is selective leaf cherry-picks plus complete, freshly adapted vertical slices for MCP, Agent Mode, and workspace/worktree changes.

## Investigation Log

### Phase 1.5 — External fact-gathering (4 explore probes, 2026-09-05)
**Hypothesis:** MP's characterization (hard-to-stabilize app, heavy fork cost) needs independent grounding in git history, the ledger, upstream governance, and packaging.
**Findings:** See `## Background / Prior Research` (four sub-sections). Key: upstream is young/hot (1,253 commits in 12 weeks; two maintainers = 79% of traffic; zero reverts ever; 72 fix-on-fix chains in 8 weeks); MP's patches sit on upstream's four hottest source files; textual cherry-pick conflicts were trivial across six rebuilds but semantic conflicts (replaced authorities, deleted tests via upstream PR 908) forced patch exclusion; ~40–50% of fork effort is gate/process overhead; a paid Apple account would NOT fix the debug secrets-reset (team-ID hard-coded to upstream) but a free self-signed local production lane already exists; upstream already runs a Tip channel; the only fork visibly staying current while carrying patches (Fork D) merges upstream every 1–2 days with a tiny patch set; the one large-divergence fork (Fork B, the server) failed to upstream and has drifted 110 behind.
**Conclusion:** Confirmed — MP's characterization is directionally right, but the cost driver is process + semantic drift on hot authorities, not Git mechanics.

### Phase 2 — context_builder (one chat, 32 files / ~122k tokens)
**Hypothesis:** Coupling concentrates in a few shared authorities such that protected-workflow fixes are vertical slices, not folder-local changes.
**Findings (oracle initial assessment):** Genuine compiler-enforced seams: `RepoPromptDomainRuntime` target (AppKit-free MCP/runtime/routing/persistence authority), `RepoPromptShared/MCP` (`MCPControlMessages` — real cross-process wire contract with no version negotiation), canonical tool catalog/definitions with fingerprints (strong inside one runtime only), `Packages/RepoPromptAgentProviders` Claude-compatible package + two bridges, pure core targets (CodeMap/Regex/WorkspaceCore). Directories inside `RepoPromptApp` (Features/AgentMode, ContextBuilder, Workspaces; Infrastructure/MCP, WorkspaceContext, AI, Persistence; App) are ownership labels, not enforced boundaries. Agent Mode aligns four identities (workspace, tab/context, session+binding generation, provider/MCP connection generation) via `AgentSessionLifecycleAuthority`; routing via `MCPBindingResolver`/`DomainRoutingCoordinator` collapses contexts by tab + normalized root set and fails closed on ambiguity. Persistence: settings and presets fail closed on future schema; workspace/Agent-session/window-session state has no universal safe-downgrade contract, so rollback unit = app bundle + matching state snapshot. Debug and production share one Application Support root. Verdict: adopt leaf fixes independently; adopt protected-runtime changes only as complete behavioral slices (fix + shared types + registrations + schema + tests + both app-backed and direct/headless acceptance); treat large selective features as downstream product development.
**Evidence limitation:** the largest coordinators (`MCPConnectionManager`, `MCPServerViewModel`, `AgentModeViewModel`, `WorkspaceFileContextStore`, `WorkspaceManagerViewModel`) were seen as codemaps/signatures only because the window's structure provider was fenced.
**Conclusion:** Confirmed at signature level; pair investigators asked to verify with reference counts and an empirical cherry-pick experiment.

### Phase 3 — Two pair investigators (disjoint scopes)
**Hypotheses:** (A) coupling makes protected-workflow cherry-picks brittle; (B) the repo lacks a packaged end-to-end regression net and a rollback story adequate for a personal release train.
**Findings:** See the two `## Investigator Findings: …` sub-sections. Orchestrator spot-checks: scratch worktrees removed (`git worktree list` clean); upstream PR 908 = `dbd9eeee` 2026-08-30 (confirmed); `v1.4.0` is the newest tag (confirmed). Empirical cherry-pick matrix: 4 upstream fixes × {v1.4.0, v1.3.0} → 2 clean, 1 textual conflict with no missing dependency (upstream PR 936 on v1.3.0), 1 already-present conflict (upstream PR 904 on v1.4.0), and one true-merge that `format-patch -1` mis-serializes (upstream PR 841). Inbound-reference counts: `ServerNetworkManager` 47 files, `WorkspaceFileContextStore` 49, `WindowState` 44, `WindowStatesManager` 38, `MCPServerViewModel` 29 — all inside one compiled target. Grok ACP provider landing (upstream PR 817) touched 69 files. 443 XCTest suites / 4,779 methods but no test drives the packaged app with a real provider; existing smoke covers packaging + one MCP round-trip only. Downgrade safety is mixed (settings/presets fail closed; workspace/Agent-session/window-session state does not). `test-suite-contract-ledger.tsv` was deleted upstream on 2026-08-02 (`205d9787`) — the historical conflict magnet no longer exists.
**Correction to prior claim:** "upstream PR 472 excluded because upstream replaced its authorities" is only half-supported — for upstream PR 472 it was the deleted-tests half (upstream PR 908); authority replacement is confirmed for upstream issue 881 (`08d65e43`, `9d5bb25c`, upstream PRs 904 and 936) and upstream issue 882 (`91ad453b`, `5b35b388`, `ef28b5f6`, `08bc7829`).
**Conclusion:** Both hypotheses confirmed with file:line and sha evidence.

### Phase 4 — Oracle synthesis (the same chat, selection refreshed with pair-surfaced files/slices)
**Hypothesis:** the draft hybrid (Tip-aligned RC train + short stack + self-signed install + process diet) survives a stress test.
**Findings:** Five repairs: (1) patch *count* is a weak proxy — bound by authority cluster (≤5 behavioral, ≤2 protected-authority); (2) soak is a candidate filter, promotion still needs the full packaged matrix; (3) the self-signed installer protects only the install transaction and deletes its backup after success (spot-checked: `install_local_production.sh` moves the old app to a temp backup then `rm -rf`s it) → rollback unit is app + stopped-state snapshot; (4) `stable` cannot be fast-forward-only and `--no-ff` promotion merges create untested commits → immutable annotated tags are the release authority; (5) official Tip and the personal build cannot coexist in one macOS account (same bundle id, same App Support root — spot-checked hard-coded at `AppDomainRuntimeComposition.swift:62,82`, `WindowStateManager.swift:130`). Soak rule chosen: successful Tip + ≥7 days + no later fix in the same authority cluster (14 days for settlement/Codex/provider-lifecycle/persistence). Exit criteria and burden trajectory folded into Recommendations.
**Conclusion:** Draft repaired and adopted as the recommendation.

## Root Cause / Assessment

### Is MP's characterization right? (observed vs inferred)
- **OBSERVED — the app is structurally hard to stabilize.** Eight directories that own the protected workflows (`Features/AgentMode`, `Features/ContextBuilder`, `Features/Workspaces`, `Infrastructure/MCP`, `Infrastructure/WorkspaceContext`, `Infrastructure/AI`, `Infrastructure/Persistence`, `App`) are folders inside one compiled target, `RepoPromptApp` (`Package.swift:170-174`). The shared authorities have dense fan-in inside that target: `WorkspaceFileContextStore` 49 inbound files, `ServerNetworkManager` 47, `WindowState` 44, `WindowStatesManager` 38, `MCPServerViewModel` 29. Agent Mode must keep four identities aligned (workspace, tab/context, session+binding generation, provider/MCP connection generation — `AgentSessionLifecycleAuthority.swift:5-17`). A one-line change can compile and still misroute, mis-settle, or leak a provider process.
- **OBSERVED — upstream's behavior amplifies it.** 1,253 commits in 12 weeks; two maintainers author 79%; **zero reverts in 1,589 commits**; 40% of commits are fix-shaped; 72 fix-on-fix pairs in 8 weeks, densest in MCP settlement and Codex runtime. Upstream PR 908 (`dbd9eeee`, 2026-08-30) deleted whole test suites while leaving the production code — coverage MP's fixes relied on. Documentation says where code belongs (`source-layout.md`) but there is no ADR set or call-flow doc for the four hottest files, and one architecture doc still names a manager (`MCPConnectionManager`) that no longer exists as a type.
- **OBSERVED — MP's patches sit on the hottest files.** `feature/local-rp-stability-stack` modifies `MCPConnectionManager.swift` (50 upstream commits in 8 weeks), `AgentModeViewModel.swift` (46), `MCPServerViewModel.swift` (43), `WorkspaceManagerViewModel.swift` (30), `WorkspaceFileContextStore.swift` (23).
- **INFERRED — but the dominant cost is not Git and not the app; it is process and semantic drift.** Across six stability rebuilds the only textual conflict was a since-deleted generated TSV. What forced patch exclusion in the 2026-09-05 RC was semantic: upstream replaced the seams upstream issues 881 and 882 modified (`08d65e43`, `9d5bb25c`, upstream PRs 904 and 936; `91ad453b`, `5b35b388`, `ef28b5f6`, `08bc7829`) and deleted upstream PR 472's tests. The ledger's own content share puts ~40–50% of effort into the VERIFY→REVIEW→REFACTOR→preflight→packaged-acceptance chain (with frequent verdict-less REVIEW reruns), ~30–35% into diagnostics/test scaffolding, ~20–25% into behavioral fixes.
- **OBSERVED — the debug-build "settings reset" is narrower than described and unrelated to a paid account.** Only Keychain-backed secrets (provider API keys, agent permission grants) reset, because ad-hoc debug packaging stamps `debug-adhoc` → ephemeral storage (`package_app.sh:222`, `RuntimeCodeSigningPolicy.swift:244-245`). The only debug path to a real Keychain also requires upstream's Team ID `648A27MST5` (`RuntimeCodeSigningPolicy.swift:246-261`), so MP's own Apple team would fail it too. The repo already ships a free self-signed **local production** lane with full Keychain persistence (`docs/releasing.md:404-478`, `make dev-install-local-production`), at the cost of replacing `/Applications/RepoPrompt CE.app`.

### Answers to MP's twelve questions
1. **Durable personal fork sensible?** Yes, as a *release train* (short-lived RCs off soaked upstream baselines), not as a long-lived divergent branch. Today's posture (Option 1) is already the right family; it is over-gated and under-instrumented, not wrong.
2. **Best balance?** Option 6 (repaired hybrid, below). Option 1 as practiced is a close second with the same mechanics but heavier process. Options 2/3 shift cost into diagnosis; Option 4 is a product line; Option 5 has no security feed to consume.
3. **Import features/modules without intervening changes?** Only for leaf units: the pure cores (`RepoPromptWorkspaceCore`, `RepoPromptRegexCore`, `RepoPromptCodeMapCore`), package-internal codec/DTO work in `Packages/RepoPromptAgentProviders`, UI-only or docs/tests-only changes. Not for anything in the protected workflows; a new provider (upstream PR 817) touched 69 files; the community Linux server is product-line scale.
4. **When does cherry-picking work / not?** Works: small self-contained fixes crossing 1–2 releases (upstream PR 941 applied cleanly to both `v1.4.0` and `v1.3.0`). Breaks: (a) source drift with no missing dependency (upstream PR 936 conflicts on `v1.3.0` although every symbol exists — manual adaptation), (b) hidden authority replacement (upstream issues 881 and 882 predecessors compile-adjacent but semantically stale), (c) true-merge PRs whose `format-patch -1` silently picks the wrong parent (upstream PR 841), (d) mixed squash/merge history so neither SHA nor patch-id tracking alone tells you what has landed. A clean `git apply --check` is triage, not evidence.
5. **Permanent commit-graph divergence?** Only if the fork accumulates. The disposable-RC model keeps the graph *reconvergent*: each RC descends from current upstream; carried patches are re-adapted, not merged forward. Reconciliation cost then equals the size of the patch stack, not the age of the fork. Bulk-merge or cherry-pick forks (Option 2/3) diverge permanently and reconciliation cost grows with every skipped upstream authority change.
6. **Modular enough for module imports?** Compiler-enforced seams exist and are real: `RepoPromptDomainRuntime` (AppKit-free MCP/runtime/routing/persistence), `RepoPromptShared/MCP` (app↔helper wire contract — unversioned), canonical tool catalog with fingerprints (strong inside one runtime only), the Claude-compatible provider package. Everything the protected workflows need crosses those seams *and* the dense `RepoPromptApp` graph, so module-level import is safe only for leaf/core units.
7. **How to evaluate upstream changes?** Path-triaged risk classes (Leaf / Shared-integration / Release-critical) with the acceptance gate scaled to the class, plus an authority-scoped quiet period before a commit is baseline-eligible. Details in Recommendation 4.
8. **Release-train model?** Yes — see Recommendation 3. Frozen production = the promoted, immutably tagged RC installed via the self-signed lane; upstream-integration = disposable `release/rc-<date>`; diagnostics = fork-only commits transported into each RC; staged RC = the packaged acceptance matrix.
9. **Downstream-only vs upstream?** Downstream-only: MCP phase-attribution diagnostics, personal defaults/preferences, any future personal-flavor identity patch. Upstream-bound: every liveness/protocol/persistence/routing fix (selection-mirror, qualified reads, export watchdog, same-workspace admission, app-quit teardown, selection watchdog, cancellable reads) — submitted as the *smallest source delta plus its regression test*; the +3.8k to +11k-line PRs stall, the +221 to +1.5k ones merge in ~5 days.
10. **Tests/acceptance/rollback needed?** The existing 443-suite net plus: a packaged acceptance matrix from both clients (Recommendation 4, commands in `## Investigator Findings: verification…` §2), an N→N-1 state replay check whenever a persistence path changes, and a per-release archive of signed bundle + provenance + manifest + stopped-state snapshot of `~/Library/Application Support/RepoPrompt CE` + `defaults export` + signing registry (never secrets). The installer only protects the *installation* transaction; it deletes the prior app after success (`install_local_production.sh` ~ lines 349-353).
11. **Burden?** 6 months: 10–30 h/month if the stack shrinks as patches land upstream (vs 20–40 today). 1 year: 8–25 h/month if the stack stays ≤5 behavioral patches; otherwise back to 20–40 and rising. 3 years: either back on upstream binaries or an unsustainable halfway fork — the model is designed to force that choice. Freeze: 3–12 h/month routine but 15–30 h incident months and no security feed; external drift (Claude Code CLI behavior, pinned Codex `0.149.0` app-server schema, macOS signing/Keychain/socket changes) eventually forces a large jump.
12. **Stop conditions?** Recommendation 7 (exit criteria) — evaluated every three refreshes or 90 days.


## Recommendations

### 1. Executive recommendation
Adopt the **repaired Option 6 hybrid — a Tip-aligned personal release train — for a three-refresh trial (~6–9 weeks).** Keep contributing small behavioral fixes upstream (it works: 27 commits merged, ~5-day median for small PRs). Do **not** buy an Apple Developer account for this; use the repo's self-signed local production lane instead. Do **not** create a separate personal product identity or run upstream Tip beside the personal build in the same macOS account. Cut the process weight on leaf changes and spend the savings on the one thing missing today: a packaged, real-client, real-provider acceptance matrix.

### 2. Strategy comparison

| Strategy | Stability of daily workflows | Access to upstream improvements | Maintenance cost (est. h/month) | Regression risk profile | Divergence / reconciliation | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1. Track upstream + short-lived stability stack (current) | Medium — good when the stack is promoted promptly; outages when a patch is dropped (07-20/07-22 incident) | High | 20–40 | Continuous small interruptions; semantic-stale patches every 1–2 weeks | Reconvergent (RC rebuilt from upstream) | Right family; over-gated |
| 2. Long-lived fork, merge all upstream monthly | Medium-low — one big correlated debug tail per merge | High but batched | 20–50, high variance | Large, correlated; hard to attribute | Permanent; grows with each skipped authority change | Reject |
| 3. Cherry-pick individual commits/PRs | Low-medium — omission risk from roll-forward fixes and mixed squash/merge history | Selective | 25–55 | Dependency archaeology; "clean apply" is misleading | Permanent; reconciliation cost compounds | Reject as the *default*; allowed for leaf units only |
| 4. Import selected features by manual adaptation | Depends entirely on MP owning integration architecture | Low | 30–60 + incidents | Owns migrations, security, provider drift | Effectively a separate product | Only if a real product need appears (e.g., Linux server) |
| 5. Freeze on `v1.4.0`, security/critical only | High short-term; brittle to external drift | None | 3–12 routine; 15–30 incident months | No security feed exists (`SECURITY.md` has no supported-version policy); forced jump when Claude CLI / Codex / macOS move | None until the forced jump, then very large | Viable only as abandonment-with-break-glass |
| **6. Tip-aligned release train (repaired hybrid)** | **High** — promotion gated on packaged acceptance from both clients; app+state rollback <10 min | **High** — soaked Tip baselines every 2–3 weeks | **10–30 falling toward 8–25** as patches land upstream | Bounded: ≤5 behavioral / ≤2 protected-authority patches; class-scaled gates | **Reconvergent by construction**; immutable tags as release authority | **Recommend** |

### 3. Branch and release model

```text
upstream/main            read-only mirror (fetch only)
bugfix/<issue>           contribution branches, cut from upstream/main, never from an RC
feature/local-rp-diagnostics-<baseline>   fork-only diagnostics, fresh branch per baseline (no repeated rebase of a published branch)
release/rc-YYYYMMDD      disposable RC: soaked upstream commit + adapted patch stack; rebuilt every refresh, never merged forward
mp/<date>-upstream-<sha8>.r<n>   annotated immutable tag on the exact tested RC commit = the release authority
stable                   optional deployment pointer only; moved to the tag with guarded --force-with-lease; never built from
```

- **No fast-forward-only `stable` and no `--no-ff` promotion merges.** Each RC descends from a newer upstream baseline, so it cannot fast-forward from the previous RC; a promotion merge would create a commit nobody tested. Auditability comes from the tag + archived bundle + manifest + acceptance receipt.
- **Hotfix flow:** `promoted tag → bugfix/local-<issue> → emergency RC → new tag`; in parallel port the fix onto a `bugfix/*` from `upstream/main` for contribution. Never merge the emergency RC into the next ordinary RC.
- **Runtime posture:** one active app per macOS account — the promoted RC installed via `CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production` (production bundle id, own self-signed cert, persistent Keychain). The ad-hoc debug bundle stays a *developer* tool for reproducing defects, not a second daily app; it shares the Application Support root and has no downgrade fence.
- **Rollback unit = app + state.** Per release archive under a directory outside the shared state tree: `ditto` zip of the signed `.app` + SHA-256; artifact manifest; provenance sidecar (commit, dirty=false, acceptance receipt); copy of `local-signing-identity-v1.json`; app-stopped snapshot of `~/Library/Application Support/RepoPrompt CE`, custom workspace-storage roots, and `defaults export com.pvncher.repoprompt.ce`. Never archive provider secrets or signing private keys. Rehearse one restore before trusting the <10-minute RTO.

### 4. Absorbing upstream fixes and features

**Baseline eligibility (soak as a *filter*, not a gate):** an upstream commit is eligible when (a) it shipped as a successful Tip build, (b) it is ≥7 days old, (c) no later fix-shaped commit touched the same protected authority cluster since, (d) no open upstream regression touches MP's workflows, and (e) changes to MCP settlement/watchdog, bundled Codex, provider lifecycle, or persisted formats get 14 days instead of 7. A later fix in the same cluster resets that cluster's clock. Reject "no successor Tip for N days" as a signal — it usually means CI or rollout is stalled, not that the build settled.

**Patch-stack limits:** ≤5 behavioral patches AND ≤2 touching protected authority clusters (routing, settlement/watchdog, Agent lifecycle, workspace identity, persistence, wire protocol). Each carried patch has a one-paragraph manifest: owning authority; durable/wire formats touched; app vs direct-headless paths; upstream PR or fork-only rationale; required acceptance arms. Exceeding either limit two refreshes running triggers the exit-criteria review.

**Risk classes and gates (path-triaged, machine-checkable from `git diff --name-only`):**

| Class | Trigger paths | Gate |
| --- | --- | --- |
| Leaf | docs/assets (excluding releasing/architecture/acceptance docs); test-only additions without production deletion; pure cores; UI copy; package-internal codec | Owner tests + guardrails + one focused review. No REFACTOR gate, no Context Builder REVIEW. |
| Shared integration | provider bridges, workspace lookup, Context Builder snapshot, isolated UI/parser changes | Focused integration tests + the affected packaged arms. |
| Release-critical | `Sources/RepoPrompt/{Infrastructure/MCP,Infrastructure/WorkspaceContext,Infrastructure/AI,Features/ContextBuilder,Features/AgentMode,Features/Workspaces,App}/**`; `Sources/RepoPromptShared/MCP/MCPControlMessages.swift`; `Infrastructure/Persistence/**`, `WorkspaceModel.swift`, `WindowStateManager.swift`, session stores; `Package.swift`, `Package.resolved`, `Vendor/Codex/manifest.json`, `Scripts/{package_app,install_local_production,conductor,smoke_packaged_mcp_roundtrip}*`, `AppBundle/**`, entitlements | Full tests + independent review + the complete packaged acceptance matrix; N→N-1 state replay and pre-install snapshot when persistence paths change; real Codex canary when the Codex pin (`0.149.0` today; changed 3× in 8 weeks) moves. |
| Stale-patch warning | a carried patch touches the deleted `Scripts/Fixtures/test-suite-contract-ledger.tsv` | Re-adapt to dynamic test discovery; never resurrect the ledger. |

**Per-refresh procedure (target ≤3 h mechanical, once per RC):**
1. `git fetch upstream`; pick the eligible baseline; final scan of protected-path commits since the previous RC (a fix-on-fix chain that is still open in your cluster = wait).
2. Diff upstream against the patch manifest: drop patches now upstream (match by subject/content, not SHA — ~66% of landings are squashes), mark patches whose authority moved as "re-adapt".
3. Build `release/rc-<date>` = baseline + fork-only diagnostics + re-adapted patches. Cherry-pick only leaf units; re-implement protected changes against the current authorities (this is where an engineer agent earns its keep).
4. Package once; run the acceptance matrix once on the assembled RC from **both** Claude Code and Codex (commands in `## Investigator Findings: verification & release-train feasibility` §2): packaged smoke → two-window selection isolation → `context_builder` → `oracle_send` → Codex `agent_run` → Claude `agent_run` + `steer` → worktree-bound child → `list_sessions` provenance → stop/relaunch teardown check.
5. Tag, archive (app + state snapshot), install via the self-signed lane, run one post-install canary, record the receipt.
6. Ledger: one row per RC — baseline sha, patch manifest hashes, acceptance receipt, archive path/checksum, retirement condition.

**Features:** treat anything beyond a leaf unit as a downstream *port*, not an import — estimate it by the vertical slice (the Grok ACP provider was 69 files across 7 areas). Only start such a port if the exit criteria have already pointed to permanent divergence.

### 5. Principal risks

**Technical**
- **Silent semantic staleness of carried patches.** Upstream replaces authorities without reverting; a stale patch compiles and misroutes/mis-settles. Mitigation: per-patch authority manifest + the class-C gate; treat "textual conflict" and "clean apply" as equally uninformative.
- **Mixed-version shared state.** Debug and production share `~/Library/Application Support/RepoPrompt CE`; workspace/Agent-session/window-session stores have no downgrade fence. Mitigation: one active app; snapshot before every install; N→N-1 replay when persistence paths change.
- **Roll-forward regressions in the baseline itself.** Tip publication proves CI + one `windows` round-trip only. Mitigation: authority-scoped soak + the full packaged matrix on every RC.
- **External drift that a frozen or lagging build cannot avoid:** Claude Code CLI behavior (flags, permission prompts, session identifiers, NDJSON events), Codex app-server schema (`Vendor/Codex/manifest.json` pin), macOS signing/Keychain/socket changes, MCP SDK changes. Mitigation: never fall more than ~3 refreshes behind Tip; keep the Codex-pin change as an automatic class-C trigger.
- **Unversioned wire contract.** `MCPControlMessages` enums/payloads have no version negotiation; a stale helper or client can fail as a timeout or process leak rather than a protocol error. Mitigation: always ship app + embedded helper from the same RC; run the acceptance matrix from real clients.
- **Structure-settlement/ provider-teardown defects still open** (reproduced during this very session: the orchestrator window was fenced for hours). Mitigation: these stay upstream-bound; the fork carries them only until merged.

**Organizational**
- **Bus factor of two upstream** (79% of commits); large PRs stall with no re-review; contributor account cannot label issues or rerun CI. Mitigation: keep PRs ≤~1.5k lines with a regression test; split scaffolding from behavior; track merge latency as an exit signal.
- **Process gravity.** The current gate chain consumes ~40–50% of effort and produces verdict-less reruns. Mitigation: class-scaled gates; REFACTOR and Context Builder REVIEW only for class-B/C changes.
- **Debug-tooling tax.** Ad-hoc debug builds reset secrets/permissions every relaunch (observed again today as repeated approval prompts on every agent probe). Mitigation: use the self-signed production lane for daily use; keep debug builds for reproduction only.
- **Scope creep toward a product line.** The community Linux server and Rust-ACP forks are attractive and unlanded. Mitigation: the exit criteria decide, not enthusiasm.

### 6. Staged adoption plan (reversible at every step)

| Stage | What | Done when | Reversible? |
| --- | --- | --- | --- |
| 0. Instrument (week 1) | Write the patch manifest for the current 19-commit stack; script the acceptance matrix as a runnable checklist; script the archive/snapshot + restore; rehearse one restore | Restore rehearsal passes; manifest classifies every carried patch | Nothing changed yet |
| 1. First RC on the current machine (weeks 1–2) | Baseline = soaked Tip; rebuild RC; run matrix from both clients; install via self-signed lane as the daily app; keep the debug bundle for reproduction only | Daily work runs on the promoted build for 7 days without a fork-caused outage | Restore archive → previous app/state in <10 min |
| 2. Second and third RC (weeks 3–9) | Repeat the per-refresh procedure; drop patches as they land upstream; record hours, adaptation count, acceptance failures | Three receipts in the ledger | Same |
| 3. Decision (week ~9) | Apply the exit criteria below | One of: return to upstream Tip; continue the train another 3 refreshes; commit to a downstream product | — |

Guardrails during the trial: no personal-flavor identity patch; no second daily app; no feature ports; no `stable` builds from a mutable pointer.

### 7. Exit criteria (evaluate every three refreshes or 90 days)

**Return to official upstream Tip/stable when all hold:**
- Three consecutive official Tip builds over ≥30 days pass the full protected-workflow matrix with zero downstream source changes.
- The stack has zero upstream-bound behavioral patches (≤2 fork-only diagnostics/preferences allowed).
- <10% of adopted upstream fixes needed semantic adaptation during the window.
- MP's small PRs keep a ≤7-day median merge time with none stalled >30 days.
- ≥3 distinct people reviewed or merged protected-path work upstream in the last 90 days.

**Commit to a permanently divergent downstream when BOTH a product need and the evidence hold:**
- Product need: a durable behavior upstream will not accept (separate identity, server operation, different persistence/provider architecture).
- Evidence (any two): >5 behavioral or >2 protected-authority patches persist through three refreshes; ≥40% of carried patches need reimplementation per refresh; two of three refreshes expose an upstream-caused protected acceptance failure; small-PR median latency >30 days or >50% unresolved after 45 days; <2 active protected-path maintainers for 60 days.
- MP accepts ~30–60 h/month plus incident spikes and ownership of migrations, provider drift, and security monitoring.

**Freeze instead** if upstream activity collapses *and* no product need exists: cheaper than a product line, with the forced-jump risk stated above.


## Preventive Measures
- Make the acceptance matrix and the archive/restore scripts first-class repo tooling (or Toolkit tooling) so every RC is gated the same way without re-deriving the checklist.
- Keep contributions small and split: behavior + its regression test in one PR; diagnostics and broad scaffolding separately or downstream.
- Record per-RC receipts (baseline sha, patch manifest hashes, acceptance results, archive checksum, hours) in the ledger so the exit criteria are computed from data, not memory.
- Treat a Codex-pin bump, a `MCPControlMessages` change, a persistence-store change, or a `Package.swift` change as automatic class-C triggers regardless of diff size.
- Never adopt a "clean cherry-pick" as evidence; adopt a passed acceptance receipt.
- Log each recurrence of the structure-settlement fence and provider-teardown leak against the open upstream issues; they are the fork's reason to exist and its retirement condition.
