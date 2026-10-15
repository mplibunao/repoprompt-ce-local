# Developer Daemon

`conductor` is RepoPrompt CE's developer daemon: repository-internal tooling that runs builds, tests, packaging, style checks, and debug-app launches for this checkout. The `make dev-*` targets are aliases for its commands, and the daemon starts on first use. `./conductor --help` lists every command and flag.

Build, run, and validate through the daemon rather than a bare `swift build` or `swift test`. Agents in other checkouts and worktrees share the machine and the debug app, and the daemon keeps them from building, launching, testing, or running style tools over each other and corrupting `.build` or the live app.

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
make dev-smoke-launch                               # ./conductor smoke --launch: builds and launches the debug app, then runs the smoke
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

[`docs/testing.md`](../testing.md#debug-cli-and-live-mcp-smoke) covers installing the debug CLI, through the daemon or directly, and the live MCP smoke.

## Coordination

### Lanes

Jobs claim named lanes: `build`, `debugArtifact`, `liveApp`, `release`, and `style`. The daemon runs jobs that share a lane one at a time and lets jobs on unrelated lanes run concurrently.

The `format` job also claims `build`, because it rewrites files the compiler reads. The `format-check` and `lint` jobs claim only `style`. The `format-tools-status` and `codex-schema-check` jobs claim no lane, so neither queues behind a build.

Lanes coordinate jobs submitted to the daemon. They do not freeze source files against editor changes, direct commands, or edits from another agent. Avoid starting a coordinated build or relaunch while another actor is editing the same checkout. If compilation fails because an input file changed during the build, wait for edits and builds to settle, then retry. For a stable compiler error, fix it and retry. A compile or rebuild failure does not mean a newer stop or relaunch superseded the job.

### Machine-wide heavy slots

Swift- and Xcode-heavy jobs take a per-user heavy slot under `/tmp/repoprompt-ce-dev-locks-<uid>/`, independent of daemon socket overrides, so the limit holds across every checkout and worktree. The default capacity is 1. Set `REPOPROMPT_DEV_HEAVY_SLOTS=N` explicitly to allow more concurrent heavy jobs.

When `job status` or `job wait` shows `global-wait` or "waiting for global heavy slot", another checkout or worktree is already running heavy work. Wait on the ticket. Do not bypass the daemon with direct `swift` or `xcodebuild` commands, and do not start duplicate jobs. Holder metadata is display-only and names the operation, ticket, repository, and worktree when available.

### Live-app lock

Debug app stop, launch, relaunch, and smoke-launch work acquires a separate per-user `live-app.lock`, so worktree-local daemons cannot change the shared debug app concurrently.

### Tickets and async jobs

Every job gets a ticket and can run detached with `--async`. Start a build, keep working, and query or wait on it later with `job status` or `job wait` instead of blocking on a long compile. Jobs survive reconnects.

```bash
./conductor build --async --request-key debug-package
./conductor job wait --request-key debug-package
```

`--request-key` is idempotent: a queued or running job with the same key and a matching request is reused instead of enqueuing a duplicate. A different request under an active key fails with a request-key mismatch. `./conductor job list` shows jobs by state, and `job status`, `job wait`, and `job cancel` each accept a ticket or `--request-key`.

## Command output

Synchronous `dev-*` commands and `job wait` print progress highlights, a terminal summary, and the full log path instead of replaying raw build, test, or style output. The daemon keeps full raw logs under its jobs directory; render one with `--full-log`, for example `./conductor build --full-log` or `./conductor job wait --request-key debug-package --full-log`. `--verbose` is separate: it passes `VERBOSE=1` to delegated scripts where supported, so the stored log captures more detail, but it does not replay raw output.

On a failure, read the highlights first, then open the printed log path or rerun or wait with `--full-log` if the summary is not enough.

## Debug app lifecycle

- `make dev-run` (daemon `run`) is the ordinary first-in, first-out coordinated launch. It builds and packages a uniquely named staged app while holding a heavy slot, then releases the slot. Then it takes the live-app lock to stop the running app, activate the staged bundle as the shared `DebugApps/RepoPrompt.app`, open it, and confirm it started. A build or package failure performs no lifecycle action and leaves the live bundle unchanged. Run it only when it is safe to stop the existing debug app instance.
- `./conductor app relaunch` is the overriding interactive relaunch, for a user-directed action that should win over older work. Like `app stop`, it can cancel older active or queued `liveApp` work. It builds and packages before replacing the debug app, so a failure before lifecycle work begins does not stop or reopen an already-running app.
- `make dev-stop-app`, or `./conductor app stop`, is the overriding interactive stop. It cancels older active or queued `liveApp` operations before confirming the app is stopped.
- `./conductor app launch-existing`, or `make dev-launch-existing`, requires the shared debug app bundle to exist already. It reports the bundle's provenance, never waits for a heavy slot, and never falls back to building.
- Do not assume an in-flight `run`, `smoke`, or diagnostics job will complete if another operator issues `app stop` or an interactive `app relaunch`.
- `./conductor smoke --agent-run` is opt-in, for when provider credentials and model access are available.

## Style jobs

Neither `make dev-format-check` nor `make dev-lint` installs missing tools; `make dev-install-format-tools` does. If a `format` job is canceled after it starts, inspect `git diff`, then rerun the format or restore the files.

## Build outputs

`make dev-build` and `make build` package the debug app into the shared bundle at `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app`, which launches run. Commands that package and then launch (`make dev-run`, `make run`, `./conductor app relaunch`, `make dev-smoke-launch`, and the Finder launcher) package into a staging folder beside it and swap the result into place. `.build/debug/RepoPrompt.app` is only a link to the last packaged bundle, and after any of those commands it points at a staging folder that no longer exists. SwiftPM's architecture-specific build output is usually under `.build/arm64-apple-macosx/debug/`. `make clean` removes `.build`.

When packaging fails or hangs, trace the packaging script directly:

```bash
VERBOSE=1 ./Scripts/package_app.sh debug 2>&1 | tee /tmp/repoprompt-build.log
```

`docs/testing.md` describes the debug app's [identity](../testing.md#live-debug-app-identity-and-lifecycle) and its [signing and secure storage](../testing.md#debug-app-signing-and-secure-storage).

## Uncoordinated fallback

The direct commands below claim no lanes and are never superseded by a newer stop or relaunch. When several agents are active, they can build, launch, or run style tools over each other, and a direct launch can reopen the app after a coordinated stop. Use them only when the daemon is unavailable but the tooling they need, including `python3`, still works.

```bash
make build                  # ./Scripts/package_app.sh debug
make run                    # ./Scripts/run.sh; stops the running debug app, like make dev-run
make test                   # swift test
make format
make format-check
make lint
make format-tools-status
make install-format-tools
```

Direct `swift test --filter <name>` and `swift build --product <name>` need no `python3` and produce the same results, but they are uncoordinated. Use them only when the daemon is unavailable, and avoid them when other agents may be building.

The Finder launcher runs `./conductor app relaunch`, so it requires `python3`; it does not provide an uncoordinated no-Python fallback, because safe lifecycle actions require exact debug-executable identity checks. The `rpce-cli-debug` commands of the [manual live flow](../testing.md#debug-cli-and-live-mcp-smoke) remain valid for direct live MCP validation.
