# Build 47 promotion handoff (approved stack #147, #149, #152)

> Investigation report, observed 2026-10-03 to 2026-10-04 on build 47 (`main` at `89b10bac`). It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

This file was the working handoff between the session that merged build 47's pull requests and the session that ran the production lifecycle, with a status log appended as the promotion went. It held session handles, temporary receipt paths, signing identifiers, and the state of an unrelated task that shared production, so it is reduced to a summary of what it recorded.

## What merged

MP approved #147, #149, and #152 for build 47 and kept #148, #151, and #153 out. An approved-only candidate (`main` plus merges of the three approved heads) passed `pr-ready` (its first run failed only the #74 timing flake) and a debug-app run, with the Oracle and Context Builder rows run on an earlier candidate whose stack source files were byte-identical. On GitHub:

- The stack merge of #147 and #149 produced one merge commit, `1685da11`, whose tree equals #149's head.
- The three-pull-request stack merge refused atomically, because #152's branch had been cut from an earlier #149 commit. After #147 and #149 merged, GitHub retargeted #152 to `main` and rebased it, keeping the patch and the candidate's tree. It merged as `356dcb89`.
- #154 bumped `BUILD_NUMBER` from 46 to 47 and merged as `89b10bac`, the commit to promote. `git diff` against the validated candidate showed only that line.

The main checkout's developer daemon had been running the pre-merge `Scripts/conductor.py` since 2 October. The batch changed that file without changing its protocol version, so nothing would have restarted the daemon; it was stopped by hand before the install.

## First install: restored to build 46

The first install of `89b10bac` reused the signing identity, but the first launch stopped on a macOS Keychain item-access prompt for the app's own secure-storage item and never became ready. Production was restored to build 46 with its windows and context IDs intact, and the build 47 bundle and pre-restore profile were kept in a rescue archive. Build 47 was not accepted, tagged, or published.

## Retry: accepted, pending tag and receipt

After MP returned, a fresh archive of build 46 was taken under a separate archive root (`LOCAL_RELEASE_ARCHIVE_ROOT`), because the first attempt's `local/v1.4.0-b46` archive was stale. The original build 47 bundle was installed from the rescue copy without a rebuild. MP answered the Keychain prompts at the keyboard. Every client row of the acceptance matrix passed with settings identical to the baseline, and the final quit-and-relaunch passed, with a new run making a RepoPrompt tool call afterwards.

When the file ends, build 47 was accepted on the machine. Tagging `local/v1.4.0-b47` and publishing the receipt were waiting for MP's approval, and the rollback unit was the new archive root's `local/v1.4.0-b46`. [local-production-keychain-prompt-per-build-2026-10-15.md](local-production-keychain-prompt-per-build-2026-10-15.md) covers the Keychain prompt.
