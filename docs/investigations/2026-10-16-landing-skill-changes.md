# Landing skill changes for approval

> Investigation report, observed 2026-10-16. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [.agents/skills/rpce-merge-pr-batch/SKILL.md](../../.agents/skills/rpce-merge-pr-batch/SKILL.md), the whole skill; [.agents/skills/rpce-contribution-check/SKILL.md](../../.agents/skills/rpce-contribution-check/SKILL.md), Candidate validation.

This file was a plain-language table of the release-candidate landing change for MP's review: one row per change to `rpce-merge-pr-batch` and `rpce-contribution-check`, saying what an agent would do differently once it landed. [2026-10-16-landing-skill-wording-for-approval.md](2026-10-16-landing-skill-wording-for-approval.md) held the exact wording.

It flagged two losses:

- The steps for pull requests from outside contributors were removed: the agent no longer strips credentials or switches to trusted tooling when a pull request edits the preflight scripts. Only MP's approved heads from this repository can land, so a hostile pull request from a fork is no longer a case the skill handles.
- The `rpce-contribution-check` description was cut from 579 to 215 characters, dropping the trigger phrases "secret scanning", "remote allowlist", and "production-app operations".

The approved changes landed in the files linked above, so this table is reduced to a summary.
