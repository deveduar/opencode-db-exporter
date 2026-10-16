# Export guide — what do I export when?

> User-facing counterpart of the design docs. `opencode-db export` turns your opencode
> sessions into documents. There are **four products** (what a document is) and
> **named plans** (a product or a bundle of products plus its configuration).
> If you are unsure, start with the **decision matrix** at the end.

## 1. The four products

### `transcript` — "read, share, audit" (the human document)

What it produces: one Markdown file per session (and per subagent, `--sub separate`)
with the **whole conversation**: your messages, the assistant answers, the model's
reasoning, every tool call (command + arguments + its output), the code/patch diffs,
and the compaction summaries **inline** where they happened. A per-run `index.md`
lists all sessions; with `faithful` an additional **lossless machine archive** (the
native opencode message shape, see below) is written alongside it.

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

`rag` is the same artifact as `memory` (a named preset, not a richer product). It is
plain JSONL, ready for a loader (LangChain `JSONLinesLoader`) or a claim/supersession
store such as `consolidation-memory`; the corpus is the *index*, the `faithful`
archive is the lossless *evidence*, and the mapping (episodes, scopes, file anchors,
time) is documented in [docs/schemas.md](schemas.md) under *Consuming
`corpus.jsonl`*.

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

### `faithful` — "lossless machine archive" (the raw copy)

What it produces: one **JSON file per session** (and per subagent, always under its
root's `subagents/` folder) in the **native opencode shape** `{info, messages:[{info,
parts}]}`. Nothing is display-filtered: every message, every part, the full tool
output, the reasoning, the patches — the raw record. Only `--sanitize` redacts
(recursively, in memory, before the file is written).

Sizing: **the heaviest possible** — it grows with every token the conversation ever
produced. It is the counterpart to `transcript`: where `transcript` is the
human-readable, filtered view, `faithful` is the recoverable source.

Use it when you want the session *back*, machine-exact: to rebuild a transcript
yourself, to feed a tool that wants opencode's native JSON, or to keep a backup that
nothing has summarised away. A run containing `faithful` is what the cards call
**lossless** — everything else is a view.

`faithful` has no layout flag: the subagent folders are always separate (`--sub`
only re-arranges the Markdown products). It ignores the display filters
(`--tool-output`, `--patch`, `--role`, `--no-reasoning`, `--mark-compactions`,
`--summary-diffs`) because it never applied them in the first place.

## 1b. Subagents: include them or not (all products)

A **subagent** is a session that opencode spawned from another one (`parent_id`
set). Two things about them are independent:

| | flag | effect |
|---|---|---|
| **which subagents are in the export** | `--no-subagents` | drops every subagent, for **all four** products. A session whose parent is gone is *not* a subagent for this purpose (it is an orphan = a root), so it survives |
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
| `archive` | transcript (`tool_output full`) + memory (`files`) + **faithful** | **lossless backup**: everything — complete tool outputs, touched-file lists and the raw session | heavy |
| `quick` | **faithful** | **raw copy**: the whole session as native JSON, lossless, with no Markdown | light |
| `study` | transcript (`tool_output truncated`) + memory (`files`) | **read + RAG**: a readable log plus the searchable corpus, no raw copy | medium |
| `review` | transcript (`no_reasoning`) + **faithful** | **review log**: no reasoning, plus the raw session for the raw copy. It does **not** redact — read the output before you pass it on | medium |
| `notes` | transcript (defaults) | **read conversation**: every message, tool output truncated (~500 chars), patches and reasoning kept | light |
| `conversation` | transcript (`tool_output omit` + `patch omit` + `no_reasoning`) | **the dialogue only**: just the user and assistant text, no tool calls, patches or reasoning — the cleanest read | light |
| `prompts` | transcript (`role user`) | **just what I asked**: only the user prompts, no assistant replies/reasoning/tools — a task log or a prompt library | tiny |
| `rag` | memory (defaults) | **feed another AI**: one JSON line per root session (tokens, first ask, last answer, todos, tools, digests); no transcript | light |
| `digest` | digest (defaults) | **knowledge arc**: just the compaction summaries | tiny |

**Fidelity.** Every card ends with a derived `fidelity:` line. It is `lossless` when
the run includes the `faithful` product **and** drops no data (no `no_subagents` /
`no_orphan_subagents`, no `sanitize`), so the raw session is fully recoverable;
otherwise `lossy`, naming the reasons. The reason fits the product that
carries the data: a content product (`transcript`/`digest`) without `faithful` is
`no faithful JSON: the Markdown is filtered`, while a `memory`-only plan is `the RAG
corpus is a summary, not the full session` (the corpus is *distilled*, so no faithful
copy exists there). That makes `archive`, `quick` and `review`
**lossless** — the faithful archive keeps the whole session even where the Markdown is
filtered — while `notes`, `conversation`, `prompts`, `rag`, `digest` and `study`
are **lossy**. A bare product keyword (no preset) is lossy too. `sanitize` counts
as lossy on purpose: redaction is best-effort and does not let you review what it
removed. The same verdict is a **column of the preset picker row** (between the product
list and the description) and of `--list-presets`/the legend — it is computed by one
helper, so the row and the card can never disagree, and the description never repeats
it.

`sessions` and recency selection are **not** presets: a pinned id list goes stale the
moment the session is renamed, and always-matching patterns (`%2026-09%`, `%this_week%`)
are a data-dependent guess. Use the CLI-only rules instead — `--filter`, `--sessions`,
`--last N`, `--since DATE` (`export transcript --last 5`), or the menu's session
picker, which narrows any preset at run time.

`--sanitize` is a **per-run** flag, deliberately baked into no preset: it redacts
high-confidence prefixes only, and a plan that silently redacted part of the content
would promise a safety it cannot keep. See §5. Likewise `--snapshot fresh` (a
backup-alignment guard) ships in no preset; pass it per run, e.g.
`export transcript --snapshot fresh`.

Run `opencode-db export --list-presets` to see every named plan (name + derived verdict
+ description; `--list-products` lists the four products + their aliases), `export
--explain` for a catalog of every preset (its description, the flags it sets, its
`fidelity:` line and an example file tree — static, no DB), `export <name> --show` for
one resolved plan (static, no DB), and `export <name> --dry-run`
to see both the plan and the sessions the selection would match (read-only, writes
nothing) — useful before running a hand-edited presets file. The menu's preset picker
reaches the same catalog with its `[?] what each preset produces` row.

Sizing is DB-dependent, and `quick` (the native JSON) is the raw data: `archive` adds
the readable transcript and the corpus on top of it, so it is several times larger.
Delete runs you no longer need with `opencode-db exports remove <stamp>`.

## 3. The menu flow, step by step

```
opencode-db menu  →  Export
```

1. **Session picker** — if the presets file exists, you see the session picker first.
   Sessions are listed with `[x]` marks (default: all marked). Subagents start **hidden**,
   so only the roots get a row. The header is one line of live state — `3/6 marked ·
   newest first · ESC: back` (`· subagents hidden (they follow their session)` is appended
   while the switch is hidden; a caveat line warns `subagents keep their own mark: un-marking
   a session does not remove them` while they are shown). You can:
   - Toggle individual sessions with Enter
   - Use the two bulk rows: `mark all`, `unmark all`
   - Flip the sort with the `[*] newest first  →  old first` row (re-sorting keeps your marks)
   - Flip `subagents: hidden → shown` (hidden rows are not rendered, so they can never be marked by hand; they follow their root and are exported with it)
   - Press `[>] choose the preset` to continue

   There are **no recency rows** (`last N`, `oldest N`, `last N days`): marking rows is
   for picking sessions, and a rule that re-evaluates on every run is a selection, not a
   marking. Ask for it on the CLI instead — `export transcript --last 5` (the N most
   recently used roots, plus their subagents) or `--since 2026-09-01` (every session
   updated on or after that date). Both are CLI-only and never preset keys.

   Without a presets file, it prints setup guidance and falls back to the raw CLI.

2. **Preset picker** — shows your named plans (each with its purpose tag). Pick one.

3. **Plan confirmation** — a `-> Export plan` block. The header rows
   (`Source:`/`Preset:`/`Sessions:`/`Menu adds:`/`Output:`, plus `Note:` when the menu has
   one) come first; then the plan: the **card** — the `name (products)` line, its
   description, the `flags:` line with the effective flag phrases and an example file tree,
   all indented two spaces. The header names the products, so no separate product-intro
   legend sits above it. It is the
   SAME block `export <name> --show` / `--dry-run` and `export --explain` print, so the
   catalog and the runtime plan can never disagree. Every line wraps at 72 columns. The
   point of the `Sessions:` line is that
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

Without a presets file, the classic raw-flags CLI remains available (`opencode-db export transcript|memory|digest|faithful [flags]`; `full` and `compactions` still resolve as aliases). ESC always climbs back / cancels.

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
   appears exactly once (the `--yes` call does not repeat it). A plan that sets
   `snapshot: fresh` (no shipped preset does; pass it per run) offers the same when the
   last backup has diverged.
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
| keep a lossless backup of everything | `export archive` | complete tool outputs + the raw session + corpus |
| keep the raw session, losslessly | `export quick` (or `export faithful`) | one native-JSON file per session, no Markdown; only `--sanitize` redacts |
| read a conversation and keep its RAG corpus, no raw copy | `export study` | readable log + corpus.jsonl, no faithful JSON |
| review or hand a session to someone | `export review` | no reasoning + the raw session; it does **not** redact — **read the output before passing it on** |
| read a conversation plain | `export notes` | every message; tool output truncated (~500 chars), patches and reasoning kept |
| read only the dialogue (no tools, patches or reasoning) | `export conversation` | user + assistant text only; the leanest readable transcript |
| collect just the prompts I typed (task log / prompt library) | `export prompts` | user messages only (`role user`); no assistant replies, reasoning or tools |
| give another AI the context of my sessions (RAG) | `export rag` (a named plan) or `export memory` (CLI) | corpus.jsonl with defaults; add `--files` for touched files |
| skim the "knowledge arc" of a session | `export digest` | just the compaction summaries (also in transcript + memory) |
| archive-grade export, but make sure the backup is current first | `export transcript --snapshot fresh` | offers a fresh backup when the last one diverged, then a full transcript |
| read one conversation in full **and** keep the raw copy | `export archive` (CLI: `export transcript` then `export faithful`) | the Markdown plus the native-JSON archive |
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