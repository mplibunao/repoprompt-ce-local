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

4. Merge into `main` with `git merge --no-ff`, then run the push preflight from
   the `main` checkout before pushing.

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
