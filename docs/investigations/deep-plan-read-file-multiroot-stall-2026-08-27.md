# Investigation: Multi-root exact `read_file` stall during deep planning

> Investigation report, observed 2026-08-27 on the Tip build 1.3.0 (35.15.18) and a debug build of `2f94412e`. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary

A deterministic gated test confirms that an absolute or explicit-root request can inherit peer-root latency while deriving a canonical path that later operations can safely reuse. The failure was first observed in the official RepoPrompt CE Tip Build, version 1.3.0 (35.15.18). Correlated live diagnostics on a DEBUG build from the same source commit then reproduced both a slow success and a 30-second timeout against the same generated export. In both traced runs, addressed-root validation completed first. Canonical compaction then waited on unrelated roots before content loading could begin.

The defect is separate from upstream issues 881 and 882, and upstream PR 472 doesn't fix it. The final duplicate search found no pre-existing matching GitHub issue or pull request. Merged upstream PR 800 is the likely regression source because it introduced the shared exact-path flow that performs the second all-root pass. The cross-root responsiveness defect and its ability to produce the deep-plan failure class are confirmed. The original request lacked correlated instrumentation and can't be reconstructed event for event, but the same file, workspace, tool, and timeout boundary now reproduce under correlated tracing. Upstream issue 887 now tracks the defect.

## Scope distinctions

| Item | Boundary | Relationship to this investigation |
| --- | --- | --- |
| Upstream issue 881 | Large app-backed `prompt` / `workspace_context` export exceeds its watchdog | Separate operation and code path |
| Upstream issue 882 | Concurrent same-workspace `agent_run.start` durable admission race | Separate agent admission problem |
| Upstream PR 472 / upstream issue 457 | A completed read can wedge while its selection mirror drains | Related historical wedge, but downstream of content resolution |
| Upstream issue 818 / upstream PR 822 | Detached-provider settlement can fence structural tools in the same window | Downstream `tool_execution_structure_settlement_busy` containment, not the initiating stall |
| Upstream PR 800 | Unified exact-path resolution and canonical replay paths | Likely regression source; merged without a zero-peer-probe latency invariant for qualified paths |
| Upstream issue 887 | Qualified exact resolution waits on unrelated roots during canonical-path derivation | Filed with deterministic and correlated live evidence |

## Symptoms

- Reading a generated Oracle plan export under `prompt-exports/` sometimes succeeded slowly and sometimes exceeded the 30-second execution contract.
- The initial failures occurred in official Tip Build 1.3.0 (35.15.18), tag `tip-2f94412e6ab5`. Stable wasn't tested. The later DEBUG build from source commit `2f94412e` added observability and reproduced the behavior; it didn't introduce the affected path.
- The timed-out provider didn't settle during the five-second cancellation grace, so the watchdog detached it.
- Later structural reads could then receive `tool_execution_structure_settlement_busy`; that response is containment after the first timeout, not the initiating defect.
- The failure reproduced against a clean debug build of upstream PR 472 after RepoPrompt had been restarted.
- One traced request completed in 11.9 seconds; 11.7 seconds were unrelated-root pruning and approximately four milliseconds were content loading.
- A second traced request reached an unrelated-root prune and exceeded the 30-second client timeout before content loading began.

## Background / prior research

- Upstream PR 472's focused selection-coordinator tests passed locally, and all of its GitHub checks were green.
- Live diagnostics on the upstream PR 472 debug build showed freshness validation completing in under one millisecond and no pending ingress.
- The failing request produced no content-load completion or automatic selection event before the watchdog fired. Runtime counters for `read_file_auto_selection` were zero.
- GitHub searches for the exact symbols and broader combinations of multi-root, exact-path, `read_file`, timeout, stall, and `prompt-exports` found no duplicate issue or pull request.
- Upstream PR 800 introduced the current unified exact-path resolution flow. Its fast-path tests don't establish that a qualified request avoids unrelated-root probes or has bounded peer-root latency.

## Investigator findings

### Qualified exact resolution can depend on peer roots

`resolveExactExistingWorkspaceFile` resolves absolute and explicit-root inputs against only the addressed binding. After materialization succeeds, both branches call `exactExistingFileMatch` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:16871`).

`exactExistingFileMatch` then calls `exactFileCandidates` with every binding in `namespace.rootBindings` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:17181`). This second scan decides whether the returned canonical path can be a plain relative token or must use an explicit root alias.

The canonical path is a replay token for later mutations, not cosmetic display text. Namespace-wide classification protects hidden ignored duplicates, unavailable projected work trees, alias-looking literal paths, and multi-root collisions. Removing the scan globally is unsafe. Catalog absence can't prove uniqueness, and a relative path returned without peer checks could replay against the wrong root.

### A missing peer path can wait behind unrelated actor or filesystem work

For each peer root without a catalog record, `exactFileCandidates` awaits that root's `FileSystemService.catalogRegularFileEligibility` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:17119`). The eligibility function performs synchronous `FileManager.fileExists` metadata I/O on the actor (`Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift:116`).

The scan runs serially and doesn't throw. It has no explicit cancellation checks, and cancellation can't interrupt an actor queue wait or synchronous `fileExists` call. A missing peer can also enter `fenceAndPruneCatalogFileMissingOnDisk`, which acquires a code-map path fence even when no stale record remains (`WorkspaceFileContextStore.swift:17644`). An addressed read of root A can inherit unrelated delay from root B while proving that a short replay token is safe.

### Target materialization was a credible alternative before correlated tracing

The first one-binding lookup precedes `exactExistingFileMatch`. On a catalog miss, `materializeExplicitlyRequestedFile` repeats eligibility and managed-file registration, then calls `beginCodemapRootMutationFence` and `awaitCodemapCleanupFlights` (`WorkspaceFileContextStore.swift:17235`). A newly generated or ignored export may enter this path before any peer-root scan.

The earlier trace proved only that freshness finished and content loading hadn't completed. It couldn't show whether target materialization ended or canonical compaction began. The new correlated trace closes that gap for the reproduced failure. It shows completed qualified target validation followed by canonical compaction, where unrelated-root pruning consumed the watchdog budget. No materialization checkpoint appeared in either reproduced request.

### The settlement registry amplifies the first timeout but doesn't cause it

`read_file`, `get_file_tree`, and `get_code_structure` share a window-scoped detach-and-settle registry. When the first provider ignores cancellation, the registry retains a settlement lease and intentionally fences later structural calls. Weakening that registry wouldn't repair the initiating stall and could conceal escaped work.

## Investigation log

### Live upstream PR 472 validation

**Hypothesis:** The deep-plan blocker is the selection-mirror wedge fixed by upstream PR 472.

**Findings:** The failing request never reached content loading or automatic selection. Upstream PR 472 changes the later selection-mirror phase.

**Conclusion:** Eliminated. Upstream PR 472 remains valid for its own bug but doesn't fix this failure.

### Freshness and export-size checks

**Hypothesis:** Workspace freshness or the generated export's size consumes the watchdog budget.

**Findings:** Freshness completed immediately, and the export is approximately 60 KB. The failure occurred before content loading.

**Conclusion:** Eliminated as the observed first cause.

### Multi-root exact-path resolution

**Hypothesis:** Resolving an already-qualified path unnecessarily probes peer roots and can block on their file-system actors.

**Findings:** Source tracing confirmed that qualified inputs perform a second namespace-wide scan after one-binding target resolution. The scan uses serial actor and filesystem probes without a per-binding deadline. Independent review also confirmed that the scan protects replay-safe canonical paths and performs incidental stale-catalog pruning.

**Conclusion:** The cross-root dependency is confirmed. Correlated live reproduction is still required to distinguish it from earlier target validation or materialization in any individual timeout.

### Deterministic peer-dependency proof

**Hypothesis:** An already-cataloged qualified target in root A waits on root B only during canonical compaction. A bare-relative request legitimately waits on root B during `namespace` classification.

**Method:** A temporary DEBUG-only probe recorded each `exactFileCandidates` call's purpose. It distinguished qualified target validation from relative `namespace` classification. Canonical compaction used a separate value. The probe held only root B for `Target.swift`. The qualified test covered absolute resolution and the returned explicit-alias round trip. It also replayed an edit that could change only root A. The negative control used the same gate for a bare-relative request. The diagnostic harness didn't stay in the source because the qualified test describes the desired fixed behavior and stays red on current code.

**Findings:** `testQualifiedExactReadDoesNotAwaitBlockedPeerProbe` compiled and then timed out while the root-B canonical-compaction gate was held. Conductor ticket `<redacted>` ran one test with one failure in 4.565 seconds. `testBareRelativeReadAwaitsPeerNamespaceClassification` entered the root-B classification gate. After release, it completed and resolved root A. Conductor ticket `<redacted>` ran one test with zero failures in 0.008 seconds. Non-mutating format validation passed under ticket `<redacted>`.

**Conclusion:** The qualified resolver has a deterministic responsiveness dependency on unrelated peer roots. The negative control shows that the proof distinguishes canonical compaction from the namespace-wide classification required for bare-relative inputs.

### Correlated live reproduction

**Hypothesis:** The same generated export and the owner's four-root multi-root workspace stall after addressed-root validation, during canonical compaction of unrelated roots.

**Method:** DEBUG-only lifecycle diagnostics correlated resolver, materialization, content-load, provider, and watchdog events with the existing MCP request identity. Events record only stage, outcome, serial root position, an ephemeral root token, and cache status. The live debug app reused the owner's existing multi-root workspace; no workspace, tab, or work tree was created. The request read the first lines of the same generated export by absolute path.

**Findings:** The first request succeeded. `EditFlow.ReadFile.ResolveReadableFile` took 11,914.243 milliseconds and `EditFlow.ReadFile.WorkspaceContentLoad` took 4.09 milliseconds. Qualified target validation completed in the `repoprompt-ce` root before canonical compaction scanned all four workspace roots. Missing-file pruning took approximately 205.6 milliseconds in the toolkit repository root, 10,697.5 milliseconds in `repoprompt-classic`, and 997.0 milliseconds in `dotfiles`. Revalidation of the addressed `repoprompt-ce` root completed in approximately 0.4 milliseconds. Content loading then returned from disk in approximately four milliseconds.

The second request reached the same canonical-compaction sequence. It spent approximately 953.7 milliseconds pruning the toolkit repository's candidate, began pruning the unrelated `repoprompt-classic` candidate, and didn't emit the matching end checkpoint before the 30-second client timeout. It never emitted `ReadFile.ContentLoadBegan`.

Immediately after the timeout, `get_file_tree(type="roots")` returned `tool_execution_structure_settlement_busy`. After the watchdog's bounded settlement interval, the same roots request succeeded without an app restart. This demonstrates that settlement-busy is a temporary containment response to the timed-out provider in this reproduction, not the initiating failure.

**Conclusion:** The instrumented reproduction attributes the live failure class to canonical compaction waiting on unrelated-root missing-file pruning. The file size, content I/O, OpenAI provider, Context Builder, and selection mirror aren't on the stalled path. The original request without correlated instrumentation remains historical evidence rather than a correlated trace, but it used the same tool, file, workspace, and timeout boundary.

### Diagnostic seam validation

The correlated markers use the existing MCP request identity and lifecycle correlation. They don't add a parallel request registry. Resolver checkpoints are generic to exact workspace resolution, while file-content checkpoints remain specific to `read_file`. Approved dimension lists exclude paths, filenames, file identifiers, and content.

The focused lifecycle and privacy guard passed under conductor ticket `<redacted>`. The full `MCPReadMutationPathContractTests` suite passed 15 tests under ticket `<redacted>`, including unavailable work trees, hidden duplicates, and alias round trips. The existing permit and request-identity regression passed under ticket `<redacted>`. Final formatting changed no files under ticket `<redacted>`, and strict lint passed under ticket `<redacted>`.

### Current GitHub duplicate triage

The final read-only search found no issue or pull request that tracks unrelated-root canonical-compaction latency for an absolute or explicit-root `read_file` request.

- Upstream PR 800 is the likely regression source, not a fix. It introduced the current absolute and explicit-root resolution followed by a namespace-wide canonical-path pass.
- Upstream issue 457 and upstream PR 472 concern a later selection-mirror task chain. They don't modify exact-path resolution.
- Upstream issue 818 and upstream PR 822 concern detached-provider settlement and bounded recovery. They explain the downstream `tool_execution_structure_settlement_busy` response but don't prevent the initiating resolver timeout.
- Upstream PR 755 concerns `read_file` selection and physical-identity convergence. It doesn't remove unrelated-root eligibility or pruning probes.
- Upstream issues 808 and 811 concern separate read admission and synchronous-I/O paths.
- Upstream issue 881 remains the separate large export watchdog problem.

Upstream issue 887 tracks the regression against upstream PR 800. It links the selection-mirror and settlement artifacts as related boundaries, not duplicates. The requested `bug` and `area:mcp` labels weren't applied because the contributor account lacks label-assignment permission.

### RepoPrompt investigation workflow availability

**Hypothesis:** The complete `$rp-investigate` workflow can independently validate the finding.

**Findings:** Its required Phase 0 `bind_context` call didn't return within 90 seconds against the running upstream PR 472 debug app, so the client stopped the call. Restarting the existing debug app produced the same result. The CE debug CLI then returned the window inventory immediately and showed two `Default` windows with no workspace loaded, while MCP `manage_workspaces.list` also hung. After Codex Desktop restarted, the task registered no RepoPrompt MCP tools even though the debug CLI remained healthy. The workflow never started Context Builder, pair, selection refinement, or Oracle.

**Conclusion:** The RepoPrompt workflows remained blocked at Phase 0 by the external MCP client surface. This transport state is separate from the original `read_file` stall and doesn't support or refute its attribution. This report doesn't claim completion of the remaining RepoPrompt workflow phases.

### Native context and browser Oracle fallback

**Hypothesis:** Native context curation plus an independent GPT-5.6 Pro browser review can challenge the leading theory while RepoPrompt MCP is unavailable.

**Findings:** A GPT-5.6 Luna agent curated source slices, tests, history, runtime facts, competing hypotheses, and public links. A separate native explorer challenged feature dependencies and found that canonical-path qualification is a mutation safety contract. GPT-5.6 Pro confirmed that contract independently. It also elevated target materialization as a credible earlier blocker and proposed separate evidence gates for deterministic and live validation.

The browser Oracle initially tried to clone the public repository. Future fallback packets should explicitly require attached slices and browser or connector access instead of shell cloning, and should ask the Oracle to name any source it couldn't inspect.

**Conclusion:** The fallback produced material corrections and a safer evidence threshold. It doesn't replace the stateful selection guarantees of RepoPrompt Context Builder, but it was sufficient to prevent premature filing or a globally unsafe scan removal.

## Root cause status

The qualified exact resolver defect is confirmed: an already-cataloged target can wait on an unrelated root while proving that its canonical path may be relative. The peer scan crosses actors and performs synchronous metadata work. It may also acquire pruning fences. A slow peer can hold a read past the outer watchdog.

Correlated live diagnostics reproduce the observed failure class and distinguish the competing paths. Addressed-root validation completed; no target-materialization checkpoint appeared; canonical compaction then stalled in unrelated-root missing-file pruning. Watchdog detachment and later `tool_execution_structure_settlement_busy` remain downstream containment, not the initiating cause. The settlement fence cleared after bounded recovery in the reproduced timeout.

## Recommendations

1. Use the proven test design with the fix: `testQualifiedExactReadDoesNotAwaitBlockedPeerProbe` belongs beside `MCPReadMutationPathContractTests`. Gate peer eligibility by purpose, root, and relative path. An absolute read of an already cataloged target in root A must complete while root B's peer gate remains closed. Its explicit alias must round-trip, and a replayed edit must change only root A.
2. Retain the proven negative control. The explicit-root read should complete without peer entry; the bare-relative read must keep namespace-wide classification and wait for the peer gate.
3. Retain the correlated diagnostics while applying and validating the fix. The fixed qualified request must skip peer probes and reach content loading directly. Cancellation tests must show that no detached settlement lease remains.
4. Split qualified identity from global compaction in the shared exact resolver. Preserve one-binding eligibility and materialization, then return the namespace-generated explicit alias for absolute and explicit-root files in multi-binding root sets. Keep namespace-wide probing for every bare-relative request.
5. Preserve collision, ignored-file, unavailable-worktree, logical-to-physical projection, alias-fallback, and read-to-`apply_edits` round-trip tests. Don't weaken the structure-settlement registry or rely on catalog absence as uniqueness.
6. Use upstream issue 887 as the tracker for the deterministic cross-root dependency and correlated live timeout. Keep `tool_execution_structure_settlement_busy` as a downstream symptom unless a separate reproduction shows the settlement fence failing to clear after its bounded recovery.

## Preventive measures

- Separate qualified identity from global replay-token compaction when compaction requires cross-root I/O.
- Require cancellation-aware boundaries for loops that await multiple root actors.
- Add a multi-root latency oracle that proves a qualified root doesn't inherit an unrelated peer root's delay while bare-relative ambiguity remains fail-closed.
- Keep target materialization separate from canonical compaction in diagnostics so future pre-content timeouts can be attributed without inference.
