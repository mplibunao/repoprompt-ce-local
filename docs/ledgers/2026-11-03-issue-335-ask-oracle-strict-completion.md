# Run ledger: `ask_oracle` waits for the provider's completion

Request: #335

Make Agent-session `ask_oracle` send with the strict completion policy that `oracle_send` already uses, so a Codex oracle that writes one sentence and then reasons silently for more than 10 s is no longer cut off by the interactive inactivity watchdog. Prove it with the endpoint-policy test and a debug-app run, then open the pull request.

Base: `main` at `3fbf22021`.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Strict policy for `ask_oracle` and its endpoint test | done | engineer · #335 1/3: strict policy for ask_oracle + endpoint test | `fix(mcp): send ask_oracle with the strict completion policy` |
| 2. Debug-app proof on a Codex oracle | done | pair · #335 2/3: debug-app proof on a Codex oracle | none |
| 3. Review, cleanup, and pull request | done | engineer · #335 3/3a: independent review; pair · #335 3/3b: cleanup pass; engineer · #335 3/3c: pr-ready and pull request | `docs(ledgers): add the run ledger for issue 335` |

## Decisions made before the run

- Decision: `ask_oracle` sends with `.contextBuilderStrict` in `MCPOracleToolService.executeAskOracle`, the policy `oracle_send` has used since #77. Every reply delivered through the MCP oracle tools then waits for the provider's terminal event, an error, or cancellation; only in-app edit-and-resend keeps the interactive policy. Source: user.
- Decision: Codex liveness events are not counted as activity. In rollouts of four cut-off oracle turns (2026-10-21), reasoning items finished up to about 20 s apart after the first sentence. The rollouts don't record liveness events, but none of their kinds is a periodic heartbeat and an oracle turn uses no tools, so they likely would not cover those silences; Codex liveness stays with #4. Source: user.
- Decision: no marker in saved chats for replies the interactive watchdog ends, because that watchdog also ends some complete replies from providers that never send a terminal event. Source: user.
- Decision: no live run on the old code; the 2026-10-21 production rollouts and the endpoint test's failure on unchanged source show the bug. Source: user.
- Decision: the `completionPolicy` parameter on the MCP send path stays; removing it would change four interfaces for no change in behavior. Source: approved plan.
- Decision: the branch is `bugfix/335-ask-oracle-strict-completion`, following the repository's `bugfix/<issue>-<slug>` pattern. Source: orchestrator judgment.

## 1. Strict policy for `ask_oracle` and its endpoint test

- Decision: `MCPOracleToolService.executeAskOracle` passes `.contextBuilderStrict` to `sendChat`, and `testOracleEndpointsSelectExplicitCompletionPolicies` in `MCPOracleCompletionPolicyTests` expects strict from both endpoints. The test's `ask_oracle` message changed from `"interactive"` to `"ask"`; the `oracle_send` message `"strict"` is on a line this change doesn't touch, so it stays. Source: approved plan, and orchestrator judgment for the untouched line.
- Evidence: with only the test changed, the test failed at `MCPOracleCompletionPolicyTests.swift:38`, observing `[contextBuilderStrict, interactive]`; the daemon's cold-build retry failed the same way. After the source change, `MCPOracleCompletionPolicyTests` passed 6 of 6, and `make dev-format` (no changes beyond the edit), `make dev-lint`, `make dev-swift-build PRODUCT=RepoPrompt`, and the commit preflight passed.
- Evidence: a Context Builder review of the commit's diff reported no findings. The implementing agent confirmed that no tracked code, test, doc, tool description, or workflow prompt states that `ask_oracle` runs interactive, and that the policy reaches `sendMessage` through `MCPServerViewModel.swift:900` and `OracleViewModel+MCP.swift:1198` with no default in between.
- Decision: the commit body says `Refs #335`; the pull request closes the issue. Source: implementing agent judgment.

## 2. Debug-app proof on a Codex oracle

- Evidence: the debug app was relaunched on a build of `610684a9b` after a check that none of its 10 windows had a running or waiting Agent session; production was not stopped or relaunched. `make dev-smoke-launch` failed at its workspace-switch stage while window 1 was still reopening a large saved session; `make dev-smoke` then passed every stage.
- Evidence: two engineer Agent runs in the debug app each added two files to their own selection and called `ask_oracle` twice, a new chat and then a follow-up on its `chat_id`, with no retries. Both follow-ups returned their whole reply through the closing sentinel (4,839 and 4,761 characters), and each saved chat holds the same text. Run 1 used the debug profile's Oracle model, GPT-6.1 Sol at high effort; run 2 used production's, gpt-6-astra at xhigh effort, set with `app_settings` and restored afterwards.
- Evidence: neither follow-up had a silence after its first text. In the Codex rollouts, each turn ended in `task_complete` with no `turn_aborted`, and all reasoning finished before the first text (run 1: one reasoning item, text from +17.3 s; run 2: three items, text from +43.6 s). The interactive watchdog only acts after text appears, so neither run would have been cut off on the old code either. The runs are wiring evidence only.
- Evidence: production's tool-free Codex oracle turns over the five days before the run all used gpt-6-astra at xhigh; 68 of 112 opened with a separate first sentence, and 6 ended in `turn_aborted`. Each 2026-10-21 cut-off opened with a separate first sentence followed by reasoning.
- Decision: the run stopped after one rerun, the cap in the approved plan, rather than spending more provider requests on a cut-off that showed up in about 6 of 112 recent production turns. Source: approved plan.
- Deferred: the plan's debug-app procedure needs two corrections for later runs. `ask_oracle` uses the first matching model preset instead of `models.planning_model` when `mcp.show_model_presets` is on and presets exist, so `oracle_utils` `models` should confirm the model first. And `make dev-smoke-launch` fails at workspace switch while a large saved session is still reopening; rerunning `make dev-smoke` afterwards works.
- Decision: #335's acceptance no longer requires the live run to cross a silence longer than 10 s; it requires a current debug build to complete an Agent-session `ask_oracle` follow-up on a Codex CLI oracle and keep the whole reply, which these runs did. The pull request closes #335 and states that no live run reproduced the silence. Source: user, choosing this over closing the issue later from production logs or spending about 20 more debug runs.

## 3. Review, cleanup, and pull request

- Decision: the review and cleanup ran as fresh Agent sessions bound to this worktree, from the prompts in `.agents/skills/rpce-merge-pr-batch/references/review-prompts.md`, quoting the pull request description draft. Source: orchestrator judgment, following `CONTRIBUTING.md` step 4.
- Evidence: the review found no blocker and no code change to make. It confirmed one `sendChat` call site for every `ask_oracle` path, that review packaging and the export run outside it, that strict changes only the two watchdogs, that stream exhaustion without a terminal event fails the same way under both policies, that no tool description, workflow prompt, or test relies on `ask_oracle` running interactive, and that the endpoint test separates broken from fixed.
- Decision: the review's two text findings were accepted. The pull request description now says that cancelling or timing out the `ask_oracle` tool call drops only the waiting call while the provider turn runs on until it completes or times out, which the interactive watchdog used to cut at its first 10 s silence; and it states the Codex liveness conclusion as an inference, because rollouts don't record liveness events. Source: review finding.
- Evidence: the cleanup pass made no changes. It rejected removing the `completionPolicy` parameter, because the endpoint test observes the policy through it; renaming the endpoint test, whose name is still accurate; and renaming the untouched `"strict"` test message. Source: cleanup session judgment.
