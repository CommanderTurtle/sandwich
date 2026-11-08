#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly SANDWICH_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)"
source "$SANDWICH_ROOT/lib/bun-runtime.sh"
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

# Who owns a system binary and who would break without it, as "package|dependents"
# (empty dependents means removable). Debian and Arch are answered from their own
# package databases; elsewhere nothing is claimed. A compatibility shim can shadow
# such a binary, but only its packager decides whether it may be removed.
bs_package_owner() {
    local path="$1" package="" dependents=""
    if command -v dpkg-query >/dev/null 2>&1; then
        local owner=""
        owner="$(dpkg-query -S "$path" 2>/dev/null | head -n 1)" || owner=""
        [[ -n "$owner" && "$owner" == *:* ]] || return 1
        printf '%s|\n' "${owner%%:*}"
        return 0
    fi
    command -v pacman >/dev/null 2>&1 || return 1
    package="$(pacman -Qo "$path" 2>/dev/null | awk '/is owned by/ {print $(NF-1)}' | head -n 1)" || package=""
    [[ -n "$package" ]] || return 1
    dependents="$(pacman -Qi "$package" 2>/dev/null |
        sed -n 's/^Required By *: //p' | tr -s ' ' | sed 's/^ //; s/ $//; s/ /, /g' || true)"
    [[ -n "$dependents" && "$dependents" != "None" ]] || dependents=""
    printf '%s|%s\n' "$package" "$dependents"
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

# One Bun global root, discovered rather than assumed. Omarchy installs Bun with
# `mise use -g bun@latest` and neither Mise nor Omarchy exports BUN_INSTALL, so
# the root Bun actually uses is configuration, not a constant: an explicit
# BUN_INSTALL_GLOBAL_DIR, then bunfig's [install] globalDir (the file this
# project authors), then the tree the launchers already on PATH execute from,
# then the prefix defaults, including the ${XDG_CACHE_HOME:-~/.cache}/.bun prefix
# an older install used. A candidate counts only when it holds an installed tree
# (package.json plus node_modules or a lockfile), so exactly one root resolves
# unless none exists yet; the others are reported as duplicates. Shell builtins
# only: this runs on every shim call.
SANDWICH_BUNFIG_VALUE=""

bs_bunfig_setting() {
    local key="$1" file section="" line name value
    for file in "${SANDWICH_BUNFIG:-$HOME/.bunfig.toml}" /etc/bunfig.toml; do
        [[ -r "$file" ]] || continue
        section=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -n "$line" ]] || continue
            if [[ "$line" == \[*\] ]]; then
                section="${line:1:${#line}-2}"
                section="${section%"${section##*[![:space:]]}"}"
                continue
            fi
            [[ "$section" == install ]] || continue
            name="${line%%=*}"
            [[ "$name" != "$line" ]] || continue
            name="${name%"${name##*[![:space:]]}"}"
            [[ "$name" == "$key" ]] || continue
            value="${line#*=}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            case "$value" in
                '~') value="$HOME" ;;
                '~/'*) value="$HOME/${value#\~/}" ;;
            esac
            value="${value//\$HOME/$HOME}"
            [[ "$value" == /* ]] || continue
            SANDWICH_BUNFIG_VALUE="$value"
            return 0
        done <"$file"
    done
    return 1
}

bs_bun_root_installed() {
    local root="$1"
    [[ -n "$root" && -f "$root/package.json" ]] || return 1
    [[ -d "$root/node_modules" || -f "$root/bun.lock" || -f "$root/bun.lockb" ]]
}

SANDWICH_BUN_CANDIDATES=()

bs_bun_offer_candidate() {
    local candidate="$1" existing
    [[ -n "$candidate" ]] || return 0
    for existing in "${SANDWICH_BUN_CANDIDATES[@]}"; do
        [[ "$existing" == "$candidate" ]] && return 0
    done
    SANDWICH_BUN_CANDIDATES+=("$candidate")
}

# Roots in precedence order. PATH directories named bin are Bun's own layout
# signature, so their sibling install/global is probed without any subprocess.
bs_bun_collect_candidates() {
    local -a path_dirs=()
    local directory sibling
    SANDWICH_BUN_CANDIDATES=()
    bs_bun_offer_candidate "${BUN_INSTALL_GLOBAL_DIR:-}"
    if bs_bunfig_setting globalDir; then
        bs_bun_offer_candidate "$SANDWICH_BUNFIG_VALUE"
    fi
    IFS=: read -r -a path_dirs <<<"$PATH"
    for directory in "${path_dirs[@]}"; do
        [[ -n "$directory" ]] || directory="$PWD"
        case "${directory%/}" in
            */bin)
                sibling="${directory%/bin}/install/global"
                bs_bun_root_installed "$sibling" && bs_bun_offer_candidate "$sibling"
                ;;
        esac
    done
    bs_bun_offer_candidate "${BUN_INSTALL:-$HOME/.bun}/install/global"
    bs_bun_offer_candidate "$HOME/.bun/install/global"
    bs_bun_offer_candidate "${XDG_CACHE_HOME:-$HOME/.cache}/.bun/install/global"
}

# npm's "global prefix" is the parent of Bun's global root in Bun's layout; an
# unusual globalDir has no such parent, so the prefix stays the Bun prefix then.
bs_bun_global_prefix() {
    if [[ "$BUN_INSTALL_GLOBAL_DIR" == */install/global ]]; then
        printf '%s\n' "${BUN_INSTALL_GLOBAL_DIR%/install/global}"
    else
        printf '%s\n' "$BUN_INSTALL"
    fi
}

# The version a directory layout declares, read rather than executed: a tool
# manager names an install directory after the version it holds and points
# `latest`/`global` at it, and a Node package states its version in its own
# package.json (first such key). Nothing is run and nothing is written; a tool
# with no tree on disk prints nothing, which is a fact worth reporting too.
# Output is "version<TAB>where".
SANDWICH_MISE_DATA="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
readonly SANDWICH_MISE_DATA

bs_declared_version() {
    local name="$1"
    local alias_dir version="" file
    for alias_dir in "$SANDWICH_MISE_DATA/installs/$name/latest" "$SANDWICH_MISE_DATA/installs/$name/global"; do
        [[ -e "$alias_dir" ]] || continue
        version="$(basename -- "$(readlink -f -- "$alias_dir" 2>/dev/null || printf '%s' "$alias_dir")")"
        [[ "$version" =~ ^v?[0-9]+(\.[0-9]+)*$ ]] || continue
        printf '%s\t%s\n' "${version#v}" "$alias_dir"
        return 0
    done
    for file in "$SANDWICH_MISE_DATA/installs/node/latest/lib/node_modules/$name/package.json" \
        "/usr/lib/node_modules/$name/package.json" \
        "${BUN_INSTALL_GLOBAL_DIR:-$HOME/.bun/install/global}/node_modules/$name/package.json"; do
        [[ -f "$file" ]] || continue
        version="$(sed -n '/"version"[[:space:]]*:/ { s/.*"\([0-9][0-9.]*\)".*/\1/; p; q; }' "$file" 2>/dev/null)" || version=""
        [[ -n "$version" ]] || continue
        printf '%s\t%s\n' "$version" "${file%/package.json}"
        return 0
    done
    return 1
}

SANDWICH_BUN_GLOBAL_ROOT=""
SANDWICH_BUN_GLOBAL_ROOTS=()
SANDWICH_BUN_STALE_ROOTS=""

bs_bun_discover() {
    local candidate lead=1
    bs_bun_collect_candidates
    SANDWICH_BUN_GLOBAL_ROOTS=()
    for candidate in "${SANDWICH_BUN_CANDIDATES[@]}"; do
        bs_bun_root_installed "$candidate" && SANDWICH_BUN_GLOBAL_ROOTS+=("$candidate")
    done
    if (( ${#SANDWICH_BUN_GLOBAL_ROOTS[@]} )); then
        SANDWICH_BUN_GLOBAL_ROOT="${SANDWICH_BUN_GLOBAL_ROOTS[0]}"
    else
        SANDWICH_BUN_GLOBAL_ROOT="${BUN_INSTALL_GLOBAL_DIR:-${BUN_INSTALL:-$HOME/.bun}/install/global}"
    fi
    SANDWICH_BUN_STALE_ROOTS=""
    for candidate in "${SANDWICH_BUN_GLOBAL_ROOTS[@]}"; do
        if (( lead )); then lead=0; continue; fi
        SANDWICH_BUN_STALE_ROOTS="${SANDWICH_BUN_STALE_ROOTS:+$SANDWICH_BUN_STALE_ROOTS:}$candidate"
    done
}

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export DO_NOT_TRACK=1
bs_bun_discover
export SANDWICH_BUN_GLOBAL_ROOT SANDWICH_BUN_STALE_ROOTS
# An explicitly exported BUN_INSTALL_GLOBAL_DIR is the caller's decision and
# always wins, even for a prefix that holds nothing yet; discovery only fills
# the gap when nothing was exported.
export BUN_INSTALL_GLOBAL_DIR="${BUN_INSTALL_GLOBAL_DIR:-$SANDWICH_BUN_GLOBAL_ROOT}"
if bs_bunfig_setting globalBinDir; then
    SANDWICH_BUN_BIN="$SANDWICH_BUNFIG_VALUE"
elif [[ -d "${SANDWICH_BUN_GLOBAL_ROOT%/install/global}/bin" ]]; then
    SANDWICH_BUN_BIN="${SANDWICH_BUN_GLOBAL_ROOT%/install/global}/bin"
else
    SANDWICH_BUN_BIN="$BUN_INSTALL/bin"
fi
export BUN_INSTALL_BIN="${BUN_INSTALL_BIN:-$SANDWICH_BUN_BIN}"
unset SANDWICH_BUN_BIN

SANDWICH_BIN="$(sandwich_bun_runtime || true)"
if [[ -z "$SANDWICH_BIN" ]]; then
    printf 'sandwich: no Bun runtime found; install Bun or export SANDWICH_BUN\n' >&2
    exit 127
fi
export SANDWICH_BUN="$SANDWICH_BIN"
readonly SANDWICH_BIN

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
