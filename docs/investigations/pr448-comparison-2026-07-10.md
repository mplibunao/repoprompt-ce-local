# Comparison of upstream PR 448 and the local fix for upstream issue 444

> Investigation report, observed 2026-07-10 on upstream PR 448 at `a3ab68ee` and a local fix branch. It records what was true then. Where it disagrees with a current document, the current document is right.

**Compared:** Upstream PR 448 at a3ab68eec51652e8d9b710a8981ac55156df0841. The other sources are upstream issue 444 and the local fix branch's commits since upstream/main.

Line references below use the upstream PR 448 head.

## Gap analysis

| Mechanism | Upstream PR 448 | Local fix | Assessment |
| --- | --- | --- | --- |
| Detach eligibility | MCPConnectionManager.swift:6002 detaches any `.discoverRun` close regardless of cause or initiator. The renamed detach helper retains the bidirectional-routing, live-context, matching-run, and no-prior-detach guards at MCPServerViewModel+TabContext.swift:4021-4026. | Uses the same discover-run-only eligibility and downstream guards. | **Equivalent at the ownership-transfer gate.** Garbage entries remain excluded. |
| Completed discovery after a non-orderly close | The close is published as `.detachedWithoutOrderlyPeerEOF` at MCPConnectionManager.swift:5913-5925, but the production drain resolver accepts only `.peerEOFDetached` at ContextBuilderRunLifecycle.swift:57-63. The finalization path stops before commit. | A valid detached discover-run context remains an acceptable finalization handoff; stale/current checks still decide whether it may commit. | **Functional gap in upstream PR 448.** It preserves the context in storage but still fails publication/export after a completed discovery closes non-orderly. |
| Supersession that reaches finalize | The stale `finalizeContextBuilderRun` branch calls retirement at ContextBuilderAgentViewModel.swift:1955-1962; retirement schedules provider cleanup at :2053-2078. | Same retirement result through a smaller shared resource funnel. | **Covered by both.** |
| Silent supersession that never reaches finalize | `cancelRun` still returns immediately when ownership has flipped at ContextBuilderAgentViewModel.swift:2612. The only production caller of the new retirement helper is the finalize early-return; the other caller is a DEBUG test hook. | The `cancelRun` early-return routes through retirement, so tab close or MCP cancellation disposes a parked/silent run even if its stream never finishes. | **Missing in upstream PR 448.** Provider cleanup and waiter resolution can remain pending indefinitely while the superseded stream stays silent. |
| Provider and config-lease disposal | Once retirement is reached, `scheduleRunTeardown` calls `provider.dispose()`. Upstream PR 448 doesn't change `ClaudeCodeAgentProvider`: its existing `dispose()` cancels the stream and runner, while lease deletion remains in asynchronous stream cleanup. The new test uses a fake provider. | `ClaudeCodeAgentProvider.dispose()` explicitly and releases through an idempotent operation the active `MCPConfigLease`; `prepare()` also releases a new lease if later preparation fails. | **Partial in upstream PR 448.** Provider disposal is requested on reached retirement paths, but immediate real `discovery-*.json` deletion is neither owned explicitly nor tested. Silent supersession misses both. |
| MCP caller/waiter | Retirement resumes the continuation according to `waiterResolution` at ContextBuilderAgentViewModel.swift:2068-2085. | Retirement takes and resumes the waiter once, including the silent cancel/tab-close path. | **Covered when upstream PR 448 retirement runs; missing for the silent path that never reaches it.** |
| `missingFinalContext` connection ID | The production constructor remains `connectionID: nil` at ContextBuilderAgentViewModel.swift:2797. | Captures the live discovery connection ID after routing and threads it into the failure. | **Missing in upstream PR 448.** |
| Additional lifecycle hygiene | Cancels pending preview publication, calls `endRunAttempt(ifCurrent:)`, conditionally clears the active-tab marker, and preserves snapshot-versus-cancellation waiter semantics at ContextBuilderAgentViewModel.swift:2059-2085. It also generalizes the detach-helper name and records the actual close classification. | Omits some stale-retirement hygiene and the generalized naming/classification. | **Useful upstream PR 448 work to retain.** The close classification is valuable for diagnostics, but it shouldn't be an unconditional failure gate after discovery completed successfully. |

## Regression coverage comparison

| Red-to-green scenario | Upstream PR 448 coverage | Gap |
| --- | --- | --- |
| Non-orderly close-cause table | Directly detaches and invokes the lower-level commit API for server shutdown, run cancellation, read error, write hangup, and write stall at ContextBuilderRunLifecycleTests.swift:784-827,876-909. Separately, the production-like finalization test explicitly expects read error to fail before commit at :592-690. | The direct-commit table bypasses the resolver used by `commitTabContextForAgent`; it proves recovery, not successful production publication. It also doesn't exercise the broader cause/initiator matrix or a completion-aware distinction. |
| Silent supersession | `testStaleRunRetirementStillDisposesProviderAndCancelsExecution` directly invokes the DEBUG-only retirement hook at ContextBuilderRunLifecycleTests.swift:1014-1085. | No ownership flip, parked stream, production cancellation/tab-close, or “finalize never runs” path. |
| Waiter resume | The retirement helper contains continuation logic, but the new stale-retirement test constructs no continuation. | No assertion that the superseded MCP caller finishes, especially for a silent run. |
| Lease release | The fake provider asserts one `dispose()` call at ContextBuilderRunLifecycleTests.swift:1044-1050,1072-1078. | No real lease and no bounded assertion that a `discovery-*.json` file is removed. The local fix makes release deterministic, although its `XCTest` also uses a fake provider; real file deletion remains a live-smoke boundary. |
| Diagnostic connection ID | Existing result-rendering coverage can format an explicitly supplied ID, but production still supplies nil. | No red-to-green test for capture/threading of the last-known discovery connection ID. |

## Review comment

The review comment drafted here was posted on upstream PR 448 on 2026-07-10 with the drafted body. It credited the widened discover-run detach gate, stale retirement, and the close-cause diagnostics, and named three gaps: production finalization still rejects a completed discovery after a non-orderly close, a silent superseded run has no production retirement trigger, and lease cleanup and the `missingFinalContext` connection ID lack coverage. It proposed a regression scenario for each.
