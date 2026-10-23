# Testing RepoPrompt CE

Use this guide for contributor-facing XCTest changes and live debug-app validation. Follow [`architecture/developer-daemon.md`](architecture/developer-daemon.md) for coordinated daemon use and style checks, and [`AGENTS.md`](../AGENTS.md#commit-preflight) for which app actions need approval. Use `$rpce-test-quality` when deciding whether coverage is worth adding, retaining, consolidating, or removing.

## Quality gate before adding a test

Add a test only when all four answers are concrete:

1. **Contract:** What current behavior must remain true?
2. **Plausible defect:** What realistic regression would violate it, and what is the impact?
3. **Lowest faithful layer:** Can deterministic core or provider-package coverage reproduce the risk, or is root SwiftPM integration actually required?
4. **Observable oracle:** What exact output, state, error, side effect, cleanup, wire format, or bounded performance result distinguishes broken from correct behavior?

Search existing direct and outcome-level coverage first. Prefer a test that fails against known-bad behavior. Do not add invocation-only, no-crash, non-nil-only, source-shape, symbol-presence, constant-restatement, arbitrary-sleep, or coverage-driven tests unless that fact is itself the contract and no stronger oracle exists.

## Choose the lowest faithful layer

- **Isolated core:** deterministic decisions, transformations, parsers, state machines, policy, invariants, and failure semantics.
- **Provider package:** provider protocol, codec, translation, launch arguments, and model mapping under `Packages/RepoPromptAgentProviders/Tests`.
- **Root SwiftPM:** module behavior without a GUI, including actors, persistence, fixtures, subprocess adapters, in-process MCP, and deterministic concurrency under `Tests/RepoPromptTests`.
- **Runtime diagnostics:** assembled-app-only rendering, restoration, routing instrumentation, churn, or resource investigations. Require a bounded scenario, privacy-safe machine-readable evidence, entry point, and cleanup path.
- **Live/packaged smoke:** real app/MCP wiring, bundle layout, embedded helpers, ownership, signing, provenance, and a few critical journeys.
- **Structural guard:** last resort when executable behavior, compiler boundaries, lint, or guardrails cannot cheaply enforce a narrow constraint.

Do not use smoke as the only protection for deterministic logic. Without a predeclared acceptance threshold, a benchmark is diagnostics rather than executable contract coverage.

## Add and run root or provider XCTest coverage

- **Root target:** place app-integrated and root-package tests under `Tests/RepoPromptTests` and validate with `make dev-test`.
- **Provider target:** place provider protocol, codec, translation, launch-argument, or model-mapping tests under `Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests` and validate with `make dev-provider-test`.
- Keep one coherent contract per method. Labeled tables are appropriate when cases differ only by input, boundary, or expected outcome.
- Control time, randomness, locale, environment, resources, ordering, and concurrency. Prefer gates, clocks, or continuations over sleeps, and verify meaningful cleanup or ownership.

Each root or provider test job gets a fresh conductor profile sandbox beside its job log, with the path shown in the summary until job retention removes the directory. Export a non-empty `REPOPROMPT_TEST_SANDBOX_ROOT` before invoking conductor to use a caller-owned sandbox instead. Inside the sandbox, a test's profile takes its build flavor's name, `profile/RepoPrompt CE Debug` for the debug test build. Its runtime temporary files sit in that profile's `Temporary` folder, so no test resolves a developer's real debug or production profile.

A conductor test job runs `Scripts/ci_app_test_runner.py --local`. It builds with `swift build --build-tests`, lists the package test bundle (with Swift Build, the bundle of each declared test target), and runs the selected tests with `xctest` directly. On that path only the listing and `xctest` get the sandbox: SwiftPM keys its manifest cache on the whole environment, so a per-job value would make every job re-evaluate the package manifests. The runner uses `swift test` instead, with the sandbox and so the slower manifest re-evaluation, for `--test-product`, for packages whose tests import Swift Testing, for bundles it can't find or list, and for a `--filter` that Python and SwiftPM's regex engine might read differently, such as one with `\d`, `(?i)` or `{n}`. The job log shows each command the runner starts.

Focused daemon-coordinated examples:

```bash
make dev-test FILTER=RepoPromptTests.ExampleTests
make dev-test FILTER=RepoPromptTests.ExampleTests/testBehavior
make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.ExampleTests
make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.ExampleTests/testBehavior
```

Use the narrowest relevant filter while iterating. Adding, renaming, consolidating, or removing a test needs the affected focused run. Broaden to the affected target or full suite when the change crosses shared infrastructure, package boundaries, generated surfaces, test harness behavior, or many unrelated suites:

```bash
make dev-test
make dev-provider-test
```

A focused green run is evidence for the named contract, not a substitute for full-suite or CI coverage when the changed boundary is broad. The hosted root-test workflow discovers one current root XCTest population through `swift test list` and runs the discovered suites in one Build and Test job, each suite in its own XCTest process. The runner stops at the first failing suite, so a red run doesn't report the suites after it. Root CI has no contract/integration tier split or contributor-maintained registry. Provider-package tests run inside the Style job.

Hosted CI validates pull requests, release candidates, and pushes to `main`. A push to `main` first asks GitHub whether the commit already has a successful `CI` run from a push to `release/**`: when it does, the run confirms that and stops, and when it doesn't, or the question fails, the commit gets a validation run. A validation run first lists its changed paths: a pull request is compared with its base branch, a release candidate with `main`, and a push to `main` with the commits it adds. When every path ends in lowercase `.md`, the Style job runs only `make guardrails` and `make conductor-selftest`, whose tests check wording in `README.md` and `docs/architecture/developer-daemon.md`. The run skips the Build and Test job and the Sentry-enabled build, and the secret scan runs as usual. When CI can't list the paths, it runs everything. Once a day at 19:17 UTC, or on a `workflow_dispatch` from `main`, a refresh run on `main` builds the products and test bundles without running a test and saves the SwiftPM caches that every other run restores; no other run saves one.

The Sentry-enabled build runs on validated pushes to `release/**` and `main`, and in the refresh. Its `SentryTelemetryPrivacyTests` filter matches no suite in this distribution, so the step passes without running a test and a green run isn't privacy-test coverage.

## Codemap-sensitive changes

Routine pipeline and integration tests should not await real codemap generation when generation correctness is not the contract. Prefer seams, fakes, synthetic artifacts, or dual-path assertions that accept either pending/not-ready codemap status or ready code-structure output while still proving routing, path shape, and leakage boundaries.

Use the retained deterministic CodeMap tests for local coverage:

```bash
make dev-test FILTER=CodeMapGoldenTests
make dev-test FILTER=CodeMapArtifactContainerTests
```

Run these when changes touch CodeMap generation, syntax parsing, artifact storage, or Tree-sitter support. The packaged-app live codemap projection-demand gate is documented later in this guide.

## Performance and optimization evidence

Define the workload, acceptance threshold, comparable environment, sample count, warmup policy, source-state controls, invalid-sample rules, and retained evidence before measuring. Keep root and provider timings separate unless a derived serial estimate is clearly labeled. Diagnostic and wake-probe runs are lifecycle evidence, not valid timing samples.

Use focused before/after measurements to attribute a change, then exercise the full affected boundary before making repository-wide performance claims. Store durable evidence only when it has continuing review value; otherwise keep raw logs and machine-specific samples local. Do not create a replacement executable registry, method census, append-only repository scoreboard, or mandatory artifact hierarchy merely to track test counts.

## Live debug app identity and lifecycle

A debug package keeps the `RepoPrompt.app` directory and the `<bundle ID>.debug` identifier, but its `CFBundleExecutable` is `RepoPromptDebug`, at `Contents/MacOS/RepoPromptDebug`, and it shows as `RepoPrompt CE Debug` with the debug icon (`AppBundle/AppIconDebug.icns`) and a blue DEBUG badge, top rule, and composer ring in its windows. Release and local production packages keep `RepoPrompt`, at `Contents/MacOS/RepoPrompt`, and production's install path, executable, bundle identifier, and signing are the release values. The packaging validators, the packaged MCP round-trip smoke, and conductor read the executable from `CFBundleExecutable` instead of assuming a name.

Conductor stop, status, and launch, and the archive and restore guards, also accept a debug bundle packaged before that name, whose executable is still `RepoPrompt`. Conductor looks for it at the configured debug path. The guards recognize the debug app by its executable path, `RepoPromptDebug` or that older `RepoPrompt`, inside `DebugApps` or a `DebugApps-*` directory of the Application Support directory, or in the bundle that `REPOPROMPT_DEBUG_APP_BUNDLE` or `REPOPROMPT_DEBUG_APP_ROOT` names.

A change to debug packaging, conductor's debug lifecycle, or the archive and restore guards is validated against the packaged debug app while production keeps running, after `make conductor-selftest` and `make release-selftest` pass. Production's process is never stopped, launched, or relaunched by these steps.

1. Record production's PID, executable path, and start time. The production guard prints the PID and path and exits 3 while production runs; `ps -o lstart= -p <pid>` gives the start time:

   ```bash
   python3 Scripts/debug_app_process.py guard production \
       --production-executable "/Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt"
   ```

   Compare all three values after every step below. Any change is a failure, even if the step itself succeeded.
2. Exercise each debug action on its own through conductor: `make dev-run`, `./conductor app stop`, `make dev-launch-existing`, `make dev-smoke`, and a package that fails on purpose. Confirm through `./conductor app status` that the intended debug PID stopped or started and that it runs `Contents/MacOS/RepoPromptDebug`; a window title or a process-name match is not evidence. A failed package must leave the running debug app and its bundle untouched.
3. With both apps running, `guard release-state` must report production and the debug app, plus any attached helpers, and exit 3, while `guard production` reports only production:

   ```bash
   python3 Scripts/debug_app_process.py guard release-state \
       --production-executable "/Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt" \
       --app-name RepoPrompt \
       --display-name "RepoPrompt CE" \
       --support-dir "$HOME/Library/Application Support/RepoPrompt CE"
   ```

4. In light and dark appearance, confirm the DEBUG toolbar badge, the 2-point blue rule under the window chrome, and the blue composer ring. On an explicitly highlighted composer, such as an MCP-controlled tab, the orange highlight replaces the ring. Check one narrow window for toolbar layout. Release builds show none of these cues.

These steps run the debug app against its own profile, which [Debug profile isolation](#debug-profile-isolation) describes.

## Debug app signing and secure storage

Debug packaging may auto-detect an Apple Development signing identity for a valid local app signature, but auto-detected debug signing still uses ephemeral in-memory secure storage to avoid macOS Keychain prompts. Set an explicit `SIGN_IDENTITY="Apple Development: ..."` to opt in to persistent debug Keychain storage; `DEBUG_SECURE_STORAGE_BACKEND=keychain` is also supported for explicit debug storage opt-in when the signed app has a TeamIdentifier. If no stable identity is available, set `ALLOW_ADHOC_SIGNING=1` to build an ad-hoc debug app; ad-hoc debug builds use ephemeral in-memory secure storage, so API keys and secure permission changes do not persist across launches. Release packaging requires `SIGN_IDENTITY` and continues to use real Keychain storage.

## Debug CLI and live MCP smoke

Test this app with the CE debug CLI, `rpce-cli-debug`. The production `rp-cli` and `rp-cli-debug` connection is only an analogue and may talk to the non-CE app.

Install or inspect the debug CLI:

```bash
make debug-cli-status
make install-debug-cli     # packages the debug app, then installs /usr/local/bin/rpce-cli-debug
./Scripts/doctor.sh --install-debug-cli
```

`./conductor debug-cli-status` and `./conductor install-debug-cli` are the [developer daemon](architecture/developer-daemon.md) forms of the first two commands. The installer links:

```text
/usr/local/bin/rpce-cli-debug
  -> ~/RepoPrompt/repoprompt_ce_cli_debug
  -> ~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp
```

If `/usr/local/bin` needs administrator privileges, run the install target from an interactive terminal so `sudo` can prompt, or install the CLI from Settings → MCP → CLI Tools. Without the PATH link, use the direct fallback:

```bash
"$HOME/RepoPrompt/repoprompt_ce_cli_debug" -e 'windows'
```

The debug CLI talks to the debug app and shares its profile, which [Debug profile isolation](#debug-profile-isolation) describes.

The [validation matrix](../.agents/skills/rpce-contribution-check/references/validation-matrix.md) says which changes need the live smoke. `make dev-smoke` runs it against an already-running debug app, and `make dev-smoke-launch` builds and launches the debug app first. Both create the `repoprompt-ce` workspace once in a fresh debug profile and never recreate it. When creating it needs approval, the smoke stops within seconds and names the setting to change: Settings → Permissions → Workspace Approvals → Create workspace.

To check the live wiring by hand, launch the debug app and drive it with the debug CLI:

```bash
make dev-run
rpce-cli-debug -e 'windows'
rpce-cli-debug -w 1 -e "workspace create repoprompt-ce --folder-path $PWD"   # only when 'workspace list' lacks it
rpce-cli-debug -w 1 -e 'workspace switch repoprompt-ce'
rpce-cli-debug -w 1 -e 'tree --type roots'
rpce-cli-debug -w 1 -c agent_manage -j '{"op":"list_agents","roles_only":true}'
```

Then use `agent_run` for end-to-end Agent Mode behavior:

```bash
rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"explore","session_name":"CE debug CLI smoke","message":"Reply exactly with CE_AGENT_RUN_SMOKE_OK and stop. Do not edit files.","detach":true}'
rpce-cli-debug -w 1 -c agent_run -j '{"op":"wait","session_id":"<session_id>","timeout":120}'
```

### DEBUG-only diagnostics

Before live Agent Mode or Claude investigations, enable debug-only diagnostics through the CE debug app's MCP `app_settings` surface:

```bash
rpce-cli-debug -w 1 -c app_settings -j '{"op":"list","group":"agent_mode","detailed":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_logging_enabled","value":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_log_file_path","value":"/tmp/repoprompt-ce-claude-raw-events"}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.perf_diagnostics_enabled","value":true}'
```

If a key is unavailable, confirm that `rpce-cli-debug --version` resolves to the current CE debug build before falling back to lower-level defaults.

The `mcp_structure_settlement_snapshot` op reports one window's settlement registry: the counts of active, detached, released, and blocking entries, and a `leases` array, oldest admission first. Each lease gives its lease, invocation, and connection IDs, its tool, state, admission age, and blocking age, its `released` and `provider_completed` flags, and the handler phase its invocation last reported, with that report's transition and age. A handler phase is the await the call most recently reached. A `started` phase with a large age is the await that hasn't returned. A lease held by a protected mutation, such as `prompt set`, also gives its `mutation_state`. The state is `not_applied` once a deadline or cancellation has revoked the mutation before its commit, and `indeterminate_after_commit` once its commit has begun.

```bash
rpce-cli-debug -w 1 -c __repoprompt_debug_diagnostics -j '{"op":"mcp_structure_settlement_snapshot","window_id":1}'
```

Debug and release builds also write each watchdog escalation (deadline expiry, request cancellation, cleanup-grace expiry, detach, force-disconnect), each late settlement of a timed-out or cancelled provider, and each rejection at a window's released-provider limit to the unified log, with the tool, the invocation and connection IDs, the window, the handler phase and its age, and the window's blocking and released counts. Entries for a protected mutation, such as `apply_edits`, add its `mutation_state` and `operation_id`. The log records the first rejection for one blockage and then at most one more every 30 seconds. Read them from the debug or production app with:

```bash
log show --last 1h --style compact --predicate 'subsystem == "com.repoprompt.mcp" AND category == "ToolExecution"'
```

### Reproducing a stuck tool call

Run a stuck-call reproduction only against the debug app, never production. Confirm the target PID runs from the `DebugApps` bundle with `ps -o comm= -p <pid>` before pointing any tool at it. Record the workspace list and each window's tabs first, and compare them after cleanup.

1. Create the scratch roots under `/tmp` and add them as a scratch workspace by their `/tmp/...` paths. A root registered as `/tmp/...` doesn't resolve a `/private/tmp/...` path.
2. Drive each workload for a bounded time, one at a time:
   - concurrent `apply_edits` rewrites and creates, with `read_file` and `get_file_tree` loops, on one root
   - the same loops while a second root takes repeated Git commits
   - about 450 new directories in a minute while reads and edits continue
   - a create or rewrite of a megabyte or more
   - stopping an `rpce-cli-debug` client while its edit runs
3. While a workload runs, poll `mcp_structure_settlement_snapshot` for the scratch window every one or two seconds. Follow the unified log with `log stream` and the `ToolExecution` predicate, and take stacks with `sample <pid> 10` whenever a call stops returning.
4. You have found the wait when a lease stays in one `started` handler phase with a growing age, `sample` shows the same frame across samples, and the same workload reproduces it again.
5. Delete the scratch workspace, list the windows, and close any window the delete left open.

`swift-inspect` can't attach to the debug app. The debug bundle lacks the `get-task-allow` entitlement, so the task port request fails with `(os/kern) failure 0x5`. Use `sample` for stacks.

### Catalog shard patch measurement

A root's catalog shard is the store's sorted file, folder, and search-entry arrays for that root, with its path index. `mcp_read_search_runtime_snapshot` takes these arguments for measuring how a window's store applies a published batch of file changes to the shard:

- `catalog_batch_sample_limit` (0 to 128, default 0) returns each root's most recent batch samples under `store_work.root_catalog_shards.roots[].batches`. A sample describes one applied batch: its input size, the added or modified records that matched the shard's existing record (`no_op_count`), its effective edits, its outcome (`patched`, `rebuilt`, or `retention_blocked`), any fallback reason, the duration of each timed patch phase, and `canonical_apply_us`. The store keeps the last 128 samples per root. `total_observed_count` and `dropped_count` show how many it has seen and discarded.
  - Effective edits are file and folder record insertions plus removals, so a record that replaces another at the same path counts two.
  - The timed phases are normalize, locate, derive, merge copy, and path-index segment, and their sum is the timed-phase total. It leaves out building `affectedFileIDs`, `changedRelativePaths`, and the patch payload, which runs after the merge-copy phase and before the path-index segment.
  - `canonical_apply_us` runs from entering `applyPreparedIndexDeltas` to the end of the mutation pass, minus any comparison. It includes the preflight's awaited eligibility checks. It excludes the eligibility loop in `handleObservedFileSystemDeltas` and the wait to enter the store actor, so it isn't end-to-end publication latency.
- `catalog_patch_cap_override` (0 to 1,000,000) replaces the release cap, which gates patch eligibility. A batch over the cap, or one the store can't patch safely, requests an authoritative rebuild instead. Retention can block publishing the patch or the rebuild, which leaves the shard dirty until a later build and records the outcome `retention_blocked`. A root with no published shard and no delta state for its current lifetime stays lazy whatever the batch size. 0 restores the release cap.
- `catalog_patch_comparison` set to `next` makes the store build, and discard, an authoritative shard after the next patched batch of every root loaded at that moment. The batch's sample then includes `comparison`: the rebuild's duration, the parity check's duration, and `parity_matched`. `on` compares every patched batch, and `off` stops. The comparison runs on the store actor, and the sample's apply durations exclude its time.

The cap override and the comparison mode change one window's store, so both require `window_id`. Use them only on a generated scratch root that only the debug app has as a root. Keep it in a folder under your home directory, never in a repository checkout or worktree. Arm the comparison and raise the cap in one call before each measured batch:

```bash
rpce-cli-debug -w 1 -c __repoprompt_debug_diagnostics -j '{"op":"mcp_read_search_runtime_snapshot","window_id":1,"catalog_patch_cap_override":8192,"catalog_patch_comparison":"next","catalog_batch_sample_limit":16}'
```

A measured batch counts as a valid sample when these hold:

- All of the burst's effective edits landed in one batch sample, and that sample includes `comparison`. `parity_matched` is an outcome, not a condition: keep a sample whose parity failed, and mark its cell failing.
- Its outcome is `patched` with no fallback reason, and its effective edits equal the batch's size. Modifications never count as effective edits, so size a batch of rewrites by its input size instead.
- The shard's `lifetime_id` didn't change, and the newly observed samples fit in the returned list: the increase in `total_observed_count` across the burst is at most the number of new samples returned. Once the store holds 128 samples, every new sample evicts the oldest and advances `dropped_count`, so an advancing `dropped_count` doesn't mean a sample was lost.

The watcher's scheduled coalescing delay is 0.2 s from a burst's first event, so a longer burst can arrive as several published batches, called publications. The root's `ingress.accepted_service_publication_sequence` counts them, but take the actual batching from the samples: reject an attempt only when its intended effective edits are split across samples, not because more than one publication arrived. Renaming a file is quicker than writing one, so stage a large batch outside the root and rename its files in, and rename a whole folder to add or remove a subtree in one event.

When you're done, run the same operation with `"catalog_patch_cap_override":0` and `"catalog_patch_comparison":"off"` in every window you changed. Delete the scratch workspace with `manage_workspaces` (`delete` with `close_window`), and then delete the scratch folders. The [catalog shard batch patch investigation](investigations/catalog-shard-batch-patch-2026-10-20.md) records the measurement that used these arguments.

## Debug profile isolation

The debug app, the debug CLI, and debug headless sessions keep runtime state in `~/Library/Application Support/RepoPrompt CE Debug` and `$TMPDIR/RepoPrompt CE Debug`. Workspaces, chat and agent history, settings, presets, window sessions, saved prompts, and the managed Codex home live there, and production's `~/Library/Application Support/RepoPrompt CE` is neither read nor written. Developer infrastructure stays in the production profile's directory: the debug bundle under `DebugApps`, conductor state under `Conductor`, and the CLI links in [Debug CLI and live MCP smoke](#debug-cli-and-live-mcp-smoke). Archive and restore keep excluding those entries and never touch the debug profile. A debug build packaged before the split still reads and writes production's profile.

Preferences stay in the debug app's own defaults domain. A debug build ignores a saved custom workspace storage location and the automatic `~/Downloads/RepoPrompt-Backup` restore without changing either preference, and it refuses to relocate workspace storage. Workspace metadata that points outside the debug profile's `Workspaces` directory, whether in the workspace index, the runtime catalog, or a working journal, stays on disk unchanged. The runtime reports that workspace unavailable with the reason `workspace_storage_boundary_violation`, and mutations against it fail with the same reason.

Production state is the release profile, its temporary root, and the release prompt folder `~/Library/Application Support/com.pvncher.repoprompt`. Nothing starts when the debug profile resolves into production state, such as through a symlink. The same check covers the top-level entries of the profile and of its temporary root. It also covers the fixed files and directories each store declares below them, such as the domain runtime's state, the Codex homes and configuration, and the settings, preset, and identity-diagnostics files. The app prints `RepoPrompt CE Debug did not start:` and the reason to stderr, and records the same message in the unified log under subsystem `com.repoprompt.debug-profile`, category `launch`:

```bash
log show --last 1h --predicate 'subsystem == "com.repoprompt.debug-profile"'
```

The CLI prints `RepoPrompt MCP:` and the reason to stderr, then exits 1. Remove the symlink or override the message names, then relaunch.

Each store checks the locations it names per workspace or per item where it resolves them: workspace documents and the workspace index, chat and agent-session files and indexes, saved prompts, partitions, workflows, git data, and the domain runtime's per-workspace journals, revisions, deletion records, and locks. A location that resolves outside the debug profile, through a symlink at the file or along its folders, is never followed. A read skips it and leaves it on disk unchanged, a write fails with an error that names it, and the domain runtime reports `workspace_storage_boundary_violation` and stays read-only.

Three suites hold the deterministic contracts. Each opts in to the debug isolation policy, which stays off under XCTest so other suites can keep using temporary custom storage locations:

```bash
make dev-test FILTER=MCPFilesystemIdentityIsolationTests
make dev-test FILTER=DebugProfilePersistenceIsolationTests
make dev-test FILTER=DomainWorkspaceStorageBoundaryTests
```

The live check writes distinct markers through the debug and release apps and their CLIs, then reopens both. Each profile must hold only its own markers, and a fresh debug profile must hold nothing from production. A byte-for-byte comparison of the production profile needs an approved quiet window, because a running production app changes its own state. For a run that must not touch either real profile, use a disposable home and set `CFFIXED_USER_HOME` as well as `HOME`, because `HOME` alone does not move Foundation preferences or sockets. Confirm the app's effective Application Support and preferences paths before starting.

Isolation covers state files only. The URL scheme, document types, global shortcuts, and Sparkle update ownership are still shared between the two apps.

## Seed the debug profile from a release archive

A fresh debug profile is empty, so it can't reproduce how the app behaves with many workspaces and long chat and agent histories. `Scripts/seed_debug_profile.py` copies that state one way from a production [release archive](releasing.md#rollback-unit) into the debug profile. It reads only the archive, never the live production profile, so production can keep running.

Reading `application-support.tar.zst` needs Python 3.14 or newer built with zstd support. On an older Python the seed stops before reading and says which Python it needs. Gzip archives seed on any Python the script supports.

```bash
python3 Scripts/seed_debug_profile.py --dry-run     # run every check and report what would be copied
python3 Scripts/seed_debug_profile.py               # newest complete archive, every workspace
python3 Scripts/seed_debug_profile.py --archive local/v1.4.0-b45 --workspace my-project
python3 Scripts/seed_debug_profile.py --replace     # move the current debug profile aside first
```

`--archive` takes a tag under `~/Archives/repoprompt-ce` or an absolute archive directory. Without it, the seed picks the archive with the newest manifest timestamp. Repeat `--workspace` to select more than one workspace. Naming `repoprompt-ce` with `--workspace`, in any letter case, refuses without changing anything, because that name belongs to the smoke workspace. The data is only as fresh as the archive, and the report gives its age. For fresher data, quit production and run `Scripts/local_release_archive.sh <tag>`.

The seed refuses, before it writes anything, when:

- The manifest is missing, or a listed file doesn't match its `.sha256` sidecar and the checksum in the manifest.
- The manifest lists neither state file or both, or it lists `application-support.tar.zst` and the running Python can't read zstd.
- The archive's working-journal schema version is unknown, or it or a journal in the archive is newer than the `RepoPromptWorkingJournalSchemaVersion` the debug bundle declares. Build the debug app with `make dev-build` first. An older archive is fine: the debug build reads it the way production will after its next upgrade, so seeding also exercises the upgrade path.
- The debug app or a debug CLI is running. A running production app doesn't block it.
- The debug profile or its staging directory resolves into the production profile, such as through a symlink in one of its parent folders.
- The debug profile holds anything and `--replace` is absent. `--replace` renames the current profile to `RepoPrompt CE Debug.before-seed-<timestamp>` beside it and never deletes it.

The seed copies each selected workspace's document with its `Chats` and `AgentSessions` folders, its working journal and revision record, the workspace index and runtime catalog filtered to those workspaces, presets, and `Settings/globalSettings.json`. It leaves out managed Codex homes, MCP routing records, policy files, agent run ownership records, event and kill-signal directories, locks, diagnostics, and temporary files. Anything else outside that list stays behind too, such as code map caches, partitions, workflows, window sessions, and each workspace's `_git_data`. Settings kept in the preferences domain, such as approvals, aren't copied. The report names every skipped workspace with its reason. The seed skips a workspace whose storage lies outside the archived profile or that the archive lacks, and it always skips `repoprompt-ce`, the small workspace `make dev-smoke` creates and uses.

The seed rewrites JSON string values that start with the archived production profile's path, as a plain path or a file URL, to start with the debug profile's path. Text that only mentions the path stays as written, and source folder paths don't change, because debug opens the same folders. A file without such a value keeps its exact bytes. When the seed rewrites a workspace document, it also updates that workspace's working journal and revision record wherever their saved-document digest matched the archived document. Debug then neither treats the document as edited outside the app nor resets its saved revision. The seed also decodes each working journal's unsaved working document and rewrites and scans it the same way. A working document that names no production path keeps its exact bytes. After rewriting, any path value that still resolves into production, such as one that uses `..` or different letter case, stops the seed. The error names the archive member and the JSON location, never the value.

Extraction refuses a member with an absolute or `..` name, a device, or a FIFO. It also refuses any symbolic or hard link inside the state it copies. A link can carry a later write out of the profile, and the release archives hold no links there. Two members whose names differ only in letter case or Unicode normalization also stop the seed, because one would overwrite the other on a case-insensitive file system. The seed assembles the profile in a staging directory beside the destination and publishes it with one rename. A failure removes the staging directory and leaves the debug profile unchanged. If Control-C, SIGTERM, or SIGHUP stops the publish after `--replace` moved the current profile aside, the seed moves it back, and the final message says whether it published anything. A kill the seed can't catch, such as SIGKILL, or a second interruption while it's already cleaning up or restoring, can leave the hidden `.RepoPrompt CE Debug.seed-staging-*` directory or the moved-aside `RepoPrompt CE Debug.before-seed-<timestamp>` in `~/Library/Application Support`.

To seed a disposable profile instead of the real debug profile, point `HOME` at a temporary directory and pass the archive by absolute path. Name the real debug bundle with `REPOPROMPT_DEBUG_APP_BUNDLE`, so the format check and the running-app check both use it:

```bash
real_home="$HOME"
HOME=/tmp/seed-home \
    REPOPROMPT_DEBUG_APP_BUNDLE="$real_home/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app" \
    python3 Scripts/seed_debug_profile.py --archive "$real_home/Archives/repoprompt-ce/local/v1.4.0-b45"
```

To launch the debug app on that profile, also set `CFFIXED_USER_HOME`, as [Debug profile isolation](#debug-profile-isolation) describes.

`python3 Scripts/test_seed_debug_profile.py` covers each refusal, rewrite, skip, and replacement with small fixture archives under a temporary home. On a Python without zstd support it skips the case that seeds from a zstd archive.

## Live Codex Desktop direct-headless worktree routing

Run this release acceptance only from a Codex Desktop task whose repository root is an existing linked worktree and whose RepoPrompt launcher selects `--backend headless` with that exact root in `REPOPROMPT_MCP_WORKING_DIRS`. The canonical checkout must already belong to one saved RepoPrompt CE workspace. This lane validates an installed release candidate; it does not build, install, launch, stop, or relaunch RepoPrompt, create a workspace, or create a worktree.

Record the saved workspace file hash and `git worktree list --porcelain` before starting. In the same Codex task:

1. Call `bind_context` with `op=status`. Require a bound context from the saved canonical workspace, then use `get_file_tree`, `read_file`, and `git status` to prove the task's linked worktree is the physical execution root. A path that exists only in the canonical checkout must remain outside the root fence.
2. Start two detached `agent_run` sessions with `worktree=@current` and bounded read-only instructions that report a worktree-only marker. Save both returned session IDs and require them to be distinct.
3. Reconcile both exact session IDs with `agent_run op=wait` and inspect them with `agent_manage op=list_sessions`. Require both terminal snapshots to report the same exact `worktree_root_path`, repository identity, and worktree identity, and require both markers to come from that worktree. Cancel and reconcile any nonterminal session before ending the task. Nested `orchestrate` acceptance belongs to the separate direct-headless workflow/tool-policy change and is not a release gate for this standalone routing change.
4. Recheck `git worktree list --porcelain`, the saved workspace file hash, and workspace catalog count. Require no added worktree, no changed saved workspace, no temporary workspace, and no durable worktree binding. Repeat once with an explicit different existing selector and require only that session's physical root to change.

The Codex Desktop pre-start app-CLI isolation fallback remains in place through this acceptance and the release that contains the fix. Removing or bypassing it is a separate post-release change after the recorded acceptance passes; a failed or unavailable direct-headless check leaves the fallback unchanged.

## Live MCP run-affinity validation

Run this before merging a change to how MCP connections join Agent Mode runs: pending-policy admission, the bootstrap `initialize` refusal, the routing fallback, or a provider's per-turn policy lease. The contract is that a connection joins an established run only with that run's session token or a newly armed run-owned pending policy; a connection that matches the run by process ancestry alone is refused with `expected_pid_without_pending_policy`, receives an `initialize` error naming the agent session and the remedy, and never routes, binds a window, or serves tools.

Deterministic coverage comes first:

```bash
make dev-test FILTER=PersistedMCPRoutingIdentityTests
make dev-test FILTER=MCPWindowBootstrapReadinessTests
make dev-test FILTER=CodexMCPRoutingReadinessTests
make dev-test FILTER=ACPIntegratedAgentModeRunnerExecutionTests
```

`PersistedMCPRoutingIdentityTests` drives four connections against one established run:

- C1 consumes the run's one-shot policy and owns the run.
- C2 carries a fresh token with the same ancestry and no pending policy; a real socket handshake must refuse it.
- C3 reconnects with C1's token and takes over the run with identical restrictions.
- C4 carries a fresh token and consumes a newly installed policy exactly once.

Then exercise the exact debug bundle through `rpce-cli-debug` with a disposable repository, using only models the debug app advertises. Record every arm as passed, failed, or not run with its reason; a provider quota or model refusal is "not run", never a pass, and says nothing about the routing contract.

| Arm | Exercise | Required result |
|---|---|---|
| Start and steer | Start one Agent Mode session per configured provider (Codex, Claude Code, and OpenCode when configured), then steer it | Routed on start; no refusal |
| Idle reconnect | Leave a session idle until its helper reconnects with its session token | Same run, same restrictions |
| Provider restart | Use each provider's supported reconnect or restart path | Admitted by token or by a new pending policy |
| Child runs | From a parent session, start one `agent_run` child per role: explore, engineer, pair, design | Each child routes to its own run |
| Concurrent runs | Run two sessions at once, including two that share one parent process | Each keeps its own run and restrictions |
| Context Builder | Run Context Builder, then send a follow-up on its chat | No refusal |
| OpenCode follow-up | Continue an OpenCode session for several turns, and respawn its helper within the first minute of one follow-up turn | Each follow-up turn arms one pending policy; the respawned helper consumes it and is admitted, a turn that ends with its policy unused removes it, and the established helper keeps its run and restrictions throughout |
| Forced refusal | Terminate a session's `repoprompt-mcp` helper mid-turn so its provider respawns it with a fresh token and no pending policy | Each provider surfaces the reason-bearing error text to the agent |

Count refusals in the debug app's run-routing history, where each one is a `policy_rejected` event with reason `expected_pid_without_pending_policy`:

```bash
rpce-cli-debug -w 1 -c __repoprompt_debug_diagnostics -j '{"op":"run_routing_history","limit":500}'
```

Count by distinct cause, because a provider may retry a failed `initialize`; every arm other than the forced refusal requires zero. Repeated refusals must stay cheap and must not accumulate routing state. Finish with `agent_manage op=list_sessions` showing no orphan active run, and retain sanitized run and connection provenance only; never record capability tokens.

This validation proves the admission contract only. The cause of unexplained `Transport closed` and tool-watchdog failures remains unproven; it is not attributed to this refusal and is investigated separately.

### Context Builder cross-tab rows

Run these rows before merging a change to Context Builder admission, its startup or routing waits, its teardown, or MCP run routing. They exercise two Context Builder runs in one window at once, which the earlier arms don't. [`docs/mcp-progress.md`](mcp-progress.md) states the startup waits, the refusals, and how to read the phases and errors these rows produce.

Deterministic coverage comes first:

```bash
make dev-test FILTER=ContextBuilderWindowAdmissionTests
make dev-test FILTER=ContextBuilderGracefulShutdownTests
```

Use an already-running debug app and a dedicated workspace with two compose tabs, A and B, each with its own distinguishable fixture file selected. The rows never build, install, launch, stop, or relaunch the app. For a cold row, prepare the workspace and relaunch the debug app before starting, and label the row cold only when that boundary is true. List the window's tabs with their `context_id` values, and confirm the flag names with `rpce-cli-debug --help` before the first row:

```bash
rpce-cli-debug -e 'windows'
```

Each `rpce-cli-debug` invocation is its own caller connection, and `--context-id` binds it to one tab before its command runs. Start one call per tab together, and keep each call's result and its progress output:

```bash
rpce-cli-debug --context-id <A_CONTEXT_ID> --raw-json \
    -e 'call context_builder {"instructions":"<question only fixture A answers>","response_type":"question"}' \
    > a.json 2> a.progress &
rpce-cli-debug --context-id <B_CONTEXT_ID> --raw-json \
    -e 'call context_builder {"instructions":"<question only fixture B answers>","response_type":"question"}' \
    > b.json 2> b.progress &
wait
```

Send a follow-up on a returned chat with the `chat_id` its result names:

```bash
rpce-cli-debug --context-id <A_CONTEXT_ID> --raw-json \
    -e 'call ask_oracle {"message":"<follow-up question>","chat_id":"<CHAT_ID>","new_chat":false}'
```

| Row | Exercise | Required result |
|---|---|---|
| Cold and warm starts | Start A and B together, once right after a relaunch and once on a warm app | Both complete, each with its own provider process, routing events, and commit |
| Panel plus MCP | Press Run on tab A in the app and start B through the CLI, then the reverse | Both complete, and the window shows only the selected tab's run |
| Same-tab overlap | Start a second call for A while A's run is in discovery | The second call returns `Context Builder is already running for this tab.`, A's run completes, and the refused call changes nothing in A |
| Cancel A | Cancel A's call while B is in discovery | A ends as cancelled and its provider process exits; B completes |
| Close A's tab | Close tab A while both runs are in discovery | Only A ends; B commits its own prompt and selection |
| Close the window | Close the window while one run is in discovery and another is in its follow-up | Every run the window owns settles, and no provider process remains |
| Follow-up on the chat | After a call with a `response_type` completes, send a follow-up on its chat | The follow-up answers in that chat with that tab's context; no refusal, including with OpenCode |
| Two windows, one workspace | Open the workspace in a second window. Start A from each window, then A from one and B from the other | The second call for A is refused; A and B in different windows both complete |
| Background question | Let B's run ask a clarifying question while tab A is shown | The question appears on B when B is shown, and A's panel is unchanged |
| Late cleanup | Cancel A's run, then start a new run on A while the first run's provider is still exiting | The new run routes, commits, and keeps its controls |

Record every row as passed, failed, or not run with its reason. For each run, keep these as evidence:

- The result's `context_id`, which must be the tab the call bound. The bind step alone proves nothing.
- The result's exact `prompt` and `selection`, which must be that tab's, and its `agent` and `model`.
- The last progress line, and the returned `chat_id` when the call asked for a response.
- The run's routing events and its child connection, from the debug app's run-routing history and connection list:

```bash
rpce-cli-debug -w <WINDOW_ID> -c __repoprompt_debug_diagnostics -j '{"op":"run_routing_history","limit":500}'
rpce-cli-debug -w <WINDOW_ID> -c __repoprompt_debug_diagnostics -j '{"op":"connections"}'
```

A row with two runs needs overlap inside the app, shown in both directions by exact run ID in the run-routing history. A's `connection_observed` or `policy_applied` event comes before B's last `policy_cleared`, and B's `connection_observed` or `policy_applied` event comes before A's last `policy_cleared`. One direction alone also holds when one run finished before the other started. Admission isn't evidence in either direction. An admitted run is still preparing and may have no provider yet, so `policy_installed` or a `running` state doesn't show two providers at work.

A run's last `policy_cleared` is the end of its routing-policy lifetime and nothing more. A run clears its policy last, after its discovery has ended and its result is committed. This check shows that two policy lifetimes overlapped. It doesn't show that two providers' work overlapped.

The "Cold and warm starts" and "Panel plus MCP" rows need that direct evidence, by exact run ID. Overlapping admissions or policy lifetimes alone are insufficient for these rows. A run's `expected_pid_cleared` event is insufficient too. It's cleanup evidence only. The app records it some time after the provider process has exited, so an event that comes before it doesn't show the process was still running. The minimum for these rows is one of the two kinds of evidence that follow. Prefer the first.

The first is interleaved tool calls. A snapshot of a run's child connection reports the child's tool-call count and the time of its latest call. The connection is the `connection_id` of the run's `policy_applied` event:

```bash
rpce-cli-debug -w <WINDOW_ID> -c __repoprompt_debug_diagnostics -j '{"op":"connection_snapshot","connection_id":"<CHILD_CONNECTION_ID>"}'
```

Take snapshots of both children at different times while both runs are in discovery. The row has overlap when a `last_tool_call_at_ms` of the second run's child falls between two `last_tool_call_at_ms` values of the first run's child.

The second is the first run's provider process observed running across a tool call of the second run. The process ID is the `expected_pid` of the first run's `expected_pid_registered` event. Check it right after a snapshot of the second run's child shows a `total_tool_calls` of at least one, and keep the time, the state, and the start time:

```bash
date +%s; ps -p <PROVIDER_PID> -o pid=,stat=,lstart=
```

The row has overlap when all these hold:

- `ps` lists the process at a time later than that snapshot's `last_tool_call_at_ms`, in a state other than zombie (`Z`).
- The process started before that `last_tool_call_at_ms`.
- The process started no later than the `timestamp_ms` of the `expected_pid_registered` event.

Both diagnostics times are Unix milliseconds, and `lstart` has one-second resolution. The start time doesn't rule out a reused process ID. A start time that can't be told apart from a later start, or from a replacement process, is ambiguous and leaves the row incomplete.

A snapshot that reports `missing` was taken after its connection ended and is no evidence. Neither is a zombie or a `ps` that lists no process. A missing event or a missing snapshot leaves the row incomplete.

Two CLI processes that were alive together don't show overlap. A row without that overlap, with ambiguous or unsupported evidence, or with cleanup that can't be attributed to one run, is incomplete, never a pass. A unit-test pass doesn't stand in for it.

Two CLI invocations are two caller connections, so these rows don't cover one caller connection that rebinds between two calls. No automated test covers that case. A caller-side timeout is a safety bound for a failed row, not the app's routing limit, and ending a CLI process doesn't prove its provider stopped. Reconcile exact run IDs and provider process IDs from the diagnostics afterward, and never end processes by name. Keep raw results, progress output, the build identity, and the app's process ID and start time privately, and never record capability tokens.

## Live large-workspace worktree-startup diagnostic

`Scripts/worktree_startup_live_benchmark.py` is the reusable validation lane for
large-root and linked-worktree startup. It drives `rpce-cli-debug` and the
DEBUG-only `worktree_startup_benchmark` diagnostics. It never builds, installs,
launches, stops, or relaunches RepoPrompt. A fresh-process (cold) run therefore
requires relaunching the debug app before invoking the script; label a run
`cold` only when that boundary is true. An aged run requires the configured
minimum existing Agent Mode session count and keeps aged and warm samples in
separate distributions.

This is a runtime diagnostic, not XCTest coverage. It does not replace focused
behavioral tests or the broader suite validation required by the changed boundary.

The [June 2026 benchmark campaign
report](investigations/worktree-startup-benchmark-campaigns-2026-06-26.md)
records the interactive-readiness and content-addressed codemaps campaigns and
holds the full check lists this section summarizes.

### Dedicated workspace and plan

Use a disposable workspace whose name starts with `RPCE 8E Bench ` or the
established `RPCE Search Bench ` prefix. Never use the active development
checkout. Create/open a separate disposable root with `rpce-cli-debug`, bind
the benchmark tab, and record its exact window, workspace, context, and root IDs. A name or
current selection is not proof of isolation. Create an exclusive root marker
with a new owner UUID after those stable IDs exist:

```bash
OWNER_TOKEN="$(uuidgen)"
python3 Scripts/worktree_startup_live_benchmark.py create-marker \
  --root-path /absolute/path/to/disposable/large/repository \
  --workspace-id '<workspace-uuid>' \
  --root-id '<root-uuid>' \
  --owner-token "$OWNER_TOKEN" \
  --confirm-disposable-root
```

The marker binds its canonical root, workspace UUID, root UUID, owner token,
disposable purpose, and SHA-256 digest. Preflight/run/smoke/cleanup also resolve
the workspace by UUID through `manage_workspaces`, require the exact name and
root membership, and require the planned root to be the sole root before and
after the campaign. A missing, changed, renamed, system/current-only, or
operator-named substitute is rejected. Workspace creation, root
addition/removal, and visible window changes can request app approval; prepare
the workspace before the campaign.

The driver rejects its own repository root as a disposable root. To benchmark a
dedicated checkout of this repository instead, run that checkout's copy of the
script and pass `--confirm-real-repository-benchmark` and
`--confirm-dedicated-workspace` to `create-marker` and `plan`, and
`--confirm-dedicated-workspace` to `preflight` and `run`. The [campaign
report](investigations/worktree-startup-benchmark-campaigns-2026-06-26.md#interactive-readiness-iteration-0-campaign)
shows those commands.

Write an immutable plan without contacting the app:

```bash
python3 Scripts/worktree_startup_live_benchmark.py plan \
  --workspace-name "RPCE 8E Bench 20260625T120000Z" \
  --window-id 3 \
  --workspace-id '<workspace-uuid>' \
  --context-id '<context-uuid>' \
  --root-id '<root-uuid>' \
  --root-path /absolute/path/to/large/repository \
  --owner-token "$OWNER_TOKEN" \
  --dataset-label rpce-large \
  --asserted-file-count 100000 \
  --base-ref HEAD \
  --search-marker WorkspaceRootSeedPlanner \
  --read-path Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceRootSeedPlanner.swift \
  --read-marker WorkspaceRootSeedPlanner \
  --invocations-per-series 3 \
  --output /tmp/rpce-worktree-startup-plan.json
```

`read-path` must name a blob committed in the exact `base-ref`, and that blob
must contain both `search-marker` and `read-marker`. Plan resolves `base-ref` to
an immutable commit OID, verifies the blob through that OID, and freezes both
the commit OID and blob SHA-256. Preflight, run, and smoke re-resolve the symbolic
ref and reject drift; every app/local worktree start uses the stored OID. The rest of a
100k/1M pressure fixture may remain untracked in the parent root, but an
untracked-only marker cannot be inherited by an app-created Git worktree and is
rejected.

`asserted_file_count` is operator-supplied provenance, not an app measurement.
The plan freezes the ownership-marker digest; do not recreate or edit the marker
between cohorts.
The plan is the sole source of truth for required route/process/checkout/width
cells and aggregate thresholds.

Before any mutation, enable the DEBUG-only benchmark gate for the campaign, and
restore it to its prior value after all run and smoke cleanup completes. The
harness verifies the gate but never changes this global setting on the
operator's behalf:

```bash
rpce-cli-debug -w 3 -c app_settings -j \
  '{"op":"set","key":"agent_mode.worktree_startup_benchmark_diagnostics_enabled","value":true}'
```

Then run preflight:

```bash
python3 Scripts/worktree_startup_live_benchmark.py preflight \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --confirm-live-debug-app
```

Preflight rejects a moved symbolic `base-ref`, rechecks the tracked marker blob
through the stored commit OID, freezes
SHA-256 hashes for the relevant CLI schemas, and requires the DEBUG benchmark
token plus `manage_workspaces.remove_folder`. A marker, schema, or scope change
invalidates the campaign; do not silently substitute IDs.

### Route and concurrency cohorts

Run one route/process/checkout/width series at a time. Every retained series
uses one excluded warmup and five retained samples. `plan` and `run` reject
other counts. The plan defaults to exactly three invocation artifacts per matrix
cell. Valid slow samples remain included. A rerun gets a new invocation ID and
never replaces the old artifact; an unplanned extra invocation makes the
campaign incomplete rather than supplying replacement samples.

```bash
python3 Scripts/worktree_startup_live_benchmark.py run \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --route forced-full \
  --process-state warm \
  --checkout-kind linked-worktree \
  --width 4 \
  --invocation 1 \
  --warmups 1 \
  --samples 5 \
  --confirm-live-debug-app \
  --confirm-process-state
```

Repeat for every route, process state, and width the plan declares. `run`
rejects any other value. Plans written today declare process states `warm` and
`aged`, widths 1, 4, and 8, and three routes. `baseline` is the ordinary
automatic full-crawl control, `forced-full` forces that route, and `projected`
serves the worktree from its diff-seeded projection. Cold main-root numbers
come from the external evidence described below. Automated route samples are
always app-created `linked-worktree` starts. The harness checks each cohort's
actual route and fallbacks in the diagnostic export, so configured route names
alone never satisfy it; the
[campaign report](investigations/worktree-startup-benchmark-campaigns-2026-06-26.md#route-accounting) gives the exact route accounting.

The current DEBUG token does not measure initial main-workspace opening. Capture
main-checkout cold/warm root-ready/search/read separately from the existing
restore/readiness diagnostics and retain it beside the campaign; the driver
does not offer a label-only `main` route that could be mistaken for a real
measurement. If that evidence is absent, the final decision is `incomplete`,
never a pass.
Record reviewed external evidence in the same plan namespace rather than
putting an unstructured claim in the scoreboard:

```bash
python3 Scripts/worktree_startup_live_benchmark.py record-evidence \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --scenario cold-main-workspace-open-root-ready \
  --status pass \
  --details /tmp/cold-main-sanitized-details.json \
  --output /tmp/cold-main-evidence.json
```

Also record `main-checkout-cold-warm-root-search-read`. The other required
records are `fresh-process-provenance`,
`aged-process-session-and-thread-inventory`, and
`host-sleep-and-thermal-validity`. `aggregate --evidence <file>` accepts each
reviewed record; missing or plan-mismatched evidence keeps the gate incomplete.

Every sample record, diagnostic export, and ordinal has a one-to-one mapping
to a unique correlation UUID and unique Agent Mode session UUID. Aggregation
rejects reuse, disagreement between record/export IDs, duplicate ordinals,
mixed artifact/cohort identities, and extra or missing invocation/sample
counts. Any attempted sample—including an excluded warmup—with route,
attribution, or correctness failure invalidates the cohort and campaign; valid
extras cannot mask it.

### Correctness, watchers, and root churn

Run the smoke lane after route sampling:

```bash
python3 Scripts/worktree_startup_live_benchmark.py smoke \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --confirm-live-debug-app \
  --confirm-dedicated-workspace
```

The smoke lane uses a script-owned app worktree and temporary roots. It checks
Agent Mode tool use in a parent session and an inherited-worktree child;
exact-root search, read, selection, and codemap results; non-Git handling;
watcher convergence; and root add and remove during in-flight calls. The
[campaign report](investigations/worktree-startup-benchmark-campaigns-2026-06-26.md#smoke-lane-checks) lists each check.

The harness records and checks parent and child terminal status, removes only
roots it added, cancels/waits only sessions it started, and removes registered,
clean, script-owned worktrees only after every relevant agent is terminal or
cancelled. Cleanup evidence must include terminal agents, removed secondary
roots/worktrees, restored route control, unchanged benchmark setting, successful
diagnostic reset, stopped resource sampling, and restoration to the sole planned
root. Dirty, nonterminal, missing-identity, or otherwise ambiguous resources are
preserved for manual cleanup. Resume interrupted cleanup with:

```bash
python3 Scripts/worktree_startup_live_benchmark.py cleanup \
  --artifact /tmp/rpce-worktree-startup/v1/<run> \
  --confirm-live-debug-app \
  --confirm-owned-resources
```

Raw CLI responses may contain paths or source snippets. Run directories are
created non-overwriting with mode `0700`; files use `0600`. Review before
sharing. Summary/scoreboard output must not be treated as privacy-scrubbed raw
evidence.

### Mandatory live codemap projection-demand gate

`codemap-gate` is the packaged-app release authority for live codemap demand.
It uses the already-running current DEBUG app, `rpce-cli-debug`, the exact
dedicated workspace plan above, and real `agent_run` sessions. It never builds,
launches, stops, or relaunches the app. Prepare its lifecycle state separately.
The planned root must be an owned,
synthetic or explicitly source-allowlisted Git workspace with at least 5,000
supported code files; the existing `plan` command's 100,000-file minimum is a
valid stronger fixture. Each measured directory fixture must remain within the
gate's 100-file output bound; use the separate overflow fixture for rejection.

Create a private fixture JSON. It must contain at least 20 unique individual
files and 20 unique directories. Every marker must occur in the exact tracked
or intentionally synthetic source file named by that entry, and the overflow
directory must contain at least two listed individual fixtures:

```json
{
  "schema_version": 1,
  "individuals": [
    {"path": "Sources/Large/A.swift", "marker": "CodemapGateA"}
  ],
  "directories": [
    {
      "path": "Sources/Large/DirectoryA",
      "expected_file": "Sources/Large/DirectoryA/Entry.swift",
      "marker": "CodemapDirectoryGateA"
    }
  ],
  "overflow_directory": "Sources/Large/Overflow",
  "watcher_directory": ".rpce-codemap-gate"
}
```

Use a retained, previously accepted `codemap-gate` `summary.json` from the same
fixture digest as the baseline, plus a separately reviewed acceptance ledger.
The ledger is strict JSON and binds the raw summary-file SHA-256, artifact ID,
and fixture SHA-256; one exact entry must match. Supply the ledger's separately
reviewed SHA-256 explicitly so a synthetic summary plus synthetic ledger cannot
self-attest:

```json
{
  "schema_version": 1,
  "kind": "codemap-gate-baseline-ledger",
  "accepted_summaries": [
    {
      "artifact_id": "20260625T000000Z-codemap-gate-example",
      "summary_sha256": "<sha256-of-the-exact-summary.json-bytes>",
      "fixture_sha256": "<fixture_sha256-from-summary.json>"
    }
  ]
}
```

The release gate deliberately refuses a missing, hand-written/unaccepted,
different-fixture, wrong-count, missing-inventory, zero, `NaN`, or infinite
baseline:

```bash
python3 Scripts/worktree_startup_live_benchmark.py codemap-gate \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --fixture /tmp/rpce-codemap-gate-fixture.json \
  --baseline /tmp/rpce-codemap-retained-baseline/summary.json \
  --baseline-ledger /tmp/rpce-codemap-baseline-ledger.json \
  --baseline-ledger-sha256 <independently-reviewed-ledger-sha256> \
  --cold-samples 20 \
  --warm-samples 40 \
  --confirm-live-debug-app \
  --confirm-dedicated-workspace \
  --confirm-synthetic-allowlisted-source
```

The printed artifact directory is local raw evidence. It contains the exact
`rpce-cli-debug` JSON, agent transcript XML, sample NDJSON, state, cleanup,
resource, fixture, plan, and derived summary files. Directories must remain
`0700` and files `0600`. The final scan fails closed on credential patterns,
the developer checkout, unallowlisted home/private paths, or mode drift.
Only the separate derived `summary.json` shape is shareable: scenario IDs,
hashed relative identifiers, content/presence hashes, statuses, issue codes,
counters, and timings. Do not publish raw artifacts.

The command passes only when all eight gates pass: sample counts and readiness,
the agent probes, root add and remove, non-Git and watcher behavior, the held
timeout, regression against the retained baseline, and cleanup. The [campaign
report](investigations/worktree-startup-benchmark-campaigns-2026-06-26.md#codemap-gate-pass-criteria) lists them.

Any missing raw evidence, missing retry delay, stale path/content/marker,
privacy leak, non-Git codemap work, latency/resource regression, nonterminal
agent, ambiguous ownership, or incomplete cleanup is a hard failure. On an
interrupted run, use the existing `cleanup` command with the artifact path; it
releases or proves expiry of recorded codemap holds and removes recorded added
roots only when its independent ownership checks pass. Temporary non-Git roots
carry an exclusive artifact/plan/token-bound ownership marker; a mutable
`state.json` path or basename prefix is never sufficient deletion proof.

### Aggregation, thresholds, and append-only scoreboard

Aggregate offline after collecting every matrix cell and correctness smoke:

```bash
python3 Scripts/worktree_startup_live_benchmark.py aggregate \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --artifact /tmp/rpce-worktree-startup/v1/<run-1> \
  --artifact /tmp/rpce-worktree-startup/v1/<run-2> \
  --evidence /tmp/cold-main-evidence.json \
  --output /tmp/rpce-worktree-startup-aggregate
```

The aggregate emits `summary.json` and a reviewable
`scoreboard-section.md`. After reviewing evidence and paths, append—never
rewrite—the candidate to the scoreboard the plan's `scoreboard` field names,
`docs/investigations/optimize-worktree-interactive-readiness-runs.md` for plans
written today. `--append-scoreboard` appends only to an existing file, so
create the scoreboard first if it is missing. The explicit automation path is
guarded and append-only:

```bash
python3 Scripts/worktree_startup_live_benchmark.py aggregate \
  ... \
  --append-scoreboard docs/investigations/optimize-worktree-interactive-readiness-runs.md \
  --confirm-append-scoreboard
```

The aggregate applies the thresholds the plan froze.

Missing matrix cells, CPU/physical-footprint data, cold main-root evidence, or
correctness evidence yields `incomplete`. Any recorded invalid attempt yields
`fail`; it is never silently excluded from campaign validity. Never infer a gate
from configured route names, untyped text, generic tool failures, or additional
valid samples.

Script-only validation, with no app or CLI calls:

```bash
python3 -m py_compile Scripts/worktree_startup_live_benchmark.py
python3 Scripts/worktree_startup_live_benchmark.py --help
python3 Scripts/worktree_startup_live_benchmark.py create-marker --help
python3 Scripts/worktree_startup_live_benchmark.py self-test
python3 Scripts/worktree_startup_live_benchmark.py self-test --help
python3 Scripts/worktree_startup_live_benchmark.py plan --help
python3 Scripts/worktree_startup_live_benchmark.py record-evidence --help
python3 Scripts/worktree_startup_live_benchmark.py preflight --help
python3 Scripts/worktree_startup_live_benchmark.py run --help
python3 Scripts/worktree_startup_live_benchmark.py smoke --help
python3 Scripts/worktree_startup_live_benchmark.py codemap-gate --help
python3 Scripts/worktree_startup_live_benchmark.py aggregate --help
python3 Scripts/worktree_startup_live_benchmark.py cleanup --help
```

## Canonical MCP schema and bind_context discovery

`docs/spec/mcp-domain-canonical-tool-definitions.generated.json` is a review projection of `MCPDomainCanonicalToolDefinitions`; never edit it by hand. After changing a canonical definition, regenerate it from the Swift authority, then rerun without the marker to prove equality:

```bash
mkdir -p .build && touch .build/update-mcp-domain-schema-review-snapshot
make dev-test FILTER=DirectHeadlessCompositionTests/testCanonicalDefinitionsMatchReadableGeneratedReviewSnapshot
make dev-test FILTER=DirectHeadlessCompositionTests/testCanonicalDefinitionsMatchReadableGeneratedReviewSnapshot
```

Review the snapshot diff: only the definitions you changed may differ. Update the expected `catalogFingerprint` in `MCPDomainStandaloneCompositionTests` from the value that test reports, never from a guess.

Four suites cover `bind_context` discovery: `MCPDomainStandaloneCompositionTests` (canonical schema), `DirectHeadlessCompositionTests` (real headless rejection), `BindContextRoutingAuthorityTests` (handler parsing, listing, and binding), and `BindContextOutputFormattingTests` (compact and filtered output, hinted arguments). A change to its schema, handler, or hints is also exercised live from a client that sees only the retrieved schema:

1. Start a fresh external MCP client, such as a new Claude Code session, against the CE debug app; a client that cached the old tool list must reinitialize. Validate each intended `bind_context` argument against the `tools/list` schema with a stock JSON-schema validator before sending it, because a raw `rpce-cli-debug -c` call skips schema validation.
2. Prepare one window with an active tab, a bound inactive tab, and at least two inactive unbound tabs, and a second window with unrelated tabs. An unfiltered `list` keeps the compact Windows summary. A `list` with the first window's integer `window_id` returns every compose tab of that window and none of the second, without changing the active tab, focus, binding, or selection.
3. Bind an inactive tab by its listed `context_id`, switch the visible tab, and confirm later calls still target the bound tab. Repeat with `window_id` alone and with `window_id` beside `context_id` or `working_dirs`.
4. Unknown, `null`, string, fractional, and out-of-range `window_id` values fail; none returns an unfiltered list.
5. Against `repoprompt-mcp --backend headless` with an explicit `REPOPROMPT_MCP_HEADLESS_PROFILE_DIR`, the backend advertises the same schema and rejects any supplied `window_id`, including `null`, without changing scope. Agent Mode sessions still do not receive `bind_context`.

Keep the captured schema and assertion results as local evidence; do not commit raw MCP transcripts.

## Handoff checklist

- Protected contract, plausible defect, chosen layer, and observable oracle.
- Added/renamed/consolidated/removed exact IDs, including complete `old -> new/removed` mappings.
- Exact focused and broader validation commands with results appropriate to the changed boundary.
- Style, guardrail, build, smoke, or packaging evidence when applicable.
- For performance work: measurement protocol, retained evidence, sample validity, and timing comparison.
- Any coverage deliberately omitted, removed, moved to diagnostics, or replaced by a guardrail, with justification.
