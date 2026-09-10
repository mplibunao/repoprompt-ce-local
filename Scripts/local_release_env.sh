#!/usr/bin/env bash
# Shared environment for the local release rollback unit: the locations an archive covers,
# the live-process guard, and the tag contract. Sourced by local_release_archive.sh and
# local_release_restore.sh.

LOCAL_RELEASE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_RELEASE_ROOT_DIR="$(cd "$LOCAL_RELEASE_SCRIPTS_DIR/.." && pwd)"

# shellcheck source=Scripts/load_release_metadata.sh
source "$LOCAL_RELEASE_SCRIPTS_DIR/load_release_metadata.sh"
# APP_NAME, DISPLAY_NAME and BUNDLE_ID feed pgrep patterns and mv/rm paths below, so they
# come from the validating loader rather than a raw `source version.env`.
load_release_metadata "$LOCAL_RELEASE_ROOT_DIR"

LOCAL_PRODUCTION_INSTALL_DIR="${LOCAL_PRODUCTION_INSTALL_DIR:-/Applications}"
LOCAL_PRODUCTION_APP="${LOCAL_PRODUCTION_APP:-$LOCAL_PRODUCTION_INSTALL_DIR/$DISPLAY_NAME.app}"
LOCAL_APP_SUPPORT_DIR="${LOCAL_APP_SUPPORT_DIR:-$HOME/Library/Application Support/$DISPLAY_NAME}"
LOCAL_DEFAULTS_DOMAIN="${LOCAL_DEFAULTS_DOMAIN:-$BUNDLE_ID}"
LOCAL_RELEASE_ARCHIVE_ROOT="${LOCAL_RELEASE_ARCHIVE_ROOT:-$HOME/Archives/repoprompt-ce}"
LOCAL_SIGNING_IDENTITY_REGISTRY_PATH="${LOCAL_SIGNING_IDENTITY_REGISTRY_PATH:-$LOCAL_APP_SUPPORT_DIR/local-signing-identity-v1.json}"
# Command-line fragments that mark a live RepoPrompt process. Overridable for the same
# reason the paths above are: so the scripts can be exercised against a non-production
# target without matching the operator's real app.
IFS=':' read -r -a RUNNING_PROCESS_PATTERNS <<<"${LOCAL_RELEASE_RUNNING_PROCESS_PATTERNS:-/$DISPLAY_NAME.app/Contents/MacOS/$APP_NAME:DebugApps/$APP_NAME.app/Contents/MacOS/$APP_NAME:repoprompt-mcp:repoprompt_ce_cli}"
# When set, `step` aborts at the start of the first step whose message contains this text.
# It exists so a test can stop a run part-way and inspect what the script left behind.
LOCAL_RELEASE_ABORT_AT_STEP="${LOCAL_RELEASE_ABORT_AT_STEP:-}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$*"
    if [[ -n "$LOCAL_RELEASE_ABORT_AT_STEP" && "$*" == *"$LOCAL_RELEASE_ABORT_AT_STEP"* ]]; then
        fail "Aborting at step '$*' (LOCAL_RELEASE_ABORT_AT_STEP)."
    fi
}

# Refuses while anything that writes the app's state is alive: the production bundle under
# any install root, the debug bundle, the MCP server, or a CLI attached to either.
require_no_running_repoprompt_processes() {
    local action="$1"
    local pattern pid found=""
    for pattern in ${RUNNING_PROCESS_PATTERNS[@]+"${RUNNING_PROCESS_PATTERNS[@]}"}; do
        [[ -n "$pattern" ]] || continue
        for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
            [[ "$pid" != "$$" ]] || continue
            found+="  $pid  $(ps -o command= -p "$pid" 2>/dev/null | head -1)"$'\n'
        done
    done
    [[ -z "$found" ]] || fail "Quit RepoPrompt before $action; these processes hold its state:"$'\n'"$found"
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
