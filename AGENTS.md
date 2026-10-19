# Agent Notes

This is a Swift Package macOS app for RepoPrompt CE. This file states the rules that appear in no other document, and for every other topic it links to the document that defines it. Read that document before acting on its topic.

## Documents by topic

- **Builds, runs, tests, and style checks:** use the coordinated developer daemon, `make dev-*` or `./conductor`, and fall back to the plain `make`, `swift`, and `./Scripts` commands only when it is unavailable. [`docs/architecture/developer-daemon.md`](docs/architecture/developer-daemon.md) explains why and lists the commands.
- **Validation for a change:** the [validation matrix](.agents/skills/rpce-contribution-check/references/validation-matrix.md) lists the evidence each changed boundary needs, including the live smoke for packaging, MCP, and Agent Mode changes.
- **Plans, run ledgers, investigations, and ADRs:** plans and other working files stay local; run ledgers, investigation reports, and ADRs are committed. [`CONTRIBUTING.md`, Plans and committed records](CONTRIBUTING.md#plans-and-committed-records) says where each lives, which files stay local, when a decision gets an ADR, and how to redact and cite them.
- **Swift style:** after any Swift edit, run `make dev-format` before handoff, then `make dev-lint`, which the Swift row of the [validation matrix](.agents/skills/rpce-contribution-check/references/validation-matrix.md) requires. Never run `make dev-format` on a change with no Swift edits. Run `make dev-lint` too when style tooling is relevant to the change. Do not run a full-repository formatting baseline unless the task explicitly asks for it.
- **Tests:** [`docs/testing.md`](docs/testing.md) covers where tests go, focused and full runs, and the handoff checklist. `$rpce-test-quality` decides whether to add, keep, consolidate, or remove a test.
- **Debug app and debug CLI:** test this app through the CE debug CLI, `rpce-cli-debug`, which [`docs/testing.md`](docs/testing.md#debug-cli-and-live-mcp-smoke) covers along with the live MCP smoke flow, the DEBUG-only diagnostics, and the debug app's identity, signing, and profile.
- **MCP tools:** before changing an MCP tool's description, schema, output hints, or CLI help, read [`docs/architecture/mcp-tool-descriptions.md`](docs/architecture/mcp-tool-descriptions.md).
- **Source placement:** [`docs/architecture/source-layout.md`](docs/architecture/source-layout.md) is the ownership map and lists the documented exceptions, and [`docs/architecture/provider-plugins.md`](docs/architecture/provider-plugins.md) covers the Agent Mode provider plugin seam. `make guardrails` enforces the layout.
- **Generated Xcode workspace:** [`docs/architecture/xcode-workspace.md`](docs/architecture/xcode-workspace.md).

## Commit preflight

Before every commit or push, read and run the repository-local [`$rpce-contribution-check`](.agents/skills/rpce-contribution-check/SKILL.md) skill, which owns what each lane checks and which range it validates. Run a lane with `.agents/skills/rpce-contribution-check/scripts/preflight.sh <lane>` at these points:

- `commit`: stage only the intended changes, then run it before creating a commit; rerun it after any staging change, including partial-staging updates.
- `push`: run it after committing and before pushing the intended current branch.
- `pr-ready`: run this full local validation pass on a branch before opening its pull request. It is mandatory.
- `candidate`: run it on a release candidate before the candidate lands. It is mandatory.

Obtain explicit user approval immediately before force-pushing or rewriting `main` or a tag, deleting a remote branch, a fork, or a local branch that isn't merged into `origin/main`, rotating credentials, or making any other GitHub-visible destructive mutation. Rebasing a pull request's own branch and pushing it with `--force-with-lease` bound to the head last observed on the remote doesn't need approval. Neither does removing a local branch you created once it is merged into `origin/main`; a worktree or debug-app workspace you created once its branch is merged and the worktree has no uncommitted changes; a pull request's head branch on `origin` once GitHub shows that pull request merged; or a `release/` branch on `origin` that [`docs/releasing.md`](docs/releasing.md) step 5 deletes after a promotion tag is pushed. Stopping, launching, or relaunching the production RepoPrompt CE app also needs MP's approval, and the reason is the work inside it: an agent session or a Context Builder run that the stop would kill. When MP has said he is away or asleep, that nobody is using the app, or that a validation window is pre-approved, and the app is idle, meaning no agent session is running and no Context Builder run is active, stopping production for that window and relaunching it before MP returns to it is within that approval; record the stop and relaunch times in the run's note. When MP has told you to promote a build, that covers every stop and relaunch the promotion procedure in `docs/releasing.md` makes, as long as the app is idle when you stop it, apart from agent sessions the procedure itself started. The debug app runs beside production and holds none of that work, so launching, stopping, and relaunching it needs no approval.

## Branch model

`main` is the integration branch and the only long-lived branch. Every change reaches `main` from a `bugfix/`, `port/`, or `chore/` branch through a pull request on `mplibunao/repoprompt-ce-local`, so the review, the checks, and the diff stay auditable on GitHub. Approved pull requests land through a release candidate: `main` fast-forwards to the candidate's validated tip and moves in no other way. The agent that owns a pull request takes it through the [`CONTRIBUTING.md`](CONTRIBUTING.md) flow: the debug-app run for changes under `Sources/` or `Packages/`, an independent review and a separate refactor pass, and `pr-ready`, all before the pull request opens, then labels, MP's approval, and the landing. That document also covers stacked pull requests, the Codex review bot, and landing, and [`docs/releasing.md`](docs/releasing.md) owns promotion and its `local/v<version>-b<build>` tags.

## Upstream is read-only

Three repositories share this code and each has a `main`; name them. *Upstream* is `repoprompt/repoprompt-ce`, the maintainers' repository, read only. *The fork* is `mplibunao/repoprompt-ce` on GitHub, frozen with its upstream pull requests open; nothing lands there. *The distribution* is `mplibunao/repoprompt-ce-local` on GitHub and this checkout on disk; every branch, pull request, issue, tag, and promoted build belongs to it, and an unqualified `main` means the distribution's `main`.

Write upstream issues and pull requests as plain text, for example `upstream issue 803` or `upstream PR 957`, never as `owner/repo#N` or a URL, in commit messages, pull request text, issues, and comments: GitHub posts a "mentioned this" event on the referenced item for every such reference from a public repository. A bare `#N` refers to the distribution's own tracker.

Upstream is never a remote of this repository. The preflight's remote allowlist accepts only an `origin` whose fetch and push URLs target `github.com/mplibunao/repoprompt-ce-local`, with or without the `.git` suffix. [`docs/porting.md`](docs/porting.md) names the read-only reference clone for reading upstream and owns the porting procedure, including the rule that an upstream change crosses into this repository only as hand-written source edits.

## Changes to skills and workflow prompts

A plan that changes the built-in workflow prompts under `Sources/RepoPromptShared/Workflows/` states the exact new wording, and implementation starts only after the user approves it. These prompts ship in the app and run in every project, a small wording change can weaken agent behavior, and no evals exist to catch it. Skills under `.agents/skills/` are used only in this repository, and their changes are reviewed in the pull request with the rest of the change. MCP tool descriptions are exempt: their wording can change during implementation, and `docs/architecture/mcp-tool-descriptions.md` covers them.
