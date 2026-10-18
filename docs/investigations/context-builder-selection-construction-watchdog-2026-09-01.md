# Context Builder nested selection-construction watchdog

> Investigation report, observed 2026-09-01 on the RepoPrompt CE debug app with `rpce-cli-debug` 1.3.0. It records what was true then. Where it disagrees with a current document, the current document is right.

This file was the filing packet for upstream issue 918, "Context Builder loses its result when nested selection construction exceeds the MCP watchdog". The issue was filed with the packet's body, so this file is reduced to a summary.

The finding: in a multi-root workspace with a worktree-bound Agent session, a Context Builder plan or review finished discovery, and then the child's nested `manage_selection` request stayed in the `manage_selection.selection_construction` phase for about 35.09 seconds, past the 30-second execution deadline and 5-second cleanup grace. The watchdog detached the child, final-context commit was refused, and the caller got `Context Builder response delivery did not finish` with no response or export. This happened on three attempts in one campaign.

The phase wraps three awaited operations in `MCPSelectionToolProvider.executeManageSelectionAttempt`: `stabilizedVirtualSelection`, `freezePromptGitReviewContext`, and `resolveManageSelectionArtifactInputs`. The trace didn't say which one stalled; the Git-checkout freeze path, which serially awaits root and Git-layout probes, was the leading static candidate. The packet separated the issue from upstream issues 170, 881, 444, 562, 526, and 887.
