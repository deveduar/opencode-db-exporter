# Bash operations

> The optional Bash interface manages the database and stored artifacts. For creating exports, the stable primary interface is [the Python CLI](../README.md#python-exporter-cli); Bash `export` delegates to that same engine.

## Entry points and installation

- From a checkout, run `./opencode-db.sh <command>` without installing.
- `./install.sh` installs the Bash command as `~/.local/bin/opencode-db`, copies `src/`, and installs the shipped preset files into the user config directory. It does not install the root Python launcher; Python export remains available from the checkout.
- `./uninstall.sh` removes the installed Bash code and shim while preserving configuration and data; `--all` also removes the installed config/data.
- `install.sh` and `uninstall.sh` stay at the repository root because they are user-facing lifecycle commands, not internal implementation scripts.

The install copies the current `src/` tree, so Bash-dispatched Python features and bundles are updated by reinstalling. The exported `opencode-db` shim points directly at the installed `src/opencode-db.sh` dispatcher. The installer checks for Bash-suite dependencies but does not install them.

## Responsibilities

| Bash command family | Responsibility |
|---|---|
| `status`, `version`, `list`, `info`, `digest` | Read-only database inspection and schema/dependency reporting |
| `backup`, `backups` | WAL-aware snapshots, manifest/hash validation, retention |
| `exports` | List/view/verify/update/remove/prune stored export runs; update invokes the Python export engine |
| `shrink`, `shrinks` | Build and manage pruned database copies; optional guarded `--swap` |
| `menu` | Optional fzf interface over the same workflows |
| `export` | Validate Bash dependencies/config and dispatch to `src/exportlib/cli.py` |

For details, see [shrink architecture](shrink.md), [swap safety](swap-safety.md), [menu design](menu-design.md), [shared configuration and safety](configuration-and-safety.md), and [README command reference](../README.md#bash-command-suite).
