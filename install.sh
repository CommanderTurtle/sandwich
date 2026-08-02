#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
mode=apply
upgrade_bun=0
with_hermes=0
purge_foreign=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [--check] [--upgrade-bun] [--with-hermes] [--purge-foreign]

  --check         inspect the install without changing anything
  --upgrade-bun   update an existing Bun stable installation first
  --with-hermes   verify an existing official Hermes install through Sandwich;
                  this never changes Hermes source
  --purge-foreign remove Debian Node packages and known user Node managers
                  after an exact interactive confirmation

The default install is user-scoped. Existing command shims and shell files are
backed up under ~/.local/state/sandwich before replacement.
EOF
}

while (($#)); do
    case "$1" in
        --check) mode=check ;;
        --upgrade-bun) upgrade_bun=1 ;;
        --with-hermes) with_hermes=1 ;;
        --purge-foreign) purge_foreign=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'sandwich: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export DO_NOT_TRACK=1
bun="$BUN_INSTALL/bin/bun"

if [[ "$mode" == check ]]; then
    if [[ -x "$bun" ]]; then
        printf 'Bun %s (%s)\n' "$("$bun" --version)" "$("$bun" --revision)"
    else
        printf 'Bun is not installed at %s\n' "$bun"
    fi
    "$root/scripts/install-user.sh" --check
    if [[ "$with_hermes" -eq 1 ]]; then
        "$root/scripts/update-hermes.sh" --check
    fi
    if [[ "$purge_foreign" -eq 1 ]]; then
        "$root/scripts/purge-foreign-runtimes.sh" --check
    fi
    exit 0
fi

if [[ ! -x "$bun" ]]; then
    command -v curl >/dev/null 2>&1 || {
        echo 'sandwich: curl is required to install Bun' >&2
        exit 1
    }
    printf 'Installing Bun from the official installer...\n'
    curl -fsSL https://bun.com/install | bash
elif [[ "$upgrade_bun" -eq 1 ]]; then
    "$bun" upgrade --stable
fi

"$root/scripts/install-user.sh" --apply
if [[ "$purge_foreign" -eq 1 ]]; then
    [[ -t 0 ]] || {
        echo 'sandwich: --purge-foreign requires an interactive terminal' >&2
        exit 1
    }
    printf 'Type PURGE-FOREIGN-JS to remove other JavaScript runtimes: '
    read -r purge_confirmation
    "$root/scripts/purge-foreign-runtimes.sh" \
        --apply \
        --confirm "$purge_confirmation"
fi
if [[ "$with_hermes" -eq 1 ]]; then
    "$root/scripts/update-hermes.sh" --check
fi

printf '\nSandwich is ready. Open a new shell or run: source ~/.bashrc\n'
if [[ "$with_hermes" -eq 1 ]]; then
    printf 'Update Hermes with: sandwich hermes update\n'
fi
