# Session-bound `read_file` timeout and settlement investigation

> Investigation report, observed 2026-08-29, with an addition from 2026-09-01, on the packaged debug app built from a local stability branch. It records what was true then. Where it disagrees with a current document, the current document is right.

Status: Packaged-runtime defect accepted; initiating phase and tracker lineage unresolved

## Summary

RepoPrompt CE repeatedly exceeded the 30-second `read_file` execution contract for a
12.6 KB source file when the request ran through an existing session-bound worktree.
The same packaged app completed small main-checkout reads in 2.4 to 2.6 seconds, and the
operating system read the worktree file in 0.00 seconds. The controlled evidence accepts
a current route-specific product defect while leaving its inner stage and issue lineage
unresolved.

The initiating stall is currently localized only to `read_file.content_read`. That
envelope includes selected Git-artifact authorization, explicit freshness, exact
resolution and worktree projection, interactive content loading, and reply construction.
No captured event set separates those stages for the failing invocation.

The later `tool_execution_structure_settlement_busy` response is a downstream result of
providers that did not settle during cancellation grace. The released-provider limit and
window fence match the current settlement-registry design and tests.

## Runtime and controlled state

- Packaged debug app source: a local stability branch.
- The package includes follow-up commit `863ea876` from the qualified-read work.
- The app was relaunched from the existing package without rebuilding before the
  post-recovery controls.
- One RepoPrompt CE process was running after recovery.
- The failing target was
  `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionLifecycleAuthority.swift`.
- Target size: 12,631 bytes.
- Existing worktree: `bugfix/882-same-workspace-admission` at `f5787166`, registered with
  RepoPrompt.
- This investigation left the worktree's contents unchanged.

## Failure chronology

The chronology comes from the preserved Codex session log for 2026-08-27. All timestamps below are UTC.

1. `12:26:55.577`: the client explicitly bound context
   `<redacted>`.
2. `12:26:58.652`: roots succeeded.
3. `12:27:08.867` to `12:27:29`: worktree and Git checks verified the registered worktree,
   branch, and five-path diff.
4. `12:27:22.971`: `read_file` began for the target, lines 1 to 30.
5. `12:28:00.219`: the call returned `tool_execution_timeout`; cancellation did not
   settle during the five-second grace period, so the provider detached.
6. Non-structure control operations continued to succeed.
7. `12:28:47.307`: an immediate lines 1 to 24 retry was rejected before provider execution
   with `tool_execution_structure_settlement_busy` and the released-provider-limit
   message.
8. After more than eight minutes without structure work, roots succeeded again.
9. `12:37:06.837`: the single authorized quiescent retry began for lines 1 to 24.
10. `12:37:42.294`: it returned the same timeout and detach result.

One persisted watchdog record from the same failure window reports:

- connection `<redacted>`;
- invocation `<redacted>`;
- elapsed `35430.09575` ms;
- deadline `30000` ms and cleanup grace `5000` ms;
- phase `read_file.content_read`, age `35390.57779` ms;
- a failure fingerprint.

The transcript does not expose an invocation ID, and the persisted terminal event is
written on a force-disconnect path rather than the ordinary detach result. The event is
same-window failure-family evidence, not a proven one-to-one match for either transcript
call.

## 2026-09-01 concurrent-read evidence

A later planning run supplied a second controlled chronology. Three narrow Explore
agents in one window read the same investigation file from a clean RepoPrompt-managed
worktree at exact upstream commit `5bc82b7f`. Times below are UTC.

| Agent read | Start | Observed outcome |
| --- | --- | --- |
| First | `09:29:31.025` | `tool_execution_timeout` at `09:30:06.322`; the provider detached after 30 seconds plus the five-second grace |
| Second | `09:29:43.356` | MCP connection failure at `09:30:19.438`, approximately 36.082 seconds later |
| Third | `09:29:48.249` | MCP connection failure at `09:30:24.331`, approximately 36.082 seconds later |

The first agent received a settlement-busy response by `09:30:09`. All three Explore
agents later completed normally, but their structure-provider leases didn't reconcile.
Fresh MCP connections still received `released_provider_limit_reached` at `09:43:30`
and `09:44:52` before Context Builder could launch.

Current source and tests classify the resulting window state as the terminal containment
designed in merged upstream PR 822. The registry allows one released cancellation-ignoring
provider; later grace expiry force-disconnects behind an existing blocking lease, and
more than one retained provider produces non-retryable restart guidance. The registry
has no expiration policy or reaper, so elapsed time alone can't recover the
window. Exact late provider completion or process restart removes the retained state.

This chronology strengthens the accepted initiating `read_file` defect family but
doesn't identify its inner blocking stage. The preserved client output lacks the registry
invocation identity and last handler phase, while the app launch directed stderr to
`/dev/null`. It also doesn't connect the read stalls causally to upstream issue 921, whose
protected `file_actions create` failure is a separate operation and contract.

## Post-relaunch controls

The preserved context did not rehydrate after relaunch: `get_file_tree(type=roots)`
reported zero runtime roots while listing the three configured paths, and RepoPrompt Git
and worktree lookup failed. A new background tab in the existing workspace hydrated all
three canonical roots and became the clean control context.

Controls on the same packaged app:

| Control | Result |
| --- | --- |
| Main-checkout MCP `read_file`, `AGENTS.md`, five lines | Success in 2.4 seconds |
| Existing upstream issue 882 worktree Agent `read_file`, exact target, lines 1 to 24 | Timeout in 32.5425 seconds |
| Cancellation outcome for the post-relaunch worktree call | Settled during grace; no detach |
| Immediate main-checkout MCP health read after the timeout | Success in 2.6 seconds |
| Native worktree file read | 0.00 seconds |

The settled-during-grace result establishes that the worktree route is not invariably
cancellation-ignoring and that a timeout does not necessarily poison the window. It does
not identify the stage that consumed the execution budget.

The direct CE CLI transport control was not run. Packaged CLI option `-t` addressed a
different worktree instead of the requested clean tab during the mandatory Git-routing
preflight, so a CLI `read_file` would have tested the wrong context. This is known
upstream issue 900 selector-routing behavior and is not a separate candidate in this investigation.

## Resource and contention controls

At the preservation checkpoint:

- RepoPrompt CE used 0.0% CPU and approximately 566 MiB RSS.
- System memory reported 58% free and no throttled pages.
- No conductor job was queued or running.
- Only one RepoPrompt app process was present.
- More than eight minutes of quiescence did not prevent the second detached timeout.

These controls make global CPU, RAM, duplicate-app, and ordinary build contention weak
explanations. They do not replace historical resource telemetry from the exact failing
seconds.

## Hypothesis status

The controls falsify or materially weaken several explanations:

- Native file size and disk throughput cannot explain the stall. The complete target is
  12.6 KB, and a native read finishes in 0.00 seconds.
- A Codex Desktop client-only failure cannot explain the trigger. A RepoPrompt-created
  Agent bound directly to the existing worktree reproduced the timeout.
- Global app saturation is unlikely. Main-checkout reads on the same packaged process
  succeeded before and after the worktree timeout.
- CPU, memory, duplicate-app, and conductor contention were absent at the preservation
  checkpoint and remain weak explanations.
- The worktree route is not always cancellation-ignoring. The post-relaunch timeout
  settled during grace.
- A timeout does not always detach a provider or fence the window. The immediate health
  read after the settled cancellation succeeded.
- The settlement registry is not the initiating cause. Its busy response occurs at
  admission after an earlier provider escapes cancellation.

The following hypotheses remain unresolved because the failing invocation lacks inner
stage attribution:

- session-bound freshness, ingress, or authority reconciliation related to closed upstream issue 390;
- qualified-path peer-root canonical compaction related to upstream issue 887;
- selected Git-artifact authorization or frozen review-context preflight;
- worktree projection or exact materialization;
- interactive snapshot, cache, scheduler, or off-actor content loading.

## Source boundaries

The source references below describe the current checkout. That checkout contains later
qualified-read work that was not rebuilt into the packaged commit. The references
establish architecture, contracts, and diagnostic seams; they do not prove that every
current branch detail executed in the packaged failure.

### Provider and read stages

- `MCPFileToolProvider.swift:386-506` parses the request and reports
  `read_file.request_resolution`, `read_file.content_read`, and
  `read_file.auto_selection`.
- `MCPServerViewModel.swift:6067-6145` performs selected Git-artifact preflight.
- `MCPServerViewModel.swift:6184-6295` captures roots, awaits explicit freshness,
  resolves the file, and invokes `interactiveReadSnapshot`.
- `WorkspaceReadableFileService.swift:34-104` owns the explicit freshness diagnostics
  and timeout mapping.
- `WorkspaceFileContextStore.swift:11233-11323` owns the interactive snapshot, cache,
  fingerprint, scheduler, off-actor content load, and revalidation path.
- `WorkspaceRootBindingProjection.swift` and
  `AgentWorkspaceLookupContextResolver.swift` own session-bound logical-to-physical
  projection and lifetime validation.

### Timeout hierarchy

`read_file` has a 30-second outer watchdog. Explicit freshness also receives a 30-second
budget, but it starts after request resolution and Git-artifact preflight. The outer
watchdog can expire before the intended freshness timeout response. Watchdog
cancellation may surface a generic execution timeout instead of the retryable
`workspace_freshness_timeout` result.

This timeout hierarchy is a source-backed diagnostic-masking component. It does not prove
that freshness caused these invocations.

### Settlement and fencing

- `MCPDomainToolExecutionWatchdog.swift:369-454` cancels at the deadline and waits up to
  five more seconds for the operation to settle.
- `MCPDomainCodeStructureSettlementRegistry.swift` uses a 30-second recovery horizon and
  allows one released cancellation-ignoring provider per window.
- `MCPConnectionManager.swift:12189-12227` maps the released-provider limit to the observed
  non-retryable busy response.
- `MCPCodeStructureSettlementRegistryTests.swift:232-295` and
  `MCPToolExecutionWatchdogIntegrationTests.swift` cover the second escaped provider,
  released-provider limit, late settlement, and window containment.

The fence is not independently defective on current evidence. A separate fence defect
would require post-settlement leakage, cross-window impact, blocking of non-fenced tools,
or registry counts/origins inconsistent with the actual escaped leases.

## Prior issue and pull-request comparison

### Closed upstream issue 390

Upstream issue 390 covers session-bound worktree freshness and ingress stalls in basic MCP tools.
Merged upstream PR 392 (`02df4915`) added targeted authority reconciliation and bounded
`read_file` freshness handling. Merged upstream PR 520 (`dcc6a511`) made freshness timeout
cancellation-independent and closed upstream issue 390.

Upstream issue 390 is a related closed issue and conditional lineage candidate. It is not yet a
duplicate or confirmed regression because the failing invocation lacks freshness-stage
attribution.

### Open upstream issue 887 and upstream PR 889

Upstream issue 887 covers qualified reads waiting on unrelated roots during canonical compaction.
Upstream PR 889 remains open. Packaged commit `863ea876` changes display-alias materialization to
avoid workspace-wide canonical compaction. That change does not cover session-bound
projection, explicit freshness, Git-artifact preflight, interactive loading, or watchdog
cancellation.

An upstream issue 887-like residual requires a correlated qualified request to enter
`purpose=canonicalCompaction` for an unrelated peer-root token. Route specificity alone
does not establish that behavior.

### Closed upstream issue 818

Upstream issue 818 covers detached-provider fencing and bounded recovery. It explains the downstream
containment behavior, not the initiating worktree read stall.

## Workflow review results

The mandatory RepoPrompt Context Builder concluded that the initiating phase and tracker
lineage were insufficiently attributed. The Pair review accepted the current defect from
the controlled route-specific reproduction while agreeing that upstream issue 390 lineage was
unproven. The same-chat Oracle adjudication adopted the combined classification:

> Packaged-runtime defect accepted; initiating phase and tracker lineage unresolved.

## Required later diagnostic packet

A separately authorized diagnostic lane should capture one isolated failure using one
correlation identity. The packet must include:

1. Exact executable build/hash and compiled source commit.
2. Connection generation, JSON-RPC request, invocation, window, tab, session, and run IDs.
3. Input classification, translated physical-root token, root scope, binding fingerprint,
   ownership generation, projection materialization, and root lifetime IDs.
4. Provider phase transitions and phase age at the deadline.
5. Git-artifact capability, classification, authorization timing, and fallthrough outcome.
6. `ReadFile.ExplicitFreshnessBegan/Ended`, outcome, addressed root, ingress sequences,
   watcher watermarks, queues, waiters, oldest publication age, and seeded-authority state.
7. Session-root availability and lifetime currentness before and after the wait.
8. Exact-resolution checkpoints with purpose, root token, serial position, and
   validation/prune/materialization outcomes.
9. Content-load, interactive snapshot, fingerprint, cache, scheduler, and off-actor I/O
   begin/end events.
10. Watchdog deadline, cancellation origin, grace outcome, detach/late settlement, and
    settlement-registry snapshot.

The first discriminator is the historical or newly captured
`ReadFile.ExplicitFreshnessBegan/Ended` pair:

- begin without a timely end supports an upstream issue 390-class freshness/ingress lineage;
- neither event localizes the stall before ordinary freshness;
- a prompt successful end falsifies freshness as the 30-second stage and shifts the next
  check to exact resolution and content loading.

## Stop boundary

This investigation does not authorize another failing-worktree retry, app rebuild or
relaunch, repository/worktree mutation, code changes, issue draft, or issue filing.
Tracker lineage remains unresolved until a correlated stage packet identifies the
initiating seam.
