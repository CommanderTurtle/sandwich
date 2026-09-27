#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for argument in "$@"; do
    case "$argument" in
        --dry-run|--help|-h)
            exec "$root/scripts/manage-integrations.sh" reconcile "$@"
            ;;
        --strict) ;;
        *) printf 'Usage: sandwich hermes integrate [--strict] [--dry-run]\n' >&2; exit 2 ;;
    esac
done

env_file="${SANDWICH_ENV_FILE:-$root/.env}"
if [[ ! -f "$env_file" ]]; then
    [[ -t 0 ]] || {
        printf 'sandwich: run sandwich integrations configure, or copy .env-example to %s\n' "$env_file" >&2
        exit 1
    }
    "$root/scripts/manage-integrations.sh" configure
fi
source "$env_file"
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export DO_NOT_TRACK=1 CI=1
export SANDWICH_TRANSIENT_LOCK_DIR="${SANDWICH_HERMES_STATE_DIR:-$HOME/.local/state/sandwich/hermes}"
export PATH="$root/bin:$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"

hermes="$(command -v hermes 2>/dev/null || true)"
[[ -n "$hermes" && -x "$hermes" ]] || {
    printf 'sandwich: official Hermes executable not found on PATH\n' >&2
    exit 127
}

pending="$SANDWICH_TRANSIENT_LOCK_DIR/pending-integration-gateway"
gateway_was_active=0
if [[ -f "$pending" ]]; then
    read -r gateway_was_active <"$pending"
    [[ "$gateway_was_active" == 0 || "$gateway_was_active" == 1 ]] || {
        printf 'sandwich: invalid gateway state: %s\n' "$pending" >&2
        exit 1
    }
elif "$hermes" gateway status >/dev/null 2>&1; then
    gateway_was_active=1
fi

"$root/scripts/manage-integrations.sh" reconcile "$@"
"$root/bin/sandwich" doctor
if [[ "$gateway_was_active" == 1 ]]; then
    "$hermes" gateway restart
fi
rm -f -- "$pending"
printf 'Hermes integrations are reconciled.\n'
