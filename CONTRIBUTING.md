# Contributing to RepoPrompt CE

This repository is the personal distribution at
[`mplibunao/repoprompt-ce-local`](https://github.com/mplibunao/repoprompt-ce-local).
Work is tracked as issues and pull requests there.

## Flow

1. Branch from `main` using a `bugfix/`, `port/`, or `chore/` prefix.
2. Make the change and run the smallest relevant coordinated validation
   commands: the
   [validation matrix](.agents/skills/rpce-contribution-check/references/validation-matrix.md)
   lists what each changed boundary needs, and
   [`docs/architecture/developer-daemon.md`](docs/architecture/developer-daemon.md)
   covers the commands.
3. Stage only the intended files and run the commit preflight:

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh commit
   ```

4. Commit, then run the `pr-ready` lane while the branch still has no
   configured upstream, so it validates the whole branch against `main` (the
   comparison-base procedure in
   `.agents/skills/rpce-contribution-check/SKILL.md` explains why the order
   matters):

   ```bash
   git commit
   .agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
   ```

5. Run the push preflight, push the branch, and open a pull request against
   `main` on `mplibunao/repoprompt-ce-local`, with the `pr-ready` result from
   step 4 recorded in the description, one type label (`bug`, `port`,
   `tooling`, `agent-env`, `documentation`, or `cleanup`), and the `area:`
   labels for the code it touches. Open it ready for review, not as a draft,
   so the Codex review bot reviews it from the start.

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push -u origin <branch>
   gh pr create --base main --label <type> --label area:<area>
   ```

   When the change depends on a pull request that is still open, branch from
   that branch instead of `main`, open the pull request against it, then link
   the two as a GitHub stack and add the `stacked` label. The stack view shows
   only this layer's diff, and GitHub retargets the branch onto `main` once
   the lower pull request merges, rewriting the upper branch's commits in the
   process, so fetch and reset the local branch to `origin` before committing
   to it again. The `gh stack` extension installs with
   `gh extension install github/gh-stack`.

   ```bash
   gh pr create --base <lower-branch> --label <type> --label area:<area> --label stacked
   gh stack link <lower-pr-number> <this-pr-number>
   ```

   A change under `Sources/` or `Packages/` needs a debug-app run before MP
   reviews it, and its description says that validation is pending until you
   record the run. Build and launch the debug app from the branch, exercise
   the changed behavior through `rpce-cli-debug` or the app itself, and record
   the commands, what you observed, and the result in the description. Unit
   tests and `pr-ready` do not replace that run. Validate from a current
   build, as [Debug profile isolation](docs/testing.md#debug-profile-isolation)
   explains; the approval rules in [`AGENTS.md`](AGENTS.md#commit-preflight)
   cover launching the debug app.

   ```bash
   make dev-smoke-launch          # builds, launches the debug app, runs the smoke flow
   rpce-cli-debug -w 1 -e '<the check for this change>'
   ```

6. Before asking for MP's review, run an independent review and a separate
   refactor pass on the change, such as an orchestrated workflow's review and
   refactor gates, and fix what they find. The Codex review bot may also
   review the pull request. Its review is optional input, never a merge gate:
   when it does not review, nothing waits for it or asks it to review again.
   When it posts findings, assess each one: fix the findings that are real
   defects, reply with the reason for any you decline, resolve each thread,
   commit the fix through the commit preflight, and push it through the push
   preflight.

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh commit
   git commit
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push
   ```

7. MP reads the pull request and approves it. Fetch `origin` first so `main`
   is current for everything below. If the branch conflicts with `main`,
   rebase it onto `origin/main` and resolve the conflicts first.
   Run the push preflight, then push with a lease pinned to the head you
   reviewed, so a newer push to the branch makes the push fail instead of
   being overwritten:
   `git push --force-with-lease=refs/heads/<branch>:<reviewed sha> origin HEAD:refs/heads/<branch>`.
   Let the checks run on the new head. MP's approval covers the rebase.
   Any other commit pushed after the approval, such as a review fix, needs
   MP's approval again before the merge.
   Then, with every review thread resolved and the checks green, run the
   `pr-ready` lane on the final head with the upstream unset so it validates
   `origin/main..HEAD` rather than an empty range, restore the upstream,
   confirm the local head is the pushed head, and merge with a merge commit
   pinned to that commit so a head that moved in the meantime aborts the
   merge. A pull request that is part of a stack merges through the stack
   command after the same head check; merging a lower layer makes GitHub
   retarget and rewrite the layers above it, and MP's approval of the lower
   layer covers that rewrite.

   ```bash
   git fetch origin
   git branch --unset-upstream
   .agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
   git branch --set-upstream-to=origin/<branch>
   test "$(git rev-parse HEAD)" = "$(git rev-parse origin/<branch>)"
   gh pr merge <number> --merge --match-head-commit "$(git rev-parse HEAD)"
   gh stack merge <number> --merge --yes   # when the pull request is in a stack
   ```

## Landing a batch

`main` must stay promotable at every commit, because a hotfix build comes from
it. Two paths land work there.

**One at a time.** With few open pull requests and no shared files, validate
each app-code pull request in the debug app on its own branch, then merge it.
This is the default path and the one the flow above describes. An urgent fix
takes this path even while a release candidate is open, so `main` never waits
on a batch.

**Release candidate.** When more than three app-code pull requests are waiting,
or any two touch the same file, validate them together before anything merges:

1. Cut `release/<version>-rc<N>` from `origin/main` in a dedicated worktree and
   merge each pull request head into it with `git merge --no-ff`, in dependency
   order, stacked pull requests through their tip. The candidate carries only
   those merges; do not rebase or otherwise rewrite the pull request branches,
   and do not commit fixes on the candidate.
2. Build the candidate once, launch the debug app, and run each pull request's
   own scenario plus the acceptance matrix in
   [`docs/releasing.md`](docs/releasing.md) against that debug app, following
   the matrix's release-candidate instructions so every call reaches the
   candidate rather than the installed production build.
3. On failure, fix on the pull request branch and cut the next candidate from
   `origin/main` plus the current heads. To find the pull request at fault,
   split the candidate along groups of pull requests that touch the same files
   and build the halves.
4. On pass, merge the pull requests into `main` one by one in the same order,
   each through `pr-ready` and a merge commit, without relaunching the app.
   After the last merge, run `git fetch origin` and require
   `git diff <candidate tip> origin/main` to be empty: a non-empty diff means a
   pull request changed after validation and the candidate is void.
5. Promote from `main` per [`docs/releasing.md`](docs/releasing.md). The
   candidate branch is never merged into `main` and may be deleted once the
   promotion is tagged.

Ports from upstream follow [`docs/porting.md`](docs/porting.md). Builds are
promoted per [`docs/releasing.md`](docs/releasing.md).

## Validation

Keep changes focused and explain what they do. AI-assisted work is welcome, but
you should understand the code you submit and be able to explain its behavior.

Do not check raw generated RP outputs into the repo; prompts, reviews,
investigations, analysis, designs, and reference dumps are working artifacts
unless deliberately distilled into durable docs. [`AGENTS.md`](AGENTS.md#commit-preflight)
covers local `docs/investigations/*.md` reports.

The [validation matrix](.agents/skills/rpce-contribution-check/references/validation-matrix.md)
lists the checks each changed boundary needs. Add focused
`make dev-test FILTER=<SuiteName>` coverage for behavior changes.

[Release metadata and signing](docs/open-source-readiness.md#release-metadata-and-signing)
covers changes to release metadata, signing identities, bundle IDs, Sparkle
keys, and release channels.
