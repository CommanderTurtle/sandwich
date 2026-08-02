#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
live="${HERMES_LIVE_DIR:-$HOME/.hermes/hermes-agent}"
mode="update"

usage() {
    cat <<'EOF'
Usage: sandwich hermes update [hermes-update options]
       sandwich hermes check

Updates an official Hermes installation while Sandwich supplies the external
Node/npm compatibility commands through Bun. Hermes source is never patched,
committed, rebased, or reconciled by Sandwich.
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

print_status

# The official updater remains the only component that changes Hermes. Its
# npm/node subprocesses resolve to Sandwich's shims through PATH and therefore
# execute on Bun without adding a second JavaScript runtime.
"$hermes" update "$@"

# A previously interrupted update can already be at the newest source commit
# while its JavaScript workspaces were never rebuilt. Reconcile those generated
# dependencies with a frozen lock kept in Sandwich state. The npm shim copies
# it into place only for the Bun process and removes it through an EXIT trap.
cd "$live"
"$root/bin/npm" ci \
    --include=dev \
    --no-fund \
    --no-audit \
    --progress=false \
    --workspaces=false
workspace_args=()
for workspace in ui-tui web; do
    [[ -f "$workspace/package.json" ]] && \
        workspace_args+=(--workspace "$workspace")
done
if ((${#workspace_args[@]})); then
    "$root/bin/npm" ci \
        --include=dev \
        --no-fund \
        --no-audit \
        --progress=false \
        "${workspace_args[@]}"
fi
[[ -f ui-tui/package.json ]] && "$bun" run --bun --filter "./ui-tui" build
[[ -f web/package.json ]] && "$bun" run --bun --filter "./web" build

print_status
"$root/bin/sandwich" doctor
printf 'Hermes is current; its tracked source remains identical to upstream.\n'
