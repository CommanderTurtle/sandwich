#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
projects="${HERMES_PROJECTS_DIR:-$HOME/Hermes}"
localflame="${LOCALFLAME_ROOT:-$HOME/Deepseek/localflame}"
action="${1:-check}"
strict=0
dry_run=0

usage() {
    cat <<'EOF'
Usage: sandwich integrations check [--strict] [--dry-run]
       sandwich integrations reconcile [--strict] [--dry-run]
       sandwich integrations update [--strict] [--dry-run]

Run each installed integration through the scripts committed by its owning
repository. `check` runs doctors only, `reconcile` reapplies registrations and
then doctors them, and `update` runs each owner's updater followed by its
doctor. Missing optional owners are reported; --strict makes them an error.

No command in this path contacts Firecrawl or starts a model.
EOF
}

case "$action" in
    check|reconcile|update) shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

while (($#)); do
    case "$1" in
        --strict) strict=1 ;;
        --dry-run) dry_run=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export DO_NOT_TRACK=1
export CI=1
export PATH="$root/bin:$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"

owners=(
    localflame
    hermes-workspace
    context-mode
    camofox-browser
    camofox-mcp
    codebase-memory-mcp
    librarian
    leetcoder
    retrieval
    persephone
)

owner_root() {
    case "$1" in
        localflame) printf '%s\n' "$localflame" ;;
        camofox-browser) printf '%s\n' "$projects/camofox/camofox-browser" ;;
        *) printf '%s\n' "$projects/$1" ;;
    esac
}

owner_script() {
    local owner="$1"
    local requested="$2"
    case "$owner:$requested" in
        localflame:check) printf '%s\n' doctor.sh ;;
        localflame:reconcile) printf '%s\n' install.sh ;;
        localflame:update) printf '%s\n' update.sh ;;
        hermes-workspace:check|context-mode:check|camofox-browser:check|camofox-mcp:check)
            printf '%s\n' audit.sh
            ;;
        librarian:check|leetcoder:check|retrieval:check)
            printf '%s\n' doctor.sh
            ;;
        hermes-workspace:reconcile|context-mode:reconcile|camofox-browser:reconcile|camofox-mcp:reconcile|librarian:reconcile|leetcoder:reconcile|retrieval:reconcile)
            printf '%s\n' integrate.sh
            ;;
        hermes-workspace:update|context-mode:update|camofox-browser:update|camofox-mcp:update|librarian:update|leetcoder:update|retrieval:update)
            printf '%s\n' update.sh
            ;;
        codebase-memory-mcp:check) printf '%s\n' doctor-local.sh ;;
        codebase-memory-mcp:reconcile) printf '%s\n' integrate-local.sh ;;
        codebase-memory-mcp:update) printf '%s\n' update-local.sh ;;
        persephone:check) printf '%s\n' scripts/doctor.sh ;;
        persephone:reconcile) printf '%s\n' scripts/integrate.sh ;;
        persephone:update) printf '%s\n' scripts/update.sh ;;
        *) return 1 ;;
    esac
}

run_owner_script() {
    local owner="$1"
    local requested="$2"
    local owner_dir="$3"
    local relative
    relative="$(owner_script "$owner" "$requested")"
    local script="$owner_dir/$relative"
    if [[ ! -f "$script" || ! -r "$script" ]]; then
        printf 'sandwich: %s owner script is missing or unreadable: %s\n' \
            "$owner" "$script" >&2
        return 1
    fi
    printf '[%s] %s: %s\n' "$owner" "$requested" "$script"
    if [[ "$dry_run" == 0 ]]; then
        bash "$script"
    fi
}

failures=0
installed=0
skipped=0

for owner in "${owners[@]}"; do
    owner_dir="$(owner_root "$owner")"
    if [[ ! -d "$owner_dir" ]]; then
        printf '[%s] not installed: %s\n' "$owner" "$owner_dir"
        skipped=$((skipped + 1))
        if [[ "$strict" == 1 ]]; then
            failures=$((failures + 1))
        fi
        continue
    fi
    installed=$((installed + 1))
    if ! run_owner_script "$owner" "$action" "$owner_dir"; then
        failures=$((failures + 1))
        continue
    fi
    if [[ "$action" != "check" ]] && \
       ! run_owner_script "$owner" check "$owner_dir"; then
        failures=$((failures + 1))
    fi
done

printf 'Integration owners: %s installed, %s skipped, %s failed.\n' \
    "$installed" "$skipped" "$failures"
if ((failures)); then
    exit 1
fi
