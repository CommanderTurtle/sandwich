#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode="--check"
allow_active=false
live="${HERMES_LIVE_DIR:-$HOME/.hermes/hermes-agent}"
patch="$root/patches/hermes-sandwich.patch"
base_file="$root/patches/hermes-base.sha"
lock_artifact="$root/config/hermes.bun.lock"
bunfig_artifact="$root/config/hermes.bunfig.toml"
protected_roots="${SANDWICH_PROTECTED_ROOTS:-$HOME/Hermes:$HOME/Odysseus}"

for arg in "$@"; do
    case "$arg" in
        --check|--apply)
            mode="$arg"
            ;;
        --allow-active)
            allow_active=true
            ;;
        *)
            printf 'usage: %s [--check|--apply] [--allow-active]\n' "$0" >&2
            exit 2
            ;;
    esac
done

[[ -d "$live/.git" || -f "$live/.git" ]] || {
    printf 'not a Git worktree: %s\n' "$live" >&2
    exit 1
}
for artifact in "$patch" "$base_file" "$lock_artifact" "$bunfig_artifact"; do
    [[ -f "$artifact" ]] || {
        printf 'missing maintenance artifact: %s\n' "$artifact" >&2
        exit 1
    }
done

maintenance_current() {
    [[ -f "$live/bun.lock" && -f "$live/bunfig.toml" ]] || return 1
    grep -Fq 'def _run_bun_install_deterministic(' \
        "$live/hermes_cli/main.py" || return 1
    grep -Fq 'def _reconcile_carried_bun_lock(' \
        "$live/hermes_cli/main.py" || return 1
    grep -Fq '"packageManager": "bun@' "$live/package.json" || return 1
    grep -Fq '"@hermes/shared": "workspace:*"' \
        "$live/web/package.json" || return 1
}

printf 'Hermes Bun maintenance\n'
printf '  live:        %s\n' "$live"
printf '  live HEAD:   %s\n' "$(git -C "$live" rev-parse HEAD)"
printf '  patch base:  %s\n' "$(tr -d '[:space:]' <"$base_file")"

if maintenance_current; then
    printf '  result: current; Hermes owns a clean carried Bun compatibility commit\n'
    exit 0
fi

base_head="$(tr -d '[:space:]' <"$base_file")"
live_head="$(git -C "$live" rev-parse HEAD)"
[[ "$live_head" == "$base_head" ]] || {
    printf 'refusing: the reviewed patch targets a different Hermes upstream commit\n' >&2
    printf 'update Sandwich or refresh its reviewed Hermes artifacts first\n' >&2
    exit 1
}

blockers=0
for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    cmdline="$({ tr '\0' ' ' <"$proc/cmdline"; } 2>/dev/null || true)"
    cwd="$(readlink -f "$proc/cwd" 2>/dev/null || true)"
    if [[ "$cmdline" == *"$live"* || "$cwd" == "$live"* ]]; then
        printf '  process blocker: pid=%s cwd=%s cmd=%s\n' \
            "$pid" "$cwd" "$cmdline"
        blockers=$((blockers + 1))
    fi
done

if command -v docker >/dev/null 2>&1; then
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        compose_dir="$(
            docker inspect \
                --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
                "$container" 2>/dev/null || true
        )"
        IFS=: read -r -a protected <<<"$protected_roots"
        for protected_root in "${protected[@]}"; do
            [[ -n "$protected_root" ]] || continue
            [[ "$protected_root" == /* ]] || {
                printf 'invalid non-absolute SANDWICH_PROTECTED_ROOTS entry: %s\n' \
                    "$protected_root" >&2
                exit 2
            }
            case "$compose_dir" in
                "$protected_root"|"$protected_root"/*)
                    printf '  container blocker: %s (%s)\n' \
                        "$container" "$compose_dir"
                    blockers=$((blockers + 1))
                    break
                    ;;
            esac
        done
    done < <(docker ps -q 2>/dev/null || true)
fi

if ((blockers)); then
    if [[ "$allow_active" == true ]]; then
        printf '  warning: continuing with %d active production blocker(s) by explicit override\n' \
            "$blockers" >&2
    else
        printf '  result: REFUSED (%d active production blocker(s)); pass --allow-active only during an authorized maintenance window\n' \
            "$blockers" >&2
        exit 3
    fi
fi

tracked_changes="$(
    git -C "$live" status --porcelain --untracked-files=no
)"
[[ -z "$tracked_changes" ]] || {
    printf 'refusing to mix the maintenance profile with tracked worktree changes\n' >&2
    printf '%s\n' "$tracked_changes" >&2
    exit 4
}

if [[ "$mode" == "--check" ]]; then
    git -C "$live" apply --check "$patch"
    printf '  result: ready; pass --apply%s during the maintenance window\n' \
        "$([[ "$allow_active" == true ]] && printf ' --allow-active')"
    exit 0
fi

git -C "$live" apply --check "$patch"
git -C "$live" apply "$patch"
install -m 0644 -- "$lock_artifact" "$live/bun.lock"
install -m 0644 -- "$bunfig_artifact" "$live/bunfig.toml"

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export DO_NOT_TRACK=1
export PATH="$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"
cd "$live"
bun install --frozen-lockfile --no-progress \
    --filter "./" \
    --filter "./ui-tui" \
    --filter "./web"
bun run --bun --filter "./ui-tui" build
bun run --bun --filter "./web" build
"$live/venv/bin/python" -m py_compile "$live/hermes_cli/main.py"

git -C "$live" add -A
git -C "$live" \
    -c user.name=CommanderTurtle \
    -c user.email=CommanderTurtle@users.noreply.github.com \
    commit --no-verify -m "Keep Hermes updates native to Bun"

"$root/bin/sandwich" doctor

printf '  result: applied, built, and committed as one carried compatibility change\n'
printf '  normal `hermes update` now preserves and refreshes that commit automatically\n'
