# opencode-db-exporter

Read, back up and export the local SQLite database of **opencode** (`opencode` CLI) to readable Markdown. It never writes to the opencode database: every access is read-only (`mode=ro`).

Intended for Linux with the **opencode CLI**. The database it reads is the shared store written by opencode at `~/.local/share/opencode/opencode.db`. If your opencode stores the DB elsewhere (other OS, custom `XDG_DATA_HOME`, or the desktop app using its own storage), set `OPENCODE_DB` to point at it.

## Motivation

OpenCode's CLI binds sessions to Git states and working directories, so switching
branches or HEAD can hide older sessions even though the data is still in the global
SQLite file. `opencode-db` reads that file directly in **strict read-only mode** — no
CLI filters, no writes — so every prompt history, agent path and metric stays
exportable. The full design rationale (data model, export pipeline, sanitization, menu
and `shrink --swap` safeguards) is in **[docs/architecture.md](docs/architecture.md)**.

## Requirements

- Linux (tested on Debian/Ubuntu) and the opencode CLI
- `sqlite3`, `python3` (**>= 3.10**, uses `str | None` annotations), `jq`, `gzip` (core)
- `fzf` (only for `opencode-db menu`)

The tool can install its own missing dependencies idempotently:

```bash
opencode-db deps --check   # report only (no sudo)
opencode-db deps # install what's missing (apt/pacman/dnf, prompts for sudo)
```

## Install

```bash
./install.sh            # copies modules+tests(+uninstall.sh) to ~/.local/share/opencode-db-exporter,
                        # symlinks ~/.local/bin/opencode-db, creates the config if missing
export PATH="$HOME/.local/bin:$PATH"
opencode-db status      # first check
```

No installation is strictly required: you can run it straight from the repo with `bash modules/opencode-db.sh`.

## Commands

```bash
opencode-db menu                      # interactive fzf menu
opencode-db status                    # DB state + alignment with the last backup + version/schema + dependency check
opencode-db version                   # tool version + opencode CLI version + schema probe
opencode-db list [--root|--sub] [--filter PATTERN] [--info]
                                      # --order: created-asc|created-desc|updated-asc|updated-desc
opencode-db info <session_id>         # tokens, cost, compactions, counts
opencode-db compactions <session_id> [show [last|N|all]]
                                      # compaction points; 'show' prints the digest
opencode-db backup [--no-compress]    # consistent snapshot (.backup), gzip + sha256 + manifest
opencode-db backups [list|verify <file>|prune <N>]
opencode-db export <product> [FLAGS]  # products: transcript | memory | compactions
opencode-db exports [list|remove <stamp> [--yes]|prune <N> [--yes]]
opencode-db shrink [preset|--keep N|--older-than DAYS|--since DATE|--keep-all
                    |--keep-sessions ID[,ID]|--discard-sessions ID[,ID]]
                    [--strip-reasoning] [--list-presets] [--dry-run] [--swap]
                                      # pruned + VACUUMed COPY (never touches the live DB
                                      # unless --swap replaces it safely)
opencode-db shrinks [list [--tsv]|view <stamp>|verify [--tsv] [--yes]|remove <stamp> [--yes]|prune <N>]
                                      # manage the produced shrink copies
opencode-db guide [--list]            # linear wizard: export -> shrink -> swap (type 'confirm' to swap)
opencode-db deps [--check]            # idempotent dependency check/install (apt|pacman|dnf)
opencode-db help
```

## Menu (opencode-db menu)

The interactive menu is **picker-driven**: the main pickers are real fzf lists, not nested
menus. There is **no TAB multi-select** — mode switching and bulk operations are their own
rows. The `backups`, `sessions` (details), `exports` and `shrinks` pickers are
**single-mode**; the export picker is **preset-only** (it needs a presets file).

- **status** — the full report (DB, backups alignment, version/schema, dependencies) + pause.
  The header counts (DB/sessions/WAL/backups/exports) are recomputed on every root loop, so
  they are never stale after an action.
- **backups** picker (single mode) — rows: `[create backup]`, `[delete ALL backups]`,
  `[delete olds (keep newest)]` and one row per backup (date/size/sessions/msgs/sha).
  Selecting a row removes it with confirmation. Shrink creation lives in its own **shrinks**
  picker. Verify stays in the CLI (`backups verify <file>`), for after-copy or before
  `--from-backup` checks.
- **sessions** picker (details only) — one row per session; selecting one shows the full
  info + compaction digests.
- **shrinks** picker (create + manage) — rows: `[create shrink copy…]` (a 3-step wizard
  from the LIVE DB, own snapshot), `[>] swap into the LIVE DB` (destructive, requires
  typing `confirm` — the copy is checked for staleness first), a `view`/`remove` toggle
  (remove mode adds `[delete ALL]` / `[delete old (keep newest)]` and one row per
  produced copy). Creating a copy asks, in order: **(1) sessions** — one row per ROOT
  session with a `(N sub)` badge, `[x]` = survive (default all marked; bulk `ALL` /
  `NONE` / last-N / oldest-N / last-N-days; `make` continues), sorted **newest used
  first** with a row to flip to oldest first (re-sorting keeps your marks),
  **(2) the recipe** — `lean` (strip reasoning) or `quiet` (prune + vacuum), and nothing
  else: picking one goes straight to **(3) the plan** — the exact read-only counts
  (kept roots+subagents, discarded cascade, rows per table, reasoning, current size)
  before the y/N gate; discarding offers `export memory --sessions <ids>` first, and
  declining goes back to the recipes.
- **export** picker (preset-only) — one row per named plan in the presets file (bundle plans
  render `[transcript+memory]`), then a session or `ALL SESSIONS`. Without a presets file it
  prints the setup guidance (`cp presets.json.example …`) and the raw CLI as fallback — there
  is no manual session→product picker anymore.
- **Manage exports** picker (mode `view` / `remove`) — rows: toggle,
  `[delete ALL export runs]`, `[delete all except the newest]`, one row per run
  (date/profiles/roots/messages/size). `view` shows the run, `remove` deletes it.

Export flow: plan → session (**or ALL**) → confirmation (`Will produce:` block per product,
with the effective flags) → run. A picked session becomes `export <name> --filter <ses>`
(CLI wins over any embedded preset selection; a bundle shares the override); `ALL` runs the
plan as configured. **No** variant tables or custom checklists in the menu — tuning and
multi-product runs in one stamp (bundle presets) live in the presets file (`OCED_PRESETS`)
or on the CLI (`--no-reasoning`, `--json`, `--sanitize`, `--tool-output full`, …).

## Export

Products: `transcript` (the conversation, markdown) · `memory` (RAG corpus,
`corpus.jsonl`) · `compactions` (the compacted-context digests). `full` is accepted as
an alias of `transcript`.

```bash
opencode-db export memory                  # full text, no truncation (default)
opencode-db export memory --files          # also list the touched files per session
opencode-db export memory --cap 2000       # cap EVERY text value to N chars (0 = unlimited)
```

The full flag list (name/choices/default per product) is generated from the single
source of truth — `modules/exportlib/flags.py` — shown by `opencode-db export --help`
(`opencode-db help` prints the product/flags summary) and tabulated in
[`generated/flags-table.md`](generated/flags-table.md). The purpose/size of every product and the
decision matrix live in [docs/export-guide.md](docs/export-guide.md).

> `transcript` is **one** export, not one per option: whether tool output is truncated depends on `--tool-output` (default `truncated`). In the `menu` every product runs with its default options (tune via the presets file or the CLI).

**Token backfill** — sessions with `0`/NULL token/cost columns are reconstructed from the
per-step `step-finish` parts at export time (flagged `tokens_backfilled`). The mechanism
is described in [docs/architecture.md](docs/architecture.md).

`memory` is a RAG-ready corpus, **not** a readable transcript: one `corpus.jsonl` entry per
root session, subagents summarized inline, `first_user` (the goal), `last_assistant` (the
outcome) and all `compaction_digests[]`. Keys are documented in each run's `index.md`.

No text is ever truncated by default; `--cap N` caps every text value (first_user, last_assistant, digests) to N chars — a guard only you choose to raise if feeding the corpus to a strict model.

Each run writes `exports/<timestamp>/<profile>/` with one Markdown file per session, an `index.md`, and a machine-readable `metadata.json`.

## Named export presets

Running the export by raw flags is fine for one-offs, but the recurring combinations
are better pinned in a **presets file** (JSON, path in `OCED_PRESETS`, default
`~/.config/opencode-db/presets.json`, same env>conf precedence as the rest; `install.sh`
auto-creates it from `presets.json.example` when missing). The file is the **source of
truth** for both the CLI and the menu: a preset names a product (or a *bundle* of
products run under one stamp), its config flags and optionally the selection (`filter`
or exact `sessions`). The contract (exact keys/types/choices) is machine-checkable in
[`generated/presets.schema.json`](generated/presets.schema.json) and fully documented in
[`docs/schemas.md`](docs/schemas.md) (which also covers `metadata.json`, the memory
`corpus.jsonl`, the faithful JSON archive, the backup `manifest.json`, `shrink.json`
and the `exports list` line).

```json
{
  "presets": {
    "archive": {
      "products": {
        "transcript": { "json": true, "tool_output": "full" },
        "memory": { "files": true }
      }
    },
    "quick": {
      "products": {
        "transcript": { "json": true, "tool_output": "truncated" },
        "memory": { "files": true }
      }
    },
    "share": {
      "product": "transcript",
      "json": true,
      "sanitize": true,
      "no_reasoning": true
    },
    "notes": { "product": "transcript" },
    "rag":   { "product": "memory" },
    "digest": { "product": "compactions" }
  }
}
```

```bash
opencode-db export share                 # run the named preset (product + config + its own selection)
opencode-db export share --filter '%'    # a concrete CLI flag overrides the preset
opencode-db export rag --cap 3000        # same, per-run
opencode-db export transcript --json     # product keywords always mean the product (raw flags unchanged)
opencode-db export archive               # bundle: transcript + memory under ONE stamp
opencode-db export archive --sessions ses_abc   # one CLI flag overrides the whole selection
```

- `export <name>` resolves to a preset; `export transcript|memory|compactions|full` always
  mean the product. An unknown name fails listing the known presets.
- Allowed preset keys: `product` + `sub`, `tool_output`, `tool_input_limit`,
  `tool_output_limit`, `patch`, `role`, `no_reasoning`, `mark_compactions`,
  `summary_diffs`, `json`, `sanitize`, `cap`, `files` (bools/choices as in the flags),
  `snapshot` = `"fresh"` (**single preset only**) and the selection `filter` (LIKE
  string) **or** `sessions` (list of ids, not both).
- A **bundle preset** uses `products` instead of `product`: a map of
  `{product: {flags}}` (products may only be `transcript|memory|compactions` and each
  keeps its own flags, e.g. `cap`/`files` only matter for `memory`). The selection stays
  at the top level and is shared by every product; the whole bundle runs under **one
  stamp** (`exports/<stamp>/transcript`, `exports/<stamp>/memory`, plus an
  `index.md` at the stamp root) and each subfolder is identical to running that product
  alone. `product` and `products` are mutually exclusive.
- A `filter`/`sessions`/`--sessions` passed on the command line overrides the preset's
  selection; a config flag passed on the command line overrides the preset too (both for
  single and bundle presets).
- **`snapshot: fresh`** coordinates the export with the reference backup: when this key is
  set the CLI warns if no backup exists or the last one diverged from the live DB (run
  `opencode-db backup` to align it), and the menu offers a fresh backup first. The export
  itself still reads the live DB read-only; this only keeps the *archive* reproducible.
- No presets file (or none matching) → no presets: export behaves exactly as before.
The **menu** has no product-only flow: each preset is a first-class action (read from the same
  file), and it asks **which session or ALL SESSIONS** to export (pending state: a plan is config
  + selection, and the two are separated at run time — a plan runs **ad-hoc** just like raw flags
  do). Choosing **ALL** runs the preset as configured (keeping its embedded selection); picking
  **one session** becomes a `--filter` override shared by every product of a bundle (CLI
  wins, see above). **No `Manual…` row** (the shipped default plans `notes`/`rag`/`digest` cover
  the three products with defaults); without a presets file the export picker prints setup
  guidance (`cp presets.json.example …`) and the raw CLI as fallback — the manual session →
  product flow is gone from the menu.
- `compactions` is a valid product (CLI or a plan) but is **not** part of the shipped example
  plans: its digests are already inline in `transcript` and in the memory corpus
  (`compaction_digests`), so shipping it in a bundle would triple the same text.
- `--sanitize` redacts high-confidence secret prefixes (sk-, ghp_, Bearer, JWT, PEM…) —
  **best-effort; review the output before sharing**.

```bash
# weekly lossless export of everything, e.g. in crontab:
0 2 * * 1 opencode-db export archive
```

Each run's `metadata.json` records `"preset": "<name>"` (and `sessions_selected`) for
provenance (a bundle records the preset name in every product's metadata).

## Managing export runs

Export folders accumulate; list, delete or prune them with `opencode-db exports` (also in the menu):

```bash
opencode-db exports list              # date / profile / counts / size per run (multi-profile runs show 'full+compactions', counts are totals)
opencode-db exports remove <stamp>    # delete one run (asks; --yes to skip)
opencode-db exports prune 5           # keep only the 5 most recent runs
```

## Compaction digests

`compactions <id> show` prints a session's digests; the `compactions` export product
writes one markdown file per session with them. How a compaction digest is stored in the
DB (markers vs. the following `mode=compaction` message) is explained in
[docs/architecture.md](docs/architecture.md).

## shrink — a lighter DB copy to swap over opencode

The opencode DB only grows, and most of the weight is the event store (`event` alone is ~375 MB of a typical 490 MB file): deleting sessions frees pages for reuse but does **not** shrink the file (only a `VACUUM` does, and it needs exclusive locks on the live DB). `opencode-db shrink` builds a pruned + VACUUMed **copy** from a snapshot and never writes to the live database — you swap the copy in manually:

```bash
opencode-db shrink                         # default: copy with the 10 most recent sessions
opencode-db shrink lean                    # + strip the reasoning parts (recommended)
opencode-db shrink quiet                   # prune + vacuum only, keep the full text
opencode-db shrink --keep 5 --dry-run      # only report what would be pruned
opencode-db shrink --keep-all              # keep every session (just prune orphans + vacuum)
opencode-db shrink --older-than 30         # keep sessions updated in the last 30 days
opencode-db shrink --since 2026-01-15      # keep sessions updated since date (UTC)
opencode-db shrink --keep-sessions ses_aaaaaa     # keep ONLY the listed ids + their parents/subagents
opencode-db shrink --discard-sessions ses_bbbbbb  # keep everything EXCEPT the ids + their subagents
                                               # (hints to export memory --sessions <ids> first)
opencode-db shrink lean --keep 30          # raw flags compose over a recipe (30 most recent, still strips)
opencode-db shrink lean --swap             # build the copy AND replace the live DB (safe: --yes to skip the prompt)
```

A shrink has two independent parts, and they are split on purpose:

- **Which sessions survive** = a **selection flag** (exactly one: `--keep N` = default
  10, `--older-than DAYS`, `--since DATE`, `--keep-all`, `--keep-sessions`, `--discard-sessions`).
- **What else happens to the copy** = the **operations**, and that is all a named recipe
  may carry: `lean` = strip the reasoning parts, `quiet` = nothing (prune + vacuum only).

So `shrink lean` means "the default selection, plus strip reasoning", and
`shrink lean --keep 30` keeps 30 and still strips. A keep rule inside a recipe is
rejected (it points at the flag to use instead). The built-ins always exist; a **shrink
recipes file** (`OCED_SHRINK_PRESETS`, default `~/.config/opencode-db/shrink-presets.json`,
auto-created from `shrink-presets.json.example`) extends/overrides them with operations
only — see [`generated/shrink.schema.json`](generated/shrink.schema.json) and
`shrink --list-presets`. `--keep-sessions`/`--discard-sessions` are exact-id selections
(comma-separated). `shrink --help` lists everything.

The kept set is **closed**: parents and subagents of a kept session are kept too (no orphan links), and the sessions-bound tables (message, part, todo, session_message, session_share, session_context_epoch, session_input) plus the `event`/`event_sequence` aggregates of the deleted sessions are pruned — orphans are never shipped. Output is written to `backups/shrink/<timestamp>/opencode.shrunk.db` + `shrink.json` (profile/criteria, counts, per-table removed rows, sizes, `integrity_check` and `foreign_key_check`). The copy is verified (`PRAGMA integrity_check` = ok, `PRAGMA foreign_key_check` = 0 rows) before being stored. If the swap is fine, replace the DB yourself:

```bash
mkdir -p "$OCED_BACKUP_DIR/pre-shrink"
cp "$OPENCODE_DB" "$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink$(date +%s).db"   # safety copy
cp <shrunk.db> "$OPENCODE_DB"
rm -f "$OPENCODE_DB-wal" "$OPENCODE_DB-shm"
```

> **Stop opencode before swapping.** Replacing the DB behind a running opencode process
> drops the WAL tail and can corrupt state. Prefer `opencode-db shrink --swap`, which
> aborts if opencode is still running, snapshots a safety copy to
> `$OCED_BACKUP_DIR/pre-shrink/` (sqlite `.backup`, WAL-safe), swaps atomically and
> rolls back if the new DB does not open read-only (see
> [docs/architecture.md](docs/architecture.md) §6).

Workflow that preserves knowledge while reclaiming space: `opencode-db backup` → `opencode-db export memory` (keeps the distilled facts) → `opencode-db shrink`. `status` warns with a checklist when the live DB is over 1 GiB. Prefer the guided version: `opencode-db guide` walks the same steps with explanations.

Produced copies accumulate under `backups/shrink/`; manage them like export runs:

```bash
opencode-db shrinks list              # date / criteria / kept-deleted / sizes per copy
opencode-db shrinks list --tsv        # same, as stamp<TAB>display (the menu picker's source)
opencode-db shrinks view <stamp>      # show a copy's shrink.json
opencode-db shrinks verify [--yes]    # audit: orphan dirs, old pre-shrinks, stale copy vs live DB
opencode-db shrinks remove <stamp>    # delete one copy (asks; --yes to skip)
opencode-db shrinks prune 3           # keep only the 3 most recent copies
```

`--strip-reasoning` additionally removes the `reasoning` parts on the copy (the weighty chain-of-thought, rarely useful once a session is over). Community tooling reports ~77% extra savings — the combined copy (`delete sessions → strip reasoning → VACUUM`) is the smallest file we can hand you. Reasoning is a *part* stored per message; the exported transcript reads it from the original DB (toggle `--no-reasoning`), so stripping never touches what you can re-export. Stripped reasoning is only **recoverable while you keep the original DB or a backup**: keep `opencode-db backup` and the `pre-shrink` safety copy if you ever need it. If you use opencode between a `shrink` and the swap, the copy is stale — **shrink again before swapping** (the pre-shrink copy is your only rollback).

## Activity log (opt-in)

`OCED_LOG=1` appends mutations (backup created, exports/prune, shrink) to `OCED_ACTIVITY_LOG` (default `~/.local/state/opencode-db/activity.log`), one tab-separated line per event. Nothing is ever logged by default.

## Reading from a backup

The global flag `--from-backup` (before the subcommand) points every read command at a stored backup instead of the live DB. It accepts a filename under `OCED_BACKUP_DIR` or an absolute path, and transparently decompresses `.gz` backups to a temp file. The live DB is never touched.

```bash
opencode-db --from-backup opencode-20260920-155652.db.gz status
opencode-db --from-backup opencode-20260920-155652.db.gz list --root
opencode-db --from-backup opencode-20260920-155652.db.gz export memory
```

`status`/`version` report whether the backup is `[OK] aligned` with the live DB or `[!] out of sync` (same sessions/messages/last activity), so you know how stale the source is.

## Uninstall

```bash
./uninstall.sh          # removes the installed code + shim; keeps config/backups/exports
./uninstall.sh --all    # also removes config, backups and exports
```

It never removes system packages: dependencies installed by `opencode-db deps` stay on the system.

## Design notes

The detailed architecture — read-only discipline (WAL, `.backup`, `--from-backup`),
the opencode data model, the export pipeline (products, sanitization **in memory on
native types before serializing**, token backfill, streaming corpus), the menu design and
the `shrink --swap` safeguards — lives in **[docs/architecture.md](docs/architecture.md)**.
The [`docs/export-analysis.md`](docs/export-analysis.md) log records how the export
redesign decisions were reached. **[`docs/schemas.md`](docs/schemas.md)** is the
machine-facing contract reference (presets, `metadata.json`, the memory corpus, the
faithful archive, backup/shrink manifests). This README covers usage only.

A few facts that are good to know anyway:

- Config precedence is **environment > conf file > built-in default**: an explicitly
  exported `OPENCODE_DB`/`OCED_OUT`/`OCED_ACTIVITY_LOG`/... is never clobbered by the conf.
- Output dirs and the DB path are configurable via `~/.config/opencode-db/opencode-db.conf`
  (see `opencode-db.conf.example`).

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
| Portable (no install) | Yes | Run `bash modules/opencode-db.sh …` straight from the repo. No config is created; defaults are used. |

- **Portable run**: if `~/.config/opencode-db/opencode-db.conf` does *not* exist it is never created, so nothing on your config is touched; exports/backups still go to `~/.local/share/opencode-db-exporter/{exports,backups}` by default (override with `OCED_OUT`/`OCED_BACKUP_DIR`). If the conf *does* exist it is only read (and `chmod 600`).
- **Removing data**: `uninstall.sh --all` deletes the config, backups and exports even if you only ever ran it portably.

### Portable configuration

In portable mode you do not need `install.sh`, but you can still keep your settings in any file: copy `opencode-db.conf.example` next to the repo and point `OCED_CONF` at it (no auto-discovery; nothing is created for you):

```bash
cp opencode-db.conf.example ./portable.conf
OCED_CONF=./portable.conf bash modules/opencode-db.sh status
```

Environment variables still win over that file, which in turn wins over the built-in default: **environment > conf > default**.

## Tests

```bash
bash tests/export_smoke.sh   # end-to-end against a fake DB -> 175 OK / 0 FAIL
bash tests/menu_flow.sh      # fzf menu logic (fzf stubbed) -> 102 OK / 0 FAIL
```

## Layout

```
modules/
  opencode-db.sh   CLI dispatcher
  common.sh        config + helpers (always read-only)
  view.sh          status / list / info / compactions (+ digests)
  backup.sh        consistent snapshots + sha256 + manifest.json
  export.sh        bash -> python bridge
  exportlib/       Python renderer package (products transcript/memory/compactions,
                   subagents, presets, --json/--sanitize, index.md, metadata;
                   cli.py is the self-bootstrapping CLI entry)
  exports.sh       list/remove/prune of past export runs
  shrink.sh        pruned + VACUUMed copy from a snapshot (dry-run / report / --swap)
                   + the shrinks manager (list/view/remove/prune of produced copies)
  deps.sh          idempotent dependency check/install
  guide.sh         step-by-step console wizard (safe workflow)
  menu.sh          interactive fzf menu (pickers, preset-only export flow, shrinks picker)
docs/
  architecture.md  design & rationale (read-only model, schema, export pipeline, menu, shrink safeguards)
  export-analysis.md  decision log of the export redesign
install.sh         copies modules+tests, symlinks the CLI
uninstall.sh       removes the install (keeps data unless --all)
tests/
  make_fake_db.sh  generates a fake DB for the tests
  export_smoke.sh  end-to-end assertions
  menu_flow.sh     menu logic with a stubbed fzf
```