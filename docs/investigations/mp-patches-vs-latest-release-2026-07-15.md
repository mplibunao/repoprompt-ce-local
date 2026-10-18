# Investigation: MP patches versus the latest RepoPrompt CE release

> Investigation report, observed 2026-07-15 on the local patch branch, upstream `v1.0.29`, and upstream `main` at `f7b899d9`. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary
Continue using the current personal build only as a temporary bridge: stock `v1.0.29` and pinned `upstream/main` both lack four runtime fixes from the local patch branch (the wire-key, mirror-tail, waiter, and retry-drain patches). Replace it with a clean build based on official `v1.0.29`, carrying focused production-and-test ports in that order; the test-setup patch is an optional XCTest-only companion. The affected paths are identical between the release and main refs, so current main offers no patching advantage and would add unrelated unreleased change.

## Symptoms
- The current `MP patches` branch contains personal fixes that may or may not have reached upstream.
- The repository has a newer release, so continuing the personal build without comparison risks carrying redundant or conflicting patches.
- A release-build decision requires behavioral equivalence, not only matching commit hashes or file diffs.

## Background / Prior Research
- The official newest release is [RepoPrompt CE v1.0.29](https://github.com/repoprompt/repoprompt-ce/releases/tag/v1.0.29), published 2026-07-15 at commit [`fe68009b`](https://github.com/repoprompt/repoprompt-ce/commit/fe68009b80aa97bd4e15ec6b11d1cfb2728073be). The local annotated tag and peeled commit match the live upstream tag, and local `upstream/main` at `f7b899d9` matched live upstream when checked.
- The personal branch is the local patch branch. It diverged from upstream at `dd8a14ed` and is five commits ahead and 54 commits behind current `upstream/main`; the same five commits are unique relative to v1.0.29.
- All five commits are `+` under cherry-aware comparison. None is an exact patch-ID equivalent already merged to upstream main:
  1. Wire-key patch — correct Codex app-server text payload handling.
  2. Mirror-tail patch — bound and repair the selection mirror tail.
  3. Waiter patch — release invalidated auto-selection mirror waiters.
  4. Test-setup patch — synchronize selected-scope test setup.
  5. Retry-drain patch — drain MCP retry backoff cancellation safely.
- Three selection-related changes have equivalents in open upstream PR 472, not in v1.0.29 or upstream main. Two are stable patch-ID matches and one differs only through current ledger context.
- The Codex payload fix has a refined personal topic-branch equivalent but no upstream-main implementation. The retry-backoff fix has personal rebases and open upstream issue 513; a broader upstream PR 517 was proposed but is not present in either audited ref.
- Release notes mention adjacent Context Builder, selection packaging, workspace authority, and process-lifecycle work, including upstream PR 529, upstream PR 520, upstream PR 538, and upstream PR 539. Commit/path archaeology does not show those changes subsuming the five personal patches.

## Investigator Findings

### Decision matrix

| Commit | Invariant | Classification | `v1.0.29` | `upstream/main` |
| --- | --- | --- | --- | --- |
| Wire-key patch | Codex text input uses the generated `text_elements` wire key without dropping images | Runtime-required | Missing | Missing |
| Mirror-tail patch | One suspended selection mirror cannot wedge later window-scoped mutations indefinitely | Runtime-required | Missing | Missing |
| Waiter patch | Context invalidation releases its mirror waiters and fences late worker generations | Runtime-required after the mirror-tail patch | Missing | Missing |
| Test-setup patch | Selected-scope XCTest setup writes through canonical selection authority | Test-only synchronization | Optional test port | Optional test port |
| Retry-drain patch | MCP retry-backoff cancellation drains the suspended sleep outside the task-group child frame | Runtime-required workaround | Missing | Missing |

The four runtime fixes are independent except for the two selection patches: the waiter patch relies on the mirror-tail patch to keep physical UI mirror attempts serialized when an invalidated outer worker and its replacement briefly coexist.

### Ref and path baseline

- The audited refs resolve to the local patch branch head, `v1.0.29` `fe68009b80aa97bd4e15ec6b11d1cfb2728073be`, and `upstream/main` `f7b899d92e30217d7bec0e35aa993b779e59ffb9`.
- `git cherry` reports all five commits as unique against both target refs. This establishes absence by patch identity, not behavioral necessity.
- The behavioral comparison is stronger: `git diff v1.0.29 upstream/main` is empty across every affected production file, regression-test file, and `Scripts/Fixtures/test-suite-contract-ledger.tsv`. The two target bases therefore have the same owning implementations and tests.
- The MP stack is based at `dd8a14ed`. From `dd8a14ed` to `v1.0.29`, only the contract ledger and two unrelated lines in `Sources/RepoPromptMCP/main.swift` changed among the affected paths. The four runtime call sites and their test files did not move.
- The current-main replay risk is consequently not higher than the release replay risk at these boundaries. The material risks are stale ledger context, the semantic coupling between the selection patches, and the retry workaround's narrow scope.

### Wire-key patch — Codex app-server text serialization

**Invariant and failure.** Both `turn/start` and `turn/steer` must pass text entries using the generated app-server key `text_elements`. The stale `textElements` shape is rejected by direct app-server probing and can leave RepoPrompt waiting for a terminal event because `turn/start` intentionally has no general reasoning timeout.

**Production path.** On the MP branch, `startUserTurn` and `steerUserTurn` both call the sole dictionary encoder at `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1350-1419`; `turnInput` preserves URL and local-image entries and emits `text_elements` at `:1603-1636`. Both target refs retain the same calls at `:1350-1419` but emit `textElements` at `v1.0.29:Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1603-1636` and `upstream/main:Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1603-1636`.

**Regression coverage.** The MP tests cover start and steer payloads at `Tests/RepoPromptTests/AI/CodexNativeSessionControllerTurnDispatchTests.swift:6-68`, mixed URL/local-image ordering at `:70-98`, and an exact negative assertion rejecting `textElements` at `:331-338`. This deterministic wire contract does not need a race test. The remaining gap is a live app-server schema smoke; the prior direct probe is recorded at `docs/investigations/repo-prompt-codex-agent-hang-2026-07-08.md:22-38`.

**Eliminated alternatives.** Commit `1ab555e6` changes Codex process startup, environment capture, and memory-mode readiness, not `turnInput`. No secondary encoder, generated request adapter, or normalization layer exists on either base.

**Replay risk.** The one-line production change and focused tests have low textual and semantic risk on both bases. Replaying the wire-key patch wholesale has medium repository risk because it includes a historical contract-ledger row. Use the ledger-free two-file content represented by `dbf69f55`, then add any required current ledger entry through the repository's authoritative test-list workflow.

### Mirror-tail patch — Bounded, superseding selection mirror tail

**Invariant and failure.** A suspended `applySelectionMirrorAttempt` must not make every later mutating selection request in the window await the same predecessor forever.

**Production path.** Both target refs define a tail containing only an ID, target, and task at `v1.0.29:Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:156-172` and the identical upstream-main lines. Their enqueue path awaits the predecessor and then the new task without a timeout or supersession signal at `:614-655`; repair remains chained through `:660-731`. The MP implementation adds the independent wait signal and ten-second bound at `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:156-209`, then implements cancel-on-supersede, bounded caller release, serialized latest-target repair, and generation-safe completion at `:635-824`.

**Regression coverage.** Positive serialization is covered at `Tests/RepoPromptTests/WorkspaceContext/WorkspaceSelectionCoordinatorTests.swift:68-116`; churn and ABA stale-target repair at `:117-187`; negative/no-op and caller-cancellation behavior at `:188-243`; supersession at `:244-285`; cooperative timeout at `:286-326`; and uncooperative timeout, bounded callers, one-at-a-time application, and eventual repair at `:327-412`. Peer closure is separately fenced at `:637-707`.

**Remaining limit.** If the underlying UI apply ignores cancellation forever, callers return within the bound and canonical selection advances, but physical UI repair still waits for that predecessor to exit. The implementation deliberately preserves one-at-a-time UI mutation instead of starting an overlapping repair.

**Eliminated alternatives.** Commit `610c1306` created the serialized mirror ordering but also created the unbounded predecessor chain. Commit `dadd4b06` adds a canonical presentation fence at `dadd4b06:Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:260-278`; `5a714a9f` generalizes its documentation. Neither bounds the tail. Commits `674a00d3` and `01c269b6` address mutation-ingress progress without touching this coordinator. Transport timeout recovery only releases the external caller; it cannot retire the internal tail.

**Replay risk.** Textual risk is low because the target refs contain identical coordinator and test files. Semantic risk is high because timeout, supersession, completion ownership, latest-target repair, and peer fencing form one state machine. Port the complete production-and-test behavior rather than the historical commit's ledger hunk.

### Waiter patch — Invalidation-safe auto-selection waiters

**Invariant and failure.** Invalidating a context must cancel only that context's ticket waiters, retire its worker generation, permit a replacement context to progress, and prevent late completion from advancing the replacement lane.

**Production path.** Both target refs wait on a tab-scoped ticket without recording its originating context at `v1.0.29:Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift:585-600`; invalidation at `:616-623` does not resume mirror waiters. Worker ownership is stored separately at `:954-1000`, while waiters at `:1065-1128` have no context identity and lane cleanup at `:1208-1215` refuses a parked worker. The upstream-main file is identical. The MP implementation passes the context into the waiter and cancels it during invalidation at `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift:585-633`, owns workers by generation and fences late completion at `:964-1020`, stores context-aware waiters and cancels them selectively at `:1083-1176`, and reclaims the old worker/lane at `:1240-1263`.

**Regression coverage.** Existing positive and caller-cancellation coverage spans `Tests/RepoPromptTests/MCP/MCPReadFileAutoSelectionCoordinatorTests.swift:225-480`. The patch adds parked-waiter invalidation and full lane/worker reclamation at `:610-657`, plus a replacement context progressing while the old worker is parked and rejecting late old-generation completion at `:658-717`.

**Remaining limit.** Replacement outer workers can briefly coexist when an invalidated apply ignores cancellation. Correctness depends on the worker-ID fence at `MCPReadFileAutoSelectionCoordinator.swift:1011-1014` and the inner serialization supplied by the mirror-tail patch.

**Eliminated alternatives.** Canonical-selection and Context Builder packaging changes do not attach context ownership to mirror waiters. Removing the outer worker guard without the paired inner-tail fix would allow overlapping UI mutation and is unsafe.

**Replay risk.** Textual risk is low and semantic risk is medium-high on both bases. Apply after the mirror-tail patch; never reverse the order or port the waiter cleanup alone.

### Test-setup patch — Selected-scope test synchronization

**Scope proof.** The test-setup patch changes only `Tests/RepoPromptTests/MCP/MCPCodeStructureWorktreeTests.swift` by 22 insertions and three deletions. No source, package, resource, or executable target changes.

**Test behavior.** Both target refs directly mutate a compose-tab copy at `v1.0.29:Tests/RepoPromptTests/MCP/MCPCodeStructureWorktreeTests.swift:619-642` and the identical upstream-main lines. The MP test instead constructs a canonical identity, calls `persistSelection`, and asserts the snapshot before and after the selected-scope budget check at `Tests/RepoPromptTests/MCP/MCPCodeStructureWorktreeTests.swift:619-711`. The required production APIs already exist at `v1.0.29:Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:280-328` and the identical upstream-main lines.

**Coverage classification.** The test positively verifies canonical fixture setup, negatively verifies `limit + 1` rejection without content/codemap work, and asserts selection remains unchanged. It removes detached-copy/timing ambiguity but does not add a runtime race or shipped behavior.

**Replay risk and disposition.** Risk is low on both bases. Omit it from runtime builds. Port the test-setup patch or its exact patch-equivalent `37047b39` only when carrying the affected selected-scope regression.

### Retry-drain patch — MCP retry-backoff cancellation drain

**Invariant and failure.** When one `MCPService.run()` child wins, task-group cancellation must not tear down the transport child while its retry sleep frame is resuming. Historical crash-symbol mapping identifies the retry backoff as the `swift_task_dealloc` site; the evidence and confidence limits are recorded at `docs/investigations/codex-appserver-and-issue-triage-2026-07-12.md:88-103`.

**Production path.** Both target refs keep `runTransport()` inside the three-child throwing task group at `v1.0.29:Sources/RepoPromptMCP/main.swift:2113-2155` and suspend directly in `Task.sleep` at `:2263-2320`; upstream main is identical at those lines. Neither ref contains `MCPRetryBackoffWait.swift`. The MP branch retains the same enclosing group at `Sources/RepoPromptMCP/main.swift:2113-2155`, moves the sleep behind the helper at `:2263-2319`, and explicitly forwards cancellation to an owned sleep task while awaiting settlement at `Sources/RepoPromptMCP/MCPRetryBackoffWait.swift:3-21`.

**Regression coverage.** Normal delay forwarding and settlement are covered at `Tests/RepoPromptTests/MCP/MCPRetryBackoffWaitTests.swift:6-26`; cancellation drains 100 independently suspended sleeps at `:28-52`. Remaining gaps are cancellation before the injected sleep reports startup, a deliberately non-cooperative sleep, and an integration test through the full `MCPService.run()` race.

**Eliminated alternatives.** No explicit-task replacement for `MCPService.run()` is present in either audited ref; both still contain the triggering task group and direct backoff sleep. Adjacent transport, kill-signal, and parent-watchdog changes do not relocate this suspension point.

**Replay risk.** The call-site and helper have low textual risk on both bases. Semantic risk is medium: this is a targeted Swift-runtime/code-generation workaround, not a proof that every transport suspension point is teardown-safe. The historical and topic commits also carry two ledger rows, so port the helper, one-line call site, and focused tests, then reconcile the current ledger separately.

### Historical versus refined/topic equivalents

| Behavior | Historical commit | Refined/topic evidence | Safe source |
| --- | --- | --- | --- |
| Codex wire key | Wire-key patch, including ledger | A rebased topic commit has the same patch ID; `dbf69f55` omits only the ledger row | `dbf69f55` production/test content |
| Bounded mirror tail | Mirror-tail patch | `d8d47126` has identical source/test changes; its patch-ID difference is ledger context only | Complete source/test state-machine port |
| Waiter invalidation | Waiter patch | `57a3f408` has the same patch ID | Complete source/test port after the bounded tail |
| Selected-scope setup | Test-setup patch | `37047b39` has the same patch ID | Optional single-test port |
| Retry drain | Retry-drain patch | Two rebased topic commits have the same patch ID | Helper, call site, and tests without historical ledger replay |

The MP stack is already rebased onto `dd8a14ed`, while the selection PR topic starts at older `6ceafd39`. The topic commits are useful semantic references, but they are not categorically safer cherry-picks. The safest method on either target is to port the named production-and-test behavior and update the current ledger surgically.

### Per-base replay risks

| Commit | `v1.0.29` risk | `upstream/main` risk | Disposition |
| --- | --- | --- | --- |
| Wire-key patch | Low source/test; medium whole-commit ledger risk | Same | Include ledger-free refined equivalent |
| Mirror-tail patch | Low textual; high concurrency/state-machine risk; medium whole-commit ledger risk | Same | Include complete source/test equivalent |
| Waiter patch | Low textual; medium-high semantic dependency risk | Same | Include after the mirror-tail patch |
| Test-setup patch | Low, test-only | Same | Exclude from runtime; optional test companion |
| Retry-drain patch | Low textual; medium narrow-workaround and ledger risk | Same | Include focused helper/call-site/test equivalent |

### Minimal ordered patch recommendation

#### `v1.0.29` local build

Runtime patches:

1. Port the ledger-free Codex production/test change from `dbf69f55`.
2. Port the full bounded and superseding mirror-tail behavior from the mirror-tail patch/`d8d47126`, preserving peer fences and latest-target repair.
3. Port the context-owned waiter cancellation and worker-generation fencing from the waiter patch/`57a3f408`.
4. Port the retry helper, call-site swap, and tests from the retry-drain patch or its rebased topic commit.

Test-only companion:

5. Port the test-setup patch/`37047b39` only if the selected-scope test is carried.

Ledger-only handling:

- Add current ledger rows only after the target branch's authoritative test list confirms the final method IDs. Do not replay historical ledger context as part of the runtime patches.

#### `upstream/main` local build

Use the same four runtime ports in the same order. The affected paths are identical to `v1.0.29` at `f7b899d9`, so no different current-main architecture is required. Rebase each focused port onto the target ref and keep the same optional test-only and ledger-only handling.

### Maintainer-guidance check

- **User impact and invariant:** prevent Codex turns from using an invalid wire shape, prevent selection windows from remaining permanently wedged, and prevent MCP bridge teardown crashes.
- **Root-cause confidence:** confirmed for the wire key and test-only scope; high for the two selection lifecycle gaps; medium-high for the retry crash trigger because the source trigger and crash frame are known but were not dynamically replayed on the two target builds.
- **Authority:** generated Codex app-server schema, `WorkspaceSelectionCoordinator`, `MCPReadFileAutoSelectionCoordinator`, and `MCPService.run()/runTransport()`.
- **State-safety risks:** the selection patches must stay ordered and preserve one-at-a-time UI mutation; stale ledger replay must not overwrite the curated test inventory.
- **Scale and observability risks:** the bounded tail prevents one suspended apply from amplifying into a window-wide queue; the retry workaround remains narrow and needs integration-level crash observation.
- **Recommended scope:** carry four focused runtime ports; keep the test-setup patch test-only; do not introduce compatibility shims or parallel selection authorities.
- **Validation boundary:** focused wire, selection, waiter, and retry suites plus one live Codex schema smoke, one end-to-end selection lifecycle harness, and one MCP task-group cancellation harness.

## Investigation Log

### Phase 1 - Initial assessment and verification design
**Hypothesis:** Some personal commits are now redundant, while others may remain necessary or may have been superseded by different upstream implementations.

**Findings:** The comparison must establish the exact personal branch, latest release ref, ancestry, patch inventory, behavioral intent, test coverage, and release/build implications.

**Evidence:** User-provided repository state and requested comparison.

**Conclusion:** Compare patch intent and runtime behavior, not only raw diffs.

### Verification strategy
1. Map each MP-only commit to upstream by exact ancestry, cherry/patched equivalence, and changed-file overlap.
2. Trace each surviving behavioral fix through current production paths to detect upstream solutions implemented differently.
3. Compare regression tests and invariants for every personal fix, including negative and lifecycle edge cases.
4. Cross-check the latest release tag against branch ancestry and packaging/build configuration so the recommendation targets the actual released code.

### Phase 2 - Context Builder ownership
**Hypothesis:** After explore-session cleanup, Context Builder could seed the selection for behavioral analysis.

**Findings:** Both required `context_builder` attempts failed with `DiscoverAgent Code=2: Context Builder is already MCP-controlled for this tab`. `agent_manage list_sessions` reported zero managed sessions before the retry.

**Evidence:** The first call used the full report-informed investigation prompt; the second call retried after cleanup and a delay with a reduced prompt. Both returned the same ownership error.

**Conclusion:** The tab-level ownership collision blocked that Context Builder attempt. It did not establish or refute behavioral equivalence.

### Phase 3 - Ref-specific production, test, and replay audit
**Hypothesis:** The four runtime invariants remain absent on both target refs, while the test-setup patch changes only test synchronization.

**Findings:** Ref-specific reads found the stale Codex key, unbounded selection tail, invalidation-unaware waiters, and direct retry sleep on both targets. The affected paths are identical between `v1.0.29` and `upstream/main`. Commit and range comparison isolated ledger context from the production-and-test changes.

**Evidence:** Exact call paths, line ranges, patch IDs, eliminated adjacent changes, coverage classifications, and per-base risks are recorded under Investigator Findings.

**Conclusion:** Both target bases need the same four focused runtime ports in the documented order. The selected-scope synchronization remains test-only.

### Phase 4 - Oracle synthesis and product decision
**Hypothesis:** The safest replacement build uses the official release as its base and ports only the missing behavior.

**Findings:** Oracle synthesis agreed that the existing personal build prevents real regressions and should remain in use only until a clean replacement is validated. Official `v1.0.29` is the lower-risk base because current main has no relevant path differences. A blind retry-patch replay can also restore the old branch's `CLI_VERSION = "1.0.28"`; the replacement must retain all `v1.0.29` version and packaging metadata.

**Evidence:** Ref-specific path comparison, the pair's invariant matrix, focused Git patch inspection, and the curated Oracle selection all converge on the same four runtime ports and one test-only companion.

**Conclusion:** Build the replacement from `v1.0.29`, port behavior rather than whole historical commits, and adopt it only after focused, full-suite, and live lifecycle validation.

### Phase 5 - Final validation
**Findings:** RepoPrompt Git confirmed zero affected-path differences between `v1.0.29` and upstream main, the exact Codex key change, the focused retry helper/call-site delta, and the one-test-file scope of the test-setup patch. Repository status shows no tracked or source modifications.

**Prose review:** The repository has no dedicated prose target. Vale reported numerous findings dominated by technical identifiers, commit terminology, code vocabulary, and generic style rules. Those rewrites were rejected because they would make the evidence less precise.

**Conclusion:** Static investigation evidence is internally consistent. Dynamic build and runtime validation belongs to the subsequent implementation phase.

## Root Cause
The target refs retain four distinct production defects: a stale Codex wire key, an unbounded serialized selection-mirror tail, invalidation-unaware mirror waiters, and a retry sleep suspended in the MCP task-group child frame implicated by teardown crashes. The fifth commit repairs only a test fixture that bypasses canonical selection authority.

## Recommendations
1. Keep the current personal build in daily use until a validated replacement exists; an unpatched official build would reintroduce the four runtime defects.
2. Base the replacement on official `v1.0.29` at `fe68009b`, not current main, unless an unrelated post-release feature is explicitly required.
3. Follow the existing minimal ordered patch list: Codex wire key, bounded selection tail, invalidation-safe waiters, then retry-backoff drain. Preserve the semantic coupling between the two selection patches.
4. Treat the test-setup patch as an optional test-only companion. Reconcile ledger entries from the target branch's authoritative test list rather than replaying historical ledger hunks.
5. Preserve `v1.0.29` release metadata, especially `CLI_VERSION`; port only the retry helper, call-site change, and focused tests.

## Preventive Measures
- Compare RepoPrompt's hand-built Codex payload against a generated or live app-server schema in a focused smoke.
- Exercise selection timeout, invalidation, replacement generation, and eventual repair through a full tool-lifecycle harness, not only coordinator unit tests.
- Exercise MCP service cancellation while transport is in backoff and assert all owned tasks settle without a crash.
- Use ref-specific path diffs, range-diff, and stable patch IDs together; none alone proves behavioral equivalence.
