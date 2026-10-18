# Run ledger: docs layout

Request: #29 · Plan: `docs-layout-run-ledgers-2026-10-16.md`

Commit run ledgers, sanitized investigation reports, and ADRs, keep plans local, and change the built-in Orchestrate and Optimize prompts and the toolkit's `rp-orchestrate-loop` skill to write those records. The orchestrator that ran this work still edited plans as checklists, so this ledger was kept by hand from the template the new Orchestrate prompt carries.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Records and rails | done | engineer · Orchestrate 1/5: Records and rails | `docs: commit run ledgers, investigation reports, and ADRs` |
| 2. Investigations sweep | pending | | |
| 3. Built-in Orchestrate ledger and Optimize scoreboard | pending | | |
| 4. Toolkit loop ledger and docs | pending | | |
| 5. Citation check and ledger close-out | pending | | |

## 1. Records and rails

- Decision: every item's implementation runs on the `engineer` role, including the investigations sweep and the prompt changes, which the plan gave to `pair`. Source: orchestrator judgment, keeping the costlier `pair` model for review work.
- Decision: the new `CONTRIBUTING.md` paragraphs are wrapped to the file's 80-column prose width without changing a word. Source: approved plan.
- Evidence: a staged `docs/ledgers/tmp.md` holding an absolute home-directory path failed the commit preflight under the new `agent-doc-home-path` gitleaks rule, and the same path in a `Tests/*.swift` file passed.
- Evidence: `make guardrails` passes with the ADRs and this ledger tracked, and a force-added `docs/plans/tmp.md`, `docs/ledgers/tmp.json`, and `docs/ledgersx/tmp.md` each fail check 8.
- Evidence: each changed document matches its approved text byte for byte, apart from the wrapping above and the ADR's two filled dates.
