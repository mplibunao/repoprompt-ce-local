#!/usr/bin/env bash
# Capture the rollback unit for one promoted local build: the installed app bundle, the
# app's Application Support state, its preferences domain, and the local signing identity
# record. `Scripts/local_release_restore.sh` consumes what this writes.
set -euo pipefail

# shellcheck source=Scripts/local_release_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/local_release_env.sh"

LOCAL_RELEASE_ARCHIVE_OVERWRITE="${LOCAL_RELEASE_ARCHIVE_OVERWRITE:-0}"
# Top-level Application Support entries left out of the state tarball. A trailing `*`
# matches names by prefix; every other rule is an exact name.
IFS=':' read -r -a EXCLUDED_STATE_NAMES <<<"${LOCAL_RELEASE_ARCHIVE_EXCLUDES:-DebugApps:Rollbacks:Conductor:DebugApps-*}"

APP_ARCHIVE_NAME="app.zip"
STATE_ARCHIVE_NAME="application-support.tar.gz"
DEFAULTS_ARCHIVE_NAME="defaults.plist"
IDENTITY_ARCHIVE_NAME="local-signing-identity-v1.json"

resolve_release_tag "$(basename "$0")" "${1:-}"
MANIFEST_PATH="$ARCHIVE_DIR/manifest.json"

[[ -d "$LOCAL_PRODUCTION_APP" ]] || fail "No installed app bundle at $LOCAL_PRODUCTION_APP."
[[ -d "$LOCAL_APP_SUPPORT_DIR" ]] || fail "No application support directory at $LOCAL_APP_SUPPORT_DIR."
require_no_running_repoprompt_processes "archiving"
if [[ -e "$MANIFEST_PATH" && "$LOCAL_RELEASE_ARCHIVE_OVERWRITE" != "1" ]]; then
    fail "Archive $ARCHIVE_DIR already holds a manifest. Set LOCAL_RELEASE_ARCHIVE_OVERWRITE=1 to replace it."
fi

# An explicit operand list confines exclusion matching to top-level entries and keeps
# identically named nested content in the archive.
ENTRY_LIST="$(mktemp "${TMPDIR:-/tmp}/repoprompt-ce-archive-entries.XXXXXX")"
trap 'rm -f "$ENTRY_LIST"' EXIT
find "$LOCAL_APP_SUPPORT_DIR" -mindepth 1 -maxdepth 1 -print0 >"$ENTRY_LIST" ||
    fail "Could not enumerate $LOCAL_APP_SUPPORT_DIR."
TAR_OPERANDS=()
while IFS= read -r -d '' entry; do
    base="${entry##*/}"
    matches_excluded_state_name "$base" "${EXCLUDED_STATE_NAMES[@]}" || TAR_OPERANDS+=("./$base")
done <"$ENTRY_LIST"
(( ${#TAR_OPERANDS[@]} > 0 )) || fail "Every top-level entry of $LOCAL_APP_SUPPORT_DIR is excluded; nothing to archive."

mkdir -p "$ARCHIVE_DIR"
# manifest.json is written last, so its absence marks an incomplete archive and the restore
# side can refuse one without a separate completion flag.
rm -f "$MANIFEST_PATH"

step "Archiving app bundle from $LOCAL_PRODUCTION_APP"
rm -f "$ARCHIVE_DIR/$APP_ARCHIVE_NAME"
ditto -c -k --keepParent "$LOCAL_PRODUCTION_APP" "$ARCHIVE_DIR/$APP_ARCHIVE_NAME"

step "Archiving application support state (excluding top-level ${EXCLUDED_STATE_NAMES[*]})"
rm -f "$ARCHIVE_DIR/$STATE_ARCHIVE_NAME"
tar -czf "$ARCHIVE_DIR/$STATE_ARCHIVE_NAME" -C "$LOCAL_APP_SUPPORT_DIR" "${TAR_OPERANDS[@]}"

step "Exporting preferences domain $LOCAL_DEFAULTS_DOMAIN"
rm -f "$ARCHIVE_DIR/$DEFAULTS_ARCHIVE_NAME"
defaults export "$LOCAL_DEFAULTS_DOMAIN" "$ARCHIVE_DIR/$DEFAULTS_ARCHIVE_NAME"

IDENTITY_ARCHIVED=0
rm -f "$ARCHIVE_DIR/$IDENTITY_ARCHIVE_NAME" "$ARCHIVE_DIR/$IDENTITY_ARCHIVE_NAME.sha256"
if [[ -f "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" ]]; then
    step "Archiving local signing identity record"
    # The record is public identity metadata (certificate name, leaf SHA-256, service
    # generation) and the private key stays in the Keychain, so it is copied whole. Refuse
    # the copy if a future schema ever carries key material.
    IDENTITY_PATH="$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" python3 - <<'PY'
import json
import os
import sys

path = os.environ["IDENTITY_PATH"]
with open(path, encoding="utf-8") as handle:
    record = json.load(handle)
if not isinstance(record, dict):
    sys.exit(f"ERROR: {path} is not a JSON object.")
forbidden = ("privatekey", "secret", "password", "passphrase", "pkcs12", "p12", "pem", "keydata")
offending = sorted(key for key in record if any(token in key.lower() for token in forbidden))
if offending:
    sys.exit(f"ERROR: refusing to archive {path}; it carries key material fields: {offending}")
PY
    cp -p "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" "$ARCHIVE_DIR/$IDENTITY_ARCHIVE_NAME"
    chmod 600 "$ARCHIVE_DIR/$IDENTITY_ARCHIVE_NAME"
    IDENTITY_ARCHIVED=1
else
    printf 'No local signing identity record at %s; recording it as absent.\n' \
        "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
fi

step "Writing checksums and manifest"
(
    cd "$ARCHIVE_DIR"
    for name in "$APP_ARCHIVE_NAME" "$STATE_ARCHIVE_NAME" "$DEFAULTS_ARCHIVE_NAME"; do
        shasum -a 256 "$name" >"$name.sha256"
    done
    if (( IDENTITY_ARCHIVED )); then
        shasum -a 256 "$IDENTITY_ARCHIVE_NAME" >"$IDENTITY_ARCHIVE_NAME.sha256"
    fi
)

ARCHIVE_TAG="$TAG" \
    ARCHIVE_DIR="$ARCHIVE_DIR" \
    ARCHIVE_APP_PATH="$LOCAL_PRODUCTION_APP" \
    ARCHIVE_STATE_PATH="$LOCAL_APP_SUPPORT_DIR" \
    ARCHIVE_DEFAULTS_DOMAIN="$LOCAL_DEFAULTS_DOMAIN" \
    ARCHIVE_IDENTITY_PATH="$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" \
    ARCHIVE_IDENTITY_PRESENT="$IDENTITY_ARCHIVED" \
    ARCHIVE_EXCLUDES="$(printf '%s\n' ${EXCLUDED_STATE_NAMES[@]+"${EXCLUDED_STATE_NAMES[@]}"})" \
    python3 - <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import json
import os
import plistlib
import time

archive_dir = Path(os.environ["ARCHIVE_DIR"])
app_path = Path(os.environ["ARCHIVE_APP_PATH"])


def info_plist_value(key: str) -> str | None:
    try:
        with (app_path / "Contents" / "Info.plist").open("rb") as handle:
            value = plistlib.load(handle).get(key)
    except (OSError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, str) else None


def bundle_provenance() -> dict | None:
    path = app_path / "Contents" / "Resources" / "RepoPromptProvenance.json"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def checksum(name: str) -> str | None:
    sidecar = archive_dir / f"{name}.sha256"
    if not sidecar.is_file():
        return None
    return sidecar.read_text(encoding="utf-8").split(maxsplit=1)[0]


files = ["app.zip", "application-support.tar.gz", "defaults.plist"]
if os.environ["ARCHIVE_IDENTITY_PRESENT"] == "1":
    files.append("local-signing-identity-v1.json")

provenance = bundle_provenance()
now = time.time()
manifest = {
    "schemaVersion": 1,
    "tag": os.environ["ARCHIVE_TAG"],
    "archivedAtEpoch": now,
    "archivedAtISO": datetime.fromtimestamp(now, timezone.utc).astimezone().isoformat(timespec="seconds"),
    "app": {
        "sourcePath": str(app_path),
        "bundleIdentifier": info_plist_value("CFBundleIdentifier"),
        "shortVersion": info_plist_value("CFBundleShortVersionString"),
        "build": info_plist_value("CFBundleVersion"),
        "signingMode": info_plist_value("RepoPromptSigningMode"),
        # An installed bundle may not carry the provenance file; the commit is null then.
        "commit": (provenance or {}).get("commit"),
        "provenanceBuildTimeISO": (provenance or {}).get("buildTimeISO"),
    },
    "applicationSupport": {
        "sourcePath": os.environ["ARCHIVE_STATE_PATH"],
        "excludedNames": [name for name in os.environ["ARCHIVE_EXCLUDES"].splitlines() if name],
    },
    "defaults": {"domain": os.environ["ARCHIVE_DEFAULTS_DOMAIN"]},
    "localSigningIdentity": {
        "sourcePath": os.environ["ARCHIVE_IDENTITY_PATH"],
        "archived": os.environ["ARCHIVE_IDENTITY_PRESENT"] == "1",
    },
    "files": {name: {"sha256": checksum(name), "bytes": (archive_dir / name).stat().st_size} for name in files},
}
(archive_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Manifest: {archive_dir / 'manifest.json'}")
print(f"  build {manifest['app']['build']}  commit {manifest['app']['commit']}")
PY

printf '\nArchived %s to %s\n' "$TAG" "$ARCHIVE_DIR"
