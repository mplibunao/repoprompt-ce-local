# Run ledger for the upstream PR 1348 port

Request: re-create upstream PR 1348 (upstream commit `e378f9d76`) on `main` · Plan: `port-1348-context-builder-saved-agent-2026-11-06.md` (local, uncommitted)

The run ports upstream PR 1348 as hand-written edits. After `app_settings` clears the Context Builder model, the runtime keeps the saved agent and runs it on its catalog default, and that default isn't saved. `app_settings` reads and writes the stored Context Builder configuration instead of an availability fallback.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Resolver keeps the saved agent when its model is blank | done | engineer · Orchestrate 1/2: CB resolver keeps saved agent | `fix(context-builder): keep the saved agent when its model is cleared` |
| 2. `app_settings` reads and writes the stored Context Builder configuration | pending | | |
| 3. Validation, debug-app run, and pull request | pending | | |

## Planning

- Decision: the gap was still present on `main` at `c4b5abfed`. `AutoRecommendationEngine.resolveContextBuilderSelection` required a nonempty saved model, so a cleared model sent the saved agent into recommendation ranking (Codex CLI first), while Settings showed the saved agent with its default. Source: code reading during planning.
- Decision: `app_settings` reads report the stored agent, independent of provider availability. The previous reads normalized against `AgentModelCatalog.AvailabilityContext.current`, a static assumption that marks Cursor and Grok Build unavailable. So a saved `cursor` or `grokBuild` read as `codexExec`, and an explicit set of the displayed value was skipped as unchanged. Source: orchestrator judgment. `docs/architecture/settings-persistence.md` puts catalog fallback at runtime.
- Decision: both Context Builder `app_settings` writers use `GlobalSettingsStore.setGlobalAgentModelsProfile(_:contextBuilderWriteIntent: .userInitiated)` instead of the legacy `setGlobalContextBuilderAgentSelection` overloads. The legacy overloads normalize against `.current`, so `set agent cursor` stored `codexExec`, and a model write could land under another agent's key. This adopts the stored-configuration writer behavior from upstream commit `7a6149b83` and nothing else from it. Source: orchestrator judgment, confirmed by the plan critique.
- Decision: no new guard against restoration writing settings back. Automatic restoration assigns under `isRestoringState`, and `commitContextBuilderSettings()` has only explicit picker callers. Source: code reading.
- Decision: clearing the model when no agent is saved follows upstream. It clears Claude's slot, sets the user-defined marker, and doesn't save an agent. The legacy writer saved `claudeCode` here. Only settings written by older builds can be in this state. Source: orchestrator judgment (plan critique finding).
- Deferred (not ported): the `.headless` selection surface (the distribution has only `.general`), upstream-only providers, and upstream `7a6149b83`'s Cursor/Grok Build `options` catalog expansion.

## 1. Saved agent with a blank model

- Decision: `AutoRecommendationEngine.resolveContextBuilderSelection` accepts a saved agent that parses and is available, then returns `AgentModelCatalog.normalizeSelection` for it when the saved model is blank or passes `isValidPersistedContextBuilderModel`. A blank model normalizes to the catalog default. An invalid nonempty model, an unavailable agent, or an unknown agent still goes to the unchanged recommendation ranking. Source: approved plan.
- Decision: the test's expected result for an invalid model or an unavailable agent is whatever the resolver returns with no saved selection. The Codex fallback model comes from the advertised Codex catalog, so the test doesn't name it. Source: the coding agent's judgment.
- Decision: one guarded `normalizeSelection` call replaces two calls that differed only in the model argument. `normalizedRawModel` already maps a blank string to nil. Source: refactor review. The refactor review rejected moving the tests' resolver plumbing into a shared production seam, because the production adapters also own workspace selection and provider-validation gating. The refactor-plan step didn't run because the review gave one step with its replacement code.
- Evidence: red first, `make dev-test FILTER=RepoPromptTests.AutoRecommendationEngineScopedSettingsTests` had 5 failures on the old resolver. The agreement test resolved `codexExec` after the clear and after a reload, and the resolver table's absent, empty, and whitespace rows did the same. After the change, that suite passed 10 of 10 and `AutoRecommendationEngineModelRefreshTests` passed 7 of 7. `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-format`, and `make dev-lint` passed. The correctness review and the follow-up refactor review found nothing left to change.

## Parked decisions

- File a follow-up issue to port the rest of upstream commit `7a6149b83` (Cursor/Grok Build `options` candidates without claiming availability)? Options: file an issue, or leave it untracked. Recommendation: file an issue. Blocks: nothing. Creating a GitHub issue needs the maintainer's approval. Answer:
