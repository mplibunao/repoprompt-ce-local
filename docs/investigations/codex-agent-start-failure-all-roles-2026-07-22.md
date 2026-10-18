# Investigation: Codex agent starts fail with "Codex app-server process is not running" (2026-07-22)

> Investigation report, observed 2026-07-22 on a local debug build from the 2026-07-20 upstream sync. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/porting.md](../porting.md), Procedure.

Date: 2026-07-22
Status: complete — resolved same day

## Summary
The reported "every Codex dispatch fails" was upstream issue 554 (worktree-bound Codex app-server starts failing) running unfixed in the local build: the 2026-07-20 upstream sync omitted the user's own fix, upstream PR 568 (`bugfix/codex-worktree-app-server-start`), so builds from that sync regressed to the behavior before upstream PR 568. Worktree-bound Codex sub-agents in the work-repository workflows (bindings inherit by default) all failed, which presented as total Codex breakage; restarts, the codex-CLI upgrade, and a reboot were irrelevant. Resolution: merged the upstream PR 568 branch into the build branch, rebuilt and relaunched the debug app, and verified with a four-probe matrix — the previously deterministic work-repository worktree failure now passes (SMOKE4_OK). Durable prevention: a local patch ledger and an upstream-sync checklist.

Live differential testing showed the failure is NOT environmental and NOT "all Codex dispatches": on the current app instance, unbound Codex dispatches succeed in both open workspaces, a worktree-bound dispatch succeeds for repoprompt-ce, and a worktree-bound dispatch on `<work repo>` fails deterministically with `Codex native start failed: Codex app-server process is not running.` The entire codex CLI / node / mise / PATH environment is exonerated by direct wire-level probes, including from inside the failed session's own worktree cwd. The defect is inside RepoPrompt's worktree-bound Codex session-start path (upstream issue 554 class), running the local build from the 2026-07-20 sync (built 2026-07-20T16:09Z, dirty).

## Symptoms
- Reported (handoff, 2026-07-22): every Codex-role `agent_run` dispatch fails immediately with `Codex native start failed: Codex app-server process is not running.`; onset mid-session while a pair agent was spawning sub-agents; survived RepoPrompt restarts, codex CLI upgrade to 0.145.0 (03:23 UTC), and a machine reboot. Claude-backed roles and the MCP server unaffected.
- Reproduced live (this session, app instance started 04:31:34 UTC):

| Probe (Codex explore role) | Result |
|---|---|
| owner's window, unbound | ✅ completed |
| owner's window, worktree-bound, repo repoprompt-ce (`worktree_create`) | ✅ completed |
| work window, unbound | ✅ completed |
| work window, worktree-bound, repo `<work repo>` (`worktree_create`) | ❌ exact reported error (the work reproduction session and its new worktree) |

- Pre-existing failed sessions in the app: three baseline sessions (all codexExec, all the same error) — the failure class is filed as upstream issue 554 and its baselines all target work-repository worktrees.

## Background / Prior Research

### Prior investigations in this repo
- `docs/investigations/codex-appserver-and-issue-triage-2026-07-12.md`: error text = `CodexAppServerClient.ClientError.processNotRunning`, a generic fan-in (child exit/EOF, liveness invalidation, teardown races) with no retained stderr/exit status.
- `docs/investigations/worktree-bound-codex-app-server-start-failure-2026-07-15.md`: worktree binding projects the worktree path into BOTH app-server process launch cwd and protocol cwd; recommended separating launch cwd (logical root) from execution cwd (worktree) plus bounded stderr/exit-status retention. Whether those recommendations are implemented in the running build is an open question below.

### Environment exoneration (live wire-level probes, 2026-07-22, codex-cli 0.145.0)
All probes used a harness that keeps stdin open (see pitfall below) and the same absolute node and codex binaries RepoPrompt resolves:
- `initialize` responds from: scratchpad cwd (×2), `<work repo>` main checkout cwd, the failed session's own worktree cwd `<worktree>` (×2), and with a second node shim.
- `thread/start` with `cwd` = that worktree: thread starts, 12 `mcpServer/startupStatus/updated` notifications all `error:null`, identical to main-checkout cwd.
- Therefore eliminated: codex 0.145.0 breakage, `~/.codex/config.toml` corruption, codex project/hook trust (the project was already trusted), node resolution (either node shim), mise worktree trust (mise 2026.7.4 DOES fail `mise env`/shim-node inside the worktree — `Config files ... are not trusted` — but codex app-server does not depend on it at startup/thread-start), disk space, auth.
- Probe-harness pitfall (do not repeat): redirecting stdin from a file makes 0.145.0 app-server race `initialize` response against stdin EOF (`exit_reason="last_connection_closed"`, response dropped as "disconnected connection") — this produced false "silent failure" results until corrected. Real clients keep stdin open.

### Other live facts
- Running app: the debug app since 04:31:34 UTC; its provenance (`RepoPromptDebugProvenance.json`) names the local build branch at the checkout's HEAD, built 2026-07-20T16:09Z, dirty.
- The app's discovery/warmup app-server (spawned 04:31:38 UTC) is healthy and long-lived; its argv shows RP resolves node to the absolute mise path and codex to the npm shim.
- codex 0.145.0 added an app-server daemon subcommand and `~/.codex/app-server-daemon/` (lock files created 03:43:41 UTC, 0 bytes); no daemon process observed; not implicated by probes.
- In the work window, `worktree_create` without explicit `worktree_repo_root` defaulted to another work repository and was rejected: "worktree binding currently supports the primary workspace root only... provider runtime cwd resolves from primary root `~/<work project>/<work repo>`" — i.e. "first loaded Git repo" and "primary root" disagree in the work multi-root workspace.
- The `<work repo>` root carries its own tool-version files and a repository-level Codex config; repoprompt-ce has neither. The two repos also differ in size and worktree container path (`~/<work project>/.repoprompt-worktrees/` vs `<worktree>/`).
- Unified log has no RepoPrompt entries for the failure window (debug build prints to stdout, app launched via Finder).

### Session-store failure timeline (on-disk `AgentSessions/*.json` containing the error text)
- 07-08: one work-repository session (first occurrence).
- 07-15: a 12-session burst of probes and retries, the incident that produced the 07-15 investigation and upstream issue 554.
- 07-16/07-17: one work-repository session, then the deliberate baseline sessions targeting work-repository worktrees.
- 07-21: one work-repository session.
- **07-22: the reported failure**, then two more work-repository sessions, one of them this investigation's reproduction probe.
- Every one of these sessions has worktree-binding evidence in its JSON. Interpretation: the failure class has been continuous since 07-15 and repo/binding-conditional, not a machine-wide 07-22 onset; the 07-22 perception of "every dispatch fails" matches workflows whose Codex sub-agents are worktree-bound (children inherit worktree bindings by default).
- Additional exoneration: non-interactive login-shell env capture executed from inside the failed worktree succeeds cleanly (95 variables, no stderr) — the app's env-capture input is not poisoned by the worktree cwd.

### Open questions (for code investigation at the build's HEAD)
1. What is the exact worktree-bound Codex start sequence in this build, and which step emits `processNotRunning` for the `<work repo>` worktree while succeeding for repoprompt-ce?
2. Were the 07-15 recommendations (launch-cwd/execution-cwd separation, stderr tail + exit status retention) implemented? Is there a fix that references upstream issue 554 in `git log`?
3. What do the July-13 fail-closed Codex MCP readiness commits (`f80e2005`, `d39eebc6`, `0df1ef7f`) do on this path in this build — can a provisioning/validation failure surface as `processNotRunning`?
4. Why would repo identity (`<work repo>` vs repoprompt-ce) change the outcome if the spawned child itself is healthy under both cwds — e.g. worktree materialization timing, multi-root resolution (`repoPaths.first` vs primary root vs "first loaded Git repo"), per-session config writes, or a pre-spawn validation that inspects the repo?
5. Does the reported "every dispatch fails" state reduce to worktree inheritance (children of a worktree-bound pair agent inherit bindings by default), or was there a broader transient state that a later relaunch cleared? (Sub-agent sessions from the reported failure should show their worktree bindings.)

### Second-round live evidence (2026-07-22 ~05:0x UTC)
- Reproduction is deterministic: a second work + `<work repo>` worktree-bound start (work reproduction 2) failed identically.
- A 10Hz child-process watcher during the failing start captured ~90 short-lived git children of the app (including `git status` inside the new worktree) but **no codex/node app-server child** — the app-server child either never spawns or dies in <~100 ms. Prior watcher output for successful session starts captures the app-server child easily at 0.5s sampling.
- **The "successful" repoprompt-ce worktree probe was itself natively failed-and-recovered**: its completed turn ran inside a `<forked_session>` recovery prompt reading "You are continuing a session that was restarted after a native resume failed for Codex CLI", and the recovered thread then ran with `cwd` = the repoprompt-ce worktree successfully. So the first native attempt failed on BOTH repos; the observable difference is that recovery rescued the repoprompt-ce session ("native resume failed" path) while the work-repository session failed terminally ("native start failed" path).
- Successful session app-server argv (from watcher): the absolute mise Node path, the npm Codex shim, the `-c` overrides listed under Q4, and `app-server`.

### Upstream status (checked 2026-07-22 05:1x UTC)
- Upstream issue 554 is OPEN with no fix; a maintainer invited a fast-tracked PR (2026-07-15 comment).
- v1.1.0 (2026-07-21) ships the MCP watchdog upstream PRs 567 and 575 and MP's upstream PRs 450 and 532 — all already present in the local build branch. The 27-commit `HEAD..upstream/main` delta contains no watchdog, worktree, or app-server-start changes; its only Codex commit is `c82143ce` (upstream PR 603 "Fix Codex app-server tool override policy", merged 2026-07-21T22:26Z), which prunes deprecated `-c features.*` overrides and adds `features.code_mode.direct_only_tool_namespaces=["mcp__RepoPromptCE"]` at thread start/resume — not a fix for upstream issue 554.

### Upstream PR 568 status (the user's own fix for upstream issue 554)
- upstream PR 568 "Fix worktree-bound Codex app-server startup" (OPEN upstream, base main) implements exactly the 07-15 recommendations: launch-cwd/execution-cwd separation, controller identity on the path pair, bounded startup stderr + structured exit status, repo-scoped worktree selectors.
- **It is NOT in the running build.** Its head `96872f7f` (`bugfix/codex-worktree-app-server-start`) is not an ancestor of the local build branch; the three new files it adds (`CodexRuntimeWorkspacePaths.swift`, `CodexProcessStderrCapture.swift`, `ChildProcessExitObserver.swift`) are absent from the checkout; `docs/investigations/upstream-sync-mp-patches-2026-07-20.md` never mentions it. The 07-20 sync omitted it.
- Consequence: the running app is unfixed upstream issue 554 baseline; the live failures imply nothing about upstream PR 568's correctness.

## Investigator Findings

### Mechanism verdict

The worktree-bound `agent_run.start` path creates a **fresh** per-session Codex controller after the worktree binding is committed. It does not first create a primary-root controller and replace it. The fresh controller passes the bound worktree path both to the app-server process launch and to `thread/start`. In the failed work sessions, that first native startup loses its transport after `posix_spawnp` succeeds and before a Codex thread reference is persisted; the generic `processNotRunning` fan-in does not retain enough evidence to distinguish stdout EOF during reader/PID setup, failure during `initialize`, failure before or during `thread/start`, or a request/write interleaving with teardown.

The apparent “resume recovery” in the owner's workspace is not evidence of a failed native attempt. Worktree binding stages a synthetic `<forked_session>` payload whose fixed prose says “restarted after a native resume failed” even for a blank new tab, before any Codex controller exists. A successful send clears that payload; a failed send leaves it persisted. The record from the owner's workspace contains one completed run span and one Codex thread ID. Each work record contains one failed run span, the `Codex native start failed` error, no thread ID, and the still-pending synthetic handoff.

Static configuration does not explain the difference between the owner's workspace and the work workspace. Codex environment capture is process-global, the successful and failed probes use the same provider/model/effort class, and source predicts the same process overrides under matched global permission and feature state. The only direct workspace-derived launch/request input is the effective worktree path, also used as the workspace-write sandbox root; repository-local Codex discovery can additionally observe files under that cwd. Only the argv from the owner's workspace was observed, so the failed argv is a source-derived prediction rather than retained runtime evidence.

### Q1 — Fresh start, resume selection, and the misleading recovery payload

A first send records whether the tab already has resume-eligible non-user history, then calls `ensureCodexNativeSession` with `skipResumeWhenNoPriorCodexHistory` for a new run (`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:4320-4350`). `codexResumeCandidate` also requires `session.codexNeedsReconnect`; it returns `nil` for the blank first-send case (`CodexAgentModeCoordinator.swift:2801-2816`). That `nil` becomes `existingRef: nil`, which is classified as a fresh start (`CodexAgentModeCoordinator.swift:2697-2744,4060-4095`). The native controller derives a resume thread ID only from a non-nil existing reference; otherwise it sends `thread/start`, not `thread/resume` (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1050-1063,1090-1153`).

The quoted recovery sentence comes from a different mechanism:

- An idle execution-destination change calls `stageResumeRecoveryHandoffIfNeeded` before invalidating provider context and committing the worktree binding (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:5718-5767`).
- The staging helper creates a pending handoff without requiring a prior controller, thread ID, resume attempt, or non-empty transcript (`AgentModeViewModel.swift:13203-13242`).
- `composeClaudeResumeRecoveryHandoffPayload` supplies the fixed sentence “restarted after a native resume failed for …” (`AgentModeViewModel.swift:15215-15250`).
- The next provider send prepends the payload (`AgentModeViewModel.swift:13186-13200`). It is cleared only after the provider accepts the send; failed sends reset only the staged flag and retain the payload (`AgentModeViewModel.swift:13251-13260`).

Therefore, `<forked_session>` is synthetic continuity content, not Codex lifecycle telemetry. In a worktree-bound fresh start it is staged before the first controller exists. Its presence cannot prove a native resume, and its absence after success cannot prove that it was never staged.

Codex's synchronous fresh-thread fallback is limited to genuine resume cases:

- Missing-rollout fallback requires `existingRef != nil` and a recognized missing-rollout error, then retries with `existing: nil` (`CodexAgentModeCoordinator.swift:2726-2763`).
- Repeated-timeout fallback requires a resume target and two qualifying timeouts, then replaces the controller and starts fresh (`CodexAgentModeCoordinator.swift:2854-2928,4151-4197`).
- A fresh `processNotRunning` has no existing reference, so neither predicate applies; the coordinator appends `Codex native start failed:` (`CodexAgentModeCoordinator.swift:4210-4237`). The send path detects that error, avoids a duplicate “session not ready” error, and terminalizes the run (`CodexAgentModeCoordinator.swift:4345-4395`).

There is also a separate asynchronous recovery path for an unexpected controller event-stream end while a run remains active (`CodexAgentModeCoordinator.swift:3196-3365,3880-3932`). That path does not create the quoted handoff. It can only run after inbound controller streams exist, and the persisted records do not retain a process-attempt ledger that would prove or disprove an invisible pre-protocol attempt. No persisted error or retry marker appears in the successful run in the owner's workspace; the durable evidence is one successful run span and one final thread ID.

Git history contains no fix for upstream issue 554. The handoff builder and the Codex resume fallbacks enter CE history in root snapshot `351e9803`. Worktree-transition staging at the current call site blames to `5aedc938` (“Fix session-worktree edit rebasing,” 2026-06-18). Commit `51b2a0e4` later added the current first-send/resume labeling distinction; it did not add a fresh-start retry.

### Q2 — First-attempt ordering and controller lifecycle

The worktree binding lands before provider startup:

1. `executeStart` resolves or creates a background tab and Agent session (`Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift:426-438`; `AgentModeViewModel.swift:5991-6071`).
2. It awaits `startWorktreeCoordinator.prepare`, including repository resolution, worktree creation/selection, projection materialization, and `transitionWorktreeBindings` (`AgentRunMCPToolService.swift:529-555`; `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPStartWorktreeCoordinator.swift:145-303`).
3. Only after worktree preparation and validation return does it call `startRun` (`AgentRunMCPToolService.swift:611-676`).
4. External run startup activates the MCP control context, configures the selected provider, binds the request to the tab, and dispatches the instruction (`Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentExternalMCPRunStarter.swift:73-121`).
5. `ensureSessionReady(reconnectActiveProviders: true)` reconnects Codex only when the session is already active; the new target is still idle during configuration (`AgentModeViewModel.swift:4063-4083,6116-6123`).
6. During dispatch, the runtime path is resolved from the committed `session.worktreeBindings` (`AgentModeViewModel.swift:1839-1879`), and only then does the coordinator construct the controller (`CodexAgentModeCoordinator.swift:3763-3855`).

The production factory creates a new `CodexAppServerClient` for every controller (`AgentModeViewModel.swift:1429-1451`). General controller replacement clears the session's controller identity synchronously and schedules shutdown of the captured old controller (`CodexAgentModeCoordinator.swift:3510-3578`); the old controller owns a different client and cannot clear the replacement client's process.

A broader re-entrancy hazard exists in `shutdownCodexSession`: it awaits `controller.shutdown()` before clearing `session.codexController` (`CodexAgentModeCoordinator.swift:8297-8333`). Another startup entering that await window could observe the shutting-down controller. That is not the ordered first-start path here: worktree preparation awaits provider invalidation before returning, and provider dispatch has not begun. No source or session-record evidence connects that general hazard to these five starts.

**Q2 verdict:** there is no primary-root controller created before binding and no old-client shutdown that can poison the first worktree controller. The first native attempt is made by a fresh client already configured with the bound worktree path.

### Q3 — Environment cache scope and capture cwd

`CLIEnvironmentCache.shared` is one process-wide actor. Its snapshots, fallbacks, load tasks, and generations are keyed only by `ShellEnvironmentCaptureMode`, not workspace, tab, session, repository, or cwd (`Sources/RepoPrompt/Infrastructure/Process/CLIEnvironmentCache.swift:4-69`). Codex app-server and preflight requests always select the non-interactive `.loginShell` mode (`Sources/RepoPrompt/Infrastructure/Process/ProcessEnvironmentBuilder.swift:62-72,107-126`).

The capture command is the user's login shell with `["-l", "-c", "env"]`. The `Process` never receives `currentDirectoryURL`, so it inherits the RepoPrompt host process cwd rather than the target worktree (`CLIEnvironmentCache.swift:86-144,146-231`). The captured dictionary is then merged with the app's inherited environment and sanitized (`ProcessEnvironmentBuilder.swift:77-105,128-158`). The worktree path is applied later to the actual Codex child (`CodexNativeSessionController.swift:1083-1088`; `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexAppServerClient.swift:401-415`).

**Q3 verdict:** the work workspace and the owner's workspace share the same Codex login-shell snapshot within the same app process and capture generation. Values can change after global invalidation/refresh or app relaunch, but not merely because a session belongs to another workspace. The live shell probe from the failing worktree is additional evidence that the environment itself is healthy, but it is not the cwd used by the app's cached capture shell.

### Q4 — Spawn argv and `thread/start` inputs

The successful watcher in the owner's workspace observed this interpreter-level argv:

```text
<absolute node path>
<absolute codex path>
-c tool_output_token_limit=25000
-c features.apps=false
-c features.computer_use=false
-c features.goals=true
-c features.js_repl=false
-c features.js_repl_tools_only=false
-c features.memories=false
-c features.plugins=false
-c features.tool_call_mcp_elicitation=false
-c features.tool_search=false
-c features.tool_suggest=false
-c memories.generate_memories=false
-c memories.use_memories=false
app-server
```

RepoPrompt itself resolves the executable Codex shim and passes its override arguments plus `app-server`; the shim's interpreter accounts for the watcher showing absolute Node followed by the Codex script (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexProviderHelpers.swift:45-100`; `CodexAppServerClient.swift:929-960`). Override order is deterministic: token limit first, then sorted forced feature keys (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppOnly/CodexOverrides.swift:4-18,77-112,177-209`). Goal/computer-use state is resolved immediately before launch (`CodexNativeSessionController.swift:1882-1900`).

For a fresh session, the JSON-RPC `thread/start` request contains:

- selected model, reasoning effort, and optional service tier;
- `cwd` equal to the effective worktree path;
- thread-level config overrides;
- Agent Mode base instructions;
- approval policy, sandbox mode, and approval reviewer from the effective permission profile (`CodexNativeSessionController.swift:1124-1153`).

The thread config combines tool policy, forced steering, goal/reasoning/computer-use state, MCP enablement, and permission settings (`CodexNativeSessionController.swift:480-537,7987-8067`). MCP-originated starts use the global sub-agent permission policy, including top-level `agent_run.start` sessions; a custom policy resolves per provider, not per workspace (`Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentModeProviderBindingService.swift:46-70`; `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentProviderPermissionProfile.swift:14-75`). Production hard-codes experimental steering on (`AgentModeViewModel.swift:1429-1440`).

For the directly comparable probes, the persisted records agree on provider `codexExec`, model `gpt-5.6-sol`, and effort `low`. The direct workspace differences are:

| Input | owner's workspace probe | work probes |
|---|---|---|
| Process and thread cwd | `<worktree>` | the corresponding `~/<work project>/.repoprompt-worktrees/<work repo>/...` path |
| Workspace-write writable root | owner's worktree path | work worktree path |
| Repository-local discovery | repoprompt-ce worktree contents | `<work repo>` worktree contents, including repo-local Codex/tool files |

Model defaults can be workspace-scoped during role resolution, but the persisted probe records show the same resolved model and effort. Permission policy, feature toggles, steering, environment capture, and MCP inventory are global/provider/session inputs rather than workspace-path-derived inputs. Computer use is per next turn; none is evidenced for these probes. The work-session failure differs in effort (`high`), but it fails with the same pre-thread error as the low-effort probes.

Only the argv from the owner's workspace was captured. Source predicts the same process argv for the failed starts under the matched feature state, but the report must not present that inferred failed argv as observed. Thread-level config was also not persisted wire-for-wire. The reliable differential is the effective cwd/sandbox root and cwd-sensitive repository discovery. The decided manual probe shows that those static inputs are not sufficient on their own to make Codex CLI fail.

### Q5 — Persisted session timelines

Offsets are computed from the persisted Apple-reference timestamps. Each record contains one transcript turn and one run span.

| Session | Binding and handoff | Persisted native sequence |
|---|---|---|
| Work-repository session started by a parent session (the reported failure) | Pending handoff created 1.052 s after binding | Run starts 1.245 s after binding; error 256 ms later: `Codex native start failed: Codex app-server process is not running.`; failed; no Codex thread ID |
| owner's worktree probe | Final record has no pending handoff because the accepted send cleared it | Run starts 3.263 s after binding; assistant returns `CODEX_WORKTREE_PROBE_OK` 9.149 s later; completed; one Codex thread ID |
| Work-repository session | Pending handoff created 1.195 s after binding | Run starts 1.449 s after binding; identical start error 313 ms later; failed; no thread ID |
| work reproduction | Pending handoff created 1.108 s after binding | Run starts 1.279 s after binding; identical start error 216 ms later; failed; no thread ID |
| work reproduction 2 | Pending handoff created 1.098 s after binding | Run starts 1.275 s after binding; identical start error 189 ms later; failed; no thread ID |

Records live at `~/Library/Application Support/RepoPrompt CE/Workspaces/Workspace-<name>-<ID>/AgentSessions/AgentSession-<ID>.json`.

The failure records retain `pendingHandoffPayload` because provider send never succeeded. The successful run in the owner's workspace cleared it after acceptance. This explains the persisted difference without postulating different resume/recovery entry paths. The records do not persist app-server process-attempt IDs, initialize requests, raw `thread/start` requests, stderr, or termination status; they cannot distinguish one successful process attempt from an invisible failed pre-protocol attempt followed by asynchronous recovery. They do establish that no work attempt produced a durable Codex thread and that the session in the owner's workspace produced exactly one durable thread.

### Exact failure boundary and remaining uncertainty

A synchronous chdir, pipe, spawn-action, attribute, or `posix_spawnp` failure would remain a typed `ProcessLauncherError`, not `ClientError.processNotRunning` (`Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift:150-284`; `CodexAppServerClient.swift:929-981`). The generic error can arise after spawn when:

- stdout EOF invalidates the transport and fails pending requests;
- the post-reader/PID-registration guard observes that teardown already cleared the process;
- a request or write interleaves after transport teardown;
- liveness invalidation or explicit teardown clears the transport (`CodexAppServerClient.swift:463-481,528-648,739-775,948-981,991-1073,1429-1471`).

The 10 Hz watcher seeing no Codex child is consistent with a child lifetime below 100 ms; it is not evidence that `posix_spawnp` was never called. Because the failed sessions have no thread ID, retained state cannot locate the loss more narrowly than post-spawn and pre-persisted-thread. Provisioning failure remains a distinct typed pre-spawn error, and routing readiness remains a distinct typed post-thread error (`CodexNativeSessionController.swift:478-488,1069-1088`; `CodexAgentModeCoordinator.swift:3674-3731,3995-4046`).

**Final verdict:** upstream issue 554 at this HEAD is a fresh per-session Codex transport loss exposed only by the worktree-bound work path, not an erroneous resume selection, not a prebinding controller-replacement race, and not a workspace-scoped environment cache. The source and records identify the exact RepoPrompt lifecycle and error fan-in, but the historical child-exit trigger remains unrecoverable without bounded stderr, termination status, and a persisted startup-attempt trace.

## Investigation Log

### Phase 1 — Environment triage (agent, live shell + live app probes)
**Hypothesis:** on-disk environment breakage (config corruption, codex/node/mise/PATH, codex 0.145.0 daemon).
**Findings:** all eliminated by wire-level probes (see Environment exoneration). Live app probes isolated the failing condition to worktree-bound Codex starts on `<work repo>`; matches pre-existing upstream issue 554 baselines.
**Conclusion:** RP-side code defect on the worktree-bound Codex start path; proceed to source investigation at the build's HEAD.

## Root Cause

**Operational root cause (the incident):** the 2026-07-20 upstream sync produced a local build branch (upstream/main + two selection-mirror commits) without upstream PR 568's `bugfix/codex-worktree-app-server-start` branch, and the build of 2026-07-20 16:09 UTC and the relaunch that followed put that regressed code live. Nothing on the machine changed on 07-22; the failure class had been continuous since 07-15 and simply surfaced whenever workflows dispatched worktree-bound Codex children.

**Technical root cause (the underlying upstream issue 554 defect, per Investigator Findings):** the code without upstream PR 568 projects the bound worktree path into the app-server process launch cwd (as well as protocol/sandbox cwd) and collapses all transport-loss modes into `processNotRunning` with no retained stderr/exit status. Under RepoPrompt's exact launch inputs the app-server transport dies within ~250 ms of a `<work repo>` worktree-bound start (fresh controller, no replacement race, global env capture — all ruled out as differentiators; the effective cwd/sandbox root and cwd-sensitive repo-local discovery are the only workspace-derived inputs). The exact child-death submechanism remains unattributable on builds without upstream PR 568 precisely because of the diagnostics gap upstream PR 568 closes; the manual-probe evidence shows cwd alone is not sufficient, so the trigger is specific to the app's launch-input combination.

### Eliminated along the way
- codex-cli 0.145.0, `~/.codex/config.toml`, auth, node resolution (both node shims), mise worktree trust, disk space, the new app-server daemon, login-shell env capture poisoning, MCP provisioning/routing readiness (distinct error strings), controller replacement races, and any repo-identity branch in the start path.
- The `<forked_session>` "restarted after a native resume failed" text as evidence of a failed first attempt — it is a synthetic continuity payload staged by worktree binding before any controller exists.
- Probe-harness artifact: `codex app-server < file` silently exits on stdin EOF racing the response; all early "environment failures" were this.

## Resolution (verified 2026-07-22)
1. Merged `bugfix/codex-worktree-app-server-start` (upstream PR 568, head `96872f7f`) into the local build branch; one snapshot-test conflict resolved; commit preflight, RepoPrompt build, `AgentRunWorktreeStartTests` (47), `CodexNativeSessionControllerGoalConfigTests` (19) all green.
2. Rebuilt and relaunched the debug app (`ALLOW_ADHOC_SIGNING=1 ./conductor app relaunch`; provenance now names the merge commit).
3. Four-probe smoke matrix all green, including the previously deterministic failure: work + `<work repo>` `worktree_create` explore probe → SMOKE4_OK.

Pre-existing, unrelated: the canonical ledger verifier reports missing=10/stale=1 for codemap/selection-mirror test IDs on this branch (present before the merge; untouched).

## Recommendations
1. Attach the live verification evidence to upstream PR 568 (deterministic repro matrix, ~250 ms persisted failure timelines, session-record analysis) — a maintainer offered fast-tracked review on upstream issue 554 and this is the strongest possible support.
2. Keep `bugfix/codex-worktree-app-server-start` in every local build until upstream PR 568 merges.
3. Optional cleanup: five throwaway probe worktrees under the RepoPrompt worktree folders of both repositories plus the probe tabs/sessions created during this investigation.

## Preventive Measures
- A local patch ledger and upstream-sync checklist now exist: every sync/rebuild must pass a `git merge-base --is-ancestor` check per OPEN ledger row before relaunch, and the upstream issue 554 smoke matrix runs before handing the app back for real work.
- Diagnose from the session store (`Workspaces/*/AgentSessions/*.json`) before trusting symptom recall — it reconstructs failure timelines across days and immediately falsified the "sudden 07-22 onset" framing.
- When probing `codex app-server` manually, keep stdin open; file-redirect harnesses produce false failures.
