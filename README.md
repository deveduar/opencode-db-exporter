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
opencode-db info <session_id>         # tokens, cost, compactions, counts
opencode-db compactions <session_id> [show [last|N|all]]
                                      # compaction points; 'show' prints the digest
opencode-db backup [--no-compress]    # consistent snapshot (.backup), gzip + sha256 + manifest
opencode-db backups [list|verify <file>|prune <N>]
opencode-db export <product> [FLAGS]  # products: transcript | memory | compactions
opencode-db exports [list|remove <stamp> [--yes]|prune <N> [--yes]]
opencode-db shrink [--keep N|--older-than DAYS] [--dry-run] [--swap]
                                      # pruned + VACUUMed COPY (never touches the live DB
                                      # unless --swap replaces it safely)
opencode-db guide [--list]            # step-by-step console wizard (safe workflow)
opencode-db deps [--check]            # idempotent dependency check/install (apt|pacman|dnf)
opencode-db help
```

## Menu (opencode-db menu)

The interactive menu is **picker-driven**: the main pickers are real fzf lists, not nested
menus. There is **no TAB multi-select** — mode switching and bulk operations are their own
rows. The `backups`, `sessions` (details) and `export` pickers are **single-mode**.

- **status** — the full report (DB, backups alignment, version/schema, dependencies) + pause.
- **backups** picker (single mode) — rows: `[create backup]`, `[shrink…]` (from the LIVE
  DB, own snapshot), `[delete ALL backups]`, `[delete olds (keep newest)]` and one row
  per backup (date/size/sessions/msgs/sha). Selecting a row removes it with confirmation.
  Verify stays in the CLI (`backups verify <file>`), for after-copy or before `--from-backup`
  checks.
- **sessions** picker (details only) — one row per session; selecting one shows the full
  info + compaction digests.
- **export** picker — `ALL SESSIONS` or a single session, then the product
  (`transcript`/`memory`/`compactions`).
- **Manage exports** picker (mode `view` / `remove`) — rows: toggle,
  `[delete ALL export runs]`, `[delete all except the newest]`, one row per run
  (date/profiles/roots/messages/size). `view` shows the run, `remove` deletes it.

Export flow: session (**or ALL**) → **product** (`transcript`/`memory`/`compactions`)
→ plan confirmation → run. Each product runs with its **default options**; there are
**no** variant tables or custom checklists in the menu — tuning and multi-product runs
in one stamp (bundle presets) live in the presets file (`OCED_PRESETS`) or on the CLI
(`--no-reasoning`, `--json`, `--sanitize`, `--tool-output full`, …). `shrink` lives
inside the backups picker: recipes built from the live DB (default, dry-run, custom
keep-N / last-N-days / since date).

## Export

Products:

| Product       | Content                                             |
|---------------|-----------------------------------------------------|
| `transcript`  | the conversation in markdown: text + reasoning + tool calls (truncated by default) + patches. `full` is accepted as an alias |
| `compactions` | only the compacted-context digests (`mode=compaction` messages) |
| `memory`      | RAG/memory corpus: one JSON per **root** session (metadata + first/last user/assistant text + **all** compaction digests) in `corpus.jsonl` |

Flags:

- `--filter PATTERN` — SQL `LIKE` on session id/title (e.g. `'ses_f7%'`); useful to export one session or one project.
- `--sessions ID[,ID…]` — export exact session id(s) (repeatable) instead of a pattern; e.g. `--sessions ses_abc,ses_xyz`.
- `--sub separate|inline|omit` — how to place subagents (default `separate`: folder per root session with `subagents/` inside).
- `--tool-output full|truncated|omit` — tool output verbosity (default `truncated`).
- `--patch full|omit` — include patch parts (default `full`).
- `--mark-compactions` — annotate where context compaction happened (transcripts only).
- `--no-reasoning` — omit the reasoning parts (transcripts only).
- `--summary-diffs` — include opencode's `summary.diffs` (files + additions/deletions) per message.
- `--role all|user|assistant` — render only one role's messages (default `all`; `user` = prompts only, `assistant` = answers only). Applied by `transcript`/`compactions`; `memory` ignores it.
- `--json` — also write a **faithful JSON archive** per session (native `{info, messages:[{info, parts}]}` shape), next to each markdown file.
- `--sanitize` — redact secret-looking values (API keys `sk-`/`ghp_`/`github_pat_`/`xox…`/`AIza…`/`AKIA…`, Bearer tokens, JWTs, private PEM keys, `key=value` pairs) recursively, in markdown, JSON and the memory corpus.
- `--cap N` / `--files` — `memory` tuning: truncate every text value to N chars (`0` = unlimited, default) and/or list the touched files per session.

> `transcript` is **one** export, not one per option: whether tool output is truncated depends on `--tool-output` (default `truncated`). In the `menu` every product runs with its default options (tune via the presets file or the CLI).

**Token backfill** — sessions with `0`/NULL token/cost columns are reconstructed from the
per-step `step-finish` parts at export time (flagged `tokens_backfilled`). The mechanism
is described in [docs/architecture.md](docs/architecture.md).

`memory` is a RAG-ready corpus, **not** a readable transcript: one `corpus.jsonl` entry per
root session, subagents summarized inline, `first_user` (the goal), `last_assistant` (the
outcome) and all `compaction_digests[]`. Keys are documented in each run's `index.md`.

```bash
opencode-db export memory                  # full text, no truncation (default)
opencode-db export memory --files          # also list the touched files per session
opencode-db export memory --cap 2000       # cap EVERY text value to N chars (0 = unlimited)
```

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
[`presets.schema.json`](presets.schema.json) and fully documented in
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
  `summary_diffs`, `json`, `sanitize`, `cap`, `files` (bools/choices as in the flags) and
  the selection `filter` (LIKE string) **or** `sessions` (list of ids, not both).
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
- No presets file (or none matching) → no presets: export behaves exactly as before.
- The menu lists each preset as a first-class action (read from the same file), then asks
  **which session or ALL SESSIONS** to export (pending state: a plan is config + selection,
  and the two are separated at run time — a plan runs **ad-hoc** just like raw flags do).
  Choosing **ALL** runs the preset as configured (keeping its embedded selection); picking
  **one session** becomes a `--filter` override shared by every product of a bundle (CLI
  wins, see above). **No `Manual…` row** when presets exist (the shipped default plans
  `notes`/`rag`/`digest` cover the three products with defaults). Without a file, the
  classic session → product flow with defaults remains.
- `compactions` is a valid product (CLI or a plan) but is **not** part of the shipped example
  plans: its digests are already inline in `transcript` and in the memory corpus
  (`compaction_digests`), so shipping it in a bundle would triple the same text.
- `--sanitize` redacts known secret patterns (sk-, ghp_, Bearer, JWT, PEM, key=value…) —
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
opencode-db shrink lean                    # keep 10 most recent + strip reasoning (recommended)
opencode-db shrink recent                  # keep sessions updated in the last 90 days
opencode-db shrink full                    # keep ALL sessions, strip reasoning + vacuum
opencode-db shrink bare                    # keep 10 most recent, physically shrink only
opencode-db shrink --keep 5 --dry-run      # only report what would be pruned
opencode-db shrink --since 2026-01-15      # keep sessions updated since date (UTC)
opencode-db shrink lean --swap             # build the copy AND replace the live DB (safe: --yes to skip the prompt)
```

The named recipes are presets, like the export recipes: `lean` = `--keep 10 --strip-reasoning`, `recent` = `--older-than 90`, `full` = keep everything + strip reasoning (pure space reclamation), `bare` = `--keep 10` without stripping. Raw flags compose over a recipe (`shrink lean --keep 30` keeps 30 and still strips reasoning). `shrink --help` lists them.

The kept set is **closed**: parents and subagents of a kept session are kept too (no orphan links), and the sessions-bound tables (message, part, todo, session_message, session_share, session_context_epoch, session_input) plus the `event`/`event_sequence` aggregates of the deleted sessions are pruned — orphans are never shipped. Output is written to `backups/shrink/<timestamp>/opencode.shrunk.db` + `shrink.json` (profile/criteria, counts, per-table removed rows, sizes, `integrity_check` and `foreign_key_check`). The copy is verified (`PRAGMA integrity_check` = ok, `PRAGMA foreign_key_check` = 0 rows) before being stored. If the swap is fine, replace the DB yourself:

```bash
cp "$OPENCODE_DB" "$OPENCODE_DB.pre-shrink$(date +%s)"   # safety copy
cp <shrunk.db> "$OPENCODE_DB"
rm -f "$OPENCODE_DB-wal" "$OPENCODE_DB-shm"
```

> **Stop opencode before swapping.** Replacing the DB behind a running opencode process
> drops the WAL tail and can corrupt state. Prefer `opencode-db shrink --swap`, which
> aborts if opencode is still running, snapshots a `.pre-shrink` safety copy (sqlite
> `.backup`, WAL-safe), swaps atomically and rolls back if the new DB does not open
> read-only (see [docs/architecture.md](docs/architecture.md) §6).

Workflow that preserves knowledge while reclaiming space: `opencode-db backup` → `opencode-db export memory` (keeps the distilled facts) → `opencode-db shrink`. `status` warns with a checklist when the live DB is over 1 GiB. Prefer the guided version: `opencode-db guide` walks the same steps with explanations.

`--strip-reasoning` additionally removes the `reasoning` parts on the copy (the weighty chain-of-thought, rarely useful once a session is over). Community tooling reports ~77% extra savings — the combined copy (`delete sessions → strip reasoning → VACUUM`) is the smallest file we can hand you. Reasoning is a *part* stored per message; the exported transcript reads it from the original DB (toggle `--no-reasoning`), so stripping never touches what you can re-export. Stripped reasoning is only **recoverable while you keep the original DB or a backup**: keep `opencode-db backup` and the `.pre-shrink` safety copy if you ever need it.

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
bash tests/export_smoke.sh   # end-to-end against a fake DB -> 134 OK / 0 FAIL
bash tests/menu_flow.sh      # fzf menu logic (fzf stubbed) -> 83 OK / 0 FAIL
```

## Layout

```
modules/
  opencode-db.sh   CLI dispatcher
  common.sh        config + helpers (always read-only)
  view.sh          status / list / info / compactions (+ digests)
  backup.sh        consistent snapshots + sha256 + manifest.json
  export.sh        bash -> python bridge
  export.py        entry shim for the exportlib package
  exportlib/       Python renderer package (products transcript/memory/compactions,
                   subagents, presets, --json/--sanitize, index.md, metadata)
  exports.sh       list/remove/prune of past export runs
  shrink.sh        pruned + VACUUMed copy from a snapshot (dry-run / report / --swap)
  deps.sh          idempotent dependency check/install
  guide.sh         step-by-step console wizard (safe workflow)
  menu.sh          interactive fzf menu (pickers + export flow)
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