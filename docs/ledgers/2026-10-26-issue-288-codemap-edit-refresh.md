# Run ledger: CodeMap graph refresh after a file edit

Request: #288

Make an edited file in an indexed Git root show its new symbols in the CodeMap selection graph after the follow-up graph-index pass, without reopening the workspace, then prove it on the debug app and open the pull request.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Shadow generation fix and its two tests | done | pair · #288 W1–W3: shadow generation fix and tests | `fix(codemap): show an edited file's new symbols after the graph-index pass` |
| 2. Debug-app proof of the edit refresh | done | pair · #288 W4: debug-app proof of codemap edit refresh | `docs(ledgers): add the run ledger for issue 288` |

## 1. Shadow generation fix and its two tests

- Decision: the regression test, the fix, and the overlay contract test form one item and one source commit, because the regression test fails until the fix is in. Source: approved plan.
- Evidence: on unchanged source, `testUncommittedEditRefreshesGraphWithoutArtifactDemand` reached a later completed graph-index run (completed-run counter 1 to 2) and then failed: coverage was incomplete with one pending slot, and the edited file's slot was `.pending` at path generation 2. Eight repeated runs failed the same way.
- Evidence: after the fix, both new tests pass, `WorkspaceCodemapGraphIncrementalIndexTests` passes 13 of 13 and `CodemapAutomaticSelectionGraphNativeTests` 3 of 3 (the PR 285 live-precedence test included), and `make dev-format`, `make dev-lint`, and `make dev-swift-build PRODUCT=RepoPrompt` pass. Two throwaway mutations of the resolve check, since reverted, failed test 2: a check that never resolves failed every edit row and both cancellation checks, and a check without the generation comparison showed the stale pre-edit definition.
- Decision: both new tests are `@MainActor`. In a throwaway probe with 7 deliberate failures, a nonisolated async test that returned at once recorded 1 or 2 of them, while one that waited 5 seconds before returning, and a `@MainActor` one, recorded all 7. Test 2's first mutation run also recorded only 7 of 18 failures. This differs from the PR 285 run's minimal probe, which recorded every failure in 80 executions. Source: implementing agent judgment.
- Decision: the marker types in test 1 have a stored property, because CodeMap doesn't record a definition for an empty struct. Test 1 also checks its starting state and that the edited slot's path generation increased, so a broken fixture can't pass it. Source: implementing agent judgment.
- Decision: test 2 asserts that `incrementalReconcileCount` increases as well as `incrementalFallbackCount == 0`, and checks coverage only after a separate sealing publication, because a publication with `enumerationFinished: true` also runs a full reconcile. Source: implementing agent judgment.
- Evidence: the resolving publication removes the shadow before reconciliation runs. Test 2's edit case covers removal at publication, its cancellation case covers the pass-through in `shadowedGraphSlot` under full reconciliation, and the pass-through at the incremental call site has no test. The approved two-test scope stands.
- Evidence: the first run of test 1 used a developer-daemon SwiftPM seed with stale-file warnings naming the #287 worktree, and it passed an assertion this branch's code can't pass (an empty struct counted as a definition). The daemon discarded that build, and the cold rebuild showed the expected failure.
- Evidence: this item neither confirms nor refutes #289. It didn't exercise renames, and `.renamed` shadows behave as before.
- Evidence: the full root suite (`make dev-test`) passed, 1,899 tests in the main bundle and every smaller bundle with 0 failures, and `make guardrails` passed.
- Evidence: the independent review answered four questions with no finding: the resolve check at its three call sites (another pipeline's shadow, a delayed pre-edit publication, terminal states, and the `.pending` slot that invalidation writes), accounting and dirty-scope consistency after publication-time removal, the engine's generation handoff, and whether either test could pass falsely. Its one nit, a citation of the local plan in this ledger's header, was fixed.
- Decision: Context Builder in the run's tab kept the tab's earlier planning prompt instead of the review instructions, and twice hit a provider rate limit. So the review and refactor questions went to its chats directly, with the diff attached as artifacts. Source: orchestrator judgment.
- Decision: the refactor pass made two changes: the existing `testNestedRepositoryGraphUsesValidatedWorktreeBytesAndCompletesWithoutRetry` uses the new `requireReadySnapshot` helper in place of its own copy of that lookup, and `Shadow.pathGeneration` holds the one explanation of where the generation comes from. It kept the two cancellation shadow writers inline and kept `graphSlot(_:resolves:)` beside `shadowedGraphSlot`. Its follow-up found nothing more. The implementing agent applied the changes, because they were small and in its own code. Source: refactor finding, and orchestrator judgment for the routing.
- Evidence: after the refactor, `make dev-format` reported 0 changed files, `make dev-lint` passed, and both focused suites passed again (3 of 3, 13 of 13). The commit preflight passed.

## 2. Debug-app proof of the edit refresh

- Evidence: the debug-app block ran from 18:17 to 18:32 (+0800) on 2026-10-26, under the shared debug-app lock. `make dev-smoke-launch` replaced the running debug app with a build of this branch at `cefd83773` (not dirty), the smoke passed, and `rpce-cli-debug` reached the app. Production RepoPrompt CE kept the same PID and start time throughout and was never driven.
- Evidence: the fixture was a committed 41-file Swift Git repository under the home directory, `Hub.swift` and `Node1.swift` to `Node40.swift`, each `NodeN` holding a `Node(N-1)` property and a marker type with a stored property, opened as a disposable workspace. Indexing completed with 41 of 41 files contributed and no active, queued, or draining batches before the first step.
- Evidence: every scenario passed. Latency is measured from the completed write, or from the `apply_edits` response, to the first `get_code_structure` reply that showed the new marker, no old marker, both files without pending or partial status, and the dependent's edge to the edited file:

| Scenario | File (dependent) | Graph work | Latency |
| --- | --- | --- | --- |
| External edit, not committed | `Node12.swift` (`Node13.swift`) | One replacement job published and completed coverage 0.66 s after the write | 1.70 s |
| `apply_edits` through the debug CLI | `Node30.swift` (`Node31.swift`) | The app's path fence and then the watcher event each started a job. The second published 0.33 s after the response | 1.32 s |
| External edit, then a commit of only that file | `Node20.swift` (`Node21.swift`) | One replacement job published 0.72 s after the write; the commit didn't add CodeMap events of its own | 1.54 s |
| Two edits 0.46 s apart | `Node35.swift` | The second invalidation cancelled the first replacement job mid-run. The next job published 1.03 s after the first write | 1.44 s after the second write. The intermediate marker never appeared |

- Evidence: on the first poll during a replacement job, the dependent sometimes read pending rather than partial, and the next poll was clean every time. That fits the documented rule that a file without a usable graph node reads pending while indexing is incomplete.
- Evidence: seven read-only `codemap_graph_status` calls went to other debug windows without an explicit tab. They didn't change any state.
- Evidence: cleanup returned the debug window to its earlier workspace and tab and deleted the disposable workspace and the fixture repository. The debug app still runs this branch's build. This item didn't test renames, so it doesn't bear on #289.

## Parked decisions

- Should an issue be filed for XCTest dropping assertion failures in nonisolated async tests? Item 1's probe recorded 1 or 2 of 7 deliberate failures when such a test returned at once, so a late failing assertion could pass silently in other async tests in the suite. The PR 285 run's probe recorded every failure in 80 executions, so the trigger isn't pinned down yet. Options: file an issue through `rpce-issue-creator`, or leave it. Recommendation: file it. Blocks: nothing in this run.
- Should an issue be filed for a developer-daemon SwiftPM seed from another worktree producing a test result this branch's code can't produce? Item 1's first test run used a seed with stale-file warnings naming the #287 worktree, and the daemon then discarded that build. Options: file an issue through `rpce-issue-creator`, or leave it. Recommendation: file it, because a seeded build that passes a test it shouldn't can hide a failing change. Blocks: nothing in this run.
