# Run ledger: docs layout

Request: #29 · Plan: `docs-layout-run-ledgers-2026-10-16.md`

Commit run ledgers, sanitized investigation reports, and ADRs, keep plans local, and change the built-in Orchestrate and Optimize prompts and the toolkit's `rp-orchestrate-loop` skill to write those records. The orchestrator that ran this work still edited plans as checklists, so this ledger was kept by hand from the template the new Orchestrate prompt carries.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Records and rails | done | engineer · Orchestrate 1/5: Records and rails | `docs: commit run ledgers, investigation reports, and ADRs`; `docs: apply review fixes to the run records and check 8`; `fix: catch home paths after escaped newlines, not inside escaped paths` |
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
- Decision: the per-item `context_builder` reviews that the orchestration workflow requires ran only after items 2 and 3 had started on top of this item, because the first dispatch briefs left them out. Each item still gets its review, and item 2 reruns its scans after this item's review fix. Source: user, who caught the omission.
- Decision: the `agent-doc-home-path` rule accepts an escaped newline, return, or tab right before the path, and no longer accepts a lone backslash there. The first change catches a home path that follows `\n` in JSON text, which the sweep found the rule missing. The second stops a JSON-escaped folder called `home` inside another path, such as a managed Codex home, from being reported, which the `context_builder` review found. Source: review findings.
- Decision: pull requests #203 and #206 land in the same release candidate. Check 8 starts accepting `docs/investigations/` in the same change that brings the sanitized reports, so `main` never accepts tracked reports while only the unsanitized local copies exist. #204 lands in the next candidate after rebasing onto `main`, because it and #206 both edit this ledger and the one merged second would leave a shared candidate. Source: the coordinating session, answering the parked landing-order decision.
- Evidence: a staged `docs/ledgers/tmp.md` holding an absolute home-directory path failed the commit preflight, and a direct gitleaks run attributed it to the new `agent-doc-home-path` rule while passing the same path in a `Tests/*.swift` file.
- Evidence: `make guardrails` passes with the ADRs and this ledger tracked, and a force-added `docs/plans/tmp.md`, `docs/ledgers/tmp.json`, and `docs/ledgersx/tmp.md` each fail check 8.
- Evidence: each changed document matches its approved text byte for byte, apart from the wrapping, the two review fixes above, and the ADR's two filled dates.
- Evidence: `pr-ready` passed on the first commit. An independent review found no blockers, a separate cleanup pass found nothing to change, and the `context_builder` review found the gitleaks false positive above.

## Parked decisions

- Should the toolkit's global unattended-run sentence drop "(orchestrated runs do)"? The clause is false until version 64 is released and toolkit pull request 80 merges, and it stays false for other orchestrators. Options: approve the replacement the toolkit skills audit proposed, or keep the approved text. Recommendation: approve the replacement. Blocks: the wording of toolkit pull request 79.
- In which order do the toolkit pull requests merge? Options: 79 together with or after 80, or 79 first, as planned. Recommendation: together with or after 80, so the toolkit docs never point at a ledger template the skill doesn't have yet. Blocks: merging toolkit pull request 79.
