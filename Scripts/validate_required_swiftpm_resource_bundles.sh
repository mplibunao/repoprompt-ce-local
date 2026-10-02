#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
LAYOUT_LABEL="${2:-Required SwiftPM resource bundle layout}"
# Packaging validates the layout before it writes Info.plist, so it names the packaged
# executable here. Once Info.plist exists, it must declare that same executable.
EXECUTABLE_NAME="${3:-}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "Usage: $0 <app-bundle> [label] [packaged-executable-name]"

python3 - "$APP_BUNDLE" "$LAYOUT_LABEL" "$EXECUTABLE_NAME" <<'PYTHON'
import os
import plistlib
import stat
import sys
from pathlib import Path

app = Path(sys.argv[1])
label = sys.argv[2]
executable_name = sys.argv[3]
required_bundles = ["KeyboardShortcuts_KeyboardShortcuts.bundle"]
patch_marker = b"RepoPromptKeyboardShortcutsResourceLookupV1"


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_real_directory(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing required SwiftPM resource bundle directory: {path}")
    if not stat.S_ISDIR(mode):
        fail(f"required SwiftPM resource bundle path must be a real directory: {path}")


def require_regular_file(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing required SwiftPM resource bundle file: {path}")
    if not stat.S_ISREG(mode):
        fail(f"required SwiftPM resource bundle path must be a regular file: {path}")


try:
    app_root_entries = {path.name for path in app.iterdir()}
except FileNotFoundError:
    fail(f"missing app bundle: {app}")
if app_root_entries != {"Contents"}:
    fail(f"unexpected app bundle root entries: {sorted(app_root_entries ^ {'Contents'})}")

for bundle_name in required_bundles:
    bundle = app / "Contents" / "Resources" / bundle_name
    require_real_directory(bundle)
    require_regular_file(bundle / "Contents" / "Info.plist")
    require_regular_file(bundle / "Contents" / "Resources" / "en.lproj" / "Localizable.strings")

info_plist = app / "Contents" / "Info.plist"
if executable_name and not os.path.lexists(info_plist):
    declared = executable_name
else:
    require_regular_file(info_plist)
    try:
        with info_plist.open("rb") as source:
            declared = plistlib.load(source).get("CFBundleExecutable")
    except Exception as exc:
        fail(f"could not read CFBundleExecutable from {info_plist}: {exc}")
    if executable_name and declared != executable_name:
        fail(f"Info.plist declares executable {declared!r}, expected {executable_name!r}")
if not isinstance(declared, str) or not declared or declared in {".", ".."} or "/" in declared:
    fail(f"invalid packaged executable name: {declared!r}")
executable = app / "Contents" / "MacOS" / declared
require_regular_file(executable)
if patch_marker not in executable.read_bytes():
    fail(f"packaged RepoPrompt executable is missing KeyboardShortcuts resource lookup patch marker: {patch_marker.decode()}")

print(f"OK: {label} matches the required SwiftPM resource bundle policy.")
PYTHON
