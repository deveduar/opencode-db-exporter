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
bash tests/export_smoke.sh        # must give: 119 OK / 0 FAIL
bash tests/menu_flow.sh           # fzf menu logic (fzf stubbed) -> 78 OK / 0 FAIL
```

## Structure

- `modules/opencode-db.sh` — CLI dispatcher: `status | version | list | info | compactions | backup | backups | export | exports | shrink | deps | menu | help`. Accepts a global `--from-backup <file>` (before the subcommand) that sets `OCED_FROM_BACKUP` so every read command uses a stored backup as source. Sources common.sh + view.sh + backup.sh + export.sh + exports.sh + deps.sh; menu.sh is sourced on demand.
- `modules/common.sh` — config (`OPENCODE_DB`, `OCED_OUT`, `OCED_BACKUP_DIR`, `OCED_CONF`, `OCED_ACTIVITY_LOG`, `OCED_FROM_BACKUP`, `OCED_VERSION`) and helpers `o_q`, `o_die`, `o_ts`, `o_now_utc`, `o_check_deps`, `o_resolve_db`/`o_effective_db` (memoized: resolves live DB or backup, gunzips `.gz` to one temp file), `o_cleanup_tmp`, `o_backup_aligned`. `o_q` is ALWAYS readonly: `sqlite3 "$(o_db_uri)"`. `load_conf` snapshots env vars BEFORE sourcing `$OCED_CONF` (env > conf) for `OPENCODE_DB OCED_OUT OCED_BACKUP_DIR OCED_COMPRESS OCED_LOG OCED_ACTIVITY_LOG OCED_FROM_BACKUP`.
- `modules/view.sh` — status/version/list/info/compactions (reads only); helpers `o_version_block`/`o_schema_probe`/`o_deps_report`; `status` ends with "Version / schema:" + "Dependencies:" sections; `version` prints tool version (opencode-db) + opencode CLI version (max `session.version`) + schema probe (`OCED_EXPECTED_TABLES`/`OCED_EXPECTED_COLUMNS`), returning non-zero when tables/columns are missing; `compactions <id> show [last|N|all]` prints the compacted-context digest from the following `mode=compaction` message.
- `modules/backup.sh` — `sqlite3 "$DB" ".backup <snap>"` (WAL-safe), optional gzip, sha256, atomic `manifest.json` (jq), `backups list/verify/prune`.
- `modules/export.sh` + `modules/export.py` — products `transcript|memory|compactions` (`full` accepted as an alias of `transcript`); no `all` meta-profile, no `no-calls`/`text-only`; `--filter`, `--sub separate|inline|omit`, `--tool-output full|truncated|omit`, `--patch full|omit`, `--mark-compactions`, `--summary-diffs`, `--no-reasoning`, `--role all|user|assistant` (a flag, NOT a preset; `memory` ignores it, documented in its index); `--json` (faithful archive per session, native `{info, messages:[{info, parts}]}` shape, `info.tokens.backfilled`); `--sanitize` (recursive regex redaction **in memory, on native types, before serializing** — `sanitize_json` walks `dict`/`list`/`str`; markdown sanitizes each string at render time; never post-processes the final file: `sk-`/`ghp_`/`github_pat_`/`xox[baprs]-`/`AIza`/`AKIA`/JWT/Bearer/private PEM keys (multiline, `re.S`)/`key=value`); **token backfill** — sessions whose `tokens_*`/`cost` row is 0/NULL get their totals summed from `part` rows `data.type='step-finish'` (`tokens.input/output/reasoning/cache.{read,write}` + `cost`), in-memory, flagged `tokens_backfilled`; `memory` adds `--cap N` (0 = unlimited, default) + `--files` (touched files from tool inputs `path/filePath/file_path` and `+++ b/` patch headers) and writes `corpus.jsonl` **streamed line by line** (one root+subagents per line, `flush()` per root — never accumulates the corpus in RAM; prints a `--cap` hint past ~50 MB with unlimited text); help `digests_for`/`touched_files` — the SAME compaction source used by `view.sh` and the `compactions` product. Writes `index.md` + `metadatos.json` per run (`metadatos.json.role`, `.json`, `.sanitize`, `.reasoning`, `.tokens_backfilled`).
- `modules/exports.sh` — `exports list|remove <stamp>|prune <N>` over `OCED_OUT` run dirs; `list` aggregates every `metadatos.json` under a stamp (profiles/products joined with `+`, roots/subagents = max, msgs/comp = sum).
- `modules/deps.sh` — `oced_deps [--check]`: idempotent apt-based install of sqlite3/python3/jq/gzip (+fzf for the menu); `--check` never uses sudo.
- `modules/guide.sh` — `oced_guide [--list]`: console wizard (no fzf) for the safe workflow inspect -> backup -> export memory -> shrink -> swap manually; `--list` prints the plan and exits, non-TTY input is plan-only, each step asks `[y/N]` before running. Never writes the live DB.
- `modules/shrink.sh` — `oced_shrink`: recipes `lean|recent|full|bare` + `--keep N`/`--older-than DAYS`/`--since DATE`/`--strip-reasoning`/`--dry-run` over a copy (line 2: `set -uo pipefail`) — closed keep-set, prunes session-bound tables (message/part/todo/session_message/session_share/session_context_epoch/session_input) + `event`/`event_sequence` aggregates (`aggregate_id LIKE 'ses_%'`); optional strip-reasoning removes `part` rows whose `data` JSON has `type=reasoning`; then `integrity_check` (ok) + `foreign_key_check` (0 rows) BEFORE storing `opencode.shrunk.db`; `shrink.json` records criteria/counts/per-table `removed`/`stripped_reasoning`/integrity. `--swap [--yes]` (opt-in, incompatible with `--dry-run`) replaces the LIVE DB via `oced_shrink_swap`: aborts if a process cmdline mentions `opencode` (pgrep, excluding the tool itself), re-verifies the copy read-only, snapshots the live DB with `sqlite3 .backup` to `…pre-shrink-<ts>`, swaps with an atomic `mv`, drops the stale `-wal`/`-shm` and rolls back if the new DB fails `integrity_check`. `--swap` is the ONLY path that writes the live DB, and only on explicit request.
- `modules/menu.sh` — fzf menu (`run_menu`/`choose_action`/`oc_fzf_sel`); root: status/backups/sessions/**export**/exports/guide/help. Pickers: `oc_backups_picker` single-mode (`__CREATE__` → `__SHRINK__` → `__DELETE_ALL__` → `__KEEP_NEWEST__` → per-backup rows; selecting a row deletes it; `backups verify` stays CLI-only), `oc_sessions_picker` details-only (info+compactions), `oc_export_picker` (ALL or one session → wizard), `oc_exports_picker` with a mode toggle (`oc_toggle_row`, key `__TOGGLE__` view/remove) — **no TAB multi-select anywhere**, bulk ops are their own rows. Rows are TSV `key<TAB>display` (`--with-nth=2..`); single-row actions are per-file. Export wizard = session (**or ALL**) → `oc_pick_product` (**transcript|memory|compactions**, 3 rows) → `oc_recipes_for <product>` **variant** tables with non-repeating labels (product = the document to produce, variant = how it's configured, bundle = several products one run; transcript = 14 rows incl. `--json`, `--json --sanitize`, `--no-reasoning`, `__FULLMEM__` bundle = transcript+memory one shared stamp; compactions = 5 rows; memory = 3; **no** solo-prompts/answers presets — `--role` is only in the custom checklist; `__CUSTOM__` = `oc_custom_run` checklist `OC_CK_*` with cycles, transcript = tools/outfull/patches/markers/diffs/sub/role/reasoning/json/sanitize, compactions = sub/role/json/sanitize; `oc_memory_custom` = files/cap) → `oc_export_confirm` plan. `shrink` lives in the backups picker (LIVE DB, own snapshot, `--from-backup` does NOT affect it): `pick_shrink_profile`/`oc_pick_shrink_custom` recipes + dry-run via `oc_read_int`+`confirm_action`. ESC cancels/climbs one level.
- `tests/make_fake_db.sh` — fake DB (6 sessions, orphan/nested subagents, compaction marker + digest message, long tool outputs, summary:true edge case, step-finish with tokens/cost for the backfill, tool with a fake API key for `--sanitize`; also the empty real tables so the `version` schema probe passes).
- `tests/export_smoke.sh` — end-to-end assertions (119, incl. token backfill, faithful `--json`, `--sanitize`, memory corpus + caps, `--from-backup` temp hygiene, `shrink --swap`).
- `tests/menu_flow.sh` — menu logic with a stubbed fzf (separator rows, single-mode + mode-toggle pickers, bulk deletes, product→variant export flow, custom checklist, shrink).
- `docs/arquitectura.md` — design & rationale (read-only model, real opencode schema, export pipeline incl. sanitization **in memory before serializing**, streaming corpus, token backfill, menu, `shrink --swap` safeguards). `docs/export-analysis.md` — decision log (§7 = confirmed decisions). README covers usage only; keep rationale in these docs.

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
- **`shrink --swap`**: the EXIT trap removing `$snap` must be cleared (`trap - EXIT`) BEFORE the swap moves the snap into `$OPENCODE_DB`, or the trap would delete the live DB on exit.
- `o_effective_db` is memoized: `o_resolve_db` must run in the **parent** shell (the dispatcher calls it; `o_db_exists` calls it directly). Never resolve a backup only inside `$(...)` (command substitution = subshell: the decompressed temp would be re-created per call and never cleaned). The dispatcher sets `trap 'o_cleanup_tmp' EXIT` to remove the decompressed `.gz` temp.
- Paths and file names: `safe_filename` strips `@()[]` etc.

## Deploy

- `install.sh` — copies modules+tests (+`uninstall.sh`) to `~/.local/share/opencode-db-exporter`, symlinks `~/.local/bin/opencode-db` → `modules/opencode-db.sh`, creates conf from `opencode-db.conf.example` if missing (permissions 600).
- `uninstall.sh [--all] [--yes]` — removes the installed code + shim; keeps conf/backups/exports unless `--all`.
- Config: `~/.config/opencode-db/opencode-db.conf` (600). Dependencies are self-managed via `opencode-db deps`.