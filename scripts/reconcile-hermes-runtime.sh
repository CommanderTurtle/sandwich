#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
live="${HERMES_LIVE_DIR:-$HOME/.hermes/hermes-agent}"
bun="${BUN_INSTALL:-$HOME/.bun}/bin/bun"

[[ -x "$bun" ]] || {
    printf 'Bun is unavailable at %s\n' "$bun" >&2
    exit 1
}
[[ -d "$live/.git" || -f "$live/.git" ]] || {
    printf 'not a Git worktree: %s\n' "$live" >&2
    exit 1
}
[[ -f "$live/bun.lock" ]] || {
    printf 'Hermes does not have its carried Bun lockfile\n' >&2
    exit 1
}
grep -Fq 'def _reconcile_carried_bun_lock(' \
    "$live/hermes_cli/update_cmd.py" || {
    printf 'Hermes does not have the current Sandwich update contract\n' >&2
    exit 1
}

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export CI=1
export DO_NOT_TRACK=1
export PATH="$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"
cd "$live"

if ! "$bun" install \
    --frozen-lockfile \
    --lockfile-only \
    --ignore-scripts \
    --no-progress; then
    "$bun" install --lockfile-only --ignore-scripts --no-progress
    "$bun" install \
        --frozen-lockfile \
        --lockfile-only \
        --ignore-scripts \
        --no-progress
fi

changed="$(
    git -C "$live" diff --name-only HEAD --
)"
if [[ -n "$changed" ]]; then
    [[ "$changed" == "bun.lock" ]] || {
        printf 'refusing to amend unrelated Hermes changes:\n%s\n' \
            "$changed" >&2
        exit 4
    }
    carried_count="$(
        git -C "$live" rev-list --count origin/main..HEAD
    )"
    ((carried_count > 0)) || {
        printf 'refusing to amend bun.lock without a carried local commit\n' >&2
        exit 4
    }
    git -C "$live" add -- bun.lock
    git -C "$live" commit --amend --no-edit --no-verify
fi

"$bun" install --frozen-lockfile --no-progress \
    --filter "./" \
    --filter "./apps/shared" \
    --filter "./ui-tui" \
    --filter "./web"
"$bun" run --bun --filter "./ui-tui" build
"$bun" run --bun --filter "./web" build
"$live/venv/bin/python" -m py_compile \
    "$live/hermes_cli/main.py" \
    "$live/hermes_cli/update_cmd.py"
"$root/bin/sandwich" doctor

printf 'Hermes Bun workspaces are frozen, built, and current.\n'
