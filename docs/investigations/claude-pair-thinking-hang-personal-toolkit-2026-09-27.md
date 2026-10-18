# Investigation: Claude Code pair agent stuck on "Thinking…" in the personal toolkit workspace

> Investigation report, observed 2026-09-27 on local build 45. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary
The Claude provider setting "RepoPrompt Only (Strict MCP)" was turned off in production CE on 2026-09-25 08:19 UTC. Since then, CE has launched Claude Code without `--strict-mcp-config`, so Claude loads the user's own MCP servers for the session cwd. For sessions in the personal toolkit's workspace (cwd: the toolkit repository), those include a long-standing entry for the RepoPrompt Classic proxy. The Classic app isn't running, so the proxy never answers, and Claude Code never finishes startup or begins the turn. CE shows "Thinking…" with no timeout for the whole wait. The configuration exposed the hang; the silent, unbounded "Thinking…" is a CE startup-supervision defect. Neither b45 nor the Claude Code version is involved.

## Symptoms
- A Claude Code `pair` session (Opus Latest 1M, High) in the personal toolkit's RepoPrompt CE workspace shows "Thinking…" for 30+ minutes on the prompt `hi`. Some sessions eventually respond.
- The same role works in other workspaces (the owner's multi-root workspace, others). Plain Claude Code outside RepoPrompt works.
- It persists across a RepoPrompt CE restart. It was first noticed the day after the b45 production promotion.

## Background / Prior Research

### Reproduction (2026-09-27 00:33 UTC)
- An MCP `agent_run start model_id=pair message="hi"` bound to the personal toolkit's window produced a session that stayed at `Running · Thinking…`.
- Child process: `claude -p --verbose --output-format stream-json --input-format stream-json --permission-prompt-tool stdio --allow-dangerously-skip-permissions --mcp-config <launch config> --disallowedTools …`, with the toolkit repository as cwd. No `--strict-mcp-config`.
- The children it spawned: the user's other MCP servers, **the RepoPrompt Classic proxy**, and `repoprompt_ce_cli --backend app` (from the RepoPrompt launch config). Every Claude child was at 0% CPU.
- No transcript for the new session was written while it was stuck.

### The inherited MCP servers
Without `--strict-mcp-config`, Claude Code also loads the MCP servers in the user's own Claude configuration for the session cwd. For the toolkit repository, those include an entry for the RepoPrompt Classic proxy. The Classic app isn't running.

### Classic proxy never answers when the Classic app is down
- A direct MCP `initialize` probe of the Classic proxy got no response in 25 s. It logs `Bootstrap connection lost (connectionFailed(... connectFailed(errno: 2))). Retrying in 0.5s` forever (attempt 45 at 25 s) and never exits.
- Claude Desktop's log for its own Classic entry shows the same retry loop every day since at least 2026-09-15, so Classic has been down the whole period, including Sep 24.

### Controlled Claude Code tests (outside RepoPrompt, empty scratch cwd, `--strict-mcp-config`)
| Claude Code | MCP config | Mode | Result |
|---|---|---|---|
| 2.1.283 | empty | `-p` text | `OK` in 8.3 s |
| 2.1.283 | Classic only | `-p` text | no output, killed at 150 s |
| 2.1.281 | Classic only | `-p` text | no output, killed at 150 s |
| 2.1.283 + `MCP_TIMEOUT=5000` | Classic only | `-p` text | no output, killed at 150 s |
| 2.1.281 | Classic only | stream-json (RepoPrompt's mode) | only `system/hook_*` events, no `system/init`, killed at 120 s |
| 2.1.283 | Classic only | stream-json | same as 2.1.281 |

A single unresponsive stdio MCP server blocks Claude Code headless startup before `system/init` on both versions, and `MCP_TIMEOUT` does not bound it.

### Transcript timing: queue → first recorded user turn (entrypoint `sdk-cli`)
- The toolkit repository on 2.1.281 (Sep 24, 07:51–11:48 UTC): 0 s, 0 s, 0 s, and one 38 s outlier.
- The toolkit repository on 2.1.283, from Sep 26 07:47 UTC: 962 s, 614 s, 201 s, 320 s, 234 s, 247 s, 363 s. The Sep 27 00:16 UTC `hi` session was dequeued at 00:16:10 and recorded the user turn only at 00:22:14, together with `[Request interrupted by user]`.
- `repoprompt-ce` (2.1.283, Sep 26–27): 0.0–0.5 s. Another personal project (2.1.283, Sep 26–27): 0.0–0.4 s.

### Release timing
- `local/v1.4.0-b45` tagged 2026-09-26 10:29 UTC. The installed `/Applications/RepoPrompt CE.app` binary is dated 2026-09-26 10:22 UTC.
- The first slow toolkit-repository session (Sep 26 07:47 UTC) predates the b45 install, so b44 was running. Other workspaces on b45 start instantly. **b45 is not the trigger.**
- Claude Code 2.1.283 was installed 2026-09-25 22:19 UTC, but 2.1.281 hangs identically in the controlled tests. **The Claude Code version is not the trigger.**

### Claude Code outside RepoPrompt
MP starts Claude Code outside RepoPrompt with `--strict-mcp-config`, which is why those sessions are unaffected.

## Investigator Findings

Source refs are at HEAD `40716eb1`. `git diff --stat local/v1.4.0-b45 -- Sources/RepoPrompt/Features/AgentMode Sources/RepoPrompt/Infrastructure/AI/Providers` is empty, so the lines below are also the b45 production lines. Times are UTC.

### Bottom line
The trigger is the **"RepoPrompt Only (Strict MCP)" Claude setting being turned off in production RepoPrompt CE on 2026-09-25 08:19:23 UTC**. The Classic entry in the user's Claude configuration for the toolkit repository dates from at least 2026-05-08. While strict mode was on, CE launched Claude with `--strict-mcp-config`, Claude ignored that entry, and the Classic proxy never started. With strict mode off, Claude loads every server in the user's Claude configuration for the cwd, and the dead Classic proxy blocks startup. The same hang happened during a 2-minute strict-off window on Sep 24; details under item 2.

### 1. Which persisted setting turns strict mode off — **Confirmed** (setting and storage); current value **inferred**, direct read blocked
**Decision path (verified):**
- `ClaudeNativeProcessSessionController.swift:1999–2003` appends `--mcp-config <path>`. It appends `--strict-mcp-config` only when `config.mcpStrictMode` is true.
- `ClaudeAgentModeCoordinator.swift:355,362` takes `effectiveMCPStrictMode` from `effectiveClaudeRuntimePermission` (`:1472–1493`), which calls `ClaudeControllerLaunchPolicy.resolve`.
- `ClaudeControllerLaunchPolicy.swift:16–21`: `.mcpSafeDefaults` forces `mcpStrictMode: true` and `allowNativeBashTool: false`. `:23–33`: `.userConfigured` and `.providerOverride` read `ClaudeAgentToolPreferences.mcpStrictModeEnabled(...)`.
- **(a) Sessions started from the Agent Mode UI:** `AgentTabSession.swift:218` defaults `permissionProfile` to `.userConfigured`. Strict mode therefore equals the Claude preference.
- **(b) Sessions started over MCP `agent_run` or `create_session`:** `AgentModeViewModel.swift:9593` sets the profile from `AgentModeProviderBindingService.permissionProfileForMCPActivation` (`AgentModeProviderBindingService.swift:71–90`). That function reads the global sub-agent policy (`AgentModePermissionPreferences.swift:20–28`, enum `:124`). `safeManaged` gives `.mcpSafeDefaults` (strict forced on). `inheritProviderSettings` gives `.userConfigured`, and `custom` gives `.providerOverride`. In both of those, strict mode equals the same Claude preference.
- The preference is `ClaudeAgentToolPreferences.mcpStrictModeEnabled` (`ClaudeAgentToolPreferences.swift:279–290`; setter `:292–304`). Production reads go through the secure store (`resolvedSecureStore`, `:481–489`): `secureStore.claudePermissions().mcpStrictModeEnabled ?? true`. The UserDefaults key `claudeCodeMCPStrictModeEnabled` (`:187`) is used only for injected non-standard suites. `defaults read com.pvncher.repoprompt.ce` contains no strict-mode or profile key, which confirms this.
- The UI writer is `Toggle("RepoPrompt Only (Strict MCP)")` at `AgentProviderPermissionControlsComponents.swift:393–395`, which applies `.mcpStrictMode(enabled:)`. The Agent Mode input bar has the same control at `AgentInputBar.swift:1466–1468`. Both paths persist through `AgentProviderPreferenceSnapshotStore.swift:247–248`.

**Where it is stored (verified):** the value lives in the macOS login Keychain as generic-password items. The account names come from decoding the byte arrays at `SecureStorageAccountCatalog.swift:74–88` (XOR 0x5A):
- Claude permissions (includes `mcpStrictModeEnabled`): account `rp.agent.permissions.claude.v1`.
- Sub-agent policy (`globalPolicyRaw`): account `rp.agent.permissions.subagent.v1`.
- The production app is signed `Authority=RepoPrompt CE Local Self-Signed Code Signing` (`codesign -dvv`), so it uses the service `com.pvncher.repoprompt.ce.local-self-signed.<fingerprint>.keychain.v<generation>` (`SecureKeyValueStorageBackend.swift:118–124`).

`security dump-keychain` (item attributes only, no secret payload) returned:

| Service (production local-self-signed) | Account | **Last modified** |
|---|---|---|
| `…local-self-signed…` | `rp.agent.permissions.claude.v1` | **2026-09-25 08:19:23** |
| `…local-self-signed…` | `rp.agent.permissions.subagent.v1` | 2026-09-23 11:44:59 |

**Current values: inferred, not read directly.** Reading the JSON payload needs `security find-generic-password -w`. That command is not in the item's access list, so it would show MP a Keychain access prompt, and I did not run it. The inference rests on runtime evidence:
- `claude.mcpStrictModeEnabled == false`: every CE Agent Mode session since Sep 25 08:22 loads the user's other MCP servers (item 2). Bash is enabled in those sessions, so they are not on the Safe Managed path, and on the non–Safe Managed path strict mode can only come from this value. This investigator session, started from production CE today, runs as `claude -p … --allow-dangerously-skip-permissions --mcp-config <launch config> --disallowedTools Write,Edit,Glob,Grep,Task,Monitor,SlashCommand,NotebookEdit,TodoWrite` (from `ps`): no `--strict-mcp-config`, and Bash is not disallowed.
- Sub-agent policy is `inheritProviderSettings` or `custom`, not `safeManaged`: the MCP-started reproduction session launched without `--strict-mcp-config`, and `.mcpSafeDefaults` would have forced it on.
- The production `app_settings` MCP surface doesn't expose either value. `agent_mode` lists only 4 unrelated keys.

### 2. When strict mode became effectively off — **Confirmed**
Method: sweep all 335 transcripts with a top-level `"entrypoint":"sdk-cli"`, keeping only CE Agent Mode sessions, meaning the `prompt_snapshot.systemPrompt` contains "RepoPrompt's MCP tools". Loaded MCP servers come from the structured `mcp_instructions_delta.addedNames` and the `prompt_snapshot.tools[].name` prefixes, not from prose. The output was a temporary table, not retained.
- **Latest session that loaded only `RepoPromptCE` at start:** a session in another personal project, 2026-09-25 07:30:35.
- **Earliest session in the persistent strict-off period:** a `repoprompt-ce` session, 2026-09-25 08:22:57. It loaded `RepoPromptCE` and the user's other MCP servers, with Bash enabled and `bypassPermissions`. That is **3.5 min after the Claude-permissions Keychain write at 08:19:23**.
- Every CE Agent Mode session from then through Sep 27 00:18 loads the user's other MCP servers, in this repository, another personal project, and two CE worktrees; that is about 40 sessions. Those folders have no Classic entry, so they start in 0.0–0.5 s. Every toolkit-repository session in the period (seven, from Sep 26 07:47) records no tool snapshot, which is the hung-startup signature.
- **Earlier short strict-off window, same hang:** two sessions that started CE-only on Sep 23 received mid-session deltas: one gained a user MCP server at 2026-09-24 07:50:42 and the other at 07:51:02. The second then dropped it at 07:52:27, which fits a controller relaunch after the strict setting flipped (`ClaudeAgentModeCoordinator.swift:373–390`). A toolkit-repository session started at 07:51:32 inside that window. Its first user turn was recorded at 07:52:10 together with `[Request interrupted by user]`, and it has no tool snapshot. That is the "38 s outlier" in the timing table: a hang that was interrupted, then strict mode went back on, and three later Sep 24 toolkit-repository sessions, from 08:01, started CE-only in under 10 ms.
- **The Classic entry is not new:** every backup of the user's Claude configuration back to 2026-05-08 contains it, and so does the live file. **This eliminates the open hypothesis** that the entry was added between Sep 24 and Sep 26.

Caveat: Keychain `mdat` keeps only the last write. The Sep 25 08:19:23 write is pinned to the strict-off flip by timing, not by reading the diff; permission mode or Bash could have changed in the same write.

### 3. Do b43→b44 or b44→b45 touch the strict/profile path? — **Eliminated**
- `git diff --name-only local/v1.4.0-b43..local/v1.4.0-b44` and `local/v1.4.0-b44..local/v1.4.0-b45`, filtered for `ClaudeAgentToolPreferences|ClaudeControllerLaunchPolicy|AgentModeProviderBindingService|AgentProviderPreferenceSnapshotStore|AgentProviderPermissionControlsComponents|AgentPermissionSecureStore|AgentModePermissionPreferences|ClaudeNativeProcessSessionController|ClaudeAgentModeCoordinator|SecureStorage|Keychain`, found no files in either range.
- `git diff <range> | rg -c 'strict-mcp-config|mcpStrictMode|subagentPermissionPolicy'` found 0 hits in both ranges.
- Tags: b43 2026-09-23 14:58 UTC, b44 2026-09-24 06:02 UTC, b45 2026-09-26 10:29 UTC. b44→b45 is start-gating fixes (`b2fb4b4f`, `72e11bdb`, `852c1455`, `1c74a5a5`, `8c09ef81`), Codex fixes, and MCP bootstrap readiness (`204a6ece`). The `ClaudeIntegratedAgentModeRunner.swift` hunk adds a `submissionID` and doesn't touch launch arguments. No migration of these preferences exists in either range.
- The strict-off flip (Sep 25 08:19 UTC) happened on b44, which was installed Sep 24, and it persisted into b45. This matches "b45 is not the trigger."

### 4. Pinned CE startup lines — **Confirmed**
| Item | Location | Meaning |
|---|---|---|
| Strict flag condition | `ClaudeNativeProcessSessionController.swift:1971` (`buildArguments`), `:1999–2003` | `--mcp-config` only when a launch config exists; `--strict-mcp-config` only if `config.mcpStrictMode`. |
| Nil strict mode falls back to the preference | `ClaudeCodeAgentConfig.swift:58, 68–69` | `mcpStrictMode ?? ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults:)`. |
| Secure-document default | `AgentPermissionSecureStore.swift:190, 200, 922–923` | New or fail-closed documents default to strict mode on. Only an explicit `false` turns it off. |
| `initializeIfNeeded` | `ClaudeNativeProcessSessionController.swift:643`, called from `:403` | Sends `initialize`. |
| Its `sendControlRequest` has no timeout | `:648` `try await sendControlRequest(request: request)` | No `timeoutSeconds` argument is passed. |
| `sendControlRequest` default | `:780–782` `timeoutSeconds: TimeInterval? = nil`; `:800–803` arms a timeout task only `if let timeoutSeconds, timeoutSeconds > 0` | With nil, it awaits the continuation until Claude responds or the process ends. |
| `sdkConnectTimeoutSeconds` | declared `ClaudeCodeAgentConfig.swift:20`, default `10` at `:53`/`:124`, clamped `:162`; passed on at `ClaudeCompatibleProviderRuntimeBridge.swift:101` into `ClaudeCompatibleProviderPlugin.swift:118/157` | Stored and passed along, but nothing reads it to arm a timeout. `rg -n sdkConnectTimeoutSeconds Sources Packages` finds only declarations, assignments, and one test argument. |
| "Thinking…" and `.running` before provider init | `ClaudeIntegratedAgentModeRunner.swift:94–95`; provider init starts at `:128–129` (`providerInitializationStarted`, `sendClaudeNativeMessage`) | The UI shows a running "Thinking…" state before the Claude process has initialized. |
| View fallback label | `AgentModeView.swift:3322` `Text(runInteractionSnapshot.runningStatusText ?? "Thinking…")` | This label shows for the whole hang. |

### Why Sep 24 toolkit-repository sessions started instantly and Sep 26+ sessions hung
Strict mode was **on** for the Sep 24 toolkit-repository sessions that started instantly. They loaded only `RepoPromptCE`, and `--strict-mcp-config` made Claude skip the Classic entry. The one Sep 24 session that started during the brief 07:50–07:52 strict-off window hung and was interrupted. On Sep 25 08:19 the setting was turned off and stayed off. The first toolkit-repository session afterwards, Sep 26 07:47, and every later one loaded the Classic proxy and blocked before `system/init`. Other workspaces also lost strict mode then, but they have no Classic entry, so they only gained the user's other servers and still started instantly.

### Candidate fix locations (listed only; no changes made)
- Setting: turn "RepoPrompt Only (Strict MCP)" back on (`AgentProviderPermissionControlsComponents.swift:393`). Separately, remove the stale Classic entries from the user's Claude configuration.
- A bounded `initialize`: `ClaudeNativeProcessSessionController.swift:648` passes no timeout to `sendControlRequest` (`:780–803`), and `sdkConnectTimeoutSeconds` (`ClaudeCodeAgentConfig.swift:20`) is never read. A timeout there would turn the silent hang into a visible startup failure. Note that Claude itself blocks before `system/init`, so any timeout has to cover the whole pre-init phase.
- Status honesty: `ClaudeIntegratedAgentModeRunner.swift:94–95` and `AgentModeView.swift:3322` report "Thinking…" before the provider is up.

## Investigation Log

### Phase 1 — Claude Code MCP startup (outside CE)
**Hypothesis:** an unresponsive stdio MCP server blocks Claude Code headless startup.
**Findings:** confirmed on 2.1.281 and 2.1.283, in both `-p` text and stream-json modes. `MCP_TIMEOUT` does not bound it (see "Controlled Claude Code tests").
**Conclusion:** Confirmed.

### Phase 1 — Classic entry added recently
**Hypothesis:** the Classic entry for the toolkit repository was added between Sep 24 and Sep 26, which would explain why Sep 24 sessions started instantly.
**Findings:** the entry is present in every backup of the user's Claude configuration back to 2026-05-08, and shell history and transcripts show nothing adding it in the window.
**Conclusion:** Eliminated. Sep 24 sessions started instantly because strict mode was on (Investigator Findings, item 2).

### Phase 1 — b45 promotion or Claude Code 2.1.283 as trigger
**Findings:** the first slow session predates the b45 install. b43→b44 and b44→b45 touch no strict/profile code. 2.1.281 hangs identically.
**Conclusion:** Eliminated.

### Phase 4 — Where the stall sits relative to CE's SDK handshake
**Hypothesis:** Claude blocks before answering CE's SDK `initialize` control request (`ClaudeNativeProcessSessionController.swift:648`), so a timeout on that request would catch the hang.
**Method:** a scratch probe mirrors the controller's order. It sends `{"type":"control_request","request_id":"init-1","request":{"subtype":"initialize"}}`, waits for the `control_response`, then writes the user message. Claude Code 2.1.283, `--permission-prompt-tool stdio --strict-mcp-config`, run with an empty MCP config and with a Classic-only config.
**Findings:**
| MCP config | `initialize` response | User message written | `system/init` | Result |
|---|---|---|---|---|
| empty | 0.3 s, `success` | 0.3 s | 0.5 s | `OK` at 2.6 s |
| Classic only | 0.3 s, `success` | 0.3 s | never | stalled; only `system/hook_*` events through 90 s |

**Conclusion:** Eliminated. Claude acknowledges `initialize` immediately and stalls **after** CE writes the user message, before stream `system/init`. A timeout on `:648` alone would not catch this hang. Startup supervision has to span "user message written" → "stream `system/init` observed" for a cold process.

## Root Cause
Two layers.

**Trigger (configuration, works as designed).** "RepoPrompt Only (Strict MCP)" is off (Keychain item `rp.agent.permissions.claude.v1` last written 2026-09-25 08:19:23 UTC; the flip is tied to that write by transcript timing, not by reading the value). With strict off, `ClaudeNativeProcessSessionController.swift:1999–2003` omits `--strict-mcp-config`, so Claude also loads user-scope and project/local-scope servers for the cwd. The documented off-state text reads: "Other MCP servers from your Claude config will also be loaded" (`AgentProviderPermissionControlsComponents.swift:393–406`). MCP-started sessions follow the same setting unless the sub-agent policy is Safe Managed (`AgentModeProviderBindingService.swift:71–90`, `ClaudeControllerLaunchPolicy.swift:16–33`). For the personal toolkit's workspace, the cwd is the workspace's first repo path, the toolkit repository (`AgentModeViewModel.swift:2213–2218`). Its configuration loads the Classic proxy, which retries its socket connect forever while the Classic app is down. Claude Code never completes startup.

**Defect (CE).** CE marks the run `.running` / "Thinking…" before the provider has initialized (`ClaudeIntegratedAgentModeRunner.swift:94–95`, before provider init at `:128–129`; label fallback `AgentModeView.swift:3322`). Nothing supervises the cold-start window. Startup control requests carry no timeout (`:648`, `:780–803`), `sdkConnectTimeoutSeconds` (`ClaudeCodeAgentConfig.swift:20`) is never read, and the only readiness gate (`MCPBootstrapLease.releaseWhenRouted`) runs after send and covers only CE's own server. A live Claude process that never emits `system/init` therefore shows "Thinking…" indefinitely, with no user-facing failure or diagnosis.

## Recommendations
1. **Immediate unblock (MP's choice of one or both):**
   - Turn "RepoPrompt Only (Strict MCP)" back on (Settings → Agent providers → Claude, `AgentProviderPermissionControlsComponents.swift:393`), unless the Sep 25 change was made deliberately to give agents the user's other MCP servers.
   - Remove the stale Classic entries from the user's Claude configuration. This keeps strict-off workable.
2. **CE defect: supervise Claude cold start.** For a newly spawned (cold or `--resume`) process, arm a startup watchdog from spawn through the first stream `system/init`. Per the Phase 4 probe, it must cover the post-user-message window, not only `initialize` (`ClaudeNativeProcessSessionController.swift:643–671`, `:780–803`). Scope it to the transport generation so it can't kill a replacement process. Leave warm sessions unaffected. Route timeout through the existing attempt/terminal-commit path, and don't auto-replay the user message. Use a soft "taking longer than expected" warning plus a generous or configurable hard limit, since Docker-backed servers can be slow but healthy. Either wire `sdkConnectTimeoutSeconds` into this or remove it.
3. **CE defect: honest startup status.** Replace the initial "Thinking…" (`ClaudeIntegratedAgentModeRunner.swift:94`) with a startup status such as "Starting Claude Code…". Transition on an explicit stream-`system/init`-observed milestone, not on any `.runtimeInit` (session-ID and SDK-init events also emit it). On timeout, say which MCP servers were configured but never reported, where known.

## Resolution (2026-09-27)
- Strict MCP stays off deliberately, so agents keep the user's other MCP servers.
- The stale Classic entries were removed from the user's Claude configuration. A before-and-after comparison showed those removals and no other change.
- Verified in production CE: a `pair` session with prompt `hi` in the personal toolkit's workspace started its turn 0.5 s after dequeue (previously 200–962 s) and replied 4.1 s later. It loaded `RepoPromptCE` and the user's other MCP servers.

- The CE startup-supervision and status defects (Recommendations 2–3) are tracked in distribution issue #124, deferred.

## Preventive Measures
- Keep one RepoPrompt edition per Claude process. Stale Classic entries in the user's Claude configuration become latent hangs whenever strict mode is off.
- Treat "strict MCP off" as a mode that inherits the user's whole MCP fleet. A dead server anywhere in that fleet should surface as a visible startup failure, not a silent spinner.
