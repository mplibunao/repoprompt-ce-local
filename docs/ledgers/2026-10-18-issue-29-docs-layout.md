# Run ledger: docs layout

Request: #29 · Plan: `docs-layout-run-ledgers-2026-10-16.md`

Commit run ledgers, sanitized investigation reports, and ADRs, keep plans local, and change the built-in Orchestrate and Optimize prompts and the toolkit's `rp-orchestrate-loop` skill to write those records. The orchestrator that ran this work still edited plans as checklists, so this ledger was kept by hand from the template the new Orchestrate prompt carries.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Records and rails | done | engineer · Orchestrate 1/5: Records and rails | `docs: commit run ledgers, investigation reports, and ADRs`; `docs: apply review fixes to the run records and check 8`; `fix: catch home paths after escaped newlines, not inside escaped paths` |
| 2. Investigations sweep | pending | | |
| 3. Built-in Orchestrate ledger and Optimize scoreboard | done | engineer · Orchestrate 3/5: Built-in Orchestrate ledger and Optimize scoreboard | `feat(workflows): record Orchestrate runs in a run ledger`; `feat(workflows): write the Optimize scoreboard to docs/ledgers`; `test(workflows): apply review fixes to the run-record test and porting notes` |
| 4. Toolkit loop ledger and docs | pending | | |
| 5. Citation check and ledger close-out | pending | | |

## 1. Records and rails

- Decision: every item's implementation runs on the `engineer` role, including the investigations sweep and the prompt changes, which the plan gave to `pair`. Source: orchestrator judgment, keeping the costlier `pair` model for design critique.
- Decision: the new `CONTRIBUTING.md` paragraphs are wrapped to the file's 80-column prose width without changing a word. Source: approved plan.
- Decision: check 8 lists tracked docs with `core.quotePath=false`. Without it, git quotes a non-ASCII path, the existence test fails, and a file such as `docs/plans/café.md` skips the check. Source: review finding.
- Decision: `CONTRIBUTING.md` says the `rp-orchestrate-loop` skill lives in a separate toolkit repository, because the public repository has no other mention of it. Source: review finding.
- Decision: two review findings are left as they are. The ADR template's placeholders render as empty HTML tags on GitHub, but agents copy the source. The benchmark scoreboard and the Swift 6 migration inventory are appended to during a campaign, while the records table says reports aren't edited after they land; a later campaign writes a new dated report. A third finding, that these docs describe workflow behavior the prompt changes add, is a matter of landing order. Source: orchestrator judgment.
- Decision: the per-item `context_builder` reviews that the orchestration workflow requires ran only after items 2 and 3 had started on top of this item, because the first dispatch briefs left them out. Each item still gets its review, and item 2 reruns its scans after this item's review fix. Source: user, who caught the omission.
- Decision: the `agent-doc-home-path` rule accepts an escaped newline, return, or tab right before the path, and no longer accepts a lone backslash there. The first change catches a home path that follows `\n` in JSON text, which the sweep found the rule missing. The second stops a JSON-escaped folder called `home` inside another path, such as a managed Codex home, from being reported, which the `context_builder` review found. Source: review findings.
- Evidence: a staged `docs/ledgers/tmp.md` holding an absolute home-directory path failed the commit preflight, and a direct gitleaks run attributed it to the new `agent-doc-home-path` rule while passing the same path in a `Tests/*.swift` file.
- Evidence: `make guardrails` passes with the ADRs and this ledger tracked, and a force-added `docs/plans/tmp.md`, `docs/ledgers/tmp.json`, and `docs/ledgersx/tmp.md` each fail check 8.
- Evidence: each changed document matches its approved text byte for byte, apart from the wrapping, the two review fixes above, and the ADR's two filled dates.
- Evidence: `pr-ready` passed on the first commit. An independent review found no blockers, a separate cleanup pass found nothing to change, and the `context_builder` review found the gitleaks false positive above.

## 3. Built-in Orchestrate ledger and Optimize scoreboard

- Decision: `docs/porting.md` cites the ADR as `docs/adr/2026-10-18-committed-run-records.md`, filling the date placeholder in the approved text. Source: approved plan.
- Decision: the run-record test also asserts that the old "in the export file" monitor sentence is absent, so a port that drops the `recordStep:` argument fails it. Source: review finding.
- Decision: two `docs/porting.md` sentences now match the installer code: a full install also rewrites when a skill file is missing, and the workspace-switch and app-launch refreshes skip the counter and update only existing copies. Source: review finding.
- Decision: four review findings are left as they are. The Prior perf work scout doesn't search `docs/ledgers/`, and Optimize has no fallback location; the user decided both. The single-item ledger sentence is explicit, and the `/// Version 64:` comment is accurate. Source: orchestrator judgment.
- Decision: the Optimize setup and loop briefs keep their approved wording and don't repeat the scoreboard's writing rule. Adding it would be overengineering, session IDs in a scoreboard help later analysis, and the briefs' exact lines were already approved. Source: user.
- Evidence: the four workflow sources match their approved text byte for byte. Rendering every other workflow, variant, and setting on `main` and on this branch differs only in the skills version line.
- Evidence: each run-record test fails in all six variant and setting cases when its change is undone.
- Evidence: in the debug app, an Orchestrate run in a scratch repository wrote its ledger where that repository's AGENTS.md said, with both rows `done`. The plan survived the run, "Looks good." got one question about deleting it, and "Yes, the work is done." deleted it after the decision check. A tracked plan was kept, and without AGENTS.md the ledger went to `docs/ledgers/`. An Optimize run in the same scratch repository wrote `docs/ledgers/2026-10-18-optimize-count-primes.md` there from setup on, with the baseline, one iteration, and Rejected candidates.
- Evidence: the agents in those runs drifted from the template: decisions in run-level sections, a session column that didn't match the session name, no scope line in the scoreboard, home paths in the scoreboard's notes, and the setup agent writing Rejected candidates.
- Evidence: `pr-ready` passed with 1,767 root tests. An independent review found no blockers, a separate cleanup pass found nothing to change, and a `context_builder` review of the branch found no defects.
- Deferred: every `context_builder` call from an Agent Mode session in the debug app returned "Tool execution was cancelled". Nothing in this change causes it, and it needs its own investigation.

## Parked decisions

- Should pull request #203 land only in the same release candidate as the investigations sweep? Landing it first lets the unsanitized local reports in the main checkout pass check 8, and most of them gitleaks, until the sweep lands and the originals are removed. Options: the same candidate as the sweep; a candidate with the prompt changes first, as planned, accepting that window; or moving `docs/investigations/` from check 8's record folders in this pull request to the sweep's pull request, so this one is safe to land alone. Recommendation: the same candidate as the sweep, or the move if the prompt changes have to land first. Blocks: landing item 1.
- Should the toolkit's global unattended-run sentence drop "(orchestrated runs do)"? The clause is false until version 64 is released and toolkit pull request 80 merges, and it stays false for other orchestrators. Options: approve the replacement the toolkit skills audit proposed, or keep the approved text. Recommendation: approve the replacement. Blocks: the wording of toolkit pull request 79.
- In which order do the toolkit pull requests merge? Options: 79 together with or after 80, or 79 first, as planned. Recommendation: together with or after 80, so the toolkit docs never point at a ledger template the skill doesn't have yet. Blocks: merging toolkit pull request 79.
