# GitHub drafts from the #176 investigation (not filed)

> Investigation report, observed 2026-10-15 on local build 53 (`local/v1.4.0-b53`). It records what was true then. Where it disagrees with a current document, the current document is right.

Three drafts for `mplibunao/repoprompt-ce-local`. Nothing here is posted. `#A` and `#B` are placeholders for the new issues' numbers, filled in after they exist.

**Remaining, to do in one pass:**
1. Re-run the duplicate search in the distribution's tracker and the upstream triage, since these drafts were checked on 2026-10-15.
2. File issue A and issue B, then put their numbers in place of `#A` and `#B` in the #176 comment.
3. Post the #176 comment, and in the same pass edit #176: retitle it to name upstream PRs 1069, 1049, and 1081, add 1069 to its "Upstream" list, and add the done-when line about background tabs of the active workspace.
4. Decide whether the shared-connection behavior (sessions on one RepoPrompt MCP process share one tab binding) gets its own docs issue, or stays in the #176 comment only.

---

## 1. Comment on #176

The cancellation has a cause that upstream already fixed, in upstream PR 1069 (commit c88a623d), so this port should include it with 1049 and 1081.

**What happens.** When `read_file` or an eligible `file_search` auto-selects into a tab the window isn't showing, the selection mirror ends `.invalidated` straight away (`applyStoredSelectionMirrorForReadFileAutoSelection` in `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift`). The read-file auto-selection coordinator records that outcome. Every later drain on the same connection that needs the mirrored selection replays that outcome without waiting. So the failures come back in under a second instead of after the 10-second mirror wait, and they repeat with no new reads. Drains that only need the canonical selection pass, so `manage_selection op=get` kept working.

**Reproduced on build 53** (`local/v1.4.0-b53`). After a read through a connection bound to a background tab, `manage_selection` add and remove returned `Tool execution was cancelled.` every time while `op=get` succeeded. Binding a different tab and then back cleared it. Binding the same tab again, which reports `Changed: no`, didn't. The build 50 session from this issue's body shows the same pattern: `context_builder`, `workspace_context` twice, and `manage_selection remove` were all cancelled over 80 seconds, while `op=get` and `prompt get` worked.

**Why it's common.** A host that runs one RepoPrompt MCP proxy for several sessions gives them one tab binding, because the app keys bindings per connection. Claude Code Desktop does this. One session's `bind_context` moves the others, and their reads then auto-select into tabs nobody is viewing.

**The fix.** Upstream PR 1069 makes a background tab's mirror update its presentation and finish converged. `main` matches its pre-image, and the types it uses are already on `main`. With it in place, 1049 and 1081 report what's left, such as a mirror displaced by a newer request, as typed errors.

Scope for this issue is now upstream PRs 1069, 1049, and 1081 on one port branch.

The empty Context Builder selections from the earlier comments turned out to be separate defects, filed as #A (Context Builder treats a failed discovery as success) and #B (a timed-out read blocks every read in the window).

---

## 2. New issue A

**Title:** Context Builder returns a normal answer when discovery failed or couldn't read files

**Labels:** `bug`, `area:context-builder`, `provider:claude`

### What happens

Context Builder reports "run complete" and sends the plan or question follow-up even when its discovery agent failed. The caller gets a normal-looking answer built from whatever was selected before the run, sometimes nothing.

### Where I saw it

Build 53 (`local/v1.4.0-b53`), macOS 26.6.2, arm64, 2026-10-15:

1. **Discovery failed authentication.** With the `claudeCodeGLM` provider, every discovery request got `401 token expired or incorrect`. Discovery made no tool calls and ended with Claude Code's synthetic "Failed to authenticate" message. Each of three runs still returned a generated answer. One answer was built from the single file that was selected before the run started.
2. **Discovery couldn't read files.** A Codex discovery run hit a 30-second `read_file` timeout. After that, every read, `get_file_tree`, and `prompt set` it made returned `tool_execution_structure_settlement_busy` (#B). It selected two files. Its handoff prompt, which said the handoff was incomplete, was itself rejected, and the run still completed normally.

On build 51 (2026-10-14), three plan calls returned answers from an empty selection (`Total tokens: 0` with no files listed). I haven't confirmed the cause for those, but busy errors were reported in that window at the time.

### Why

- `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCodeAgentProvider.swift`: the `result` case never reads `is_error`, `subtype`, or `errors`, and nothing reads `isApiErrorMessage`. After `message_stop`, the stream loop stops before the exit status arrives and finishes as success. `parseStreamEvents` is called under `try?`, so an error thrown while parsing wouldn't surface either.
- `Sources/RepoPrompt/Features/ContextBuilder/ViewModels/ContextBuilderAgentViewModel.swift`: a provider stream that ends without throwing counts as `.completed`, and the run commits its tab context without comparing it with the starting state.
- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPContextBuilderToolProvider.swift`: `responseDisposition` sends the follow-up for any completed run. Only review mode checks for an empty selection (`ContextBuilderReviewTarget.swift`).

Agent Mode's Claude controller already fails a turn on `is_error`, an error subtype, or result errors (`ClaudeNativeProcessSessionController.swift`).

### Upstream

Not reported upstream; unchanged on upstream main at 116f9214.

### Done when

- A discovery run whose provider reports an error result or an API-error message ends as failed, and `context_builder` returns a failed status with the provider's message instead of a generated answer.
- A plan or question follow-up isn't sent when discovery leaves no files selected, and the caller is told why.
- A transient retry event on its own doesn't fail the run.
- Focused tests cover the provider's stream classification and the empty-selection check.

Open question: should a discovery run whose reads all failed count as failed even when the provider ends cleanly? The busy-window case only surfaces if it does.

---

## 3. New issue B

**Title:** A timed-out `read_file` leaves a stuck structure provider that blocks every read in the window

**Labels:** `bug`, `area:mcp`

### What happens

After one `read_file` exceeds the 30-second tool timeout, every later `read_file`, `get_file_tree`, `get_code_structure`, and `prompt set` in that window returns `tool_execution_structure_settlement_busy`: "Window N reached its limit of one released cancellation-ignoring structure provider. Wait for it to settle or restart RepoPrompt CE." It affects every connection to the window, including fresh `rpce-cli` processes, and it didn't clear on its own while I watched.

### Where I saw it

Build 53 (`local/v1.4.0-b53`), macOS 26.6.2, arm64, 2026-10-15 around 10:00 UTC. The workspace had five roots, about 1,170 tabs, and several agent sessions running. A Context Builder discovery run's `read_file` of the repository's `CLAUDE.md` timed out after 35 seconds, twice. Busy errors started nine seconds after the first timeout. A one-line read from a fresh CLI connection still failed at 10:06, and reads were still failing shortly before the app was restarted at 10:19. The restart cleared it.

Earlier sightings: build 51 on 2026-10-14 (comments on #176). Discovery runs on 2026-10-13 and 2026-10-14 also logged busy errors and `read_file` timeouts.

### What I know

- The cap is `releasedProviderLimit = 1`, with a 30-second recovery horizon, in `Sources/RepoPromptDomainRuntime/MCPDomainCodeStructureSettlementRegistry.swift`. The error is raised in `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift`. A provider that outlives watchdog cancellation keeps its lease until it actually finishes, so one stuck read blocks the whole window.
- I haven't established why a read of a small file stalled past 30 seconds. Upstream PR 1003 (commit c9778b03, from upstream issue 1002) fixes a lock re-entry deadlock in seeded worktree publication that can strand a provider like this, and it isn't in the distribution.
- Related: #8 (closed), where `apply_edits` stayed pending after a structure-settlement rejection, and #182.

### Upstream

Upstream PR 1003 is merged upstream. Upstream main at 116f9214 still has `releasedProviderLimit = 1`, and its registry differs from ours only by an added observer. The stalled-read symptom isn't otherwise reported upstream.

### Done when

- The cause of the stalled read is identified and reproduced.
- After a single read times out, the window recovers without restarting the app.
- We've decided whether upstream PR 1003 belongs in the fix.
