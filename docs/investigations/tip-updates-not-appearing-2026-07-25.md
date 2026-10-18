# Investigation: Tip updates not appearing (2026-07-25)

> Investigation report, observed 2026-07-25 on the official app at Tip build `1.1.0 (31.11.42)`. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary

RepoPrompt is behaving as designed. Installed build `1.1.0 (31.11.42)`
exactly matches the latest published Tip from `f56b2c0c…`. The only newer
`main` merge, `679fc3a0…`, failed CI, so automatic Tip publication was skipped.
Restarting is not required for discovery: the running app polls passively every
12 hours when enabled, and Check for Updates performs an immediate manual check.
Passive discovery appears through in-app affordances rather than necessarily
opening a modal window.

## Symptoms
- RepoPrompt prompted for an update after switching from the local debug build to the official app, and the installed update appeared to be a Tip build.
- Subsequent PRs have merged into `main`, but the desktop app has not shown further update prompts.
- It is unclear whether RepoPrompt must be restarted to discover Tip updates.

## Background / Prior Research

The 2026-07-24 investigation established that the ordinary automatic Tip path
runs only after the named `CI` workflow succeeds on `main`, not immediately when
a pull request merges. An authorized manual workflow dispatch can bypass that
prior CI-success gate for a commit reachable from protected `main`, but the build
must still complete staging, signing, notarization, packaged smoke testing, and
publication. The app selects a separate Sparkle feed when
`RepoPromptUpdateChannel` is `tip`.

### Live app and installed bundle

- The About dialog reports `RepoPrompt CE Version 1.1.0 (31.11.42)`.
- Settings → Updates shows Tip Builds selected, automatic update checks enabled,
  and “You have the latest version.”
- A manual Check for Updates returned “You’re up to date.”
- `/Applications/RepoPrompt CE.app/Contents/Info.plist` identifies the release
  bundle as `com.pvncher.repoprompt.ce`, version `1.1.0`, build `31.11.42`.
- The build-number scheme encodes Tip sequence 1142 as `31.11.42`; the installed
  build is therefore a Tip build.
- `~/Library/Preferences/com.pvncher.repoprompt.ce.plist` contains
  `RepoPromptUpdateChannel = "tip"` and
  `RepoPromptPassiveAppcastChecksEnabled = true`.
- Sparkle-owned `SULastCheckTime` records a manual-path update check at
  `2026-07-25 06:04:15 UTC`. RepoPrompt's passive scheduler separately uses
  `SparkleLastUpdateCheck`. No pending-relaunch marker exists.

### Upstream publication state

- Current `main` is `679fc3a0d7579886a55b8dc2be4f9f3c576d1a1b`, the merge
  of upstream PR 613 on 2026-07-24 at 15:58 UTC.
- The latest published Tip is `tip-f56b2c0c9bfe`, source commit
  `f56b2c0c9bfe60942ef39a2cba5ea86510d86f7d`, version/build
  `1.1.0 (31.11.42)`, published on 2026-07-24 at 09:45 UTC.
- Upstream PR 613 is the only merge after the published Tip.
- CI run `30107511214` for upstream PR 613's merge commit failed in an app-test shard
  and the style-tool installation job.
- Publish Tip run `30108685633` was skipped after that failed CI run.
- No newer Tip build is pending or published. The installed build exactly matches
  the latest appcast.

## Investigator Findings

### Verdict

The observed behavior is expected; the available evidence does **not** identify an
updater defect. There was no newer published Tip for the installed app to offer,
and passive discovery intentionally publishes update state into the app UI rather
than opening Sparkle's modal update window.

1. **Restart is not required for discovery — confirmed, with settings caveats.**
   The release app starts the updater during `applicationDidFinishLaunching`
   (`Sources/RepoPrompt/App/AppDelegate.swift:103-116`). Startup schedules a passive
   appcast check after three seconds and installs the periodic scheduler
   (`Sources/RepoPrompt/App/Sparkle/SparkleUpdateManager.swift:173-190`). With
   automatic checks enabled, the scheduler checks immediately when its last
   successful passive check is absent or at least 12 hours old, then every 12 hours
   while the app is running (`SparkleUpdateManager.swift:206-257`). A manual Check
   for Updates is independently available and calls Sparkle directly
   (`SparkleUpdateManager.swift:615-647`;
   `Sources/RepoPrompt/Features/Settings/Views/General/LicenseUpdatesSettingsView.swift:23-42`).
   Changing channel also persists immediately, resets the update cycle, and
   reschedules discovery (`SparkleUpdateManager.swift:598-612`), so it does not
   require a restart. Practical caveat: launch and periodic passive checks require
   `RepoPromptPassiveAppcastChecksEnabled`; with it disabled, use the manual action.
   A Tip published just after a successful passive check may wait until the next
   12-hour poll, so the manual action is the immediate path. Channel changes reset
   and reschedule discovery but do not necessarily fetch immediately because
   `SparkleLastUpdateCheck` is shared across channels.

2. **Installed `1.1.0 (31.11.42)` exactly matched the latest published Tip at the
   investigation snapshot — confirmed.** The selected channel is persisted under
   `RepoPromptUpdateChannel`, and `.tip` selects the separate Tip feed
   (`Sources/RepoPrompt/App/Sparkle/UpdateChannel.swift:4-8,28-48`;
   `Sources/RepoPrompt/Infrastructure/Security/SecurityObfuscation.swift:9-14,30-32`).
   The live bundle/build and appcast evidence above agree with the latest release,
   [`tip-f56b2c0c9bfe`](https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/tag/tip-f56b2c0c9bfe),
   whose source commit is `f56b2c0c9bfe60942ef39a2cba5ea86510d86f7d`
   and build is `31.11.42`. The workflow derives a Tip build number from the stable
   build plus the selected main commit's revision count
   (`.github/workflows/main-tip.yml:54-82`), and release tooling rejects an appcast
   whose `sparkle:version` differs from that exact Tip build
   (`Scripts/main_tip_release.sh:261-335`). The updater compares numeric Sparkle
   build numbers before marketing versions (`SparkleUpdateManager.swift:392-459`),
   so equal `31.11.42` correctly means no update.

3. **The only newer main merge was absent from Tip because automatic publication
   was gated off by failed CI — confirmed.** CI runs on pushes to `main`
   (`.github/workflows/ci.yml:1-7`). Publish Tip listens for completed main CI runs,
   but its setup job runs automatically only when the CI conclusion is `success`
   (`.github/workflows/main-tip.yml:1-8,23-28`). The recorded
   [CI run `30107511214`](https://github.com/repoprompt/repoprompt-ce/actions/runs/30107511214)
   for `679fc3a` failed in Style and app-test shard 2; downstream
   [Publish Tip run `30108685633`](https://github.com/repoprompt/repoprompt-ce/actions/runs/30108685633)
   was therefore skipped. The dependency chain is explicit: secret-free stage
   (`main-tip.yml:114-163`) → sign/notarize (`main-tip.yml:165-310`) → secret-free
   packaged smoke (`main-tip.yml:312-359`) → appcast publication
   (`main-tip.yml:361-396`). Signing notarizes and staples the app and DMG, generates
   and cryptographically validates the appcast, and publication requires every
   resulting asset (`Scripts/main_tip_release.sh:337-449`). Corrected scope: this is
   the **automatic** gate; an intentional `workflow_dispatch` is allowed to bypass
   the prior CI-success condition (`main-tip.yml:8-13,23-28`), but no such newer
   publication is present in the captured evidence.

4. **Passive discovery uses in-app affordances, not a modal prompt — confirmed.**
   Passive checks fetch and parse the appcast directly; only user-initiated checks
   invoke Sparkle UI (`SparkleUpdateManager.swift:239-310,615-647`). A newer build
   becomes `availableUpdate` state (`SparkleUpdateManager.swift:392-429,567-583`).
   That state reveals a blue install pill in the main toolbar
   (`Sources/RepoPrompt/Infrastructure/UI/Components/UpdateAvailableToolbarPill.swift:35-83`;
   `Sources/RepoPrompt/App/Views/ContentViewToolbarContent.swift:34-37`), changes the
   app menu to Install Update (`Sources/RepoPrompt/App/Sparkle/UpdateMenu.swift:18-35`),
   and adds an install action/status in Settings
   (`LicenseUpdatesSettingsView.swift:23-45`). Clicking one of those affordances
   starts Sparkle's release-notes/install flow. Therefore “no modal prompt” after a
   background poll is not evidence that discovery failed.

### Practical caveats

- `SULastCheckTime` is not the passive scheduler's timestamp. RepoPrompt records
  successful passive fetch/parse checks under `SparkleLastUpdateCheck`
  (`SparkleUpdateManager.swift:95-102,239-257`), while the observed manual Sparkle
  check can account for `SULastCheckTime`. Inspect the RepoPrompt key when diagnosing
  passive scheduling specifically.
- The 12-hour poll uses a run-loop timer and may be delayed by sleep, process
  suspension, or run-loop blockage. Failed passive fetch/parse attempts do not
  advance the successful-check timestamp; later periodic checks, the next enabled
  launch check, or a manual check can retry
  (`SparkleUpdateManager.swift:183-190,239-257`).
- Installing an available update still requires Sparkle to restart the application;
  that installation restart is separate from discovery
  (`SparkleUpdateManager.swift:545-550`).

### Maintainer-guidance check

- **User impact/invariant:** a passing, published build newer than the installed
  build must become discoverable without requiring an app restart.
- **Root-cause confidence / authority:** confirmed from the installed/appcast/Actions
  evidence plus `SparkleUpdateManager` and `main-tip.yml`, the owning runtime and
  publication authorities.
- **Recommended scope:** no product-code fix. Treat the missing modal as expected UI;
  re-investigate only if a strictly newer Tip appcast exists and neither the passive
  affordances nor a manual Sparkle check detects it.

## Investigation Log

### Initial assessment
**Hypotheses:**
1. The official app is not currently configured for the Tip channel.
2. Recent `main` merges have not produced a newer Tip release because CI or the Tip publishing workflow is pending or failing.
3. Sparkle checks on a schedule and the app has not polled since a newer Tip release became available.
4. The installed Tip build is already the newest published build.

**Verification plan:**
1. Inspect the live app's displayed channel, version, and update status without changing settings.
2. Trigger the app's ordinary Check for Updates action and observe whether it reports current, offers an update, or errors.
3. Independently compare the installed bundle version/build and embedded update-feed configuration with the latest published Tip appcast/release.
4. Trace the updater and GitHub workflow code to establish whether launch/restart is required and how merges map to published Tip builds.

## Root Cause

There is no updater-discovery failure. The apparent discrepancy came from
treating a merge to `main` as equivalent to a published Tip and from expecting
passive checks to open Sparkle's modal UI. The sole newer merge failed required
CI, its automatic Publish Tip run was skipped, and no newer signed appcast item
existed to discover.

## Recommendations

1. Do not restart or reinstall for the current incident.
2. Use Check for Updates for immediate discovery after a publication is expected.
3. Verify the exact commit's CI and Publish Tip runs before diagnosing the desktop
   updater.
4. Treat merge, passing CI, successful Tip publication, and desktop discovery as
   separate states.
5. If a strictly newer appcast is proven but a manual check still reports the
   installed build as current, confirm Tip Builds is selected, relaunch once as
   recovery, and report an updater defect with the installed build, appcast build,
   channel, and check time if the mismatch remains.

## Preventive Measures

- Diagnose missing Tip updates in this order: exact-commit CI, Publish Tip
  workflow, published appcast build, installed build, then desktop discovery.
- Use the build number rather than only the marketing version when comparing Tip
  builds; multiple Tips can share marketing version `1.1.0`.
- Treat the blue toolbar pill, Settings status, and app-menu install action as
  successful passive discovery even when no modal prompt appears.
