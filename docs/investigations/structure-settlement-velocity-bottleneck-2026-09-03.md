# Structure settlement: upstream PR 822 adoption reconciliation

> Investigation report, observed 2026-09-03 and 2026-09-04 on packaged debug apps built from two successive commits of a local stability branch. It records what was true then. Where it disagrees with a current document, the current document is right.

## Disposition

The host reboot cleared the historical process and its two residual providers. The replacement debug process began with balanced `read_file`, `get_file_tree`, and `get_code_structure` counters and admitted an immediate roots canary. That clean baseline rules out survival of the earlier in-memory registry state across the reboot.

The replacement process then reproduced the same terminal precondition while running the unchanged packaged commit. Two current Agent sessions independently issued qualified `read_file` calls: one absolute path and one projected root-qualified path. Each reached the 30-second execution deadline and ignored the five-second cancellation grace. Both detached. The non-resetting `read_file` totals became `deadline_expired=2`, `cleanup_grace_expired=2`, `detached_for_settlement=2`, and `detached_settled=0`. An immediate roots canary returned `tool_execution_structure_settlement_busy`.

This evidence confirms upstream issue 887's qualified-read trigger and upstream PR 889's intended repair. It doesn't show a failure in upstream PR 822's one-released-provider fence or justify another public issue. The decisive replay remains gated on a clean packaged commit that contains both the then-current upstream and final upstream PR 889 head `4ff8036d0fdb4d675da0caa5a28eabfcd7d14fc2`. At this observation, current upstream is `f650a1babf9bd61ea8d0ba16fd47f268fe9d0837`. The packaged runtime contains neither that upstream state nor final upstream PR 889.

## Evidence

- Upstream PR 822 merged as `99367c753c8da87c0b5568b64f5e4440efd90aa3` and is an ancestor of the refreshed packaged stability build.
- Upstream PR 889 precursor `863ea8765ee0ed5039e3618dedae825cbac0aba6` is also an ancestor of that packaged build. Final PR head `4ff8036d0fdb4d675da0caa5a28eabfcd7d14fc2` isn't: later commits `9180e6041af8b09d88d589a86602d21bf856e72f` and `4ff8036d0fdb4d675da0caa5a28eabfcd7d14fc2` add exact-identity revalidation and qualified-path freshness isolation.
- At the pre-reboot upstream snapshot `42fbfc770048ff4bd76d2f7b58c8ec0f36804318`, the registry and watchdog blobs were byte-identical at the upstream PR 822 merge, the refreshed packaged build, and that upstream commit:
  - `MCPDomainCodeStructureSettlementRegistry.swift`: `15ab8de417a26b9d6d5aa49e6bb2e4496ddbd739`
  - `MCPDomainToolExecutionWatchdog.swift`: `90d62fe2dca5ed63cb3c159464ac8f46e033e374`
- The registry allows one cancellation-ignoring structure provider to stop fencing after a 30-second recovery horizon while retaining its exact invocation lease ([`MCPDomainCodeStructureSettlementRegistry.swift`](../../Sources/RepoPromptDomainRuntime/MCPDomainCodeStructureSettlementRegistry.swift):3, [`MCPDomainCodeStructureSettlementRegistry.swift`](../../Sources/RepoPromptDomainRuntime/MCPDomainCodeStructureSettlementRegistry.swift):202).
- Admission becomes terminal when `releasedProviderCount + blockingEntries.count` exceeds the limit of one ([`MCPDomainCodeStructureSettlementRegistry.swift`](../../Sources/RepoPromptDomainRuntime/MCPDomainCodeStructureSettlementRegistry.swift):11, [`MCPDomainCodeStructureSettlementRegistry.swift`](../../Sources/RepoPromptDomainRuntime/MCPDomainCodeStructureSettlementRegistry.swift):220). The reopened incident's message says the window reached its limit of one released provider. The implementation can emit that message only for `releasedProviderLimitReached`; with the later aggregate evidence, that means one released `read_file` lease plus a second blocking `read_file` lease.
- The public error is intentionally non-retryable at that limit and directs the operator to wait for exact settlement or restart RepoPrompt CE ([`MCPConnectionManager.swift`](../../Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift):12191).
- Upstream PR 822's former focused coverage explicitly exercised the same `releasedProviderLimitReached` state with zero released providers after two escaped providers. It also covered one-provider recovery at 30 seconds, exact late settlement, sibling-window availability, and successful fresh admission after drain. Commit `dbd9eeee` (upstream PR 908) later removed those focused registry/watchdog tests while leaving the production registry and watchdog implementations unchanged.

## Post-reboot reactivation evidence

The fresh read-only triage used the existing physical window and contexts. It didn't create a window, workspace, `worktree`, or provider run, and it didn't reopen the canceled historical triage run.

- The only RepoPrompt process was debug app `<debug app A>`, launched at 2026-09-04 01:31:59 UTC. Bundle provenance reported the local stability branch and `dirty: false`; no production process was present.
- The first non-resetting snapshot showed balanced counters. `get_file_tree` had three starts and three handler completions, while `read_file` had two starts and two handler completions. Neither tool had a deadline expiration, grace expiration, detachment, or residual settlement entry. `get_code_structure` had no residual detachment. An explicitly routed roots canary completed in 20 to 40 milliseconds.
- The incident-correlation session for upstream issue 918 (heartbeat-only) called `read_file` at 01:40:52 with the absolute path `<checkout>/docs/investigations/context-builder-selection-construction-watchdog-2026-09-01.md`. The response arrived 35.259 seconds later with `tool_execution_timeout` and explicit detached-for-eventual-cleanup semantics.
- Session `Upstream heartbeat coverage audit` called `read_file` at 01:42:40 with projected root-qualified path `repoprompt-ce/Sources/RepoPrompt/Features/Diagnostics/MCP/MCPToolExecutionDiagnostics.swift`. The response arrived 35.086 seconds later with the same timeout and detachment result. This is a projected workspace path, distinct from the explicit `root-alias//relative-path` token form.
- After those calls, `read_file` reported 12 starts, ten handler completions, two deadline expiration events, two cleanup-grace expiration events, two detachments, and zero detached settlements. `get_file_tree` remained balanced at ten starts and ten handler completions with no deadline, grace, or detachment event.
- A bounded roots canary then returned in 30 milliseconds with `tool_execution_structure_settlement_busy`, reporting the limit of one released cancellation-ignoring structure provider. The exact saved session records tie the two timeout outputs to their qualified input paths, so the new pair no longer has the historical incident's first-provider attribution gap.
- A mandatory upstream issue 881 Context Builder was already active when the first Agent timed out. A separate stability-integration Context Builder began after the terminal fence already existed. Neither builder's owner interrupted or repurposed it for this triage. Their owning lanes retain the campaign's 20-minute continuous no-progress policy.

This sequence proves process-local recurrence from a clean baseline on that build; it doesn't prove persistence across reboot. Both failing forms are explicitly within upstream issue 887: an absolute existing-file path and a root-qualified existing-file path in a multi-root workspace.

## Current integration prerequisite

GitHub reported upstream `main` at `f650a1babf9bd61ea8d0ba16fd47f268fe9d0837` on 2026-09-04. Upstream PR 889 remained open and non-draft, but its review state blocked merging. All eight reported checks were successful, and its head was exactly `4ff8036d0fdb4d675da0caa5a28eabfcd7d14fc2`. The two lines have diverged and both touch `WorkspaceFileContextStore.swift`, so replaying either commit alone isn't the integration gate.

Let `C` be the packaged stability commit used for the replay. Before any lifecycle action or read replay, these checks must pass:

1. Refresh upstream and PR metadata, then pin the exact upstream and final upstream PR 889 commit IDs used for the run. If either moved, update the recorded prerequisite instead of relying on these captured values.
2. `git merge-base --is-ancestor <current-upstream> C` and `git merge-base --is-ancestor 4ff8036d0fdb4d675da0caa5a28eabfcd7d14fc2 C` must both succeed.
3. The packaged bundle's provenance file must name `C` exactly and report `dirty: false`.
4. The quiescent phase must have no unrelated Context Builder or Agent scope in flight. Its owning lane must resolve any builder with no new output or state change for 20 continuous minutes before replay; elapsed runtime alone isn't a stop condition.
5. A non-resetting concurrency snapshot must show zero residual detached providers, and an explicitly routed roots canary must complete without a settlement-busy response.

The current package fails checks 2 and 3. The missing integrated, provenance-verified runtime is the only stability-runtime prerequisite for the decisive replay. Active campaign work is a scheduling condition for the quiescent phase, not permission to weaken the integration gate.

## Pre-reboot upstream assessment

At the earlier pre-reboot observation, the only commit after the packaged build's upstream base that touched the listed settlement-path files was upstream PR 936, merged as `29477196bdb123e2144af0558db2ff469340534c`. It changed active-workspace and explicit-binding resolution in `MCPConnectionManager`. The settlement registry, watchdog, and `MCPFileToolProvider` stayed unchanged; the file-tool provider blob was `7aac28d60d9b34511140a7044f8675923da04e5a` in both the packaged build and that upstream snapshot.

Upstream PR 936 can prevent a routed tool from combining an inactive workspace identity with an explicitly bound window. The reported upstream PR 936 failure was an immediate route-conflict error. The post-refresh calls reached the file providers, and the sibling `read_file` response reported the intended session-bound upstream PR 472 worktree. No confirmed execution path connects upstream PR 936's routing correction to the admitted `get_file_tree` stall.

## Post-refresh packaged-runtime evidence

Bundle provenance recorded the same clean stability commit. The replay used fresh `rpce-cli-debug` invocations with explicit window and context routing against a temporary window and context `<context A>`.

- At 2026-09-03 11:56:20 UTC, the stability acceptance task issued `get_code_structure`, `read_file`, and `get_file_tree` concurrently in the temporary window. Code structure completed in 25.408 seconds and the read completed in 21.253 seconds. The tree request targeting `Sources/RepoPrompt/Infrastructure/MCP` reached the 30-second execution deadline, did not settle during the five-second cancellation grace, and returned `tool_execution_timeout` at 11:56:55.
- At 11:57:14, 18.8 seconds after the detached timeout completed, another tree request returned `tool_execution_structure_settlement_busy` with bounded-recovery guidance. This is the expected upstream PR 822 fence during its 30-second recovery horizon.
- At 11:57:45, 50.3 seconds after the first detach, a fresh tree request was admitted. Admission proves the first provider stopped fencing on schedule. The fresh request independently reached the same 30-second deadline and five-second grace and returned `tool_execution_timeout` at 11:58:20.
- No post-refresh response reported `released_provider_limit_reached`. The replay therefore did not exhaust the one-released-provider allowance and did not enter upstream PR 822's terminal safety state.
- The two timed-out providers are attributable to the stability acceptance caller in the temporary window. Context `<context A>` projected reads into the upstream PR 472 worktree, but upstream PR 472 did not initiate these invocations.
- The timeout responses omitted invocation ID, connection ID, and last handler phase. Current code reports separate `get_file_tree` phases for request resolution, ingress wait, and tree construction, so this evidence cannot distinguish a worktree-ingress wait from tree construction.
- MP retired the temporary physical window after this sequence. That retirement canceled the later tiny Context Builder availability canary and superseded its result; it did not cause the earlier tree timeouts and is not standalone provider evidence.

## Reopened packaged-runtime evidence

The later incident occurred in the still-running packaged debug process `<debug app B>`, launched from the same clean commit. It affects a different window than the retired temporary one.

### Entry into the terminal fence

- The stability Context Builder started at 2026-09-03 19:22:46 UTC in tab `<tab A>`. Its outer CLI process is `<stability client>`.
- An upstream issue 830 Agent session, Codex conversation `<redacted>`, started at 19:23:14 in the session-bound upstream issue 830 worktree. Its initial disambiguated reads completed normally.
- At 19:24:02 the upstream issue 830 Agent called `read_file` for the absolute path `<checkout>/docs/investigations/root-agent-replacement-handoff-2026-09-02/proposed-revised-goal.md`. At 19:24:37 it returned after 35.1736 seconds with `tool_execution_timeout` and `settlement: detached` semantics.
- At 19:24:46 the same Agent's next absolute `read_file`, targeting the hot campaign ledger, returned `tool_execution_structure_settlement_busy` in 204 milliseconds with the released-provider-limit message. Further upstream issue 830 reads and a tree request were rejected synchronously.
- This sequence proves that a released provider predated the upstream issue 830 goal read. The upstream issue 830 goal read was admitted only after the earlier blocker had reached the registry's 30-second recovery horizon; it then became the second blocking lease.
- Working backward from the upstream issue 830 goal-read admission, the earlier call had to cross its 30-second execution deadline, five-second cancellation grace, and 30-second registry recovery horizon after the stability Context Builder began. The stability builder is the only correlated surviving operation whose start time fits that window. This is strong attribution evidence, not proof of the exact nested invocation or file path.
- The root Doc Garden Context Builder started later, at 19:32:41 in tab `<redacted>`, with CLI process `<Doc Garden client>`. It cannot have caused entry into the terminal state.
- Independent roots canaries then observed the same window-3 response across upstream issue 916 beginning at 19:39, upstream issues 830 and 882, and root through 22:53. At 22:53 root explicitly bound existing upstream issue 830 context `<redacted>`; the binding succeeded and its immediate roots request returned the same terminal fence. This separates routing success from provider settlement failure.

### Live pre-lifecycle snapshot

A source-verified read-only DEBUG diagnostics call at the same process, without resetting counters, reported these active window-3 scopes:

- stability Context Builder: connection `<connection A>`, sequence 868;
- root Doc Garden Context Builder: connection `<connection B>`, sequence 903;
- a separate Agent run: connection `<connection C>`, sequence 1449.

Both Context Builder connections were `ready`, in flight, and still owned one outer `context_builder` scope. Process start order and the monotonic scope sequence map sequence 868 to `<stability client>` and sequence 903 to `<Doc Garden client>`; `lsof` independently maps the two client sockets to app file descriptors 45 and 54.

The non-resetting concurrency snapshot localizes the remaining settlement entries:

| Tool | Deadline expiries | Grace expiries | Detached | Detached settled | Residual detached |
| --- | ---: | ---: | ---: | ---: | ---: |
| `read_file` | 15 | 12 | 11 | 9 | 2 |
| `get_file_tree` | 2 | 2 | 2 | 2 | 0 |
| `get_code_structure` | 0 | 0 | 0 | 0 | 0 |

`read_file` also recorded one force-disconnect request. The exact difference between detachments and detached settlements is two, matching the registry state required by the terminal response. The earlier window-2 tree providers have both settled and do not own the current fence.

The public error metadata contains an origin tool, invocation, connection, age, and handler phase, but ordinary CLI and Agent result projection retained only the human-readable error text. The hidden diagnostics surface exposes active outer scopes and aggregate execution counters, not each retained settlement lease. This leaves the first released nested read without exact attribution before a lifecycle boundary.

The duration inventory's separate 10-second readiness ceiling is not evidence of a `read_file` provider contract violation. Source inspection ties that ceiling to interactive client-session initialization. The relevant provider boundary here is the observed 30-second execution deadline plus five-second cancellation grace; the registry then deliberately retains the detached lease until exact settlement.

### Final pre-relaunch snapshot

MP authorized recursive retirement of the two Context Builder clients without stopping the app. The stability client exited first; the root Doc Garden client then exited with code 130 after an interrupt. Neither process retained an OS descendant. The app's terminal-event store independently recorded both connections as peer-initiated EOFs:

- at 2026-09-03 23:07:11 UTC, connection `<connection A>`, peer `<stability client>`;
- at 23:10:49 UTC, connection `<connection B>`, peer `<Doc Garden client>`.

An immediate upstream issue 830 roots canary after both client exits still returned `tool_execution_structure_settlement_busy`. At 23:14:49 UTC, a final non-resetting diagnostics snapshot showed neither Context Builder connection or scope, while `read_file` remained at 11 detachments and nine detached settlements. The two residual providers survived both outer clients and remain inside `<debug app B>`; client EOF did not settle or remove their registry leases.

The same snapshot contained one active outer `agent_run` scope on connection `<connection C>`, sequence 1466. That scope belongs to unrelated upstream issue 881 merge-coverage work and is not settlement evidence. The visible app must remain undisturbed until those Agent sessions finish and the root campaign establishes the authorized relaunch boundary.

## Deduplication and residual boundary

- Upstream issue 818 and upstream PR 822 own settlement fencing and bounded recovery. Upstream PR 822 explicitly designed the observed second-provider state to be non-retryable and require exact settlement or an app restart. The persistent fence conforms to that contract while both read providers remain unsettled.
- Upstream PR 644 owns the earlier change that moved `read_file` and `get_file_tree` onto detach-and-settle instead of disconnecting the bridge.
- Closed upstream issue 390 and merged upstream PR 520 own session-bound worktree ingress stalls and basic-tool waits. The missing internal phase leaves this as the nearest root-cause family, not a confirmed regression.
- Open upstream issue 172 owns the broader MCP throughput roadmap, including small-read admission, freshness, worktree binding, and file-provider projection. The two tree timeouts are compatible with that active track.
- Upstream issue 887 and upstream PR 889 own qualified `read_file` probing of unrelated roots. The upstream issue 830 goal read is an absolute existing-file request in the same multi-root workspace and matches that issue's trigger shape. The running package does not contain upstream PR 889's final exact-identity and freshness-isolation commits, so this incident cannot validate or invalidate the final repair.
- Upstream issue 918 owns a nested `manage_selection.selection_construction` stall after Context Builder discovery. The canceled tiny Context Builder attempt did not reach an attributable phase and adds no evidence to that issue.
- Upstream PR 936 owns routing authority, not provider execution. The successful sibling operations and explicit worktree projection make stale routing an unsupported explanation for these timeouts.

Current GitHub deduplication found closed upstream issue 818 for the immortal settlement fence, merged upstream PR 822 for bounded recovery and the one-provider cap, open upstream issue 887 with open upstream PR 889 for qualified multi-root reads, and open upstream issue 918 for a distinct nested `manage_selection.selection_construction` stall. No issue should be filed for the current evidence alone.

A separate issue becomes maintainer-ready in either of these controlled cases:

1. A package containing final upstream PR 889 head `4ff8036d` still lets an addressed absolute, explicit-root, or projected root-qualified `read_file` cross the 30-second deadline, ignore cancellation grace, and either remain unsettled or exhaust the released-provider allowance.
2. Every owning provider/session reaches a proven terminal state, but a fresh same-window structure call still reports the retained settlement fence. That would show stale registry ownership rather than an intentionally live escaped provider.

Until one of those controls passes, retain this as a provider-level candidate and do not draft or file another settlement issue.

## Safe-boundary replay plan

The replay uses the existing physical window, workspace, and upstream PR 889 context. It must not create a window, workspace, `worktree`, Context Builder, or Agent session. Capture exact commands, timestamps, process identity, context ID, and raw JSON results in the run artifact.

### Phase A: Quiescent packaged runtime

1. Meet all five integration prerequisites. Capture `connections`, `agent_manage` running and waiting inventories, and `mcp_tool_concurrency_evidence_snapshot` with `{"reset":false}`. Don't begin while an unrelated outer scope is active.
2. Start `mcp_read_search_capture_begin` with label `issue-887-qualified-read-replay-quiescent` and `max_samples: 20000`. This resets response-delivery and work-count debug history, so preserve the non-resetting concurrency snapshot first.
3. Read the same small, tracked file in sequence with `start_line: 1` and `limit: 20`:
   - absolute: `<checkout>/Sources/RepoPromptWorkspaceCore/WorkspacePathPolicy.swift`;
   - explicit root: `repoprompt-ce//Sources/RepoPromptWorkspaceCore/WorkspacePathPolicy.swift`;
   - projected root-qualified token: `repoprompt-ce/Sources/RepoPromptWorkspaceCore/WorkspacePathPolicy.swift`.
4. Run `get_file_tree` with `{"type":"roots"}` through the same explicit context binding.
5. Finish with `mcp_read_search_capture_snapshot` using `{"finish":true,"include_timeline":true}` and a second non-resetting concurrency snapshot.

Phase A passes only if all three reads return the same file identity and requested content. Each read and the roots call must complete within five seconds. The `read_file` delta must be exactly three starts and three handler completions, with no new deadline expiration, cleanup-grace expiration, detachment, force-disconnect, admission rejection, or residual provider. Five seconds is the operational threshold because it leaves a sixfold margin before the 30-second execution contract. Any timeout, settlement-busy result, or forbidden counter delta is an immediate hard failure.

### Phase B: Controlled unrelated-root ingress

1. On the exact integrated source commit `C`, run the coordinated focused suite `make dev-test FILTER=MCPReadMutationPathContractTests`. Require these three controls to pass:
   - `testQualifiedResolutionSkipsPeerProbeWhileBareRelativeClassifiesNamespace` proves qualified resolution doesn't probe the peer while the bare-relative control does;
   - `testReadProviderQualifiedReplayCompletesWhilePeerIngressIsHeld` proves the addressed provider returns while the unrelated root's ingress barrier is demonstrably still active;
   - `testReadProviderBareRelativeFreshnessWaitsForHeldPeerIngress` proves the harness would detect the expected namespace-wide wait for the negative control.
2. Synthetic live load isn't a substitute for that gate. Ordinary concurrent tree or search calls can finish before the evidence captures overlap, so they can't prove held unrelated-root ingress. The deterministic held-peer test is the decisive controlled-unrelated-root replay; Phase A is the packaged end-to-end confirmation.
3. Repeat Phase A once after the focused suite on the same provenance-verified package. Require the same five-second response thresholds and zero forbidden counter deltas. This second pass catches integration or packaging drift that a source-level fixture can't exercise.

If a final-upstream PR 889 qualified read fails either phase, prepare one maintainer issue for the upstream issue 887 provider trigger with the exact integrated commit and trace. If every addressed read passes but a terminal fence survives after all owning providers have demonstrably ended, prepare a separate upstream issue 818/upstream PR 822 regression issue for stale settlement ownership. Don't combine the two defect families.

## Maintainer-guidance check

- **User impact and invariant:** two qualified reads can recreate the terminal structure fence from a clean process, blocking later structure tools. The settlement invariant still bounds hidden-provider accumulation rather than silently admitting more work.
- **Root-cause confidence:** high that both post-reboot detached providers came from the two recorded qualified `read_file` calls; high that the later terminal response is upstream PR 822's intended one-released-provider fence; unresolved on a runtime containing final upstream PR 889 because that package doesn't exist yet.
- **Authority:** `MCPFileToolProvider`, `MCPServerViewModel`, `WorkspaceReadableFileService`, and `WorkspaceFileContextStore` own the qualified read path. `MCPDomainCodeStructureSettlementRegistry`, `MCPConnectionManager`, and `MCPDomainToolExecutionWatchdog` own the confirmed terminal fence.
- **State-safety risks:** relaxing the limit without a way to stop providers can accumulate detached work or let stale completion affect newer work.
- **Scale and observability risks:** one released provider plus one later blocker makes all three structure tools terminal for the window. Aggregate diagnostics prove the residual count; persisted Agent records supply the exact two input paths and timeout outputs that aggregate diagnostics omit.
- **Recommended scope:** keep upstream PR 822 adopted and upstream issue 887/upstream PR 889 as the owning provider trigger. Don't file a separate issue unless the integrated final-upstream PR 889 replay fails or stale settlement survives proven provider termination.
- **Validation boundary:** first require an integrated commit descended from current upstream and final upstream PR 889, with clean bundle provenance. Then run the quiescent packaged replay and deterministic held-peer-root suite. Generic concurrent live load is only supporting evidence because it can't prove held unrelated-root ingress.

## Post-upstream PR 889 `get_file_tree` regression

### Classification

A clean package containing final upstream PR 889 reproduced one cancellation-unresponsive `get_file_tree` provider. The provider eventually settled, and no outer tool scope remained active. This is a provider latency and cancellation defect, not stale settlement ownership under upstream issue 818/upstream PR 822 and not a recurrence of upstream issue 887's qualified `read_file` routing bug.

The closest prior owner is closed upstream issue 390. Its acceptance criteria require bounded, typed freshness behavior for file tree and other basic tools. Merged upstream PR 520 closed upstream issue 390 after hardening mutation ingress, but the current tree provider still waits without an internal bound and can reach the generic MCP watchdog. No open issue or pull request found on 2026-09-04 owns that exact file-tree failure. A new regression issue should reference upstream issue 390 rather than reopen upstream issue 818, upstream PR 822, upstream issue 887, upstream PR 889, or upstream issue 921.

### Runtime and invocation evidence

- The sole debug app was `<debug app C>`, launched at 2026-09-04 02:36:38 UTC. Bundle provenance reported a later clean commit on the local stability branch. That commit contains final upstream PR 889 head `4ff8036d0fdb4d675da0caa5a28eabfcd7d14fc2`.
- The existing context was `<tab A>` in an existing physical window. It projected the `repoprompt-ce` root into its existing session-bound stability `worktree`. The triage made no changes to the window, workspace, context, or `worktree`.
- At 02:43:28 UTC, a fresh packaged `repoprompt-mcp` process issued `tree Sources/RepoPrompt/Infrastructure/MCP` with explicit window and context routing. The bare relative path could resolve across the context's multi-root `namespace`.
- At 02:44:04, after 35.685 seconds, the call returned `tool_execution_timeout`. It crossed the 30-second execution deadline and remained active through the five-second cleanup grace, so the watchdog detached it for eventual cleanup.
- Immediately before the tree call, two `get_code_structure` requests returned code-graph-pending responses and a direct `read_file` for lines 1 to 20 completed in 3.7 seconds. Those sibling outcomes show that routing and basic file access were available. They don't identify the tree provider's blocked phase.
- The terminal event for connection `<redacted>` records peer-initiated EOF at 02:44:04 from peer `<peer client>`, after the timeout response.

A later non-resetting concurrency snapshot reported this exact `get_file_tree` delta:

| Event | Count |
| --- | ---: |
| execution started | 2 |
| handler completed | 1 |
| deadline expired | 1 |
| cancellation requested | 1 |
| cleanup grace expired | 1 |
| detached for settlement | 1 |
| detached settled | 1 |

The same snapshot had no active outer tool scope. The equality of detach and detached-settled counts proves eventual cleanup and rules out a residual registry lease from this invocation.

### Provider-stage boundary

The saved evidence can't recover the exact blocked handler phase. `MCPFileToolProvider.executeGetFileTree` reports three phases: `get_file_tree.request_resolution`, `get_file_tree.ingress_wait`, and `get_file_tree.construction`. Deadline and detachment trace events include the latest phase, but the app wrote those events to `stderr` and `<debug app C>` had `stderr` attached to `/dev/null`. The non-resetting aggregate recorder retains execution-event counts and latency histograms, not the per-invocation handler-phase snapshot. The CLI timeout response also omits that snapshot.

Post-hoc root diagnostics show no active or pending ingress flight. Every root had zero accepted/applied publication gap, zero queued or applying publication, and zero ingress waiter. Retained barrier history reported `max_wait_ms: 0`. That evidence shows the store was quiescent when inspected; it makes a completed 30-second scoped barrier wait unlikely. It can't exclude time spent before a barrier record, a canceled wait omitted from completion history, request resolution, or tree construction. Replaying the timeout merely to capture a phase would risk another detached provider and is unnecessary for issue acceptance.

### Current-upstream applicability

At the investigation snapshot, upstream `main` was `f650a1babf9bd61ea8d0ba16fd47f268fe9d0837`. `MCPFileToolProvider.swift` had blob `7aac28d60d9b34511140a7044f8675923da04e5a` in both the packaged commit and current upstream, so the relevant `executeGetFileTree` path is byte-identical. Merged upstream PR 927 changes search-index freshness after root lifecycle changes, not the tree provider's watchdog, freshness, or construction behavior.

### Smallest repair plan

1. Preserve the latest handler-phase snapshot for bounded failed-invocation history and include it in `tool_execution_timeout` diagnostics. A timeout must remain attributable after app `stderr` is unavailable.
2. Give `get_file_tree` its own internal deadline shorter than the 30-second outer watchdog. If freshness is blocking, use the existing bounded ingress helper and return typed, `retryable` `workspace_freshness_timeout` output. Keep bare-relative paths namespace-wide; narrow only absolute or explicit-root inputs whose root identity is unambiguous.
3. Make tree snapshot construction cancellation-cooperative at recursive traversal boundaries. If construction reaches its internal budget, return a typed tree-construction timeout without leaving a detached provider.
4. Add deterministic phase tests. Hold request resolution, one scoped ingress flight, and recursive construction independently; assert the recorded last phase, bounded response, provider settlement within cleanup grace, and no structure-settlement residue. Use an unrelated held root plus an explicitly qualified tree path to prove safe root narrowing, with a bare-relative request as the negative control.
5. Run the focused provider and watchdog suites, then the full coordinated test and lint lanes. Package the exact repaired commit and repeat the explicit-context tree command with non-resetting before/after counters; require completion within five seconds and zero deadline, grace, detach, rejection, or residual deltas.

### Filing packet

The filing packet drafted here was filed, reworded, as upstream issue 949 on 2026-09-04. It reported the 35.685-second `tool_execution_timeout` and detached cleanup for `tree Sources/RepoPrompt/Infrastructure/MCP`, named upstream issue 390 as the closest prior owner, and asked for a typed, phase-attributed result before the outer watchdog with settlement inside cleanup grace.
