# Issue #226, peer propagation order: design review

Date: 2026-10-20. Branch `bugfix/226-per-window-tab-loading` at `f9bedc199` plus the uncommitted stage 1 of item b. Read-only review of the peer acceptance rule. No source or test changed. Line numbers are from the worktree at the time of the review. The approved redesign is `docs/investigations/2026-10-20-issue-226-reconciliation-design.md`, rule R3, and the ledger is `docs/ledgers/2026-10-19-issue-226-per-window-tab-loading.md`, lines 108 to 148.

## Scope

A window that shows a workspace receives MCP selection changes made in other windows through peer propagation. A shown-source store targets the workspace its window shows. It stores into that window's copy and takes a process-wide counter in the same main-actor turn, then propagates at once. A canonical-source commit targets a workspace its window doesn't show. It commits through the gateway, and the authority accepts it at a working revision. The answer arrives later, possibly out of order with other answers. The source takes its counter in the answer's turn (`WorkspaceContentGateway.swift:831`, `didStore` before the projection wait at `:839`). Each receiving window waits for its own projection to reach that revision before it decides (`WorkspaceManagerViewModel.swift:7302`).

Each of the last three review rounds found an ordering at a receiving window where the hybrid rule in `acceptMCPPeerSelection` (`WorkspaceManagerViewModel.swift:1093-1118`) ends on the wrong selection. This review answers which acceptance rule, with the least per-tab state, ends on the correct selection for every interleaving of shown-source stores, canonical answers in any order, and the window's own projection.

Decisions taken as given: a canonical propagation includes the accepted revision and the counter. Each window keeps per-tab state for both. A receiving window may store a canonical selection. The outcome matches `main` (`7114d37b7`) wherever the interleaving allows. A shown-source store made after a canonical commit is accepted and before its answer arrives loses to the commit, which is the accepted limit.

Definitions used below. *Counter* is `nextMCPSelectionPropagationRevision`, taken in `registerMCPSelectionSourceMutation` (`:1052`). *Revision* is the authority's working revision. *The copy* is the window's `workspaces[W]`. *The projected selection* of a tab is the selection the window's projection last installed for it. *An ordered store* is a store into the copy that the window took a counter for or that came with an accepted revision, which is the window's own shown-source store or any propagated selection, shown-source or canonical. *Main's outcome* is the selection with the highest counter in store order, because on `main` every MCP selection stored into the source window's copy in the turn of the MCP call, and each peer stored the highest counter it saw.

## Finding

The rule reads "newer" off the copy, and the copy has no provenance. Today's canonical branch (`:1108-1114`) drops a commit below the highest revision the window presented, drops it behind a later shown-source store, and then checks whether the copy's selection equals the commit's or is a value a peer's shown-source store put there. That last check is meant to answer the question "is the copy's selection newer than this commit?" The copy can't answer it. Its value may come from projection, which installs anything at or after the commit's revision. It may come from an ordered store, older than the commit by counter or newer. Or it may come from a local edit. The marker `peerStoredMCPSelectionRevisionByWorkspaceTab` (`:864`) tags only one of those cases. Each round found a value the marker didn't tag:

1. Round 1: a canonical selection stored over a peer's shown-source store kept that store's marker alive, and an older commit replaced a newer one. Fixed by `latestPresentedCanonicalSelectionRevisionByWorkspaceTab` (`:860`).
2. Round 3 (this round): the same overwrite advances the selection revision and invalidates the marker. The rule then drops the next, newer commit, and the window ends on the older one.
3. Found in this review: the window's own shown-source store never sets the marker (`WorkspaceSelectionCoordinator.swift:599` sets it only for `.mcpPeerContext`). Every other window accepts a canonical commit answered after that store, and the store's own window drops it. The windows showing the tab diverge. The accepted limit says the store loses. Today it loses everywhere except in its own window.
4. Found in this review: when the store window has already published a shown-source store and the receiving window has already projected it, the projection installs an equal value and `recordSelectionRevisionIfChanged` (`:1490`) doesn't advance the revision. The marker is unchanged. A canonical commit at a lower revision then overwrites the store, and the copy disagrees with the authority's document at a revision the window has already installed.

The rule needs the authority's selection for the tab at the revision the window has projected. The window already waits for that projection before deciding. It only has to remember what the projection installed for the tab.

## The rule

Per-tab state at each window, keyed by `WorkspaceTabSelectionKey`:

| State | Meaning | Today |
| --- | --- | --- |
| `shownCounter` | Highest counter of a shown-source store this window made or took | `latestShownMCPSelectionRevisionByWorkspaceTab` (`:854`), unchanged |
| `canonicalCounter` | Highest counter of a canonical commit this window made or presented | `latestCanonicalMCPSelectionRevisionByWorkspaceTab` (`:857`), unchanged |
| `projectedSelection` | The tab's selection as this window's projection last installed it, for every tab of every installed workspace | New: `selectionByTabID` on `ProjectedWorkspaceInstall` (`:699`), recorded in `recordProjectedInstalls` (`:1168`) |
| `orderedStoreRevision` | The tab's selection revision right after the last ordered store into the copy | `peerStoredMCPSelectionRevisionByWorkspaceTab` (`:864`), set by every ordered store instead of only a peer's shown-source store |
| removed | | `latestPresentedCanonicalSelectionRevisionByWorkspaceTab` (`:860`) |

The comparison, for a propagation with selection `s`, counter `c`, and optional accepted revision `r`, against the tab's current selection `copy` and selection revision `selRev`:

- Shown-source (`r` is nil): accept when `c > max(shownCounter, canonicalCounter)`. Then store `s` when `copy != s`, set `orderedStoreRevision = selRev`, set `shownCounter = c`.
- Canonical (`r` set), evaluated only after the window's projection has installed the workspace at `r` or later: accept when `c > shownCounter` and `projectedSelection == s` and (`copy == s` or `orderedStoreRevision == selRev`). Then store `s` when `copy != s`, set `orderedStoreRevision = selRev`, set `canonicalCounter = max(canonicalCounter, c)`, and present `s`.

Each clause answers one question.

- `c > shownCounter`: a shown-source store taken after the commit's answer is newer than the commit without ambiguity, because the answer follows the acceptance. This is the decided counter order between a shown-source store and a canonical commit.
- `projectedSelection == s`: the authority's document, as far as this window has projected it, still has the commit's selection for the tab. Anything else at that revision is a later write by the authority's order. That write may be a later canonical commit, a context commit (`MCPServerViewModel+TabContext.swift:5234` writes through `mutateComposeTab` and never propagates), a published shown-source store, or another window's published UI edit. This clause replaces the presented-revision guard. A presented commit at a higher revision has already projected, and the projected selection then differs.
- `copy == s` or `orderedStoreRevision == selRev`: when the copy differs from what the projection installed, something stored since. An ordered store lost to this commit under the two clauses above, and the commit replaces it. Anything else is a local edit the projection didn't make, and the rule keeps it. `main` overwrote local edits by counter, and the "Limits" section covers the choice to keep them.
- No presented-revision state: the projection wait plus the projected selection order canonical commits among themselves. The authority never accepts two commits at one revision.
- `canonicalCounter` is kept only for the shown-source branch. There it applies the accepted limit in the one order the projected selection can't see, which is a shown-source store whose propagation reaches the window after the window presented a later-answered commit.

The source window of a shown-source store runs the same rule on its own copy for commits it receives. Its outcome equals its peers'.

## Interleaving table

Actors: X shows W and makes shown-source stores. Z, Z1, and Z2 don't show W and make canonical commits. P shows W and is the window under test. A is the tab's initial selection. "accept r" is the authority accepting a commit at r. "answer c" is the source's `didStore` turn taking counter c. "proj r" is P's projection installing W at r. "prop" is P processing the propagation. Outcome is P's stored selection after the listed events, before the authority accepts any later publish. Where the store window's later debounced publish of its store re-installs it by projection, that happens the same way on `main` and under this rule, and the table says so.

| # | Case | Events, in main-actor order | Main | Today | Rule |
| --- | --- | --- | --- | --- | --- |
| 1 | Commit answers after the store, P projects the commit before the propagation (traced earlier; `commitArrivesAfterStore`) | Z accept r1 (B); X store c1 (C), P prop stores C; Z answer c2; P proj r1, copy B; commit prop | B | B | B: `c2 > c1`, projected B = B, copy B. X's publish of C later re-installs C in both. |
| 2 | Store's propagation arrives after the commit's (traced earlier; `storeArrivesAfterCommit`) | Z accept r1 (B); X store c1 (C), prop delayed; Z answer c2; P proj r1; commit prop presents B; store prop | B | B | B: `c1 < max(0, c2)` drops the store. |
| 3 | Store after the commit's answer (traced earlier; `storeAfterTheCommitAnswer`) | Z accept r1 (B); Z answer c1; P proj r1; commit prop presents B; X store c2 (C), prop | C | C | C: `c2 > c1`. |
| 4 | Older commit after a newer commit and a store (`olderCommitAfterNewerCommitAndStore`, round 1's finding) | Z1 accept r1 (B); Z2 accept r2 (C); P proj r2, copy C; Z2 answer c1, prop presents C; X store c2 (D), prop stores D; Z1 answer c3, prop | D | D | D: projected C ≠ B drops r1. |
| 5 | Store between two commit answers, in revision order (this round's finding) | Z1 accept r1 (B); Z2 accept r2 (C); P proj r2, copy C; X store c1 (D), prop stores D; Z1 answer c2, prop; Z2 answer c3, prop | D by store order; the accepted limit says C | B | C: r1's prop is dropped (projected C ≠ B); r2's prop has `c3 > c1`, projected C = C, copy D with a valid marker, so it stores C. |
| 6 | Commits answered in reverse revision order (`testPeerPresentsSelectionsInAuthorityOrder`, round 5's finding 3) | Z1 accept r1 (B); Z2 accept r2 (C); Z2 answer c1; Z1 answer c2; P proj r2; both props | C | C | C: r1's prop sees projected C ≠ B. Same in either processing order. |
| 7 | Store between two reversed answers | Z1 accept r1 (B); Z2 accept r2 (C); Z2 answer c1, P proj r2, prop presents C; X store c2 (D), prop stores D; Z1 answer c3, prop | D | D | D: `c3 > c2` passes, projected C ≠ B drops r1. |
| 8 | P's own shown-source store, then a commit answered later (found here) | P proj r1 after Z accept r1 (B), copy B; P stores c1 (C) as source, propagates to Q; Z answer c2; commit prop at P and at Q | B at P and Q | C at P, B at Q | B at both. At P the projected selection is B, and the copy's C has a valid marker because the own store sets it. |
| 9 | Store published and projected before the commit propagates (found here) | Z accept r1 (B); X store c1 (C), P prop stores C; X publishes C at r2; P proj r2, copy C unchanged, marker valid; Z answer c2; commit prop | B at propagation, then C once X's save projects | B, and nothing re-installs C | C: projected C ≠ B drops the commit. Equals `main`'s outcome after its projection. |
| 10 | Context commit between the acceptance and the propagation | Z accept r1 (B); Z answer c1, prop delayed; context commit E at r2; P proj r2, copy E; commit prop | E | E | E: projected E ≠ B. |
| 11 | Stores propagated in reverse counter order | X1 store c1 (C); X2 store c2 (D); P gets D then C | D | D | D: `c1 < c2`. |
| 12a | Cycle, P projects the higher revision first | Z2 accept r2 (B2); Z1 accept r1 > r2 (B1); P proj r1, copy B1; Z1 answer c1, prop presents B1; X store c2 (D), prop stores D; Z2 answer c3, prop | D | D | D: projected B1 ≠ B2 drops r2. |
| 12b | Cycle, P has projected only r2 when r2's propagation runs | Z2 accept r2 (B2); Z1 accept r1 > r2 (B1); P proj r2, copy B2; Z1 answer c1, prop waits for r1; X store c2 (D), prop stores D; Z2 answer c3, prop stores and presents B2; P proj r1, copy B1; r1's prop | D | B1 in the copy, B2 presented | B1 in the copy, B2 presented. See the section on the cyclic case. |

Rows 1, 2, 3, 4, 6, and 7 are the existing contract rows and keep their outcomes. Rows 5, 8, and 9 fail today and pass under the rule. Row 10 passes today and stays the reason the projected-selection clause exists. Row 12b is the one the decisions can't order.

## The cyclic case

Row 12: commit K2 is accepted at r2, commit K1 at r1 above it, K1's answer arrives, a shown-source store D is made, then K2's answer arrives. The decisions fix three pairwise orders. D is newer than K1, because D's counter follows K1's answer and so K1's acceptance. K1 is newer than K2, by revision. K2 is newer than D, by the accepted limit, because D was stored after K2's acceptance and before K2's answer. Those three form a cycle, and whichever selection a window ends on breaks one decided order. `main` ends on D, because on `main` the store order was K2, K1, D.

When P's projection has passed r1 before it processes K2 (row 12a), the rule sees that the authority's document no longer has K2's selection and drops it, and the window ends on D, as `main` does. When P has projected exactly r2 at that moment (row 12b), nothing P can observe says K1 exists: K1's propagation is still waiting for P's projection, and the document P has is K2's. The rule stores and presents B2, then projection installs B1, then K1's propagation is dropped because D's counter is above K1's. P's copy ends on the authority's document at the highest revision it projected, with B2 shown until the next presentation. The store window X's debounced publish of D is accepted above r1, and its projection puts D back in P's copy. No per-tab rule can end 12b on D at the moment K2's propagation runs, because what decides it hasn't reached P.

The closest rule is the one above. It never stores a canonical selection over one the projection has superseded, which bounds 12b's damage to the time between K2's propagation and the next projection or publish, and 12a, the order where P can see the newer commit, ends on `main`'s outcome. Today's rule gives the same two outcomes for row 12. The rule doesn't regress there.

## Limits

- Rows 2 and 5 show the accepted limit: a shown-source store made after a commit's acceptance and before its answer loses to the commit. The projected-selection clause narrows it to the time before the store's own publish projects. Once the store window has published the store and the receiving window has projected that revision (row 9), the store stays. That is also `main`'s outcome once its projection ran.
- A local edit the receiving window made to the shown workspace after its last projection, and that no ordered store replaced, is kept over a canonical commit answered later. `main` stored the commit over it by counter and then re-published the local edit from the active tab's live UI, so for the active tab both end the same. For another tab of the shown workspace, whose stored selection only changes on a tab switch, `main` lost the edit and this rule keeps it. Dropping the marker would match `main`'s letter and remove one field. Keeping it costs nothing new, and this review recommends keeping it.
- The projection installing a document over a newer-by-counter propagated store in the copy (row 3 with the projection after the store) is not an acceptance decision. The copy has the authority's document until the authority accepts the store window's publish, as on `main` and today.
- A window with no projection (no bridge, or the workspace dropped from the catalog) never accepts a canonical propagation, as today: `awaitProjectedInstall` returns nil and the propagation skips it (`:7302`).

## Code changes

`Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift`:

- `ProjectedWorkspaceInstall` (`:699`): add `selectionByTabID: [UUID: StoredSelection]`. `selectionRevisionByTabID` stays, because context-commit receipts read it.
- `recordProjectedInstalls` (`:1168`): fill `selectionByTabID` from the installed workspace's compose tabs, in the same loop that fills `selectionRevisionByTabID`. The self-echo record of a command the copy produced (`applyCopySourcedCommit`, `:5437`) records the copy's own selections, which are the authority's document at that revision.
- Delete `latestPresentedCanonicalSelectionRevisionByWorkspaceTab` (`:860`) and its two uses (`:1109`, `:1116`).
- Rename `peerStoredMCPSelectionRevisionByWorkspaceTab` (`:864`) to say it marks every ordered store, and `recordPeerStoredMCPSelection` (`:1120`) to match. The body is unchanged.
- `acceptMCPPeerSelection` (`:1093`): the shown-source branch is unchanged. The canonical branch becomes: `guard latestShown < sourceRevision, projectedInstallByWorkspaceID[workspaceID]?.selectionByTabID[tabID] == selection, currentSelection == selection || marker == selectionRevision else { return false }`, then set `latestCanonical`. Read the install record inside the method rather than taking the one `awaitProjectedInstall` returned. The comparison then uses the latest install.
- `propagateMCPSelectionToPeerHosts` (`:7286`), fallback branch without a coordinator (`:7328`): call the marker method after every store, not only when `acceptedRevision == nil`.
- Doc comments on `acceptMCPPeerSelection` and the marker method: the canonical rule and what an ordered store is.

`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift`:

- `persistSelectionResult` (`:599`): after `persist` succeeds, set the marker when `source.isMCPSelectionSource`. That covers the window's own `.mcpTabContext` store and both kinds of `.mcpPeerContext` store.
- `transformSelection` (`:741`): after `persist(after, for: identity)` succeeds, set the marker when `source.isMCPSelectionSource`.
- `WorkspaceSelectionHost` (`:97-103`): rename the marker method and update the two doc comments. The default stays a no-op.

`MCPSelectionPeerPropagation` (`WorkspaceSelectionCoordinator.swift:20`) is unchanged: it already has the counter and the accepted revision.

Per-tab state removed: `latestPresentedCanonicalSelectionRevisionByWorkspaceTab`. Per-tab state added: the projected selection, on the install record the window already keeps.

## Test specification

One table-driven contract test, extending `MixedPropagationRow` in `Tests/RepoPromptTests/MCP/Control/BindContextRoutingAuthorityTests.swift:1160` and its driver `assertPeerEndsOnTheLatestChange` (`:1183`), on the runtime-backed fixture with the test hooks it already uses: `commitResultWillReturnHandlerForTesting` to run work in a commit answer's turn, `setDomainWorkspaceEventConsumptionWillBeginHandlerForTesting` plus `ArrivalGate` to hold a window's projection, and `awaitProjectedInstall` to wait for it. Contract: a window showing the tab ends on the selection the rule names, and presents it only when the projection has it. The existing four rows stay. New rows:

| Row | Setup | Expected at the peer | Fails today because |
| --- | --- | --- | --- |
| `storeBetweenTwoCommitAnswersInRevisionOrder` (table row 5) | Committers Z1 and Z2 commit B then C. Hold both answers. After the peer projects the second commit, store D on the store window and propagate it to the peer. Release the answers in revision order. | Stored C, presented C; D's mirror policy no longer visible | The window ends on B: the first answer overwrites D and invalidates the marker, and the second answer is dropped |
| `ownStoreBeforeTheCommitAnswer` (row 8) | A window showing the tab stores C as the MCP source and propagates to a second window showing the tab. A committer's answer for B, accepted before the store, is held until both have C. Release it. | Both windows store B | The store window keeps C and the other window takes B |
| `storePublishedBeforeTheCommitPropagates` (row 9) | Hold the committer's answer for B. Store C on the store window, propagate, force the store window's working publish, and wait for the peer's projection of that revision. Release the answer. | Stored C; nothing presented for B; the peer's copy equals the canonical tab | The peer stores B over C, and its copy differs from the canonical tab at a revision it has installed |
| `contextCommitBeforeTheCommitPropagates` (row 10) | Hold the committer's answer for B. Commit E through `commitTabContext` from a bound connection. Wait for the peer's projection. Release the answer. | Stored E; nothing presented for B | Passes today. It pins the reason the projected-selection clause can't become a value compare on the copy. |

Each row asserts `shownTabSelection(for:)` on every window that shows the tab, the presented selection through `promptViewModel.currentComposeTabs`, and, for a row run with `mirrorToUIIfActive`, the file tree, as `assertWindowsShowingTheTabEndOnTheLaterCommit` (`:1063`) does. Row 12 doesn't get a test. 12a is row 4 with a third commit and would add a second contract to the same row, and 12b would pin an outcome the decisions can't order. If the no-marker variant from "Limits" is chosen instead, `ownStoreBeforeTheCommitAnswer` keeps its expectation and no row changes.

Deliberate breakages that each row must catch, for the `$rpce-test-quality` check:

- Remove the projected-selection clause. Rows 5, 9, and 10 fail.
- Stop setting the marker on own stores. Row 8 fails.
- Stop setting it on canonical stores. Row 5 fails.
- Restore the presented-revision guard in place of the projected-selection clause. Row 9 fails.
