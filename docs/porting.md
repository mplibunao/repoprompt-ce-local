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

   Then identify the upstream pull request or commit range and record its number.
2. Run `rp-deep-plan` with the task `re-implement upstream PR N on main`. Name the absolute reference-clone paths to read and the working-repository paths to change.
3. Create `port/<N>-<slug>` from `main` in `/Users/mp/Projects/personal/repoprompt-ce`.
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

8. Run the `pr-ready` lane while the branch still has no configured upstream, so it validates the whole port against `main` (see the comparison-base procedure in `.agents/skills/rpce-contribution-check/SKILL.md`). Then run the push preflight, push the branch, open a pull request against `main`, and merge it with a merge commit once its checks pass:

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push -u origin <branch>
   gh pr create --base main
   ```

9. Promote a build only after archiving the current install with `Scripts/local_release_archive.sh <tag>` and with MP present. Run this command from the `main` checkout:

   ```bash
   CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make install-local-production
   ```

## Source-level boundary

Changes cross from the reference clone into the working repository only as hand-written source edits. Never `git cherry-pick`, `git format-patch`, or `git merge` anything from the reference clone.
