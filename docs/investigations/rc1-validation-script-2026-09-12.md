# RC1 validation checklist — 2026-09-12

> Investigation report, observed 2026-09-12 on the RC1 release candidate. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [CONTRIBUTING.md](../../CONTRIBUTING.md), Landing.

The supplied list contains 13 PR numbers; all 13 are covered below. Run app scenarios against the launched CE debug app with `rpce-cli-debug`; use a clean disposable workspace where a scenario mutates state.

## PR checks

### #39 — fix(context-builder): keep the partial Oracle answer when the inactivity monitor fires
- **Defect:** A Context Builder follow-up that stops streaming for 600 seconds discarded the partial Oracle answer and returned no MCP response.
- **Scenario:** Start `rpce-cli-debug -w 1 -c context_builder -j '{"instructions":"Answer with a long, incremental analysis of the selected files.","response_type":"question"}'` using a provider/network setup that becomes silent after partial output; let the inactivity monitor fire, then inspect the chat and MCP result.
- **Pass:** The partial text remains visible and the result/chat ends with `[RepoPrompt: response ended after 600 s without stream activity; content above is partial]`.
- **Pre-fix failure:** The chat may show partial text, but the MCP caller receives an empty/cleared response and route.

### #45 — release: gate promotion on the working-journal version
- **Defect:** Release tooling could promote a build whose working-journal schema differed from the archived build without requiring rollback instructions.
- **Proof (non-app):** Run `make release-selftest`; exercise the release archive with a planted journal and compare candidate/archive `working_journal_version` values per `docs/releasing.md`.
- **Pass:** Archive tests record the journal version (or `null` when absent), and promotion is blocked on a version mismatch until release notes include rollback instructions.
- **Pre-fix failure:** The archive omitted the mechanical journal-version evidence and the promotion checklist did not enforce the rollback gate.

### #49 — refactor(mcp): render tool errors through the shared helper
- **Defect:** The two `agent_run` worktree-start MCP error paths bypassed the shared MCP error-rendering rule, allowing inconsistent caller-facing formatting.
- **Proof (non-app):** Run `make dev-test FILTER=AgentRunMCPToolServiceStartDefaultTests`.
- **Pass:** All 5 focused tests pass and the worktree-start MCP error strings remain the shared helper’s output.
- **Pre-fix failure:** The focused path could regress independently from the shared renderer even while unrelated MCP error tests passed.

### #50 — port: restart codemap indexing after unrelated git churn
- **Defect:** Unrelated Git index/metadata changes invalidated whole codemap pages, causing large-workspace indexing to oscillate instead of completing.
- **Scenario:** In a large multi-root workspace, start `rpce-cli-debug -w 1 -c get_file_tree -j '{"type":"files","depth":3}'`; while indexing is active, make unrelated Git metadata/index changes in one root and repeat the tree request until indexing settles.
- **Pass:** Codemap progress continues through unrelated churn and reaches the full file count without repeated restart/oscillation.
- **Pre-fix failure:** Progress repeatedly falls backward or stalls at changing counts such as `1,725/1,860` and never completes.

### #51 — fix(agent-mode): make steer wait handles follow the steered run
- **Defect:** Steering an idle agent session with `wait=true` could return `Status: Expired` immediately even though the steer was delivered and the run completed.
- **Scenario:** Start a detached long-lived session with `rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"codexExec","message":"Wait idle for the operator steer.","detach":true}'`; after the session has been idle beyond terminal-record expiry, run `rpce-cli-debug -w 1 -c agent_run -j '{"op":"steer","session_id":"<id>","message":"Reply STEER_OK.","wait":true}'`.
- **Pass:** The steer call waits for the new run and returns a terminal result containing `STEER_OK`.
- **Pre-fix failure:** The call returns `Status: Expired` immediately while the steered run continues in the background.

### #52 — fix(workspaces): persist the Default workspace before its first activation
- **Defect:** Startup or an immediate workspace/bind request could observe an active Default workspace before its canonical record was writable, causing Agent Mode admission failure.
- **Scenario:** Relaunch the CE debug app, immediately run `rpce-cli-debug -e 'windows'`, then `rpce-cli-debug -w 1 -c bind_context -j '{"op":"list"}'` and `rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"explore","message":"Reply DEFAULT_OK.","detach":true}'`.
- **Pass:** The Default workspace is canonical before activation/binding, and the agent run is admitted normally.
- **Pre-fix failure:** The immediate bind or agent start observes a transient active-but-uncanonical Default and is rejected by workspace admission.

### #53 — fix(agent-mode): name the failed admission check in agent_run refusals
- **Defect:** A refused `agent_run start` reported one generic sentence, causing orchestrators to retry without knowing which workspace check failed.
- **Scenario:** Create a reproducible admission failure such as unsaved workspace changes, then run `rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"explore","message":"Reply ADMISSION_OK.","detach":true}'`.
- **Pass:** The refusal includes a bounded reason code such as `unsaved_workspace_changes` plus guidance to inspect workspace state or an existing session.
- **Pre-fix failure:** The caller receives only the generic refusal sentence and cannot distinguish the failed admission check.

### #54 — fix(mcp): answer prompt set before the active-tab reapply
- **Defect:** `prompt set` waited for a heavy active-tab reapply, could exceed the 35-second tool budget, and then lose the MCP run when the watchdog disconnected the connection.
- **Scenario:** In a large workspace, run `rpce-cli-debug -w 1 -c prompt -j '{"op":"set","text":"RC1 prompt mutation"}'`; immediately run `rpce-cli-debug -w 1 -c prompt -j '{"op":"get"}'` even if the set path reports a bounded timeout.
- **Pass:** The set responds promptly, or returns a bounded error while preserving the connection; the following get succeeds and returns `RC1 prompt mutation`.
- **Pre-fix failure:** Set stalls around 35 seconds, the watchdog disconnects the run, and the following get cannot use the connection.

### #55 — fix(context-builder): refuse a second run in the same window
- **Defect:** Two Context Builder calls on different compose tabs in one window could both pass admission, leaving the second run “running” with no provider, output, chat, or error.
- **Scenario:** Use `bind_context op=list` to obtain two tab context IDs, then concurrently bind two CLI connections with `rpce-cli-debug -w 1 -c bind_context -j '{"op":"bind","context_id":"<tab-A>"}'` and `... '<tab-B>'`; issue the same `context_builder` question from both while the provider is gated or slow.
- **Pass:** One call runs; the other is refused immediately with `Context Builder is already running in this window.`
- **Pre-fix failure:** Both calls appear admitted; the second remains running until the caller timeout without provider/output/chat/error.

### #56 — fix(mcp): bound the apply_edits preview read behind detached structure reads
- **Defect:** After a timed-out structure read left a physical read permit occupied, `apply_edits` could wait indefinitely for its preview read and never report or apply a result.
- **Scenario:** On a large workspace, start a `get_file_tree`/`read_file` request that times out, cancel/close that CLI connection while its physical read is still settling, then run `rpce-cli-debug -w 1 -c apply_edits -j '{"path":"RC1.txt","search":"before","replace":"after"}'`; repeat after the read settles.
- **Pass:** The first edit call fails within the bounded deadline with `apply_edits_read_busy` and leaves the file unchanged; the retry succeeds after the read drains.
- **Pre-fix failure:** The edit call remains pending for hundreds of seconds and lands no useful result.

### #57 — test: keep the suite inside the injected profile root
- **Defect:** Tests wrote workspaces, settings, runtime state, chats, and cleanup data into the real CE profile instead of an isolated test profile.
- **Proof (non-app):** Run `REPOPROMPT_TEST_SANDBOX_ROOT=$(mktemp -d) make dev-test` through the repository test runner, then run `make conductor-selftest`; verify test-named workspaces are absent from the real profile and present only under the sandbox.
- **Pass:** The full isolated suite passes and all test-created persistence is contained in the injected sandbox root.
- **Pre-fix failure:** A partial suite leaves test-named/default workspaces or settings under the real CE profile.

### #58 — port: attribute manage_selection operations inside selection construction
- **Defect:** Selection-construction watchdog diagnostics reported only the aggregate phase, not whether `set`, `add`, `remove`, `promote`, or `demote` stalled.
- **Scenario:** Enable debug diagnostics, run `rpce-cli-debug -w 1 -c manage_selection -j '{"op":"set","paths":["Sources/RepoPrompt/App/AppCoordinator.swift"]}'`, then run a `context_builder` question on a deliberately slow multi-root selection construction and inspect the watchdog packet.
- **Pass:** The diagnostic packet identifies the exact stalled operation, for example `manage_selection.set`, rather than only `selection_construction`.
- **Pre-fix failure:** The packet attributes the stall only to the aggregate construction phase, hiding the operation that needs investigation.

### #59 — fix(context-builder): reuse the frozen review context in nested selection
- **Defect:** Nested `manage_selection` rebuilt Git review context across every workspace root, which could freeze Context Builder on a multi-root, worktree-bound workspace.
- **Scenario:** In a three-root workspace with a linked worktree, select files with `rpce-cli-debug -w 1 -c manage_selection -j '{"op":"set","paths":["RootA/MarkerA.txt"]}'`; run `rpce-cli-debug -w 1 -c context_builder -j '{"instructions":"Review the selected files and use nested selection operations before answering.","response_type":"review"}'` while watching selection-phase timing/diagnostics.
- **Pass:** Nested selection reuses the frozen review target, the selection persists, the question completes, and no watchdog detachment occurs.
- **Pre-fix failure:** Nested selection re-probes all roots, freezes or times out, and the Context Builder run fails to complete.

## Required overlap runs

### #39 + #55 — ContextBuilderAgentViewModel interaction
- In one window, create/bind two compose-tab contexts and launch concurrent `context_builder` calls; make the first stream partial text and then go silent past the inactivity threshold.
- **Pass:** The second call is refused immediately with the same-window message, while the first preserves its partial answer and timeout marker in chat and MCP output.
- **Pre-fix signal:** The second call can hang as an unserved “running” session, and the first can lose its MCP response after timeout.

### #52 + #54 + #57 — WorkspaceManagerViewModel interaction
- Run `REPOPROMPT_TEST_SANDBOX_ROOT=$(mktemp -d) make dev-test`; in the same RC1 validation run, relaunch the debug app, immediately issue `bind_context op=list`, then set/get the prompt during a large-workspace refresh: `rpce-cli-debug -w 1 -c prompt -j '{"op":"set","text":"RC1 combined prompt"}'` followed by `... -c prompt -j '{"op":"get"}'`.
- **Pass:** Test persistence stays in the sandbox; startup binding sees a canonical Default; prompt mutation is bounded and the follow-up get succeeds.
- **Pre-fix signal:** Tests contaminate the real profile, startup bind can race an uncanonical Default, and prompt set can drop the connection before get runs.
