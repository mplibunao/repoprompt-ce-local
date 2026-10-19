# Run ledger: per-window tab loading

Request: #226 · Plan: `issue-226-per-window-tab-loading-2026-10-19.md`

Make each window's `WorkspaceManagerViewModel` keep decoded compose and stashed tabs only for the workspace it shows, so retained tab storage grows by the shown workspace's tabs per added window instead of by the whole catalog. Readers of other workspaces use lightweight summaries or load one workspace on demand through `WorkspaceContentGateway`. The run deletes, archives, and rewrites no saved tab.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| a. Summaries, single-workspace reads, and the gateway | done | pair · #226 item (a): summaries, single-workspace reads, gateway | `feat(workspaces): add workspace summaries and the content gateway` |
| b. Move every reader and writer to summaries and the gateway | pending | | |
| c. Keep only the shown workspace decoded | pending | | |
| d. Measure and run the live journeys | pending | | |

## Decisions carried in from planning

- Decision: the fix deletes, archives, and rewrites no saved tab. Unshown workspaces stay on disk as they are. Source: user.
- Decision: each window keeps decoded compose and stashed tabs only for the workspace it shows. The done-when is #226's acceptance bound, measured with `heap` on the debug app. Source: user.
- Decision: an edit to an unshown workspace decodes the canonical document, applies the edit, encodes the whole document, and submits it at the exact canonical revision with `.failClosed`. The run adds no JSON field-merge preparer and no cross-window flush barrier. Source: user.
- Decision: four work items in expand, migrate, contract order. Source: user.
- Decision: encoded-document retention in the domain runtime (`DomainContextMetadata.documentBytes`, the authority's bootstrap-loaded documents) stays out of this run. #233 tracks it. Source: user.
- Decision: the lighter debug-app measurement protocol: one fresh-launch run per condition, and three when a result falls within 20% of its bound. Source: user.
- Decision: a workspace shown in several windows gets no shared decoded copy. #232 removes the main source of duplicate windows. Source: user.
- Decision: the summary type is not `Codable`, so no encoder or save API accepts it, and an unloaded workspace's empty tab arrays can't reach a save. Source: approved plan.
- Decision: the run adds no shared decoded cache of shown or recently loaded workspaces. On-demand loads of a hidden workspace were near zero in a month of production MCP use. A keep-warm cache waits until the gateway's DEBUG recorder or production use shows frequent repeat loads. Source: approved plan.
- Decision: during item b, a gateway write is durable at once and also updates the originating window's own copy. A later whole-model save from that window then can't revert it. Source: approved plan.
- Decision: when another window changes the shown workspace, the shown window keeps today's behavior: it installs the canonical document, and its active tab's live UI state wins the next publish. Source: approved plan.
- Decision: the gateway refuses a write whose decode lost a compose or stashed tab. Source: approved plan.
- Decision: from item a on, summaries come only from the domain store and never from a decoded model. Source: approved plan.
- Decision: a gateway receipt is either committed (canonical revision and digest) or pending-local (an edit to the shown workspace that leaves through the debounced publish). Source: approved plan.
- Decision: the gateway is its own type, `WorkspaceContentGateway`, testable with a store fixture. Source: approved plan.

## Run-wide decisions

- Decision: each item's review and refactor gates run as agent sessions bound to the run's worktree, using the templates in `.agents/skills/rpce-merge-pr-batch/references/review-prompts.md`, instead of `context_builder` review chats. `context_builder` reads the workspace's main checkout, which holds none of the branch's changes. Source: orchestrator judgment.

## a. Summaries, single-workspace reads, and the gateway

- Decision: a `.saved` mutation of the shown workspace applies the edit to the shown model, awaits the existing shown-workspace save for that exact workspace ID, and returns a committed receipt with the accepted revision and digest. A `.working` mutation of a shown target still returns pending-local. If the target stops being shown before the edit applies, the gateway never falls back to the newly shown workspace. Source: orchestrator judgment, from the plan's rule that a caller needing an authority revision for a shown target uses the existing saved-receipt path.
- Decision: the tab-loss check refuses a document with a stashed tab whose ID collides with a compose tab ID. Both decoders had dropped that tab, so the check passed and a rename removed the stash. Source: review finding.
- Decision: an edit of the shown workspace's active tab starts from the captured live UI state and is mirrored into the prompt UI before any save. The save's capture then can't revert it. Source: review finding.
- Decision: the gateway skips the own-copy install when the window already recorded a newer revision for that workspace. When the window stored local edits during the submit, the gateway merges the edit's one run into the window's copy: each tab the edit changed takes the committed version, and a workspace-level field keeps the copy's value only where the copy changed it and the edit didn't. The committed document replaces the copy instead when no merge keeps both sides: the copy moved or removed a tab the edit changed, the edit reordered tabs, or the result loses its active tab or puts one tab ID in both lists. The merge also requires the window's recorded working revision at dispatch to equal the edit's baseline revision, which keeps a window that hasn't projected another writer's commit from reverting it. A tab list with a duplicate ID also skips the merge. Running the edit a second time was rejected because it gives created tabs a second ID. The exact-document entry point always installs. Source: review findings. The fallback cases are implementer judgment.
- Decision: a gateway edit waits only while a switch involving its workspace is changing which workspace the window shows. That span runs from saving the outgoing workspace until the switch finishes, and covers a recovering or retargeted switch whose roots are unloaded or whose active workspace has moved. The edit then decides again whether the workspace is shown. During confirmation and session cancellation the edit goes to the shown copy, which keeps edits from waiting on a dialog or on a run the switch is cancelling. The wait ends on task cancellation and when the gateway closes. A read during such a switch returns the stored copy without the live UI overlay. Source: review findings. The phase list is implementer judgment.
- Decision: the gateway's UI mirror looks the tab up by exact workspace and tab identity. The shared helper's other callers move in item b. Source: review finding.
- Decision: an edit of the shown workspace mirrors only the edited active tab and the tab strip into the UI. Workspace-level preset and meta-prompt fields keep coming from the UI at the next capture, and no planned writer edits them. If the workspace stops being shown during the mirror, a `.saved` call returns pending-local without saving, because the switch publishes the edit. Source: implementer judgment.
- Decision: the refactor pass removed the gateway's DEBUG write-read hook in favor of the tests' intercepting backend and merged the two duplicated checkpoints in `mutate`. It also deleted a dead `DomainWorkspaceDocument` initializer, finished the fixture extraction, consolidated test helpers, put the success predicate in one place, and fixed a misleading name. It declined cosmetic candidates: a restored synthesized initializer, a failure factory, a named tuple, merging the two install methods, the bridge `consume` shape, and a double count in the diagnostics payload. Source: refactor analysis.
- Decision: when item b moves `commitTabContext` onto the gateway, its UI apply calls the gateway's shown-edit mirror instead of repeating it. Source: refactor analysis.
- Decision: item a doesn't change a switch that reloads the saved file and so reverts a working-only offscreen edit. The gap exists only between items b and c, which land in one pull request, and item c makes the switch load the canonical working document. Source: orchestrator judgment, declining a review finding for this item.
- Decision: item d's before-and-after debug-app runs time the summary pass, which re-serializes stashed tabs and selections for their digests on every document construction. No separate benchmark runs. Source: orchestrator judgment, on a review nit.
- Evidence: five review rounds. The fifth reported nits only. The full `RepoPromptTests` suite (1,783 tests) passed, as did `make dev-lint`, `make guardrails`, and `make dev-swift-build` for `RepoPrompt` and `repoprompt-mcp`. Each new test failed against a deliberate breakage of the fix it covers.
- Deferred: `pollAndSaveStateWithOutcomeAsync(workspaceID:)` can suspend before its capture while admission recovery holds the workspace, and a switch during that suspension captures a workspace the window no longer shows. This predates the run and needs admission recovery and a switch to coincide.
