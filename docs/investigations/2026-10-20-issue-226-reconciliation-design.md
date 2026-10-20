# Issue #226, gateway commit reconciliation: design review

Date: 2026-10-20. Branch `bugfix/226-per-window-tab-loading` at `f9bedc199` plus the uncommitted stage 1 of work item b. Read-only review; the run's plan stayed local, and the ledger is `docs/ledgers/2026-10-19-issue-226-per-window-tab-loading.md`. Line numbers are from the worktree at the time of the review.

## Scope

The question: after `WorkspaceContentGateway` commits an edit to a workspace the window doesn't show, the gateway reconciles the accepted result into the window's own copy, presents it when the workspace became shown during the submission, registers peer-selection propagation, and updates binding caches. Five review rounds found a new interleaving in that code each time. Is the design sound, or is there a design that closes the class by construction?

Constraints taken as given: no saved tab is deleted, archived, or rewritten except by an explicit edit; an edit to an unshown workspace decodes the canonical document, applies the edit, encodes the whole document, and submits it at the exact canonical revision with `.failClosed`, with no field-merge preparer and no cross-window flush barrier; items b and c land in one pull request; no shared decoded copy for a workspace shown in several windows; the six planning choices stand unless overruled.

Verdict: the reconciliation design isn't sound, and the cause is structural rather than a missing case. The recommended design below removes the reconciliation code instead of fixing it, and closes each finding and each earlier class with four rules. It asks to revisit planning choice 1 and to narrow choice 5.

## Findings

### F0. Three bookkeepings for one fact

A window needs one fact per workspace: which document its copy holds, at which authority revision. The code keeps that fact in three places that advance independently:

| Holder | Advanced by |
|---|---|
| `domainWorkspaceRevisionsByID` and `domainWorkspaceDigestsByID` (`WorkspaceManagerViewModel.swift:5140-5171`) | `applyDomainAuthorityOutcome` after the shown workspace's debounced publish (`:5120`), after a gateway commit (`contentGatewayApplyAcceptedOutcome`, `:6109`), by `suppressSelfEcho` from the *current* canonical snapshot (`DomainWorkspacePresentationBridge.swift:403-418`), and by projection (`applyDomainWorkspaceProjection`, `:5668`) |
| `workspaces[W]`, the copy | Projection, the gateway's merge or replace (`contentGatewayInstallLocalEdit`, `contentGatewayInstallAcceptedCopy`, `:6092-6107`), local edits |
| `projectedDigests` in the bridge, its change detector (`:235`) | Projection, and `suppressSelfEcho` from the current canonical snapshot |

The gateway's `commit` then infers the fact from these: "the copy is at the baseline" from `copyRevision >= baselineRevision`, "this write is still current" from `windowHasNothingNewer`, and "what the UI showed" from a reconstructed `replaced` model (`WorkspaceContentGateway.swift`, `commit`, `presentWriteInShownCopy`, `windowHasNothingNewer`). Every finding in rounds 1 to 5 is an interleaving where one of three inferences is false:

- A. "The copy holds the document its recorded revision names." False after a self-echo (round 5, finding 2), after a superseded write skipped its install, and whenever a merge reads an earlier write's fields as local edits (round 4).
- B. "This window's recorded revision orders writes." False across windows (round 5, finding 3), for a delayed accepted result (round 4), and for a stale no-op (round 3).
- C. "A returned value is still the current value." False for the binding's prompt cache (round 5, finding 4), for the mirror that takes the file tree's selection as the active tab's truth (round 5, finding 1), and for the mirror's reload (rounds 2 and 3).

Each fix added a mechanism that reads more of the three holders, which adds interleavings between them. There is no finite set of checks that makes three independently advanced holders agree; the design has to have one.

### F1. The self-echo hole (round 5, finding 2), traced

`suppressSelfEcho` (`DomainWorkspacePresentationBridge.swift:393-424`) treats any event whose origin is this window's `.appPresentation(windowID:)` as already applied. It then reads `canonicalWorkspaceSnapshot(W)`, which is the *current* canonical, not the event's, and records that revision and digest in both the manager (`applyDomainAuthorityBaseline`) and `projectedDigests`, while keeping whatever model the manager holds.

Interleaving: window X commits an edit to unshown W through the gateway, accepted at r1 (event E1, origin X). Window Y, showing W, publishes at r2 before X's bridge consumes E1 (event E2, origin Y). X's bridge consumes E1: self-echo, `canonicalWorkspaceSnapshot` returns r2, so X records r2 and the r2 digest and keeps its r0 model. X's bridge consumes E2: `project` compares the snapshot digest with `projectedDigests[W]`, which already equals the r2 digest, so W counts as unchanged and the model isn't decoded. X's copy is at r0, recorded as r2. The gateway's own continuation for the r1 write sees `windowHasNothingNewer(than: r1)` false and skips its install. A later prompt-only gateway write from X merges at `copyRevision (r2) >= baselineRevision (r2)`, finds the copy's r0 selection differs from the baseline, treats it as a local edit, keeps it, and marks the copy unsaved. A whole-model save of W from X then publishes the r0 selection over Y's.

Two defects compound here: self-echo is keyed by origin rather than by the command whose document the copy produced, and it refreshes from the current canonical rather than from what the window submitted. A gateway commit on an unshown workspace is never copy-sourced, so it must not be a self-echo at all.

### F2. The mirror reads the file tree as truth (round 5, finding 1)

`contentGatewayMirrorAcceptedEdit` (`WorkspaceManagerViewModel.swift:5934-5983`) reconstructs the UI's "before" state and, at `:5952`, sets the active tab's selection from `fileManager.snapshotSelection()` whenever no mirror is applying. A selection that the coordinator protected from deferred UI snapshots (`protectCanonicalMCPSelectionFromDeferredUISnapshots`) is exactly a selection that the file tree doesn't show, so this read replaces B with A. The function exists only because the gateway installs a reconciled copy and then has to present it; without that install it has no job.

### F3. Propagation is ordered by callback arrival (round 5, finding 3)

`registerMCPSelectionSourceMutation` (`:1003`) allocates a process-wide counter at the moment the source stores the selection, and `acceptMCPPeerSelectionRevision` (`:1026`) accepts a propagation when its counter is higher than the peer's last. For the canonical path the store happens in `didStore`, after the authority accepted the write (`WorkspaceSelectionCoordinator.swift:622-660`), so the counter follows *result arrival*, not commit order. Two windows X and Z committing to one tab at r1 and r2 can have their results arrive in either order, and the counter then disagrees with the authority. `windowHasNothingNewer` is per window, so neither window can see that the other's write is newer.

### F4. The binding cache takes a returned value (round 5, finding 4)

`updateCurrentTabContext` (`MCPServerViewModel+TabContext.swift:4614-4647`) writes `stored.prompt` into `tabContextByConnectionID[connectionID].promptText` after the commit returns, gated only by the connection's binding lifecycle counter, which says whether the binding changed, not whether a newer prompt was stored. `resolveTabContext` serves that cached snapshot (`:3613`), so `prompt get` (`MCPPromptContextToolProvider.swift:162`) and `workspace_context` with `prompt` (`MCPServerViewModel+WorkspaceContext.swift:179`) answer from the cache. Two appends on one connection whose results return out of order leave the older prompt in the cache.

### F5. What the interim state is for

Planning choice 1 has the gateway write the accepted model into the originating window's copy during item b so "a later save from that window can't revert the edit." That install, and everything built to make it safe, is the code under review. The saves it guards against are whole-model saves of an *unshown* workspace from a window. Item b's done-when moves every one of the manager's own whole-model saves to the gateway and removes the offscreen `updateComposeTabStoredOnly`; item c leaves no copy of an unshown workspace. Since b and c ship in one pull request, the interim install protects against a path that the same pull request removes. The ledger's one remaining whole-model save of a possibly unshown workspace, `pollAndSaveStateWithOutcomeAsync(workspaceID:)` suspending across a switch, predates the run and is deferred to item c's switch rewrite.

### F6. `commitExactWorkspaceDocument` has no callers yet

`grep` finds no caller outside its definition. Its `copyUpdate: .replace` install is subject to the same rules below; nothing depends on it today.

## Evaluation of the four options

### (a) Projection as the only path by which committed documents reach a copy

Sound, and it closes inference A by construction: a copy and its recorded revision and digest change together, in one place, from a canonical snapshot. The originating window pays one decode of W on its own commit's event. In item b's interim every other window already decodes W on that event, and in item c only a window showing W decodes anything, so the cost is at most one decode per commit per window that shows W.

The shown workspace keeps the plan's choice 2: a projected change installs the canonical document, and the active tab's live UI state wins its next publish. That rule then covers the originating window's own canonical commits too, including the case where W became shown during the submission, with no separate presentation policy.

How to stop treating gateway commits as self-echo: by operation ID, not by origin. The manager registers the operation IDs of commands whose document came from its own copy. Self-echo is "this event's `operationID` is registered." A gateway commit registers nothing, so every window projects it, the originating one included. An origin change (a new `DomainCommandOrigin` case, or reusing `.appMCP`) would also work and needs no new state, but it keys on the *kind* of caller rather than on the fact that matters, and it leaves F1's second defect, the refresh from the current canonical, in place. Operation IDs fix both.

### (b) Order by the accepted authority revision

Sound for every canonical commit: the working revision is a total order per workspace assigned by the authority at commit, and "delayed" has no meaning against it. A receipt already carries `revisions` (`WorkspaceContentWriteReceipt.committed`). Propagation carries the accepted revision, and a peer acts on a propagation only once its own projection of W has reached that revision, comparing the projected selection with the propagated one.

The shown MCP-source path has no revision at store time: it stores locally, mirrors, and publishes 200 ms later. To order it with the canonical path it needs an accepted revision before it propagates. The recommended way is an immediate publish of the shown workspace for MCP selection source commits only; the alternative is to leave that path as it is and accept the remaining crossing. Both are in rule R3.

### (c) Caches updated only from projected state

Sound. The binding's prompt cache is the only cache in the findings. Its simplest form is no cache: `prompt get` and `workspace_context` read the tab at request time, which `makeTabContextSnapshot` already does for the snapshot built at bind time (`+TabContext.swift:1225`, through `readMCPTabContextComposeSnapshot`). Run-scoped virtual contexts keep an in-memory prompt that isn't the tab's stored prompt; that is a different value and stays.

### (d) Interim b versus c

With b and c in one pull request, the interim state must guarantee only what disk-level safety needs: every canonical write is a `.failClosed` CAS at the canonical revision (unchanged), a whole-model save of an unshown workspace from a window either doesn't exist in b's end state or fails closed at the window's un-advanced revision, and the originating window's copy converges by projection within one event. It need not guarantee that the copy reflects a gateway write in the same main-actor turn. What c makes moot: every copy of an unshown workspace, and with it the merge, the own-copy install, the per-window currency check, and the "became shown" presentation policies.

## Recommended design

Four rules. Each names what it keeps, changes, and deletes.

### R1. One installer per copy

The window's copy of W and its recorded revision and digest for W change in exactly two places:

1. Projection: `applyDomainWorkspaceProjection` (item b) and the shown-model install of the plan's bridge step 5 (item c). They install the canonical document and its revision and digest together.
2. Local edits of content the window holds (its shown workspace and its own ephemeral workspaces): `contentGatewayInstallLocalEdit`, `storeShownTabSelection`, and the UI. These don't touch the revision. The shown workspace's publish outcome advances the revision through `applyDomainAuthorityOutcome`, which is correct because the copy was that document's source.

The gateway's canonical path touches neither. After `backend.commit` returns, it reports the outcome and returns the receipt. Nothing else.

Delete from `WorkspaceContentGateway.swift`: `CopyUpdate`, `ShownWorkspacePresentation`, `presentWriteInShownCopy`, `windowHasNothingNewer`, `merging`, `mergingTab`, `mergedTabs`, `commitResultWillApplyHandlerForTesting`, and the `isCurrent` parameter of `didStore`. Delete from `WorkspaceManagerViewModel.swift`: `contentGatewayMirrorAcceptedEdit`, `contentGatewayInstallAcceptedCopy`, `contentGatewayApplyAcceptedOutcome`, `contentGatewayCommittedState` (its remaining reader is `mutateLocal`'s `.saved` receipt, which can read `domainWorkspaceRevisionsByID` through a narrower accessor). Split `applyDomainAuthorityOutcome` so its issue-clearing side effect stays reachable from the gateway without the baseline advance.

Keep: `mutateLocal`, `contentGatewayMirrorShownEdit`, `contentGatewayPresentShownSelections`, `awaitShownStateSettled` and `contentGatewayShownStateIsChanging` for deciding whether the edit targets the copy or the canonical document (targeting, not reconciliation), the post-decode recheck in `mutate` that routes to the copy when the window started showing W during the read, the tab-loss check, `uniqueTabIdentity`, and the reads.

`commitExactWorkspaceDocument` installs nothing; the bridge projects it.

### R2. Self-echo by copy-sourced operation ID

The manager keeps `copySourcedSubmissions: [UUID: (workspaceID: UUID, digest: String)]`, registered immediately before each command whose document came from the window's copy: `publishWorkingDocumentToDomainAuthority` (`:5056`; the operation ID is already allocated there), the `.saved` shown path (`pollAndSaveStateWithOutcomeAsync` and `saveWorkspaceAsync`, through the client's `save` and `saveFailClosed`), and item c's `flushShownWorkspaceWorkingState`. The digest is the encoded document's `contentDigest`, known before the call.

`suppressSelfEcho(for:)` becomes: if `event.operationID` is registered for `event.workspaceID`, record `event.revisions` and the registered digest as the window's baseline, remove the registration, and return true. It never calls `canonicalWorkspaceSnapshot`. Every other event projects. The suppressible-kind set stays; the origin check goes.

`projectedDigests` is deleted; `project` compares each snapshot digest with the manager's recorded digest for that workspace, the one bookkeeping R1 keeps truthful. `projectedModels` goes in item c as planned. If the outcome returns before the event (the usual order), `applyDomainAuthorityOutcome` has already recorded the same revision and digest and the self-echo is a no-op; if the event arrives first, the self-echo records them and the outcome's apply is the no-op. Both orders leave the same state.

No `DomainCommandOrigin` change. The `Hashable` conformance added in stage 1 can revert once R4 removes its only use.

### R3. Currency and order are the authority's

Receipts: `.committed(revisions, digest, changedTabIDs)` for a canonical write, `.pendingLocal` for a held-content edit. `didStore` reports the stored model and, for a canonical write, the accepted revision; it has no `isCurrent`. A superseded write is one whose accepted revision is below the revision the consumer's projection has reached; the consumer decides that, not the gateway.

`commitTabContext` (`+TabContext.swift:5204`): for a canonical target the fence is the value compare already there, `tab.selection != context.storedSelectionAtRevision`, which is complete without a revision counter (a selection that changed and changed back equals what the context saw, so applying the context's selection loses nothing). For the shown target, the window's own selection revision, advanced by R4. `holdsIntendedSelection` is `storedTab.selection == intendedSelection`; for an accepted canonical write that is always true, because the stored tab *is* the document. The Context Builder `.review` completion check keeps rereading the canonical tab, which handles supersession at the point that cares.

Peer propagation: `MCPSelectionPeerPropagation.sourceRevision` becomes the accepted working revision of W. `propagateMCPSelectionToPeerHosts` sends it to every window that shows the tab, the originating window included when it started showing W during the submission; that replaces `ShownWorkspacePresentation` with the path peers already use. A peer awaits its own projection of W reaching at least that revision (a manager-level `awaitProjectedRevision(of:atLeast:)`, continuations resumed by R1's installers and by teardown; the DEBUG `waitUntilProjected` at `DomainWorkspacePresentationBridge.swift:263` shows the shape, keyed by publication sequence and polling, and should be replaced rather than reused), then compares its projected stored selection with the propagated one. Equal: present it, mirroring into the file tree when `mirrorToUIIfActive` and the tab is the peer's active tab, otherwise `updateComposeTabSelectionPresentation` plus `protectCanonicalMCPSelectionFromDeferredUISnapshots`, both existing seams. Not equal: a newer commit already projected; drop. The peer never stores a selection from a propagation, which is what "presentation only" in the plan means literally. `latestMCPSelectionRevisionByWorkspaceTab`, `acceptMCPPeerSelectionRevision`, and the process-wide `nextMCPSelectionPropagationRevision` go. `MCPSelectionPeerMutationFence` and `canCommitMCPSelectionPeerMutation` stay; they guard manager replacement and closing windows, which revisions don't cover.

The shown MCP-source selection path (`persistSelectionResult` and `transformSelection` when `shownTabSelection` is non-nil and `source == .mcpTabContext`): after the local store and mirror, which stay synchronous, the coordinator awaits an immediate publish of the shown workspace at the window's recorded revision and propagates with the accepted revision. This is one window publishing its own shown workspace, not a cross-window barrier. Cost: one working-journal write per MCP selection call, the same write the debounced publish makes 200 ms later. Conflict behavior is the debounced publish's: `DomainWorkspaceConflictRecoveryPolicy` has only `.failClosed` (`DomainWorkspaceCommand.swift:35-37`), and the shown publish passes nil, so the authority replays and the shown workspace's capture wins, which is choice 2. The reply then carries `.committed`. If the immediate publish is declined, the shown path keeps today's counter for its own propagations and the crossing between a shown source and a canonical source to a third window stays open; it is the pre-#226 behavior and should be recorded as an accepted limit in the ledger. Prompt commits don't propagate and stay `.pendingLocal` (choice 5).

### R4. One source for the window's selection revision

`selectionRevisionByWorkspaceTab` advances inside R1's two installers and nowhere else. The local installer already does this (`contentGatewayInstallLocalEdit` calls `recordSelectionRevisions`); `applyDomainWorkspaceProjection` gets the same call per installed workspace, comparing against the model it replaces, and in item c the shown-model install does. Then delete `advanceSelectionRevisionsForSummaryChanges` (`:5852-5874`), `DomainTabSummary.selectionChangeOrigin` and `attributingSelectionChange(to:)`, `DomainTabSelectionAuthor` (`DomainWorkspaceModels.swift:274`), `WorkspaceRecord.selectionAuthors`, `replaceDocument(attributingSelectionChangesTo:)`, `keepSelectionAuthors` (`DomainWorkspaceContextAuthority.swift:177-220, 1735`), and the summary initializer that takes authors.

Why the store-side attribution isn't needed: it exists so that a summary-digest change from the window's own commit doesn't advance the fence. Under R3 an unshown tab's fence is value-based and needs no counter, and under R1 a shown tab's copy changes only through the installers, so advancing on every install is exactly right, the window's own commits included; a context that made the commit receives the new revision in its `CommittedTabWrite`. In item c the window has no copy of unshown tabs and therefore no counter for them, which is consistent with the value-based fence.

### R5. The binding prompt is read-through

The prompt tool's `promptText` on a binding is a cache of the tab's stored prompt. Drop it: `prompt get` and `workspace_context` take the prompt from `readMCPTabContextComposeSnapshot` at request time (shown tab: live capture; unshown tab: canonical). `updateCurrentTabContext` keeps the binding-lifecycle check, which answers a different question (did the connection rebind during the commit), and stops writing `promptText` into the binding for the prompt tool. Run-scoped virtual contexts, the non-prompt branch at `:4620-4629` that pushes a context to the UI, keep their in-memory prompt as today; that value isn't the tab's. If dropping the cache turns out to touch more call sites than this round should, the fallback is to store the accepted revision beside the cached prompt and replace it only with a value from a higher accepted revision; `.pendingLocal` values are stored in main-actor order and need no revision.

## How each finding closes

| Finding | Rule | Why it can't recur |
|---|---|---|
| 1. `contentGatewayMirrorAcceptedEdit` replaces a protected selection with the file tree's | R1, R3 | The function is deleted. A window that shows the tab presents a canonical selection through the peer path, which presents the projected selection and never reads `fileManager.snapshotSelection()`. |
| 2. Self-echo advances the revision without the model | R2, R1 | Self-echo applies only to a command whose document the copy produced and records the digest that window submitted. Every other document reaches the copy with its revision in one install. No merge exists to read stale fields as local edits. |
| 3. Per-window currency and arrival-ordered propagation | R3 | Order is the authority's working revision. A peer acts after its projection reaches the revision and only if the projection agrees. |
| 4. Delayed append rolls back the prompt cache | R5 | No cache. |
| Local edits during the submit | R1 | The copy keeps them until projection replaces W, as a remote change does today; the active tab's UI wins its next publish (choice 2). |
| Workspace becomes shown mid-submission | R1, R3 | Projection installs the document; presentation comes through the peer path, the originating window being a peer. No presentation policy enum. |
| Whole-tab versus field-level merge | R1 | No merge. |
| Superseded result arriving late | R3 | Its accepted revision is lower; the consumer's projection has passed it; the propagation is dropped and the receipt still reports what was committed. |
| Propagation ordered by callback arrival | R3 | Revision, not counter. |
| Binding caches rolled back | R5, and the per-connection lifecycle counter stays for "did the binding change" | The lifecycle counter answers a yes-or-no question about the binding, not an ordering question about documents. |

## Mechanisms: keep, change, delete

| Mechanism | Disposition |
|---|---|
| Canonical read, tab-loss check, `.failClosed` CAS, receipt cases, `uniqueTabIdentity`, summaries | Keep |
| `awaitShownStateSettled`, `contentGatewayShownStateIsChanging`, the post-decode held recheck | Keep (targeting) |
| `mutateLocal`, `contentGatewayMirrorShownEdit`, `contentGatewayPresentShownSelections`, `contentGatewayInstallLocalEdit` | Keep |
| `MCPSelectionPeerMutationFence`, `canCommitMCPSelectionPeerMutation`, host generations | Keep |
| Per-connection binding lifecycle counter | Keep (binding change, not ordering) |
| `commitTabContext`'s value-based fence for canonical targets | Keep |
| `suppressSelfEcho` | Change: operation-ID keyed, records the submitted digest, no canonical read |
| `project` change detection | Change: compare with the manager's recorded digest; delete `projectedDigests` |
| `applyDomainWorkspaceProjection` | Change: advance selection revisions per installed workspace |
| `MCPSelectionPeerPropagation.sourceRevision` and `propagateMCPSelectionToPeerHosts` | Change: accepted revision, wait for projection, compare, present only |
| Shown MCP-source selection commits | Change: immediate publish before propagation (or accepted limit) |
| `didStore(_, isCurrent:)` | Change: no `isCurrent`; report revision |
| `updateCurrentTabContext`, `prompt get`, `workspace_context` prompt | Change: read-through |
| `CopyUpdate`, `merging`, `mergingTab`, `mergedTabs`, `windowHasNothingNewer`, `presentWriteInShownCopy`, `ShownWorkspacePresentation`, `commitResultWillApplyHandlerForTesting` | Delete |
| `contentGatewayMirrorAcceptedEdit`, `contentGatewayInstallAcceptedCopy`, `contentGatewayApplyAcceptedOutcome` | Delete |
| `advanceSelectionRevisionsForSummaryChanges`, `selectionChangeOrigin`, `DomainTabSelectionAuthor`, `WorkspaceRecord.selectionAuthors`, `replaceDocument(attributingSelectionChangesTo:)`, `keepSelectionAuthors` | Delete |
| `latestMCPSelectionRevisionByWorkspaceTab`, `acceptMCPPeerSelectionRevision`, `nextMCPSelectionPropagationRevision` | Delete |

## Planning choices to revisit

1. Choice 1, "the gateway also writes the accepted model into the originating window's own copy": revisit. Recommended wording: "During item b the originating window's copy takes a gateway write through the bridge's projection of the accepted document, as every other window does; the gateway writes no copy." Reason: the install is the origin of the race class (F0, F1, F2), and its purpose is served otherwise (F5): the whole-model saves it guards against are removed by item b, the one that remains is deferred to item c, and the pull request ships b and c together. `testGatewayEditThenRenameInSameWindowKeepsBoth` still holds, because the rename reads the canonical document, not the copy.
2. Choice 5, pending-local receipts "so MCP prompt commits on the shown tab don't wait for the 200 ms debounced publish": stands for prompt commits. R3 narrows it for MCP selection source commits on the shown workspace, which publish immediately to get an accepted revision. This is a narrowing, not an overrule, and it needs a decision because it adds a working-journal write per MCP selection call.
3. Choice 2 stands and becomes the only rule for every document that reaches a shown copy from outside its UI, including the window's own canonical commits. Its accepted limit should be written down: a canonical selection commit to a tab that some window's UI shows as active is overwritten by that window's next capture unless the propagation mirrored or protected it there, which is today's behavior for cross-window writes.
4. The stage 1 decision to record selection authors in the store (ledger, item b) is implementer work from a review finding, not a planning choice; R4 deletes it. Called out because it's committed-to work in the worktree.

## Risks and what could regress

- Stored edits in non-active tabs of a shown workspace are replaced when a canonical commit to that workspace projects. This is today's behavior for a remote write and choice 2. Under the new rules the originating window commits canonically to W only while W is unshown; the exposure is the "became shown mid-submission" window, which choice 2 already covers.
- The originating window decodes W on its own commit's event. In item b every other window already does; in item c only a window showing W does. Item d's measurement sees it.
- The immediate publish for MCP selection sources adds a working-journal write per call. A conflict replays, so the shown workspace's capture wins as it does 200 ms later today. Fail-closed isn't appropriate there, by choice 2.
- The peer's wait for projection must end when the window closes or the bridge stops; resume the continuations in teardown. No timeout is needed, because the event stream delivers or the window closes.
- A propagation can be dropped when the peer's projection already holds a newer selection; the peer then shows the newer one without the older's mirror. That is the correct outcome, and it is the only case where a mirror request is lost.
- Tests that encode the deleted mechanisms fail to compile; the list below names them. `$rpce-test-quality` decides each.
- Nothing here changes the persisted format, the CAS, the tab-loss check, or decision 1.

## Test strategy

Contract-level tests, one contract each, on the runtime-backed fixture (`Tests/RepoPromptTests/Workspaces/RuntimeBackedWorkspaceFixture.swift`). Races use gates, not sleeps.

| Test | Contract | Plausible defect | Observable result |
|---|---|---|---|
| `WorkspaceContentGatewayTests.testCanonicalCommitReachesTheOriginatingWindowOnlyByProjection` | R1 | A gateway-side install or revision advance | With the bridge's event consumption gated, after the commit the window's copy and recorded revision for W are unchanged; after the gate opens, the copy equals the decoded canonical document and the revision equals the accepted one |
| `DomainWorkspacePresentationBridge` test, `testSelfEchoAppliesOnlyToCopySourcedCommandsAndRecordsTheSubmittedDigest` | R2 | Origin-keyed suppression; refresh from the current canonical | (a) The shown publish's event is suppressed and the window's recorded digest equals the submitted digest even when another window's commit lands between the publish and the event's consumption; the next event then projects the newer document. (b) A gateway commit's event with the same origin is projected. |
| `BindContextRoutingAuthorityTests.testPeerPresentsSelectionsInAuthorityOrder` | R3 | Arrival-ordered counters; presenting before projection | Two canonical selection commits to one tab from two windows, accepted at r1 and r2, with results delivered to a third window showing the tab in reverse order: the peer's stored tab holds r2's selection, its presentation and protection correspond to r2, and r1's propagation is dropped |
| `WorkspaceDuplicateCleanupTests` or a manager test, `testSelectionRevisionAdvancesOnEveryInstallIntoTheCopy` | R4 | A path that installs into the copy without advancing; a summary-only advance | A local store and a projection each advance the tab's selection revision exactly once; a summary refresh alone doesn't |
| `BindContextRoutingAuthorityTests.testPromptGetReadsTheTabNotTheBinding` | R5 | A cache served after a newer store | Two appends on one connection with results returned in reverse order; `prompt get` returns the tab's stored prompt |

Keep: `testOffscreenContextCommitPreservesNewerSelection`, `testOffscreenContextCommitKeepsASelectionTheWindowHasNotProjected`, `testOffscreenContextCommitPreservesSelectionFromAnotherWindow` (value-based fence), `testConflictingTabEditDoesNotReplaceCanonicalWinner`, `testEditRefusedWhenDecodeLosesStashedTabs`, `testMetadataEditPreservesUnshownComposeAndStashedPayloads`, `testGatewayEditThenRenameInSameWindowKeepsBoth`, the switch-wait tests, `testPromptAppendDuringAnotherAppendToAnUnshownTabKeepsBoth`, `testRefusedStickyPromptCommitFailsTheCallAndKeepsTheBindingPrompt` (reshaped: the call fails and the tab is unchanged), the three bind-lifecycle tests, and `testStickyBindingEditsUnshownWorkspaceWithoutChangingShownTab`.

Delete or fold: `testAcceptedWriteKeepsNewerRevisionRecordedDuringSubmit`, `testLocalEditDuringSubmitAndGatewayEditBothReachLaterSave`, `testCommitAcceptedAfterItsWorkspaceBecomesShownFollowsItsMirrorPolicy`, `testPromptCommitAcceptedAfterItsWorkspaceBecomesShownKeepsTheSelectionMadeMeanwhile…`, `testPromptCommitIntoACopyBehindItsBaselineLeavesTheSelectionMadeMeanwhile…`, `testUnshownSelectionCommitSupersededBeforeItsResultArrivesLeavesTheWindowSh…`, `testLaterStoredUnshownSelectionReachesTheWindowShowingIt`, `testUnmirroredSelectionCommitLeavesTheFileTreeWhenItsWorkspaceBecomesShown`, `testUnshownSelectionCommitMatchingTheCanonicalTabLeavesTheWindowShowingIt` (all into `testPeerPresentsSelectionsInAuthorityOrder` and its protect branch), `testSupersededContextCommitReportsItsWriteWithoutConfirmingTheSelection` (the receipt reports `.committed(r)`; supersession is the consumer's reread), `testOwnCommitShownByASummaryForAnotherEventKeepsItsRevision` (into `testSelectionRevisionAdvancesOnEveryInstallIntoTheCopy`), and `testPromptReplyDescribesTheTabItWroteWhenTheConnectionRebinds` (the reply is built from the write's returned tab, which R5 doesn't change; keep only if the lifecycle branch still has a distinct observable).

## Order of work

1. R2: self-echo by operation ID, the manager-recorded digest as the bridge's change detector. Smallest change; closes F1 alone.
2. R1: delete the gateway's canonical-path reconciliation. Mechanical.
3. R3: propagation by accepted revision with the projection wait; the shown-source immediate publish, pending the decision.
4. R4: selection revision from the installers; delete the store-side authors.
5. R5: read-through prompt.

Each step compiles on its own, and the tests above are consolidated at the step that makes them possible.
