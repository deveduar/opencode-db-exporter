# Bash menu design

> Design and navigation contracts for the optional fzf menu.

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
| `get_sub_ids` | sessions + export | adds the `subagents: shown ⇄ hidden` row **and starts the picker hidden** (`hide_subs` defaults to 1); its presence is also what makes `make_action` receive the third argument `hide_subs`, which keeps the shrink callback at arity 2 without a special case in the shared code |
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

**The title is capped and the agent column is fixed.** After the id field the title is a
fixed `TITLE_COL_W`=57 column: padded when short, cut to `TITLE_COL_W-1` + `…` when long, so
it can never push the metadata right. Then `COL_GAP`=2 spaces, then `@<agent>` in a fixed
`AGENT_COL_W`=10 column (always reserved, so `@build`/`@general`/`@explore`/empty all leave
the date at the same offset), then the updated `YYYY-MM-DD HH:MM` date. The old "full title,
never truncated" rule pushed the metadata right on a long title; the row is now
deterministic on every row (see `archive/export-analysis-2026-full.md` §47).

**Heavy commands run under a light spinner.** The commands that stay quiet for a while
before their one-line result (backup create, export create, the shrink discard-offer export,
shrink build, `--swap`) are bracketed by
`run_oced_tool_spin`, which draws frames on `/dev/tty` while the **same streaming**
`run_oced_tool` runs. It never captures the output (the streaming contract holds), it is
TTY-gated and a no-op under tests/pipes (and off with `OCED_SPINNER_DISABLE=1`), and the
frames never reach stdout, so a pipe or the streamed log cannot see them (see
`archive/export-analysis-2026-full.md` §48).

**The export flow is sessions → preset → confirm.** The sessions picker comes first
(`(N sub)` badges, `subagents: shown ⇄ hidden` **starting hidden** so roots-only is the
default, recency-ordered with a flip row, marks in a 1/0 array so a re-sort or a bulk row
cannot resurrect an unmarked session). Then the **preset-only** picker lists each named
preset as a direct action (rows/descriptions/plans resolved by `exportlib/plan.py`;
bundle presets render their actual products, e.g. `[transcript+memory+corpus+faithful]` for `complete`); **without the file it prints setup guidance**
(`cp presets.json …`) plus the raw CLI — **there is no manual session→product
fallback** (`oc_pick_product`, `oc_export_flow` and `oc_export_manual_picker` are gone).
Asking for the selection *after* the plan was the old order and it was wrong twice
over: it forced a second, identical list of sessions after the plan was already
chosen, and it made "all sessions" indistinguishable from "all sessions plus the
filter the preset happened to carry". The selection is **run-time state**, not part of
the plan identity, so it is asked first and simply applied with **one rule**: an
*untouched* selection (every RENDERED row still marked — all roots while hidden, all
sessions while shown) runs the preset as configured (no `--sessions`, so a preset-pinned
filter wins), a *narrowed* one runs `export <name> --sessions <csv>` (CLI-wins, and
identical for a bundle, whose selection is shared). A narrowed hidden run expands the
marked roots to their full recursive cascade with `oc_export_expand_subs`; no
`--no-subagents` flag is used (see the [Python CLI guide](../README.md#python-exporter-cli)).

**The confirmation states the effective selection, not the intent.** "All marked" and
"the preset pins a filter" are two different outcomes, and only one of them is what the
user just did on screen. `oc_preset_run` therefore asks `plan.py selection <name>` and
`plan.py subagents <name>` (python stays the SSoT for preset text) and prints three
lines that cannot lie: `Sessions:` (untouched + no pinned selection → `all N sessions
in the DB`; untouched + a pinned one → `filter "%…%" (from the preset) — your N marks
are not used`; narrowed → `the N sessions you marked (the menu overrides the preset: …)`),
`Menu adds:` (only what the menu itself contributes — `nothing`, or
`subagents cascaded from selected roots` when the menu narrowed a hidden run), and an
optional `Note:` (subagents that will be exported standalone, or a preset that already
drops subagents, which the switch cannot widen). The old
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
each preset carries its own `description` **in the presets file**, so the shipped
plans (`complete`/`source`/`review`/`notes`/`conversation`/`prompts`/`corpus`/`digest`) annotate themselves
from the same source that defines them (a preset with no `description` shows the bare
row). The confirm step prints the plan as the SAME **card** `--explain` prints, so a
single builder describes every plan. `plan_text()` prints `card_lines()` for a preset: the
preset `name (products)` line, its `description`, a `flags:` line with the effective flag
phrases (` · `-joined) and an example file tree, all indented two spaces. That header names
the products, so no separate product-intro legend sits above it; a bare product keyword has
no recipe and no card, so it prints its intro plus the `Default options, no flags set`
caption and the same tree. `card_lines()` is shared by `explain_text()` (the static
`--explain` catalog), so the catalog and the runtime plan cannot drift (a smoke test asserts
archive's card is byte-identical in `--show` and `--explain`). `_wrap()` keeps every line
inside a fixed 72-column budget so the block is deterministic; the keyword's
`PRODUCT_INTRO` is still printed in full, only folded. The old per-product blocks, the operator
symbology (a `+` on the first flag joined with `' · '`, which read as an expression rather
than a list) and the separate `-> Notes` block are all gone: `annotate_flags()` returns a
**list** of standalone phrases ` · `-joined on the single `flags:` line, and the caveats
(sanitize, truncation) are carried by that same line (the `faithful` product, which used
to be a `json` caveat, is now named in the products line) rather than a
hand-written block. There are **no
variant tables or custom checklists**: tuning and "bundle everything in one stamp" live
in the presets file (`OCED_PRESETS`) or the CLI.

**The run manager is where a run is refreshed, not the recipe.** "What changed since last
time" is a property of a *run*, so `exports update <stamp>` lives in the exports manager
(the picker's `[>] update` row), never as a switch on the export/enable
picker. The engine is `exportlib/update.py` (the run manager's Python counterpart of a
fresh export): it reads the run's own `metadata.json` (`.session_records`, `.scope`,
`.flags`, `.preset`), compares them against the LIVE DB read-only, and re-renders the
target set into a temp dir that is swapped over the run in two `rename`s — a failed refresh
never leaves a half-updated export. The run keeps its STAMP (and its place in
`exports list`); only its content moves. `--keep-history` keeps the previous state as
`<stamp>~<date>` (hardlinks) without ever listing it as a run. `--mode delta` (default) keeps
the run's own set (`+new`, `-gone`); `--mode accumulative` re-syncs it with the whole scope.
`--sticky` controls whether a session the menu deliberately left out (`.excluded`) is pulled
back in: `stale` (default) revives it **only once it was edited** ("the run no longer
describes it"), `never` refuses even that — the user's "I dropped it, keep it dropped" — and
`--include-excluded ID,ID` reopens **specific** excluded sessions by id, the one thing the
mode axis cannot express. `--include-excluded all` was the exact twin of `--mode accumulative`
(both land on `in_scope`), so it is **refused** with a pointer at accumulative — there is no
redundant flag left. `.excluded` is the **selection** gap only (`effective_scope - written`);
a drop caused by the run's own `--no-subagents`/`--no-orphan-subagents` policy lives in
`.no_subagents`/`.no_orphan_subagents`/`.subagents_hidden`, and the refresh applies those
recorded flags to the scope before computing `new`/`revived`, so a policy-dropped subagent is
never revived only to be dropped again.

**The refresh flow is three levels.** LEVEL 1 is the view/remove list; its `[>] update` opens
LEVEL 2, the run list **in update mode**; picking a run opens LEVEL 3, the modes screen. LEVEL 3
is **fila-run, not toggles**: the plan is the engine's own `--dry-run`, so what the gate confirms
is literally what the run will do; the failure the old toggle screen caused was that changing a
modifier **re-ran and re-printed the plan** and then opened `fzf` over it, so the user could never
read what was about to happen. Now each ROW is a concrete update — its own mode and excluded
policy, its label carrying the live counts — and picking one prints the plan **uncovered** (fzf is
closed by then, so it scrolls) BEFORE the y/N gate:

| Row | Flags | Meaning |
|---|---|---|
| `sticky stale (default) — re-render N[ · +M new][ · revive K edited] → T_delta` | (none) | keep the run's own set, `--sticky stale`; it revives the excluded sessions the DB edited |
| `sticky never — 0 revived, E excluded stay out → T_never` | `--sticky never` | keep the run's own set, an edited excluded session stays out — offered ONLY when delta would revive one (`revived > 0`), and it lands on ITS OWN target |
| `bring the whole scope back — revive R → T_scope` | `--mode accumulative` | re-open the whole gap: every excluded session comes back and the run follows its scope |

**Three rules keep the screen honest.** A row is rendered only when its plan really **moves**
something (the engine's `up_to_date` is false): a no-op mode is never offered, because picking it
would print a plan and then do nothing — this is what made a `sticky never` that changes nothing
(a narrowed run whose delta revives nothing) stop appearing. `--include-excluded all` and
`--mode accumulative` land on the **SAME** set (mathematically `in_scope == still ∪ new ∪
ex_live`), so the CLI has **no** `all` form (`--include-excluded` takes ids only; `all` is
refused pointing at accumulative) and the menu offers **ONE** reopen row (accumulative). And
when exactly **one** real action remains — a full run with no gap (delta alone), or a
narrowed run whose only useful move is reopening — the picker is **skipped** and the action runs
straight into its plan+gate: a one-row `fzf` screen whose only job is to make the user press
Enter is a step with no decision in it.

Each row carries the set it LANDS ON (`→ target`, each policy's OWN target), so the user sees
where each option ends up BEFORE the plan prints (the `never` row used to print delta's target).
The labels use the CLI's own terms (`sticky`, `accumulative`), glossed on a three-line header.
That header also explains why delta and `never` can differ (the edited excluded session delta
revives).

`update all runs` is deliberately **not** in this table: it is the FIRST row of LEVEL 2
(`[>] update all runs`, `__UPDATE_ALL__`, only with more than one run), next to the runs it
refreshes, because refreshing the whole shelf is a property of the LIST, not of one run's modes
screen. It collects the runs with `exports_runs_find` and runs them behind ONE global gate.

**Each level owns its own loop** (this is the navigation contract, guarded by tests): LEVEL 3
ALWAYS returns to LEVEL 2 — running, declining or ESC'ing an update redraw the run list, so the
user can refresh another run without landing back in the view/remove list; only ESC at LEVEL 2
leaves to LEVEL 1. The nothing-moved path therefore carries no navigation signal (it just says so
and LEVEL 2 redraws) — the old shape paused inside the wizard AND returned 0 to a caller that
paused again, so Enter re-showed the same screen.

The scope row is rendered only when `.excluded` is non-empty (there is a gap to reopen), the
"sticky never" row only when delta would revive an excluded session (otherwise it is the same
action as delta) AND it moves, and every row only when its plan is not `up_to_date`. A
**narrowed** run is never dismissed just because its own set did not move: if it still has a gap,
the scope row is offered so the gap can be closed. Only when **no** row would move anything does
it say "nothing has moved" and stop.

**Freshness has one per-session rule, and one run-level verdict.** A backup or a shrink
records a single `max_updated`; an export records each session's own `updated` in
`.session_records`. `exportlib/freshness.py` is the shared source for snapshot integrity and
scope coverage: `snapshot_changes` detects `stale`/`missing`/`unverifiable` recorded sessions, and
`new_sessions` detects live sessions in the effective scope that are neither written nor
deliberately excluded. It feeds `exports freshness <stamp> [--tsv|--json]`, the `== Changed
since export ==` and `== New in scope ==` blocks of `exports view`, and `exports update`.
On top of it,
`o_export_freshness <meta> [--tag]` is a Bash formatting wrapper around
`exportlib/freshness.py --summary`; the `exports list` row, `view`'s `freshness:` line,
`exports verify [--tsv]`, and the menu all consume that same result. List, verify, and the
menu send their metadata paths in one `--summary-batch` call, sharing one read-only DB
connection rather than starting Python once per run. It distinguishes
**stale** (live `time_updated` is later than the recorded value), **missing** (the session
no longer exists), **unverifiable** (a timestamp is absent or invalid), and **new** (live
session in scope, not recorded and not deliberately excluded). `exports freshness --json|--tsv`
reports recorded and live timestamps; comparisons are at second resolution. A run without
the canonical metadata contract is rejected and must be re-exported. `new` is a coverage
status, not a snapshot-integrity failure, and can coexist with stale/missing statuses. A
direct `--sessions ID` run stores exactly those IDs as `.scope`; preset/menu flows may
preserve a broader scope when that broader selection was explicit.
refresh keeps the stamp, so the list, view **and menu row** render the refresh **next to** it
(`refreshed <time> (<mode>)` / `updated: <mode> mode (refreshed in place)` / `· refreshed
(mode)`), which is the only visible proof a real update moved; the menu row also shows the
refresh's **own date** (`metadata.date`, in the display TZ) instead of the stamp date, since a
refresh keeps the stamp and the old date would read as "same run, same date";
`exports update --yes` suppresses the plan (the caller owns the gate and already showed it),
exactly like `backup --yes`.

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
deliberately folded into `backups view` because a details screen must not show an
unvalidated backup, and the second is exposed as the shrinks picker's `[?] verify` row,
which audits **every** copy ([shrink architecture](shrink.md)). The `backups` picker has no `verify all` row on
purpose: hashing a backup costs ~0.5 s per 163 MB `.gz` (~3 s for a full 1.1 GiB copy),
so validating the whole shelf belongs to `backups verify <file>` / a script, not to a
menu row that would look like a hang.

**Create + manage in one picker.** Shrink lives in its own root entry: `oc_shrinks_picker`
offers `[>] create shrink copy` (a **3-step wizard**: sessions → recipe → read-only
plan; see [shrink architecture](shrink.md); LIVE DB, own snapshot), a `[>] swap a copy into the LIVE DB` row
(`__SWAP__`) that swaps the picked copy into the LIVE DB behind
`oc_confirm_typed "confirm"` (staleness checked via `o_shrink_freshness` first), a
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
same spirit as `o_shrink_freshness` being the one staleness check for shrinks — and the view
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
(`transcript|memory|corpus|digest|faithful`). The Python CLI decision matrix is in
[export architecture](export-architecture.md); short usage is in the
[README command suite](../README.md#bash-command-suite).
