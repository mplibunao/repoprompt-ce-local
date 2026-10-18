# Investigation: Ongoing Codex-agent / context_builder complaints — post-fix triage

> Investigation report, observed 2026-07-12 on a debug build of the local patch branch. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/testing.md](../testing.md), Debug CLI and live MCP smoke.

Date: 2026-07-12
Status: complete

## Summary
The complaints are real and are **four co-occurring RepoPrompt CE defects — not an upstream Codex CLI problem** (codex-cli 0.144.1 exonerated again: all dispatch probes completed turns). Live today, on a host app that already contains the upstream PR 450 + upstream PR 472 + `1ab555e6` fixes: (1) **orchestrator MCP bridges crash** — every Claude Code session's `RepoPromptCE` config resolves to the UNFIXED release 1.0.27 `repoprompt-mcp` in /Applications, which SIGABRTed 25× today ("Connection closed"); (2) **the selection-mutation wedge persists despite upstream PR 472** — the mutating path has a second, unbounded await (`MCPSelectionToolProvider.swift:177` → `awaitAppliedIngress(rootScope:)`) that upstream PR 472 never touched; upstream PR 520 is the intended fix; (3) **`context_builder` typed runs fail structurally** — MCP `instructions` are never written to `tab.promptText`, so typed runs with an empty tab prompt trip the `usedAgentOutputAsPrompt` gate (`MCPContextBuilderToolProvider.swift:665`), a distinct unfiled defect — and failed/superseded runs keep leaking `claude -p` discovery children (7→10 today, Fault B); (4) **upstream issue 514 child MCP provisioning is intermittent** (1 of 3 probe children lacked RP tools). The "only Codex, not cloud" perception: Codex-backed explore/engineer children are the ones making RP tool calls that hit the wedge/bridge, and upstream issue 514 only affects children — Claude pair/design sessions do the same work without tripping the broken surfaces as visibly.

## Symptoms
- Orchestrators report Codex-backed agents/context_builder "erroring, stalling, or hanging" (second-hand; not directly observed by user).
- Orchestrators apply workarounds — e.g., substituting the Claude-backed `design` role when an `engineer` (Codex) dispatch fails (recorded 2026-07-12 in a work-repository window).
- Cloud (Claude) models unaffected — implicates the Codex CLI/app-server path.
- LIVE (this session): two consecutive `file_actions create` calls failed with `MCP error -32000: Connection closed`; reads (`git status`) worked immediately after. Write-path-skewed bridge failure, matches defect class 3 (+ possibly Fault C selection auto-select on create).

## Known prior defect classes (from earlier investigations in this folder)
1. **Upstream issue 449 / upstream PR 450** — `textElements` camelCase key suppresses `turn/completed` on codex app-server ⇒ indefinite "Thinking…" hang. Fixed locally on the local patch branch; upstream status to re-verify.
2. **App-server startup stalls** — pre-`1ab555e6` builds: interactive fish login-shell env capture + blocking memoryMode call ⇒ "Codex app-server process is not running" on start/resume. Fixed by upstream `1ab555e6` (in local base).
3. **`repoprompt-mcp` bridge SIGABRT** (upstream issue 513, superseded by upstream PR 517) — retry-backoff sleep frame dealloc crash ⇒ intermittent "Connection closed". Fixed locally by a backoff patch.
4. **Silent child MCP provisioning failure** (upstream issue 514) — Codex children can start without `mcp__RepoPromptCE__*` tools; stop-don't-substitute rule turns this into hard refusals.
5. **Context Builder faults A/B/C** (07-09 doc; upstream issue 457/upstream PR 472 covers the wedge) — missingFinalContext drop on non-orderly close, leaked discovery children, selection-mirror head-of-line wedge. Upstream PR 472 rebased+pushed; A/B unfiled(?) — re-verify.

## Open questions this triage must answer
- Q1: Is the currently running debug app built from the local patch branch (with the backoff patch, the 00:04 UTC package), or still the older build? ("relaunch pending" at end of 07-12 doc)
- Q2: Do Codex explore/engineer dispatches work right now (start, complete, and receive `mcp__RepoPromptCE__*` tools)?
- Q3: What are the 5 upstream commits the local patch branch is behind — did upstream PR 450 and/or upstream PR 517 merge (drop-triggers for local cherry-picks)?
- Q4: Which complaints post-date the relaunch (if it happened)? Are they residual classes (upstream issue 514, CB Faults A/B) rather than the fixed ones?
- Q5: Any new crash reports since 07-11 00:52 UTC? Which binary serves THIS session's MCP bridge (release vs debug vs mp-patches)?

## Background / Prior Research

### Phase 1.5 findings (explore probes + orchestrator checks, 2026-07-12)

**Q1 — running build (ANSWERED): the relaunch DID happen at 23:32 UTC on 07-11, but for the 4-commit stack; the 5-commit repackage (00:04 UTC on 07-12) has never been launched.**
- Only ONE app instance running: the debug app, started 2026-07-11 23:32:41 UTC by a conductor run job (packaged 23:32:09 UTC from the then-4-commit local patch branch). No release app process.
- Running app therefore CONTAINS: upstream PR 450 text_elements fix, 3x upstream PR 472 wedge-fix commits, upstream `1ab555e6` startup fix. MISSING: the backoff patch (upstream issue 513 bridge backoff fix — but that only matters for the embedded helper binary).
- On-disk DebugApps bundle = the 00:04:24 UTC package (1.0.28/29, post-2bc5179c). Running process predates it (loaded the image staged at 23:32 UTC).

**Q2 — live Codex dispatch (ANSWERED): dispatch + turn completion WORK; provisioning inconsistent; in-child RP tool calls can time out.**
- Smoke probe: completed, listed 9 mcp__RepoPromptCE__* tools, BUT its read_file call timed out → shell fallback. Ended CODEX_PROVISIONING_SMOKE_OK.
- Inventory probe: RP MCP tools UNAVAILABLE in its session (defect upstream issue 514 live, intermittent per-child).
- GitHub probe: RP MCP tools available. → 2/3 children provisioned; 1/3 not.

**NEW FINDING — selection-mirror wedge REPRODUCES on a build containing upstream PR 472's fix.**
- This window: `manage_selection op=get` instant; `op=add` hit the 30s execution contract ("settled as cancellation during cancellation grace") — the exact upstream issue 457 signature.
- Also: 2x `file_actions create` → `MCP error -32000: Connection closed`; child probe read_file timeout. Token accounting stuck at "pending/incomplete" for selected files.
- ⇒ upstream PR 472 does not cover the whole wedge class. Candidate residual path: the mutation-ingress await (`awaitAppliedIngress`) — see upstream PR 520 below.

**Q3 — upstream state (ANSWERED, GitHub probe):**
- Upstream issue 449 open (mp's repro comment posted 07-11); upstream PR 450 open, review required, Copilot clean, NO human review. Upstream PR 472 open, review required. Upstream issues 513 and 514 open, no comments. Upstream PR 517 open — a maintainer: "looks like a great fix" (07-11 23:57 UTC) but unmerged.
- The 5 `upstream/main` commits the local patch branch lacks: upstream PR 497 appcast fail-closed + 4x upstream PR 516 titlebar/menu UI. Neither upstream PR 450 nor upstream PR 517 among them → no drop-triggers; no upstream relief.
- Latest release v1.0.28 (07-10); Homebrew cask already 1.0.28,29. Installed /Applications app is 1.0.27-era binary (its crash build UUID matches the 1.0.27 vintage from the earlier report).
- NEW upstream items to evaluate: **upstream PR 520 "Fix Oracle selection packaging and mutation-ingress stalls"** (prime suspect for residual wedge), upstream issue 515 (CB leaks intermediate selection after failed discovery), upstream PR 455 (unbounded MCP buffering / silent receive drops), upstream issue 390 (MCP freshness/ingress stalls), upstream PR 360 (reduce retained app-server processes).

**Q4/Q5 — crash storm + bridge routing (ANSWERED): all of today's 25 repoprompt-mcp SIGABRTs are the RELEASE binary, spawned per MCP-client config, NOT the running app.**
- 25 .ips today: 01:23 x3, 07:38–08:55 x22 (UTC); every procPath = /Applications/RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp, signature = MCPService.runTransport() / swift_task_dealloc (defect upstream issue 513/upstream PR 517).
- Bridge routing: some Claude client configurations resolved `RepoPromptCE` to the stale release helper, which runs the /Applications RELEASE binary, while Codex's configuration resolved to the debug helper.
- ⇒ Claude Code orchestrator sessions use the unfixed release bridge (crash → "Connection closed" storms); Codex children use the debug helper. The crash storm windows correlate with active orchestrator sessions.
- 7 live `claude -p` discovery children under the debug app (oldest 00:52 UTC, ~9.5h) with 7 matching discovery-D-*.json leases — CB child leak (Fault B / upstream issue 515 territory) live on the current build.
- 4 codex app-server chains under the debug app; codex-cli 0.144.1.

## Investigator Findings
### Method + live upstream issue 514 probe note (2026-07-12, pair investigator on the local patch branch with the backoff patch, read-only)

Traced the full source on the running branch; three Codex-backed `agent_explore` probes ran in parallel for recon (gh PR diffs, error-string location, await-definition sites). **All three probes completed inside the 3-min window and all had `mcp__RepoPromptCE__*` tools available** (they successfully ran `file_search`/`gh`). So **defect upstream issue 514 did NOT reproduce this round** — consistent with the earlier "2/3 children provisioned" observation that upstream issue 514 is *intermittent, not deterministic*. Load-bearing probe claims (error-string site, `awaitAppliedIngress` bounded-vs-unbounded, `usedAgentOutputAsPrompt` origin) were independently re-read from source before being used below.

---

### Q-A — Why the mutating-selection wedge persists despite upstream PR 472 (confidence: **HIGH** on mechanism; **MEDIUM-HIGH** that this is the live 30s park point, inferred from code + phase instrumentation, not observed live)

**Answer: upstream PR 472 bounded the mirror chain (both layers) but never touched the *second* mutating-only await in the same `op=add` path — `awaitAppliedIngress`. That applied-ingress barrier is unbounded and effectively uncancellable, and it is the residual wedge.**

**The op=add await chain today (`MCPSelectionToolProvider.executeManageSelectionAttempt`, `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPSelectionToolProvider.swift:143`):**
1. `:163-166` — drain requirement splits by op: `op=="get"` → `.canonicalSelection`; every mutating op → `.mirroredSelectionAndMetrics`, then `guard drain == .completed`. **← the mirror chain upstream PR 472 fixed.**
2. `:171` — `resolveTabContextSnapshot(...)` throws directly (not a park).
3. `:173-179` — **`if op != "get"` → `:177 await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupRootScope)`**, wrapped in phase `.manageSelectionIngressWait` (`:176`/`:178`). **← the residual wedge. Gated on `op != "get"`, which is exactly the reported "op=get instant / op=add 30s" split.**

**What upstream PR 472's three commits actually bounded (read from `git show`):**
- The *bound selection mirror tail* commit (`WorkspaceSelectionCoordinator.swift`) — introduced `makeSelectionMirrorTail` with a `timeoutTask` (`Task.sleep(for: mcpSelectionMirrorTimeout)`, **default `.seconds(10)`**, `defaultMCPSelectionMirrorTimeout`) plus a `MCPSelectionMirrorWaitSignal`; callers now `await waitForSelectionMirrorTail(tail)` (fires on completion **or** the 10s timeout) instead of the old unbounded `await task.value`; `supersedeSelectionMirrorTail` cancels predecessor task+timeout on the next enqueue. **⇒ Layer 2 (`mcpSelectionMirrorTail`) is now bounded to ~10s.**
- The *release auto-selection mirror waiters* commit (`MCPReadFileAutoSelectionCoordinator.swift`) — `invalidate(context:)` now calls `cancelMirrorWaiters(for:)`; `waitForMirrorTicket` bails when `invalidatedContexts.contains(contextKey)`; `cleanupMirrorLaneIfSettled` now cancels the parked worker task (`mirrorWorkers.removeValue(...)?.task.cancel()`). **⇒ Layer 1 (mirror-ticket waiters) now self-heals / releases on invalidate.**
- The third commit — **test-only** (`MCPCodeStructureWorktreeTests.swift`), no runtime effect.

**None of the three touched `MCPSelectionToolProvider.swift` or `WorkspaceFileContextStore.swift`.** So the applied-ingress await at `:177` is *unchanged* by upstream PR 472.

**Why `:177` is unbounded (the still-uncancelled await):**
- `store.awaitAppliedIngress(rootScope:)` → `WorkspaceFileContextStore.swift:7973` → `awaitAppliedIngress(rootIDs:)` `:8081` → `awaitAppliedIngress(rootID:target:)` `:8135` → **`await join.value()` at `:8165`, `:8177`, `:8187`, `:8206`** on a `ScopedIngressBarrierJoin`. The only cancellation check is `guard !Task.isCancelled` at the *entry* (`:8139`) and in the chunk loop (`:8100`); there is **no timeout and no cancellation race wrapped around `join.value()`**. Once parked in `join.value()`, task cancellation does not resume the continuation.
- **Contrast — the bounded twin exists and is used elsewhere:** `awaitAppliedIngressForExplicitRequest(..., timeout:)` (`:8050`) → `awaitAppliedIngressWithTimeout` (`:8063`) races the operation against `Task.sleep(for: timeout)` inside a `withThrowingTaskGroup { defer { group.cancelAll() } }`. `read_file` uses this bounded variant (`WorkspaceReadableFileService.swift:41`). **`manage_selection` mutation calls the *unbounded* sibling.** This is the whole defect in one line.

**What parks / what unparks:**
- **Parks:** the `ScopedIngressBarrierJoin` never resolves because the root's watcher-watermark / service-publication-sequence never reaches the captured `target` (`launchScopedIngressBarrier` never drives convergence) — i.e. the root's freshness/reconciliation pipeline is stalled. This is exactly the class described by **upstream issue 390** ("warm single-file mutations trigger full-root reconciliation; freshness/ingress can stall basic MCP tools 8-12s"). The 30s MCP execution contract then ends the *tool call* ("settled as cancellation during cancellation grace"), but the underlying `join` is not resumed — the *same* "cancellation settles, resource never released" shape H4 found in the mirror tail, moved one layer over.
- **Unparks:** either the barrier genuinely converges (watermarks advance), or a real timeout/cancellation race is added around `join.value()` (currently absent).

**Corroborating (non-blocking) symptom — the stuck token accounting:** `MCPServerViewModel+TokenStats.swift:266` returns `source: "bound_tab_cached_state"` with `refreshPending: true` (`:267`) and non-empty `incompleteComponents`; rendered as "incomplete from bound_tab_cached_state; refresh pending" (`ToolOutputFormatter.swift:2957`). This path **does not await** the refresh — `enqueueVirtualTokenRefresh` is fire-and-forget. So the perpetually-incomplete accounting is a *read-out of the same stalled root pipeline*, not a second wedge. It confirms the root's ingress/convergence is stuck (which is precisely what `:177` blocks on).

---

### Q-B — Source of "Context Builder completed without a typed direct response for the requested question" (confidence: **HIGH** on site+mechanism; **HIGH** that it is distinct from Fault A and from the Q-A wedge; **MEDIUM-HIGH** that it is structurally deterministic for typed instructions-only MCP CB runs — recommend a 1-shot dynamic repro to lock the intended-design question)

**Exact site:** `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPContextBuilderToolProvider.swift:665`, inside `responseDisposition(responseType:terminalDisposition:usedAgentOutputAsPrompt:effectivePrompt:)` (`nonisolated static`, `:651`). Thrown by its caller at `:447-451` (`case let .failed(message): throw MCPError.internalError(message)`).

**Producing condition:** `responseType?.wantsResponse == true` (a typed `plan`/`question`/`review` was requested) **AND** `terminalDisposition == .completed` **AND** `usedAgentOutputAsPrompt == true` (`:663` guard). It is a *disposition gate on a successfully-completed run*, not a discovery failure.

**What sets `usedAgentOutputAsPrompt = true`:** `ContextBuilderAgentViewModel.copyAgentOutputToPromptIfEmpty` (`:2215`) and the MCP tab-context commit fallback (`:2822`, mirrored at `MCPServerViewModel+TabContext.swift:4122`). Semantics: **when the tab's `promptText` is empty, CB copies the discovery agent's own output into the prompt and sets the flag.** `effectivePrompt` is then read back from the result tab (`MCPContextBuilderToolProvider.swift:415`, `= resultTab.promptText`).

**Why an MCP typed CB run hits it (structural gap):** the MCP `instructions` arg (`MCPContextBuilderToolProvider.swift:177`) is threaded as `instructionsOverride` (`:344`) and written to `session.contextBuilderInstructions` / `contextBuilderInstructions` — the **discovery agent's task** (`ContextBuilderAgentViewModel.swift:1764`). It is **never written to `tab.promptText`** (the provider only *reads* `promptText`, at `:415`). Combined with `enhancementModeOverride: .fullRewrite` (`:348`), a typed run that supplies only `instructions` and no pre-existing tab prompt will: finish discovery `.completed` → find `promptText` empty → copy agent output in → `usedAgentOutputAsPrompt = true` → `responseDisposition` refuses at `:665`. This is a **structural condition of the CE MCP CB typed path**, which is why it fails 2/2 rather than intermittently.

**Is it the Fault A family (`missingFinalContext`)? NO — distinct.** Fault A is thrown when the final-context *connection mapping* is nil at commit (non-orderly peer close, `MCPConnectionManager` gate); this is a prompt-emptiness gate on a `.completed` run in a different type (`responseDisposition`). Different site, different terminal disposition, different cause.

**Can a wedged selection mutation or failed final-context commit cause it? NO (independent, co-occurring):**
- The Q-A ingress wedge sets nothing here — the flag is driven purely by `tab.promptText` emptiness, independent of selection state.
- A failed final-context *commit* produces **different** errors (`ContextBuilderAgentViewModel.swift:2818` "could not store its prompt fallback"; or `outcome: .staleOrNoLongerCurrent`), not the `:665` message.
- So the wedge and the typed-response failure are **two separate defects that co-occurred** in the complaint session, not cause-and-effect.

**Does it leak the discovery child (the 7 live children)? NO on this branch.** A `.completed` run runs `finalizeContextBuilderRun → scheduleRunTeardown` (`ContextBuilderAgentViewModel.swift:2073`) → `await payload.provider?.dispose()` (`:2145`) *before* the completion snapshot is returned to the MCP provider (verified via the teardown read). The `.failed` disposition is evaluated *after* teardown is already scheduled. **The 7 leaked children are Fault B** (superseded/stale finalize early-return), a separate path. Caveat: if the caller *retried* CB rapidly after each typed-response failure, those retries can supersede prior run records → Fault B leak — but the leaking mechanism is still Fault B, not this gate.

---

### Q-C — Upstream PR coverage (confidence: **HIGH** per-item classification from `gh` diffs; **MEDIUM-HIGH** on cherry-pick conflict prediction, not yet trial-merged)

| Item | Type/State | Touches Q-A/Q-B await points? | Verdict |
|---|---|---|---|
| **Upstream PR 520** Fix Oracle selection packaging + mutation-ingress stalls | PR, open | **YES** — changes `awaitAppliedIngress` behavior; touches `WorkspaceSelectionCoordinator.swift`, `WorkspaceFileContextStore.swift`, `MCPServerViewModel+TabContext.swift`, `MCPWindowToolDependencies.swift`, `MCP{ApplyEdits,File}ToolProvider.swift`, `MCPMutationRetryableFailure.swift`; **adds `Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift`**. Separates mutation-ingress ack from codemap convergence; bounds freshness stalls. Closes upstream issue 515. | **COVERS Q-A** (the intended upstream fix for the residual ingress wedge). Possibly *partially* touches Q-B (it edits `MCPServerViewModel+TabContext.swift:4122`, the `usedAgentOutputAsPrompt` commit region) but its stated scope is selection/ingress → treat Q-B coverage as **uncertain/partial**. |
| **Upstream PR 455** Prevent unbounded MCP buffering / silent receive drops | PR, open | **NO** — transport layer only (`NewlineDelimitedSocketReader`, `UnixSocketMCPTransport`, 256 MiB frame ceiling). | **UNRELATED** to the selection/ingress/CB-typed wedges. (Adjacent to the release-bridge "Connection closed" / upstream issue 513/upstream PR 517 family, not this.) |
| **Upstream issue 390** worktree freshness/ingress stalls; warm mutation → full-root reconciliation | Issue, open | **YES (conceptual)** — names `awaitAppliedIngress`, proposes bounded typed failures + incremental reconciliation. No code. | **COVERS Q-A conceptually** — this is the tracking issue for exactly the `:177` ingress-stall class; upstream PR 520 is its likely implementation. |
| **Upstream issue 515** CB leaks intermediate selection into Oracle context after **failed** discovery | Issue, open | Names `MCPSelectionToolProvider.swift`; about selection authority after *failed* discovery. | **PARTIALLY related to Q-B family** but a **different CB fault** — the Q-B gate is a *completed*-discovery prompt-emptiness gate, not failed-discovery selection authority. Upstream PR 520 closes it. |
| **Upstream PR 360** Reduce Agent Mode memory from retained provider processes | PR, open, **425 files** (oversized diff) | Touches `MCPSelectionToolProvider.swift` + `awaitAppliedIngress` *incidentally*; core = 5-min idle shutdown + cancellation-safe provider teardown. Does **not** touch `WorkspaceSelectionCoordinator.swift` or `MCPReadFileAutoSelectionCoordinator.swift`. | **PARTIALLY related to Fault B** (leaked discovery children — idle shutdown + cancellation-safe teardown could reap them), **not** the Q-A ingress wedge or Q-B typed gate. The 425-file scope warrants caution. |

**Is cherry-picking upstream PR 520 onto the local patch branch sound?**
- **Upstream PR 520 is the correct fix for the Q-A residual wedge** (it bounds mutation-ingress and adds `MCPTimeoutPolicy`). But it **rewrites `WorkspaceSelectionCoordinator.swift` and `WorkspaceFileContextStore.swift` — the same files the local patch branch already heavily rewrote via upstream PR 472's mirror-tail commit** (mirror tail/fence). A clean cherry-pick is **unlikely**; expect conflicts in `WorkspaceSelectionCoordinator.swift` (overlapping mirror-tail/fence regions) and possibly the store's ingress region. The two are *complementary* (upstream PR 472 bounded the mirror tail; upstream PR 520 bounds mutation ingress) so both should be kept — but that requires **manual conflict reconciliation**, not a fast-forward pick.
- **Recommended lower-risk local patch (surgical alternative):** swap `MCPSelectionToolProvider.swift:177` from the unbounded `awaitAppliedIngress(rootScope:)` to a **bounded** wait. The machinery already exists — `awaitAppliedIngressWithTimeout` (`WorkspaceFileContextStore.swift:8063`) — so add a `rootScope`+`timeout` overload that wraps `awaitAppliedIngress(rootScope:)` in it (timeout < the 30s contract, e.g. 8-12s, ideally via an MCP timeout policy constant). ~1 file + 1 small helper, composes cleanly with upstream PR 472's already-applied mirror-tail timeout, and directly bounds the residual wedge without importing upstream PR 520's 26-file surface. **Prefer this for the local patch branch** unless full upstream parity with upstream PR 520 is the goal; if upstream parity is wanted, take upstream PR 520 wholesale on a fresh branch and reconcile the upstream PR 472 overlap deliberately.
- **Separately:** the Q-B typed-response gate is **not** covered by any of these with confidence — upstream PR 520 *may* touch its commit region incidentally but no PR clearly seeds `tab.promptText` from MCP `instructions` for typed runs. If the 2/2 CB failures are to be fixed, that gap likely needs its own change (seed the effective prompt from `instructions` on typed MCP CB runs, or relax the `usedAgentOutputAsPrompt` guard when `instructions` were supplied). Recommend filing/confirming this as a distinct item rather than assuming upstream PR 520 resolves it.

## Investigation Log

### Phase 1 — Assessment (orchestrator, this session)
- Role labels: explore/engineer = Codex CLI GPT-5.6 Sol; pair = Claude Opus; design = Claude Fable 5 — confirms "only codex-backed roles affected" framing.
- The local patch branch = upstream/main (`d4b1e05e`) + 5 cherry-picks (upstream PR 450 fix, 3× upstream PR 472, upstream issue 513 backoff fix). Branch is 5 behind upstream/main → Q3.
- History: all five "Codex app-server process is not running" events are 2026-07-11 15:34–15:57Z (in the work workspace), none since → consistent with startup-stall class being build-vintage-bound.
- LIVE bridge failure evidence: 2× `Connection closed` on `file_actions create` at investigation start; report file had to be created via shell.

### Phase 2 — context_builder live test (orchestrator, 2026-07-12)
**Hypothesis:** CB works on the current (upstream PR 472-fixed) build.
**Findings:** FAILED 2/2 with `[-32603] Internal error: Context Builder completed without a typed direct response for the requested question` (response_type=question). Deterministic, not transient. Discovery-child count went 7 → 10 across the two failed attempts ⇒ each failed run leaks a `claude -p` child + discovery-D-*.json lease (Fault B / upstream issue 515 signature, live on current build).
**Evidence:** two identical MCP errors; ps count before/after; a new `discovery-D-*.json` lease per attempt.
**Conclusion:** CB failure class persists on the upstream PR 472-fixed build; selection seeding for the oracle done manually (mutating selection ops are wedged in this window anyway).

### Phase 3 — pair investigator dispatched
A Claude Opus pair session: Q-A residual wedge await-chain, Q-B "typed direct response" error source, Q-C upstream PR coverage (upstream PRs 520 and 455/upstream issues 390 and 515/upstream PR 360).


### Follow-up round 2 (2026-07-12 late) — config-audit correction + upstream PR 520-vs-upstream PR 472 verdict

**Correction to defect 1's attribution (MP pointed out that orchestrator sessions start through a launcher with a strict MCP config).** Verified: that launcher's MCP config points at the **debug** helper, so launcher-started orchestrator sessions were NOT using the release bridge. The 25 crashed release bridges were spawned by Claude clients (confirmed from .ips `parentProc`) that did not go through the launcher and whose own configuration still resolved to the RELEASE helper.

Since NO release app is running, these release helpers dial the release socket (`repoprompt-ce-<n>.sock`) with no app behind it (a known failure mode), retry in `runTransport`'s backoff, and die in the upstream issue 513 teardown crash — a storm of zombie bridges from sessions that never successfully used RP. **The "self-inflicted stale path" fear is confirmed but narrowly scoped**: the maintained configurations all point at the debug helper; the stale ones are a few Claude client entries.

**Upstream PR 520 vs upstream PR 472 (user question: can upstream PR 472 be dropped when upstream PR 520 lands?) — NO; they are COMPLEMENTARY.** Evidence from `gh pr diff`:
- Upstream PR 520 (by a maintainer, open) contains **zero** occurrences of the mirror-tail symbols upstream PR 472 bounded (`mcpSelectionMirrorTail`/`makeSelectionMirrorTail`/`waitForSelectionMirrorTail`/`supersedeSelectionMirrorTail`/`cancelMirrorWaiters`/`waitForMirrorTicket`) and does not touch `MCPReadFileAutoSelectionCoordinator.swift` at all; its 43 relevant hits are all `awaitAppliedIngress*`/`IngressBarrier`/`MCPTimeoutPolicy`.
- The only production-file overlap with upstream PR 472 is `WorkspaceSelectionCoordinator.swift`, where upstream PR 520 adds a single new function (`protectCanonicalMCPSelectionFromDeferredUISnapshots`, ~line 260) — additive, nowhere near upstream PR 472's mirror-tail regions. Rebase overlap is near-trivial (plus the shared test-ledger fixture).
- Conclusion: upstream PR 472 fixes the mirror-chain awaits; upstream PR 520 fixes the mutation-ingress await (`MCPSelectionToolProvider.swift:177` class) + selection packaging. Both are needed; keep both. The earlier "expect conflicts" prediction is downgraded: expect at most a ledger-fixture conflict.

**Links index:** upstream issue 449 · upstream PR 450 · upstream issue 457 · upstream PR 472 · upstream issue 513 · upstream issue 514 · upstream issue 515 · upstream PR 517 · upstream PR 520 · upstream issue 390 · upstream PR 455 · upstream PR 360

**Live bridge note (this session):** the orchestrator's own RepoPromptCE MCP connection died mid-investigation ("not connected", no auto-reconnect) after two earlier `Connection closed` write failures; no matching .ips (mechanism unconfirmed — NOT proven to be the upstream issue 513 signature). Claude Code restart required to restore RP MCP for this session.

### Amended recommendation 1 (replaces the earlier recommendation 1)
Remove or repoint the stale Claude client entries that resolve to the RELEASE helper: delete each entry, or point it at the debug helper while the local debug build is in use. This ends the release-bridge crash storm at the source.

## Root Cause
Four independent, co-occurring defects (all RepoPrompt CE, none in codex-cli), each verified this session:

1. **Bridge routing → unfixed release binary crashes (the "Connection closed" complaints).** Some Claude client configurations resolve `RepoPromptCE` to the release helper, which runs `/Applications/RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp` (1.0.27, no upstream issue 513/upstream PR 517 fix). 25 SIGABRTs today, all this binary, all `MCPService.runTransport()`/`swift_task_dealloc`. The fixed debug helper (with the backoff patch since 00:04 UTC) is what Codex children use.
2. **Residual selection-mutation wedge (the "stalling/hanging" complaints).** `MCPSelectionToolProvider.swift:177` awaits the UNBOUNDED `WorkspaceFileContextStore.awaitAppliedIngress(rootScope:)` (:7973 → `join.value()` with no timeout/cancellation race) for every mutating op, gated `op != "get"` — exactly the observed op=get-instant/op=add-30s split. Upstream PR 472 bounded only the mirror chain (both layers). The bounded twin (`awaitAppliedIngressForExplicitRequest`, :8050) exists and is used by read_file's explicit path. Upstream: upstream issue 390 names this class; upstream PR 520 is the fix. Downstream casualties: `file_actions`/`apply_edits` mutations, child-agent `read_file` auto-selection timeouts, permanently "pending" token accounting.
3. **Context Builder typed-response structural failure + child leaks (the "context builder errors").** MCP `instructions` flow only to the discovery task (`ContextBuilderAgentViewModel.swift:1764`), never to `tab.promptText`; on completion with an empty tab prompt, CB copies agent output in, sets `usedAgentOutputAsPrompt`, and `responseDisposition` refuses (`MCPContextBuilderToolProvider.swift:663-665`) ⇒ deterministic 2/2 failure for typed instructions-only runs. Distinct from Fault A (missingFinalContext) and from the wedge. Discovery children leak via Fault B (supersession skips `provider.dispose()`): 7→10 live children today.
4. **Upstream issue 514 intermittent child MCP tool provisioning.** 1/3 explore children this session had no `mcp__RepoPromptCE__*` tools; pair's 3 probes all had them. Intermittent routing/bootstrap failure, open upstream, unfixed.

**Build-state addendum:** the 23:32 UTC relaunch loaded the 4-commit local patch branch package — upstream PRs 450 and 472/`1ab555e6` fixes ARE live in the host app; only the 5-commit repackage (00:04 UTC, adds the backoff patch) remains unlaunched, which matters only for the app-embedded helper. No Codex turn hangs or app-server start failures occurred today — those two classes are confirmed fixed by the running build.

## Eliminated hypotheses
- **Upstream codex-cli regression** — 0.144.1 latest; all Codex dispatches today started AND completed turns; no `turn/completed` hangs, no "process is not running" since 07-11 (pre-fix build).
- **"The fixed build isn't running"** (as full explanation) — 4 of 5 local fixes are live in the host app; the wedge reproduces WITH upstream PR 472 applied, so the wedge explanation had to move to the ingress path.
- **CB failure caused by the wedge or Fault A** — the typed-response gate is prompt-emptiness-driven, fires on `.completed` runs, different site/type than missingFinalContext; independent of selection state.
- **Upstream issue 514 as deterministic child breakage** — 1/3 then 0/3 reproduction; intermittent.
- **The crash storm coming from the running app** — all 25 .ips are the /Applications release binary spawned by client configs; no release app process exists.

## Recommendations
1. **Repoint Claude Code MCP config at the fixed bridge** (highest leverage, zero build work): point the stale Claude client entries at the debug helper, which contains the backoff patch, until an upstream release ships upstream PR 517. This should end the release-bridge crashes behind the "Connection closed" storms.
2. **Surgical bounded-ingress patch on the local patch branch**: swap `MCPSelectionToolProvider.swift:177` to a bounded wait using the existing `awaitAppliedIngressWithTimeout` machinery (`WorkspaceFileContextStore.swift:8063`) via a small `rootScope`+`timeout` overload (8-12s). Composes with upstream PR 472; avoids importing upstream PR 520's 26-file surface. Adopt upstream PR 520 wholesale (with deliberate upstream PR 472 conflict reconciliation) when it merges upstream — drop the surgical patch then.
3. **Relaunch the debug app** (user approval required) to load the 00:04 UTC bundle — clears the currently wedged window state and picks up the backoff patch in the embedded helper; kill the 10 leaked `claude -p` discovery children at the same time (no reaper exists).
4. **File the CB typed-response gap upstream** (after confirming upstream PR 520 doesn't fix it): typed MCP `context_builder` runs never seed `tab.promptText` from `instructions`, so instructions-only typed runs fail deterministically at `MCPContextBuilderToolProvider.swift:665`. Reference upstream issue 515 as related-but-distinct.
5. **Nudge upstream review**: upstream PRs 450, 472, and 517 are all CI-green and awaiting human review; upstream issue 449 already has the repro evidence; a maintainer's "looks like a great fix" on upstream PR 517 suggests a merge is close — after it lands, drop the backoff patch per the recorded disposition.
6. **Workaround guidance for orchestrators until fixed**: prefer op=get/read-only RP calls; avoid `manage_selection` mutations, `file_actions`, `apply_edits`, and typed `context_builder` in wedged windows; treat child RP-tool timeouts as the ingress wedge, not agent flakiness.

## Preventive Measures
- Add a preflight check to orchestrator/session-start tooling that verifies which `repoprompt-mcp` binary the session's MCP config resolves to (release vs debug vs vintage) — the entire crash-storm class was a config symlink, invisible to the app-side fixes.
- Any `await` on the MCP tool path must have a timeout or cancellation race; both wedge layers (upstream issue 457) and this ingress wait share the "cancellation settles the call, resource stays parked" shape. Upstream PR 520's `MCPTimeoutPolicy` is the right pattern — adopt it repo-wide.
- Keep the running app and the on-disk package in lockstep: a completed package without a relaunch (the 00:04 UTC one) silently means "fix exists but is not running" — surface bundle-vs-process vintage in `make dev-status`.
- When agents report "RepoPrompt is flaky", split by failure class first (bridge crash vs wedge vs CB vs provisioning); this session found four simultaneously-live classes that would have been conflated as one.

## Preventive Measures
(TBD)

## Resolution status (2026-07-12)

All three approved remediation items executed:

1. The stale client configurations were repointed to the debug helper.
2. Debug app relaunched onto the 00:04 UTC five-fix bundle; leaked discovery children were already gone.
3. CB typed-response gate filed upstream as upstream issue 526
   after adversarial review corrected the mechanism attribution: for MCP runs the
   `usedAgentOutputAsPrompt` flag is set by the `commitTabContextForAgent` empty-prompt fallback
   (`copyAgentOutputToPromptIfEmpty` is skipped via `!record.origin.isMCP`), and the first
   `responseDisposition` guard fires — error string "without a typed direct response".

Post-fix watch items: "Connection closed" bridge drops persist on the patched build without
SIGABRT reports; one unexplained silent app exit (~12:49–12:54 UTC); `agent_run` respond only
accepts the `response` key despite advertising `decision` (unfiled). Upstream PR 520 merged upstream, so
the local patch branch is due for a rebase.
