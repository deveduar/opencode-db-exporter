# opencode-db-exporter

Read, back up and export the local SQLite database of **opencode** (`opencode` CLI) to readable Markdown. It never writes to the opencode database: every access is read-only (`mode=ro`).

Intended for Linux with the **opencode CLI**. The database it reads is the shared store written by opencode at `~/.local/share/opencode/opencode.db`. If your opencode stores the DB elsewhere (other OS, custom `XDG_DATA_HOME`, or the desktop app using its own storage), set `OPENCODE_DB` to point at it.

## Requirements

- Linux (tested on Debian/Ubuntu) and the opencode CLI
- `sqlite3`, `python3` (**>= 3.10**, uses `str | None` annotations), `jq`, `gzip` (core)
- `fzf` (only for `opencode-db menu`)

The tool can install its own missing dependencies idempotently:

```bash
opencode-db deps --check   # report only (no sudo)
opencode-db deps           # install what's missing (apt, prompts for sudo)
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
opencode-db status                    # DB state + alignment with the last backup
opencode-db list [--root|--sub] [--filter PATTERN] [--info]
opencode-db info <session_id>         # tokens, cost, compactions, counts
opencode-db compactions <session_id> [show [last|N|all]]
                                      # compaction points; 'show' prints the digest
opencode-db backup [--no-compress]    # consistent snapshot (.backup), gzip + sha256 + manifest
opencode-db backups [list|verify <file>|prune <N>]
opencode-db export <profile> [FLAGS]  # profiles: full | no-calls | text-only | compactions | all
opencode-db exports [list|remove <stamp> [--yes]|prune <N> [--yes]]
opencode-db deps [--check]            # idempotent dependency check/install
opencode-db help
```

## Export

Profiles:

| Profile       | Content                                             |
|---------------|-----------------------------------------------------|
| `full`        | text + reasoning + tool calls (truncated by default) + patches |
| `no-calls`    | text + reasoning, no tool calls                     |
| `text-only`   | only user/assistant text                            |
| `compactions` | only the compacted-context digests (`mode=compaction` messages) |
| `all`         | meta-profile: the four above in **one run folder**, each with maximal capabilities |

Flags:

- `--filter PATTERN` — SQL `LIKE` on session id/title (e.g. `'ses_f7%'`); useful to export one session or one project.
- `--sub separate|inline|omit` — how to place subagents (default `separate`: folder per root session with `subagents/` inside).
- `--tool-output full|truncated|omit` — tool output verbosity (default `truncated`).
- `--patch full|omit` — include patch parts (default `full`).
- `--mark-compactions` — annotate where context compaction happened.
- `--summary-diffs` — include opencode's `summary.diffs` (files + additions/deletions) per message.

> `full` is **one** export, not one per option: whether tool output is truncated depends on `--tool-output` (default `truncated`). The `menu` exposes the same combinations as ready-made **recipes** (select several and each becomes its own run).

`export all` is the "everything" profile: it writes the four profiles into a single run folder, each with maximal capabilities (`--tool-output full --patch full --mark-compactions --summary-diffs --sub separate`). `export all --filter <ses>` scopes it to a session and overrides may be appended afterwards.

Each run writes `exports/<timestamp>/<profile>/` with one Markdown file per session, an `index.md`, and a machine-readable `metadatos.json`.

## Managing export runs

Export folders accumulate; list, delete or prune them with `opencode-db exports` (also in the menu):

```bash
opencode-db exports list              # date / profile / counts / size per run (multi-profile runs show 'full+compactions', counts are totals)
opencode-db exports remove <stamp>    # delete one run (asks; --yes to skip)
opencode-db exports prune 5           # keep only the 5 most recent runs
```

## Compaction digests

The `compaction` part is only a marker (`auto`, `overflow`, `tail_start_id`). The actual compacted-context summary is stored in the following `mode=compaction` assistant message. `compactions <id> show` prints it, and the `compactions` export profile writes one Markdown file per session with just those digests.

## Uninstall

```bash
./uninstall.sh          # removes the installed code + shim; keeps config/backups/exports
./uninstall.sh --all    # also removes config, backups and exports
```

It never removes system packages: dependencies installed by `opencode-db deps` stay on the system.

## Design notes

- The opencode DB uses **WAL mode** (`opencode.db-wal`). Backups use `sqlite3 .backup` (a consistent snapshot), never `cp`.
- All reads use SQLite `mode=ro` — opencode is never locked or modified.
- Every command (status/list/info/compactions/export) reads the **live** DB; backups are offline archives. If you restore an old backup elsewhere, point `OPENCODE_DB` at it. `metadatos.json` records `db` + `db_sha256` so an export can be correlated with a snapshot.
- **Subagents** are detected via `session.parent_id`; an orphan without a parent in the result set is exported as a root labeled `Subagent of: <parent>`.
- Output dirs and the DB path are configurable via `~/.config/opencode-db/opencode-db.conf` (see `opencode-db.conf.example`).
- Config precedence is **environment > conf file > built-in default**: an explicitly exported `OPENCODE_DB`/`OCED_OUT`/... is never clobbered by the conf.

## Portability (WSL / Windows / portable)

| Scenario | Works? | Notes |
|----------|--------|-------|
| Linux (Debian/Ubuntu) | Yes | `opencode-db deps` installs missing packages via `apt`. |
| WSL, opencode inside WSL | Yes | Defaults match; `deps` uses `apt`/`sudo`. |
| WSL, opencode is native Windows | Yes, with config | Set `OPENCODE_DB=/mnt/c/Users/<user>/.local/share/opencode/opencode.db`. Residual risk: SQLite WAL file locking over `drvfs`. |
| Native Windows | No | Bash-only (no `.bat`/`.ps1`); `sqlite3`, `python3`, `jq`, `gzip`, `fzf` are absent. Use WSL. |
| Git Bash / MSYS2 | Partial | Runs only if you install those tools yourself; `deps` refuses to install (no `apt`). |
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
bash tests/export_smoke.sh   # end-to-end against a fake DB -> 43 OK / 0 FAIL
bash tests/menu_flow.sh      # fzf menu logic (fzf stubbed) -> 10 OK / 0 FAIL
```

## Layout

```
modules/
  opencode-db.sh   CLI dispatcher
  common.sh        config + helpers (always read-only)
  view.sh          status / list / info / compactions (+ digests)
  backup.sh        consistent snapshots + sha256 + manifest.json
  export.sh        bash -> python bridge
  export.py        Markdown renderer (profiles, subagents, index.md, metadata)
  exports.sh       list/remove/prune of past export runs
  deps.sh          idempotent dependency check/install
  menu.sh          interactive fzf menu (recipes)
install.sh         copies modules+tests, symlinks the CLI
uninstall.sh       removes the install (keeps data unless --all)
tests/
  make_fake_db.sh  generates a fake DB for the tests
  export_smoke.sh  end-to-end assertions
  menu_flow.sh     menu logic with a stubbed fzf
```