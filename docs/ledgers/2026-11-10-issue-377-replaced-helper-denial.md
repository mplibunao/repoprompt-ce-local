# Run ledger: replaced-helper denial message

Request: #377 · Plan: `port-1105-replaced-helper-denial-2026-11-10.md`

Port upstream PR 1105. A protected mutation from an MCP helper whose executable was replaced while it ran is denied, and today the message says only that the client principal isn't verified. After the port, the message gives the helper's PID and says to reconnect the MCP server. Check the change live on the integrated debug build.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Port the denial message, with tests | done | engineer · Orchestrate 1/1: port 1105 replaced-helper denial | `fix(mcp): name the replaced helper and reconnect remedy in denials` |
| 2. Live check on the integrated debug build | done | orchestrator | `docs(ledgers): record the live check of the replaced-helper denial` |

## Decisions made while planning

- Decision: port the new case and its `errorDescription` text, and leave out upstream's `CustomStringConvertible` restructuring. Upstream moved its messages into `description` because its tool-error path interpolates the error; this repository's `mcpErrorRenderingText` (`Sources/RepoPrompt/Infrastructure/MCP/CallToolResultConvenience.swift`) already reads `errorDescription`, so the restructuring wouldn't change any text a client sees. The long-running provider's activity status text comes from `String(describing:)` and so shows the case name, as for every other policy error. Source: approved plan.
- Decision: reset `errno` before `proc_pidpath`, a deviation from upstream. `proc_pidpath` can return 0 without the call setting `errno`, so a stale `ENOENT` could otherwise mislabel the peer. Source: approved plan, confirmed by the plan's design critique.
- Decision: this run doesn't fix the cause. Refusing the stale helper's handshake would stop its reads too. Having the helper re-execute itself would change its lifecycle and trust model. Verifying by code signature would change what grants bind to. The pull request references #377 and doesn't close it. Source: approved plan.
- Decision: `DirectHeadlessMCPService` is left as it is. It fingerprints the MCP client rather than a helper, so the generic denial is the right one there. Source: approved plan.

## 1. Port the denial message, with tests

- Decision: an `engineer` agent implemented the item, because the plan fixed the approach down to the lines to change. Source: orchestrator judgment.
- Decision: the new test checks that the message contains the helper's PID and "Reconnect the MCP server" rather than matching the whole sentence, as upstream's test does. No test covers a missing-executable failure without a PID: production can't build that principal, and `peerExecutableMissing(processID:)` takes a non-optional PID. Source: approved plan.
- Evidence: `make dev-test FILTER=RepoPromptDomainRuntimeTests.DomainProtectedMutationSecurityTests` passed, 12 tests. With the policy's new selection branch removed, `testAppProxyWhoseExecutableWasDeletedIsDeniedWithReconnectRemedy` failed with 3 assertion failures (it got `principalUnverified` and the generic text) and the other 11 passed. The branch was then restored.
- Evidence: `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-format` (no files rewritten), and `make dev-lint` passed. A correctness review and a separate refactor review of the diff found nothing to change.
- Evidence: the release (`#else`) branch of the peer-identity code was checked by reading. The daemon and CI compile only the DEBUG configuration, so that branch first compiles at the next promotion. It uses the same lines as the DEBUG branch.
- Deferred: a helper that started before a bundle replacement is still denied until its MCP server reconnects. #377 keeps that open.

## 2. Live check on the integrated debug build

- Decision: the check ran on a scratch copy of the debug build's `repoprompt-mcp`, and the copy was deleted while it ran. The plan called for this session's own helper, but the host starts a new Claude Code process each turn, so that helper had started after the rebuild and its executable still resolved. Deleting a running helper's file leaves the same condition that a bundle swap leaves. Source: orchestrator judgment.
- Decision: the scratch helper gave the app the client name `agent-local`, which is on the debug app's MCP client allow-list. A first run under a name missing from that list opened a client approval prompt in the debug app. The app denies such a prompt by itself after 300 seconds. Source: orchestrator judgment.
- Evidence: the integrated build at `dc9cfc1c6` merged this branch at `46633d0c4`. On one helper connection, PID 77450, with the executable present, `bind_context bind` to a scratch tab and `prompt set` succeeded. After the copy was deleted, `proc_pidpath` failed with `ENOENT`, and `bind_context status` and `prompt get` still succeeded. `prompt set` then returned `isError` with "Protected mutation denied because the RepoPrompt MCP helper (pid 77450) is running an executable that no longer exists on disk, usually because RepoPrompt CE was updated after the helper started. Reconnect the MCP server to start a current helper." A following `prompt get` showed the earlier text.
- Evidence: through a fresh `rpce-cli-debug` connection, `prompt set`, `get`, and `clear` on the same tab succeeded, and the tab was then closed. `make dev-smoke` passed on the integrated build.
- Evidence: after the deletion, a second `bind_context bind` to the same tab succeeded. The protected-mutation classifier lists `bind`. #377 also saw `bind`, `create_tab`, and `close_tab` succeed on a stale connection. This run didn't investigate why.
