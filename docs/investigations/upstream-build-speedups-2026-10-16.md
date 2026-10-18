# Upstream build and CI speed-ups: what to port, and in what order

> Investigation report, observed 2026-10-16 on `main` at `f68ca4d0d` and the upstream reference clone at `116f9214`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [CONTRIBUTING.md](../../CONTRIBUTING.md), Landing.

## Answer

Port three things, in this order. Defer the build-modularization series.

1. **Conductor per-job overhead (upstream PR 1088).** Every conductor build or test job pays a fixed 11–15 s before any useful work, because each job hands SwiftPM a new environment value and SwiftPM re-evaluates the package manifests whenever its environment changes. A no-op focused test costs 16.7 s locally, for 3 ms of tests. For the same case, upstream measured 74.7 s before its fix and 2.2 s after. Small port (3 files upstream). It has to be adapted to the distribution's own test sandbox, which adds a second per-job value.
2. **Fewer macOS jobs per CI run, and caches saved only from `main` (parts of upstream PRs 1127 and 1174).** Run the Sentry-enabled build on branch pushes only, not on pull requests, and run the secret scan on Linux. Also fold the provider tests into the Style job, which is a distribution adaptation. Restore the compiled cache on every run, but save it only from `main` pushes. A pull request run drops from 8 macOS jobs to 5, which fits GitHub's 5-job macOS concurrency limit, and from 5 app builds to 4. This change is YAML only.
3. **CI build-once (upstream PRs 1127 and 1152).** One job compiles the test bundles, and the four shards run them without compiling. The shards also prove that every listed test executed. Today every shard recompiles all ~1,050 app sources. After items 2 and 3, a run compiles the app once and should use about half of today's 75–86 macOS runner-minutes. This item doesn't make a lone run faster. It cuts queueing when several runs overlap.

Defer upstream PRs 1107 (beyond the PR 1088 fix it repeats), 1113, 1116–1118, the rest of 1127, 1173, 1194, 1201 and 1224. Only 7% of the distribution's Swift edits since the fork touched code that upstream has moved out of the app target so far. The areas where distribution work concentrates (`Features/AgentMode`, `Infrastructure/MCP`) move in upstream PRs 7–10, which upstream hasn't opened. The port would be hand-written across about 1,200 file touches. It would also conflict with #192's local-signing changes, which edited 7 of the files upstream PR 1127 moves into a new `RepoPromptSecureStorage` target.

All three fit the proposed release-candidate landing path, and two of them change how its `ci.yml` edit should be written. Item 2 belongs in the same change set as the landing path, because once `release/**` pushes run CI, a run that saves a cache anywhere but `main` wastes repository cache space. Item 1 can run alongside, and item 3 follows. [How the ports fit the landing-path design](#how-the-ports-fit-the-landing-path-design) has the details.

## How the ports fit the landing-path design

The design was a local working document, not yet approved. Approved pull requests merge in order onto `release/<version>-rc<N>`. The candidate is validated once: hosted CI runs through a new `release/**` push trigger, a new local `candidate` preflight lane runs the `pr-ready` lanes and `make dev-smoke-launch`, and the agent runs the debug-app checks. Then `main` fast-forwards to the tested tip.

**Local validation is shorter than the design assumes.** The design takes local `pr-ready` to need about 20 minutes for app code. The preflight's own timing receipts (`.build/validation-artifacts/pr-ready/*.json` in agent worktrees, 2026-08-28 to 2026-10-15, heavy-slot waits included) say otherwise. The 55 passing runs that ran the full root suite took p50 198 s and at most 399 s. The root-test phase was p50 157 s of that. On the design's own figures, the candidate lane would then take about 8–12 minutes including `dev-smoke-launch` (about 5 minutes), and the debug-app checks about 20. That puts the local side at about 28–32 minutes. Hosted CI takes 20–25 minutes uncontended and up to 51 minutes when runs overlap, so it's close to the local side and longer whenever runs queue. CI speed affects how long each landing waits, and items 2 and 3 count for more than the design's timing table suggests.

**Caches must be saved only from `main`.** A workflow run can restore caches from its own branch or the default branch, and a pull request run can also restore from its base branch. No run can restore a cache saved on a sibling branch ([GitHub docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)). Each candidate is a new branch, so a cache saved by a `release/**` run is visible only to that candidate. It still counts against the 10 GB repository limit, where eviction removes the least recently used caches first. Today's `ci.yml` uses `actions/cache`, which saves whenever the exact key misses. The key changes only with the root and provider `Package.swift` and `Package.resolved` files, so a candidate or pull request that changes a dependency would save 3 GB caches on its own branch. With 9.4 GB already in use, that evicts at least one of `main`'s caches. Item 2 fixes this the way upstream PRs 1127 and 1174 do: restore on every run, save only on `main` pushes, and key each save by commit, so every `main` push replaces the shared cache with a current one.

**Whether `main` pushes keep running CI then matters for caches and for Sentry.** The design left open whether `main` pushes keep running CI after a landing. If they stop, no run ever refreshes the shared cache, and a `main`-only Sentry job never runs. Under item 2:

- Sentry runs on `push` to `main` and `release/**` and never on `pull_request`. Each candidate gets one Sentry build whichever way that question is decided.
- If `main` pushes keep CI, that run is also the cache producer. After items 2 and 3, it costs about 50 macOS runner-minutes including the Sentry build, instead of today's 75–86.
- If `main` pushes drop CI, a `main`-push job that only builds and saves the cache keeps pull request and candidate runs warm. From today's step timings (restore, app and MCP builds, test-bundle build, save), that job would take roughly 13–18 minutes on one macOS runner.

The compiled cache spares the dependency builds and nothing else, because checkout resets every source file's modification time. That still saves several minutes per job: upstream measured 321 s to build a cold module closure of 57 dependency-heavy targets, plus about 227 s to resolve and fetch dependencies (section P0.3 of `docs/migrations/build-modularization/ledger.md` in the reference clone, upstream's measurement record).

**The secret-scan move keeps the design's range rule.** The design adds a `release/*` case that scans `origin/main..<tip>`. Item 2 moves the scan to `ubuntu-latest` and must keep that case, the `.gitleaks.toml` handling, and `fetch-depth: 0`.

**Hosted bisect is where the job count hurts most.** For a failure that reproduces only on the hosted runner, the design pushes every merge commit at once as `release/<version>-rc<N>-m<i>` and expects one wait instead of k. GitHub runs at most 5 macOS jobs at once on this account's plan ([limits](https://docs.github.com/en/actions/reference/limits)). Five parallel runs need 375–430 macOS runner-minutes today, so on 5 slots they take at least 75–86 minutes, against one run's 20–25. Item 2 changes little here, because the bisect branches match `release/**` and still run the Sentry build. With item 3 a run needs about 50 runner-minutes, so five take at least about 50 minutes, or about 37 if the bisect branches skip the Sentry build (a `!release/**-m*` branch filter would do that). These are lower bounds from runner-minutes, not measurements. Running only the failing job on the bisect branches would avoid most of the queue, and that's a design question.

**Item 1 shortens agents' iteration more than the landing.** The `candidate` lane runs about five to seven conductor jobs (lint, root tests, provider tests, two product builds, `dev-smoke-launch`), which saves about 1–1.5 minutes per candidate. The larger saving is in the pre-approval loop: up to 182 conductor jobs a day across checkouts, each 11–15 s shorter.

**Sequencing.** Item 2 edits the same `ci.yml` lines as the design: the triggers, the secret-scan range, and the cache steps the new trigger makes wasteful. `docs/porting.md` requires each port on its own `port/` branch with an `Upstream-Ref`. Item 2 goes on a `port/` branch stacked on the landing-path branch, with the `stacked` label, and both land in the same candidate. Item 1 touches only conductor files and can run in parallel. Item 3 follows both, because it rebuilds the workflow that item 2 trims and reuses item 1's direct-`xctest` runner.

## Baseline

**Fork point.** The newest upstream commit in distribution `main`'s history is `bbc14343` (2026-09-05). Upstream `main` has 299 first-parent landings since then. The distribution brings upstream changes over one pull request at a time ([`docs/porting.md`](../porting.md)), and none of the candidates below has been ported.

**Local, through conductor.** Swift 6.4, idle machine, `main` checkout.

| Job | Conductor exec | SwiftPM's reported build |
| --- | --- | --- |
| `make dev-swift-build PRODUCT=RepoPrompt`, after `main` moved | 1 m 49 s, plus cache publication (131 s wall) | 86 s |
| Same, no changes | 13.2 s | 1.7 s |
| `make dev-test FILTER=RepoPromptRegexCoreTests`, first run (test bundle relinks) | 59.0 s | not reported |
| Same, no changes | 16.7 s | 1.8 s; 7 tests ran in 3 ms |
| `touch` one app file (`SequenceExtension.swift`), then `make dev-swift-build PRODUCT=RepoPrompt` | 32.0 s | 18.7 s |

Conductor's retained logs across all checkouts hold 661 build-producing jobs from 2026-10-02 to 2026-10-16, with up to 182 jobs on one day. All of them pass through one machine-wide heavy slot. At 11–15 s of fixed overhead per job, that's about 2–2.7 hours of serialized heavy-slot time over the two weeks. Heavy-slot waits are small by comparison: 616 of the 641 jobs that logged one got the slot within milliseconds, 10 waited over a minute, and the longest wait was 6 m 15 s.

**Hosted CI.** Five `ci.yml` runs on 2026-10-15:

- Each run starts 8 macOS jobs: Style, four root shards, the Sentry-enabled build, provider tests, and the secret scan. Each run uses 75–86 macOS runner-minutes.
- A shard takes 12–17 min. Of that, "Build app product" takes 8–11.7 min and the test step 2.7–3.8 min. The Sentry job takes 8.5–15 min.
- GitHub ran at most 5 of the account's macOS jobs at once. In two pull request runs that overlapped a `main` push, jobs waited 7–22.6 min to start. Wall time across the last 60 runs that weren't cancelled ranged from 11 to 51 min.
- All three SwiftPM caches (3.1 GB each, 9.4 GB in total) were created on 2026-09-24 and never replaced, because their key hashes only `Package.swift` and `Package.resolved`. Even so, a fresher cache would not help first-party code. Shard 1 of run 38769220904 hit the cache, then compiled 1,048 `RepoPromptApp` sources and the vendored C sources (`Build of product 'RepoPrompt' complete! (460.69s)`). `actions/checkout` gives every source file a new modification time, and each job then rebuilds all first-party code. The cache only spares the job from compiling dependencies.
- The same shard log has 12,252 warning lines. The deprecated MCP `.text(_:metadata:)` call accounts for 4,860 of them.
- Both red `main` runs on 2026-10-15 failed in shard 2's test step, not in dependency download.

**Upstream's CI after its build-once change.** Three runs on 2026-10-14 and 2026-10-15:

- The single "Build and Static Gates" job takes 28–37 min. Lint takes 3–4 min, the test-bundle build 11–13.5 min, and the module parity tests 5–11 min, all in sequence.
- The no-build shards then take 2.6–7.6 min each.
- Each run uses 47–55 macOS runner-minutes, and wall time is 28–64 min.

Upstream's change cut builds and runner-minutes, and left wall time where it was. Its serial gate job is longer than a distribution shard. Item 3 below keeps Style as a parallel job so the distribution doesn't repeat that.

**Where distribution edits land.** Since the fork, 514 Swift file touches in non-merge commits: 452 (88%) in `Sources/RepoPrompt`, 23 in `RepoPromptDomainRuntime`, 23 in `RepoPromptShared`, 9 in `RepoPromptMCP`, and 6 in the provider package. Inside the app, the most-edited areas are `Features/AgentMode` (120), `Infrastructure/MCP` (107), `Features/ContextBuilder` (40) and `Infrastructure/AI` (39). 37 touches (7%) hit files that upstream has moved out of the app through its PR 5.

## Candidates

Sizes are upstream's pull request totals. "Changed lines" compare each repository's file with the fork point.

| Upstream | Merged | Size | What it changes | Upstream's measured gain | Distribution |
| --- | --- | --- | --- | --- | --- |
| PR 1088 | 09-28 | +314/−10, 3 files | Conductor passes the job ticket only to its own operation runner. The local test runner lists the built bundle with `swiftpm-xctest-helper` and runs it with `xctest` directly. | No-op focused test 74.7 s → 2.2 s | Missing. `Scripts/conductor.py:4323` exports the ticket to every job. |
| PR 1107 | 09-29 | +4,893/−30, 19 files | Modularization phase 0: plan and ledger, conductor phase timings, index-graph and ratchet tooling, `test --module` (one test target built with Swift Build in its own scratch path), and the PR 1088 fix | Module path: edit→test 77% faster (`RepoPromptMCPCoreTests`), 95% (`RepoPromptDomainRuntimeTests`) | Missing |
| PR 1113 (lands 1108 and 1109) | 09-29 | +3,939/−3,751, 83 files | Retires the app's Objective-C bridging header; splits the MCP CLI into a `RepoPromptMCPCore` library and a thin executable | None claimed | Missing |
| PRs 1116, 1118 | 09-29 | Docs | Completion plan and review policy | None | Missing |
| PR 1117 | 09-29 | +977/−1, 7 files | Move-audit and access-lift tooling for later moves | None | Missing |
| PR 1127 (modularization 2 of 10) | 10-01 | +7,058/−2,449, 452 files | Tooling T1–T5: module catalog, import check, ratchets, `dev-test MODULE=`, admission v2, CI build-once, Sentry build on `main` only, secret scan on Linux. Foundations A1–A5: 5 new targets and 76 file moves. | CI: one app build per run instead of five | Missing |
| PR 1152 | 10-01 | +747/−98, 18 files | Style becomes the final Linux gate and proves every listed test executed; binary-artifact cache; bounded retries for package resolution; module parity tests on pull requests | None (correctness and robustness) | Missing |
| PR 1173 (3 of 10) | 10-02 | +2,056/−2,774, 45 files | WorkspaceContext seams, no file moves | None claimed (seams for headless MCP) | Missing |
| PR 1174 | 10-02 | +15/−2, 1 file | Saves the binary-artifact cache only on `main` pushes | None (cache hygiene) | No separate binary cache to apply it to |
| PR 1194 (4 of 10) | 10-03 | +3,583/−1,361, 56 files | MCP server seams, no file moves | None claimed (seams for headless MCP) | Missing |
| PR 1201 (5 of 10) | 10-05 | +13,740/−8,532, 585 files | Extracts FileSystem, VCS, Persistence and SettingsCore targets with owning tests (96 file moves) | Module tests for those areas | Missing |
| PR 1224 | 10-05 | +1/−0 | Adds an import that PR 1201 missed | None | Only needed with PR 1201 |

T1–T5 and A1–A5 are item labels from upstream's completion plan, `docs/migrations/build-modularization/completion-plan.md` in the reference clone. No modularization pull request after 5 of 10 exists upstream yet. Upstream PRs 1177 (Tip release workflow, which the distribution has parked) and 1256 (conductor process identity across locales) touch the same files but aren't speed work.

**How far each file has diverged.**

| File | Distribution changed lines | Upstream changed lines | Distribution-only work in it |
| --- | --- | --- | --- |
| `Scripts/conductor.py` | 498 | 774 | Test-job sandbox (`configure_xctest_sandbox`), heavy-waiter fix, smoke restore wait, debug profile and executable, local production signing (#192, 6 lines) |
| `Scripts/ci_app_test_runner.py` | 0 | 601 (399 → 960 lines) | None |
| `Package.swift` | 2 | 190 (17 → 38 targets) | None that conflicts |
| `.github/workflows/ci.yml` | 15 | 261 | Secret scan honours `.gitleaks.toml`; Codex CLI pin |
| `Makefile` | 5 | 23 | Small |

## Recommended port order

### 1. Conductor per-job overhead: port upstream PR 1088

- **What.** Keep per-job values out of the environment of SwiftPM processes. Upstream's change has two parts:
  - It passes the conductor job ticket only to conductor's own operation runner.
  - It runs a focused test's built bundle with `xctest` directly instead of through `swift test`. Mixing `swift build` and `swift test` re-plans the next build, which costs another 10–15 s.

  The distribution needs a third part. Conductor's test sandbox (`REPOPROMPT_TEST_SANDBOX_ROOT`, a new path for each job) must reach the XCTest process but not SwiftPM. The only reader is `Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift`.
- **Expected gain.** About 11–15 s off every conductor build and test job. A no-op focused test should fall from 16.7 s to a few seconds, and a one-file app build from 32 s toward its 18.7 s build time. The cause comes from upstream's diagnosis. The port's first step confirms it here with a stable-environment comparison run through conductor.
- **Depends on.** Nothing. Include the follow-up commit `ad24b29e` from the same upstream pull request, which fixes how XCTest method nodes are read from the helper's listing.
- **Size and risk.** Small to medium. The ticket half is about 30 lines. The direct-`xctest` half means writing a local mode for `Scripts/ci_app_test_runner.py`, or the same logic in conductor, because the distribution never adopted upstream PR 986's `--local` runner. It also needs a fallback to `swift test` for Swift Testing, `--test-product`, and bad filters. The main risk is test discovery drifting from `swift test list`. Upstream checked that both listed the same 3,599 tests.
- **Conflicts.** None with #192 (its 6 conductor lines are elsewhere). It overlaps the distribution's sandbox code, which is the adaptation above.

### 2. Fewer macOS jobs per CI run, and caches saved only from `main`: parts of upstream PRs 1127 and 1174

- **What.**
  - Move the Sentry-enabled build and its privacy test to a workflow that runs on pushes to `main` and `release/**`, never on pull requests. Upstream's `ci-main.yml` runs it on `main` pushes only. The `release/**` trigger is a distribution adaptation for the landing path. No distribution build links Sentry: the local production installer doesn't, and the official release lane is parked.
  - Move the secret scan to `ubuntu-latest` with a pinned, checksum-verified gitleaks, keeping the distribution's `.gitleaks.toml` handling and the landing path's `release/*` range case.
  - Run the provider package tests in the Style job and drop their separate job. This is a distribution adaptation. Upstream runs them in its build job.
  - Split each `actions/cache` step into a restore that always runs and a save that runs only on `main` pushes, with the commit SHA in the key and a prefix restore key, as upstream PR 1127 does for its build cache and upstream PR 1174 for its binary cache.
- **Expected gain.** A pull request run uses 5 macOS jobs instead of 8 and builds the app 4 times instead of 5. It no longer queues against itself at the 5-job limit (shard 4 waited 7.9 min in run 38769220904). It also saves about 10–16 macOS runner-minutes. This is an estimate from the five runs above, not a measurement. The cache rule protects `main`'s caches from eviction and keeps them current.
- **Depends on.** Nothing in this report. It can merge in parallel with item 1, because the two touch different files.
- **Size and risk.** About 80 lines of YAML. Low risk: every check still runs on `release/**` and `main` pushes.
- **Conflicts.** The landing-path design edits the same workflow's triggers and secret-scan range. Stack this port on the landing-path branch, as the sequencing paragraph above describes. Whether `main` pushes keep running CI decides what refreshes the shared cache after a landing.

### 3. CI build-once: upstream PR 1127 (T5) and PR 1152

- **What.**
  - One macOS job builds the root test bundles and both products, packs the runnable test products, and uploads them. The four shards download them and run tests without compiling.
  - Style stays a separate parallel job. Upstream folds it into the build job.
  - Port PR 1152's execution receipts and its final coverage gate, so a shard that runs no tests, or fewer tests than assigned, fails. Today `Scripts/ci_app_test_runner.py` checks only each suite's exit status and returns 0 for a shard with no suites.
  - Keep item 2's cache rule. Only the build job restores and saves the compiled cache.
  - Leave out upstream's index-graph attestations, type-check ratchet, clean `main` builds and module parity tests. They belong to the modularization tooling.
- **Expected gain.** One app build per run instead of four. About 35–45 macOS runner-minutes per pull request run instead of 75–86, and about 50 for a branch push that also runs the Sentry build. During the build phase two overlapping runs use 4 macOS jobs and fit the limit, which also shortens hosted bisects. A lone run is no faster and may take 2–4 min longer: one 12–14 min build, then 3–5 min shards. These are estimates. Upstream's own numbers are in the baseline above.
- **Depends on.** Item 1's direct-`xctest` runner (the shards run a transferred bundle), item 2's job layout, and the landing path's triggers.
- **Size and risk.** Medium. A `ci.yml` rewrite plus three or four Python scripts and their self-tests (pack and unpack, shard runner, coverage gate), all under `Scripts/` and `.github/`, with no Swift changes. Risks: artifact size, because upstream measured the aggregate test bundle at 415 MB, and the shard-runs-nothing case, which the coverage gate covers.
- **Conflicts.** Same workflow file as the landing-path design and item 2. It also touches `Scripts/ci_app_test_runner.py`, which item 1 changes.

### Deferred: the build-modularization series

Upstream PRs 1107 (except the PR 1088 fix), 1113, 1117, 1127 (foundations and T1–T4), 1173, 1194, 1201 and 1224.

- **Gain for the distribution is small today.**
  - Module tests skip the app only for code that lives outside it. That's 7% of distribution edits for what upstream has moved so far, plus 4.5% already in `RepoPromptDomainRuntime`.
  - Upstream PRs 3 and 4 don't claim a build-time gain. They add seams for headless MCP.
  - The phase where upstream expects the gain moves WorkspaceContext, the MCP server, AI and the agent runtime. Those are upstream PRs 6–10, which upstream hasn't opened.
- **Cost is high.**
  - About +36,000/−19,000 lines, reproduced as hand-written source edits under `docs/porting.md`, with debug-app validation for each port.
  - Files the distribution also edited since the fork: 9 in PR 1113, 107 in PR 1127, 15 in PR 1173, 31 in PR 1194, and 131 in PR 1201.
  - Upstream PR 1127 moves 13 `Infrastructure/Security` files into a new `RepoPromptSecureStorage` target. #192 changed 7 of them for local production signing.
- **Cost of waiting.** Each upstream move puts files at new paths, so later ports of upstream fixes in those files need path translation. That cost grows with each modularization pull request. It's a porting-strategy question rather than a speed question.
- **Revisit when** upstream merges its MCP server move (PR 7 of 10). Then measure what share of the trailing 60 days of distribution edits would land outside the app.
- **Admission v2 (from PR 1127)** schedules more heavy jobs at once. Heavy-slot waits are already small (see the baseline), so it has little to remove.

## Observations outside this report's scope

These ideas aren't upstream ports, and none of them is verified. They're listed because they came out of the measurements. "Ledger" below means upstream's measurement record, `docs/migrations/build-modularization/ledger.md` in the reference clone.

- **CI rebuilds all first-party code** because checkout resets file modification times. Normalizing source modification times before restoring the cache might let the shared compiled cache skip unchanged files. Upstream doesn't do this, and llbuild's file signatures may defeat it.
- **Warning volume.** On one large rebuild, upstream measured SwiftPM spending 238 s printing compiler diagnostics after compilation had finished (ledger, P0.1). The distribution's CI build prints 12,252 warning lines, 4,860 of them from one deprecated MCP call.
- **`dsymutil`** takes 60–75% of every debug link in upstream's measurements (ledger, P0.5). Upstream recommended evaluating local debug links without dSYM generation but hasn't adopted it.

## Draft issues

These are drafts only. None has been filed. The labels come from the distribution's label set. A search of open and closed distribution issues found no duplicates. #26 (conductor `BuildCache` retention) is related but separate.

### Draft 1

**Title:** Conductor: keep per-job environment values away from SwiftPM (port upstream PR 1088)

**Labels:** `port`, `tooling`

**Body:**

Every conductor build and test job spends 11–15 s before it does any work. Upstream traced the same overhead to SwiftPM's manifest cache, which is keyed on the full process environment because `Package.swift` reads it. Conductor gives each job a new `REPOPROMPT_CONDUCTOR_JOB_TICKET` (`Scripts/conductor.py`, where the job environment is prepared) and, for test jobs, a new `REPOPROMPT_TEST_SANDBOX_ROOT`. SwiftPM then re-evaluates the manifests and re-plans the build for each job.

Measured through conductor on 2026-10-16 (Swift 6.4, idle machine):

| Job | Conductor exec | SwiftPM's reported build |
| --- | --- | --- |
| `make dev-test FILTER=RepoPromptRegexCoreTests`, no changes | 16.7 s (7 tests, 3 ms) | 1.8 s |
| `make dev-swift-build PRODUCT=RepoPrompt`, no changes | 13.2 s | 1.7 s |
| Same after touching one app file | 32.0 s | 18.7 s |

Conductor logged 661 build-producing jobs across checkouts from 2026-10-02 to 2026-10-16. They all share one machine-wide heavy slot. The overhead also delays every other agent's job.

Upstream PR 1088 (commits `dfef50f4` and `ad24b29e`) fixed this upstream. The ticket goes only to conductor's operation runner, and focused tests run the built bundle with `xctest` directly instead of through `swift test`. Upstream measured a no-op focused test at 74.7 s before the fix and 2.2 s after. The distribution's local test path differs from upstream's, because it never adopted upstream PR 986's `--local` runner and has its own conductor test sandbox. The sandbox root must also reach only the XCTest process.

Acceptance:

- A run through conductor with a stable environment confirms the cause before the change, and the issue records the result.
- A no-op `make dev-test FILTER=RepoPromptRegexCoreTests` finishes in a few seconds, and a no-op `make dev-swift-build PRODUCT=RepoPrompt` stays within a few seconds of SwiftPM's reported build time.
- The direct-`xctest` path discovers the same tests as `swift test list` for the root package. It falls back to `swift test` for Swift Testing, `--test-product`, and filters it can't apply.
- Tests still run inside the conductor sandbox. `MCPFilesystemIdentityIsolationTests` and the conductor self-tests pass.
- Lock metadata still shows the job ticket.

### Draft 2

**Title:** CI: cut a pull request run to five macOS jobs and save caches only from main (port parts of upstream PRs 1127 and 1174)

**Labels:** `port`, `area:ci`

**Body:**

Each `ci.yml` run starts 8 macOS jobs, and GitHub runs at most 5 of the account's macOS jobs at once. One run on its own already queues: in run 38769220904, provider tests waited 5.3 min and shard 4 waited 7.9 min. When it overlaps a `main` push, its jobs wait up to 22 min to start. Each run uses 75–86 macOS runner-minutes.

These jobs don't need a macOS slot on every pull request:

- **Sentry-enabled build and privacy test** (8.5–15 min, a full app build). No distribution build links Sentry: the local production installer doesn't, and the official release lane is parked. Upstream PR 1127 moved this job to a workflow that runs on `main` pushes only. Here it should run on branch pushes: `main`, plus `release/**` if the release-candidate landing path adds that trigger, so every candidate gets one Sentry build even if `main` pushes stop running CI.
- **Secret scan.** Upstream PR 1127 runs it on `ubuntu-latest` with a pinned, checksum-verified gitleaks.
- **Provider tests** (1–2.6 min, most of it restoring a 3 GB cache to run under 30 s of tests). They can run in the Style job.

The cache steps need the same change. `actions/cache` saves whenever its exact key misses, and the key hashes only `Package.swift` and `Package.resolved`. A run can restore caches from its own branch and the default branch only (pull request runs also from their base branch). A pull request or `release/**` branch that changes a dependency then saves 3 GB caches that no other branch can use. The three `main` caches already fill 9.4 GB of the 10 GB repository limit, so such a save evicts them. Upstream PRs 1127 and 1174 restore on every run and save only on `main` pushes, with the commit in the key.

Acceptance:

- A pull request run starts 5 macOS jobs (Style and the four root shards) and no longer queues against itself.
- The Sentry-enabled build and `SentryTelemetryPrivacyTests` run on every `main` push, and on every `release/**` push if that trigger exists. They don't run on pull requests.
- The secret scan covers the same commit ranges, including a `release/**` case if one exists, and still uses `.gitleaks.toml` when the tree has one.
- Provider package tests still gate pull requests.
- Pull request and `release/**` runs restore the latest `main` cache and never save one. `main` pushes save a cache keyed by commit, or a dedicated `main`-push job does if `main` pushes stop running CI.

### Draft 3

**Title:** CI: build root test bundles once and run the shards from that build (port upstream PRs 1127 and 1152)

**Labels:** `port`, `area:ci`

**Body:**

Every root shard compiles the whole app before it runs its quarter of the tests. In run 38769220904, shard 1 restored the SwiftPM cache, then compiled 1,048 `RepoPromptApp` sources (`Build of product 'RepoPrompt' complete! (460.69s)`), and ran tests for 2.8 min. `actions/checkout` gives every source a new modification time. The restored cache then spares only the dependency builds, and every shard repeats the same app build. The caches date from 2026-09-24 and are never replaced.

Upstream builds once. A "Build and Static Gates" job compiles the root test bundles, packs the runnable test products, and uploads them. "Test Root Shard (No Build)" jobs download them and run their suites without compiling (upstream PR 1127). Upstream PR 1152 makes the final Style gate prove that every listed test ran exactly once across the shards. Without that proof, a shard that executes nothing still passes: `Scripts/ci_app_test_runner.py` checks only each suite's exit status and returns 0 for a shard with no suites.

Port the build-once job, the no-build shards, and the execution receipts and coverage gate. Only the build job restores and saves the compiled cache, under the `main`-only save rule. Keep Style as a parallel job instead of folding lint and self-tests into the build job: upstream's combined job takes 28–37 min, longer than a distribution shard. Upstream's index-graph attestations, type-check ratchet and module parity tests depend on its modularization tooling, so they stay out.

This depends on the direct-`xctest` runner from the conductor per-job overhead port. It edits the same workflow as the change that cuts a pull request run to five macOS jobs. It also shortens a hosted bisect that pushes several branches at once, because each run then holds only two macOS jobs while it builds.

Acceptance:

- One job per run compiles the app and test bundles. Shard logs don't show any compilation.
- The final gate fails a run when any listed test didn't execute, executed twice, or a shard's receipt is missing.
- Shard jobs neither restore nor save the compiled cache.
- Comparing about five runs before and after: macOS runner-minutes per run fall by roughly half, and the change reports wall time with and without an overlapping run.

### Draft 4 (optional: deferral tracker)

**Title:** Revisit porting the upstream build-modularization series after upstream's MCP server move

**Labels:** `follow-up`, `needs-mp`

**Body:**

Upstream is splitting `RepoPromptApp` into modules in a series capped at 10 pull requests. Merged so far: upstream PRs 1107, 1113, 1117, 1127, 1173, 1194, 1201 and 1224. The distribution has none of them. They're deferred for now:

- 7% of distribution Swift edits since the fork touched code upstream has moved so far.
- Upstream PRs 3 and 4 of the series don't claim a build-time gain.
- The port is about +36,000/−19,000 lines of hand-written edits, and it collides with the local production signing changes in #192.

Revisit when upstream merges its MCP server move (PR 7 of 10). Then measure what share of the trailing 60 days of distribution Swift edits would land outside the app target, and weigh that against the path-translation cost that every upstream move adds to later ports.
