# Bash operations

> The optional Bash interface manages the database and stored artifacts. For creating exports, the stable primary interface is [the Python CLI](../README.md#python-exporter-cli); Bash `export` delegates to that same engine.

## Entry points and installation

- From a checkout, run `./opencode-db.sh <command>` without installing.
- `./scripts/install.sh` is for Linux/WSL. It installs the Bash command as `~/.local/bin/opencode-db`, copies `src/` and `scripts/{install,uninstall}.sh` into the prefix, and installs the shipped preset files into the user config directory. The installed prefix has no root-level `install.sh`/`uninstall.sh`. It does not install or configure the Python entry point.
- `./scripts/uninstall.sh` removes the installed Bash code and shim while preserving configuration and data; `--all` also removes the installed config/data. Neither script affects Python's checkout mode or repo-local exports.
- The dispatcher exposes the same lifecycle commands as `opencode-db install` and `opencode-db uninstall`; both resolve `$OCED_REPO_ROOT/scripts/<name>.sh` and fail if that file is missing (there is no fallback to a root-level copy).

The install copies the current `src/` tree, so Bash-dispatched Python features and bundles are updated by re-running `./scripts/install.sh` after updating the checkout; changing the shared checkout alone does not update the installed copy. The exported `opencode-db` shim points directly at the installed `src/opencode-db.sh` dispatcher. The installer checks for Bash-suite dependencies but does not install them. Running the checkout launcher defaults output/backups/logs to the repo even when an installed user's config exists; explicit path settings still win. The installed prefix, which ships no repo config, defaults to `~/.local/share/opencode-db-exporter/`.

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
