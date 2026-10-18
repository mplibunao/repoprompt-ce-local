# CI macOS runner-minute optimization

- Start date: 2026-10-19
- Metric: macOS runner minutes per CI workflow run: the sum of the elapsed time of every macOS job in the run, with parallel jobs counted separately and queue time left out.
- Reported for: Markdown-only pull requests, code pull requests, release-candidate pushes, pushes to `main`, and runs that re-test a Git tree that already passed.
- Stop criterion: a Markdown-only pull request uses no macOS minutes beyond the guardrails step, which needs macOS; the code pull request median is at most 40.8 minutes, 30% below the baseline; and no run re-tests a tree that already passed. The loop also stops when the oracle reports diminishing returns, or after five iterations.
- Scope: `.github/workflows/ci.yml`, `.github/workflows/xcode-workspace.yml`, `Scripts/ci_app_test_runner.py` and its self-test, the Makefile targets CI calls, and the Landing section of `CONTRIBUTING.md`. App code and test contents are out of scope.
- Constraint: a release candidate still needs a green hosted run on its own tip before it lands.
- Measurement: the GitHub API's run list (`repos/mplibunao/repoprompt-ce-local/actions/workflows/ci.yml/runs`) and each attempt's jobs (`actions/runs/<run>/attempts/<n>/jobs`). Each job counts when one of its runner labels starts with `macos`. A pull request run is Markdown-only when every file its pull request changes ends in `.md`. A run's tested tree is its head commit's tree for pushes, and for pull requests the merge of the head into `main` as of the run's start. Skipped jobs count zero. The medians use successful first attempts; cancelled, failed, and rerun attempts are totalled separately.

## Runs

| # | Change | Markdown-only PR | Code PR | Release-candidate push | Push to `main` | Re-tests of a passed tree | Evidence |
|---|--------|------------------|---------|------------------------|----------------|---------------------------|----------|
| 0 | Baseline: the last 40 CI runs, 42 attempts, 2,340.3 macOS minutes | 53.0 (one clean run; 5 attempts used 216.7) | median 58.3, middle half 52.8–71.2, n=16 | median 68.9, n=3 | median 85.2, n=4 | 7 runs, 436.9 minutes | Runs from 2026-10-15 to 2026-10-18. Cancelled, failed, and rerun attempts: 18, using 713.7 minutes. Example repeat: [the `main` push for #209](https://github.com/mplibunao/repoprompt-ce-local/actions/runs/39171969019), 62.8 minutes on a tree its candidate had already built. |

## Rejected candidates
