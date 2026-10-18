# Investigation: Upstream PR 472 Independent Scope and Maintainer-Feedback Audit

> Investigation report, observed 2026-08-25 on upstream PR 472 at `621b6b75`. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary
**Verdict: SIMPLIFY.** The published reconstruction at `621b6b75` is materially larger than the old patch, but its core bounded inner pump, exact outer ownership/in-flight transfer, typed outcomes, dual-layer deadlines, and physical-retirement accounting are necessary to satisfy upstream issue 457 and the maintainers’ non-cooperative-worker/reclamation requests. Do not restore the old predecessor-chain design. Remove three proven redundancies in one additive cleanup commit, then obtain fresh focused human concurrency review because the reconstruction supersedes the design maintainers previously examined.

## Symptoms
- The requested task was to refresh and finish an existing reviewed PR, but the published reconstruction materially changed the implementation.
- The original patch was 6 files (`+535/-97`); the reconstruction is 10 files (`+1177/-153`).
- Maintainers described the original design as directionally sound and requested rebase/current-main validation, focused concurrency review, stress, reclamation, and immediate deadline cancellation.
- The reconstruction replaced core mechanics with a bounded pump, expanded ownership/lifecycle accounting, and added substantial tests and diagnostics without a clearly surfaced scope-decision checkpoint.
- The user no longer trusts the prior investigation’s conclusions and needs an independent evidence-based keep/simplify/replace recommendation.

## Background / Prior Research

### Authoritative GitHub record
- Upstream issue 457 remains open and scopes recovery to the window-scoped selection-mirror wedge: bounded/supersedable mirror waits, invalidation release of context-owned waiters, invalidated-lane reclamation, later mutation progress, and focused timeout/invalidation/read regression coverage.
- Upstream PR 472 remains open at `621b6b75b01604b5e8b48bba6c9ac73296e05294`, with no formal human approval and hosted CI 7/8 green.
- Maintainer A (a comment on upstream PR 472) said the goal remained valuable, warned there was no human review of the substantial cancellation/generation-fencing change, and requested current-main refresh, focused ownership/concurrency review, and exact-head checks.
- A collaborator (a comment on upstream PR 472) called the original design coherent and requested current-main refresh, sustained timeout/cancellation/reordering stress, repeated supersession/context invalidation, and proof that retired completion/deadline tasks are reclaimed promptly.
- The same collaborator's follow-up (a comment on upstream PR 472) called the design directionally sound and explicitly requested a non-cooperating old worker, replacement-context progress, eventual lane reclamation, and immediate cancellation of completed deadline tasks.
- Maintainers did not request unrelated Context Builder fixes, broad cleanup, parallel physical mirror workers, or pretending cancellation destroys a non-cooperating task. Their comments were conditional endorsements, not formal approval.

### Original patch archaeology (`6ceafd39..37047b39`)
- `d8d47126` added per-tail worker/timeout/signal state, bounded caller waits, cooperative supersession, latest-target repair, and tests for supersession, timeout repair, and a cancellation-ignoring gate.
- It deliberately retained physical serialization by making every new worker await its predecessor. Therefore caller latency was bounded, but sustained churn behind one non-cooperating apply could retain an uncompressed chain of cancelled/parked tasks.
- `57a3f408` added worker IDs/tasks, exact invalidation of context-owned waiters, and post-apply/defer generation checks. It could logically remove a parked worker and start a replacement before the old physical apply exited; generation fences protected bookkeeping but not overlapping external UI side effects.
- Queued mirror batches lacked originating context ownership, the worker did not check invalidation before calling `applyMirror`, and mirror drains had no independent deadline.
- `37047b39` was test-only selected-scope setup and did not affect production liveness.

### Published reconstruction archaeology (`44774ffa..621b6b75`)
- Four commits: `cb8cd1c8` inner ownership redesign, `d5800082` outer ownership/settlement redesign, `9ab7c673` lifecycle stress/integration tests, and `621b6b75` deterministic test scheduling.
- Aggregate delta is 10 files, approximately `+1177/-153`. Core production redesign is concentrated in `WorkspaceSelectionCoordinator.swift` and `MCPReadFileAutoSelectionCoordinator.swift`; roughly 600 added lines are tests.
- Inner additions: one active physical worker plus one latest pending demand, per-request waiters/deadlines, typed converged/deferred/invalidated/cancelled outcomes, exact worker/revision/context/peer fences, repair promotion, and physical/deadline lifecycle accounting.
- Outer additions: exact per-context ownership of tab work, in-flight state, lane generations, retired-worker tracking until physical exit, waiter deadlines, exact terminal settlement ranges, same-tab survivor requeue, later-convergence upgrades, and bounded settlement-history pruning.
- Compatibility wiring propagates typed outcomes through `WorkspaceManagerViewModel`, `MCPServerViewModel`, tab-context cleanup, diagnostics, and mocks.
- Tests add 100-demand parked-worker stress, 30 terminal-event iterations, 50 invalidation/replacement cycles, 64 settlement-history cycles, same-tab ownership transfer, immediate deadline cancellation, and persistent connection-removal reclamation.
- Explorers made no builds, tests, checkouts, source edits, app launches, or GitHub mutations.

## Investigator Findings

### Executive verdict: **SIMPLIFY**

From an upstream maintainer/public-contributor perspective, the reconstruction should **not** be replaced by a refreshed copy of the old predecessor-chain patch. The old design bounds each caller but does not bound retained tasks under sustained churn, cannot transfer exact same-tab ownership after dequeue, and reports a parked outer worker as reclaimed before its task exits. Those are precisely the gaps raised by the maintainers' non-cooperative-worker, replacement-progress, and reclamation requests.

The reconstruction's core architecture is therefore earned: one inner physical worker plus one replaceable latest demand; exact outer context ownership; explicit in-flight state; pre-dequeue and post-suspension worker fencing; typed outcomes; bounded waiters; and honest retired-worker accounting. The published implementation is nevertheless larger than the invariant requires. Four reductions are supported by the code rather than by diff-size preference:

1. use the inner demand's unique `requestID` as its worker fence instead of allocating a second ID;
2. use the outer worker UUID as the generation token instead of also storing/incrementing a numeric generation;
3. do not store `.converged` settlement ranges because `convergedTicket` resolves them first; and
4. centralize the duplicated inner deadline/caller-cancellation settle-cancel-repair transition.

Retired outer work must remain represented until physical exit, but a retired-worker ID set/counter is sufficient after cancellation; retaining every `Task` handle is a defensible observability choice, not a safety prerequisite. The post-`Task.yield()` ownership guard is also redundant with the next loop's identical guard.

This is a **SIMPLIFY**, not **REPLACE**, recommendation: narrow the current-main reconstruction without returning to the old ownership model.

### Evidence standard and public record

- Upstream issue 457 explicitly requires bounded/cancel-on-supersede mirror work, invalidation release of parked waiters, lane self-healing/reclamation, later same-window mutation progress, and regression coverage for over-bound apply, invalidation, later mutation, and unaffected `op=get`.
- Maintainer A (a comment on upstream PR 472) requested a current-main refresh, focused ownership/concurrency review, and exact-head checks because the cancellation/generation change had no human review.
- The collaborator (a comment on upstream PR 472) called the timeout/generation/invalidation/reclamation design coherent, then requested sustained timeout/cancellation/reordering stress, repeated supersession/invalidation, and prompt retirement of completion/deadline tasks.
- The collaborator's follow-up (a comment on upstream PR 472) specifically requested one active physical mirror application, a non-cooperating old worker, replacement-context progress, eventual lane reclamation, and immediate cancellation of completed deadline tasks.
- These are conditional endorsements and acceptance demands, not approval of any particular data structure. The audit therefore distinguishes the requested property from the reconstruction's representation of it.

The exact inspected ranges were old `6ceafd393ea7630dfee65dd5e8d2c9f109527f27..37047b3900d9b49eed277e0a7fe6481d4c738ade` and reconstruction `44774ffafc74dc22696cd9bf6189f6650a9cc1a0..621b6b75b01604b5e8b48bba6c9ac73296e05294`. No prior `pr-472-finish-line` report or prior-agent conclusion was used.

### Maintainer request → old implementation → reconstruction → minimality

| Requested property | Old implementation | Reconstruction | Minimality classification |
| --- | --- | --- | --- |
| Bound a mirror request and supersede stale work | `d8d47126`; at old head `WorkspaceSelectionCoordinator.swift:618-669`, every request creates a task, timeout task, and signal, and the task awaits `predecessor?.value` at `:629`. Supersession at `:672-680` cancels/releases the logical caller only. | `cb8cd1c8`; at head `WorkspaceSelectionCoordinator.swift:182-208,1023-1117`, one worker is retained until physical exit and only one latest pending demand is replaceable. | **Explicitly requested and technically necessary.** Old caller latency is bounded, but retained work is O(churn), not O(1). |
| Preserve a single active physical UI mirror under a non-cooperative apply | The predecessor chain serializes actual applies, but retains one task per demand and unwinds the chain only after the parked predecessor exits (`37047b39:WorkspaceSelectionCoordinator.swift:618-760`). | The inner pump starts a successor only after `selectionMirrorWorkerExited` clears the physical slot (`621b6b75:WorkspaceSelectionCoordinator.swift:1077-1155`). The 100-demand test proves one physical worker/one pending demand (`WorkspaceSelectionCoordinatorTests.swift:254-315`). | **Technically necessary architecture.** Do not restore the chain. Worker ID representation is reducible. |
| Release invalidated context-owned waiters | Old outer waiters carry `ContextKey` and invalidation cancels matching mirror waiters (`37047b39:MCPReadFileAutoSelectionCoordinator.swift:390-394,625-633,1083-1175`), but canonical waiters are not distinctly invalidated. | Exact canonical and mirror settlement returns `.invalidated` and cancels deadlines (`621b6b75:MCPReadFileAutoSelectionCoordinator.swift:737-746,1267-1432`). | **Explicitly requested and technically necessary.** Typed invalidation is preferable to reporting teardown as generic caller cancellation. |
| Do not lose same-tab survivor work when one route invalidates | Old `QueuedMirrorBatch` has no owners and `MirrorLane` has no `inFlight` (`37047b39:MCPReadFileAutoSelectionCoordinator.swift:404-415`). After dequeue, ownership cannot be reconstructed. | `owners`, `inFlight`, exact owner stripping, and survivor union/requeue (`621b6b75:MCPReadFileAutoSelectionCoordinator.swift:480-495,1040-1078,1435-1476`); focused test at `MCPReadFileAutoSelectionCoordinatorTests.swift:1015-1057`. | **Technically necessary.** An outer generation counter alone cannot answer which same-tab work survives. |
| Permit replacement progress without letting an old completion mutate replacement state | Old cleanup cancels/removes the worker record and lane even while its callback is suspended (`37047b39:MCPReadFileAutoSelectionCoordinator.swift:1240-1262`). Its post-await UUID check at `:1011-1013` protects the high-water mark but not exact ownership or lifecycle accounting. | Retirement revokes active ownership, requeues survivors, starts a replacement, and fences completion before dequeue and after suspension (`621b6b75:MCPReadFileAutoSelectionCoordinator.swift:1090-1169,1435-1476`). | **Explicitly requested semantics; technically necessary.** UUID fencing is sufficient; the additional numeric generation is redundant. |
| Do not pretend cancellation destroyed a non-cooperative physical task; prove reclamation | The old test asserts worker/lane counts are zero before releasing the parked callback (`37047b39:MCPReadFileAutoSelectionCoordinatorTests.swift:610-655`), exactly the logical-versus-physical accounting gap. | Retired task state persists until the task body's `defer` removes it (`621b6b75:MCPReadFileAutoSelectionCoordinator.swift:518-520,1111-1126,1448-1453`); 50-cycle stress checks eventual zero state (`MCPReadFileAutoSelectionCoordinatorTests.swift:1059-1112`). | **Explicitly requested lifecycle fact.** Tracking until exit is necessary; retaining the task handle rather than an ID/count is optional. |
| Bound the outer mirror-ticket drain and retire deadline tasks immediately | Old outer `waitForMirrorTicket` has cancellation handling but no deadline (`37047b39:MCPReadFileAutoSelectionCoordinator.swift:1083-1121`). | Per-waiter deadlines are installed/cancelled at `621b6b75:MCPReadFileAutoSelectionCoordinator.swift:1310-1432`; `finish` returns `.deferred` at the deadline and later reclamation is tested at `MCPReadFileAutoSelectionCoordinatorTests.swift:862-893`. | **Explicitly requested and technically necessary.** The inner bound alone does not protect an outer worker suspended before or around the inner call. |
| Cancel completed deadline tasks immediately | Old tail deadlines are cancelled on exact tail completion, but the old tests do not prove lifecycle equality under sustained races. | Inner deadlines are removed/cancelled on settlement (`621b6b75:WorkspaceSelectionCoordinator.swift:1201-1208`); early 30-second deadline cancellation is tested at `WorkspaceSelectionCoordinatorTests.swift:317-345`, and 30 terminal-race iterations at `:371-430`. | **Explicitly requested.** Counters are optional instrumentation; the behavior is not. |
| Keep `manage_selection get` independent of mirror completion | The read-only drain remains canonical-only. | The reconstruction preserves that routing. Existing current-main integration coverage explicitly waits for canonical persistence and asserts `get` returns while the mirror is blocked (`621b6b75:PersistentAgentModeMCPReadFileConnectionTests.swift:1898-1981`). | **Acceptance invariant already covered.** Adding another reconstruction-specific `get` test would be duplicative. |
| Refresh to current main and validate exact head | Old head is based on `6ceafd39`; its third commit `37047b39` is only selected-scope test setup. | Reconstruction is based on `44774ffa` and ends at `621b6b75`; `cb8cd1c8` and `d5800082` contain production redesign, `9ab7c673` tests it, and `621b6b75` removes a test race. | **Explicitly requested process.** This read-only audit did not rerun the already-reported validation. |

### 1. Inner bounded worker/latest-demand design

**Proved necessary; the old predecessor chain is insufficient.**

At old head, every enqueue captures the current tail as a predecessor and creates a new task (`WorkspaceSelectionCoordinator.swift:683-723`). Timeout/supersession releases callers, but each cancelled successor remains parked on `await predecessor?.value` (`:629`). With one cancellation-ignoring apply and N new demands, the old code retains O(N) task bodies/captures until the predecessor exits. The old uncooperative test submits only one successor (`37047b39:WorkspaceSelectionCoordinatorTests.swift:327-390`), so it cannot establish the sustained-churn reclamation requested by the maintainer.

The reconstructed pump has only `mcpSelectionMirrorWorker` and `pendingMCPSelectionMirrorDemand` (`621b6b75:WorkspaceSelectionCoordinator.swift:205-206`). A new demand replaces/settles the old pending demand and cancels the active task cooperatively without starting another (`:1064-1075`). Only physical exit clears the slot and promotes the latest pending demand or a synthesized latest-target repair (`:1120-1155`). The state bound is independent of request count: at most one physical apply, one pending latest demand, and the live waiter/deadline entries that have not already been settled.

The exact minimum inner state machine is:

1. `idle` or `running(activeDemand, physicalTask, pendingLatest?)`;
2. request-ID keyed continuation and deadline records;
3. enqueue while running settles the prior pending/active logical caller, cancels cooperatively, and replaces `pendingLatest` without clearing physical ownership;
4. deadline/caller cancellation settles exactly once, cancels its deadline immediately, and installs a latest-target repair only if no newer pending demand exists;
5. worker entry validates target/revision/peer ownership before apply, and worker exit validates active ownership/target/peer/cancellation after suspension before declaring convergence; and
6. only physical exit clears the worker slot and promotes pending work.

The reconstruction implements those invariants at `WorkspaceSelectionCoordinator.swift:1023-1208`. It does not need two identities for one demand: `requestID` is allocated for every direct and repair demand (`:1028-1034,1145-1150,1167-1172,1191-1196`), a demand starts at most once, and `startSelectionMirrorWorker` unnecessarily allocates another ID at `:1079`. Reusing `demand.requestID` preserves every fence.

Likewise, `selectionMirrorDeadlineFired` (`:1158-1175`) and `cancelSelectionMirrorRequest` (`:1183-1199`) duplicate the same settle-active-cancel-install-repair transition. One helper parameterized by terminal outcome and deadline accounting is smaller and easier to prove exactly-once.

### 2. Outer ownership, fencing, and physical retirement

**Exact ownership/in-flight/fences are necessary; their current representation can be smaller.**

The old outer patch partially solved invalidation: a waiter owns a `ContextKey`, a worker UUID fences late high-water mutation, and a replacement can be scheduled. It did not record who owned a queued/dequeued batch, and cleanup could remove the only worker record while its task remained suspended. The old replacement test deliberately observes two outer callback invocations before releasing the first (`37047b39:MCPReadFileAutoSelectionCoordinatorTests.swift:658-715`), while the old reclamation test reports zero workers before physical release (`:610-655`). Thus old logical reclamation is not physical reclamation.

For a same-tab batch owned by `{A, B}`, invalidating A must settle only A's waiter. If the batch is pending, A can be removed and B retained. If it is in flight and the lane is revoked, B's demand must be requeued and the retired callback must be unable to settle B's ticket. That is impossible without exact owners plus explicit in-flight state. The reconstruction supplies both and performs this transition at `621b6b75:MCPReadFileAutoSelectionCoordinator.swift:1435-1476`.

The pre-dequeue and post-suspension worker-token checks are also load-bearing. All state is `@MainActor`, so checking the active UUID before moving pending work to `inFlight` and again after `await applyMirror` is sufficient to keep a retired callback from completing replacement state (`:1111-1169`). The separate `MirrorLane.generation`/`MirrorWorker.generation` fields (`:491,504-507`) and increment/capture plumbing (`:1095-1103,1449`) cannot distinguish a reachable state that the fresh UUID does not already distinguish. Remove the numeric counter, but keep the conceptual generation fence via the unique worker token. The guard after `Task.yield` at `:1161` is also repeated by the next loop condition at `:1129`.

Important limitation: the outer reconstruction still permits two **outer callback bodies** to overlap; its own focused replacement test observes two invocations before the first gate releases (`621b6b75:MCPReadFileAutoSelectionCoordinatorTests.swift:804-860`). Outer retirement protects outer state; it does not serialize arbitrary side effects. Production safety is compositional:

- the standard callback delegates through `MCPServerViewModel.swift:1843-1872` and `WorkspaceManagerViewModel.swift:5383-5405` into the inner one-physical-worker pump; and
- the worktree-only branch updates presentation from current canonical state (`MCPServerViewModel.swift:1855-1869`), an intended idempotent latest-state operation.

Therefore “one physical mirror application” is an inner invariant. Outer retired-worker tracking is necessary to report and fence still-live callback tasks honestly, not to claim they do not overlap. A minimal outer implementation can cancel/remove the active task, add its UUID to a retired-ID set, and remove the UUID in the task's `defer`; retaining the `Task` in `retiredMirrorWorkerTasks` is not otherwise used for safety.

### 3. Outcomes, deadlines, settlement, diagnostics, and wiring

#### Typed outcomes — **technically necessary**

The old `ApplyMirror -> Void` path advances the outer ticket after the inner logical waiter returns, even when timeout/cancellation did not produce UI convergence. That can turn a bounded failure into a false success. The reconstructed `SelectionMirrorOutcome` (`621b6b75:WorkspaceSelectionCoordinator.swift:175-180`) and outer `SequenceWaitResult` (`MCPReadFileAutoSelectionCoordinator.swift:454-459`) distinguish:

- `.converged`: the exact target survived post-suspension fences;
- `.deferred`: the caller was bounded but repair/convergence remains outstanding;
- `.invalidated`: exact context/target ownership ended; and
- `.cancelled`: the caller/task cancelled.

The drain mapping at `MCPReadFileAutoSelectionCoordinator.swift:676-723` prevents `.deferred` from becoming `.completed`, while tab teardown suppresses commit for `.cancelled` and `.invalidated` (`MCPServerViewModel+TabContext.swift:4326-4339`). Collapsing the four cases would either reintroduce false completion or erase exact invalidation/caller-cancellation semantics. Keep the enum internal, but keep the distinctions.

#### Waiter deadlines — **explicitly requested and technically necessary**

The inner deadline bounds the actual UI-mirror request. The outer deadline independently bounds a drain parked on a mirror ticket, including suspension before the inner coordinator is reached. Both must cancel their deadline tasks immediately on settlement. The new inner lifecycle code is at `WorkspaceSelectionCoordinator.swift:1035-1061,1158-1208`; the new outer waiter deadline is at `MCPReadFileAutoSelectionCoordinator.swift:1310-1432`.

#### Settlement history and later upgrades — **necessary handoff, reducible storage**

A physical mirror can settle before the canonical worker publishes `latestRequiredMirrorTicket` and before a waiter registers. Some terminal fact must survive that handoff. Later same-tab convergence must also upgrade an earlier deferred ticket for a still-live owner; exact context invalidation remains authoritative. The reconstruction encodes this with `convergedTicket` plus merged terminal ranges (`MCPReadFileAutoSelectionCoordinator.swift:1171-1265`).

The storage is not fully minimal. `completeMirrorBatch` records `.converged` ranges at `:1181-1195`, but `resolvedMirrorWaitResult` returns from `convergedTicket >= ticket` at `:1241` before consulting settlement history at `:1242`. Stored converged ranges are therefore unreachable as lookup authority. Keep the monotonic convergence high-water and only the compact non-converged ranges required for late handoff/exact outcomes; keep bounded pruning. This preserves the black-box semantics tested at `MCPReadFileAutoSelectionCoordinatorTests.swift:920-979` without retaining redundant entries.

#### Lifecycle diagnostics — **defensible but optional representation**

The inner DEBUG created/exited/live counts (`WorkspaceSelectionCoordinator.swift:211-246`) and outer retired/deadline/settlement counts (`MCPReadFileAutoSelectionCoordinator.swift:792-807`) do not create correctness. They are, however, direct deterministic evidence for the maintainers' request that physical workers and deadline tasks be reclaimed rather than merely cancelled logically. Retain a minimal created/exited/live accounting surface unless an equivalent deterministic hook replaces it; do not treat diagnostic counters as production authority.

#### Compatibility wiring — **narrow and earned**

The extra files are primarily signature propagation, not unrelated product work: `WorkspaceManagerViewModel.swift:5383-5405` returns and revalidates the outcome; `MCPServerViewModel.swift:1840-1872` propagates it; `MCPServerViewModel+TabContext.swift:4334` handles exact invalidation; and `MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift:269-274` keeps the existing diagnostic result legible. The diagnostics guard changes one mock return. This wiring is necessary once `Void` becomes a typed result; the human-readable diagnostic labels are defensible optional polish, not a second authority.

### 4. Test volume and maintainer feedback

The reconstruction changes 10 files and `+1177/-153`; production accounts for `+571/-141`, while tests account for `+606/-12`. `9ab7c673` alone adds 600 test lines and `621b6b75` adds seven lines to make the cancellation race deterministic. That is a high public review cost, but raw volume overstates scope because the maintainers explicitly asked for sustained concurrency/lifecycle proof.

**Directly justified by explicit feedback:**

- 100-demand cancellation-ignoring inner worker, one-worker/one-latest bound, and eventual worker equality: `WorkspaceSelectionCoordinatorTests.swift:254-315`;
- immediate cancellation/exit of an early-completed 30-second deadline: `:317-345`;
- caller cancellation with no explicit successor still repairs latest state: `:347-369`;
- 30 completion/timeout/cancellation terminal races with exact-once settlement and lifecycle equality: `:371-430`;
- exact parked-waiter invalidation, replacement fencing, and retired physical worker exit: `MCPReadFileAutoSelectionCoordinatorTests.swift:804-860`;
- bounded `finish` plus physical-exit reclamation: `:862-893`;
- same-tab survivor preservation: `:1015-1057`;
- 50 invalidation/replacement cycles ending with zero workers, waiters, deadlines, and lanes: `:1059-1112`; and
- connection-removal integration while a selection mirror is physically parked: `PersistentAgentModeMCPReadFileConnectionTests.swift:250-258,516-572`.

**Technically useful focused regressions:** exact canonical invalidation (`MCPReadFileAutoSelectionCoordinatorTests.swift:895-919`), late terminal handoff (`:920-949`), and later same-tab convergence upgrade (`:950-979`).

**Consolidation candidates:** the settlement-history shape/pruning test (`:981-1013`) and repeated internal-counter assertions are coupled to the chosen representation rather than the user-visible contract. If converged ranges are removed, combine late handoff, upgrade, and bounded-history assertions into a smaller black-box-oriented test. The stress iteration counts 100/30/50 are not semantic constants, but removing the sustained loops altogether would ignore explicit maintainer feedback.

The volume is therefore **high but broadly justified**, not wholesale test scope creep. The implementation-created settlement-history surface and its shape test are the clearest avoidable portion. Existing current-main coverage already protects `op=get` while mirror work is blocked, so no duplicate test is needed.

### 5. Credible smaller current-main port

A credible smaller port exists, but it is a narrowed form of the reconstruction, not a port of the old chain.

**Inner model**

- one `Demand` whose `requestID` is also the worker ownership token;
- one active task and one replaceable pending latest demand;
- waiter/deadline dictionaries keyed by request ID;
- one shared `settleRequest(id:outcome:repairIfActive:)` transition used by deadline and caller cancellation;
- pre-apply target/revision/peer checks and post-suspension active-token/target/peer/cancellation checks; and
- latest-target repair promotion only after physical exit.

**Outer model**

- `MirrorBatch(highestTicket, owners)`;
- `MirrorLane(acceptedTicket, completedTicket, convergedTicket, pending, inFlight, waiters, compactNonConvergedSettlements)`;
- one active worker UUID/task per tab, plus a retired UUID set/count removed only at physical exit;
- exact invalidation settlement and owner removal;
- in-flight survivor requeue;
- UUID checks before dequeue and after `applyMirror`, with no numeric generation and no duplicate post-yield check; and
- per-waiter deadline tasks cancelled on every completion/invalidation/caller-cancellation path.

**Tests/wiring**

- retain the non-cooperative 100-demand inner bound, immediate-deadline cancellation, terminal-race stress, exact invalidation/replacement, same-tab survivor, repeated reclamation, and one assembled connection-removal test;
- retain existing `manage_selection get` integration coverage;
- consolidate history-shape/counter-heavy tests after removing converged settlement storage; and
- keep only the compatibility wiring needed to transport the typed outcome and present existing diagnostics.

This smaller model satisfies all issue acceptance criteria and every quoted reviewer invariant: bounded callers, no unbounded predecessor chain, one actual UI apply, exact invalidation, replacement progress, same-tab preservation, stale-completion fencing, truthful physical retirement, immediate deadline cancellation, eventual reclamation, and unaffected `get`. A “minimal” current-main cherry-pick of the old `d8d47126`/`57a3f408` mechanics cannot do so without recreating the reconstructed pump and ownership-transfer concepts; once those are added, it is no longer meaningfully the old design.

### Minimality categories

#### Explicitly requested

- bounded/supersedable mirror waits;
- a non-cooperating old worker without permanent window wedge;
- exact invalidation release;
- replacement-context progress;
- single actual mirror application;
- generation fencing as a property;
- repeated supersession/invalidation/reordering stress;
- eventual physical-worker/lane reclamation; and
- immediate deadline-task cancellation.

#### Technically necessary

- separate logical settlement from physical ownership;
- one inner active worker plus one latest pending demand;
- exact outer owners and `inFlight` state;
- worker-token fences before dequeue and after suspension;
- same-tab survivor requeue;
- typed converged/deferred/invalidated/cancelled results;
- inner and outer deadlines with exact-once continuation settlement;
- latest-target repair after timeout/cancellation/drift; and
- a compact late-settlement handoff plus monotonic later-convergence upgrade.

#### Defensible but optional

- retaining retired outer `Task` handles rather than retired IDs/counts;
- detailed DEBUG lifecycle counters beyond the minimum needed for deterministic reclamation proof;
- human-readable diagnostic outcome labels; and
- the exact stress iteration magnitudes and some repeated internal-count assertions.

#### Scope creep / reducible complexity

- the outer numeric generation in addition to a unique worker UUID;
- the inner worker ID in addition to the demand's unique request ID;
- storing `.converged` settlement ranges that cannot become lookup authority;
- duplicated deadline/caller-cancellation settlement-and-repair code;
- the duplicate post-yield outer ownership guard; and
- a test whose primary contract is the internal settlement-history representation rather than observable recovery.

No unrelated Context Builder fix, new product feature, or parallel physical UI-mirror design appears in the reconstruction range. The old range itself included the selected-scope test synchronization commit `37047b39`; the reconstruction does not carry that unrelated test-only change.

### Eliminated hypotheses

1. **“The old predecessor chain is already bounded.” — Disproved.** Caller wait is bounded; retained task count behind a non-cooperative predecessor is not.
2. **“Cancelling/removing the old outer worker record means the task is gone.” — Disproved.** The old tests report zero while the gate still holds the physical callback.
3. **“Old worker UUID fencing alone makes the old outer model sufficient.” — Disproved.** It protects late high-water mutation but cannot identify same-tab owners or requeue survivors after dequeue.
4. **“The reconstruction's outer layer itself guarantees no callback overlap.” — Disproved.** Replacement tests intentionally start a second outer callback before the first exits; production actual-apply serialization comes from the inner pump.
5. **“The outer numeric generation is required for generation fencing.” — Disproved.** A fresh UUID checked against the sole active-worker map is already a non-reused generation token on `@MainActor`.
6. **“Every stored settlement range is required.” — Disproved for `.converged`.** The convergence high-water resolves first; non-converged handoff storage remains justified.
7. **“Typed outcomes and waiter deadlines are optional diagnostics.” — Disproved.** Without them, a bounded non-convergence can be reported as completed or an outer drain can remain parked.
8. **“The 600 test lines are unrelated overtesting.” — Disproved in the aggregate.** Most scenarios map directly to explicit stress/reclamation feedback; internal-history shape and counter repetition remain consolidation candidates.
9. **“A much smaller old-design port can satisfy the same review invariants.” — Disproved.** It must add the same bounded pump, ownership transfer, typed settlement, deadlines, and physical retirement concepts; only representation-level simplification remains credible.

### Public review and maintenance cost

The current patch asks a reviewer to prove two coupled async state machines across 10 files while also reasoning about two identities for one inner demand, a UUID plus numeric generation for one outer worker, terminal ranges that include unreachable converged entries, duplicated repair transitions, retained task handles, and counter-heavy tests. Those redundant states enlarge the interleaving/state space, make future refactors preserve implementation details, and obscure the genuinely load-bearing ownership boundaries.

Conversely, reducing the PR to the old six-file shape would hide real cross-layer outcome and teardown semantics. The narrow compatibility files are review cost caused by a truthful typed contract, not accidental scope. The appropriate public-contributor move is to remove the redundant states and consolidate representation tests while leaving the core tests that demonstrate the maintainers' requested non-cooperation/reclamation behavior.

### Maintainer-guidance check

- **User impact and invariant:** one wedged selection mirror must not permanently disable mutations in a window; cancellation/invalidation must release callers without lying about physical ownership, and latest canonical selection must eventually be repairable.
- **Root-cause confidence:** confirmed by both exact ranges. The old predecessor dependency and logical-only outer cleanup are directly visible; the reconstruction directly addresses them.
- **Authority:** canonical compose-tab selection plus the two coordinators' explicit ownership state. Diagnostics remain observational.
- **State-safety risks:** stale same-tab completion, dropped survivor demand, false `.completed`, unbounded retained tasks, and cleanup before physical exit.
- **Scale and observability risks:** O(churn) predecessor tasks in the old design; redundant state/shape tests in the reconstruction; invisible physical retirement if tracking is removed rather than simplified.
- **Recommended scope:** simplify the current reconstruction in place; do not reopen the old design and do not add unrelated features.
- **Validation boundary:** focused inner/outer coordinator stress plus one persistent-connection teardown test and existing blocked-mirror `manage_selection get` coverage. This investigation was read-only and, by instruction, did not build or test.

### Unambiguous recommendation

**SIMPLIFY.** Keep the reconstructed bounded pump, exact outer ownership/in-flight transfer, typed outcomes, dual-layer deadlines, physical-retirement accounting, and maintainer-requested behavioral stress. Remove the redundant outer numeric generation, reuse the inner demand ID as the worker fence, omit converged settlement ranges, centralize duplicated repair settlement, represent retired workers minimally, and consolidate implementation-shape tests. **Do not replace the reconstruction with a minimal port of the old predecessor-chain/logical-reclamation design.**

## Investigation Log

### Phase 1 - Triage
**Hypothesis:** The reconstruction may contain a necessary core redesign plus optional bookkeeping/test bulk, or it may be an unnecessary departure from a reviewed minimal design.
**Findings:** The decision cannot be made from diff size alone. The audit must distinguish explicit maintainer requests, issue-required invariants, implementation necessities, and optional scope.
**Evidence:** Upstream PR 472 old head `37047b3900d9b49eed277e0a7fe6481d4c738ade`; old merge base `6ceafd393ea7630dfee65dd5e8d2c9f109527f27`; reconstruction base `44774ffafc74dc22696cd9bf6189f6650a9cc1a0`; published head `621b6b75b01604b5e8b48bba6c9ac73296e05294`.
**Conclusion:** External maintainer/PR facts and git archaeology are required before Context Builder.

### Phase 2 - Context Builder initial assessment
**Hypothesis:** Broad code context may show that the reconstruction’s core redesign is necessary while narrower bookkeeping can be reduced.
**Findings:** Context Builder selected both exact old/new diffs, the two complete coordinators, focused integration seams, the audit report, and the relevant test suites. It provisionally validated the inner bounded worker/latest-demand model, typed outcomes, exact context ownership, in-flight state, per-request deadlines, peer fences, and retired physical-worker retention as distinct lifecycle boundaries. It identified four simplification candidates for independent verification: remove an outer generation counter if unique worker ID already fences ownership; avoid storing unreachable `.converged` settlement ranges; reuse a demand’s unique ID as its physical-worker fence; and centralize duplicated deadline/caller-cancellation settlement plus repair promotion.
**Evidence:** The Context Builder chat selected exact diffs `6ceafd39..37047b39` and `44774ffa..621b6b75` plus 13 relevant source/test/report artifacts.
**Conclusion:** Initial direction is **SIMPLIFY**, but the pair must independently test each proposed reduction and determine whether a smaller port can satisfy all issue and maintainer invariants.

### Phase 3 - Pair investigator
**Hypothesis:** A smaller port of the old design may satisfy the issue, or the reconstruction may be correct in architecture but reducible in representation.
**Findings:** The pair proved the old inner design is caller-bounded but O(churn) in retained predecessor tasks, and the old outer design cannot preserve exact same-tab owners after dequeue or honestly account for a still-running retired callback. It classified the reconstructed pump, owner/in-flight transfer, typed outcomes, deadlines, and physical retirement as necessary; it identified duplicate inner/outer identities, unreachable converged settlement storage, duplicated settle/repair transitions, and representation-coupled tests as reducible.
**Evidence:** Full `## Investigator Findings` mapping table and exact old/new file:line references above.
**Conclusion:** **SIMPLIFY**, not KEEP or REPLACE.

### Phase 4 - Oracle adjudication and orchestrator spot-check
**Hypothesis:** The pair may be rationalizing prior architecture or recommending cosmetic churn after publication.
**Findings:** Oracle independently confirmed the core reconstruction is within issue/feedback scope, rejected restoration of the old chain, and narrowed must-change work to three reductions: reuse the inner demand ID as the physical-worker fence; remove the outer numeric generation while keeping UUID fences; and stop storing `.converged` settlement ranges. It treated a shared cancellation helper, post-yield guard removal, retired-task representation changes, and broad test consolidation as optional/non-blocking. Direct `git show` spot-checks confirmed the old `await predecessor?.value` chain, ownerless old batches/logical cleanup, duplicate new identities/generation, and unreachable converged-range lookup order.
**Evidence:** The same Oracle chat; old head `WorkspaceSelectionCoordinator.swift:620-696`, old head `MCPReadFileAutoSelectionCoordinator.swift:404-430,980-1018,1256-1262`; published head `WorkspaceSelectionCoordinator.swift:182-208,1077-1095`; published head `MCPReadFileAutoSelectionCoordinator.swift:480-507,1090-1103,1171-1265`.
**Conclusion:** Make only the three substantive reductions if the user authorizes implementation. Preserve history with an additive cleanup commit; do not force-rewrite again.

## Root Cause
The original implementation correctly separated logical caller release from cooperative task cancellation, but it did not bound retained physical work: every new inner request created a task awaiting the previous task. Under a cancellation-ignoring apply, request count and retained task/capture count grow together. The old outer patch likewise released logical lane ownership while the callback remained physically suspended; batches carried no exact owner set or explicit in-flight state, so invalidation after dequeue could not preserve surviving same-tab work or prove physical reclamation.

The reconstruction addresses those root causes, but added redundant representations around the necessary state machine: two unique IDs for one inner demand/worker, UUID plus numeric generation for one outer worker, and stored successful settlement ranges that can never win lookup because `convergedTicket` is checked first. These do not create adjacent product scope, but they enlarge the interleaving and review surface without adding safety.

The process failure was separate: the redesign decision was not surfaced before implementation/publication, and conditional maintainer endorsement of the old direction was treated as if it covered the reconstructed mechanics. The new architecture is technically within scope, but it still requires fresh human review.

## Recommendations
1. **SIMPLIFY in place; do not replace with the old design.** Preserve the one-active/one-latest inner pump, exact outer owners/in-flight state, typed outcomes, inner/outer deadlines, same-tab survivor requeue, worker-token fences, and physical-retirement accounting.
2. **Must-change reduction 1:** reuse `MCPSelectionMirrorDemand.requestID` as the inner physical-worker ownership token; remove the second worker-ID allocation.
3. **Must-change reduction 2:** remove `MirrorLane.generation` and `MirrorWorker.generation`; retain the unique worker UUID as the generation/ownership fence before dequeue and after `applyMirror`.
4. **Must-change reduction 3:** record only non-converged settlement ranges; use `convergedTicket` as the sole successful-convergence authority and retain bounded non-converged history for late handoff.
5. **Do not block on optional churn:** leave retired `Task` handles, the explicit post-yield guard, detailed diagnostics, and most stress tests unless the must-change edits naturally require a narrow adjustment. A shared deadline/cancellation helper is optional only if it reduces code without policy flags.
6. **Publication strategy:** if implementation is authorized, use one additive cleanup commit after focused validation. Do not force-rewrite history again. Then request fresh human ownership/concurrency review on the exact head and disclose that the architecture was rebuilt rather than merely rebased.
7. **CI:** treat the unrelated Context Builder lifecycle failure separately; do not broaden upstream PR 472 to fix it.

## Preventive Measures
- Require an explicit scope checkpoint whenever investigation changes a refresh/rebase task into an architectural rewrite.
- Maintain a reviewer-request → invariant → code-change mapping before implementation, and classify adjacent discoveries as follow-ups by default.
- Treat conditional design endorsement as historical context, not approval of a materially different implementation.
- Optimize public contributions for the smallest state machine that proves the required invariant; remove duplicate identity authorities and unreachable bookkeeping before publication.
- Keep the orchestrator responsible for scope, minimality, public review cost, and final synthesis; agents supply evidence rather than authorization.
- Require explicit user approval before any future source, commit, push, comment, or PR mutation arising from this audit.
