#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
env_file="${SANDWICH_ENV_FILE:-$root/.env}"
if [[ -f "$env_file" ]]; then
    source "$env_file"
fi
live="${HERMES_LIVE_DIR:-$HOME/.hermes/hermes-agent}"
mode="update"

usage() {
    cat <<'EOF'
Usage: sandwich hermes update [hermes-update options]
       sandwich hermes integrate [--strict] [--dry-run]
       sandwich hermes check

Updates an official Hermes installation while Sandwich supplies the external
Node/npm compatibility commands through Bun. Hermes source is never patched,
committed, rebased, or reconciled by Sandwich.
Run `sandwich hermes integrate` separately to apply configured project integrations.
EOF
}

case "${1:-}" in
    --check|check)
        mode="check"
        shift
        ;;
    --help|-h|help)
        usage
        exit 0
        ;;
esac

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export DO_NOT_TRACK=1
export CI=1
export SANDWICH_TRANSIENT_LOCK_DIR="${SANDWICH_HERMES_STATE_DIR:-$HOME/.local/state/sandwich/hermes}"
export PATH="$root/bin:$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"

hermes="$(command -v hermes 2>/dev/null || true)"
bun="$BUN_INSTALL/bin/bun"

[[ -n "$hermes" && -x "$hermes" ]] || {
    printf 'sandwich: official Hermes executable not found on PATH\n' >&2
    exit 127
}
[[ -x "$bun" ]] || {
    printf 'sandwich: Bun executable not found: %s\n' "$bun" >&2
    exit 127
}
[[ -d "$live/.git" || -f "$live/.git" ]] || {
    printf 'sandwich: official Hermes checkout not found: %s\n' "$live" >&2
    exit 1
}

print_status() {
    local changes
    changes="$(git -C "$live" status --porcelain --untracked-files=all)"
    printf 'Hermes through Sandwich\n'
    printf '  executable: %s\n' "$hermes"
    printf '  source:     %s\n' "$live"
    printf '  npm:        %s\n' "$(command -v npm)"
    printf '  bun:        %s (%s)\n' "$bun" "$("$bun" --version)"
    if [[ -n "$changes" ]]; then
        printf '  source:     MODIFIED\n'
        printf '%s\n' "$changes"
        return 1
    fi
    printf '  source:     pristine upstream checkout\n'
}

recover_interrupted_lock_stage() {
    local hidden="$live/.sandwich-package-lock.json"
    if [[ ! -e "$live/package-lock.json" && -f "$hidden" ]]; then
        mv -f -- "$hidden" "$live/package-lock.json"
        printf 'sandwich: restored package-lock.json after an interrupted Bun process\n' >&2
    fi
}

recover_interrupted_lock_stage

if [[ "$mode" == "check" ]]; then
    print_status
    exit
fi

[[ $# -eq 0 || "${1:-}" == -* ]] || {
    usage >&2
    exit 2
}

gateway_was_active=0
if "$hermes" gateway status >/dev/null 2>&1; then
    gateway_was_active=1
fi

print_status

# The official updater remains the only component that changes Hermes. Since
# the 2026-09-12 runtime refactor (rolled out here by the 2026-09-30 update)
# the updater provisions its own Node and npm through Hermes PM under
# ~/.hermes/tools, installs the ui-tui and web workspaces with a root-hoisted
# npm ci (receipt node_modules/.hermes-node-deps), and rebuilds the TUI and
# web UI itself. Sandwich must not reinstall those workspaces on Bun
# afterwards: Bun's filtered installs prune root-hoisted devDependencies
# (apps/shared's vitest), which breaks the web type-check with TS2307.
"$hermes" update "$@"

print_status
# Preserve the pre-update gateway state for the integration half, including
# retries after a failed owner script. The official updater handles its own restart.
mkdir -p -- "$SANDWICH_TRANSIENT_LOCK_DIR"
pending="$SANDWICH_TRANSIENT_LOCK_DIR/pending-integration-gateway"
pending_tmp="$(mktemp "$pending.XXXXXX")"
printf '%s\n' "$gateway_was_active" >"$pending_tmp"
mv -f -- "$pending_tmp" "$pending"
printf 'Hermes is current; its tracked source remains identical to upstream.\n'
printf 'Run sandwich hermes integrate to reapply configured integrations.\n'
