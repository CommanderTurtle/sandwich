---
name: sandwich-runtime
description: Operate and maintain a Bun-only JavaScript environment through Sandwich's compatibility commands.
version: 1.1.0
metadata:
  hermes:
    tags: [bun, javascript, runtime, compatibility, sandwich]
    category: software-development
---

# Sandwich runtime

Use the system's existing Sandwich installation for JavaScript work. Sandwich
maps `node`, `npm`, `npx`, `pnpm`, `yarn`, and `corepack` commands to explicit
Bun behavior; those command names do not authorize installing their original
runtimes or package managers.

## Before changing the runtime

1. Run `sandwich doctor`.
2. Resolve the installation with `command -v sandwich` and inspect the reported
   source path. Do not assume a fixed home directory.
3. Preview installer changes with `./install.sh --check` from that source.

## Package workflows

- Prefer native `bun install`, `bun run`, `bunx`, and `bun update` commands.
- When a project or upstream script requires another command name, invoke it
  normally and let Sandwich translate it.
- Preserve committed lockfiles. Use frozen installs for reproducible builds.
- Do not silently reinterpret unsupported package-manager semantics. Sandwich
  intentionally fails when a translation would be ambiguous.
- Use `bun pm trust` only after reviewing the package and its lifecycle script.

## Maintenance

- Update Bun with `./install.sh --upgrade-bun`.
- Re-apply user command shims with `./install.sh`.
- Keep the official Hermes checkout pristine. Never patch or commit Bun
  compatibility files into Hermes.
- Update Hermes only with `sandwich hermes update`; Sandwich runs the official
  updater and supplies Bun-compatible Node/npm commands externally.
- Use `sandwich hermes check` to verify that Hermes has no local source files.
- `./install.sh --with-hermes` only verifies an existing Hermes installation;
  it does not modify Hermes.
- Finish by running `sandwich doctor` and the repository's own checks.

Runtime state and installer backups belong under Sandwich's user state
directory, never in the source repository.
