#!/usr/bin/env bun

import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

type Scope = "projects" | "venvs" | "tools" | "all";
type Action = "dryrun" | "apply";
type Result = { exitCode: number; stdout: string; stderr: string };
type Update = { name: string; version: string; latest: string };
type Outcome = "clean" | "planned" | "updated" | "skipped" | "failed";

const home = homedir();
const uv = process.env.SANDWICH_UV ?? Bun.which("uv");

function fail(message: string): never {
  console.error(`sandwich: ${message}`);
  process.exit(64);
}

function help(): void {
  console.log(`usage:
  sandwich checkZoo --dryrun [--scope=all|projects|venvs|tools] [options] [path ...]
  sandwich checkZoo --apply=projects|venvs|tools|all [options] [path ...]

Audit uv-locked projects, inspect standalone virtual environments, and inspect
uv-managed tools. Applying changes is intentionally impossible without an
explicit scope. Project updates preserve uv.lock constraints, standalone venv
updates use only uv pip commands, and uv tools retain their installation
constraints.

Options:
  --dryrun                 report audits and available updates without writes
  --apply=SCOPE            apply only the explicitly named scope
  --scope=SCOPE            restrict --dryrun (default: all)
  --protect=NAME[,NAME]    never upgrade these normalized Python package names
  --protect-file=PATH      add newline-delimited protected names (# comments)

SANDWICH_ZOO_PROTECT may contain additional comma-separated names. The system
also reads ~/.config/sandwich/python-protected.txt when it exists; override that
location with SANDWICH_ZOO_PROTECT_FILE. The system Python installation is
never selected or modified. Optional paths restrict project and venv discovery;
uv tools remain user-scoped.`);
}

function parseScope(value: string): Scope {
  if (["projects", "venvs", "tools", "all"].includes(value)) return value as Scope;
  fail(`invalid checkZoo scope: ${value}`);
}

let action: Action | undefined;
let scope: Scope = "all";
let scopeWasSet = false;
const inputs: string[] = [];
const protectedInputs: string[] = [];
const protectFiles: string[] = [];
const argv = process.argv.slice(2);

for (let index = 0; index < argv.length; index++) {
  const argument = argv[index]!;
  if (["-h", "--help", "help"].includes(argument)) {
    help();
    process.exit(0);
  } else if (argument === "--dryrun") {
    if (action && action !== "dryrun") fail("choose exactly one of --dryrun or --apply=SCOPE");
    action = "dryrun";
  } else if (argument.startsWith("--apply=")) {
    if (action) fail("choose exactly one of --dryrun or --apply=SCOPE");
    action = "apply";
    scope = parseScope(argument.slice("--apply=".length));
    scopeWasSet = true;
  } else if (argument === "--apply") {
    if (action) fail("choose exactly one of --dryrun or --apply=SCOPE");
    const value = argv[++index];
    if (!value) fail("--apply requires projects, venvs, tools, or all");
    action = "apply";
    scope = parseScope(value);
    scopeWasSet = true;
  } else if (argument.startsWith("--scope=")) {
    if (scopeWasSet) fail("scope was specified more than once");
    scope = parseScope(argument.slice("--scope=".length));
    scopeWasSet = true;
  } else if (argument === "--scope") {
    if (scopeWasSet) fail("scope was specified more than once");
    const value = argv[++index];
    if (!value) fail("--scope requires projects, venvs, tools, or all");
    scope = parseScope(value);
    scopeWasSet = true;
  } else if (argument.startsWith("--protect=")) {
    protectedInputs.push(argument.slice("--protect=".length));
  } else if (argument === "--protect") {
    const value = argv[++index];
    if (!value) fail("--protect requires a package name");
    protectedInputs.push(value);
  } else if (argument.startsWith("--protect-file=")) {
    protectFiles.push(resolve(argument.slice("--protect-file=".length)));
  } else if (argument === "--protect-file") {
    const value = argv[++index];
    if (!value) fail("--protect-file requires a path");
    protectFiles.push(resolve(value));
  } else if (argument.startsWith("-")) {
    fail(`unknown checkZoo option: ${argument}`);
  } else {
    inputs.push(argument);
  }
}

if (!action) fail("checkZoo requires --dryrun or an explicit --apply=SCOPE");
if (action === "apply" && !scopeWasSet) fail("applying checkZoo requires an explicit scope");
if (!uv) fail("uv was not found on PATH (or through SANDWICH_UV)");

function normalize(name: string): string {
  return name.trim().toLowerCase().replace(/[-_.]+/g, "-");
}

const protectedNames = new Set<string>();
const configuredProtectFile = process.env.SANDWICH_ZOO_PROTECT_FILE;
const defaultProtectFile = resolve(configuredProtectFile ?? join(home, ".config", "sandwich", "python-protected.txt"));
if (configuredProtectFile || existsSync(defaultProtectFile)) protectFiles.unshift(defaultProtectFile);
for (const source of [process.env.SANDWICH_ZOO_PROTECT ?? "", ...protectedInputs]) {
  for (const name of source.split(/[\s,]+/)) if (name.trim()) protectedNames.add(normalize(name));
}
for (const file of protectFiles) {
  if (!existsSync(file)) fail(`protected-package file does not exist: ${file}`);
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const value = line.replace(/#.*$/, "").trim();
    if (value) protectedNames.add(normalize(value));
  }
}

function run(command: string[], cwd = home): Result {
  const child = Bun.spawnSync({
    cmd: command,
    cwd,
    env: {
      ...process.env,
      UV_NO_PROGRESS: "1",
      UV_PYTHON_DOWNLOADS: "never",
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: child.exitCode,
    stdout: child.stdout.toString(),
    stderr: child.stderr.toString(),
  };
}

function printResult(result: Result): void {
  if (result.stdout.trim()) process.stdout.write(result.stdout.endsWith("\n") ? result.stdout : `${result.stdout}\n`);
  if (result.stderr.trim()) process.stderr.write(result.stderr.endsWith("\n") ? result.stderr : `${result.stderr}\n`);
}

function pythonFor(venv: string): string | undefined {
  const unix = join(venv, "bin", "python");
  const windows = join(venv, "Scripts", "python.exe");
  if (existsSync(unix)) return unix;
  if (existsSync(windows)) return windows;
  return undefined;
}

function activateFor(venv: string): string | undefined {
  const unix = join(venv, "bin", "activate");
  const windows = join(venv, "Scripts", "activate");
  if (existsSync(unix)) return unix;
  if (existsSync(windows)) return windows;
  return undefined;
}

function runInVenv(venv: string, command: string[], cwd = dirname(venv)): Result {
  const activate = activateFor(venv);
  if (!activate) return { exitCode: 1, stdout: "", stderr: `missing activation script: ${venv}` };
  const script = [
    "set +u",
    'source "$1"',
    "shift",
    '"$@"',
    "status=$?",
    "deactivate >/dev/null 2>&1 || true",
    'exit "$status"',
  ].join("; ");
  return run(["bash", "-c", script, "sandwich-checkzoo", activate, ...command], cwd);
}

const excludedNames = new Set([
  ".git", ".cache", ".cargo", ".rustup", ".bun", "node_modules", "target",
  "dist", "build", "vendor", "__pycache__", ".tox", ".nox", ".mypy_cache",
  ".pytest_cache",
]);
const excludedPaths = new Set([
  join(home, ".local", "share", "uv"),
  join(home, ".local", "state"),
].map((path) => resolve(path)));

function discover(searchInputs: string[]): { projects: string[]; venvs: string[]; missing: string[] } {
  const projects = new Set<string>();
  const venvs = new Set<string>();
  const missing: string[] = [];
  const starts = searchInputs.length ? searchInputs : [home];

  const visit = (directory: string, explicitRoot: boolean): void => {
    let entries;
    try {
      entries = readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
      if (["EACCES", "EPERM", "ENOENT"].includes(code)) return;
      throw error;
    }
    const names = new Set(entries.map((entry) => entry.name));
    if (names.has("pyvenv.cfg") && pythonFor(directory) && activateFor(directory)) {
      venvs.add(resolve(directory));
      return;
    }
    if (names.has("uv.lock") && names.has("pyproject.toml")) projects.add(resolve(directory));

    for (const entry of entries) {
      if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
      const path = resolve(directory, entry.name);
      if (!explicitRoot && (excludedNames.has(entry.name) || excludedPaths.has(path))) continue;
      if (excludedNames.has(entry.name) || excludedPaths.has(path)) continue;
      visit(path, false);
    }
  };

  for (const input of starts) {
    let target = resolve(input);
    if (!existsSync(target)) {
      missing.push(target);
      continue;
    }
    if (statSync(target).isFile()) target = dirname(target);
    visit(target, true);
  }
  return {
    projects: [...projects].sort(),
    venvs: [...venvs].sort(),
    missing,
  };
}

function parseProjectUpdates(root: string): Update[] {
  const result = run([uv!, "tree", "--locked", "--outdated", "--format", "json"], root);
  if (result.exitCode !== 0) throw new Error(result.stderr.trim() || "uv tree failed");
  const document = JSON.parse(result.stdout) as { resolution?: Record<string, unknown> };
  const updates = new Map<string, Update>();
  for (const raw of Object.values(document.resolution ?? {})) {
    if (!raw || typeof raw !== "object") continue;
    const item = raw as { name?: unknown; version?: unknown; latest_version?: unknown };
    if (typeof item.name !== "string" || typeof item.version !== "string" || typeof item.latest_version !== "string") continue;
    if (item.version === item.latest_version) continue;
    const update = { name: item.name, version: item.version, latest: item.latest_version };
    updates.set(normalize(item.name), update);
  }
  return [...updates.values()].sort((left, right) => normalize(left.name).localeCompare(normalize(right.name)));
}

function auditProject(root: string): { vulnerabilities: number; adverse: number; ok: boolean } {
  const result = run([uv!, "audit", "--locked", "--output-format", "json"], root);
  try {
    const report = JSON.parse(result.stdout || "{}") as {
      summary?: { vulnerabilities?: number; adverse_statuses?: number; audited_packages?: number };
      vulnerabilities?: { dependency?: { name?: string; version?: string }; display_id?: string; id?: string; fix_versions?: string[] }[];
    };
    if (!report.summary) throw new Error("missing audit summary");
    const vulnerabilities = Number(report.summary.vulnerabilities ?? 0);
    const adverse = Number(report.summary.adverse_statuses ?? 0);
    console.log(`  audit: ${report.summary.audited_packages ?? "?"} packages, ${vulnerabilities} vulnerabilities, ${adverse} adverse statuses`);
    const grouped = new Map<string, Set<string>>();
    for (const advisory of report.vulnerabilities ?? []) {
      const packageName = advisory.dependency?.name ?? "unknown";
      const id = advisory.display_id ?? advisory.id ?? "unknown";
      const key = `${packageName}@${advisory.dependency?.version ?? "?"}`;
      const entry = grouped.get(key) ?? new Set<string>();
      entry.add(id);
      grouped.set(key, entry);
    }
    for (const [dependency, ids] of grouped) console.log(`    ${dependency}: ${[...ids].join(", ")}`);
    return { vulnerabilities, adverse, ok: result.exitCode === 0 || vulnerabilities + adverse > 0 };
  } catch (error) {
    console.error(`  audit failed: ${result.stderr.trim() || (error instanceof Error ? error.message : String(error))}`);
    return { vulnerabilities: 0, adverse: 0, ok: false };
  }
}

function lockPackages(path: string): Map<string, string[]> {
  const raw = readFileSync(path, "utf8");
  const parsed = Bun.TOML.parse(raw) as { package?: Record<string, unknown>[] };
  const versions = new Map<string, Set<string>>();
  for (const item of parsed.package ?? []) {
    if (typeof item.name !== "string") continue;
    const key = normalize(item.name);
    const values = versions.get(key) ?? new Set<string>();
    values.add(JSON.stringify(item));
    versions.set(key, values);
  }
  return new Map([...versions].map(([name, values]) => [name, [...values].sort()]));
}

function protectedDrift(before: Map<string, string[]>, after: Map<string, string[]>): string[] {
  const drifted: string[] = [];
  for (const name of protectedNames) {
    const oldValue = JSON.stringify(before.get(name) ?? []);
    const newValue = JSON.stringify(after.get(name) ?? []);
    if (oldValue !== newValue) drifted.push(`${name}: protected lock entry changed`);
  }
  return drifted;
}

function restoreLock(backup: string, lock: string): void {
  copyFileSync(backup, lock);
}

function checkProject(root: string): Outcome {
  console.log(`\n[checkZoo:project] ${root}`);
  const auditBefore = auditProject(root);
  if (!auditBefore.ok) return "failed";
  let updates: Update[];
  try {
    updates = parseProjectUpdates(root);
  } catch (error) {
    console.error(`  update scan failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }
  const allowed = updates.filter((item) => !protectedNames.has(normalize(item.name)));
  for (const item of updates) {
    const protectedLabel = protectedNames.has(normalize(item.name)) ? " [protected]" : "";
    console.log(`  ${item.name}: ${item.version} -> ${item.latest}${protectedLabel}`);
  }
  const hasFindings = auditBefore.vulnerabilities + auditBefore.adverse > 0;
  if (action === "dryrun") {
    if (!updates.length && !hasFindings) console.log("  clean");
    else console.log("  dry run: uv.lock and project environment unchanged");
    return updates.length || hasFindings ? "planned" : "clean";
  }
  if (!allowed.length) {
    console.log(updates.length ? "  no unprotected updates" : "  no updates available");
    if (hasFindings) return "failed";
    return updates.length ? "skipped" : "clean";
  }

  const lock = join(root, "uv.lock");
  const temporary = mkdtempSync(join(tmpdir(), "sandwich-zoo-"));
  const backup = join(temporary, "uv.lock");
  copyFileSync(lock, backup);
  const before = lockPackages(lock);
  try {
    const command = [uv!, "lock"];
    for (const item of allowed) command.push("--upgrade-package", item.name);
    console.log(`  running: uv lock ${allowed.map((item) => `--upgrade-package ${item.name}`).join(" ")}`);
    const update = run(command, root);
    printResult(update);
    if (update.exitCode !== 0) {
      restoreLock(backup, lock);
      console.error("  lock update failed; original uv.lock restored");
      return "failed";
    }
    const drift = protectedDrift(before, lockPackages(lock));
    if (drift.length) {
      restoreLock(backup, lock);
      console.error(`  protected package drift; original uv.lock restored:\n    ${drift.join("\n    ")}`);
      return "failed";
    }

    const environment = join(root, ".venv");
    if (pythonFor(environment) && activateFor(environment)) {
      console.log("  running: uv sync --locked --inexact --active");
      const sync = runInVenv(environment, [uv!, "sync", "--locked", "--inexact", "--active"], root);
      printResult(sync);
      if (sync.exitCode !== 0) {
        restoreLock(backup, lock);
        console.error("  sync failed; original uv.lock restored and prior lock is being re-synced");
        const rollback = runInVenv(environment, [uv!, "sync", "--locked", "--inexact", "--active"], root);
        printResult(rollback);
        return "failed";
      }
    } else {
      console.log("  lock updated; no existing .venv was created implicitly");
    }
    const auditAfter = auditProject(root);
    if (!auditAfter.ok) {
      restoreLock(backup, lock);
      if (pythonFor(environment) && activateFor(environment)) {
        const rollback = runInVenv(environment, [uv!, "sync", "--locked", "--inexact", "--active"], root);
        printResult(rollback);
      }
      console.error("  post-update audit failed; original uv.lock restored");
      return "failed";
    }
    if (auditAfter.vulnerabilities + auditAfter.adverse > 0) {
      console.error("  update completed, but the project still has audit findings");
      return "failed";
    }
    return "updated";
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function venvPackages(venv: string, outdated: boolean): Update[] {
  const python = pythonFor(venv);
  if (!python) throw new Error("missing Python interpreter");
  const command = [uv!, "pip", "list", "--python", python, "--format", "json"];
  if (outdated) command.push("--outdated");
  const result = runInVenv(venv, command);
  if (result.exitCode !== 0) throw new Error(result.stderr.trim() || "uv pip list failed");
  const rows = JSON.parse(result.stdout) as { name?: unknown; version?: unknown; latest_version?: unknown }[];
  return rows.flatMap((row) => {
    if (typeof row.name !== "string" || typeof row.version !== "string") return [];
    const latest = typeof row.latest_version === "string" ? row.latest_version : row.version;
    return [{ name: row.name, version: row.version, latest }];
  }).filter((item) => !outdated || item.latest !== item.version)
    .sort((left, right) => normalize(left.name).localeCompare(normalize(right.name)));
}

function checkVenv(venv: string): Outcome {
  console.log(`\n[checkZoo:venv] ${venv}`);
  const python = pythonFor(venv);
  if (!python) {
    console.error("  missing Python interpreter");
    return "failed";
  }
  const integrity = runInVenv(venv, [uv!, "pip", "check", "--python", python]);
  if (integrity.exitCode !== 0) {
    console.error("  environment integrity check failed");
    printResult(integrity);
  } else {
    console.log("  dependency integrity: clean");
  }
  let updates: Update[];
  try {
    updates = venvPackages(venv, true);
  } catch (error) {
    console.error(`  update scan failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }
  const allowed = updates.filter((item) => !protectedNames.has(normalize(item.name)));
  for (const item of updates) {
    const protectedLabel = protectedNames.has(normalize(item.name)) ? " [protected]" : "";
    console.log(`  ${item.name}: ${item.version} -> ${item.latest}${protectedLabel}`);
  }
  if (action === "dryrun") {
    if (!updates.length && integrity.exitCode === 0) console.log("  clean");
    else console.log("  dry run: virtual environment unchanged");
    return updates.length || integrity.exitCode !== 0 ? "planned" : "clean";
  }
  if (!allowed.length) {
    console.log(updates.length ? "  no unprotected updates" : "  no updates available");
    if (integrity.exitCode !== 0) return "failed";
    return updates.length ? "skipped" : "clean";
  }

  const temporary = mkdtempSync(join(tmpdir(), "sandwich-zoo-"));
  try {
    const installed = venvPackages(venv, false);
    const constraints = join(temporary, "protected.txt");
    const pins = installed
      .filter((item) => protectedNames.has(normalize(item.name)))
      .map((item) => `${item.name}==${item.version}`);
    writeFileSync(constraints, pins.length ? `${pins.join("\n")}\n` : "", "utf8");
    const packages = allowed.map((item) => `${item.name}==${item.latest}`);
    const base = [uv!, "pip", "install", "--python", python, "--upgrade", "--strict"];
    if (pins.length) base.push("--constraints", constraints);
    base.push(...packages);
    const preflight = runInVenv(venv, [...base, "--dry-run"]);
    printResult(preflight);
    if (preflight.exitCode !== 0) {
      console.error("  uv preflight failed; environment unchanged");
      return "failed";
    }
    console.log(`  running: uv pip install --upgrade ${packages.join(" ")}`);
    const install = runInVenv(venv, base);
    printResult(install);
    if (install.exitCode !== 0) return "failed";
    const after = new Map(venvPackages(venv, false).map((item) => [normalize(item.name), item.version]));
    const drift = pins.filter((pin) => {
      const match = pin.match(/^(.+)==(.+)$/)!;
      return after.get(normalize(match[1]!)) !== match[2];
    });
    if (drift.length) {
      console.error(`  protected-package invariant failed: ${drift.join(", ")}`);
      return "failed";
    }
    return "updated";
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function toolNames(output: string): string[] {
  return output.split(/\r?\n/)
    .filter((line) => line.trim() && !/^\s/.test(line))
    .map((line) => line.trim().split(/\s+/)[0]!)
    .filter(Boolean);
}

function checkTools(): Outcome {
  console.log("\n[checkZoo:tools] uv-managed tools");
  const installed = run([uv!, "tool", "list"]);
  if (installed.exitCode !== 0) {
    printResult(installed);
    return "failed";
  }
  const names = toolNames(installed.stdout);
  const outdatedResult = run([uv!, "tool", "list", "--outdated", "--show-version-specifiers"]);
  if (outdatedResult.exitCode !== 0) {
    printResult(outdatedResult);
    return "failed";
  }
  const outdated = toolNames(outdatedResult.stdout);
  const allowed = outdated.filter((name) => !protectedNames.has(normalize(name)));
  if (outdatedResult.stdout.trim()) printResult(outdatedResult);
  for (const name of outdated.filter((item) => protectedNames.has(normalize(item)))) console.log(`  ${name}: [protected]`);

  let integrityFailed = false;
  const toolsRootResult = run([uv!, "tool", "dir"]);
  if (toolsRootResult.exitCode === 0) {
    const toolsRoot = toolsRootResult.stdout.trim();
    for (const name of names) {
      const environment = join(toolsRoot, name);
      const python = pythonFor(environment);
      if (!python || !activateFor(environment)) continue;
      const integrity = runInVenv(environment, [uv!, "pip", "check", "--python", python], environment);
      if (integrity.exitCode !== 0) {
        integrityFailed = true;
        console.error(`  ${name}: dependency integrity failed`);
        printResult(integrity);
      }
    }
  }

  const toolAuditHelp = run([uv!, "tool", "audit", "--help"]);
  if (toolAuditHelp.exitCode === 0 && names.length) {
    const audit = run([uv!, "tool", "audit", "--all"]);
    printResult(audit);
    if (audit.exitCode !== 0) integrityFailed = true;
  } else if (names.length) {
    console.log("  uv tool audit is unavailable in this uv version; integrity and outdated checks completed");
  }

  if (action === "dryrun") {
    if (!outdated.length && !integrityFailed) console.log("  clean");
    else console.log("  dry run: uv tool environments unchanged");
    return outdated.length || integrityFailed ? "planned" : "clean";
  }
  if (!allowed.length) return integrityFailed ? "failed" : outdated.length ? "skipped" : "clean";
  let failed = false;
  for (const name of allowed) {
    console.log(`  running: uv tool upgrade ${name}`);
    const upgrade = run([uv!, "tool", "upgrade", name]);
    printResult(upgrade);
    if (upgrade.exitCode !== 0) failed = true;
  }
  return failed ? "failed" : "updated";
}

let discovery: ReturnType<typeof discover>;
try {
  discovery = scope === "tools"
    ? { projects: [], venvs: [], missing: [] }
    : discover(inputs);
} catch (error) {
  console.error(`sandwich: discovery failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
for (const path of discovery.missing) console.error(`sandwich: skipping missing path: ${path}`);

const projectEnvironments = new Set(discovery.projects.map((root) => join(root, ".venv")));
const standaloneVenvs = discovery.venvs.filter((venv) => !projectEnvironments.has(venv));
const outcomes: Record<Outcome, number> = { clean: 0, planned: 0, updated: 0, skipped: 0, failed: discovery.missing.length };
const record = (outcome: Outcome): void => { outcomes[outcome]++; };

if (scope === "projects" || scope === "all") for (const root of discovery.projects) record(checkProject(root));
if (scope === "venvs" || scope === "all") for (const venv of standaloneVenvs) record(checkVenv(venv));
if (scope === "tools" || scope === "all") record(checkTools());

const examined = (scope === "projects" || scope === "all" ? discovery.projects.length : 0)
  + (scope === "venvs" || scope === "all" ? standaloneVenvs.length : 0)
  + (scope === "tools" || scope === "all" ? 1 : 0);
console.log(`\ncheckZoo: ${examined} scopes; ${outcomes.clean} clean, ${outcomes.planned} planned, ${outcomes.updated} updated, ${outcomes.skipped} protected/skipped, ${outcomes.failed} failed`);
process.exit(outcomes.failed ? 1 : 0);
