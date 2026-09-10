#!/usr/bin/env bun

import { existsSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

type Advisory = {
  severity?: string;
  vulnerable_versions?: string;
  range?: string;
};

type AuditReport = Record<string, Advisory[]>;
type Result = { exitCode: number; stdout: string; stderr: string };
type DependencyMap = Record<string, string>;
type PackageManifest = {
  name?: string;
  version?: string;
  dependencies?: DependencyMap;
  devDependencies?: DependencyMap;
  optionalDependencies?: DependencyMap;
  peerDependencies?: DependencyMap;
  overrides?: Record<string, unknown>;
  scripts?: Record<string, string>;
};
type Requirement = { consumer: string; range: string; direct: boolean };
type DependencyGraph = {
  requirements: Map<string, Requirement[]>;
  installed: Map<string, Set<string>>;
};
type OverridePlan = {
  fixes: Record<string, string>;
  unresolved: string[];
};
type FileSnapshot = {
  path: string;
  contents?: Uint8Array;
  mode?: number;
};

const home = homedir();
const bun = process.env.SANDWICH_BUN
  ?? (process.env.BUN_INSTALL ? join(process.env.BUN_INSTALL, "bin", "bun") : join(home, ".bun", "bin", "bun"));
const globalRoot = process.env.BUN_INSTALL_GLOBAL_DIR
  ?? join(process.env.BUN_INSTALL ?? join(home, ".bun"), "install", "global");

function run(command: string[], cwd: string): Result {
  const child = Bun.spawnSync({
    cmd: command,
    cwd,
    env: { ...process.env, DO_NOT_TRACK: "1" },
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
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
}

function hasBunLock(root: string): boolean {
  return existsSync(join(root, "bun.lock")) || existsSync(join(root, "bun.lockb"));
}

function scan(searchRoot: string): string[] {
  const excludedNames = new Set(["node_modules", ".git", ".cache", ".venv", "venv", "target", "dist", "build", "vendor"]);
  const excludedPaths = [join(home, ".local", "state"), join(home, ".local", "share"), join(home, ".bun", "install", "cache")];
  if (process.platform === "win32" && resolve(searchRoot) === resolve(home)) excludedNames.add("AppData");

  const normalize = (path: string) => process.platform === "win32" ? resolve(path).toLowerCase() : resolve(path);
  const excluded = new Set(excludedPaths.map(normalize));
  const roots = new Set<string>();
  const pending = [resolve(searchRoot)];

  while (pending.length) {
    const directory = pending.pop()!;
    let entries;
    try {
      entries = readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
      if (["EACCES", "EPERM", "ENOENT"].includes(code)) continue;
      throw error;
    }

    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (excludedNames.has(entry.name) || excluded.has(normalize(path))) continue;
        pending.push(path);
      } else if (entry.isFile() && entry.name === "package.json" && hasBunLock(directory)) {
        roots.add(directory);
      }
    }
  }

  return [...roots];
}

function rootsFor(paths: string[]): string[] {
  const roots = new Set<string>();
  if (paths.length === 0) {
    if (existsSync(join(globalRoot, "package.json")) && hasBunLock(globalRoot)) roots.add(globalRoot);
    for (const root of scan(home)) roots.add(root);
  } else {
    for (const input of paths) {
      const target = resolve(input);
      if (existsSync(join(target, "package.json")) && hasBunLock(target)) roots.add(target);
      else if (existsSync(target)) for (const root of scan(target)) roots.add(root);
      else console.error(`sandwich: skipping missing path: ${target}`);
    }
  }
  return [...roots].sort((left, right) => {
    if (left === globalRoot) return -1;
    if (right === globalRoot) return 1;
    return left.localeCompare(right);
  });
}

function audit(root: string): AuditReport {
  const result = run([bun, "audit", "--json"], root);
  let report: unknown;
  try {
    report = JSON.parse(result.stdout.trim() || "{}");
  } catch {
    throw new Error(result.stderr.trim() || "bun audit returned invalid JSON");
  }
  if (!report || typeof report !== "object" || Array.isArray(report)) throw new Error("bun audit returned an unexpected report");
  if (result.exitCode !== 0 && Object.keys(report).length === 0) throw new Error(result.stderr.trim() || "bun audit failed");
  return report as AuditReport;
}

function readManifest(path: string): PackageManifest | undefined {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    return value && typeof value === "object" && !Array.isArray(value) ? value as PackageManifest : undefined;
  } catch {
    return undefined;
  }
}

function installedPackageDirectories(root: string): string[] {
  const found: string[] = [];
  const pending = [join(root, "node_modules")];
  const visited = new Set<string>();

  while (pending.length) {
    const nodeModules = pending.pop()!;
    const normalized = resolve(nodeModules);
    if (visited.has(normalized)) continue;
    visited.add(normalized);

    let entries;
    try {
      entries = readdirSync(nodeModules, { withFileTypes: true });
    } catch {
      continue;
    }

    const addPackage = (directory: string): void => {
      if (!existsSync(join(directory, "package.json"))) return;
      found.push(directory);
      if (existsSync(join(directory, "node_modules"))) pending.push(join(directory, "node_modules"));
    };

    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const path = join(nodeModules, entry.name);
      if (entry.name.startsWith("@") && entry.isDirectory()) {
        let scoped;
        try {
          scoped = readdirSync(path, { withFileTypes: true });
        } catch {
          continue;
        }
        for (const child of scoped) if (child.isDirectory()) addPackage(join(path, child.name));
      } else if (entry.isDirectory()) {
        addPackage(path);
      }
    }
  }

  return found;
}

function dependencyGraph(root: string): DependencyGraph {
  const requirements = new Map<string, Requirement[]>();
  const installed = new Map<string, Set<string>>();
  const rootManifest = readManifest(join(root, "package.json"));
  const directConsumers = new Set([
    ...Object.keys(rootManifest?.dependencies ?? {}),
    ...Object.keys(rootManifest?.devDependencies ?? {}),
    ...Object.keys(rootManifest?.optionalDependencies ?? {}),
  ]);

  const addRequirements = (manifest: PackageManifest, consumer: string, includeDev: boolean, direct: boolean): void => {
    const groups = [manifest.dependencies, manifest.optionalDependencies, manifest.peerDependencies];
    if (includeDev) groups.push(manifest.devDependencies);
    for (const dependencies of groups) {
      for (const [name, range] of Object.entries(dependencies ?? {})) {
        if (typeof range !== "string" || !/^(?:\s*[v=~^*<>\d]|.*\|\|)/.test(range)) continue;
        const list = requirements.get(name) ?? [];
        list.push({ consumer, range, direct });
        requirements.set(name, list);
      }
    }
  };

  if (rootManifest) addRequirements(rootManifest, rootManifest.name ?? "(root)", true, true);

  for (const directory of installedPackageDirectories(root)) {
    const manifest = readManifest(join(directory, "package.json"));
    if (!manifest) continue;
    if (manifest.name && manifest.version) {
      const versions = installed.get(manifest.name) ?? new Set<string>();
      versions.add(manifest.version);
      installed.set(manifest.name, versions);
    }
    addRequirements(
      manifest,
      `${manifest.name ?? directory}@${manifest.version ?? "?"}`,
      false,
      Boolean(manifest.name && directConsumers.has(manifest.name)),
    );
  }

  return { requirements, installed };
}

function satisfies(version: string, range: string): boolean {
  try {
    return Bun.semver.satisfies(version, range);
  } catch {
    return false;
  }
}

const versionCache = new Map<string, string[]>();
const versionAuditCache = new Map<string, boolean>();

function publishedVersions(root: string, packageName: string): string[] {
  const key = `${root}\0${packageName}`;
  const cached = versionCache.get(key);
  if (cached) return cached;
  const result = run([bun, "pm", "view", packageName, "versions", "--json"], root);
  if (result.exitCode !== 0) throw new Error(result.stderr.trim() || `could not find versions for ${packageName}`);
  const parsed = JSON.parse(result.stdout);
  const versions = (Array.isArray(parsed) ? parsed : [parsed]).filter((value): value is string => typeof value === "string");
  if (!versions.length) throw new Error(`could not find versions for ${packageName}`);
  versionCache.set(key, versions);
  return versions;
}

function compatibleVersion(
  root: string,
  packageName: string,
  requirements: Requirement[],
  advisories: Advisory[] = [],
): string | undefined {
  const candidates = publishedVersions(root, packageName).filter((version) => {
    if (!requirements.every((item) => satisfies(version, item.range))) return false;
    return advisories.every((advisory) => {
      const vulnerable = advisory.vulnerable_versions ?? advisory.range;
      if (!vulnerable) throw new Error(`audit did not provide a vulnerable range for ${packageName}`);
      return !satisfies(version, vulnerable);
    });
  });
  candidates.sort((left, right) => Bun.semver.order(left, right));
  return candidates.at(-1);
}

function versionIsAuditClean(root: string, packageName: string, version: string): boolean {
  const key = `${packageName}@${version}`;
  const cached = versionAuditCache.get(key);
  if (cached !== undefined) return cached;

  const temporary = mkdtempSync(join(tmpdir(), "sandwich-checkexpr-audit-"));
  try {
    writeFileSync(join(temporary, "package.json"), `${JSON.stringify({ private: true, dependencies: { [packageName]: version } }, null, 2)}\n`);
    const install = run([bun, "install", "--lockfile-only", "--ignore-scripts"], temporary);
    if (install.exitCode !== 0) throw new Error(install.stderr.trim() || `could not resolve ${key} for compatibility audit`);
    const report = audit(temporary);
    const clean = Object.keys(report).length === 0;
    versionAuditCache.set(key, clean);
    return clean;
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function existingOverrideRepairs(root: string, graph: DependencyGraph): OverridePlan {
  const manifest = readManifest(join(root, "package.json"));
  const overrides = manifest?.overrides;
  if (overrides !== undefined && (!overrides || typeof overrides !== "object" || Array.isArray(overrides))) {
    throw new Error(`${join(root, "package.json")} has a non-object overrides field`);
  }

  const fixes: Record<string, string> = {};
  const unresolved: string[] = [];
  for (const [name, override] of Object.entries(overrides ?? {})) {
    if (typeof override !== "string") continue;
    const requirements = graph.requirements.get(name) ?? [];
    const installed = [...(graph.installed.get(name) ?? [])];
    if (!requirements.some((item) => item.direct)
      || requirements.every((item) => installed.some((version) => satisfies(version, item.range)))) continue;

    const violations = requirements.filter((item) => !installed.some((version) => satisfies(version, item.range)));
    const candidate = compatibleVersion(root, name, requirements);
    const consumers = violations.slice(0, 3).map((item) => `${item.consumer} requires ${item.range}`).join("; ");
    if (candidate && versionIsAuditClean(root, name, candidate)) {
      fixes[name] = candidate;
      console.log(`  compatibility repair: ${name} ${override} -> ${candidate} (${consumers})`);
    } else if (candidate) {
      console.log(`  compatibility hold: ${name} ${override} remains because the in-range ${candidate} release is vulnerable`);
    } else {
      unresolved.push(name);
      console.log(`  compatibility warning: ${name} ${override} conflicts with ${consumers}; mixed requirements have no single release`);
    }
  }
  return { fixes, unresolved };
}

function securityOverridePlan(root: string, graph: DependencyGraph, report: AuditReport): OverridePlan {
  const fixes: Record<string, string> = {};
  const unresolved: string[] = [];
  for (const [name, advisories] of Object.entries(report)) {
    const requirements = graph.requirements.get(name) ?? [];
    const candidate = compatibleVersion(root, name, requirements, advisories);
    const severity = [...new Set(advisories.map((item) => item.severity).filter(Boolean))].join(", ");
    if (candidate) {
      fixes[name] = candidate;
      console.log(`  ${name}: ${candidate}${severity ? ` (${severity})` : ""}`);
    } else {
      unresolved.push(name);
      const consumers = requirements.slice(0, 3).map((item) => `${item.consumer} requires ${item.range}`).join("; ");
      console.error(`  ${name}: no non-vulnerable release satisfies installed consumers${consumers ? ` (${consumers})` : ""}`);
    }
  }
  return { fixes, unresolved };
}

function writeOverrides(root: string, overridesToSet: Record<string, string>): void {
  const manifestPath = join(root, "package.json");
  const raw = readFileSync(manifestPath, "utf8");
  const manifest = JSON.parse(raw) as Record<string, unknown>;
  const existing = manifest.overrides;
  if (existing !== undefined && (!existing || typeof existing !== "object" || Array.isArray(existing))) {
    throw new Error(`${manifestPath} has a non-object overrides field`);
  }
  manifest.overrides = { ...((existing ?? {}) as Record<string, string>), ...overridesToSet };
  const indent = raw.match(/\n([ \t]+)"/)?.[1] ?? "  ";
  const newline = raw.endsWith("\n") ? "\n" : "";
  const temporary = `${manifestPath}.sandwich-checkexpr-${process.pid}`;
  writeFileSync(temporary, JSON.stringify(manifest, null, indent) + newline, { mode: statSync(manifestPath).mode });
  renameSync(temporary, manifestPath);
}

function snapshot(root: string): FileSnapshot[] {
  return ["package.json", "bun.lock", "bun.lockb"].map((name) => {
    const path = join(root, name);
    return existsSync(path)
      ? { path, contents: readFileSync(path), mode: statSync(path).mode }
      : { path };
  });
}

function restore(files: FileSnapshot[]): void {
  for (const file of files) {
    if (file.contents) {
      const temporary = `${file.path}.sandwich-checkexpr-restore-${process.pid}`;
      writeFileSync(temporary, file.contents, { mode: file.mode });
      renameSync(temporary, file.path);
    } else if (existsSync(file.path)) {
      unlinkSync(file.path);
    }
  }
}

function applyOverrides(root: string, overrides: Record<string, string>): boolean {
  if (!Object.keys(overrides).length) return true;
  const before = snapshot(root);
  writeOverrides(root, overrides);
  console.log("  running: bun update");
  const update = run([bun, "update"], root);
  printResult(update);
  if (update.exitCode === 0) return true;

  console.error("  bun update failed; restoring package.json and Bun lockfile");
  restore(before);
  const reinstall = run([bun, "install", "--frozen-lockfile", "--ignore-scripts"], root);
  printResult(reinstall);
  if (reinstall.exitCode !== 0) console.error("  dependency restore failed; the original manifest and lockfile were restored on disk");
  return false;
}

function followUp(root: string): void {
  const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { scripts?: Record<string, string> };
  const builds = Object.keys(manifest.scripts ?? {}).filter((name) => /^(?:pre|post)?build$/.test(name));
  if (builds.length) console.log(`  manual build available: ${builds.join(", ")} (not run by Sandwich)`);

  const untrusted = run([bun, "pm", "untrusted"], root);
  const output = `${untrusted.stdout}\n${untrusted.stderr}`;
  const count = Number(output.match(/Found\s+(\d+)\s+untrusted/i)?.[1] ?? "0");
  if (untrusted.exitCode !== 0 || count > 0) {
    console.log(`  untrusted scripts require review: cd ${JSON.stringify(root)} && bun pm untrusted`);
  }
}

function check(root: string, dryRun: boolean): "clean" | "planned" | "updated" | "failed" {
  console.log(`\n[checkExpr] ${root}`);
  let graph: DependencyGraph;
  let compatibility: OverridePlan;
  try {
    graph = dependencyGraph(root);
    compatibility = existingOverrideRepairs(root, graph);
  } catch (error) {
    console.error(`  compatibility scan failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }

  let changed = false;
  if (Object.keys(compatibility.fixes).length) {
    if (dryRun) changed = true;
    else {
      try {
        if (!applyOverrides(root, compatibility.fixes)) return "failed";
        changed = true;
        graph = dependencyGraph(root);
      } catch (error) {
        console.error(`  compatibility repair failed: ${error instanceof Error ? error.message : String(error)}`);
        return "failed";
      }
    }
  }

  let report: AuditReport;
  try {
    report = audit(root);
  } catch (error) {
    console.error(`  audit failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }
  const vulnerable = Object.entries(report);
  if (vulnerable.length === 0) {
    if (dryRun && changed) {
      console.log("  dry run: compatible override repairs shown above; package.json and bun.lock unchanged");
      return "planned";
    }
    console.log(changed ? "  clean after compatibility repair" : "  clean");
    return changed ? "updated" : "clean";
  }

  let security: OverridePlan;
  try {
    security = securityOverridePlan(root, graph, report);
    if (dryRun) {
      console.log("  dry run: compatible security overrides shown above; package.json and bun.lock unchanged");
      return "planned";
    }
  } catch (error) {
    console.error(`  override failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }

  if (security.unresolved.length) {
    console.error(`  unresolved audit packages: ${security.unresolved.join(", ")}`);
    console.error("  refusing to force a release outside an installed consumer's declared range");
    return "failed";
  }
  try {
    if (!applyOverrides(root, security.fixes)) return "failed";
  } catch (error) {
    console.error(`  override failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }

  let after: AuditReport;
  try {
    after = audit(root);
  } catch (error) {
    console.error(`  post-update audit failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }
  if (Object.keys(after).length) {
    console.error(`  audit findings remain after update: ${Object.keys(after).join(", ")}`);
    return "failed";
  }
  followUp(root);
  return "updated";
}

function help(): void {
  console.log(`usage: sandwich checkExpr [--dryrun] [path ...]

Starting at ~/.bun/install/global, run bun audit in every user-owned Bun
package root, maintain its overrides block, and run bun update. Security fixes
are selected from published releases accepted by every installed consumer.
checkExpr repairs an existing override when one compatible release can satisfy
all consumers, but never falls through to an API-incompatible major. Project
builds are left to the user, and blocked scripts are reported through bun pm
untrusted. --dryrun audits and prints proposed overrides without writing or
updating. Optional paths restrict the scan.`);
}

const args = process.argv.slice(2);
if (args.some((argument) => ["-h", "--help", "help"].includes(argument))) {
  help();
  process.exit(0);
}
const dryRun = args.includes("--dryrun");
const paths = args.filter((argument) => argument !== "--dryrun");

let roots: string[];
try {
  roots = rootsFor(paths);
} catch (error) {
  console.error(`sandwich: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}

const totals = { clean: 0, planned: 0, updated: 0, failed: 0 };
for (const root of roots) totals[check(root, dryRun)]++;
console.log(`\ncheckExpr: ${roots.length} roots; ${totals.clean} clean, ${totals.planned} planned, ${totals.updated} updated, ${totals.failed} failed`);
process.exit(totals.failed ? 1 : 0);
