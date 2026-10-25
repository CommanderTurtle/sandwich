#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly SANDWICH_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)"
readonly SANDWICH_BIN="${SANDWICH_BUN:-$(type -P bun 2>/dev/null || printf '%s/bin/bun' "${BUN_INSTALL:-$HOME/.bun}")}"
readonly SANDWICH_STATE_DIR="${SANDWICH_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/sandwich}"
readonly SANDWICH_CONFIG_DIR="${SANDWICH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/sandwich}"

# Data only: never source/eval registry responses or a user-writable version file.
resolved_npm=12.2.1 resolved_pnpm=12.15.0 resolved_yarn=1.22.22
if [[ -f "$SANDWICH_STATE_DIR/versions.tsv" ]]; then
    while IFS=$'\t' read -r tool version; do
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        case "$tool" in
            npm) resolved_npm="$version" ;;
            pnpm) resolved_pnpm="$version" ;;
            yarn) resolved_yarn="$version" ;;
        esac
    done <"$SANDWICH_STATE_DIR/versions.tsv"
fi
readonly SANDWICH_NPM_VERSION="${SANDWICH_NPM_VERSION:-$resolved_npm}"
readonly SANDWICH_PNPM_VERSION="${SANDWICH_PNPM_VERSION:-$resolved_pnpm}"
readonly SANDWICH_YARN_VERSION="${SANDWICH_YARN_VERSION:-$resolved_yarn}"
unset resolved_npm resolved_pnpm resolved_yarn

SANDWICH_MODE="${SANDWICH_MODE:-}"
if [[ -z "$SANDWICH_MODE" && -f "$SANDWICH_CONFIG_DIR/mode" ]]; then
    read -r SANDWICH_MODE <"$SANDWICH_CONFIG_DIR/mode" || true
fi
SANDWICH_MODE="${SANDWICH_MODE:-shadow}"
case "$SANDWICH_MODE" in shadow|unshadow) ;; *) printf 'sandwich: invalid mode: %s\n' "$SANDWICH_MODE" >&2; exit 64 ;; esac
readonly SANDWICH_MODE

bs_is_shim() {
    local resolved manifest
    resolved="$(readlink -f -- "$1" 2>/dev/null || true)"
    [[ "$resolved" == "$SANDWICH_ROOT/bin/"* || "$resolved" == "$SANDWICH_ROOT/.windows-bin/"* ]] && return 0
    # Also skip another installed Sandwich checkout, avoiding forwarding loops.
    manifest="$(dirname -- "$(dirname -- "$resolved")")/manifest.json"
    [[ -f "$manifest" ]] && grep -Eq '"id"[[:space:]]*:[[:space:]]*"sandwich"' "$manifest"
}

bs_native_target() {
    local name="$1" directory candidate
    local -a search_dirs
    IFS=: read -r -a search_dirs <<<"$PATH"
    for directory in "${search_dirs[@]}"; do
        [[ -n "$directory" ]] || directory=.
        for candidate in "$directory/$name" "$directory/$name.exe" "$directory/$name.cmd"; do
            [[ -f "$candidate" && -x "$candidate" ]] || continue
            bs_is_shim "$candidate" && continue
            printf '%s\n' "$candidate"
            return 0
        done
    done
    return 1
}

# An external program cannot edit its parent shell's PATH. Persistent unshadow
# therefore makes only our compatibility entrypoints delegate to the next real
# command (including mise); it never removes a manager or overwrites its shims.
compat_name="$(basename -- "${BASH_SOURCE[1]:-}")"
if [[ "$SANDWICH_MODE" == unshadow ]]; then
    case "$compat_name" in
        node|npm|npx|pnpm|yarn|corepack)
            native="$(bs_native_target "$compat_name" || true)"
            if [[ -z "$native" ]]; then
                printf 'sandwich: unshadow: no native %s found after skipping Sandwich shims\n' "$compat_name" >&2
                exit 127
            fi
            exec "$native" "$@"
            ;;
    esac
fi
unset compat_name

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export BUN_INSTALL_BIN="${BUN_INSTALL_BIN:-$BUN_INSTALL/bin}"
export BUN_INSTALL_GLOBAL_DIR="${BUN_INSTALL_GLOBAL_DIR:-$BUN_INSTALL/install/global}"
export DO_NOT_TRACK=1

if [[ ! -x "$SANDWICH_BIN" ]]; then
    printf 'sandwich: Bun executable not found: %s\n' "$SANDWICH_BIN" >&2
    exit 127
fi

bs_die() {
    printf 'sandwich: %s\n' "$*" >&2
    exit 64
}

bs_note() {
    printf 'sandwich: %s\n' "$*" >&2
}

bs_workspace_filter() {
    local workspace="$1"
    if [[ "$workspace" == ./* || "$workspace" == ../* || "$workspace" == /* ]]; then
        printf '%s\n' "$workspace"
    elif [[ -d "$workspace" && -f "$workspace/package.json" ]]; then
        printf './%s\n' "${workspace%/}"
    else
        printf '%s\n' "$workspace"
    fi
}

bs_project_root() {
    local cursor="$PWD"
    while [[ "$cursor" != "/" ]]; do
        if [[ -f "$cursor/package.json" ]]; then
            printf '%s\n' "$cursor"
            return 0
        fi
        cursor="${cursor%/*}"
        [[ -n "$cursor" ]] || cursor="/"
    done
    printf '%s\n' "$PWD"
}

bs_print_help() {
    cat <<'EOF'
Sandwich Bun compatibility layer

Supported npm-compatible commands:
  install, ci, run, test, start, exec, audit, outdated, update,
  add, remove, list, why, view, pack, publish, version, pkg,
  root, prefix, bin, cache, config get, init, create, doctor

Commands are translated to Bun only when their semantics are known.
Unsupported or ambiguous state-changing operations fail instead of
pretending to succeed. Use bun/bunx directly for Bun-native behavior.
EOF
}
