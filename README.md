# opencode-db-exporter

Export the local **opencode** session database to Markdown, a searchable corpus, compaction digests, or faithful JSON. Python is the stable, primary interface for creating exports and never writes to the opencode database. The optional Bash suite handles database inspection, backups, shrink/run management, and the interactive menu; its export command delegates to the same Python exporter.

The Python exporter runs from a checkout without installation and supports native Windows. On Windows it asks `opencode debug paths db` for the active database path ([OpenCode path docs](https://opencode.ai/docs/cli/#paths)); set this project's `OPENCODE_DB` environment variable to override discovery. Python does not read `opencode-db.conf`.

## Quick start

Python 3.10+ is enough; no `pip install` or install step is needed. This command
creates the `complete` bundle:

```bash
python3 opencode-db-export.py complete
```

From PowerShell, use `python` instead of `python3`. The default output is `./exports`
when run from a checkout; `--out` or `OCED_OUT` changes it. Live progress is shown on
interactive terminals and can be disabled with `--no-progress`.

## What it does

OpenCode's CLI binds sessions to Git states and working directories, so switching branches or HEAD can hide older sessions even though the data is still in the global SQLite file. The exporter reads that database directly, so every prompt history, agent path and metric stays reachable, including roots and subagents:

- **Export** to readable Markdown (`transcript`), a  `corpus.jsonl` (`memory`), the compaction digests (`digest`) or a lossless native-JSON archive (`faithful`) — with named **presets** and **bundles**.
- The optional Bash suite can **back up** the DB with a WAL-safe snapshot and sha256 manifest, **shrink** a copy, manage export/shrink runs, and launch the **fzf menu**.

## Requirements

- Python exporter: Python **>= 3.10** (standard library only; no `pip` dependencies).
- Native Windows database discovery uses the OpenCode CLI; `OPENCODE_DB` can override it.
- Optional Bash suite on Linux/WSL: `bash`, the `sqlite3` executable, Python **>= 3.10**,
  `jq`, and `gzip`. `fzf` is needed only for the menu.

## Which interface does what?

Use the Python entry point (`opencode-db-export.py`) to export without installing; it is the primary interface and needs only the standard library. The optional Bash suite (`opencode-db`) adds database status/version, backups, export-run management, shrink copies, and the fzf menu; its `export` command delegates to the same Python engine.

```bash
# export (also --show/--check/--dry-run)
python3 opencode-db-export.py complete
# read-only session feed
python3 opencode-db-export.py --list-sessions --json
# Bash: DB/schema/dependency status
./opencode-db.sh status
# Bash: WAL-safe backups
./opencode-db.sh backups list
# Bash: refresh a stored export run
./opencode-db.sh exports update <stamp>
# Bash: plan a shrink copy
./opencode-db.sh shrink --keep 10 --dry-run
# Bash: fzf menu from a checkout
./opencode-db.sh menu
# optional shim + user config
./scripts/install.sh
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
| `corpus` | Memory corpus (`corpus.jsonl`) |
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

Examples (command-line flags override preset settings):

```bash
# Selection: exactly one of --filter/--sessions/--last/--since.
# 5 newest roots + their subagents
python3 opencode-db-export.py transcript --last 5
# exact ids (comma-separated)
python3 opencode-db-export.py memory --sessions ses_abc123,ses_def456
# updated on/after a UTC date
python3 opencode-db-export.py digest --since 2026-10-01
# id/title LIKE pattern
python3 opencode-db-export.py faithful --filter 'ses_project_%'

# All products: output, subagent policy, redaction, progress, run metadata.
python3 opencode-db-export.py complete --out ./my-exports
# drop every subagent
python3 opencode-db-export.py complete --no-subagents
# keep only subagents whose parent is selected
python3 opencode-db-export.py faithful --no-orphan-subagents
# best-effort secret redaction
python3 opencode-db-export.py transcript --sanitize
# no stderr progress
python3 opencode-db-export.py conversation --no-progress
python3 opencode-db-export.py review --title "October review" --notes "before cleanup"

# Single-product workflows can guard on backup freshness.
# warn if the backup is missing or stale
python3 opencode-db-export.py transcript --snapshot fresh

# Transcript: subagent layout and tool content.
python3 opencode-db-export.py transcript --sub separate --tool-output truncated
python3 opencode-db-export.py transcript --sub inline --tool-input-limit 2000 --tool-output-limit 4000
python3 opencode-db-export.py transcript --sub omit --tool-output omit --patch omit

# Transcript: chunking and content filters (0 disables chunking).
python3 opencode-db-export.py transcript --chunk-mb 0
python3 opencode-db-export.py transcript --no-reasoning --mark-compactions --summary-diffs --role user

# Digest content filters.
python3 opencode-db-export.py digest --no-reasoning --mark-compactions --summary-diffs --role assistant

# Memory: cap text values (0 = unlimited) and include touched files.
python3 opencode-db-export.py memory --cap 3000 --files

# Discovery and automation (no export).
python3 opencode-db-export.py --list-products
python3 opencode-db-export.py --list-presets
python3 opencode-db-export.py --explain
python3 opencode-db-export.py complete --show
python3 opencode-db-export.py complete --dry-run --json
python3 opencode-db-export.py --check --json
python3 opencode-db-export.py --list-sessions --json
```

`--filter`, `--sessions`, `--last`, and `--since` are mutually exclusive. `--sessions`
accepts repeated ids or a comma-separated list. `--last N` selects the N most recently
updated roots plus their descendants; `--since DATE` uses a UTC date. Command-line
flags override preset settings. Product-specific flags are validated; for the full list
and exact defaults run `python3 opencode-db-export.py --help`. `--sanitize` is best
effort; inspect the export before sharing it.

### Automation contract: preflight, plan, and exit codes

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

### Session listing

`--list-sessions [--json]` is the read-only session.

```bash
# All sessions, newest updated first (the default order).
python3 opencode-db-export.py --list-sessions

# Stable JSON for a launcher; no output directory is created.
python3 opencode-db-export.py --list-sessions --json

# The 5 most recently used roots plus their subagents.
python3 opencode-db-export.py --list-sessions --last 5 --json

# Exact ids (repeat --sessions or use one comma-separated list).
python3 opencode-db-export.py --list-sessions --sessions ses_abc123,ses_def456

# Sessions updated on/after a UTC date, oldest created first.
python3 opencode-db-export.py --list-sessions --since 2026-01-01 --order created-asc

# id or title LIKE pattern, newest created first.
python3 opencode-db-export.py --list-sessions --filter '%refactor%' --order created-desc
```

`--order` accepts `created-asc`, `created-desc`, `updated-asc`, or `updated-desc`
(default). The JSON shape is:

```json
{"schema_version":1,"tool":"opencode-db/exportlib","version":"…","ok":true,"status":"ready","source":{"resolved":"/path/opencode.db","exists":true,"origin":"environment"},"sessions_found":1,"no_data_reason":null,"error":null,"writes":false,"sessions":[{"id":"ses_…","title":"…","created":"…","updated":"…","created_at":"…Z","updated_at":"…Z","revision":1731840421000,"project_id":"…","directory":"…","parent_id":null,"kind":"root","source":"opencode","source_file":"/path/opencode.db"}]}
```

`origin` is `environment`, `opencode-cli`, or `default`. `kind` is `root` or `subagent`
(an orphan whose parent row is gone is a root). Each JSON session includes
canonical `created_at` and `updated_at` UTC timestamps; `created` and
`updated` remain compatibility aliases. `revision` is the source database's
`time_updated` integer used by change-aware launchers. Use `updated_at` for
display and ordering; the integer remains the equality token. Per-session
folders and files begin with the UTC last-update date, followed by title and
short session ID. Run folders use a UTC `YYYYMMDDTHHMMSSZ` stamp and append
the preset name with one underscore (for example, `20261118T005834Z_complete`).
Older run folders remain readable.
The text form prints
`Sessions found: N` followed by one line per session. Exit codes match the contract
above; an empty DB or an empty selection returns `3` with a `no_data_reason`, and a
missing/unreadable DB returns `1` with `"status":"error"`.

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
From a checkout, use `./opencode-db.sh`; `./scripts/install.sh` installs the `opencode-db`
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
repo-local data paths. `./scripts/install.sh` and `./scripts/uninstall.sh` manage only the optional
Linux/WSL Bash installation; installing does not change Python's checkout defaults.
Re-run `./scripts/install.sh` after updating the checkout to refresh the separate installed
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

- [x] Python-first exporter, presets/bundles, JSON preflight/plans, no-data exit code,
  progress control, sanitization, and streaming corpus.
- [x] Optional Bash inspection, WAL-safe backups, run management, shrink copies, and menu.
- [ ] Validate `shrink --swap` in a real environment.
- [ ] Test on a Windows machine with OpenCode installed, end to end. is (Python-level only).
- [ ] Evaluate the exported corpus with `consolidation-memory` / LangChain.
