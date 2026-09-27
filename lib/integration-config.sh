#!/usr/bin/env bash

# Discovery supplies suggestions only. Execution is driven entirely by .env.
integration_defaults() {
    local name="$1" directory="$2"
    integration_script=""
    check_script=""
    update_script=""
    local candidate
    for candidate in integrate.sh scripts/integrate.sh integrate-local.sh; do
        if [[ -f "$directory/$candidate" ]]; then
            integration_script="$candidate"
            break
        fi
    done
    if [[ "$name" == localflame && -f "$directory/install.sh" ]]; then
        integration_script=install.sh
    fi
    for candidate in audit.sh doctor.sh scripts/doctor.sh doctor-local.sh; do
        if [[ -f "$directory/$candidate" ]]; then
            check_script="$candidate"
            break
        fi
    done
    for candidate in update.sh scripts/update.sh update-local.sh; do
        if [[ -f "$directory/$candidate" ]]; then
            update_script="$candidate"
            break
        fi
    done
}

discover_integrations() {
    local projects="${HERMES_PROJECTS_DIR:-$HOME/Hermes}"
    local localflame="${LOCALFLAME_ROOT:-$HOME/Deepseek/localflame}"
    local name directory canonical parent nested
    local -A seen=()
    detected_names=()
    detected_roots=()
    # Preserve the established dependency order for known owners, then append
    # any other project exposing an integration entrypoint (including nested ones).
    local -a candidates=(
        "$localflame" "$projects/hermes-workspace" "$projects/context-mode"
        "$projects/camofox/camofox-browser" "$projects/camofox-mcp"
        "$projects/codebase-memory-mcp" "$projects/librarian"
        "$projects/leetcoder" "$projects/retrieval" "$projects/persephone"
    )
    if [[ -d "$projects" ]]; then
        while IFS= read -r -d '' directory; do
            candidates+=("$directory")
        done < <(find "$projects" -mindepth 1 -maxdepth 2 \
            -name '.*' -prune -o -type d -print0 | sort -z)
    fi
    for directory in "${candidates[@]}"; do
        [[ -d "$directory" ]] || continue
        canonical="$(realpath -e -- "$directory")"
        [[ -z "${seen[$canonical]:-}" ]] || continue
        nested=0
        for parent in "${!seen[@]}"; do
            if [[ "$canonical" == "$parent/"* ]]; then nested=1; break; fi
        done
        ((nested == 0)) || continue
        name="$(basename -- "$directory")"
        integration_defaults "$name" "$directory"
        [[ -n "$integration_script" ]] || continue
        seen[$canonical]=1
        detected_names+=("$name")
        detected_roots+=("$directory")
    done
}

write_integration_config() {
    local ask="$1"
    local index number name directory answer enabled
    printf '# Sandwich integrations. Bash assignments; see .env-example.\n'
    printf 'HERMES_PROJECTS_DIR=%q\n\n' "${HERMES_PROJECTS_DIR:-$HOME/Hermes}"
    for index in "${!detected_roots[@]}"; do
        number=$((index + 1))
        name="${detected_names[$index]}"
        directory="${detected_roots[$index]}"
        enabled=true
        if [[ "$ask" == 1 ]]; then
            while true; do
                printf 'Enable %s (%s)? [Y/n] ' "$name" "$directory" >&2
                IFS= read -r answer || { printf '\nConfiguration cancelled.\n' >&2; return 1; }
                case "$answer" in
                    ''|[Yy]|[Yy][Ee][Ss]) enabled=true; break ;;
                    [Nn]|[Nn][Oo]) enabled=false; break ;;
                    *) printf 'Please enter Y or N.\n' >&2 ;;
                esac
            done
        fi
        integration_defaults "$name" "$directory"
        printf 'PROJECT_%s=%q\n' "$number" "$directory"
        printf 'PROJECT_%s_NAME=%q\n' "$number" "$name"
        printf 'PROJECT_%s_ENABLED=%s\n' "$number" "$enabled"
        printf 'PROJECT_%s_INTEGRATE=%q\n' "$number" "$integration_script"
        printf 'PROJECT_%s_CHECK=%q\n' "$number" "$check_script"
        printf 'PROJECT_%s_UPDATE=%q\n\n' "$number" "$update_script"
    done
}

configure_integrations() {
    local destination="$1" temporary
    if [[ -e "$destination" ]]; then
        printf 'sandwich: configuration already exists: %s\n' "$destination" >&2
        return 1
    fi
    discover_integrations
    mkdir -p -- "$(dirname -- "$destination")"
    temporary="$(mktemp "$destination.XXXXXX")"
    if ! write_integration_config 1 >"$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    # Refuse to replace a config created by another concurrent invocation.
    if ! ln -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    printf 'Saved integration choices to %s\n' "$destination"
}
