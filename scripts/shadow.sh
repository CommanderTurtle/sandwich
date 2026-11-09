#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode="${1:?shadow or unshadow required}"
shift
config="${SANDWICH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/sandwich}"
shell_name="" dry_run=0 unexec=""
usage() {
    printf 'usage: sandwich %s [--dry-run] [--unexecute|--unexecute=off] [--shell=bash|zsh|fish|powershell]\n' "$mode"
}
# A sudo invocation must still write the invoking user's mode file.
if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" ]]; then
    sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$sudo_home" ]] && config="${SANDWICH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$sudo_home/.config}/sandwich}"
fi
for argument in "$@"; do
    case "$argument" in
        --shell=*) shell_name="${argument#*=}" ;;
        --unexecute) unexec=hide ;;
        --unexecute=off) unexec=show ;;
        --dry-run|--dryrun) dry_run=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
done
case "$mode" in shadow|unshadow) ;; *) exit 64 ;; esac
case "$shell_name" in ''|bash|zsh|fish|powershell) ;; *) printf 'sandwich: unsupported shell: %s\n' "$shell_name" >&2; exit 64 ;; esac
# unshadow forwards to the native commands, so they have to stay executable.
[[ "$mode" == unshadow ]] && unexec=show
# Unexecute: clear the execute bit on the native binaries the shims replace, so
# a program that never saw the shell's PATH cannot reach real Node by absolute
# path either and the shadow cannot be lost quietly. Those files belong to a
# packager, so the chmod needs root; SANDWICH_UNEXECUTE_CHMOD names the chmod to run
# for an already-rooted caller or a test, and SANDWICH_NATIVE_DIRS the directories
# to scan. Restoring is exact: only recorded paths get the bit back.
shadow_names=(node npm npx pnpm pnpx yarn yarnpkg corepack)
IFS=: read -r -a shadow_dirs <<<"${SANDWICH_NATIVE_DIRS:-/usr/local/bin:/usr/bin:/bin}"
unexecuted_file="$config/unexecuted"
declare -a unexec_command=()
[[ -n "${SANDWICH_UNEXECUTE_CHMOD:-}" ]] && read -r -a unexec_command <<<"$SANDWICH_UNEXECUTE_CHMOD"

unexec_note() {
    if [[ -n "$shell_name" ]]; then printf '  %s\n' "$*" >&2; else printf '  %s\n' "$*"; fi
}

# "candidate<TAB>resolved": the name a packager ships and the file holding the
# execute bit. Anything under the user's home, Mise's, or Sandwich's own is a
# runtime the shadow is supposed to reach, so it is never touched.
unexec_targets() {
    local directory name candidate resolved
    for directory in "${shadow_dirs[@]}"; do
        [[ -d "$directory" ]] || continue
        for name in "${shadow_names[@]}"; do
            candidate="$directory/$name"
            [[ -e "$candidate" || -L "$candidate" ]] || continue
            resolved="$(readlink -f -- "$candidate" 2>/dev/null)" || continue
            case "$resolved" in
                "$HOME"*|"$root"*|*/mise/*) continue ;;
            esac
            printf '%s\t%s\n' "$candidate" "$resolved"
        done
    done
}

# Apply one mode change to a list of files, escalating only where a file is not
# ours to change. One sudo prompt covers the whole list, and a prompt that cannot
# be answered stops the command before anything on the machine changes.
unexec_apply() {
    local mode="$1" hint="$2" file owner me
    shift 2
    (($#)) || return 0
    if ((${#unexec_command[@]})); then
        "${unexec_command[@]}" "$mode" "$@"
        return
    fi
    local -a mine=() rootly=()
    me="$(id -u)"
    for file in "$@"; do
        # Only files whose bit actually differs need a chmod, so re-running this
        # command needs no root at all.
        if [[ "$mode" == a-x && ! -x "$file" ]]; then continue; fi
        if [[ "$mode" == a+x && -x "$file" ]]; then continue; fi
        owner="$(stat -c '%u' -- "$file" 2>/dev/null || printf '')"
        if ((EUID == 0)) || [[ "$owner" == "$me" ]]; then
            mine+=("$file")
        else
            rootly+=("$file")
        fi
    done
    if ((${#mine[@]})); then
        chmod "$mode" -- "${mine[@]}"
    fi
    if ((${#rootly[@]})); then
        command -v sudo >/dev/null 2>&1 || {
            unexec_needs_root "$hint" "${rootly[@]}"
            return 1
        }
        unexec_note "root:     ${#rootly[@]} files belong to their packager; sudo will ask for a password" || true
        sudo -v || {
            unexec_needs_root "$hint" "${rootly[@]}"
            return 1
        }
        sudo chmod "$mode" -- "${rootly[@]}"
    fi
}

unexec_needs_root() {
    local hint="$1" file
    shift
    printf 'sandwich: root is needed for:\n' >&2
    for file in "$@"; do printf '            %s\n' "$file" >&2; done
    printf '        %s\n' "$hint" >&2
}

# State written by root stays owned by the user who ran the command.
unexec_own() {
    if ((EUID == 0)) && [[ -n "${SUDO_UID:-}" ]]; then
        chown -- "$SUDO_UID:${SUDO_GID:-0}" "$1" || true
    fi
}

# Unexecute is always stated, never implied: `sandwich shadow` on its own keeps
# its existing meaning of choosing the compatibility mode and touching nothing
# outside Sandwich's own state.

if ((dry_run)); then
    printf 'Would set %s/mode to %s; no files or PATH changed.\n' "$config" "$mode"
    if [[ "$unexec" == hide ]]; then
        declare -a previewed=()
        while IFS=$'\t' read -r candidate resolved; do
            for preview in "${previewed[@]}"; do
                [[ "$preview" == "$resolved" ]] && continue 2
            done
            previewed+=("$resolved")
            if [[ -x "$resolved" ]]; then
                printf 'Would clear the execute bit on %s (%s)\n' "$candidate" "$resolved"
            fi
        done < <(unexec_targets)
    elif [[ "$unexec" == show && -f "$unexecuted_file" ]]; then
        while IFS= read -r resolved; do
            printf 'Would restore the execute bit on %s\n' "$resolved"
        done <"$unexecuted_file"
    fi
    exit 0
fi
mkdir -p -- "$config"
unexec_own "$config"

# The privileged work happens before the mode file changes. A password prompt
# that cannot be answered has to leave the machine as it was: shadow mode over
# inert natives is a working state, unshadow mode over them is not.
declare -a unexecuted_paths=() unexecuted_names=() restore_paths=()
if [[ "$unexec" == hide ]]; then
    # Returns 0 only when the file is newly listed, so a packager's second name
    # for the same file (Arch /bin/node and /usr/bin/node) is handled once.
    unexec_record() {
        local existing
        for existing in "${unexecuted_paths[@]}"; do
            [[ "$existing" == "$2" ]] && return 1
        done
        unexecuted_paths+=("$2")
        unexecuted_names+=("$1")
        return 0
    }
    while IFS=$'\t' read -r candidate resolved; do
        unexec_record "$candidate" "$resolved" || continue
    done < <(unexec_targets)
    # The list that restores these files is written before any of them changes,
    # so a broken pipe or a failed chmod cannot strand an inerted binary.
    temporary="$(mktemp "$config/.unexecuted.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    if ((${#unexecuted_paths[@]})); then
        printf '%s\n' "${unexecuted_paths[@]}" >"$temporary"
    else
        : >"$temporary"
    fi
    mv -f -- "$temporary" "$unexecuted_file"
    unexec_own "$unexecuted_file"
    trap - EXIT
    if ((${#unexecuted_paths[@]})); then
        unexec_apply a-x \
            'run it where a password can be typed: sandwich shadow --unexecute' \
            "${unexecuted_paths[@]}" || exit 1
    fi
elif [[ "$unexec" == show && -f "$unexecuted_file" ]]; then
    while IFS= read -r path_entry; do
        [[ -n "$path_entry" ]] && restore_paths+=("$path_entry")
    done <"$unexecuted_file"
    if ((${#restore_paths[@]})); then
        unexec_apply a+x \
            'run it where a password can be typed: sandwich unshadow' \
            "${restore_paths[@]}" || exit 1
    fi
fi

temporary="$(mktemp "$config/.mode.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
printf '%s\n' "$mode" >"$temporary"
mv -f -- "$temporary" "$config/mode"
unexec_own "$config/mode"
trap - EXIT

# Reported last, so the printed modes are the ones now on disk.
index=0
while [[ "$index" -lt ${#unexecuted_paths[@]} ]]; do
    unexec_note "inert:    ${unexecuted_names[index]} -> ${unexecuted_paths[index]} (mode $(stat -c '%a' "${unexecuted_paths[index]}" 2>/dev/null || printf 'unknown'))" || true
    index=$((index + 1))
done
if [[ "$unexec" == show ]]; then
    for path_entry in "${restore_paths[@]}"; do
        unexec_note "executable: ${path_entry} (mode $(stat -c '%a' "$path_entry" 2>/dev/null || printf 'unknown'))" || true
    done
    rm -f -- "$unexecuted_file"
fi

if [[ -z "$shell_name" ]]; then
    printf 'Sandwich mode: %s\n' "$mode"
    if [[ "$mode" == shadow ]]; then
        printf 'For this Bash/Zsh shell: eval "$(sandwich shadow --shell=bash)"\n'
        printf 'This places Sandwich before mise without modifying mise.\n'
        if [[ -f "$unexecuted_file" ]]; then
            printf 'Native binaries are inert (no execute bit). sandwich unshadow or shadow --unexecute=off restores them.\n'
        fi
    else
        printf 'Sandwich shims now forward to native commands on PATH, including mise.\n'
    fi
    printf 'If your shell cached a command, run hash -r (Bash) or rehash (Zsh).\n'
    if [[ -n "${SANDWICH_MODE:-}" && "$SANDWICH_MODE" != "$mode" ]]; then
        printf 'SANDWICH_MODE is exported; unset it or evaluate this command with --shell to use the saved mode.\n'
    fi
    exit 0
fi
# stdout is exclusively shell code when explicitly requested. Quote literal paths.
case "$shell_name" in
    bash|zsh)
        printf 'unset SANDWICH_MODE\n'
        [[ "$mode" != shadow ]] || printf 'export PATH=%q:"$PATH"\n' "$root/bin"
        if [[ "$shell_name" == zsh ]]; then printf 'rehash\n'; else printf 'hash -r\n'; fi
        ;;
    fish)
        quoted="${root//\\/\\\\}"; quoted="${quoted//\'/\\\'}"
        printf 'set -e SANDWICH_MODE\n'
        [[ "$mode" != shadow ]] || printf "fish_add_path --move --prepend '%s/bin'\n" "$quoted"
        ;;
    powershell)
        windows_root="$root/.windows-bin"
        command -v cygpath >/dev/null 2>&1 && windows_root="$(cygpath -w "$windows_root")"
        windows_root="${windows_root//\'/\'\'}"
        printf 'Remove-Item Env:SANDWICH_MODE -ErrorAction SilentlyContinue\n'
        [[ "$mode" != shadow ]] || printf "\044env:Path = '%s;' + \044env:Path\n" "$windows_root"
        ;;
esac
