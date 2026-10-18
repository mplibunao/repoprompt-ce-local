# Investigation: upstream PR 472 finish-line plan (2026-08-23)

> Investigation report, observed 2026-08-23 to 2026-08-25 on upstream `main` at `44774ffa`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [AGENTS.md](../../AGENTS.md), Upstream is read-only.

## Summary
Upstream PR 472 addresses a real, still-open provider-level liveness defect: current `main` still has an unbounded physical selection-mirror predecessor chain and loses exact context ownership at the outer per-tab mirror lane. The July patch should not be rebased mechanically; rebuild its first two behavioral contracts on current `main` as a bounded single-worker pump plus ownership-aware drains/teardown, retain and strengthen the five regression tests, and drop the unrelated third commit and deleted ledger changes.

## Symptoms
- Upstream PR 472 was opened on July 10 and has been unattended for more than a month while upstream `main` changed substantially.
- The pull request has review comments that still need to be retrieved, evaluated, and addressed.
- The original agent session is unavailable, so the issue validity, branch intent, and implementation rationale must be reconstructed from durable evidence.

## Background / Prior Research

### Prior local investigation (2026-07-24)
- `docs/investigations/pr-472-upstream-parity-and-tip-release-2026-07-24.md` concluded that upstream PR 472 fixed upstream issue 457, a selection-mirror wedge caused by an unbounded internal mirror tail plus invalidation-insensitive outer waiters.
- At that time upstream PR 472 was open and conflicting, upstream issue 457 remained open, and upstream `main` did not contain equivalent guarantees.
- The July report identified local branch `bugfix/selection-mirror-wedge` and three PR commits: `d8d47126`, `57a3f408`, and `37047b39`.
- The July report recommended rebasing onto current upstream and revalidating five targeted regression tests.

### Refreshed upstream main (explore agent, 2026-08-23)
- `git fetch upstream main` succeeded without changing the working tree. `upstream/main` was already current at [`44774ffa`](https://github.com/repoprompt/repoprompt-ce/commit/44774ffafc74dc22696cd9bf6189f6650a9cc1a0), "Enable Codex apps with runtime 0.149.0 (upstream PR 851)."
- The July anchor `cebd7e64` is 352 commits behind this tip. Major adjacent changes include upstream PRs 664, 722, 755, 801, 822, and 823.
- Static inspection still finds the pre-fix mirror tail and invalidation-insensitive waiter behavior; no upstream equivalent of `MCPSelectionMirrorWaitSignal`, `mcpSelectionMirrorTimeout`, `cancelMirrorWaiters`, or a context-bearing `SequenceWaiter` exists.

### Local branch archaeology (explore agent, 2026-08-23)
- GitHub PR head: `origin/bugfix/selection-mirror-wedge` at `37047b3900d9b49eed277e0a7fe6481d4c738ade`, matching a local rebase branch.
- Do not confuse it with stale local `bugfix/selection-mirror-wedge` at `2ca83e9703c930221d0e682349e464b64a70408f`; that is the pre-rebase series.
- PR commits are `d8d47126` (bounded selection mirror tail), `57a3f408` (released auto-selection waiters), and `37047b39` (selected-scope test setup). Aggregate delta: six files, +535/-97.
- The first two commits add the substantive implementation and five regression tests. The third only synchronized a selected-scope test setup; its current relevance is uncertain because that test was later rewritten.

### Current GitHub state and maintainer feedback (explore agent, 2026-08-23)
- Upstream PR 472 is open, non-draft, `CONFLICTING`/`DIRTY`, and `REVIEW_REQUIRED`; no human approval exists. Old-head CI passed but is stale.
- Upstream issue 457 remains open. It records repeated release 1.0.27 reproduction across MCP and CLI transports, with sibling windows healthy. Current static code corroborates its mechanism, although a fresh live reproduction is still required.
- GitHub reports one Copilot summary review, zero review threads, and zero inline review comments. The actionable feedback is in three collaborator discussion comments:
  - Maintainer A, 2026-08-09 (a comment on upstream PR 472): refresh onto current `main`, request focused ownership/concurrency review, and provide exact-head checks.
  - A collaborator, 2026-08-14 09:45 (a comment on upstream PR 472): add sustained timeout/cancellation/reordering stress, repeated supersession/context invalidation, and task-reclamation proof.
  - The same collaborator, 2026-08-14 09:55 (a comment on upstream PR 472): cancel completed deadline tasks rather than retaining them until expiry; test lifecycle cleanup.
- Later upstream PRs 520, 755, and 822 are related but do not supersede upstream PR 472. Upstream PR 822 explicitly treats upstream issue 457 as a distinct provider-level trigger.

### PR head versus current upstream (explore agent, 2026-08-23)
- Merge base: `6ceafd393ea7630dfee65dd5e8d2c9f109527f27`; current topology is upstream +644 / PR +3.
- Patch-equivalence checks leave all three PR commits unmatched. The core semantic delta survives.
- Definite conflicts: delete/modify on the now-removed `Scripts/Fixtures/test-suite-contract-ledger.tsv`, plus textual conflict in `MCPCodeStructureWorktreeTests.swift` whose selected-scope test was heavily rewritten.
- The two production files and two primary test files may merge textually, but have substantial semantic overlap with new route, automatic-codemap, persistence, mutation, and inline-composer behavior.
- Safest direction: rebuild the two production fixes and five regression tests on current `main`; drop the deleted ledger changes; re-evaluate rather than blindly carry the third commit.

## Investigator Findings
<!-- The pair investigator appends structured analysis here. -->

### Current-main evidence record (2026-08-23)

#### Scope and verdict

- The inspected checkout is exactly current main: `HEAD == upstream/main == 44774ffafc74` on branch `main`. The two production coordinators and their focused tests have no branch-local delta.
- **Finding 1 is confirmed.** `WorkspaceSelectionCoordinator` still builds a physical linked list of unstructured mirror tasks. Every new task awaits its predecessor's `Task.value`, and the originating request awaits the new task's physical exit.
- **Finding 2 is confirmed.** `MCPReadFileAutoSelectionCoordinator` loses exact `ContextKey` ownership when canonical work becomes a per-tab mirror ticket. Context invalidation therefore cannot identify/release that context's mirror waiter, cancel/reclaim the parked per-tab worker, or let a replacement generation own the tab lane.
- Both are liveness defects after or alongside canonical persistence. They must not be described as a single generic timeout: request completion, physical task reclamation, and final file-tree/UI convergence are three separate contracts.
- The safest merge path remains a **current-main re-author** of the first two commits' behavioral contracts. Do not cherry-pick their state machines. Drop historical commit `37047b39` and all deleted ledger changes.

#### End-to-end authority, request, mirror, drain, and teardown flow

1. **Read/search request admission.** `MCPFileToolProvider.executeReadFileBody` reads and projects the file, then submits the auto-selection side effect at `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift:378-510`. The side effect only enqueues auto-selection and returns (`MCPFileToolProvider.swift:923-938`); the comment explicitly says historical read completion guarantees queue admission, not deferred mirror completion.
2. **Exact context identity.** Auto-selection keys include window, workspace, tab, route `(connectionID, runID)`, and binding generation (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift:4662-4692`; the generation is allocated at `MCPServerViewModel+TabContext.swift:618-622`). This is the correct canonical ownership fence.
3. **Canonical queue and persistence.** `MCPServerViewModel.enqueueReadFileAutoSelection` constructs the intent and enqueues it at `MCPServerViewModel.swift:4304-4400`. The outer coordinator advances a context-lane sequence and coalesces pending canonical work at `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift:532-604`. Its worker revalidates exact context ownership before and after its test gate and canonical apply (`MCPReadFileAutoSelectionCoordinator.swift:760-880`, especially `:792-800` and `:819`). The app-side batch re-resolves the latest canonical selection and persists against an expected base at `MCPServerViewModel.swift:4985-5132` and `MCPServerViewModel+TabContext.swift:1898-2011`.
4. **Canonical source of truth.** Compose-tab `StoredSelection` is authoritative; the file-tree checkbox state is a projection. The inner coordinator commits the tab and records its revision at `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:1129-1140`. Its normal MCP persistence path validates identity/fences at `:374-403`, commits at `:441-446`, publishes the change, and only then awaits the active UI mirror at `:459-467`. `transformSelection` has the same canonical-before-mirror ordering at `:493-534`. A mirror timeout is therefore potentially **post-commit partial success**, not permission to blindly retry or roll back the mutation.
5. **Outer mirror handoff.** After a changed canonical batch, the outer coordinator discards the exact `ContextKey` and enqueues only `key.mirrorKey` (`window/workspace/tab`) at `MCPReadFileAutoSelectionCoordinator.swift:819-826`. Canonical completion stores the required per-tab mirror ticket and resumes canonical waiters at `:884-912`.
6. **Physical UI projection.** The outer mirror worker calls a tab-only `ApplyMirror` closure (`MCPReadFileAutoSelectionCoordinator.swift:430-431,1021-1069`; wiring at `MCPServerViewModel.swift:1835-1845`). The closure awaits `applyStoredSelectionMirrorForReadFileAutoSelection` (`MCPServerViewModel.swift:1848-1871`), which resolves the newest stored tab selection and calls the inner coordinator (`Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:5381-5396`). The real inner attempt enters tab-context suppression and awaits `fileManager.applyStoredSelection` (`WorkspaceManagerViewModel.swift:5363-5379`); that operation has several actor suspensions and mutation phases (`Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift:11660-11725`).
7. **Drain semantics.** The outer drain first captures and waits a finite canonical high-water mark, then optionally waits the required tab mirror ticket (`MCPReadFileAutoSelectionCoordinator.swift:607-670`). `.canonicalSelection` intentionally returns while mirroring is blocked; the persistent MCP integration contract proves this at `Tests/RepoPromptTests/MCP/Control/PersistentAgentModeMCPReadFileConnectionTests.swift:1903-1909`. `.mirroredSelectionAndMetrics` currently means the physical `ApplyMirror` returned and the ticket advanced.
8. **Later selection tools.** `manage_selection get` drains canonical work, while mutations drain mirrored selection/metrics **before** the filesystem-ingress wait (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPSelectionToolProvider.swift:175-195`). Therefore the later bounded ingress work does not supersede upstream issue 457: a parked mirror wedges before that boundary.
9. **Graceful finish and teardown.** `finish(context:)` closes admission and awaits the mirrored drain before marking the context retiring (`MCPReadFileAutoSelectionCoordinator.swift:672-680`). Connection removal awaits that finish before calling `removeTabContext` (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:6165-6208`), so orderly teardown can park before invalidation is reached. Other release/removal paths call `invalidateReadFileAutoSelection` directly (`MCPServerViewModel+TabContext.swift:625-653,4430-4446`), but current invalidation still cannot release a previously registered mirror waiter or worker.

#### Gap 1: inner mirror tail is request-unbounded and physically unbounded

**Direct proof**

- `MCPSelectionMirrorTail` owns a concrete `Task<Void, Never>` (`WorkspaceSelectionCoordinator.swift:175-180`); the coordinator retains the newest tail at `:190-192`.
- Every exact mirror captures `mcpSelectionMirrorTail?.task` (`:959-965`), creates a new task that first executes `await predecessor?.value` (`:968-970`), installs that new tail (`:999`), and makes the request execute `await task.value` (`:1000`).
- Repair work repeats the same physical dependency: it accepts a predecessor (`:1005-1007`), awaits its value (`:1010-1012`), and becomes the new tail (`:1035`).
- With parked head `T1`, later work is retained transitively as `Tn -> ... -> T2 -> T1`. Revision and active-target checks at `:976-982` run only after the predecessor exits; they can skip stale work but cannot bound the chain.
- `discardSelectionMirrorTask` only clears an entry if it is still the currently stored tail (`:1074-1077`). It cannot unlink predecessors already captured by successor closures.
- Caller cancellation is deliberately insufficient: the source states that the internal task owns completion after canonical persistence (`:966-967`), and `testCancelledMCPMirrorRequestDoesNotCancelBlockedPredecessorOrLatestSuccessor` codifies the behavior (`Tests/RepoPromptTests/WorkspaceContext/WorkspaceSelectionCoordinatorTests.swift:213-251`).

**Three distinct outcomes**

- **Request-level bounded completion:** absent on current main. A request at `enqueueSelectionMirror` awaits the physical task indefinitely.
- **Physical cleanup:** absent on current main. A cancellation-ignoring head retains its own task and every transitive successor. There is no timeout, wait signal, live-worker counter, pending-target bound, or deadline accounting in the coordinator initializer/state (`WorkspaceSelectionCoordinator.swift:175-209`).
- **Final UI convergence:** current revision/context fencing is sound once physical progress resumes. The exact target includes workspace, tab, selection, and mirror-context revision (`:29-41,97-106`), and `finishSelectionMirrorTask` coalesces a latest-target repair at `:1038-1068`. If the head never returns, no successor/repair can run, so final convergence is not guaranteed even though canonical state is current.

**Current test gap**

- `testMCPActiveSelectionMirrorsAreAwaitedSerializedAndSkipSupersededRevision` proves eventual latest convergence only after manually releasing the first gate (`WorkspaceSelectionCoordinatorTests.swift:73-120`).
- `testMCPMirrorRequestCompletesWhileChurnRepairsCoalesceToLatest` releases the initial physical apply at `:146` before asserting request completion at `:149-150`; it proves that a completed request does not await later repair, not that the head wait is bounded (`:122-162`).
- ABA repair remains useful coverage (`:164-190`) but also manually releases the gate.
- The inner `SelectionMirrorGate` is a polling gate with a five-second escape and no checked-continuation mode that deliberately ignores cancellation (`:1331-1354`). The fake manager records starts/completions but not live/peak physical attempts or task/deadline lifecycle (`:1377-1463`).

#### Gap 2: outer invalidation cannot release exact mirror ownership or reclaim the tab lane

**Direct proof**

- Canonical work retains exact `ContextKey` identity and is revalidated around its suspensions (`MCPReadFileAutoSelectionCoordinator.swift:792-800,819`). That identity is lost at `enqueueMirror(for: key.mirrorKey)` (`:819-826`).
- `SequenceWaiter` contains only a ticket target and continuation (`:447-460`). `waitForMirrorTicket` registers it only in the `TabMirrorKey` lane and checks only the drain task's cancellation (`:1132-1162`). There is no originating context, route, or binding generation to match during invalidation.
- `invalidate(context:)` marks canonical lifecycle sets, schedules pending canonical work, and calls cleanup; it neither finds/resumes mirror waiters nor cancels a mirror worker (`:683-690`).
- The worker is represented only by a `Set<TabMirrorKey>` plus a diagnostic UUID map, not a task handle/generation (`:490-492,1021-1033`). It awaits `applyMirror` without a deadline (`:1035-1069`).
- Worker defer and ticket completion are not guarded by worker ID (`:1035-1045,1072-1089`). Current code never replaces a parked worker, so this is latent; any replacement-progress fix must add the fence before allowing a successor generation.
- Cleanup explicitly refuses to remove the lane while a worker, pending batch, waiter, or same-tab canonical lane exists (`:1259-1281`). Thus an invalidated context's uncancelled mirror drain and worker registration form a retention cycle at the coordinator level until physical apply returns.

**Behavioral boundary**

- A sibling tab has a different `TabMirrorKey` and remains healthy. A replacement context for the same tab shares the parked lane and cannot make mirrored progress.
- Explicitly cancelling the drain task is not an invalidation fix. `testCancelledMirrorDrainResumesPromptlyWithoutStoppingWorker` removes only that task's waiter and intentionally asserts the worker remains one until the gate is released (`Tests/RepoPromptTests/MCP/MCPReadFileAutoSelectionCoordinatorTests.swift:482-518`).
- Existing invalidation tests cover pending/pre-commit canonical work and binding replacement, not a parked mirror waiter/worker (`MCPReadFileAutoSelectionCoordinatorTests.swift:660-684,759-815`).
- The DEBUG snapshot exposes logical lane/worker/waiter counts only (`MCPReadFileAutoSelectionCoordinator.swift:692-742`). It cannot distinguish current ownership from a retired-but-physically-running task and therefore cannot prove reclamation.

#### Historical PR patch versus current-main requirements

**Commit `d8d47126` -- retain its three contracts, replace its mechanics**

- The patch added an `MCPSelectionMirrorWaitSignal`, one timeout task per tail, supersession cancellation, and a timeout-injectable initializer (`d8d47126:Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:156-177,618-723`). This correctly separated the originating request waiter from physical task completion.
- It did **not** remove the physical predecessor chain. Each successor still captured `predecessor?.task`, and every physical task still began with `await predecessor?.value` (`d8d47126:Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:626-630,688-697`). Under repeated supersession behind one cancellation-ignoring head, callers return but an arbitrarily deep chain remains parked.
- It also missed immediate deadline cancellation on a completed-target-mismatch repair path. `finishSelectionMirrorTask` scheduled a repair with `cancelExistingTail: false`; repair installation overwrote the old tail, while `completeSelectionMirrorTail` could cancel only an entry that was still current (`d8d47126:Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:728-760,790-805`). The completed entry's deadline could therefore sleep until its original expiry. This directly supports the maintainer request to cancel completed deadline tasks immediately and test lifecycle cleanup.
- Retain and strengthen these current-main-absent contracts:
  1. `testNewMCPMirrorCancelsSupersededApply` (`d8d47126:Tests/RepoPromptTests/WorkspaceContext/WorkspaceSelectionCoordinatorTests.swift:244-284`).
  2. `testMCPMirrorTimeoutRepairsCanonicalSelectionAfterCancelledApplyReturns` (`:286-325`).
  3. `testMCPMirrorTimeoutBoundsUncooperativeTailAndRepairsLatestSelection` (`:327-391`).

**Commit `57a3f408` -- retain its two contracts and ownership direction, complete the fence/proof**

- The patch added `SequenceWaiter.contextKey`, exact `cancelMirrorWaiters(for:)`, a `{id, task}` mirror-worker handle, conditional owner removal in defer, and a post-apply worker-ID fence (`57a3f408:Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift:388-418,625-633,964-1019,1083-1122,1156-1176`). Those are directionally correct.
- The worker loop still dequeued `mirrorLanes[key].pending` without first proving `mirrorWorkers[key]?.id == workerID`. After the loop's `Task.yield`, a retired worker could re-enter, steal a replacement generation's pending batch, apply it, and only then notice ownership loss (`57a3f408:Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift:994-1020`). Fence loop entry/before dequeue and every post-suspension commit, not only the point after `applyMirror`.
- Its reclamation test asserted logical `mirrorWorkerCount == 0` before releasing a cancellation-ignoring checked-continuation gate. That proves handle/lane de-ownership, not physical task exit. A live-retired task counter and an explicit post-release zero assertion are required.
- Retain and strengthen these current-main-absent contracts:
  4. `testInvalidationCancelsParkedMirrorWaiterAndReclaimsWorker` (`57a3f408:Tests/RepoPromptTests/MCP/MCPReadFileAutoSelectionCoordinatorTests.swift:610-656`).
  5. `testReplacementContextMirroredDrainCompletesWhileInvalidatedWorkerIsParked` (`:658-716`).

**Commit `37047b39` -- drop**

- It changed only selected-scope code-structure test setup/assertions, not production liveness (`37047b39:Tests/RepoPromptTests/MCP/MCPCodeStructureWorktreeTests.swift:619-713`).
- Current main later rewrote that test architecture; the historical selected-scope test no longer exists in `Tests/RepoPromptTests/MCP/MCPCodeStructureWorktreeTests.swift`, and the old contract-ledger file is deleted. The current file history includes later selected-scope stabilization and the graph-native codemap rewrite.
- Patch non-equivalence is not a reason to carry obsolete test setup. Drop this commit and all `Scripts/Fixtures/test-suite-contract-ledger.tsv` hunks.

#### Safest current-main implementation plan

1. **Replace the inner linked task tail with a bounded pump.** Keep at most one physically active inner mirror worker, one coalesced latest pending target/request, and bounded request-wait state. New requests must not create a task that awaits a parked predecessor.
2. **Separate logical request completion from physical ownership.** On supersession or deadline, release the exact logical waiter and cancel its deadline immediately. Request cancellation/timeout may request worker cancellation, but the worker continues to own the physical slot until its body actually exits.
3. **Preserve strict inner serialization.** Do not launch a replacement inner apply while a cancellation-ignoring apply is alive. Promote the single pending latest target only from the active worker's physical-exit transition. This keeps maximum concurrent file-tree applies at one and prevents a late stale apply from overwriting the latest projection.
4. **Fence every inner transition.** Use exact worker/request generation IDs for completion, timeout, supersession, repair promotion, and teardown. A stale worker or deadline must not clear/cancel/promote successor state. The paired deadline must be cancelled on every terminal path independently of whether its entry is still the current target.
5. **Preserve current correctness fences.** Keep canonical-before-mirror ordering, `selectionRevisionByIdentity`, exact `selectionMirrorContextRevision` ABA detection, deferred UI-selection fencing (`WorkspaceSelectionCoordinator.swift:1102-1115`), and peer-host mutation fencing.
6. **Carry exact ownership into the outer mirror lane.** Pass the originating `ContextKey` into mirror enqueue and waiter registration. Tag queued/in-flight ticket demand and waiters by exact context. Invalidation resumes only matching waiters as cancelled and must preserve another live same-tab context's demand.
7. **Make outer worker ownership physical and explicit.** Store current worker `{id, task}`, its in-flight batch, and retired-but-not-exited tasks. Fence loop entry/before dequeue, after every suspension including `applyMirror` and `Task.yield`, before ticket advancement, and in defer/cleanup. A late old worker must never dequeue, advance, or clear successor-generation state.
8. **Keep one per-tab authority.** Do not make outer mirror lanes/workers independently context-keyed; that would permit concurrent UI projection and destroy tab-level coalescing. When an invalidated worker is logically retired, requeue only surviving live demand under the new tab-lane generation.
9. **Return an explicit mirror outcome.** Current `ApplyMirror` is `async -> Void` (`MCPReadFileAutoSelectionCoordinator.swift:430-431`). If the inner request waiter times out while physical convergence is pending, treating the outer ticket as `.completed` would lie about `.mirroredSelectionAndMetrics`. Plumb an explicit result such as converged/deferred/cancelled. Bound drains on timeout/invalidation, but report canonical durability and UI non-convergence honestly; repair remains latest-canonical work.
10. **Integrate teardown with the bounded outcome.** Graceful finish must not wait forever, and invalidation must be able to release exact waiters even if finish began first. Do not erase tab/run state until canonical ownership and the partial-success outcome are recorded.

#### Risk boundaries and eliminated alternatives

- **Uncooperative-task theorem:** Swift cancellation cannot forcibly destroy an operation that never cooperates. The achievable invariant is bounded logical request completion, O(1) retained coordinator work, strict inner apply serialization, and eventual physical reclamation/convergence once the underlying operation returns. Permanent final UI convergence cannot be promised if the physical apply literally never returns.
- **Do not launch a second inner apply after timeout.** It would improve apparent progress but allow overlapping UI mutations; a late old apply could overwrite the latest result.
- **Do not merely add `Task.cancel()` or a timeout to the current tail.** Cancellation does not unlink `Task.value` predecessors, and timeout-only tests can hide retained tasks.
- **Do not clear a task handle and call it reclaimed.** Logical de-ownership is useful for replacement routing, but physical reclamation requires observing the task body exit.
- **Do not rely on current canonical fences.** They correctly prevent stale stored commits, but ownership has already been discarded when work enters the tab-only mirror lane.
- **Do not rely on request cancellation or weak captures.** Request cancellation can remove its own waiter; invalidation does not cancel that task, and a begun worker retains its execution until the awaited closure returns.
- **Do not clone the outer lane per context.** Concurrent same-tab workers would violate projection serialization and coalescing. Preserve tab authority and add owner-tagged demand plus generation fences.
- **Do not claim the later ingress timeout fixes this path.** `manage_selection` waits for mirrored auto-selection before ingress (`MCPSelectionToolProvider.swift:179-195`).
- **Do not broaden first to `WorkspaceFilesViewModel.applyStoredSelection`.** Its cancellation behavior can be hardened separately, but coordinator memory/request bounds and truthful outcomes are independently fixable at the owning seams.

#### Exact harness hooks and counters required

**Inner coordinator and fake host**

- Injectable deadline scheduler/sleep or task factory, not only a short real duration.
- A checked-continuation mirror gate with explicit release and a mode that intentionally ignores cancellation.
- Snapshot/events for active physical worker count and peak; workers created/exited; pending-target count and peak; active logical waiters; waiter registered/released; live deadline tasks; deadlines created/cancelled/fired/exited; timeout/supersession/repair counts; and active/pending worker/request generation IDs.
- Fake-host current/maximum concurrent mirror attempts, exact selections started/completed, and a physical-exit signal. The current arrays alone cannot distinguish cancellation, logical return, or physical exit.

**Outer coordinator and diagnostics**

- Preserve the existing lane/high-water/waiter counters, then add current owned workers, physically active worker tasks, retired-but-not-exited tasks, queued versus in-flight batches, and exact waiter counts by `ContextKey`.
- Extend diagnostic events with owner generation/worker ID and whether the event's worker still owns the lane. Current `workerActive` cannot distinguish an old stopping task from a simultaneously active successor.
- Extend `CoordinatorDiagnosticRecorder.waitFor` (`MCPReadFileAutoSelectionCoordinatorTests.swift:900-937`) with predicates by worker ID/generation and exact event-count/multiset helpers so repeated stress can pair every start/stop and detect stale mutations.
- Reuse the current checked-continuation `CoordinatorAsyncGate` (`:940-968`) for deliberately parked physical outer work, but assert physical zero only after explicit release.

#### Maintainer-feedback implementation and test checklist

- [ ] Re-author on exact current main; request focused concurrency/ownership review on the resulting head and provide exact-head checks.
- [ ] Retain all five named regression contracts above; retain current serialization/superseded-revision, ABA repair, stale-UI fence, no-op reconciliation, peer-close, canonical handover, and same-tab coalescing tests.
- [ ] Strengthen the inner timeout tests with repeated supersession (prefer a deterministic injected clock and at least 100 iterations): while the first apply ignores cancellation, every request returns within its bound, canonical selection is latest, active physical workers equal one, pending targets are at most one, and obsolete waiters/deadlines are zero.
- [ ] Release the inner head and prove only the latest target is promoted, maximum concurrent inner applies remains one, final mirrored UI equals canonical state, and worker/pending/waiter/deadline counts all reach zero with created == exited.
- [ ] Prove immediate deadline cancellation: use a deliberately long deadline, complete or supersede early, observe live deadline count reach zero and cancelled/exited advance without waiting for expiry, then fire/advance a stale deadline and prove it cannot affect a successor (`fired == 0` for the cancelled entry).
- [ ] Run repeated completion-versus-timeout-versus-caller-cancellation races and assert each waiter resumes exactly once; include ABA tab switching and peer-host invalidation/replacement.
- [ ] Invalidate an old outer context with a parked mirror and assert only its exact waiter returns cancelled. A different live same-tab context must retain its waiter/demand.
- [ ] Start a same-tab replacement generation while the old outer worker is logically retired; prove the replacement's bounded drain outcome, then release the old gate and prove its late exit cannot dequeue or advance successor tickets or clear the successor worker.
- [ ] Repeat invalidation/replacement/reordering stress for at least 50-100 iterations. Pair unique worker start/stop IDs and assert no waiter double resume, no stale high-water advancement, and no lane/current-worker/retired-task retention after each fully released iteration.
- [ ] Add an orderly connection-teardown integration test: a parked mirror must produce a bounded, truthful non-convergence outcome instead of parking before invalidation/removal; after repair/release, all context/lane/task state must be reclaimed.
- [ ] Distinguish assertions at all boundaries: (a) canonical persisted, (b) request/drain returned boundedly, (c) physical task exited, and (d) final UI converged. Do not use one assertion as evidence for another.
- [ ] Run the two focused coordinator suites repeatedly, then persistent MCP read/manage-selection handover and teardown tests, then the live CE MCP reproduction/repair flow before declaring upstream issue 457 fixed.
- [ ] Drop `37047b39`, ledger hunks, and obsolete selected-scope setup from the branch.

#### Maintainer-guidance check

- **User impact and invariant:** one parked projection must not wedge later MCP selection requests, same-tab replacement contexts, or connection teardown; canonical selection remains authoritative, UI applies remain serialized, and UI eventually converges when physical progress is possible.
- **Root-cause confidence:** confirmed statically at the concrete current-main predecessor capture/await and ownership-loss/invalidation sites. A fresh release reproduction is still useful integration evidence, not required to establish these code-level gaps.
- **Authority:** compose-tab `StoredSelection` and its revision/fences; the file-tree UI and metrics are derived projections.
- **State-safety risks:** timeout can occur after a durable canonical mutation. Never roll back or blindly replay it; preserve exact connection/run/binding-generation ownership and report partial success truthfully.
- **Scale and observability risks:** current inner retained task depth grows with requests behind a parked head; current outer diagnostics conflate logical worker registration with physical task lifetime. New counts must prove O(1) inner state and eventual zero physical/retired state.
- **Recommended scope:** implement both coordinator fixes together on current main, keep the five strengthened contracts, drop the unrelated historical commit, and defer broader file-tree cancellation hardening unless new evidence requires it.
- **Validation boundary:** focused repeated coordinator stress first; persistent MCP read/manage-selection handover and teardown next; then a live CE MCP/CLI reproduction and recovery check on the exact PR head.

## Investigation Log

### Phase 1.5 - external and Git archaeology
**Hypothesis:** upstream issue 457 may have been hallucinated, fixed independently, or superseded while upstream PR 472 became stale.
**Findings:** Four independent probes found the issue and PR still open, no patch-equivalent upstream fix, and current static code retaining both failure mechanisms. The PR head is 644 commits behind current upstream and has actionable collaborator discussion comments but no inline review threads or human approval.
**Evidence:** `upstream/main` `44774ffafc74dc22696cd9bf6189f6650a9cc1a0`; PR head `37047b3900d9b49eed277e0a7fe6481d4c738ade`; merge base `6ceafd393ea7630dfee65dd5e8d2c9f109527f27`; GitHub links and comment checklist in Background.
**Conclusion:** Hallucination/supersession eliminated. Updating or replacing the PR remains worthwhile.

### Phase 2 - current architecture discovery
**Hypothesis:** Later canonical-selection, read convergence, or structure-settlement work may already bound the failing path.
**Findings:** Canonical mutation/revision/context/peer fencing is materially stronger, but `manage_selection` mutations still wait for mirrored auto-selection before the later bounded ingress fence. Neither upstream PRs 520 and 755, nor upstream PR 822 releases the two provider-level ownership wedges.
**Evidence:** `MCPSelectionToolProvider.swift:175-195`; `WorkspaceSelectionCoordinator.swift:959-1077`; `MCPReadFileAutoSelectionCoordinator.swift:683-690,819-826,1021-1089,1132-1162`.
**Conclusion:** Eliminated. Preserve newer correctness fences while replacing only mirror ownership/lifecycle machinery.

### Phase 3/4 - pair proof and Oracle adjudication
**Hypothesis:** The original timeout/wait-signal patch can be replayed with small conflict fixes.
**Findings:** The historical inner patch bounded callers but retained a physical predecessor chain and could leave completed deadline tasks alive until expiry. The historical outer patch added useful ownership direction but did not fence every dequeue/suspension/commit or prove physical exit. Oracle adjudication selected a bounded single-worker pump, one coalesced latest demand, exact generated outer ownership, truthful converged/deferred outcomes, and bounded finish/invalidation ordering.
**Evidence:** Historical `d8d47126` and `57a3f408` analysis under Investigator Findings; direct spot checks against current `main` and historical blobs.
**Conclusion:** Mechanical rebase/cherry-pick eliminated. Full current-main re-author is required.

## Root Cause

### Inner window-scoped mirror chain
`WorkspaceSelectionCoordinator.enqueueSelectionMirror` captures `mcpSelectionMirrorTail?.task`, makes every new task await `predecessor?.value`, installs the new physical task as the tail, and makes the request await `task.value` (`WorkspaceSelectionCoordinator.swift:959-1000`). Repair work repeats the physical predecessor relation (`:1005-1035`). If one `applyStoredSelection` suspension ignores cancellation, every later mirror and repair is retained behind it. Revision/context/peer checks are correct but run only after predecessor completion, so they cannot provide liveness.

### Outer per-tab mirror lane
Canonical work is correctly keyed by exact `ContextKey` (connection, run, and binding generation), but the coordinator discards that identity when it enqueues the `TabMirrorKey` ticket (`MCPReadFileAutoSelectionCoordinator.swift:819-826`). `SequenceWaiter` and mirror tickets cannot be matched back to invalidation (`:447-460,683-690,1132-1162`); the worker is a set entry plus diagnostic UUID rather than an owned task/generation (`:490-492,1021-1089`). A parked obsolete worker therefore owns the same-tab lane and blocks a replacement binding. Graceful `finish` can wait on that lane before connection removal reaches invalidation, extending the wedge into teardown.

### Required semantic distinction
Canonical compose-tab selection is already durable before UI mirroring. The fix must separately model: (1) canonical durability, (2) bounded logical request/drain settlement, (3) physical task exit, and (4) final UI/token-metric convergence. Swift cancellation cannot forcibly terminate an uncooperative task; the achievable invariant is O(1) retained work, no overlapping UI applies, bounded truthful request outcomes, and latest-canonical convergence once physical progress resumes.

## Recommendations

1. **Rebuild from current upstream, not the stale patch text.** Create a clean implementation branch/worktree from `44774ffafc74dc22696cd9bf6189f6650a9cc1a0`; preserve the old PR head only as historical reference. Do not carry `37047b39` or the deleted contract-ledger hunks.
2. **Commit 1 — `fix: bound workspace selection mirror ownership`.** Replace the linked physical tail with at most one active physical operation and one coalesced latest pending demand. Timeout/supersession releases exact logical waiters and immediately cancels/joins deadline tasks, but never starts a second UI apply until the active physical task exits. Preserve all revision, context, deferred-UI, and peer fences; return converged/deferred/invalidated/cancelled outcomes.
3. **Commit 2 — `fix: retire invalidated auto-selection mirror owners`.** Carry `ContextKey` through mirror demand/waiters, add exact generated worker/task records, fence before dequeue and after every suspension/yield/commit, distinguish settled from converged tickets, bound `finish`, let `invalidate` interrupt it, preserve other same-tab owners plus one committed-state repair demand, and ensure connection removal advances after the bound.
4. **Commit 3 — `test: stress selection mirror recovery lifecycle`.** Retain and strengthen the five historical contracts. Add deterministic 100-1,000 iteration timeout/completion/cancellation races; repeated supersession, ABA, peer close, binding rebind, same-tab shared ownership, escape-budget, deadline cancellation, physical-exit, and persistent connection teardown tests. Assert O(1) pending state, maximum one inner physical apply, exactly-once waiter settlement, immediate deadline disappearance, and eventual zero physical/logical state after gates release.
5. **Address maintainer A's comment directly.** Reply with the refreshed base/head SHAs, explain the current-main re-author and dropped obsolete commit, provide clean exact-head CI/test receipts, and request focused reviews from owners of workspace selection/UI presentation and MCP connection/binding lifecycle.
6. **Address the collaborator's comments directly.** Report sustained stress seeds/iterations, repeated supersession and invalidation results, separate logical-versus-physical reclamation counters, immediate deadline cancellation evidence before original expiry, same-tab replacement progress, and final zero-state receipts after releasing noncooperative gates.
7. **Validation before review.** Run focused coordinated suites for `WorkspaceSelectionCoordinatorTests`, `MCPReadFileAutoSelectionCoordinatorTests`, `PersistentAgentModeMCPReadFileConnectionTests`, and unchanged `MCPCodeStructureWorktreeTests`; then formatter/lint, broader/full tests, and a live two-window upstream issue 457 CE MCP/CLI reproduction-and-recovery check on the exact implementation head. Verify GitHub `headRefOid` equals the tested SHA.
8. **PR update strategy.** Prefer updating the existing PR only after the reconstructed series is reviewed locally. Any history rewrite/`--force-with-lease` requires explicit user approval immediately beforehand. If the existing PR proves impractical, open a replacement before closing upstream PR 472; do not close upstream issue 457 without current-head evidence that the provider-level wedge is fixed.

## Execution Outcome (Orchestrate Loop, 2026-08-24)
- Implemented in isolated worktree `<worktree>` on a local recovery branch, based at `44774ffafc74dc22696cd9bf6189f6650a9cc1a0`.
- Final uncommitted diff: 10 files, +1171/-153. No commit, push, force-push, branch deletion, GitHub mutation, or visible app launch occurred.
- Correctness review converged after three passes; a separate refactor review found no worthwhile simplification.
- Validation passed: build; `WorkspaceSelectionCoordinatorTests` 34/34; `MCPReadFileAutoSelectionCoordinatorTests` 27/27; persistent MCP connection integration 24/24; unchanged code-structure suite 9/9; formatter; strict lint; and `git diff --check`.
- Full suite executed 4,715 tests. Two transient diff/stdio failures passed focused reruns. Three consistently failing Codex fallback tests exercise local `strictModeRequiresApproval` behavior outside the changed paths and remain an external baseline issue.
- Live CE MCP validation completed after explicit relaunch approval. In the debug app window, authoritative read auto-selection advanced sequence 6→7 in 84.5 ms, an immediate `manage_selection clear` completed within two seconds, and probe drain completed in 0.1 ms with idle worker, no pending work, and zero waiters. Two replacement connections also drained in 0.2 ms and left all canonical/mirror lane, worker, pending, and closing-context counts at zero after exit. The sibling window remained responsive (selection snapshot 0.09 s; indexed search 2.01 s). A truly cancellation-ignoring physical mirror park was not injectable through the live diagnostics surface; the XCTest-only gate remains the deterministic evidence for that path. Structural-file reads separately encountered `tool_execution_structure_settlement_busy` while auto-selection counts were all zero, confirming an unrelated pre-auto-selection settlement issue rather than upstream issue 457.
- Proposed commit split remains: (1) `fix: bound workspace selection mirror ownership`; (2) `fix: retire invalidated auto-selection mirror owners`; (3) `test: stress selection mirror recovery lifecycle`.

## Preventive Measures
- Treat canonical durability, request settlement, physical task lifetime, and presentation convergence as separate typed outcomes in future asynchronous selection work.
- Require exact owner/generation fencing before dequeue and after every suspension for replaceable workers.
- Pair every timeout with lifecycle accounting and a test proving the losing deadline/task exits promptly; never equate clearing a handle with physical reclamation.
- Preserve O(1) queue/pending-state invariants under deliberately cancellation-ignoring tests.
- Record base SHA, tested head SHA, stress seed/iterations, and final lifecycle counters in concurrency-sensitive PRs.
- Keep durable investigation reports for agent-originated fixes so later maintainers can recover the reasoning without the original chat session.

## Publication Handoff (2026-08-24, supersedes the uncommitted status above)

### Local publication state

- Branch: the local recovery branch
- Exact base: `44774ffafc74dc22696cd9bf6189f6650a9cc1a0` (`upstream/main` at reconstruction time)
- Exact local head: `9ab7c673821d86c1241621cfc66e913b09f07bd6`
- Clean tracked/untracked worktree at handoff.
- Exact atomic series:
  1. `cb8cd1c8b105dbc189a41e10e813c4bc149b34db fix: bound workspace selection mirror ownership`
  2. `d580008248bcc450a55159d2add1a081299d0fee fix: retire invalidated auto-selection mirror owners`
  3. `9ab7c673821d86c1241621cfc66e913b09f07bd6 test: stress selection mirror recovery lifecycle`
- Diff from the reconstruction base: 10 files, +1171/-153. `MCPCodeStructureWorktreeTests.swift` is unchanged. Historical `37047b39`, deleted ledger changes, and obsolete selected-scope edits are absent.
- Each commit was staged by exact path, reviewed with staged status/stat/full diff plus `git diff --cached --check`, and passed `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit` immediately before commit.

### Validation receipts

- Exact committed-head `RepoPrompt` product build passed in 22.9 s.
- Inner coordinator: `WorkspaceSelectionCoordinatorTests` 34/34.
- Outer coordinator: `MCPReadFileAutoSelectionCoordinatorTests` 27/27.
- Persistent teardown/replacement: 24/24.
- Unchanged code-structure boundary: 9/9.
- Formatter, strict lint before commit, and exact-head PR-ready lint passed.
- Exact-range `pr-ready` used a non-persistent Git config overlay selecting `upstream/main..HEAD` (3 commits, 10 paths). It passed whitespace, staged/outgoing secret scans, guardrails, clean-tree validation, path selection, and strict lint. Root tests ran 4,715 tests with 11 skipped and exactly the three known Codex fallback failures. Because `pr-ready` stops on the root-test phase, the selected product-build phase was then run separately and passed.
- Baseline disclosure: a pristine detached worktree at exact base `44774ffafc74dc22696cd9bf6189f6650a9cc1a0` ran `make dev-test FILTER=CodexFallbackFIFOTests`. It executed 30 tests twice (seeded attempt and cold retry); both runs failed the same three tests with `strictModeRequiresApproval`: `testFollowUpDuringInitialHookDiscoveryCoalescesGateAndPreservesRun`, `testIdlePumpFallbackWaitsForHookReviewBeforeClaimingHeadOrAttachments`, and `testTerminalSuccessorFallbackWaitsForHookReviewBeforeSuccessorClaim`. This establishes that the exact PR-ready failures pre-exist the implementation.
- The first exact-head full run also surfaced `ContextBuilderRunLifecycleTests.testRealConnectionCleanupCannotEraseContextBeforeCommit`; its focused rerun passed 1/1, so it is recorded as transient and unrelated.
- Final exact-range `.agents/skills/rpce-contribution-check/scripts/preflight.sh push` passed without pushing: 3 outgoing commits, 55.33 KB scanned, no leaks, guardrails clean, worktree clean.

### Deterministic stress and reclamation evidence

- The inner pump exercises 100 later demands behind a cancellation-ignoring parked physical apply and asserts one active physical worker, at most one pending latest demand, zero obsolete waiters/deadlines, maximum concurrency one, latest-only promotion after release, and created == exited. Completion/timeout/caller-cancellation is repeated for 30 deterministic iterations with exactly-once settlement and eventual zero.
- The outer coordinator repeats invalidation/replacement for 50 deterministic iterations, separately exercises 64 settlement-history cycles, preserves a live same-tab sibling owner, fences a retired worker from successor tickets, and reaches zero canonical/mirror lanes, active/retired workers, pending/in-flight batches, waiters, and deadlines after release.
- Persistent connection removal is bounded while a mirror is physically parked; after release it proves zero canonical/mirror lane, worker, pending/in-flight, retired-task, waiter, and deadline counts.

### Live upstream issue 457 receipt

- Smoke launch/packaging had already been explicitly approved and completed; the smoke passed using `/usr/local/bin/rpce-cli-debug`.
- Strong capture: one window, workspace, tab, and connection, binding generation 12.
- Authoritative read sequence advanced 6 -> 7; the probed read changed selection in 84.5 ms. Immediate `manage_selection clear` returned inside 2 s. Drain target 7 completed in 0.1 ms (settle 0 ms) with no pending work, no waiters, and idle worker.
- After connection exit, both windows reached zero canonical/mirror lanes, workers, pending/closing state within 1 s and the limiter record disappeared. The sibling window remained healthy: selection snapshot 0.09 s, indexed search 2.01 s.
- The live MCP diagnostics surface does not expose the XCTest-only cancellation-ignoring mirror gate (`setReadFileAutoSelectionMirrorGateForTesting`), so live testing proves bounded ordinary read/mutation/drain/replacement/teardown and sibling health, not a truly cancellation-ignoring physical park. The deterministic XCTest gates provide that proof.

### Current PR and lease expectation

- Read-only `gh pr view 472 --repo repoprompt/repoprompt-ce` on 2026-08-24: PR is OPEN, non-draft, review required, base `main`, head repository owner `mplibunao`, head branch `bugfix/selection-mirror-wedge`, head OID `37047b3900d9b49eed277e0a7fe6481d4c738ade`.
- A safe fetch confirmed `refs/remotes/origin/bugfix/selection-mirror-wedge` is exactly `37047b3900d9b49eed277e0a7fe6481d4c738ade`.
- The only intended publication command, after immediate explicit approval and orchestration lease grant, is an exact force-with-lease update of that branch from local head `9ab7c673821d86c1241621cfc66e913b09f07bd6`, using the expectation `--force-with-lease=refs/heads/bugfix/selection-mirror-wedge:37047b3900d9b49eed277e0a7fe6481d4c738ade`. No push or GitHub mutation has occurred.
- An orchestration push request was pending. It was a ledger request only; no lease was granted and no remote action occurred.

### Draft maintainer reply (not posted)

A reply to maintainer A and the collaborator was drafted and not posted. It gave the rebuilt base and head, what each of the three commits does, the stress and reclamation evidence above, the focused receipts, the three pre-existing Codex fallback failures, the live receipt and its limit, the force-with-lease plan, and the areas to focus review on.

### Hosted exact-head CI result (2026-08-24)

Exact-head CI run `32711432509` completed at `9ab7c673821d86c1241621cfc66e913b09f07bd6` with seven successful jobs and one changed-path-related failure. Style, Provider Tests, Secret Scan, app shards 2/3/4, and the Sentry-enabled build passed. App shard 1 built both products successfully, then `WorkspaceSelectionCoordinatorTests.testRepeatedMirrorCompletionTimeoutAndCancellationSettleExactlyOnceAndRepair` failed because the 20 ms deadline returned `.deferred` before the asynchronously enqueued cancellation handler returned `.cancelled` in cancellation-mode iterations 2, 8, 11, 14, 20, 23, 26, and 29. This test and the cancellation/deadline arbitration it exercises were added by commit `9ab7c673`, so the hosted failure is classified as changed-path-related timing/order behavior, not a pristine baseline failure or runner infrastructure issue. No rerun, workflow mutation, code edit, or follow-up push was performed; remediation requires returning to the parent for a decision and a fresh review/validation cycle.

### Follow-up publication and CI status (2026-08-25; not posted)

- The cancellation assertion was made deterministic without changing production semantics. Follow-up commit `621b6b75b01604b5e8b48bba6c9ac73296e05294` (`test: make mirror cancellation race deterministic`) passed focused stress, the complete coordinator suite, format/lint/diff checks, commit preflight, PR-ready validation, and push preflight, then was normally fast-forward pushed to `origin/bugfix/selection-mirror-wedge`. Upstream PR 472 and the fork ref were verified at that exact SHA.
- Exact-head run [`32717191720`](https://github.com/repoprompt/repoprompt-ce/actions/runs/32717191720) passed Style, Provider Tests, Secret Scan, app shards 1/3/4, and the Sentry-enabled build. App shard 2 failed in the pre-existing `ContextBuilderRunLifecycleTests.testRealConnectionCleanupCannotEraseContextBeforeCommit` path; all three assertions at lines 930, 1050, and 1099 expected `context detached during response drain` but observed `context retained after peer EOF cleanup`.
- Reproduction/classification evidence: the published PR head passed eight focused iterations and reproduced the same three assertions on iteration 9. Pristine reconstruction base `44774ffafc74dc22696cd9bf6189f6650a9cc1a0` passed 20/20 focused iterations, and first architecture commit `cb8cd1c8` passed 12/12. Causal inspection found that this test does not enqueue read-file auto-selection work and its detached-context commit takes the `alreadyFinishedAutoSelection` path, bypassing upstream PR 472's mirror-finish behavior. The most plausible classification is an unrelated latent asynchronous cleanup/finalization ordering race, with moderate rather than absolute confidence because the pristine sample did not reproduce.
- A failed-job-only rerun was attempted with `gh run rerun 32717191720 --failed --repo repoprompt/repoprompt-ce`, but GitHub rejected it: `Must have admin rights to Repository.` No workflow was rerun, no code or history was changed, and no PR discussion/metadata mutation occurred.

### Current proposed maintainer reply (requires user approval before posting)

A second reply, for head `621b6b75`, summarized the same implementation and evidence, disclosed the app shard 2 failure and the rejected rerun, and asked a maintainer to rerun the failed jobs on run `32717191720` before review. It needed user approval before posting.
