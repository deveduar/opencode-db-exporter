# opencode-db-exporter — schemas & contracts

Consolidated reference of every persistent artifact this tool reads or writes.
Runtime rule: **the live opencode DB is never written** — every read goes through
`file:$DB?mode=ro` (`sqlite3` in bash, `uri=True` in python). The one deliberate,
opt-in exception is `shrink --swap`, which snapshots the live DB first and swaps
in the pruned copy atomically (§6). This file is the human-readable contract;
JSON-serializable artifacts have machine-checkable schemas where noted.

Dates are always **ISO-8601 UTC** (`YYYY-MM-DDTHH:MM:SSZ`, epoch ms converted via
`ts_iso`). Absent values are `null` (never `""`) in machine artifacts
(`corpus.jsonl`, the `faithful` archives, `metadata.json`); `""` only appears
in human markdown rendering.

Legend: `R?` = optional key.

---

## 1. presets.json — `$OCED_PRESETS`

Source of truth for `opencode-db export <name>` and the export menu (preset-first
when the file exists). Defaults to `~/.config/opencode-db/presets.json` if present,
else the repo-shipped `presets.json` when running portably from a checkout.
Authoritative machine schema: [`generated/presets.schema.json`](../generated/presets.schema.json)
(draft-07). **The schema and the per-key table are generated from
`src/exportlib/flags.py`** (flags = the single source of truth; see
`scripts/generate_schema.py`, output in [`generated/`](../generated/)). Runtime
validation in `exportlib/presets.py` imports the same key lists, so everything stays
in sync by construction.

> Per-key rules table (generated, checked in): [`generated/flags-table.md`](../generated/flags-table.md)
> — regenerate with `python3 scripts/generate_schema.py --docs`; do not edit by hand.
> The table below is only a summary of its non-obvious rows; the generated file is the
> contract. The `product` / `products` values are `transcript` \| `memory` \| `digest` \|
> `faithful` and nothing else: `full` is a CLI alias of `transcript` and `compactions` is a
> deprecated alias of `digest` (both normalised at resolve time, so a run records `digest`).

| `product` | string | `transcript` \| `memory` \| `digest` \| `faithful` | single only (`full` is a CLI alias, **not** a preset product; `compactions` is the deprecated alias of `digest`) |
| `products` | object | keys restricted to the products above | bundle only (exclusive with `product`) |
| `description` | string | — | optional human one-liner (picker row / `--list-presets` / legend); it travels with the recipe, a preset without one shows no prose |
| `filter` / `sessions` | string / string[] | — | selection (shared; exclusive, `not` both) |
| `snapshot` | string | `"fresh"` | **single preset only** (never per-product/bundle): coordinate the export + the reference backup — CLI warns, menu offers a fresh backup, when no backup exists or the last one diverged from the live DB |
| `out` | string | — | CLI-only (never a preset key) |
| `last` / `since` | int / date | — | CLI-only selection rules (never preset keys): a recency rule is recomputed every run |

Unknown keys fail (`additionalProperties: false`). Flags that a product ignores are
harmless. CLI overrides win: an explicit `--filter`/`--sessions` voids the whole
preset selection; any explicit flag beats the preset value per product.

**`fidelity:` is derived, not a key.** No preset declares lossless/lossy: the plan
computes it (`plan.py:fidelity_parts`, exposed in the `resolve` JSON as the `fidelity`
phrase) — **lossless** iff the `faithful` product is part of the plan and no flag drops
data (`no_subagents` / `no_orphan_subagents`, or `sanitize`, which redacts
best-effort), else **lossy** with the reasons. The reason depends on the product that
carries the data: a content product (`transcript` / `digest`) without `faithful` is lossy
for the filtered Markdown; a `memory`-only plan is lossy because the RAG corpus is a
distilled summary, never the full session. `sub: omit` is a loss only when no `faithful`
copy carries the subagents. It is the line each
`--explain` / `--show` / `--dry-run` / menu-confirm card prints after `flags:`. The same
computation yields the **verdict column** of the preset picker row (`plan.py:_preset_row`)
and of `--list-presets`/the legend — one helper, so the row and the card never disagree,
and a `description` never repeats the verdict.

**Selection is run-time state** (menu). A preset is a *plan*: its embedded
`filter`/`sessions` makes it automatable, but in the menu the **sessions picker comes
first** and the selection is applied to the plan that is picked afterwards — marking
every session runs it as configured, a partial one adds `--sessions <csv>` (identical to
the CLI override above, shared by every product of a bundle). A hidden-subagent run also
pins `--no-subagents`. A selection that keeps a subagent whose session it dropped is
named in the confirmation (`N subagent(s) will be exported standalone`), so the
resulting `index.md`/`corpus.jsonl` is predictable. Therefore a plan never "owns" its selection: `setup_cli` clobbers
it only when no explicit CLI/selection is given.

**Bundle semantics.** `products` = `{product: {flags}}`; the selection is
top-level and shared. `run_bundle()` computes one collision-free shared stamp
(`stamp@N` bumped only when any product dir already exists, so every product
lands under the same prefix), then runs one unchanged single-product export per
product with `--stamp <shared> --preset-name <name>`. Each child writes its own
`index.md` + `metadata.json` (with `.preset` provenance); a root `index.md` ties
the bundle (it has no `metadata.json` of its own — that's by design); `exports
list` aggregates it as `transcript+memory`.

---

## 2. Export run layout & metadata.json

`OCED_OUT/<stamp>/`:

```
<stamp>/                       transcript+memory+faithful bundle   <stamp>/            transcript bundle
  index.md                       (bundle tie-in)                  also:  index.md
  transcript/index.md                                        (single product: one dir)
  transcript/metadata.json
  transcript/<session>.md        subagents/<sub>_<id>.md  (per --sub layout)
  memory/index.md
  memory/metadata.json
  memory/corpus.jsonl
  faithful/index.md              the lossless JSON product
  faithful/metadata.json
  faithful/01-<title>_<id>/<title>.json
  faithful/01-<title>_<id>/subagents/<sub>_<id>.json
```

The tool reads `metadata.json` only. Pre-rename run dirs that contain only the
old `metadatos.json` name are ignored by every reader (`exports list`/`view`,
menu, the shrink discard-link).

### `index.md` (human view of a run)

`index.md` mirrors the most useful `metadata.json` cells in a Markdown table, for
a person reading the export without a JSON parser. The always-present rows are
`Product · Date · Source DB · Selection · Sessions (roots/subagents/total) ·
Messages · Compactions · Compaction digests · Tool output · Reasoning ·
Sanitize · Extraction · Full metadata`. The rows that only appear when
the run actually set them (same rule as `--no-subagents`) are:

| row | shown when |
|---|---|
| `Preset` | a preset/plan produced the run (`args.preset`), else no row |
| `Subagents` | `--no-subagents` / `--no-orphan-subagents` narrowed the set |
| `Subagent layout` | `--sub` is not the default `separate` |
| `Role` | `--role` is not the default `all` |
| `Summary diffs` / `Mark compactions` | the matching flag was on |
| `Tokens backfilled` | that many sessions had their tokens/cost summed from `step-finish` |

`Compactions` and `Compaction digests` are the two distinct counters (markers vs
summary texts, see below). The `memory` product writes its own `index.md` with a
memory-shaped row set (root/subagent counts, `Tuning` for `--cap`/`--files`,
`Compaction markers`/`Compaction digests`, `Tokens backfilled`, `Role filter`) and
the same conditional `Preset` row.

### transcript / digest `metadata.json`

```jsonc
{
  "tool": "opencode-db/exportlib", "version": "0.x.0",
  "date": "YYYY-MM-DDTHH:MM:SSZ",
  "db": "/…/opencode.db", "db_sha256": "…",
  "filter": null,                       // or SQL LIKE pattern
  "sessions_selected": null,            // or ["ses_…", …] — the REQUESTED ids, only when --sessions was passed
  "session_records": [                  // WHICH sessions this run actually CONTAINS (never a cap)
    {"id": "ses_a", "title": "Project Alpha", "kind": "root",
     "parent_id": null, "created": "…Z", "updated": "…Z"},
    {"id": "ses_b", "title": "Explore gaps", "kind": "subagent",
     "parent_id": "ses_a", "created": "…Z", "updated": "…Z"}
  ],
  "selection": {"rule": "all"},         // the ONE rule that produced this run; see below
  "scope": {"rule": "all"},             // the BROADER selection the run was DRAWN FROM (same rule shapes); differs from
                                        // `selection` exactly when the CLI/menu narrowed it. `exports update` re-opens it.
  "excluded": [                         // `scope_match - written`: what was in scope but deliberately left out (the menu's
    {"id": "ses_x", "title": "…"}       // marks, or a drop flag). The gap `exports update` can revive; never folded with the
  ],                                    // no_subagents/orphan policy (re-applied at write time). Always present.
  "flags": {"sub": "full", "…": "…"},   // the EFFECTIVE content flags of the run (the recipe `exports update` replays), from
                                        // flags.effective_flags(args): every FLAGS key with its resolved value. Always present.
  "updated_from": "2026-10-19_13-36",   // R?: present only on a REFRESHED run — the stamp it was refreshed from (== its own)
  "update_mode": "delta",               // R?: present only on a refreshed run — delta | accumulative
  "profile": "transcript",              // product keyword: transcript | memory | digest | faithful (never a preset name)
  "preset": "archive",              // R?: preset/plan name that produced this run, else null
  "sub": "inline", "tool_output": "full", "reasoning": true, "summary_diffs": false,
  "sanitize": false, "role": "all",
  "no_subagents": false,            // --no-subagents: subagents excluded from the set
  "no_orphan_subagents": false,     // --no-orphan-subagents: closed set (a subagent whose parent is not exported was dropped)
  "subagents_hidden": 0,            // how many subagents those two flags actually dropped from the MATCHED set
                                   // (0 for an exact --sessions selection: a subagent that was never selected cannot be dropped)
  "tokens_backfilled": 0,               // number of sessions whose token/cost rows were summed from step-finish parts
  "sessions": {"total": 6, "roots": 1, "subagents": 5},
  "compactions": 2, "digests": 2, "messages": 21,
  "last_backup": {"file": "…", "date": "…"},   // R?: latest entry of the backup manifest, else null
  "files": ["transcript/index.md", "transcript/ses_….md"]
}
```

The `faithful` product writes a **subset** of these keys (`sub`/`role`/`reasoning`/
`tool_output` are display concerns it never applies), same as `memory`:

`selection` records which of the four mutually exclusive selection rules ran, so a
run is self-describing even when `filter`/`sessions_selected` are both `null`:

| `rule` | shape | meaning |
|---|---|---|
| `all` | `{"rule": "all"}` | no rule: every session in the source |
| `filter` | `{"rule": "filter", "value": "Project Beta"}` | SQL LIKE on id or title |
| `sessions` | `{"rule": "sessions", "ids": ["ses_a", …]}` | explicit ids |
| `last` | `{"rule": "last", "value": 5}` | the N most recently updated **roots**, plus every session that follows them |
| `since` | `{"rule": "since", "value": "2026-09-01"}` | every session updated on/after that UTC date, subagents included as they match |

`last`/`since` are CLI-only (never preset keys, see `CLI_ONLY_KEYS`): the set they
select changes every time they run. The same phrase appears as the `Selection` row of
`index.md` and in the error when a rule matches nothing
(`error: No sessions to export (last 5 session(s) by last update matched nothing).`).

**`compactions` and `digests` are two different counters and never interchangeable.**

| key | counts | source in the DB |
|---|---|---|
| `compactions` | the **markers** — the compaction *events* opencode recorded | `part.data.type = 'compaction'` |
| `digests` | the **summary texts** it produced for those events | the `text` part of the next message, whose `message.data.mode = 'compaction'` |

A marker carries no content of its own (only `auto`/`overflow`/`tail_start_id`), so a
session can have more markers than digests if a compaction was interrupted before the
model answered. `'compaction'` in `part.data` and `'compaction'` in `message.data` are
opencode's own two vocabularies, not ours. The `digest` **product** exports the digests
(the second column); `--mark-compactions` is what puts the *markers* inline in a
transcript. Both keys are always present in every product's `metadata.json`, so a
consumer never has to guess which of the two it is reading.

### `session_records` vs `sessions` vs `sessions_selected`

Three keys, one job each — they are deliberately not redundant:

| key | answers | shape |
|---|---|---|
| `session_records` | **which sessions the run contains** | array, one entry per written session (roots + subagents), export order, **never capped** |
| `sessions` | how many | `{total, roots, subagents}` — the *summary* of `session_records`, derived from the same list |
| `sessions_selected` | what was **requested** | the `--sessions` ids, or `null` when a rule like `filter`/`last`/`since` chose the set |

The gap `session_records` fills is real: with `filter`/`last`/`since` (or any
subagent flag) nothing in `metadata.json` recorded the resulting set, so
`exports view --json` could not list what a run actually holds.

- **One source of truth**: it is built from the same `written` list of
  `(root, subagents, folder)` tuples that created the directories on disk, so the
  records cannot disagree with the artifacts, and a cascaded or dropped subagent
  is recorded as the result — not as the intent.
- **Identity only.** `id`, `title`, `kind`, `parent_id`, `created`, `updated`. There
  are no per-session `messages`/`compactions`: those totals already exist at the top
  level, and a second copy would be a second number to keep in sync for no gain.
- `kind` is `root`/`subagent` as resolved by the run, so an **orphan** (parent row
  gone) is `root` even though it carries a dangling `parent_id` — the same rule the
  counts use. `parent_id` is `null` when there is none, never `""`.
- Dates are ISO-8601 UTC (`ts_iso`), like every other date in the machine artifacts.

### `scope`, `excluded`, `flags` (and how `exports update` reads them)

`selection` says what the run **contains**; `scope` says the **broader set it was drawn
from**. They are identical for a plain run and differ exactly when the CLI/menu narrowed
it (e.g. a preset pins `filter X`, the menu marks a subset → `--sessions`): then
`selection` is the subset and `scope` is the whole rule. `excluded` is the pure fact
`scope_match − written` — the sessions that were reachable but deliberately left out — and
is what `exports update` may revive: `--sticky stale` (default) revives an excluded session
only once it was edited, `--sticky never` refuses even that (a dropped session stays
dropped), and `--include-excluded ID,ID` reopens **specific** excluded sessions by id — the
one thing the mode axis cannot express. `--include-excluded all` was the exact twin of
`--mode accumulative` (both land on `in_scope == still ∪ new ∪ ex_live`), so it is **refused**
pointing at `--mode accumulative`: "bring everything back" is one action, and the CLI no
longer carries a redundant flag (the menu's single reopen row runs accumulative). It is **not**
folded
with a run's own `no_subagents`/orphan policy, because that policy is re-applied at write
time; folding it would make a drop flag look like a hand-picked exclusion.

`flags` is the run's **effective** content flags (`flags.effective_flags(args)`), i.e. the
recipe `exports update` replays. All three keys are always written.

```jsonc
// A refreshed run additionally carries its provenance (absent on a fresh run):
"updated_from": "2026-10-19_13-36",   // the stamp refreshed (== its own — the stamp never moves)
"update_mode": "delta"                // delta | accumulative
```

The run **keeps its stamp** across a refresh (its place in `exports list`), so the surfaces
that show the stamp also show the refresh next to it (`refreshed <time> (<mode>)` in
`exports list`, `updated: <mode> mode (refreshed in place)` in `exports view`) — a legacy
run without `.session_records` cannot be refreshed at all (there is no record of what it
holds) and is reported `unverifiable`, never silently called fresh.

A **subagent** is a session with a non-empty `parent_id` **whose parent row still
exists**; a session whose parent is gone is an *orphan* and counts as a root
everywhere (it has no parent to hide behind, and its parent can never be
exported). The two inclusion flags are applied to the selected set BEFORE the
hierarchy is resolved, so `sessions`, the index and the printed counts always
describe the same set:
| Flag | Effect |
|---|---|
| `--no-subagents` | every subagent is dropped (all products); orphans stay |
| `--no-orphan-subagents` | a selected subagent survives only while its parent survives (fixpoint over nested chains), instead of being promoted to a root |
| (neither, default) | a subagent selected without its parent is exported standalone, as a root |

### memory `metadata.json`

Same header keys, then product-specific: `"profile": "memory"` always, plus
`"cap"`, `"touched_files"` (bool; whether the `--files` key was requested for the
corpus) and `"files": ["corpus.jsonl", "index.md"]` (the produced files — same
shape as the transcript `files` list). No `sub`/`tool_output`/`reasoning`/
`summary_diffs`. The subagent inclusion keys (`no_subagents`,
`no_orphan_subagents`, `subagents_hidden`) ARE present: memory folds each
subagent into its root's corpus line, so `--no-subagents` empties the
`subagents` array of every entry (`index.md` also carries a
`Subagents excluded` row).

### faithful `metadata.json`

Same header keys, then product-specific: `"profile": "faithful"` always, plus
`"sanitize"` and the produced `"files"` list (the `.json` files + `index.md`).
No `sub`/`tool_output`/`reasoning`/`role`/`summary_diffs` — the faithful product
is the raw record and applies none of the display filters. The subagent
inclusion keys ARE present (`--no-subagents` drops the subagent `.json` files
and `index.md` carries the `Subagents excluded` row).

---

## 3. corpus.jsonl (memory)

One JSON object per root session (subagents ride inside), streamed line by line —
file order is the only record order. Key shape (`exportlib/memory.py`,
`memory_session_entry()`):

```jsonc
{
  "schema_version": 1,                   // bump on any breaking shape change; consumers pin to this
  "id": "ses_…", "title": "…", "slug": "…", "directory": "/…",
  "agent": "build",                      // or null
  "model": "anthropic/claude-…",         // always a plain string id, never a JSON blob
  "created": "…", "updated": "…",        // ISO-8601 UTC; "updated": null when never touched
  "cost": 0.0,
  "tokens": {"input": 0, "output": 0, "reasoning": 0,
             "cache": {"read": 0, "write": 0}, "backfilled": false},
  "parent_id": null,                     // null for roots
  "messages": 9, "tools": 4, "compactions": 1,   // counts are for the ROOT session only (subagents excluded)
  "first_user": "…", "last_assistant": "…",
  "compaction_digests": [{"created": "…", "text": "…"}],
  "todos": {"open": [{"content": "…", "status": "pending", "priority": 0,
                      "position": 0, "created": "…", "updated": "…"}],
            "done": ["…"]},             // "open" = in-flight list, "done" = completion record
  "files": ["src/a.py"],                 // R?, only with --files
  "subagents": [{"id": "ses_…", "title": "…", "agent": "…",
                 "directory": "…", "created": "…"}]    // R? when present
}
```

Field notes:

- `schema_version` — bump to `2` etc. on any incompatible shape change; RAG
  pipelines key on it to re-ingest.
- `slug` — short, stable machine id of the session (e.g. `alpha-alpha`),
  distinct from `title`.
- `model` — normalized by `model_str()`: if the DB value is a JSON object
  (`{"id":…,"provider":…}`) only the `id` is emitted; otherwise the string is
  kept as-is. One form, always.
- `created`/`updated` and `compaction_digests[].created` / `todos` timestamps are
  ISO-8601 UTC; absent → `null`.

### Consuming `corpus.jsonl` (RAG, claims, supersession)

`rag` is **not** a separate artifact: it is a named **preset** whose content is
`{"product": "memory"}` (`presets.json`), so `export rag` and `export memory`
produce the **same** `corpus.jsonl`. Nothing here needs a change to be consumed —
this section is the contract for *other tools*.

**Loading it.** Both artifacts are plain JSON and need no adapter:

- `corpus.jsonl` → one JSON object per line (`langchain_community.document_loaders.JSONLinesLoader`).
- `<stamp>/faithful/…/<title>.json` → one document per session (`JSONLoader` with a `jq_schema`).

**What the corpus is, and what it is not.** Each entry is a **summary of one root
session** (the goal, the outcome, the compaction digests, the counts, the touched
files) — it is **lossy** and is neither a transcript nor a claim store. The
lossless source of truth is the `faithful` archive, which carries the whole session
(messages and `part.data` verbatim). A consumer that needs facts *inside* a
conversation reads `faithful`; a consumer that only needs to *locate* the session
(which chat, which project, which files, when) reads the corpus.

**Mapping to a claim/supersession store** (e.g. [`consolidation-memory`](https://github.com/charliee1w/consolidation-memory),
which models `episodes` as evidence and `claims` as reusable beliefs with drift
detection, `as_of` time queries and `namespace/project/app/agent/session` scopes):

| consolidation-memory | comes from `corpus.jsonl` |
|---|---|
| episode (per root) | one JSON line |
| scope `project` | `directory` |
| scope `agent` | `agent` |
| scope `session` | `id` (`parent_id` for the subagent relation) |
| scope `namespace` | the export itself (global / one source) |
| **file anchors** (for drift) | `files` — present only with `--files` |
| time axis (`as_of`) | `created` / `updated` / `compaction_digests[].created` |
| **claims / supersession / drift** | **NOT in the corpus** — this is the consumer's job |

The corpus deliberately stops at *evidence*: it keeps no claim identity
(subject/relation/object), no "old value superseded" state and no drift events.
Extracting claims is a write-side, LLM-assisted step (the consumer's), and the
**faithful archive is its evidence source** while the corpus is its index.

**Provenance.** It already lives at the **run** level, not per line: each run's
`metadata.json` records `db`, `db_sha256`, `date`, `preset`, `selection` and
`session_records`, and the enclosing directory name is the run's `stamp`. A
consumer that keeps a corpus together with its `metadata.json` (and the `stamp`)
knows exactly where every line came from, so no per-line provenance field is added
(the corpus carries only `schema_version` to pin the shape).

---

## 4. Faithful JSON archive (the `faithful` product)

One `<stamp>/faithful/01-<title>_<id>/<title>.json` per root session (subagents
under the same folder's `subagents/<sub>_<id>.json`). Native shape,
mirrors `{info, messages:[{info, parts}]}` (see `exportlib/faithful.py`):

```jsonc
{
  "info": {
    "id": "ses_…", "title": "…", "slug": "…", "projectId": "…", "directory": "/…",
    "agent": "build",                          // or null
    "model": "anthropic/claude-…",             // plain string id (model_str), never a JSON blob
    "time": {"created": "…", "updated": "…"},  // ISO-8601 UTC
    "parentId": null,                          // null for roots
    "tokens": {"input": 0, "output": 0, "reasoning": 0,
               "cache": {"read": 0, "write": 0}, "backfilled": false},
    "cost": 0.0, "compactions": 1
  },
  "messages": [{
     "info": {"id": "ms-…", "role": "user", "mode": null, "agent": null,
              "time": {"created": "…", "updated": "…"}},
     "parts": [ {"type": "text", "text": "…"}               // part.data as-is
                // tool: {"type":"tool","state":{"input":{...},"output":…}}
                // reasoning / file / step-start / step-finish / patch / compaction
     ]
  }]
}
```

Part records keep `part.data` verbatim; only quoted/escaped where sqlite raw
dumps require it. `tokens.backfilled` flags summed-from-step-finish sessions.
Absent `agent`/`mode`/`parentId` are `null`.

`info.compactions` counts the **markers** (as in `metadata.json`); there is no
`info.digests` count because the digests are not summarised here — they are in the
archive itself, as the message whose `info.mode = 'compaction'` with its `text` part.
A consumer that wants the number counts those messages.

This archive is the **lossless evidence source** for extraction pipelines; the `memory`
corpus indexes the same run — see *Consuming `corpus.jsonl`* under §3.

---

## 5. Backup manifest.json

`$OCED_BACKUP_DIR/manifest.json` — atomic `jq` update after each backup:

```json
{"backups": [ { "date": "YYYY-MM-DDTHH:MM:SSZ", "file": "opencode-<stamp>.db[.gz]",
                "sha256_raw": "…", "sha256": "…",
                "size_raw": 123456, "size": 45678,
                "sessions": 6, "messages": 21, "parts": 140,
                "max_updated": "…",              // newest session time_updated (UTC)
                "source": "/…/opencode.db" } ]}
```

`sha256_raw`/`size_raw` refer to the un-gzipped snapshot; `sha256`/`size` to the
stored file (identical when `OCED_COMPRESS=0`).

The **pre-shrink safety copy** `shrink --swap` takes before replacing the live DB
is a special, always-refreshed backup stored as a SINGLETON under `.pre_shrink`
(never inside `.backups`, so `prune`/`[delete all]` can never drop it by count):

```json
{"backups": [ … ],
 "pre_shrink": { "date": "YYYY-MM-DDTHH:MM:SSZ", "file": "pre-shrink/opencode.pre-shrink-<epoch>.db",
                 "kind": "pre-shrink", "sha256": "…", "sha256_raw": "…",
                 "size": 123456, "size_raw": 123456,
                 "sessions": 6, "messages": 21, "parts": 140,
                 "max_updated": "…", "source": "/…/opencode.db" }}
```

It is refreshed on every successful `--swap` (the previous `.pre_shrink` entry is
replaced; the old file is removed), so exactly one exists while it exists. It
belongs to the **shrink domain**: `shrinks preshrink` shows its details + sha256
check + freshness, `shrinks preshrink remove` deletes the file and clears the
singleton, and `--from-backup pre-shrink/<file>` resolves it read-only. It does
NOT appear in `backups list`/`view`/`verify`/`remove` nor in the backups picker;
`prune` ignores it. A `.pre_shrink` with no matching file on disk is reported by
`shrinks preshrink` as `MISSING`.

---

## 5b. shrink-presets.json — `$OCED_SHRINK_PRESETS`

Named shrink **recipes**, the source of truth for `opencode-db shrink <name>` and the
shrink menu's recipe step (the picker's rows are exactly these recipes, plus the
built-ins; picking one goes straight to the read-only plan). Defaults to
`~/.config/opencode-db/shrink-presets.json` if present, else the repo-shipped
`shrink-presets.json` in a portable checkout. Authoritative machine schema:
[`generated/shrink.schema.json`](../generated/shrink.schema.json) (draft-07). **The
schema and the per-key tables are generated from `src/shrinklib/flags.py`**
(mirror of §1; same generator `scripts/generate_schema.py`).

A recipe is split in **two disjoint families** (see
[`generated/shrink-flags-table.md`](../generated/shrink-flags-table.md)):

- **session SELECTION** — `keep` / `older_than` / `since` / `keep_all` /
  `keep_sessions` / `discard_sessions`: **CLI flags only**, never recipe keys. The
  menu asks for them with its sessions picker (root sessions, `[x]` = survive) and
  forwards `--keep-all` / `--discard-sessions`; headless users pass them directly.
  Exactly ONE applies (`keep` = 10 is the default).
- **OPERATIONS** — today only `strip_reasoning`: what is done to the copy besides
  the pruning. These are the **operation keys** of a recipe.
- **`description`** — an optional human one-liner (string) for the picker row /
  `--list-presets` tag / the `Recipe:` line of the plan. It travels **with the
  recipe** (the built-ins carry it in code, a file recipe carries its own); a
  recipe without one simply shows no prose. It configures nothing.

The built-in recipes **always exist** — `lean` (strip reasoning) and `quiet`
(prune + vacuum) — and the file *extends/overrides* them (a file recipe with the
same name shadows the built-in). A missing/empty file simply means "built-ins only".


An empty object is legal (no operation = just prune + vacuum). A keep rule inside a
recipe is **rejected** with a pointer to the matching CLI flag, unknown keys fail
(`additionalProperties: false`), and `strip_reasoning` must be a boolean.
`opencode-db shrink --list-presets` shows the *effective* set (built-ins + file).
Bake: `shrink <name>` → the operation flags only (`shrinklib/plan.py bake`), and they
are **prepended**, so an explicit selection flag still wins (`shrink lean --keep 3`).
The menu resolves its operation rows, descriptions and baked flags from
`shrinklib/plan.py` (`rows`/`descr`/`bake`/`ops-flags`/`op-lines`) — no jq in menu.sh,
and it never derives a selection from a recipe.

---

## 6. shrink.json

`$OCED_BACKUP_DIR/shrink/<stamp>/shrink.json` (written only when a real run
finishes; `--dry-run` writes nothing):

```jsonc
{
  "tool": "opencode-db/shrink", "date": "…", "source": "/…/opencode.db",
  "stamp": "YYYY-MM-DD_HH-MM-SS", "criteria": "keep the 10 most recent session(s) + strip reasoning",
  "selection": {"rule": "keep", "value": 10},
                       // the rule that produced the run: keep|older_than|since|keep_all|
                       //   keep_sessions|discard_sessions; scalar rules carry "value",
                       //   session rules carry "ids": ["ses_…", …] (the rule/ids shape
                       //   shrinklib/plan.py emits for the menu); a discard ALSO carries
                       //   "cascade": ["ses_…", …] = the listed ids closed over their
                       //   descendants — what `shrinks verify` re-checks later (the live
                       //   DB may no longer have them after --swap)
  "discard_exported": "20261006-150000"[,   // R?: the stamp of the newest export run whose
                       //   .sessions_selected EQUALS the discarded cascade (order-insensitive);
                       //   auto-detected by o_shrink_discard_export after a discard run,
                       //   absent when no run matches — never a hand-written key
  "sessions": {"total": 20, "kept": 10, "deleted": 10, "max_updated": 1790293022000},
                       // max_updated = the copy's newest session time_updated (ms epoch);
                       // 0 only for a pre-max_updated legacy shrink.json
  "size": {"before": 123456, "after": 45678},
  "integrity_check": "ok", "foreign_key_check": 0,
  "removed": {"message": 5, "part": 60, "todo": 3, "event": 2, "event_sequence": 2},
                       // per-table: message/part/todo/session_message/session_share/
                       //   session_context_epoch/session_input/event/event_sequence
  "removed_total": 70,
  "stripped_reasoning": 4,
  "file": "opencode.shrunk.db"
}
```

Keep rules (`oced_shrink`, last one wins — exactly ONE applies):

| Rule | Keep-set in the pruned copy | `.selection` |
|---|---|---|
| `--keep N` *(default 10)* | the N most recent sessions | `{"rule":"keep","value":N}` |
| `--older-than DAYS` | sessions updated within the last DAYS days | `{"rule":"older_than","value":DAYS}` |
| `--since DATE` | sessions updated since DATE | `{"rule":"since","value":"DATE"}` |
| `--keep-all` | all sessions (strip/vacuum only) | `{"rule":"keep_all"}` |
| `--keep-sessions ID[,ID]` | the listed ids **+ their parents/subagents** (closed set) | `{"rule":"keep_sessions","ids":[…]}` |
| `--discard-sessions ID[,ID]` | everything except the listed ids **+ their subagents** (the discard set is descendant-closed, FK-safe by construction); the closed set is stored as `.selection.cascade` | `{"rule":"discard_sessions","ids":[…],"cascade":[…]}` |

`--strip-reasoning` also drops every `part` whose `data` JSON has `type=reasoning`
(kept set unchanged). `--discard-sessions` prints a first-step hint to
`opencode-db export <profile> --sessions <cascade>` so the knowledge is preserved
before the pruned copy is made. The hint lists the **cascade** (the selected ids plus
every descendant that travels with them), because `--sessions` matches exact ids and
the discard set does not. `<profile>` is `$OCED_SHRINK_DISCARD_EXPORT_PROFILE`
(default `archive`); an unknown value is reported with the valid product/preset names
and falls back instead of failing inside the export. A profile that would NOT preserve
the subagents of that cascade (`no_subagents`, `no_orphan_subagents`, `sub: omit`) is
warned about on screen first — `roots/subagents/total` cannot distinguish "exported with
its subagents" from "exported without them" in a way the user asked for, and both look
identical in `metadata.json`.

When the cascade export is actually done before the shrink (the hint command, or the
menu's offer), the run records it: `shrink.json.discard_exported` = the stamp of the
newest export run whose `metadata.json`.`sessions_selected` list is exactly the
discarded cascade (any order); the run notes `(recorded: the cascade export is <stamp>
— see: opencode-db shrinks view <stamp>)` and `shrinks view` prints the
`discard export:` line. The key is absent when no matching run exists — a discard
without the export is fully valid, it just stays unlinked. The closed set itself is
stored regardless (`.selection.cascade`): it is the evidence `shrinks verify` asks
about later, when the live DB may no longer hold the sessions.

The same closed keep-set is used to derive deleted counts. `--swap` additionally
snapshots the live DB to `$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink-<ts>.db`
(WAL-safe, newest-copy-only auto-cleanup) and performs the atomic swap — the one
opt-in path that ever writes the live DB. `shrinks verify [--tsv] [--yes]` checks
for orphan run dirs, old pre-shrink copies, the freshness of **every** copy vs
the live DB (or unverifiable: a legacy shrink.json without `sessions.max_updated`
is always flagged; the TTL rule is re-run-shrink-before-swap whenever opencode was
used in between), and **discard-export coverage**: every copy whose rule is
`discard_sessions` with sessions deleted must have an export run covering its
`.selection.cascade`.

Freshness is asked **once per run**, never once for the newest: a stale answer for
`runs[0]` left every older copy unverified, which is the one thing a copy shelf
needs to know. The `--tsv` rows are `type<TAB>key<TAB>display`:

| row | key | when |
|---|---|---|
| `orphan` | the run dir | no valid `shrink.json` |
| `preshrink` | the file name | an old `pre-shrink` copy |
| `stale` | **the copy's stamp** | that copy is stale or unverifiable vs the live DB |
| `unexported` | **the copy's stamp** | its discarded cascade has no covering export run |

Coverage (`o_shrink_unexported <shrink.json>`, the sibling of `o_shrink_stale`,
asked only by `verify`) is a **live** re-check: the stored cascade is matched
against the exports shelf at verify time, so an export made AFTER the shrink
clears the flag and one removed with `exports remove` brings it back. A root-only
export of the same root is a different set and never clears it (order-insensitive
equality, the same `o_shrink_discard_export` the engine links with). A legacy
copy has no cascade to re-check: only the stamp it DID record can condemn it
(`discard_exported` pointing at a vanished run is flagged; a live one is not) and
no record at all is never a false charge. A `--keep` run is out of scope by
construction — its json carries no cascade — so a non-discard copy is never
flagged.

An orphan dir is reported **once**, as an orphan: it is never also a `stale` or
`unexported` row (`o_shrink_stale` would answer "shrink.json missing" for it,
which would count the same broken dir twice).

---

## 7. exports list

`exports list` aggregates every `metadata.json` under a stamp directory:

```
  N.  <YYY-MM-DD HH:MM UTC>  <profiles joined '+' +, order = dir sort>  <K/N kept | N> · <R root S sub> · <msgs> msgs · <comp> comp · <size>[(<tag>)][ refreshed <date> (<mode>)]
```

roots/subagents = max across metadata files, msgs/comp = sum (comp = the
`compactions` **markers**), size = du of the stamp dir; a run with no readable
metadata renders `profiles="?"`.

The SIZE cell replaces the old bare `<roots> roots (<subagents> subagent)`, which
alone hid how big the run really was (3 roots can be 3 sessions or 22). A **full** run
prints just `N · R root S sub`; a **narrowed** run (`.excluded` non-empty) prints
`K/N kept · R root S sub`, where `K` = `.session_records` length (or
`roots+subagents` when there are none) and `N` = `K + len(.excluded)` — the excluded
count is the difference `N - K`, so it is not repeated — so a `--sessions`
run can never be mistaken for a full one. The short root/sub breakdown always rides
along; the menu picker row uses the same cell, and marks a refreshed run
with ` ⟳` instead of the `<mode>` sentence the CLI keeps.

The two trailing decoration fields are both optional and answer two different
questions:

- `(<tag>)` is the **freshness** verdict from `o_export_stale … --tag`: `stale` (a
  recorded session was edited since the run), `missing` (a recorded session is gone
  from the live DB) or `unverifiable` (no `.session_records` — a legacy run). Absent =
  fresh.
- `refreshed <date> (<mode>)` names the refresh, read from `.update_mode`/`.date`. It
  exists because a refresh keeps the stamp, so without it a real update would read as
  "same run, same date".

`exports verify [--tsv]` audits every run against the SAME verdict (`--tsv` emits
`stamp<TAB>tag` rows). `exports update <stamp>` refreshes in place (see §5 of
`architecture.md` and the metadata subsection above).

`exports view <stamp>` is a **detail screen**, so it leads with a banner
(`== Export run: <stamp> ==`), then one summary line per product, the aggregate
`totals:`/`date:`/`db:`/`sha256:` block and a `== Details per product ==` section
with one field block per `metadata.json` (blank-line separated). Three rules worth
naming because the data shapes are not uniform:

- `selection:` is rendered by `util.selection_phrase()` from **`.selection`**, not
  from `.filter`/`.sessions_selected`: those two only describe a filter or an
  explicit id list, so a run selected by `--last N` would read as "all sessions" —
  flatly wrong in the screen whose whole job is to say what the run contains. Runs
  written before `.selection` existed are labelled `(legacy record)`. It is a
  **run-level** fact, so a bundle prints it once (read from the first product's
  metadata), not once per product.
- `.sessions_selected` is an **array**, never concatenated as a string (a `// "all"`
  default with no `join` breaks on real runs).
- `Sessions:` shows `total (roots · subagents)`; when a legacy run has no
  `.sessions.total` it is derived as `roots + subagents`. A field block prints only
  the keys its metadata actually has (`cap: 0`/`touched_files: false` were rendered
  for every transcript before), and the sessions a run contains come from
  `.session_records`.
- `scope:` (when `.scope` is present) is the wider set the run was drawn from, rendered
  by the **same** `util.selection_phrase()` that names `.selection` (a legacy run has no
  `.scope`, so the line is absent). It differs from `selection:` exactly when the run was
  narrowed — printing both is what makes the gap legible.
- `updated:` appears only on a refreshed run (`<mode> mode (refreshed in place)`),
  read from `.update_mode`; the `date:` above it is already the refresh time, so
  without the line the two are indistinguishable.
- `freshness:` is the same `o_export_stale` verdict as `list`/`verify`, spelled out:
  `fresh (…)`, `STALE — <reason>` or `unverifiable (no session_records recorded)`.
- A `== Excluded (N kept out of scope) ==` block follows `== Sessions ==` when
  `.excluded` is non-empty: `id + title` per left-out session, capped at 8 with `… N more`
  (like `shrinks view`). This is the run's own GAP — the reason a `--sessions` run is not
  a full export — and it is deliberately separate from the content.

`--json` returns one metadata record per product as a JSON array (the raw
`metadata.json` contents, no banner, no aggregation). Only the
human mode carries the header — a machine reader gets the data untouched.

## 8. shrinks list

`shrinks list --tsv` emits one TSV row per produced copy (the machine format the menu
picker consumes — same aggregation as `shrinks list`):

```
<stamp>\t<YYYY-MM-DD HH:MM:SS UTC>  <tag>  <kept>/<total> kept  <before> -> <after> -<pct>%  <state>
```

`<stamp>` is the run dir name (`YYYYMMDD-HHMMSS`, UTC); the tag comes from
`shrinklib/plan.py rule-tag` (the compact selection tag: `keep 1 newest`, `discard 2 ids +strip`,
etc.); `<kept>/<total> kept` is the session survival count; ONE size delta replaces the
three size fields the old format repeated; `<state>` is the copy's own state only when
anomalous (`(swapped/no copy)`). Numbers come from that run's `shrink.json` (see §6); size
fields are human-readable. Without `--tsv` the same row is printed numbered with a
`view <stamp> · remove <stamp> · prune <N>` footer.

A legacy `shrink.json` without `.selection` falls back to a 24-char cut of its `.criteria`
as the tag, so the column never empties.

---

## 9. shrinks view

`shrinks view <stamp> [--json]` is a **detail screen**, shaped like `exports view`:

**Human mode (default):** leads with `== Shrink copy: <stamp> ==` then one fact per line:

```
  sessions:   <total> total · <kept> kept · <deleted> deleted
  size:       <before> -> <after> (freed <freed>, -<pct>%)
  criteria:   <full criteria sentence from shrink.json>
  reasoning:  <n> part(s) stripped          # only when stripped_reasoning > 0
  date:       <ISO-8601 UTC from shrink.json>
  db:         <source path from shrink.json>
  integrity:  <integrity_check> · foreign keys <foreign_key_check>
  freshness:  ok — nothing in the live DB is newer than this copy
              STALE — <reason from o_shrink_stale>
  ids (<n>):  ses_... (first 8)
              … N more (--json has all of them)
  removed:    <removed_total> row(s) total
    <table> <count>        # per-table removals, biggest first (only non-zero)
  files:
    opencode.shrunk.db   <human size>
    shrink.json          <human size>
```

- NO `selection:` line: the rule is already named in words by `criteria:` and the
  count opens `ids (<n>):` — `selection: <rule> · <n> id(s)` repeated the same
  fact a third time on one screen (`--json` keeps `.selection` untouched).
- The `criteria` sentence is the full parenthetical text from `shrink.json` — the list
  column only carries the compact tag (same fact, two formats).
- The `freshness` line is the **same check** `shrinks verify` uses (`o_shrink_stale`), so
  a detail screen can never show a copy nobody validated. A legacy shrink.json without
  `sessions.max_updated` prints `STALE — shrink.json has no sessions.max_updated; cannot verify freshness`.
- IDs are capped at 8 with `… N more`; the real count is the `ids (<n>):` header.

**Machine mode (`--json`):** returns `shrink.json` **verbatim**, byte for byte, no banner,
no aggregation. This is the contract the menu picker depends on.