# Run ledger: Claude Fable 5.2 in the model catalogs

Request: none · Plan: a local deep plan, not committed

Add Claude Fable 5.2 (`claude-fable-5-2`) as a selectable, pinnable model wherever Claude Fable 5.1 appears: in the Claude Code catalogs for Agent Mode and chat, and in the direct Anthropic and OpenRouter chat catalogs. Fable 5.1 stays selectable, and a saved Fable 5.1 pin keeps resolving to `claude-fable-5-1`.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Add Fable 5.2 to the five catalog surfaces, with the test updates | done | engineer · Orchestrate 1/1: Fable 5.2 catalog entries | `feat(models): add Claude Fable 5.2 to the Claude Code, Anthropic, and OpenRouter catalogs` |
| 2. Branch-level validation and push | done | pair · Review: Fable 5.2 catalog branch | `test(models): drop the Fable 5.2 provider-default assertion`, `docs(ledgers): add the run ledger for Claude Fable 5.2` |
| 3. Live validation on the integrated debug build and pull request | done | none | `docs(ledgers): record the Fable 5.2 live check` |

## 1. Add Fable 5.2 to the five catalog surfaces, with the test updates

- Decision: Fable 5.2 is a new entry beside Fable 5.1 in the provider package catalog (`ClaudeCompatibleProviderPlugin.swift`), `AgentModel`, the adapter's XHigh set, the Claude Code chat catalog (`ClaudeCodeAIModelCatalog.swift`), and `AIModel` (`claudeFable52` with raw `claude-fable-5-2`, `openrouterClaudeFable52` with raw `anthropic/claude-fable-5.2`). Its fields match Fable 5.1's, including the five effort levels from Low to Max, the 1M context window, and the discovery tags. Source: approved plan.
- Decision: in the three Claude Code lists, Fable 5.2 sits after Fable Latest (`fable`) and before Fable 5.1, following the `AgentModel` rule that latest aliases come first and pinned IDs follow by descending version. Source: approved plan.
- Decision: the description reads "Pinned Claude Fable 5.2 with 1M context for demanding reasoning and long-horizon agentic work. Requires Claude Code 2.1.321 or newer." in both the package and `AgentModel`. Each file contains its own copy of the string, because the package doesn't import app code. Source: approved plan, following the "Core vs plugin ownership" section of `docs/architecture/provider-plugins.md`.
- Decision: no Claude Code version check, retry, or substitution for older CLIs. An older CLI fails through the existing start and turn error paths, and the description states the requirement as Fable 5.1's does. Source: approved plan.
- Decision: Fable 5.1 keeps every field, and nothing redirects `claude-fable-5-1` to `fable` or to Fable 5.2. Claude Code roles and defaults stay as they were. The provider default stays `opus`, and none of the role recommendation chains lists a Fable model. Source: approved plan.
- Decision: the change extends five existing tests and doesn't add a test file. The agent renamed `testClaudeCodeCatalogExposesSonnet55AndRestrictedMythos51` to `testClaudeCodeCatalogKeepsAgentAndChatPinnedModelsConsistent`, because its table now covers Fable 5.2 and Fable 5.1 too. Source: approved plan, following `.agents/skills/rpce-test-quality/SKILL.md`.
- Evidence: focused runs pass: `ClaudeCompatibleRuntimeSupportTests/testProviderCatalogDefaultsExposeStableRawValues` (1), `ClaudeCompatiblePluginBridgeTests/testClaudeCodeCatalogKeepsAgentAndChatPinnedModelsConsistent` (1), `ModelPickerStringOrderingTests/testClaudeCodePickerExposesOpus55WithSupportedEfforts` (1), `DirectModelCatalogRefreshTests` (7), and `AnthropicProviderRequestPolicyTests` (4). `make dev-format` left every file unchanged, and `make dev-lint` passes.
- Review: the engineer agent's `context_builder` review found nothing to fix. The refactor review didn't find a material opportunity: the new entries follow their neighbours, and the duplicated catalog data follows the package and app ownership split. Refactor gate: no changes.
- Deferred: the direct Anthropic picker lists Fable 5.1 before Fable 5.2, as it lists Opus 5 before Opus 5.5, because its sort reads hyphenated IDs as a suffix. Issue #380 tracks it. Direct Anthropic requests can't set an effort level, so the direct Fable 5.2 entry runs at its default effort. Issue #128 tracks it. Claude Mythos 5.2 and the Cursor catalog are out of scope.

## 2. Branch-level validation and push

- Decision: item 1's review came from the agent that wrote the change. A second, independent session reviewed the branch on a different model, from the Engineer review template in `.agents/skills/rpce-merge-pr-batch/references/review-prompts.md`. Source: orchestrator judgment.
- Review: no blockers. The reviewer confirmed that every Fable 5.1 site outside the tests has a Fable 5.2 counterpart, that no two models share an identity, and that each extended test fails if Fable 5.2 is missing from the XHigh set, the chat catalog, or the package catalog, or if it reuses Fable 5.1's identity.
- Decision: the new `XCTAssertFalse(fable52.isProviderDefault)` line is removed, although the plan listed it. `snapshot` sets `isProviderDefault` to false for every Claude Code model, so the assertion couldn't fail. The `defaultModelRaw` check already guards the default. The same assertions on Opus 4.8, Sonnet 5.5, and Mythos 5.1 remain, because they're outside this change. Source: review finding, under the `rpce-test-quality` rule against restating constants.
- Decision: the pull request text limits the adaptive-thinking claim to direct Anthropic requests. The OpenRouter provider builds its own request and can send `temperature`, which OpenRouter's model list (checked 2026-11-10) doesn't list as supported for Fable 5.2, Fable 5.1, or Opus 5.5. OpenRouter ignores unsupported parameters by default, so this behaviour predates the change and doesn't make requests fail. Source: review finding.
- Evidence: after the fix, `make dev-format` left every file unchanged, `make dev-lint` passes, and `ClaudeCompatibleRuntimeSupportTests/testProviderCatalogDefaultsExposeStableRawValues` passes.
- Evidence: `git merge-tree` shows the branch merges cleanly with the heads of #363, #353, and #364, which touch model and role settings.
- Evidence: `pr-ready` passed on `origin/main..HEAD` before the first push. It ran Swift lint, the root and provider tests, and the `RepoPrompt` product build, with no failures. The push preflight passed.
- Decision: pull request #382 opened before the debug-app check because the coordinating thread asked for an early review. The dog-food rules allow that when the description says the check is pending. Source: coordinating thread.
- Decision: the type label is `enhancement`, because a model addition fits none of the six type labels in `CONTRIBUTING.md`. The preflight lanes don't check the type label. The area labels are `area:agent-mode`, `area:chat`, and `provider:claude`. Source: approved plan.

## 3. Live validation on the integrated debug build and pull request

- Evidence: the integrated debug build contained this branch at `54bac0ae0`. `make dev-smoke` passed against it.
- Evidence: in the debug app, `app_settings` `options` for Claude Code lists Fable 5.2 between Fable Latest and Fable 5.1 in the Agent Mode catalog, with Low to Max efforts and a 1M context window. Its tags match Fable 5.1's. The Claude Code chat catalog lists `claude_code__claude-fable-5-2` and its five effort variants. The role mapping matched the mapping before the rebuild, and no role moved to Fable 5.2.
- Decision: the catalog check used `app_settings` `options` instead of `agent_manage` `list_agents`. The debug profile sets `restrictMCPAgentDiscoveryToRoleLabels`, so `list_agents` returns only the role labels. The check left that setting unchanged. Source: orchestrator judgment.
- Evidence: an agent started on `claudeCode:claude-fable-5-2:high` replied with the expected token. The app sent `claude-fable-5-2` in `apply_flag_settings`, and the CLI's `init` event reported `model` `claude-fable-5-2` on Claude Code 2.1.321.
- Evidence: an agent started on `claudeCode:claude-fable-5-1:high` replied with its token. The app sent `claude-fable-5-1`, and the `init` event reported `claude-fable-5-1` on Claude Code 2.1.321. Claude Code 2.1.321 runs an explicit Fable 5.1 pin as Fable 5.1.
- Evidence: Claude raw event logging and the performance diagnostics were already on, and the check left every setting unchanged. Both test sessions finished and were deleted, and the debug app kept the same process throughout.
- Evidence: `pr-ready` on the full branch after this ledger update failed in two root tests that this change doesn't touch. `BindContextRoutingAuthorityTests/testNewWindowSwitchReusesPreferredWindowAlreadyShowingWorkspace` passed when rerun alone. `MCPWorkspaceScopedCursorModelParameterTests/testSettingsPinnedCursorEffortAndSpeedReachRoleLabelRun` failed with `CancellationError()` in every rerun, including one on `origin/main` `403c210a8`. Issue #274 tracks both tests.
