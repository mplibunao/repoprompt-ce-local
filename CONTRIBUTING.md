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

4. Commit. A change under `Sources/` or `Packages/` then needs a debug-app
   run: build and launch the debug app from the branch, exercise the changed
   behavior through `rpce-cli-debug` or the app itself, and note the commands,
   what you observed, and the result for the pull request description. Unit
   tests and `pr-ready` don't replace that run. Validate from a current
   build. [Debug profile isolation](docs/testing.md#debug-profile-isolation)
   says why. [`AGENTS.md`](AGENTS.md#commit-preflight) says which app actions
   need approval.

   ```bash
   make dev-smoke-launch          # builds, launches the debug app, runs the smoke flow
   rpce-cli-debug -w 1 -e '<the check for this change>'
   ```

   Next, draft the pull request description. Then run an independent review
   and a separate refactor pass on the branch, such as an orchestrated
   workflow's review and refactor gates or sessions started from the prompts in
   [`review-prompts.md`](.agents/skills/rpce-merge-pr-batch/references/review-prompts.md),
   which quote the draft. Commit the fixes for what they find through the
   commit preflight, and repeat the debug-app run when a fix changes the
   behavior it covered. All this happens before the pull request opens. CI
   runs on every push to an open pull request, and a push during a run cancels
   that run and wastes the minutes it already used.

   Then run the `pr-ready` lane while the branch still has no configured
   upstream, so it validates the whole branch against `main`, fixes included
   (the comparison-base procedure in
   `.agents/skills/rpce-contribution-check/SKILL.md` explains why `pr-ready`
   runs before the first push):

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
   ```

5. Run the push preflight, push the branch, and open a pull request against
   `main` on `mplibunao/repoprompt-ce-local`, with the `pr-ready` result and
   any debug-app run from step 4 recorded in the description, one type label
   (`bug`, `port`, `tooling`, `agent-env`, `documentation`, or `cleanup`), and
   the `area:` labels for the code it touches. Open it ready for review, not
   as a draft, so the Codex review bot reviews it from the start.

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

6. The Codex review bot may review the pull request. Its review is optional
   input, never a merge gate: when it doesn't review, nothing waits for it or
   asks it to review again. When it posts findings, assess each one: fix the
   findings that are real defects, reply with the reason for any you decline,
   resolve each thread, commit the fixes through the commit preflight, and push
   them together through the push preflight.

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh commit
   git commit
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push
   ```

7. MP reads the pull request and approves it in chat. GitHub doesn't let an
   author approve a pull request opened from their own account, so its review
   state doesn't record the approval. Confirming an ordered landing list
   approves the pull requests on it the same way. An approval stays valid when
   more commits are pushed to the pull request afterwards, such as fixes for
   review findings. From here the pull request waits for a release candidate
   ([Landing](#landing)), which merges the head of every approved pull request
   onto `origin/main`, validates that candidate once, and pushes it to `main`.
   The pull request needs nothing more unless its head no longer merges
   cleanly or the candidate fails on it. For a conflict with `main`, rebase it
   onto `origin/main`, run the push preflight, and push with a lease pinned to
   the head last observed on `origin`, so a newer push to the branch makes the
   push fail instead of being overwritten. When a lower stack layer is
   rebased, the upper layer is rebased onto the lower layer's new head the
   same way. `main` is never merged into a pull request branch.

   ```bash
   git fetch origin
   git rebase origin/main
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push --force-with-lease=refs/heads/<branch>:<observed sha> origin HEAD:refs/heads/<branch>
   ```

## Landing

Approved pull requests, one or many, reach `main` through one path: a release
candidate. No agent starts one unless MP asks for it, and a re-cut after a
failed candidate continues that request. A request to promote a build also asks
for the candidate that lands its `BUILD_NUMBER` bump, and the bump goes in the
same candidate as the other pull requests ready to land. The agent running a
candidate lists every open pull request that is ready to land, and the
candidate lands the ones MP confirms, so one validation run covers the whole
batch. `$rpce-merge-pr-batch` (`.agents/skills/rpce-merge-pr-batch/SKILL.md`)
runs the procedure and holds the commands and checks. These are its steps.

1. **Cut.** In the candidate worktree, a plain worktree kept across candidates
   so its `.build` stays warm, start `release/<version>-rc<N>` from
   `origin/main`. `<version>` is `MARKETING_VERSION` in
   [`version.env`](version.env) on `origin/main`, and `N` is one more than the
   highest candidate number that exists on `origin` for that version. Merge each
   approved pull request's head with `git merge --no-ff` in the order MP gave.
   An upper stack layer enters only after its lower layer in the same
   candidate. The candidate contains only those merge commits: nothing else is
   committed on it and the pull request branches are not rewritten. A head that
   conflicts with `main` is rebased per step 7 and its new head is merged
   instead. A head that conflicts with a pull request merged earlier in the
   same candidate leaves this candidate with anything stacked on it; once that
   pull request lands, it rebases onto the new `main` per step 7 and enters the
   next candidate.
2. **Push.** Run the push preflight and push the candidate. Hosted CI runs on
   the push.
3. **Validate.** Run `preflight.sh candidate` on the candidate;
   [Candidate validation](.agents/skills/rpce-contribution-check/SKILL.md#candidate-validation)
   says what it selects. Then run any checks it prints against the debug app it
   launched. The candidate passes when the hosted runs on its tip are green (CI,
   and Xcode Workspace Validation when the candidate touches that workflow's
   paths), the lane passed, and the printed checks passed.
4. **Land.** Fetch; require `origin/main` to equal the candidate's base and the
   local `HEAD` to equal the tip; retarget the upper layer of any stack in the
   candidate onto `main`; run the push preflight; require each pull request's
   head to equal the head that was merged; push the tip to `main`. A rejected
   push means `main` moved: the candidate is void, and each retargeted upper
   layer goes back to its lower branch. The push starts a `CI` run that
   confirms the commit already passed on the candidate and stops; the run on
   the candidate's tip is the landing evidence. After the push, GitHub marks
   each pull request merged. Comment on each with the candidate name, its tip,
   and the hosted run, then delete the head branches. The candidate branch
   stays until the version is promoted.
5. **Fail.** Fix on the pull request's branch or drop the pull request and
   anything stacked on it, then cut
   rc<N+1> from `origin/main` with the current heads. Step 6 of
   `$rpce-merge-pr-batch` finds the pull request at fault.

New approvals enter the next candidate; MP may abandon an open candidate so the
next one is cut now. Every `main` tip is a landed candidate, and promotion
follows [`docs/releasing.md`](docs/releasing.md). A commit pushed to `main`
that never passed as a candidate gets the `CI` run a candidate gets. The daily
cache refresh on `main` builds without running tests and validates nothing.
[`docs/testing.md`](docs/testing.md) describes the `CI` run on `main` and the
refresh.

Ports from upstream follow [`docs/porting.md`](docs/porting.md).

## Plans and committed records

Plans are local working documents in `docs/plans/`, which git ignores. They are
never committed. Three kinds of agent-written records are committed, because
Context Builder and later agents can read files in the checkout but not git
history or GitHub:

| Folder | Holds | Edited after it lands |
| --- | --- | --- |
| `docs/ledgers/` | One ledger per orchestrated run: its work items with outcome, agent session, and commits, then each item's decisions with their sources, evidence, and deferrals as issue numbers. One scoreboard per built-in Optimize run: its baseline, each iteration's result, and its rejected candidates | Only to finish the run that wrote it |
| `docs/adr/` | Architecture decision records: why a hard-to-reverse choice was made | No; a later ADR supersedes it |
| `docs/investigations/` | Investigation reports: what was found, as of the report's date | No |

`docs/architecture/` and `docs/spec/` describe how the system works now and are
edited in place. GitHub issues and pull requests track open work.

**Working files.** These stay local and are never committed:

- plans, in `docs/plans/`;
- prompt exports in `prompt-exports/` and other raw RepoPrompt output, such as
  prompts and Context Builder or oracle responses;
- reviews, designs, analysis, and reference dumps, in `docs/reviews/`,
  `docs/designs/`, `docs/analysis/`, and `docs/references/`;
- local configuration;
- daemon logs, raw provider traces and events, transcripts, and generated
  diagnostic artifacts;
- promotion logs, session handoffs, approval drafts, and issue drafts, in
  `docs/plans/`. Their content goes in the release receipt, issue, pull
  request, or plan they serve.

To keep something a working file found, write it into a committed record or a
durable document. Under `docs/`, check 8 of
`Scripts/source_layout_guardrails.sh` fails on any tracked file that is neither
a Markdown record in the three folders above nor on the script's allowlist of
durable documents; adding a document to that list is how a working document is
promoted.

**Run ledgers.** Run ledgers are committed in `docs/ledgers/`, as part of the
run's pull request. The built-in Orchestrate workflow and the
`rp-orchestrate-loop` skill from a separate toolkit repository write them and
define the template. A ledger is named `<YYYY-MM-DD>-issue-<number>-<topic>.md`
for the date the run started, without `issue-<number>-` when the run has no
issue. Deferrals are recorded as GitHub issues. The built-in Optimize workflow
writes its scoreboard here too, as `<YYYY-MM-DD>-optimize-<slug>.md`; the
scoreboard is that run's record, so an Optimize run writes no separate ledger.
The orchestrator deletes the run's plan only when the user says the work is
done, after checking that the plan's decisions are in the ledger or an ADR.

**ADRs.** A decision gets an ADR when it is hard to reverse, would surprise
someone without the background, and involved a real trade-off. Other decisions
stay in the run's ledger. Copy `docs/adr/template.md` to
`docs/adr/<YYYY-MM-DD>-<topic>.md`, dated the day the decision is accepted. ADR
drafts in a plan are approved with the plan, written during the run, and
committed in the run's pull request. For decisions made during execution, the
orchestrator lists ADR candidates in its final report and writes the ones the
user approves, in the same pull request. To replace a decision, write a new ADR
and change the old one's status line to `Status: superseded by <link>, <date>`.

**Investigations.** An investigation report states one of four kinds of
finding: a root cause, a ruled-out option, a measurement, or the evidence
behind a decision. A file that states none of them isn't an investigation
report. Reports are committed in `docs/investigations/`. A runbook goes in the
document that describes its procedure, such as `docs/releasing.md` or
`docs/testing.md`. Each report opens with the date of what it observed. It
records what was true then. Where it disagrees with a current document, the
current document is right.

**Redaction.** Ledgers and investigation reports are public once pushed. Before
committing one, apply the rules in
[`.agents/skills/rpce-issue-creator/SKILL.md`](.agents/skills/rpce-issue-creator/SKILL.md):
its private-data list, its limits on evidence, and its plain-text rule for
upstream references. The commit preflight's gitleaks scan rejects absolute home
paths under `docs/investigations/` and `docs/ledgers/`, and the rest is the
author's job.

**Citing records.** When you explain why something is the way it is, cite the
ADR, ledger, or investigation by its repository path and say how old the
evidence is. Plans and `prompt-exports/` files are local, so they are never
cited.

## Validation

Keep changes focused and explain what they do. AI-assisted work is welcome, but
you should understand the code you submit and be able to explain its behavior.

Commit the change and the records it produces, and nothing else:
[Plans and committed records](#plans-and-committed-records) lists the working
files that stay local.

The [validation matrix](.agents/skills/rpce-contribution-check/references/validation-matrix.md)
lists the checks each changed boundary needs, and
[`AGENTS.md`](AGENTS.md#documents-by-topic) says when a style-tooling change
needs `make dev-lint`. Add focused `make dev-test FILTER=<SuiteName>` coverage
for behavior changes.

[Release metadata and signing](docs/open-source-readiness.md#release-metadata-and-signing)
says which release and signing changes need deliberate review.
