# Run ledger: Agent review follow-ups review the agent's own files

Request: none · Plan: `agent-own-review-followups-2026-11-03.md`

Make a child Agent session's `review`-mode Oracle follow-ups on its own Context Builder review chat send the child's files and diff, instead of the launching tab's selection frozen when the child started, while keeping the delegated review packaging from upstream commit 198ca0cd1 for children launched to review their launcher's work.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Own review ends the run's delegated review context, with tests | done | pair · Orchestrate 1/1: own review ends delegated packaging; engineer · Review gate: own review ends delegated packaging; engineer · Refactor gate: own review ends delegated packaging | `fix(mcp): send an agent's own files on its review follow-ups` |
| 2. Live debug-app run and smoke | done | pair · Orchestrate 2/3: own review follow-ups live debug-app run | |
| 3. Contribution gates and pull request | pending | | |

## Run decisions

- Decision: when the child's own `context_builder` review returns a reply, remove that run's delegated review context with the existing `AgentModeViewModel.mcpRemoveAgentRunOracleReviewContext(sessionID:runID:)`, called from the `runMCPPlanOrQuestion` closure in `MCPServerViewModel`. Every later `review`-mode call in that run is then packaged from the child's tab. Source: user (approved plan).
- Decision: the chat-scoped alternative (record the child's own review chat IDs and keep delegation for every other chat) is not built. It would move chat selection ahead of packaging in the send path every MCP Oracle call uses. Known limit: a child that reviews its launcher's work and also runs its own review in one first run gets its own files for the launcher reviews after its own review. No built-in workflow or toolkit skill does both in one run. Source: user (approved plan).
- Decision: a fresh `review`-mode chat that the child starts without running `context_builder` first keeps the launcher's package, because nothing distinguishes it from a delegated review. Source: user (approved plan).
- Decision: no test of diff assembly with temporary git repositories; the live run's deletion-marker step covers the diff. Source: user (approved plan).
- Decision: no separate GitHub issue; the pull request carries the bug description. Source: user (approved plan).
- Decision: no cancellation check before the removal; one log line at the removal; doc comments on `mcpStageAgentRunOracleReviewSource` and in `AgentRunOracleReviewContext.swift` amended to say the fail-closed rule holds until the child's own review returns. Source: approved plan, from its design critique.
- Decision: the run works in its own worktree on `bugfix/agent-own-review-followups`, branched from `main` at `3fbf22021`. Source: orchestrator judgment, so the run doesn't change the shared main checkout.
- Decision: separate agents bound to the same worktree run the review and refactor gates with Context Builder, instead of the orchestrator, because the orchestrator's tab reads the main checkout, not the worktree. Each gate session was created empty and given its work with `steer`, so no delegated review context was staged for it and the bug this run fixes couldn't affect its own review. Source: orchestrator judgment.

## 1. Own review ends the run's delegated review context, with tests

- Decision: the closure reaches the window's `agentModeViewModel` with `try? requireTargetWindow()`. A failed lookup, which only happens while the window is being torn down, skips the removal instead of turning a finished review into an error. Source: implementing agent's judgment, accepted by the orchestrator and the independent review.
- Decision: the removal logs one line at `debug`, worded "ended the run's delegated review context, if any", because the line also fires when no delegated context existed. Source: independent review finding.
- Decision: the tests make the child a background tab, as `agent_run` creates child tabs, and bind its session with `ensureSessionReady` and `test_installPersistentSessionBinding` before `mcpActivateControlContext`. `MCPOracleCompletionPolicyFixture` became module-internal so the new tests reuse it. Source: implementing agent's judgment. With the child as the window's active tab, the packaged selection came back empty; the cause wasn't found.
- Evidence: `testChildContextBuilderReviewEndsDelegatedReviewPackaging` failed with the removal deleted (provenance `delegated`, the launcher's selection) and passes with it. `MCPAskOracleWorktreeTests` 5 of 5 and `MCPOracleCompletionPolicyTests` 6 of 6 pass; `make dev-format` changed no files; `make dev-lint` and `make dev-swift-build PRODUCT=RepoPrompt` pass.
- Evidence: an independent Context Builder review found no defects and one nit, fixed. Its follow-up round in the same chat found nothing more and reviewed the worktree's uncommitted code. A separate Context Builder refactor analysis found no P1 or P2 opportunities.
- Not pursued: two P3 test-helper consolidations from the refactor analysis, sharing the launcher selection literal and the three `ChatSendReply` literals in `MCPAskOracleWorktreeTests.swift`; each saves a few lines.

## 2. Live debug-app run and smoke

- Evidence: debug build 1.4.0 (67) of this branch at the item 1 commit, run beside production through `rpce-cli-debug`. In a disposable repository opened as its own workspace, a launcher tab had only an uncommitted `README.md` edit selected, and a child started with `agent_run op=start` and `worktree_create=true` ran every step in its first run:
  - Before its own review, a new `review`-mode chat and its follow-up both received the launcher's `README.md` and its uncommitted hunk.
  - When the child's own `context_builder` review returned, the app logged the fix's `debug` line once, with that child's session and run.
  - Continuing the review's chat in `review` mode, with and without `chat_id`, sent the child's `Gamma.swift`, `Beta.swift`, and its own `README.md`, with no launcher hunk.
  - Continuing the earlier launcher-review chat afterwards sent the child's files, which is the known limit.
- Evidence: `make dev-smoke-launch` built and launched the branch's debug app, but its smoke stage stopped at `workspace switch` because window 1 was still reopening its saved workspace. `make dev-smoke` against the same build passed.
- Decision: the app was relaunched from the same bundle with its stdout and stderr sent to a file, because the fix's log line goes to stderr and the conductor launch discards it. Source: live-run agent's judgment, accepted by the orchestrator.
- Decision: the scenario ran a second time with a Claude Code child, because the Codex child's sandbox refused the commit in the marker step (`Operation not permitted` on the worktree's `index.lock`). Source: live-run agent's judgment.
- Decision: the follow-up's diff is the patch the child's own review captured, not a fresh diff. The review leaves its patch file under `_git_data/` in the child's selection, and review packaging sends a selected patch instead of computing a new diff (`PromptPackagingService.resolveGitDiffResolution`). That rule predates this change. So after a round of fixes, a follow-up sees the child's current files with the first review's diff, and the marker step's fresh-diff expectation failed for that reason. The fix stays as decided, and the pull request text says what a follow-up receives. Source: orchestrator judgment; widening the fix to refresh the patch would change the decided design.
- Not run: in-run `oracle_send`, because it isn't in an Agent Mode child's tool list.

## Parked decisions

- Should the stale review patch in follow-ups get its own GitHub issue? After an agent's own Context Builder review, its `review`-mode follow-ups in the same chat send the review's captured patch instead of a fresh diff, so a follow-up after fixes reviews current files against the first round's diff. Options: file an issue, or leave it in this ledger. Recommendation: file it, since the `rp-orchestrate-loop` review loop relies on follow-ups after fixes. Blocks: nothing in this run. Answer: pending.
