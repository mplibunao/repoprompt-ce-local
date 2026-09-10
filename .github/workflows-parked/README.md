# Workflow reference

GitHub runs workflow files only from `.github/workflows/`. The files here don't run.

| File | Purpose | Requirements to run again |
| --- | --- | --- |
| `pr-gate.yml` | Checks new or reopened pull requests using `.github/APPROVED_CONTRIBUTORS`. It closes submissions from users who aren't approved. | Move it to `.github/workflows/`, maintain the contributor file, and grant read access to contents plus write access to issues and pull requests. |
| `issue-gate.yml` | Checks new or reopened issues using `.github/APPROVED_CONTRIBUTORS`. It closes submissions from users who aren't approved. | Move it to `.github/workflows/`, maintain the contributor file, and grant read access to contents plus write access to issues. |
| `approve-contributor.yml` | Handles maintainer `lgtm` and `lgtmi` comments. It updates contributor capabilities on the default branch. | Move it to `.github/workflows/`, run the contributor gates, keep `.github/APPROVED_CONTRIBUTORS` current, and grant write access to contents and issues. |
| `main-tip.yml` | Runs the Tip build and public update flow, including Apple signing and notarization. | Move it to `.github/workflows/`; restore the Tip release helper to its expected path or update the workflow path; configure an owned update repository; and provide the required Apple, Sparkle, Sentry, and GitHub credentials. |
| `release.yml` | Builds approved tagged source and creates a signed, notarized draft release with a smoke test. | Move it to `.github/workflows/`; restore `verify_release_ref.sh` to its expected path or update the workflow path; and provide the required Apple, Sparkle, Sentry, and GitHub configuration. |
| `release-promote.yml` | Checks reviewed draft assets before publishing them to the stable public update channel. | Move it to `.github/workflows/`; restore `verify_release_ref.sh` and `promote_release.sh` to their expected paths or update the workflow paths; configure owned source and update repositories; and provide the required GitHub, Sparkle, and Sentry credentials. |
