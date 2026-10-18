# PR 156 follow-up: keep the admitted MCP call cancellable after registration

> Investigation report, observed 2026-10-07 through 2026-10-09 on #156, #162, and local builds 48 and 49. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

This file was the working log of the session that finished #156, promoted build 49, rolled it back, repaired the defect that failed acceptance in #162, and promoted build 49 again. It held conductor tickets, process IDs, temporary receipt paths, chat and session identifiers, workspace names, and the state of other tasks that shared production, so it is reduced to a summary of what it recorded.

## #156: admitted-call cancellation

- Defect: run registration removed the token-scoped cancellation action for an admitted MCP call (`removePreparationCancellation` in `ContextBuilderAgentViewModel.swift`). After the run ended, a tab or window close could not cancel the call's post-discovery work, and `performAdmittedMCPCall` let a cancelled task's successful result through.
- Repair: keep the action until the call's cleanup releases its claim, and reject cancelled work in `performAdmittedMCPCall` whatever its result. One regression in `ContextBuilderGracefulShutdownTests` holds the call after discovery, closes the tab, and expects `CancellationError`. It failed on the unrepaired source and passed with the fix.
- Accepted residual from review: a close or cancellation that lands while a generated Oracle export is being written, or during the result handoff after the writer returns, can leave the export under the primary root's `prompt-exports/` while the call answers `CancellationError`. The follow-up is to keep export cleanup ownership through result delivery; a check inside the writer would not cover a cancel that lands after it returns.
- Live check, 2026-10-08: in the debug app, deleting a disposable chat through the sidebar's Delete action while a real `clarify` call was in registered discovery ended the call with `Error: Tool execution was cancelled.` That covers registered discovery; the unit regression covers the interval after discovery.
- A reviewer asked whether runs had become serial again. They had not: claims are per tab, different tabs run concurrently, and the window-level check cancels work only when the window closes. #55 had refused a second Context Builder run anywhere in a window as containment for #6, whose cause was never established.

## #156: startup deadlines removed, watchdog restored

- `d83cf82e` removed the readiness and routing deadlines that #156 had added, because no calibration evidence for their values was found. It restored the indefinite routing call and added one readiness test that cancels one caller while the shared transition is parked. Indefinite startup waits remain an accepted limitation when an operation neither completes nor responds to cancellation.
- `d3ed72f9` restored the upstream `mcpRoutingWatchdogSeconds` diagnostic, one "Still waiting…" warning after 30 seconds without an owned connection, which an earlier #156 commit had removed along with the deadline. The watchdog cannot settle the run or release its tab claim.
- #156 merged as `b101eb56`. #161 changed the build number to 49 and merged as `7e91e6c8`.

## Build 49, first attempt: rolled back

- Automatic approval review refused the production quit twice, because the approval reached the session only through relayed tool content. When the deployment resumed, production was already closed.
- The first launch after the install stopped on the macOS Keychain prompt for the app's secure-storage item. After Keychain authentication, production responded.
- The acceptance matrix failed on the selection row. In an inactive restored tab of the second window, `manage_selection op=set` reported one selected file, and a later `get` returned the original 28. Production was restored to build 48 from the `local/v1.4.0-b48` rollback unit, with tab IDs, active contexts, and Agent Mode settings matching the before-image. Build 49 got no tag or receipt.

## #162: the selection defect and the full-suite failures

- The defect reproduced on build 48. `DomainWorkspacePresentationBridge.project` rebuilt the manager projection from cached models for unchanged workspace digests. An inactive tab's selection update advanced the manager model but not the bridge cache, so a publication from another workspace replaced the pending selection with the older model. `e28f0b8c` repaired the bridge. A regression against the real domain store and bridge failed before the repair and passed after it, and in the debug app the single selected path survived a cross-workspace tab create and close, a later read, the saved document, and a relaunch.
- Whole-branch `pr-ready` then failed on `ContentReadCancellationTests` permit counts. The cause was three test fixtures that loaded the real checkout and left store-owned CodeMap work running after their tests returned: `AgentRunMCPToolServiceSteerResumeTests.makeWindow`, `AgentComposerSubmissionAttemptTests.makeWindow`, and `AgentRunMCPControlledSessionContext`. `fda5196f` and `361a3f17` unload their roots explicitly before window teardown. No assertion or cancellation code changed.
- The next failure was `ConcurrentSameWorkspaceAgentRunAdmissionTests.testCanonicalAdmissionRefreshRejectsDuplicateTabIDWithoutMutationOrDispatch`, where only `activeChatSessionID` differed. The writer was Oracle workspace-switch restoration, which creates a blank chat after the switch and sets its ID. `e04fdd6b` makes the existing awaited reload join the switch tasks already scheduled, and the fixture awaits that reload before taking its baseline.
- Two environmental stalls appeared along the way and were not diagnosed further: skill-catalog workers waiting on LaunchServices metadata calls during test runs, and long-running conductor daemons that failed debug packaging or reported the signing identity missing until each was restarted.
- Follow-ups recorded on #162: the manager's repo-path save baseline when projecting local models, the workspace-list reload route that can also replace pending selections, an intermittent `NSFileHandleOperationException` in `ClaudeCodeAgentProviderGracefulDisposalTests`, and whether the production window-close path needs a root shutdown that touches resources only.
- #162 merged as `c58c212c` after the whole-branch gate passed at `e04fdd6b`, with 1,742 app tests.

## Build 49, second attempt: accepted

- Before the quit, the session waited for another caller's Context Builder run to finish, because Agent Mode inventories do not show Context Builder runs. A fresh rollback archive was taken afterwards.
- Build 49 was installed from `c58c212c`. The Codex and Claude Code client arms passed, and the inactive-tab selection kept its single path through peer publications, later reads, the saved document, and a quit and relaunch. Tab IDs, their order, active contexts, and Agent Mode settings matched the baseline.
- Tag `local/v1.4.0-b49` and its receipt-only release were published on 2026-10-09.
