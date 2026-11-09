# Run ledger: replaced-helper denial message

Request: #377 · Plan: `port-1105-replaced-helper-denial-2026-11-10.md`

Port upstream PR 1105. A protected mutation from an MCP helper whose executable was replaced while it ran is denied, and today the message says only that the client principal isn't verified. After the port, the message gives the helper's PID and says to reconnect the MCP server. Check the change live on the integrated debug build.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Port the denial message, with tests | done | engineer · Orchestrate 1/1: port 1105 replaced-helper denial | `fix(mcp): name the replaced helper and reconnect remedy in denials` |
| 2. Live check on the integrated debug build | pending | | |

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
