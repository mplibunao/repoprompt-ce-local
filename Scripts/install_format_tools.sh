#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-status}"

if (( $# > 1 )); then
    echo "ERROR: Expected one subcommand." >&2
    exit 2
fi

case "$ACTION" in
    --help|-h)
        cat <<'EOF'
Usage: ./Scripts/install_format_tools.sh [status|check|install|resolve-swiftformat|resolve-swiftlint]

SwiftFormat and SwiftLint versions are pinned in mise.toml.

  status               Print availability and versions without installing anything.
  check                Fail if either pinned tool is missing.
  install              Install both pinned tools through mise, then verify them.
  resolve-swiftformat  Print the pinned SwiftFormat executable path.
  resolve-swiftlint    Print the pinned SwiftLint executable path.
EOF
        exit 0
        ;;
    status|check|install|resolve-swiftformat|resolve-swiftlint) ;;
    *) echo "ERROR: Unknown subcommand: $ACTION" >&2; exit 2 ;;
esac

fail(){ echo "ERROR: $*" >&2; exit 1; }

if ! command -v mise >/dev/null 2>&1; then
    echo "ERROR: Missing required tool: mise. Install mise, then run 'make dev-install-format-tools'." >&2
    [[ "$ACTION" == status ]] && exit 0
    exit 1
fi

resolve_tool(){
    local tool="$1" backend path
    case "$tool" in
        swiftformat) backend="github:nicklockwood/SwiftFormat" ;;
        swiftlint) backend="aqua:realm/SwiftLint" ;;
    esac
    # `mise which` can fall back to global tools when the requested version is missing.
    path="$(mise -C "$ROOT_DIR" where "$backend")/$tool" || return
    [[ -x "$path" ]] || return 1
    printf '%s\n' "$path"
}

print_status(){
    local tool path
    echo "Swift style tools from mise.toml"
    for tool in swiftformat swiftlint; do
        if path="$(resolve_tool "$tool" 2>/dev/null)"; then
            printf '  %s: %s (%s)\n' "$tool" "$("$path" --version)" "$path"
        else
            printf '  %s: missing; run make dev-install-format-tools\n' "$tool"
        fi
    done
}

check_tools(){
    local tool
    for tool in swiftformat swiftlint; do
        resolve_tool "$tool" >/dev/null 2>&1 ||
            fail "Missing required tool: $tool from mise.toml. Run 'make dev-install-format-tools'."
    done
}

case "$ACTION" in
    status) print_status ;;
    check) check_tools ;;
    install)
        echo "Installing Swift style tools from mise.lock..."
        mise -C "$ROOT_DIR" install --locked --quiet github:nicklockwood/SwiftFormat aqua:realm/SwiftLint
        check_tools
        print_status
        ;;
    resolve-*)
        resolve_tool "${ACTION#resolve-}" ||
            fail "Missing required tool: ${ACTION#resolve-} from mise.toml. Run 'make dev-install-format-tools'."
        ;;
esac
