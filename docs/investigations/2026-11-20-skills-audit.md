# Skills audit 2026-11-20

Observed on 2026-11-20, at pull request #396's head `6372c2701` against `main` at `3dd846fcd`.

## Scope

Pull request #396 lets Codex sessions in RepoPrompt run the global hooks in `~/.codex/hooks.json`. Codex runs a hook only after someone trusts it. When a session finds a hook that nobody has trusted, RepoPrompt pauses the session's first turn until someone decides. This report calls that pause a hook approval. The orchestrator is the agent that called `agent_run` to start the session. It gets RepoPrompt's reply about the pause and can answer it. The Codex agent in the paused session never sees these texts.

This audit covers the agent-facing text that #396 adds or changes in code: the hook approval section of the `agent_run` reply, the hook approval's prompt, context, title, answer descriptions, and hook details, the notices RepoPrompt adds to the session's chat around it, and its errors. The pull request's Markdown records and the text only a person reads (the approval screen's layout, the Settings row, and the tool card's `codex hook approval` label) are out of scope. Usage window: not applicable, because no skill is in scope.

Examples use one global hook, rtk's `PreToolUse` hook, as the production Codex home copies it. `<home>` stands for the user's home folder, and the character counts count it as six characters. Other runtime values are written as placeholders, such as `<session id>`.

Each string has these readers:

- The hook approval section of the `agent_run` text reply: the orchestrator, when its `agent_run` `start`, `wait`, or `poll` returns a session that waits for hook approval. The section has one entry per hook.
- The hook approval's title, answer descriptions, and hook details: agents and scripts that read the raw JSON form of the reply, such as `rpce-cli --raw-json`. The source label is also on the approval screen a person sees in RepoPrompt.
- Notices: a person in the session's chat in RepoPrompt, the orchestrator through `agent_manage` `get_log`, which shows them as `<system>` lines, and the model in a forked or replayed session.
- Errors: the orchestrator after a failed `agent_run` `respond`, and a person on the approval screen.

## Checks run

| Check | Command or method | Result |
| --- | --- | --- |
| Structure | GitHub checks on `6372c2701`; the tests that pin the text | Build and Test, Style, and Secret Scan pass. `ToolOutputFormatterWorktreeTests` pins each hook's entry, `Project (project)`, and the hash. `AgentRunMCPToolServiceRespondDiagnosticsTests.swift:254` pins `Project (project)`. |
| Usage and dependents | not applicable | No skill in scope. |
| Prose | Vale with the user configuration on the extracted strings; unslop docs rules, report-only | Vale: passive voice in status text, kept; semicolons in the `continue_without_hooks` description and the trusted notice, which findings 3 and 6 remove. Unslop: the trusted notice uses two undefined terms, "unresolved" and "controller binding" (finding 6). |
| Restated rules | reading pass per references/restated-rules.md | The `approve_selected` line of the hook approval section restates the respond error at `AgentModeViewModel.swift:11345` (kept, finding 7). The `continue_without_hooks` description and the continued notice state one fact in different words (findings 3 and 5). |
| Platform claims | Codex hooks documentation, https://learn.chatgpt.com/docs/hooks (308 from https://developers.openai.com/codex/hooks), checked 2026-11-20 | "already trusted or managed hooks can still run" holds: non-managed hooks run only once trusted, new or changed hooks are skipped until trusted, and managed hooks are trusted by policy. Where trust is stored is unverifiable: the page doesn't say. The private Codex home's `config.toml` holds it under `[hooks.state]`. "copied from ~/.codex/hooks.json at launch" holds: `CodexRuntimeAuthority.prepareState` copies it whenever RepoPrompt starts a Codex runtime. |
| Rigidity | reading pass per references/rigidity.md | none |
| Pruning | reading pass per references/pruning.md | no action: the hash in each hook's entry (finding 1); duplication: the source path in each hook's entry (finding 1), "without trusting the other shown hooks" (finding 2), `Project (project)` (finding 4), "This decision does not disable…" (finding 5) |

## Findings

| # | Location | Check | Evidence | Disposition | Proposed change | Effect |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Sources/RepoPrompt/Infrastructure/MCP/ToolOutputFormatter.swift:6156-6162`; `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:7183` | pruning (no action; duplication) | Each hook's entry ends with a 71-character hash that no call takes and no agent can check, and repeats the source path that the key already starts with | trim (approved) | drop `hash …` and the source path from each hook's entry, and the source path from the `hook_keys` option description ([details](#finding-1)) | The orchestrator reads 162 fewer characters per global hook. They lose the hash, and the separate path if Codex's key ever stops starting with it. The approval screen and the raw JSON details keep both. |
| 2 | `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:7107` | pruning (duplication) | "only" already says the other hooks stay untrusted | trim (approved) | "Trust only the hooks listed in answers.hook_keys and continue" ([details](#finding-2)) | Raw JSON readers lose nothing. |
| 3 | `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:7114` | prose; restated rule | "without completing hook trust" doesn't say that the shown hooks stay untrusted, and Codex skips untrusted hooks; finding 5's notice states the same fact in other words | correct (approved) | "Continue without trusting the shown hooks. Trusted and managed hooks can still run." ([details](#finding-3)) | A raw JSON reader learns that choosing it leaves the shown hooks off. The option and the notice use the same words. |
| 4 | `Sources/RepoPrompt/Features/AgentMode/Models/CodexHookApprovalModels.swift:34` | pruning (duplication) | `Project (project)` repeats the word; `Global (user)` maps a label to Codex's name, so it stays | trim (approved) | `Project` ([details](#finding-4)) | Agents and the approval screen show `Project`. Two test assertions change. |
| 5 | `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:1189` | pruning (duplication); restated rule | The second sentence takes 64 characters to say what finding 3's option says in 40 | trim (approved) | "Continued without trusting <n> Codex hook(s). Trusted and managed hooks can still run." ([details](#finding-5)) | The transcript, `get_log`, and forked sessions read 24 fewer characters and the same fact. |
| 6 | `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:1335` | prose (undefined terms) | "unresolved" (not trusted yet) and "controller binding" (the Codex process the session uses) are code terms that nothing in the chat defines | trim (approved) | "Trusted <n> Codex hook(s) and left <m> untrusted." ([details](#finding-6)) | Readers no longer learn that RepoPrompt asks about the skipped hooks again when the session gets a new Codex process. Codex skips them until then either way. |
| 7 | `Sources/RepoPrompt/Infrastructure/MCP/ToolOutputFormatter.swift:6110-6168` | restated rule | The `approve_selected` line restates the respond error at `AgentModeViewModel.swift:11345` | keep | none | The agent needs the shape to write its first valid `respond`. `docs/architecture/mcp-tool-descriptions.md` principle 2 keeps a rule in place when an agent needs it to write a valid call. |
| 8 | `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:7194-7196` | platform claim | "Trust is saved for this RepoPrompt profile…": Codex's documentation doesn't say where trust is stored | keep | none | The claim rests on the `[hooks.state]` table observed in the private Codex home, not on documentation. |

The other strings in scope have no finding: the interaction title, the `retry` description, the matcher note `Not provided by Codex`, the new discovery-warning notice, the resolved-externally notice, and the eight reworded errors, which replace "project hook" with "Codex hook" or "global and project hook".

## Finding details

### Finding 1

`Sources/RepoPrompt/Infrastructure/MCP/ToolOutputFormatter.swift:6156-6162`, one hook's entry in the hook approval section of the `agent_run` reply. `main` printed no entries. The same decision applies to the `hook_keys` option description at `AgentModeViewModel.swift:7183`, `<event> · <source label> · <source path> · <trust>`, whose option label is the key.

Current, 332 characters:

```text
  - `<home>/Library/Application Support/RepoPrompt CE/Codex/Release/home/hooks.json:pre_tool_use:0:0`: event preToolUse · Global (user) `<home>/Library/Application Support/RepoPrompt CE/Codex/Release/home/hooks.json` · matcher `Bash` · trust untrusted · hash `sha256:be6c6fcb2978ea348dd05101efed0afcf00efcbfb5d7e78949108142c875a77d`
```

Revised, 170 characters (−162):

```text
  - `<home>/Library/Application Support/RepoPrompt CE/Codex/Release/home/hooks.json:pre_tool_use:0:0`: event preToolUse · Global (user) · matcher `Bash` · trust untrusted
```

### Finding 2

`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:7107`, the `approve_selected` option description.

Before, at `main` `3dd846fcd`, 44 characters:

```text
Trust only the hook_keys answer and continue
```

Current, 104 characters:

```text
Trust only the hooks identified by answers.hook_keys and continue without trusting the other shown hooks
```

Revised, 61 characters (−43):

```text
Trust only the hooks listed in answers.hook_keys and continue
```

### Finding 3

`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:7114`, the `continue_without_hooks` option description.

Before, at `main` `3dd846fcd`, 68 characters:

```text
Continue this Codex session without enabling the shown project hooks
```

Current, 86 characters:

```text
Continue without completing hook trust; already trusted or managed hooks can still run
```

Revised, 83 characters (−3):

```text
Continue without trusting the shown hooks. Trusted and managed hooks can still run.
```

### Finding 4

`Sources/RepoPrompt/Features/AgentMode/Models/CodexHookApprovalModels.swift:32-34`, the two source labels, one per line. `main` showed the source path in their place.

Current, 31 characters:

```text
Global (user)
Project (project)
```

Revised, 21 characters (−10):

```text
Global (user)
Project
```

### Finding 5

`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:1189`, the notice after `continue_without_hooks`. When the count is unknown, `<n> Codex hook(s)` reads `an unknown number of Codex hooks`.

Before, at `main` `3dd846fcd`, 109 characters:

```text
Continued without trusting <n> Codex project hook(s). The hooks remain untrusted for this controller binding.
```

Current, 110 characters:

```text
Continued without trusting <n> Codex hook(s). This decision does not disable already trusted or managed hooks.
```

Revised, 86 characters (−24):

```text
Continued without trusting <n> Codex hook(s). Trusted and managed hooks can still run.
```

### Finding 6

`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:1335`, the notice after a trust decision.

Before, at `main` `3dd846fcd`, 84 characters:

```text
Trusted <n> Codex project hook(s); <m> remain untrusted for this controller binding.
```

Current, 77 characters:

```text
Trusted <n> Codex hook(s); <m> remain unresolved for this controller binding.
```

Revised, 49 characters (−28):

```text
Trusted <n> Codex hook(s) and left <m> untrusted.
```

## Applied

The user approved findings 1 to 6 on 2026-11-20, choosing for finding 1 to remove both the hash and the repeated path. The commit that adds this report applies them, with the two tests that pin the source label and each hook's entry.

## Not checked

- Usage: no skill in scope.
- Behaviour evidence: an audit scoped to one diff.
- The pull request's Markdown records and the person-only text listed under Scope.
