#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$root/lib/common.sh"
mode="${1:?shadow or unshadow required}"
shift
config="${SANDWICH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/sandwich}"
shell_name="" dry_run=0 inert_action=""
usage() {
    printf 'usage: sandwich %s [--dry-run] [--inert|--inert=off] [--shell=bash|zsh|fish|powershell]\n' "$mode"
}
# A sudo invocation must still write the invoking user's mode file.
if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" ]]; then
    sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$sudo_home" ]] && config="${SANDWICH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$sudo_home/.config}/sandwich}"
fi
for argument in "$@"; do
    case "$argument" in
        --shell=*) shell_name="${argument#*=}" ;;
        --inert) inert_action=hide ;;
        --inert=off) inert_action=show ;;
        --dry-run|--dryrun) dry_run=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
done
case "$mode" in shadow|unshadow) ;; *) exit 64 ;; esac
case "$shell_name" in ''|bash|zsh|fish|powershell) ;; *) printf 'sandwich: unsupported shell: %s\n' "$shell_name" >&2; exit 64 ;; esac
# unshadow forwards to the native commands, so they have to stay executable.
[[ "$mode" == unshadow ]] && inert_action=show
# Unexecute: clear the execute bit on the native binaries the shims replace, so
# a program that never saw the shell's PATH cannot reach real Node by absolute
# path either and the shadow cannot be lost quietly. Only the group and other bits
# go away. An ordinary process needs one of those two, so this is what makes a
# binary inert to the user running it (and to anything running as that user, an
# agent included), while the file's owner stays as its packager left it: a rooted
# transaction, a scriptlet, or a rooted service can still exec it. Removing every
# execute bit would also stop root, which exec needs at least one of, so the owner
# bit is left alone deliberately. Those files belong to a packager, so the chmod
# needs root; SANDWICH_INERT_CHMOD names the chmod to run for an already-rooted
# caller or a test, and SANDWICH_NATIVE_DIRS the directories to scan. Restore is
# exact: the mode each file had is recorded beside its path, files already inert
# are never recorded, and only recorded paths ever change.
shadow_names=(node npm npx pnpm pnpx yarn yarnpkg corepack)
IFS=: read -r -a shadow_dirs <<<"${SANDWICH_NATIVE_DIRS:-/usr/local/bin:/usr/bin:/bin}"
inerted_file="$config/inert"
archive_dir="${SANDWICH_INERT_ARCHIVE:-$SANDWICH_STATE_DIR/inert}"
declare -a inert_chmod_command=()
[[ -n "${SANDWICH_INERT_CHMOD:-}" ]] && read -r -a inert_chmod_command <<<"$SANDWICH_INERT_CHMOD"

inert_note() {
    if [[ -n "$shell_name" ]]; then printf '  %s\n' "$*" >&2; else printf '  %s\n' "$*"; fi
}

# "candidate<TAB>resolved<TAB>mode": the name a packager ships, the file holding
# the execute bit, and the mode to restore it to. Anything under the user's home,
# Mise's, or Sandwich's own is a runtime the shadow is supposed to reach, so it is
# never touched, and a file already inert for non-owners is left out, because
# recording it would make a restore add a bit nothing had removed.
inert_targets() {
    local directory name candidate resolved perm
    for directory in "${shadow_dirs[@]}"; do
        [[ -d "$directory" ]] || continue
        for name in "${shadow_names[@]}"; do
            candidate="$directory/$name"
            [[ -e "$candidate" || -L "$candidate" ]] || continue
            resolved="$(readlink -f -- "$candidate" 2>/dev/null)" || continue
            case "$resolved" in
                "$HOME"*|"$root"*|*/mise/*) continue ;;
            esac
            perm="$(stat -c '%a' -- "$resolved" 2>/dev/null)" || continue
            bs_nonowner_inert "$resolved" && continue
            printf '%s\t%s\t%s\n' "$candidate" "$resolved" "$perm"
        done
    done
}

# Apply one mode change to a list of files, escalating only where a file is not
# ours to change. One sudo prompt covers the whole list, and a prompt that cannot
# be answered stops the command before anything on the machine changes.
inert_chmod() {
    local mode="$1" hint="$2" file owner me
    shift 2
    (($#)) || return 0
    if ((${#inert_chmod_command[@]})); then
        "${inert_chmod_command[@]}" "$mode" "$@"
        return
    fi
    local -a mine=() rootly=()
    me="$(id -u)"
    for file in "$@"; do
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
            inert_needs_root "$hint" "${rootly[@]}"
            return 1
        }
        inert_note "root:     ${#rootly[@]} files belong to their packager; sudo will ask for a password" || true
        sudo -v || {
            inert_needs_root "$hint" "${rootly[@]}"
            return 1
        }
        sudo chmod "$mode" -- "${rootly[@]}"
    fi
}

inert_needs_root() {
    local hint="$1" file
    shift
    printf 'sandwich: root is needed for:\n' >&2
    for file in "$@"; do printf '            %s\n' "$file" >&2; done
    printf '        %s\n' "$hint" >&2
}

# State written by root stays owned by the user who ran the command.
inert_own() {
    if ((EUID == 0)) && [[ -n "${SUDO_UID:-}" ]]; then
        chown -- "$SUDO_UID:${SUDO_GID:-0}" "$1" || true
    fi
}

# A tar of a file as it was found, kept under the state directory. tar carries
# owner, mode and timestamps, so a restore hands the packager's own file back
# exactly instead of rebuilding it from a mode string. The archive is named after
# the path, so an existing one always belongs to this same file, and the first one
# written is never replaced. SANDWICH_INERT_ARCHIVE moves the directory, which is
# how tests isolate it; without tar the recorded modes remain the restore path.
inert_archive_for() {
    local digest
    digest="$(printf '%s' "$1" | sha1sum 2>/dev/null | cut -d' ' -f1)"
    [[ -n "$digest" ]] || digest="$(printf '%s' "$1" | cksum | tr -d ' ')"
    printf '%s/%s.tar.gz' "$archive_dir" "$digest"
}

inert_archive_files() {
    local file archive directory name
    if ! command -v tar >/dev/null 2>&1 || ! command -v sha1sum >/dev/null 2>&1; then
        inert_note "archive:  no tar here; the recorded modes are the restore path" || true
        return 0
    fi
    mkdir -p -- "$archive_dir" || return 0
    for file in "$@"; do
        [[ -e "$file" ]] || continue
        archive="$(inert_archive_for "$file")"
        [[ -e "$archive" ]] && continue
        directory="$(dirname -- "$file")"
        name="$(basename -- "$file")"
        if ! tar -C "$directory" -zcf "$archive" -- "$name" 2>/dev/null; then
            rm -f -- "$archive"
            inert_note "archive:  could not archive $file; the recorded mode is its restore path" || true
            continue
        fi
        inert_note "archived: $file -> $archive" || true
    done
}

inert_pending() {
    pending_paths+=("$2")
    pending_notes+=("$3")
    pending_groups["$1"]+="$2"$'\n'
}

# Decide what one recorded file needs to become executable again. An archive whose
# stored copy still matches the file on disk is the exact restore. Once the
# packager has replaced that content, extracting would roll the package's own
# update back, so the recorded mode is what comes back and the archive is dropped
# as stale.
inert_restore_plan() {
    local file="$1" perm="$2" archive live archived
    archive="$(inert_archive_for "$file")"
    if [[ -f "$archive" ]]; then
        live="$(sha256sum -- "$file" 2>/dev/null | cut -d' ' -f1)"
        archived="$(tar -xOf "$archive" -- "$(basename -- "$file")" 2>/dev/null | sha256sum | cut -d' ' -f1)"
        if [[ -n "$live" && "$live" == "$archived" ]]; then
            if [[ -n "$perm" ]]; then
                [[ "$(stat -c '%a' -- "$file" 2>/dev/null)" == "$perm" ]] && return 0
            else
                bs_nonowner_inert "$file" || return 0
            fi
            inert_pending "tar:$archive" "$file" \
                "restored: $file (mode $(stat -c '%a' "$file" 2>/dev/null || printf '?') -> $perm, from its archive)"
            return 0
        fi
        stale_archives+=("$archive")
    fi
    if [[ -n "$perm" ]]; then
        [[ "$(stat -c '%a' -- "$file" 2>/dev/null)" == "$perm" ]] && return 0
        inert_pending "chmod:$perm" "$file" "restored: $file (mode $perm)"
    elif bs_nonowner_inert "$file"; then
        inert_pending 'chmod:g+x,o+x' "$file" "restored: $file (group and other execute)"
    fi
}

# Putting a packager's file back means giving its ownership back too, which only
# root can do; that is the same single password prompt the chmod needs.
inert_untar() {
    local archive="$1" file="$2" directory name
    directory="$(dirname -- "$file")"
    name="$(basename -- "$file")"
    if ((EUID == 0)) || [[ -w "$file" ]]; then
        tar -C "$directory" -xzpf "$archive" -- "$name"
    elif command -v sudo >/dev/null 2>&1; then
        inert_note "root:     $file has to return owned by its packager; sudo will ask for a password" || true
        sudo -v || {
            inert_needs_root 'run it where a password can be typed: sandwich uninert' "$file"
            return 1
        }
        sudo tar -C "$directory" -xzpf "$archive" -- "$name"
    else
        inert_needs_root 'run it where a password can be typed: sandwich uninert' "$file"
        return 1
    fi
}

# "mode<TAB>path", or a bare path from a record written before modes were stored.
inert_split() {
    inert_perm="${1%%$'\t'*}"
    inert_path="${1#*$'\t'}"
    if [[ "$inert_path" == "$1" ]]; then
        inert_perm=""
        inert_path="$1"
    fi
}

# Write the first <count> entries as the record: "<mode><TAB><path>", or a bare
# path when the mode was never observed.
inert_record_write() {
    local target="$1" count="$2" index=0
    : >"$target"
    while [[ "$index" -lt "$count" ]]; do
        if [[ -n "${inert_perms[index]}" ]]; then
            printf '%s\t%s\n' "${inert_perms[index]}" "${inert_paths[index]}" >>"$target"
        else
            printf '%s\n' "${inert_paths[index]}" >>"$target"
        fi
        index=$((index + 1))
    done
}

# Inerting is always stated, never implied: `sandwich shadow` on its own keeps
# its existing meaning of choosing the compatibility mode and touching nothing
# outside Sandwich's own state.

if ((dry_run)); then
    printf 'Would set %s/mode to %s; no files or PATH changed.\n' "$config" "$mode"
    if [[ "$inert_action" == hide ]]; then
        declare -a previewed=()
        while IFS=$'\t' read -r candidate resolved perm; do
            for preview in "${previewed[@]}"; do
                [[ "$preview" == "$resolved" ]] && continue 2
            done
            previewed+=("$resolved")
            printf 'Would clear the group and other execute bit on %s (%s, mode %s)\n' "$candidate" "$resolved" "$perm"
        done < <(inert_targets)
    elif [[ "$inert_action" == show ]]; then
        while IFS= read -r record_line; do
            inert_split "$record_line"
            [[ -n "$inert_path" && -e "$inert_path" ]] || continue
            if [[ -n "$inert_perm" ]]; then
                [[ "$(stat -c '%a' -- "$inert_path" 2>/dev/null)" == "$inert_perm" ]] && continue
            else
                bs_nonowner_inert "$inert_path" || continue
            fi
            printf 'Would restore %s on %s\n' "${inert_perm:-the group and other execute bit}" "$inert_path"
        done <"$inerted_file"
    fi
    exit 0
fi
mkdir -p -- "$config"
inert_own "$config"

# A record written by the earlier name of this command is adopted, not ignored:
# a bare path means "mode unknown, restore by handing back the group and other
# execute bit", which the splitter already understands.
if [[ ! -f "$inerted_file" && -f "$config/unexecuted" ]]; then
    mv -f -- "$config/unexecuted" "$inerted_file"
    inert_own "$inerted_file"
fi

# The privileged work happens before the mode file changes. A password prompt
# that cannot be answered has to leave the machine as it was: shadow mode over
# inert natives is a working state, unshadow mode over them is not.
declare -a inert_paths=() inert_names=() inert_perms=()
declare -a pending_paths=() pending_notes=() stale_archives=()
declare -A pending_groups=()
inert_known_index=-1
inert_known() {
    local existing index=0
    inert_known_index=-1
    for existing in "${inert_paths[@]}"; do
        if [[ "$existing" == "$1" ]]; then
            inert_known_index=$index
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

# Loading what is already recorded keeps an earlier run's entries and the modes
# they stored, so a rerun narrows nothing and a restore stays exact. A file that
# has since been removed by its packager has nothing to inert or restore, so it
# drops out here.
if [[ -f "$inerted_file" ]]; then
    while IFS= read -r record_line; do
        inert_split "$record_line"
        [[ -n "$inert_path" && -e "$inert_path" ]] || continue
        inert_paths+=("$inert_path")
        inert_names+=("$inert_path")
        inert_perms+=("$inert_perm")
    done <"$inerted_file"
fi
loaded_count=${#inert_paths[@]}

if [[ "$inert_action" == hide ]]; then
    # A packager's second name for the same file (Arch /bin/node and
    # /usr/bin/node) resolves to one entry, whose label becomes the newest name.
    while IFS=$'\t' read -r candidate resolved perm; do
        [[ -n "$resolved" ]] || continue
        if inert_known "$resolved"; then
            inert_names[inert_known_index]="$candidate"
            # A record written before modes were stored gains the mode now seen,
            # so the next restore is exact rather than a bare bit handshake.
            [[ -n "${inert_perms[inert_known_index]}" ]] ||
                inert_perms[inert_known_index]="$perm"
        else
            inert_paths+=("$resolved")
            inert_names+=("$candidate")
            inert_perms+=("$perm")
        fi
    done < <(inert_targets)
    index=0
    while [[ "$index" -lt ${#inert_paths[@]} ]]; do
        bs_nonowner_inert "${inert_paths[index]}" ||
            pending_paths+=("${inert_paths[index]}")
        index=$((index + 1))
    done
    # The archive is written before any bit changes, and an existing archive is
    # never overwritten: it holds the file as this command first found it.
    inert_archive_files "${inert_paths[@]}"
    # The list that restores these files is written before any of them changes,
    # so a broken pipe or a failed chmod cannot strand an inerted binary.
    temporary="$(mktemp "$config/.inert.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    inert_record_write "$temporary" "${#inert_paths[@]}"
    mv -f -- "$temporary" "$inerted_file"
    inert_own "$inerted_file"
    trap - EXIT
    if ((${#pending_paths[@]})); then
        if ! inert_chmod 'g-x,o-x' \
            'run it where a password can be typed: sandwich inert' \
            "${pending_paths[@]}"; then
            # If nothing became inert, the record would describe a change that
            # never happened: put back what was there before this run and stop.
            any_inert=0
            for file in "${inert_paths[@]}"; do
                bs_nonowner_inert "$file" && {
                    any_inert=1
                    break
                }
            done
            if ((any_inert)); then
                inert_note "record:   ${inerted_file} (partly applied; sandwich inert again finishes it)" || true
            elif ((loaded_count)); then
                temporary="$(mktemp "$config/.inert.XXXXXX")"
                trap 'rm -f -- "$temporary"' EXIT
                inert_record_write "$temporary" "$loaded_count"
                mv -f -- "$temporary" "$inerted_file"
                inert_own "$inerted_file"
                trap - EXIT
            else
                rm -f -- "$inerted_file"
            fi
            exit 1
        fi
    fi
elif [[ "$inert_action" == show ]]; then
    index=0
    while [[ "$index" -lt ${#inert_paths[@]} ]]; do
        inert_restore_plan "${inert_paths[index]}" "${inert_perms[index]}"
        index=$((index + 1))
    done
    for spec in "${!pending_groups[@]}"; do
        mapfile -t group_paths <<<"${pending_groups[$spec]%$'\n'}"
        case "$spec" in
            tar:*)
                for file in "${group_paths[@]}"; do
                    inert_untar "${spec#tar:}" "$file" || exit 1
                done
                ;;
            *)
                inert_chmod "${spec#chmod:}" \
                    'run it where a password can be typed: sandwich uninert' \
                    "${group_paths[@]}" || exit 1
                ;;
        esac
    done
fi

temporary="$(mktemp "$config/.mode.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
printf '%s\n' "$mode" >"$temporary"
mv -f -- "$temporary" "$config/mode"
inert_own "$config/mode"
trap - EXIT

# Reported last, so the printed modes are the ones now on disk.
if [[ "$inert_action" == hide ]]; then
    index=0
    while [[ "$index" -lt ${#inert_paths[@]} ]]; do
        inert_note "inert:    ${inert_names[index]} -> ${inert_paths[index]} (mode $(stat -c '%a' "${inert_paths[index]}" 2>/dev/null || printf 'unknown'), was ${inert_perms[index]:-unknown})" || true
        index=$((index + 1))
    done
    if ((${#inert_paths[@]})); then
        inert_note "archive:  ${archive_dir}" || true
    fi
elif [[ "$inert_action" == show ]]; then
    for note in "${pending_notes[@]}"; do
        inert_note "$note" || true
    done
    for archive in "${stale_archives[@]}"; do
        inert_note "stale:    ${archive##*/} (its file was replaced since archiving)" || true
    done
    rm -f -- "$inerted_file"
    # The record is gone, so nothing will look these up again; an archive left
    # behind would be an old snapshot the next run could not tell from a live one.
    for file in "${inert_paths[@]}"; do
        rm -f -- "$(inert_archive_for "$file")"
    done
    if [[ -d "$archive_dir" && -z "$(ls -A -- "$archive_dir" 2>/dev/null)" ]]; then
        rmdir -- "$archive_dir" 2>/dev/null || true
    fi
fi

if [[ -z "$shell_name" ]]; then
    printf 'Sandwich mode: %s\n' "$mode"
    if [[ "$mode" == shadow ]]; then
        printf 'For this Bash/Zsh shell: eval "$(sandwich shadow --shell=bash)"\n'
        printf 'This places Sandwich before mise without modifying mise.\n'
        if [[ -f "$inerted_file" ]]; then
            printf 'Native binaries are inert for non-owners (group and other execute cleared, originals archived). sandwich uninert or unshadow restores them.\n'
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
