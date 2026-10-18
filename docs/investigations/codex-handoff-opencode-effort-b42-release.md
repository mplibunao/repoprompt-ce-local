# Handoff: OpenCode/Cursor effort feature — build 42 release (continued from Codex)

> Investigation report, observed 2026-09-21 to 2026-09-22 on local build 42 (`main` at `0c6bb1d3`). It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

This report summarizes a handoff between two agent sessions and the work it describes.

## Scope

A Codex session took over an `rp-orchestrate` run that ported two upstream features into the distribution: the ACP model-parameter framework with Cursor support (upstream PR 960, ported as #83) and configurable OpenCode thinking and effort levels (upstream PR 1009, ported as #84). The session validated both features in the debug app, fixed review findings, merged both pull requests, and ran the release train for local build 42: #87 set the build number to 42, and #88 fixed a release-only build failure. The session ended while the final build 42 production artifact was compiling, before the install step, which needs MP present.

## Findings

- **The first stale-effort check used the wrong model ID.** The test configuration disabled `max` for `opencode-go/deepseek-v4.1-flash`, but the chat used the direct API route, `deepseek/deepseek-flash`. The two routes have similar display names. Once the override targeted `deepseek/deepseek-flash` and the chat switched to another model and back to drop cached metadata, the composer reported `max, unavailable`, and the effort menu offered only Low, High, Default, and Clear saved value.
- **The accessibility state did not prove the warning color.** The Computer Use screenshot call returned no image for the debug app, so the first pass relied on the accessibility value. An OS-level screenshot then showed the unavailable `max` chip in gray instead of orange.
- **A borderless SwiftUI `Menu` drops its label's styling.** A first fix gave the label orange text and an orange-tinted background, and the packaged build still showed a gray chip with no background. The fix that passed draws an orange warning triangle outside the menu label.
- **The remaining live acceptance checks passed.** Clear changed the unavailable `max` to the provider default, Low, and left the persisted parameter list empty. Changing the model from GLM to DeepSeek while the old effort menu was open invalidated that menu, so its action could not apply. A deliberately long GLM run rejected a `resume_session` call that tried to switch it to DeepSeek with `effort=high`, and the run then completed normally.
- **The Codex review bot found three defects, all fixed with regression tests before merge.** `list_agents` could enrich the wrong OpenCode model when another workspace had refreshed the shared catalog snapshot last; it now refreshes the catalog for the target window's active workspace and omits enrichment if that refresh fails. `AgentModeViewModel.deinit` did not cancel the OpenCode parameter-observation task. The Cursor controller compared raw model names, so it could reject a legacy alias such as `composer-2` after the catalog had mapped it to `composer-2.5`.
- **Upstream PR 960 bundled an unrelated fix, which #83 left out.** Its 13-line change to `Sources/RepoPrompt/App/ViewModels/ContentViewModel.swift` makes the MCP client connection-approval overlay appear as soon as a client waits for approval. Without it, the overlay waits for an unrelated redraw of the root view. #86 tracks porting it separately.
- **#84 dropped no production behavior from upstream PR 1009.** The upstream differences #84 listed as not ported were a regression test for an Oracle model roster the distribution does not implement, code for the Antigravity and Devin providers that predates upstream PR 1009, and test-helper changes that the distribution adapted to its own helpers.
- **Xcode 27 broke the release-only build.** The optimized arm64 build failed on a Sentry type mismatch in code that build 41 already contained. #88 fixed it with an explicit `NSNumber` conversion, and the universal release artifact then built, packaged, and passed its signature and architecture checks.
- **A clean checkout can't run the full test gate as is.** The vendored Sparkle XCFramework declares an empty `dSYMs` folder, which git can't store. Creating the folder after a failed build doesn't help, because the failed build caches the missing path, and the conductor test sandbox drops the untracked folder when it rebuilds the checkout. Creating the folder before the first build in a fresh worktree let `pr-ready` pass.
- **Smaller process findings.** The debug app hung while quitting and needed a targeted signal to stop. A RepoPrompt workspace deletion reported success, but the workspace inventory still listed the record; nobody checked it again. The live smoke script assumes a saved workspace named `repoprompt-ce`. A duplicate-tab admission test failed once in the full suite after about 5 seconds and passed alone in 0.1 seconds. Running `pr-ready` against a branch's own remote copy compares an empty range, so it has to run against `origin/main`.

## State when the session ended

- `origin/main` was `0c6bb1d3`, the merge of #88, with both effort features, build number 42, and the Xcode 27 fix. #83 had merged as `28f2605` and #84 as `cbe94fe`.
- Release preflight had passed on `0c6bb1d3`, and the final build 42 production artifact was compiling in a detached worktree at that commit.
- Production was still build 41. Next were the promotion, the install, and a live acceptance run of the effort controls with OpenCode and DeepSeek through the direct API, because the OpenCode Go and Zen routes were unstable at the time.
