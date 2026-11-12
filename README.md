# opencode-db-exporter

Export the local **opencode** session database to Markdown, a searchable corpus, compaction digests, or faithful JSON. Python is the stable, primary interface for creating exports and never writes to the opencode database. The optional Bash suite handles database inspection, backups, shrink/run management, and the interactive menu; its export command delegates to the same Python exporter.

The Python exporter runs from a checkout without installation and supports native Windows. On Windows it asks `opencode debug paths db` for the active database path ([OpenCode path docs](https://opencode.ai/docs/cli/#paths)); set `OPENCODE_DB` to override it.

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
bash src/opencode-db.sh menu    # portable menu from a checkout; no install required
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

These commands provide database/run management and the interactive menu; they are
not prerequisites for the Python exporter.

```bash
opencode-db menu                      # interactive fzf menu
opencode-db status                    # DB state + alignment with the last backup + version/schema + dependency check
opencode-db version                   # tool version + opencode CLI version + schema probe
opencode-db list [--root|--sub] [--filter PATTERN] [--info]
                                      # --order: created-asc|created-desc|updated-asc|updated-desc
opencode-db info <session_id> [--json] [--no-digest]
                                      # banner + tokens, cost, digests, counts
                                      # --json = the row as JSON (no banner)
                                      # --no-digest = drop the compaction-digest block
opencode-db digest <session_id> [show [last|N|all]]
                                      # compaction MARKERS (points); 'show' prints
                                      # the DIGEST written for each one
                                      # ('compactions' is the deprecated alias)
opencode-db backup [--no-compress] [--dry-run] [--yes]   # consistent snapshot (.backup), gzip + sha256 + manifest
                                          # --dry-run prints the plan (source/target/est. size) and writes nothing
                                          # --yes skips the question AND the plan (the caller owns the gate)
opencode-db backups [list|view <file> [--json]|verify <file>|remove <file> [--yes]|prune <N>]
opencode-db export <product> [FLAGS]    # products: transcript | memory | digest | faithful
opencode-db export --list-presets       # list the named presets in the presets file
opencode-db export --check --json       # read-only preflight (database + session count)
opencode-db export <name> --show         # the resolved plan only (static, no DB read)
opencode-db export <name> --dry-run      # plan + sessions the selection would match (writes nothing)
opencode-db exports [list|remove <stamp> [--yes]|prune <N> [--yes]]
opencode-db shrink [preset|--keep N|--older-than DAYS|--since DATE|--keep-all
                    |--keep-sessions ID[,ID]|--discard-sessions ID[,ID]]
                    [--strip-reasoning] [--list-presets] [--dry-run] [--swap]
                                      # pruned + VACUUMed COPY (never touches the live DB
                                      # unless --swap replaces it safely)
opencode-db shrinks [list [--tsv]|view <stamp>|verify [--tsv] [--yes]|remove <stamp> [--yes]|prune <N>]
                                      # manage the produced shrink copies
opencode-db deps [--check]              # idempotent dependency check/install (apt|pacman|dnf)
opencode-db help
```

## Menu (opencode-db menu)

The interactive menu is **picker-driven**: real fzf lists, no nested menus, no TAB multi-select.
Mode switching and bulk operations are their own rows.

| Marker | What the row does | Examples |
| --- | --- | --- |
| `[>]` | opens a flow (create / swap / continue) | `[>] create backup`, `[>] swap a copy into the LIVE DB` |
| `[?]` | inspects something | `[?] verify` |
| `[*]` | flips a mode and re-renders (shows both states) | `[*] view → remove`, `[*] newest first → old first` |
| `[word]` | bulk action | `[mark all]`, `[unmark all]`, `[delete all]` |
| `[x]` / `[ ]` | whether a session is included | `[x] My session (2 sub)` |

**Pickers** (each with a `view`/`remove` toggle + `newest first`/`old first` sort):
- **status** — full report (DB, backups alignment, version/schema, deps); header counts refresh on every loop.
- **backups** — create (plan → y/N → run) + manage; `view` runs sha256 check + live-DB compare.
- **sessions** — details only; pick a row for `info` + digests.
- **shrinks** — create (3-step wizard: sessions → recipe → plan) + manage; `swap` requires typing `confirm`, checks staleness first.
- **export** — preset-only: (1) mark root sessions (subagents hidden by default, cascade included), (2) pick preset, (3) confirm with effective selection shown.
- **export runs** — view/update/remove/prune past runs.

## Export

**Four products** (what a document is):

| Product | Document | Typical use |
| --- | --- | --- |
| `transcript` | conversation in Markdown (text + tools + patches + digests) | read, share, audit |
| `memory` | `corpus.jsonl` — one JSON line per root session (goal, outcome, digests, metadata) | feed another AI (RAG) |
| `digest` | only the compacted-context digests | quick knowledge review |
| `faithful` | lossless machine archive: one native JSON file per session (all messages, parts, reasoning) | recoverable source / tools |

Named **presets** (a product or bundle + config + optional selection) live in `OCED_PRESETS`
(default `~/.config/opencode-db/presets.json`, auto-created by `install.sh`).

```bash
opencode-db export review                # run the named preset
opencode-db export review --sanitize     # opt into best-effort redaction for one run
opencode-db export complete              # transcript + memory + faithful, grouped by session
opencode-db export transcript --last 5   # 5 most recently used roots (+ their subagents)
opencode-db export rag --cap 3000        # per-run override
```

- **One selection rule per run**: `--filter`, `--sessions`, `--last`, `--since` (mutually exclusive; CLI-only, never preset keys).
- **CLI wins over preset**: flags/selection on the command line override the preset.
- `export --list-presets` / `--show <name>` / `--dry-run <name>` / `--explain` inspect plans without DB.
- `--sanitize` redacts high-confidence secret prefixes — best-effort; review output before sharing.

## Managing export runs

Run management is exposed by the optional Bash suite; `exports update` uses the Python
export engine internally, but is not a separate public Python CLI command.

```bash
opencode-db exports list              # date / profile / counts / size / preset / status / refresh
opencode-db exports view <stamp>      # detail: sessions, "Changed since export" and "New in scope", excluded
opencode-db exports view <stamp> --files   # + produced files with sizes
opencode-db exports freshness <stamp> --tsv    # stale/missing/unverifiable plus new in-scope (--json = array)
opencode-db exports update <stamp>    # refresh in place (delta by default; --mode accumulative to reopen scope)
opencode-db exports remove <stamp>    # delete one run (asks; --yes to skip)
opencode-db exports prune 5           # keep only the 5 most recent runs
```

## Compaction digests

`opencode-db digest <id> show` prints a session's digests; the `digest` export product
writes one markdown file per session with them. `compactions` is a deprecated alias.

## shrink — a lighter DB copy to swap over opencode

The opencode DB only grows. `opencode-db shrink` builds a pruned + VACUUMed **copy** from a snapshot; by default it never touches the live DB, while `--swap` installs it safely after a safety snapshot.

```bash
opencode-db shrink                         # default: 10 most recent sessions
opencode-db shrink lean                    # + strip reasoning parts (recommended)
opencode-db shrink quiet                   # prune + vacuum only, keep full text
opencode-db shrink --keep 5 --dry-run      # only report what would be pruned
opencode-db shrink --older-than 30         # keep sessions updated in the last 30 days
opencode-db shrink --since 2026-01-15      # keep sessions updated since date (UTC)
opencode-db shrink --keep-sessions ID...   # keep ONLY the listed ids + their parents/subagents
opencode-db shrink --discard-sessions ID...# keep everything EXCEPT the ids + their subagents
                                           # (offers export complete --sessions <cascade> first)
opencode-db shrink lean --keep 30          # raw flags compose over a recipe
opencode-db shrink lean --swap             # build copy AND replace live DB (safe)
```

A shrink has two independent parts:
- **Selection** (exactly one): `--keep N` (default 10), `--older-than DAYS`, `--since DATE`, `--keep-all`, `--keep-sessions`, `--discard-sessions`.
- **Operations** (recipe only): `lean` = strip reasoning, `quiet` = prune + vacuum only.

Built-in recipes exist; a custom recipes file (`OCED_SHRINK_PRESETS`,
`~/.config/opencode-db/shrink-presets.json`) extends/overrides them.

Output: `backups/shrink/<timestamp>/opencode.shrunk.db` + `shrink.json` (criteria, counts, per-table removed rows, sizes, integrity checks). The copy is verified before being stored.

## Managing shrink copies

```bash
opencode-db shrinks list              # date / tag / kept/total / size delta
opencode-db shrinks view <stamp> [--json]  # detail screen (sessions/size/criteria/freshness/ids)
opencode-db shrinks verify [--tsv] [--yes]  # audit: orphan dirs, freshness of EVERY copy vs live DB,
                                            # and that every discard's cascade still has a covering export run
opencode-db shrinks remove <stamp>    # delete one copy (asks; --yes to skip)
opencode-db shrinks prune 3           # keep only the 3 most recent copies
```

## Activity log (opt-in)

`OCED_LOG=1` appends mutations (backup created, exports/prune, shrink) to `OCED_ACTIVITY_LOG`
(default `~/.local/state/opencode-db/activity.log`, or `./activity.log` when running portably
from the repo), one tab-separated line per event. Nothing is ever logged by default.

## Reading from a backup

The global flag `--from-backup` (before the subcommand) points every read command at a stored backup instead of the live DB. It accepts a filename under `OCED_BACKUP_DIR` or an absolute path, and transparently decompresses `.gz` backups to a temp file. The live DB is never touched.

```bash
opencode-db --from-backup opencode-20260920-155652.db.gz status
opencode-db --from-backup opencode-20260920-155652.db.gz list --root
opencode-db --from-backup opencode-20260920-155652.db.gz export memory
```

`status`/`version` report whether the backup is `[OK] aligned` with the live DB or `[!] out of sync`.

## Uninstall

```bash
./uninstall.sh          # removes the installed code + shim; keeps config/backups/exports
./uninstall.sh --all    # also removes config, backups and exports
```

It never removes system packages: dependencies installed by `opencode-db deps` stay on the system.

## Design notes

The detailed architecture — the data-access model (WAL, `.backup`, `--from-backup`),
the opencode data model, the export pipeline (products, sanitization **in memory on
native types before serializing**, token backfill, streaming corpus), the menu design and
the `shrink --swap` safeguards — lives in **[docs/architecture.md](docs/architecture.md)**.

Machine contracts (presets, `metadata.json`, corpus, faithful archive, manifests):
**[docs/schemas.md](docs/schemas.md)**.

This README covers usage only. One fact worth knowing here: dates are stored and printed
in **UTC** everywhere (ISO-8601, `Z`), except the **menu picker rows**, which show your
local time — set `OCED_TZ` (e.g. `Europe/Madrid`) to pin the display zone instead of
auto-detecting the system one. It never affects files or the CLI.

## Portability (WSL / Windows / portable)

| Scenario | Works? | Notes |
|----------|--------|-------|
| Linux (Debian/Ubuntu) | Yes | `opencode-db deps` installs missing packages via `apt`. |
| Linux (Arch/omarchy, pacman) | Yes | `deps` installs via `pacman -S --needed`; all packages are in the repos. |
| Linux (Fedora, dnf) | Yes | `deps` installs via `dnf install -y`. |
| WSL, opencode inside WSL | Yes | Defaults match; `deps` uses `apt`/`sudo`. |
| WSL, opencode is native Windows | Yes, with config | Set `OPENCODE_DB=/mnt/c/Users/<user>/.local/share/opencode/opencode.db`. Residual risk: SQLite WAL file locking over `drvfs`. |
| Native Windows | Generate exports only | Use `python opencode-db-export.py <preset>`; the OpenCode CLI resolves its database path. Bash run management, backups, shrink and menu remain Linux/WSL.|
| Git Bash / MSYS2 | Partial | Runs only if you install those tools yourself; `deps` refuses to install (no `apt`/`pacman`/`dnf`). |
| Portable (no install) | Yes | Run `bash src/opencode-db.sh …` straight from the repo. The repo-shipped config is read directly; exports/backups/activity log default into the repo (`./exports`, `./backups`, `./activity.log`, gitignored). |

- **Portable run**: the repo ships three real config files — `opencode-db.conf`, `presets.json`, `shrink-presets.json` — the single source of truth (there are no `.example` copies anymore). Running from the checkout auto-discovers them; `~/.config/opencode-db/` is only consulted when it already has a file there (your config wins over the repo's, never the reverse). Exports/backups/activity log default into the repo (`./exports`, `./backups`, `./activity.log` — gitignored), so a clone sandbox stays fully local. The repo's shipped conf is read, never chmod'ed; a conf under `~/.config/opencode-db/` still gets `chmod 600` as before.
- **Removing data**: portable data lives in the repo (`./exports`, `./backups`, `./activity.log`) and is gitignored — `uninstall.sh --all` only knows the installed `~/.local/share/opencode-db-exporter/` and does not reach repo data. Delete those directories yourself (or keep them; they are yours).

### Portable configuration

In portable mode you do not need `install.sh` and nothing is created for you: running the CLI from the checkout reads the repo-shipped files. Per config file the resolution is `~/.config/opencode-db/<file>` if present, else the repo-shipped copy (a prefix that ships no config at all, like an install, never goes portable). You can still point `OCED_CONF`/`OCED_PRESETS`/`OCED_SHRINK_PRESETS` at any file on your machine:

```bash
cp opencode-db.conf ./portable.conf
OCED_CONF=./portable.conf bash src/opencode-db.sh status
```

Environment variables still win over that file, which in turn wins over the per-file default: **environment > conf file > `~/.config` > repo-shipped > built-in default**.

## Tests

```bash
bash tests/export_smoke.sh   # end-to-end against a fake DB; never touches real data
bash tests/menu_flow.sh      # menu logic with fzf stubbed
```

## Roadmap / Status

- ✅ **Export**: 4 products (`transcript`, `memory`, `digest`, `faithful`), presets, bundles, CLI discovery/preflight (`--show/--dry-run/--check --json`), no-data exit status, sanitization, token backfill, corpus streaming.
- ✅ **Shrink**: selection (keep/older/since/keep-sessions/discard), recipes (`lean`/`quiet`), `shrinks verify` (freshness + discard-export coverage), `--swap` **designed and tested** (not yet validated manually in real environment).
- ✅ **Backups**: WAL-safe snapshots, sha256 manifest, `view` with embedded check, `--from-backup` global.
- ✅ **Menu**: preset-only export, sessions picker (subagents hidden/shown), backups/shrinks/exports pickers with toggle view/remove, integrated verify.
- 🔄 **To validate**: `shrink --swap` in real environment (stop opencode → swap → verify).
- 🔄 **To validate**: install and run the Python exporter in a real native Windows environment.
- 📋 **Next**: consume `corpus.jsonl`/`faithful` with `consolidation-memory` / LangChain, evaluate `schema_version: 2` if a multi-source consumer emerges.
- 📋 **Nice-to-have**: native Windows run management/backups/shrink/menu, pre-commit hooks for tests, complete `help` for subcommands.