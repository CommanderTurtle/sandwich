#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode="${1:?shadow or unshadow required}"
shift
config="${SANDWICH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/sandwich}"
shell_name="" dry_run=0
for argument in "$@"; do
    case "$argument" in
        --shell=*) shell_name="${argument#*=}" ;;
        --dry-run|--dryrun) dry_run=1 ;;
        --help|-h) printf 'usage: sandwich %s [--dry-run] [--shell=bash|zsh|fish|powershell]\n' "$mode"; exit 0 ;;
        *) printf 'usage: sandwich %s [--dry-run] [--shell=bash|zsh|fish|powershell]\n' "$mode" >&2; exit 64 ;;
    esac
done
case "$mode" in shadow|unshadow) ;; *) exit 64 ;; esac
case "$shell_name" in ''|bash|zsh|fish|powershell) ;; *) printf 'sandwich: unsupported shell: %s\n' "$shell_name" >&2; exit 64 ;; esac
if ((dry_run)); then
    printf 'Would set %s/mode to %s; no files or PATH changed.\n' "$config" "$mode"
    exit 0
fi
mkdir -p -- "$config"
temporary="$(mktemp "$config/.mode.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
printf '%s\n' "$mode" >"$temporary"
mv -f -- "$temporary" "$config/mode"
trap - EXIT

if [[ -z "$shell_name" ]]; then
    printf 'Sandwich mode: %s\n' "$mode"
    if [[ "$mode" == shadow ]]; then
        printf 'For this Bash/Zsh shell: eval "$(sandwich shadow --shell=bash)"\n'
        printf 'This places Sandwich before mise without modifying mise.\n'
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
