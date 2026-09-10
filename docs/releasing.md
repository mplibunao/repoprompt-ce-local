# Local promotion

A promoted build is the self-signed production app at `/Applications/RepoPrompt CE.app`,
packaged from a pushed `main` commit, accepted against a live matrix, and recorded as an
annotated `local/v<version>-b<build>` tag with a GitHub Release receipt. Promote with MP
present; the previous install and its state are archived first so the step is reversible.

## Promotion procedure

Before you start:

- The [rollback unit](#rollback-unit) restore has been rehearsed at least once on this machine.
- `main` is pushed at the commit to promote, and the tracked tree is clean, so [build provenance](#build-provenance) records that commit with `dirty: false`.
- `BUILD_NUMBER` in [`version.env`](../version.env) is bumped for this build.

1. Quit the debug app and production, then archive the current install:

   ```bash
   ./Scripts/local_release_archive.sh local/v1.4.0-b37
   ```

2. Install the new build from the `main` checkout:

   ```bash
   CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make install-local-production
   ```

3. Launch production and run the [acceptance matrix](#acceptance-matrix) once from Claude
   Code and once from Codex. Confirm the bundle provenance names the promoted commit:

   ```bash
   cat "/Applications/RepoPrompt CE.app/Contents/Resources/RepoPromptProvenance.json"
   ```

4. On pass, with `main` pushed at the promoted commit, tag the build and publish the
   receipt:

   ```bash
   git tag -a local/v1.4.0-b38 -m "Local promotion: build 38"
   git push origin local/v1.4.0-b38
   gh release create local/v1.4.0-b38 \
     --repo mplibunao/repoprompt-ce-local \
     --verify-tag \
     --notes-file <receipt>
   ```

   The receipt records the promoted commit, the build number, the acceptance results, and
   the archive path. On fail, restore from the archive and keep the failed build's archive
   for diagnosis.

## Install a local self-signed production build

The command-line paths are the coordinated alias and its direct fallback:

```bash
CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production
CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make install-local-production
```

Double-clicking
[`Install RepoPrompt CE Local Production.command`](../Install%20RepoPrompt%20CE%20Local%20Production.command)
in Finder does the same thing. The Finder launcher requires Python 3, confirms replacement
of any existing installed app, runs the coordinated developer daemon, and keeps the
terminal window open so certificate approval prompts and build results stay visible.

Local production packaging requires a full Xcode installation. The installer preserves an
explicit compatible `DEVELOPER_DIR`; otherwise it uses the selected full Xcode or discovers
a compatible Xcode app for that process without changing the system-wide `xcode-select`
setting. It inventories or mints the signing identity and packages the app first, then
refuses to replace the installed app while that app is running.

The installer uses the exact identity name `RepoPrompt CE Local Self-Signed Code Signing`,
but continuity is anchored to the selected certificate's SHA-256 fingerprint rather than to
that display name. It inventories every valid private-key-backed exact-name identity. On
first use it mints and registers one identity only when no valid candidate exists, adopts
the sole candidate when exactly one exists, and refuses ambiguous duplicates. When
duplicates exist, select one explicitly:

```bash
LOCAL_SIGNING_IDENTITY_SHA256=<64-hex-fingerprint> \
  CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production
```

The versioned registry is stored at
`~/Library/Application Support/RepoPrompt CE/local-signing-identity-v1.json` with
owner-only directory and file permissions. It records the exact certificate fingerprint and
local secure-storage service generation. After a fingerprint is registered, a missing,
expired, or private-keyless identity is a hard failure; the installer never silently adopts
or mints a replacement. Packaging embeds the registered fingerprint and service generation
in signed bundle metadata, verifies the packaged leaf certificate, and prints both the
fingerprint and extracted designated requirement before replacing the installed app.
Repeated installs with the same registry therefore retain the same designated requirement
and Keychain service.

Rotation is deliberately explicit. To mint and register a new identity:

```bash
ROTATE_LOCAL_SIGNING_IDENTITY=1 \
  CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production
```

To rotate to another existing exact-name identity, combine rotation with
`LOCAL_SIGNING_IDENTITY_SHA256`. Each local Keychain service name is scoped by both the
registered certificate fingerprint and generation. First registration uses a high-entropy
generation so deleting and recreating the registry cannot predictably reconnect to an old
service; rotation increments the recorded generation instead of overwriting the prior
service, and registry loss cannot route a different certificate into an earlier identity's
service. Secrets in the prior local generation are not copied and are inaccessible to the
newly signed app; the prior certificate and service remain available for rollback or manual
re-entry. If app replacement or the atomic registry update fails, the installer restores the
prior app and leaves the prior registry authoritative.

The resulting app is host-native, self-signed, and not notarized. Do not upload it to a
GitHub Release and do not copy it to another Mac.

## Rollback unit

One archive covers everything a promotion can break: the installed app bundle, the app's
Application Support state, its preferences domain, and the local signing identity record.
Both scripts refuse to run while any RepoPrompt process holds that state, so quit
production, the debug app, and any attached CLI first.

```bash
./Scripts/local_release_archive.sh local/v1.4.0-b37
./Scripts/local_release_restore.sh local/v1.4.0-b37
```

The archive lands in `~/Archives/repoprompt-ce/<tag>/` and holds `app.zip`,
`application-support.tar.gz`, `defaults.plist`, `local-signing-identity-v1.json` when the
record exists, a `.sha256` sidecar per file, and `manifest.json`. The manifest is written
last, so its absence marks an incomplete archive and the restore refuses one. It records the
tag, timestamps, bundle identifier, version, build, signing mode, and the commit read from
the bundle's provenance file. Re-archiving over a completed archive needs
`LOCAL_RELEASE_ARCHIVE_OVERWRITE=1`.

`LOCAL_RELEASE_ARCHIVE_EXCLUDES` is a colon-separated list of top-level exclusion rules
and defaults to `DebugApps:Rollbacks:Conductor:DebugApps-*`. An entry ending in `*` matches
top-level names by prefix; every other entry matches an exact name, while matching names
below the top level remain archived. The manifest records the effective list in
`applicationSupport.excludedNames`, which restore honors when it moves excluded entries
back from the rescue copy; `Codex/` stays archived because it holds agent session history.

The restore verifies every checksum before touching anything, moves the current app and
state into a rescue directory beside the archive, extracts the archived bundle and state,
moves the excluded top-level entries back from the rescue copy, clears the preferences
domain and imports the archived one, and restores the signing identity record. It prints the
rescue directory path; remove it once the restore is confirmed good.

Rehearse the restore against the current install before the first promotion, and time it. A
rehearsal that takes more than ten minutes means the unit needs work before it is trusted as
a rollback path.

## Build provenance

Packaging writes `Contents/Resources/RepoPromptProvenance.json` into every debug and release
bundle. The manifest records the repository root, worktree path and name, branch, commit,
and build time. `dirty` reports staged or modified tracked files. `untracked_files` reports
non-ignored files outside Git tracking. `Scripts/conductor.py` reads the manifest to identify
a bundle, and the archive manifest reads the commit from it. After an install, confirm the
file names the promoted commit with `dirty: false`. The `untracked_files` field may be true
when the checkout contains local investigation files.

## Acceptance matrix

Run this against the launched production app, once from Claude Code and once from Codex.
Running it "from" a client means issuing at least one of these calls as a RepoPrompt MCP
tool call inside that client's own session: raw CLI output cannot prove client-side
selector and routing behavior.

`$CLI` is the user-space CLI link the app maintains for the release build
(`MCPFilesystemIdentity.userSpaceCLIURL()`), which resolves to the installed bundle's
`repoprompt-mcp`:

```bash
CLI="$HOME/RepoPrompt/repoprompt_ce_cli"
```

`~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli` is a legacy link to the
same executable; prefer the path above.

Use a two-root workspace with a distinct marker file per root and an existing linked
worktree. `$W1` and `$W2` are the two window IDs from the first arm. Every arm must pass:

```bash
"$CLI" -e 'windows'                                                              # two distinct window IDs
"$CLI" -w "$W1" -c manage_selection -j '{"op":"set","paths":["RootA/MarkerA.txt"]}'
"$CLI" -w "$W2" -c manage_selection -j '{"op":"set","paths":["RootB/MarkerB.txt"]}'
"$CLI" -w "$W1" -c manage_selection -j '{"op":"get","view":"files"}'              # still A only
"$CLI" -w "$W2" -c manage_selection -j '{"op":"get","view":"files"}'              # B only
"$CLI" -w "$W1" -c context_builder -j '{"instructions":"Reply with the selected marker and root.","response_type":"question"}' # answers A/RootA, never B
"$CLI" -w "$W1" -c oracle_send -j '{"message":"Reply ORACLE_OK and identify the selected root."}' # terminal ORACLE_OK, reusable chat_id
"$CLI" -w "$W1" -c agent_run -j '{"op":"start","model_id":"codexExec","message":"Reply CODEX_OK.","detach":true}'
"$CLI" -w "$W1" -c agent_run -j '{"op":"wait","session_id":"<codex session>","timeout":180}' # terminal state carrying CODEX_OK
"$CLI" -w "$W1" -c agent_run -j '{"op":"start","model_id":"claudeCode","message":"Wait for steering.","detach":true}' # returns session_id
"$CLI" -w "$W1" -c agent_run -j '{"op":"steer","session_id":"<claude session>","message":"Reply CLAUDE_STEER_OK."}'
"$CLI" -w "$W1" -c agent_run -j '{"op":"wait","session_id":"<claude session>","timeout":180}' # terminal state carrying CLAUDE_STEER_OK
"$CLI" -w "$W1" -c agent_run -j '{"op":"start","model_id":"explore","worktree":"@current","message":"Report pwd and worktree marker.","detach":true}'
"$CLI" -w "$W1" -c agent_run -j '{"op":"wait","session_id":"<explore session>","timeout":180}' # exact linked-worktree root and marker
"$CLI" -w "$W1" -c agent_manage -j '{"op":"list_sessions"}'                      # child binding and provenance exact, no orphan active run
```

One arm stays outside the script: quit production and relaunch it, then confirm the
long-running agent processes and their MCP descendants are gone and a new run starts.
Quitting a visible app needs MP's explicit approval immediately before it, so run this arm
last and only once approved.

## KeyboardShortcuts resource lookup workaround

Packaging copies the SwiftPM resource bundle to
`RepoPrompt.app/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle`, which is not
where `Bundle.module` looks. [`Scripts/package_app.sh`](../Scripts/package_app.sh) therefore
patches the pinned `KeyboardShortcuts` checkout before compilation so the package finds its
localized resources there first, and validates the packaged layout afterwards; the universal
builder applies the same patch to each architecture's isolated checkout.

The patch, the bundle copy, and the layout validator have to stay in sync. Do not remove the
workaround without confirming that **Settings → Keyboard Shortcuts** opens in a packaged app
build. A cleaner fix would make the adjusted source part of normal dependency resolution, by
upstreaming the resource lookup fix, depending on a pinned fork, or vendoring a local patched
package.

## Bundled Codex artifact

Debug and release packaging include the complete official OpenAI Codex 0.153.4 standalone
package. The authority is the repository-owned
[`Vendor/Codex/manifest.json`](../Vendor/Codex/manifest.json), which pins the official
[`rust-v0.153.4` release](https://github.com/openai/codex/releases/tag/rust-v0.153.4), the
official [`codex-package_SHA256SUMS`](https://github.com/openai/codex/releases/download/rust-v0.153.4/codex-package_SHA256SUMS),
both macOS package assets, their complete extracted layouts, file hashes, architectures, and
primary executable signing identities. The upstream release publishes SHA-256 sums but does
not document a public GPG, minisign, or SLSA verification procedure, so acquisition requires
both the fixed HTTPS release URLs and agreement between the official checksum file and the
independently pinned repository manifest.

Packaging is the only automatic acquisition boundary; the app never downloads Codex at
runtime. To acquire or inspect the cache explicitly:

```bash
make codex-acquire                         # verifies both macOS packages
make codex-acquire CODEX_ARCH=host         # current host only
make codex-status                          # offline verification of both caches
```

The verified cache lives under `.build/codex-runtime/<manifest-version>/<target>/` by default
and can be relocated with `REPOPROMPT_CODEX_CACHE_ROOT`. Ordinary host-native debug and
non-public packaging defaults to the host target and embeds one package under that target
name. Setting `REPOPROMPT_CODEX_ARCH=all` explicitly for one of those host-native lanes embeds
both target packages. Universal release-candidate lanes always select `all`, acquire and embed
both official macOS packages, and reject an explicit single-target selection.

Each intact thin package is copied to the stable target-specific layout
`Contents/Resources/BundledRuntimes/Codex/<target>/`. Ordinary host-native output contains only
its selected target directory, while explicit `REPOPROMPT_CODEX_ARCH=all` output and universal
artifacts contain both `aarch64-apple-darwin/` and `x86_64-apple-darwin/`. Runtime selection
fails closed unless the package matching the running app architecture is present. Each target
subtree preserves `codex-package.json`, `bin/codex`, `bin/codex-code-mode-host`,
`codex-resources/`, `codex-path/`, and all additional package resources; the binaries inside
remain thin and must match the directory's target architecture. The two primary macOS
executables are Developer ID signed by `OpenAI OpCo, LLC` (team `2DC432GLL2`) with hardened
runtime and timestamps. RepoPrompt's signing scripts do **not** thin, mutate, or re-sign
anything in this subtree. The outer app signature seals the resource tree, after which the
artifact verifier rechecks every byte, architecture, and upstream signature. This
mixed-authority layout passes macOS strict deep code signature verification without changing
the upstream binary hashes.

The bundled package is RepoPrompt's default Codex runtime authority; runtime selection never
falls through to the user's shell `PATH`. Advanced users may set one explicit absolute external
override with `REPOPROMPT_CODEX_EXECUTABLE`. RepoPrompt rejects overrides older than 0.149.0,
the external admission minimum, which stays deliberately below the exact bundled and
schema-gate pin at 0.153.4 because no outgoing request needs the newer version.
[`docs/architecture/codex-app-server-schema-gate.md`](architecture/codex-app-server-schema-gate.md)
owns the per-rotation schema findings behind both numbers and the limits of what admission at
the floor proves. Bundled and external runtimes both use RepoPrompt-owned `CODEX_HOME`
and `CODEX_SQLITE_HOME` directories under
`~/Library/Application Support/RepoPrompt CE/Codex/{Debug,Release}/`, leaving `~/.codex` and
official Codex App state untouched.

Within that isolated `config.toml`, RepoPrompt owns the `[mcp_servers.RepoPromptCE]`
launch/policy keys, the managed global tool-output limit, and exactly
`[features.code_mode].enabled` plus `[features.code_mode].direct_only_tool_namespaces`. It
preserves other TOML, applies repeated updates idempotently, and stops with an actionable
conflict instead of guessing when the code-mode policy is ambiguous, uses dotted or inline
definitions that would redefine the owned table/keys, or uses `non_prefixed_mcp_tool_names`.

The standalone package also contains the upstream Zsh executable at
`codex-resources/zsh/bin/zsh`. Its exact Zsh 5.9 licence is included as
[`ThirdPartyLicenses/codex/ZSH-LICENCE`](../ThirdPartyLicenses/codex/ZSH-LICENCE) and is
covered by the packaged legal inventory checksum contract.

To diagnose acquisition independently of a build, run:

```bash
python3 Scripts/codex_runtime_artifact.py acquire --arch all
python3 Scripts/codex_runtime_artifact.py verify \
  --arch aarch64-apple-darwin \
  --package .build/codex-runtime/0.153.4/aarch64-apple-darwin
python3 Scripts/codex_runtime_artifact.py stage-bundle \
  --arch all \
  --cache-root .build/codex-runtime \
  --bundle /tmp/RepoPrompt-Codex-bundle
python3 Scripts/codex_runtime_artifact.py verify-bundle \
  --arch all \
  --bundle /tmp/RepoPrompt-Codex-bundle
```

Rotate the pin only by reviewing a new official release and its checksum asset, updating every
archive and exact-tree hash in the manifest, capturing the new license/notice files, and
rerunning the offline artifact tests plus a promoted build's acceptance matrix. Never derive a
new pin from an unverified local installation.

### Guarded Codex update candidates

`Scripts/codex_update_candidate.py` prepares evidence for a possible rotation; it does not edit
or replace `Vendor/Codex/manifest.json`. Select exactly one explicit stable version/tag, or opt
in explicitly to GitHub's latest stable release:

```bash
make codex-update-candidate CODEX_CANDIDATE_VERSION=0.154.0
make codex-update-candidate CODEX_CANDIDATE_TAG=rust-v0.154.0
make codex-update-candidate CODEX_CANDIDATE_LATEST=1
```

Official mode accepts no baseline or verification-tool override: it uses the repository
manifest, `/usr/bin/lipo`, `/usr/bin/codesign`, and live official `openai/codex`
metadata/assets. `--release-json`, `--asset-dir`, or any non-default baseline/tool requires
`--fixture-mode`; that mode rejects `--latest-stable` and marks the report, manifest filename,
metadata, marker file, and provenance as a **NON-PROMOTABLE TEST FIXTURE**. Fixture provenance
records the baseline path and digest, explicit selection mode, input sources, and effective
tools so fixture evidence cannot make an official-online claim.

The tool rejects draft and prerelease releases, requires exactly one checksum asset and both
exact macOS package assets, bounds downloads to the release-declared size, bounds archive
members and total expansion, and verifies the archives against the upstream checksums. It then
uses the same artifact verifier as packaging to reject extracted-layout, Mach-O
inventory/architecture, normalized-payload, and OpenAI signing-identity drift. The official
output directory contains a proposed `candidate-manifest.json`, `candidate-provenance.json`,
sanitized `release-metadata.json`, the upstream checksum file, self-checksums, and a
deterministic `candidate-report.md`. The live 0.153.4 pin remains authoritative until a
complete rotation change is reviewed and deliberately applied.

The known-good rollback for the 0.153.4 rotation is verified Codex 0.149.0 (`rust-v0.149.0`;
arm64 package archive SHA-256
`6c7589a52fe90e3742e35662115a4c55c39715601df0d41345ba8ec8f4221d4e`, x86_64 package archive
SHA-256 `ba332e647cc898e3b4e86a3bc6e8db414a124eb88d8480f4707bbc66b0432f9d`). After a reviewed
rotation, roll back by reverting the complete rotation change and rebuilding from the restored
manifest rather than mixing old and new authority files.

The manual **Codex Runtime Update Candidate** workflow runs only from `main`, has
`contents: read`, uploads those evidence files, and cannot commit, open a pull request, or
publish a release. Local and workflow runs share the same repository-owned tool. A report is
not approval: it leaves the external override floor as an explicit policy decision and requires
review against
[`docs/architecture/codex-app-server-schema-gate.md`](architecture/codex-app-server-schema-gate.md),
license/NOTICE review, focused validation, rollback confirmation, and soak before any rotation.

## Public release train

The Developer ID, notarization, Sparkle feed, and GitHub Release publishing lane is parked
under `Scripts/parked-upstream-release/` and `.github/workflows-parked/`; each directory's
README states what a lane needs to run again.
