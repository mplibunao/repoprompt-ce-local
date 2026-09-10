---
name: rpce-release
description: Promote a local RepoPrompt CE production build through the repository-owned procedure with MP present for approval and acceptance.
---

# RepoPrompt CE Release

Use this skill for a local production promotion. Read and follow [`docs/releasing.md`](../../../docs/releasing.md), which owns the promotion, rollback, provenance, and acceptance procedures.

## Inputs

Confirm these before starting:

- the exact pushed `main` commit to promote
- the intended version, build number, and `local/v<version>-b<build>` tag
- the archive tag for the installed build
- the GitHub Release receipt path

Ask MP for any missing or ambiguous input instead of inferring it.

## Invocation boundary

MP must be present throughout the promotion. Obtain immediate approval at every repository-required approval boundary, including visible-app lifecycle changes and GitHub-visible mutations. Follow `$rpce-contribution-check` before any commit or push.

The promoted artifact is the local self-signed production app. Do not distribute or upload the app artifact.

## Stop conditions

Stop before changing the installed app or repository state when:

- MP is not present or an immediate approval is missing
- the selected commit is not the clean, pushed `main` tip
- the build number, tag, archive target, or receipt is unresolved
- the rollback rehearsal prerequisite in `docs/releasing.md` is not satisfied
- archive, install, acceptance, provenance, tag, push, or receipt verification fails

On failure, preserve the evidence and follow the rollback path in `docs/releasing.md`; do not continue to later promotion steps.
