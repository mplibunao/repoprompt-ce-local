# Run ledger for the upstream PR 1348 port

Request: re-create upstream PR 1348 (upstream commit `e378f9d76`) on `main` · Plan: `port-1348-context-builder-saved-agent-2026-11-06.md` (local, uncommitted)

The run ports upstream PR 1348 as hand-written edits. After `app_settings` clears the Context Builder model, the runtime keeps the saved agent and runs it on its catalog default, and that default isn't saved. `app_settings` reads and writes the stored Context Builder configuration instead of an availability fallback.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Resolver keeps the saved agent when its model is blank | done | engineer · Orchestrate 1/2: CB resolver keeps saved agent | `fix(context-builder): keep the saved agent when its model is cleared` |
| 2. `app_settings` reads and writes the stored Context Builder configuration | done | pair · Orchestrate 2/2: app_settings stored CB config; engineer · Refactor: remove legacy CB selection API | `fix(app_settings): read and write the stored Context Builder selection` |
| 3. Validation, debug-app run, and pull request | done | engineer · Branch review: port 1348; engineer · Review fixes: port 1348 | `refactor(settings): drop markUserDefined from settings write diagnostics`; `docs(ledgers): record validation for the upstream PR 1348 port` |

## Planning

- Decision: the gap was still present on `main` at `c4b5abfed`. `AutoRecommendationEngine.resolveContextBuilderSelection` required a nonempty saved model, so a cleared model sent the saved agent into recommendation ranking (Codex CLI first), while Settings showed the saved agent with its default. Source: code reading during planning.
- Decision: `app_settings` reads report the stored agent, independent of provider availability. The previous reads normalized against `AgentModelCatalog.AvailabilityContext.current`, a static assumption that marks Cursor and Grok Build unavailable. A saved `cursor` or `grokBuild` read as `codexExec`, an unknown saved ID read as `claudeCode`, and an explicit set of the displayed value was skipped as unchanged. Source: orchestrator judgment. `docs/architecture/settings-persistence.md` puts catalog fallback at runtime.
- Decision: both Context Builder `app_settings` writers use `GlobalSettingsStore.setGlobalAgentModelsProfile(_:contextBuilderWriteIntent: .userInitiated)` instead of the legacy `setGlobalContextBuilderAgentSelection` overloads. The legacy overloads normalize against `.current`, so `set agent cursor` stored `codexExec`, and a model write could land under another agent's key. This adopts the stored-configuration writer behavior from upstream commit `7a6149b83` and nothing else from it. Source: orchestrator judgment, confirmed by the plan critique.
- Decision: no new guard against restoration writing settings back. Automatic restoration assigns under `isRestoringState`, and `commitContextBuilderSettings()` has only explicit picker callers. Source: code reading.
- Decision: clearing the model when no agent is saved follows upstream. It clears Claude's slot, sets the user-defined marker, and doesn't save an agent. The legacy writer saved `claudeCode` here. Only settings written by older builds can be in this state. Source: orchestrator judgment (plan critique finding).
- Deferred (not ported): the `.headless` selection surface (the distribution has only `.general`), upstream-only providers, and upstream `7a6149b83`'s Cursor/Grok Build `options` catalog expansion.

## 1. Saved agent with a blank model

- Decision: `AutoRecommendationEngine.resolveContextBuilderSelection` accepts a saved agent that parses and is available, then returns `AgentModelCatalog.normalizeSelection` for it when the saved model is blank or passes `isValidPersistedContextBuilderModel`. A blank model normalizes to the catalog default. An invalid nonempty model, an unavailable agent, or an unknown agent still goes to the unchanged recommendation ranking. Source: approved plan.
- Decision: the test's expected result for an invalid model or an unavailable agent is whatever the resolver returns with no saved selection. The Codex fallback model comes from the advertised Codex catalog, so the test doesn't name it. Source: the coding agent's judgment.
- Decision: one guarded `normalizeSelection` call replaces two calls that differed only in the model argument. `normalizedRawModel` already maps a blank string to nil. Source: refactor review. The refactor review rejected moving the tests' resolver plumbing into a shared production seam, because the production adapters also own workspace selection and provider-validation gating. The refactor-plan step didn't run because the review gave one step with its replacement code.
- Evidence: red first, `make dev-test FILTER=RepoPromptTests.AutoRecommendationEngineScopedSettingsTests` had 5 failures on the old resolver. The agreement test resolved `codexExec` after the clear and after a reload, and the resolver table's absent, empty, and whitespace rows did the same. After the change, that suite passed 10 of 10 and `AutoRecommendationEngineModelRefreshTests` passed 7 of 7. `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-format`, and `make dev-lint` passed. The correctness review and the follow-up refactor review found nothing left to change.

## 2. Stored Context Builder selection in `app_settings`

- Decision: `context_builder.agent` reads the saved agent ID, or `claudeCode` when none is saved, and `allowed_values` still lists every `AgentProviderKind`. `context_builder.model` reads `null` for an unknown saved agent and otherwise the model slot of the saved agent (`claudeCode` when none is saved). Both writers edit the global Agent Models profile and save it with `.userInitiated`. A non-null model write with no saved agent or an unknown one also saves `claudeCode`. The implicit `options` agent is the model writer's target. Source: approved plan.
- Decision: the per-key descriptions say the selection is stored independent of provider availability and give the unknown-agent read, clear, and write rules. They appear only in `app_settings` `list` output, so the `tools/list` entry and the canonical snapshot don't change. Source: approved plan, reworded by the coding agent and its review.
- Decision: the legacy `GlobalSettingsStore` Context Builder selection API is removed: `persistedGlobalContextBuilderAgentSelection()`, `globalContextBuilderAgentSelection()`, `globalContextBuilderRememberedModelRaw(for:)`, both `setGlobalContextBuilderAgentSelection` overloads, the matching `SettingsManaging` requirements, and the `WindowSettingsManager` forwarders. Once the `app_settings` writers moved to the profile API, a search of `Sources`, `Tests`, `Packages`, and `Scripts` showed callers only inside that family, and its writers still normalized against provider availability. The approved plan kept this API by default; the refactor review changed that, because removal is compile-checked and leaves one write path. Source: refactor review.
- Decision: the new tests, their fixture, the reader's unknown-agent guard, and the description facts stay as written. Source: refactor review.
- Correction to the plan: an unknown saved agent ID read as `claudeCode`. `normalizeSelection` maps an agent that doesn't parse to `.claudeCode`, where the plan had said `codexExec`. Only a known, unavailable agent moved to the first selectable agent. The defect and the fix are the same. Source: the coding agent's red-first run.
- Evidence: red first, `make dev-test FILTER=RepoPromptTests.AppSettingsMCPServiceAgentModeSettingsTests` failed both new tests on the old service. The unknown-agent test saw `claudeCode`/`haiku` on read, a `set model null` that wiped the unknown ID, and agent and model sets skipped as unchanged. The Cursor test saw `set agent cursor` store `codexExec` and a Cursor model written to the Codex slot. After the change and the API removal, that suite passed 11 of 11, `AutoRecommendationEngineScopedSettingsTests` 10 of 10, and `GlobalSettingsPersistenceSafetyTests` 11 of 11. `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-format`, and `make dev-lint` passed. The correctness review found one wording issue in a description, which was fixed. Its follow-up and the follow-up refactor review found nothing left to change.

## 3. Validation, debug-app run, and pull request

- Evidence: `make dev-smoke-launch` built the debug app from the branch's second commit and passed its smoke flow, with Codex CLI and Claude Code both available. The build recorded the commit as `139af15f8`, which became `7f5e9d3c1` after a commit-message fix with the same tree. Through `rpce-cli-debug`, starting from `claudeCode` with a saved `sonnet`:
  - `set context_builder.model null` returned `changed` and `applied` true, and `get` returned `claudeCode` and `null`. A second clear returned both flags false.
  - A bounded `context_builder` run then reported agent `claudeCode` and model `opus`, Claude's catalog default, and `get` still returned a `null` model.
  - After a debug-only stop and `launch-existing`, `get` still returned `claudeCode` and `null`.
  - `set context_builder.agent cursor` read back `cursor`, and the implicit `options` call reported `filters.agent` `cursor` with no candidates.
  - The debug profile's original Context Builder values were restored afterwards.
- Decision: the debug app was idle when the smoke replaced it, with no running or waiting agent sessions. It was running another worktree's build. Source: orchestrator check before the relaunch.
- Decision: a branch-level review from the engineer template in `.agents/skills/rpce-merge-pr-batch/references/review-prompts.md` reviewed every commit on the branch against the PR description draft. It reported nits only, with no blockers or should-fix items. Fixed from its nits:
  - The `markUserDefined` diagnostic field that only the removed setters used.
  - A missing assertion for clearing the model with no saved agent.
  - A test that posted on the shared notification center.
  - Over-broad wording in `docs/architecture/settings-persistence.md`.
  - The claim that `get` output includes the per-key descriptions.
  - The `Upstream-Ref` line, which sat outside the commit trailer block.

  Rejected: splitting the unknown-agent test, whose name and grouping follow upstream and whose scenarios share one saved-agent state, and removing pin re-derivation from `persistGlobalDefaultsChange`, which this port doesn't touch. Source: branch review.

- Decision: the refactor pass that `CONTRIBUTING.md` asks for is the refactor gate items 1 and 2 each went through, so no separate branch-level cleanup session ran. Source: orchestrator judgment.
- Evidence: `pr-ready` against `main` passed at `9788f5005`: Swift lint, the root tests (2,048 tests in five bundles, no failures), and the RepoPrompt product build. The review fixes didn't change the behavior the debug-app run covered, so the run wasn't repeated.

## Parked decisions

- File a follow-up issue to port the rest of upstream commit `7a6149b83` (Cursor/Grok Build `options` candidates without claiming availability)? Options: file an issue, or leave it untracked. Recommendation: file an issue. Blocks: nothing. Creating a GitHub issue needs the maintainer's approval. Answer:
