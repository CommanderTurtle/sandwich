#!/usr/bin/env bash

# Canonical regression chain for the 2026-09-30 Hermes update. Unlike the
# offline fixtures, these checks exercise the live installations: the runtime
# contract published by `hermes --print-runtime-command`, the integration
# scripts that hung after the 2026-09-12 runtime refactor, and dsh's plugin
# runtime under the Bun compatibility layer. Nothing here restarts the gateway.

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SANDWICH_TEST_ROOT="$root"
export PATH="$root/bin:$HOME/.local/bin:$HOME/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SANDWICH_BUN="${SANDWICH_BUN:-$HOME/.bun/bin/bun}"
export DO_NOT_TRACK=1

passed=0
failed=0

check() {
    local label="$1"
    shift
    local number=$((passed + failed + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$number" "$label"
        passed=$((passed + 1))
    else
        printf 'not ok %d - %s\n' "$number" "$label" >&2
        failed=$((failed + 1))
    fi
}

runtime_json="$(timeout 30 hermes --print-runtime-command 2>/dev/null || true)"

check "hermes --print-runtime-command prints a JSON argv array" \
    env RUNTIME_JSON="$runtime_json" "$SANDWICH_BUN" -e '
        const parts = JSON.parse(process.env.RUNTIME_JSON || "");
        if (!Array.isArray(parts) || typeof parts[0] !== "string") process.exit(1);
        if (!parts.includes("-I") || !parts.includes("-c")) process.exit(1);
    '

check "printed runtime interpreter exists and executes in isolation" \
    env RUNTIME_JSON="$runtime_json" "$SANDWICH_BUN" -e '
        const [python] = JSON.parse(process.env.RUNTIME_JSON || "[]");
        if (!python || !require("node:fs").existsSync(python)) process.exit(1);
        const probe = Bun.spawnSync([python, "-I", "-c", "print(6 * 7)"]);
        if (probe.exitCode !== 0 || probe.stdout.toString().trim() !== "42") process.exit(1);
    '

check "printed bootstrap code names the agent root both harnesses parse" \
    env RUNTIME_JSON="$runtime_json" "$SANDWICH_BUN" -e '
        const parts = JSON.parse(process.env.RUNTIME_JSON || "[]");
        const code = parts.slice(2).find((part) => part.includes("sys.path.insert(0,"));
        if (!code) process.exit(1);
        const marker = "sys.path.insert(0, ";
        const rest = code.slice(code.indexOf(marker) + marker.length);
        const agentRoot = rest.slice(1, rest.indexOf(")") - 1);
        const fs = require("node:fs");
        if (!fs.existsSync(agentRoot + "/hermes_bootstrap.py")) process.exit(1);
        if (!fs.existsSync(agentRoot + "/agent/shell_hooks.py")) process.exit(1);
    '

check "integration approval snippet imports shell_hooks under the printed runtime without hanging" \
    env RUNTIME_JSON="$runtime_json" timeout 60 "$SANDWICH_BUN" -e '
        const parts = JSON.parse(process.env.RUNTIME_JSON || "[]");
        const [python] = parts;
        const code = parts.slice(2).find((part) => part.includes("sys.path.insert(0,"));
        const marker = "sys.path.insert(0, ";
        const rest = code.slice(code.indexOf(marker) + marker.length);
        const agentRoot = rest.slice(1, rest.indexOf(")") - 1);
        const snippet = "import os, sys; " +
            "os.environ.pop(\"PYTHONHOME\", None); " +
            "os.environ.pop(\"PYTHONPATH\", None); " +
            "os.environ.pop(\"VIRTUAL_ENV\", None); " +
            "sys.path.insert(0, " + JSON.stringify(agentRoot) + "); " +
            "os.environ[\"HERMES_AGENT_ROOT\"] = " + JSON.stringify(agentRoot) + "; " +
            "import hermes_bootstrap; " +
            "from agent import shell_hooks; " +
            "print(\"hooks-ok\")";
        const proc = Bun.spawnSync([python, "-I", "-c", snippet], {
            env: { ...process.env, HERMES_AGENT_ROOT: agentRoot },
        });
        if (proc.exitCode !== 0 || !proc.stdout.toString().includes("hooks-ok")) {
            process.stderr.write(proc.stderr.toString());
            process.exit(1);
        }
    '

check "codebase-memory integrate-local.sh completes instead of hanging" \
    timeout 180 "$HOME/Hermes/codebase-memory-mcp/integrate-local.sh"

check "retrieval integrate.sh completes instead of hanging" \
    timeout 180 "$HOME/Hermes/retrieval/integrate.sh"

check "dsh resolves on PATH and reports a version" \
    bash -c 'command -v dsh >/dev/null && dsh --version >/dev/null'

check "dsh web boots under Bun with every plugin activated" \
    timeout 120 bash -c '
        port=$((20000 + RANDOM % 20000))
        workdir="$(mktemp -d)"
        log="$workdir/dsh-web.log"
        cd "$workdir"
        timeout 90 dsh web --port "$port" --no-open >"$log" 2>&1 &
        dsh_pid=$!
        for _ in $(seq 1 90); do
            grep -q "dsh web: http" "$log" 2>/dev/null && break
            kill -0 "$dsh_pid" 2>/dev/null || break
            sleep 1
        done
        kill "$dsh_pid" 2>/dev/null
        wait "$dsh_pid" 2>/dev/null
        grep -q "dsh web: http" "$log" &&
            ! grep -q "did not activate" "$log"
        rm -rf -- "$workdir"
    '

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
