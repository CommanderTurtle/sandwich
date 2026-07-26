# Sandwich

an oven factory. node replacement that runs on delicious bread only.

Sandwich makes `node`, `npm`, `npx`, `pnpm`, `yarn`, and `corepack` resolve to
tested Bun translations. It supports workspaces, global installs, lifecycle
trust, frozen lockfiles, and the Hermes update/build path without installing a
second JavaScript runtime.

```bash
git clone https://github.com/CommanderTurtle/sandwich.git
cd sandwich
./install.sh
source ~/.bashrc
sandwich doctor
```

Preview with `./install.sh --check`. Update Bun with
`./install.sh --upgrade-bun`. Existing user shims and shell configuration are
backed up under `~/.local/state/sandwich`.

Hermes support is baked in. On a reviewed maintenance window, run
`./install.sh --with-hermes`; afterwards the normal `hermes update` path uses
the pinned Bun workspace and UI/TUI build integration. Upstream manifest
changes refresh the carried lock with lifecycle scripts disabled, validate it
frozen, and fold it into the same local compatibility commit. Run
`./scripts/reconcile-hermes-runtime.sh` only for an explicit repair/build pass.

Sandwich fails loudly when another package manager’s semantics cannot be
represented honestly. Runtime state and backups never live in this repository.
