#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SANDWICH_TEST_ROOT="$root"
export PATH="$root/bin:$HOME/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SANDWICH_BUN="${SANDWICH_BUN:-$HOME/.bun/bin/bun}"
export DO_NOT_TRACK=1

passed=0
failed=0

check() {
    local label="$1"
    shift
    if "$@"; then
        printf 'ok - %s\n' "$label"
        passed=$((passed + 1))
    else
        printf 'not ok - %s\n' "$label" >&2
        failed=$((failed + 1))
    fi
}

equals() {
    [[ "$1" == "$2" ]]
}

contains() {
    [[ "$1" == *"$2"* ]]
}

matches() {
    [[ "$1" =~ $2 ]]
}

node_version="$(node --version)"
check "node --version is a Node-compatible v-string" matches "$node_version" '^v[0-9]+\.[0-9]+\.[0-9]+$'
check "sandwich reports a semantic version" matches "$(sandwich --version)" '^[0-9]+\.[0-9]+\.[0-9]+$'
check "component manifest matches CLI version" \
    "$SANDWICH_BUN" -e '
        const root = process.env.SANDWICH_TEST_ROOT;
        const manifest = await Bun.file(`${root}/manifest.json`).json();
        const packageManifest = await Bun.file(`${root}/package.json`).json();
        if (manifest.schema_version !== "sandwich.component.v1") process.exit(1);
        if (manifest.version !== Bun.spawnSync([`${root}/bin/sandwich`, "--version"]).stdout.toString().trim()) process.exit(1);
        if (manifest.version !== packageManifest.version) process.exit(1);
        if (packageManifest.dependencies.amaro !== "1.1.11") process.exit(1);
        if (manifest.operations.hermes_update.human_confirmation !== true) process.exit(1);
        if (manifest.operations.hermes_check.mutating !== false) process.exit(1);
        if (manifest.integrations.hermes.source_mutation !== false) process.exit(1);
        if (manifest.operations.audit.mutating !== false) process.exit(1);
    '
check "node runtime is Bun" equals "$(node -p 'process.versions.bun')" "$("$SANDWICH_BUN" --version)"
check "node eval" equals "$(node -e 'process.stdout.write(String(6 * 7))')" "42"
check "node print" equals "$(node -p '6 * 7')" "42"
check "node stdin" equals "$(printf 'console.log(6 * 7)\n' | node)" "42"
check "node ESM stdin via --input-type=module" \
    equals \
    "$(printf 'const value = await Promise.resolve(42); process.stdout.write(String(value))\n' | node --input-type=module)" \
    "42"
check "node split --input-type module" \
    equals \
    "$(printf 'process.stdout.write(String(Boolean(process.versions.bun)))\n' | node --input-type module)" \
    "true"
check "node CommonJS stdin via --input-type=commonjs" \
    equals \
    "$(printf 'module.exports = { value: 42 }; process.stdout.write(String(module.exports.value))\n' | node --input-type=commonjs)" \
    "42"
check "node resolves generated base64 JavaScript data modules" \
    equals \
    "$(node --input-type=module -e 'const url = "data:text/javascript;base64,ZXhwb3J0IGNvbnN0IHZhbHVlPTQyOw=="; const loaded = await import(url); process.stdout.write(String(loaded.value));')" \
    "42"
check "node:module supplies position-preserving TypeScript stripping" \
    node --input-type=module -e '
        import { createRequire, stripTypeScriptTypes } from "node:module";
        const source = "const answer: number = 42;";
        const stripped = stripTypeScriptTypes(source);
        if (typeof createRequire !== "function") process.exit(1);
        if (stripped.length !== source.length) process.exit(1);
        if (stripped.includes(": number") || !stripped.includes("= 42;")) process.exit(1);
    '
check "node:module CommonJS default exposes TypeScript stripping" \
    node -e '
        const moduleApi = require("node:module");
        if (typeof moduleApi.stripTypeScriptTypes !== "function") process.exit(1);
        if (moduleApi.stripTypeScriptTypes("let value: string").includes(": string")) process.exit(1);
    '
check "node:module rejects TypeScript syntax that requires transformation" \
    node --input-type=module -e '
        import { stripTypeScriptTypes } from "node:module";
        try {
          stripTypeScriptTypes("enum Answer { Value = 42 }");
          process.exit(1);
        } catch (error) {
          if (!String(error?.message).includes("not supported")) process.exit(1);
        }
    '
check "node:module fails loudly for unimplemented transform mode" \
    node --input-type=module -e '
        import { stripTypeScriptTypes } from "node:module";
        try {
          stripTypeScriptTypes("enum Answer { Value = 42 }", { mode: "transform" });
          process.exit(1);
        } catch (error) {
          if (!String(error?.message).includes("position-preserving strip mode only")) process.exit(1);
        }
    '
check "node:module bridges DSH's zero-root profile watcher loader" \
    node --input-type=module -e '
        import { createRequire } from "node:module";
        const addon = createRequire(import.meta.url)("node-addon-require-builtin");
        const internal = addon.requireBuiltin("internal/modules/esm/loader");
        const loader = internal.getOrInitializeCascadedLoader();
        const loaded = await loader.import("node:path", import.meta.url, {});
        if (typeof loaded.join !== "function") process.exit(1);
        if (!(loader.loadCache instanceof Map)) process.exit(1);
    '
check "node:module loader bridge refuses private modules outside its contract" \
    node --input-type=module -e '
        import { createRequire } from "node:module";
        const addon = createRequire(import.meta.url)("node-addon-require-builtin");
        try {
          addon.requireBuiltin("internal/not-supported");
          process.exit(1);
        } catch (error) {
          if (!String(error?.message).includes("does not expose Node private module")) process.exit(1);
        }
    '

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/node_modules/.bin"
cat >"$fixture/node_modules/.bin/hello-bun" <<'EOF'
#!/usr/bin/env node
process.stdout.write(`hello:${process.versions.bun}`)
EOF
chmod +x "$fixture/node_modules/.bin/hello-bun"

check "npx uses bunx with Bun runtime" \
    contains "$(cd "$fixture" && npx --no-install hello-bun)" "hello:$("$SANDWICH_BUN" --version)"
check "npm version is valid semver" matches "$(npm --version)" '^[0-9]+\.[0-9]+\.[0-9]+$'
check "npx version matches npm compatibility version" equals "$(npx --version)" "$(npm --version)"
check "corepack resolves to Sandwich" contains "$(corepack --version)" "sandwich-"

mkdir -p "$fixture/fixture-dep"
cat >"$fixture/fixture-dep/package.json" <<'EOF'
{
  "name": "fixture-dep",
  "version": "1.0.0"
}
EOF
cat >"$fixture/package.json" <<'EOF'
{
  "name": "sandwich-fixture",
  "private": true,
  "dependencies": {
    "fixture-dep": "file:./fixture-dep"
  },
  "scripts": {
    "runtime": "node -e \"process.stdout.write(process.versions.bun)\""
  }
}
EOF
(
    cd "$fixture"
    "$SANDWICH_BUN" install --lockfile-only --ignore-scripts >/dev/null
)
check "npm run forces Bun recursively" \
    equals "$(cd "$fixture" && npm run --silent runtime)" "$("$SANDWICH_BUN" --version)"
check "pnpm script shorthand maps to Bun run" \
    equals "$(cd "$fixture" && pnpm runtime)" "$("$SANDWICH_BUN" --version)"

mkdir -p "$fixture/prefix-package"
cat >"$fixture/prefix-package/package.json" <<'EOF'
{
  "name": "prefix-package",
  "private": true,
  "scripts": {
    "runtime": "node -e \"process.stdout.write(process.cwd() + ':' + process.versions.bun)\""
  }
}
EOF
check "npm run --prefix maps to Bun --cwd and keeps Bun runtime" \
    equals \
    "$(cd "$fixture" && npm run runtime --prefix prefix-package)" \
    "$fixture/prefix-package:$("$SANDWICH_BUN" --version)"

cat >"$fixture/node-test.mjs" <<'EOF'
import test from "node:test";
import assert from "node:assert/strict";

test("Sandwich maps node --test to Bun's test runner", () => {
  assert.equal(6 * 7, 42);
});
EOF
check "node --test maps to Bun test" node --test "$fixture/node-test.mjs"

check "npm ci uses frozen bun.lock" \
    bash -c 'cd "$1" && npm ci --ignore-scripts --no-audit --no-fund --progress=false >/dev/null' _ "$fixture"

mkdir -p "$fixture/npm-lock-only"
cat >"$fixture/npm-lock-only/package.json" <<'EOF'
{
  "name": "npm-lock-only",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "fixture-dep": "file:../fixture-dep"
  }
}
EOF
cat >"$fixture/npm-lock-only/package-lock.json" <<'EOF'
{
  "name": "npm-lock-only",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "npm-lock-only",
      "version": "1.0.0",
      "dependencies": {
        "fixture-dep": "file:../fixture-dep"
      }
    }
  }
}
EOF
check "npm ci keeps its frozen compatibility lock outside the project" \
    bash -c 'cd "$1" && SANDWICH_TRANSIENT_LOCK_DIR="$1/transient-state" npm ci --workspaces=false >/dev/null && compgen -G "transient-state/*.bun.lock" >/dev/null && test ! -e bun.lock && test ! -e bun.lockb' _ "$fixture/npm-lock-only"

check "user installer check is read-only and succeeds" "$root/scripts/install-user.sh" --check
check "foreign runtime audit is read-only and succeeds" \
    "$root/scripts/purge-foreign-runtimes.sh" --check
for retired in \
    "$root/config/hermes.bun.lock" \
    "$root/config/hermes.bunfig.toml" \
    "$root/patches/hermes-base.sha" \
    "$root/patches/hermes-sandwich.patch" \
    "$root/scripts/apply-hermes-maintenance.sh" \
    "$root/scripts/reconcile-hermes-runtime.sh" \
    "$root/scripts/refresh-hermes-artifacts.sh"; do
    check "Hermes source-mutation artifact is absent: ${retired#$root/}" test ! -e "$retired"
done
check "Hermes wrapper help is available" \
    contains "$(sandwich hermes help)" "never patched"

check "npm root-only workspace install maps to the root filter" \
    bash -c 'cd "$1" && npm install --workspaces=false --no-save >/dev/null' _ "$fixture"

for file in "$root"/bin/* "$root"/lib/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
    check "bash syntax: ${file#$root/}" bash -n "$file"
done
check "top-level installer syntax" bash -n "$root/install.sh"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
