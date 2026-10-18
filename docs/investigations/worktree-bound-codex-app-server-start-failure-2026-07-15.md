# Investigation: Worktree-bound Codex app-server startup failure

> Investigation report, observed 2026-07-15 on the debug bundle built from `release/mp-patches` at `96df8c52`. It records what was true then. Where it disagrees with a current document, the current document is right.

Status: complete

## Summary

RepoPrompt CE has two confirmed defects at this boundary. A worktree binding is unnecessarily projected into both the Codex app-server process launch directory and the Codex execution directory, making provider bootstrap sensitive to repository-local tooling before the thread starts. The client also collapses several startup and transport-loss paths into `processNotRunning` while retaining neither stderr nor process termination status. A cwd-sensitive wrapper exit is the strongest explanation for the July 15 incident, but the retained evidence cannot prove that mise, Node, trust handling, or even immediate child exit was the specific trigger.

Reusing a healthy root app-server is protocol-compatible but does not fit RepoPrompt's current per-session ownership model. The smallest robust correction is to keep one app-server per session, launch it from the binding's owning logical root, and continue sending the worktree path as the Codex thread, turn, and sandbox cwd.

## Symptoms

- A Codex `agent_run op=start` without a worktree binding starts and completes from the primary workspace root.
- A Claude Code start bound to the same app-managed worktree starts and completes.
- Codex starts bound through either `worktree_id` or `worktree: "@branch:<name>"` create and queue a session, then fail with `Codex native start failed: Codex app-server process is not running.`
- The existing RepoPrompt child process tree still contains a live Codex app-server wrapper and native process at failure time.
- A worktree-bound attempt does not leave an additional Codex app-server process visible.
- Killing stale debug CLI daemons and fully restarting RepoPrompt CE twice does not change the behavior.
- Worktree-bound Codex starts worked in the same workspace around 2026-07-09 through 2026-07-13; the failure was first observed on 2026-07-15.

## Background / Prior Research

- `docs/investigations/codex-appserver-and-issue-triage-2026-07-12.md` established that Codex app-server clients/controllers are per session or tab, that idle servers are intentionally retired, and that older builds could collapse startup detail into the same generic “process is not running” message. The current report treats the worktree-only isolation as a distinct regression until the startup path and current build history prove otherwise.
- The target repositories keep mise tool-version configuration at the root, so each fresh worktree also contains it, which may affect cwd-sensitive executable or environment resolution.

### Codex protocol and mise behavior

- Current Codex app-server v2 accepts `cwd` on `thread/start`, `thread/resume`, and `turn/start`; one initialized app-server can keep multiple threads with different working directories. Reusing a healthy process is therefore protocol-compatible, although RepoPrompt may still choose per-session processes for isolation. Sources: [official app-server documentation](https://learn.chatgpt.com/docs/app-server), [v2 protocol source](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2.rs), and [app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md).
- mise discovers configuration from the invocation cwd and its parents, while shims select tools using `PWD`. Before mise v2026.7.5, a linked worktree's distinct config path could require separate trust; v2026.7.5 added main-checkout-to-worktree trust sharing, except in paranoid mode or when explicitly ignored. Sources: [mise configuration](https://mise.jdx.dev/configuration.html), [shims](https://mise.jdx.dev/dev-tools/shims.html), [trust](https://mise.jdx.dev/cli/trust.html), and [v2026.7.5 release](https://github.com/jdx/mise/releases/tag/v2026.7.5).
- The npm Codex entry point uses `#!/usr/bin/env node`. If `node` resolves through a mise shim, a cwd-specific mise failure can occur before Node or the Codex wrapper starts. The parent launcher can still retain that stderr if it attaches capture before spawn. Source: [Codex npm entry point](https://github.com/openai/codex/blob/main/codex-cli/bin/codex.js).

### Git archaeology

- Three July 13 commits introduced a Codex-only fail-closed MCP readiness chain: `f80e2005` added throwing routing readiness, `d39eebc6` validated Codex MCP provisioning before app-server launch, and `0df1ef7f` converted an unconfirmed route into terminal startup failure. These commits could amplify a worktree-specific routing mismatch, but the installed debug bundle reports provenance commit `96df8c52`, which does not contain them by ancestry; the bundle's dirty marker prevents treating that provenance as absolute exclusion.
- No July 9–15 commit changed the existing cwd projection itself: `CodexNativeSessionController` passes the selected workspace path to `CodexAppServerClient`, which uses it both as process cwd and thread cwd. The bound worktree therefore changes app-server process cwd even though Codex protocol does not require a separate cwd-bound server.
- `48e1171b` later improved process-launch error classification without changing Codex cwd, environment construction, or executable resolution. The debug bundle predates this diagnostic hardening by ancestry.
- The July 9 `text_elements` protocol correction occurs after startup and does not explain the worktree-only provider-start boundary.

## Investigator Findings

### Verdict

The source confirms an unnecessary coupling. In the ordinary primary-root case, one resolved path supplies the Codex app-server process cwd. The same path supplies the Codex thread and turn cwd. The client preserves no startup stderr or exit status, so the retained evidence cannot show why the observed child exited. The proposed diagnosis is a **confirmed product defect with a plausible incident mechanism**, not a fully proven live root cause.

Two parts of the proposed diagnosis require narrower wording:

- The exact `processNotRunning` message strongly fits stdout EOF or an immediate-exit race during initialization, but it does not require that path. Liveness invalidation, controller shutdown, deinitialization, and process/write interleavings can produce the same error.
- A stable launch cwd is safe only when it uses the worktree binding's owning logical root and controller identity tracks both paths. `activeWorkspace.repoPaths.first` is insufficient for secondary roots in a multi-root workspace.

### Proposition assessment

| Proposition | Finding | Confidence |
| --- | --- | --- |
| 1. Bound worktree path is used for process and protocol cwd; unbound uses the primary root. | **Confirmed for a binding whose logical root matches the active workspace's first repository; qualified for multi-root workspaces.** | High |
| 2. The exact error requires a spawned child that exits or reaches EOF during initialize. | **Disproved as a requirement.** Early child exit is the leading incident explanation, while several lifecycle races emit the same text. Direct synchronous chdir/spawn failure, ordinary initialize timeout, MCP route timeout, and a cwd-keyed registry miss do not emit this exact error in the selected source. | High for the code-path classification; medium-high for early exit as the incident explanation |
| 3. There is no cwd-keyed process registry and clients are session-owned. | **Confirmed in production source.** Reusing another session's process would change ownership and isolation architecture. | High |
| 4. Stable process cwd can be separated safely from worktree protocol cwd. | **Confirmed with conditions.** Preserve the worktree for thread, turn, sandbox, and worktree-local diagnostics; use the owning logical root for process launch; include both paths in replacement identity. | High for start/resume/turn/sandbox/PID policy; medium for complete multi-root wiring until covered by a test |
| 5. Mise is plausible but not provable from retained evidence. | **Confirmed.** Mise is one member of the broader class of cwd-sensitive wrapper or toolchain failures. | Medium for plausibility; low for mise as the specific incident trigger |

### 1. Bound and unbound path projection

Production chooses `activeWorkspace.repoPaths.first` as the fallback Codex workspace root and passes the resolved runtime path into the Codex controller factory (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:1412-1423,1429-1458`). The resolver returns a binding's `worktreeRootPath` only when its `logicalRootPath` matches that fallback; otherwise it returns the fallback root (`Sources/RepoPrompt/Features/AgentMode/Services/AgentWorktreeRuntimeWorkspaceResolver.swift:4-29`). The coordinator records that runtime path as the controller workspace identity (`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:3739-3756`).

The controller then uses the same `workspacePath` in four distinct roles:

- process cwd through `client.updateWorkingDirectory(workspacePath)` before startup (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1052-1065`);
- `thread/resume.cwd` and `thread/start.cwd` (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1069-1087,1099-1116`);
- `turn/start.cwd` (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1360-1373`);
- the turn sandbox workspace (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1377-1389,7942-7960`).

The client passes its configured cwd directly to `ProcessLauncher.spawn` (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexAppServerClient.swift:920-958`). This proves the ordinary bound-primary-root and unbound traces. The blanket multi-root version is not: a secondary-root binding is not selected by the current first-root resolver when a primary fallback exists.

### 2. Exact error fan-in and eliminated alternatives

The displayed text comes from `CodexAppServerClient.ClientError.processNotRunning` (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexAppServerClient.swift:169-181`) and is prefixed by the coordinator after the controller propagates the error (`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:4110-4119`).

The strongest matching path is:

1. `posix_spawnp` succeeds and readers are attached.
2. The initialize request is registered.
3. The child closes stdout.
4. stdout EOF invokes transport termination with the default `.processNotRunning` failure.
5. the pending initialize continuation receives that error.

The relevant code is `CodexAppServerClient.swift:886-927,948-981,991-1022,1064-1073` and `CodexAppServerClient.swift:528-590,739-775`. A neighboring race reaches the post-reader guard at `CodexAppServerClient.swift:979-981` after teardown has already cleared the process.

Other paths can produce the same error:

- a failed liveness probe invalidates an existing transport with `.processNotRunning` (`CodexAppServerClient.swift:463-481`);
- a request or JSON write that interleaves after transport teardown sees no process or stdin descriptor (`CodexAppServerClient.swift:739-743,1429-1439`);
- emergency deinitialization fails pending requests with the same error (`CodexAppServerClient.swift:630-648`);
- coordinator replacement clears the session controller and asynchronously shuts down the old controller, creating a possible startup teardown race (`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:3486-3532`).

The following alternatives are eliminated for the exact reported text in this checkout:

- **Synchronous chdir failure:** `posix_spawn_file_actions_addchdir_np` failure remains `ProcessLauncherError.changeDirectoryFailed` (`Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift:168-181`).
- **Synchronous pipe, spawn-action, attribute, or spawn failure:** these remain typed `ProcessLauncherError` cases, including `spawnFailed` (`ProcessLauncher.swift:150-181,184-260,269-284`).
- **Executable resolution failure:** this throws `.executableUnavailable` before spawn (`CodexAppServerClient.swift:920-944`).
- **Reader setup failure:** this throws `.transportReadSetupFailed` and tears down with that same error (`CodexAppServerClient.swift:963-978`).
- **Ordinary initialize timeout:** the timed-out initialize continuation receives `.requestFailed` with the timeout message; only other pending requests are poisoned with `.processNotRunning` (`CodexAppServerClient.swift:1524-1548`).
- **Ordinary stdin write failure:** this becomes `.transportWriteFailed`; only a missing-process or missing-descriptor interleaving uses `.processNotRunning` (`CodexAppServerClient.swift:1429-1471`).
- **MCP route timeout:** routing wait occurs only after the controller has an active thread, and its Boolean result is discarded in this checkout (`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:3875-3925`; `Sources/RepoPrompt/Infrastructure/MCP/MCPBootstrapLease.swift:240-291`).
- **MCP discovery provisioning:** `ensureCodexServerForDiscovery()` has its result discarded before process start and cannot directly construct the client error (`CodexNativeSessionController.swift:1052-1058`).
- **Stale cwd registry lookup:** no shared Codex app-server registry participates in this path.

The source proves that direct synchronous chdir/spawn and route timeout are not the error source. It does not prove that the incident necessarily reached EOF, because no retained event distinguishes EOF from concurrent teardown.

### 3. Process ownership and reuse

Production constructs a new `CodexAppServerClient` inside the controller factory (`AgentModeViewModel.swift:1429-1458`). Each tab session stores its own controller and generation (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift:479-500`), and the controller privately owns its client (`CodexNativeSessionController.swift:557-565`). Replacement shuts down that exact controller (`CodexAgentModeCoordinator.swift:3486-3532`), while controller deinitialization clears expected-PID ownership and stops an owned client (`CodexNativeSessionController.swift:742-776`).

A repository-wide construction search found production factories and diagnostic/test helpers, but no process registry keyed by cwd. Reusing the healthy root process would require shared ownership for JSON-RPC request IDs, notification and server-request streams, expected-PID policy, process feature configuration, shutdown, idle retirement, and failure blast radius. It is protocol-compatible, but it is not the smallest fix.

### 4. Safe cwd separation and required conditions

The narrow fix should retain one client per session and pass two immutable paths into the Codex controller:

- **app-server launch cwd:** the selected binding's `logicalRootPath`, or the selected logical root when unbound;
- **execution cwd:** the binding's `worktreeRootPath`, or the same logical root when unbound.

Only `client.updateWorkingDirectory` should use the launch cwd. Thread start and resume should keep the execution cwd. Turn start and sandbox construction should also keep it. Raw event logs and workspace diagnostics should remain worktree-local.

Expected-PID routing is independent of cwd. Registration identity consists of PID, client name, and run ID (`CodexAppServerClient.swift:351-388`), and the spawned PID is registered after reader setup (`CodexAppServerClient.swift:948-981`).

Controller replacement currently compares only `codexControllerWorkspacePath` (`CodexAgentModeCoordinator.swift:3703-3711`) and stores only that value (`AgentModeViewModel+TabSession.swift:498-500`). The replacement identity must include both launch cwd and execution cwd; otherwise a logical-root change could retain a process launched from the wrong root.

For multi-root workspaces, always using `repoPaths.first` would preserve the current primary-root bias. The launch cwd should come from the chosen binding's `logicalRootPath`, and the resolver/factory boundary must carry that owner explicitly. This also avoids granting the primary checkout sandbox access or moving worktree-specific logs away from the execution root.

### 5. Live trigger and build provenance

The stderr reader drains output but retains it only as optional debug printing (`CodexAppServerClient.swift:1025-1050`). Teardown discards the result of `ProcessTermination.terminateAndReap` (`CodexAppServerClient.swift:681-699`). The incident left no exit code, signal, or stderr tail from which to identify the launcher failure.

The installed debug bundle's retained provenance reports branch `release/mp-patches`, commit `96df8c5282e2d31e908dbb64ad3750625350e723`, build time `2026-07-13T02:52:27Z`, and `dirty: true`. The current checkout is also at `96df8c52`; its tracked source has no current modifications, while investigation and prompt-export files are untracked. The provenance format records only a Boolean dirty flag, not the files or diff present at build time (`Scripts/package_app.sh:344-384`). Byte-for-byte correspondence between the installed artifact and commit `96df8c52` cannot be established.

Mise remains plausible because the app-server wrapper is launched under the worktree cwd and cwd-sensitive tool selection can fail before JSON-RPC initialization. The same evidence also fits any other cwd-sensitive wrapper, shim, trust rule, runtime lookup, or repository-local tool configuration. Without retained startup stderr or an incident-time wrapper trace, mise cannot be elevated above that class of explanations.

### Concrete fix and verification recommendations

1. **Separate launch and execution cwd at the controller boundary.** Extend the production factory and `CodexNativeSessionController` initializer with an app-server launch cwd derived from the binding's owning logical root. Keep the existing workspace path for protocol requests, sandbox policy, logs, and diagnostics.
2. **Track both paths in controller identity.** Recycle the controller if either the launch cwd or execution cwd changes.
3. **Preserve bounded startup diagnostics.** Add a bounded stderr tail to `CodexAppServerClient`, retain exit status or signal from process reaping, and introduce a startup process-exit error that includes executable, cwd, termination status, and stderr tail. Reserve bare `.processNotRunning` for absent or concurrently torn-down transports.
4. **Extend the existing subprocess fixture.** `Tests/RepoPromptTests/AgentMode/Codex/CodexNativeSessionControllerGoalConfigTests.swift:85-160,362-443` already launches a Python fake app-server and records JSON-RPC. Make it record `os.getcwd()`, fail with a fixed status and stderr marker when launched from a simulated worktree, and assert that a root-launched process still receives the worktree in `thread/start`, `thread/resume`, and `turn/start`.
5. **Add focused startup-failure diagnostics coverage.** A new `CodexAppServerClientStartupFailureTests` fixture should emit more stderr than the chosen bound. A unique tail marker and fixed exit status must survive in the resulting error. Assert cwd, executable, truncation behavior, invalid UTF-8 handling, and empty-stderr behavior. Explicit `stop()` must remain classified as an intentional shutdown.
6. **Cover composition and multi-root behavior without a real provider.** Extend the factory recorder in `Tests/RepoPromptTests/MCP/AgentRunWorktreeStartTests.swift` with unbound, existing, created, inherited, and secondary-root cases. For the secondary-root case, assert that launch cwd equals the binding's `logicalRootPath`. Assert separately that execution cwd equals its `worktreeRootPath` rather than `repoPaths.first`.
7. **Cover lifecycle replacement.** Add a coordinator test proving that changes to either launch cwd or execution cwd replace and stop the old controller, while unchanged pairs reuse it.

## Investigation Log

### Phase 1 - Initial triage

**Hypothesis:** Worktree binding changes the Codex provider's launch cwd or app-server lookup key, exposing either cwd-sensitive environment resolution, a per-worktree server-registry miss, or a recent lifecycle regression.

**Findings:** The isolation matrix rules out general Codex authentication/model failure, general worktree creation failure, and a workspace-wide dead app-server. The decisive boundary is Codex plus worktree binding.

**Evidence:** User-supplied same-session matrix and process observations in the bug report; prior investigation listed above.

**Conclusion:** Trace the bound and unbound startup paths, inspect recent git history, and independently test cwd/mise behavior before choosing between reuse and diagnostic-surfacing fixes.

### Phase 1.5 - External behavior and regression history

**Hypothesis:** Codex might require one app-server per cwd, or mise trust might explain the worktree-only boundary.

**Findings:** Codex app-server supports per-thread and per-turn cwd overrides, so process reuse across working directories is protocol-compatible. Mise configuration and shim resolution are cwd-sensitive, but current mise versions can share trust from a main checkout to linked worktrees. Git history showed later Codex-only fail-closed MCP readiness changes, while the installed dirty debug provenance predates them by ancestry.

**Evidence:** Codex app-server protocol and mise documentation linked under Background / Prior Research; commits `f80e2005`, `d39eebc6`, `0df1ef7f`, and installed provenance `96df8c52`.

**Conclusion:** A separate app-server is an integration ownership choice, not a Codex cwd requirement. Mise remains a plausible trigger class, not a proven cause.

### Phase 2 - Startup-path context

**Hypothesis:** Worktree binding changes either provider routing or the Codex process launch environment before thread creation.

**Findings:** The selected path flows from `agent_run` worktree resolution through `AgentWorktreeRuntimeWorkspaceResolver`, the Codex coordinator, and `CodexNativeSessionController` into both `CodexAppServerClient` process cwd and Codex protocol cwd. MCP route waiting occurs after an active thread in the selected checkout and cannot directly produce this pre-thread client error.

**Evidence:** Source paths and line references in Investigator Findings sections 1 and 2.

**Conclusion:** The worktree path is projected one layer too far into provider bootstrap.

### Phase 3 - Independent path and lifecycle verification

**Hypothesis:** The generic message uniquely proves immediate child exit, and a healthy root process could be reused without larger changes.

**Findings:** Immediate child exit or stdout EOF best matches the process observation, but other teardown and liveness races can emit the same client error. Clients, transports, expected-PID policy, and shutdown are session-owned; no cwd-keyed process registry exists.

**Evidence:** Investigator Findings sections 2 and 3; 37 cited source locations were checked across 15 files.

**Conclusion:** Preserve per-session process ownership. Separate launch cwd from execution cwd and improve typed startup diagnostics.

### Phase 4 - Live read-only application check

**Hypothesis:** The investigation may be routed to the wrong RepoPrompt window or an inactive app state.

**Findings:** The running RepoPrompt CE window is the owner's multi-root workspace on `release/mp-patches`. The pair investigator and its three focused probes are visibly completed in the active investigation task.

**Evidence:** RepoPrompt accessibility state for an investigation window.

**Conclusion:** The report and delegated evidence belong to the intended live workspace. No provider restart was needed for the source-level diagnosis.

## Root Cause

The confirmed root cause of **worktree-sensitive provider bootstrap exposure** is a cwd-model defect. `AgentWorktreeRuntimeWorkspaceResolver` selects the bound worktree, and `CodexNativeSessionController` uses that single value for app-server process cwd, `thread/start`, `thread/resume`, `turn/start`, and sandbox policy. Only the execution-facing protocol and sandbox layers require the worktree path. Launching the npm/Node wrapper there unnecessarily makes Codex provider startup depend on worktree-local tool configuration.

The confirmed diagnostic defect prevents attribution of the historical trigger. `CodexAppServerClient` drains stderr without retaining a bounded tail, discards the process reaping result, and maps several transport-loss paths to `.processNotRunning`. The coordinator then publishes the generic client description as `Codex native start failed: Codex app-server process is not running.`

The strongest incident explanation is a short-lived child or wrapper failure before JSON-RPC initialization, because no additional app-server remained visible after the attempt. That inference is not unique. Liveness invalidation, controller shutdown or deinitialization, and request/write interleavings after teardown can produce the same error. The incident's exit code, signal, stderr, and precise trigger are unrecoverable from retained state.

Mise is therefore a plausible mechanism within a broader class of cwd-sensitive wrappers, shims, trust rules, and runtime resolution failures. It is not a proven cause.

### Eliminated explanations

- A synchronous working-directory, pipe, spawn-action, attribute, or `posix_spawn` failure would preserve a typed `ProcessLauncherError` rather than this message.
- Executable resolution and reader setup failures have separate typed errors.
- An ordinary initialize timeout or typed stdin write failure has a different error path.
- MCP route waiting occurs after an active thread in the selected checkout; ordinary route timeout does not construct this client error.
- No shared app-server registry performs a cwd-keyed lookup.
- Codex protocol does not require a separate process for each cwd.
- Claude's success proves that the worktree exists and is accessible through the Claude stack; it does not validate the Codex npm/Node launcher path.

### Remaining uncertainty

- The installed debug bundle reports commit `96df8c52` with `dirty: true`, so byte-for-byte correspondence with the selected checkout is unproven.
- The exact incident path among immediate exit, EOF, liveness invalidation, and teardown races is unknown.
- Secondary-root worktree creation remains outside the current product scope, but inherited multi-root bindings require the cwd model to derive both paths from the same owning root.

## Recommendations

1. **Separate the path pair at the workspace resolver boundary.** Add a projection containing app-server launch cwd and execution cwd. For a bound session, derive both from the same binding: `logicalRootPath` for launch and `worktreeRootPath` for execution. For an unbound session, use the selected logical root for both. Do not independently substitute `activeWorkspace.repoPaths.first`.
2. **Preserve per-session process ownership.** Keep constructing one `CodexAppServerClient` per Agent session. Pass the launch cwd only to `client.updateWorkingDirectory`; retain the execution cwd for thread start/resume, turn start, sandbox policy, raw logs, and workspace diagnostics.
3. **Track both paths as controller identity.** Update `CodexAgentModeCoordinator` and `AgentModeViewModel+TabSession` so a change to either launch cwd or execution cwd replaces and stops the old controller. This prevents a correct execution cwd from retaining a process launched under the wrong logical root.
4. **Add the provider-boundary regression harness.** Extend `CodexNativeSessionControllerGoalConfigTests` so the fake app-server records `os.getcwd()`, fails from a simulated worktree, succeeds from its owning logical root, and records the worktree in start, resume, turn, and sandbox payloads.
5. **Cover composition and multi-root projection.** Extend `AgentRunWorktreeStartTests` for unbound, existing, created, inherited, missing, and secondary-root projections. The secondary-root test should validate the resolver/factory contract without expanding user-facing worktree creation scope.
6. **Preserve actual startup failure details.** In `CodexAppServerClient`, retain a bounded stderr tail and observed exit status or signal. Add a typed process-exit error containing executable, cwd, termination status, and stderr tail. Keep explicit shutdown, liveness invalidation, and teardown races distinct rather than relabeling them as observed process exits.
7. **Test diagnostic bounds and lifecycle replacement.** Add `CodexAppServerClientStartupFailureTests` for stderr truncation, invalid UTF-8, empty stderr, exit status, signal, and intentional stop. Add coordinator coverage showing that either-path changes replace the controller and stale events from the retired generation cannot affect the replacement.

Shared app-server pooling, Claude startup changes, machine-specific mise workarounds, secondary-root worktree product expansion, and later MCP fail-closed behavior are outside this fix boundary.

## Preventive Measures

- Model provider launch context separately from task execution context whenever a protocol supplies its own cwd field.
- Preserve bounded child stderr and termination metadata at the process boundary before translating failures into provider-level errors.
- Test worktree bindings at the real provider-start boundary rather than stopping at binding propagation.
- Include multi-root ownership in path identity; never pair a worktree from one logical root with the launch directory of another.
- Keep process pooling as an explicit architecture decision because it changes transport, routing, lifecycle, and failure-isolation ownership.
