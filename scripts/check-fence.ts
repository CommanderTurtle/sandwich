#!/usr/bin/env bun

import { copyFileSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

type Scope = "projects" | "global" | "all";
type Action = "dryrun" | "apply";
type Result = { exitCode: number; stdout: string; stderr: string };
type Outcome = "clean" | "planned" | "updated" | "skipped" | "failed";
type CargoInstall = {
  name: string;
  version: string;
  source: string;
  metadata: {
    version_req?: string | null;
    bins?: string[];
    features?: string[];
    all_features?: boolean;
    no_default_features?: boolean;
    profile?: string;
    target?: string;
  };
};

const home = homedir();
const cargo = process.env.SANDWICH_CARGO ?? Bun.which("cargo");
const cargoHome = resolve(process.env.CARGO_HOME ?? join(home, ".cargo"));

function fail(message: string): never {
  console.error(`sandwich: ${message}`);
  process.exit(64);
}

function help(): void {
  console.log(`usage:
  sandwich checkFence --dryrun [--scope=all|projects|global] [options] [path ...]
  sandwich checkFence --apply=projects|global|all [options] [path ...]

Run RustSec audits and Cargo lockfile update plans across Cargo projects. The
global scope inspects Cargo's tracked binary installations and can refresh only
crates.io installs whose original features, target, profile, and bin selection
can be reconstructed exactly.

Options:
  --dryrun                 audit and run cargo update --dry-run only
  --apply=SCOPE            apply only the explicitly named scope
  --scope=SCOPE            restrict --dryrun (default: all)
  --protect=NAME[,NAME]    do not refresh these globally installed crates

Optional paths restrict project discovery. checkFence never runs project
builds, edits Cargo.toml, installs cargo-audit automatically, or guesses how to
recreate Git, path, or custom-registry binary installations.`);
}

function parseScope(value: string): Scope {
  if (["projects", "global", "all"].includes(value)) return value as Scope;
  fail(`invalid checkFence scope: ${value}`);
}

let action: Action | undefined;
let scope: Scope = "all";
let scopeWasSet = false;
const inputs: string[] = [];
const protectedNames = new Set<string>();
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
    if (!value) fail("--apply requires projects, global, or all");
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
    if (!value) fail("--scope requires projects, global, or all");
    scope = parseScope(value);
    scopeWasSet = true;
  } else if (argument.startsWith("--protect=")) {
    for (const name of argument.slice("--protect=".length).split(/[\s,]+/)) if (name) protectedNames.add(name.toLowerCase());
  } else if (argument === "--protect") {
    const value = argv[++index];
    if (!value) fail("--protect requires a crate name");
    for (const name of value.split(/[\s,]+/)) if (name) protectedNames.add(name.toLowerCase());
  } else if (argument.startsWith("-")) {
    fail(`unknown checkFence option: ${argument}`);
  } else {
    inputs.push(argument);
  }
}

if (!action) fail("checkFence requires --dryrun or an explicit --apply=SCOPE");
if (action === "apply" && !scopeWasSet) fail("applying checkFence requires an explicit scope");
if (!cargo) fail("cargo was not found on PATH (or through SANDWICH_CARGO)");

function run(command: string[], cwd = home): Result {
  const child = Bun.spawnSync({
    cmd: command,
    cwd,
    env: { ...process.env, CARGO_TERM_COLOR: "never" },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { exitCode: child.exitCode, stdout: child.stdout.toString(), stderr: child.stderr.toString() };
}

function printResult(result: Result): void {
  if (result.stdout.trim()) process.stdout.write(result.stdout.endsWith("\n") ? result.stdout : `${result.stdout}\n`);
  if (result.stderr.trim()) process.stderr.write(result.stderr.endsWith("\n") ? result.stderr : `${result.stderr}\n`);
}

const excludedNames = new Set([
  ".git", ".cache", ".cargo", ".rustup", ".bun", ".venv", "venv", "node_modules",
  "target", "dist", "build", "vendor", "__pycache__",
]);
const excludedPaths = new Set([join(home, ".local", "state")].map((path) => resolve(path)));

function discover(searchInputs: string[]): { projects: string[]; missing: string[] } {
  const projects = new Set<string>();
  const missing: string[] = [];
  const starts = searchInputs.length ? searchInputs : [home];

  const visit = (directory: string): void => {
    let entries;
    try {
      entries = readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
      if (["EACCES", "EPERM", "ENOENT"].includes(code)) return;
      throw error;
    }
    const names = new Set(entries.map((entry) => entry.name));
    if (names.has("Cargo.toml") && names.has("Cargo.lock")) projects.add(resolve(directory));
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
      const path = resolve(directory, entry.name);
      if (excludedNames.has(entry.name) || excludedPaths.has(path)) continue;
      visit(path);
    }
  };

  for (const input of starts) {
    let target = resolve(input);
    if (!existsSync(target)) {
      missing.push(target);
      continue;
    }
    if (statSync(target).isFile()) target = dirname(target);
    visit(target);
  }
  return { projects: [...projects].sort(), missing };
}

const auditProbe = run([cargo!, "audit", "--version"]);
const auditAvailable = auditProbe.exitCode === 0;
const auditHelp = auditAvailable ? run([cargo!, "audit", "--help"]) : { exitCode: 1, stdout: "", stderr: "" };
const binaryAuditAvailable = auditAvailable && /\bbin\b/.test(`${auditHelp.stdout}\n${auditHelp.stderr}`);

function auditProject(root: string): { ok: boolean; findings: number } {
  if (!auditAvailable) {
    console.error("  security audit unavailable: install RustSec with `cargo install --locked cargo-audit`");
    return { ok: false, findings: 0 };
  }
  const result = run([cargo!, "audit", "--json"], root);
  try {
    const report = JSON.parse(result.stdout || "{}") as {
      vulnerabilities?: { count?: number; found?: boolean; list?: unknown[] };
      warnings?: Record<string, unknown[]>;
    };
    const findings = Number(report.vulnerabilities?.count ?? report.vulnerabilities?.list?.length ?? 0);
    const warnings = Object.values(report.warnings ?? {}).reduce((sum, items) => sum + items.length, 0);
    console.log(`  RustSec: ${findings} vulnerabilities, ${warnings} warnings`);
    return { ok: result.exitCode === 0 || findings + warnings > 0, findings: findings + warnings };
  } catch (error) {
    console.error(`  RustSec audit failed: ${result.stderr.trim() || (error instanceof Error ? error.message : String(error))}`);
    return { ok: false, findings: 0 };
  }
}

function checkProject(root: string): Outcome {
  console.log(`\n[checkFence:project] ${root}`);
  const auditBefore = auditProject(root);
  const plan = run([cargo!, "update", "--dry-run"], root);
  printResult(plan);
  if (plan.exitCode !== 0) return "failed";
  const planHasUpdates = /^\s+(?:Updating|Adding|Removing|Downgrading)\s+\S+\s+v?\d/m.test(`${plan.stdout}\n${plan.stderr}`);
  if (action === "dryrun") {
    console.log("  dry run: Cargo.lock and build outputs unchanged");
    return auditBefore.ok ? (auditBefore.findings || planHasUpdates ? "planned" : "clean") : "failed";
  }
  if (!auditBefore.ok) {
    console.error("  apply refused because the pre-update security audit did not complete");
    return "failed";
  }

  const lock = join(root, "Cargo.lock");
  const temporary = mkdtempSync(join(tmpdir(), "sandwich-fence-"));
  const backup = join(temporary, "Cargo.lock");
  copyFileSync(lock, backup);
  try {
    console.log("  running: cargo update");
    const update = run([cargo!, "update"], root);
    printResult(update);
    if (update.exitCode !== 0) {
      copyFileSync(backup, lock);
      console.error("  update failed; original Cargo.lock restored");
      return "failed";
    }
    const metadata = run([cargo!, "metadata", "--locked", "--format-version", "1", "--no-deps"], root);
    if (metadata.exitCode !== 0) {
      printResult(metadata);
      copyFileSync(backup, lock);
      console.error("  lock verification failed; original Cargo.lock restored");
      return "failed";
    }
    const auditAfter = auditProject(root);
    if (!auditAfter.ok) {
      copyFileSync(backup, lock);
      console.error("  post-update audit failed; original Cargo.lock restored");
      return "failed";
    }
    if (auditAfter.findings) {
      console.error("  compatible lock updates were applied, but manifest-level audit findings remain");
      return "failed";
    }
    return readFileSync(lock).equals(readFileSync(backup)) ? "clean" : "updated";
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function cargoInstalls(): CargoInstall[] {
  const registry = join(cargoHome, ".crates2.json");
  if (!existsSync(registry)) return [];
  const document = JSON.parse(readFileSync(registry, "utf8")) as { installs?: Record<string, CargoInstall["metadata"]> };
  const installs: CargoInstall[] = [];
  for (const [key, metadata] of Object.entries(document.installs ?? {})) {
    const match = key.match(/^(\S+)\s+(\S+)\s+\((.+)\)$/);
    if (!match) continue;
    installs.push({ name: match[1]!, version: match[2]!, source: match[3]!, metadata });
  }
  return installs.sort((left, right) => left.name.localeCompare(right.name));
}

function latestCrate(name: string): string | undefined {
  const result = run([cargo!, "search", name, "--limit", "10"]);
  if (result.exitCode !== 0) return undefined;
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = result.stdout.match(new RegExp(`(?:^|\\n)${escaped}\\s*=\\s*"([^"]+)"`));
  return match?.[1];
}

function registryInstall(install: CargoInstall): boolean {
  return install.source === "registry+https://github.com/rust-lang/crates.io-index"
    || install.source === "registry+sparse+https://index.crates.io/"
    || install.source === "registry+https://index.crates.io/";
}

function installCommand(install: CargoInstall): string[] {
  const specification = install.metadata.version_req
    ? `${install.name}@${install.metadata.version_req}`
    : install.name;
  const command = [cargo!, "install", "--locked", specification];
  for (const bin of install.metadata.bins ?? []) command.push("--bin", bin);
  if (install.metadata.features?.length) command.push("--features", install.metadata.features.join(","));
  if (install.metadata.all_features) command.push("--all-features");
  if (install.metadata.no_default_features) command.push("--no-default-features");
  if (install.metadata.profile && install.metadata.profile !== "release") command.push("--profile", install.metadata.profile);
  if (install.metadata.target) command.push("--target", install.metadata.target);
  return command;
}

function checkGlobal(): Outcome {
  console.log("\n[checkFence:global] Cargo-installed binaries");
  const installs = cargoInstalls();
  if (!installs.length) {
    console.log("  clean: no tracked Cargo installs");
    return "clean";
  }
  const updates: { install: CargoInstall; latest: string }[] = [];
  let skipped = false;
  let failed = false;
  for (const install of installs) {
    if (!registryInstall(install)) {
      console.log(`  ${install.name}@${install.version}: non-crates.io source skipped (${install.source})`);
      skipped = true;
      continue;
    }
    const latest = latestCrate(install.name);
    if (!latest) {
      console.error(`  ${install.name}@${install.version}: could not resolve latest crates.io version`);
      failed = true;
      continue;
    }
    if (latest !== install.version) {
      const isProtected = protectedNames.has(install.name.toLowerCase());
      const protectedLabel = isProtected ? " [protected]" : "";
      console.log(`  ${install.name}: ${install.version} -> ${latest}${protectedLabel}`);
      if (isProtected) skipped = true;
      else updates.push({ install, latest });
    }
  }

  if (binaryAuditAvailable) {
    for (const install of installs) {
      for (const bin of install.metadata.bins ?? []) {
        const path = join(cargoHome, "bin", bin);
        if (!existsSync(path)) continue;
        const audit = run([cargo!, "audit", "bin", path]);
        if (audit.exitCode !== 0) {
          console.error(`  RustSec binary audit reported findings for ${bin}`);
          printResult(audit);
          failed = true;
        }
      }
    }
  } else if (!auditAvailable) {
    console.error("  binary security audit unavailable: install RustSec with `cargo install --locked cargo-audit`");
    failed = true;
  } else {
    console.log("  installed cargo-audit lacks binary scanning; version checks completed");
  }

  if (action === "dryrun") {
    if (!updates.length && !skipped && !failed) console.log("  clean");
    else console.log("  dry run: Cargo-installed binaries unchanged");
    return failed ? "failed" : updates.length ? "planned" : skipped ? "skipped" : "clean";
  }
  if (failed) {
    console.error("  apply refused because the global preflight did not complete cleanly");
    return "failed";
  }
  for (const { install } of updates) {
    const command = installCommand(install);
    console.log(`  running: ${command.slice(1).join(" ")}`);
    const result = run(command);
    printResult(result);
    if (result.exitCode !== 0) failed = true;
  }
  return failed ? "failed" : updates.length ? "updated" : skipped ? "skipped" : "clean";
}

let discovery: ReturnType<typeof discover>;
try {
  discovery = scope === "global" ? { projects: [], missing: [] } : discover(inputs);
} catch (error) {
  console.error(`sandwich: discovery failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
for (const path of discovery.missing) console.error(`sandwich: skipping missing path: ${path}`);

const outcomes: Record<Outcome, number> = { clean: 0, planned: 0, updated: 0, skipped: 0, failed: discovery.missing.length };
const record = (outcome: Outcome): void => { outcomes[outcome]++; };
if (scope === "projects" || scope === "all") for (const root of discovery.projects) record(checkProject(root));
if (scope === "global" || scope === "all") record(checkGlobal());

const examined = (scope === "projects" || scope === "all" ? discovery.projects.length : 0)
  + (scope === "global" || scope === "all" ? 1 : 0);
console.log(`\ncheckFence: ${examined} scopes; ${outcomes.clean} clean, ${outcomes.planned} planned, ${outcomes.updated} updated, ${outcomes.skipped} unsupported/skipped, ${outcomes.failed} failed`);
process.exit(outcomes.failed ? 1 : 0);
