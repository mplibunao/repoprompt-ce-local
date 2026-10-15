#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=Scripts/local_release_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/local_release_env.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SOURCE_ROOT="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$ROOT_DIR}"
cd "$ROOT_DIR"

LOCAL_SIGNING_TEAM_ID="${LOCAL_SIGNING_TEAM_ID:-}"
ROTATE_LOCAL_SIGNING_IDENTITY="${ROTATE_LOCAL_SIGNING_IDENTITY:-0}"
LOCAL_SIGNING_IDENTITY_TOOL="$ROOT_DIR/Scripts/local_signing_identity.py"
FULL_XCODE_RESOLVER="$ROOT_DIR/Scripts/resolve_full_xcode_developer_dir.sh"
TMP_DIR=""
STAGED_DIR=""
STAGED_APP=""
BACKUP_DIR=""
BACKUP_APP=""
REGISTRY_LOCK_DIR=""
REGISTRY_BACKUP_PATH=""
REGISTRY_EXISTED=0
REGISTRY_MUTATION_STARTED=0
PRESERVE_TRANSACTION_SNAPSHOT=0
TRANSACTION_ACTIVE=0
APP_BACKED_UP=0
APP_INSTALLED=0

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if (( status != 0 && TRANSACTION_ACTIVE )); then
        rollback_transaction || status=1
    fi
    if [[ -n "$TMP_DIR" ]]; then
        if (( PRESERVE_TRANSACTION_SNAPSHOT )); then
            printf 'ERROR: Preserving failed transaction snapshot for manual recovery: %s\n' "$TMP_DIR" >&2
        else
            rm -rf "$TMP_DIR"
        fi
    fi
    [[ -z "$STAGED_DIR" ]] || rm -rf "$STAGED_DIR"
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        printf 'WARNING: Preserving prior app backup after rollback failure: %s\n' "$BACKUP_APP" >&2
    fi
    [[ -z "$BACKUP_DIR" ]] || rmdir "$BACKUP_DIR" 2>/dev/null || true
    if [[ -n "$REGISTRY_LOCK_DIR" ]]; then
        rm -f "$REGISTRY_LOCK_DIR/pid"
        rmdir "$REGISTRY_LOCK_DIR" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT

json_field() {
    local path="$1"
    local expression="$2"
    python3 - "$path" "$expression" <<'PY'
import json
import sys

value = json.loads(open(sys.argv[1], encoding="utf-8").read())
for component in sys.argv[2].split("."):
    value = value[component]
if isinstance(value, bool):
    print("1" if value else "0")
elif value is not None:
    print(value)
PY
}

inventory_local_identities() {
    local output="$1"
    local -a args=(
        "$LOCAL_SIGNING_IDENTITY_TOOL" inventory
        --keychain "$LOGIN_KEYCHAIN"
    )
    if [[ -n "${LOCAL_SIGNING_IDENTITY_INVENTORY_FIXTURE:-}" ]]; then
        args+=(--fixture "$LOCAL_SIGNING_IDENTITY_INVENTORY_FIXTURE")
    fi
    if [[ -n "${LOCAL_SIGNING_IDENTITY_EVALUATED_AT:-}" ]]; then
        args+=(--at "$LOCAL_SIGNING_IDENTITY_EVALUATED_AT")
    fi
    python3 "${args[@]}" > "$output"
}

rollback_transaction() {
    local rollback_failed=0
    if (( APP_INSTALLED )); then
        rm -rf "$LOCAL_PRODUCTION_APP" || {
            printf 'ERROR: Could not remove failed installed app during rollback: %s\n' "$LOCAL_PRODUCTION_APP" >&2
            rollback_failed=1
        }
        APP_INSTALLED=0
    fi
    if (( APP_BACKED_UP )); then
        if [[ -e "$LOCAL_PRODUCTION_APP" || -L "$LOCAL_PRODUCTION_APP" ]]; then
            rm -rf "$LOCAL_PRODUCTION_APP" || rollback_failed=1
        fi
        if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
            mv "$BACKUP_APP" "$LOCAL_PRODUCTION_APP" || {
                printf 'ERROR: Could not restore prior app from backup: %s\n' "$BACKUP_APP" >&2
                rollback_failed=1
            }
            if [[ -e "$LOCAL_PRODUCTION_APP" ]]; then
                APP_BACKED_UP=0
                BACKUP_APP=""
            fi
        else
            printf 'ERROR: Prior app backup is missing during rollback.\n' >&2
            rollback_failed=1
        fi
    fi
    if [[ "${REGISTRY_NEEDS_WRITE:-0}" == "1" && "$REGISTRY_MUTATION_STARTED" == "1" ]]; then
        if (( REGISTRY_EXISTED )); then
            local registry_restore_path
            registry_restore_path="$(dirname "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH")/.$(basename "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH").rollback.$$"
            rm -f "$registry_restore_path"
            if [[ ! -f "$REGISTRY_BACKUP_PATH" ]]; then
                printf 'ERROR: Prior registry snapshot is missing during rollback.\n' >&2
                rollback_failed=1
                PRESERVE_TRANSACTION_SNAPSHOT=1
            elif ! cp -p "$REGISTRY_BACKUP_PATH" "$registry_restore_path" ||
                ! mv -f "$registry_restore_path" "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
            then
                rm -f "$registry_restore_path"
                printf 'ERROR: Could not atomically restore prior local signing registry.\n' >&2
                rollback_failed=1
                PRESERVE_TRANSACTION_SNAPSHOT=1
            fi
        else
            rm -f "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" || {
                printf 'ERROR: Could not remove newly created local signing registry.\n' >&2
                rollback_failed=1
            }
        fi
    fi
    TRANSACTION_ACTIVE=0
    return "$rollback_failed"
}

[[ "${CONFIRM_LOCAL_PRODUCTION_INSTALL:-}" == "1" ]] ||
    fail "Set CONFIRM_LOCAL_PRODUCTION_INSTALL=1 to build and replace the local production app in $LOCAL_PRODUCTION_INSTALL_DIR."

for command in codesign ditto openssl plutil python3 security swift; do
    require_command "$command"
done
[[ -f "$LOCAL_SIGNING_IDENTITY_TOOL" ]] || fail "Missing local signing identity tool: $LOCAL_SIGNING_IDENTITY_TOOL"
[[ -x "$FULL_XCODE_RESOLVER" ]] || fail "Missing full-Xcode resolver: $FULL_XCODE_RESOLVER"

# The running-app check repeats at each boundary a long build or staging copy could let
# production reopen across. Each is a point-in-time observation, not a lock: production
# must stay quit for the whole install.
require_production_app_stopped "building a replacement for $LOCAL_PRODUCTION_APP"

DEVELOPER_DIR="$("$FULL_XCODE_RESOLVER")"
export DEVELOPER_DIR
printf 'Local production Xcode developer directory: %s\n' "$DEVELOPER_DIR"

LOGIN_KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
[[ -n "$LOGIN_KEYCHAIN" && -f "$LOGIN_KEYCHAIN" ]] || fail "Could not resolve the user's default login keychain."

TMP_DIR="$(mktemp -d)"
mkdir -p "$(dirname "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH")"
chmod 700 "$(dirname "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH")"
REGISTRY_LOCK_CANDIDATE="$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH.lock"
mkdir "$REGISTRY_LOCK_CANDIDATE" 2>/dev/null || fail "Another local production install is active, or a stale lock must be inspected: $REGISTRY_LOCK_CANDIDATE"
REGISTRY_LOCK_DIR="$REGISTRY_LOCK_CANDIDATE"
chmod 700 "$REGISTRY_LOCK_DIR"
printf '%s\n' "$$" > "$REGISTRY_LOCK_DIR/pid"
chmod 600 "$REGISTRY_LOCK_DIR/pid"
REGISTRY_BACKUP_PATH="$TMP_DIR/local-signing-identity-registry.backup"
INVENTORY_PATH="$TMP_DIR/identity-inventory.json"
PLAN_PATH="$TMP_DIR/identity-plan.json"

inventory_local_identities "$INVENTORY_PATH"
PLAN_ARGS=(
    "$LOCAL_SIGNING_IDENTITY_TOOL" plan
    --inventory "$INVENTORY_PATH"
    --registry "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
)
[[ -z "$LOCAL_SIGNING_TEAM_ID" ]] || PLAN_ARGS+=(--team "$LOCAL_SIGNING_TEAM_ID")
if [[ "$ROTATE_LOCAL_SIGNING_IDENTITY" == "1" || "$ROTATE_LOCAL_SIGNING_IDENTITY" == "true" ]]; then
    PLAN_ARGS+=(--rotate)
fi
python3 "${PLAN_ARGS[@]}" > "$PLAN_PATH"

IDENTITY_ACTION="$(json_field "$PLAN_PATH" action)"
SIGN_IDENTITY="$(json_field "$PLAN_PATH" candidate.sha1)"
SIGNING_CERTIFICATE_NAME="$(json_field "$PLAN_PATH" candidate.commonName)"
RESOLVED_SIGNING_TEAM_ID="$(json_field "$PLAN_PATH" teamIdentifier)"
LOCAL_KEYCHAIN_SERVICE="$(json_field "$PLAN_PATH" keychainService)"
REGISTRY_NEEDS_WRITE="$(json_field "$PLAN_PATH" registryNeedsWrite)"

case "$IDENTITY_ACTION" in
    rotate)
        printf 'WARNING: Rotating the local signing identity makes secrets in the prior local Keychain service inaccessible to the new app.\n' >&2
        printf 'WARNING: The prior Keychain service is preserved for rollback; values are not copied automatically.\n' >&2
        ;;
    adopt-from-self-signed)
        printf 'Local production builds are now signed by Apple Development team %s.\n' "$RESOLVED_SIGNING_TEAM_ID"
        printf 'Stored secrets stay in the Keychain service that self-signed builds used.\n'
        printf 'On the first launch, macOS asks once for each stored secret. Choose Always Allow so later builds read them without asking.\n'
        ;;
esac

LOCAL_SIGNING_REQUIREMENT="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$RESOLVED_SIGNING_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
printf 'Local signing identity action: %s\n' "$IDENTITY_ACTION"
printf 'Selected signing certificate: %s\n' "$SIGNING_CERTIFICATE_NAME"
printf 'Selected local signing team: %s\n' "$RESOLVED_SIGNING_TEAM_ID"
printf 'Selected local Keychain service: %s\n' "$LOCAL_KEYCHAIN_SERVICE"

LOCAL_PRODUCTION_RELEASE=1 \
    LOCAL_SIGNING_TEAM_ID="$RESOLVED_SIGNING_TEAM_ID" \
    LOCAL_KEYCHAIN_SERVICE="$LOCAL_KEYCHAIN_SERVICE" \
    SIGN_IDENTITY="$SIGN_IDENTITY" \
    "$ROOT_DIR/Scripts/package_app.sh" release

SOURCE_APP="$RELEASE_SOURCE_ROOT/.build/release/$APP_NAME.app"
[[ -d "$SOURCE_APP" ]] || fail "Missing packaged local production app: $SOURCE_APP"
[[ "$(plutil -extract RepoPromptSigningMode raw "$SOURCE_APP/Contents/Info.plist")" == "local-apple-development" ]] ||
    fail "Packaged app is missing the local Apple Development signing-mode marker."
[[ "$(plutil -extract RepoPromptLocalSigningTeamIdentifier raw "$SOURCE_APP/Contents/Info.plist")" == "$RESOLVED_SIGNING_TEAM_ID" ]] ||
    fail "Packaged app local signing team metadata does not match the selected team."
[[ "$(plutil -extract RepoPromptLocalKeychainService raw "$SOURCE_APP/Contents/Info.plist")" == "$LOCAL_KEYCHAIN_SERVICE" ]] ||
    fail "Packaged app local Keychain service metadata does not match the registry plan."
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$SOURCE_APP"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$SOURCE_APP" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$DESIGNATED_REQUIREMENT" ]] || fail "Could not extract the packaged app designated requirement."
grep -F -- "$RESOLVED_SIGNING_TEAM_ID" <<< "$DESIGNATED_REQUIREMENT" >/dev/null ||
    fail "Packaged app designated requirement is not anchored to the selected team."
printf 'Packaged designated requirement: %s\n' "$DESIGNATED_REQUIREMENT"

require_production_app_stopped "staging the replacement for $LOCAL_PRODUCTION_APP"
mkdir -p "$LOCAL_PRODUCTION_INSTALL_DIR"
STAGED_DIR="$(mktemp -d "$LOCAL_PRODUCTION_INSTALL_DIR/.$DISPLAY_NAME.app.installing.XXXXXX")"
STAGED_APP="$STAGED_DIR/$DISPLAY_NAME.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$STAGED_APP"
printf 'Installing team %s build with designated requirement: %s\n' "$RESOLVED_SIGNING_TEAM_ID" "$DESIGNATED_REQUIREMENT"
if [[ "$REGISTRY_NEEDS_WRITE" == "1" ]]; then
    if [[ -e "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" ]]; then
        cp -p "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" "$REGISTRY_BACKUP_PATH"
        REGISTRY_EXISTED=1
    fi
fi
require_production_app_stopped "replacing $LOCAL_PRODUCTION_APP"
TRANSACTION_ACTIVE=1
if [[ -e "$LOCAL_PRODUCTION_APP" ]]; then
    BACKUP_DIR="$(mktemp -d "$LOCAL_PRODUCTION_INSTALL_DIR/.$DISPLAY_NAME.app.backup.XXXXXX")"
    BACKUP_APP="$BACKUP_DIR/$DISPLAY_NAME.app"
    mv "$LOCAL_PRODUCTION_APP" "$BACKUP_APP"
    APP_BACKED_UP=1
fi
mv "$STAGED_APP" "$LOCAL_PRODUCTION_APP"
APP_INSTALLED=1
STAGED_APP=""
rmdir "$STAGED_DIR"
STAGED_DIR=""

if [[ "$REGISTRY_NEEDS_WRITE" == "1" ]]; then
    REGISTRY_MUTATION_STARTED=1
    if ! python3 "$LOCAL_SIGNING_IDENTITY_TOOL" write-registry \
        --path "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" \
        --team "$RESOLVED_SIGNING_TEAM_ID" \
        --keychain-service "$LOCAL_KEYCHAIN_SERVICE" >/dev/null
    then
        fail "Could not atomically update the local signing identity registry; transaction will restore the prior app and registry."
    fi
fi
python3 "$LOCAL_SIGNING_IDENTITY_TOOL" read-registry --path "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" >/dev/null ||
    fail "Installed app continuity registry could not be verified; transaction will restore the prior app and registry."
TRANSACTION_ACTIVE=0

if [[ -n "$BACKUP_APP" ]]; then
    rm -rf "$BACKUP_APP"
    rmdir "$BACKUP_DIR"
    BACKUP_APP=""
    BACKUP_DIR=""
    APP_BACKED_UP=0
fi
APP_INSTALLED=0

printf 'Installed local production app: %s\n' "$LOCAL_PRODUCTION_APP"
printf 'Registered local signing team: %s\n' "$RESOLVED_SIGNING_TEAM_ID"
printf 'Local Keychain service: %s\n' "$LOCAL_KEYCHAIN_SERVICE"
printf 'This app is local-only, not notarized, and must not be distributed or uploaded to GitHub Releases.\n'
