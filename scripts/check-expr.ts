#!/usr/bin/env bun

import { existsSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

type Advisory = {
  severity?: string;
  vulnerable_versions?: string;
  range?: string;
};

type AuditReport = Record<string, Advisory[]>;
type Result = { exitCode: number; stdout: string; stderr: string };

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
  const excludedNames = ["node_modules", ".git", ".cache", ".venv", "venv", "target", "dist", "build", "vendor"];
  const excludedPaths = [join(home, ".local", "state"), join(home, ".local", "share"), join(home, ".bun", "install", "cache")];
  const prune: string[] = ["(", "-type", "d", "("];
  const exclusions = [
    ...excludedNames.map((name) => ["-name", name]),
    ...excludedPaths.map((path) => ["-path", path]),
  ];
  exclusions.forEach((parts, index) => {
    if (index) prune.push("-o");
    prune.push(...parts);
  });
  prune.push(")", "-prune", ")");

  const found = run(["find", searchRoot, ...prune, "-o", "-type", "f", "-name", "package.json", "-print0"], home);
  if (found.exitCode !== 0) throw new Error(found.stderr.trim() || `could not scan ${searchRoot}`);
  return found.stdout
    .split("\0")
    .filter(Boolean)
    .map(dirname)
    .filter(hasBunLock);
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

function overrideRange(advisories: Advisory[]): string {
  const boundaries: { version: string; inclusive: boolean }[] = [];
  for (const advisory of advisories) {
    const range = advisory.vulnerable_versions ?? advisory.range ?? "";
    for (const match of range.matchAll(/(<=|<)\s*v?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)/g)) {
      boundaries.push({ version: match[2], inclusive: match[1] === "<=" });
    }
  }
  if (boundaries.length === 0) throw new Error("audit did not provide a vulnerable upper version");
  boundaries.sort((left, right) => {
    const ordered = Bun.semver.order(left.version, right.version);
    return ordered || Number(left.inclusive) - Number(right.inclusive);
  });
  const highest = boundaries.at(-1)!;
  return `${highest.inclusive ? ">" : ">="}${highest.version}`;
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

function latest(root: string, packageName: string): string {
  const result = run([bun, "pm", "view", packageName, "version", "--json"], root);
  if (result.exitCode !== 0) throw new Error(result.stderr.trim() || `could not find latest ${packageName}`);
  const version = JSON.parse(result.stdout);
  if (typeof version !== "string") throw new Error(`could not find latest ${packageName}`);
  return version;
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
  let report: AuditReport;
  try {
    report = audit(root);
  } catch (error) {
    console.error(`  audit failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }
  const vulnerable = Object.entries(report);
  if (vulnerable.length === 0) {
    console.log("  clean");
    return "clean";
  }

  const overrides: Record<string, string> = {};
  try {
    for (const [name, advisories] of vulnerable) {
      overrides[name] = overrideRange(advisories);
      const severity = [...new Set(advisories.map((item) => item.severity).filter(Boolean))].join(", ");
      console.log(`  ${name}: ${overrides[name]}${severity ? ` (${severity})` : ""}`);
    }
    if (dryRun) {
      console.log("  dry run: overrides shown above; package.json and bun.lock unchanged");
      return "planned";
    }
    writeOverrides(root, overrides);
  } catch (error) {
    console.error(`  override failed: ${error instanceof Error ? error.message : String(error)}`);
    return "failed";
  }

  console.log("  running: bun update");
  let update = run([bun, "update"], root);
  printResult(update);
  if (update.exitCode !== 0) {
    console.log("  bun update failed; pinning published latest versions");
    try {
      for (const [name] of vulnerable) overrides[name] = `^${latest(root, name)}`;
      writeOverrides(root, overrides);
    } catch (error) {
      console.error(`  fallback failed: ${error instanceof Error ? error.message : String(error)}`);
      return "failed";
    }
    update = run([bun, "update"], root);
    printResult(update);
  }
  if (update.exitCode !== 0) return "failed";
  followUp(root);
  return "updated";
}

function help(): void {
  console.log(`usage: sandwich checkExpr [--dryrun] [path ...]

Starting at ~/.bun/install/global, run bun audit in every user-owned Bun
package root, maintain its overrides block, and run bun update. If Bun cannot
resolve an audit boundary, checkExpr retries with the package's ^latest version.
Project builds are left to the user, and blocked scripts are reported through
bun pm untrusted. --dryrun audits and prints proposed overrides without writing
or updating. Optional paths restrict the scan.`);
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
