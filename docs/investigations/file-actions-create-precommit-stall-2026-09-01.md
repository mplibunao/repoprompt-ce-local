# Protected `file_actions create` pre-commit stall

> Investigation report, observed 2026-09-01 on a clean debug package of upstream `5bc82b7f`. It records what was true then. Where it disagrees with a current document, the current document is right.

This file was the filing packet for upstream issue 921, "Protected `file_actions create` can stall before commit past its freshness bound". The issue was filed with the packet's body, so this file is reduced to a summary.

The finding: in a multi-root workspace with an MCP client bound to a RepoPrompt-managed worktree, a protected `file_actions create` of a new plan file ran past the 30-second MCP deadline, didn't settle during the 5-second cleanup grace, and was detached by the watchdog after 35.25 seconds with `tool_execution_timeout`. No file appeared at the logical or the physical worktree path, and the worktree stayed clean. It reproduced four times: three on the local stability package, then once on a clean current-upstream package with a fresh client and a fresh Agent session, which ruled out the retained patches, stale client identity, path projection, and shared build load.

Binding and root inspection completed in milliseconds, so the stall sat before durable commit, in mutation preparation. The packet compared it with the ingress-starvation class of upstream issue 390 (fixed by upstream PR 520) and with upstream PR 688, without identifying the blocking substage. It separated the issue from upstream issue 918, where Context Builder loses its response later, and named upstream issues 910 and 494 as possible amplifiers.
