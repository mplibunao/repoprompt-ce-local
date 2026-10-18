# Handoff — screenshot the upstream issue 665 hook-approval UI changes

> Investigation report, observed 2026-07-29. It records what was true then. Where it disagrees with a current document, the current document is right.

This file was a handoff prompt for a Codex Desktop agent, so it is reduced to a summary. It asked the agent to capture before-and-after screenshots of the Codex hook-approval UI from branch `feature/665-hook-approval-flow` (upstream issue 665), with the debug app running the branch build:

- Settings → Agent Mode on the Tip build before the relaunch, and again on the branch build with the new "Codex hook approval strict mode" card;
- the hook review card shown before the first turn of a session on a repository with an untrusted `.codex` PreToolUse hook, with its strict-mode variant, where "Continue without hooks" is absent;
- the separate layout for a hook discovery failure.

It required a scratch repository with a harmless hook and no Approve or Trust click on any real repository.
