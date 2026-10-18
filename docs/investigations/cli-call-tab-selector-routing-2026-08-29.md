# Investigation: CLI tab selector ignored by single-shot tool calls

> Investigation report, observed 2026-08-29 on the packaged stability debug build. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary

RepoPrompt CE CLI accepts tab selectors such as `--context-id` / `-t` for shell-style `-e` execution, but controlled live evidence shows the same selector is ignored by single-shot `-c <tool>` execution. An explicitly targeted inactive tab returned its own empty prompt and selection through `-e`; the equivalent `-c workspace_context` call returned the active tab's unrelated prompt and four-file selection instead.

The complete investigation confirmed a narrow mode-propagation defect rather than server-side routing: CLI parsing stores the tab selector on the exec-command options used by `-e`, while the single-shot call path cannot carry the selector into its request context. The server-side resolver honors valid explicit context identities and fails closed when they are unavailable. Pair investigation and independent Oracle synthesis both recommend filing a distinct focused issue.

## Scope distinctions

| Item | Boundary | Relationship |
| --- | --- | --- |
| `-e` command execution | Shell-style CLI commands with explicit tab routing | Control path; explicit targeting worked |
| `-c` single-shot calls | Direct MCP tool invocation from the CLI | Affected path; explicit targeting was ignored |
| Server context resolution | Resolves an explicit context identity when supplied | No misrouting defect demonstrated |
| Workspace/window routing | Selects the owner's existing multi-root workspace and window | Required setup, not the suspected defect |
| Upstream issue 887 / upstream PR 889 | Qualified file reads waiting on peer roots | Separate resolved path-selection defect |

## Controlled reproduction

The test used the owner's existing multi-root workspace and an inactive compose-tab context. No workspace or worktree was created.

1. `rpce-cli-debug -w 1 --context-id <inactive-context> -e 'workspace_context ...'` returned the targeted inactive tab's empty prompt and selection.
2. `rpce-cli-debug -w 1 --context-id <same-inactive-context> -c workspace_context ...` returned the active `CE fallback review` tab, including an unrelated prompt and four-file selection.

The result separates selector resolution from tool behavior: the same selector and target work through `-e`, while `-c` falls back to the active tab.

## Initial source and prior-art findings

- `-t` / `--context-id` populate the CLI exec-command option path.
- The `-c` single-shot path does not appear to consume those options.
- The server resolver uses explicit context identity when one reaches it and fails closed when that identity cannot be resolved.
- No exact matching GitHub issue or pull request was found in the initial reconnaissance or the current authenticated GitHub search.
- Upstream issue 169 is the closest semantic neighbor: it covers `context_id` being absent from published tool schemas and a server-side wrong-tab tripwire being swallowed. The CLI single-shot path is schema-independent, so upstream issue 169 does not demonstrate or fix propagation of the CLI's own `--context-id` / `-t` selector into `-c`.
- Upstream issue 168 covers concurrent run-scoped rebinding that stomps explicit connection bindings. The controlled CLI result reproduced without concurrent run traffic or binding drift.
- Upstream issue 456 and merged upstream PR 812 cover choosing a window where a context's workspace is inactive. The controlled CLI result used one existing workspace and showed a mode-dependent result for the same target.
- Broader related routing work includes upstream PRs 372 and 616 and upstream issues 862, 335, and 79, but none was shown to own single-shot selector propagation.

## Competing explanations

1. **Leading:** the CLI's single-shot call mode drops the parsed tab selector before request dispatch.
2. The server receives an explicit context identity but replaces it with active-tab routing.
3. The selector resolves correctly, but `workspace_context` independently reads active presentation state.
4. The result is stale app or connection state rather than deterministic mode behavior.

The existing A/B test weakens explanations 2–4 but does not eliminate them without request-level tracing or a focused test at the CLI/server boundary.

## Investigation workflow status

- Phase 0 initially failed because a released cancellation-ignoring structural provider fenced `get_file_tree` with `tool_execution_structure_settlement_busy`.
- After a clean relaunch of the exact packaged stability build, the owner's existing multi-root workspace was restored and root enumeration succeeded with the expected three roots.
- A dedicated compose tab was created inside the existing workspace for the remaining investigation. No new workspace or worktree was created.
- Context Builder completed with a 16-file selection covering CLI parsing, both client modes, server normalization, binding resolution, prompt-context consumption, and existing routing tests.
- The Pair investigator confirmed the root cause, eliminated the server and stale-state alternatives, and added exact source references and regression risks below.
- The same-selection Oracle synthesis independently returned `FILE NEW ISSUE` and converged on an exact-route-or-fail-before-dispatch safety contract.
- Filed as upstream issue 900 after MP approved the reviewed draft. Labels remain for maintainer triage.

## Required verification

1. Add a CLI-level A/B test proving `--context-id` reaches both `-e` and `-c` request construction.
2. Add a server-boundary test proving an explicit inactive context is preserved through single-shot dispatch.
3. Run a packaged live replay with two distinguishable tabs and compare prompt/selection fingerprints without publishing their contents.
4. Repeat after a clean app restart to rule out stale connection state.

## Filing threshold

File a new issue only if the complete investigation confirms the selector is accepted by CLI syntax but omitted or ignored specifically in `-c`, and current GitHub issues and pull requests do not already own that contract. The issue should describe the mode mismatch and user impact without claiming a general server-routing defect unless request-level evidence proves one.

## Investigator Findings

### Root-cause verdict

**Confirmed:** the CLI parser accepts `-t` / `--context-id`, but single-shot `-c` selects the interactive option path and those selectors are stored only in `ExecOptions`. The selector is absent before `InteractiveREPL` constructs the tool request. No evidence supports a later server-side overwrite or `workspace_context` reading the active presentation after a valid selector reaches dispatch.

The mode split is explicit:

- `-c` sets `isInteractive` and writes `interactiveOptions.callTool` (`Sources/RepoPromptMCP/main.swift:2655-2660`).
- `-e` sets `isExec` and appends to `execOptions.commands` (`Sources/RepoPromptMCP/main.swift:2697-2704`).
- If both mode families are present, exec wins and the interactive call is discarded (`Sources/RepoPromptMCP/main.swift:2890-2895`).
- `-w` is genuinely shared because it populates both `interactiveOptions.initialWindowID` and `execOptions.windowID` (`Sources/RepoPromptMCP/main.swift:2789-2795`). In contrast, `-t` writes only `execOptions.tabID`, and `--context-id` writes only `execOptions.contextID` (`Sources/RepoPromptMCP/main.swift:2797-2807`).
- `InteractiveOptions` has `initialWindowID` but no tab-name or canonical-context field (`Sources/RepoPromptMCP/Interactive/InteractiveREPL.swift:13-28`). The `-c` branch consequently applies only the window ID before dispatch (`Sources/RepoPromptMCP/Interactive/InteractiveREPL.swift:85-88`).
- The single-shot request parses only `-j` and forwards those arguments (`Sources/RepoPromptMCP/Interactive/InteractiveREPL.swift:770-778`). `InteractiveMCPClientSession` can inject a selected context, but only if `selectedContextID` was previously populated; it also correctly preserves an explicit `context_id` already supplied in `-j` (`Sources/RepoPromptMCP/Interactive/InteractiveMCPClientSession.swift:773-782`).

This explains the controlled A/B result without relying on timing: `-e` receives `ExecOptions.tabID/contextID`, while `-c` receives an `InteractiveOptions` value that cannot represent either selector.

### Why `-e` works

`ExecOptions` owns `windowID`, `tabID`, `contextID`, and `workingDirs` (`Sources/RepoPromptMCP/Exec/ExecOptions.swift:11-23`). Before running commands, exec mode locally seeds the window/canonical context and performs a `bind_context` startup operation. Its current priority is `contextID`, then `tabID`, then `workingDirs`, then `windowID` (`Sources/RepoPromptMCP/Exec/ExecMCPService.swift:75-114`). UUID-shaped `-t` values are treated as canonical context IDs; named tabs are resolved by exact name, case-insensitive name, then case-insensitive prefix, with unknown and ambiguous matches rejected (`Sources/RepoPromptMCP/Interactive/InteractiveMCPClientSession.swift:1226-1269`).

Current CLI precedence is therefore observable rather than validated as a conflict: `--context-id` silently wins over `-t`, later repeated scalar flags overwrite earlier values, and repeated `--working-dir` values append. A parity repair should either preserve this behavior deliberately or change both modes under a separately documented CLI-contract decision.

### Downstream alternatives eliminated

1. **Server normalization does not replace a valid explicit context with the active tab.** The normalizer extracts a valid top-level `context_id`, removes it from the tool payload, and returns it as routing metadata (`Sources/RepoPromptDomainRuntime/MCPToolArgsNormalizer.swift:207-230`). Dispatch passes that identity into `MCPBindingResolver.resolveLogicalContextBinding` (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:10997-11024`, `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:11048-11080`).
2. **Binding resolution is fail-closed for an explicit identity.** Explicit `context_id` has priority over legacy `_tabID`; no match, incompatible window, and ambiguous multi-window matches throw rather than select an active fallback (`Sources/RepoPrompt/Infrastructure/MCP/MCPBindingResolver.swift:70-115`, `Sources/RepoPrompt/Infrastructure/MCP/MCPBindingResolver.swift:162-206`). The resolved tab/workspace/window becomes a one-shot `TabContextHint` (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:11067-11080`) and is carried through the TaskLocal dispatch envelope (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:11213-11216`, `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:11349-11355`).
3. **A sticky binding cannot silently override a conflicting explicit hint.** `resolveTabContext` throws if an existing authoritative binding does not match the one-shot hint; with no binding, it constructs a snapshot from the hint and returns it as `.explicitHint` (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift:3057-3139`).
4. **`workspace_context` consumes the resolved snapshot.** The provider resolves request metadata to a `ResolvedTabContextSnapshot` and passes that snapshot into `buildTabWorkspaceContext` (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift:53-85`). The builder physicalizes `context.selection` and returns `context.promptText`; it does not substitute the presentation-active tab (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+WorkspaceContext.swift:5-23`, `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+WorkspaceContext.swift:179-198`).
5. **Stale app state is not needed to reproduce the defect.** The omission follows deterministically from the option type and request-construction branches. Restarting can change the connection's fallback tab but cannot add a selector field that `InteractiveOptions` does not contain.

The active-tab result from the reproduction is the connection's unselected/default route after the CLI drops the selector. It does not show that the server received and replaced an explicit context.

### Regression and safety risks

- **Wrong-context reads and mutations:** the defect affects every direct `-c` tool, not only `workspace_context`. A caller can believe it pinned an inactive tab while the tool operates through the connection's current/default context.
- **Generated handoff instructions are currently misleading:** the app emits `rpce-cli` / `rpce-cli-debug` commands using `-w … --context-id … -c agent_manage …` as the CLI equivalent for exact-session handoff (`Tests/RepoPromptTests/App/AgentChatTitlebarSafetyTests.swift:125-166`). That test validates the string, not its routing behavior.
- **Malformed selectors can fail open if exec behavior is copied mechanically:** `--context-id` is not parser-validated. The normalizer extracts only UUID-shaped strings; malformed values remain ordinary payload fields (`Sources/RepoPromptDomainRuntime/MCPToolArgsNormalizer.swift:207-218`). Exec mode seeds the raw value, catches startup-binding failure as a warning, and continues to the requested command (`Sources/RepoPromptMCP/Exec/ExecMCPService.swift:75-114`). A single-shot repair must not dispatch the target tool after an invalid, unknown, or ambiguous explicit selector.
- **Outer-selector versus JSON conflicts:** the session correctly avoids overwriting a `context_id` explicitly present in `-j` (`Sources/RepoPromptMCP/Interactive/InteractiveMCPClientSession.swift:780-782`). If startup binding is added to `-c`, a conflicting JSON context must reach the existing mismatch guard and fail rather than silently choosing either tab.
- **Window/tab consistency:** `-w` plus a canonical context must retain the server's active-workspace/window validation. Current binding resolves only contexts in each window's active workspace and rejects an incompatible requested window (`Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift:1649-1691`; `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:4988-5014`).

### Exact regression coverage

The existing `InteractiveREPLSingleShotRoutingTests` prove `_windowID` injection and preservation of a `context_id` supplied inside `-j`, but they never represent an outer `-t` or `--context-id` selector (`Tests/RepoPromptTests/MCP/Control/InteractiveREPLSingleShotRoutingTests.swift:6-46`). The smallest useful coverage is:

1. **Parser/options tests:** `--context-id <uuid> -c workspace_context` and `-t <name> -c workspace_context` must produce a single-shot option value carrying the selector; `-w` must remain orthogonal. Include ordering cases before and after `-c`.
2. **Canonical UUID request test:** with a mock `bind_context`, assert the selected UUID is bound/installed and the subsequent target call carries the same canonical `context_id`; assert the target call is not sent if binding fails.
3. **Named-tab request test:** return two distinguishable tabs from `bind_context op=list`. Verify exact-name resolution and the final target context. Then verify unique case-insensitive/prefix resolution. Unknown and ambiguous names must produce zero target-tool calls.
4. **Precedence/conflict tests:** cover `--context-id` plus `-t` and repeated scalar selectors. Test matching and conflicting outer versus `-j context_id` values separately. Preserve current `--context-id`-over-`-t` behavior only if it is the intentional shared CLI contract; the outer/JSON mismatch must fail closed.
5. **Invalid-selector tests:** malformed UUID, unknown UUID, empty/missing selector value, context/window mismatch, and named-tab ambiguity must exit non-zero before `workspace_context` or any mutating target is dispatched.
6. **Live two-tab replay:** give the active and inactive tabs distinct prompt/selection fingerprints. Compare `-e` and `-c` for UUID and named-tab selectors. Repeat after restart, comparing fingerprints rather than prompt contents.

### GitHub scope and deduplication

This defect is distinct from the named prior art:

- Upstream issue 169 concerns schema-strict MCP clients dropping a per-call `context_id` that is absent from published tool schemas, plus an older swallowed mismatch error. Direct CLI `-c -j` construction is schema-independent; the defect here occurs earlier because the CLI's outer selector never enters `InteractiveOptions` or the request. Current dispatch still extracts a valid context and routes it through `MCPBindingResolver`.
- Upstream issue 168 requires concurrent run-policy traffic that overwrites a connection's explicit binding. The controlled reproduction requires neither concurrency nor run-scoped rebinding and is explained before any server binding mutation.
- Upstream issue 456 concerns a successful `bind_context context_id` pairing with a window where the context's workspace was inactive. Here, `-c` never attempts the bind at all, and the reproduction used the same active workspace with a different compose tab.
- Upstream PR 812 fixed upstream issue 456's candidate eligibility by restricting external `context_id` binds to each window's active workspace while preserving stored/inactive lookup for internal routing. The current split is visible in `bindingCandidate` versus `storedBindingCandidate` (`Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:4988-5014`); it does not add selector fields or startup binding to `InteractiveOptions`.

Authenticated GitHub searches for `"--context-id" "-c"`, `"single-shot" context_id`, `"--tab" CLI`, and matching pull requests returned no exact owner on 2026-08-29.

### Filing recommendation

**File a new focused issue.** The user-facing invariant is: an explicit CLI tab selector must route the requested single-shot tool to that tab or fail before the tool runs. Scope the issue to CLI mode/options propagation and single-shot startup routing, with the invalid/conflicting-selector cases as safety acceptance criteria. Do not characterize it as a general MCP server-routing or `workspace_context` defect.

### Maintainer-guidance check

- **User impact and invariant:** explicit `-c` routing can read or mutate the wrong tab; explicit selectors must route exactly or fail closed.
- **Root-cause confidence:** confirmed by deterministic value-flow evidence.
- **Authority:** CLI argument parsing and the single-shot `InteractiveOptions`/`InteractiveREPL` request path.
- **State-safety risks:** wrong-context selection, prompt, file, Git, worktree, or mutation operations; invalid-selector fallback.
- **Scale and observability risks:** no scale mechanism is implicated; the current lack of a bind/selector error makes misrouting opaque.
- **Recommended scope:** new issue, then a small CLI fix with focused parser/request tests and live two-tab validation.
- **Validation boundary:** CLI option construction, in-memory MCP request capture, server mismatch/fail-closed behavior, and packaged CE CLI replay.

## Proposed GitHub issue

Filed as upstream issue 900, "CLI -c silently ignores -t/--context-id and can dispatch tools to the active tab" (labels `bug`, `area:mcp`), after MP approved the reviewed draft. Its body restates the reproduction, root cause, acceptance criteria, and related work above, so the draft is not repeated here.
