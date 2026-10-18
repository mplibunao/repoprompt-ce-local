# Run ledgers, investigation reports, and ADRs are committed, and plans stay local

Status: accepted, 2026-10-18
Sources: #29, `docs/ledgers/2026-10-18-issue-29-docs-layout.md`

## Context

Agents and Context Builder explain past decisions from files in the checkout. Context Builder cannot read git history or GitHub. Plans, investigation reports, optimization scoreboards, and orchestration progress lived only in untracked local files. Orchestrated runs mostly happen in worktrees, which are deleted after merge, so what a run decided survived only in commit messages and chat. A plan also records intent rather than outcome: items change during a run, so a committed plan either drifts from what happened or is edited until it no longer shows what was approved.

## Decision

- Each orchestrated run writes one ledger in `docs/ledgers/`, committed in the run's pull request: a table of work items with outcome, agent session, and commits, then a short log per item with its decisions and their sources, deferrals as issue numbers, and evidence. The built-in Orchestrate workflow and the toolkit's `rp-orchestrate-loop` skill both write it. The built-in Optimize workflow writes its scoreboard there too, as that run's record.
- Plans stay local in the gitignored `docs/plans/`. The orchestrator deletes a run's plan when the user says the work is done, after checking that the plan's decisions are in the ledger or an ADR.
- Investigation reports in `docs/investigations/` are committed after redaction. Each is dated evidence and never overrides a current document.
- A decision that is hard to reverse, would surprise someone without the background, and involved a real trade-off gets an ADR in `docs/adr/`.
- GitHub issues and pull requests remain the record of open work.

## Alternatives considered

- Commit plans in active and completed folders: plans are long and change during a run. Keeping them current needs the edit-in-place checklist this decision removes, and the ledger keeps the outcome without the draft.
- Keep ledgers local: a ledger written in a run's worktree is deleted with the worktree, and nobody reading the repository can see it.
- A tech-debt tracker for deferrals: issues already track open work, and a second list drifts from them.

## Consequences

- Context Builder and later agents can cite a ledger, investigation, or ADR as the source of a past decision.
- The repository is public, so reports and ledgers need redaction before commit. A gitleaks rule scoped to `docs/investigations/` and `docs/ledgers/` rejects absolute home paths. The rest depends on the redaction rules in `CONTRIBUTING.md`.
- Older investigations describe processes that have since changed. Each opens with its date, and current documents take precedence.
- The ledger stays short and gates nothing: a missing entry never holds up dispatch, review, or a commit.
- Upstream ports that touch the Orchestrate or Optimize prompts keep their ledger, close-out, and scoreboard passages (`docs/porting.md`).
