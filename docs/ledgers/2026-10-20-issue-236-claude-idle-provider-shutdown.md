# Run ledger: idle Claude provider shutdown

Request: #236 · Plan: `issue-236-claude-idle-provider-shutdown-2026-10-20.md`

Shut down an idle Claude Agent Mode provider process after a configurable period (default 5 minutes, 0 = never, shared with Codex) and resume the session with `--resume` on the next message, keeping the process while a run, prompt, queued instruction, MCP tool, child wait, or live background task needs it. A failed resume retries once, then falls back to the existing fresh start with a notice.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Validate seams and probe the background-task event | partial | engineer · 236 item 1: seam check | none |
| 2. Setting, task store, and Codex | done | engineer · 236 item 2: setting, store, Codex | `feat(agent-mode): add the idle provider shutdown setting and use it for Codex` |
| 3. Claude idle timer and retirement | pending | | |
| 4. Background-task keep-alive and spawn evidence fields | pending | | |
| 5. Resume retry, notice, and test consolidation | pending | | |
| 6. Checks, debug-app run, and pull request | pending | | |

## 0. Prepare the branch

- Decision: the branch `bugfix/236-claude-idle-provider-shutdown` starts from `origin/main` at `cacf48158`, in its own RepoPrompt worktree attached to the existing `repoprompt-ce` workspace. Source: approved plan.
- Decision: the plan's eight execution items run as five work items plus close-out. Plan item 6's `process.spawned` fields go with item 4, which edits the same controller, and its test consolidation goes with item 5, the last code item. Plan items 7 and 8 (checks, debug-app run, review, `pr-ready`) are close-out item 6. Source: orchestrator judgment.
- Decision: MP's rule for this run (2026-10-20): reversible questions are decided by the orchestrator from the plan's decisions and MP's stated preference to keep current behavior when a change could break something unexpectedly or the existing behavior has a reason. Source: user.

## 1. Validate seams and probe the background-task event

- Evidence: a read-only seam check on `cacf48158` found every integration point the design uses where the plan puts it, give or take a few lines: the attach in `ensureClaudeNativeSession` (`ClaudeAgentModeCoordinator.swift:437`), the resume transfer (`:1207-1291`), `stop()` (`:223-232`), `startOrResumeWithFallback` (`:639-737`), both runner terminals (`ClaudeIntegratedAgentModeRunner.swift:375-435`, neither passes `postCommit`; `Request.init` defaults it to `{}`), the barrier calling `postCommit` synchronously right before `startFollowUpRun`, `PerKeyTaskStore`, and Codex's idle timer with its stale `defer` (`CodexAgentModeCoordinator.swift:9949`). `isSessionCurrent` is an identity check on the window's session map, so hiding Agent Mode doesn't end a timer.
- Decision: `stop()` stops cancelling and clearing resume-transfer state, as Decision 10 says. The check found one consequence the plan doesn't name: a finished transfer left in the retired list (after a workspace switch moves it there) keeps `hasPendingResumeTransfer` true for that tab until the next run attempt drains it, and until then a `.reconnect` attach returns `.superseded`. Accepted: reconnect needs a persisted ownerless active run, and a workspace switch cancels active runs before it detaches; the idle gate is unaffected because no controller is attached until that run attempt. Source: approved plan (Decision 10), orchestrator judgment on the consequence.
- Decision: `idleProbe()` is a protocol requirement with no default implementation, so the compiler forces every conformer to answer it. The two test conformers the plan's file list misses (`StartupTestClaudeController` in `AgentRunStartupSnapshotTests.swift`, `ShutdownRecordingNativeController` in `ContextBuilderGracefulShutdownTests.swift`) get explicit implementations. Source: orchestrator judgment.
- Decision: the whole-number and range checks for `agent_mode.idle_provider_shutdown_minutes` run before any mutation. `numberSetting` accepts any finite number today and has no validator hook, so the check is added without changing `models.temperature`'s behavior. The settings type the coordinators are wired to is `GlobalSettingsStore.shared` (defined in `GlobalSettingsManager.swift`). Source: orchestrator judgment.
- Decision: the idle timer is armed at both controller attach sites in the coordinator, the one in `ensureClaudeNativeSession` and the fresh-start fallback's (`:719`, later item 5's helper). The terminal barrier skips `postCommit` when it rejects a commit outright, so without the second arm a controller attached by the fallback could stay unarmed until its next run. Source: orchestrator judgment.
- Decision: the test fake's `currentSessionRef()` returns a fixed ID and its `startOrResume` never throws; items 3 and 5 extend it so a test can choose both. Source: orchestrator judgment.

## 2. Setting, task store, and Codex

- Decision: `app_settings` validates `agent_mode.idle_provider_shutdown_minutes` with a sibling `wholeNumberSetting` helper; `numberSetting` and `models.temperature` are unchanged, and the key still lists as type `number`. Source: implementer, accepted by the orchestrator.
- Decision: the Codex coordinator takes the setting as a required init parameter so no construction site can skip it; a DEBUG `idleShutdownDelayNanos` override still wins at arm and fire. The DEBUG view-model initializer passes a constant 5 minutes, which keeps tests off the machine's real settings. Source: implementer, accepted by the orchestrator.
- Decision: the help text scopes the 2-hour background-command keep-alive to Claude, because Codex doesn't keep a process for background terminals. The headless `app_settings` catalog in `Sources/RepoPromptDomainRuntime/DomainDirectSettings.swift` doesn't get the key, because headless has no Agent Mode runtime. Source: implementer, accepted by the orchestrator.
- Evidence: `PerKeyTaskStoreTests/testReplacedTaskCannotRemoveItsSuccessor` passes, and with `remove(_:ifToken:)` changed to ignore the token it fails on the successor-lost assertions. The two `AppSettingsMCPServiceAgentModeSettingsTests` methods pass (default 5, persistence across a reload; 1.5, "1.5", -1, 121, infinity, "ten", true and null leave the value and file unchanged; 0 stays distinct from missing). `make dev-format`, `make dev-lint` and `make dev-swift-build PRODUCT=RepoPrompt` pass. No test exercises Codex's timer; the debug-app Codex step in item 6 covers it.
- Decision: review found no must-fix or suggestion-level issues. Of its two nits, the store test now asserts the replaced task is cancelled and cancels it before awaiting, so a regression fails instead of waiting out a one-hour sleep. The other stays: a numeric string with more digits than a `Double` holds is rounded before the whole-number check, and a JSON number with the same digits is rounded at decode anyway. Source: review finding.
- Decision: refactor pass, two behavior-preserving changes: `PerKeyTaskStore` has one `set(_:token:task:)` with a default token whose body calls `cancel(_:)`, and the Codex init label is `idleShutdownDelayNanosOverride:` to match what it now means. A shared fixture for the settings tests was dropped, because the file's other seven tests inline the same setup. A follow-up analysis on the same chat found nothing further. Source: refactor analysis.
- Evidence: RepoPrompt reads in production window 1 failed throughout with `tool_execution_structure_settlement_busy`, so review and refactor analyses received the patch pasted into the chat instead of through discovery.
- Deferred: Codex's stall-watchdog task has the same stale-removal defect in its `defer` (a cancelled task can remove a successor's entry). Outside #236's plan; drafted for filing, not filed.
