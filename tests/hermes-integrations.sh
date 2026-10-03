#!/usr/bin/env bash

# Offline fixtures: no live Hermes updates, owner scripts, or gateway restarts.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home"
export BUN_INSTALL="$HOME/.bun"
export SANDWICH_ENV_FILE="$fixture/.env"
export SANDWICH_HERMES_STATE_DIR="$fixture/state"
export HERMES_LIVE_DIR="$fixture/live"
export HERMES_PROJECTS_DIR="$fixture/projects"
export LOCALFLAME_ROOT="$fixture/no-localflame"
export TRACE="$fixture/calls"
export GATEWAY_ACTIVE=1
export FAIL_OWNER=0
mkdir -p "$HOME/.local/bin" "$BUN_INSTALL/bin" "$HERMES_LIVE_DIR/ui-tui" \
    "$HERMES_LIVE_DIR/web" "$fixture/sandwich/scripts" "$fixture/sandwich/lib" \
    "$fixture/sandwich/bin" "$HERMES_PROJECTS_DIR/first owner" "$HERMES_PROJECTS_DIR/second"
cp "$root/scripts/"{update-hermes,integrate-hermes,manage-integrations}.sh "$fixture/sandwich/scripts/"
cp "$root/lib/integration-config.sh" "$fixture/sandwich/lib/"
cat >"$HOME/.local/bin/hermes" <<'EOF'
#!/usr/bin/env bash
printf 'hermes %s\n' "$*" >>"$TRACE"
if [[ "$*" == 'gateway status' ]]; then [[ "$GATEWAY_ACTIVE" == 1 ]]; fi
EOF
cat >"$BUN_INSTALL/bin/bun" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then printf '1.3.14\n'; else printf 'bun %s\n' "$*" >>"$TRACE"; fi
EOF
cat >"$fixture/sandwich/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >>"$TRACE"
EOF
cat >"$fixture/sandwich/bin/sandwich" <<'EOF'
#!/usr/bin/env bash
printf 'sandwich %s\n' "$*" >>"$TRACE"
EOF
for name in 'first owner' second; do
    for script in integrate.sh audit.sh update.sh; do
        cat >"$HERMES_PROJECTS_DIR/$name/$script" <<'EOF'
#!/usr/bin/env bash
printf '%s/%s' "$(basename "$(dirname "$0")")" "$(basename "$0")" >>"$TRACE"
if (($#)); then printf ' <%s>' "$@" >>"$TRACE"; fi
printf '\n' >>"$TRACE"
[[ "$FAIL_OWNER" != 1 || "$0" != */integrate.sh ]]
EOF
    done
done
# Owner scripts intentionally stay non-executable, as supported by the live runner.
chmod +x "$HOME/.local/bin/hermes" "$BUN_INSTALL/bin/bun" "$fixture/sandwich/bin/"* \
    "$fixture/sandwich/scripts/"*.sh
for directory in "$HERMES_LIVE_DIR" "$HERMES_LIVE_DIR/ui-tui" "$HERMES_LIVE_DIR/web"; do
    printf '{}\n' >"$directory/package.json"
done
git -C "$HERMES_LIVE_DIR" init -q
git -C "$HERMES_LIVE_DIR" add .
git -C "$HERMES_LIVE_DIR" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture

runner="$fixture/sandwich/scripts/manage-integrations.sh"
updater="$fixture/sandwich/scripts/update-hermes.sh"
integrator="$fixture/sandwich/scripts/integrate-hermes.sh"

# Missing configuration is never silently enabled or written during a check/dry run.
"$runner" reconcile --dry-run >/dev/null
[[ ! -e "$SANDWICH_ENV_FILE" ]]
if "$runner" check </dev/null >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$SANDWICH_ENV_FILE" ]]
printf 'n\ny\n' | "$runner" configure >/dev/null
source "$SANDWICH_ENV_FILE"
[[ "$PROJECT_1_ENABLED" == false && "$PROJECT_2_ENABLED" == true ]]
[[ "$(stat -c %a "$SANDWICH_ENV_FILE")" == 600 ]]
: >"$TRACE"
"$runner" reconcile --strict >/dev/null
[[ "$(cat "$TRACE")" == $'second/integrate.sh\nsecond/audit.sh' ]]
if "$runner" configure </dev/null >/dev/null 2>&1; then exit 1; fi
printf 'ok - discovery saves individual choices and preserves existing configuration\n'

# Sparse indices, numeric order, disabled missing paths, and exact argument boundaries.
cat >"$SANDWICH_ENV_FILE" <<'EOF'
PROJECT_11="$HERMES_PROJECTS_DIR/second"
PROJECT_11_INTEGRATE=integrate.sh
PROJECT_11_CHECK=audit.sh
PROJECT_11_UPDATE=update.sh
PROJECT_2="$HERMES_PROJECTS_DIR/first owner"
PROJECT_2_INTEGRATE=integrate.sh
PROJECT_2_CHECK=audit.sh
PROJECT_2_UPDATE=update.sh
PROJECT_1000=/does/not/exist
PROJECT_1000_ENABLED=false
EOF
# Variables sourced above belong to this test shell, not its subprocesses.
: >"$TRACE"
"$runner" reconcile --strict >/dev/null
expected_owners=$'first owner/integrate.sh\nfirst owner/audit.sh\nsecond/integrate.sh\nsecond/audit.sh'
[[ "$(cat "$TRACE")" == "$expected_owners" ]]
printf 'PROJECT_2_ARGS=(--target "a b")\nPROJECT_2_CHECK_ARGS=()\n' >>"$SANDWICH_ENV_FILE"
: >"$TRACE"
"$runner" reconcile --strict >/dev/null
[[ "$(cat "$TRACE")" == $'first owner/integrate.sh <--target> <a b>\nfirst owner/audit.sh\nsecond/integrate.sh\nsecond/audit.sh' ]]
printf 'PROJECT_2_ARGS=()\n' >>"$SANDWICH_ENV_FILE"
printf 'ok - arbitrary project counts, numeric order, disabled entries, and owner arguments\n'

for action in check update; do
    : >"$TRACE"
    "$runner" "$action" --strict >/dev/null
    if [[ "$action" == check ]]; then
        [[ "$(cat "$TRACE")" == $'first owner/audit.sh\nsecond/audit.sh' ]]
    else
        [[ "$(cat "$TRACE")" == $'first owner/update.sh\nfirst owner/audit.sh\nsecond/update.sh\nsecond/audit.sh' ]]
    fi
done
: >"$TRACE"
"$integrator" --dry-run >/dev/null
[[ ! -s "$TRACE" && ! -e "$SANDWICH_HERMES_STATE_DIR" ]]
printf 'ok - check/update contracts and dry-run isolation\n'

: >"$TRACE"
"$updater" --yes >/dev/null
expected_update=$'hermes gateway status\nhermes update --yes'
[[ "$(cat "$TRACE")" == "$expected_update" ]]
[[ "$(cat "$SANDWICH_HERMES_STATE_DIR/pending-integration-gateway")" == 1 ]]
"$integrator" --strict >/dev/null
[[ "$(cat "$TRACE")" == "$expected_update"$'\n'"$expected_owners"$'\nsandwich doctor\nhermes gateway restart' ]]
[[ ! -e "$SANDWICH_HERMES_STATE_DIR/pending-integration-gateway" ]]
printf 'ok - update plus integrate retains the original call order, builds, checks, and restart\n'

: >"$TRACE"
"$updater" >/dev/null
FAIL_OWNER=1 "$integrator" --strict >/dev/null 2>&1 && exit 1
[[ -f "$SANDWICH_HERMES_STATE_DIR/pending-integration-gateway" ]]
! grep -q 'gateway restart' "$TRACE"
: >"$TRACE"
"$integrator" --strict >/dev/null
[[ "$(cat "$TRACE")" == "$expected_owners"$'\nsandwich doctor\nhermes gateway restart' ]]
printf 'ok - failed integrations preserve restart state for a successful retry\n'

export GATEWAY_ACTIVE=0
: >"$TRACE"
"$updater" >/dev/null
"$integrator" --strict >/dev/null
! grep -q 'gateway restart' "$TRACE"
: >"$TRACE"
"$integrator" --strict >/dev/null
[[ "$(cat "$TRACE")" == $'hermes gateway status\n'"$expected_owners"$'\nsandwich doctor' ]]
printf 'ok - standalone integration and inactive gateway remain supported\n'
