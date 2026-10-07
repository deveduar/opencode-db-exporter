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
  is the single source of this digest, shared by the `digest` product and `memory`. The
  same two literals make `compactions` and `digests` two different counters in
  `metadata.json` (markers vs summaries) and are the reason the **product** is named
  `digest`: it only ever wrote digests. `compactions` survives as a deprecated alias
  (`PRODUCT_ALIASES`, normalised at resolve time) — see `docs/export-analysis.md`.
- Config precedence: **env > conf file > per-file default** (`load_conf` in `common.sh` snapshots
  the variables before sourcing `$OCED_CONF`). The per-file default is `~/.config/opencode-db/<file>`
  if present, else the repo-shipped copy when running portably, else the built-in.
- **Portable mode**: running the CLI from a checkout that ships real config (`opencode-db.conf`,
  `presets.json`, `shrink-presets.json` — there are no `.example` copies anymore, these files
  ARE the single source of truth) goes `OCED_PORTABLE=1` and reads those files directly: the
  data dirs default into the repo (`<repo>/{exports,backups,activity.log}`, gitignored) and the
  repo conf is read without the `chmod 600` an installed conf gets. An install prefix ships no
  config (install.sh copies only `src/`), so it never goes portable. A user
  `~/.config/opencode-db` file always wins over the repo copy.

## 3. Export pipeline

`export.sh` is a "bash → python" bridge: it validates dependencies/DB and delegates to the
`exportlib` package (`src/exportlib/cli.py` is the self-bootstrapping CLI entry — the old
`src/export.py` shim is gone), which is the only SQLite reader. There is no fork toward
the opencode CLI (the CLI offers no `session export` and
its environment filters would hide sessions; reading the DB directly in `mode=ro` is what
guarantees seeing everything).

### Products

| Product | Document |
|---|---|
| `transcript` | the conversation in markdown (text + reasoning + tools + patches + markers). `full` is an accepted alias |
| `digest` | only the `mode=compaction` digests (`compactions` = deprecated alias) |
| `memory` | RAG corpus: one JSON object per **root** session (metadata, `first_user`, `last_assistant`, all digests) |

There is no `all` meta-profile; "all sessions" means selecting ALL in the picker (or an
empty `--filter`). `--role` is a flag (`all|user|assistant`), not a preset; `memory`
ignores it (documented in its `index.md`).

### Named presets (`presets.json` = source of truth)

The product × flags combination is folded into a **presets** file (JSON in `OCED_PRESETS`,
default `~/.config/opencode-db/presets.json`, same env > conf > default rules;
`install.sh` auto-creates it from the shipped `presets.json` when missing). A preset pins
`product` + its config flags + optionally the selection (`filter` LIKE **or** exact
`sessions`, never both). It is the source of truth for both the CLI and the menu:

- `export <name>` resolves: if `name` ∈ `transcript|memory|digest|full` it is a
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
  `transcript|memory|digest` (mutually exclusive with `product`). The selection is
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

In the menu this is the sessions picker's `subagents: shown ⇄ hidden` row
(`get_sub_ids` in the generic picker): a hidden subagent is not rendered, so it cannot
be marked and never reaches the CSV — the CSV is expanded **after** the picker to include
the full recursive cascade of subagents for every marked root. No `--no-subagents` flag
is used; the expansion is structural, so the guarantee does not depend on a CLI flag.
In shown mode, each subagent is its own row with its own mark, and the confirm reports
how many were explicitly unmarked.

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
TAB multi-select** — mode switches and bulk operations are their own rows.

**One marker grammar, not per-picker decoration.** Every row opens with at most one
bracket and the token states what the row *does*, so the pickers can be read without
memorising their layout: `[>]` opens a flow (`__CREATE__`/`__SWAP__`/`__MAKE__`),
`[?]` inspects (`__VERIFY__`), `[*]` toggles and always renders both states
(`[*] view  →  remove`), `[<word>]` is a bulk action (`[mark all]`, `[unmark all]`,
`[delete all]`, `[delete olds]`) and `[x]`/`[ ]` stay the per-session marks.
`oc_toggle_row` is the only implementation of a toggle row, so the mode, order and
subagent switches cannot drift apart. Two consequences shaped the copy: a flow row no
longer carries a parenthetical (what a backup copies, what a shrink does) because the
marker plus the sub-picker header already say it, and `oldest first` became `old first`
so the two order states are short enough to read in a toggle row.
`tests/menu_flow.sh` guards the grammar: it collects the rows of every picker, fails on
any token outside the allow-list, on `[>]` outside a flow row, on `[?]` outside an
inspect row and on a toggle without `[*]`, and asserts the sample is non-vacuous.

**`menu.sh` is a dispatcher, not a monolith.** It holds `run_menu`/`choose_action`/
`oc_fzf_sel` and sources the per-domain flows from `src/menu/`
(`backups.sh`, `sessions.sh`, `export.sh`, `exports.sh`, `shrink.sh`), with the shared
multi-mark picker in `src/menu/core.sh`. That picker is **one generic function**
(`oc_session_picker`) parameterised through a `cfg` nameref, so the three session
screens cannot drift apart:

| cfg key | used by | meaning |
|---|---|---|
| `roots_only` | shrink | render ROOT sessions only (a subagent always follows its root) |
| `title` / `header` | all | the fzf title and the live-state line above the rows |
| `order` / `order_mode` | all | initial sort and its label; the `[*]` order row flips both |
| `make_label` / `make_action` | select screens | the `[>]` flow row's text and what it runs with the marked-ids CSV |
| `empty_guard_msg` | select screens | what to say when `[>]` is pressed with nothing marked |
| `get_sub_count` | select screens | the `(N sub)` badge per root (recursive) |
| `get_sub_ids` | sessions + export | adds the `subagents: shown ⇄ hidden` row; its presence is also what makes `make_action` receive the third argument `hide_subs`, which keeps the shrink callback at arity 2 without a special case in the shared code |
| `mode: view` | sessions | browse instead of select: no marks, no `__MAKE__`, no mark-all rows, and a session row is a **report** rather than a selection (so it wears no `[x]`/`[ ]`, which would promise a selection that is never built) |
| `view_action` / `view_action_all` / `view_all_header` | sessions | the per-row report, the iterator for `[>] details of all sessions`, and the one group header printed **before** the loop by the picker itself (a callback cannot tell the first call from the last) |

The cfg is passed as a name, never copied into a local: a self-referential nameref would
be a circular reference.

**One list, one rule: where a picker goes after it returns.** `run_menu` has **no
back-stack** — a submenu is a function call, so a picker that `return`s hands control to
the root menu, and every "go back to the list I came from" has to be a `continue` inside
the picker's own `while true`. The single idiom is:

```bash
menu_pause "<label>" || return 0; continue    # Enter: redraw THIS list · Esc: main menu
```

This was not cosmetic. The report paths used to `return 0` after the pause (→ root) while
the remove paths `continue`d (→ stayed), which is why Enter after a report jumped to the
main menu and Enter after a confirmed removal did not. A deep wizard must therefore
**not** own a pause: `oc_export_picker` and the shrink wizard return `0` = "it ran" and
`130` = "ESC'd out, no pause", and the frame that owns the list pauses and decides the
destination (`[ $? -eq 0 ] || continue; menu_pause … || return 0; continue`). Report
pauses are labelled after the list (`Manage exports`/`Backups`/`Shrinks`) and create
pauses after the action (`Export`/`New backup`/`Shrink copy`), so they can never be
confused. `oc_shrinks_swap_pick` is the one exception that already owned its pause: it
returns the pause rc so `__SWAP__` can propagate an ESC.

**A menu action is not done when the command returns.** `run_oced_tool` pipes the
dispatcher through `tee` instead of capturing it, because a captured command talks to a
pipe: anything it asks on stdin (its plan, its `[y/N]`) stays invisible while it blocks on
`read`, so `create backup` looked frozen and the blind keypress that ended the freeze was
an empty line — i.e. a cancelled backup. The general rule follows: **the frame that owns
the list owns the gate**. `__CREATE__` in the backups picker is plan → our `confirm_action`
→ non-interactive run, the shrink wizard's shape, which is why `backup --dry-run` (the
mirror of `shrink --dry-run`) had to exist: it prints the plan and returns, and the menu
then passes `--yes` so no command ever asks anything from inside a menu call. The
`snapshot: fresh` offer follows the same rule — it already had a `confirm_action`, and the
backup it launched used to ask a second, invisible one. This is untestable by stubs and by
non-TTY runs (`run_oced_tool` is stubbed in `menu_flow.sh`, and every real prompt sits
behind `[ -t 0 ]`), so it is guarded structurally — no `out=$(bash "$OC_DISPATCHER"`, no
bare `run_oced_tool backup` in `src/menu/` — plus by a `script -t` pty test that
measures *when* the first output chunk reaches the screen (~0.01 s streaming vs ~2 s
captured).

**The label is a short id; the key is the full id.** `oc_short_id` renders
`ses_f72115a…` as `f72115a_` in a fixed `ID_LABEL_W`=8 column (`ses_` dropped, cut with
a `_` truncation marker), and every session row does it the same way across the three
pickers, so the id is a fixed-width field and the title/date columns stay aligned. The
**row key stays the full id**: marks, the CSV and every command depend on it. This is
display only — a `__REPORT_ALL__` id is never shortened in the data path, and the
`info <id>` banner keeps the full id on purpose (it is copy-pasteable there).

**The export flow is sessions → preset → confirm.** The sessions picker comes first
(all sessions marked, `(N sub)` badges, `subagents: shown ⇄ hidden`, recency-ordered with
a flip row, marks in a 1/0 array so a re-sort or a bulk row cannot resurrect an
unmarked session). Then the **preset-only** picker lists each named preset as a direct
action (rows/purposes/plans resolved by `exportlib/plan.py`; bundle presets render as
`[transcript+memory]`); **without the file it prints setup guidance**
(`cp presets.json …`) plus the raw CLI — **there is no manual session→product
fallback** (`oc_pick_product`, `oc_export_flow` and `oc_export_manual_picker` are gone).
Asking for the selection *after* the plan was the old order and it was wrong twice
over: it forced a second, identical list of sessions after the plan was already
chosen, and it made "all sessions" indistinguishable from "all sessions plus the
filter the preset happened to carry". The selection is **run-time state**, not part of
the plan identity, so it is asked first and simply applied: every session marked runs
the preset as configured (no `--sessions`), a partial one runs
`export <name> --sessions <csv>` (CLI-wins, and identical for a bundle, whose selection
is shared). A hidden-subagent run additionally pins `--no-subagents` (see §3).

**The confirmation states the effective selection, not the intent.** "All marked" and
"the preset pins a filter" are two different outcomes, and only one of them is what the
user just did on screen. `oc_preset_run` therefore asks `plan.py selection <name>` and
`plan.py subagents <name>` (python stays the SSoT for preset text) and prints three
lines that cannot lie: `Sessions:` (all marked + no pinned selection → `all N sessions
in the DB`; all marked + a pinned one → `filter "%…%" (from the preset) — your N marks
are not used`; partial → `the N sessions you marked (the menu overrides the preset: …)`),
`Menu adds:` (only what the menu itself contributes — currently just
`--no-subagents`), and an optional `Note:` (subagents that will be exported standalone,
or a preset that already drops subagents, which the switch cannot widen). The old
`Filter: (preset as configured)` / duplicated `Spec:` CSV is gone: the per-product
block already carries the descriptions. The recency rules that used to
be mark-only rows are now CLI flags (`--last N` counts roots and closes over their
subagents, `--since DATE` is a plain window; both CLI-only via `CLI_ONLY_KEYS`, so a
preset can never pin a non-reproducible set), and the rule that ran is recorded in
`metadata.json` as `.selection` plus the `Selection` row of `index.md`.

Product
rows still come straight from `exportlib/plan.py products` but only as the CLI/test API
surface (no product-only menu flow). Menu labels
explain *purpose and relative size*: product rows carry a "use it when…" tag;
`oc_preset_purpose` annotates the shipped plans
(`archive`/`quick`/`share`/`notes`/`rag`/`digest`) with their intent (unknown names get
the bare row). The confirm step prints the plan as a **flat, flush-left** block. The
rationale is legibility at a glance: an indented tree forced the reader to decode a
hierarchy that carries no extra meaning, and the bullets broke the alignment that made
the rows scannable. So `plan_text()` emits one line per product at the left margin with
its description and effective flags *below* it, a blank line between products, and no
label, bullet or nesting anywhere; `_wrap()` keeps every line inside a fixed 72-column
budget so the block is deterministic. Nothing is hidden to achieve this — the full
`PRODUCT_INTRO` is still printed, only folded. What changed next was the **symbology**:
the flags used to be joined with `' · '` and the first one carried a `+`, which read as an
expression rather than a list of things (`+faithful JSON, raw and unfiltered · full tool
outputs`) — and that `+` only survived because it happened to be first, so it pointed at
nothing. `annotate_flags()` now returns a **list** of standalone phrases rendered one per
line, and `PRODUCT_INTRO` lost its `—` and `+` too; a test fails if a `+`/`*`/`-` marker, a
`' · '` joiner or an em dash reappears in the block. The caveats (raw/unfiltered faithful
JSON, sanitize) are **not** products, so they moved out
of the tree into their own `-> Notes` block (`notes_text()`), which is omitted entirely
when a plan has nothing to warn about. There are **no
variant tables or custom checklists**: tuning and "bundle everything in one stamp" live
in the presets file (`OCED_PRESETS`) or the CLI.

The root menu recomputes its header on every loop: `run_menu --refresh-cb oc_root_status`
rebuilds `ACTION_STATUS` (DB/sessions/WAL/backup/exports counts) after each action, so a
pickered deletion is reflected immediately.

**There is no `check` entry, because `status` is the check.** The root is
`exports · backups · shrinks · sessions · status · help`, and that is deliberate rather than
an omission: `status` is read-only, prints the whole health picture (size/WAL, the `> 1 GiB`
warning with its shrink recipe, table/session/message counts, **backup alignment**, the
version + schema probe and the dependency report) and already returns **non-zero** when the
schema probe fails, so it is scriptable as a health check. A second `check` row would only
reprint it. What `status` genuinely does *not* cover is verifying stored **artifacts**
(`backups verify`'s sha256 vs the manifest, `shrinks verify`'s staleness): the first is
deliberately folded into `backups view` (§4) because a details screen must not show an
unvalidated backup, and the second is exposed as the shrinks picker's `[?] verify` row,
which audits **every** copy (§6). The `backups` picker has no `verify all` row on
purpose: hashing a backup costs ~0.5 s per 163 MB `.gz` (~3 s for a full 1.1 GiB copy),
so validating the whole shelf belongs to `backups verify <file>` / a script, not to a
menu row that would look like a hang.

**Create + manage in one picker.** Shrink lives in its own root entry: `oc_shrinks_picker`
offers `[>] create shrink copy` (a **3-step wizard**: sessions → recipe → read-only
plan, see §5; LIVE DB, own snapshot), a `[>] swap a copy into the LIVE DB` row
(`__SWAP__`) that swaps the picked copy into the LIVE DB behind
`oc_confirm_typed "confirm"` (staleness checked via `o_shrink_stale` first), a
`[?] verify` row, a `[>] details of all copies` row (view mode only), plus a
`[*] view  →  remove` toggle with per-run rows and the
`[delete all]` / `[delete olds]` bulk rows. Rows come from the shrink.sh helpers
(`shrinks_runs_find`/`shrinks_run_row`) — the same source as `shrinks list --tsv`,
so the menu never re-aggregates jq. This removed the old `__SHRINK__` row from the backups
picker, which is now create + a `view`/`remove` toggle over the manifest rows.

**A details screen must show something worth trusting.** The backups picker gained the
same two modes as exports and shrinks (`__CREATE__`, the toggle, the destructive rows in
remove mode, then one row per backup). In view mode a row runs `backups view <file>`,
which prints the manifest record *and performs the sha256 check*, because a details screen
that displays a backup nobody validated is a trap. `oc_backup_sha_state` is the one
implementation of that check — it backs `backups view` and `backups verify` alike, in the
same spirit as `o_shrink_stale` being the one staleness check for shrinks — and the view
adds the `vs live DB` line from `o_backup_aligned <file> -v`. The alignment helper took an
optional file for that: no argument keeps the "last backup" default every other caller
wants, a file makes the view of a *non-newest* copy correct. The check is not a separate
`[?] verify` row in the backups picker because it is not optional information; `verify`
stays available in the CLI for scripted use.

**One screen, every entry: `[>] details of all …`.** The sessions browse got
`[>] details of all sessions`; the exports and shrinks pickers have the same row
(`[>] details of all runs` / `[>] details of all copies`), because "what exactly do I
have stored?" is the question a list cannot answer and N round-trips through a nested
screen answer worse. It is **view mode only** (never rendered next to `[delete all]`)
and it exists only when the list has at least one entry. `oc_view_all <header>
<pause-label> <manager> <stamp>…` in `menu/core.sh` is the one implementation: ONE global
header, then the *same* `exports view`/`shrinks view` a row runs, once per stamp, and a
single pause labelled after the list — so the all-report and the per-row report cannot
drift, and a report pause can never be mistaken for a create pause. That pause **returns
its rc**: ESC (2) travels to the caller's `__REPORT_ALL__` branch and closes the submenu
like every other report, instead of silently redrawing the list. The two wrappers
(`oc_exports_view_all`, `oc_shrinks_view_all`) exist only to name the header and the
label. The key is `__REPORT_ALL__`, the same key the sessions screen uses, and the token
is `[>]` even though no flow opens: it prints the screens a row prints, all of them at
once, and inventing a fourth token for it would be worse than the small stretch of the
`[>]` contract (the symbol guard's allow-list admits `__REPORT_ALL__` explicitly).
Backups deliberately has **no** such row: its per-row view already hashes the file, and
hashing the whole shelf would take seconds per gigabyte.

The term **plan/preset** always means the named config; **product** always the keyword
(`transcript|memory|digest`). Usage and the decision matrix:
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

**Named recipes = OPERATIONS only** (the shrink mirror of §3.3): `src/shrinklib/` is
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
`opencode-db export <profile> --sessions <cascade>` — so nothing is lost before the
pruned copy is made; the menu makes it an actual offer. The hint and the offer both
carry the **cascade**, not the listed roots: `--discard-sessions` drops the roots and
every descendant, while `export --sessions` matches EXACT ids, so the roots alone
exported part of what was about to be deleted — silently, because the export
succeeded. `<profile>` is `$OCED_SHRINK_DISCARD_EXPORT_PROFILE` (default `archive` =
transcript + memory), validated against products + preset names in
`o_shrink_discard_profile`, so a typo is reported where the command is printed.

That resolver also asks `plan.py subagent-gaps <profile>` (read across every product of a
bundle) whether the profile would keep the subagents it is being handed:
`no_subagents`/`no_orphan_subagents` drop the sessions themselves, and `sub: omit` empties
`children_of`, so **no subagent body is written** while the run still reports plausible
counts. All three are silent successes — the exact failure this offer exists to prevent,
now with a closed set that specifically contains the subagents. So the resolver warns
before the y/N gate. It is a warning and not a veto: dropping subagents on purpose is a
legitimate reason to run the export. A product keyword can never gap, so `archive` stays
silent for free.

**The create flow is sessions-first** (`oc_pick_shrink` = the `__CREATE__` entry of the
shrinks picker), and it is the only way to create a shrink from the menu:

1. `oc_shrink_sessions_pick` — **root sessions only** (`list --root`): a subagent always
   follows its root, so it never needs a row, and an orphan whose parent is gone *is* a
   root. `[x]` = survives in the copy, default ALL marked; a `(N sub)` badge (recursive)
   shows what each root drags along. The only bulk rows are `mark all` / `unmark all`:
   a recency rule re-evaluates on every run, so it is a *selection* (a CLI rule), not
   something a row can "mark" — `--keep N` / `--older-than` / `--since` already own that
   on the engine side, and `export --last N` is the export-side mirror. `__MAKE__` is
   **continue**, not "build": all marked → `--keep-all`,
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
   `export <profile> --sessions <cascade>` offer when discarding (the list names each
   discarded session by id + title, capped), the picked `Recipe:`/`Command:`
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
(`shrinks list [--tsv]|view <stamp> [--json]|verify [--tsv] [--yes]|remove <stamp> [--yes]|prune <N>`)
manages them the way `exports` manages run folders. The presentation splits into two
screens with two widths:

* `shrinks list` — a **COLUMN**: `<date>  <tag>  <kept>/<total> kept  <before> -> <after> -N%`,
  the tag from `plan.py rule-tag` (the SSoT for the compact form), one size delta,
  the copy's state only when anomalous (`(swapped/no copy)`).
* `shrinks view` — a **DETAIL** screen shaped like `exports view`
  (`== Shrink copy: <stamp> ==` then `sessions:`/`size:`/`selection:`/`criteria:`/
  `reasoning:`/`date:`/`db:`/`integrity:`/`freshness:` + per-table removals + files);
  `--json` returns `shrink.json` verbatim, byte for byte, no banner.

Both formats are generated from the same `shrink.json`; the sentence and the tag are
two formats of ONE fact living side by side in `plan.py` (`rule-line` / `rule-tag`).
The bash engine never builds these phrases itself; it delegates to the single source.

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
valid `shrink.json`), old `pre-shrink/*` copies, and **every copy's** freshness vs
the live DB. Freshness is asked once per run, not once for the newest: a stale
answer for `runs[0]` was a half-verification — a 3-copy shelf reported the orphan in
the third directory but never that copies 1 and 2 were stale, which is the one thing
you want to know before choosing one to swap. `shrink.json` records
`sessions.max_updated` (newest kept session `time_updated`)
so the freshness check runs in-database; a legacy shrink.json without that field is
flagged as unverifiable rather than silently "up to date". An orphan dir is reported
once, as an orphan, never also as a stale copy. The clean verdict names how many copies
were asked (`all 7 shrink copies are up to date`): the count is the only visible proof
that the loop ran, and a fresh-looking verdict over three unchecked copies is exactly
the answer that hid the other two.

## 7. Links

- `../README.md` — usage guide (installation, commands, flags, tests, layout).
- `export-analysis.md` — pre-redesign analysis and §7 with the confirmed decisions.