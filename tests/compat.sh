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
        if (manifest.operations.integrations_check.mutating !== false) process.exit(1);
        if (manifest.operations.integrations_reconcile.human_confirmation !== true) process.exit(1);
        if (manifest.operations.integrations_update.maintenance_window !== true) process.exit(1);
        if (manifest.operations.repository_audit.mutating !== false) process.exit(1);
        if (manifest.operations.repository_update.human_confirmation !== true) process.exit(1);
        if (manifest.operations.hermes_check.mutating !== false) process.exit(1);
        if (manifest.operations.check_expr.human_confirmation !== true) process.exit(1);
        if (manifest.integrations.hermes.source_mutation !== false) process.exit(1);
        if (manifest.operations.audit.mutating !== false) process.exit(1);
        if (manifest.operations.check_fence_preview.mutating !== false) process.exit(1);
        if (manifest.operations.check_fence_apply.human_confirmation !== true) process.exit(1);
        if (manifest.operations.check_zoo_preview.mutating !== false) process.exit(1);
        if (manifest.operations.check_zoo_apply.human_confirmation !== true) process.exit(1);
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

integration_fixture="$fixture/integrations"
integration_projects="$integration_fixture/Hermes"
integration_localflame="$integration_fixture/Deepseek/localflame"
mkdir -p "$integration_projects" "$integration_localflame"
for spec in \
    "$integration_localflame:doctor.sh,install.sh,update.sh" \
    "$integration_projects/hermes-workspace:audit.sh,integrate.sh,update.sh" \
    "$integration_projects/context-mode:audit.sh,integrate.sh,update.sh" \
    "$integration_projects/camofox/camofox-browser:audit.sh,integrate.sh,update.sh" \
    "$integration_projects/camofox-mcp:audit.sh,integrate.sh,update.sh" \
    "$integration_projects/codebase-memory-mcp:doctor-local.sh,integrate-local.sh,update-local.sh" \
    "$integration_projects/librarian:doctor.sh,integrate.sh,update.sh" \
    "$integration_projects/leetcoder:doctor.sh,integrate.sh,update.sh" \
    "$integration_projects/retrieval:doctor.sh,integrate.sh,update.sh" \
    "$integration_projects/persephone:scripts/doctor.sh,scripts/integrate.sh,scripts/update.sh"; do
    owner_dir="${spec%%:*}"
    scripts="${spec#*:}"
    mkdir -p "$owner_dir"
    old_ifs="$IFS"
    IFS=,
    set -- $scripts
    IFS="$old_ifs"
    for relative in "$@"; do
        mkdir -p "$(dirname -- "$owner_dir/$relative")"
        cat >"$owner_dir/$relative" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" >>"$SANDWICH_INTEGRATION_TEST_LOG"
EOF
        chmod +x "$owner_dir/$relative"
    done
done
integration_log="$integration_fixture/calls.log"
: >"$integration_log"
check "integration check delegates to all ten owner audits or doctors" \
    bash -c '
        HERMES_PROJECTS_DIR="$1" LOCALFLAME_ROOT="$2" \
        SANDWICH_INTEGRATION_TEST_LOG="$3" \
            "$4/scripts/manage-integrations.sh" check --strict >/dev/null &&
        [[ "$(wc -l <"$3")" == 10 ]]
    ' _ "$integration_projects" "$integration_localflame" "$integration_log" "$root"
: >"$integration_log"
check "integration reconciliation uses owner integrators then doctors" \
    bash -c '
        HERMES_PROJECTS_DIR="$1" LOCALFLAME_ROOT="$2" \
        SANDWICH_INTEGRATION_TEST_LOG="$3" \
            "$4/scripts/manage-integrations.sh" reconcile --strict >/dev/null &&
        [[ "$(wc -l <"$3")" == 20 ]]
    ' _ "$integration_projects" "$integration_localflame" "$integration_log" "$root"
: >"$integration_log"
check "integration update uses owner updaters then doctors" \
    bash -c '
        HERMES_PROJECTS_DIR="$1" LOCALFLAME_ROOT="$2" \
        SANDWICH_INTEGRATION_TEST_LOG="$3" \
            "$4/scripts/manage-integrations.sh" update --strict >/dev/null &&
        [[ "$(wc -l <"$3")" == 20 ]]
    ' _ "$integration_projects" "$integration_localflame" "$integration_log" "$root"

repository_fixture="$fixture/repository-owner"
mkdir -p "$repository_fixture"
git init --bare --initial-branch=main "$repository_fixture/source.git" >/dev/null
git init --bare --initial-branch=main "$repository_fixture/fork.git" >/dev/null
git init --initial-branch=main "$repository_fixture/seed" >/dev/null
git -C "$repository_fixture/seed" config user.name Fixture
git -C "$repository_fixture/seed" config user.email fixture@example.invalid
printf 'base\n' >"$repository_fixture/seed/state.txt"
git -C "$repository_fixture/seed" add state.txt
git -C "$repository_fixture/seed" commit -m base >/dev/null
git -C "$repository_fixture/seed" remote add source "$repository_fixture/source.git"
git -C "$repository_fixture/seed" remote add fork "$repository_fixture/fork.git"
git -C "$repository_fixture/seed" push source main >/dev/null
git -C "$repository_fixture/seed" push fork main >/dev/null
printf 'source\n' >>"$repository_fixture/seed/state.txt"
git -C "$repository_fixture/seed" commit -am source >/dev/null
git -C "$repository_fixture/seed" push source main >/dev/null
git clone "$repository_fixture/fork.git" "$repository_fixture/owner" >/dev/null
git -C "$repository_fixture/owner" remote rename origin fork
git -C "$repository_fixture/owner" remote add upstream "$repository_fixture/source.git"
git -C "$repository_fixture/owner" config user.name Fixture
git -C "$repository_fixture/owner" config user.email fixture@example.invalid
cat >"$repository_fixture/owner/doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
git diff --check
EOF
chmod +x "$repository_fixture/owner/doctor.sh"
git -C "$repository_fixture/owner" add doctor.sh
git -C "$repository_fixture/owner" commit -m doctor >/dev/null

repository_audit_output="$({
    "$root/bin/sandwich" repository audit \
        --root="$repository_fixture/owner" \
        --source-remote=upstream \
        --source-url="$repository_fixture/source.git" \
        --source-branch=main \
        --fork-remote=fork \
        --fork-url="$repository_fixture/fork.git" \
        --fork-branch=main \
        --doctor=doctor.sh
} 2>&1)"
check "repository audit reports source and fork divergence without mutation" \
    bash -c '
        [[ "$1" == *"source     behind=1 ahead=1 relation=clean-merge"* ]] &&
        [[ "$1" == *"fork       behind=0 ahead=1 relation=contained"* ]] &&
        [[ "$(git -C "$2" rev-parse HEAD)" != "$(git --git-dir="$3" rev-parse main)" ]]
    ' _ "$repository_audit_output" "$repository_fixture/owner" "$repository_fixture/source.git"

repository_update_output="$({
    "$root/bin/sandwich" repository update \
        --root="$repository_fixture/owner" \
        --source-remote=upstream \
        --source-url="$repository_fixture/source.git" \
        --source-branch=main \
        --fork-remote=fork \
        --fork-url="$repository_fixture/fork.git" \
        --fork-branch=main \
        --verify=doctor.sh
} 2>&1)"
check "repository update merges and verifies locally but never pushes" \
    bash -c '
        [[ "$1" == *"Repository update verified locally. No remote was pushed."* ]] &&
        [[ "$1" == *"git push"* ]] &&
        grep -q source "$2/state.txt" &&
        [[ "$(git --git-dir="$3" rev-parse main)" != "$(git -C "$2" rev-parse HEAD)" ]]
    ' _ "$repository_update_output" "$repository_fixture/owner" "$repository_fixture/fork.git"

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

mkdir -p "$fixture/hermes-web"
cat >"$fixture/hermes-web/package.json" <<'EOF'
{
  "name": "web",
  "private": true,
  "devDependencies": {
    "@rolldown/plugin-babel": "0.2.3",
    "@vitejs/plugin-react": "6.0.3"
  }
}
EOF
cat >"$fixture/hermes-web/vite.config.ts" <<'EOF'
const preset = reactCompilerPreset();
preset.rolldown.filter.code = /react/;
EOF
printf '{}\n' >"$fixture/hermes-web/tsconfig.app.json"
printf '{}\n' >"$fixture/hermes-web/tsconfig.node.json"
cat >"$fixture/fake-hermes-bun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDWICH_FAKE_BUN_LOG"
if [[ "$*" == *"tsconfig.node.json"* ]]; then
    if [[ "${SANDWICH_FAKE_UNEXPECTED:-0}" == "1" ]]; then
        printf "vite.config.ts(12,3): error TS9999: unexpected diagnostic.\n"
        exit 2
    fi
    printf "vite.config.ts(11,3): error TS18048: 'preset.rolldown.filter' is possibly 'undefined'.\n"
    exit 2
fi
exit 0
EOF
chmod +x "$fixture/fake-hermes-bun"
check "Hermes web build accepts only the known Bun-visible preset diagnostic" \
    bash -c '
        : >"$2"
        cd "$1"
        SANDWICH_BUN="$3" \
        SANDWICH_FAKE_BUN_LOG="$2" \
        SANDWICH_HERMES_WEB_BUILD_COMPAT=1 \
        SANDWICH_HERMES_WEB_DIR="$1" \
            "$4/bin/npm" run build >/dev/null 2>&1
        grep -Fq "tsconfig.node.json" "$2" &&
            grep -Fq "tsconfig.app.json" "$2" &&
            grep -Fq "vite build" "$2"
    ' _ "$fixture/hermes-web" "$fixture/hermes-build.log" \
        "$fixture/fake-hermes-bun" "$root"
check "Hermes web build rejects every unrecognized TypeScript diagnostic" \
    bash -c '
        : >"$2"
        cd "$1"
        ! SANDWICH_BUN="$3" \
            SANDWICH_FAKE_BUN_LOG="$2" \
            SANDWICH_FAKE_UNEXPECTED=1 \
            SANDWICH_HERMES_WEB_BUILD_COMPAT=1 \
            SANDWICH_HERMES_WEB_DIR="$1" \
                "$4/bin/npm" run build >/dev/null 2>&1
    ' _ "$fixture/hermes-web" "$fixture/hermes-build.log" \
        "$fixture/fake-hermes-bun" "$root"

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

expr="$fixture/check-expr"
mkdir -p \
    "$expr/project/node_modules/@deepseek-ai/dsh-app-boot" \
    "$expr/project/node_modules/@deepseek-ai/cordis-plugin-include" \
    "$expr/project/node_modules/js-yaml"
cat >"$expr/project/package.json" <<'EOF'
{
  "name": "global-fixture",
  "private": true,
  "dependencies": {
    "@deepseek-ai/dsh-app-boot": "1.0.0"
  },
  "overrides": {
    "js-yaml": "^5.4.1"
  }
}
EOF
printf '%s\n' '# fixture lock' >"$expr/project/bun.lock"
cat >"$expr/project/node_modules/@deepseek-ai/dsh-app-boot/package.json" <<'EOF'
{"name":"@deepseek-ai/dsh-app-boot","version":"1.0.0","dependencies":{"js-yaml":"^4.2.0"}}
EOF
cat >"$expr/project/node_modules/@deepseek-ai/cordis-plugin-include/package.json" <<'EOF'
{"name":"@deepseek-ai/cordis-plugin-include","version":"1.0.0","dependencies":{"js-yaml":"^4.1.0"}}
EOF
cat >"$expr/project/node_modules/js-yaml/package.json" <<'EOF'
{"name":"js-yaml","version":"5.4.1"}
EOF
cat >"$expr/fake-bun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SANDWICH_FAKE_BUN_LOG"
case "$*" in
    "pm view js-yaml versions --json")
        printf '%s\n' '["4.2.0","4.3.0","4.3.1","4.3.2","5.4.1"]'
        ;;
    "audit --json")
        if [[ -f node_modules/js-yaml/package.json ]]; then
            version=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' node_modules/js-yaml/package.json)
        else
            version=$(sed -n 's/.*"js-yaml": "\([^"]*\)".*/\1/p' package.json)
        fi
        if [[ "$version" == "4.2.0" ]]; then
            printf '%s\n' '{"js-yaml":[{"severity":"high","vulnerable_versions":">=4.0.0 <4.3.2"}]}'
            exit 1
        fi
        printf '%s\n' '{}'
        ;;
    update)
        version=$(sed -n 's/.*"js-yaml": "\([^"]*\)".*/\1/p' package.json)
        [[ -n "$version" ]] || version=4.2.0
        printf '{"name":"js-yaml","version":"%s"}\n' "$version" >node_modules/js-yaml/package.json
        ;;
    "pm untrusted") printf '%s\n' 'Found 0 untrusted dependencies' ;;
    "install --lockfile-only --ignore-scripts") printf '%s\n' '# audit fixture lock' >bun.lock ;;
    "install --frozen-lockfile --ignore-scripts") ;;
    *) printf 'unexpected fake bun command: %s\n' "$*" >&2; exit 93 ;;
esac
EOF
chmod +x "$expr/fake-bun"
: >"$expr/bun.log"
check "checkExpr dry-run reports an incompatible override without changing it" \
    bash -c '
        before=$(sha256sum "$2/project/package.json" "$2/project/bun.lock")
        output=$(SANDWICH_BUN="$2/fake-bun" SANDWICH_FAKE_BUN_LOG="$2/bun.log" "$1" "$3/scripts/check-expr.ts" --dryrun "$2/project")
        after=$(sha256sum "$2/project/package.json" "$2/project/bun.lock")
        [[ "$before" == "$after" ]] &&
            [[ "$output" == *"compatibility repair: js-yaml ^5.4.1 -> 4.3.2"* ]] &&
            ! grep -Fxq update "$2/bun.log"
    ' _ "$SANDWICH_BUN" "$expr" "$root"

: >"$expr/bun.log"
check "checkExpr repairs a cross-major override within consumer ranges" \
    bash -c '
        SANDWICH_BUN="$2/fake-bun" SANDWICH_FAKE_BUN_LOG="$2/bun.log" "$1" "$3/scripts/check-expr.ts" "$2/project" >/dev/null &&
            grep -Fq "\"js-yaml\": \"4.3.2\"" "$2/project/package.json" &&
            grep -Fq "\"version\":\"4.3.2\"" "$2/project/node_modules/js-yaml/package.json" &&
            grep -Fxq update "$2/bun.log" &&
            ! grep -Fq "pm view js-yaml version " "$2/bun.log"
    ' _ "$SANDWICH_BUN" "$expr" "$root"

cp -R "$expr/project" "$expr/security-project"
cat >"$expr/security-project/package.json" <<'EOF'
{
  "name": "global-security-fixture",
  "private": true,
  "dependencies": {
    "@deepseek-ai/dsh-app-boot": "1.0.0"
  }
}
EOF
printf '%s\n' '{"name":"js-yaml","version":"4.2.0"}' >"$expr/security-project/node_modules/js-yaml/package.json"
: >"$expr/bun.log"
check "checkExpr selects the audit-clean release inside a consumer's major" \
    bash -c '
        SANDWICH_BUN="$2/fake-bun" SANDWICH_FAKE_BUN_LOG="$2/bun.log" "$1" "$3/scripts/check-expr.ts" "$2/security-project" >/dev/null &&
            grep -Fq "\"js-yaml\": \"4.3.2\"" "$2/security-project/package.json" &&
            grep -Fq "\"version\":\"4.3.2\"" "$2/security-project/node_modules/js-yaml/package.json" &&
            ! grep -Fq "pm view js-yaml version " "$2/bun.log"
    ' _ "$SANDWICH_BUN" "$expr" "$root"

check "checkZoo requires an explicit action" \
    bash -c '! "$1/bin/sandwich" checkZoo >/dev/null 2>&1' _ "$root"
check "checkFence requires an explicit action" \
    bash -c '! "$1/bin/sandwich" checkFence >/dev/null 2>&1' _ "$root"

zoo="$fixture/zoo"
mkdir -p "$zoo/project/.venv/bin" "$zoo/standalone/bin" "$zoo/uv-tools/ruff/bin"
cat >"$zoo/project/pyproject.toml" <<'EOF'
[project]
name = "zoo-project"
version = "0.1.0"
dependencies = ["safe", "vllm"]
EOF
cat >"$zoo/project/uv.lock" <<'EOF'
version = 1

[[package]]
name = "safe"
version = "1.0.0"

[[package]]
name = "vllm"
version = "1.0.0"
EOF
for environment in "$zoo/project/.venv" "$zoo/standalone" "$zoo/uv-tools/ruff"; do
    printf 'home = /fixture\n' >"$environment/pyvenv.cfg"
    cat >"$environment/bin/activate" <<EOF
VIRTUAL_ENV='$environment'
export VIRTUAL_ENV
deactivate() { unset VIRTUAL_ENV; }
EOF
    cat >"$environment/bin/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$environment/bin/python"
done
cat >"$zoo/fake-uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s | VIRTUAL_ENV=%s | CWD=%s\n' "$*" "${VIRTUAL_ENV:-}" "$PWD" >>"$SANDWICH_FAKE_UV_LOG"
case "$*" in
    "audit --locked --output-format json")
        printf '%s\n' '{"summary":{"audited_packages":2,"vulnerabilities":0,"adverse_statuses":0},"vulnerabilities":[]}'
        ;;
    "tree --locked --outdated --format json")
        printf '%s\n' '{"resolution":{"safe":{"name":"safe","version":"1.0.0","latest_version":"2.0.0"},"vllm":{"name":"vllm","version":"1.0.0","latest_version":"2.0.0"}}}'
        ;;
    lock*)
        if [[ "${SANDWICH_FAKE_UV_DRIFT:-0}" == 1 ]]; then
            sed -i 's/version = "1.0.0"/version = "9.0.0"/g' uv.lock
        else
            sed -i '0,/version = "1.0.0"/s//version = "2.0.0"/' uv.lock
        fi
        ;;
    "sync --locked --inexact --active") ;;
    pip\ check*) printf '%s\n' 'Checked 2 packages' ;;
    *"pip list"*"--outdated"*)
        printf '%s\n' '[{"name":"safe","version":"1.0.0","latest_version":"2.0.0"},{"name":"vllm","version":"1.0.0","latest_version":"2.0.0"}]'
        ;;
    *"pip list"*)
        printf '%s\n' '[{"name":"safe","version":"1.0.0"},{"name":"vllm","version":"1.0.0"}]'
        ;;
    pip\ install*) ;;
    "tool list") printf '%s\n' 'ruff v1.0.0' '  - ruff' ;;
    "tool list --outdated --show-version-specifiers") printf '%s\n' 'ruff v1.0.0 (latest: v2.0.0)' ;;
    "tool dir") printf '%s\n' "$SANDWICH_FAKE_UV_TOOLS" ;;
    "tool audit --help") exit 2 ;;
    tool\ upgrade*) ;;
    *) printf 'unexpected fake uv command: %s\n' "$*" >&2; exit 91 ;;
esac
EOF
chmod +x "$zoo/fake-uv"
: >"$zoo/uv.log"
check "checkZoo dry-run discovers projects and standalone venvs without writes" \
    bash -c '
        before=$(sha256sum "$2/project/uv.lock")
        output=$(SANDWICH_UV="$2/fake-uv" SANDWICH_FAKE_UV_LOG="$2/uv.log" SANDWICH_FAKE_UV_TOOLS="$2/uv-tools" \
            "$1/bin/sandwich" checkZoo --dryrun --protect vllm "$2")
        after=$(sha256sum "$2/project/uv.lock")
        [[ "$before" == "$after" ]] &&
            [[ "$output" == *"[checkZoo:project]"* ]] &&
            [[ "$output" == *"[checkZoo:venv]"* ]] &&
            [[ "$output" == *"vllm: 1.0.0 -> 2.0.0 [protected]"* ]]
    ' _ "$root" "$zoo"

: >"$zoo/uv.log"
check "checkZoo applies targeted project upgrades and activates only the existing project venv" \
    bash -c '
        SANDWICH_UV="$2/fake-uv" SANDWICH_FAKE_UV_LOG="$2/uv.log" SANDWICH_FAKE_UV_TOOLS="$2/uv-tools" \
            "$1/bin/sandwich" checkZoo --apply=projects --protect vllm "$2/project" >/dev/null
        grep -Fq "lock --upgrade-package safe" "$2/uv.log" &&
            ! grep -Fq -- "--upgrade-package vllm" "$2/uv.log" &&
            grep -F "sync --locked --inexact --active" "$2/uv.log" | grep -Fq "VIRTUAL_ENV=$2/project/.venv" &&
            grep -A2 "name = \"vllm\"" "$2/project/uv.lock" | grep -Fq "version = \"1.0.0\""
    ' _ "$root" "$zoo"

sed -i '0,/version = "2.0.0"/s//version = "1.0.0"/' "$zoo/project/uv.lock"
: >"$zoo/uv.log"
check "checkZoo restores uv.lock when a protected package drifts" \
    bash -c '
        before=$(sha256sum "$2/project/uv.lock")
        ! SANDWICH_UV="$2/fake-uv" SANDWICH_FAKE_UV_LOG="$2/uv.log" SANDWICH_FAKE_UV_TOOLS="$2/uv-tools" SANDWICH_FAKE_UV_DRIFT=1 \
            "$1/bin/sandwich" checkZoo --apply=projects --protect vllm "$2/project" >/dev/null 2>&1
        after=$(sha256sum "$2/project/uv.lock")
        [[ "$before" == "$after" ]]
    ' _ "$root" "$zoo"

: >"$zoo/uv.log"
check "checkZoo standalone venv mode uses uv pip preflight inside an activated subshell" \
    bash -c '
        SANDWICH_UV="$2/fake-uv" SANDWICH_FAKE_UV_LOG="$2/uv.log" SANDWICH_FAKE_UV_TOOLS="$2/uv-tools" \
            "$1/bin/sandwich" checkZoo --apply=venvs --protect vllm "$2/standalone" >/dev/null
        grep -F "pip install" "$2/uv.log" | grep -Fq -- "--dry-run" &&
            grep -F "pip install" "$2/uv.log" | grep -Fq "VIRTUAL_ENV=$2/standalone" &&
            ! grep -Eq "Bun\\.which\\(\"pip\"|\\[\"pip\"" "$1/scripts/check-zoo.ts"
    ' _ "$root" "$zoo"

fence="$fixture/fence"
mkdir -p "$fence/project" "$fence/cargo-home/bin"
cat >"$fence/project/Cargo.toml" <<'EOF'
[package]
name = "fence-project"
version = "0.1.0"
edition = "2024"
EOF
printf 'version = 4\n# original\n' >"$fence/project/Cargo.lock"
cat >"$fence/cargo-home/.crates2.json" <<'EOF'
{"installs":{"iwe 1.0.0 (registry+https://github.com/rust-lang/crates.io-index)":{"version_req":null,"bins":["iwe"],"features":["fast"],"all_features":false,"no_default_features":false,"profile":"release","target":"x86_64-unknown-linux-gnu"}}}
EOF
cat >"$fence/cargo-home/bin/iwe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fence/cargo-home/bin/iwe"
cat >"$fence/fake-cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s | CWD=%s\n' "$*" "$PWD" >>"$SANDWICH_FAKE_CARGO_LOG"
case "$*" in
    "audit --version")
        [[ "${SANDWICH_FAKE_NO_AUDIT:-0}" != 1 ]] || exit 2
        printf '%s\n' 'cargo-audit 1.0.0'
        ;;
    "audit --help") printf '%s\n' 'Audit Cargo.lock files' ;;
    "audit --json") printf '%s\n' '{"vulnerabilities":{"found":false,"count":0,"list":[]},"warnings":{}}' ;;
    "update --dry-run") printf '%s\n' 'update plan' ;;
    "update") printf 'version = 4\n# updated\n' >Cargo.lock ;;
    "metadata --locked --format-version 1 --no-deps")
        [[ "${SANDWICH_FAKE_METADATA_FAIL:-0}" != 1 ]] || exit 2
        printf '%s\n' '{}'
        ;;
    search\ *) printf '%s\n' 'iwe = "2.0.0" # fixture' ;;
    install\ *) ;;
    *) printf 'unexpected fake cargo command: %s\n' "$*" >&2; exit 92 ;;
esac
EOF
chmod +x "$fence/fake-cargo"
: >"$fence/cargo.log"
check "checkFence dry-run audits and plans without changing Cargo.lock" \
    bash -c '
        before=$(sha256sum "$2/project/Cargo.lock")
        SANDWICH_CARGO="$2/fake-cargo" SANDWICH_FAKE_CARGO_LOG="$2/cargo.log" CARGO_HOME="$2/cargo-home" \
            "$1/bin/sandwich" checkFence --dryrun --scope=projects "$2/project" >/dev/null
        after=$(sha256sum "$2/project/Cargo.lock")
        [[ "$before" == "$after" ]] && grep -Fq "update --dry-run" "$2/cargo.log"
    ' _ "$root" "$fence"

: >"$fence/cargo.log"
check "checkFence applies and validates a Cargo.lock update without building" \
    bash -c '
        SANDWICH_CARGO="$2/fake-cargo" SANDWICH_FAKE_CARGO_LOG="$2/cargo.log" CARGO_HOME="$2/cargo-home" \
            "$1/bin/sandwich" checkFence --apply=projects "$2/project" >/dev/null
        grep -Fq "# updated" "$2/project/Cargo.lock" &&
            grep -Fq "metadata --locked --format-version 1 --no-deps" "$2/cargo.log" &&
            ! grep -Eq "(^| )check( |$)|(^| )build( |$)" "$2/cargo.log"
    ' _ "$root" "$fence"

printf 'version = 4\n# original\n' >"$fence/project/Cargo.lock"
: >"$fence/cargo.log"
check "checkFence restores Cargo.lock when metadata validation fails" \
    bash -c '
        before=$(sha256sum "$2/project/Cargo.lock")
        ! SANDWICH_CARGO="$2/fake-cargo" SANDWICH_FAKE_CARGO_LOG="$2/cargo.log" SANDWICH_FAKE_METADATA_FAIL=1 CARGO_HOME="$2/cargo-home" \
            "$1/bin/sandwich" checkFence --apply=projects "$2/project" >/dev/null 2>&1
        after=$(sha256sum "$2/project/Cargo.lock")
        [[ "$before" == "$after" ]]
    ' _ "$root" "$fence"

: >"$fence/cargo.log"
check "checkFence reconstructs tracked crates.io installs from Cargo metadata" \
    bash -c '
        SANDWICH_CARGO="$2/fake-cargo" SANDWICH_FAKE_CARGO_LOG="$2/cargo.log" CARGO_HOME="$2/cargo-home" \
            "$1/bin/sandwich" checkFence --apply=global >/dev/null
        grep -Fq "install --locked iwe --bin iwe --features fast --target x86_64-unknown-linux-gnu" "$2/cargo.log"
    ' _ "$root" "$fence"

check "checkFence fails closed when RustSec is unavailable" \
    bash -c '
        ! SANDWICH_CARGO="$2/fake-cargo" SANDWICH_FAKE_CARGO_LOG="$2/cargo.log" SANDWICH_FAKE_NO_AUDIT=1 CARGO_HOME="$2/cargo-home" \
            "$1/bin/sandwich" checkFence --dryrun --scope=projects "$2/project" >/dev/null 2>&1
    ' _ "$root" "$fence"

check "npm root-only workspace install maps to the root filter" \
    bash -c 'cd "$1" && npm install --workspaces=false --no-save >/dev/null' _ "$fixture"

for file in "$root"/bin/* "$root"/lib/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
    check "bash syntax: ${file#$root/}" bash -n "$file"
done
check "top-level installer syntax" bash -n "$root/install.sh"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
