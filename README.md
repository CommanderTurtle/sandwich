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

Hermes build compatibility remains fail-closed. When Bun exposes stricter
optional-peer types than npm's installed layout, Sandwich accepts only a known,
version-scoped declaration mismatch, still type-checks the application, and
runs the real upstream build. Any additional diagnostic fails normally; no
tracked Hermes source is changed.

`./install.sh --with-hermes` is an optional read-only verification of an
existing official Hermes install. No separate Git pull is part of the user
workflow.

```bash
sandwich doctor  # verify Bun and every compatibility shim
sandwich audit   # report foreign JavaScript runtimes without changing them
sandwich checkExpr      # audit every Bun root, repair overrides, bun update
sandwich checkFence --dryrun  # audit Cargo projects and installed binaries
sandwich checkZoo --dryrun    # audit uv projects, venvs, and installed tools
sandwich hermes check   # verify Hermes is an unmodified upstream checkout
sandwich hermes update  # update Hermes, reconcile integrations, restart an active gateway
sandwich integrations check      # run each installed repository owner doctor
sandwich integrations reconcile  # reapply and verify installed owner contracts
sandwich integrations update     # update, integrate, and verify installed owners
```

Localflame, Context Mode, Camofox, Codebase Memory, Librarian, Leetcoder,
Retrieval, and Persephone keep ownership of their own harness configuration.
Sandwich only invokes their checked-in scripts in a fixed order. It does not
copy their MCP definitions, skills, hooks, profiles, or generated state.

`sandwich integrations check` and `reconcile` skip owners that are not
installed. Add `--strict` when this workstation's complete roster is required.
Every action accepts `--dry-run` to print the exact owner entrypoints without
running them. None of the owner doctors contacts Firecrawl or starts a model.

After an official Hermes update, `sandwich hermes update` reapplies all
installed owner contracts and restarts the default gateway only if it was
already active. This keeps update season one command while leaving each
project's update and integration logic in that project's repository.

`sandwich checkExpr` starts at `~/.bun/install/global`, finds each user-owned
project with a Bun lockfile, and runs `bun audit`. Vulnerable packages are added
to (or refreshed inside) that project's top-level `overrides` block before a
normal `bun update`. Sandwich selects the newest non-vulnerable release that
still satisfies every installed consumer's declared range. It also repairs a
stale override that breaks a directly installed application's declared range
when one compatible release can satisfy all consumers and an isolated audit
confirms that release is clean; it will report an unresolved advisory instead
of forcing an API-incompatible major.
Existing unrelated overrides are preserved. Sandwich does not invoke a project
build or trust blocked dependency scripts; it reports the project's build hooks
and tells you when `bun pm untrusted` needs review.
Use `sandwich checkExpr --dryrun` to print the proposed overrides without
changing manifests, locks, or installed modules.

### Cargo maintenance

`sandwich checkFence` walks user-owned Cargo roots containing both
`Cargo.toml` and `Cargo.lock`. It runs the RustSec auditor and Cargo's native
`cargo update --dry-run`; it does not compile a project or edit
`Cargo.toml`. Install RustSec once if it is not already available:

```bash
cargo install --locked cargo-audit
sandwich checkFence --dryrun
sandwich checkFence --apply=projects
```

The global scope reads Cargo's own tracked-install metadata. It can recreate a
crates.io installation with the original feature set, selected binaries,
profile, target, version requirement, and packaged lockfile. Git, path, and
custom-registry installations are reported but never guessed.

```bash
sandwich checkFence --dryrun --scope=global
sandwich checkFence --apply=global
sandwich checkFence --apply=global --protect iwe
```

All mutations require `--apply=projects`, `--apply=global`, or `--apply=all`.
Cargo lockfiles are backed up before resolution and restored if update or
metadata validation fails. Manifest-level RustSec findings remain explicit;
Sandwich does not invoke the experimental manifest rewriter.

### Python maintenance

`sandwich checkZoo` discovers uv-locked projects and standalone virtual
environments, then checks uv-managed command-line tools. Locked projects use
native `uv audit`; standalone environments use `uv pip check` and
`uv pip list --outdated`. The latter cannot be represented honestly as a
lockfile security audit, so the distinction remains visible in the output.

```bash
sandwich checkZoo --dryrun
sandwich checkZoo --dryrun --scope=projects ~/Hermes
sandwich checkZoo --apply=projects --protect vllm,torch
sandwich checkZoo --apply=venvs --protect-file ~/.config/sandwich/python-protected.txt ~/multimedia
sandwich checkZoo --apply=tools
```

Project changes use targeted `uv lock --upgrade-package` operations. Existing
`.venv` directories are activated in isolated subshells, synchronized with the
new lock, and deactivated before the walker continues. A missing project
environment is never created implicitly. Standalone venv updates run a uv
resolution preflight before `uv pip install`; uv tools are upgraded one at a
time so protected names can be honored. Sandwich never invokes `pip`, selects
`--system`, or mutates a distro Python installation.

Protected names may be repeated with `--protect`, listed comma-separated, read
from `--protect-file`, or supplied through `SANDWICH_ZOO_PROTECT`. If present,
`~/.config/sandwich/python-protected.txt` is loaded automatically; set
`SANDWICH_ZOO_PROTECT_FILE` to choose another persistent list. Names use
Python's normalized `-`, `_`, and `.` equivalence. A protected version change
during project resolution aborts the operation and restores the original
`uv.lock`. Every write requires `--apply=projects`, `--apply=venvs`,
`--apply=tools`, or `--apply=all`; a bare `checkZoo` is rejected.

The lock and audit behavior follows the upstream [uv locking and
syncing](https://docs.astral.sh/uv/concepts/projects/sync/), [uv tool
management](https://docs.astral.sh/uv/concepts/tools/), [Cargo
update](https://doc.rust-lang.org/cargo/commands/cargo-update.html), and
[RustSec cargo-audit](https://github.com/RustSec/rustsec/tree/main/cargo-audit)
contracts.

Sandwich fails loudly when another package manager’s semantics cannot be
represented honestly. Runtime state and backups never live in this repository.
