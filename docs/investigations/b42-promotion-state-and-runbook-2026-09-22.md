# Build 42 promotion — verified state and runbook

> Investigation report, observed 2026-09-22 on local build 42 (`main` at `0c6bb1d3`). It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Promotion procedure.

Verified on disk 2026-09-22 ~07:05 UTC.

Supersedes the state that [codex-handoff-opencode-effort-b42-release.md](codex-handoff-opencode-effort-b42-release.md)
records at the end of its session, where the build-42 artifact job was still running. It failed.
That file remains the record of the Codex session's work.

## Verified state

- `origin/main` = `0c6bb1d307f9bf4ce880313e72961a50c92c22c4`; local `main` matches.
- Tracked tree clean. Untracked `docs/investigations/` files only, which provenance records
  as `dirty: false`, `untracked_files: true`. `docs/releasing.md` permits that.
- `version.env`: `MARKETING_VERSION=1.4.0`, `BUILD_NUMBER=42`.
- Installed production: `/Applications/RepoPrompt CE.app` version 1.4.0 **build 41**,
  provenance commit `e24df046`, `dirty: false`, `git_status: ok`. Untouched.
- Promotion tags present through `local/v1.4.0-b41`. `local/v1.4.0-b42` does not exist.
- No `~/Archives/repoprompt-ce/local/v1.4.0-b41` archive yet.

### Promotion preconditions (`docs/releasing.md`)

| Precondition | Status |
| --- | --- |
| Rollback restore rehearsed on this machine | Met. `~/Archives/repoprompt-ce/local/v1.4.0-b39.rescue-<timestamp>` is a real `local_release_restore.sh` run. |
| `main` pushed at the promoted commit, tracked tree clean | Met. |
| `BUILD_NUMBER` bumped | Met, 42. |
| Working-journal schema gate | Clear. Installed b41 `Info.plist` key = 1, candidate = 1, observed journals = `[1]`. No release-note rollback instructions required. |

### Archive target

Archive tag names the build being archived, not the incoming one. The b40 archive manifest
records `app.build = "40"` from `sourcePath /Applications/RepoPrompt CE.app`. Installed is
41, so the archive tag is `local/v1.4.0-b41`.

## What the build-42 artifact evidence actually proves

Two release jobs ran in a detached worktree at `0c6bb1d3`:

- The first job **failed** at 05:18:40 UTC after 50m32s. Cause:
  `codesign --remove-signature` on a temp copy of the x86_64 Codex binary returned
  `internal error in Code Signing subsystem` while normalizing it for verification. A
  transient macOS code-signing fault, not a source defect.
- The retry completed in 20m14s with
  signature, architecture, and Codex bundle verification passing.

That completed artifact is **universal (`x86_64 arm64`) and explicitly ad-hoc signed**: the
log warns `Ad-hoc package created explicitly; do not use this artifact for release`. It
proves build 42 compiles and packages through the release path. It is not installable.

The installed app is built by a different lane. `Scripts/package_app.sh` sets
`PUBLIC_UNIVERSAL_RELEASE=1` only when release packaging is *not* local-self-signed
(lines 239-242), so `install_local_production.sh` produces a **host-native arm64** build.
Installed build 41 is `arm64` only, confirming this. Two consequences: the install is
materially cheaper than the universal runs, and the x86_64 Codex normalization step that
broke the first job is not on the install path at all.

## Open defects found while verifying (file as issues)

### 1. Production app replacement guard cannot fire

`Scripts/install_local_production.sh:301` guards replacement with:

```sh
pgrep -f "$LOCAL_PRODUCTION_APP/Contents/MacOS/$APP_NAME"
```

On this machine that returns no match while the app is running, so the guard never fires and
the script proceeds to `mv` the live app. Verified: the app runs as PID with argv exactly
`/Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt`, `ps` lists it, and
`pgrep -f` with that exact string returns nothing. Prefix probes match only the bundled
Codex helper process, which shares the `/Applications/RepoPrompt CE.app/Contents/` prefix;
the app process is invisible to `pgrep -f` at every pattern length. `pgrep -x RepoPrompt`
also returns nothing.

Impact: the documented safety net against replacing a running install is absent. Prefer an
identity check that does not depend on `pgrep` argv matching, for example matching the
running executable path through `ps -ax -o pid,comm,command` or resolving the bundle's
executable inode.

### 2. Segfault in codemap graph-index cancellation

`~/Library/Logs/DiagnosticReports/RepoPrompt-<timestamp>.ips`, build 41:
`EXC_BAD_ACCESS (SIGSEGV)`, `KERN_INVALID_ADDRESS at 0x18`. Faulting thread:

```text
WorkspaceCodemapBindingEngine.runGraphIndex(jobID:workerID:rootEpoch:)
  -> $defer #1
  -> finishGraphIndexWorker(jobID:workerID:rootEpoch:reason:)
  -> cancelGraphIndexAdmission(jobID:)
  -> CheckedContinuation.resume(returning:)
  -> _StringGuts.append(_:) / _StringObject.getSharedUTF8Start()
```

Crashing inside `CheckedContinuation.resume(returning:)` while appending a String points at
a continuation resumed more than once, or a String read after its backing storage is gone,
on the graph-index worker cancellation path. Reproduced twice, on 2026-09-19 and 2026-09-22, under heavy
worktree churn, which repeatedly changes root epochs and cancels graph-index workers.

`git diff e24df046 0c6bb1d3 -- '*WorkspaceCodemapBinding*'` is empty, so **build 42 does not
change this code and will not fix these crashes.**

## Incident: unattended install cancelled

A conductor job (run by the main checkout's
daemon) started `Scripts/install_local_production.sh` at 07:00:18 UTC while MP was away. It was
cancelled at 3m02s during `[42/49] RepoPromptApp`, before any packaging or replacement step.

It had to be stopped because it would have replaced production with **no archive**: the
installer backs the old app up to a temporary directory and `rm -rf`s it on success
(lines 319-352). It never archives Application Support, the defaults domain, or the signing
identity record, so completing it would have destroyed the build-41 rollback unit. The guard
in defect 1 would not have stopped it either, and `docs/releasing.md` plus the
`rpce-release` skill both require MP present.

Cancelling preserved the compile progress in `.build`, so the next install resumes
incrementally rather than rebuilding from the Sep 19 state.

## Runbook

The runbook followed the promotion procedure in `docs/releasing.md`, run from a terminal outside
the app because quitting production ends any Agent Mode session it hosts:

1. Quit production and the debug app, then archive build 41 with
   `./Scripts/local_release_archive.sh local/v1.4.0-b41`, and confirm its manifest reports build
   41 and working-journal schema version 1. A higher version blocks promotion.
2. Install build 42 with `CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production`,
   reusing the existing signing identity. A rotation prompt or a different certificate
   fingerprint means stop.
3. Launch and check that the installed provenance names `0c6bb1d3` with `dirty: false`,
   `git_status: ok`, and `CFBundleVersion` 42.
4. Run the acceptance matrix once from Claude Code and once from Codex, exercising the new effort
   controls through OpenCode with DeepSeek over the direct API rather than the unstable `go` or
   `zen` routes, with the quit-and-relaunch arm last.
5. Tag `local/v1.4.0-b42`, push the tag, and publish the GitHub Release receipt with the
   promoted commit, build number, acceptance results, and archive path.

It stopped on a missing archive manifest or one with a working-journal version above 1, wrong
provenance, a changed signing fingerprint, or a failed acceptance arm, and restored with
`./Scripts/local_release_restore.sh local/v1.4.0-b41` on a failure after replacement.

## Upstream status of the defects

Verified 2026-09-22 against the reference clone
`<upstream clone>`, fetched to upstream `main`
`4232fc4b`. Upstream references are written as plain text deliberately; linking them from
this repository posts "mentioned this" events on the upstream items.

### Defect 1, installer guard — present upstream, unreported

`Scripts/install_local_production.sh` carries the identical guard upstream at line 304
(ours is line 301):

```sh
pgrep -f "$LOCAL_PRODUCTION_APP/Contents/MacOS/$APP_NAME"
```

No upstream issue or pull request covers it. Searched `pgrep`,
`install_local_production`, `installer`, `local production`, and `replace`. The closest
upstream item is issue 102, closed, about the local production installer reusing a stale
conductor daemon, which is a different failure. The distribution tracker has nothing either;
#20, closed, only made the script source `local_release_env.sh`.

This is a genuine upstream bug, not a distribution-local one.

### Defect 2, codemap crash — no upstream fix, closely related open issue

`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceCodemapBindingEngine.swift` is
byte-identical to upstream `main` (9761 lines both sides), so no upstream fix is missing from
the distribution.

No upstream issue reports this production crash. Upstream issue 350, open since 2026-07-02
and labelled `bug`/`area:codemap`, covers the same engine and the same admission and
cancellation machinery: "shared-adoption race after waiter cancellation ... + fatal crash in
projection preload test". Its evidence is test flakes under load; this crash is production
evidence with a faulting stack, which that issue explicitly lacks.

Upstream issue 1039, opened 2026-09-22, is a different subsystem: a `swift_task_dealloc`
fatal in MCP teardown through `ServerNetworkManager.withConnectionID`. Both are Swift
concurrency lifecycle faults, but the paths do not overlap.

### Mechanism is not yet established

`WorkspaceCodemapBindingEngine` is an `actor` (line 91), and every cancellation site filters,
removes, and resumes in one synchronous actor-isolated block, so a waiter cannot be resumed
by two cancellation paths. That makes a plain double resume between
`cancelGraphIndexAdmission` (line 2551) and the job-revocation site (line 5331) structurally
unreachable, and it weakens the first reading of the stack.

`_StringGuts.append` appearing inside `CheckedContinuation.resume(returning:)` is consistent
with the Swift runtime building its "CONTINUATION MISUSE ... resumed more than once" fatal
message, but release-build symbolication can also misattribute inlined frames. Discriminating
the two requires a symbolicated or debug reproduction under worktree churn. An issue should
ask for that rather than assert a cause.

### Additional finding: admission waiters abandoned on shutdown

The shutdown path at line 1614 clears the queue without resuming its waiters:

```swift
graphIndexAdmissionQueue.removeAll()
```

Every other site that removes waiters resumes their continuations first (lines 2484, 2526,
2557, 5334). A continuation that is never resumed leaves its awaiting caller suspended
forever. If engine shutdown runs per workspace or per window rather than only at process
exit, this hangs live callers; confirm which before deciding severity. The symptom would
resemble upstream issue 910, open, "CodeMap can remain indefinitely indexing after retry or
budget terminal states", though that issue attributes the state to retry and budget terminal
paths rather than shutdown.

## Tracking

Both defects are filed on the distribution tracker: #89 covers the installer's
ineffective running-app guard, and #90 covers the codemap graph-index cancellation
segfault, with the shutdown waiter observation folded in as a robustness note. Neither is
filed upstream: `.agents/skills/rpce-issue-creator/SKILL.md` keeps upstream strictly
read-only for issues and comments, so upstream status is recorded as plain text inside each
distribution issue instead.

## Promotion completed

Build 42 was promoted on 2026-09-22 from commit `0c6bb1d3`, tagged `local/v1.4.0-b42`, and
published as a GitHub Release with the receipt. #91 records that the acceptance matrix in
`docs/releasing.md` specifies `model_id` values the build rejects, which blocked two arms.
The Codex client arm and the two-window selector-isolation arm were not run; the receipt
states why. The quit-and-relaunch arm remains outstanding as a post-promotion sanity check.
