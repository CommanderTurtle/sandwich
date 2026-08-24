#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../lib/common.sh"

web_dir="${1:-$PWD}"
[[ -d "$web_dir" ]] || bs_die "Hermes web directory does not exist: $web_dir"
web_dir="$(cd -- "$web_dir" && pwd -P)"

package_json="$web_dir/package.json"
vite_config="$web_dir/vite.config.ts"

is_known_preset_mismatch() {
    [[ -f "$package_json" && -f "$vite_config" ]] &&
        grep -Fq '"@rolldown/plugin-babel": "0.2.3"' "$package_json" &&
        grep -Fq '"@vitejs/plugin-react": "6.0.3"' "$package_json" &&
        grep -Fq 'preset.rolldown.filter.code =' "$vite_config"
}

# Preserve the upstream build unchanged unless this is the one dependency/type
# combination where npm and Bun intentionally expose different type topology.
if ! is_known_preset_mismatch; then
    exec "$SANDWICH_BIN" run --cwd "$web_dir" --bun build
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sandwich-hermes-web.XXXXXX")"
node_log="$tmp_dir/tsconfig-node.log"
cleanup() {
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

set +e
"$SANDWICH_BIN" run --cwd "$web_dir" --bun tsc \
    -p tsconfig.node.json --noEmit --pretty false >"$node_log" 2>&1
node_status=$?
set -e

if [[ "$node_status" -eq 0 ]]; then
    cleanup
    trap - EXIT HUP INT TERM
    exec "$SANDWICH_BIN" run --cwd "$web_dir" --bun build
fi

mapfile -t diagnostics < <(grep -E 'error TS[0-9]+:' "$node_log" || true)
if [[ "${#diagnostics[@]}" -ne 1 ]] ||
   [[ "${diagnostics[0]}" != *"vite.config.ts("* ]] ||
   [[ "${diagnostics[0]}" != *"error TS18048: 'preset.rolldown.filter' is possibly 'undefined'."* ]]; then
    cat "$node_log" >&2
    exit "$node_status"
fi

bs_note "Hermes web: applying the npm/Bun React Compiler type compatibility path"

# `tsc -b` checks the application and the Vite configuration. The only Vite
# diagnostic above is a declaration mismatch: reactCompilerPreset() supplies
# `filter` at runtime, while @rolldown/plugin-babel types it as optional. Check
# every application source normally, then run Vite against the real upstream
# config. No tracked Hermes file or dependency declaration is changed.
"$SANDWICH_BIN" run --cwd "$web_dir" --bun tsc \
    -p tsconfig.app.json --noEmit --pretty false
"$SANDWICH_BIN" run --cwd "$web_dir" --bun vite build
