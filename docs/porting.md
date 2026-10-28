# Porting upstream changes

## Reference source

Use the read-only reference clone at:

```text
/Users/mp/Projects/personal/repoprompt-ce-upstream-readonly
```

## Procedure

1. At the start of a specific port, refresh the reference clone:

   ```bash
   git -C /Users/mp/Projects/personal/repoprompt-ce-upstream-readonly pull
   ```

   Then identify the upstream source and record its reference: the pull request number, or the commit SHA when the change has no pull request. That reference is `<ref>` below.
2. Run `rp-deep-plan` with the task `re-implement upstream <ref> on main`, for example `re-implement upstream PR 984 on main` or `re-implement upstream commit 4b2b914d on main`. Name the absolute reference-clone paths to read and the working-repository paths to change.
3. Create `port/<ref>-<slug>` from `main` in `/Users/mp/Projects/personal/repoprompt-ce`, for example `port/984-codemap-git-churn` or `port/4b2b914d-sparkle-isolation`.
4. Apply the planned source changes in the working repository.
5. Run focused tests for the affected behavior, then run:

   ```bash
   make dev-swift-build PRODUCT=RepoPrompt
   ```

   Use `PRODUCT=repoprompt-mcp` for MCP or shared-protocol changes.
6. Commit, open the pull request, and take it through steps 3 to 7 of the [`CONTRIBUTING.md`](../CONTRIBUTING.md) flow, using the `port` type label. The commit message must name the upstream source as plain text (no `owner/repo#N` or URL, see [`AGENTS.md`](../AGENTS.md#upstream-is-read-only)), in one of these forms:

   ```text
   Upstream-Ref: upstream PR <number> (<commit range>)
   Upstream-Ref: upstream commit <sha>
   ```

   The pull request then waits for a release candidate ([Landing](../CONTRIBUTING.md#landing)). Promotion is a separate step that [`releasing.md`](releasing.md) owns.

## Workflow prompts and `skillsVersion`

`RepoPromptWorkflowPrompts.skillsVersion` counts this distribution's versions of the generated skill text. A full install of skill copies rewrites them only when the counter it stored at the last install differs from the built-in value or a skill file is missing, so every change to generated text, ported or local, sets the counter to one above the distribution's current value and adds a `/// Version N:` comment describing the change. A port never copies upstream's number: the same number can already name different text here, and an install that recorded it would keep the stale copy.

Two distribution changes to the workflow prompts outlast any port (`docs/adr/2026-10-18-committed-run-records.md`). The Orchestrate prompt writes a run ledger and deletes the run's plan only when the user says the work is done. The Optimize prompt writes its scoreboard as a dated file in `docs/ledgers/` instead of a `prompt-exports/` file. A port that changes `WorkflowPrompt+Orchestrate.swift`, the `sharedMonitorAndVerifyBlock` that Orchestrate calls with `recordStep:`, or `WorkflowPrompt+Optimize.swift` keeps that behavior. `WorkflowPromptRunRecordTests` fails if either disappears.

After promoting a build, the app rewrites the existing managed `.claude/skills` copies in a workspace's roots each time it switches to that workspace, and the existing managed Codex prompts each time it launches. Both refreshes skip the counter check and update only copies that already exist. `~/.agents/skills` changes only when you reinstall from Settings → MCP.

## Source-level boundary

Changes cross from the reference clone into the working repository only as hand-written source edits. Never `git cherry-pick`, `git format-patch`, or `git merge` anything from the reference clone.

One binary asset is the documented exception: `AppBundle/AppIconDebug.icns` is a byte-for-byte copy of upstream's file from upstream PR 1074 (commit `77d45fd6`), SHA-256 `1acb93894a4506cd3d87a278f762edce881db4e77c3e0eccf0b77d1228016c6b`. It is the app icon with a blue `DEBUG` tag, and reproducing the same artwork locally would only add generator code to review. Code, patches, and merges still cross only as hand-written source edits.
