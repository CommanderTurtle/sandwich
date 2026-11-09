#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$root/lib/common.sh"
mode="${1:---check}"
local_bin="$HOME/.local/bin"
bun_bin="$BUN_INSTALL_BIN"
global_dir="$BUN_INSTALL_GLOBAL_DIR"
state_root="$HOME/.local/state/sandwich"
bashrc="$HOME/.bashrc"
commands=(sandwich node npm npx pnpm yarn corepack)
link_dirs=("$local_bin" "$bun_bin")

case "$mode" in
    --check|--apply|--reshadow) ;;
    *)
        printf 'usage: %s [--check|--apply|--reshadow]\n' "$0" >&2
        exit 2
        ;;
esac

printf 'Sandwich user install\n'
printf '  source: %s\n' "$root"
printf '  bins:   %s, %s\n' "$local_bin" "$bun_bin"
printf '  global: %s\n' "$global_dir"
printf '  bashrc: %s\n' "$bashrc"
if [[ -n "$SANDWICH_BUN_STALE_ROOTS" ]]; then
    printf '  warning: %s also holds an installed Bun global tree\n' "$SANDWICH_BUN_STALE_ROOTS"
    printf '           reinstall its packages into %s, then remove that prefix and its PATH entry\n' "$global_dir"
fi

for name in "${commands[@]}"; do
    [[ -x "$root/bin/$name" ]] || {
        printf 'missing executable: %s\n' "$root/bin/$name" >&2
        exit 1
    }
    for link_dir in "${link_dirs[@]}"; do
        printf '  %-13s %s -> %s\n' \
            "$name" \
            "${link_dir}/${name}" \
            "$root/bin/$name"
    done
done

# Drift: what a rewrite would change. --reshadow runs this after a tool manager
# updates a runtime, so the shadow is re-established without touching anything
# that already agrees with what was resolved.
drift=0
declare -a drift_reasons=()
declare -a foreign_victims=()

for link_dir in "${link_dirs[@]}"; do
    for name in "${commands[@]}"; do
        target="$link_dir/$name"
        if [[ ! -L "$target" || "$(readlink -f -- "$target" 2>/dev/null)" != "$root/bin/$name" ]]; then
            drift=1
            drift_reasons+=("shim link missing or redirected: $target")
        fi
    done
done
if ! bs_bunfig_setting globalDir || [[ "$SANDWICH_BUNFIG_VALUE" != "$global_dir" ]]; then
    drift=1
    drift_reasons+=("$HOME/.bunfig.toml does not record globalDir = $global_dir")
fi
if ! bs_bunfig_setting globalBinDir || [[ "$SANDWICH_BUNFIG_VALUE" != "$bun_bin" ]]; then
    drift=1
    drift_reasons+=("$HOME/.bunfig.toml does not record globalBinDir = $bun_bin")
fi
if ! grep -Fq "BUN_INSTALL_GLOBAL_DIR:-\"$global_dir\"" "$bashrc" 2>/dev/null; then
    drift=1
    drift_reasons+=("$bashrc block does not pin BUN_INSTALL_GLOBAL_DIR to $global_dir")
fi
# Unexecute is the user's decision, recorded by `sandwich shadow
# --unexecute`; a package update re-arms the native binaries, and re-running the
# command asks for the password it needs to disarm them again.
if [[ -f "$SANDWICH_CONFIG_DIR/unexecuted" ]]; then
    while IFS= read -r unexecuted_path; do
        [[ -n "$unexecuted_path" ]] || continue
        [[ -x "$unexecuted_path" ]] || continue
        if ((EUID == 0)); then
            chmod a-x -- "$unexecuted_path"
            printf '  inert:    %s (a package update restored the execute bit)\n' "$unexecuted_path"
        else
            drift=1
            drift_reasons+=("native binary is executable again: $unexecuted_path (sandwich shadow --unexecute)")
        fi
    done <"$SANDWICH_CONFIG_DIR/unexecuted"
fi
for name in bun bunx node npm npx pnpm pnpx yarn yarnpkg corepack; do
    candidate="$bun_bin/$name"
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    bs_is_shim "$candidate" && continue
    drift=1
    foreign_victims+=("$candidate")
    drift_reasons+=("runtime binary shadows the manager's copy: $candidate")
done

if (( ${#drift_reasons[@]} )); then
    printf '  drift:\n'
    for reason in "${drift_reasons[@]}"; do printf '    %s\n' "$reason"; done
else
    printf '  drift:    none\n'
fi

if [[ "$mode" == "--reshadow" && $drift -eq 0 ]]; then
    printf '  runtime:  %s (%s, via %s)\n' \
        "$SANDWICH_BIN" "$("$SANDWICH_BIN" --version)" "$(sandwich_bun_runtime_source "$SANDWICH_BIN")"
    printf '  result: already shadowed; nothing changed\n'
    exit 0
fi

if [[ "$mode" == "--check" ]]; then
    printf '  state:  %s\n' "$state_root"
    printf '  result: preview only; pass --apply to install\n'
    exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$state_root/backups/$timestamp"
mkdir -p -- "$backup" "$local_bin" "$bun_bin"

if (( ${#foreign_victims[@]} )); then
    mkdir -p -- "$backup/foreign-bins"
    for candidate in "${foreign_victims[@]}"; do
        printf '  retiring  %s (a tool manager owns this runtime; this directory leads PATH)\n' "$candidate"
        cp -a -- "$candidate" "$backup/foreign-bins/$(basename -- "$candidate")"
        rm -f -- "$candidate"
    done
fi

for link_dir in "${link_dirs[@]}"; do
    backup_dir="$backup/$(basename -- "$(dirname -- "$link_dir")")-$(basename -- "$link_dir")"
    mkdir -p -- "$backup_dir"
    for name in "${commands[@]}"; do
        target="$link_dir/$name"
        if [[ -e "$target" || -L "$target" ]]; then
            cp -a -- "$target" "$backup_dir/$name"
        fi
    done
done
[[ -f "$bashrc" ]] && cp -a -- "$bashrc" "$backup/bashrc"
[[ -f "$HOME/.bunfig.toml" ]] && cp -a -- "$HOME/.bunfig.toml" "$backup/bunfig.toml"

for link_dir in "${link_dirs[@]}"; do
    for name in "${commands[@]}"; do
        ln -sfn -- "$root/bin/$name" "$link_dir/$name"
    done
done
# Bun reads globalDir/globalBinDir from bunfig before BUN_INSTALL, so the copy
# written here records the root that was actually resolved instead of a baked
# literal; an externally chosen prefix (Mise, Omarchy, XDG) then survives.
generated_bunfig="$backup/bunfig.toml.generated"
while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        'globalDir = '*) printf 'globalDir = "%s"\n' "$global_dir" ;;
        'globalBinDir = '*) printf 'globalBinDir = "%s"\n' "$bun_bin" ;;
        *) printf '%s\n' "$line" ;;
    esac
done <"$root/config/bunfig.toml" >"$generated_bunfig"
install -m 0644 -- "$generated_bunfig" "$HOME/.bunfig.toml"

tmp_bashrc="$(mktemp "${bashrc}.sandwich.XXXXXX")"
trap 'rm -f -- "$tmp_bashrc"' EXIT
if [[ -f "$bashrc" ]]; then
    awk '
        $0 == "# >>> sandwich >>>" {
            managed = 1
            next
        }
        $0 == "# <<< sandwich <<<" {
            managed = 0
            next
        }
        !managed { print }
    ' "$bashrc" >"$tmp_bashrc"
fi
{
    printf '\n'
    # Bake the paths Sandwich resolved into the block so a fresh install starts
    # from the prefix actually in use (Mise, Omarchy, or XDG chosen). The ${VAR:-}
    # form keeps any setting the user exported above the block in charge.
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            'export BUN_INSTALL_BIN='*)
                printf 'export BUN_INSTALL_BIN="${BUN_INSTALL_BIN:-%s}"\n' "\"$bun_bin\""
                ;;
            'export BUN_INSTALL_GLOBAL_DIR='*)
                printf 'export BUN_INSTALL_GLOBAL_DIR="${BUN_INSTALL_GLOBAL_DIR:-%s}"\n' "\"$global_dir\""
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$root/config/shell-block.sh"
} >>"$tmp_bashrc"
chmod 0644 "$tmp_bashrc"
mv -f -- "$tmp_bashrc" "$bashrc"
trap - EXIT

printf '%s\n' "$backup" >"$state_root/latest-backup"
export BUN_INSTALL BUN_INSTALL_BIN BUN_INSTALL_GLOBAL_DIR DO_NOT_TRACK
case ":$PATH:" in *":$BUN_INSTALL_BIN:"*) ;; *) PATH="$BUN_INSTALL_BIN:$PATH" ;; esac
case ":$PATH:" in *":$local_bin:"*) ;; *) PATH="$local_bin:$PATH" ;; esac
export PATH

"$root/tests/compat.sh"
"$root/bin/sandwich" doctor
printf '  backup: %s\n' "$backup"
if [[ "$mode" == "--reshadow" ]]; then
    printf '  result: reshadowed (Bun %s via %s)\n' \
        "$("$SANDWICH_BIN" --version)" "$(sandwich_bun_runtime_source "$SANDWICH_BIN")"
else
    printf '  result: installed\n'
fi
