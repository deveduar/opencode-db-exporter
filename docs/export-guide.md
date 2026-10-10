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

### `digest` — "quick knowledge review" (the digest-only extract)

What it produces: one Markdown file per session with **only the compacted-context
digests** — what opencode "remembered" each time the conversation was compacted.
(The old name `compactions` still works as a deprecated alias; `digest` is the real
one, because a *compaction* is the event and a *digest* is the summary written for
it — see the marker/digest table in [docs/schemas.md](schemas.md).)

Sizing: **very small**.

Use it when you want to see, in one glance, the *knowledge arc* of a session (which
threads/objectives got consolidated) without reading the whole transcript. **Note:**
the same digests are already inside `transcript` (inline) and `memory`
(`compaction_digests`); the standalone product is a convenient extract, not new
information — it is redundant when you are exporting either of the others.

## 1b. Subagents: include them or not (all products)

A **subagent** is a session that opencode spawned from another one (`parent_id`
set). Two things about them are independent:

| | flag | effect |
|---|---|---|
| **which subagents are in the export** | `--no-subagents` | drops every subagent, for **all three** products. A session whose parent is gone is *not* a subagent for this purpose (it is an orphan = a root), so it survives |
| **where a kept subagent is rendered** | `--sub separate\|inline\|omit` | transcript only: its own `subagents/` file, appended to the parent's file, or not rendered |

So a "roots only" export is just `opencode-db export notes --no-subagents`, and the
menu's **subagents switch** does it for you: while it reads `hidden`, the subagent
rows disappear and un-marking a session takes its subagents with it. While it reads
`shown`, a subagent is an ordinary row with its own mark, so un-marking its session
leaves it in — the confirmation then warns how many will be exported **standalone**
before you start, and points at `--no-orphan-subagents` to drop them instead.

The default is deliberately permissive, because "export just that one subagent" is a
real need: if you select a subagent **without** its parent, it is exported
standalone, promoted to a root (that is what a selection of exact ids means — a
subagent is only in the set if you asked for it). If you would rather have a *closed*
set, where a subagent never travels without its parent, add
`--no-orphan-subagents`: any selected subagent whose parent is not part of the export
is dropped instead.

## 2. CLI runs vs named plans

Products run, by default, with their plain defaults:

| | default |
|---|---|
| tool output | truncated (~500 chars) |
| subagents | included, in separate files |
| patches / reasoning | included |
| faithful `--json` | off |
| sessions | **all** (or `--filter` / `--sessions` to narrow; recency is `--last N` / `--since DATE` — both **CLI-only**, never plan keys) |

These are the defaults a plan that configures nothing inherits. To repeat a configured
combination again and again (and to run **several products under one stamp**) define a **plan** in
`~/.config/opencode-db/presets.json` (created from the shipped `presets.json` at install;
schema documented in `docs/schemas.md` and machine-checkable in
`generated/presets.schema.json`).

The **shipped plans** (exactly what the repo's `presets.json` contains) are named after
their purpose:

| plan | products | purpose | relative size |
|---|---|---|---|
| `archive` | transcript (`tool_output full` + `json`) + memory (`files`) | **lossless backup**: everything, complete tool outputs + faithful JSON + file lists | heavy |
| `quick` | transcript (`tool_output truncated` + `json`) + memory (`files`) | **light daily review**: the same backup without the bulky tool outputs | medium |
| `share` | transcript (`json` + `no_reasoning`) | **publish transcript**: faithful JSON, no reasoning. It does **not** redact — add `--sanitize` (best effort) yourself, and read the output before you publish | medium |
| `notes` | transcript (defaults) | **read conversation**: plain transcript, nothing extra | light |
| `rag` | memory (defaults) | **feed another AI**: corpus with default options | light |
| `digest` | digest (defaults) | **knowledge arc**: just the compaction summaries | tiny |
| `backup_then_full` | transcript (`snapshot: fresh` + `tool_output full`) | **archive-grade but safe to run any time**: offers a fresh backup first when the last one diverged from the live DB | heavy |
| `this_week` | transcript (pinned `filter "%2026-09%"`) | **sessions whose text matches that pattern**: edit the month before using it. The plan's own selection wins over your marks, and the confirmation says so | light |
| `one_session` | memory (pinned `sessions`) | **corpus of one session**: template — replace `ses_ONLY_THIS_ID` with a real id | light |

`--sanitize` is a **per-run** flag, deliberately not baked into `share`: it redacts
high-confidence prefixes only, and a plan that silently redacted part of the content
would promise a safety it cannot keep. See §5.

Sizing is DB-dependent: `archive` can easily be 10× `quick` on the same sessions, and
`quick` ~4× the plain CLI transcript. Delete runs you no longer need with
`opencode-db exports remove <stamp>`.

## 3. The menu flow, step by step

```
opencode-db menu  →  Export
```

1. **Session picker** — if the presets file exists, you see the session picker first.
   Sessions are listed with `[x]` marks (default: all marked). The header is one line of
   live state — `3/6 marked · newest first · ESC: back` (`· subagents hidden, never
   exported` is appended while the switch is hidden) — plus a caveat line when a
   switch has a consequence the rows cannot show. You can:
   - Toggle individual sessions with Enter
   - Use the two bulk rows: `mark all`, `unmark all`
   - Flip the sort with the `[*] newest first  →  old first` row (re-sorting keeps your marks)
   - Flip `subagents: shown → hidden` (hidden rows are not rendered, so they can never be marked nor exported)
   - Press `[>] choose the preset` to continue

   There are **no recency rows** (`last N`, `oldest N`, `last N days`): marking rows is
   for picking sessions, and a rule that re-evaluates on every run is a selection, not a
   marking. Ask for it on the CLI instead — `export transcript --last 5` (the N most
   recently used roots, plus their subagents) or `--since 2026-09-01` (every session
   updated on or after that date). Both are CLI-only and never preset keys.

   Without a presets file, it prints setup guidance and falls back to the raw CLI.

2. **Preset picker** — shows your named plans (each with its purpose tag). Pick one.

3. **Plan confirmation** — a flat, flush-left `-> Export plan` block. The header rows
   (`Source:`/`Preset:`/`Sessions:`/`Menu adds:`/`Output:`, plus `Note:` when the menu has
   one) come first; then each product gets its own line at the left margin with its
   description and effective flags on the lines below, a blank line between products, and
   an optional `-> Notes` block for the caveats. Nothing is bulleted, indented or nested,
   and every line wraps at 72 columns. The point of the `Sessions:` line is that
   it can never lie about what will be selected:
   - all marked + a preset that pins no selection → `all 6 sessions in the DB`
   - all marked + a preset that pins one (`filter`/`sessions`) → `filter "%…%" (from the
     preset) — your 6 marks are not used`, and the run is the plain `export <name>`
   - some unmarked → `the 2 sessions you marked (the menu overrides the preset: …)` and
     the run is `export <name> --sessions CSV`
   `Menu adds:` names only what the menu itself contributes, and with the subagents
   switch **hidden it adds no flag at all**: hidden subagent rows are never rendered, so
   they cannot be marked nor reach the CSV, and the run instead says
   `subagents cascaded from selected roots` (the marked roots are expanded to their full
   cascade before the `--sessions` override). Otherwise it reads `nothing`. It never
   repeats the preset's own config. `Note:` appears when a row cannot show the
   consequence: subagents that will be exported standalone, or a preset that already
   drops subagents (the switch cannot widen it).
   Accept to run, or ESC to go back and change sessions/preset.

4. The run lands in `~/.local/share/opencode-db-exporter/exports/<stamp>/` with one
   subfolder per product (`transcript/`, `memory/`, …) and all sessions aggregated by
   `opencode-db exports list|view`.

Without a presets file, the classic raw-flags CLI remains available (`opencode-db export transcript|memory|digest [flags]`; `full` and `compactions` still resolve as aliases). ESC always climbs back / cancels.

## 3b. Managing your runs

Every list in the menu has the same shape: one flow row, one `[*] view → remove`
toggle, then a row per entry. Only in **view** mode do you get the detail rows.

| list | rows | what a row does |
|---|---|---|
| exports | `[>] create export`, `[*] view → remove`, `[>] details of all runs`, `[delete all]`, `[delete olds]` | `exports view <stamp>` prints the run's metadata only (not its markdown), one screen with a banner and per-product blocks |
| backups | `[>] create backup`, `[*] view → remove`, `[delete all]`, `[delete olds]` | `backups view <file>` prints the manifest record **and runs the sha256 check** — `[OK]`, `[FAIL]` with both hashes, or `[MISSING]` — plus `vs live DB` and a `--from-backup` restore hint |
| shrinks | `[>] create shrink copy`, `[>] swap a copy into the LIVE DB`, `[?] verify`, `[*] view → remove`, `[>] details of all copies`, `[delete all]`, `[delete olds]` | `shrinks view <stamp>` shows one copy; `verify` audits **every** copy, not just the newest |

Every row is a single action — there is no TAB multi-select anywhere. The two `delete`
rows only appear in **remove** mode, next to the toggle, never next to a detail row.

Three behaviours worth knowing:

- **`[>] details of all …`** prints every entry's detail screen in one pass — one
  global header, then the same `view` command the single row runs, with a single pause
  at the end (Enter returns to the list, Esc closes the submenu). It appears only in
  view mode, and only when the list is not empty. Backups has no such row: hashing
  every file twice is not worth it, and `backups view` already validates each one you open.
- **`[?] verify` on shrinks** is a real audit, not a display: a copy is **stale** when
  the live DB has content newer than the copy — a session added, edited or compacted
  since it was made (or when it predates the last backup),
  and a directory without a `shrink.json` is reported once, as an orphan. Delete a stale
  copy knowing this.
- **`[>] create backup` shows the plan before asking.** It runs `backup --dry-run`
  first, then a single `Create this backup now?` gate, then `backup --yes` — so no
  command ever stops to ask you something from inside the menu, and the plan block
  appears exactly once (the `--yes` call does not repeat it). The `snapshot: fresh`
  plan (`backup_then_full`) offers the same when the last backup has diverged.
- **When the shrink discards sessions, the plan names them and offers the export
  first.** You see every session that will be dropped by **id + title + how many
  subagents come with it** (an id alone does not tell you which conversation it is),
  and the offer is `export archive --sessions <cascade>` — the whole discard set
  (roots **and** their subagents), which is the only thing that protects them:
  `export --sessions` matches exact ids, so the roots alone would export part of
  what the shrink is about to delete. Answer `y` and you keep a readable reference;
  answer `n` and the same command is printed so you can run it later (the live DB
  still has everything — the export matters before you **swap** the copy in). Set
  `OCED_SHRINK_DISCARD_EXPORT_PROFILE=memory` in the conf file if you prefer a
  corpus-only reference. Whatever you pick, it must keep the subagents: a preset with
  `no_subagents`, `no_orphan_subagents` or `sub: omit` earns an on-screen warning, because
  the export would run, look fine, and leave the subagents behind.

## 4. Decision matrix

| I want to… | use | notes |
|---|---|---|
| keep a lossless backup of everything | `export archive` | complete tool outputs + faithful JSON + corpus |
| review what I did today, fast | `export quick` | light, readable transcript + corpus |
| send a session to a colleague / paste in an issue / publish | `export share` | no reasoning + faithful JSON; it does **not** redact — add `--sanitize` if you must (best effort) and **read the output before sharing** |
| read a conversation plain | `export notes` | plain transcript defaults, nothing extra |
| give another AI the context of my sessions (RAG) | `export rag` (a named plan) or `export memory` (CLI) | corpus.jsonl with defaults; add `--files` for touched files |
| skim the "knowledge arc" of a session | `export digest` | just the compaction summaries (also in transcript + memory) |
| archive-grade export, but make sure the backup is current first | `export backup_then_full` | offers a fresh backup when the last one diverged, then a full transcript |
| read one conversation in full | `export transcript` (CLI) | add `--json` if you also want the faithful archive |
| audit what opencode actually ran | `transcript` + `--tool-output full` `--patch full` | evidence = tool calls + diffs |
| skim the "knowledge arc" of a session **without exporting** | `opencode-db info <id>` / `opencode-db digest <id> show` | the compaction digests are already on the read-only side (`info --no-digest` drops the block) |
| narrow a run to a project/session | `--filter 'Project X'` or `--sessions ses_…` | also the menu's session picker / plan override |
| export from a stored backup instead of the live DB | `--from-backup <file>` | every read command honors it |

## 5. Precedence and safety

- Environment > conf file > defaults for paths/options; **the CLI wins over a plan**
  (`opencode-db export archive --filter ses_X` overrides the plan's selection; an
  explicit flag overrides the plan's value).
- The DB is always opened **read-only**; exports never mutate opencode data. The only
  path that writes the live DB is the opt-in `shrink --swap`.
- Every export's `metadata.json` carries a `db_sha256`, so you can correlate a run with
  the exact snapshot that produced it.
- **`--sanitize` is best-effort**: it redacts high-confidence secret prefixes
  (sk-, ghp_, Bearer, JWT, PEM…) but is not a guarantee; always review the output
  before sharing.