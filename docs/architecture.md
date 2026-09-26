# Architecture — opencode-db-exporter

> Design & rationale document. For practical usage (commands, flags, installation)
> see [`README.md`](../README.md). The confirmed product decisions from the export
> redesign are recorded in [`export-analysis.md`](export-analysis.md) (§7).

## 1. Philosophy: never write to the live DB

The guiding principle is that `opencode-db` is an **audit** tool: it reads, backs up and
exports, but never modifies the database opencode uses live.

- All access uses `mode=ro`: bash `sqlite3 "file:$DB?mode=ro"` (`o_db_uri` in
  `common.sh`), python `sqlite3.connect(f"file:{db}?mode=ro", uri=True)`.
- The opencode DB runs in **WAL** mode (`opencode.db-wal`): a `cp` of the main file does
  not capture the WAL tail. That is why backups and the `shrink` snapshot use
  `sqlite3 .backup <dest>` (consistent snapshot), never `cp`.
- `shrink` builds a **copy** that is pruned + VACUUMed and verifies
  (`integrity_check` = ok, `foreign_key_check` = 0 rows) **before** storing it. Replacing
  the live DB is manual — or the new `shrink --swap` (see §6), the only path that touches
  the live DB, and always explicitly and guarded.
- `--from-backup` (global flag, before the subcommand) points every read at a stored
  backup; a `.gz` is decompressed to a single memoized temp file
  (`o_resolve_db`/`o_effective_db` in the parent shell, cleaned with `trap ... EXIT`);
  a backup is never resolved inside `$(...)` (subshell) because that would create one
  temp per call that never gets cleaned.

## 2. opencode data model (real schema)

Verified information about the schema this tool consumes (not generic: other sources may
describe an invented schema):

- Table `session` (singular), with: `id`, `parent_id` (subagent when non-empty), `agent`,
  `model`, `directory`, `title`, `version`, `time_created`/`time_updated` (epoch ms),
  `cost`, `tokens_*` (`input/output/reasoning/cache_read/cache_write`), `share_url`.
- Table `part`: `part.data` is JSON with `type ∈ text | file | step-start | reasoning |
  tool | step-finish | patch | compaction`.
- Tool call: `part.data.state.input.command` (tool), `.state.input.arguments`,
  `.state.output` (truncatable).
- `message.data.summary.diffs`: per-message change summary (`--summary-diffs`);
  `summary` can be `true` (bool), not only an object.
- **Compaction**: the `part.data.type = 'compaction'` rows are only markers (`auto`,
  `overflow`, `tail_start_id`); the **digest** of the compacted context is the `text` of
  the following message with `data.mode='compaction'`. `digests_for` (in `exportlib/db.py`)
  is the single source of this digest, shared by the `compactions` product and `memory`.
- Config precedence: **env > conf file > default** (`load_conf` in `common.sh` snapshots
  the variables before sourcing `$OCED_CONF`).

## 3. Export pipeline

`export.sh` is a "bash → python" bridge: it validates dependencies/DB and delegates to the
`exportlib` package (`modules/exportlib/cli.py` is the self-bootstrapping CLI entry — the old
`modules/export.py` shim is gone), which is the only SQLite reader. There is no fork toward
the opencode CLI (the CLI offers no `session export` and
its environment filters would hide sessions; reading the DB directly in `mode=ro` is what
guarantees seeing everything).

### Products

| Product | Document |
|---|---|
| `transcript` | the conversation in markdown (text + reasoning + tools + patches + markers). `full` is an accepted alias |
| `compactions` | only the `mode=compaction` digests |
| `memory` | RAG corpus: one JSON object per **root** session (metadata, `first_user`, `last_assistant`, all digests) |

There is no `all` meta-profile; "all sessions" means selecting ALL in the picker (or an
empty `--filter`). `--role` is a flag (`all|user|assistant`), not a preset; `memory`
ignores it (documented in its `index.md`).

### Named presets (`presets.json` = source of truth)

The product × flags combination is folded into a **presets** file (JSON in `OCED_PRESETS`,
default `~/.config/opencode-db/presets.json`, same env > conf > default rules;
`install.sh` auto-creates it from `presets.json.example` when missing). A preset pins
`product` + its config flags + optionally the selection (`filter` LIKE **or** exact
`sessions`, never both). It is the source of truth for both the CLI and the menu:

- `export <name>` resolves: if `name` ∈ `transcript|memory|compactions|full` it is a
  product; if it is a known preset, `apply_preset()` applies its keys over the argparse
  `args` (validating `choices`/types with `die()` on an invalid value); otherwise
  `ap.error` lists the known products and presets. `metadata.json` records `"preset"`
  and `sessions_selected` for provenance.
- **The CLI wins over the preset**: a `--filter`/`--sessions` on the command line voids
  the whole preset selection (`cli_selection`), and any explicit flag (e.g. `--cap`)
  beats the preset value. Detected with `flag_in_argv()`, not with the argparse default.
- **`snapshot: fresh`** is a workflow key (**single preset only**, `SINGLE_ONLY_KEYS`;
  never per-product/bundle): when a plan carries it, the export is expected to double as
  a reference archive. The CLI reads the last backup's manifest and compares
  sessions/messages/max_updated against the live DB (`_backup_aligned` — the same triple
  as the menu's `o_backup_aligned`) and warns (`no backup exists yet` / `out of sync`)
  before exporting; the menu turns that into an offer to create a fresh backup first.
  Skipped silently under `--from-backup` (the source *is* the snapshot).
- **Bundle presets** (`products` instead of `product`): a map `{product: {flags}}` over
  `transcript|memory|compactions` (mutually exclusive with `product`). The selection is
  top-level and shared; `apply_bundle()` validates it and stores `args.bundle`. Dispatch
  (`run_bundle()` in `cli.py`) computes one shared collision-free stamp (bumped to
  `stamp@N` only when any product dir already exists), then re-executes `exportlib/cli.py
  <product>` per product with the shared `--stamp` and a hidden `--preset-name` for
  provenance. Each child runs the unchanged single-product pipeline, so a bundle subfolder
  is byte-identical to a normal run; the parent writes an `index.md` at the stamp root
  listing the bundle products. `bundle_child_argv()` forwards user-explicit flags as-is
  (CLI wins) and only emits a per-product value when it was not explicit.
- `load_sessions()` now accepts exact ids: `WHERE s.id IN (…)` when `--sessions` is given,
  the previous LIKE when only `--filter`, and the whole table when there is no selection.
- Without a file (or no matches) there are no presets: the raw-flags path is unchanged.

### Faithful JSON (`--json`)

Each session writes a `.json` file next to its `.md` with the native shape
`{"info": {...}, "messages": [{"info": {...}, "parts": [...]}]}` (parity with
`session_faithful`). Inline subagents go to `<stem>.sub-<id8>.json`. `info.tokens`
includes `backfilled`.

### Token backfill

Old sessions with `tokens_*`/`cost` at 0/NULL are reconstructed in memory by summing the
`part.data.type='step-finish'` rows (`tokens.input/output/reasoning/cache.{read,write}` +
`cost`). The result is flagged `tokens_backfilled` in `metadata.json`/JSON/corpus.
Nothing is migrated in the DB.

### Sanitization (`--sanitize`, opt-in)

**In memory, on native types, before serializing**: `sanitize_json()` walks the
dict/list recursively and applies the regexes only to `str` values; then clean JSON is
serialized. In markdown, sanitization is applied to each string at the render point
(`Renderer.w`), never on the final written file. Display blocks
(```` ```json ```` from `state.input`, `patch`, `file`) are sanitized over their
serialized text — it is markdown code content that nobody parses again, so there is
no risk.

Covered patterns (high-confidence prefixes only, regex): `sk-`/`sk-ant-`, `ghp_`,
`gho_`, `github_pat_`, `xox[baprs]-`, `AIza…`, `AKIA…`, JWT (`eyJ…`), `Bearer …`,
and multiline private PEM keys (`re.S`). Deliberately **excluded** to avoid false
positives: generic `key=value` pairs and bare env-var names (`*_API_KEY`).

Assumed and documented limits: the regex is a *baseline*, not a semantic filter — a
contextual secret (a password in prose without `=`/`:`) can slip through; it is not a
substitute for rotating real keys. The "sanitize vs faithful JSON" tension is resolved by
making `--sanitize` opt-in.

### `memory`: streamed corpus

`corpus.jsonl` can weigh more than the DB itself (untruncated text + all digests +
`--files`). So `memory_export` **writes line by line** (one root + its subagents = one
JSON line) with `flush()`, never accumulating the corpus in memory; the RAM peak stays
bounded to one root session at a time. `--cap N` bounds every text value (optional guard);
if the corpus exceeds ~50 MB without `--cap`, it suggests bounding.

### index.md / metadata.json

Each run writes `index.md` (summary/index) + `metadata.json` (tool/version/date, `db` +
`db_sha256` to correlate the export with a snapshot, `profile`, flags such as
`role`/`json`/`sanitize`/`reasoning`/`tokens_backfilled`, counts). `exports.sh` aggregates
these `metadata.json` per stamp for `exports list/remove/prune`.

## 4. Menu design

Picker-driven with real fzf: TSV rows `key<TAB>display` (`--with-nth=2..`), **no
TAB multi-select** — mode switches and bulk operations are their own rows. The export
picker is **preset-only**: if the presets file exists, it lists each preset as a direct
action (rows/purposes/plans resolved by `exportlib/plan.py`; bundle presets render as
`[transcript+memory]`); **without the file it prints setup guidance**
(`cp presets.json.example …`) plus the raw CLI — **there is no manual session→product
fallback** (`oc_pick_product`, `oc_export_flow` and `oc_export_manual_picker` are gone;
`oc_export_manual_rows` became `oc_selection_rows`, reused by `oc_preset_run`).
Picking a preset asks next for **the selection** (`oc_preset_run`, reusing the
session/ALL rows): **ALL** keeps the preset's embedded selection (runs as configured),
**one session** runs `export <name> --filter <ses>` — selection is run-time state, not
part of the plan identity, so a plan behaves ad-hoc just like raw flags (CLI-wins
already implemented). Product rows still come straight from `exportlib/plan.py
products` but only as the CLI/test API surface (no product-only menu flow). Menu labels
explain *purpose and relative size*: product rows carry a "use it when…" tag;
`oc_preset_purpose` annotates the shipped plans
(`archive`/`quick`/`share`/`notes`/`rag`/`digest`) with their intent (unknown names get
the bare row). The confirm step prints a **Will produce:** block with per-product
descriptions + effective flags, and a sanitize caveat when applicable. There are **no
variant tables or custom checklists**: tuning and "bundle everything in one stamp" live
in the presets file (`OCED_PRESETS`) or the CLI.

The root menu recomputes its header on every loop: `run_menu --refresh-cb oc_root_status`
rebuilds `ACTION_STATUS` (DB/sessions/WAL/backup/exports counts) after each action, so a
pickered deletion is reflected immediately.

**Create + manage in one picker.** Shrink lives in its own root entry: `oc_shrinks_picker`
offers `[create shrink copy…]` (a **3-step wizard**: sessions → recipe → read-only
plan, see §5; LIVE DB, own snapshot), a **`__SWAP__`** row that
swaps the picked copy into the LIVE DB behind `oc_confirm_typed "confirm"` (staleness
checked via `o_shrink_stale` first), plus a `view`/`remove` toggle with per-run rows and
the `delete ALL` / `delete old (keep newest)` bulk rows. Rows come from the shrink.sh
helpers (`shrinks_runs_find`/`shrinks_run_row`) — the same source as `shrinks list --tsv`,
so the menu never re-aggregates jq. This removed the old `__SHRINK__` row from the backups
picker, which is now just create/delete-all/keep-newest/delete-one.

The term **plan/preset** always means the named config; **product** always the keyword
(`transcript|memory|compactions`). Usage and the decision matrix:
`docs/export-guide.md`; short usage: `README.md` (Menu).

## 5. `shrink`

Motivation: the DB only grows (the bulk is the event store); deleting sessions reuses
pages but does not shrink the file (only `VACUUM` does, and it needs an exclusive lock).
`oced_shrink` runs on a copy:

1. `.backup` snapshot of the live DB (WAL-safe).
2. **One keep rule** (exactly one; the last one given wins): `--keep N` (default 10),
   `--older-than DAYS`, `--since DATE`, `--keep-all`, `--keep-sessions ID[,ID]` or
   `--discard-sessions ID[,ID]`. `--keep-sessions` yields the **closed** keep-set via a
   recursive CTE (parents and subagents of a kept session are kept too; no orphans);
   `--discard-sessions` inverts it — the kept set is *everything except* the listed ids
   **and their descendants**, so the discard set is descendant-closed by construction and
   the keep side needs no extra closure (FK-safe).
3. FK-safe deletion order of session-bound tables + `event`/`event_sequence` aggregates
   (`aggregate_id LIKE 'ses_%'`).
4. Optional `--strip-reasoning` (the `part` rows with `data.type='reasoning'`).
5. `integrity_check` + `foreign_key_check` **before** saving `opencode.shrunk.db` +
   `shrink.json` (criteria/counts/per-table + `selection` in the `{"rule", ids/value}`
   shape the menu consumes).
6. Manual swap — or `--swap`, see §6.

**Named recipes = OPERATIONS only** (the shrink mirror of §3.3): `modules/shrinklib/` is
the python SSoT, split in two disjoint families. **Session selection** (`keep`/
`older_than`/`since`/`keep_all`/`keep_sessions`/`discard_sessions`) is a **CLI flag**
— exactly one per invocation, never a recipe key. **Operations** (today
`strip_reasoning`) are the only valid recipe keys: `flags.py` owns both families +
the built-ins (`lean` = strip, `quiet` = prune+vacuum), `presets.py` loads
`$OCED_SHRINK_PRESETS` (validated: a keep rule inside a recipe dies pointing at the
matching flag, unknown keys die) and merges it **over** the built-ins, `plan.py`
resolves rows/descriptions/bake/`ops-flags` for the CLI and the menu. `shrink <name>`
bakes the recipe to the raw **operation** flags (`--strip-reasoning`) and prepends
them, so an explicit selection flag still wins (`shrink lean --keep 3`); unknown names
error and list the known ones. `--discard-sessions` prints a first-step hint —
`opencode-db export memory --sessions <ids>` — so nothing is lost before the pruned copy
is made; the menu makes it an actual offer.

**The create flow is sessions-first** (`oc_pick_shrink` = the `__CREATE__` entry of the
shrinks picker), and it is the only way to create a shrink from the menu:

1. `oc_shrink_sessions_pick` — **root sessions only** (`list --root`): a subagent always
   follows its root, so it never needs a row, and an orphan whose parent is gone *is* a
   root. `[x]` = survives in the copy, default ALL marked; a `(N sub)` badge (recursive)
   shows what each root drags along. Bulk rows `__ALL__`/`__NONE__`/`__LAST__ <N>`/
   `__OLDEST__ <N>`/`__DAYS__ <N>` (the age ones **rest**: unmark all, then mark the
   matching ones). `__MAKE__` is **continue**, not "build": all marked → `--keep-all`,
   unmarked roots → `--discard-sessions <csv>`, nothing marked → refused ("the copy
   would be an EMPTY database"). Rows are **sorted by `time_updated` (newest first)**
   and an `__TOGGLE__` row flips to oldest-first: the rows are re-read on every render
   and the marks live in an associative array, so re-sorting loses nothing. The session
   order is the *only* thing the toggle changes — the selection is run-time state.
2. `oc_shrink_ops_pick <sel-args>` — the **recipe**, and nothing else: the recipe rows
   (`shrinklib/plan.py rows`), each described by its purpose. There is no operation
   toggle and no "continue" row: every row is a named ops-only recipe (`lean` strips
   reasoning, `quiet` prunes + vacuums), and picking one bakes its operations and goes
   straight to the plan. Composition is expressed by writing a recipe, not by stacking
   toggles in a picker.
3. `oc_shrink_confirm_run` — the **read-only plan**: exact counts on the LIVE DB using
   the *engine's own predicates* (kept roots+subagents, the discarded cascade, rows per
   table, reasoning parts, current size) via `WITH RECURSIVE` closures, the
   `export memory --sessions` offer when discarding, the picked `Recipe:`/`Command:`
   lines, then the y/N gate.

Rationale: the *selection* is the decision users actually think in ("which conversations
do I keep?"), and it is a property of a specific DB, never of a reusable recipe — so it
is asked at run time, not baked into a named preset. The *operations* are the reusable,
DB-independent part, so that is all a recipe may carry. The plan reuses the numbers the
engine will really apply, so the confirmation cannot lie. `__CUSTOM__`, `__DRYRUN__` and
`__SESSIONS__` are gone (the picker itself is the custom flow, and the plan replaces the
dry-run); the CLI keeps `--dry-run` and the full selection flag set for headless use.
Declining at the plan re-renders the recipe rows (pick another one; the selection is
untouched) and ESC there climbs back to the sessions picker with the marks intact.

Produced copies accumulate under `$OCED_BACKUP_DIR/shrink/<o_ts>/`; `oced_shrinks`
(`shrinks list [--tsv]|view <stamp>|remove <stamp> [--yes]|prune <N>`) manages them the
way `exports` manages run folders — `list` aggregates each `shrink.json` + the copy size
into one row, `--tsv` emits `stamp<TAB>display` as the single machine row format (used by
the menu picker).

## 6. Operational safety of the swap (`shrink --swap`)

The manual swap published in the README has a real risk: `rm -f` of the `-wal`/`-shm`
while opencode is running can lose the WAL tail. `opencode-db shrink
[recipe] --swap [--yes]` automates the replacement with guards:

1. **Process guard**: aborts if there is a process whose cmdline mentions `opencode`
   (excluding the tool itself / `pgrep`) — `pgrep -af`.
2. **Re-verification** of the copy in `mode=ro` (`integrity_check` + `foreign_key_check`).
3. **Safety copy** of the live DB with `sqlite3 .backup` →
   `$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink-<ts>.db` (WAL-safe; never `cp`),
   auto-keeping only the most recent copy. The swap safety copy is **not** a
   `backups`/manifest run — `shrinks verify` lists/cleans it.
4. **Atomic swap** with `mv -f` + cleaning of the old DB's `-wal`/`-shm`.
5. **Rollback**: if the new DB does not open/verify in `mode=ro`, the safety copy is
   restored.

`--dry-run` never writes; combining it with `--swap` is rejected. Confirmation `[y/N]`
can be skipped with `--yes`.

`shrinks verify [--tsv] [--yes]` audits the produced copies: orphan run dirs (no
valid `shrink.json`), old `pre-shrink/*` copies, and a last shrink stale vs the live
DB. `shrink.json` records `sessions.max_updated` (newest kept session `time_updated`)
so the freshness check runs in-database; a legacy shrink.json without that field is
flagged as unverifiable rather than silently "up to date".

## 7. Links

- `../README.md` — usage guide (installation, commands, flags, tests, layout).
- `export-analysis.md` — pre-redesign analysis and §7 with the confirmed decisions.