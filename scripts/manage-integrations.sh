#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$root/lib/integration-config.sh"
env_file="${SANDWICH_ENV_FILE:-$root/.env}"
action="${1:-check}"
strict=0
dry_run=0

usage() {
    cat <<'EOF'
Usage: sandwich hermes integrate [--strict] [--dry-run]
       sandwich integrations configure
       sandwich integrations check [--strict] [--dry-run]
       sandwich integrations reconcile [--strict] [--dry-run]
       sandwich integrations update [--strict] [--dry-run]

Use PROJECT_1, PROJECT_2, ... in Sandwich's .env (or SANDWICH_ENV_FILE).
Projects run in numeric order; there is no project count limit. See .env-example.
`configure` detects projects and asks Y/N for each before saving the local .env.
`check` runs doctors, `reconcile` runs integrators then doctors, and `update`
runs updaters then doctors. `hermes integrate` also checks Sandwich and restarts
the gateway if it was active. Missing projects are errors with --strict.
Dry runs print entrypoints without executing scripts or writing configuration.
EOF
}

case "$action" in
    check|reconcile|update|configure) shift || true ;;
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

if [[ "$action" == configure ]]; then
    if ((dry_run)); then
        discover_integrations
        write_integration_config 0
    else
        configure_integrations "$env_file"
    fi
    exit
fi
if [[ ! -f "$env_file" ]]; then
    if ((dry_run)); then
        printf 'No .env yet; discovered projects below are suggestions only.\n'
        discover_integrations
        write_integration_config 0
        exit 0
    elif [[ "$action" != check && -t 0 ]]; then
        configure_integrations "$env_file"
    else
        printf 'sandwich: run sandwich integrations configure, or copy .env-example to %s\n' "$env_file" >&2
        exit 1
    fi
fi
source "$env_file"

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export DO_NOT_TRACK=1 CI=1
export PATH="$root/bin:$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"

run_owner_script() {
    local number="$1" requested="$2" owner_dir="$3" owner="$4"
    local key relative script args_key
    case "$requested" in
        reconcile) key="PROJECT_${number}_INTEGRATE"; args_key="${key}_ARGS" ;;
        check) key="PROJECT_${number}_CHECK"; args_key="${key}_ARGS" ;;
        update) key="PROJECT_${number}_UPDATE"; args_key="${key}_ARGS" ;;
    esac
    relative="${!key:-}"
    if [[ -z "$relative" && "$requested" == check ]]; then
        printf '[%s] no check script configured\n' "$owner"
        return 0
    fi
    script="$(realpath -m -- "$owner_dir/$relative")"
    if [[ -z "$relative" || "$script" != "$owner_dir/"* || ! -f "$script" || ! -r "$script" ]]; then
        printf 'sandwich: %s owner script is missing, unreadable, or outside the project: %s\n' \
            "$owner" "${relative:-$key}" >&2
        return 1
    fi
    if ! declare -p "$args_key" >/dev/null 2>&1; then
        args_key="PROJECT_${number}_ARGS"
    fi
    local -a args=()
    if declare -p "$args_key" >/dev/null 2>&1; then
        local -n configured_args="$args_key"
        args=("${configured_args[@]}")
    fi
    printf '[%s] %s: %s' "$owner" "$requested" "$script"
    if ((${#args[@]})); then printf ' %q' "${args[@]}"; fi
    printf '\n'
    if ((dry_run == 0)); then
        bash "$script" "${args[@]}"
    fi
}

failures=0
installed=0
skipped=0
mapfile -t project_numbers < <(compgen -A variable | sed -n 's/^PROJECT_\([1-9][0-9]*\)$/\1/p' | sort -n)
for number in "${project_numbers[@]}"; do
    key="PROJECT_${number}_ENABLED"
    case "${!key:-true}" in
        false|0|no) skipped=$((skipped + 1)); continue ;;
        true|1|yes) ;;
        *) printf 'sandwich: %s must be true or false\n' "$key" >&2; exit 2 ;;
    esac
    key="PROJECT_${number}"
    owner_dir="${!key}"
    key="PROJECT_${number}_NAME"
    owner="${!key:-$(basename -- "$owner_dir")}"
    if [[ ! -d "$owner_dir" ]]; then
        printf '[%s] not installed: %s\n' "$owner" "$owner_dir"
        skipped=$((skipped + 1))
        if ((strict)); then failures=$((failures + 1)); fi
        continue
    fi
    owner_dir="$(realpath -e -- "$owner_dir")"
    installed=$((installed + 1))
    if ! run_owner_script "$number" "$action" "$owner_dir" "$owner"; then
        failures=$((failures + 1))
        continue
    fi
    if [[ "$action" != check ]] && \
       ! run_owner_script "$number" check "$owner_dir" "$owner"; then
        failures=$((failures + 1))
    fi
done

printf 'Integration owners: %s installed, %s skipped, %s failed.\n' \
    "$installed" "$skipped" "$failures"
((failures == 0))
