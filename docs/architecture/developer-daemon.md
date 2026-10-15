# Developer Daemon

`conductor` is RepoPrompt CE's developer daemon: repository-internal tooling that runs builds, tests, packaging, style checks, and debug-app launches for this checkout. The `make dev-*` targets are aliases for its commands, and the daemon starts on first use. `./conductor --help` lists every command and flag. This document covers how the daemon coordinates work and when to use each path.

Build, run, and validate through the daemon rather than a bare `swift build` or `swift test`. Agents in other checkouts and worktrees share the machine and the debug app, and the daemon keeps them from building, launching, or testing over each other.

## Coordination

### Lanes

Every job claims named lanes: `build`, `debugArtifact`, `liveApp`, `release`, and `style`. The daemon runs jobs that share a lane one at a time and lets jobs on unrelated lanes run concurrently. That serial queue stops agents from building, launching, or running style tools over each other and corrupting `.build` or the live app.

The style jobs claim lanes by what they change:

- The mutating `format` job also claims `build`, because it rewrites files the compiler reads.
- The non-mutating `format-check` and `lint` jobs use only `style`.
- The read-only `format-tools-status` job is unlaned, so it never queues behind a build. `codex-schema-check` is unlaned as well.

Lanes coordinate jobs submitted to the daemon. They do not freeze source files against editor changes, direct commands, or edits from another agent. Avoid starting a coordinated build or relaunch while another actor is editing the same checkout. If compilation fails because an input file changed during the build, wait for edits and builds to settle, then retry. For a stable compiler error, fix it and retry. A compile or rebuild failure does not mean a newer stop or relaunch superseded the job.

### Machine-wide heavy slots

Swift- and Xcode-heavy jobs acquire per-user global heavy admission under `/tmp/repoprompt-ce-dev-locks-<uid>/`, independent of daemon socket overrides, so the limit holds across every checkout and worktree. The default capacity is 1. Set `REPOPROMPT_DEV_HEAVY_SLOTS=N` explicitly to allow more concurrent heavy jobs.

When `job status` or `job wait` shows `global-wait` or "waiting for global heavy slot", another checkout or worktree is already running heavy work. Wait on the ticket. Do not bypass the daemon with direct `swift` or `xcodebuild` commands, and do not start duplicate jobs. Holder metadata is display-only and names the operation, ticket, repository, and worktree when available.

### Live-app lock

Debug app stop, launch, relaunch, and smoke-launch work acquires a separate per-user `live-app.lock`, so worktree-local daemons cannot change the single shared debug app at the same time.

### Tickets and async jobs

Every job gets a ticket and can run detached with `--async`. Start a build, keep working, and query or wait on it later with `job status` or `job wait` instead of blocking on a long compile. Jobs survive reconnects.

```bash
./conductor build --async --request-key debug-package
./conductor job wait --request-key debug-package
```

`--request-key` is idempotent: a queued or running job with the same key is reused instead of enqueuing a duplicate. `./conductor job list`, `job status`, `job wait`, and `job cancel` each accept a ticket or `--request-key`.

### Output

Synchronous `dev-*` commands and `job wait` print progress highlights, a terminal summary, and the full log path instead of replaying raw build, test, or style output. The daemon keeps full raw logs under its jobs directory; render one with `--full-log`, for example `./conductor build --full-log` or `./conductor job wait --request-key debug-package --full-log`. `--verbose` is separate: it passes `VERBOSE=1` to delegated scripts where supported, so the stored log captures more detail, but it does not replay raw output.

On a failure, read the highlights first, then open the printed log path or rerun or wait with `--full-log` if the summary is not enough.

## Commands

```bash
make doctor                                         # Swift/Xcode setup, SDK, signing diagnostics, SwiftUI probe, debug CLI status
make dev-status
make dev-build                                      # coordinated debug package
make dev-swift-build PRODUCT=repoprompt-mcp         # focused product build (PRODUCT=RepoPrompt|repoprompt-mcp|all, default all)
make dev-run                                        # build, package, stop the existing debug app, launch the new build
make dev-launch-existing                            # launch the current DebugApps bundle without building
make dev-test                                       # full coordinated test suite
make dev-test FILTER=WorkspaceFileContextStoreTests # focused coordinated test run
make dev-provider-test                              # RepoPromptAgentProviders package tests (FILTER= also supported)
make dev-smoke                                      # non-disruptive: requires a running CE debug app and installed debug CLI
make dev-smoke-launch                               # builds and launches the debug app, then runs the smoke flow
make dev-format-check                               # non-mutating SwiftFormat check
make dev-lint                                       # non-mutating format-check, then SwiftLint strict
make dev-format                                     # mutates first-party Swift files; run only when intended
make dev-format-tools-status
make dev-check-format-tools
make dev-install-format-tools
make dev-codex-schema-check                         # bounded Codex app-server schema drift check
make dev-stop-app                                   # ./conductor app stop
make dev-daemon-stop                                # stops the daemon itself
make guardrails
```

`./conductor install-debug-cli` and `./conductor debug-cli-status` run the debug CLI installer through the daemon. [`docs/testing.md`](../testing.md#debug-cli-and-live-mcp-smoke) covers the debug CLI and the live smoke flow.

## Debug app lifecycle

- `make dev-run` (daemon `run`) is the ordinary first-in, first-out coordinated launch. It builds and packages a uniquely named staged app under heavy admission and releases that heavy slot. Then it takes the live-app lock to stop the running app, activate the staged bundle as the shared `DebugApps/RepoPrompt.app`, open it, and confirm it started. A build or package failure performs no lifecycle action and leaves the live bundle unchanged. Run it only when it is safe to stop the existing debug app instance.
- `./conductor app relaunch` is the overriding interactive relaunch, for a user-directed action that should win over older work. The Finder launcher uses it when `python3` is available. Like `app stop`, it can cancel older active or queued `liveApp` work. It builds and packages before replacing the debug app, so a failure before lifecycle work begins does not stop or reopen an already-running app.
- `make dev-stop-app`, or `./conductor app stop`, is the overriding interactive stop. It cancels older active or queued `liveApp` operations before confirming the app is stopped.
- `./conductor app launch-existing`, or `make dev-launch-existing`, requires the shared debug app bundle to exist already. It reports the bundle's provenance, never waits for heavy admission, and never falls back to building.
- Do not assume an in-flight `run`, `smoke`, or diagnostics job will complete if another operator issues `app stop` or an interactive `app relaunch`.
- `make dev-smoke` is the non-disruptive live-only check. It assumes the CE debug app is already running and the debug CLI is installed and resolvable.
- `make dev-smoke-launch`, or `./conductor smoke --launch`, builds, packages, and launches the debug app before the smoke validation.
- `./conductor smoke --agent-run` is opt-in, for when provider credentials and model access are available.

## Style jobs

`make dev-format-check` and `make dev-lint` are non-mutating, and neither installs missing tools; `make dev-install-format-tools` is the explicit install path. `make dev-lint` runs `format-check` followed by `swiftlint lint --strict`.

`make dev-format` rewrites first-party Swift files. Run it only when formatting mutation is intended. If a format job is canceled after it starts, inspect `git diff`, then rerun the format or restore the files.

## Build outputs

A debug package is created at `.build/debug/RepoPrompt.app`, and launches run the shared bundle at `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app`. SwiftPM's architecture-specific build output is usually under `.build/arm64-apple-macosx/debug/`. `make clean` removes `.build`.

When packaging fails or hangs, trace the packaging script directly:

```bash
VERBOSE=1 ./Scripts/package_app.sh debug 2>&1 | tee /tmp/repoprompt-build.log
```

`docs/testing.md` describes the debug app's [identity](../testing.md#live-debug-app-identity-and-lifecycle) and its [signing and secure storage](../testing.md#debug-app-signing-and-secure-storage).

## Uncoordinated fallback

The direct commands below claim no lanes and are never superseded by a newer stop or relaunch. When several agents are active, they can build, launch, or run style tools over each other, and a direct launch can reopen the app after a coordinated stop. Use them only when the daemon is unavailable but its required tooling, including `python3`, still works, and prefer the `dev-*` aliases whenever the daemon is available.

```bash
make build                  # ./Scripts/package_app.sh debug
make run                    # ./Scripts/run.sh
make test                   # swift test
make format
make format-check
make lint
make format-tools-status
make install-format-tools
```

Direct `swift test --filter <name>` and `swift build --product <name>` produce the same results without `python3`. Use them only when the daemon is unavailable, for example without `python3`, and avoid them when other agents may be building.

The Finder launcher requires `python3` and does not provide an uncoordinated no-Python fallback, because safe lifecycle actions require exact debug-executable identity checks. Manual `rpce-cli-debug` commands remain valid for direct live MCP validation.
