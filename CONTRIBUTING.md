# Contributing to RepoPrompt CE

This repository is the personal distribution at
[`mplibunao/repoprompt-ce-local`](https://github.com/mplibunao/repoprompt-ce-local).
Work is tracked as issues and pull requests there.

## Flow

1. Branch from `main` using a `bugfix/`, `port/`, or `chore/` prefix.
2. Make the change and run the smallest relevant coordinated validation commands
   from [`AGENTS.md`](AGENTS.md).
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
   labels for the code it touches. MP merges it with a merge commit after
   reading it and once its checks pass; the agent's work ends at the open pull
   request. Nothing merges into `main` directly.

   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   git push -u origin <branch>
   gh pr create --base main --label bug --label area:mcp
   ```

   When the change depends on a pull request that is still open, branch from
   that branch instead of `main`, open the pull request against it, then link
   the two as a GitHub stack and add the `stacked` label. The stack view shows
   only this layer's diff, and GitHub retargets the branch onto `main` once
   the lower pull request merges. The `gh stack` extension installs with
   `gh extension install github/gh-stack`.

   ```bash
   gh pr create --base <lower-branch> --label bug --label area:mcp --label stacked
   gh stack link <lower-pr-number> <this-pr-number>
   ```

6. The Codex review bot reviews the pull request when it is ready for review.
   While addressing its findings, convert the pull request to a draft so the
   open, non-draft list stays a list of reviewable work; reply to and resolve
   each thread, push the fix, and mark the pull request ready again so the bot
   reviews the fixed code. Repeat until a pass leaves no findings.

   ```bash
   gh pr ready <number> --undo   # draft while fixing
   gh pr ready <number>          # ready again after the fix is pushed
   ```

Ports from upstream follow [`docs/porting.md`](docs/porting.md). Builds are
promoted per [`docs/releasing.md`](docs/releasing.md).

## Validation

Keep changes focused and explain what they do. AI-assisted work is welcome, but
you should understand the code you submit and be able to explain its behavior.

Do not check raw generated RP outputs into the repo; prompts, reviews,
investigations, analysis, designs, and reference dumps are working artifacts
unless deliberately distilled into durable docs. Local `docs/investigations/*.md`
reports stay unignored so RepoPrompt tooling can read them; do not stage or merge
them unless intentionally requested.

For every change, run the repository guardrails:

```bash
make guardrails
```

For Swift or style-sensitive changes, also run:

```bash
make dev-lint
```

Add focused `make dev-test FILTER=<SuiteName>` coverage for behavior changes.
Before merging into `main`, the `pr-ready` lane of
[`$rpce-contribution-check`](.agents/skills/rpce-contribution-check/SKILL.md) is
mandatory; that skill documents how to invoke it so it validates the whole
branch.

When changing the Xcode generator, workflow wrapper, or generated scheme
contracts, also run:

```bash
make xcode-validate
```

Do not change release metadata, signing identities, bundle IDs, Sparkle keys, or
release channels unless the change is deliberate and reviewed.
