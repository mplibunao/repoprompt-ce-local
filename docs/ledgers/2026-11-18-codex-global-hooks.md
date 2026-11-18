# Run ledger: Codex global hooks

Request: none (direct request, no issue) · Plan: `codex-global-hooks-2026-11-18.md`

Make the bundled Codex that RepoPrompt CE launches run the user's global Codex hooks. Each launch copies `~/.codex/hooks.json` into the private Codex home, and the Agent Mode hook approval flow covers user hooks as well as project hooks.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Project `hooks.json` into the private Codex home | done | engineer · Orchestrate 1/4: project hooks.json | `feat(codex): copy the global hooks.json into the private Codex home` |
| 2. Gate, approve, and verify user hooks; surface discovery warnings | done | pair · Orchestrate 2/4: gate and approve user hooks | `feat(agent-mode): review and trust global Codex hooks in the first-turn gate` |
| 3. Show hook source and matcher at approval; source-neutral copy | done | pair · Orchestrate 3/4: consent metadata and copy | `feat(agent-mode): show hook source and matcher when approving Codex hooks` |
| 3b. Show hook approvals in the default MCP `agent_run` text | done | engineer · Orchestrate 3b: hook_approval MCP text | `feat(mcp): explain hook approval pauses in agent_run output` |
| 4. Current docs and ADR | done | engineer · Orchestrate 4/4: docs and ADR | `docs(codex): record the global hooks projection and its ADR` |
| 5. Debug-app acceptance run | pending | | |

## 1. Project `hooks.json` into the private Codex home

- Decision: extend the existing projection's allowlist with `hooks.json` and rename the type to `CodexGlobalFilesProjection`, keeping the manifest file `.repoprompt-agents-projection.json` and schema version 1. Existing manifests stay valid, so instruction copies stay owned. Source: approved plan.
- Decision: the error strings say "global Codex file" throughout. `inspectionFailed` no longer claims that no file changed, because `commitManifest` can raise it after the file writes. The two mutation failures say a retry can report an unowned file. Source: approved plan, design critique.
- Evidence: `make dev-test FILTER=RepoPromptTests.CodexGlobalFilesProjectionTests` (9 passed) and `FILTER=RepoPromptTests.CodexRuntimeAuthorityTests` (9 passed). `make dev-format` and `make dev-lint` were clean. The correctness review and the refactor review found nothing to change.

## 2. Gate, approve, and verify user hooks; surface discovery warnings

- Decision: a hook is reviewable when its `hooks/list` source is exactly `project` or `user`. Disabled hooks still count, other sources are never offered, and the gate, the trust write, and post-write verification all use that one set. Source: approved plan.
- Decision: discovery warnings never block. When the gate has nothing to review, it appends one transcript notice built from the bounded summary that the discovery-failure message also uses. Codex 0.159.0 warns about hooks that still load, and throwing in `decode` would leave every hook unapprovable while a warning persists. Source: approved plan, design critique.
- Decision: the uncalled test SPI `test_gateFirstTurnForProjectHooks` is deleted instead of renamed. The gate test drives the real send path. Source: approved plan.
- Decision: if every summarized warning is blank, the notice leaves out the summary. Source: orchestrator judgment (an agent's choice, accepted).
- Evidence: `CodexHookTrustTests` (2 passed) and `CodexHookGateTests` (2 passed). With the filter set back to project-only and the notice call removed, all four new tests fail. The 13 suites that use the changed test double all pass, among them `AgentRunStartupTicketTests` (38) and `AgentRunMCPToolServiceRespondDiagnosticsTests` (5). Format and lint were clean, and the correctness and refactor reviews found nothing to change.

## 3. Show hook source and matcher at approval; source-neutral copy

- Decision: hook metadata decodes the optional `matcher`. A missing key or null becomes nil, a string is kept exactly, and any other type is rejected. The schema contract lists `data[].hooks[].matcher` as optional and nullable, as the Codex 0.159.0 schema reports it. Source: approved plan.
- Decision: the review hook carries the raw `source` and `matcher`, and one `sourceLabel` ("Global (user)", "Project (project)") and one `matcherDisplay` feed both the card and the MCP interaction. The reported `sourcePath` is shown unchanged. Source: approved plan.
- Decision: every hook-approval string says "Codex hooks" rather than "project hooks", and the card says global hooks are edited in `~/.codex/hooks.json`. Raw identifiers, settings keys, response parsing, and request identity are unchanged. Source: approved plan.
- Evidence: `CodexHookTrustTests` (3), `CodexHookGateTests` (2), `AgentRunMCPToolServiceRespondDiagnosticsTests` (6), `CodexHookReviewCardStateTests` (4), and `AppSettingsMCPServiceAgentModeSettingsTests` (9) pass. The decode and MCP snapshot tests fail when the decoder trims the matcher or the details show the raw source. `make dev-codex-schema-check` checks against the Codex on `PATH`, which is 0.166.0. `Scripts/check_codex_app_server_schema.py` run directly against the bundled 0.159.0 also passes, with 45 methods, 196 parameter paths, and 94 response paths. Format and lint were clean, and the correctness and refactor reviews found nothing to change.
- Deferred: the default `agent_run` text showed none of these details, because `ToolOutputFormatter` had no `hook_approval` case. That predates this branch; item 3b fixes it.

## 3b. Show hook approvals in the default MCP `agent_run` text

- Decision: add this item to the run. `ToolOutputFormatter.formatAgentControlRun` had no case for the `hook_approval` interaction kind. An MCP caller's default `agent_run` text for a paused run showed only a generic "Provide response" line, and the hook keys, details, and allowed responses reached a caller only through `_rawJSON`. That affected project hooks before this branch. Now that global hooks pause every MCP-started Codex session once per hook definition, the gap would stall orchestrated runs. Source: user (via the parent session).
- Decision: the case lists the allowed responses from the interaction's options, the `Error` and `Warning` details, the `hook_keys` syntax for `approve_selected`, and each hook's key, event, source, source path, matcher, trust, hash, and full command. A multiline command goes in a fenced block so its line breaks survive. The details are read from the `Hook N <Field>` labels `AgentModeViewModel` writes, and the helper's comment names that coupling. Source: orchestrator judgment.
- Evidence: `ToolOutputFormatterWorktreeTests` (20) and `AgentRunMCPToolServiceRespondDiagnosticsTests` (6) pass, and format and lint are clean. For one untrusted user hook, the default poll text grows from 547 to 1,114 characters (55 to 100 words). The `tools/list` entry is unchanged. Two correctness review rounds fixed one finding (multiline commands), and the refactor review found nothing to change.

## 4. Current docs and ADR

- Decision: the project and approve decision gets an ADR, [`docs/adr/2026-11-18-codex-global-hooks-in-isolated-home.md`](../adr/2026-11-18-codex-global-hooks-in-isolated-home.md). It is hard to reverse, because it persists trust and manifest ownership. It would surprise a reader of upstream's "no global hook bridge". And it trades isolation for global tooling. Source: approved plan.
- Decision: `docs/releasing.md` owns the operating rules: which files are read from `~/.codex`, where trust lives, that global hooks are edited in `~/.codex/hooks.json`, and that hook commands run with the private `CODEX_HOME`. The ADR owns why warnings don't block. `docs/architecture/codex-app-server-schema-gate.md` owns the current behavior, the `matcher` contract path, and the gap that the gate can't pin the `user` source value. Each links to the others instead of repeating them. Source: refactor review.
- Evidence: `make guardrails` passes. `make dev-codex-schema-check` reports 45 methods, 196 parameter paths, and 94 response paths, and the doc now says 94. Vale shows no findings above suggestion level on the changed lines. The writing agent's accuracy review ended clean after three rounds, and the consolidation review's two findings are applied.
