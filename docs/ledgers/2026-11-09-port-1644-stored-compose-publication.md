# Run ledger: Port upstream PR 1644 (stored compose-tab publication)

Request: port upstream PR 1644, "Keep file selection responsive across windows" (merge `f713d289c`, commits `bdf959e34` and `260f63a60`) · Plan: a local Deep Plan plan, not committed

Make `WorkspaceManagerViewModel.updateComposeTabStoredOnly(_:inWorkspaceID:)` skip a tab equal to the stored one and write a changed tab with one `workspaces` assignment instead of two, recording the selection revision after it. Leave out upstream's session-carrier-index publication hint, which needs Overseer infrastructure the distribution lacks.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Stored-only method change and its tests | done | engineer · Orchestrate 1/1: port 1644 stored-only publication | `perf(workspace): publish a stored-only tab update once` |
| 2. Live check on the integrated build, then the pull request | pending | | |

## Scope

- Decision: the port applies in part. The equality no-op, the one-assignment write and the revision recorded after it apply here. Upstream's `composeTabPresentationPublication` hint, its carrier-index assertions and its `SessionAdminProductionOrganizerTests.swift` changes don't. They depend on the session carrier index, `modelRoutingTabIndexes` and `workspaceChooserPresentation`, which came with upstream PRs 1363, 1139 and 1205 and aren't in the distribution. Source: task brief and a code search of `Sources/`, `Tests/` and `docs/`.
- Decision: equal MCP selection propagation is already write-free here, because the coordinator's `persist` and the peer fallback skip equal selections. The cross-window gain is one `workspaces` publication instead of two per changed propagation in each peer window. Source: orchestrator judgment from `WorkspaceSelectionCoordinator.swift` and `propagateMCPSelectionToPeerHosts`.

## 1. Stored-only method change and its tests

- Decision: compare the whole `ComposeTabState` with its synthesized `==` before any timestamp is set. An equal tab returns `true` with no publication, timestamp, dirty bump or revision. A changed tab, including one that differs only in `lastModified`, is written as one replacement workspace. Source: approved plan, following upstream.
- Decision: after the assignment, find the workspace and tab again by ID and record the selection revision against them. No observable property publishes after `workspaces` storage is installed here, so this is a precaution. `recordSelectionRevisionIfChanged` checks only that the indexes are in bounds, so stale indexes would revise the wrong tab. Source: approved plan, following upstream commit `260f63a60`.
- Decision: equal writes no longer touch `lastModified`, `dateModified` or the dirty version. Among current callers, two can pass an equal tab:
  - `setActiveChatSessionID` with the ID already stored;
  - Oracle's `ensureTabForSession` (`OracleViewModel.swift:2034`) when the session has no files. The agent's caller inventory found this one. Its tab was already appended, dirtied and saved by `createBackgroundComposeTab` (`PromptViewModel.swift:3122-3127`), so skipping the equal follow-up write loses nothing.

  The MCP write paths stamp `lastModified` before calling, so they still write and still advance the stale-snapshot guard in `MCPServerViewModel+TabContext.swift`. Source: approved plan and orchestrator check of the Oracle caller.
- Decision: three tests in `WorkspaceEphemeralPersistenceTests.swift`:
  - `testStoredOnlySelectionChangePublishesOnce`: a changed selection publishes once. The published workspace has the new selection and both new timestamps, and the manager stores that same workspace. Only the target's dirty version and revision move;
  - `testStoredOnlyNoWriteResultsPreserveState`: equal tabs and missing targets don't publish or change storage, the dirty version or the revision;
  - `testStoredOnlyEqualSelectionEditsStillPublishOnce`: session, prompt and `lastModified`-only edits with an equal selection still write once.

  Left out:
  - upstream's disk round trip and restore, because the save and load paths don't change;
  - the duplicate-routes test, because first-match lookup is unchanged;
  - the carrier and reentry tests, because their infrastructure is absent;
  - the 8-window peer stress test, which mostly exercises unchanged peer fences.

  Source: approved plan, after a design critique of the draft.
- Evidence: against the unchanged method, `make dev-test FILTER=RepoPromptTests.WorkspaceEphemeralPersistenceTests` failed with 17 assertion failures in the new tests:
  - a changed selection published 2 times instead of 1, and the first publication had the old `dateModified`;
  - equal tabs published 2 times instead of 0 and changed the timestamps and the dirty version;
  - each equal-selection edit published 2 times instead of 1.
- Evidence: after the change, these pass:
  - `make dev-format` (formatted only the test file) and `make dev-lint`;
  - `make dev-swift-build PRODUCT=RepoPrompt`;
  - `make dev-test` with these filters: `WorkspaceEphemeralPersistenceTests` (11 tests), `WorkspaceDuplicateCleanupTests` (8), `WorkspaceSelectionMirrorRecoveryTests` (5), `BindContextRoutingAuthorityTests` (11), `MCPExportWatchdogIntegrationTests` (57) and `MCPAskOracleWorktreeTests` (5).
- Review: the agent's Context Builder review didn't find defects in the source or tests. Its one finding was the Oracle caller above, recorded here.
- Refactor gate: the refactor review found nothing material. The fixes applied were cosmetic:
  - the method's doc comment was reworded;
  - `testStoredOnlyNoWriteResultsPreserveState` lost two timestamp asserts that `XCTAssertEqual(manager.workspaces, baseline)` already covers, because `WorkspaceModel.==` compares `dateModified` and `composeTabs`.

  A shared fixture helper for the three tests was rejected as indirection, since their fixtures differ. Afterwards `make dev-format`, `make dev-lint` and `WorkspaceEphemeralPersistenceTests` (11 tests) pass.

## Tooling notes

- The run's RepoPrompt calls went to the debug app running the integrated build.
- The first planning `context_builder` call over MCP came back to the client as interrupted, with no result. Its discovery had already filled the tab's selection, but no chat or export appeared afterwards. The same call through `rpce-cli-debug` on the same tab finished and exported the plan. The cause is unknown: either the MCP client's request deadline or the app dropped the run.
- Each `export_response` export on a worktree-scoped tab was written to the worktree's `prompt-exports/`, while the reply gave a path under the main checkout. This is issue #368. The exports were deleted after use.
