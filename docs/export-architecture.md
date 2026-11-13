# Export architecture

> Product and pipeline design for the Python exporter. User-facing commands and flags are in [README.md](../README.md); data formats are in [schemas.md](schemas.md).

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
  is the single source of this digest, shared by the `digest` product and `memory`. The
  same two literals make `compactions` and `digests` two different counters in
  `metadata.json` (markers vs summaries) and are the reason the **product** is named
  `digest`: it only ever wrote digests. `compactions` survives as a deprecated alias
  (`PRODUCT_ALIASES`, normalised at resolve time) — see `archive/export-analysis-2026-full.md`.
- Config precedence: **env > conf file > per-file default** (`load_conf` in `common.sh` snapshots
  the variables before sourcing `$OCED_CONF`). The per-file default is `~/.config/opencode-db/<file>`
  if present, else the repo-shipped copy when running portably, else the built-in.
- **Checkout defaults**: Python run from the checkout defaults data to the repo's
  gitignored `exports/` and `backups/` regardless of an installed user's config; Python
  does not read `opencode-db.conf`. Bash run from the checkout uses the same repo-local
  data defaults unless `OCED_OUT`/`OCED_BACKUP_DIR` is explicitly set in the environment
  or selected `OCED_CONF`. Its config/preset lookup can still prefer per-user files. The
  Bash install copies only `src/` and therefore defaults to the user's app-data exporter
  directory; re-run `install.sh` after updating a checkout to refresh the installed copy.

## 3. Export pipeline

The root `opencode-db-export.py` entry point is the primary, stable interface for creating
exports. It runs the `exportlib` package directly with Python's standard-library
`sqlite3`; no `pip install` or external SQLite executable is required. `export.sh` is an
optional Bash bridge to the same self-bootstrapping Python CLI (`src/exportlib/cli.py`;
the old `src/export.py` shim is gone), adding the Bash suite's command and menu
integration. There is no fork toward the opencode CLI (the CLI offers no `session export` and
its environment filters would hide sessions; reading the DB directly in `mode=ro` is what
guarantees seeing everything).

On Windows, the Python config asks the installed OpenCode CLI for `opencode debug paths db`
(unless `OPENCODE_DB` is set), so channel-specific and overridden database locations are
respected. SQLite access builds a percent-encoded file URI with `mode=ro`. The exporter
shows live progress on an interactive terminal; `--no-progress` disables it, and progress
never goes to non-terminal stderr. This is native Windows support for generating exports;
export-run management, backups, shrink and the interactive menu remain in the
Bash/Linux/WSL command suite. The Python `update.py` module is an implementation backend for
the Bash `exports update` run-management command, not a separate public export CLI.

The versioned (`schema_version: 1`) Python automation contract includes
`--check --json` (read-only database preflight), `--show --json` (static plan), and
`--dry-run --json` (read-only selected-session count). Preview operations never create
output directories. Exit code `0` means ready/success, `1` means a runtime or database
error, `2` is argparse usage error, and `3` means no data to export. JSON preflight
distinguishes `status: "no_data"` plus `no_data_reason` from `status: "error"` plus
`error`.

The two interfaces intentionally have different configuration surfaces. The standalone
Python exporter reads `OPENCODE_DB`, `OCED_OUT`, `OCED_PRESETS`,
`OCED_TRANSCRIPT_CHUNK_MB`, and the backup settings needed by `--snapshot fresh`; it does
not source `opencode-db.conf`. The Bash suite reads `OCED_CONF` and its path/preferences
(`OCED_BACKUP_DIR`, `OCED_FROM_BACKUP`, `OCED_SHRINK_PRESETS`, compression/logging/timezone
settings) and passes the relevant export environment to Python. `OCED_FROM_BACKUP` alone
does not redirect the Python entry point to a backup; Bash resolves the chosen backup and
passes that file as `OPENCODE_DB`.

On WSL, direct reads from a Windows-mounted database may be affected by SQLite WAL locking
and filesystem semantics. Keep the database and its `-wal`/`-shm` sidecars together. The
optional Bash backup uses SQLite `.backup`, which creates a consistent WAL-aware snapshot;
the Python exporter does not create backups.

### Products

| Product | Document |
|---|---|
| `transcript` | the conversation in markdown (text + reasoning + tools + patches + markers), split near the 1 MB target between complete rendered messages by default when needed. A single oversized message stays whole. `full` is an accepted alias |
| `digest` | only the `mode=compaction` digests (`compactions` = deprecated alias) |
| `memory` | RAG corpus: one JSON object per **root** session (metadata, `first_user`, `last_assistant`, all digests) |
| `faithful` | the lossless machine archive: one native `{info, messages:[{info, parts}]}` JSON file per session, nothing display-filtered |

The Markdown products do not print the internal `step-start`/`step-finish` parts.
They remain available in `faithful`, and `step-finish` still feeds token/cost
backfill. After display filters run, a message with no visible body is omitted
with its heading and timestamp. Messages are separated by headings and spacing,
not a horizontal rule after every message; `--mark-compactions` keeps its
separate, intentional compaction annotation.

There is no `all` meta-profile; "all sessions" means selecting ALL in the picker (or an
empty `--filter`). `--role` is a flag (`all|user|assistant`), not a preset; `memory`
ignores it (documented in its `index.md`). The `faithful` product ignores every
display filter too (`--tool-output`, `--patch`, `--role`, `--no-reasoning`,
`--mark-compactions`, `--summary-diffs`): it is the raw record.

### Named presets (`presets.json` = source of truth)

The product × flags combination is folded into a **presets** file (JSON in `OCED_PRESETS`,
default `~/.config/opencode-db/presets.json`, same env > conf > default rules;
`install.sh` auto-creates it from the shipped `presets.json` when missing). A preset pins
`product` + its config flags + optionally the selection (`filter` LIKE **or** exact
`sessions`, never both). It is the source of truth for both the CLI and the menu:

- `export <name>` resolves: if `name` ∈ `transcript|memory|digest|faithful|full` it is a
  product; if it is a known preset, `apply_preset()` applies its keys over the argparse
  `args` (validating `choices`/types with `die()` on an invalid value); otherwise
  `ap.error` lists the known products and presets. `metadata.json` records `"preset"`
  and canonical `selection` provenance.
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
  `transcript|memory|digest|faithful` (mutually exclusive with `product`). The selection is
  top-level and shared; `apply_bundle()` validates it and stores `args.bundle`. Dispatch
  (`run_bundle()` in `cli.py`) computes one shared collision-free stamp (bumped to
  `stamp@N` only when the run directory already exists), then re-executes `exportlib/cli.py
  <product>` per product with the shared `--stamp`, a hidden `--preset-name` for
  provenance, and an internal bundle-child marker that writes all session products as
  siblings in `<stamp>/<UTC-updated-date>__<session-folder>`. The date comes from
  `session.time_updated` in epoch milliseconds and is formatted in UTC, so folder
  names do not vary by machine timezone. Session filenames carry their product suffix;
  only `subagents/` and transcript `.parts/` add a nested directory. Product indexes and
  metadata are named `index.<product>.md` and `metadata.<product>.json` at the run root;
  the aggregated memory `corpus.jsonl` also remains at the root. The root `index.md`
  links those product indexes. `exports update` uses the same layout when rebuilding a
  multi-product run. `bundle_child_argv()` forwards user-explicit flags as-is (CLI wins)
  and only emits a per-product value when it was not explicit.
- `load_sessions()` now accepts exact ids: `WHERE s.id IN (…)` when `--sessions` is given,
  the previous LIKE when only `--filter`, and the whole table when there is no selection.
- Without a file (or no matches) there are no presets: the raw-flags path is unchanged.

### Subagent inclusion (`--no-subagents`, `--no-orphan-subagents`)

Two *inclusion* questions, deliberately separated from `--sub` (which only decides
**where** a kept subagent is rendered, transcript only):

1. **Is a subagent in the export at all?** `--no-subagents` says no, for **every**
   product. It matters most for `memory` (the corpus folds subagents into their root's
   line, so it empties the `subagents` array) and for any `--filter`/no-selection run,
   where the matched set would otherwise pull the whole tree in.
2. **What happens to a selected subagent whose parent is not exported?** By default it
   is **promoted to a root** and exported standalone — the "I only want that one
   subagent" case, which a `WHERE s.id IN (…)` selection makes possible by
   construction. `--no-orphan-subagents` instead yields a **closed set**: the subagent is
   dropped, iterating to a fixpoint so a nested chain collapses one level per pass.

Both run on the selected set **before** the hierarchy is resolved, so `sessions` counts,
`index.md`, `metadata.json` and the printed summary can never disagree about what was
exported. A **subagent** is defined as a session with a non-empty `parent_id` **whose
parent row still exists** (`all_session_ids()`); a session whose parent is gone is an
*orphan*, i.e. a root for every purpose here — nothing to hide behind, and a parent that
can never be exported. If the flags leave nothing to export, the run dies with an
explanatory message instead of writing an empty artifact.

After inclusion, writers walk every selected descendant recursively. Transcript and
faithful files for all levels live under the root's `subagents/` directory; the run
index nests their links by `parent_id`, and memory nests child references in the root
corpus record. A fork has no subagent `parent_id`, so it remains an independent root.

In the menu this is the sessions picker's `subagents: shown ⇄ hidden` row
(`get_sub_ids` in the generic picker), which **starts hidden** so browse and export both
open roots-only: a hidden subagent is not rendered, so it cannot be marked and never
reaches the CSV — the CSV is expanded **after** the picker to include the full recursive
cascade of subagents for every marked root. No `--no-subagents` flag is used; the
expansion is structural, so the guarantee does not depend on a CLI flag. In shown mode,
each subagent is its own row with its own mark, and the confirm reports how many were
explicitly unmarked.

### `faithful`: the lossless JSON archive

The `faithful` product writes one `.json` file per root session (subagents under
its `subagents/` folder) with the native shape
`{"info": {...}, "messages": [{"info": {...}, "parts": [...]}]}` (parity with
`session_faithful`). It is a product, not a flag on `transcript` — the Markdown and
the machine copy are two different documents, and a plan includes the one it needs
(`complete`/`review` include both; `source` is the raw copy alone). `info.tokens` includes
`backfilled`.
Because it never applies the display filters, a plan containing it is what the
cards call **lossless**.

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

Each run writes directly into its stamp directory, without a product subdirectory.
Single-product runs use `index.md` + `metadata.json`; bundles use product-suffixed
`index.<product>.md` + `metadata.<product>.json` alongside the bundle `index.md`.
`metadata.json` (tool/version/date, `db` +
`db_sha256` to correlate the export with a snapshot, `profile`, flags such as
`sanitize`/`reasoning`/`tokens_backfilled`, counts). `exports.sh` aggregates
these `metadata.json` per stamp for `exports list/remove/prune`.

## 7. Quick decision matrix — what do I export when?

| I want to… | use | notes |
|---|---|---|
| keep a lossless backup of everything | `python opencode-db-export.py complete` | complete tool outputs + the raw session + corpus |
| keep the raw session, losslessly | `python opencode-db-export.py source` (or `faithful`) | one native-JSON file per session, no Markdown; only `--sanitize` redacts |
| read a conversation and keep its RAG corpus, no raw copy | `python opencode-db-export.py study` | readable log + corpus.jsonl, no faithful JSON |
| review or hand a session to someone | `python opencode-db-export.py review` | no reasoning + the raw session; it does **not** redact — **read the output before passing it on** |
| read a conversation plain | `python opencode-db-export.py notes` | every message; tool output truncated (~500 chars), patches and reasoning kept |
| read only the dialogue (no tools, patches or reasoning) | `python opencode-db-export.py conversation` | user + assistant text only; the leanest readable transcript |
| collect just the prompts I typed (task log / prompt library) | `python opencode-db-export.py prompts` | user messages only (`role user`); no assistant replies, reasoning or tools |
| give another AI the context of my sessions (RAG) | `python opencode-db-export.py rag` or `memory` | corpus.jsonl with defaults; add `--files` for touched files |
| skim the "knowledge arc" of a session | `python opencode-db-export.py digest` | just the compaction summaries (also in transcript + memory) |
| archive-grade export, but make sure the backup is current first | `python opencode-db-export.py complete --snapshot fresh` | offers a fresh backup when the last one diverged, then exports all bundle products |
| read one conversation in full **and** keep the raw copy | `python opencode-db-export.py complete --sessions ses_X` | the Markdown, corpus and native-JSON archive |
| audit what opencode actually ran | `transcript` + `--tool-output full` `--patch full` | evidence = tool calls + diffs |
| skim the "knowledge arc" of a session **without exporting** | `opencode-db info <id>` / `opencode-db digest <id> show` | Bash inspection commands; `info --no-digest` drops the digest block |
| narrow a run to a project/session | `--filter 'Project X'` or `--sessions ses_…` | also the menu's session picker / plan override |
| export from a stored backup instead of the live DB | `opencode-db --from-backup <file> export <product>` | Bash global option; every read command honors it |
| refresh an existing run after the DB moved on | `opencode-db exports update <stamp>` (menu: `[>] update`) | Bash run manager; keeps the stamp and invokes the Python engine |
| check whether a run is still current | `opencode-db exports verify` (or the tag on `exports list`) | Bash run manager; reports stale/missing/unverifiable sessions |
| see what a run left out | `opencode-db exports view <stamp>` | Bash run manager; includes out-of-scope sessions |
