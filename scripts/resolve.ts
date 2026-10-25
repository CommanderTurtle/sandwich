import { mkdir, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { homedir } from "node:os";

const args = process.argv.slice(2);
if (args.some(arg => !["--dry-run", "--dryrun", "--help", "-h"].includes(arg))) {
  console.error("usage: sandwich resolve [--dry-run]");
  process.exit(64);
}
if (args.includes("--help") || args.includes("-h")) {
  console.log("sandwich resolve [--dry-run]\nResolve npm/pnpm/yarn compatibility labels from their stable npm dist-tags.\nDoes not install those managers, upgrade Bun, or spoof Bun's Node API version.");
  process.exit(0);
}
const dryRun = args.includes("--dry-run") || args.includes("--dryrun");
const names = ["npm", "pnpm", "yarn", "bun"] as const;
const versions = await Promise.all(names.map(async name => {
  const response = await fetch(`https://registry.npmjs.org/${name}/latest`, {
    headers: { accept: "application/json", "cache-control": "no-cache" },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`${name}: registry returned HTTP ${response.status}`);
  const data = await response.json() as { name?: string; version?: string };
  if (data.name !== name || !data.version || !/^\d+\.\d+\.\d+$/.test(data.version)) {
    throw new Error(`${name}: registry did not return a stable release`);
  }
  return [name, data.version] as const;
}));
const resolved = Object.fromEntries(versions);
console.log("Sandwich stable resolution (compatibility labels, not installed package managers)");
for (const name of ["npm", "pnpm", "yarn"]) console.log(`  ${name}: ${resolved[name]}`);
console.log(`  Bun running: ${Bun.version}; stable: ${resolved.bun}`);
console.log(`  Node API actually provided by Bun: ${process.version}`);
if (Bun.version !== resolved.bun) console.log("  Bun is not changed by resolve; update it through its original installer/manager.");
if (!dryRun) {
  const state = process.env.SANDWICH_STATE_HOME ?? path.join(process.env.XDG_STATE_HOME ?? path.join(homedir(), ".local", "state"), "sandwich");
  await mkdir(state, { recursive: true });
  const file = path.join(state, "versions.tsv");
  const temporary = `${file}.${process.pid}.tmp`;
  await writeFile(temporary, versions.filter(([name]) => name !== "bun").map(([name, version]) => `${name}\t${version}\n`).join(""), { mode: 0o600 });
  await rename(temporary, file);
  console.log(`  Saved ${file}`);
  console.log("  Explicit SANDWICH_NPM_VERSION/PNPM_VERSION/YARN_VERSION environment overrides still take precedence.");
} else console.log("  Dry run: no state changed.");
