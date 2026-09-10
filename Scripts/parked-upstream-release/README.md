# Upstream release script reference

The scripts here contain the hosted Tip and stable release flows. Local production targets don't call them.

| File | Purpose | Requirements to run again |
| --- | --- | --- |
| `main_tip_release.sh` | Runs Tip asset staging, Apple signing and notarization, validation, and publication. | Restore it beside the live release helpers or update its control-plane paths; provide a Tip release policy, an owned update repository, and the required Apple, Sparkle, Sentry, and GitHub credentials. |
| `promote_release.sh` | Checks reviewed draft assets and publishes the stable update release with deployment metadata. | Restore it beside the live release helpers or update its control-plane paths; configure owned source and update repositories; and provide reviewed checksums plus GitHub, Sparkle, and Sentry credentials. |
| `publish_public_update_test.sh` | Checks a signed, notarized app archive and publishes a public updater smoke release with a generated Sparkle feed. | Restore it beside the live release helpers or update its paths; provide a signed artifact and manifest, an owned public update repository, a Sparkle signing key, GitHub credentials, and explicit publication confirmation. |
| `verify_release_ref.sh` | Resolves a canonical release tag and verifies that its commit is reachable from protected `main`. | Restore it at the path expected by the hosted release workflows or update those workflow paths; provide the tag plus either the local `origin/main` refs or GitHub repository credentials. |
| `test_publish_tip_release.py` | Hermetic process-level tests cover Tip release publication and workflow integration. | Restore the Tip workflow and companion scripts to the relative paths expected by the test, or update its fixture paths before adding it back to `release-selftest`. |
