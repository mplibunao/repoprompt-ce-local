#!/usr/bin/env bash
# Reverse `Scripts/local_release_archive.sh <tag>`: swap the archived app bundle,
# Application Support state, preferences domain, and local signing identity record into
# place. Everything replaced is moved aside into a timestamped rescue directory that this
# script never deletes.
set -euo pipefail

# shellcheck source=Scripts/local_release_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/local_release_env.sh"

REQUIRED_ARCHIVE_FILES=("app.zip" "application-support.tar.gz" "defaults.plist")

RESCUE_DIR=""
RESCUED_ENTRY_LIST=""
report_rescue_on_failure() {
    local status=$?
    [[ -z "$RESCUED_ENTRY_LIST" ]] || rm -f "$RESCUED_ENTRY_LIST" || true
    if (( status != 0 )) && [[ -n "$RESCUE_DIR" && -d "$RESCUE_DIR" ]]; then
        printf '\nRestore did not complete. Everything moved aside is kept at:\n  %s\n' "$RESCUE_DIR" >&2
    fi
}
trap report_rescue_on_failure EXIT

resolve_release_tag "$(basename "$0")" "${1:-}"
[[ -f "$ARCHIVE_DIR/manifest.json" ]] ||
    fail "No completed archive at $ARCHIVE_DIR (manifest.json is written last and is missing)."

step "Reading manifest"
# Read the manifest into variables through a checked command substitution. A parse failure
# inside a process substitution or pipeline would be invisible to `set -e`, which would let
# the restore proceed with an empty checksum list.
MANIFEST_FIELDS="$(
    MANIFEST_PATH="$ARCHIVE_DIR/manifest.json" EXPECTED_TAG="$TAG" python3 - <<'PY'
import json
import os
import sys

path = os.environ["MANIFEST_PATH"]
try:
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    sys.exit(f"unreadable manifest {path}: {error}")
if not isinstance(manifest, dict):
    sys.exit(f"manifest {path} is not a JSON object")
if manifest.get("schemaVersion") != 1:
    sys.exit(f"manifest {path} has unsupported schemaVersion {manifest.get('schemaVersion')!r}")
if manifest.get("tag") != os.environ["EXPECTED_TAG"]:
    sys.exit(f"manifest {path} records tag {manifest.get('tag')!r}, not {os.environ['EXPECTED_TAG']!r}")


def plain_names(values, label):
    if not isinstance(values, list):
        sys.exit(f"manifest {path} field {label} is not a list")
    for value in values:
        if not isinstance(value, str) or not value or "/" in value or "\n" in value or value in (".", ".."):
            sys.exit(f"manifest {path} field {label} holds an unusable entry {value!r}")
    return values


files = manifest.get("files")
if not isinstance(files, dict) or not files:
    sys.exit(f"manifest {path} lists no archive files")
plain_names(sorted(files), "files")
state = manifest.get("applicationSupport")
if not isinstance(state, dict) or "excludedNames" not in state:
    sys.exit(f"manifest {path} is missing applicationSupport.excludedNames")
excluded = plain_names(state["excludedNames"], "applicationSupport.excludedNames")

for name in sorted(files):
    print(f"FILE\t{name}")
for name in excluded:
    print(f"EXCLUDE\t{name}")
PY
)" || fail "Refusing to restore from $ARCHIVE_DIR; its manifest is unusable."

ARCHIVE_FILES=()
EXCLUDED_STATE_NAMES=()
while IFS=$'\t' read -r kind value; do
    case "$kind" in
        FILE) ARCHIVE_FILES+=("$value") ;;
        EXCLUDE) EXCLUDED_STATE_NAMES+=("$value") ;;
        "") ;;
        *) fail "Unexpected manifest field '$kind'." ;;
    esac
done <<<"$MANIFEST_FIELDS"

(( ${#ARCHIVE_FILES[@]} > 0 )) || fail "Manifest lists no archive files; refusing to restore."
for required in "${REQUIRED_ARCHIVE_FILES[@]}"; do
    present=0
    for name in "${ARCHIVE_FILES[@]}"; do
        [[ "$name" != "$required" ]] || present=1
    done
    (( present )) || fail "Manifest does not list the required archive file $required."
done

step "Verifying archive checksums"
VERIFIED=0
for name in "${ARCHIVE_FILES[@]}"; do
    [[ -f "$ARCHIVE_DIR/$name" ]] || fail "Manifest names a missing archive file: $name"
    [[ -f "$ARCHIVE_DIR/$name.sha256" ]] || fail "Missing checksum sidecar for $name"
    (cd "$ARCHIVE_DIR" && shasum -a 256 -c "$name.sha256" >/dev/null) ||
        fail "Checksum mismatch for $name; refusing to restore from $ARCHIVE_DIR."
    VERIFIED=$((VERIFIED + 1))
done
(( VERIFIED == ${#ARCHIVE_FILES[@]} )) || fail "Verified $VERIFIED of ${#ARCHIVE_FILES[@]} archive files; refusing to restore."
printf 'Verified %d archive files.\n' "$VERIFIED"

require_no_running_repoprompt_processes "restoring"

# mktemp keeps the timestamp readable while guaranteeing a fresh directory when two
# restores of the same tag land in the same second.
RESCUE_DIR="$(mktemp -d "$ARCHIVE_DIR.rescue-$(date +%Y%m%d-%H%M%S).XXXXXX")" ||
    fail "Could not create a rescue directory next to $ARCHIVE_DIR."
printf 'Pre-restore copies are kept at %s\n' "$RESCUE_DIR"

step "Exporting current preferences into the rescue directory"
defaults export "$LOCAL_DEFAULTS_DOMAIN" "$RESCUE_DIR/defaults-before-restore.plist" || true

step "Restoring app bundle to $LOCAL_PRODUCTION_APP"
APP_PARENT="$(dirname "$LOCAL_PRODUCTION_APP")"
APP_BASENAME="$(basename "$LOCAL_PRODUCTION_APP")"
mkdir -p "$APP_PARENT"
if [[ -e "$LOCAL_PRODUCTION_APP" || -L "$LOCAL_PRODUCTION_APP" ]]; then
    mv "$LOCAL_PRODUCTION_APP" "$RESCUE_DIR/$APP_BASENAME"
fi
# `ditto -c -k --keepParent` stored the bundle at the zip root, so this lands the bundle in
# place without a staging copy.
if ! ditto -x -k "$ARCHIVE_DIR/app.zip" "$APP_PARENT"; then
    rm -rf "$LOCAL_PRODUCTION_APP"
    [[ ! -e "$RESCUE_DIR/$APP_BASENAME" ]] || mv "$RESCUE_DIR/$APP_BASENAME" "$LOCAL_PRODUCTION_APP"
    fail "Failed to extract the archived app bundle; any previous bundle was put back."
fi
[[ -d "$LOCAL_PRODUCTION_APP" ]] ||
    fail "Archive app.zip does not contain $APP_BASENAME; nothing was installed at $LOCAL_PRODUCTION_APP."

step "Restoring application support state to $LOCAL_APP_SUPPORT_DIR"
RESCUED_STATE="$RESCUE_DIR/application-support"
if [[ -e "$LOCAL_APP_SUPPORT_DIR" || -L "$LOCAL_APP_SUPPORT_DIR" ]]; then
    mv "$LOCAL_APP_SUPPORT_DIR" "$RESCUED_STATE"
fi
mkdir -p "$LOCAL_APP_SUPPORT_DIR"
tar -xzf "$ARCHIVE_DIR/application-support.tar.gz" -C "$LOCAL_APP_SUPPORT_DIR"
# Excluded top-level entries move back from the rescue copy. Manifest rules ending in
# `*` match by prefix; every other rule matches an exact file or directory name.
if [[ -d "$RESCUED_STATE" ]]; then
    step "Enumerating excluded Application Support entries"
    RESCUED_ENTRY_LIST="$(mktemp "${TMPDIR:-/tmp}/repoprompt-ce-restore-entries.XXXXXX")" ||
        fail "Could not create the excluded-entry list."
    find "$RESCUED_STATE" -mindepth 1 -maxdepth 1 -print0 >"$RESCUED_ENTRY_LIST" ||
        fail "Could not enumerate excluded entries in $RESCUED_STATE."
    while IFS= read -r -d '' entry; do
        name="${entry##*/}"
        matches_excluded_state_name "$name" "${EXCLUDED_STATE_NAMES[@]}" || continue
        rm -rf "${LOCAL_APP_SUPPORT_DIR:?}/$name"
        mv "$entry" "$LOCAL_APP_SUPPORT_DIR/$name"
    done <"$RESCUED_ENTRY_LIST"
    rm -f "$RESCUED_ENTRY_LIST"
    RESCUED_ENTRY_LIST=""
fi

step "Importing preferences domain $LOCAL_DEFAULTS_DOMAIN"
# `defaults import` merges, so the domain is cleared first: a rollback must not leave keys
# the newer build introduced. The rescue export above is the recovery copy.
defaults delete "$LOCAL_DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
if ! defaults import "$LOCAL_DEFAULTS_DOMAIN" "$ARCHIVE_DIR/defaults.plist"; then
    if [[ -f "$RESCUE_DIR/defaults-before-restore.plist" ]]; then
        defaults import "$LOCAL_DEFAULTS_DOMAIN" "$RESCUE_DIR/defaults-before-restore.plist" || true
    fi
    fail "Failed to import archived preferences into $LOCAL_DEFAULTS_DOMAIN."
fi

if [[ -f "$ARCHIVE_DIR/local-signing-identity-v1.json" ]]; then
    step "Restoring local signing identity record"
    mkdir -p "$(dirname "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH")"
    chmod 700 "$(dirname "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH")"
    cp -p "$ARCHIVE_DIR/local-signing-identity-v1.json" "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
    chmod 600 "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
fi

printf '\nRestored %s from %s\n' "$TAG" "$ARCHIVE_DIR"
printf 'Replaced app bundle and state kept at %s (remove it when the restore is confirmed good).\n' "$RESCUE_DIR"
