# Run ledger: Codex global hooks

Request: none (direct request, no issue) · Plan: `codex-global-hooks-2026-11-18.md`

Make the bundled Codex that RepoPrompt CE launches run the user's global Codex hooks. Each launch copies `~/.codex/hooks.json` into the private Codex home, and the Agent Mode hook approval flow covers user hooks as well as project hooks.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Project `hooks.json` into the private Codex home | done | engineer · Orchestrate 1/4: project hooks.json | `feat(codex): copy the global hooks.json into the private Codex home` |
| 2. Gate, approve, and verify user hooks; surface discovery warnings | pending | | |
| 3. Show hook source and matcher at approval; source-neutral copy | pending | | |
| 4. Current docs and ADR | pending | | |
| 5. Debug-app acceptance run | pending | | |

## 1. Project `hooks.json` into the private Codex home

- Decision: extend the existing projection's allowlist with `hooks.json` and rename the type to `CodexGlobalFilesProjection`, keeping the manifest file `.repoprompt-agents-projection.json` and schema version 1. Existing manifests stay valid, so instruction copies stay owned. Source: approved plan.
- Decision: the error strings say "global Codex file" throughout. `inspectionFailed` no longer claims that no file changed, because `commitManifest` can raise it after the file writes. The two mutation failures say a retry can report an unowned file. Source: approved plan, design critique.
- Evidence: `make dev-test FILTER=RepoPromptTests.CodexGlobalFilesProjectionTests` (9 passed) and `FILTER=RepoPromptTests.CodexRuntimeAuthorityTests` (9 passed). `make dev-format` and `make dev-lint` were clean. The correctness review and the refactor review found nothing to change.
