# Skill wording for approval: release-candidate landing (after the skills audit)

> Investigation report, observed 2026-10-16. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [.agents/skills/rpce-merge-pr-batch/SKILL.md](../../.agents/skills/rpce-merge-pr-batch/SKILL.md), the whole skill; [.agents/skills/rpce-contribution-check/SKILL.md](../../.agents/skills/rpce-contribution-check/SKILL.md), Candidate validation.

This file listed, for MP's approval under `AGENTS.md`, "Changes to skills and workflow prompts", the skill wording behind the release-candidate landing change, with the fixes from [2026-10-16-skills-audit-landing.md](2026-10-16-skills-audit-landing.md) folded in:

- the full rewrite of `rpce-merge-pr-batch`, kept in [2026-10-16-landing-proposed-merge-batch-SKILL.md](2026-10-16-landing-proposed-merge-batch-SKILL.md), with the wording that differed from the design quoted section by section;
- the new launcher text in `rpce-merge-pr-batch/agents/openai.yaml`, which stops wherever `AGENTS.md` reserves an action for MP's approval;
- `references/review-prompts.md` reframed for the review before MP approves a pull request, not for landing time;
- in `rpce-contribution-check`: a shorter description, one comparison-base rule for `push`, `pr-ready`, and `candidate`, a new "Candidate validation" section, and a matching row in the validation matrix.

It also recorded one change outside the skills: `CONTRIBUTING.md` step 7, where MP's approval of an upper stack layer covers rebasing it onto its rebased lower layer. The approved wording landed in the files linked above, so this draft is reduced to a summary.
