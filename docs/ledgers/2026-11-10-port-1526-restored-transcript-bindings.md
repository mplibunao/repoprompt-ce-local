# Run ledger: port upstream PR 1526, restored transcript bindings

Request: none · Plan: a local `rp-deep-plan` plan, not committed

Re-implement upstream PR 1526 (squash commit `48be48da8`, parent `f7529bd44`) on `main`: remove the `lastProcessedTabID` guard and its resets from `AgentModeViewModel`, so a real selection of a tab whose persisted Agent session already hydrated reapplies that session's bindings and shows its saved transcript. Add root SwiftPM regression coverage and a bounded live before-and-after on the debug app.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Bounded live "before" on the integrated debug build without the port | done | orchestrator, debug CLI and Computer Use | none |
| 2. DEBUG seams and regression suite, red with the guard, then remove the guard | done | pair · Orchestrate 2/3: port 1526 seams, suite, guard removal; engineer · Refactor: port 1526 completion recorder | `fix(agent-mode): reapply restored transcript bindings on tab selection` |
| 3. Live "after" on the rebuilt integrated build, then the pull request | pending | | |

## 1. Bounded live "before" on the integrated debug build without the port

- Evidence, build: the running debug app was built from the local integration branch at `dc9cfc1c6` (every open pull request head except #355, plus the upstream 1105 port branch), which still contains all nine `lastProcessedTabID` sites.
- Evidence, setup: in a scratch window with two scratch workspaces, a one-turn Agent session (tab T) saved a unique marker, and a blank tab U sat beside it. Switching away and back hydrated T from disk (`agentSessionHydration.perform outcome=applied`), and the transcript under `agentTranscript.scrollView` showed the marker.
- Evidence, attempts: 4 attempts in about 6 minutes, 0 matched orderings. None of the attempts captured an empty transcript or logged a load error. Agent Mode's switch handler ran 100 to 200 ms from `agentMode.workspaceSwitch.begin` to `.end`, near the end of a 4 to 7 second switch. An MCP `select_tab` on the switching window, from that window's connection or another window's, was held until the `workspace switch` call returned, after the handler had finished, so an MCP-driven selection can't land inside the window (attempts 1 to 3). A Computer Use selection timed for the 1.8 s between the switch overlay clearing and the handler running didn't land, because the accessibility read hung while the switch ran (attempt 4).
- Decision: stop at 4 attempts, under the plan's bound of 8 attempts or 10 minutes, because no remaining driver could reach a matched ordering without staging windows and guessing the timing, and the plan says not to force the race. So the live differential rests on the deterministic suite in item 2. Source: approved plan (section F, "If the race doesn't reproduce") and orchestrator judgment.
- Decision: the `explore` role (Cursor CLI) answered with an "Upgrade your plan to continue" error. The saved turn contains the marker in its user row and that error as its reply, which is enough for rendering evidence. Source: orchestrator judgment.
- Cleanup: the scratch session, both workspaces, the scratch window and the scratch folder are deleted. Restore diagnostics were on through the app's defaults before the check; the check's `clear` emptied the shared buffer, and the effective state is back to on.

## 2. DEBUG seams and regression suite, red with the guard, then remove the guard

- Decision: the two DEBUG hooks, the suite and the guard removal go in one commit, so no commit contains the failing suite. Source: approved plan.
- Decision: keep both tests and the activation-completion hook. The selection-after-hydration test catches a guard that leaves the transcript empty; the selection-during-hydration test catches a dedupe that drops a selection arriving mid-load or a second disk load, and only the hook tells "the second activation never ran" apart from a fixture that never started. Source: `rpce-test-quality`, applied by the item's agent.
- Decision: the fixture also waits for its own sidebar index refresh to finish before saving the session, so a leftover refresh can't read the saved file. Source: the item's agent's judgment.
- Evidence, red with the guard: the selection-after-hydration test failed only in its final check (11 failures: empty working and visible rows, unhydrated bindings, the load-in-progress tab still set, `workspaceSwitchInFlight` still true), with every precondition passing. A cold-build retry gave the same result. The selection-during-hydration test passed its preconditions, then its wait for two finished activations timed out after 5 seconds with one recorded completion and the preparation gate at one entry, followed by the same transcript failures.
- Evidence, without the guard: both tests pass. `make dev-format` left the files unchanged, and `make dev-lint`, `make dev-test FILTER=RepoPromptTests.AgentTranscriptRestorationBindingTests` and `make dev-swift-build PRODUCT=RepoPrompt` pass. `lastProcessedTabID` no longer appears under `Sources/RepoPrompt/Features/AgentMode` or `Tests`; `ContextBuilderAgentViewModel` still has its own guard of that name, as upstream left it.
- Review: the item's review didn't find a production problem. Its one finding, that teardown waits for one activation completion rather than every one started, was declined: a second wait would add a 5-second cleanup failure to exactly the guarded run the test exists to catch, and nothing signals that an activation started. The reviewer withdrew it.
- Refactor gate: one P2, narrowing the private completion recorder to the fixture's single tab and single pending expectation (438 to 434 lines). A follow-up found nothing else. The private gate, wait and fixture stay in the file rather than moving to shared helpers, because the similar helpers in other suites are private analogues and extracting them would widen the change.
