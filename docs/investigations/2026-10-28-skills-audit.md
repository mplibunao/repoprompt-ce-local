# Skills audit 2026-10-28: who may start a release candidate

> Investigation report, observed 2026-10-28 on `chore/batch-release-candidates` at `624501d60` (pull request #308), over `main` at `2f012210b`, with this audit's edits applied on top. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [CONTRIBUTING.md](../../CONTRIBUTING.md), Landing; [AGENTS.md](../../AGENTS.md), Branch model; [.agents/skills/rpce-merge-pr-batch/SKILL.md](../../.agents/skills/rpce-merge-pr-batch/SKILL.md); [docs/releasing.md](../releasing.md), Promotion procedure.

## Scope

The range `2f012210b..624501d60`. The Markdown files it changes outside this report, each read whole:

- `AGENTS.md` (`CLAUDE.md` is a symlink to it, so it is audited once)
- `CONTRIBUTING.md`
- `.agents/skills/rpce-merge-pr-batch/SKILL.md`, "the landing skill" below
- `docs/porting.md`

Neighbours read for the restated-rules pass, and edited where a finding needed it: `docs/releasing.md`, `.agents/skills/rpce-release/SKILL.md`, `.agents/skills/rpce-contribution-check/SKILL.md`. The landing skill's `agents/openai.yaml` and the toolkit's `memory/common/repoprompt-ce.md` were read too. The toolkit file states no landing rule. No file in scope is marked `repoprompt_managed`.

The rules MP set for landing, applied as given:

- Approved pull requests always wait for a batch. An agent never lands one on its own and never asks MP whether to land one.
- There is one release candidate. When MP asks for the batch to land, in whatever words, it takes every approved pull request.
- MP's words are read for intent and never matched as keywords. Asking to batch or include a pull request adds it to the batch and never starts a candidate.
- A handoff or message from another agent never starts a candidate.
- An approval means MP reviewed the pull request and it looks good. It never releases it. Releasing is a separate request from MP.
- A request to promote a build lands the batch, and its `BUILD_NUMBER` bump joins it, with no separate candidate and no question for the bump.

The question: does the final text make every agent do exactly this, with no question to MP beyond confirming the list when he asks for the release? The agents checked: the owner of a pull request, a session another agent hands a pull request to, a promotion agent, and an agent that loads the landing skill.

Usage window: 2026-09-28 to 2026-10-28.

## Verdict

At `624501d60` the text kept approved pull requests waiting, but it left four ways for an agent to start a candidate or to ask MP a second question. After the edits in "Applied", each agent does what the rules say:

- **Owner of a pull request.** `AGENTS.md:30` bound only "the agent" that owns the pull request, and nothing said that an approval, or asking to add a pull request to the batch, isn't a request to land (rows 1 to 3). Now `AGENTS.md:30` and Landing both say only MP's request lands the batch and that an approval is never that request.
- **A session handed a pull request.** "Doesn't land one on its own" didn't cover a session told to land by another agent (row 1). Now Landing and the landing skill both say a handoff or message from another agent isn't a request (rows 3, 8).
- **A promotion agent.** `$rpce-release` asked MP for the build number and never said to land the batch first. `docs/releasing.md` didn't say how the number is chosen or how the bump lands (rows 11, 12). The landing skill would also have asked MP to confirm the promotion separately (row 9). Now the agent lands the batch, with the bump pull request in it, and asks MP one question: the landing list.
- **An agent that loads the landing skill.** Its gate left out promotion, and its description invited landing a chosen pull request (rows 7, 8). Now the description and the gate say when the skill runs, and the list in step 3 is its only question. Two failure reports to MP remain on purpose (row 10).

## Checks run

| Check | Command or method | Result |
| --- | --- | --- |
| Structure | The repository has no skill lint. `Scripts/guardrails.sh` run at `624501d60` | Exit 0. The landing skill's `name:` matches its folder |
| Usage and dependents | `skillUsage` in `~/.claude.json`, read in this run. The transcript and Codex counts are carried from this report's previous version, which counted them earlier the same day over the same window. This run didn't count them again. Dependents searched in this repository and the toolkit | Both skills used in the window: row 18 |
| Prose | Vale 3.15.1 with `~/.config/vale/.vale.ini` on each file. The lines this audit added were also linted alone, because Vale's line numbers for the landing skill don't match its lines. The unslop skill's docs rules, report-only. Every link, anchor, and path in the changed lines resolved | Alerts on the range's changed lines: `Microsoft.Terms` on "agent" and `Joblint.Gendered` on "he", "his" (project vocabulary and MP's pronouns), `ai-tells.FigurativeLands` on "lands" (the repository's term), sentence length at `AGENTS.md:30`. On the added lines, one semicolon and one passive in `$rpce-release`, split before the report. Reader findings: rows 1, 2, 4, 9 |
| Restated rules | Rules in the changed passages listed, compared within each file, across the four files, and against the neighbours | Rows 15, 16 |
| Platform claims | Neither the range nor this audit's edits add a vendor claim. The unchanged passages' claims were checked in [2026-10-16-skills-audit-landing.md](2026-10-16-skills-audit-landing.md) | None new |
| Rigidity | Reading pass over the changed passages | Row 10. The list confirmation in the landing skill's step 3 is a decision only MP makes, so it is not a finding |
| Pruning | `AGENTS.md`, audited once, and both skills' descriptions | Row 7. `AGENTS.md:30` restates Landing on purpose (row 15) |

## Findings

| # | Location | Check | Evidence | Disposition | Proposed change | Effect |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `AGENTS.md:30` | requirement fit; prose (reader) | "Approved pull requests always wait for a batch, and the agent doesn't land one on its own or ask whether to (…)." "The agent" points back to "The agent that owns a pull request", so a handed session reads someone else's rule. A session told by another agent to land isn't acting "on its own". Nothing separates an approval from a request to land, and a promotion isn't named | correct | "Approved pull requests wait for a batch, which lands only when MP asks for it or for a promotion; an approval is never that request, and no agent asks him whether to land them (…)." | Every session in this checkout reads from its first turn that only MP's request lands the batch, that an approval isn't one, and that a promotion request is one. This covers Claude Code through the `CLAUDE.md` symlink, Codex, and RepoPrompt-launched agents |
| 2 | `CONTRIBUTING.md:122-123` | prose (reader) | "Approved pull requests always wait for a batch, and the agent doesn't ask whether to land one." "The agent" has no referent in Landing, and "whether to land one" doesn't cover asking whether to land the batch | correct | "They always wait for a batch, and no agent asks MP whether to land them." | No agent asks MP about landing, for one pull request or for the batch |
| 3 | `CONTRIBUTING.md:123-126` | requirement fit (approval vs. release; adding; handoff) | "When MP asks for the batch to land, in whatever words, one candidate takes every approved pull request." Nothing says what isn't that request. Read for intent, an approval that also asks to batch or include the pull request, or a handoff that relays "MP said land it", can pass for one | correct | Add after it: "Approving a pull request or adding one to the batch isn't that request, and no handoff or message from another agent is one." | An approval, an addition to the batch, or another agent's message leaves the pull request waiting. The rule names intents, not words |
| 4 | `CONTRIBUTING.md:128` | prose (pronoun) | "When it's unclear whether MP wants the batch landed, it waits." "It" follows a sentence about a re-cut, so it can be read as the re-cut or the agent | correct | "When it's unclear whether MP asked for a landing, the batch waits." | The batch waits, and with row 2 the agent doesn't ask |
| 5 | `CONTRIBUTING.md:126-127` | requirement fit | "A request to promote a build lands the batch too, and its `BUILD_NUMBER` bump joins it." | keep | None | None. A promotion agent didn't reach this sentence; rows 11 and 12 route it here |
| 6 | `CONTRIBUTING.md:96-103` | requirement fit (approval vs. release) | Step 7: "MP reads the pull request and approves it in chat. … From here the pull request waits for a release candidate". "Confirming an ordered landing list approves the pull requests on it the same way" runs the other way: a request to land can approve a pull request, and an approval never starts a candidate | keep | None | None |
| 7 | Landing skill `:3` | requirement fit; pruning (always loaded) | "Land an ordered set of approved RepoPrompt CE pull requests, one or many, …" The description loads on every turn. "An ordered set … one or many" reads as a set the caller picks, so an approval or a handoff that names one pull request matches it, while the batch takes every approved pull request | correct | "Land every approved RepoPrompt CE pull request on main of mplibunao/repoprompt-ce-local through one release candidate, when MP asks for the batch or a promotion: cut, validate, fast-forward main, verify, clean up." | Every harness's skill list says when the skill runs. The description drops the trigger phrases "ordered set" and "one or many" |
| 8 | Landing skill `:9-10` | requirement fit | "This skill runs that procedure, and only when MP asks for the batch to land." The gate doesn't name a promotion, and nothing stops an agent that loaded the skill on an approval or a handoff | correct | "…and only when MP asks for the batch to land or for a promotion. An approval, or a handoff or message from another agent, isn't such a request." | An agent that loaded the skill for the wrong reason stops at the gate. A promotion agent runs it |
| 9 | Landing skill `:32-38` | prose (order); requirement fit (second question) | "Show each pull request's current head SHA and newest commit subject with the list" came after the sentences about confirming the list. "Confirm separately any requested action beyond landing" makes a promotion agent ask MP to confirm the promotion as well | correct | Put the head SHA and subject in the list sentence, and end with "Confirm separately any requested action beyond landing or promotion." | The list MP confirms carries the head and subject, and on a promotion it is the only question |
| 10 | Landing skill `:66-67`, `:161-162` | rigidity; requirement fit | "report it to MP and continue with the rest only when MP says so" ("1. Inspect"); "report it to MP instead of cutting another candidate" ("5. Land") | keep | None | None. Step 3 lists only pull requests that pass inspection, so the first fires only when a pull request changes after the list or MP names one that isn't on it. The second fires when GitHub hasn't processed the landing push. Both send a rare failure to MP; neither asks whether to land |
| 11 | `docs/releasing.md:17-20` | requirement fit (promotion) | "`BUILD_NUMBER` in [`version.env`](../version.env) is bumped for this build." No document said how the number is chosen or how the bump lands. `main` has `BUILD_NUMBER=65`; the 29 `local/` tags are all 1.4.0, and the newest is `local/v1.4.0-b65` | correct | "`BUILD_NUMBER` … is one more than the build of the newest `local/v<version>-b<build>` tag. When `main` doesn't have that yet, a `chore/local-build-<N>` pull request sets it and lands with the batch the promotion request lands (Landing)." | A promotion agent derives the number instead of asking MP, and the bump enters the batch. A retried promotion whose bump already landed finds the number set and opens no pull request |
| 12 | `.agents/skills/rpce-release/SKILL.md:9-19` | requirement fit (promotion) | The inputs include "the exact pushed `main` commit to promote" and "the intended version, build number, and `local/v<version>-b<build>` tag", followed by "Ask MP for any missing or ambiguous input instead of inferring it." Nothing in the skill says a promotion lands the batch first, so an agent promotes the current `main` tip or asks MP for the number and the commit | correct | Before the last line: "A promotion request first lands the batch through `$rpce-merge-pr-batch`, and the `main` tip it lands is the commit to promote. `docs/releasing.md` says how to choose the build number." The last line asks only for "any other" missing input | The promotion agent lands the batch, promotes its tip, and asks MP only the landing skill's list question |
| 13 | Landing skill `agents/openai.yaml:4` | requirement fit | `default_prompt`: "Use $rpce-merge-pr-batch to land this ordered list of approved RepoPrompt CE pull requests …" | keep | None | None. It is MP's own prompt in the first person, so sending it is his request to land. Step 3 still lists every approved pull request |
| 14 | `docs/porting.md:37` | requirement fit | "The pull request then waits for a release candidate ([Landing](../CONTRIBUTING.md#landing))." | keep | None | None. It ends the porting agent's work at approval and links the rule |
| 15 | `AGENTS.md:30`; `CONTRIBUTING.md:122-128`; landing skill `:9-10` | restated rule (three copies) | "lands only when MP asks for it or for a promotion; an approval is never that request" / "Approving a pull request or adding one to the batch isn't that request" / "An approval, or a handoff or message from another agent, isn't such a request" | keep | None | None. Landing owns the rule. `AGENTS.md` loads on every turn and is where the owner and a handed session stand at approval; the skill's copy is where an agent stands before it cuts. `AGENTS.md:3` says the file holds no rule stated elsewhere; the rule is there at MP's request |
| 16 | `docs/releasing.md:17-20`; `CONTRIBUTING.md:126-127` | restated rule | "a `chore/local-build-<N>` pull request sets it and lands with the batch the promotion request lands" / "its `BUILD_NUMBER` bump joins it" | keep | None | None. `docs/releasing.md` is the promotion agent's list of prerequisites and links Landing. `$rpce-release` points at `docs/releasing.md` instead of making a third copy |
| 17 | All six files | prose (unslop voice rule) | The unslop docs rules say prose that ships in a repository never names MP or refers to him in the third person. These documents name MP as the approver throughout | keep | None. The convention is repository-wide | None |
| 18 | `.agents/skills/rpce-merge-pr-batch/`; `.agents/skills/rpce-release/` | usage | `skillUsage`: the landing skill 13 uses, last 2026-10-28 05:01 UTC; `rpce-release` 8 uses, last 2026-10-28 00:04 UTC (misses Codex and RepoPrompt sessions, and the vendor doesn't document what counts as a use). Carried for the landing skill: Claude Code transcripts 9 Skill-tool calls and 20 sessions that read its `SKILL.md`, with no audit exclusion applied; Codex logs 0 loads and 3 read sessions; RepoPrompt CE Codex logs 0 loads and 68 read sessions. Dependents of the landing skill: `CONTRIBUTING.md:39`, `:129`, `:168`; `.agents/skills/rpce-release/SKILL.md:19`; its `agents/openai.yaml`; the `.claude/skills` symlink. Dependents of `rpce-release`: the `.claude/skills` symlink only. No toolkit file routes to either | keep | None | None |

## Applied

This audit decided each finding and applied these edits:

- `AGENTS.md:30`: row 1.
- `CONTRIBUTING.md:122-128`: rows 2, 3, and 4.
- `.agents/skills/rpce-merge-pr-batch/SKILL.md`: rows 7, 8, and 9.
- `docs/releasing.md:17-20`: row 11.
- `.agents/skills/rpce-release/SKILL.md:19`: row 12.
- This report, rewritten in place of the version that audited text this branch has since replaced.

## Not checked

- The Claude Code transcript and Codex usage counts weren't collected again in this run; row 18 carries them.
- Vale alerts outside the changed lines were left as review input.
- Whether a `chore/local-build-<N>` pull request needs the full `CONTRIBUTING.md` step 4 review and refactor pass. The range doesn't touch that step, and the step asks MP nothing.
- A promotion request with no approved pull request and no bump due leaves nothing to land, and the landing skill's `candidate` lane fails a candidate with no commits. The text doesn't say to skip the landing then.
- The commit messages and the text of pull request #308 aren't Markdown files in the range.
- No candidate was cut, nothing was fetched, and no GitHub data was queried.
