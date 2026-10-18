# Run ledger: docs layout

Request: #29 · Plan: `docs-layout-run-ledgers-2026-10-16.md`

Commit run ledgers, sanitized investigation reports, and ADRs, keep plans local, and change the built-in Orchestrate and Optimize prompts and the toolkit's `rp-orchestrate-loop` skill to write those records. The orchestrator that ran this work still edited plans as checklists, so this ledger was kept by hand from the template the new Orchestrate prompt carries.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Records and rails | done | engineer · Orchestrate 1/5: Records and rails | `docs: commit run ledgers, investigation reports, and ADRs`; `docs: apply review fixes to the run records and check 8` |
| 2. Investigations sweep | pending | | |
| 3. Built-in Orchestrate ledger and Optimize scoreboard | pending | | |
| 4. Toolkit loop ledger and docs | pending | | |
| 5. Citation check and ledger close-out | pending | | |

## 1. Records and rails

- Decision: every item's implementation runs on the `engineer` role, including the investigations sweep and the prompt changes, which the plan gave to `pair`. Source: orchestrator judgment, keeping the costlier `pair` model for design critique.
- Decision: the new `CONTRIBUTING.md` paragraphs are wrapped to the file's 80-column prose width without changing a word. Source: approved plan.
- Decision: check 8 lists tracked docs with `core.quotePath=false`. Without it, git quotes a non-ASCII path, the existence test fails, and a file such as `docs/plans/café.md` skips the check. Source: review finding.
- Decision: `CONTRIBUTING.md` says the `rp-orchestrate-loop` skill lives in a separate toolkit repository, because the public repository has no other mention of it. Source: review finding.
- Decision: two review findings are left as they are. The ADR template's placeholders render as empty HTML tags on GitHub, but agents copy the source. The benchmark scoreboard and the Swift 6 migration inventory are appended to during a campaign, while the records table says reports aren't edited after they land; a later campaign writes a new dated report. A third finding, that these docs describe workflow behavior the prompt changes add, is a matter of landing order. Source: orchestrator judgment.
- Evidence: a staged `docs/ledgers/tmp.md` holding an absolute home-directory path failed the commit preflight, and a direct gitleaks run attributed it to the new `agent-doc-home-path` rule while passing the same path in a `Tests/*.swift` file.
- Evidence: `make guardrails` passes with the ADRs and this ledger tracked, and a force-added `docs/plans/tmp.md`, `docs/ledgers/tmp.json`, and `docs/ledgersx/tmp.md` each fail check 8.
- Evidence: each changed document matches its approved text byte for byte, apart from the wrapping, the two review fixes above, and the ADR's two filled dates.
- Evidence: `pr-ready` passed on the first commit. An independent review found no blockers, and a separate cleanup pass found nothing to change.

## Parked decisions

- Should pull request #203 land only in the same release candidate as the investigations sweep? Landing it first lets the unsanitized local reports in the main checkout pass check 8, and most of them gitleaks, until the sweep lands and the originals are removed. Options: the same candidate as the sweep, or a candidate with the prompt changes first, as planned, accepting that window. Recommendation: the same candidate as the sweep. Blocks: landing item 1.
- Should the toolkit's global unattended-run sentence drop "(orchestrated runs do)"? The clause is false until version 64 is released and toolkit pull request 80 merges, and it stays false for other orchestrators. Options: approve the replacement the toolkit skills audit proposed, or keep the approved text. Recommendation: approve the replacement. Blocks: the wording of toolkit pull request 79.
- In which order do the toolkit pull requests merge? Options: 79 together with or after 80, or 79 first, as planned. Recommendation: together with or after 80, so the toolkit docs never point at a ledger template the skill doesn't have yet. Blocks: merging toolkit pull request 79.
