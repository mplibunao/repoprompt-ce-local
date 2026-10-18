# Investigation: Context Builder "final context is missing (connection none)" failure

> Investigation report, observed 2026-07-09 on the release 1.0.27 build. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary
The `missingFinalContext (connection none)` failure is a real, previously unfiled CE bug:
Context Builder's final context survives teardown only when the discovery child closes
with an *orderly peer EOF*; any other close cause silently drops the run→connection
mapping and the finalized context (`MCPConnectionManager.swift:5959-5966`). Two sibling
faults share the same "drop, don't reconcile" root: discovery child processes leak when a
run record is superseded before teardown (5 zombies observed live), and the window-scoped
selection-mirror task chain has no timeout/cancellation, wedging all `manage_selection`
mutations in the affected window (reproduced live). The user's patched branch
is exonerated — the failing app is the *release* 1.0.27 build. Of the referenced issues,
none is this bug: upstream issue 170 is the nearest sibling (same pipeline), upstream issue 169 is an adjacent
multi-window bug but not on this path, upstream issue 312 is a different failure mode, and upstream issue 27 is the
enhancement that addresses the separate progress-visibility gap (whose purpose-built UI
already exists as dead code).

## Symptoms
Observed in a prior session (2026-07-09, in a work-repository window, RepoPrompt CE debug build from branch `bugfix/codex-app-server-text-elements`):

- Every `context_builder` call (plan mode, `export_response: true`) failed with:
  `failed: Context Builder final context is missing for run <RUN_ID> (connection none).`
- Reproduced across **both transports**: MCP (2 attempts) and CLI `rpce-cli` (1 attempt).
- The CLI run completed end-to-end in ~94s (`exit 0`), progress log showed
  "Context Builder run finalization completed in 0.001s (total 93.686s)" then
  "Context builder complete" — and then the failed status with `Total tokens: 0`.
  → Not a client timeout; app-side finalization/publish failure.
- MCP attempts *did* build a 5-file selection (8,317 tokens) with note
  `Token accounting: stale from active_tab_published; refresh pending`.
- No oracle export file ever landed on disk.
- Scope was isolated to `context_builder`: in the same window/period, `bind_context`,
  `agent_run` (5 explore agents), `rpce-cli -e 'windows'`, `--tools-schema` all worked.
- 3 windows were open at the time; multi-window state suspected as contributing factor.
- Separate UX gap reported by user: since the IDE view was removed in CE, Context
  Builder progress is invisible and Context Builder runs don't appear in the Agent view.

## Hypotheses
1. The finalized context is published to/looked up by a (child MCP) connection that no
   longer exists at finalization time → `.missingFinalContext(runID, connectionID: nil)`.
   Error site: `Sources/RepoPrompt/Features/ContextBuilder/ViewModels/ContextBuilderAgentViewModel.swift:2391-2395`.
2. Multi-window / wrong-active-tab routing causes the run to finalize against a tab whose
   connection isn't live (cf. stale `active_tab_published` token accounting note; possibly
   related to upstream issue 169's wrong-tab tripwire being swallowed).
3. The local patched branch commit `bf9a0b82` ("fix: update Codex app-server text payload
   key", touches only `CodexNativeSessionController.swift` + a Codex test) — plausible ONLY
   if the Context Builder discovery agent runs through the Codex app-server provider;
   otherwise unrelated. Needs verification of which provider backed the run.
4. No-Oracle-model misconfiguration (upstream issue 312) — likely NOT this: upstream issue 312's failure mode is
   a configuration error, not `missingFinalContext`, and the discovery phase here ran 94s.

## Background / Prior Research

### Repo/contribution status (verified 2026-07-09)
- `origin` = `git@github.com:repoprompt/repoprompt-ce.git` — **plain clone, not a fork**.
- GitHub viewer permission for `mplibunao`: **READ** → cannot push branches upstream;
  contributing requires creating a fork and adding it as a remote.
- No existing fork of `repoprompt/repoprompt-ce` under `mplibunao`.
- Local branch `bugfix/codex-app-server-text-elements` is 1 commit ahead of `main`
  (`bf9a0b82`, 2026-07-09): changes `CodexNativeSessionController.swift` (1 line) +
  adds `CodexNativeSessionControllerTurnDispatchTests.swift`. Codex-provider-scoped.

### Upstream issues reviewed
- **Upstream issue 27 (open, enhancement)** — "Make Context Builder sub-agent-first with async lifecycle
  operations": expose CB as a delegated agent with `start/poll/wait/cancel` + status/logs/
  progress/cancellation, reusing `ContextBuilderAgentViewModel` per-tab session state.
  → Directly addresses the user's visibility gap (progress + agent-view presence).
- **Upstream issue 312 (open)** — Agent Mode offers Context Builder when no Oracle model configured;
  failure is a config error. Different failure mode from ours.
- **Upstream issue 170 (open)** — Transport-closure remediation + CB stall attribution tracker. Contains
  a detailed subsystem map of the CB finalization pipeline (child MCP connection
  termination → auto-selection drain → commitTabContext → pollAndSaveStateAsync → run
  finalization → model resolution → packaging → session create → send → streaming →
  message finalization) with file:line references. Our failure sits in/near this pipeline
  but is a *hard finalization failure*, not a stall; the CLI run showed finalization
  completing in 0.001s then reporting missing final context.
- **Upstream issue 169 (open)** — per-call `context_id` honored by dispatch but absent from schemas;
  wrong-tab tripwire error swallowed. Candidate relative for the multi-window hypothesis.
- Also open, adjacent: upstream issue 26 (abort propagation to Oracle/CB), upstream issue 368 (OpenCode CB rate limits).

### Explore agent: upstream issue/PR sweep (2026-07-09)
- **No upstream issue or PR mentions `missingFinalContext` or "final context is missing"** —
  this exact failure is not yet filed. Closest siblings: upstream issue 170's one unchecked item
  (discovery-only 300s stall — a *stall*, not our hard failure) and upstream issue 169 (wrong-tab
  tripwire swallowed: `runTool` wraps `resolveTabContextSnapshot` in `try?`, so a stale
  or mismatched `context_id` silently reads the wrong bound tab instead of erroring).
- Upstream issue 170's remediation landed as **upstream PR 171 "Fix MCP transport timeout recovery"
  (`a48fec6`, merged 2026-06-13)**.
- Upstream issues 27 and 312: no linked PRs, no activity after filing. Upstream issue 169: no linked PR.
- Upstream issue 382 (closed 2026-07-06, session-bound worktrees fail-closed lookup) and upstream issue 384 cite
  upstream issue 170 as related context; no new remediation merged against upstream issue 170 since upstream PR 171.

### Explore agent: git archaeology of `missingFinalContext` (2026-07-09)
- The entire failure path was added by **one commit: `f2850ecc` "Fix Context Builder
  completion after discovery peer EOF (upstream PR 254)" (2026-06-18)** — no other
  commit in history touches the string.
- Enum case defined at `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift:42`
  (`case missingFinalContext(runID: UUID, connectionID: UUID?)`); constructed at
  `ContextBuilderAgentViewModel.swift:2719`; rendered at `:2391`.
- `f2850ecc` and upstream PR 171 (`a48fec6`) are both **ancestors of the local checkout** — the
  failing build includes the peer-EOF fix and the transport remediation.
- Local branch is **54 commits behind `origin/main`**; only `ec186667` (Sentry telemetry
  spans, 2026-06-29) touches Context Builder files, and it is instrumentation-only —
  **no upstream fix exists that the local build is merely missing**.
- Local branch delta vs main is exactly one Codex-provider commit (`bf9a0b82`).

### Explore agent: IDE view removal + CB visibility (2026-07-09)
- CE is Agent-Mode-only **by design**: Classic has `WindowUIMode` `.ide`/`.agent` toggle
  (`repoprompt-classic .../WindowState.swift:13,27,33`); CE has no such enum, and
  `docs/architecture/source-layout.md:75,126,166` + `Scripts/source_layout_guardrails.sh:245,270`
  enforce that IDE-era views stay removed.
- CB progress today is visible only as (a) an inline chat tool card when CB is invoked as
  a nested tool call (`ContextBuilderToolCards.swift`, `ToolCardRouter.swift`) and (b) the
  ask-user modal (`AgentModeDetailWithSidebarView.swift:171,216` observes `$pendingAskUser`).
- **A purpose-built progress surface exists but is dead code**:
  `Features/AgentMode/Views/RuntimeSidebar/AgentRuntimeContextBuilderSection.swift:1-57`
  (Running/Idle card + discovery log) and `AgentRuntimeStatusPill.swift:6-107` (spinner
  pill keyed on `tabsWithActiveContextBuilderRun`) — **neither is instantiated anywhere**.
  The wired pill row (`AgentInputBar.swift:164` → `AgentStatusPillsRow.swift`) has no
  dependency on `ContextBuilderAgentViewModel`.
- CB runs are never registered as `AgentSession`s (`Runtime/AgentSession.swift:127` —
  `agentKind` only models claudeCode/codexExec/openCode), so they can't appear in the
  Agent view session list. Ephemeral state lives in `ContextBuilderAgentViewModel.TabSession`
  (`ContextBuilderRunLifecycle.swift:118,146`).
- → Fix shape for the UX gap: wire the orphaned pill/section into `AgentStatusPillsRow` /
  runtime sidebar (small), and/or register CB runs as first-class sessions (upstream issue 27's
  direction, larger).

### Phase 2 note (2026-07-09)
`context_builder` was intentionally not used to seed this investigation: it is the tool
under investigation, it failed reproducibly in the prior session, and an interrupted
attempt in this session could not even be confirmed as running or cancelled from outside
the app (no session registration, no log lines, dead-code progress UI) — which is itself
live evidence of the visibility gap. File selection was seeded manually from explore-agent
findings instead.

## Live reproduction evidence (2026-07-09 ~15:10–15:35 UTC, gathered by orchestrator)

Environment discovered during this session — **two CE app instances running simultaneously**:
- The installed release app, `/Applications/RepoPrompt CE.app` — **release 1.0.27 (build 28)**, started
  Jul 9 09:50 UTC. It owned the user's working windows, including the affected ones, and
  served both the failing session and this one.
- A debug build in `DebugApps` — **debug 1.0.24 (build 25)**, started Jul 8 15:00 UTC, on its own
  socket. Not involved in the failures.
- ⇒ The local patched branch (`bf9a0b82`, Codex provider only) is **exonerated twice
  over**: the failing app is the release 1.0.27 build, and the patch touches only the
  Codex app-server payload key.

**Five orphaned Context Builder discovery agents** (headless `claude -p … --mcp-config
…/MCP/LaunchConfigs/discovery-R-<UUID>.json`, each with a `repoprompt_ce_cli` child
connecting back to the release app), all spawned by the release app, all sleeping, 0% CPU:
- one spawned Jul 9 10:58 UTC (alive 4.5h; plausibly the user's failed session)
- four spawned Jul 9 13:54:32–13:55:30 UTC, **four launches ~20s
  apart within one minute** — pattern consistent with a discovery-launch retry loop where
  the app fails to associate the child's inbound connection with the run and retries.
- 10 `discovery-R-*.json` configs on disk total; 5 children exited, 5 leaked.
- Discovery child MCP config points at `~/RepoPrompt/repoprompt_ce_cli`,
  version 1.0.27 — matches the app; version-mismatch hypothesis eliminated.

**Selection-mutation wedge, window-scoped** (all measured while both apps idle):
- The affected window: `manage_selection op=get` returns in **0.09s** ("fresh");
  `op=add` **hangs until the 30s execution contract** then settles as cancellation —
  reproduced 3× on both MCP and CLI transports (`tool_execution_timeout … settled as
  cancellation during cancellation grace`). Transport stays alive (upstream PR 171's
  cancellation-safety working at the transport layer; the underlying blockage persists).
- Another window: identical `op=add` completes in **0.11s** ⇒ wedge is window/tab-scoped.
- "Token accounting: stale from active_tab_published; refresh pending" appears in the
  *healthy* window too ⇒ that note is not diagnostic of the wedge.
- Thread sample of the release app during a blocked mutation: release binary is stripped;
  only dispatch runtime frames visible (sample not retained); parked
  Swift-concurrency continuations not observable — consistent with an awaited
  continuation rather than a busy/blocked thread.
- Unified log (`log show`, 6 min): zero Context-Builder-related lines from either app.
- A `context_builder` MCP call interrupted client-side in this session at ~15:10 UTC spawned
  **no** discovery child ⇒ it likely queued behind the existing wedge; the wedge predates
  this session's attempts.

## Investigator Findings
<!-- pair investigator appends here -->

### Investigator pass — 2026-07-09 (static trace on branch `bugfix/codex-app-server-text-elements`)

Read-only source trace of the failing pipeline. All file:line refs verified by direct read
unless marked *(probe, spot-checked)*. Version skew noted where relevant (working tree is 1
Codex-only commit ahead of the failing 1.0.27 release build; none of the code below is touched
by that commit).

#### TL;DR
Two user-visible symptoms have **one shared upstream cause and two independent downstream faults**:

1. **`missingFinalContext (connection none)`** — at finalization the run's connection lookup
   `contextBuilderFinalContextConnectionID(runID:)` returns `nil`, and the *only* constructor that
   fires on that branch hard-codes `connectionID: nil`. The run→connection association was either
   never written (routing/ownership refusal) or was **destroyed without being preserved** into the
   peer-EOF fallback dict. Preservation is gated on an *orderly* peer-EOF close; any other close
   cause tears the mapping down and loses the final context.
2. **Leaked `claude -p` discovery children** — child-process termination is owned *solely* by the
   run's terminal-teardown path (`finalizeContextBuilderRun → scheduleRunTeardown → provider.dispose()`).
   That path early-returns when the run record is superseded/stale, and there is no independent
   reaper, so an orphaned run never SIGTERMs its child or deletes its `discovery-*.json` lease file.
3. **`manage_selection op=add` 30s wedge (window-scoped)** — a *separate* subsystem. Every mutating
   selection op awaits a single window-scoped, uncancellable, un-timed-out serialized mirror `Task`
   chain (`WorkspaceSelectionCoordinator.mcpSelectionMirrorTail`); `op=get` never enters it. One
   wedged task (plausibly issued by the failing CB run's own `manage_selection` call) becomes a
   permanent head-of-line block for that window.

The connective tissue: the **same nil association** that yields `missingFinalContext` also empties
`connectionIDs(forRunID:)`, so the *secondary* connection-cleanup teardown finds nothing to
terminate — but the *primary* process disposal is independent of that mapping, so the leak is
actually driven by run-record supersession, not by the nil lookup. These are correlated, not
identical, faults.

---

#### H1 — connectionID nil at finalization: **CONFIRMED (mechanism), root-caused to the close-cause gate**

- Failure string rendered at `ContextBuilderAgentViewModel.swift:2391-2395` (`connection none` iff
  `connectionID == nil`).
- **Two** constructors of `.missingFinalContext` exist (report only noted one):
  - `ContextBuilderAgentViewModel.swift:2718-2721` — hard-codes `connectionID: nil`. **This is the
    observed one** (`connection none`).
  - `MCPServerViewModel+TabContext.swift:4095` — passes a *real* `connectionID` (would render
    `connection <uuid>`); not the observed failure.
- The nil branch is reached when `mcpServer.contextBuilderFinalContextConnectionID(runID:)` returns
  nil — `commitTabContextForAgent`, `ContextBuilderAgentViewModel.swift:2651`.
- Lookup body, `MCPServerViewModel+TabContext.swift:4044-4052`: returns a connection only if
  `connectionIDByRunID[runID]` **and** `connectionIDToRunID[cid] == runID` **and**
  `tabContextByConnectionID[cid]?.runID == runID` all agree, else falls back to
  `detachedContextBuilderTabContextByRunID[runID]?.connectionID`. Nil ⇒ *all three primary dicts
  disagree/absent* **and** *no detached fallback exists*. These dicts are **per-window**
  (`MCPServerViewModel.swift:1671,1673`), and the lookup runs on the CB run's own
  `mcpServer` (its starting window), `commitTabContextForAgent` `:2649`.
- Association is written by `registerRunIDMapping` (`:3693-3694`) / `registerPendingPolicyRunIDMapping`
  (`:3756-3757`) — both invoked from `MCPConnectionManager.mapConnectionToRunID(...)` (`:2790`) /
  `...ForPendingPolicy` (`:2880`), which resolve the window via
  `connectionWindowMap[cid] ?? windowIDForRunID(runID)` (`:2797-2807`, `windowIDForRunID` `:437-452`)
  and register on **that** window's `mcpServer`.
- **Why routing-success can still finalize nil.** If registration were merely *refused*, routing
  would time out and the run would return `.failed(routingFailed)` at `ContextBuilderAgentViewModel.swift:2310-2320`,
  **not** `missingFinalContext`. The reported CLI run did ~94s of real work then failed at
  finalization ⇒ routing succeeded and the association existed *during* the run, then was **lost by
  commit time**. The destroyer is `removeConnection` (`MCPConnectionManager.swift:5911`): the
  final-context **preservation** (detach) path is taken only when **all three** hold —
  `context.reason == peerEOF` **and** `context.initiator == .peer` **and** `purpose == .discoverRun`
  (`:5959-5966`) → `finishReadFileAutoSelectionAndRemoveTabContext(detachContextBuilderRunID:)`
  (`:5866-5868`) → `detachContextBuilderTabContextForPeerEOF` (moves the mapping into
  `detachedContextBuilderTabContextByRunID`, `TabContext.swift:4025-4051`, keeping the fallback
  alive). **Any other close cause** (server-initiated terminate, write-hangup, transport error, TTL)
  yields `detachContextBuilderRunID == nil` → tab context removed with **no** detached fallback →
  lookup nil → `missingFinalContext(connectionID: nil)`. The discovery child's real MCP peer is a
  `repoprompt_ce_cli` grandchild (per report); if `claude -p` exits and tears that peer down as a
  non-orderly close, the orderly-peer-EOF gate is missed and the final context is dropped even though
  discovery completed. This path is exactly what commit `f2850ecc` (upstream PR 254) added — the gate is real
  but *narrow*, and only the orderly-EOF shape is covered.
- Cross-window contribution *(probe A, spot-checked)*: association is by **PID-ancestry + client-name
  FIFO**, not by the launch-config UUID. The `discovery-<flavor>-<UUID>.json` UUID is a fresh
  `UUID()` (`MCPConfigExportService.swift:260`), **not** the runID — so filename-based run identity
  is not in play. The genuine multi-window risk is the non-PID-gated FIFO fallback matching purely by
  client name, which can bind a connection to the *wrong window's* pending policy when two runs share
  a client name; the window-mismatch refusals at `registerRunIDMapping:3671-3674` /
  `registerPendingPolicyRunIDMapping:3725-3726` then produce a *routing* failure rather than
  `missingFinalContext`. Given the observed 94s-then-fail shape, the close-cause gate (above) is the
  primary driver; wrong-window binding is a secondary/contributing path.

#### H2 — retries + leaked children: **CONFIRMED ownership gap; specific trigger UNDETERMINED (release build had diagnostics off)**

- **No app-side discovery retry loop exists** (verified across `ContextBuilder/`, `AgentRunCoordinator`,
  `MCPBootstrapLease`, `HeadlessAgentConnectionGate`). The single timing knob is a one-shot 10s
  routing wait: `ContextBuilderDefaults.mcpRoutingTimeoutMilliseconds = 10000` (`:39`), bootstrap TTL
  `= 15s` (`:42`), used at `ContextBuilderAgentViewModel.swift:2304-2306`. The "4 launches ~20s apart"
  is **client-side** re-invocation of `context_builder` (spawn + ≤10s routing wait + report ≈ 20s),
  not an internal relaunch.
- **Termination ownership is singular:** `finalizeContextBuilderRun` (`:1920-2008`, runs for
  `.completed`/`.cancelled`/`.failed`) → `scheduleRunTeardown` (`:2010-2043`) → `provider.dispose()`
  (`:2024`) → *(probe B, spot-checked)* `ClaudeCodeAgentProvider.dispose()` → `CLIProcessRunner.cancelAll()`
  (SIGTERM over the process registry). There is **no** independent reaper/watchdog/OS supervision, and
  the `discovery-*.json` lease file is deleted **only** by `MCPConfigLease.release()`/`deinit` invoked
  from the same `cleanup(context:)` that disposal triggers — so a skipped disposal also leaks the
  config file (matches the report's 1:1 "5 leaked children / 5 undeleted configs").
- **The gap:** `finalizeContextBuilderRun` early-returns before `scheduleRunTeardown` when
  `acceptsEvents(from:record)` is false (`:1929`) or `claimTerminal` fails (`:1931`). `acceptsEvents`
  is false once a **newer run supersedes the tab slot** — `ContextBuilderRunLifecycle.swift:279-285`
  gates on `recordsByRunID[runID] === record && activeRunIDByTabID[tabID] == runID && … && activeRunOwnership == ownership`.
  With rapid client retries on the same tab, an older record can be superseded before its finalize
  runs ⇒ its `provider.dispose()` never fires ⇒ its `claude -p` child is never SIGTERMed and its lease
  file never deleted. This is the most defensible leak mechanism; the exact cause of the 5 specific
  PIDs (supersession-skips-teardown vs. SIGTERM not reaping a `claude -p` blocked on its dead MCP
  socket vs. a spawn/registration race) can't be disambiguated statically because the failing build is
  the **release** app with CB routing diagnostics disabled.
- **Correlation with H1:** the *secondary* cleanup `clearTabContextForAgent` (`:2945-2973`) terminates
  connections found via `agentConnectionIDs(:2615-2632)` → `mcpServer.connectionIDs(forRunID:)`
  (`:3600-3608`), which reads the *same* mappings destroyed in H1. Once those are gone, this teardown
  finds **zero** connections and terminates nothing — so on the `missingFinalContext` path both the
  connection-scoped cleanup (empty mapping) and, if the record is also superseded, the process-scoped
  disposal (skipped finalize) can miss, compounding the leak.

#### H3 — discovery child lifecycle: **CONFIRMED**
- Config write: `MCPConfigExportService.makeLease(prefix:"discovery")` → `discovery-<D|R>-<UUID>.json`
  (`:141-143`, `:256-261`); `R` = release flavor. UUID ≠ runID. Delete: lease `release()`/`deinit`
  only *(probe B, spot-checked: `MCPConfigExportService` lease `:28-52`; `ClaudeCodeAgentProvider.cleanup`
  `:331-336`)*. No process-exit hook deletes it.
- Spawn/terminate owner: `ClaudeCodeAgentProvider` via `CLIProcessRunner`; kill only through
  `dispose()`/`cancelAll()` as above. A leaked child holds a live `repoprompt_ce_cli` peer connection
  and its config lease open, which is why leaked children retain app-side connection/tab-context state
  until the socket EOFs.

#### H4 — selection-mutation wedge: **CONFIRMED; two layered awaits, deepest is `mcpSelectionMirrorTail`**
- Divergence point, `MCPSelectionToolProvider.executeManageSelectionAttempt` (`:143-179`):
  `op=get` drains with `.canonicalSelection` (`:164`); every mutating op drains with
  `.mirroredSelectionAndMetrics` (`:165`) **and** additionally `awaitAppliedIngress` (`:177`).
  `resolveTabContextSnapshot` here throws directly (`:171`) — it is **not** the `try?`-swallowed call.
- Layer 1 — `MCPReadFileAutoSelectionCoordinator.drain` (`:541-602`): only `.mirroredSelectionAndMetrics`
  additionally `await`s `waitForMirrorTicket` (`:587-599`, `:1065-1090`). If the mirror worker parks
  inside `applyMirror` (`runMirrorWorker` `:968-1003`), its `defer` (`:969-978`) never runs, so
  `mirrorWorkers` retains the key and `scheduleMirrorWorkerIfNeeded` (`:955`) refuses a replacement →
  `completedTicket` never advances → every mutating drain blocks. Critically, `invalidate(context:)`
  (`:616-623`) does **not** resume/cancel pending mirror waiters, and `cleanupMirrorLaneIfSettled`
  (`:1208-1215`) won't reclaim a lane while a worker is parked or work is pending ⇒ **no self-healing,
  no teardown-time release**.
- Layer 2 (deepest, uncancellable) — the mirror apply routes into
  `WorkspaceSelectionCoordinator.enqueueSelectionMirror` (`:597-639`): a single **window-scoped**
  serialized `Task` chain (`mcpSelectionMirrorTail`). Each task `await predecessor?.value` (`:607`);
  each caller (`persistSelection` for add/remove/set/promote/demote/clear) `await task.value` (`:638`).
  The chain is **explicitly decoupled from request cancellation** (comment `:604-605`) and has **no
  timeout**. One task wedged inside `applySelectionMirrorAttempt`→`applyStoredSelection` (file-index/
  codemap work) becomes a permanent head-of-line block for that window; `op=get` never enqueues.
- This exactly reconciles upstream PR 171 (`a48fec6`): upstream PR 171 made the *transport* cancellation-safe, so the
  tool call settles at the 30s contract and the caller's `await task.value` unblocks *for that caller* —
  but the wedged tail `Task` is never cancelled, so it remains head-of-line for the **next** caller.
  "Cancellation now settles, underlying resource never released" is literally this design: the tail
  task has no cancellation path and no timeout. Window-scoping (`mcpSelectionMirrorTail` is one
  instance per window) matches the report's observation that one window wedged while another stayed fine.
- `read_file` "sometimes hangs" *(probe C, plausible)*: interactive/CLI `read_file` auto-selection
  drains `.mirroredSelectionAndMetrics` synchronously and its mirror worker feeds the same
  `mcpSelectionMirrorTail` chain, so it wedges only when it triggers a new auto-selection on the
  wedged window. (Consistent with this session's own MCP `read_file` on the report doc hitting the 30s
  contract while `get` stayed instant.)

#### H(upstream issue 169) — wrong-tab tripwire swallowed via `try?`: **RED HERRING for `missingFinalContext`**
CB finalization resolves its connection through `contextBuilderFinalContextConnectionID(runID:)` on the
run's own `mcpServer`, **not** through `resolveTabContextSnapshot`. The `manage_selection` call site
even lets `resolveTabContextSnapshot` throw (`MCPSelectionToolProvider.swift:171`). Upstream issue 169 is in the same
multi-window family but is not on the `missingFinalContext` path; it could independently mis-route a
`bind_context`/tool call to the wrong tab, which is a distinct bug.

---

#### Synthesis: one root, three faults
- **Shared root:** the Context Builder finalization/teardown pipeline assumes an **orderly, single,
  same-window peer-EOF** child lifecycle. Multi-window routing, non-orderly child close, run
  supersession, and an uncancellable mirror chain each violate that assumption, and each violation is
  handled by *dropping* state rather than *reconciling* it.
- **Fault A (`missingFinalContext`):** final-context preservation is gated on orderly peer-EOF only
  (`removeConnection:5959-5966`); every other close cause discards it. → Broaden preservation to any
  discover-run close that still has committed tab context, or capture the final context at
  stream-completion time (before teardown) instead of relying on the connection still being mapped.
- **Fault B (leaked children/configs):** process termination is owned solely by a finalize path that
  early-returns on supersession/staleness (`:1929/:1931`), with no independent reaper. → Add a
  run-scoped disposal that is guaranteed on *any* record retirement (including superseded/stale), and/or
  a process/lease reaper keyed on runID; ensure `clearTabContextForAgent`'s connection lookup does not
  depend on already-destroyed mappings.
- **Fault C (selection wedge):** the window-scoped mirror `Task` chain has no timeout and no
  cancellation, so one hung `applyStoredSelection` head-of-line-blocks the window forever. → Bound each
  mirror task (timeout + cancel-on-supersede), and make `MCPReadFileAutoSelectionCoordinator.invalidate`
  resume/cancel pending mirror waiters instead of leaving them parked.

#### Recommended fix locations (for a follow-up change; this pass is read-only)
1. `MCPConnectionManager.swift:5959-5966` — widen the CB final-context preservation gate beyond
   `reason==peerEOF && initiator==.peer` (e.g., preserve whenever `purpose==.discoverRun` and a
   committed tab context still exists), or move final-context capture earlier (at
   `consumeContextBuilderProviderStream` completion) so it does not depend on close cause.
2. `ContextBuilderAgentViewModel.swift:1920-2043` (`finalizeContextBuilderRun`/`scheduleRunTeardown`)
   + `ContextBuilderRunLifecycle.swift:279-291` — guarantee `provider.dispose()` runs on **every**
   record retirement, including superseded/stale records that fail `acceptsEvents`/`claimTerminal`.
3. `WorkspaceSelectionCoordinator.swift:597-639` (`enqueueSelectionMirror`/`mcpSelectionMirrorTail`) —
   add a per-task timeout and cancel-on-supersede so a wedged `applyStoredSelection` cannot
   head-of-line-block the window.
4. `MCPReadFileAutoSelectionCoordinator.swift:616-623` (`invalidate`) and `:1208-1215`
   (`cleanupMirrorLaneIfSettled`) — on context invalidation, resume/cancel pending mirror-ticket
   waiters and reclaim the lane so a parked worker cannot wedge future `.mirroredSelectionAndMetrics`
   drains.
5. `ContextBuilderAgentViewModel.swift:2718-2721` — the `missingFinalContext(connectionID: nil)`
   constructor discards the connectionID even when one was known earlier in the run; thread the
   last-known connectionID (`record.finalContextConnectionIDForDiagnostics`) into the diagnostic so the
   failure is not silently "connection none".
6. Visibility (pre-existing, from the report): the `discovery-*.json` lease + child PID have no
   run-scoped registry that an operator or a reaper can enumerate; a runID→{pid, leaseURL, connectionID}
   registry would make both the leak and the nil-lookup observable in release builds.


## Investigation Log

### Phase 1 — Error-site location
**Hypothesis:** the report's error string exists at a single site we can trace backwards.
**Findings:** single match: `ContextBuilderAgentViewModel.swift:2391` — case
`.missingFinalContext(runID, connectionID)` rendered as
`"Context Builder final context is missing for run … (connection none)"` when
`connectionID == nil`.
**Conclusion:** trace who throws/produces `.missingFinalContext` and under what
conditions `connectionID` is nil.

### Phase 5 — Orchestrator spot-checks (2026-07-09)
The three load-bearing investigator claims were re-verified by direct source read:
- `MCPConnectionManager.swift` ~5956-5966: comment reads "Only orderly peer EOF from a
  discover-run child may transfer final context ownership"; `detachContextBuilderRunID`
  is nil for every other close cause. **Confirmed.**
- `Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:597-639`:
  serialized `mcpSelectionMirrorTail` chain, `await predecessor?.value`, comment "The
  internal task owns its completion … even if the originating request is cancelled", no
  timeout. **Confirmed.**
- `ContextBuilderAgentViewModel.swift:2718-2721`: constructor hard-codes
  `connectionID: nil`. **Confirmed.**

Also verified: local Codex patch `bf9a0b82` (`"textElements"` → `"text_elements"`) is
NOT on `origin/main` — upstream `CodexNativeSessionController.swift:1629` still sends
`"textElements"` even after `1ab555e6` "Fix Codex app-server startup stalls" (Jul 8) —
so the local fix remains a valid upstream contribution candidate.

## Root Cause
One shared root, three faults (full mechanism in `## Investigator Findings`):
- **Fault A — the reported failure.** Final-context preservation at connection removal is
  gated on `reason==peerEOF && initiator==.peer && purpose==.discoverRun`
  (`MCPConnectionManager.swift:5959-5966`). A discovery child whose `repoprompt_ce_cli`
  peer closes any other way (process exit tearing the socket down non-orderly, terminate,
  write-hangup, TTL) loses the run→connection mapping with no detached fallback, so
  `contextBuilderFinalContextConnectionID(runID:)` returns nil at commit
  (`ContextBuilderAgentViewModel.swift:2651`) and the run fails as
  `missingFinalContext(connectionID: nil)` (`:2718-2721`) — after discovery genuinely
  completed. Introduced with the narrow gate in `f2850ecc` (upstream PR 254).
- **Fault B — leaked discovery children.** `provider.dispose()` (SIGTERM + lease/config
  cleanup) runs only via `finalizeContextBuilderRun → scheduleRunTeardown`, which
  early-returns for superseded/stale run records (`:1929/:1931`;
  `ContextBuilderRunLifecycle.swift:279-285`). Rapid re-invocation on the same tab
  supersedes older records ⇒ their `claude -p` children and `discovery-*.json` leases
  leak (5 of each observed).
- **Fault C — selection-mutation wedge.** All mutating `manage_selection` ops await the
  window-scoped `mcpSelectionMirrorTail` chain
  (`WorkspaceSelectionCoordinator.swift:597-639`), which is uncancellable and un-timed;
  one task wedged in `applyStoredSelection` head-of-line-blocks the window forever.
  Upstream PR 171 made the *transport* settle at 30s but never releases the underlying chain.

## Recommendations
1. **File a new upstream issue** for Faults A+B (one issue: finalization drop + child
   leak share the teardown pipeline), citing this report's evidence; reference upstream issue 170 and
   upstream issue 169 as related-but-distinct. Fault C is arguably its own issue (selection subsystem).
2. **Fix candidates** (see `#### Recommended fix locations` in Investigator Findings for
   the full list of 6): widen the preservation gate or capture final context at
   stream-completion (`MCPConnectionManager.swift:5959-5966`); guarantee disposal on
   every record retirement (`ContextBuilderAgentViewModel.swift:1920-2043` +
   `ContextBuilderRunLifecycle.swift:279-291`); bound the mirror chain
   (`WorkspaceSelectionCoordinator.swift:597-639`).
3. **Visibility gap** (user's UX complaint): `AgentRuntimeStatusPill` /
   `AgentRuntimeContextBuilderSection` (+ parent `AgentRuntimeSidebarView`) are
   never-wired Agent-Mode components, not IDE-era leftovers — born unwired in CE's
   initial snapshot (`351e9803`), zero instantiations in all of git history, dependencies
   are live Agent Mode types only, guardrails-clean. However, the team shipped the leaner
   `AgentStatusPillsRow` (`AgentInputBar.swift:161-172`) instead, so resurrecting the
   RuntimeSidebar concept is a product decision, not a gap-fill: raise it on upstream issue 27
   (noting the ready-made components) and let maintainers choose the surface before
   writing UI code.
4. **Contribution setup**: fork `repoprompt/repoprompt-ce` (viewer permission is READ),
   add the fork as a remote, and PR from there. The local Codex fix `bf9a0b82` is also
   still unfixed upstream and can be PR'd.
5. **Immediate remediation** (operator): quit/restart the installed release CE app
   to clear the affected window's wedge and reap nothing — the 5 zombie `claude -p`
   discovery children must be killed manually since
   no reaper exists. Decide whether both app instances (release 1.0.27 in /Applications +
   debug 1.0.24 in DebugApps) should really run concurrently.

## Preventive Measures
- A runID→{pid, leaseURL, connectionID} registry (Investigator fix location 6) would make
  both the leak and the nil-lookup observable in release builds, where CB diagnostics are
  currently debug-only.
- Registering CB runs as first-class agent sessions (upstream issue 27) gives operators a way to see and
  cancel orphaned runs instead of discovering them via `ps`.
- Any teardown/finalization path that "drops" state on unexpected lifecycle shapes
  (supersession, non-orderly close) should reconcile or at least log; the release build's
  silence made this bug invisible for weeks.
