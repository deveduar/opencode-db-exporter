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
    "digest": { "product": "compactions" }
  }
}
```

> Per-key rules table (generated, checked in): [`generated/flags-table.md`](../generated/flags-table.md)
> — regenerate with `python3 scripts/generate_schema.py --docs`; do not edit by hand.
> Summary of the non-obvious rows:

| `product` | string | `transcript` \| `memory` \| `compactions` | single only (`full` is a CLI alias, **not** a preset product) |
| `products` | object | keys restricted to the 3 products | bundle only (exclusive with `product`) |
| `filter` / `sessions` | string / string[] | — | selection (shared; exclusive, `not` both) |
| `json` | bool | — | transcript/compactions (faithful archive) |
| `snapshot` | string | `"fresh"` | **single preset only** (never per-product/bundle): coordinate the export + the reference backup — CLI warns, menu offers a fresh backup, when no backup exists or the last one diverged from the live DB |
| `out` | string | — | CLI-only (never a preset key) |

Unknown keys fail (`additionalProperties: false`). Flags that a product ignores are
harmless. CLI overrides win: an explicit `--filter`/`--sessions` voids the whole
preset selection; any explicit flag beats the preset value per product.

**Selection is run-time state** (menu). A preset is a *plan*: its embedded
`filter`/`sessions` makes it automatable, but in the menu the selection is asked
*after* picking the plan — `ALL SESSIONS` runs it as configured, picking one session
adds `--filter <ses>` (identical to the CLI override above, shared by every product of
a bundle). `Manual…` is the ad-hoc raw-flags path with defaults. Therefore a plan
never "owns" its selection: `setup_cli` clobbers it only when no explicit CLI/selection
is given.

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

### transcript / compactions `metadata.json`

```jsonc
{
  "tool": "opencode-db/exportlib", "version": "0.x.0",
  "date": "YYYY-MM-DDTHH:MM:SSZ",
  "db": "/…/opencode.db", "db_sha256": "…",
  "filter": null,                       // or SQL LIKE pattern
  "sessions_selected": null,            // or ["ses_…", …]
  "profile": "transcript",              // product keyword: transcript | memory | compactions (never a preset name)
  "preset": "archive",              // R?: preset/plan name that produced this run, else null
  "sub": "inline", "tool_output": "full", "reasoning": true, "summary_diffs": false,
  "json": false, "sanitize": false, "role": "all",
  "tokens_backfilled": 0,               // number of sessions whose token/cost rows were summed from step-finish parts
  "sessions": {"total": 6, "roots": 1, "subagents": 5},
  "compactions": 2, "messages": 21,
  "last_backup": {"file": "…", "date": "…"},   // R?: latest entry of the backup manifest, else null
  "files": ["transcript/index.md", "transcript/ses_….json"]
}
```

### memory `metadata.json`

Same header keys, then product-specific: `"profile": "memory"` always, plus
`"cap"`, `"touched_files"` (bool; whether the `--files` key was requested for the
corpus) and `"files": ["corpus.jsonl", "index.md"]` (the produced files — same
shape as the transcript `files` list). No `sub`/`tool_output`/`reasoning`/
`summary_diffs`/`json`.

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

## 4. Faithful JSON archive (transcript/compactions `--json`)

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
`opencode-db export memory --sessions <ids>` so the knowledge is preserved before
the pruned copy is made.

The same closed keep-set is used to derive deleted counts. `--swap` additionally
snapshots the live DB to `$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink-<ts>.db`
(WAL-safe, newest-copy-only auto-cleanup) and performs the atomic swap — the one
opt-in path that ever writes the live DB. `shrinks verify [--tsv] [--yes]` checks
for orphan run dirs, old pre-shrink copies, and a last shrink that is stale vs the
live DB (or unverifiable: a legacy shrink.json without `sessions.max_updated` is
always flagged; the TTL rule is re-run-shrink-before-swap whenever opencode was
used in between).

---

## 7. exports list

`exports list` aggregates every `metadata.json` (legacy `metadatos.json`
accepted) under a stamp directory:

```
  N.  <YYY-MM-DD HH:MM UTC>  <profiles joined '+' +, order = dir sort>  <roots> roots (<subagents> subagent) · <msgs> msgs · <comp> comp · <size>
```

roots/subagents = max across metadata files, msgs/comp = sum, size = du of the
stamp dir; a run with no readable metadata renders `profiles="?"`. `exports view
<stamp>` prints the `date`/`profile`/`sessions`/`messages`/`compactions`/`db`/
`db_sha256` line from the first metadata file found.

## 8. shrinks list

`shrinks list --tsv` emits one TSV row per produced copy (the machine format the menu
picker consumes — same aggregation as `shrinks list`):

```
<stamp>\t<YYYY-MM-DD HH:MM:SS UTC>  <criteria>  <kept> sess / <deleted> del  <before> -> <after> (<freed>, <pct>%)  <copy or (swapped/no copy)>
```

`<stamp>` is the run dir name (`YYYYMMDD-HHMMSS`, UTC); numbers come from that run's
`shrink.json` (see §6); size fields are human-readable. A run whose `opencode.shrunk.db`
was moved out by `--swap` renders `(swapped/no copy)`. Without `--tsv` the same row is
printed numbered with a `view <stamp> · remove <stamp> · prune <N>` footer.