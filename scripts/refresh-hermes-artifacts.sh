#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
live="${HERMES_LIVE_DIR:-$HOME/.hermes/hermes-agent}"
patch="$root/patches/hermes-sandwich.patch"
base_file="$root/patches/hermes-base.sha"
lock_artifact="$root/config/hermes.bun.lock"
bunfig_artifact="$root/config/hermes.bunfig.toml"
upstream_ref="${HERMES_UPSTREAM_REF:-origin/main}"

[[ -d "$live/.git" || -f "$live/.git" ]] || {
    printf 'not a Git worktree: %s\n' "$live" >&2
    exit 1
}
[[ -f "$live/bun.lock" && -f "$live/bunfig.toml" ]] || {
    printf 'live Hermes Bun artifacts are missing\n' >&2
    exit 1
}

live_head="$(git -C "$live" rev-parse HEAD)"
origin_head="$(git -C "$live" rev-parse "$upstream_ref")"
git -C "$live" merge-base --is-ancestor "$origin_head" "$live_head" || {
    printf 'refusing: %s is not an ancestor of the managed Hermes checkout\n' \
        "$upstream_ref" >&2
    exit 1
}
[[ -z "$(git -C "$live" status --porcelain --untracked-files=no)" ]] || {
    printf 'refusing to capture a dirty Hermes worktree\n' >&2
    exit 4
}

allowed=(
    hermes_cli/banner.py
    hermes_cli/gateway.py
    hermes_cli/main.py
    package.json
    skills/ctx-mode/DESCRIPTION.md
    skills/ctx-mode/context-mode/SKILL.md
    skills/ctx-mode/context-mode/references/anti-patterns.md
    skills/ctx-mode/context-mode/references/patterns-javascript.md
    skills/ctx-mode/context-mode/references/patterns-python.md
    skills/ctx-mode/context-mode/references/patterns-shell.md
    skills/ctx-mode/ctx-doctor/SKILL.md
    skills/ctx-mode/ctx-index/SKILL.md
    skills/ctx-mode/ctx-insight/SKILL.md
    skills/ctx-mode/ctx-purge/SKILL.md
    skills/ctx-mode/ctx-search/SKILL.md
    skills/ctx-mode/ctx-stats/SKILL.md
    skills/ctx-mode/ctx-upgrade/SKILL.md
    tests-js/package-json-lazy-deps.test.ts
    tests/hermes_cli/test_banner.py
    tests/hermes_cli/test_cmd_update.py
    tests/hermes_cli/test_systemd_optional_directives.py
    tests/hermes_cli/test_web_ui_build.py
    ui-tui/package.json
    ui-tui/packages/hermes-ink/package.json
    ui-tui/src/__tests__/gatewayClient.test.ts
    ui-tui/src/gatewayClient.ts
    web/package.json
)

expected="$(printf '%s\n' "${allowed[@]}" bun.lock bunfig.toml | sort)"
actual="$(
    git -C "$live" diff --name-only "$origin_head" "$live_head" | sort
)"
[[ "$actual" == "$expected" ]] || {
    printf 'refusing: the managed Hermes diff no longer matches the reviewed allowlist\n' >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    exit 4
}

git -C "$live" diff \
    --binary \
    --output="$patch" \
    "$origin_head" \
    "$live_head" \
    -- \
    "${allowed[@]}"
printf '%s\n' "$origin_head" >"$base_file"
install -m 0644 "$live/bun.lock" "$lock_artifact"
install -m 0644 "$live/bunfig.toml" "$bunfig_artifact"

printf 'Hermes maintenance artifacts refreshed\n'
printf '  base:  %s\n' "$origin_head"
printf '  patch: %s\n' "$(sha256sum "$patch" | cut -d' ' -f1)"
printf '  lock:  %s\n' "$(sha256sum "$lock_artifact" | cut -d' ' -f1)"
