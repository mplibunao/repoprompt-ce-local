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
6. Stage only the intended files and run the commit preflight:

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh commit
   ```

7. Commit the port branch. The commit message must name the upstream source as plain text (no `owner/repo#N` or URL, see `AGENTS.md`, "Upstream is read-only"), in one of these forms:

   ```text
   Upstream-Ref: upstream PR <number> (<commit range>)
   Upstream-Ref: upstream commit <sha>
   ```

8. Run the `pr-ready` lane while the branch still has no configured upstream, so it validates the whole port against `main` (see the comparison-base procedure in `.agents/skills/rpce-contribution-check/SKILL.md`). Then run the push preflight, push the branch, and open a pull request against `main` with the `pr-ready` result recorded in its description, the `port` label, and the `area:` labels for the code it touches; MP reads and approves it, and the agent merges it with a merge commit once its checks pass (stacking, the review-bot draft cycle, and conflict handling follow [`CONTRIBUTING.md`](../CONTRIBUTING.md) steps 5 and 6):

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push -u origin <branch>
   gh pr create --base main --label port --label area:<area>
   ```

9. The port workflow ends at the merged pull request. Promotion is a separate step MP runs after the merge, from the `main` checkout, only after archiving the current install with `Scripts/local_release_archive.sh <tag>`:

   ```bash
   CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make install-local-production
   ```

## Source-level boundary

Changes cross from the reference clone into the working repository only as hand-written source edits. Never `git cherry-pick`, `git format-patch`, or `git merge` anything from the reference clone.
