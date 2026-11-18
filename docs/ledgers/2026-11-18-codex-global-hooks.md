# Run ledger: Codex global hooks

Request: none (direct request, no issue) · Plan: `codex-global-hooks-2026-11-18.md`

Make the bundled Codex that RepoPrompt CE launches run the user's global Codex hooks. Each launch copies `~/.codex/hooks.json` into the private Codex home, and the Agent Mode hook approval flow covers user hooks as well as project hooks.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Project `hooks.json` into the private Codex home | done | engineer · Orchestrate 1/4: project hooks.json | `feat(codex): copy the global hooks.json into the private Codex home` |
| 2. Gate, approve, and verify user hooks; surface discovery warnings | done | pair · Orchestrate 2/4: gate and approve user hooks | `feat(agent-mode): review and trust global Codex hooks in the first-turn gate` |
| 3. Show hook source and matcher at approval; source-neutral copy | pending | | |
| 4. Current docs and ADR | pending | | |
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
