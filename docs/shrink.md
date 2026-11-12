# Shrink architecture

> How the Bash shrink workflow selects, prunes, verifies, and manages database copies.

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
6. Manual swap — or `--swap`, see [operational swap safety](swap-safety.md).

**Named recipes = OPERATIONS only** (the shrink mirror of the export preset model): `src/shrinklib/` is
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
succeeded. `<profile>` is `$OCED_SHRINK_DISCARD_EXPORT_PROFILE` (default `review`). That
resolver also warns, before the y/N gate, when the profile would silently drop the
subagents the cascade contains — a warning, never a veto (dropping them on purpose is
legitimate). The field-level rules — defaults, validation, the exact warning — are in
`schemas.md` §6.

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
   (`shrinklib/plan.py rows`), each carrying its own `description`. There is no operation
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
  (`== Shrink copy: <stamp> ==` then `sessions:`/`size:`/`criteria:`/
  `reasoning:`/`date:`/`db:`/`integrity:`/`freshness:` + per-table removals + files;
  no `selection:` line — `criteria:` names the rule and the `ids (<n>):` header
  counts them, so the compact form would only repeat both; `--json` returns
  `shrink.json` verbatim, byte for byte, no banner).

Both formats are generated from the same `shrink.json`; the sentence and the tag are
two formats of ONE fact living side by side in `plan.py` (`rule-line` / `rule-tag`).
The bash engine never builds these phrases itself; it delegates to the single source.
