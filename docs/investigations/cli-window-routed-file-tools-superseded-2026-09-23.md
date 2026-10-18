# Window-routed single-shot file tools fail with `workspace_authority_superseded`

> Investigation report, observed 2026-09-23 on production build 42 (`main` at `0c6bb1d3`). It records what was true then. Where it disagrees with a current document, the current document is right.

Date: 2026-09-23
Scope: read-only investigation on `main` (production build 42, `0c6bb1d3`) and the current debug build.
Line references are to `0c6bb1d3`.

## Conclusion

A file-tool call fails every time if it reaches the server with a one-time tab hint on a connection that has no tab binding. That covers a hidden `_windowID` argument, and also a per-call `context_id` argument sent without an earlier `bind_context`. The rejecting check is the connection-scoped currentness predicate `fileToolLookupSnapshotIsCurrent` (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift:2868-2887`). When the request has a `connectionID`, the predicate requires `tabContextByConnectionID[connectionID]` to exist and to match the routed snapshot:

```swift
guard let connectionID else { return true }
guard let current = tabContextByConnectionID[connectionID],
      fileToolLookupSnapshotMatches(current, snapshot)
else { return false }
```

A one-time hint route never creates that entry, which makes the predicate false on every call, and `requiredFileToolLookupContext` reports it as `FileToolAuthorityFailure.superseded`:

- `MCPServerViewModel+TabContext.swift:2261-2266`: the guard after `awaitWorkspaceRootCatalogSnapshot`. This is the throw site whenever the tab's agent-session worktree binding needs no hydration, including tabs with no active agent session. The call fails in about 240 ms, well before any readiness timeout.
- `MCPServerViewModel+TabContext.swift:2229-2233`: the same predicate, reached through `hydrateFileToolLookupSnapshotIfNeeded` (`:2766-2770`). This is the throw site when the tab has an active agent session with an unhydrated worktree binding.

Nothing about the workspace changed. The code is labeling "this connection has no binding" as "the binding was superseded". The message ("Workspace authority changed while the file request was resolving") and the retry hint both mislead the caller, and retrying can't succeed.

## Causal chain for `rpce-cli-debug -w 1 -c read_file …`

1. **CLI, `-c` single-shot mode: nothing is bound.** `InteractiveREPL.run` (`Sources/RepoPromptMCP/Interactive/InteractiveREPL.swift:87-94`) calls `setSelectedWindowID(initialWindowID)`, then `establishStartupRouting(contextID:tabID:windowID:)`. That function (`InteractiveMCPClientSession.swift:1717-1748`) sends `bind_context` only for `--context-id` or `-t`. With `-w` alone it binds nothing. After that, every call only carries a hidden `_windowID` (`InteractiveMCPClientSession.swift:957-958`).
   - `-e` works differently. `ExecMCPService.runConnectedSession` (`Sources/RepoPromptMCP/Exec/ExecMCPService.swift:104-105`) calls `selectWindow`, which sends a real `bind_context op=bind window_id=N`. That is why `-w 1 -e 'tree --type roots'` works.
   - Confirmed live: `rpce-cli-debug -w 1 -c bind_context -j '{"op":"status"}'` returns `Binding: Unbound`.
2. **Server dispatch: `_windowID` becomes a one-time tab hint.** `MCPConnectionManager.swift:11466-11492`: with no `context_id` or `tab`, `bindingResolver.resolvePresentationWindowBinding(connectionID:requestedWindowID:)` picks the window's current tab. The result becomes `dispatchTabContextHint` (task-local `currentTabContextHint`, `:11873`). A per-call `context_id` goes through `resolveLogicalContextBinding` and ends in the same kind of hint.
3. **Tab-context resolution: explicit one-time hint.** `resolveTabContext` (`MCPServerViewModel+TabContext.swift:3365-3464`) finds no `tabContextByConnectionID` entry, so it skips step 1 (bound context). It takes step 3, "explicit one-shot hint" (`:3452-3464`). That produces a snapshot with `explicitlyBound: false`, source `.explicitHint`, and no `frozenFileToolAuthority`. Nothing records it in `tabContextByConnectionID`, and step 3 doesn't start mirroring.
4. **Domain read requires a frozen file authority.** `resolveDomainReadContext` (`MCPServerViewModel+DomainRouting.swift:298-303`) calls `targetServer.requiredFileToolLookupContext(from: metadata)` for every file-group tool (`requiresFrozenFileAuthority`, `:15-18`: `read_file`, `file_search`, `get_code_structure`, `get_file_tree`). The metadata carries the real `connectionID`.
5. **Currentness check rejects the call.** The snapshot has no frozen authority, so `requiredFileToolLookupContext` takes the slow path. `fileToolLookupSnapshotIsCurrent(authoritySnapshot, connectionID: metadata.connectionID)` finds no `tabContextByConnectionID[connectionID]` and returns false, which becomes `superseded` at `:2266`, or at `:2233` for a tab with an unhydrated agent-session worktree binding.
6. **Converted to a retryable tool result.** The domain-read provider's `resolveFailure` (`MCPServerViewModel.swift:2017-2025`) turns this into the `workspace_authority_superseded` reply through `MCPFileToolProvider.authorityFailureValue`.

### Why `--context-id` and long-lived `bind_context` clients work

`establishStartupRouting` sends `bind_context op=bind context_id=…`. On the server, `bindTarget` (`WindowRoutingService.swift:1893-1945`) builds the authority up front. It calls `performIfFileToolAuthorityIsCurrent`, and `bindTabForConnection(… frozenFileToolAuthority:)` installs a `tabContextByConnectionID` entry with `explicitlyBound: true` and a frozen authority. Later file calls hit step 1 of `resolveTabContext`, then the frozen-authority fast path (`:2187-2226`), which never runs the failing predicate. The bind-time prevalidation (`resolveFileToolAuthority`, `:2085-2099`) passes `connectionID: nil`, so the connection check is skipped by design there. That asymmetry is the defect: a hint route with a live connection gets a check meant for bound connections.

## Who is affected

Any MCP connection that routes a file-tool call with a one-time hint and has no tab binding is affected, not only the CLI. Examples: a hidden `_windowID` from any client, or a per-call `context_id` argument without a prior `bind_context`. Live reproductions on the debug app:

| Call (no prior bind) | Result |
| --- | --- |
| `-w 1 -c read_file` | `workspace_authority_superseded` |
| `-w 1 -c file_search` | `workspace_authority_superseded` |
| `-c read_file` with `"context_id":"<tab uuid>"` in the arguments | `workspace_authority_superseded` |
| `-w 1 -c get_file_tree` (roots or files) | reports success with **0 roots** and `Config: Workspace authority unavailable`, which silently degrades instead of showing the error |
| `-c bind_context op=bind window_id=1` on its own | binds fine (`explicit`) |

Clients that call `bind_context` once and then reuse the connection are unaffected: the RepoPrompt MCP server connection used by Claude Code, `-e` exec mode, and `--context-id`/`-t` single-shot calls. Agent Mode runs are also unaffected: they use run-scoped bindings (`runInstall`/`runHandover`) that live in `tabContextByConnectionID`.

## When it was introduced

The regression is from `38f32b0e` "fix(mcp): preserve file authority across binding" (MP, 2026-09-07). That commit added `requiredFileToolLookupContext` and the `prevalidatedFileAuthority` requirement in `resolveDomainReadContext`. It also changed `MCPFileToolProvider.readAuthority` from the lenient `resolveFileToolLookupContext` to the throwing path. Before it, domain reads used `targetServer.lookupContext(for: context)` with no connection currentness check, so hint routes worked. The predicate itself (`8e2de9c7`, 2026-06-19) and the `_windowID`-to-hint pre-resolution (`b267d745`, 2026-07-28) came earlier. They only became fatal when `38f32b0e` made file reads depend on them.

- Every promoted build from `local/v1.4.0-b37` through `b42` contains `38f32b0e`. No earlier `local/` tag exists to compare against.
- Upstream (`repoprompt-ce-upstream-readonly`) has none of this code (`requiredFileToolLookupContext` and `prevalidatedFileAuthority` are absent), so this regression exists only in the distribution.
- Test gap: `Tests/RepoPromptTests/MCP/Control/BindContextFileAuthorityTests.swift` always binds before reading. No test sends a file-tool call with a one-time hint on a real `connectionID`.

## Smallest correct fix direction

Apply connection-scoped currentness only to routes that come from a connection binding. In `requiredFileToolLookupContext`, look at `routed.source`. For `.explicitHint`, and for any source that isn't a stored connection binding, run the currentness checks the way bind-time prevalidation already does. Keep the live-tab and agent-session checks and the root-catalog ticket checks, but pass `connectionID: nil` so the missing `tabContextByConnectionID` entry doesn't count as supersession. This applies to the `hydrateFileToolLookupSnapshotIfNeeded` call, the guard at `:2261`, the post-capture guard at `:2285-2292`, and the `.unavailable`→`.superseded` remap at `:2301-2309`. The same rule has to hold in `resolveFileToolLookupContext(from:rootCatalogSnapshot:capturedRoute:)`, which already falls back to the non-cached authoritative path when no bound snapshot exists.

Also fix the next gate before calling the fix done. `read_file` then goes to `enqueueReadFileAutoSelection` (`MCPServerViewModel.swift:4704-4719`). Its context key is always `.bound(connectionID:…)`, and `isReadFileAutoSelectionContextCurrent` (`:5009-5018`) also requires a `tabContextByConnectionID` entry. So after the authority fix, a hint-routed `read_file` will probably fail at `:4718` with the same `superseded` code. `file_search` enqueues on the same key but returns `false` instead of throwing, and `get_code_structure` has no auto-selection. The fix needs a decision: either hint routes skip read-file auto-selection, or they get a per-call key that is not treated as stale.

Do not fix this by making the CLI's `-c` mode bind the window like `-e` does. That makes `rpce-cli -w` work, but other clients using `_windowID` or a per-call `context_id` would still hit the server defect.

Regression coverage worth adding: a server-level test that runs `read_file`, `file_search`, and `get_file_tree` with a `tabContextHint` and a non-nil `connectionID` and no binding. It should also cover a tab with an active agent session to exercise the `:2233` path. Then run `rpce-cli-debug -w 1 -c read_file` live on the debug app.

## Resolution

Fixed on branch `bugfix/cli-window-routed-file-tools`, not yet merged.

- **Only run-free hints are exempt.** A hint route counts as run-free when its source is `.explicitHint` and its snapshot has no `runID`. Those routes get their currentness checked without a `connectionID` (`ResolvedTabContextSnapshot.isRunFreeHint` / `bindingCurrencyConnectionID`). Do not widen the exemption to other unbound sources.
- **Run-carrying hints still fail closed.** These are hints on a connection that has a `connectionIDToRunID` mapping but no binding. The live-tab clause of `fileToolLookupSnapshotIsCurrent` skips run snapshots, so exempting them would leave no tab currency check at all.
- **Run-free hints skip read-file auto-selection.** Unbound one-time reads have never added to the tab selection in CE: since `ce84f763`, the enqueue currency gate required a stored binding and dropped refused batches silently. Bound reads keep auto-selection.

Known limitations that remain after the fix:
- A run-carrying hint on an unbound connection still gets the retryable `workspace_authority_superseded` error, and retrying can't succeed.
- A `bind_context` on the same connection that lands between authority capture and the auto-selection resolve turns the read into an `invalidParams` routing error.
- A hint read rebinds the domain coordinator's non-run binding for that connection, so a concurrent bound read can fail its re-check once.
- `get_file_tree` reports success with 0 roots when authority genuinely fails.
- A bound route without a frozen authority, on a tab whose agent-session worktree binding is unhydrated, fails its first call.
