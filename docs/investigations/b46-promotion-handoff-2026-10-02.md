# Build 46 promotion handoff (2026-10-02)

> Investigation report, observed 2026-10-02 on `main` at `fe504414`, before build 46 was installed. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

The outer supervisor runs this. The inner orchestrator runs inside production RepoPrompt CE, so it can't stop, archive, or replace production. `docs/releasing.md` ("Promotion procedure", "Rollback unit", "Build provenance", "Acceptance matrix") owns every step. This file lists only the inputs and the facts measured for this promotion.

Authority: MP authorized finishing the work, deploying to production, and proving it stable on 2026-10-02 at 01:14Z. Production is stopped only when no agent session or Context Builder run is active.

## Inputs

| Input | Value |
| --- | --- |
| Commit to promote | `fe504414b2c80d8c145067a12f4d834acd8a9982` (pushed `main` tip after #136; tracked tree clean) |
| Version, build, tag | 1.4.0, build 46, `local/v1.4.0-b46` |
| Archive tag for the installed build | `local/v1.4.0-b45` → `~/Archives/repoprompt-ce/local/v1.4.0-b45/` (does not exist yet) |
| Receipt | GitHub Release `local/v1.4.0-b46` on `mplibunao/repoprompt-ce-local`, notes in the same shape as `local/v1.4.0-b45` |
| Installed now | build 45, commit `40716eb1` (`main`, clean), bundled Codex 0.156.1, PID `23403` |

## Prerequisites (measured 2026-10-02 ~01:25Z)

- **Rollback rehearsal:** met. `~/Archives/repoprompt-ce/local/v1.4.0-b39.rescue-<timestamp>` is the rescue directory left by a real `local_release_restore.sh` run on 2026-09-17.
- **Working-journal schema:** installed b45 `RepoPromptWorkingJournalSchemaVersion` = 1; candidate `DomainWorkingJournal.schemaVersion` = 1 (`Scripts/read_working_journal_schema_version.py`); the 101 live journals are all version 1, with none unreadable. No rollback notes are required. The archive's own `observed_working_journal_versions` is authoritative; if it shows any version above 1, follow step 2 of the promotion procedure.
- **Signing continuity:** exactly one `RepoPrompt CE Local Self-Signed Code Signing` identity in the keychain. The registry, the installed app, and that identity agree on its fingerprint and secure-storage generation. The install should report action `reuse`. Do not set `ROTATE_LOCAL_SIGNING_IDENTITY` or `LOCAL_SIGNING_IDENTITY_SHA256`.
- **Release preflight:** passed for "RepoPrompt CE 1.4.0 (46)".
- **Source evidence carried over:** `main` before #136 (`ccc5ff64`) has the release candidate's tree, which passed the acceptance matrix on the debug app. #136 (merged 02:01:10Z as `fe504414`) changes only `BUILD_NUMBER`. Its CI run `36949724061` passed 8/8 on attempt 2. Attempt 1 failed one timing-bound test in root shard 1 that #136 cannot affect.

## Blocking processes to clear before archiving

`local_release_archive.sh` refuses to run while any process holds RepoPrompt state. Its guard (`python3 Scripts/debug_app_process.py guard release-state --production-executable "/Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt" --app-name RepoPrompt --display-name "RepoPrompt CE" --support-dir "$HOME/Library/Application Support/RepoPrompt CE"`, exit 3 = blocked) listed 47 processes at 01:25Z:

- the production app (`23403`) and the debug app (`74674`);
- 33 `repoprompt-mcp` connectors spawned by Claude Code sessions, which includes the supervising sessions;
- 3 connectors spawned by Codex clients: the ChatGPT app's Codex and a `~/.codex` app-server daemon (0.160.0);
- 9 connectors spawned by `cursor-agent` processes more than a day old.

Clients launch the connector through `~/RepoPrompt/repoprompt_ce_cli` → `/Applications/RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp` (also reached through `/usr/local/bin/rpce-cli`). During the b45 promotion an external Codex client kept respawning its connector, and moving that link aside for the archive, then restoring it, cleared it.

Proposed order: confirm no agent session or Context Builder run is active, quit production, stop the debug app with `./conductor app stop`, end the connector processes the guard lists, rerun the guard until it exits 0, then archive. A session whose connector is ended loses RepoPrompt tools until it reconnects; the shell keeps working.

## Commands and acceptance

The handoff then listed this promotion's commands, run from the main checkout: archive build 45 with `local_release_archive.sh local/v1.4.0-b45`, check the archive manifest's working-journal fields, install with `CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production`, and confirm the installed provenance: commit `fe504414`, `dirty: false`, build 46, bundled Codex 0.159.0, and signing action `reuse`. The install refuses to build while production runs; the build 45 promotion had kept production down for about 16 minutes.

For acceptance it gave the inputs for the `docs/releasing.md` matrix run against production with `CLI=rpce-cli`: two windows, idle tabs whose prompt and selection are snapshotted and restored, a Claude Code arm and a Codex arm, and the quit-and-relaunch check, where a start issued within seconds of launch can be lost to open issue #108. It added runs specific to this build: resuming a Codex thread created on 0.156.1 under the 0.159.0 runtime, GPT-6.1 Sol and Sonnet 5.5 runs with one RepoPrompt tool call each, an exact comparison of settings and role pins against a baseline captured before production stopped, and an empty list of running or waiting acceptance sessions at the end.

After acceptance: tag `local/v1.4.0-b46`, push the tag, and publish the receipt without uploading the app; on a failed acceptance, restore build 45 with `local_release_restore.sh`. [b46-production-promotion-2026-10-02.md](b46-production-promotion-2026-10-02.md) records the outcome.
