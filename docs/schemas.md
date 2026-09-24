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
when the file exists). Authoritative machine schema: `presets.schema.json`
(draft-07). Runtime validation in `exportlib/presets.py` must stay in sync with
that schema.

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

| Key | Type | Allowed | Applies |
|---|---|---|---|
| `product` | string | `transcript` \| `memory` \| `compactions` | single only (`full` is a CLI alias, **not** a preset product) |
| `products` | object | keys restricted to the 3 products | bundle only (exclusive with `product`) |
| Product flags (top level for single, per product for bundle): | | | |
| `filter` / `sessions` | string / string[] | — | selection (shared; exclusive, `not` both) |
| `sub` | string | `separate` \| `inline` \| `omit` | transcript |
| `tool_output` | string | `full` \| `truncated` \| `omit` | transcript |
| `tool_input_limit` / `tool_output_limit` | int ≥ 0 | — | transcript |
| `patch` | string | `full` \| `omit` | transcript |
| `role` | string | `all` \| `user` \| `assistant` | transcript/compactions |
| `no_reasoning` / `mark_compactions` / `summary_diffs` | bool | — | transcript/compactions |
| `json` | bool | — | transcript/compactions (faithful archive) |
| `sanitize` | bool | — | any |
| `files` | bool | — | memory (touched files) |
| `cap` | int ≥ 0 (0 = unlimited) | — | memory |

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

## 6. shrink.json

`$OCED_BACKUP_DIR/shrink/<stamp>/shrink.json` (written only when a real run
finishes; `--dry-run` writes nothing):

```jsonc
{
  "tool": "opencode-db/shrink", "date": "…", "source": "/…/opencode.db",
  "stamp": "YYYY-MM-DD_HH-MM-SS", "criteria": "keep the 10 most recent session(s) + strip reasoning",
  "sessions": {"total": 20, "kept": 10, "deleted": 10},
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

Recipes (`oced_shrink`):

| Recipe | Keep-set | strip-reasoning |
|---|---|---|
| *(default)* | `--keep 10` most recent | no |
| `lean` | `--keep 10` | yes |
| `recent` | `--older-than 90` | no |
| `full` | all sessions | yes |
| `bare` | `--keep 10` | no (alias of default) |

The same closed keep-set is used to derive deleted counts. `--swap` additionally
snapshots the live DB to `…pre-shrink-<ts>` (a real `opencode-db/backup` run) and
records it through the backup manifest, then performs the atomic swap — the one
opt-in path that ever writes the live DB.

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