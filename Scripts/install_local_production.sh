#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=Scripts/local_release_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/local_release_env.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SOURCE_ROOT="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$ROOT_DIR}"
cd "$ROOT_DIR"

# `prepare` is the only writer of this path and `install-prepared` its only reader.
PREPARED_ROOT="$RELEASE_SOURCE_ROOT/.build/local-production"
PREPARED_APP="$PREPARED_ROOT/$APP_NAME.app"

LOCAL_SIGNING_TEAM_ID="${LOCAL_SIGNING_TEAM_ID:-}"
ROTATE_LOCAL_SIGNING_IDENTITY="${ROTATE_LOCAL_SIGNING_IDENTITY:-0}"
LOCAL_SIGNING_IDENTITY_TOOL="$ROOT_DIR/Scripts/local_signing_identity.py"
FULL_XCODE_RESOLVER="$ROOT_DIR/Scripts/resolve_full_xcode_developer_dir.sh"
TMP_DIR=""
STAGED_DIR=""
STAGED_APP=""
BACKUP_DIR=""
BACKUP_APP=""
PREPARE_STAGING_DIR=""
REGISTRY_LOCK_DIR=""
REGISTRY_BACKUP_PATH=""
REGISTRY_EXISTED=0
REGISTRY_MUTATION_STARTED=0
PRESERVE_TRANSACTION_SNAPSHOT=0
TRANSACTION_ACTIVE=0
APP_BACKED_UP=0
APP_INSTALLED=0
SPLIT_MODE_SIGNING_REFUSAL="Split preparation requires an existing Apple Development signing registry and an unchanged Keychain service. Complete first-use setup or explicit rotation with the combined installer, then prepare again."

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
    # Removed whatever the status: it never holds the published bundle, and a signal can
    # leave the status at 0.
    [[ -z "$PREPARE_STAGING_DIR" ]] || rm -rf "$PREPARE_STAGING_DIR"
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

rotation_requested() {
    [[ "$ROTATE_LOCAL_SIGNING_IDENTITY" == "1" || "$ROTATE_LOCAL_SIGNING_IDENTITY" == "true" ]]
}

resolve_signing_environment() {
    DEVELOPER_DIR="$("$FULL_XCODE_RESOLVER")"
    export DEVELOPER_DIR
    printf 'Local production Xcode developer directory: %s\n' "$DEVELOPER_DIR"

    LOGIN_KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
    [[ -n "$LOGIN_KEYCHAIN" && -f "$LOGIN_KEYCHAIN" ]] || fail "Could not resolve the user's default login keychain."
}

acquire_registry_lock() {
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
}

set_local_signing_requirement() {
    LOCAL_SIGNING_REQUIREMENT="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$RESOLVED_SIGNING_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
}

plan_signing_identity() {
    INVENTORY_PATH="$TMP_DIR/identity-inventory.json"
    PLAN_PATH="$TMP_DIR/identity-plan.json"

    inventory_local_identities "$INVENTORY_PATH"
    PLAN_ARGS=(
        "$LOCAL_SIGNING_IDENTITY_TOOL" plan
        --inventory "$INVENTORY_PATH"
        --registry "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH"
    )
    [[ -z "$LOCAL_SIGNING_TEAM_ID" ]] || PLAN_ARGS+=(--team "$LOCAL_SIGNING_TEAM_ID")
    if rotation_requested; then
        PLAN_ARGS+=(--rotate)
    fi
    python3 "${PLAN_ARGS[@]}" > "$PLAN_PATH"

    IDENTITY_ACTION="$(json_field "$PLAN_PATH" action)"
    SIGN_IDENTITY="$(json_field "$PLAN_PATH" candidate.sha1)"
    SIGNING_CERTIFICATE_NAME="$(json_field "$PLAN_PATH" candidate.commonName)"
    RESOLVED_SIGNING_TEAM_ID="$(json_field "$PLAN_PATH" teamIdentifier)"
    LOCAL_KEYCHAIN_SERVICE="$(json_field "$PLAN_PATH" keychainService)"
    REGISTRY_NEEDS_WRITE="$(json_field "$PLAN_PATH" registryNeedsWrite)"
    set_local_signing_requirement
}

# The prepared install signs nothing, so it takes the team and Keychain service from the
# registry. A signing plan could create a new Keychain service, as adoption and rotation do.
read_registered_signing_identity() {
    local record="$TMP_DIR/registry-record.json"
    local selected_team
    python3 "$LOCAL_SIGNING_IDENTITY_TOOL" read-registry --path "$LOCAL_SIGNING_IDENTITY_REGISTRY_PATH" > "$record" ||
        fail "$SPLIT_MODE_SIGNING_REFUSAL"
    RESOLVED_SIGNING_TEAM_ID="$(json_field "$record" teamIdentifier)"
    LOCAL_KEYCHAIN_SERVICE="$(json_field "$record" keychainService)"
    if [[ -n "$LOCAL_SIGNING_TEAM_ID" ]]; then
        # Normalized as the signing plan normalizes --team, so a selector the other modes accept
        # matches here too.
        selected_team="$(python3 -c 'import sys; print(sys.argv[1].strip().upper())' "$LOCAL_SIGNING_TEAM_ID")"
        [[ "$selected_team" == "$RESOLVED_SIGNING_TEAM_ID" ]] ||
            fail "LOCAL_SIGNING_TEAM_ID=$LOCAL_SIGNING_TEAM_ID differs from the registered team $RESOLVED_SIGNING_TEAM_ID. $SPLIT_MODE_SIGNING_REFUSAL"
    fi
    REGISTRY_NEEDS_WRITE=0
    set_local_signing_requirement
}

announce_signing_plan() {
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

    printf 'Local signing identity action: %s\n' "$IDENTITY_ACTION"
    printf 'Selected signing certificate: %s\n' "$SIGNING_CERTIFICATE_NAME"
    printf 'Selected local signing team: %s\n' "$RESOLVED_SIGNING_TEAM_ID"
    printf 'Selected local Keychain service: %s\n' "$LOCAL_KEYCHAIN_SERVICE"
}

package_release_app() {
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
}

prepared_bundle_mismatch() {
    fail "Prepared app provenance, version, or signing does not match this checkout and registry: $1. Prepare again; nothing was installed."
}

# Checks a copy of the prepared bundle against RELEASE_SOURCE_ROOT and the signing identity in
# RESOLVED_SIGNING_TEAM_ID and LOCAL_KEYCHAIN_SERVICE, the globals LOCAL_SIGNING_REQUIREMENT is
# built from. The signature seals Info.plist and the provenance file, so once it verifies,
# every value read below is the signed one. Sets DESIGNATED_REQUIREMENT.
verify_prepared_bundle() {
    local app="$1"
    local team="$RESOLVED_SIGNING_TEAM_ID"
    local service="$LOCAL_KEYCHAIN_SERVICE"
    local info="$app/Contents/Info.plist"
    local provenance="$app/Contents/Resources/RepoPromptProvenance.json"
    local head_commit versions marketing_version build_number

    # With -R, codesign runs the full verification and also tests the requirement.
    codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$app" ||
        prepared_bundle_mismatch "the signature does not verify against the team $team requirement"
    DESIGNATED_REQUIREMENT="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')" ||
        prepared_bundle_mismatch "its designated requirement could not be read"
    grep -F -- "$team" <<< "$DESIGNATED_REQUIREMENT" >/dev/null ||
        prepared_bundle_mismatch "its designated requirement is not anchored to team $team"

    [[ "$(plutil -extract RepoPromptSigningMode raw "$info" 2>/dev/null)" == "local-apple-development" ]] ||
        prepared_bundle_mismatch "it is not marked as a local Apple Development build"
    [[ "$(plutil -extract RepoPromptLocalSigningTeamIdentifier raw "$info" 2>/dev/null)" == "$team" ]] ||
        prepared_bundle_mismatch "its signing team is not $team"
    [[ "$(plutil -extract RepoPromptLocalKeychainService raw "$info" 2>/dev/null)" == "$service" ]] ||
        prepared_bundle_mismatch "its Keychain service is not $service"

    head_commit="$(git -C "$RELEASE_SOURCE_ROOT" rev-parse HEAD)" ||
        prepared_bundle_mismatch "the HEAD of $RELEASE_SOURCE_ROOT could not be read"
    [[ "$(json_field "$provenance" version 2>/dev/null)" == "1" ]] ||
        prepared_bundle_mismatch "its provenance is missing or is not version 1"
    [[ "$(json_field "$provenance" commit 2>/dev/null)" == "$head_commit" ]] ||
        prepared_bundle_mismatch "its provenance commit is not HEAD $head_commit"
    [[ "$(json_field "$provenance" dirty 2>/dev/null)" == "0" ]] ||
        prepared_bundle_mismatch "its provenance does not record a clean worktree"
    [[ "$(json_field "$provenance" git_status 2>/dev/null)" == "ok" ]] ||
        prepared_bundle_mismatch "its provenance git_status is not ok"

    # load_release_metadata runs in the command substitution's subshell, which leaves the
    # control-plane values that set paths and guards unchanged.
    # shellcheck disable=SC2153  # load_release_metadata assigns both
    versions="$(load_release_metadata "$RELEASE_SOURCE_ROOT" && printf '%s %s\n' "$MARKETING_VERSION" "$BUILD_NUMBER")" ||
        prepared_bundle_mismatch "$RELEASE_SOURCE_ROOT/version.env could not be read"
    read -r marketing_version build_number <<< "$versions"
    [[ "$(plutil -extract CFBundleShortVersionString raw "$info" 2>/dev/null)" == "$marketing_version" ]] ||
        prepared_bundle_mismatch "its version is not $marketing_version from version.env"
    [[ "$(plutil -extract CFBundleVersion raw "$info" 2>/dev/null)" == "$build_number" ]] ||
        prepared_bundle_mismatch "its build is not $build_number from version.env"
}

# Verifies a copy beside the fixed path and then renames it into place. An interrupted run
# leaves the fixed path absent or holding a complete bundle, the previous one or the new one.
publish_prepared_app() {
    rm -rf "$PREPARED_ROOT/$APP_NAME.app.preparing."*
    mkdir -p "$PREPARED_ROOT"
    PREPARE_STAGING_DIR="$(mktemp -d "$PREPARED_ROOT/$APP_NAME.app.preparing.XXXXXX")"
    ditto "$SOURCE_APP" "$PREPARE_STAGING_DIR/$APP_NAME.app"
    verify_prepared_bundle "$PREPARE_STAGING_DIR/$APP_NAME.app"
    if [[ -e "$PREPARED_APP" || -L "$PREPARED_APP" ]]; then
        mv "$PREPARED_APP" "$PREPARE_STAGING_DIR/previous.app"
    fi
    mv "$PREPARE_STAGING_DIR/$APP_NAME.app" "$PREPARED_APP"
    rm -rf "$PREPARE_STAGING_DIR"
    PREPARE_STAGING_DIR=""

    printf 'Prepared local production app: %s\n' "$PREPARED_APP"
    printf 'Prepared commit: %s\n' "$(json_field "$PREPARED_APP/Contents/Resources/RepoPromptProvenance.json" commit)"
}

stage_for_install() {
    local source_app="$1"
    local guard_action="$2"
    require_production_app_stopped "$guard_action"
    mkdir -p "$LOCAL_PRODUCTION_INSTALL_DIR"
    STAGED_DIR="$(mktemp -d "$LOCAL_PRODUCTION_INSTALL_DIR/.$DISPLAY_NAME.app.installing.XXXXXX")"
    STAGED_APP="$STAGED_DIR/$DISPLAY_NAME.app"
    ditto "$source_app" "$STAGED_APP"
}

# Swaps the verified staged app in. From the transaction start until the registry check
# passes, a failure restores the prior app, and the registry when this run wrote it.
replace_installed_app() {
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
}

# No argument: build, sign, and install in one run with production quit throughout.
# `prepare`: build, sign, and publish $PREPARED_APP while production may run.
# `install-prepared`: install $PREPARED_APP without building.
case "$#:${1:-}" in
    0:) INSTALL_MODE="combined" ;;
    1:prepare | 1:install-prepared) INSTALL_MODE="$1" ;;
    *) fail "Usage: install_local_production.sh [prepare|install-prepared]" ;;
esac

if [[ "$INSTALL_MODE" != "combined" ]] && rotation_requested; then
    fail "$SPLIT_MODE_SIGNING_REFUSAL"
fi

case "$INSTALL_MODE" in
    combined)
        [[ "${CONFIRM_LOCAL_PRODUCTION_INSTALL:-}" == "1" ]] ||
            fail "Set CONFIRM_LOCAL_PRODUCTION_INSTALL=1 to build and replace the local production app in $LOCAL_PRODUCTION_INSTALL_DIR."
        REQUIRED_COMMANDS=(codesign ditto openssl plutil python3 security swift)
        ;;
    prepare)
        REQUIRED_COMMANDS=(codesign ditto git openssl plutil python3 security swift)
        ;;
    install-prepared)
        [[ "${CONFIRM_LOCAL_PRODUCTION_INSTALL:-}" == "1" ]] ||
            fail "Set CONFIRM_LOCAL_PRODUCTION_INSTALL=1 to replace the local production app in $LOCAL_PRODUCTION_INSTALL_DIR with the prepared build."
        REQUIRED_COMMANDS=(codesign ditto git plutil python3)
        ;;
esac

for command in "${REQUIRED_COMMANDS[@]}"; do
    require_command "$command"
done
[[ -f "$LOCAL_SIGNING_IDENTITY_TOOL" ]] || fail "Missing local signing identity tool: $LOCAL_SIGNING_IDENTITY_TOOL"
if [[ "$INSTALL_MODE" != "install-prepared" ]]; then
    [[ -x "$FULL_XCODE_RESOLVER" ]] || fail "Missing full-Xcode resolver: $FULL_XCODE_RESOLVER"
fi

case "$INSTALL_MODE" in
    combined)
        # The running-app check repeats at each boundary a long build or staging copy could let
        # production reopen across. Each is a point-in-time observation, not a lock: production
        # must stay quit for the whole install.
        require_production_app_stopped "building a replacement for $LOCAL_PRODUCTION_APP"
        resolve_signing_environment
        acquire_registry_lock
        plan_signing_identity
        announce_signing_plan
        package_release_app
        stage_for_install "$SOURCE_APP" "staging the replacement for $LOCAL_PRODUCTION_APP"
        codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
        codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$STAGED_APP"
        replace_installed_app
        ;;
    prepare)
        # Preparation installs nothing and writes no registry, so production may keep running.
        resolve_signing_environment
        acquire_registry_lock
        plan_signing_identity
        [[ "$IDENTITY_ACTION" == "use" && "$REGISTRY_NEEDS_WRITE" == "0" ]] || fail "$SPLIT_MODE_SIGNING_REFUSAL"
        announce_signing_plan
        package_release_app
        publish_prepared_app
        ;;
    install-prepared)
        acquire_registry_lock
        read_registered_signing_identity
        [[ -d "$PREPARED_APP" ]] ||
            fail "No prepared local production app at $PREPARED_APP. Run make dev-prepare-local-production (or make prepare-local-production) first; nothing was installed."
        stage_for_install "$PREPARED_APP" "staging the prepared build for $LOCAL_PRODUCTION_APP"
        verify_prepared_bundle "$STAGED_APP"
        replace_installed_app
        ;;
esac
