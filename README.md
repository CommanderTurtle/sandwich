# Sandwich

an oven factory. node replacement that runs on delicious bread only.

Sandwich makes `node`, `npm`, `npx`, `pnpm`, `yarn`, and `corepack` resolve to
tested Bun translations. It supports workspaces, global installs, lifecycle
trust, frozen lockfiles, and foreign package-lock projects without installing a
second JavaScript runtime.

When Bun does not expose Node's experimental
`node:module.stripTypeScriptTypes`, Sandwich supplies its position-preserving
strip mode through the pinned Amaro implementation used by Node itself. This
lets Node-oriented loaders such as DeepSeek Harness import and strip erasable
TypeScript without modifying their installed source. Sandwich does not pretend
to provide worker isolation controls that Bun does not implement.

For DeepSeek Harness, Sandwich also bridges the private-loader call used by
its zero-root user-profile watcher. Ordinary module imports and profile-file
refreshes work; Node module-job inspection and module hot reload remain
explicitly unsupported rather than silently approximated.

```bash
git clone https://github.com/CommanderTurtle/sandwich.git
cd sandwich
./install.sh
source ~/.bashrc
sandwich doctor
```

For an existing global DeepSeek Harness install, the same shim is automatic:

```bash
dsh web --port 7001 --no-open
```

Preview with `./install.sh --check`. Update Bun with
`./install.sh --upgrade-bun`. Existing user shims and shell configuration are
backed up under `~/.local/state/sandwich`.

### Windows

Run the repository installer from
PowerShell:

```powershell
.\windows.ps1
sandwich doctor
```

The script creates small ignored `.cmd` launchers under `.windows-bin`, puts
that directory first on the user PATH, and runs the canonical Sandwich Bash
entrypoints through Git for Windows. It installs no Node runtime and updates
the current PowerShell process immediately.

Hermes support is external by design. Sandwich never patches, commits, rebases,
or installs files into the official Hermes source tree. The wrapper runs the
official updater with Sandwich first on `PATH`, so Hermes' native `node` and
`npm` commands execute on Bun. It then rebuilds the generated UI/TUI output
against a frozen compatibility lock under `~/.local/state/sandwich/hermes`.
The lock is staged only for the Bun process and removed immediately, leaving no
Bun lockfile or local compatibility commit in Hermes.

`./install.sh --with-hermes` is an optional read-only verification of an
existing official Hermes install. No separate Git pull is part of the user
workflow.

```bash
sandwich doctor  # verify Bun and every compatibility shim
sandwich audit   # report foreign JavaScript runtimes without changing them
sandwich checkExpr      # audit every Bun root, repair overrides, bun update
sandwich hermes check   # verify Hermes is an unmodified upstream checkout
sandwich hermes update  # back up, update, and rebuild Hermes through Bun
```

`sandwich checkExpr` starts at `~/.bun/install/global`, finds each user-owned
project with a Bun lockfile, and runs `bun audit`. Vulnerable packages are added
to (or refreshed inside) that project's top-level `overrides` block before a
normal `bun update`. Existing unrelated overrides are preserved. Sandwich does
not invoke a project build or trust blocked dependency scripts; it reports the
project's build hooks and tells you when `bun pm untrusted` needs review.
Use `sandwich checkExpr --dryrun` to print the proposed overrides without
changing manifests, locks, or installed modules.

Sandwich fails loudly when another package manager’s semantics cannot be
represented honestly. Runtime state and backups never live in this repository.
