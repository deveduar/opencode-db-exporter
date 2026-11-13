# opencode-db-exporter

Export the local **opencode** session database to Markdown, a searchable corpus, compaction digests, or faithful JSON. Python is the stable, primary interface for creating exports and never writes to the opencode database. The optional Bash suite handles database inspection, backups, shrink/run management, and the interactive menu; its export command delegates to the same Python exporter.

The Python exporter runs from a checkout without installation and supports native Windows. On Windows it asks `opencode debug paths db` for the active database path ([OpenCode path docs](https://opencode.ai/docs/cli/#paths)); set this project's `OPENCODE_DB` environment variable to override discovery. Python does not read `opencode-db.conf`.

## Quick start

Python 3.10+ is enough; no `pip install` or `install.sh` is needed. This command
creates the `complete` bundle:

```bash
python3 opencode-db-export.py complete
```

From PowerShell, use `python` instead of `python3`. The default output is `./exports`
when run from a checkout; `--out` or `OCED_OUT` changes it. Live progress is shown on
interactive terminals and can be disabled with `--no-progress`.

## What it does

OpenCode's CLI binds sessions to Git states and working directories, so switching branches or HEAD can hide older sessions even though the data is still in the global SQLite file. The exporter reads that database directly, so every prompt history, agent path and metric stays reachable, including roots and subagents:

- **Export** to readable Markdown (`transcript`), a RAG-ready `corpus.jsonl` (`memory`), the compaction digests (`digest`) or a lossless native-JSON archive (`faithful`) — with named **presets** and **bundles**.
- The optional Bash suite can **back up** the DB with a WAL-safe snapshot and sha256 manifest, **shrink** a copy, manage export/shrink runs, and launch the **fzf menu**.

## Requirements

- Python exporter: Python **>= 3.10** (standard library only; no `pip` dependencies).
- Native Windows database discovery uses the OpenCode CLI; `OPENCODE_DB` can override it.
- Optional Bash suite on Linux/WSL: `bash`, the `sqlite3` executable, Python **>= 3.10**,
  `jq`, and `gzip`. `fzf` is needed only for the menu.

## Which interface does what?

| Capability | Python (`opencode-db-export.py`) | Bash (`opencode-db`) |
|---|---|---|
| Create exports from products/presets, including bundles | Primary, stable interface | `export` delegates to Python |
| Inspect export plans, preflight the DB, preview selected count | Yes (`--show`, `--check`, `--dry-run`) | Export help/plan commands delegate to Python |
| Browse sessions, show status/version/schema | No | Yes |
| Create/verify/manage backups; read via `--from-backup` | No | Yes |
| Manage export runs, including `exports update` | No public run-manager command | Yes; update uses Python export code internally |
| Shrink DB copies, optionally swap, and run the fzf menu | No | Yes |
| Dependencies | Python standard library only | External CLI dependencies listed above |

Use the Python entry point for exporting without installation. The Bash suite is optional:

```bash
./opencode-db.sh menu            # portable Bash menu from a checkout; no install required
./install.sh                    # optional Bash command shim + user configuration
opencode-db status
```

## Python exporter CLI

### Products, presets, and bundles

Every invocation selects **one product or one named preset**. A preset can combine
products into a bundle; multiple independent preset names are not accepted in one run.
`full` aliases the `transcript` product. The shipped named presets are:

| Preset | Output |
|---|---|
| `complete` | `transcript` + `memory` + `faithful` bundle |
| `conversation` | Dialogue-only Markdown |
| `digest` | Compaction summaries |
| `notes` | Markdown with truncated tool output |
| `prompts` | User prompts only |
| `rag` | Memory corpus (`corpus.jsonl`) |
| `review` | Readable Markdown + faithful archive |
| `source` | Faithful JSON archive |
| `study` | Markdown + memory corpus |
| `tool-output` | Tool calls and outputs |

List products and presets or inspect a plan without reading the database:

```bash
python3 opencode-db-export.py --list-products
python3 opencode-db-export.py --list-presets
python3 opencode-db-export.py review --show
python3 opencode-db-export.py complete --dry-run
```

Examples of product/preset combinations and CLI overrides:

```bash
python3 opencode-db-export.py transcript --last 5 --tool-output full --patch omit
python3 opencode-db-export.py memory --sessions ses_abc123 --cap 3000 --files
python3 opencode-db-export.py digest --since 2026-10-01 --no-reasoning
python3 opencode-db-export.py faithful --filter 'ses_project_%' --sanitize
python3 opencode-db-export.py conversation --no-progress
python3 opencode-db-export.py complete --out ./my-exports --no-subagents
```

Important flags by scope:

| Scope | Flags | Effect |
|---|---|---|
| Selection (choose one) | `--filter LIKE`, `--sessions ID[,ID]`, `--last N`, `--since YYYY-MM-DD` | Select matching sessions; `--last` counts roots and includes descendants |
| All products | `--out DIR`, `--no-subagents`, `--no-orphan-subagents`, `--sanitize`, `--no-progress` | Output location; subagent policy; best-effort secret redaction; progress control |
| Single-product workflow | `--snapshot fresh` | Warn if a backup is missing or out of sync |
| All products | `--title TEXT`, `--notes TEXT` | Set run metadata |
| Transcript | `--sub separate\|inline\|omit`, `--tool-output full\|truncated\|omit`, `--tool-input-limit N`, `--tool-output-limit N` | Control subagent rendering and tool content |
| Transcript | `--chunk-mb N`, `--patch full\|omit`, `--no-reasoning`, `--mark-compactions`, `--summary-diffs`, `--role all\|user\|assistant` | Chunking and message-content filters; `--chunk-mb 0` disables chunking |
| Digest | `--no-reasoning`, `--mark-compactions`, `--summary-diffs`, `--role all\|user\|assistant` | Filter digest content |
| Memory | `--cap N`, `--files` | Limit text value length (`0` = unlimited); include touched files |
| Discovery/automation | `--list-products`, `--list-presets`, `--explain`, `--show`, `--dry-run`, `--check`, `--json` | Discover, inspect plans, preflight or preview; JSON is supported with `--check`, `--show`, and `--dry-run` |

`--filter`, `--sessions`, `--last`, and `--since` are mutually exclusive. `--sessions`
accepts repeated ids or a comma-separated list. `--last N` selects the N most recently
updated roots plus their descendants; `--since DATE` uses a UTC date. Command-line
flags override preset settings. Product-specific flags are validated; for the full list
and exact defaults run `python3 opencode-db-export.py --help`. `--sanitize` is best
effort; inspect the export before sharing it.

### Stable automation contract: preflight, plan, and exit codes

The root `opencode-db-export.py` script is the supported Python-only entry point.
`--check --json` reports whether the database can be read and the total session count.
`--dry-run --json` resolves the selected product/preset and reports the count that would
be exported. Both operations open SQLite read-only and create no output files; a dry run
does not create the output directory. `--show --json` returns a static plan without
accessing the database.

The machine-readable preflight shape is:

```json
{"schema_version":1,"status":"ready","database":"/path/opencode.db","session_count":6,"no_data_reason":null,"error":null,"writes":false}
```

All these JSON responses carry `schema_version: 1`. `--dry-run --json` includes `status`, `profile`, `database`, `selection`,
`selected_session_count`, `root_count`, `subagent_count`, `no_data_reason`, `error`,
`plan`, `database_read`, and `writes`. `--show --json` returns `status`, `profile`,
`plan`, `database_read`, `writes`, and `error`. A successful preview has
`"writes": false`; no matches use `"status": "no_data"` and a reason such as
`selection_matched_no_exportable_sessions`.

| Exit code | Meaning |
|---:|---|
| `0` | Preflight/plan succeeded, or export completed |
| `1` | Runtime/configuration/database error |
| `2` | Invalid command-line usage |
| `3` | No data: empty database or selection matched no exportable sessions |

For JSON preflight, an empty database has `"status": "no_data"`,
`"session_count":  0`, and `"no_data_reason": "database_has_no_sessions"`; a database
or SQLite failure has `"status": "error"` and a non-null `error`. JSON is written to
stdout; diagnostics for ordinary exports go to stderr.

Progress is written to stderr only on an interactive terminal. `--no-progress` disables
it, including for bundle products. Export summaries remain available after completion.

### Environment variables and configuration scope

Python reads the environment directly; it does **not** source `opencode-db.conf`.
The Bash command suite reads `OCED_CONF`, whose values are overridden by explicitly
exported environment variables. The shipped preset JSON files are shared by both.

| Variable | Python exporter | Bash suite |
|---|---|---|
| `OPENCODE_DB` | Database file override; on native Windows avoids CLI path discovery | Database file override |
| `OCED_OUT` | Export output root (same as `--out`) | Export output root |
| `OCED_PRESETS` | Export preset JSON file | Export preset JSON file |
| `OCED_TRANSCRIPT_CHUNK_MB` | Default transcript chunk target; `--chunk-mb` overrides | Passed through to Python exporter |
| `OCED_BACKUP_DIR` | Backup directory used for `--snapshot fresh` alignment checks | Backup storage and default location |
| `OCED_FROM_BACKUP` | Does not select a database; only an internal hint for snapshot-warning behavior | Global `--from-backup` source; Bash resolves the file and passes it as `OPENCODE_DB` to export |
| `OCED_CONF` | Not read | Bash path/preferences config file |
| `OCED_SHRINK_PRESETS` | Not read by the exporter (`shrinklib/plan.py` reads it) | Shrink recipe file |
| `OCED_COMPRESS` | Not read | Default gzip behavior for backups |
| `OCED_LOG`, `OCED_ACTIVITY_LOG` | Not read | Opt-in activity log and its path |
| `OCED_TZ` | Not read | Menu picker display timezone; CLI/files stay UTC |
| `OCED_SHRINK_DISCARD_EXPORT_PROFILE` | Not read | Default export preset used by the shrink discard offer |
| `OCED_BIN`, `OCED_PREFIX` | Not read | Bash install shim and install directory overrides |
| `OCED_SPINNER_DISABLE` | Not read | Set to `1` to disable the Bash menu spinner |

Direct Python defaults: `OPENCODE_DB` or the OpenCode default DB path;
`OCED_OUT` or `./exports` in a checkout (otherwise the user's app-data exporter
directory); `OCED_PRESETS` or the user's config preset file, falling back to the
shipped repository presets. Set an environment variable or pass `--out` explicitly
when embedding the exporter.

### Database safety and WSL/Windows notes

Python opens the opencode database with SQLite URI `mode=ro`; it never updates the
database. `--dry-run` also only reads. OpenCode uses SQLite WAL: the active database
may include committed records in its `-wal` sidecar, so keep the database and WAL/SHM
files together and readable. Avoid copying just `opencode.db` while OpenCode is
running. The Bash `backup` command uses SQLite's `.backup` operation for a consistent
WAL-aware snapshot; it is not part of the Python export CLI.

On WSL, prefer the Linux-side database if OpenCode runs in WSL. Accessing a native
Windows database over `/mnt/c` can be affected by SQLite locking and WAL behavior on
the mounted filesystem. Native Windows Python export resolves the database through
`opencode debug paths db`; setting `OPENCODE_DB` bypasses discovery. Native Windows
support here means export access, not the Bash backup/shrink/menu suite.

## Bash command suite

The optional Bash interface provides database inspection, backup and run management,
shrink copies, and the fzf menu. Its `export` command delegates to the Python exporter.
From a checkout, use `./opencode-db.sh`; `./install.sh` installs the `opencode-db`
command and its Bash configuration on Linux/WSL.

```bash
opencode-db status
opencode-db list --root --order updated-desc
opencode-db backup --dry-run
opencode-db backups list
opencode-db exports list
opencode-db exports update <stamp>
opencode-db shrink --keep 10 --dry-run
opencode-db shrinks verify
opencode-db menu
```

`--from-backup <file>` is a global Bash option placed before the command. Backups use
SQLite's WAL-aware `.backup`; shrink builds a separate copy by default. Only explicit,
guarded `shrink --swap` replaces the live database. For command details, menu behavior,
and install/uninstall scope, see [Bash operations](docs/bash-operations.md),
[shrink architecture](docs/shrink.md), [menu design](docs/menu-design.md), and
[swap safety](docs/swap-safety.md).

## Configuration and portability

`OPENCODE_DB` is **this exporter's environment variable**, not an OpenCode setting.
Python reads it directly and does not load `opencode-db.conf`. Bash loads
`opencode-db.conf` (or `OCED_CONF`); explicitly exported environment variables take
precedence. Python runs on Linux, WSL, and native Windows (where OpenCode CLI discovery
is used unless `OPENCODE_DB` is set). Bash management commands are for Linux/WSL.

From a checkout, Bash defaults exports, backups, and the activity log to gitignored
repo directories, even if an installed user config exists. This data-path default is
separate from config and preset lookup: each uses the user's `~/.config/opencode-db/`
file when present, falling back to the repo-shipped file. Explicit environment values
take precedence over `OCED_CONF`; values in the selected config can override the
repo-local data paths. `./install.sh` and `./uninstall.sh` manage only the optional
Linux/WSL Bash installation; installing does not change Python's checkout defaults.
Re-run `./install.sh` after updating the checkout to refresh the separate installed
Bash copy. An installed prefix itself defaults to app-data paths.
WSL access to a Windows-mounted DB can be affected by SQLite WAL locking; keep its DB
and sidecars together. Details:
[shared configuration and safety](docs/configuration-and-safety.md).

## Documentation and validation

- [Architecture overview](docs/architecture.md)
- [Export pipeline](docs/export-architecture.md)
- [Artifact schemas](docs/schemas.md)

```bash
bash tests/export_smoke.sh
bash tests/menu_flow.sh
```

## Roadmap

- ✅ Python-first exporter, presets/bundles, JSON preflight/plans, no-data exit code,
  progress control, sanitization, and streaming corpus.
- ✅ Optional Bash inspection, WAL-safe backups, run management, shrink copies, and menu.
- 🔄 Validate `shrink --swap` in a real environment.
- 🔄 Install and run the Python exporter on native Windows.
- 📋 Evaluate the exported corpus with `consolidation-memory` / LangChain.
