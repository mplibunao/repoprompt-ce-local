# Build 42 promotion — verified state and open items (2026-09-22)

> Investigation report, observed 2026-09-22 on local build 42 (`main` at `0c6bb1d3`). It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

This was the first state check before promoting local build 42, made at about 07:00 UTC. The fuller record from a few minutes later, [b42-promotion-state-and-runbook-2026-09-22.md](b42-promotion-state-and-runbook-2026-09-22.md), carries the same facts plus the installer defect, the cancelled unattended install, the upstream status of both defects, and the outcome of the promotion.

It recorded:

- **The promotion preconditions held.** `origin/main` and the local `main` were at `0c6bb1d3` with a clean tracked tree, `BUILD_NUMBER` was 42, and production was build 41 from `e24df046`. A rollback restore had been rehearsed on 2026-09-17, and both the installed and the candidate bundle declared working-journal schema version 1, so no rollback notes were needed. The archive target was `local/v1.4.0-b41`, because the archive names the build being replaced.
- **Corrections to [codex-handoff-opencode-effort-b42-release.md](codex-handoff-opencode-effort-b42-release.md).** The release-artifact job that report described as running had failed after 50 minutes on a transient macOS code-signing error. Its retry produced an ad-hoc signed universal release candidate, which shows release packaging works at `0c6bb1d3` but can't be installed. The local production install builds host-native arm64 instead, and a warm install of build 41 had taken 41 seconds, so the archive dominates the time production is down.
- **An open crash.** Build 41 crashed twice with `EXC_BAD_ACCESS` at `0x18` in `WorkspaceCodemapBindingEngine.cancelGraphIndexAdmission(jobID:)`, reached from `finishGraphIndexWorker(jobID:workerID:rootEpoch:reason:)` through `CheckedContinuation.resume(returning:)`. Build 42 doesn't change that file, so promotion neither fixes nor waits on it.
- **A gap in the acceptance matrix.** The Codex client arm and the `codexExec` steps couldn't run while the Codex quota was exhausted, so the tag needed either a later Codex run or a named deviation in the release receipt.
