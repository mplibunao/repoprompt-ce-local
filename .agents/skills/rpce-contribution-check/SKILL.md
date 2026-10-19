---
name: rpce-contribution-check
description: Validate RepoPrompt CE contributions before any commit, push, release candidate, history rewrite, branch or fork deletion, or other GitHub-visible change; owns the commit, push, pr-ready, and candidate preflight lanes.
---

# RepoPrompt CE Contribution Check

Run the repository-local safety preflight before every commit and push. Read `AGENTS.md` first and use daemon-coordinated validation where available.

## Before committing

1. Review `git status --short` and inspect the intended diff.
2. Stage only intended files. Review `git diff --cached --stat` and `git diff --cached`.
3. Run:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh commit
```

4. Rerun commit preflight after any staging change, including partial-staging updates. Commit mode scans materialized staged index blobs, not merely working-tree copies.
5. Keep secret values redacted in terminal output and summaries.

## Before pushing

1. Ensure the working tree is clean.
2. Run the immediate push safety gate:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh push
```

3. Review the computed current-branch range printed by the script.
4. Read [references/validation-matrix.md](references/validation-matrix.md) and ensure any required focused, release, smoke, or PR-ready evidence is recorded before pushing.
5. Push only the intended current branch and check the GitHub Actions run after pushing. On `main`, the run confirms the commit already passed as a release candidate and stops; a commit that didn't pass gets the run a release candidate gets (`CONTRIBUTING.md`, "Landing").

Default push mode validates whitespace, staged-index secrets, guardrails, the remote allowlist, clean worktree state, the current-branch outgoing range, and outgoing-range secrets. It does not run heavyweight lint/test/build/provider lanes.

Both `commit` and `push` check the repository's remotes after guardrails and before the mode-specific phases. `origin` is the only remote this repository may have; any other remote fails the preflight, and a checkout with no remotes passes. When `origin` exists, every configured fetch and push URL must target the distribution repository specified in `AGENTS.md`. Read upstream RepoPrompt CE through the reference clone described in `docs/porting.md` instead of adding a remote.

Push mode validates only the current branch against the comparison base described below. It does not validate tags, `--all`, `--mirror`, or arbitrary refspecs.

## Full / PR-ready local validation

Run the `pr-ready` lane when `AGENTS.md` "Commit preflight" says to, and whenever a maintainer or the validation matrix asks for the path-selected lane:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
```

[`AGENTS.md`](../../../AGENTS.md#commit-preflight) says when each lane runs.

`pr-ready` reruns the push safety gate, then runs any matching path-selected heavyweight lanes for the computed outgoing range, such as conductor selftests, Swift lint, root/provider tests, product builds, and generated Xcode workspace validation for Xcode boundary changes. Heavy build/test/package lanes may wait on conductor's per-user global heavy slot when another worktree is already running Swift/Xcode-heavy work; treat that as coordination, not a reason to launch duplicate direct `swift`/`xcodebuild` commands. It does not replace explicit release validation, live smoke, already-pushed PR-base comparison, or destructive-operation approval requirements.

### Comparison base

`push`, `pr-ready`, and `candidate` resolve the same comparison base and no flag overrides it: the branch's configured upstream when it has one, otherwise `origin/main` for a non-`main` branch. Once a topic branch has been pushed, its upstream is its own remote branch, so the computed range is empty and `push` and `pr-ready` exit successfully having validated nothing.

To validate a whole branch against `main`, run `pr-ready` while the branch has no configured upstream:

```bash
git branch --unset-upstream        # only needed once the branch has been pushed
.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
```

Before a branch's first push there is nothing to unset. A green `push` lane is not a substitute for this: it scans the same possibly empty range and never runs the heavyweight lanes.

A candidate branch is cut with `--no-track` and pushed without `-u`, so it never gets an upstream and `candidate` always compares it against `origin/main`.

## Candidate validation

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh candidate
```

Run it in the candidate worktree on `release/<version>-rc<N>` (`CONTRIBUTING.md`, "Landing"). It runs everything `pr-ready` runs for `origin/main..HEAD`, which covers every pull request in the candidate. When any path in that range is outside `docs/`, `.agents/`, `.github/`, and `*.md`, it runs `make dev-smoke-launch`, which packages the candidate, replaces the running debug app with it, and runs the smoke flow. It then prints the checks that remain manual: each pull request's recorded scenario and the acceptance matrix in `docs/releasing.md`. Otherwise it prints that the debug app was not selected. A debug-app relaunch ends every Agent Mode session in the debug app, so finish those first. A candidate with no commits over `origin/main` fails the lane. The candidate's merge commits run no commit lane: a clean `--no-ff` merge of approved heads adds no content of its own, and the `push` and `candidate` lanes scan the whole `origin/main..HEAD` range.

## Escalate before destructive operations

Follow the approval rules and exceptions in [`AGENTS.md`](../../../AGENTS.md#commit-preflight). Obtain explicit user approval immediately before each reserved action. Do not bundle approval for a future destructive step into an earlier request.

## Focused validation

Read [references/validation-matrix.md](references/validation-matrix.md) when deciding whether additional focused tests, builds, PR-ready validation, release checks, or live smoke are required.
