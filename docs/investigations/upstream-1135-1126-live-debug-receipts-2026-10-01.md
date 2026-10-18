# Upstream PR 1135 / PR 1126 port: live debug receipts (2026-10-01)

> Investigation report, observed 2026-10-01 and 2026-10-02 on debug builds of `port/1135-model-catalogs` at `616d67fe` and the local build 46 release-candidate branch, with bundled Codex CLI 0.159.0. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Acceptance matrix; [CONTRIBUTING.md](../../CONTRIBUTING.md), Landing.

This file was the receipt log for the live checks of the port's local plan, the build 46 release candidate's acceptance matrix, and the merge batch for #131, #132, and #133. It held workspace root paths, process IDs, log row and call identifiers, temporary evidence paths, settings-file hashes, and approval record IDs, so it is reduced to a summary of what it recorded. The source audit for the same port is [upstream-1135-1126-port-audit-2026-10-01.md](upstream-1135-1126-port-audit-2026-10-01.md).

## Model discovery and selections: passed

- The Codex server advertised `gpt-6.1-sol` at priority 1 with default effort low and efforts low through ultra, plus a fast service tier that backs the picker's "Fast" variants. Server entries marked `visibility: hide` were not offered in the picker.
- The app's merged picker offered 121 Codex options, with `gpt-6.1-sol-low` as the Codex Context Builder default, and 91 Claude Code options, including Sonnet 5.5 at five efforts and Mythos 5.1 labelled "Restricted". No Claude option and no Mythos entry was a default.
- `agent_manage list_agents` recommendations matched the expected resolution: Explore `gpt-6-luna-high`, Engineer `gpt-6.1-sol-medium`, Pair `gpt-6.1-sol-high`, Context Builder `gpt-6.1-sol-low`. Effective values differed only where saved user selections applied.
- The "Hide non-role models from MCP agents" filter has no `app_settings` key; only the Agent Models settings toggle writes it. It lives in `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`, which the debug and production apps share, so toggling it from the debug app also changes production. With MP's approval, the toggle was turned off in the debug app for about nine seconds. The full `list_agents` catalog then listed GPT-6.1 Sol, Sonnet 5.5, and the restricted Mythos model, and every setting matched the original capture after the restore.

## Minimal model runs with a RepoPrompt tool call: passed

- Codex `codexExec:gpt-6.1-sol-low`: the Codex session log and turn spans show `model=gpt-6.1-sol` and effort low on the outgoing requests. The run made a real `get_file_tree {"type":"roots"}` call through RepoPrompt MCP and returned the exact marker, with ChatGPT auth only and no approval or elicitation request.
- Claude Code `claudeCode:claude-sonnet-5-5:low`: `apply_flag_settings {"model":"claude-sonnet-5-5","effortLevel":"low"}` was applied before the user message, and the init and both assistant messages report `claude-sonnet-5-5`. RepoPrompt auto-approved the `get_file_tree` call, and the run ended `success` with the exact marker on subscription auth.
- Observation: the `session.startOrResume` diagnostic logged `"effortLevel": "xhigh"` next to `"model": "claude-sonnet-5-5:low"`, although no outgoing request carried `xhigh`. The field may be a misleading diagnostic.

## Build 46 release candidate: passed

- The build 46 release candidate merged the heads of #131, #132, and #133 onto `origin/main` at `40716eb1`; its tree equalled the stack head's tree. Every acceptance-matrix row passed on the candidate debug app except the second-window rows, which were not run because only one debug window existed.
- Two first attempts failed on their fixtures, not on the candidate. Context Builder sends the tab's stored prompt to discovery with the caller's instructions, so a tab with a stored prompt is not a valid fixture for the Context Builder row; the rerun on an empty tab passed. `agent_run` start takes worktree arguments for the primary workspace root only; the rerun used a worktree of the primary root.
- Quit and relaunch: the first start, 12 seconds after launch, was lost to the launch workspace restore that the open #108 tracks. A retry a minute later completed. `./conductor release preflight` passed for 1.4.0 (45).

## Merge batch: #131, #132, #133, then build 46

- Each layer took a final `pr-ready` on its exact head with the upstream unset, then merged in order. After each merge GitHub retargeted the next layer and rewrote its commits without changing their content.
- #136 changed `BUILD_NUMBER` from 45 to 46. One CI job failed a timing-bound test that predates the stack, `WorkspaceSelectionMirrorRecoveryTests` ("Bounded yield guard expired"); it was rerun once and passed. After the merge, `main` differed from the candidate only by the build number.
- #135, which made the Codex review bot optional input, stayed open for MP's review. The promotion continued in [b46-promotion-handoff-2026-10-02.md](b46-promotion-handoff-2026-10-02.md).
