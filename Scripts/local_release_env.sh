#!/usr/bin/env bash
# Shared environment for the local release rollback unit: the locations an archive covers,
# the live-process guards, and the tag contract. Sourced by local_release_archive.sh,
# local_release_restore.sh, and install_local_production.sh.

LOCAL_RELEASE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_RELEASE_ROOT_DIR="$(cd "$LOCAL_RELEASE_SCRIPTS_DIR/.." && pwd)"

# shellcheck source=Scripts/load_release_metadata.sh
source "$LOCAL_RELEASE_SCRIPTS_DIR/load_release_metadata.sh"
# APP_NAME, DISPLAY_NAME and BUNDLE_ID feed the process guards and mv/rm paths below, so
# they come from the validating loader rather than a raw `source version.env`.
load_release_metadata "$LOCAL_RELEASE_ROOT_DIR"

LOCAL_PRODUCTION_INSTALL_DIR="${LOCAL_PRODUCTION_INSTALL_DIR:-/Applications}"
LOCAL_PRODUCTION_APP="${LOCAL_PRODUCTION_APP:-$LOCAL_PRODUCTION_INSTALL_DIR/$DISPLAY_NAME.app}"
LOCAL_PRODUCTION_EXECUTABLE="$LOCAL_PRODUCTION_APP/Contents/MacOS/$APP_NAME"
LOCAL_APP_SUPPORT_DIR="${LOCAL_APP_SUPPORT_DIR:-$HOME/Library/Application Support/$DISPLAY_NAME}"
LOCAL_DEFAULTS_DOMAIN="${LOCAL_DEFAULTS_DOMAIN:-$BUNDLE_ID}"
LOCAL_RELEASE_ARCHIVE_ROOT="${LOCAL_RELEASE_ARCHIVE_ROOT:-$HOME/Archives/repoprompt-ce}"
LOCAL_SIGNING_IDENTITY_REGISTRY_PATH="${LOCAL_SIGNING_IDENTITY_REGISTRY_PATH:-$LOCAL_APP_SUPPORT_DIR/local-signing-identity-v1.json}"
LOCAL_RELEASE_PROCESS_TOOL="$LOCAL_RELEASE_SCRIPTS_DIR/debug_app_process.py"
# A nonempty JSON array of absolute executable paths. When set, the archive/restore guard
# blocks on exactly those executables instead of every RepoPrompt identity, so the scripts
# can be exercised against a non-production target without matching the operator's real
# app. The production installer never reads it.
LOCAL_RELEASE_GUARD_EXECUTABLES_JSON="${LOCAL_RELEASE_GUARD_EXECUTABLES_JSON:-}"
# When set, `step` aborts at the start of the first step whose message contains this text.
# It exists so a test can stop a run part-way and inspect what the script left behind.
LOCAL_RELEASE_ABORT_AT_STEP="${LOCAL_RELEASE_ABORT_AT_STEP:-}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# A trailing `*` is a prefix rule for top-level Application Support names. Other rules
# match one exact name, so shell pattern characters elsewhere have no special meaning.
matches_excluded_state_name() {
    local candidate="$1"
    shift
    local rule prefix
    for rule in "$@"; do
        if [[ "$rule" == *\* ]]; then
            prefix="${rule%\*}"
            [[ "$candidate" == "$prefix"* ]] && return 0
        elif [[ "$candidate" == "$rule" ]]; then
            return 0
        fi
    done
    return 1
}

step() {
    printf '\n==> %s\n' "$*"
    if [[ -n "$LOCAL_RELEASE_ABORT_AT_STEP" && "$*" == *"$LOCAL_RELEASE_ABORT_AT_STEP"* ]]; then
        fail "Aborting at step '$*' (LOCAL_RELEASE_ABORT_AT_STEP)."
    fi
}

# Command-line matching cannot see the running app on current macOS, so a regex setting
# would silently guard nothing; refuse it rather than reinterpret it.
[[ -z "${LOCAL_RELEASE_RUNNING_PROCESS_PATTERNS:-}" ]] ||
    fail "LOCAL_RELEASE_RUNNING_PROCESS_PATTERNS is no longer supported because processes are identified by executable path; unset it. To guard archive or restore on specific executables, set LOCAL_RELEASE_GUARD_EXECUTABLES_JSON to a JSON array of absolute paths; the production installer ignores that setting."

# Runs the read-only native guard. Exit 0 is clear and 3 lists the blocking processes;
# anything else means identity could not be established, which is not evidence that
# RepoPrompt is stopped.
run_repoprompt_process_guard() {
    local action="$1"
    shift
    local blocking status=0
    blocking="$(python3 "$LOCAL_RELEASE_PROCESS_TOOL" guard "$@")" || status=$?
    case "$status" in
        0) ;;
        3) fail "Quit $DISPLAY_NAME before $action; these processes hold its state:"$'\n'"$blocking" ;;
        *) fail "Could not confirm that $DISPLAY_NAME is stopped before $action; process identity inspection failed." ;;
    esac
}

# Refuses while anything that writes the app's state is alive: the production bundle under
# any install root, a debug bundle, or the MCP server inside either, including a CLI link
# that resolves to it.
require_no_running_repoprompt_processes() {
    local action="$1"
    if [[ -n "$LOCAL_RELEASE_GUARD_EXECUTABLES_JSON" ]]; then
        run_repoprompt_process_guard "$action" exact \
            --executables-json "$LOCAL_RELEASE_GUARD_EXECUTABLES_JSON"
    else
        run_repoprompt_process_guard "$action" release-state \
            --production-executable "$LOCAL_PRODUCTION_EXECUTABLE" \
            --app-name "$APP_NAME" \
            --display-name "$DISPLAY_NAME" \
            --support-dir "$LOCAL_APP_SUPPORT_DIR"
    fi
}

# Refuses while the configured production executable is running. Other installs, debug
# apps, and bundled helpers do not hold the bundle being replaced.
require_production_app_stopped() {
    run_repoprompt_process_guard "$1" production \
        --production-executable "$LOCAL_PRODUCTION_EXECUTABLE"
}

# Validates the tag and sets TAG and ARCHIVE_DIR for the caller. Tags may contain slashes
# (`local/v1.4.0-b37` nests under the archive root) but must not escape it.
resolve_release_tag() {
    local usage="$1"
    TAG="${2:-}"
    [[ -n "$TAG" ]] || fail "Usage: $usage <tag>"
    [[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "Refusing unsafe tag: $TAG"
    [[ "$TAG" != *".."* && "$TAG" != */ ]] || fail "Refusing unsafe tag: $TAG"
    # shellcheck disable=SC2034  # read by the sourcing script, not here
    ARCHIVE_DIR="$LOCAL_RELEASE_ARCHIVE_ROOT/$TAG"
}
