# Proposed `rpce-merge-pr-batch` skill text (draft)

> Investigation report, observed 2026-10-16. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [.agents/skills/rpce-merge-pr-batch/SKILL.md](../../.agents/skills/rpce-merge-pr-batch/SKILL.md), the whole skill.

This file held the full proposed rewrite of the `rpce-merge-pr-batch` skill, drafted for MP's approval under `AGENTS.md`, "Changes to skills and workflow prompts". The rewrite replaced landing approved pull requests one at a time with landing an ordered set through one release candidate:

1. Inspect each pull request: base, head repository, draft state, resolved review threads, and MP's approval of the current head.
2. Cut `release/<version>-rc<N>` from `origin/main` and merge each approved head with `--no-ff`, in MP's order.
3. Push the candidate and wait for its hosted CI runs.
4. Run the `candidate` preflight lane and the checks it prints.
5. Retarget any upper stack layer onto `main`, then fast-forward `main` to the validated tip.
6. On failure, bisect the candidate's merges with the failing check's own command.
7. Delete the landed head branches and keep the candidate branch until promotion.

The approved version landed as the skill linked above, so this draft is reduced to a summary.
