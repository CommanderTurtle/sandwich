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
# unshadow forwards to the native commands, so the install has to be back on disk.
[[ "$mode" == unshadow ]] && inert_action=show

# Inert means the native Node install is archived and taken away; no file mode is
# edited on the way in or out. A program or an agent that reaches for
# /usr/bin/node, /usr/bin/npm, or the code under /usr/lib/node_modules then finds
# the directory empty apart from a what-is-this.txt, so it uses the shims on PATH
# (which run on Bun) instead of discovering a Node install it has no business
# using. The archive carries mode, ownership and timestamps, so restoring is
# exact without ever having changed a permission.
#
# What gets archived is whatever the packager says the Node packages own
# (`pacman -Ql`, falling back to `dpkg -L`), so the whole install goes and nothing
# belonging to another package is disturbed. Removal and restoration happen under
# root, one sudo prompt per command, because files under /usr belong there; that
# is the only privilege involved, and it is used to move files, not to change who
# may read or exec them.
#
# SANDWICH_INERT_FILES (a file of paths) and SANDWICH_INERT_PACKAGES override the
# discovery, SANDWICH_INERT_ARCHIVE moves the archive directory, and
# SANDWICH_INERT_RM, SANDWICH_INERT_TAR, SANDWICH_INERT_INSTALL replace the
# privileged commands for automation and tests. SANDWICH_NATIVE_DIRS still says
# where to look for the runtime entry points when no packager answers.
shadow_names=(node npm npx pnpm pnpx yarn yarnpkg corepack)
IFS=: read -r -a shadow_dirs <<<"${SANDWICH_NATIVE_DIRS:-/usr/local/bin:/usr/bin:/bin}"
inerted_file="$config/inert"
archive_dir="${SANDWICH_INERT_ARCHIVE:-$SANDWICH_STATE_DIR/inert}"
marker_name="what-is-this.txt"
declare -a inert_rm_command=() inert_tar_command=() inert_install_command=()
[[ -n "${SANDWICH_INERT_RM:-}" ]] && read -r -a inert_rm_command <<<"$SANDWICH_INERT_RM"
[[ -n "${SANDWICH_INERT_TAR:-}" ]] && read -r -a inert_tar_command <<<"$SANDWICH_INERT_TAR"
[[ -n "${SANDWICH_INERT_INSTALL:-}" ]] && read -r -a inert_install_command <<<"$SANDWICH_INERT_INSTALL"

inert_note() {
    if [[ -n "$shell_name" ]]; then printf '  %s\n' "$*" >&2; else printf '  %s\n' "$*"; fi
}

# State written by root stays owned by the user who ran the command.
inert_own() {
    if ((EUID == 0)) && [[ -n "${SUDO_UID:-}" ]]; then
        chown -- "$SUDO_UID:${SUDO_GID:-0}" "$1" || true
    fi
}

inert_needs_root() {
    printf 'sandwich: root is needed to %s\n' "$1" >&2
    printf '        %s\n' "$2" >&2
}

# Run one command, trying it without root first: reading the install needs no
# privilege, while removing it or putting it back does. sudo is primed only after
# an unprivileged attempt fails, which costs one password prompt per command, and
# a prompt that cannot be answered stops before anything on the machine changes.
inert_run() {
    local reason="$1" hint="$2"
    shift 2
    if ((EUID == 0)); then
        "$@"
        return
    fi
    if "$@" 2>/dev/null; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || {
        inert_needs_root "$reason" "$hint"
        return 1
    }
    inert_note "root:     $reason; sudo will ask for a password" || true
    sudo -v || {
        inert_needs_root "$reason" "$hint"
        return 1
    }
    sudo "$@"
}

# The runtime entry points the shims replace, as "candidate<TAB>resolved".
# Anything under the user's home, Mise's, or Sandwich's own is a runtime the
# shadow is meant to reach, so it is never part of the archive.
inert_entry_points() {
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

# The packages that own those entry points. An exported SANDWICH_INERT_PACKAGES
# answers first (empty or "none" forces the fallback in inert_files), because a
# whole-install archive is only as good as the file list behind it.
inert_packages() {
    local name candidate resolved existing
    if [[ -n "${SANDWICH_INERT_PACKAGES+x}" ]]; then
        local listed="${SANDWICH_INERT_PACKAGES//,/ }"
        [[ "$listed" == none ]] && listed=""
        for name in $listed; do printf '%s\n' "$name"; done
        return 0
    fi
    local -a found=()
    while IFS=$'\t' read -r candidate resolved; do
        [[ -n "$resolved" ]] || continue
        name=""
        if command -v pacman >/dev/null 2>&1; then
            name="$(pacman -Qqo "$resolved" 2>/dev/null | head -1 || true)"
        elif command -v dpkg >/dev/null 2>&1; then
            name="$(dpkg -S "$resolved" 2>/dev/null | head -1 | cut -d: -f1 || true)"
        fi
        [[ -n "$name" ]] || continue
        for existing in "${found[@]}"; do
            [[ "$existing" == "$name" ]] && continue 2
        done
        found+=("$name")
    done < <(inert_entry_points)
    for name in "${found[@]}"; do printf '%s\n' "$name"; done
}

# Absolute paths of the files to archive: the packager's list for those packages,
# the explicit list, or - when no packager answers - the entry points plus the
# node_modules subtree each one lives in. Directories are dropped, since tar
# recreates them and a shared one like /usr/lib/node_modules has to survive.
inert_files() {
    local path package candidate resolved prefix rest name
    {
        if [[ -n "${SANDWICH_INERT_FILES:-}" ]]; then
            cat -- "$SANDWICH_INERT_FILES"
        elif inert_packages | grep -q .; then
            while IFS= read -r package; do
                [[ -n "$package" ]] || continue
                if command -v pacman >/dev/null 2>&1; then
                    pacman -Ql "$package" 2>/dev/null | cut -d' ' -f2-
                elif command -v dpkg >/dev/null 2>&1; then
                    dpkg -L "$package" 2>/dev/null
                fi
            done < <(inert_packages)
        else
            while IFS=$'\t' read -r candidate resolved; do
                [[ -n "$resolved" ]] || continue
                printf '%s\n' "$resolved"
                prefix="${resolved%%/node_modules/*}"
                if [[ "$prefix" != "$resolved" ]]; then
                    rest="${resolved#*/node_modules/}"
                    name="${rest%%/*}"
                    [[ -d "$prefix/node_modules/$name" ]] &&
                        find "$prefix/node_modules/$name" -type f 2>/dev/null
                fi
            done < <(inert_entry_points)
        fi
    } | while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        case "$path" in "$HOME"*|"$root"*|*/mise/*) continue ;; esac
        [[ -e "$path" && ! -d "$path" ]] || continue
        printf '%s\n' "$path"
    done | sort -u
}

# A name that says what is in it: when, what kind of thing, and which packages or
# entry points it came from.
inert_archive_name() {
    local slug="$1"
    slug="${slug//[^A-Za-z0-9._+-]/+}"
    printf '%s/%s--node-install--%s.tar.gz' "$archive_dir" "$(date -u +%Y%m%dT%H%M%SZ)" "$slug"
}

# The note left where the code was. It is addressed to whoever finds an empty
# directory: use Bun, or the sandwich-resolved runtime, rather than restoring
# anything by hand.
inert_marker_text() {
    local archive="$1" count="$2" packages="$3"
    printf '%s\n' \
        "This directory holds no Node code on purpose." \
        '' \
        'Sandwich archived the native Node install that lived here and removed it, so' \
        'nothing that reaches for an absolute path - a script, a build step, or an AI' \
        'agent exploring the filesystem - can pick up a real Node and start using it.' \
        'The shims on PATH are what this machine uses, and they run on Bun:' \
        '' \
        '    node, npm, npx, pnpm, yarn, corepack   -> Bun, through the shim directory' \
        '    npx --help                             -> the Bun command, in every shell' \
        '' \
        'Put the files back exactly as they were (content, mode, ownership, timestamps):' \
        '' \
        '    sandwich uninert' \
        '' \
        "Archive:  $archive" \
        "Files:    $count" \
        "Packages: ${packages:-discovered without a packager}" \
        '' \
        'If your package manager has since reinstalled Node, sandwich uninert leaves the' \
        'newer files alone rather than overwriting them.'
}

# A record line is tab-separated so a filename with a space cannot confuse it:
# relocated<TAB>utc<TAB>packages<TAB>archive<TAB>marker<TAB>count<TAB>entries.
inert_record_write() {
    local target="$1"
    printf 'relocated\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$inert_utc" "$inert_pkgs" "$inert_archive" "$inert_marker" \
        "${#inert_file_list[@]}" "$(IFS=,; printf '%s' "${inert_entries[*]}")" >"$target"
}

inert_read_record() {
    local line=""
    inert_found=0
    [[ -f "$inerted_file" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" == relocated$'\t'* ]]; then
            IFS=$'\t' read -r _ inert_utc inert_pkgs inert_archive inert_marker inert_count inert_entries <<<"$line"
            inert_found=1
        fi
    done <"$inerted_file"
}

# The directory that lost the most of the install, which is where anyone browsing
# it ends up: the deepest one holding at least half of the archived files.
inert_marker_dir() {
    local path directory depth best="" best_depth=-1
    local total="${#inert_file_list[@]}"
    local half=$(( (total + 1) / 2 ))
    declare -A counts=()
    for path in "${inert_file_list[@]}"; do
        directory="$path"
        while [[ "$directory" != "/" ]]; do
            directory="$(dirname -- "$directory")"
            counts["$directory"]=$(( ${counts["$directory"]:-0} + 1 ))
        done
    done
    for directory in "${!counts[@]}"; do
        (( ${counts[$directory]} < half )) && continue
        depth="$(printf '%s' "$directory" | tr -cd '/' | wc -c)"
        if ((depth > best_depth)); then
            best="$directory"
            best_depth=$depth
        fi
    done
    [[ -n "$best" ]] || best="$(dirname -- "${inert_file_list[0]}")"
    printf '%s\n' "$best"
}

declare -a inert_file_list=() inert_entries=()
inert_utc="" inert_pkgs="" inert_archive="" inert_marker="" inert_count=0
inert_found=0 inert_old_archive="" previous_record=""
record_pending="" restored=""

if [[ "$inert_action" == hide ]]; then
    inert_read_record
    inert_old_archive="$inert_archive"
    previous_record="$(cat -- "$inerted_file" 2>/dev/null || true)"
    while IFS= read -r path; do
        inert_file_list+=("$path")
    done < <(inert_files)
    while IFS=$'\t' read -r candidate resolved; do
        inert_entries+=("$candidate")
    done < <(inert_entry_points)
    if ((!${#inert_file_list[@]})); then
        if ((inert_found)); then
            printf 'Already inert: the archived Node install is still away. sandwich uninert puts it back.\n'
        else
            printf 'No native Node install to archive: the runtime entry points are all managed (Bun, Mise, or Sandwich).\n'
        fi
        exit 0
    fi
    inert_utc="$(date -u +%Y%m%dT%H%M%SZ)"
    inert_pkgs="$(inert_packages | paste -sd+ - | tr -d ' ')"
    [[ -n "$inert_pkgs" ]] || inert_pkgs="${inert_entries[0]##*/}"
    inert_archive="$(inert_archive_name "$inert_pkgs")"
    # The marker goes where most of the install was, which is where anyone
    # browsing it ends up; the directory is recreated if pruning emptied it.
    inert_marker="$(inert_marker_dir)/$marker_name"
    if ((dry_run)); then
        printf 'Would archive %s files to %s, remove them, and leave %s.\n' \
            "${#inert_file_list[@]}" "$inert_archive" "$inert_marker"
        printf 'The shims on PATH would then be the only Node, npm and npx to be found.\n'
        exit 0
    fi
    if ((inert_found)); then
        inert_note "replaced: $inert_old_archive (its install came back, so it is archived anew)" || true
    fi
    mkdir -p -- "$archive_dir"
    declare -a relative=()
    for path in "${inert_file_list[@]}"; do
        relative+=("${path#/}")
    done
    declare -a tar_command=()
    if ((${#inert_tar_command[@]})); then
        tar_command=("${inert_tar_command[@]}")
    else
        tar_command=(tar)
    fi
    inert_run 'archive the native Node install' 'run it where a password can be typed: sandwich inert' \
        "${tar_command[@]}" -C / -zcf "$inert_archive" "${relative[@]}" || {
        rm -f -- "$inert_archive"
        exit 1
    }
    # An archive missing a file would restore a half install, so the list is
    # checked against the archive before anything is removed.
    if comm -23 <(printf '%s\n' "${relative[@]}" | sort -u) \
        <(tar -tzf "$inert_archive" | sed 's#^\./##' | sort -u) | grep -q .; then
        inert_note "archive:  $inert_archive is missing files it should hold; nothing was removed" || true
        rm -f -- "$inert_archive"
        exit 1
    fi
    # The list that restores these files is written before any of them is removed,
    # so a failure part way through can never strand an archived-away install.
    record_pending="$(mktemp "$config/.inert.XXXXXX")"
    trap 'rm -f -- "$record_pending"' EXIT
    inert_record_write "$record_pending"
    mv -f -- "$record_pending" "$inerted_file"
    record_pending=""
    inert_own "$inerted_file"
    trap - EXIT
    declare -a rm_command=()
    if ((${#inert_rm_command[@]})); then
        rm_command=("${inert_rm_command[@]}")
    else
        rm_command=(rm -f)
    fi
    inert_run 'remove the native Node install' 'run it where a password can be typed: sandwich inert' \
        "${rm_command[@]}" "${inert_file_list[@]}" || {
        # Nothing moved: the archive is a redundant copy of files still in place,
        # and the record is put back exactly as this run found it.
        rm -f -- "$inert_archive"
        if [[ -n "$previous_record" ]]; then
            printf '%s\n' "$previous_record" >"$inerted_file"
        else
            rm -f -- "$inerted_file"
        fi
        exit 1
    }
    # Directories are dropped only when they are empty, deepest first, so a chain
    # like /usr/lib/node_modules/npm/bin unwinds while a shared one such as
    # /usr/lib/node_modules survives and other packages keep their place.
    declare -a prune_dirs=()
    while IFS= read -r directory; do
        [[ -n "$directory" && "$directory" != "/" ]] && prune_dirs+=("$directory")
    done < <(
        for path in "${inert_file_list[@]}"; do
            directory="$path"
            while [[ "$directory" != "/" ]]; do
                directory="$(dirname -- "$directory")"
                printf '%s\n' "$directory"
            done
        done | sort -u | sort -r
    )
    if ((${#prune_dirs[@]})); then
        inert_run 'remove the empty directories' 'run it where a password can be typed: sandwich inert' \
            rmdir --ignore-fail-on-non-empty -- "${prune_dirs[@]}" || true
    fi
    temporary="$(mktemp "$config/.marker.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    inert_marker_text "$inert_archive" "${#inert_file_list[@]}" "$inert_pkgs" >"$temporary"
    # The directory may have just been pruned as empty; the note needs it back.
    inert_run 'make room for the note where the install was' 'run it where a password can be typed: sandwich inert' \
        mkdir -p "$(dirname -- "$inert_marker")" || exit 1
    declare -a install_command=()
    if ((${#inert_install_command[@]})); then
        install_command=("${inert_install_command[@]}")
    else
        install_command=(install -m 0644)
    fi
    inert_run 'write the note where the install was' 'run it where a password can be typed: sandwich inert' \
        "${install_command[@]}" "$temporary" "$inert_marker" || exit 1
    trap - EXIT
    if [[ -n "$inert_old_archive" && "$inert_old_archive" != "$inert_archive" && -f "$inert_old_archive" ]]; then
        rm -f -- "$inert_old_archive"
    fi
elif [[ "$inert_action" == show ]]; then
    inert_read_record
    if ((!inert_found)); then
        printf 'Nothing sandwich archived; the native Node install is where its packager left it.\n'
        exit 0
    fi
    if [[ ! -f "$inert_archive" ]]; then
        printf 'sandwich: the archive is gone (%s); reinstall Node from its packager\n' "$inert_archive" >&2
        exit 1
    fi
    declare -a archived_list=()
    while IFS= read -r path; do
        archived_list+=("/${path#./}")
    done < <(tar -tzf "$inert_archive")
    present=0
    for path in "${archived_list[@]}"; do
        [[ -e "$path" ]] && present=$((present + 1))
    done
    if ((present == ${#archived_list[@]})); then
        printf 'Already restored: every archived file is back on disk. Its packager reinstalled them.\n'
        printf '  archive:   %s (kept; sandwich inert would archive it anew)\n' "$inert_archive"
        rm -f -- "$inerted_file"
        exit 0
    fi
    if ((dry_run)); then
        printf 'Would restore %s of %s files from %s, leaving the %s the packager reinstalled alone.\n' \
            "$(( ${#archived_list[@]} - present ))" "${#archived_list[@]}" "$inert_archive" "$present"
        exit 0
    fi
    declare -a tar_command=()
    if ((${#inert_tar_command[@]})); then
        tar_command=("${inert_tar_command[@]}")
    else
        tar_command=(tar)
    fi
    # Files the packager put back in the meantime are left alone: extracting over
    # them would roll the package update back, so only what is missing comes back.
    inert_run 'restore the native Node install' 'run it where a password can be typed: sandwich uninert' \
        "${tar_command[@]}" --skip-old-files -C / -xpf "$inert_archive" || exit 1
    missing=0
    for path in "${archived_list[@]}"; do
        [[ -e "$path" ]] || missing=$((missing + 1))
    done
    if ((missing)); then
        inert_note "incomplete: $missing of ${#archived_list[@]} files are still missing; the archive and record are kept" || true
        exit 1
    fi
    if [[ -f "$inert_marker" ]] &&
        grep -q 'holds no Node code on purpose' "$inert_marker" 2>/dev/null; then
        inert_run 'remove the note sandwich left' 'run it where a password can be typed: sandwich uninert' \
            rm -f -- "$inert_marker" || true
    fi
    restored=1
fi

temporary="$(mktemp "$config/.mode.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
printf '%s\n' "$mode" >"$temporary"
mv -f -- "$temporary" "$config/mode"
inert_own "$config/mode"
trap - EXIT

# Reported last, so what is printed matches the state now on disk.
if [[ "$inert_action" == hide ]]; then
    inert_note "relocated: ${#inert_file_list[@]} files, $(du -h -- "$inert_archive" 2>/dev/null | cut -f1) archived" || true
    inert_note "archive:   $inert_archive" || true
    inert_note "marker:    $inert_marker" || true
    inert_note "shims:     node, npm and npx run on Bun; npx --help shows the Bun command" || true
elif [[ "$inert_action" == show && -n "$restored" ]]; then
    inert_note "restored:  ${#archived_list[@]} files from $inert_archive" || true
    if ((present)); then
        inert_note "kept:      $present of ${#archived_list[@]} files its packager had already put back" || true
    fi
    inert_note "modes:     taken from the archive; no permission was edited" || true
    rm -f -- "$inerted_file" "$inert_archive"
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
            printf 'The native Node install is archived away, so only the shims on PATH can be found. sandwich uninert restores it.\n'
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
