# Export guide — what do I export when?

> User-facing counterpart of the design docs. `opencode-db export` turns your opencode
> sessions into documents. There are **three products** (what a document is) and
> **named plans** (a product or a bundle of products plus its configuration).
> If you are unsure, start with the **decision matrix** at the end.

## 1. The three products

### `transcript` — "read, share, audit" (the human document)

What it produces: one Markdown file per session (and per subagent, `--sub separate`)
with the **whole conversation**: your messages, the assistant answers, the model's
reasoning, every tool call (command + arguments + its output), the code/patch diffs,
and the compaction summaries **inline** where they happened. A per-run `index.md`
lists all sessions; with `--json` an additional **faithful archive** (the native
opencode message shape) is written next to each Markdown file.

Sizing: **the heavy product** — it grows with every tool output you kept. By default
tool outputs are **truncated** to ~500 chars; `--tool-output full` keeps everything
(and can multiply the size several times), `--tool-output omit` drops them.

Use it when you want to *read* what happened, *verify* that opencode did what you
asked (the tool calls + patches are the evidence), *search* it with any text tool, or
*share* a session with a colleague.

### `memory` — "feed another AI" (the machine corpus)

What it produces: `corpus.jsonl` — one **JSON line per root session** (subagents ride
inside their parent), streamed as it is written. Each line carries the machine facts
you want to give a second AI: metadata (model, directory, creation/update, tokens,
cost), the **first ask** and the **last answer**, the list of tools used, remaining
todos, and **all compaction digests** (the durable knowledge of the conversation).
`--files` adds the list of files touched.

Sizing: **light, compact** — summaries, not full text.

Use it when you want to *give context to another AI* (RAG: index it, search it,
ingest a summary of yesterday's work), or when you want a terse *inventory* of what
each conversation produced. Not for human continuous reading.

### `compactions` — "quick knowledge review" (the digest-only extract)

What it produces: one Markdown file per session with **only the compacted-context
summaries** — what opencode "remembered" each time the conversation was compacted.

Sizing: **very small**.

Use it when you want to see, in one glance, the *knowledge arc* of a session (which
threads/objectives got consolidated) without reading the whole transcript. **Note:**
the same digests are already inside `transcript` (inline) and `memory`
(`compaction_digests`); the standalone product is a convenient extract, not new
information — it is redundant when you are exporting either of the others.

## 2. Manual run vs named plans

Products run, by default, with their plain defaults:

| | default |
|---|---|
| tool output | truncated (~500 chars) |
| subagents | separate files |
| patches / reasoning | included |
| faithful `--json` | off |
| sessions | **all** (or `--filter` / `--sessions` to narrow) |

The menu's `Manual…` uses exactly these defaults. To repeat a configured combination
again and again (and to run **several products under one stamp**) define a **plan** in
`~/.config/opencode-db/presets.json` (created from `presets.json.example` at install;
schema documented in `docs/schemas.md` and machine-checkable in
`presets.schema.json`).

The **shipped plans** are named after their purpose:

| plan | products | purpose | relative size |
|---|---|---|---|
| `archive` | transcript (`tool_output full` + `json`) + memory (`files`) | **lossless backup**: everything, complete tool outputs + faithful JSON + file lists | heavy |
| `quick` | transcript (`tool_output truncated` + `json`) + memory (`files`) | **light daily review**: the same backup without the bulky tool outputs | medium |
| `share` | transcript (`json` + `sanitize` + `no_reasoning`) | **publish transcript (best-effort redaction)**: sanitized, no reasoning, faithful JSON | medium |
| `notes` | transcript (defaults) | **read conversation**: plain transcript, nothing extra | light |
| `rag` | memory (defaults) | **feed another AI**: corpus with default options | light |
| `digest` | compactions (defaults) | **knowledge arc**: just the compaction summaries | tiny |

Sizing is DB-dependent: `archive` can easily be 10× `quick` on the same sessions, and
`quick` ~4× the plain manual transcript. Delete runs you no longer need with
`opencode-db exports remove <stamp>`.

## 3. The menu flow, step by step

```
opencode-db menu  →  Export
```

1. If the presets file exists you see your **plans** (each labeled with its purpose)
   plus `Manual…`; without it, the session picker opens directly.
2. Pick a **plan** → you are asked **which session or ALL SESSIONS**:
   - `ALL SESSIONS` = run the plan exactly as configured (its embedded selection
     applies);
   - **one session** = run the plan for that session only (a shared `--filter`
     override for every product in the plan).
3. A plan confirmation shows Source / Filter / Profile / Spec / Output — accept it.
4. The run lands in `~/.local/share/opencode-db-exporter/exports/<stamp>/` with one
   subfolder per product (`transcript/`, `memory/`, …) and all sessions aggregated by
   `opencode-db exports list|view`.

Without a presets file, the classic session → product flow with defaults remains
(`Manual…` is the no-presets fallback). Tuning and multi-product runs belong to the
presets file (plans) or to the CLI flags. ESC always climbs back / cancels.

## 4. Decision matrix

| I want to… | use | notes |
|---|---|---|
| keep a lossless backup of everything | `export archive` | complete tool outputs + faithful JSON + corpus |
| review what I did today, fast | `export quick` | light, readable transcript + corpus |
| send a session to a colleague / paste in an issue / publish | `export share` | sanitized, no reasoning; **verify output before sharing (sanitize is best-effort)** |
| read a conversation plain | `export notes` | plain transcript defaults, nothing extra |
| give another AI the context of my sessions (RAG) | `export rag` | corpus.jsonl with defaults; add `--files` for touched files |
| skim the "knowledge arc" of a session | `export digest` | just the compaction summaries (also in transcript + memory) |
| give another AI the context of my sessions (RAG) | `export memory` | corpus.jsonl; add `--files` for touched files |
| read one conversation in full | `transcript` (manual/CLI) | add `--json` if you also want the faithful archive |
| audit what opencode actually ran | `transcript` + `--tool-output full` `--patch full` | evidence = tool calls + diffs |
| skim the "knowledge arc" of a session | `compactions` | also available without exporting: `opencode-db info <id>` / `opencode-db compactions <id> show` |
| narrow a run to a project/session | `--filter 'Project X'` or `--sessions ses_…` | also the menu's session picker / plan override |
| export from a stored backup instead of the live DB | `--from-backup <file>` | every read command honors it |

## 5. Precedence and safety

- Environment > conf file > defaults for paths/options; **the CLI wins over a plan**
  (`opencode-db export archive --filter ses_X` overrides the plan's selection; an
  explicit flag overrides the plan's value).
- The DB is always opened **read-only**; exports never mutate opencode data. The only
  path that writes the live DB is the opt-in `shrink --swap`.
- Every machine artifact carries a `db_sha256` so you can correlate an export with the
  exact snapshot that produced it.
- **`--sanitize` is best-effort**: it redacts known secret patterns (sk-, ghp_, Bearer,
  JWT, PEM, key=value…) but is not a guarantee; always review the output before
  sharing.