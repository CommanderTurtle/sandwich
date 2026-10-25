import { test, expect } from "bun:test";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const git = Bun.which("git");
const bash = process.env.SANDWICH_TEST_BASH ?? (process.platform === "win32" && git
  ? path.resolve(path.dirname(git), "../bin/bash.exe") : "/bin/bash");
const posix = (value: string) => value.replace(/\\/g, "/").replace(/^([A-Za-z]):/, (_, drive: string) => "/" + drive.toLowerCase());

async function fixture(action: (f: { directory: string; config: string; state: string; native: string; run: (code: string) => ReturnType<typeof Bun.spawnSync> }) => Promise<void>) {
  const directory = await mkdtemp(path.join(tmpdir(), "sandwich maintenance "));
  const config = path.join(directory, "config"), state = path.join(directory, "state"), native = path.join(directory, "native");
  await mkdir(native);
  const run = (code: string) => Bun.spawnSync([bash, "-c", 'export PATH="$1/bin:$3:$PATH"; ' + code, "test", posix(root), posix(directory), posix(native)], {
    cwd: root,
    env: { ...process.env, SANDWICH_BUN: process.execPath.replace(/\\/g, "/"), SANDWICH_MODE: "", SANDWICH_CONFIG_HOME: posix(config), SANDWICH_STATE_HOME: posix(state) },
    stdout: "pipe", stderr: "pipe",
  });
  try { await action({ directory, config, state, native, run }); }
  finally { await rm(directory, { recursive: true, force: true }); }
}

test("doctor explains the exact three mise-style PATH conflicts, and shadow activation fixes precedence", async () => fixture(async f => {
  for (const name of ["node", "npm", "npx"]) await writeFile(path.join(f.native, name), "#!/usr/bin/env bash\nprintf 'native\\n'\n", { mode: 0o755 });
  const before = f.run('export PATH="$3:$PATH"; bash "$1/bin/sandwich" doctor');
  expect(before.exitCode).toBe(1);
  expect(before.stdout.toString()).toContain("3 command resolution issue(s), 0 runtime capability issue(s)");
  expect(before.stdout.toString()).toContain("another PATH entry or shell function wins");
  const after = f.run('export PATH="$3:$PATH"; eval "$(bash "$1/bin/sandwich" shadow --shell=bash)"; bash "$1/bin/sandwich" doctor');
  expect(after.stderr.toString()).toBe("");
  expect(after.exitCode).toBe(0);
  expect(after.stdout.toString()).toContain("result:    OK");
  expect(await readFile(path.join(f.config, "mode"), "utf8")).toBe("shadow\n");
}));

test("unshadow forwards arguments to native commands without deleting or changing their files", async () => fixture(async f => {
  const body = '#!/usr/bin/env bash\nprintf "native:%s\\n" "$*"\n';
  for (const name of ["node", "npm", "npx", "pnpm", "yarn", "corepack"]) await writeFile(path.join(f.native, name), body, { mode: 0o755 });
  const result = f.run('bash "$1/bin/sandwich" unshadow >/dev/null; bash "$1/bin/node" "hello world" extra; bash "$1/bin/sandwich" doctor');
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toContain("native:hello world extra");
  expect(result.stdout.toString()).toContain("mode:      unshadow");
  expect(result.stdout.toString()).toContain("result:    OK");
  expect(result.stderr.toString()).toBe("");
  expect(await readFile(path.join(f.native, "node"), "utf8")).toBe(body);
  expect(await readFile(path.join(f.config, "mode"), "utf8")).toBe("unshadow\n");
}));

test("unshadow skips other Sandwich checkouts instead of recursing", async () => fixture(async f => {
  const other = path.join(f.directory, "other");
  await mkdir(path.join(other, "bin"), { recursive: true });
  await writeFile(path.join(other, "manifest.json"), '{"id":"sandwich"}');
  await writeFile(path.join(other, "bin", "node"), "#!/usr/bin/env bash\nexit 99\n", { mode: 0o755 });
  await writeFile(path.join(f.native, "node"), "#!/usr/bin/env bash\nprintf 'native\\n'\n", { mode: 0o755 });
  const result = f.run('export PATH="$2/other/bin:$PATH"; bash "$1/bin/sandwich" unshadow >/dev/null; bash "$1/bin/node"');
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toBe("native\n");
}));

test("shadow preview does not write state and version data cannot execute shell syntax", async () => fixture(async f => {
  expect(f.run('bash "$1/bin/sandwich" shadow --dry-run').exitCode).toBe(0);
  expect(await Bun.file(path.join(f.config, "mode")).exists()).toBe(false);
  await mkdir(f.state);
  await writeFile(path.join(f.state, "versions.tsv"), "npm\t12.2.1\npnpm\t12.15.0\nyarn\t1.22.22\nnpm\t$(touch injected)\n");
  const result = f.run('bash "$1/bin/npm" --version; bash "$1/bin/pnpm" --version; bash "$1/bin/yarn" --version');
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toBe("12.2.1\n12.15.0\n1.22.22\n");
  expect(await Bun.file(path.join(root, "injected")).exists()).toBe(false);
}));

test("resolve saves one validated stable set and a bad registry response preserves it", async () => fixture(async f => {
  const mock = path.join(f.directory, "mock-fetch.ts");
  await writeFile(mock, `globalThis.fetch=async url=>{const name=new URL(url).pathname.split('/')[1];return Response.json({name,version:process.env.BAD_RELEASE&&name==='pnpm'?'13.0.0-beta.1':'12.2.1'})};`);
  const run = (extra: Record<string, string> = {}, args: string[] = []) => Bun.spawnSync([process.execPath, "--preload", mock, path.join(root, "scripts/resolve.ts"), ...args], {
    env: { ...process.env, SANDWICH_STATE_HOME: f.state, ...extra }, stdout: "pipe", stderr: "pipe",
  });
  expect(run({}, ["--dry-run"]).exitCode).toBe(0);
  expect(await Bun.file(path.join(f.state, "versions.tsv")).exists()).toBe(false);
  const saved = run();
  expect(saved.exitCode).toBe(0);
  expect(saved.stdout.toString()).toContain("Node API actually provided by Bun:");
  const content = await readFile(path.join(f.state, "versions.tsv"), "utf8");
  expect(content).toBe("npm\t12.2.1\npnpm\t12.2.1\nyarn\t12.2.1\n");
  expect(run({ BAD_RELEASE: "1" }).exitCode).toBe(1);
  expect(await readFile(path.join(f.state, "versions.tsv"), "utf8")).toBe(content);
}));
