# Build 46 production acceptance record

> Investigation report, observed 2026-10-02 on local build 46 (`main` at `fe504414`). It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

Status: Complete. RepoPrompt CE 1.4.0 build 46 is installed, accepted and running with bundled Codex 0.159.0. The annotated build tag and GitHub Release receipt are published.

The owning procedure is [docs/releasing.md](../releasing.md). Prepared source validation and rollback prerequisites are in [the promotion handoff](b46-promotion-handoff-2026-10-02.md).

## Installed artifact

- Installed commit: `fe504414b2c80d8c145067a12f4d834acd8a9982`, branch `main`, `dirty: false`, `git_status: ok`.
- Provenance build time: 2026-10-02 02:27:05 UTC. Install completed 02:27:12 UTC; production availability was confirmed by 02:31 UTC.
- Signing identity reused, with an unchanged secure-storage generation; journal schema 1. Installer signature and bundled-runtime integrity checks passed.
- Rollback archive: `~/Archives/repoprompt-ce/local/v1.4.0-b45`; complete app, preferences, signing record and Application Support snapshot. Manifest supported/observed journal schema 1, no unreadable journals.
- Docs PR #135 merged as `6ac4685a1927b40f620f6a7f9fc0292dfcb2d4c1`. Its only changed files are `AGENTS.md`, `CONTRIBUTING.md`, and `docs/porting.md`; installed app source equals the new integration source. Installed provenance remains the actual build commit above.

## Production acceptance

| Check | Result |
| --- | --- |
| Codex client MCP call and terminal marker | Passed; Luna Low, `CODEX_OK` |
| Claude client MCP call and existing-session steering | Passed; Haiku Low, `CLAUDE_STEER_OK` |
| GPT-6.1 Sol model execution and MCP call | Passed; `SOL61_PRODUCTION_OK` |
| Sonnet 5.5 execution and MCP call | Passed; `SONNET55_PRODUCTION_OK` |
| Pre-upgrade Codex thread resumed on the new runtime | Passed; `OLD_CODEX_THREAD_RESUME_OK` |
| Existing linked worktree routing | Passed; an existing linked worktree on the release-candidate branch |
| Context Builder selection/root | Passed; selected distribution `README.md` and exact absolute distribution root |
| Oracle terminal response and chat reuse | Passed; `ORACLE_OK`, `ORACLE_REUSE_OK`, existing chat reused |
| Same-window tab selector isolation | Passed; primary `README.md`, secondary `CONTRIBUTING.md` |
| Two-window matrix rows | Not run; only one production window currently open |
| Saved model and Agent Mode preferences | Exact baseline retained |
| Effective role model pins | Retained; recommendation metadata updated to GPT-6.1 as intended |
| Owned acceptance runs at handoff | All six completed; running and waiting session lists empty |
| Same-build production quit/relaunch and descendant cleanup | Passed; all recorded production/provider/MCP processes exited, same bundle reopened, fresh client MCP call returned `POST_RELAUNCH_OK` |

Client-side MCP calls were inspected in bounded acceptance logs. Fresh agent sessions had empty selections; their routing checks establish client tool operation rather than selection inheritance. Tests used new background tabs in the distribution workspace with `focus=false`. Private work-workspace contents were not accessed.

The structured result, the bounded test receipts, and the source-equivalence check were kept in temporary files and not retained.

## Merge and deployment timing

All times below are UTC, on 2026-10-02 except the first row, which is 2026-10-01.

| Event | Time |
| --- | --- |
| PR #131 merged | 23:59:42 |
| PR #132 merged | 00:46:30 |
| PR #133 merged | 01:11:14 |
| PR #136 build metadata merged | 02:01:10 |
| Old production observed stopped by | 02:07:52 |
| Debug stop ticket started | 02:08:02 |
| Rollback archive | Approximately 02:09–02:16 |
| Production installer started | 02:17:28 |
| Docs PR #135 merged | 02:27:10 |
| Production installer completed | 02:27:12 |
| Production confirmed available | By 02:31 |
| Final PR #135 CI job passed | 02:29:24 |

The install job took 583.4 seconds.

PR #136 CI run `36949724061`, attempt 2: all eight checks passed after one retry of the pre-existing ABA selection recovery timing test. PR #135 CI run `36953776559`: all eight checks passed. No repeated app build was run for the docs-only integration change.

## Release closure

The approved idle-window lifecycle check completed on 2026-10-02. Production quit was verified at 03:10:06 UTC: every previously recorded app, bundled Codex, code-mode host and MCP PID had exited. The same installed build relaunched, and a fresh Codex client made a RepoPrompt MCP call and returned `POST_RELAUNCH_OK`. Production is running; no active acceptance sessions remain.

Annotated tag `local/v1.4.0-b46` targets installed commit `fe504414b2c80d8c145067a12f4d834acd8a9982` and was pushed to the distribution. [The GitHub Release receipt](https://github.com/mplibunao/repoprompt-ce-local/releases/tag/local/v1.4.0-b46) was published at 03:14:24 UTC, with no app assets uploaded. Push preflight passed in the existing clean release-validation worktree; the main checkout's unrelated local investigation files were preserved.

No remaining task or blocker exists for this selected port and release. Debug/production process-separation work is a separately queued topic.
