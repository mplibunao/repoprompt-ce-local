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
   only this layer's diff. Both layers can land in the same candidate, lower
   first. When the upper layer waits for a later candidate, the landing
   retargets it onto `main` once the lower one lands. The `gh stack` extension
   installs with `gh extension install github/gh-stack`.

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
   build. [Debug profile isolation](docs/testing.md#debug-profile-isolation)
   says why. [`AGENTS.md`](AGENTS.md#commit-preflight) says which app actions
   need approval.

   ```bash
   make dev-smoke-launch          # builds, launches the debug app, runs the smoke flow
   rpce-cli-debug -w 1 -e '<the check for this change>'
   ```

6. Before asking for MP's review, run an independent review and a separate
   refactor pass on the change, such as an orchestrated workflow's review and
   refactor gates or sessions started from the prompts in
   [`review-prompts.md`](.agents/skills/rpce-merge-pr-batch/references/review-prompts.md),
   and fix what they find. The Codex review bot may also review the pull
   request. Its review is optional input, never a merge gate:
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

7. MP reads the pull request and approves it in chat. GitHub doesn't let an
   author approve a pull request opened from their own account, so its review
   state doesn't record the approval; the approved head is the pull request's
   head when MP approves it. From here the pull request waits for a release
   candidate ([Landing](#landing)), which merges every approved head onto
   `origin/main`, validates that candidate once, and pushes it to `main`. The
   pull request needs nothing more unless its head no longer merges cleanly or
   the candidate fails on it. For a conflict with `main`, rebase it onto
   `origin/main`, run the push preflight, and push with a lease pinned to the
   head MP approved, so a newer push to the branch makes the push fail instead
   of being overwritten; MP's approval covers the rebase. When a lower stack
   layer is rebased, the upper layer is rebased onto the lower layer's new head
   the same way, and its approval covers that rebase too. `main` is never merged
   into a pull request branch. Any other commit pushed after the approval, such
   as a review fix, needs MP's approval again before the pull request enters a
   candidate.

   ```bash
   git fetch origin
   git rebase origin/main
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push --force-with-lease=refs/heads/<branch>:<approved sha> origin HEAD:refs/heads/<branch>
   ```

## Landing

Approved pull requests, one or many, reach `main` through one path: a release
candidate. `$rpce-merge-pr-batch`
(`.agents/skills/rpce-merge-pr-batch/SKILL.md`) runs it and holds the commands
and checks. These are its steps.

1. **Cut.** In the candidate worktree, a plain worktree kept across candidates
   so its `.build` stays warm, start `release/<version>-rc<N>` from
   `origin/main`. `<version>` is `MARKETING_VERSION` in
   [`version.env`](version.env) on `origin/main`, and `N` is one more than the
   highest candidate number that exists on `origin` for that version. Merge each
   approved head with `git merge --no-ff` in the order MP gave. An upper stack
   layer enters only after its lower layer in the same candidate. The candidate
   contains only those merge commits: nothing else is committed on it and the
   pull request branches are not rewritten. A head that conflicts with `main` is
   rebased per step 7 and its new head is merged instead. A head that conflicts
   with a pull request merged earlier in the same candidate leaves this
   candidate; once that pull request lands, it rebases onto the new `main` per
   step 7 and enters the next candidate.
2. **Push.** Run the push preflight and push the candidate. Hosted CI runs on
   the push.
3. **Validate.** Run `preflight.sh candidate` on the candidate;
   [Candidate validation](.agents/skills/rpce-contribution-check/SKILL.md#candidate-validation)
   says what it selects. Then run the checks it prints against the debug app it
   launched. The candidate passes when the hosted runs on its tip are green (CI,
   and Xcode Workspace Validation when the candidate touches that workflow's
   paths), the lane passed, and the printed checks passed.
4. **Land.** Fetch; require `origin/main` to equal the candidate's base, each
   pull request's head to equal the head that was merged, and the local `HEAD`
   to equal the tip; retarget the upper layer of any stack in the candidate onto
   `main`; run the push preflight; push the tip to `main` with
   `git push origin HEAD:refs/heads/main`. A rejected push means `main` moved:
   the candidate is void, and each retargeted upper layer goes back to its lower
   branch. After the push, GitHub marks each pull request merged. Comment on
   each with the candidate name, its tip, and the hosted run, then delete the
   head branches. The candidate branch stays until the version is promoted.
5. **Fail.** Fix on the pull request's branch (any fix other than a rebase needs
   MP's approval again) or drop the pull request and anything stacked on it,
   then cut rc<N+1> from `origin/main` with the current heads. To find the pull
   request at fault, bisect the candidate's merges with
   `git bisect --first-parent` between the base and the tip, running the failing
   check's own command rather than the preflight script; the first failing merge
   names it.

New approvals enter the next candidate; MP may abandon an open candidate so the
next one is cut now. Every `main` tip is a landed candidate, and promotion
follows [`docs/releasing.md`](docs/releasing.md).

Ports from upstream follow [`docs/porting.md`](docs/porting.md).

## Validation

Keep changes focused and explain what they do. AI-assisted work is welcome, but
you should understand the code you submit and be able to explain its behavior.

Do not check raw generated RP outputs into the repo; prompts, reviews,
investigations, analysis, designs, and reference dumps are working artifacts
unless deliberately distilled into durable docs. [`AGENTS.md`](AGENTS.md#commit-preflight)
covers local `docs/investigations/*.md` reports.

The [validation matrix](.agents/skills/rpce-contribution-check/references/validation-matrix.md)
lists the checks each changed boundary needs, and
[`AGENTS.md`](AGENTS.md#documents-by-topic) says when a style-tooling change
needs `make dev-lint`. Add focused `make dev-test FILTER=<SuiteName>` coverage
for behavior changes.

[Release metadata and signing](docs/open-source-readiness.md#release-metadata-and-signing)
says which release and signing changes need deliberate review.
