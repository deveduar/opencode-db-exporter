# opencode-db-exporter — schemas & contracts

Consolidated reference of every persistent artifact this tool reads or writes.
Runtime rule: **the live opencode DB is never written** — every read goes through
`file:$DB?mode=ro` (`sqlite3` in bash, `uri=True` in python). The one deliberate,
opt-in exception is `shrink --swap`, which snapshots the live DB first and swaps
in the pruned copy atomically (§6). This file is the human-readable contract;
JSON-serializable artifacts have machine-checkable schemas where noted.

Dates are always **ISO-8601 UTC** (`YYYY-MM-DDTHH:MM:SSZ`, epoch ms converted via
`ts_iso`). Absent values are `null` (never `""`) in machine artifacts
(`corpus.jsonl`, faithful `--json` archives, `metadata.json`); `""` only appears
in human markdown rendering.

Legend: `R?` = optional key.

---

## 1. presets.json — `$OCED_PRESETS`

Source of truth for `opencode-db export <name>` and the export menu (preset-first
when the file exists). Authoritative machine schema: [`generated/presets.schema.json`](../generated/presets.schema.json)
(draft-07). **The schema and the per-key table are generated from
`modules/exportlib/flags.py`** (flags = the single source of truth; see
`scripts/generate_schema.py`, output in [`generated/`](../generated/)). Runtime
validation in `exportlib/presets.py` imports the same key lists, so everything stays
in sync by construction.

```jsonc
{
  "presets": {
    "archive": {
      "products": {                       // bundle: one stamp, one index.md per product
        "transcript": { "json": true, "tool_output": "full" },  // per-product flags only
        "memory":     { "files": true }
      },
      "filter": "ses_f7%",                 // optional shared selection: filter (SQL LIKE)…
      "sessions": ["ses_…", "ses_…"]      // …or exact ids — never both
    },
    "quick": {
      "products": {
        "transcript": { "json": true, "tool_output": "truncated" },
        "memory":     { "files": true }
      }
    },
    "share": {
      "product": "transcript",            // single product: name resolves first
      "json": true, "sanitize": true, "no_reasoning": true
    },
    "notes": { "product": "transcript" },
    "rag":   { "product": "memory" },
    "digest": { "product": "digest" }
  }
}
```

> Per-key rules table (generated, checked in): [`generated/flags-table.md`](../generated/flags-table.md)
> — regenerate with `python3 scripts/generate_schema.py --docs`; do not edit by hand.
> Summary of the non-obvious rows:

> **The `product` / `products` values are `transcript` \| `memory` \| `digest`** and
> nothing else: `full` is a CLI alias of `transcript` and `compactions` is a deprecated
> alias of `digest` (both are normalised at resolve time, so a run records `digest`).
> This table restates the non-obvious rows of the generated one; it is a summary, the
> generated file is the contract.

| `product` | string | `transcript` \| `memory` \| `digest` | single only (`full` is a CLI alias, **not** a preset product; `compactions` is the deprecated alias of `digest`) |
| `products` | object | keys restricted to the 3 products | bundle only (exclusive with `product`) |
| `filter` / `sessions` | string / string[] | — | selection (shared; exclusive, `not` both) |
| `json` | bool | — | transcript/digest (faithful archive) |
| `snapshot` | string | `"fresh"` | **single preset only** (never per-product/bundle): coordinate the export + the reference backup — CLI warns, menu offers a fresh backup, when no backup exists or the last one diverged from the live DB |
| `out` | string | — | CLI-only (never a preset key) |

Unknown keys fail (`additionalProperties: false`). Flags that a product ignores are
harmless. CLI overrides win: an explicit `--filter`/`--sessions` voids the whole
preset selection; any explicit flag beats the preset value per product.

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
<stamp>/                       transcript+memory bundle   <stamp>/               transcript bundle
  index.md                       (bundle tie-in)          also:  index.md
  transcript/index.md                                     (single product: one dir)
  transcript/metadata.json
  transcript/<session>.json     only with --json
  memory/index.md
  memory/metadata.json
  memory/corpus.jsonl
```

Legacy runs wrote `metadatos.json`; the tool still reads both names (`exports
list`/`view`, menu), so old run dirs keep aggregating.

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
  "profile": "transcript",              // product keyword: transcript | memory | digest (never a preset name)
  "preset": "archive",              // R?: preset/plan name that produced this run, else null
  "sub": "inline", "tool_output": "full", "reasoning": true, "summary_diffs": false,
  "json": false, "sanitize": false, "role": "all",
  "no_subagents": false,            // --no-subagents: subagents excluded from the set
  "no_orphan_subagents": false,     // --no-orphan-subagents: closed set (a subagent whose parent is not exported was dropped)
  "subagents_hidden": 0,            // how many subagents those two flags actually dropped from the MATCHED set
                                   // (0 for an exact --sessions selection: a subagent that was never selected cannot be dropped)
  "tokens_backfilled": 0,               // number of sessions whose token/cost rows were summed from step-finish parts
  "sessions": {"total": 6, "roots": 1, "subagents": 5},
  "compactions": 2, "digests": 2, "messages": 21,
  "last_backup": {"file": "…", "date": "…"},   // R?: latest entry of the backup manifest, else null
  "files": ["transcript/index.md", "transcript/ses_….json"]
}
```

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
`summary_diffs`/`json`. The subagent inclusion keys (`no_subagents`,
`no_orphan_subagents`, `subagents_hidden`) ARE present: memory folds each
subagent into its root's corpus line, so `--no-subagents` empties the
`subagents` array of every entry (`index.md` also carries a
`Subagents excluded` row).

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

---

## 4. Faithful JSON archive (transcript/digest `--json`)

One `<stamp>/<profile>/<session-id>.json` per root session. Native shape,
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

---

## 5. Backup manifest.json

`$OCED_BACKUP_DIR/manifest.json` — atomic `jq` update after each backup:

```json
{"backups": [ { "date": "YYYY-MM-DD_HH-MM-SS", "file": "opencode-<stamp>.db[.gz]",
                "sha256_raw": "…", "sha256": "…",
                "size_raw": 123456, "size": 45678,
                "sessions": 6, "messages": 21, "parts": 140,
                "max_updated": "…",              // newest message time_created (UTC)
                "source": "/…/opencode.db" } ]}
```

`sha256_raw`/`size_raw` refer to the un-gzipped snapshot; `sha256`/`size` to the
stored file (identical when `OCED_COMPRESS=0`).

---

## 5b. shrink-presets.json — `$OCED_SHRINK_PRESETS`

Named shrink **recipes**, the source of truth for `opencode-db shrink <name>` and the
shrink menu's recipe step (the picker's rows are exactly these recipes, plus the
built-ins; picking one goes straight to the read-only plan). Authoritative machine schema:
[`generated/shrink.schema.json`](../generated/shrink.schema.json) (draft-07). **The
schema and the per-key tables are generated from `modules/shrinklib/flags.py`**
(mirror of §1; same generator `scripts/generate_schema.py`).

A recipe is split in **two disjoint families** (see
[`generated/shrink-flags-table.md`](../generated/shrink-flags-table.md)):

- **session SELECTION** — `keep` / `older_than` / `since` / `keep_all` /
  `keep_sessions` / `discard_sessions`: **CLI flags only**, never recipe keys. The
  menu asks for them with its sessions picker (root sessions, `[x]` = survive) and
  forwards `--keep-all` / `--discard-sessions`; headless users pass them directly.
  Exactly ONE applies (`keep` = 10 is the default).
- **OPERATIONS** — today only `strip_reasoning`: what is done to the copy besides
  the pruning. These are the **only valid recipe keys**.

The built-in recipes **always exist** — `lean` (strip reasoning) and `quiet`
(prune + vacuum) — and the file *extends/overrides* them (a file recipe with the
same name shadows the built-in). A missing/empty file simply means "built-ins only".

```jsonc
{
  "presets": {
    "lean":      { "strip_reasoning": true },   // shadows the built-in lean
    "quiet":     {},                            // same as the built-in quiet
    "text-only": { "strip_reasoning": false }   // keep the reasoning parts
  }
}
```

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
                       //   shrinklib/plan.py emits for the menu)
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
| `--discard-sessions ID[,ID]` | everything except the listed ids **+ their subagents** (the discard set is descendant-closed, FK-safe by construction) | `{"rule":"discard_sessions","ids":[…]}` |

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

The same closed keep-set is used to derive deleted counts. `--swap` additionally
snapshots the live DB to `$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink-<ts>.db`
(WAL-safe, newest-copy-only auto-cleanup) and performs the atomic swap — the one
opt-in path that ever writes the live DB. `shrinks verify [--tsv] [--yes]` checks
for orphan run dirs, old pre-shrink copies, and the freshness of **every** copy vs
the live DB (or unverifiable: a legacy shrink.json without `sessions.max_updated`
is always flagged; the TTL rule is re-run-shrink-before-swap whenever opencode was
used in between).

Freshness is asked **once per run**, never once for the newest: a stale answer for
`runs[0]` left every older copy unverified, which is the one thing a copy shelf
needs to know. The `--tsv` rows are `type<TAB>key<TAB>display`:

| row | key | when |
|---|---|---|
| `orphan` | the run dir | no valid `shrink.json` |
| `preshrink` | the file name | an old `pre-shrink` copy |
| `stale` | **the copy's stamp** | that copy is stale or unverifiable vs the live DB |

An orphan dir is reported **once**, as an orphan: it is never also a `stale` row
(`o_shrink_stale` would answer "shrink.json missing" for it, which would count the
same broken dir twice).

---

## 7. exports list

`exports list` aggregates every `metadata.json` (legacy `metadatos.json`
accepted) under a stamp directory:

```
  N.  <YYY-MM-DD HH:MM UTC>  <profiles joined '+' +, order = dir sort>  <roots> roots (<subagents> subagent) · <msgs> msgs · <comp> comp · <size>
```

roots/subagents = max across metadata files, msgs/comp = sum (comp = the
`compactions` **markers**), size = du of the stamp dir; a run with no readable
metadata renders `profiles="?"`.

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

`--json` returns one metadata record per product as a JSON array (the raw
`metadata.json`/`metadatos.json` contents, no banner, no aggregation). Only the
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
  selection:  <rule> · <n> id(s)
  criteria:   <full criteria sentence from shrink.json>
  reasoning:  <n> part(s) stripped          # only when stripped_reasoning > 0
  date:       <ISO-8601 UTC from shrink.json>
  db:         <source path from shrink.json>
  integrity:  <integrity_check> · foreign keys <foreign_key_check>
  freshness:  ok — the live DB has no newer session than this copy
              STALE — <reason from o_shrink_stale>
  ids (<n>):  ses_... (first 8)
              … N more (--json has all of them)
  removed:    <removed_total> row(s) total
    <table> <count>        # per-table removals, biggest first (only non-zero)
  files:
    opencode.shrunk.db   <human size>
    shrink.json          <human size>
```

- The `criteria` sentence is the full parenthetical text from `shrink.json` — the list
  column only carries the compact tag (same fact, two formats).
- The `freshness` line is the **same check** `shrinks verify` uses (`o_shrink_stale`), so
  a detail screen can never show a copy nobody validated. A legacy shrink.json without
  `sessions.max_updated` prints `STALE — shrink.json has no sessions.max_updated; cannot verify freshness`.
- IDs are capped at 8 with `… N more`; the real count stays in `selection:`.

**Machine mode (`--json`):** returns `shrink.json` **verbatim**, byte for byte, no banner,
no aggregation. This is the contract the menu picker depends on.