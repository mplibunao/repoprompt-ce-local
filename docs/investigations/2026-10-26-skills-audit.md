# Skills audit 2026-10-26: walkthroughs before decisions in the planning workflows

> Investigation report, observed 2026-10-26 on `main` at `b99e0db68`, which is also the installed production build (1.4.0 build 63, tag `local/v1.4.0-b63`), and on the toolkit's `main` at `67fbc0b9`. The user's decisions on the proposals are recorded as of 2026-10-27. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [AGENTS.md](../../AGENTS.md), "Changes to skills and workflow prompts"; [CONTRIBUTING.md](../../CONTRIBUTING.md), Plans and committed records.

## Scope

The audit started from one reported gap. On its default route, `rp-deep-plan` asks the user to decide things about the draft without first walking them through it. The user has had to ask for a walkthrough with visuals before deciding, most recently on 2026-10-26 in the planning session for issue #287.

Files read whole:

- The built-in workflow prompts that changed since 2026-10-01: `Sources/RepoPromptShared/Workflows/WorkflowPrompt+DeepPlan.swift` and `WorkflowPrompt+Investigate.swift`, in their MCP, CLI, and Agent Mode variants. The installed version 64 copies of `rp-deep-plan`, `rp-deep-plan-cli`, `rp-investigate`, and `rp-investigate-cli` under `~/.claude/skills/` were written by the installed build, whose workflow sources match `main` exactly (`git diff local/v1.4.0-b63 HEAD -- Sources/RepoPromptShared/Workflows` is empty). The commits: PR #164 (`b81af552e`, `42e3eff4a`, `b4fe830ff`, `c68cc5045`, `91e5b99db`, `77503baab`, `da1029e3c`, `f42972037`; version 63) and `42012fce5`, `03d4b5d1e`, and `fdae217ee` (version 64).
- `WorkflowPrompt+Orchestrate.swift` and `WorkflowPrompt+Optimize.swift`, read for user checkpoints and for version 63's per-item review rule. Their version 64 run-ledger text was audited in [2026-10-18-skills-audit-issue-29-d1.md](2026-10-18-skills-audit-issue-29-d1.md) and has not changed since.
- The Markdown files those commits touch: `.agents/skills/rpce-test-quality/SKILL.md` (its description) and `docs/porting.md` (the section "Workflow prompts and `skillsVersion`").
- The toolkit skills that sit around these workflows: `rp-orchestrate-loop`, `unslop` (`SKILL.md`, `references/chat.md`, `references/docs.md`), and `skills-audit` (`SKILL.md` and its six references).

Neighbours, read without findings of their own: the toolkit's `GLOBAL_CLAUDE.md` and `GLOBAL_AGENTS.md`; section 5 of the toolkit plan `docs/exec-plans/active/2026-10-04-skills-housekeeping.md`; the description of PR #164 and of the two pull requests it replaced, #160 and #163; the other managed `rp-*` skills; the third-party `visual-explainer` skill, version 0.14.0, which updates itself from its publisher; the T3 Code tool descriptions of `html_preview` and `html_render`; and T3 Code's own instructions on showing visuals.

The `rp-*` skills carry `repoprompt_managed: true`, so findings about their text are filed against the Swift sources. Every file with a finding holds wording that the user's or this repository's instructions reserve for the user's approval: the built-in prompts under `AGENTS.md`, and the toolkit's global skills and global rule file. The user reviewed findings 1 to 13 on 2026-10-27. Their Disposition cells record that decision, and [Approved wording](#approved-wording) holds the approved text. Findings 14 to 17 propose no change.

Usage window: 2026-09-26 to 2026-10-26 for Claude Code transcripts and Codex logs; all time for Claude Code's `skillUsage`.

## The three questions

### 1. Was the walkthrough meant for the external route only?

Yes, as written, but nobody decided that the default route should go without one. The walkthrough came from point 4 of section 5 in the toolkit plan `docs/exec-plans/active/2026-10-04-skills-housekeeping.md`, titled "Walkthrough on the external route". Its reason is specific to that route: "when the response comes back, which is input and not approval, the orchestrator explains it in plain language". PR #164 lists Phase 4.5 as "A new Phase 4.5 on the external route, in the interactive modes … *Source: plan, point 4*".

No source weighs the default route (4A). The evidence:

- PR #164 rebuilt both skills from version 62 and added only planned changes: "This branch starts again from version 62 … and adds only the improvements. Wherever version 62 already says something, its wording stays." So Phase 5, the Mid-flow check-in on route 4A, kept version 62's text, which asks questions without explaining the draft.
- The only decision recorded about route 4A's check-in is what happens to cuts: `42e3eff4a` holds them under Open Questions for the design critique, and `da1029e3c` notes that this applies "on the RepoPrompt route; on the external-model route the check-in is the Phase 4.5 walkthrough".
- PR #164's independent review checked consistency, not need: "the version 62 table row that sends Mid-flow to Phase 5 still holds, because Phase 4.5 says it is that check-in on route 4B".
- The plan's verification run 8 tests Hands-off on route 4A and Mid-flow on route 4B. Neither Mid-flow nor Up front on route 4A was ever run.
- Hands-off gained a plain-language explanation at the final hand-off as the user's own correction to the plan (PR #164: "*Source: plan, point 3, and my correction to it on Hands-off*"). So the least involved mode gets an explanation, and the two interactive modes on route 4A get none.

The default route's missing walkthrough is a gap that no one examined. No document records rejecting it.

### 2. Which other workflows have the same gap?

The same gap, or one close to it, appears in these places:

- **`rp-deep-plan-cli` and the Agent Mode Deep Plan.** All three variants render from one source, so each has the gap, and one fix covers all three (finding 1).
- **`rp-deep-plan`'s final hand-off.** Only Hands-off gets a plain-language explanation of the outcome. Up front on route 4A has no checkpoint after the Phase 1.5 interview, so the user meets the draft for the first time as a 2–3 sentence summary followed by its open questions. Users who walked through the draft are not told what the critique and the polish changed afterwards (finding 2).
- **`rp-investigate` and `rp-investigate-cli`.** The user's expectation is half right. An investigation asks no decision after its opening interview, so the deep-plan gap, a decision asked before a walkthrough, cannot happen. But Phase 6 already walks the user through the finished report, on the external route only, and its reason, that the user "has not read the report", holds on the default route too. On the default route the run ends at the report with no instruction to explain it (finding 5). The user approved extending Phase 6 to both routes on 2026-10-27. Its cleanup stays on route B, the external-model route, because only that route writes files to `prompt-exports/` (`WorkflowPrompt+Investigate.swift:176`).

These have no such gap:

- **`rp-orchestrate`, `rp-orchestrate-cli`, and `rp-orchestrate-loop`.** No checkpoint reviews a draft. The decisions they put to the user carry what the user needs: a parked decision has its options, a recommendation, and what it blocks; an ADR candidate in the final rollup is a decision with a trade-off by definition; and the close-out asks one yes-or-no question. Path A dispatches a generated plan without showing it to the user. That is the design of an execution workflow (`rp-deep-plan` exists for planning with the user), so it is not a finding.
- **`rp-optimize`.** Each of its two questions shows its evidence: the divergence pause has a template with `file:line`, and the iteration cap shows the scoreboard first.
- **`rp-review` and `rp-oracle-export`** ask about scope before any work starts. **`rp-build` and `rp-refactor`** have no user checkpoint.

### 3. T3 Code's `html_preview` and `html_render`, or the `visual-explainer` skill?

What each does, from its own documentation (checked 2026-10-26):

- `html_preview` and `html_render` exist only in T3 Code. `html_render` shows one self-contained HTML page inline in the thread, directly above the agent's reply and as wide as the reply column, styled with the thread's theme. `html_preview` renders the same page off-screen and returns a screenshot, the page's height, and its console output, so the agent can check the page first. T3 Code's instructions to every session say: "When a chart, table, diagram, image collage, or mockup would say more than prose, build a self-contained HTML page, check it with `html_preview`, then publish it with `html_render` before your final reply."
- `visual-explainer` (version 0.14.0) writes a source file under `~/.agent/diagrams/`, renders it with its own kit, and opens the result in a browser, except in its own Pi and MCP hosts. It offers formats the T3 tools do not: slide decks, narrated videos, and pages the reader comments on or answers in place. Its description lists "plan reviews" and "visual explanations", and those words match a request for "a walkthrough with visualizations".

Decided 2026-10-27: no document names either tool. The user prefers an inline visual, shown in the harness's own way, whenever the harness supports one. T3 Code does this with `html_render`, Codex desktop with its visualize skill, and Claude desktop with a built-in that has no name. A separate page, such as one `visual-explainer` opens, comes from an explicit request: invoking that skill, or asking for a claude.ai artifact. The rule leaves that case out, because spelling it out invites misreading.

The preference belongs in `unslop`'s `references/chat.md`, in the line that already says the user is a visual collaborator (finding 3). That line governs every reply once the user invokes `unslop` for chat; `unslop` was loaded, for chat or for docs, in 298 Claude Code sessions in the window. In the issue #287 session it was loaded at 06:49 UTC, one minute before the agent chose `visual-explainer`. The old wording was in context and did not settle the choice: it covered only UI and said nothing about where a visual goes.

The workflow prompts say nothing about visuals. A workflow started through `agent_run` with `workflow_name` runs in RepoPrompt Agent Mode with the Agent Mode render (`RepoPromptBuiltInAgentWorkflow.swift:114-124`). Agent Mode's chat renders Markdown tables but no HTML or Mermaid (`Sources/RepoPrompt/Infrastructure/UI/Markdown/EnhancedMarkdownCompiler.swift:572`). An earlier draft added a diagram-or-table sentence to each walkthrough, conditioned on what the host can display. It would not have failed in Agent Mode, but it put a question about the host into every prompt, so it was dropped. The walkthrough itself still has to come from the workflow: in the issue #287 session the user invoked `unslop` for chat at 06:49 UTC, after the agent had asked its questions at 06:14 UTC.

Other owners were considered and rejected:

- `GLOBAL_CLAUDE.md` loads on every turn in every host.
- A shared workflow fragment ships to every project and host, and how a visual is shown has nothing to do with the workflow.
- `visual-explainer` is published by a third party and updates itself, so local edits would be overwritten.
- T3 Code's instructions belong to T3 Code.

## Checks run

| Check | Command or method | Result |
| --- | --- | --- |
| Structure | `pnpm toolkit-lint` and `pnpm verify:skills` from the toolkit root (both read-only). The toolkit lint skips managed skills. No lint exists for the Swift string templates. | One error and one warning in scope: `rp-orchestrate-loop/SKILL.md` is about 8,228 estimated tokens against a hard limit of 2,000 (finding 16); `skills-audit/SKILL.md` is about 1,020 against a target of 1,000 (finding 17). `verify:skills` passed. `rpce-test-quality`'s description (349 characters) has no structural problem under this repository's rules. |
| Usage and dependents | `skillUsage` in `~/.claude.json`; Claude Code transcripts under `~/.claude/projects/` (Skill calls by tool-call id, slash invocations by message id, sessions that read the `SKILL.md`); Codex logs and RepoPrompt CE's Codex home, counting the `<skill>` wrapper (finding 9 explains the match); dependents by `grep` over the toolkit and this repository, leaving out history and investigation reports. No audit sessions (eight or more different skills read) were found. | All-time `skillUsage`: `rp-deep-plan` 78, `rp-deep-plan-cli` 4, `rp-investigate` 84, `rp-investigate-cli` 144, `rp-orchestrate-loop` 41, `unslop` 351, `skills-audit` 10, `visual-explainer` 23. In the window, Claude Code Skill calls and slash invocations: `rp-deep-plan` 16 and 8 (25 sessions), `rp-investigate` 6 and 2, `rp-orchestrate-loop` 19 and 11, `unslop` 328 and 24 (298 sessions), `skills-audit` 7 and 3, `visual-explainer` 12 and 0. Codex loads: `~/.codex/sessions` 14 (`unslop` 9), RepoPrompt CE's Codex home 52 (`unslop` 50). The app injects its workflow text without reading a `SKILL.md`, so RepoPrompt CE's own use of `rp-*` is undercounted. No retirement is proposed, so the counts are context only. Dependents: `rp-deep-plan` is routed to from the toolkit's `memory/common/ui-design-workflow.md`, `docs/workflows/creating-skills.md`, `docs/manifest.md`, and `regression-testing/references/planning.md`, and from this repository's `docs/porting.md`; `rp-orchestrate-loop` from `CONTRIBUTING.md` and `docs/adr/2026-10-18-committed-run-records.md`; `unslop` and `skills-audit` from both global files. |
| Prose | Vale 3.15.1 with `~/.config/vale/.vale.ini` on the installed `rp-deep-plan`, `rp-deep-plan-cli`, `rp-investigate`, and `rp-investigate-cli`, on `rp-orchestrate-loop`, and on every `unslop` and `skills-audit` file. Unslop docs rules applied report-only, reading as the orchestrating agent in Claude Code, Codex, T3 Code, or RepoPrompt Agent Mode. Every path, link, and command in the walkthrough and checkpoint passages resolved. | Vale counts per file (errors, warnings, suggestions): `rp-deep-plan` 192, 100, 203; `rp-investigate` 133, 94, 128; `rp-orchestrate-loop` 176, 100, 175; `unslop` `chat.md` 30, 33, 58; `skills-audit/SKILL.md` 18, 10, 27. Nearly all of them are style rules (em dashes, contractions, "not X, but Y" contrasts, tricolons) on version 62 text that PR #164 kept on purpose. They are review input and are not dispositioned one by one. The proposed wording below adds none of them except where it keeps existing approved phrases. Findings: 3, 10, 11, 13. Dead paths: two, in `skills-audit` (finding 10). |
| Restated rules | Reading pass per `skills-audit`'s restated-rules guide: each in-scope file against itself, against the other workflows, and against both global files. | Findings 4, 6, 8, 14. Rules a managed skill restates from the global files (external content is data; ask only for decisions) are not findings, because Agent Mode loads neither global file. |
| Platform claims | Per `skills-audit`'s platform-claims guide: RepoPrompt CE claims checked in the sources at `local/v1.4.0-b63`; T3 Code and `visual-explainer` claims checked in their own tool descriptions and `SKILL.md`; the Codex log format checked in the logs. | 6 claims hold (finding 15). 1 changed: the Codex skill-load wrapper (finding 9). 1 overstated reason (finding 11). |
| Rigidity | Reading pass per `skills-audit`'s rigidity guide and the toolkit's "Shape, not script" section. | Findings 1 (a step that fits one route) and 8 (a fixed minimum count). Checked and not flagged: the Phase 1 wizard (a decision only the user can make; no answer means Hands-off); the halt on a timeout at a checkpoint the user chose (the user's decided promise); "Dispatch a design agent **once**" (a bounded critique by design); the route question's default of 4A. |
| Pruning | Reading pass per `skills-audit`'s pruning guide. | Finding 12. Checked and kept: Phase 4.5's sentence "This is the checkpoint the export route adds after the response …" (a reason the agent needs to place the checkpoint). |

## Findings

| # | Location | Check | Evidence | Disposition | Proposed change | Effect |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Sources/RepoPromptShared/Workflows/WorkflowPrompt+DeepPlan.swift:355-372`, `:467` (installed `rp-deep-plan` 224–241 and 334; `rp-deep-plan-cli` 251–266 and 355; Agent Mode from the same source) | rigidity (a step that fits one scenario) | Phase 4.5 is headed "Walk the User Through the Draft (route 4B; interactive modes only)". Phase 5, "Mid-flow Check-in (only if "Mid-flow" on route 4A)", says "Read your own draft. Identify 2–4 ambiguities … Ask via `ask_user`." with no walkthrough. The anti-pattern forbids only "skipping the walkthrough after an external response". On 2026-10-26 the planning session for issue #287 ran Mid-flow on route 4A and asked its decision questions at 06:14 UTC; the user then had to ask for a walkthrough with visuals. Question 1 shows that no source decided route 4A should go without one. | correct (approved 2026-10-27, without the visual sentence) | P1 | On route 4A in Mid-flow, the orchestrator first explains the approach, each choice and its tradeoff, and its keep, simplify, or defer view of each piece of machinery, and only then asks its questions. Route 4A's rule that cuts wait for the design critique is unchanged. Where: Agent Mode Deep Plan, and `rp-deep-plan` and `rp-deep-plan-cli` in Claude Code, Codex, and T3 Code once version 65 is installed. |
| 2 | `WorkflowPrompt+DeepPlan.swift:439-446` (installed `rp-deep-plan` 291–298; `rp-deep-plan-cli` 312–319) | rigidity (a step that fits one scenario) | "If the user picked **Hands-off**, surface the plan now with a plain-language explanation of the outcome (the approach, the important choices and their tradeoffs, and what was trimmed and why) …", then "For **all** modes, report: … 2–3 sentence summary … Any open questions that survived the polish pass". Up front on route 4A has no checkpoint after Phase 1.5, so the user's first sight of the draft is a 2–3 sentence summary followed by open questions to answer. A Mid-flow user on either route is not told what the critique and the polish changed after the check-in. | correct (approved 2026-10-27, without the visual sentence) | P2 | Every mode gets the plain-language explanation before any open question. A user who already walked through the draft hears what changed since. Hands-off keeps its refinement offer. Same surfaces as finding 1. |
| 3 | toolkit `.claude/skills/unslop/references/chat.md:15` | prose (the reader can't tell which tool to use); restated rules (no document owns the choice) | "MP is a visual collaborator. When the runtime can render images, pair concise explanations of UI, layouts, screenshots, or visual differences with the relevant images inline; do not require him to reconstruct spatial relationships from prose." The line covers UI only and names no tool. In the issue #287 session, the user invoked `/unslop` at 06:49, the agent loaded `visual-explainer` at 06:50, and it used `html_preview` (07:02) and `html_render` (07:04) only after the user asked why it had not used T3 Code's built-in visuals. T3 Code's instructions point to `html_render`; `visual-explainer`'s description lists "plan reviews". Nothing decides between them. Question 3 gives the reasoning. | correct (approved 2026-10-27, without tool names) | P3 | In any harness that shows visuals inline, an agent that explains a plan, a flow, or a comparison pairs it with an inline visual in that harness's own way. Where: Claude Code and Codex sessions in which the user has invoked `unslop` for chat. |
| 4 | toolkit `GLOBAL_CLAUDE.md:84-85`, against the MCP variants of `rp-deep-plan` (Phases 1, 1.5, 5) and `rp-investigate` (Phase 1) | restated rules (a global rule contradicts the workflows in Claude Code) | `GLOBAL_CLAUDE.md:85`: "If a workflow or skill instructs you to use an MCP tool and that tool is not available …, **stop and report the missing MCP to the user**." The MCP variants say "Ask via `ask_user`." (`WorkflowPrompt+DeepPlan.swift:67`). Claude Code's RepoPrompt CE connection does not expose `ask_user`: this session's 20 RepoPrompt CE tools leave it out, which matches PR #160's finding that RepoPrompt grants it only to Context Builder and Agent Mode runs. `GLOBAL_AGENTS.md:111` (`c02d61fe`, 2026-10-19) lets Codex use its own question tool instead; `GLOBAL_CLAUDE.md` has no such line, and no toolkit record says whether leaving it out was deliberate. In the issue #287 session the agent asked through Claude Code's `AskUserQuestion`, as the Codex rule allows and the Claude rule does not. The `skills-audit` guide treats differences between the two global files as intentional; this row reports the conflict with the workflows, so the user can decide whether the difference is intended. | keep (decided 2026-10-27) | None. Claude adapts without the line: of 37 Claude Code sessions that ran `rp-deep-plan` or `rp-investigate` from 2026-09-27 to 2026-10-27, 14 asked through `AskUserQuestion`, none got a tool-not-found result for `ask_user`, and none stopped to report it missing. `GLOBAL_AGENTS.md` carries the line because Codex follows such instructions literally. | None. |
| 5 | `WorkflowPrompt+Investigate.swift:300-302`, `:388`, `:393` (installed `rp-investigate` 234–236, 323, 328; `rp-investigate-cli` 243, 332, 338) | rigidity (a step that fits one scenario) | "### Phase 6: Walk the User Through It (route B)"; "The user returned the response and has not read the report, so this is a conversation."; "🚫 Skipping the walkthrough after an external response"; "… report → walkthrough on route B." On route A the run ends at Phase 5 with no instruction to explain the report, although the user has not read it on that route either. The plan's point 4 scoped this walkthrough to the external route together with the deep-plan one. | correct (approved 2026-10-27, without the visual sentence) | P5 | On route A, the investigation ends with the same plain-language walkthrough and updates the report with what is agreed. Cleanup of `prompt-exports/` stays on route B. Where: Agent Mode Investigate, and `rp-investigate` and `rp-investigate-cli` once version 65 is installed. |
| 6 | `WorkflowPrompt+DeepPlan.swift:102` and `:470` (installed `rp-deep-plan` 25 and 337), against `:151` and `:159` | restated rule (the copies disagree) | Principle: "(Phase 1 itself is exempt: a timeout on the involvement-mode question means "no signal yet," and the documented Hands-off default applies.)" Anti-pattern: "(Phase 1's involvement-mode prompt is the one exception: a timeout there is treated as "no signal" and falls through to the Hands-off default.)" The route question is asked after the user picks Up front or Mid-flow, and its row says "a skip or timeout here means 4A"; "Handling the answer" says "Phase 1's own questions are the **only** ones in this workflow where a timeout is treated as a default-fallback." The principle and the anti-pattern exempt only the involvement question and name only the Hands-off default. PR #164's review recorded this as "Open, wording, not changed". | correct (approved 2026-10-27) | P6 | A route question that times out takes route 4A, with no competing instruction to halt. |
| 7 | PR #164's description, sections "Independent review" and "Open findings from the automated security review" | open review findings without a tracker entry (outside the seven checks) | Five items the PR left "so I can decide them as follow-ups": the route-question timeout (finding 6); the relative path in Phase 3's `file_actions` create example (`WorkflowPrompt+DeepPlan.swift:262`); and three security-review findings: external content can reach later briefs without the data-not-instructions rule, nothing stops a quoted external "decision" from becoming DECIDED, and the read-only guard accepts "the repository's CLI". A search on 2026-10-26 found no issue in this repository and no entry in the toolkit's tracker for any of them. | keep; issue drafted 2026-10-27, waiting for approval to file | One issue in this repository for the four items finding 6 does not cover, filed through `rpce-issue-creator` once the user approves the draft. | No change in agent behavior until the items are decided. The next agent to edit these prompts can find them. |
| 8 | `WorkflowPrompt+DeepPlan.swift:161`, `:185`, `:370` (installed `rp-deep-plan` 92, 108, 239), against `:101` and the anti-pattern at installed line 324 | rigidity (a fixed count); restated rule | "ask **2–4 thoughtful, plan-shaping questions**", "ask 2–4 questions the findings made askable", and "Identify 2–4 ambiguities" each set a minimum of two. The principle says "at most four per checkpoint", and the anti-pattern forbids "More than 4 questions per checkpoint". A draft with one real ambiguity pushes the agent to invent a second question, which the same paragraph says doesn't count ("Generic workflow meta-questions … don't count"). These are version 62 lines that PR #164 kept because of its own scope rule, not because of a decision about their content. | keep (decided 2026-10-27) | None. The floor of two stays: "2–4" is shorter, and its intent matches "up to four". | None. |
| 9 | toolkit `.claude/skills/skills-audit/references/usage-evidence.md:9` (and `:10`, "Same rule as the Codex logs") | platform claim (changed) | "Sessions whose user-role message carries the `<skill><name>…</name><path>…/SKILL.md</path>` wrapper (a load)". The Codex logs read on 2026-10-26 store an escaped line break between the tags (`<skill>\n<name>unslop</name>\n<path>…`). A search for the literal string returned zero loads for every skill; matching the tags found 14 loads in `~/.codex/sessions` and 52 in RepoPrompt CE's Codex home. | correct (approved 2026-10-27) | P8 | An auditor counting Codex loads matches the tags and stops reporting zero. Where: every `skills-audit` run. |
| 10 | toolkit `.claude/skills/skills-audit/references/usage-evidence.md:3`; `references/rigidity.md:3` | prose (dead path) | "`docs/investigations/2026-10-05-skill-inventory.md`, section 2, is the worked example" and "The "Shape, not script" section of `docs/workflows/creating-skills.md` owns that rule." Both paths exist only in the toolkit. Since `2109632f` (2026-10-16) the skill runs in any repository, and from this one neither path resolves. | keep (decided 2026-10-27) | None. The relative paths are deliberate: the skill works in any repository and on any machine, so it names no machine path. The references resolve when the audit runs in the toolkit. | None. |
| 11 | `WorkflowPrompt+Orchestrate.swift:223` (installed `rp-orchestrate` 192) | prose (an overstated reason); rigidity ("never") | "Never defer to a single review of the whole branch: a multi-item diff does not fit a model's context window, and findings caught late compound across items." The rule itself was decided in PR #160 and carried into #164. Its first reason is stated as always true, but the commits that wrote it name a model with a 1M-token context, and many two-item diffs fit. An agent with a small two-item run could read the rule as not applying to it. | correct (approved 2026-10-27) | P10 | Same rule; the reason no longer suggests an exception when the diff fits. Where: Agent Mode Orchestrate, `rp-orchestrate`, `rp-orchestrate-cli`. |
| 12 | `WorkflowPrompt+DeepPlan.swift:326` (installed `rp-deep-plan` 203); `WorkflowPrompt+Investigate.swift:176` (installed `rp-investigate` 134) | pruning (relevance) | "A future automation replaces this step only; nothing before or after it changes." and "A future automation replaces this hand-off step only." The running agent can't act on either sentence. They record a design intent (the plan's point 5) for whoever automates the hand-off, and the plan and PR #164 already record it. | trim (approved 2026-10-27) | P11 | No change in behavior. The agent loses a note it can't use; a maintainer finds the intent in the plan and in PR #164. |
| 13 | toolkit `.claude/skills/rp-orchestrate-loop/SKILL.md:376`, `:440` | prose (the list numbering restarts) | "1. **Summarize to the user**" follows steps 1 and 2 and a code block; "1. **Loop until**" follows steps 1 to 3 and a code block. Markdown starts a new list at 1 after the block, so each reads as a first step. The managed twin numbers the first one "3." (installed `rp-orchestrate` 350). | correct (approved 2026-10-27) | P12 | Readers see steps 3 and 4 in order. Where: Claude Code and Codex. |
| 14 | `WorkflowPrompt+DeepPlan.swift:102`, `:157`, `:159`, `:193`, `:364`, `:372`, `:470` (the halt-on-timeout rule); `:101` against toolkit `GLOBAL_CLAUDE.md:105` and `unslop` `chat.md:27` | restated rule | The halt-on-timeout rule appears seven times, each at a point where an agent decides whether to wait. "Ask the user only for decisions, each with your recommended answer" overlaps the global "Kill clarifiable ambiguity" bullet and `unslop`'s rule that every question to the user stands on its own. | keep | None. Each halt copy sits at the checkpoint it governs, and finding 6 fixes the one that disagrees. Agent Mode loads neither global file nor `unslop`, so the workflow's copy has to stand alone. | None. |
| 15 | as listed | platform claims (hold) | (a) `agent_run` `wait` takes `session_id` or `session_ids` and `timeout`, and reads `wait` on `steer` (`Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift:319`, `:874-915`, `:1170`), as the deep-plan critique wait assumes. (b) `rp-oracle-export` names exports `prompt-exports/<yyyy-mm-dd>-<hhmmss>-{question,plan,review}-<slug>.md` and offers the presets `standard`, `plan`, and `codeReview` (its `SKILL.md:174-176`, `:188`), as routes 4B and B say. (c) `docs/porting.md:41` and `:45`: a full install is skipped when the stored counter matches and every file exists, and the refresh rewrites only existing managed files, without the check (`Sources/RepoPrompt/Infrastructure/MCP/MCPIntegrationHelper.swift:1350-1356`, `:1376-1380`; `MCPPromptValidationService.swift:44`, `:76`). (d) T3 Code's `html_render` shows a self-contained page inline above the reply, as wide as the reply column; `html_preview` returns a screenshot, the page's height, and console output (tool descriptions, 2026-10-26). (e) `visual-explainer` 0.14.0 writes `~/.agent/diagrams/<name>.src.html`, renders it with its kit, and opens it in a browser outside its Pi and MCP hosts (its `SKILL.md:17-18`). (f) Claude Code's RepoPrompt CE connection exposes no `ask_user` (this session's tool list). | keep | None. | None. |
| 16 | toolkit `.claude/skills/rp-orchestrate-loop/SKILL.md` | structure | Toolkit lint: "exceeds hard limit (~8228 tokens, max: 2000)". Already recorded as finding 5 of [2026-10-18-skills-audit-issue-29-d1.md](2026-10-18-skills-audit-issue-29-d1.md) and in the toolkit's 2026-10-19 question-tool audit. | keep | None here; the earlier audit owns the follow-up. | None. |
| 17 | toolkit `.claude/skills/skills-audit/SKILL.md` | structure | Toolkit lint: "SKILL.md is ~1020 tokens (target: <1000)". A soft target, missed by 2 percent; the body is the procedure. | keep | None. | None. |

## Approved wording

Each item shows the current text and the approved text, decided on 2026-10-27. Swift interpolations such as `\(builderName)` and `\(midFlowAsk)` stay as they are, so each change renders the same way in the MCP, CLI, and Agent Mode variants. The built-in prompt changes (P1, P2, P5, P6, P10, P11) set `skillsVersion` to 65 with a `/// Version 65:` comment, as `docs/porting.md` requires; they can land together under that one version.

None of the prompt changes mentions visuals; question 3 explains why. P4, P7, and P9 were declined and are listed at the end of this section.

### P1. `rp-deep-plan`: walk the user through the draft before Phase 5's questions (finding 1)

`WorkflowPrompt+DeepPlan.swift:370`, the first sentence of Phase 5. Current:

> Read your own draft. Identify 2–4 ambiguities — places where \(builderName) hedged ("could go either way"), tradeoffs without a pick, or assumptions the user might want to weigh in on.

Proposed:

> Read your own draft and walk the user through it before you ask anything, covering Phase 4.5's items 1 to 3. Then identify 2–4 ambiguities — places where \(builderName) hedged ("could go either way"), tradeoffs without a pick, or assumptions the user might want to weigh in on.

The rest of line 370 is unchanged, including the approved sentence "A cut that comes up here, whether from the user or from you, goes under Open Questions with each view rather than into the plan; the design critique weighs in first."

Line 467, the anti-pattern. Current:

> - 🚫 Reframing a DECIDED item as a question in the export, running both routes, offering the export route in Hands-off, or skipping the walkthrough after an external response

Proposed:

> - 🚫 Reframing a DECIDED item as a question in the export, running both routes, offering the export route in Hands-off, or asking the user about the draft before walking them through it

Up front on route 4A gets no new mid-run checkpoint, because that mode promises a pause only before exploration. P2 gives that user the explanation at the hand-off.

### P2. `rp-deep-plan`: explain the outcome to every mode at the hand-off (finding 2)

`WorkflowPrompt+DeepPlan.swift:439`. Current:

> If the user picked **Hands-off**, surface the plan now with a plain-language explanation of the outcome (the approach, the important choices and their tradeoffs, and what was trimmed and why) and offer interactive refinement: *"Plan is at `<path>`. Want me to revise any section, expand scope, or trim anything?"* Treat each round as a focused edit pass on the file, not a re-plan.

Proposed:

> Surface the plan now with a plain-language explanation of the outcome (the approach, the important choices and their tradeoffs, and what was trimmed and why). If the user walked through the draft in Phase 4.5 or Phase 5, explain what changed since then instead. Give the explanation before any open question. If the user picked **Hands-off**, also offer interactive refinement: *"Plan is at `<path>`. Want me to revise any section, expand scope, or trim anything?"* Treat each round as a focused edit pass on the file, not a re-plan.

Lines 441–446 ("For **all** modes, report: …") are unchanged.

### P3. `unslop` chat rules: an inline visual when the harness supports one (finding 3)

Toolkit `.claude/skills/unslop/references/chat.md:15`. Current:

> - MP is a visual collaborator. When the runtime can render images, pair concise explanations of UI, layouts, screenshots, or visual differences with the relevant images inline; do not require him to reconstruct spatial relationships from prose.

Approved:

> - MP is a visual collaborator. Pair an explanation with a visual wherever one shows the structure better than prose: UI, layouts, screenshots, visual differences, a plan's approach, a flow, or options side by side. Show the visual inline in the reply, in the harness's own way, when the harness supports that. Do not require him to reconstruct spatial relationships from prose.

### P5. `rp-investigate`: walk the user through the report on both routes (finding 5)

`WorkflowPrompt+Investigate.swift:300`. Current: `### Phase 6: Walk the User Through It (route B)`. Proposed: `### Phase 6: Walk the User Through It`.

Line 302. Current:

> The user returned the response and has not read the report, so this is a conversation. In plain language, with enough context to follow without opening the report: the answer and the evidence that carries it, what was ruled out and by what, the recommendations, and what is still unknown. Discuss, and update the report with what you agree. Then delete each export and results file that is under `prompt-exports/` (\(deleteExport)); a response the user supplied at any other path is their file and stays.

Proposed:

> The user has not read the report, so this is a conversation. In plain language, with enough context to follow without opening the report: the answer and the evidence that carries it, what was ruled out and by what, the recommendations, and what is still unknown. Discuss, and update the report with what you agree. On route B, then delete each export and results file that is under `prompt-exports/` (\(deleteExport)); a response the user supplied at any other path is their file and stays.

Line 388. Current: `- 🚫 Skipping the walkthrough after an external response`. Proposed: `- 🚫 Skipping the walkthrough`.

Line 393. Current: `… → report → walkthrough on route B.` Proposed: `… → report → walkthrough.`

Route B is the external-model route. Only it writes files to `prompt-exports/` (the exported prompt and the returned results), so the cleanup stays on route B.

### P6. `rp-deep-plan`: both Phase 1 questions fall back to their defaults (finding 6)

`WorkflowPrompt+DeepPlan.swift:102`, the parenthetical. Current:

> (Phase 1 itself is exempt: a timeout on the involvement-mode question means "no signal yet," and the documented Hands-off default applies.)

Proposed:

> (Phase 1 itself is exempt: a timeout on one of its questions means "no signal yet," and that question's documented default applies.)

Line 470, the parenthetical. Current:

> (Phase 1's involvement-mode prompt is the one exception: a timeout there is treated as "no signal" and falls through to the Hands-off default.)

Proposed:

> (Phase 1's questions are the one exception: a timeout there is treated as "no signal" and falls through to that question's default.)

### P8. `skills-audit`: how Codex logs record a skill load (finding 9)

Toolkit `references/usage-evidence.md:9`, the first clause of the "What to count" cell. Current:

> Sessions whose user-role message carries the `<skill><name>…</name><path>…/SKILL.md</path>` wrapper (a load),

Proposed:

> Sessions whose user-role message carries a `<skill>` wrapper with `<name>…</name>` and `<path>…/SKILL.md</path>` inside it (a load; the log stores the line breaks between these tags as an escaped `\n`, so match the tags rather than one literal string),

### P10. `rp-orchestrate`: the reason for per-item review (finding 11)

`WorkflowPrompt+Orchestrate.swift:223`. Current:

> Never defer to a single review of the whole branch: a multi-item diff does not fit a model's context window, and findings caught late compound across items.

Proposed:

> Never defer to a single review of the whole branch: a multi-item diff is often too large for one review to read closely, and findings caught late compound across items.

### P11. Drop the notes about a future automation (finding 12)

Delete "A future automation replaces this step only; nothing before or after it changes." from `WorkflowPrompt+DeepPlan.swift:326`, and "A future automation replaces this hand-off step only." from `WorkflowPrompt+Investigate.swift:176`. The surrounding text is unchanged.

### P12. `rp-orchestrate-loop`: list numbering (finding 13)

Toolkit `.claude/skills/rp-orchestrate-loop/SKILL.md:376`: "1. **Summarize to the user**" becomes "3. **Summarize to the user**". Line 440: "1. **Loop until**" becomes "4. **Loop until**". Check that the toolkit's Markdown formatter keeps the numbers.

### Declined

- **P4**, the question-tool line for `GLOBAL_CLAUDE.md` (finding 4): Claude adapts without it, as the session counts in finding 4 show.
- **P7**, "up to four" in place of "2–4" (finding 8): the current text is shorter and means nearly the same.
- **P9**, machine paths in `skills-audit`'s references (finding 10): the skill is meant to work in any repository on any machine.

## Applied

None. This run reports only. Implementing the approved wording is separate work: the built-in prompts through a pull request in this repository, and the toolkit files in the toolkit.

## Not checked

- **The approved wording, live.** Nothing was run with it. The evidence for P1, P2, and P5 is a live run in T3 Code, which plan verification run 8 never covered: `rp-deep-plan` in Mid-flow on route 4A, checking that the walkthrough arrives before the questions; in Up front on route 4A, checking that the hand-off explains the plan before any open question; and `rp-investigate` on route A, checking that the run ends with the walkthrough. The validation matrix row for `Sources/RepoPromptShared/**` adds `make dev-swift-build PRODUCT=repoprompt-mcp`, and `CONTRIBUTING.md` adds a debug-app run for changes under `Sources/`. Rendering all three variants, with session-cleanup guidance on and off, and checking each changed passage by exact text is how PR #164 confirmed its wording.
- **`rp-orchestrate`, `rp-optimize`, and `rp-orchestrate-loop`, line by line.** Their version 64 run-ledger text was audited on 2026-10-18, and its recommendations are in the current text (for example, the close-out checks whether git tracks the plan before checking decisions). This audit read them only for user checkpoints and for version 63's per-item review rule.
- **Vale findings one by one.** They are counted in the Checks table and not dispositioned, because PR #164 kept the version 62 wording on purpose.
- **`visual-explainer` and T3 Code's instructions** are third-party text. They were read as neighbours, with no findings.
