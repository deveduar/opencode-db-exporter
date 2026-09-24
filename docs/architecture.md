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
`exportlib` package (`modules/export.py` is just the entry shim), which is the only SQLite
reader. There is no fork toward the opencode CLI (the CLI offers no `session export` and
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
- **Bundle presets** (`products` instead of `product`): a map `{product: {flags}}` over
  `transcript|memory|compactions` (mutually exclusive with `product`). The selection is
  top-level and shared; `apply_bundle()` validates it and stores `args.bundle`. Dispatch
  (`run_bundle()` in `cli.py`) computes one shared collision-free stamp (bumped to
  `stamp@N` only when any product dir already exists), then re-executes `modules/export.py
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

Covered patterns (regex): `sk-`/`sk-ant-`, `ghp_`, `github_pat_`, `xox[baprs]-`,
`AIza…`, `AKIA…`, JWT (`eyJ…`), multiline private PEM keys (`re.S`), variable names
`*_API_KEY`, and sensitive `key=value` pairs (`password|token|api[_-]?key|…`).

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
picker is **preset-first**: if the presets file exists, it lists each preset as a direct
action (read with `jq`, core dep; bundle presets render as `[transcript+memory]`) +
a `Manual…` row; without the file it is the classic
picker (ALL + sessions). Picking a preset asks next for **the selection** (`oc_preset_run`,
reusing the session/ALL rows): **ALL** keeps the preset's embedded selection (runs as
configured), **one session** runs `export <name> --filter <ses>` — selection is run-time
state, not part of the plan identity, so a plan behaves ad-hoc just like raw flags (CLI-wins
already implemented). The manual flow (`oc_export_flow`) is session (**or ALL**) →
`oc_pick_product` (`transcript|memory|compactions`, 3 rows) → `oc_export_confirm` plan →
run `export <product>` with its **default options** (+ `--filter <session>` when a session
was picked). Menu labels explain *purpose and relative size*: product rows carry a
"use it when…" tag; `oc_preset_purpose` annotates the shipped plans
(`archive`/`quick`/`share`/`notes`/`rag`/`digest`) with their intent (unknown names get
the bare row). **No `Manual…` row** when presets exist — the shipped default plans
cover the three products with defaults; the classic session→product flow remains the
no-presets fallback. There are **no variant tables or custom checklists in the menu**:
tuning and "bundle everything in one stamp" live in the presets file (`OCED_PRESETS`)
or the CLI. The confirm step prints a **Will produce:** block with per-product
descriptions + effective flags, and a sanitize caveat when applicable. The term
**plan/preset** always means the named config; **product** always the keyword
(`transcript|memory|compactions`). Usage and the decision matrix:
`docs/export-guide.md`; short usage: `README.md` (Menu).

## 5. `shrink`

Motivation: the DB only grows (the bulk is the event store); deleting sessions reuses
pages but does not shrink the file (only `VACUUM` does, and it needs an exclusive lock).
`oced_shrink` runs on a copy:

1. `.backup` snapshot of the live DB (WAL-safe).
2. **Closed** keep-set via a recursive CTE (parents and subagents of a kept session are
   kept too; no orphans).
3. FK-safe deletion order of session-bound tables + `event`/`event_sequence` aggregates
   (`aggregate_id LIKE 'ses_%'`).
4. Optional `--strip-reasoning` (the `part` rows with `data.type='reasoning'`).
5. `integrity_check` + `foreign_key_check` **before** saving `opencode.shrunk.db` +
   `shrink.json` (criteria/counts/per-table).
6. Manual swap — or `--swap`, see §6.

## 6. Operational safety of the swap (`shrink --swap`)

The manual swap published in the README has a real risk: `rm -f` of the `-wal`/`-shm`
while opencode is running can lose the WAL tail. `opencode-db shrink
[recipe] --swap [--yes]` automates the replacement with guards:

1. **Process guard**: aborts if there is a process whose cmdline mentions `opencode`
   (excluding the tool itself / `pgrep`) — `pgrep -af`.
2. **Re-verification** of the copy in `mode=ro` (`integrity_check` + `foreign_key_check`).
3. **Safety copy** of the live DB with `sqlite3 .backup` → `opencode.db.pre-shrink-<ts>`
   (WAL-safe; never `cp`).
4. **Atomic swap** with `mv -f` + cleaning of the old DB's `-wal`/`-shm`.
5. **Rollback**: if the new DB does not open/verify in `mode=ro`, the safety copy is
   restored.

`--dry-run` never writes; combining it with `--swap` is rejected. Confirmation `[y/N]`
can be skipped with `--yes`.

## 7. Links

- `../README.md` — usage guide (installation, commands, flags, tests, layout).
- `export-analysis.md` — pre-redesign analysis and §7 with the confirmed decisions.