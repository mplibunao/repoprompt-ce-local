# RepoPrompt CE 1.4.0 build 52 promotion

> Investigation report, observed 2026-10-14 on local build 52 (`main` at `fbb55c3a`). It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

Status: complete.

RepoPrompt CE 1.4.0 build 52 is the local self-signed production build from main commit `fbb55c3ae91b26af1802614a1e039efb200b0ad5`.

This build includes root approval-notification and per-window state-subscription fixes from #177, plus the build-number change in #178. The original Claude timeout wasn’t proven to require these fixes: the previous production build connected after saved approval and restart.

Production acceptance passed in real Claude Code and Codex sessions. Both made MCP selection and root queries. Context Builder, Oracle continuation, agent startup and steering, and existing-worktree routing also passed. A fresh client displayed the approval dialog. Allow Once completed initialization and returned 20 tools. Only one window was open after launch. The conditional second-window rows weren’t run.

Normal quit removed all 31 recorded app and child processes, including the waiting test agent and MCP descendants. After relaunch and startup settlement, a fresh Codex session made an MCP root query and completed with RELAUNCH_OK.

Bundle provenance names the promoted main commit with `dirty: false` and `git_status: ok`. Signing identity and registry are unchanged. The archive of build 51 is `~/Archives/repoprompt-ce/local/v1.4.0-b51`. All archive checksums passed. Archived, candidate, and observed working-journal schema versions are 1.

The one-line build-number PR was merged while hosted CI was queued, after local checks and independent review passed. Waiting for that hosted run was explicitly waived. Its root shard 2 later hit the exact intermittent compaction-cancellation assertion tracked in [#171](https://github.com/mplibunao/repoprompt-ce-local/issues/171). The same class passed all 21 tests in a fresh local sandbox on the promoted commit. That issue remains open. The approval-fix PR passed its hosted checks before merge.

This release records a local installation. No app binary is distributed.

## Release and local evidence

The published receipt is https://github.com/mplibunao/repoprompt-ce-local/releases/tag/local/v1.4.0-b52. Remote tag `local/v1.4.0-b52` is annotated and peels to the installed commit. GitHub reports an empty asset list.

PR177 merged as `44806e6fcb0b265dddc61765a07029e43b0d4b93`. PR178 changed only BUILD_NUMBER from 51 to 52 at `735f7b8a80f8bf1a58aab41ecaa7ebd4ae5f7f8d`. It passed local commit/push checks, release preflight, the CLI version check, independent review, and a separate refactor review. The tree of the final `pr-ready` run equals the promoted merge commit.

The build51 archive completed with all four checksum sidecars verified and no unreadable journals. Prior release records document a successful restore rehearsal on this machine. Coordinated installation ticket `<redacted>` completed with exit0. The focused test ticket `<redacted>` passed 21 tests in a fresh profile sandbox. Logs are in the main checkout’s Conductor job directory under Application Support.

Raw acceptance receipts were kept in a temporary folder and not retained. They included client tool transcripts, Context Builder and Oracle results, process snapshots, the approval result, and provenance. The temporary approval script was removed after use. Both worktree probes reported `chore/local-build-52` at `735f7b8a` from the existing metadata checkout. The completed review tab’s original empty selection was restored.

The first agent admission attempt reported a pending workspace save. Retrying after the save settled succeeded. The first bind_context call after relaunch timed out during loading. A later fresh agent made an MCP root query and completed successfully. The lifecycle test session retains a historical running marker with is_live=false, while all 31 recorded processes exited.

The existing port checkout supplied version.env from build51 during the first Context Builder check. Oracle initially treated its logical root path as a mismatch. The supplied content and session binding confirmed the expected older checkout. The second client arm used the metadata checkout and returned build52 with its physical path.

Main passed guardrails, but push preflight rejected its existing local files outside Git tracking. The clean metadata checkout passed push preflight. Tag checks separately verified the exact pushed main commit, the annotated tag object, and the remote peeled target. Existing local files and other worktrees were preserved.

## Claude Desktop resume

Re-enabled RepoPromptCE in the paused session’s connector menu, then restarted Claude Desktop to replace its disconnected MCP process. Developer settings showed RepoPromptCE Running with `~/RepoPrompt/repoprompt_ce_cli`.

Sent exactly `continue` to the paused Claude Desktop session. The message appeared, and the session changed to Running.

## Unresolved work

Issue171 tracks the intermittent hosted assertion. The successful local run doesn’t resolve it. This promotion includes no repair for that issue. The receipt distinguishes the production checks from the earlier debug multi-window evidence.
