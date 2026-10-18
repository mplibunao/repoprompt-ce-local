# Investigation: Codex Thread RepoPrompt Export Failures

> Investigation report, observed 2026-08-25 to 2026-08-26 on `main` at `2003d6c1`, rechecked at `be882cb7`. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary

Investigation complete. Two provider-independent boundaries are ready for redacted issue review: large app-backed export transport survival and concurrent same-workspace Agent admission persistence. Three Codex lifecycle and identity findings remain evidence-gated. They concern empty completion, resume identity and readiness, and provider-thread ownership during reactivation. Context Builder itself completed successfully; the bounded export that followed it failed.

## Symptoms

- Two Codex Explore sessions reported `Completed` despite producing no assistant turn; related recovery attempts failed with `session not ready` or a missing saved thread ID.
- Reactivating one empty session returned content from an unrelated task and renamed the session, despite the stored pre-reactivation log containing only the intended prompt.
- Context Builder completed after about 9 minutes 37 seconds with 32 selected items and 152,348 selection tokens.
- MCP export attempts closed the RepoPrompt transport without writing a file; CLI export failed at the same connection boundary until its tool timeout was disabled.
- One of six concurrent detached Explore starts rejected an already-bound workspace as not durably accepted, then succeeded after rebinding and retrying.

## Background / Prior Research

### Native Codex task analysis

The task archive established the following chronology and controls:

- Initial multi-window calls made before binding were correctly rejected. Explicit binding recovered them; this was expected safety behavior rather than a defect.
- Five of six concurrent Explore starts succeeded. One returned `The Agent session could not be started because its workspace binding was not durably accepted`; rebinding and retrying succeeded.
- The investigation freshly reproduced the same failure on current `main`: of three concurrent detached Explore starts from an explicitly bound tab, one started and two returned the durable-binding rejection. After explicit parent rebinding, the two failed lanes started successfully when retried sequentially.
- Two accepted Codex Explore sessions reached `Completed` with `Turns: 1/1`, containing only the original user prompt and no assistant response or error.
- Recovery attempts produced `Codex native send failed: session not ready` and `Cannot resume this Codex thread because its saved thread ID is missing`.
- One reactivated session had correct pre-reactivation log and handoff content but returned content from an unrelated task under a changed session name. A fresh replacement session later completed the intended audit.
- `context_builder(response_type:"clarify")` completed successfully; the builder was slow but did not crash.
- Two MCP `prompt(op:"export", copy_preset:"plan")` attempts closed the task's RepoPrompt transport after roughly 32–34 seconds. RepoPrompt CE remained running, no file was written, and subsequent binding calls failed until Codex Desktop restarted.
- CLI export first correctly rejected an ambiguous relative path in the four-root workspace. Root-qualified `prompt export` then failed with `[-32000] Connection closed` both with and without a preset. Canonical `workspace_context op=export` failed the same way, ruling out the shorthand and Plan preset as sole causes.
- The canonical CLI operation succeeded with `rpce-cli --tool-timeout 0`, producing 31 files, 148,725 rendered tokens, and a 566,574-byte Markdown export. The flag was the intentionally changed variable, although warm caches mean it is strong rather than exclusive causal proof.
- Export/build token differences were explainable by Plan-preset exclusion of a transient Git diff artifact and incomplete cached token accounting; no source-context loss was established.

RepoPrompt Explore research and final direct GitHub searches found adjacent fixes and reports but no exact existing issue for either provider-independent boundary. The three provider-sensitive findings also lack exact duplicates, but they need stronger event or identity evidence before filing.

### Export timeout and transport research

- Current `main` still assigns `prompt` and `workspace_context` a 30-second bounded execution deadline and `.forceDisconnect` cleanup behavior (`MCPTimeoutPolicy.swift`, `MCPDomainToolExecutionContract.swift`, and `MCPConnectionManager.swift`). The observed 32–34-second failure followed by a dead connection while the app remained alive matches that contract.
- Both CLI `prompt export` and canonical `workspace_context op=export` converge on `MCPPromptContextToolProvider`. Export assembles selection content and metadata before the file write, so cancellation during assembly explains the absent output file.
- `--tool-timeout 0` disables only the CLI-side ordinary-tool deadline; it does not override the app server's execution watchdog. Its success may also depend on warmed caches, executable/backend differences, or a shorter second execution. A controlled same-backend cold reproduction with watchdog diagnostics is still required.
- Related fixes are merged, but none reclassifies export or adds an export-specific long-running contract: upstream PRs 211, 644, and 687. Closed upstream issue 170 documents the generic 30-second deadline plus cleanup/force-close class, but not prompt export.
- No exact issue or pull request was found for large `prompt`/`workspace_context` export failing after roughly 33 seconds. Current tests cover the watchdog mechanism but not a real large-selection export that runs past 30 seconds and still writes the file.

### Empty completion and resume research

- Current CE maps Codex `turn/completed(status: completed)` directly to a durable completed run after draining pending items. It has no invariant requiring assistant output, so a provider event with no assistant item can produce `runState = completed` with only the user's prompt.
- This exact provider event shape has an external analogue in [OpenAI Codex issue 25619](https://github.com/openai/codex/issues/25619), but CE still owns the product decision to avoid presenting and persisting a semantically false success.
- Resume metadata is also incomplete-safe but not recovery-complete. A rollout path without a conversation ID can become an empty-ID resume candidate; the controller rejects it, but the coordinator only falls back to a fresh thread for missing-rollout errors. Thread start/resume responses with a missing ID can also be accepted until the subsequent send reports `session not ready`.
- No exact CE issue was found. Merged upstream PRs 299, 618, 617, 623, and 791 harden adjacent transcript, resume, liveness, reconnect, and transient-dispatch paths without closing these specific gaps.
- Current tests do not cover a provider-completed turn with no assistant evidence, a coordinator-level persisted path-only resume, or a successful-looking thread response with no thread ID.

### Cross-session identity and binding research

- The unrelated reactivation result materially resembles the historical P0 incident fixed by merged upstream PR 742, where rejected workspace saves and stale projection replaced live identity while a late title mutation produced a new name over old provider/transcript state. The 2026-08-25 event therefore appears to be a post-fix recurrence or an uncovered alternate path.
- Current local session routing is strongly UUID-fenced. A residual gap remains at the Codex provider boundary: persisted Codex conversation/rollout identity has no RepoPrompt session ownership field, and a resume response is accepted without verifying that its returned conversation ID equals the requested thread. This is a plausible mechanism, not yet a proven root cause.
- Open upstream issue 863 concerns a different session writeback race, and open upstream issue 648 concerns teardown/reconnect recovery. Neither is an exact duplicate of cross-session provider attachment.
- The concurrent binding rejection is a separate fail-closed admission/persistence race. Current code correctly prevents provider start and rolls back provisional binding when workspace persistence/CAS loses authority. Closed upstream issue 743 and merged upstream PR 744 fixed a persistent workspace-authority conflict, but current `main` still reproduced transient concurrent-start rejection.
- Current tests cover CAS winners, rejected admission, and provider non-start in narrower shapes, but not six concurrent detached `agent_run.start` calls with rollback and sequential retry assertions.

## Investigator Findings: Export Transport

### Verdict and confidence

**Confirmed on analysis commit `2003d6c1` and unchanged through final tip `0dc80b37`:** app-backed `prompt` and `workspace_context` exports use the ordinary 30-second server execution watchdog, with 5 seconds of cancellation grace and `.forceDisconnect` escalation. The transport is severed only when the provider is still unresponsive after that grace; a provider that settles during grace returns a structured `tool_execution_timeout` and leaves the connection usable. The reported connection closure is therefore consistent with, but not by itself proof of, the force-disconnect branch.

**Not yet proven for the reported call:** no correlated `MCPToolExecution`/connection-close trace was captured for the failed invocation, so the exact slow phase and the fact that watchdog escalation—not a separate transport failure—closed that specific socket remain unproven. The strongest current explanation is that export preassembly exceeded 30 seconds and did not observe cancellation within the next 5 seconds.

### Confirmed app-backed causal chain

1. The central policy sets the ordinary execution deadline to 30 seconds, cleanup grace to 5 seconds, and the independent response-send/write-stall bound to 30 seconds (`Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift:3-8,38-48`).
2. The execution catalog initially assigns every advertised tool the bounded 30-second/5-second/`.forceDisconnect` contract. Only `file_actions`, `get_code_structure`, `read_file`, and `get_file_tree` are reclassified to `.detachAndSettle`; `prompt` and `workspace_context` remain force-disconnect tools (`Sources/RepoPromptDomainRuntime/MCPDomainToolExecutionContract.swift:66-104`).
3. `ServerNetworkManager` wraps the resolved provider operation in `MCPToolExecutionWatchdog.execute` (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:12037-12090`). At 30 seconds the watchdog cancels the operation task and starts the grace timer (`Sources/RepoPromptDomainRuntime/MCPDomainToolExecutionWatchdog.swift:369-407`).
4. If the operation settles during grace, the watchdog throws `executionTimedOut(settlement:)`; the connection manager formats `tool_execution_timeout` with `shouldForceDisconnect = false` (`MCPConnectionManager.swift:12234-12255`).
5. If it is still running after 5 more seconds, `.forceDisconnect` throws `cleanupUnresponsive` (`MCPDomainToolExecutionWatchdog.swift:409-455`). The connection manager maps that to `tool_execution_cleanup_unresponsive`, marks `shouldForceDisconnect = true`, calls `abortConnectionForExecutionWatchdog`, and deliberately skips the normal `handlerResult` publication path because the transport has already been severed (`MCPConnectionManager.swift:12256-12323`).
6. The abort records the terminal cause and invokes the connection's watchdog abort (`MCPConnectionManager.swift:6079-6135`). `BootstrapSocketConnectionManager` immediately disconnects the Unix transport and only then stops the MCP server asynchronously (`Sources/RepoPrompt/Infrastructure/MCP/BootstrapSocketConnectionManager.swift:326-345`). This exactly explains “connection closed while RepoPrompt CE stayed alive” when, and only when, the provider ignored cancellation through grace.

The app-backed server also has an independent 30-second response-send timeout (`BootstrapSocketConnectionManager.swift:116-127`), and result formatting happens after the watchdog-protected provider returns (`MCPConnectionManager.swift:12452-12490`). A response-delivery stall is therefore a separate possible closure class. For the observed attempts, however, the missing file plus the write ordering below point earlier than successful result serialization/delivery; a response-only stall after a successful export would leave the file on disk.

### Entry-point convergence and backend boundary

- The CLI spelling `prompt export ...` is already normalized to a `workspace_context` tool call (`Sources/RepoPromptMCP/CommandRunner/MCPCommandParser.swift:1036-1067,1086-1113`).
- A client may still call MCP `prompt {"op":"export"}` directly. In the app provider, `workspace_context op=export` forwards to `executePrompt`, and direct `prompt` calls enter the same function (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift:21-50,88-121`). Both then select the same `exportPrompt` implementation (`MCPPromptContextToolProvider.swift:124-147,242-276`). Copy-preset choice and the CLI shorthand are therefore not distinct server execution paths.
- Both app-backed tool names are also classified as protected durable mutations for export (`Sources/RepoPromptDomainRuntime/MCPDomainProtectedMutationToolProvider.swift:32-60,87-112,145-249,286-297`).
- **Headless/direct is not equivalent and is out of this reproduction scope.** `--backend headless` bypasses the app watchdog and invokes the domain host directly with 5-second response/write-stall bounds (`Sources/RepoPromptMCP/DirectHeadlessMCPService.swift:59-84,300-333`). Its canonical `prompt` and `workspace_context` exports are separate, simplified snapshot writers rather than the app's full copy-preset packaging path (`Sources/RepoPromptDomainRuntime/MCPDomainCanonicalWorkspaceService.swift:336-365,367-400`). A ticket for this failure should explicitly target the app backend.

### Export write and response ordering

The shared app export performs work in this order:

1. Drain pending read-file auto-selection before resolving the tab (`MCPPromptContextToolProvider.swift:99-121`).
2. Resolve the effective preset and build the complete clipboard text (`MCPPromptContextToolProvider.swift:242-254`). Both clipboard builders currently catch every preassembly error and return an empty string, including a thrown cancellation unless a later step observes task cancellation (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+WorkspaceContext.swift:277-349`; `Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:6204-6242`). This is a confirmed cancellation-propagation hazard, not proof that it caused this run.
3. Build selected-file metadata, including selection collection and token evaluation (`MCPPromptContextToolProvider.swift:255-258`; `MCPServerViewModel+WorkspaceContext.swift:200-275`).
4. Resolve/authorize the destination and only then call the file writer (`MCPPromptContextToolProvider.swift:259-269`). For an absolute path outside loaded roots, physical admission and `willCommit()` occur immediately before directory creation and atomic UTF-8 write (`MCPServerViewModel.swift:6689-6709`). Workspace-root writes likewise check cancellation before entering the mutation service (`Sources/RepoPrompt/Infrastructure/MCP/ApplyEdits/WorkspaceFileEditHost.swift:66-96`), which establishes the durable commit boundary immediately before uncancellable filesystem I/O (`Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FileOperations.swift:97-139`).
5. After the write, wait for explicit workspace ingress, calculate reply metadata, return the provider `Value`, format the tool result, and finally hand the response to the MCP SDK/transport (`MCPPromptContextToolProvider.swift:270-276`; `MCPConnectionManager.swift:12120-12149,12477-12490`).

Thus, **absence of the destination file is strong evidence that the reported attempt did not cross the export commit/write boundary**. It is consistent with timeout during selection drain, prompt preassembly, file-info assembly, path admission, or another pre-write await. It does not identify which one. Conversely, a future reproduction that leaves a file but loses the reply must be treated as post-commit partial success and investigated at ingress/envelope/response delivery rather than retried blindly.

### Current tests and history

- Contract tests explicitly lock `prompt` and `workspace_context` into the ordinary bounded force-disconnect group (`Tests/RepoPromptTests/MCP/Control/MCPToolExecutionContractTests.swift:7-20,69-103`).
- The only real app prompt-export success test uses a small fixture and a manually released selection-drain gate; it proves drain-before-write and normal connection retention, not a large or longer-than-30-second export (`Tests/RepoPromptTests/MCP/Control/PersistentAgentModeMCPReadFileConnectionTests.swift:2377-2419`).
- Protected-mutation coverage proves both export names fail closed without creating a file when policy denies the destination (`Tests/RepoPromptTests/MCP/Control/MCPProtectedMutationInvocationIntegrationTests.swift:378-390`). Response-delivery coverage classifies `workspace_context export` as unsafe to replay (`Tests/RepoPromptTests/MCP/Control/PersistentMCPResponseDeliveryTests.swift:51-88`). Neither exercises watchdog expiry during real export assembly.
- Generic watchdog tests prove cooperative timeout keeps a connection usable and an artificial cancellation-ignoring provider force-disconnects it, but no current test drives a real `prompt`/`workspace_context` export across the production deadline (`MCPToolExecutionWatchdogIntegrationTests.swift:798-925,1212-1285`).
- Commit `a48fec67` (the original transport-timeout remediation behind upstream issue 170) made export's auto-selection drain cancellation-aware, but did not reclassify exports or add cancellation checkpoints/phases across the remaining assembly path. Commit `355d6a17` established the current CLI timeout policy: ordinary calls default to 300 seconds, while an explicit zero resolves to no caller deadline (`Sources/RepoPromptMCP/Interactive/InteractiveMCPClientSession.swift:964-995`; tests at `Tests/RepoPromptTests/MCP/Control/InteractiveMCPClientSessionCancellationTests.swift:23-31,66-79,100-108`). The parser accurately describes `--tool-timeout 0` as disabling only the CLI-side timeout (`Sources/RepoPromptMCP/main.swift:2605-2621`).
- Upstream PR 211 / commit `c2dcc563` fixed a Context Builder **child-connection teardown-before-final-response-write** race. It also found that selections above one million tokens did not deterministically fail, ruling out a simple payload-size ceiling. It did not change the direct app export execution contract.
- Upstream PR 644 / commit `d1f26fdd` moved only `read_file` and `get_file_tree` to detach-and-settle; it is the closest policy precedent, not an export fix.
- Closed upstream issue 170 described generic bounded-handler force-close and Context Builder opacity. Upstream PR 687 / commit `7ba5165d` closed it through Codex turn reconciliation, `file_actions` mutation settlement, process cleanup, and diagnostics. Neither item changed prompt/workspace-context export assembly or its contract.

### What `--tool-timeout 0` does and does not prove

Current main gives ordinary CLI calls a 300-second caller deadline (`MCPTimeoutPolicy.swift:50-61`), already much longer than the app server's 30-second execution bound. Explicit zero resolves to no CLI deadline (`InteractiveMCPClientSession.swift:964-995`). It cannot override `MCPDomainToolExecutionContractCatalog` or the app watchdog. Therefore the later successful zero-timeout run does **not** prove that the earlier calls died at the caller deadline; warm caches, a shorter second assembly, a different executable/backend, or other changed state remain viable explanations. The successful 566,574-byte export does prove there is no unconditional payload-size failure at that size.

### Controlled reproduction required to close attribution

1. Use a current CE debug build and `rpce-cli-debug --backend app`; record `--version`, app commit/build, window/tab binding, copy preset, selection revision, selected file count, rendered tokens, and expected bytes. Do not use Classic, production `rp-cli`, or the headless backend as an analogue.
2. Use a cold, reproducible selection at least as expensive as the observed 32 files / approximately 150k tokens and a unique absolute destination known not to exist. Token count alone is insufficient; preserve the exact selected files/slices, git inclusion, codemap state, and cache-warming sequence.
3. Run direct MCP `prompt op=export` and canonical `workspace_context op=export` separately on fresh app connections with equivalent arguments and unique paths. Use `--tool-timeout 0` only to remove caller cancellation as a variable, not as a server override.
4. Capture `[MCPToolExecution]` events and the persisted connection-close record. Required proof is the ordered sequence `deadline_expired` → cancellation requested → either `settled_during_grace` or `cleanup_grace_expired`/`connection_force_disconnect_requested`, including invocation ID, elapsed time, and last handler phase (`Sources/RepoPrompt/Features/Diagnostics/MCP/MCPToolExecutionDiagnostics.swift:179-213`; `MCPConnectionManager.swift:11856-12099,6079-6120`). Check the destination at deadline, grace expiry, socket close, and eventual provider settlement.
5. Repeat once warm with the identical selection. If cold fails and warm succeeds before 30 seconds, measure selection drain, clipboard preassembly, selected-file metadata, write/ingress, result formatting, and response delivery separately. Current export code has no export-specific phase markers, so adding deterministic test seams/diagnostic phases belongs in the implementation ticket, not this report.

### Ticket recommendation

**File a new, narrowly scoped ticket; do not reopen upstream issue 170 and do not attach the work to upstream PRs 211, 644, and 687.** Suggested title:

> Large app-backed `prompt.export` / `workspace_context export` can exceed the 30-second execution contract and force-disconnect before durable export completion

The owned invariant should be: for the shared full-context app export path, a legitimate large export either (a) durably writes the requested file and delivers a matching success response, or (b) fails with explicit pre-/post-commit state without killing unrelated MCP traffic. The ticket should require the controlled trace above, export-specific phase attribution, cancellation preservation through clipboard/file-info assembly, a deterministic real-export test crossing 30 seconds, both public tool names, and verification of file-write-before-response ordering. It should leave the remedy evidence-led: optimize/cancel the slow phase, adopt a longer/lifecycle-managed export contract, or isolate settlement locally only after the trace shows which invariant is failing.

Out of scope for that ticket: Context Builder child finalization/response drains (upstream PR 211), generic read detachment (upstream PR 644), Codex/file-action settlement (upstream PR 687/upstream issue 170), headless export parity, and unrelated Context Builder discovery latency.

**Maintainer-guidance check:** user impact is loss of the export plus the caller's entire app-backed MCP connection; root-cause confidence is confirmed for policy/control flow and plausible for the reported runtime attribution; the app provider and execution-contract catalog are the authorities; state risk is pre- versus post-commit ambiguity; scale risk is cold full-context assembly; recommended scope is a new issue followed by the smallest trace-supported fix; validation must cover the real app-backed MCP boundary, not only helper units.

## Investigator Findings: Codex Lifecycle and Identity

### Scope and method

- This Pair pass inspected `main` at `2003d6c16f38894b1661f9a01080580413ffb96e` (the same commit as `upstream/main` during the Pair run), the merge for upstream PR 742, current focused tests, and the current upstream Codex app-server protocol. The earlier Context Builder/Explore findings remain summarized under Background. An additional child RepoPrompt Explore fan-out was unavailable in this pass because the RepoPrompt MCP transport was closed, so the findings below use direct read-only source, history, test, and primary-source review.
- Focused current-contract validation passed: four tests, zero failures (`CodexNativeSessionControllerGoalConfigTests/testPathOnlyResumeFailsLocallyBeforeWritingRequest`, `AgentModeViewModelInactiveRefreshTests/testHydrationAndPresentationRejectStaleBindingGeneration`, `BackgroundComposeTabAdmissionTests/testLateTitleProviderAndInteractionAttemptsCannotCrossChangedSessionIdentity`, and `CodexFallbackFIFOTests/testMismatchRetrySuccessReconcilesOnlyWhenActualLifecycleCompletes`; conductor ticket `<redacted>`). These tests confirm the existing local fences and false-success/path-only behavior; they do not substitute for the new A/B/C regressions proposed below.
- The three boundaries remain independent. **A** can occur with a correct thread identity; **B** is specifically absent/blank identity; **C** requires a non-empty but wrong provider thread (or equivalent non-empty provider contamination). The observed chronology could contain more than one boundary, but current evidence does not justify one combined implementation ticket.

### A — Provider completes with no assistant evidence

**Invariant:** A user turn must not be published or persisted as semantically `completed` unless CE observed affirmative assistant-result evidence, or else an explicit provider failure/cancellation outcome. A syntactically valid `turn/completed(status: completed)` is insufficient when no assistant item, assistant text, or other completion evidence exists.

**Confirmed current-code gap (high confidence):**

1. `CodexNativeSessionController` tracks assistant deltas/completions (`CodexNativeSessionController.swift:849-853`), but its terminal handler never consults that state. It defaults a missing status to `completed` and emits `.turnCompleted` after only turn-correlation and failure selection (`CodexNativeSessionController.swift:3467-3535`). The deprecated mirrored `task_complete` event is deliberately non-authoritative, so duplicate terminal events are not the cause (`CodexNativeSessionController.swift:3541-3546`).
2. The coordinator correlates the completion to a local turn and then calls `finalizeCodexRun` (`CodexAgentModeCoordinator.swift:8186-8262`). Terminal draining flushes whatever output exists, but does not require any output to exist (`CodexAgentModeCoordinator.swift:7585-7596`); `finalizeCodexRun` maps provider `.completed` directly to local `.completed` and requests a completion notification (`CodexAgentModeCoordinator.swift:7598-7671`).
3. Existing coverage demonstrates the current false-success contract rather than preventing it: `testMismatchRetrySuccessReconcilesOnlyWhenActualLifecycleCompletes` injects only `.turnCompleted(..., .completed)` after dispatch and asserts `session.runState == .completed`, without any assistant event (`CodexFallbackFIFOTests.swift:65-103`). Other correlation tests correctly reject a different turn and accept matching/nil correlated turns, but likewise do not establish assistant evidence (`CodexAgentModeCoordinatorLivenessTests.swift:2182-2329`).
4. The provider-side shape is not hypothetical. OpenAI [Codex issue 25619](https://github.com/openai/codex/issues/25619) documents `turn/started` followed by `turn/completed(status: completed, last_agent_message: null)` with no item or error events when compaction failure exits before sampling. CE currently ignores `last_agent_message` and cannot distinguish that wire shape from a meaningful completion.

**Eliminated or narrowed hypotheses:**

- No stale turn, missing `turn/started`, transport teardown, or cross-session identity failure is required for A. A correctly correlated current turn is enough.
- Pending assistant-buffer loss is not required. Terminal draining does flush pending assistant and tool buffers; the defect is the absent post-drain semantic invariant.
- `codex/event/task_complete` double-finalization is not responsible because CE ignores it as a lifecycle hint.

**Deterministic reproduction/test:** Build a running Codex session with one user request, deliver a correlated `turn/started`, then a `turn/completed(status: completed)` with no assistant delta/completion, tool result that represents an answer, or error. Current code commits `.completed` and leaves the transcript with only the user request. Add a controller-level event-shape test using the `last_agent_message: null` form from Codex issue 25619 and a coordinator-level terminal-barrier assertion that false success is not published.

**Triage recommendation:** Investigate **A** before filing. Capture the raw Codex terminal event shape and any provider diagnostic, then define whether CE needs a non-success or explicit-no-output terminal state without rejecting valid tool-only, reasoning-only, or explicitly empty runs. OpenAI [Codex issue 25619](https://github.com/openai/codex/issues/25619) is a plausible upstream trigger; closed upstream issue 309 and merged upstream PR 310 provide a CE precedent for surfacing provider-specific no-content diagnostics. Do not join A to B or C.

**Confidence:** High that the CE gap is real; medium-high that it explains the two empty `Completed` sessions because the archived sessions match the exact observable shape, but the original raw app-server event stream was not captured.

### B — Missing or empty resume/readiness identity

**Invariant:** A controller is ready only after a non-empty authoritative thread ID has been validated. Persisted path-only metadata and a successful-looking start/resume response with no ID must not pass through as a usable session or degrade later into the generic `session not ready` symptom.

**Confirmed current-code gaps (high confidence):**

1. Hydration faithfully restores both optional fields and marks reconnect required when *either* exists (`CodexAgentModeCoordinator.swift:2217-2235`). The UI also treats a non-empty rollout path alone as known thread metadata (`CodexAgentModeCoordinator.swift:3853-3864`). When reconnect is requested, `codexResumeCandidate` constructs a `SessionRef` using `session.codexConversationID ?? ""`, so path-only persistence becomes an empty-ID resume candidate (`CodexAgentModeCoordinator.swift:4083-4098`).
2. The controller rejects that candidate locally before issuing `thread/resume` (`CodexNativeSessionController.swift:1813-1819`) with the exact saved-thread-ID error (`CodexNativeSessionController.swift:9286-9301`). The coordinator's fresh-start fallback recognizes only known missing-rollout error strings (`CodexAgentModeCoordinator.swift:3979-4045`), not `invalidResumeReferenceMissingThreadID`, so this path is recovery-incomplete.
3. The response side has a second gap: `parseThreadSnapshot` turns a missing response `thread.id` into `""` (`CodexNativeSessionController.swift:2659-2665`), after which the controller installs the empty snapshot, marks start/resume successful, and returns it (`CodexNativeSessionController.swift:1983-1997`, `2612-2645`). `hasActiveThread` is only `threadID?.isEmpty == false` (`CodexNativeSessionController.swift:867-869`), so the coordinator writes the empty ID, schedules persistence/title work, and can clear reconnect (`CodexAgentModeCoordinator.swift:4457-4501`) before the send path reports `Codex native send failed: session not ready` (`CodexAgentModeCoordinator.swift:6470-6501`).
4. Current tests cover the controller's path-only local rejection (`CodexNativeSessionControllerGoalConfigTests.swift:909-929`) and ordinary matching ID/path resume (`CodexNativeSessionControllerGoalConfigTests.swift:398-445`), but not a missing-ID response or coordinator-level path-only recovery.

**Eliminated or narrowed hypotheses:**

- B does **not** explain unrelated non-empty transcript content by itself; it explains the saved-ID and readiness failures.
- An ordinary first follow-up from a transcript containing only user rows will normally skip resume: resume eligibility excludes user-only history (`CodexAgentModeCoordinator.swift:4047-4055`), and the send path enables that guard for a newly started run (`CodexAgentModeCoordinator.swift:6426-6455`). Therefore the archived user-only empty session does not, by itself, prove the path-only candidate caused its later recovery failure. Path-only remains reachable through recovery/reconnect paths whose `skipResumeWhenNoPriorCodexHistory` default is false (`CodexAgentModeCoordinator.swift:5721-5729`, including unexpected-stream recovery at `5992-5996`) or when non-user history exists.
- Local hydration mismatch is not required: the hydration guards can correctly load the requested CE UUID and still restore incomplete provider metadata from that same session.

**Deterministic reproductions/tests:**

1. Hydrate a Codex session with `codexConversationID = nil`, a non-empty rollout path, reconnect required, and resume-eligible history; call the coordinator ensure/send path. Current behavior reaches the local saved-thread-ID error and does not use the fresh/handoff recovery contract.
2. Make the existing fake app-server return `{ "thread": { "status": "idle", "turns": [] } }` for `thread/start` and separately for `thread/resume`. Assert that current code returns an empty `SessionRef`, clears the reconnect flag despite having no active provider thread, then fails at the later send gate. The desired contract is to reject the control-plane response before controller state, persistence, title sync, routing-ready publication, or first-turn dispatch changes.

**Triage recommendation:** Investigate **B** before filing. Capture the error immediately preceding the generic readiness failure together with the redacted persisted conversation-ID and rollout-path presence shape. `Codex native send failed: session not ready` is a RepoPrompt fan-in symptom, and the saved-thread-ID message is a RepoPrompt local guard; neither proves the initiating failure was inside RepoPrompt. Do not silently fresh-start a historical conversation unless the existing transcript-handoff contract makes the context loss explicit and safe. Do not join B to C.

**Confidence:** High for both current gaps; medium-low that B is the initiating cause of the archived incident, because the ordinary user-only follow-up guard weakens that exact route and the original recovery call path was not instrumented.

### C — Wrong non-empty provider thread / cross-session reactivation contamination

**Invariant:** Reactivating CE AgentSession `S-A` may resume only the Codex thread durably owned by `S-A`. A resume response that resolves to another non-empty provider thread must fail closed before that identity, transcript activity, title mutation, or subsequent turn becomes authoritative for `S-A`.

**Proven current mechanism, but not yet proven live root cause:**

1. CE's resume request always sends the persisted non-empty `threadId` and also forwards a non-empty rollout `path` (`CodexNativeSessionController.swift:1722-1728`). That path forwarding was deliberately added for legacy resumes in commit `d4eacbec` / upstream PR 618, so simply removing it without migration analysis would regress an established compatibility boundary.
2. Current upstream Codex gives a non-empty `path` precedence over `thread_id` for a **non-running** thread and explicitly says the supplied `thread_id` is ignored in that case ([`ThreadResumeParams`, upstream `thread.rs:309-341`](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L309-L341)). Therefore a persisted mismatched pair `(threadId=A, path=path-to-B)` can legitimately return thread `B`; this does not require an upstream routing bug.
3. CE parses whatever non-empty response ID is returned, installs it as controller state, and completes binding without comparing it to the requested ID (`CodexNativeSessionController.swift:1983-1997`, `2636-2665`). The coordinator then overwrites `session.codexConversationID`/rollout path, schedules a save, and schedules title sync against the returned ID (`CodexAgentModeCoordinator.swift:4457-4499`). This is the exact response-identity ownership gap.
4. Current CE UUID/activation/hydration fences do not catch it, because they correctly protect a different authority:
   - `AgentSessionLifecycleAuthority.Identity` contains workspace UUID, tab UUID, AgentSession UUID, and binding generations, but no provider thread identity (`AgentSessionLifecycleAuthority.swift:5-18`); mutation validation compares only those local fields (`AgentSessionLifecycleAuthority.swift:121-136`).
   - Reactivation resolves the exact requested AgentSession UUID, creates/binds a tab if required, hydrates it, then captures the local lifecycle identity (`AgentModeViewModel.swift:7163-7224`). MCP activation rechecks object identity, AgentSession UUID, binding-transition state, activation generation, and registration (`AgentModeViewModel.swift:7805-7865`).
   - Hydration rejects a payload for the wrong AgentSession UUID or stale binding (`AgentModeViewModel.swift:4639-4695`, `4737-4758`), then restores the provider pair from the correctly loaded session (`AgentModeViewModel.swift:4782-4819`; `CodexAgentModeCoordinator.swift:2217-2235`). It does not prove that the two provider fields identify the same Codex thread.
   - Event delivery is fenced by captured run ID and controller instance (`CodexAgentModeCoordinator.swift:5943-5962`). But after the active controller and local session both adopt returned thread `B`, those fences consider `B` current. The coordinator's event-scope check also has no thread scope for `.turnCompleted` (`CodexAgentModeCoordinator.swift:7711-7751`). These protections block stale *old-controller* events, not a wrong thread adopted by the current controller.

**Fence test matrix for `(requested AgentSession=S-A, persisted thread=A, persisted path=path-to-B, returned thread=B)`:**

| Fence | Current result | Why |
| --- | --- | --- |
| CE UUID and tab binding | Passes as intended | The requested/hydrated object is still `S-A`; no local UUID collision or retarget is needed. |
| Hydration token / binding generation | Passes as intended | The payload is genuinely `S-A`'s payload; its provider pair is internally unvalidated. |
| MCP activation ID / registration | Passes as intended | Reactivation owns a fresh control activation for `S-A`, independent of Codex thread identity. |
| Run ID / active controller instance | Passes as intended | The same newly created controller requested A/path-B and adopted B. |
| Provider resume identity | **Fails open** | No requested-ID/returned-ID or ID/path ownership check exists before applying B. |

**Relationship to history and adjacent tickets:**

- Upstream PR 742 fixed a confirmed local identity-replacement incident: rejected workspace persistence allowed provider startup, then stale projection replaced the live tab/session binding and late mutations crossed identities. Current code now protects local identity (`AgentSessionLifecycleAuthority.swift:139-156`), and regression tests preserve a live pinned session, reject stale projection, and reject late title/provider/interaction mutations (`BackgroundComposeTabAdmissionTests.swift:800-945`). The 2026-08-25 symptom resembles upstream PR 742, but the response-ID gap is an uncovered provider-identity boundary, not evidence that upstream PR 742's exact local admission/projection path regressed.
- Current write sites normally assign the Codex ID and path together (`CodexAgentModeCoordinator.swift:692-719`, `2217-2249`, `4457-4499`). That narrows—but does not eliminate—the source of a mismatched persisted pair. The investigation has not proven whether it came from legacy state, an unobserved persistence/projection race, an upstream path selection, or another contamination path.
- Open upstream issue 863 is a tombstone/load-time rewrite race that can resurrect a deleted session; it is not provider thread attachment. Open upstream issue 648 is helper teardown/reconnect and approval-channel recovery; it likewise does not validate Codex resume identity. Neither is an exact duplicate.
- A title update is more likely an amplifier than the origin here: after CE accepts returned thread B, the explicit title sync also targets B (`CodexAgentModeCoordinator.swift:4394-4399`, `4494-4498`).

**Deterministic two-session reproduction/test:**

1. Persist two CE sessions `S-A` and `S-B` with Codex references `(A, path-A)` and `(B, path-B)`.
2. Reactivate `S-A` through `mcpResolveOrCreateSessionTarget`/MCP control and assert its CE session UUID, tab binding, hydration token, and activation ID remain `S-A`.
3. Inject the mismatched persisted pair `(A, path-B)` for `S-A`. Configure the existing fake app-server seam (`CodexNativeSessionControllerGoalConfigTests.swift:1187-1238`) to model upstream precedence by returning B for `thread/resume` while recording that CE requested A/path-B.
4. On current code, assert the controller reference and `session.codexConversationID` become B while every local UUID/activation/hydration fence remains valid. Add an active B turn or B-scoped completion to show that the current controller/run fences accept B's lifecycle. The fixed contract should reject before applying the response, saving metadata, syncing the title, publishing routing readiness, or dispatching a turn.

**Triage recommendation:** Investigate **C** before filing. First run the deterministic two-session ID/path-precedence canary and capture privacy-safe requested/returned identity correlation. Preserve the legacy rollout-path compatibility added by upstream PR 618 while establishing whether a real mismatched pair reaches the current response-acceptance gap. Do not label the live incident root-caused until a real mismatched persisted pair or resume response is captured.

**Confidence:** High that the mismatch path exists and crosses the present local fences exactly as described, because CE request/response behavior and upstream path precedence are explicit. Medium that it caused the unrelated reactivation result; that attribution still lacks the original persisted `(ID, path)` pair and raw `thread/resume` response.

### Ticket boundary conclusion

- **A:** investigate first — capture provider event and diagnostic evidence, then define safe empty-result semantics.
- **B:** investigate first — capture the preceding start/resume failure and persisted ID/path presence shape.
- **C:** investigate first — run the deterministic two-session ID/path-precedence canary and capture requested/returned identity correlation.
- Keep all three separate. A may explain the empty sessions, B may explain the saved-ID/readiness recovery errors, and C may fit the unrelated non-empty reactivation content, but the historical attribution of each remains unproven.

### Maintainer-guidance check

- **User impact and invariant:** Never show false success, lose resumability behind a generic readiness error, or attach one AgentSession to another provider thread.
- **Root-cause confidence:** A and B code gaps confirmed; C mechanism confirmed but live attribution plausible rather than proven.
- **Authority:** Codex owns app-server thread/path resolution; CE owns AgentSession-to-provider ownership, readiness validation, persistence, and user-visible terminal semantics.
- **State-safety risks:** Fresh fallback can silently lose native context; accepting a wrong non-empty response can persist and amplify cross-session contamination.
- **Scale and observability risks:** No scale issue is implicated. Missing raw requested/returned resume correlation and assistant-evidence telemetry prevents causal attribution.
- **Recommended scope:** Three bounded evidence-gathering tracks, not speculative compatibility code, retries, or public issues yet.
- **Validation boundary:** Controller response parsing, coordinator terminal barrier, two-session persisted hydration/reactivation, then live CE `rpce-cli-debug agent_run` resume/wait validation with DEBUG raw-event diagnostics enabled.

## Investigator Findings: Concurrent Workspace Admission

### Verdict

This is a **supported-concurrency defect at Agent child-session workspace admission**, not an expected `bind_context` conflict and not evidence of cross-session contamination. The fail-closed behavior added by upstream PR 742 is working: a losing start does not reach provider dispatch. What is defective is that same-workspace starts admitted concurrently by the MCP control lane race through independent full-workspace saves; only a subset may be accepted even though the requested sessions are independent and a sequential retry succeeds.

The exact high-level losing boundary is proven: `agent_run.start` fails while transactionally persisting the new compose-tab/session binding, before `mcpResolveOrCreateSessionTarget` returns. The most likely leaf failure is a stale workspace-revision compare-and-swap (`workspace_revision_mismatch`), but current reproduction output did not preserve the underlying `DomainCommandOutcome`; bounded save-preparation retry exhaustion can collapse to the same public error. The leaf classification is therefore **high-confidence but not fully instrumented proof**.

### Reproduction confidence

- **Symptom: confirmed on analysis commit `2003d6c1` and unchanged through final tip `0dc80b37`.** An earlier six-way detached burst admitted five and rejected one. The fresh three-way burst from an explicitly bound tab admitted one and rejected two with the exact durable-binding error. After explicit rebinding, both failed lanes started when retried sequentially.
- **Concurrency dependence: high confidence.** Two bursts produced partial admission, while sequential retry succeeded. Rebinding and serialization changed together, so the rebind is not exclusive causal proof; source location rules out connection-binding admission as the emitter of this error.
- **Exact leaf conflict: high confidence inference, not directly observed.** Unified-log queries did not recover the reproduction's lifecycle/domain outcome. Current code erases the distinction between a stale-payload retry exhaustion and a domain `workspace_revision_mismatch` before returning the MCP error.
- The requested child RepoPrompt Explore fan-out could not be repeated during Pair follow-up because the RepoPrompt MCP transport was closed. No native/team fallback findings were used. The prior completed Explore phase and the fresh live reproduction recorded above remain the behavioral evidence.

### Exact authority and persistence path

1. Concurrent `agent_run` calls are intentional at the transport boundary. `agent_run` is classified as `.control` (`Sources/RepoPromptDomainRuntime/MCPDomainToolCatalog.swift:284-294`), and the control connection lane admits up to eight calls (`Sources/RepoPromptDomainRuntime/MCPDomainToolResourceAdmissionController.swift:3-6`; asserted by `Tests/RepoPromptTests/MCP/Control/MCPToolAdmissionPolicyTests.swift:29-42,72-79`). This is not an unsupported caller pattern that the tool serializes by contract.
2. Parent routing and canonical workspace-health checks run first (`Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift:332-358`). The failing error can only occur later, while resolving the new target at lines 439-452. `detach` is read at line 329 but does not affect admission or provider startup; it is first acted upon after startup at lines 756-768.
3. The new child tab is created already carrying its intended Agent session ID, appended to the active workspace, and marked dirty before an awaited save (`Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:2824-2856`). Because this `@MainActor` function suspends on the save, sibling starts can append additional provisional tabs and advance the same workspace state while the first save is in flight.
4. Each dirty mark advances one manager-local state version (`Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:482-485,798-800`). The domain save captures that version, performs detached preparation, and retries only once if a sibling changed the workspace (`WorkspaceManagerViewModel.swift:8837-8900`). A second change after that retry reaches `guard remainingRetryCount > 0 else { throw CancellationError() }` at line 8893; `saveWorkspaceAsync` converts that cancellation to `nil` at lines 8668-8669.
5. After preparation, each call snapshots the domain authority and sends the full workspace document with the manager's current expected working revision and digest (`WorkspaceManagerViewModel.swift:8903-8916`). When the digest differs, `DomainWorkspaceAuthorityClient.save` first issues `replaceWorkingDocument` with that expectation (`Sources/RepoPrompt/Infrastructure/MCP/AppShared/DomainWorkspacePresentationBridge.swift:77-96`). The authority rejects a stale expected revision as `workspace_revision_mismatch` **before** checking whether the submitted digest is already current (`Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift:1441-1452,1472-1474`). Thus two starts that converge on the same full-workspace payload can still race: the first advances the working revision, while a sibling envelope minted from the old baseline conflicts instead of becoming `.unchanged`.
6. The presentation client deliberately retries only `.failed` lock-timeout/cancellation outcomes with the identical envelope, not `.conflict`/`stateConflict` (`DomainWorkspacePresentationBridge.swift:130-141`). The manager applies the conflict baseline and throws for every non-success disposition (`WorkspaceManagerViewModel.swift:8924-8927`) rather than refreshing the CAS expectation and retrying the logical save.
7. Both leaf failures are flattened. `saveWorkspaceAsync` returns `nil` for cancellation or a domain-operation error (`WorkspaceManagerViewModel.swift:8657-8682`), and `pollAndSaveStateWithOutcomeAsync` normally exposes only `workspace_save_failed` (`WorkspaceManagerViewModel.swift:5886-5903`). `AgentSessionLifecycleAuthority` therefore receives a generic rejected persistence outcome and mandates rollback (`Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionLifecycleAuthority.swift:139-157`). `AgentModeViewModel` finally emits the observed durable-binding message (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:7418-7467`).

The source-supported race is therefore:

```text
provisional child A appended -> save A suspends
provisional child B/C appended -> same workspace version/digest advances
saves retry/coalesce around the latest full document
one authority replace/save advances working revision
sibling save either exhausts its one local-version retry or loses expected-revision CAS
loser rolls back before target return; winner proceeds toward provider start
```

The observed subset admission and successful sequential retry are exactly consistent with that path. Capturing `WorkspacePersistenceOutcome` with the underlying `DomainCommandOutcome.diagnostic`, expected/actual revisions, and retry count is still required to say which leaf rejected each live lane.

### Fail-closed and cleanup audit

- **Provider start: complete and proven fail-closed.** A rejected durable tab creation throws from `mcpResolveOrCreateSessionTarget` (`AgentModeViewModel.swift:7418-7467`), which is awaited at `AgentRunMCPToolService.swift:443-452`. Provider dispatch is in the later block at lines 642-679. The service therefore cannot call `startRun` for this rejection, matching the error text and reproduction.
- **Provisional process state: explicitly rolled back.** The provisional tab is removed from composed and stashed tabs, active-tab fallback and prompt lists are repaired, its dirty-tab marker is cleared, and the workspace is marked dirty (`PromptViewModel.swift:2862-2872,2878-2895`). The provisional parent-session mapping is removed on the thrown creation path (`AgentModeViewModel.swift:7372-7391`). Hydration/session-runtime creation occurs only after durable creation returns (`AgentModeViewModel.swift:7261-7277`), so this failure should not leave a provider controller or live `TabSession`.
- **Existing regression coverage verifies only in-memory cleanup.** `testRejectedConcurrentAgentAdmissionsPreserveActiveLivePinnedSession` injects two persistence rejections and asserts the original composed/stashed tabs, bindings, active tab, and session map survive unchanged (`Tests/RepoPromptTests/Prompt/BackgroundComposeTabAdmissionTests.swift:800-848`). It passed on current `main` (1 test, 0 failures; conductor ticket `<redacted>`). It does not run two real domain-authority saves, inspect canonical bytes, wait for projection, or restart.
- **Durable cleanup is not proven complete.** `rollbackProvisionalAgentSessionTab` ends with `markWorkspaceDirty()` and does not await or schedule a compensating save (`PromptViewModel.swift:2878-2895`). Because each admission persists a full-workspace snapshot, a winning sibling may have captured a losing sibling's provisional tab before that sibling rolls back. Same-window authority events suppress full self-projection and pair the current local model with the canonical digest (`DomainWorkspacePresentationBridge.swift:243-283`), so an orphan durable binding could remain hidden until a later save/projection/relaunch. The sequential successful retries likely rewrote the full current workspace and removed any such residue, but the failed burst alone did not verify that. This is a state-safety test gap, not a confirmed orphan from the reproduction.

### Eliminated or distinct causes

- **Not an unbound/ambiguous parent context.** Those failures occur during routing validation before target creation and have different errors. This error is emitted only after child workspace persistence rejects. The explicit rebind before retry may refresh routing, but serialization is the source-relevant changed variable.
- **Not workspace health from upstream issue 743.** Upstream issue 743 was a restart-persistent external-conflict/read-only workspace: all starts failed until authority recovery. Here the same workspace accepts a subset concurrently and accepts the rest sequentially.
- **Upstream PR 744 is adjacent, not a fix for this race.** Upstream PR 744 preserved precise authority health, added recovery, and changed admission to use canonical authority state. It did not serialize or rebase multiple same-window Agent admission saves.
- **Upstream PR 746 self-heals a lower durability CAS layer, not stale caller envelopes.** Upstream PR 746 refreshes and replays when `persistWorking` itself reports a durable CAS conflict (`DomainWorkspaceContextAuthority.swift:1501-1547`). The current failure can occur earlier at the authority's envelope expected-revision guard (`DomainWorkspaceContextAuthority.swift:1447-1452`), which intentionally returns conflict without replay.
- **Upstream PR 742's safety invariant is working but its concurrency coverage is incomplete.** Upstream PR 742 introduced transactional binding-before-provider admission and forced-rejection cleanup coverage. It did not cover several real successful same-workspace admissions racing through the authority.
- **Not cross-session routing contamination.** Open upstream issue 168 concerns explicit connection bindings being overwritten by foreign run routing, and upstream issue 456 concerns a context binding paired with an inactive workspace. Neither emits this post-routing persistence rejection, and this reproduction contains no evidence that a provider or transcript attached to the wrong session.

### Missing diagnostics and deterministic coverage

1. Preserve a typed admission-persistence failure through the MCP error and lifecycle event: local state-version retry exhaustion versus domain disposition/error/diagnostic, expected and actual workspace revisions, expected/resulting digest match (not raw digest), save attempt count, and one privacy-safe admission correlation ID.
2. Add a domain-integrated test that starts 3-8 new sessions concurrently against one non-ephemeral workspace with a real presentation bridge/authority. Require all independent targets to be admitted, all session/tab IDs to be unique, and a provider-start spy to be called exactly once per accepted request.
3. Add a barrier at save preparation/CAS minting so sibling saves share a stale expected revision deterministically. Assert bounded refresh/rebase or same-workspace serialization rather than public admission failure; retain the authority-level one-winner CAS test as the lost-update safety invariant.
4. After forced losing admission, compare in-memory tabs, canonical authority document, saved `workspace.json`, projected state, and restarted state. Assert no provisional tab/session binding survives and no accepted sibling is removed.
5. Existing tests cover the pieces but not their composition: two-window CAS correctly rejects a stale writer and succeeds after an explicit fresh-revision retry (`Tests/RepoPromptDomainRuntimeTests/DomainWorkspaceContextAuthorityTests.swift:1261-1312`); routing CAS admits one winner by design (`DomainWorkspaceContextAuthorityTests.swift:1565-1657`); forced Agent admission rejection preserves live state (`BackgroundComposeTabAdmissionTests.swift:800-848`). None exercises concurrent `agent_run.start` full-workspace durability.

### Ticket recommendation

File a **new Agent Mode/workspace-authority concurrency bug**, rather than reopening upstream issue 743 or attaching it to a routing-contamination issue. Suggested title: **“Concurrent same-workspace `agent_run.start` calls lose workspace-admission CAS and reject valid child sessions.”**

The ticket should require one owning-boundary fix: serialize/coalesce same-workspace lifecycle-admission saves, or refresh/rebase a stale presentation CAS while revalidating every provisional child identity before commit. It must not weaken the upstream PR 742 provider-start fence or teach callers to blindly retry an unknown partial success. Include durable rollback/restart assertions because current cleanup is only source/test-proven in memory.

**Maintainer-guidance check:** User impact is unreliable parallel orchestration and possible hidden provisional durable state; the invariant is that every independent start admitted by the control lane either commits exactly once or fails with a precise non-retryable reason before provider start. The runtime workspace store remains the sole authority. Root-cause confidence is confirmed at workspace-admission persistence and high, not absolute, at the leaf CAS. Recommended scope is a focused new issue followed by a bounded admission/persistence fix and domain-integrated concurrency test; validation should include the real CE MCP concurrent detached flow after the deterministic suites pass.

## Investigation Log

### Repository synchronization

**Hypothesis:** Local source might predate an upstream fix.

**Findings:** The checkout was already on `main`, tracking `upstream/main`; the initial `git pull --ff-only upstream main` reported it was up to date. Upstream advanced during and after the investigation. The checkout was fast-forwarded again to `be882cb7` on 2026-08-26.

**Evidence:** Local and upstream tip were both `2003d6c1` at investigation start. The later `0dc80b37..be882cb7` range changed only Tip release workflows, release scripts, release-tooling tests, and release documentation; none of the owning source or test areas changed.

**Conclusion:** The findings remain current at upstream `main` `be882cb7` as of 2026-08-26.

### Native task evidence

**Hypothesis:** The reported Context Builder crash was the primary defect.

**Findings:** Context Builder completed successfully. The subsequent export repeatedly closed the MCP/CLI connection. Native task analysis also found empty successful Agent runs, resume/readiness errors, unrelated content after reactivation, and partial admission during concurrent starts.

**Evidence:** The Codex task archive was cross-checked through the native task reader. Exact task timings, commands, and bounded error excerpts are recorded under Background / Prior Research.

**Conclusion:** The task contained multiple independent failures. Context Builder runtime is not one of the confirmed defects.

### External research and current-main source analysis

**Hypothesis:** Existing upstream issues or merged pull requests already covered the observed failures.

**Findings:** RepoPrompt Explore agents traced current source and searched open/closed GitHub history. Related items include upstream issue 170, upstream PRs 211, 644, 687, 299, 617, 618, 623, 791, and 742, upstream issues 863, 648, and 743/upstream PR 744. None covers the exact current boundaries. Direct final searches for the specific error phrases and operation names found no exact duplicate.

**Evidence:** The Background / Prior Research and Pair sections cite the relevant issues, pull requests, commits, and file:line references.

**Conclusion:** Two provider-independent issue drafts are justified. The three Codex lifecycle and identity findings remain separate evidence-gathering tracks; related history should be linked without reopening or misclassifying those items as duplicates.

### Context Builder, Pair, and Oracle synthesis

**Hypothesis:** The five provisional boundaries were either over-split, over-attributed, or based on one shared lifecycle defect.

**Findings:** Context Builder selected the owning code and tests. Disjoint Pair and Explore investigations independently verified export, Codex lifecycle/identity, and concurrent workspace admission. Adversarial triage preserved five technical boundaries but found only the export and concurrent-admission boundaries ready for public issue review; the other three still lack the provider-event or identity evidence needed for responsible filing.

**Evidence:** Codex lifecycle/identity validation passed four focused tests with zero failures. Concurrent admission cleanup validation passed one focused test with zero failures. These confirm existing fences and in-memory rollback, not the missing regression canaries. Export analysis was documentation-only.

**Conclusion:** Prepare two issues after explicit approval. Keep the three Codex lifecycle/identity investigations separate and cross-reference them only as one incident family until their evidence gates are met.

## Causal model and source gaps

1. **Large app-backed export:** `prompt export` and `workspace_context export` converge on one provider that assembles the complete context before writing. Both remain under the ordinary 30-second execution deadline, five-second cancellation grace, and force-disconnect cleanup policy. A legitimate large export can therefore exceed its contract and, if it remains unsettled through grace, kill the whole MCP connection. The live timing matches this path, but the missing correlated watchdog trace prevents claiming that exact branch as the historical call's proven cause.
2. **False successful completion:** CE treats a correlated Codex `turn/completed(status: completed)` as durable success after draining pending items, without requiring assistant, reasoning, tool-result, explicit no-output, or error evidence. This makes a user-only transcript persist as `Completed`.
3. **Empty resume identity/readiness:** Persisted conversation ID and rollout path can diverge. CE can construct a path-only resume candidate with an empty ID, and it can accept a successful-looking start/resume response whose thread ID is missing or blank. Request construction, response validation, persistence, and readiness do not enforce one non-empty identity invariant.
4. **Wrong non-empty provider thread:** For non-running resumes, Codex can give a supplied rollout path precedence over the supplied thread ID. CE forwards both and accepts the returned non-empty thread without proving that it belongs to the requested AgentSession. Local UUID, activation, hydration, and notification fences remain internally correct after the wrong provider identity is adopted. This mechanism is confirmed; attribution to the historical unrelated-output incident remains medium confidence without the original ID/path pair and raw resume response.
5. **Concurrent workspace admission:** Concurrent `agent_run.start` calls append provisional child sessions and independently persist the same full workspace. Save preparation and expected-revision CAS can race, and valid independent starts can lose durable admission before provider dispatch. The public error collapses local retry exhaustion and domain revision conflict. In-memory rollback is confirmed, but canonical/projection/restart cleanup is not yet proven.

## Recommendations

### Filed issues

1. Upstream issue 881: “Large app-backed prompt/workspace export can exceed the MCP watchdog and disconnect the transport.” Provider-independent MCP issue; upstream issue 170 and upstream PRs 171, 211, 567, 644, and 687 are adjacent history. The issue requires a deterministic real export that crosses the production deadline, redacted watchdog-phase evidence, explicit pre-write/post-write semantics, and a successful follow-up call when settlement is safe. It does not claim the historical call reached force-disconnect without a correlated trace.
2. Upstream issue 882: “Concurrent same-workspace `agent_run.start` calls can lose durable workspace admission.” Provider-independent Agent Mode/MCP issue; upstream PR 742/upstream issue 743/upstream PRs 744 and 746 are adjacent rather than duplicates. The issue requires deterministic multi-start admission, exactly-once provider dispatch, typed conflict diagnostics, and rollback verified through canonical state, disk, projection, and restart. It does not claim that a successfully admitted session was later lost or that a durable orphan was observed.

The filed upstream issues 881 and 882 carry the redacted title and body. GitHub created both issues without labels because the authenticated contributor account lacks label-assignment permission.

### Investigate first

1. **Empty Codex completion:** Capture the raw terminal event shape and provider diagnostic. Determine whether CE needs a non-success or explicit-no-output terminal state without breaking valid tool-only, reasoning-only, or explicitly empty runs. Treat OpenAI [Codex issue 25619](https://github.com/openai/codex/issues/25619) as a plausible upstream trigger and closed upstream issue 309 plus merged upstream PR 310 as a CE diagnostic precedent, not exact duplicates.
2. **Missing or empty resume identity/readiness:** Capture the preceding start/resume error and the redacted persisted conversation-ID/rollout-path presence shape. `Codex native send failed: session not ready` is a RepoPrompt fan-in symptom, while the missing-saved-thread-ID message is a RepoPrompt local guard; neither identifies the initiating owner by itself.
3. **Wrong non-empty provider identity:** Run the deterministic two-session ID/path-precedence canary and capture privacy-safe requested/returned identity correlation before filing. Preserve the legacy rollout-path behavior from upstream PR 618 and do not claim the historical incident is root-caused until a real mismatched pair or response is observed.

### Maintainer-guidance check

- **User impact and invariant:** Exports must complete without destroying the caller connection; successful runs need provider-result evidence; resume identity must be valid and owned by the requested session; concurrent supported starts must commit exactly once or fail for a precise non-retryable reason.
- **Root-cause confidence:** Export policy and concurrent admission are confirmed provider-independent boundaries. The false-completion gap, empty-identity gap, and provider-mismatch mechanism exist in source, but their live incident attribution remains unproven and provider-sensitive.
- **Authority:** CE owns MCP execution policy, durable terminal semantics, AgentSession-to-provider ownership validation, and lifecycle admission. Codex owns provider thread/path resolution and event generation. Workspace domain authority owns durable workspace state.
- **State-safety risks:** Blindly retrying unknown export/admission outcomes, silently fresh-starting historical sessions, or accepting a wrong non-empty thread can amplify data loss or cross-session contamination.
- **Scale and observability risks:** Large selections and parallel starts expose missing phase diagnostics. Current errors flatten distinct failure modes and omit the correlation needed for incident attribution.
- **Recommended scope:** Two issue drafts now and three evidence-gathering tracks. No fixes or provider-sensitive issues until their bounded canaries and diagnostics establish the owner.
- **Validation boundary:** Unit and contract tests at each owner, then live CE debug CLI/MCP reproduction for export and concurrent starts; capture provider events and identity correlation before drafting the remaining issues.

## Preventive Measures

- Give full-context operations an operation-specific execution contract backed by duration and cancellation canaries.
- Record pre-commit versus post-commit state for export and workspace admission so partial success is never treated as a generic retryable failure.
- Require a provider-evidence ledger before durable successful completion.
- Enforce one non-empty readiness identity across controller, coordinator, persistence, and routing.
- Correlate requested thread ID, rollout-path participation, returned thread ID, and owning CE session without logging content.
- Add two-session isolation tests for every provider resume path, including late title and event delivery.
- Test concurrent lifecycle admission against the real workspace authority, then inspect canonical state, disk, projection, and restart.
- Preserve typed retry exhaustion, revision conflict, cancellation, and health-rejection diagnostics instead of flattening them.
