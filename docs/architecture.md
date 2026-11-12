# Architecture — opencode-db-exporter

This page is the map of the system, not a second usage guide. The project has two interfaces with deliberately different responsibilities:

- **Python** (`opencode-db-export.py`) is the stable, primary interface for producing exports. It uses only Python's standard library and opens OpenCode's SQLite DB read-only.
- **Bash** (`opencode-db.sh`, implemented in `src/opencode-db.sh`) provides database inspection, backups, export-run management, shrink operations, and the optional fzf menu. Its `export` command delegates to the Python exporter. `install.sh`/`uninstall.sh` manage this optional Bash command.

## Design documents

- [Export architecture](export-architecture.md): schema facts used by the exporter, product/preset pipeline, hierarchy, and decision matrix.
- [Bash operations](bash-operations.md): entry points, installation scope, and which work belongs to Bash.
- [Shrink architecture](shrink.md): selection rules, recipes, copy lifecycle, and reporting.
- [Menu design](menu-design.md): picker grammar, state, navigation, and prompts.
- [Operational swap safety](swap-safety.md): safeguards for `shrink --swap`.
- [Shared configuration and safety](configuration-and-safety.md): read-only and WAL guarantees plus precedence rules across both interfaces.
- [Artifact schemas](schemas.md): machine-readable contracts for presets, exports, backups, and shrink records.

## Shared invariant

The OpenCode database is never modified by normal inspection, backup, or export workflows. SQLite reads use `mode=ro`; backups use SQLite's WAL-aware `.backup` operation rather than copying the main file. The only operation that replaces the live DB is the explicit, guarded Bash `shrink --swap` workflow described in [swap safety](swap-safety.md).
