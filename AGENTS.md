# AGENTS.md — opencode-db-exporter

Bash+python tool to read, back up and export the local opencode SQLite database. Never write to
the opencode DB: all access uses `mode=ro` (bash: `file:$DB?mode=ro`; python: `sqlite3.connect(f"file:{db}?mode=ro", uri=True)`).

## Commands that MUST be run after editing code

```bash
# Shell syntax (every script has #!/usr/bin/env bash)
for f in modules/*.sh install.sh uninstall.sh tests/*.sh; do bash -n "$f"; done

# Python
python3 -m py_compile modules/export.py

# Smoke tests against a fake DB (never touches real data)
bash tests/export_smoke.sh        # must give: 43 OK / 0 FAIL
bash tests/menu_flow.sh           # fzf menu logic (fzf stubbed) -> 10 OK / 0 FAIL
```

## Structure

- `modules/opencode-db.sh` — CLI dispatcher: `status | list | info | compactions | backup | backups | export | exports | deps | menu | help`. Sources common.sh + view.sh + backup.sh + export.sh + exports.sh + deps.sh; menu.sh is sourced on demand.
- `modules/common.sh` — config (`OPENCODE_DB`, `OCED_OUT`, `OCED_BACKUP_DIR`, `OCED_CONF`) and helpers `o_q`, `o_die`, `o_ts`, `o_now_utc`, `o_check_deps`. `o_q` is ALWAYS readonly: `sqlite3 "$(o_db_uri)"`.
- `modules/view.sh` — status/list/info/compactions (reads only); `compactions <id> show [last|N|all]` prints the compacted-context digest from the following `mode=compaction` message.
- `modules/backup.sh` — `sqlite3 "$DB" ".backup <snap>"` (WAL-safe), optional gzip, sha256, atomic `manifest.json` (jq), `backups list/verify/prune`.
- `modules/export.sh` + `modules/export.py` — profiles `full|no-calls|text-only|compactions` (+ meta-profile `all`: the four, maximal flags, one run via `--stamp`); `--filter`, `--sub separate|inline|omit`, `--tool-output full|truncated|omit`, `--patch full|omit`, `--mark-compactions`, `--summary-diffs`; writes `index.md` + `metadatos.json` per run.
- `modules/exports.sh` — `exports list|remove <stamp>|prune <N>` over `OCED_OUT` run dirs; `list` aggregates every `metadatos.json` under a stamp (profiles joined with `+`, roots/subagents = max, msgs/comp = sum).
- `modules/deps.sh` — `oced_deps [--check]`: idempotent apt-based install of sqlite3/python3/jq/gzip (+fzf for the menu); `--check` never uses sudo.
- `modules/menu.sh` — fzf menu (`run_menu`/`choose_action`); export flow is 2 screens: recipes (multi-select; each becomes its own run) -> session (or all). ESC always cancels.
- `tests/make_fake_db.sh` — fake DB (6 sessions, orphan/nested subagents, compaction marker + digest message, long tool outputs, summary:true edge case).
- `tests/export_smoke.sh` — end-to-end assertions (43).
- `tests/menu_flow.sh` — menu logic with a stubbed fzf (separator rows, ESC, recipes, ALL loops).

## Schema rules (opencode.db)

- `session`: `parent_id` (subagent when non-empty), `agent` (build/explore/plan), `model`, `directory`, `time_compacting`, `tokens_*`, `cost`, `share_url`.
- `part.data.type` ∈ `text | file | step-start | reasoning | tool | step-finish | patch | compaction`.
- Tool call: `part.data` → `state.input.command` (tool), `state.input.arguments`, `state.output` (truncatable).
- `message.data.summary.diffs` — per-message change summary (`--summary-diffs`); `summary` can be `true` (bool), not only an object.
- Compactions: parts `type='compaction'` are only markers (`auto`, `overflow`, `tail_start_id`); the compacted-context **digest** is the `text` part of the next message with `data.mode='compaction'`.
- Session pickers must ignore the sqlite `-column` separator line (rows are filtered by `$1 ~ /^ses_/`).
- Config precedence is **environment > conf file > default** (`common.sh` snapshots env vars before sourcing `$OCED_CONF`). Keep it that way: never let the conf clobber an explicitly exported variable.

## Known pitfalls

- **SIGPIPE/pipefail**: never use `cmd | grep -q PATTERN` in tests or modules when `cmd` is a long-running subprocess; grep closes the pipe on match and the producer dies with 141. Capture first: `out=$(cmd); printf '%s' "$out" | grep -q PATTERN`.
- `model` may already be serialized as JSON (don't double-encode).
- Newlines inside JSON after `json_each`/diagonals are escaped before `data:json_each`; use `json_quote` for raw dumps.
- `set -euo pipefail` in bash: pipelines with `grep -q` may return 141 (see above).
- Local `trap` EXIT inside functions: `trap - EXIT` before `return` so the caller's trap isn't cancelled.
- Paths and file names: `safe_filename` strips `@()[]` etc.

## Deploy

- `install.sh` — copies modules+tests (+`uninstall.sh`) to `~/.local/share/opencode-db-exporter`, symlinks `~/.local/bin/opencode-db` → `modules/opencode-db.sh`, creates conf from `opencode-db.conf.example` if missing (permissions 600).
- `uninstall.sh [--all] [--yes]` — removes the installed code + shim; keeps conf/backups/exports unless `--all`.
- Config: `~/.config/opencode-db/opencode-db.conf` (600). Dependencies are self-managed via `opencode-db deps`.