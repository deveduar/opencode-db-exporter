# opencode-db-exporter

Read, back up and export the local SQLite database of **opencode** (the `opencode` CLI) to readable Markdown. It never writes to the opencode database.

Intended for Linux with the **opencode CLI**. The database it reads is the shared store written by opencode at `~/.local/share/opencode/opencode.db`. If your opencode stores the DB elsewhere (other OS, custom `XDG_DATA_HOME`, or the desktop app using its own storage), set `OPENCODE_DB` to point at it.

## Quick start

Run it straight from a checkout (no install), or install it once:

```bash
# portable — nothing to install:
bash src/opencode-db.sh menu

# or install:
./install.sh
opencode-db menu
```

The menu covers everything: export, backups, shrink and session browsing.

## What it does

OpenCode's CLI binds sessions to Git states and working directories, so switching branches or HEAD can hide older sessions even though the data is still in the global SQLite file. `opencode-db` reads that file directly, so every prompt history, agent path and metric stays reachable, and works over the whole hierarchy (roots + subagents):

- **Export** to readable Markdown (`transcript`), a RAG-ready `corpus.jsonl` (`memory`), the compaction digests (`digest`) or a lossless native-JSON archive (`faithful`) — with named **presets** and **bundles**.
- **Back up** the DB with a WAL-safe snapshot and a sha256 manifest; point any read command at a stored backup with `--from-backup`.
- **Shrink** a pruned + VACUUMed **copy**, and optionally **swap** it into the live DB behind guards.
- A **picker-driven fzf menu**, and a **portable** layout (run from a checkout, no install).

## Requirements

- Linux (tested on Debian/Ubuntu) and the opencode CLI
- `sqlite3`, `python3` (**>= 3.10**, uses `str | None` annotations), `jq`, `gzip` (core)
- `fzf` (only for `opencode-db menu`)

The tool can install its own missing dependencies idempotently:

```bash
opencode-db deps --check   # report only (no sudo)
opencode-db deps           # install what's missing (apt/pacman/dnf, prompts for sudo)
```

## Install

```bash
./install.sh            # copies src/+uninstall.sh to ~/.local/share/opencode-db-exporter,
                        # symlinks ~/.local/bin/opencode-db, creates the config if missing
opencode-db status      # first check
```

No installation is strictly required: you can run it straight from the repo with `bash src/opencode-db.sh`.

## Commands

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
- **export runs** — view/remove/prune past runs.

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
opencode-db export archive               # bundle: transcript + memory under ONE stamp
opencode-db export transcript --last 5   # 5 most recently used roots (+ their subagents)
opencode-db export rag --cap 3000        # per-run override
```

- **One selection rule per run**: `--filter`, `--sessions`, `--last`, `--since` (mutually exclusive; CLI-only, never preset keys).
- **CLI wins over preset**: flags/selection on the command line override the preset.
- `export --list-presets` / `--show <name>` / `--dry-run <name>` / `--explain` inspect plans without DB.
- `--sanitize` redacts high-confidence secret prefixes — best-effort; review output before sharing.

## Managing export runs

```bash
opencode-db exports list              # date / profile / counts / size per run
opencode-db exports view <stamp>      # detail: banner, per-product summary, totals, one block per product
opencode-db exports view <stamp> --files   # + produced files with sizes
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
                                           # (offers export archive --sessions <cascade> first)
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
| Native Windows | No | Bash-only (no `.bat`/`.ps1`); `sqlite3`, `python3`, `jq`, `gzip`, `fzf` are absent. Use WSL. |
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
bash tests/export_smoke.sh   # end-to-end against a fake DB -> 437 OK / 0 FAIL
bash tests/menu_flow.sh      # fzf menu logic (fzf stubbed) -> 354 OK / 0 FAIL
```

## Roadmap / Status

- ✅ **Export**: 4 products (`transcript`, `memory`, `digest`, `faithful`), presets, bundles, CLI discovery (`--show/--dry-run/--explain`), sanitization, token backfill, corpus streaming.
- ✅ **Shrink**: selection (keep/older/since/keep-sessions/discard), recipes (`lean`/`quiet`), `shrinks verify` (freshness + discard-export coverage), `--swap` **designed and tested** (not yet validated manually in real environment).
- ✅ **Backups**: WAL-safe snapshots, sha256 manifest, `view` with embedded check, `--from-backup` global.
- ✅ **Menu**: preset-only export, sessions picker (subagents hidden/shown), backups/shrinks/exports pickers with toggle view/remove, integrated verify.
- 🔄 **To validate**: `shrink --swap` in real environment (stop opencode → swap → verify).
- 📋 **Next**: consume `corpus.jsonl`/`faithful` with `consolidation-memory` / LangChain, evaluate `schema_version: 2` if a multi-source consumer emerges.
- 📋 **Nice-to-have**: Windows native (PowerShell), pre-commit hooks for tests, complete `help` for subcommands.