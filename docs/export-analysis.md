# Export analysis — decision log (opencode-db-exporter)

Live record of the decisions behind the export redesign and later iterations (products,
presets, plans, contract hardening). Each section is a decision taken with the user; later
sections supersede earlier ones when they conflict (noted inline). The pre-redesign
analysis that motivated §7 (old `full`/`no-calls`/`text-only`/`all` model, community
research, open questions) is archived in
[`docs/archive/export-analysis-2026-09-predesign.md`](archive/export-analysis-2026-09-predesign.md).
Current behavior is described in `docs/architecture.md`.

---

## 7. Decisions taken (user answers)

1. **Yes** — `all` now means "all sessions". The `all` meta-profile (4-in-1) and the
   `no-calls` / `text-only` profiles are removed.
2. **Yes** — markdown main + faithful `--json` (file per session).
3. **Yes** — `--sanitize` is implemented (recursive secret redaction).
4. **Yes** — `--role` stays a toggle of `transcript`/`compactions`; the "prompts only" /
   "answers only" presets are **removed** from the menu.
5. **Yes** — `compactions` stays as an independent markdown product (it is not merged into
   `info`/`memory`).
6. **Yes** — token backfill from `step-finish` (in-memory sum, `tokens_backfilled` flag).

Final model: **products** `transcript | memory | compactions` (no meta-profile, `full`
accepted as an alias of `transcript`). The menu was later simplified to **product-only**
(see §10): no per-product variants, no custom checklist and no bundle — each product runs
with its default options, and tuning lives in the presets file or the CLI.

## 8. Named presets (later decision, sep 2026)

The user confirmed simplifying the options surface with a **presets file** as source of
truth (no more variant lists growing in the menu):

1. **Format**: JSON (stdlib, no dependencies) — not TOML (would raise the Python floor) nor
   YAML (PyYAML).
2. **Scope**: user-global (`OCED_PRESETS`, default
   `~/.config/opencode-db/presets.json`). Each preset filters toward its project via
   `filter`/`sessions` — "per-project" is covered inside a single file.
3. **Selection inside the preset**: yes — `filter` (LIKE) or `sessions` (exact ids, not
   both) so periodic per-project/per-session exports can be automated.
4. **CLI resolution**: auto-resolves by name — if `name` is a product it is a product;
   if it is a known preset it is a preset; otherwise an error lists both.
5. **Menu**: preset-first — presets are first-class actions + `Manual…` (the classic flow;
   later product-only, see §10); without a file, the old behavior is intact.
6. **Precedence**: the CLI wins — `--filter`/`--sessions` void the preset selection; any
   explicit flag beats the preset value.

Implemented with `--sessions` (query `sessions IN (…)`) and `metadata.json.preset`/
`sessions_selected` for provenance. The ad-hoc surgical flags remain on the CLI.

## 9. Refactor to the `exportlib` package (later decision)

`modules/export.py` went from a monolith (~1075 lines) to an **entry shim** (4 lines) +
the package `modules/exportlib/` (`util`/`config`/`sanitize`/`presets`/`db`/`render`/
`transcript`/`faithful`/`memory`/`writers`/`cli`; version in `exportlib/__init__.py`).
Purely mechanical refactor: same behavior, same test suites, zero new dependencies.
`export.sh` calls `modules/exportlib/cli.py` directly — the entry is self-bootstrapping
(it adds `modules/` to `sys.path` when run as a script), so the `export.py` shim has since
been removed. This document keeps §1 as the historical state of the code before
the redesign.

## 10. Product-only menu (later decision, sep 2026)

The manual export flow in the menu was reduced to its essentials:

- **session (or ALL) → product (`transcript|memory|compactions`) → plan → run** with the
  product's default options (plus `--filter <session>` when a session was picked).
- **Removed**: the per-product variant tables (`oc_recipes_for`, transcript had 14 rows,
  compactions 5, memory 3), the `__CUSTOM__` checkbox checklist
  (`oc_custom_set`/`oc_custom_run`/`oc_custom_args`/`oc_memory_custom`) and the
  `__FULLMEM__` bundle (transcript+memory under one shared `--stamp`).
- **Rationale** (user feedback): the variant rows overflowed the terminal, too many
  choices, and multi-profile runs were confusing (`Profile: transcript + memory`,
  `Spec: transcript --sub omit`). Tuning now lives entirely in the presets file
  (`OCED_PRESETS`) or the CLI flags; the preset picker (see §8) keeps presets as
  first-class actions.

Tests: `tests/menu_flow.sh` cover the expected 3 product rows and the absence of
variant/custom/bundle rows; `tests/export_smoke.sh` covers the CLI presets.

## 11. Bundle presets (later decision, sep 2026)

The "all-in-one / export everything" idea came back as a *configuration* question, not a
menu/CLI spaghetti question: the user asked whether running "todo" should dump three
folders under one stamp and whether that would be redundant. Analysis:

- **Content overlap**: `transcript` already renders the compaction digests inline
  (`_transcript_msgs` keeps all messages; the `compactions` product only filters to the
  `mode=compaction` digest). `memory` is genuinely distinct (JSONL RAG corpus with the
  digests as a field). So the non-redundant "everything" pair is **transcript + memory**;
  `compactions` remains as a digest-only standalone product / CLI view.
- **Lossless by default**: sessions are already ALL by default; the real fidelity loss is
  the default truncated tool output and the missing faithful JSON. Rather than changing
  the everyday defaults (which would balloon every run), the shipped `archive` bundle
  runs `transcript` with `tool_output: full` + `json` and `memory` with `files` — the
  lossless path lives in the preset, not in the defaults.

Decision: **bundle presets**. A preset may now use `products` (a map
`{product: {flags}}` over `transcript|memory|compactions`, mutually exclusive with
`product`) instead of a single `product`. The selection (`filter`/`sessions`) stays
top-level and shared; `apply_bundle()` validates and stores `args.bundle`; `run_bundle()`
in `cli.py` computes one shared collision-free stamp and re-executes
`exportlib/cli.py <product> --stamp <shared> --preset-name <name>` per product, so each
bundle subfolder is byte-identical to a standalone run (own `index.md` + `metadata.json`
recording the preset name) and `exports list` aggregates the stamp as
`transcript+memory`. The parent writes an `index.md` at the stamp root. The menu gets it
for free: the preset-first picker renders bundle presets as `[transcript+memory]` and runs
`export <name>`. `presets.json.example` ships `archive` (lossless transcript+memory),
`quick` (the light transcript+memory variant: json, *truncated* tool output) and `share`
(sanitize/publish) — this replaces the removed `__FULLMEM__` bundle with the same capability,
but expressed as data (source of truth) instead of menu code.

Consequences for §8: a bundle preset is still a preset (CLI win semantics hold per
product via `flag_in_argv`; a top-level `--sessions` clobbers the shared selection for all
products). Fixed a latent key→flag bug while at it: preset keys use underscores
(`tool_output`) but CLI flags use dashes (`--tool-output`), so `flag_in_argv` now maps the
key with `_flag()`.
## §12 Contract hardening

An external review of the schema contract surfaced real gaps; all fixed (verified
against the code, not just documented):

- **`files` collision in memory `metadata.json`** — the dict literal wrote
  `"files": bool(args.files)` and later `"files": ["corpus.jsonl","index.md"]`; the
  second key won and the bool was silently dropped. The requested flag is now
  `touched_files`; `files` remains the produced-file list (same shape as
  transcript).
- **`model` one form** — `model_str()` no longer re-emits a JSON blob
  (`{"id":…,"provider":…}`); a JSON-serialized model resolves to its plain `id`.
  Applied to corpus, faithful JSON and transcript markdown.
- **Dates ISO-8601 UTC** — `ts_iso()` emits `YYYY-MM-DDTHH:MM:SSZ`; the faithful
  archive switched from raw epoch ms to the same conversion; index headers too.
- **`null` not `""`** in machine artifacts (corpus/faithful/metadata) for absent
  values; `""` stays in markdown rendering.
- **`schema_version: 1`** on every corpus line, with a documented bump policy.
- **No `--swap` contradiction** — the intro of `docs/schemas.md` states the one
  opt-in exception explicitly instead of claiming "never written" flatly.
- **Artifact renamed** `metadatos.json` → `metadata.json`; readers (`exports list/
  view`, menu) still accept the legacy name so old run dirs keep aggregating.

Test surface grew with the hardening (remembered `touched_files` is now asserted,
not just visually verified).

## §13 Plans at run time + compactions off the example (later decision)

Follow-up on the user's read of the presets picker as a "mezcla rara" and a possible
"duplicate source of truth" between the presets and the `Manual…` flow. Analysis:

- **One engine, two entry points** — the CLI (argparse in `exportlib`) is the single
  source of truth; presets are *named plans* (config + optional embedded selection),
  `Manual…` is the raw-flags path with defaults, and `flag_in_argv`/`cli_selection`
  already make the CLI win over the plan. No duplication: the perceived conflict was
  terminological (`profile` was overloaded: product keyword in `metadata.json.profile`
  vs "Profile:" plan label) compounded by the as-symmetry: presets carried selection,
  Manual asked for it.
- **Selection becomes run-time state** — a plan is config + selection, and the two are
  now separated in the menu: picking any preset is followed by a session/ALL picker.
  `ALL SESSIONS` runs the preset as configured (embedded selection kept); picking one
  session adds `--filter <ses>` (CLI wing semantics, shared by every product of a
  bundle). `Menu…` stays as the ad-hoc defaults path. Nomenclature in the menu/plan
  labels now distinguishes **product** (keyword) from **preset/plan** (name).
- **`compactions` off the shipped plans, presets renamed** — the standalone digests are
  already inline in `transcript` and a field of the memory corpus, so shipping it in a
  bundle triples the same text (empirically: 23/23 digest texts byte-identical to
  `compactions.md`). The product stays valid on the CLI and in user-defined plans; the
  shipped example no longer bundles it and the preset names were renamed to their
  **purpose**: `everything`→`archive` (lossless full backup), `debug`→`quick` (light
  daily review, truncated tool output), `clean`→`share` (sanitize/no_reasoning,
  publish-safe). The menu labels products and plans by purpose and size, and
  `compactions` is annotated as an extract already contained in the other two.
  `tests/export_smoke.sh` keeps one self-defined bundle with `compactions` to
  prove the capability, and the example e2e asserts `quick` has no `compactions` dir.
- **menu_flow coverage** — the preset picker tests now drive the two-step flow
  (`__PRESET_x` → `__ALL__` or a session) including the override commands
  (`export archive --filter ses_A0001`) and the purpose annotation of the shipped plans.

## §14 Default plans, no Manual, confirm plan with Will produce + sanitize caveat (later decision)

Follow-up on the user's request to remove the confusing `Manual…` row and make the
confirm step explicit about what will be produced.

- **Default plans replace Manual** — the shipped example now includes `notes` (transcript
  defaults), `rag` (memory defaults), `digest` (compactions defaults) alongside the
  existing `archive`/`quick`/`share`. The menu is purely preset-first: pick a plan →
  pick a session/ALL → confirm → run. The `Manual…` row and `oc_export_manual_picker`
  remain only as the **no-presets fallback** (when `OCED_PRESETS` doesn't exist or is
  empty). This eliminates the redundancy where "presets" and "Manual" were two different
  entry points for the same products. *(Note: the no-presets fallback was fully removed
  later — see **§15**.)*
- **Confirm plan shows "Will produce:"** — `oc_export_confirm` now builds a dynamic
  block listing each product with its short description and effective flags
  ("full tool outputs", "+faithful JSON (raw)", "reasoning omitted", "sanitize ON
  (best-effort redaction)", etc.). The faithful JSON note clarifies that markdown
  display filters (`tool_output`, `role`, `no_reasoning`, `tool_input_limit`) do NOT
  apply to the JSON archive, which is always raw/unfiltered (except `sanitize`).
- **Sanitize caveat** — when `sanitize` is active, the plan prints a bold warning:
  "sanitize redacts safe prefixes only (sk-, ghp_, AKIA, JWT, PEM) — review output."
  — best-effort, NOT a guarantee; verify output before sharing. Later reduced to
  high-confidence prefixes only (dropped generic `key=value` and `*_API_KEY` name
  patterns) so `share` no longer ships with `sanitize` baked in. The README and guide
  were updated accordingly; the term "public-safe" was softened to "publish transcript
  (best-effort redaction)".
- **Tests** — menu_flow grew with assertions for the new helpers
  (`oc_annotate_flags`, `oc_export_plan`) and the absence of `Manual` in presets mode
  (75 OK).
- **Phase 2 (plan API)** — the plan logic moved out of `menu.sh` jq into
  `exportlib/plan.py`: `resolve()` is the single resolver (product keyword or preset
  name → full JSON plan) and the CLI bridge (`rows`/`names`/`descr`/`purpose`/`legend`/
  `resolve`/`plan`) feeds the menu helpers (`oc_plan_py` pins `OCED_PRESETS`). Product
  intros, shipped-plan purposes (`PLAN_PURPOSE`), row tags and the "Will produce:" block
  are byte-for-byte compatible with the old jq output; edit them in `plan.py`, not in
  `menu.sh` (menu.sh only shells out).
- **Phase 3 (dedup, follow-up)** — cash in on the python bridge: the hardcoded
  `export products:/export flags:` block moved from `opencode-db.sh help()` into
  `flags.py --help-exports` (`PRODUCT_HELP`/`FLAG_HELP`, byte-identical output);
  `oc_pick_product` rows + legend now come from `plan.py products`/`products --legend`
  (was menu.sh literals); `cli.py` builds `--filter`/`--sessions`/`--out` straight from
  `FLAGS` (single source, no more hand-declared argparse row); `generate_schema.py`
  reuses `get_flags_for_product` + `PRODUCT_KEYWORDS` instead of inlining product lists;
  the product registry moved to `flags.py` (`PRODUCTS`/`PRODUCT_KEYWORDS`/
  `PRODUCT_INTRO`). Dead python helpers/imports pruned (`get_global_flags`,
  `get_flag_by_name`, `get_product_flag_names`, `get_choice_choices`, `get_int_min`,
  `get_*_flag_names`, `flag_to_json_schema`, `flag_to_argparse_kwargs`). Docs aligned:
  the pre-existing `Manual…` contradiction in `architecture.md`/`export-guide.md` (a row
  that no longer exists) is fixed and README flags list now points at
  `opencode-db export --help` + `generated/flags-table.md`.

## §15 Preset-only menu, shrinks manager, header refresh, uninstall fix (later iteration, sep 2026)

Follow-up on the user's wrap-up questions (guided workflow, workflow separation, presets,
uninstall, the export fallback, the "API", redundancy, exported artifacts) plus the new
shrink manager request. The `guide` rework is deferred (a real interactive guide needs a
fresh design); the docs/artifacts reorganisation (moving generated artifacts to their own
folder, extracting archivable info) is deferred too — "proceed with the plan".

- **Export menu is preset-ONLY (no manual fallback)** — §14 shipped the manual flow still
  as the no-presets fallback; this iteration closes that gap: `oc_export_picker` without a
  presets file now prints setup guidance (`cp "$SCRIPT_DIR/../presets.json.example"
  "$OCED_PRESETS"`) and the raw CLI line, and dispatches nothing. `oc_pick_product`,
  `oc_export_flow` and `oc_export_manual_picker` are deleted; `oc_export_manual_rows` was
  renamed `oc_selection_rows` (the session/ALL rows reused by every preset run).
  `plan.py products`/`products --legend` stay as the API surface for the CLI and tests —
  the menu no longer consumes them (recipe for a future interactive guide). Menu answers:
  the "API" is the `plan.py`/`flags.py` bash↔python bridge, unchanged.
- **Shrinks manager** — new `oced_shrinks` (`shrinks list [--tsv]|view <stamp>|remove
  <stamp> [--yes]|prune <N>`) over `$OCED_BACKUP_DIR/shrink/<stamp>/`, mirroring
  `exports`. New pickers: a dedicated root entry `shrinks` (create + manage in one picker,
  toggle view/remove, bulk delete-all/keep-newest, `__CREATE__` first row) and the
  `__SHRINK__` row is gone from the backups picker. The picker rows come from the shrink.sh
  helpers (`shrinks_runs_find`/`shrinks_run_row`) — the same source as `shrinks list
  --tsv`, so no duplicated aggregation; fixed a bug where `oced_shrinks list` dropped its
  `--tsv` argument (did not forward `$@`).
- **Root header refresh** — `run_menu` already supported `--refresh-cb`; `run_oc_menu`
  now passes `oc_root_status`, so `ACTION_STATUS` (DB/sessions/WAL/backups/exports counts)
  recomputes every root loop instead of showing stale state after actions.
- **Uninstall fix** — the keep-`backups`/`exports` branch no longer uses an outdated
  reinstall list (`scripts/ tests/ uninstall.sh` …) that broke once `generated/presets.schema.json`
  became a shipped artifact; it now does a whitelist-keep `find` under `$PREFIX`
  (`! -name backups ! -name exports`), so stale files can never be resurrected.
- **Verified** — `tests/menu_flow.sh` reworked around the preset-only export flow +
  shrinks picker + header refresh (`102 OK`); `tests/export_smoke.sh` gained the shrinks
  CLI section (`list --tsv` row format, `view`, interactive/`--yes` remove, unknown
  stamps, `prune N`) — `175 OK`.

## §16 Guided workflow rework, pre-shrink folder, stale-shrink detection (later iteration)

The `guide` deferred in §15 was redesigned from scratch: the first fzf-picker attempt was
rejected ("este no es un modo guiado de verdad") — the workflow is fixed (export → shrink →
swap), nothing to inspect or choose in a menu. Final shape (decision log):

- **Linear guide (no fzf)** — Step 1 runs `oc_export_picker` (named-preset only) and prints
  where the export was written (`$OCED_OUT/<stamp>/`); Step 2 optionally builds a shrink copy
  via `oc_pick_shrink` (warning: using opencode after the shrink makes the copy stale — re-shrink
  before swapping); Step 3 optionally swaps by re-running `shrink --swap --yes`, requiring the
  user to type exactly `confirm`, and warning via `o_shrink_stale` when the copy is stale or its
  freshness is unknown. `--list`/non-TTY = plan-only. No snapshot is added: exports read the live
  DB (`o_effective_db`), the shrink does its own `.backup`, and the swap's safety copy is the
  rollback.
- **Pre-shrink moved to a managed folder** — `shrink --swap` safety copy now lives in
  `$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink-<ts>.db` (was `$OPENCODE_DB.pre-shrink-<ts>`
  next to the live DB), auto-keeping only the most recent copy. It is **not** a `backups`
  manifest run (not listable/verifiable there); `shrinks verify` lists and cleans it.
- **Shrink temp snapshot + no orphan dirs** — a non-dry shrink snapshots to
  `mktemp /tmp/opencode-db-shrink-*.db` and only after `integrity_check`+`foreign_key_check`
  +`VACUUM` creates `shrink/<stamp>/` and `mv`s the copy in — a cancelled/failed run leaves
  nothing behind.
- **`shrinks verify [--tsv] [--yes]`** — new subcommand (interactive; `--yes` auto-removes
  orphan dirs + old pre-shrinks; `--tsv` emits `type<TAB>key<TAB>display` rows). Also reachable
  from the shrinks picker via a `__VERIFY__` row.
- **Stale-shrink detection (bug discovered by the user)** — the freshness check read
  `shrink.json` `.sessions.max_updated`, but `oced_shrink` never wrote that field, and the guard
  `max_updated > 0` silently treated old shrinks as "up to date". Fix: `oced_shrink` now records
  `sessions.max_updated` (copy's newest kept `session.time_updated`), and the check is one helper
  `o_shrink_stale <shrink.json>` used by `shrinks verify`, the (since removed) `guide.sh` Step 3 and the menu's
  remove mode — it warns when the live DB has newer sessions **or** when the field is missing
  (legacy copy ⇒ unverifiable, never silently "clean").
- **Docs/artifacts reorg (done here)** — moved `presets.schema.json` to `generated/` (with the
  `--docs` flags table), extracted the pre-redesign analysis into
  `docs/archive/export-analysis-2026-09-predesign.md`, and updated `docs/schemas.md`,
  `docs/architecture.md`, README and AGENTS.md to the new paths and contracts.
- **Verified** — `tests/export_smoke.sh` gained: `shrink.json` records `max_updated == live`,
  `shrinks verify` clean/stale/legacy cases (+`--tsv` stale row), pre-shrink in `pre-shrink/`,
  and a failed shrink leaves no orphan run dir — `183 OK`; `tests/menu_flow.sh` gained the
  `__VERIFY__` row + dispatch — `104 OK`.

## §17 Shrink recipes redesign + export snapshot coordination (later decision)

> **Superseded in part by §19**: the *selection* was removed from the recipes and the
> create flow became sessions-first. The python-SSoT extraction and the export
> `snapshot: fresh` coordination described below still stand.

The shrink recipes (`lean`/`recent`/`full`/`bare` + custom) were extracted from
`shrink.sh`/`menu.sh` literals into a python SSoT mirroring the export-presets
architecture (user confirmed the 4-decision plan: "procede"):

- **`modules/shrinklib/` — the shrink SSoT** — `flags.py` owns the recipe flags
  (`keep`/`older_than`/`since`/`keep_all`/`keep_sessions`/`discard_sessions` +
  `strip_reasoning`) + the built-in plans (`DEFAULT_SHRINK_PRESETS`:
  `lean`=`keep 10 + strip`, `recent`=`older_than 90`, `full`=`keep_all + strip`,
  `bare`=`keep 10`), `presets.py` validates `$OCED_SHRINK_PRESETS` (exactly ONE keep
  rule; unknown keys die; ids arrays non-empty) and merges it **over** the built-ins,
  `plan.py` resolves rows/descr/purpose/plan/bake/selection for the CLI + the menu
  (the `{"rule","ids"}` shape for the keep/discard offers), `bake_args` turns a name
  into raw flags (`--keep 10 --strip-reasoning`, `--discard-sessions ses_…`).
  New union report: keep-sessions vs discard-sessions are now explicit rules instead
  of an opaque `--keep`; the bake order keeps "last one wins" for `--keep N`.
- **`shrink --keep-sessions / --discard-sessions`** — session-level selection with the
  same tree semantics as everything else: `keep_sessions` yields the **closed** kept set
  (a kept session keeps its parents/subagents), `discard_sessions` keeps *everything
  except* the listed ids + their subagents (the discard set is descendant-closed ⇒
  FK-safe by construction), and the CLI prints the first-step hint
  `opencode-db export memory --sessions <ids>`; the menu turns the discard case into an
  actual pre-run export offer (keep_sessions just warns). `shrink.json` records
  `.selection` in the `{"rule", …}` shape the menu consumes.
- **Generated artifacts** — `generated/shrink.schema.json` + `generated/shrink-flags-table.md`
  are now generated by `scripts/generate_schema.py` (second SSoT branch; `tests/validate_schema.py`
  gained the `array` type so the ids presets are checkable — the example `spring-clean`
  uses `discard_sessions`). Anti-drift checks both artifacts against the generator output.
- **Export `snapshot: fresh`** — a SINGLE-preset-only workflow key (business rule: you
  can't make "one snapshot decision" per product in a bundle). Semantics from the user:
  no new snapshot file, no backup-side changes — the export reads the live DB read-only
  and only **coordinates**: the CLI warns when no backup exists or the last one diverged
  from the live DB (`_backup_aligned`, same sessions/messages/max_updated triple as the
  menu's `o_backup_aligned`); the menu offers a fresh `backup` first. Skipped under
  `--from-backup` (source already is a snapshot). The plan listened to the user: "no
  shipping the -wal flag", "the CLI does not change its behavior for non-snapshot
  presets".
- **Wiring** — `OCED_SHRINK_PRESETS` joins `common.sh` `load_conf` (env > conf > default
  `~/.config/opencode-db/shrink-presets.json`), conf example, `install.sh` auto-create
  (600), and the `opencode-db help` shrink block now comes from
  `shrinklib/flags.py --help-shrinks` (static fallback), same as the exports block.
- **Verified** — `tests/export_smoke.sh` gained keep/discard closures + FK-clean +
  `.selection`, file-preset bake/override/unknown/`--list-presets`, shrink.schema.json
  validation, and the snapshot warn/no-warn triple — `200 OK`; `tests/menu_flow.sh`
  gained the shrink preset rows/offers and the snapshot backup offer — `115 OK`.

## §18 Shrink menu rework: custom-on-preset, sessions toggle, swap entry + naming/dedup (later iteration)

> **Superseded in part by §19/§20**: `__CUSTOM__`/`__SESSIONS__`/`__DRYRUN__` are gone,
> replaced by the sessions → recipe → plan wizard. The SWAP entry, the
> naming/dedup and the single-sourced help described below still stand.

Follow-up to §17, from the user's 4 answers ("procede, sobre last y oldest deben restar
de la seleccion"): the shrink **create** flow and the **shrinks manager** were rebuilt,
and the export entry/naming + shrink help strings were unified.

- **Custom = base preset + tunings** — the loose standalone custom wizard
  (`oc_pick_shrink_custom`) is gone. `__CUSTOM__` first picks a **base preset**, then
  `oc_shrink_adjust_pick` tunes `N`/days/since/strip: `--keep`, `--older-than`,
  `--since` (format hint `YYYYMMDD`, the picker prints the DB's real
  `min..max time_updated` range to **stderr** — the stdout contract stays clean for the
  `runargs`), and a strip toggle. It prints the raw flags to run (base + tunings,
  `shrink bare --strip-reasoning`): the bash engine's "last one wins" makes the last
  rule the final one; strip is additive only. The plan block comes from
  `oc_shrink_confirm_custom "$runargs"`.
- **Sessions on/off picker** (`__SESSIONS__`) — reuses the session/ALL rows as
  run-time state, like the export picker. `[x]` = survive (default: **all marked**);
  bulk rows `__ALL__`/`__NONE__`/`__LAST__ <N>`/`__OLDEST__ <N>` — the last two
  **restan de la selección**: unmark EVERYTHING first, then mark only the N most
  recent (`ORDER BY time_updated DESC, LIMIT N`) / oldest (ASC). `__MAKE__` (first row)
  builds the copy: nothing unmarked = `--keep-all` (zero friction); some unmarked =
  offer `export memory --sessions` first, then `--discard-sessions <csv>` (the discard
  set is descendant-closed, so it is FK-safe by construction); nothing marked = guard
  "the copy would be an EMPTY database" and loop. Session rows are toggleable
  individually (a loop picker — no fzf `--multi` anywhere).
- **Swap inside the shrinks manager** — `oc_shrinks_rows` gained a `__SWAP__` row
  (always visible, before the view/remove toggle): pick a copy, `o_shrink_stale`
  warns first (stale OR unverifiable — max_updated missing), then the hard gate
  `oc_confirm_typed "confirm"` (extracted from the now-removed guide.sh, now reused by both) hands the
  path to `oced_shrink_swap` (pre-shrink WAL-safe snapshot + rollback unchanged).
  `__VERIFY__` stays as the manager's `shrinks verify`.
- **Naming** — `modules/export.py` (a 4-line shim) is **gone**: `exportlib/cli.py` is
  self-bootstrapping (adds `modules/` to sys.path when run directly, mirroring
  `shrinklib/plan.py`), `export.sh` calls `python3 "$SCRIPT_DIR/exportlib/cli.py"`, and
  `run_bundle()` re-executes `exportlib/cli.py <product> …`. The `shrink --help` +
  `shrink presets` block is now single-sourced in python: `shrinklib/flags.py` gained
  `--usage` (`usage_main_shrinks()`) + a sys.path bootstrap (it was silently falling
  back in the dispatcher before), and the bash `criteria` case in `shrink.sh` delegates
  to the new `plan.py rule-line <rule> [value] [strip]` (same human phrases as
  `rule_lines()`).
- **Misc** — `install.sh` ships `shrink-presets.json.example` to the prefix;
  `presets.json.example` showcases `snapshot:"fresh"` + `sessions`/`filter` selection.
- **Verified** — `tests/menu_flow.sh` gained the custom base+tunings flows, the
  sessions toggle matrix (ALL/NONE/LAST-2/OLDEST-1/single-toggle/EMPTY guard),
  the SWAP fresh/stale/typo cases (`oced_shrink_swap` stubbed, `opencode.shrunk.db`
  fixture per run) — `133 OK`; `tests/export_smoke.sh` — `200 OK`; install smoke with
  the shrink example in the prefix runs `status`/`shrink --help` offline.

## §19 Shrink create flow: sessions first, operations second, plan last (later decision)

> **Superseded in part by §20**: step 2 became **recipe-only** (no operation toggle, no
> `__GO__` row) and the sessions picker gained a newest-first/oldest-first order toggle.

The §17/§18 model put the *selection* inside the named recipe and left the menu as a
recipe + tuning wizard. The user's read of the real workflow killed that: nobody thinks
"which conversations do I keep?" in terms of a preset name, and asking for a recipe
first made the copy's fate depend on a config file before anyone had seen the
sessions. Decision: **three steps, no other way in** — sessions → operations → plan.

- **Two disjoint families, one SSoT** — `shrinklib/flags.py` now exports
  `KEEP_RULE_KEYS` (selection: `keep`/`older_than`/`since`/`keep_all`/
  `keep_sessions`/`discard_sessions` — **CLI flags only, never recipe keys**) and
  `OPERATION_KEYS` (`strip_reasoning` — the **only** valid recipe keys).
  `generated/shrink.schema.json` therefore no longer has a `oneOf` keep rule: a recipe
  is an object with operation properties only. A keep rule inside a recipe is rejected
  by `presets.py` with a pointer to the matching flag (better than a schema error
  message a user has to decode).
- **Built-ins became operations-only** — `lean` (strip reasoning) and `quiet`
  (prune + vacuum, no op) replace `lean`/`recent`/`full`/`bare`, which had selection
  baked in and were therefore unreusable across DBs. `shrink lean` now means "the
  default selection (10 most recent) + strip", and `shrink lean --keep 30` keeps 30 and
  still strips: the baked op flags are prepended so the CLI selection still wins.
- **Step 1, sessions (roots only)** — `oc_shrink_sessions_pick` lists
  `list --root` rows: a subagent always follows its root, so it never needs a row, and
  an orphan whose parent is gone *is* a root. `[x]` = survives (default all marked), a
  recursive `(N sub)` badge shows what each root drags along, and the bulk rows are
  `__ALL__`/`__NONE__`/`__LAST__ <N>`/`__OLDEST__ <N>`/`__DAYS__ <N>` (the age ones
  **rest** the selection: unmark all, then mark the N most recent/oldest/recent-by-
  `time_updated`). `__MAKE__` = **continue**, not "build": all marked →
  `--keep-all`, unmarked roots → `--discard-sessions <csv>`, nothing marked → refused
  ("the copy would be an EMPTY database").
- **Step 2, operations** — `oc_shrink_ops_pick` shows the recipe rows
  (`shrinklib/plan.py rows`/`ops-flags`/`op-lines`) + a `__STRIP__` toggle + `__GO__`:
  a recipe applies its ops and jumps to the plan, a toggle stays so ops can be
  combined. This is where the presets file earns its keep, and it is a **toggle set**,
  not a single profile: the ops are additive, so the menu can compose them.
- **Step 3, the plan** — `oc_shrink_confirm_run` prints the exact read-only numbers
  **on the LIVE DB with the engine's own predicates** (`o_shrink_sql_ids` +
  `WITH RECURSIVE` closures): kept roots + subagents, the discarded cascade, rows per
  table, reasoning parts, current size. The `export memory --sessions <ids>` offer
  still fires before discarding; then the y/N gate. Rationale: a confirmation that
  cannot quote the engine's own counts is decoration.
- **Removed** — `__CUSTOM__`, `__SESSIONS__`, `__DRYRUN__` rows and
  `oc_shrink_adjust_pick`/`oc_shrink_dry_pick`/`oc_shrink_confirm_custom`/
  `oc_shrink_preset_run`: the sessions picker *is* the custom flow and the plan
  *replaces* the dry-run. The CLI keeps `--dry-run` and the full selection flag set for
  headless use. ESC climbs: operations → sessions (marks intact) → cancel.
- **Config migration** — a recipes file that carried a keep rule (the interim
  `~/.config/opencode-db/shrink-presets.json` with `keep`) is now invalid, so the
  installed example ships `lean`/`quiet` only and the loader dies loudly on the old
  shape instead of silently ignoring it.
- **Verified** — `tests/export_smoke.sh` covers the ops-only schema, the
  keep-rule-in-recipe rejection, `bake` + explicit-override and `--list-presets`
  (`205 OK`); `tests/menu_flow.sh` covers the roots-only rows and badge, the bulk
  matrix, the EMPTY guard, the operations toggle + recipe rows, the snapshot-fresh
  backup offer and the plan confirm/reject (`144 OK`).

## §20 Recipe-only second step + recency-ordered sessions (current)

§19 solved *where* the selection is asked, but two things were still wrong in the real
flow, both reported from using it.

- **The operation toggle was a lie about the model.** §19's step 2 mixed recipes
  (`lean`/`quiet` + file recipes) with a `__STRIP__` toggle and a `__GO__` row, so the
  user could compose operations *in the picker* while the reusable, shareable unit — a
  recipe in `$OCED_SHRINK_PRESETS` — could not be. A recipe then silently replaced the
  toggles, and the "continue" row added a third way to say the same thing as picking a
  recipe. Decision: **step 2 is the recipe and nothing else**. Every row is a named
  ops-only recipe, picking one bakes its operations and goes **straight to the plan**
  (y/N). Composition belongs in the recipes file, where it is shareable and testable;
  `__STRIP__`/`__GO__` are gone. ESC there climbs to sessions with the marks intact.
- **The session order was the wrong default.** The picker inherited the CLI's
  `created-asc` (oldest first), which is the *worst* order to decide "what do I keep?":
  recency is what users actually reason about. `list` gained
  `--order created-asc|created-desc|updated-asc|updated-desc` (whitelisted in
  `OCED_LIST_ORDERS`, default unchanged for the CLI) and the picker opens
  **`updated-desc`** with an `__TOGGLE__` row for `updated-asc`. Because the rows are
  re-read on every render, the marks had to stop being "absent = unmarked": they now
  live in a 1/0 assoc array that is never unset, so re-sorting (or a bulk row) cannot
  resurrect an explicitly unmarked session. `time_created` is the tie-break in every
  axis.
- **The plan names the recipe** (`Recipe: <name> - <purpose>` + the effective
  `Command:`), so what will run is always visible before the gate; declining re-renders
  the recipe rows to choose another one.
- **Fixture note** — the fake DB's roots had to disagree across the two axes
  (`B` used more recently than `A`, the orphan newest on both) for all four orders to
  be distinguishable, while `shrink --keep N` keeps the same root as before, so the
  identity-based smoke assertions are untouched.
- **Subagents stay non-selectable** — measured on the real DB: 639.1 MiB of
  `event`/`event_sequence` rows belong to roots and 12.2 MiB (1.5%) to subagents, the
  heaviest being 1.7 MiB. Per-subagent discarding would need a new selection rule
  (a keep rule *plus* a "discard these subagents" set) for ~1% of the bytes, so the
  roots-only model stays: a subagent always follows its root.
- **Verified** — `tests/export_smoke.sh` `205 OK`, `tests/menu_flow.sh` `158 OK`
  (order axes, the order row and mark survival, recipe-only rows, `lean`/`quiet` jumping
  to the plan, the decline -> another recipe loop, ESC climbing, the plan's `Recipe:` /
  `Command:` lines).

## §21 Subagent inclusion in export (current)

§20 kept subagents non-selectable in the **shrink** flow, where the argument holds
(a subagent is 1.5% of the bytes and always belongs to its root). Export is a
different question — it is not about shrinking, it is about **what the document
should say**, and there the permissive default was actively wrong: a `--filter` or a
no-selection run pulled the whole tree in silently, and `memory` folded every
subagent into its root's corpus line, so there was no way to ask for a clean
roots-only corpus.

- **The bug behind the change.** Selecting a single subagent **without** its parent
  already exported it, promoted to a root. That is right, but it happened *by
  accident*: nothing in the code said "a subagent without its parent is a root", it
  just fell out of the hierarchy resolver. Once it becomes deliberate, the two
  questions separate cleanly:
- **Q1 — is a subagent in the export?** `--no-subagents`, one flag, **all three
  products** (`products=["*"]`). Not per-product: "roots only" is a property of the
  *request*, not of the document format, and a bundle asking for it in one product
  and not the other is incoherent.
- **Q2 — a selected subagent whose parent is not exported?** Default: keep it
  standalone (the "just that one subagent" use case, and the only reason a user
  selects a subagent by hand). `--no-orphan-subagents` offers the **closed set**:
  drop it instead, iterated to a fixpoint so a nested chain collapses one level per
  pass. Shipped as a flag, not as a preset default, because the default is the
  permissive one and presets exist to make the *chosen* behaviour repeatable.
- **A subagent is not "any row with a `parent_id`".** A session whose parent row is
  **gone** is an *orphan* = a root, everywhere: there is nothing to hide behind and a
  parent that can never be exported. Without this rule a deleted parent would make its
  children unselectable under `--no-subagents`, which is the opposite of what the
  flag promises.
- **The cascade in the menu is structural, not a rule.** The sessions picker gets a
  `subagents: shown ⇄ hidden` row (`get_sub_ids`, a new cfg key in the generic
  picker). While hidden the subagent rows are **not rendered**, so they can neither be
  marked nor reach the `--sessions` CSV — there is no second code path that could
  disagree with the display. The callback keeps arity: `hide_subs` is passed **only**
  when that row exists, so the roots-only shrink callback is untouched. A hidden run
  also pins `--no-subagents`, otherwise the "every session marked → run as configured"
  path would silently undo the guarantee.
- **Consequences recorded in the contract**: `metadata.json` grows
  `no_subagents`/`no_orphan_subagents`/`subagents_hidden`, where `subagents_hidden`
  counts what the flags dropped **from the matched set** (an exact `--sessions` list
  that never contained a subagent reports `0`, not a phantom number), and `index.md`
  only grows its `Subagents` row when a flag actually set one — a `null` flag must
  not change the artifact.
- **Verified** — `tests/export_smoke.sh` `223 OK`, `tests/menu_flow.sh` `178 OK`
  (drop counts, orphan-as-root, closed-set fixpoint, the lone-subagent default, all
  three products, the preset keys, the bundle propagation, the empty-set guard, the
  rendered/hidden toggle, the roots-only CSV, the pinned `--no-subagents`, the
  `subagents: hidden` confirm, marks surviving a toggle, and no regression of the
  roots-only shrink picker).

## §22 Recency moves to the CLI, and the confirmation states the EFFECTIVE selection (current)

Sections §17–§20 record the recency rows (`__LAST__`/`__OLDEST__`/`__DAYS__`) as they
were designed. They are gone now, and the reason is worth keeping:

- **A row that marks N most-recent sessions re-evaluated on every render is not a
  marking, it is a selection.** The picker already owns "which sessions are in this
  run"; a second mechanism that silently re-computes "the N newest" at run time makes
  the screen lie about what is selected (the count changes while you look at it) and
  duplicates a rule the engine already has. So the rows left both pickers (export and
  shrink, since `oc_session_picker` is shared) and the *only* bulk rows left are
  `mark all` / `unmark all`. The now-dead `oc_read_int` helper went with them.
- **Recency becomes a CLI selection rule, and it is not a preset key.** `export` gains
  `--last N` and `--since DATE` in the same mutex group as `--filter`/`--sessions`, with
  argparse validation (`--last 0` and `--last abc` are refused instead of silently
  meaning "everything"). They are listed in `CLI_ONLY_KEYS`, so `presets.schema.json`
  rejects them: the set they select changes every time they run, and a plan that pinned
  one would not be reproducible — the same argument that already keeps `out` out of a
  preset. `flags.py` remains the SSoT (one help line, the generated tables, `--help`).
- **`--last` counts ROOTS and closes the set, `--since` does not.** Ranking raw sessions
  would let `--last 2` return two subagents and drop the root they belong to, and would
  drop the subagents *of* the two roots it did pick. The first one is the `__LAST__` row's
  own semantic (it marked N rows of a roots-only list) and matches `shrink --keep N`, so
  `--last` ranks roots by `time_updated` and pulls in every descendant through a
  recursive CTE. `--since` stays a plain window over all sessions: a subagent inside the
  window is a legitimate hit, and a subagent whose parent is outside it is exactly the
  case `--no-orphan-subagents` exists for.
- **The bug this surfaced**: a bundle re-executes itself per product, and
  `bundle_child_argv` only forwarded the selection it knew about — so `--last 2` on a
  bundle printed "last 2 sessions" in the stamp index while both children exported
  everything. CLI-only selection flags have to be forwarded explicitly, like `--out`.
- **Provenance**: the effective rule is now recorded as `metadata.json` `.selection`
  (`{"rule": "all"|"filter"|"sessions"|"last"|"since", …}`), the per-product `index.md`
  grew a single `Selection` row, and the "matched nothing" error names the rule and its
  value. Three shapes of the same fact, all derived from `util.selection_rule()`.
- **The confirmation stopped being decorative.** `Filter: (preset as configured)` was
  true only when the preset had no selection of its own — the exact case the shipped
  `presets.json.example` does not contain (`this_week` pins a `filter`, `one_session`
  pins `sessions`), so a user who marked everything and picked `this_week` got a plan
  that said "ALL sessions" and a run that was neither. `oc_preset_run` now asks
  `plan.py selection` / `plan.py subagents` and prints `Sessions:` (who wins, and that
  the marks are ignored), `Menu adds:` (only the menu's own flags) and `Note:`
  (consequences a row cannot show). The duplicated `Spec:` CSV/descriptions are gone.
- **Copy pass**: one line of live state per render (`N/M marked · order · ESC: back`),
  a caveat line only when a switch has a hidden consequence, a `current → other` toggle
  row (the marker was still `[>]` here; §23 moves toggles to `[*]`), short root entries (`Export — pick sessions, then a preset`), and
  empty picker headers where the status line already says everything.
- **Verified** — `tests/export_smoke.sh` `240 OK`, `tests/menu_flow.sh` `195 OK`
  (the recency rules, their validation, `.selection` provenance, the `Selection` row, the
  bundle forwarding, and the four effective-selection cases of the confirmation).

## §23 One marker grammar, and a backups picker you can read (current)

Two complaints started this round, and they turned out to be the same complaint: the
rows did not say what they did. `backups` offered `verify` in the root entry while the
picker underneath could only delete, and a selected row jumped straight to a
confirmation — so the only way to learn what a backup contained was the CLI. Meanwhile
the same action wore different labels in different pickers (`view`/`remove`,
`newest first`/`oldest first`, `mark all`, `delete the olds (keep the newest)`), and the
one marker that did carry meaning (`[>]`, "this opens a flow") was also being used for
plain toggles.

**Decisions**

- **A marker is a verb, and there is one per class.** `[>]` flow (`__CREATE__`,
  `__SWAP__`, `__MAKE__`), `[?]` inspect (`__VERIFY__`), `[*]` toggle, `[<word>]` bulk
  action, `[x]`/`[ ]` per session. Reusing `[>]` for a toggle was the actual defect: the
  marker was decorative, so it carried no information.
- **A toggle row shows both states**: `[*] view  →  remove`, `[*] newest first  →  old
  first`, `[*] subagents: shown  →  hidden`. The current state is what a row is *for*, so
  it comes first, and the alternative has to be visible before you press it.
- **Flow rows lost their parenthetical.** `create backup (consistent snapshot)` and
  `create shrink copy (3-step wizard…)` explained themselves because the row was long, but
  the sub-picker header and the command output already say it. A row is a row.
- **`oldest first` became `old first`**: with the arrow in front of it, the long name
  pushed the destination off the edge.
- **The grammar is a contract, so it is a test.** `tests/menu_flow.sh` collects the rows of
  every picker (row producers *and* the pickers themselves, so a `[@@]` cannot hide in a
  function that never reaches `oc_fzf_sel`) and fails on: a token outside the allow-list,
  `[>]` on a non-flow row, `[?]` on a non-inspect row, a `__TOGGLE__`/`__SUBS__` row
  without `[*]`, and a sample that failed to render all eight tokens. The last check is
  the one that matters: without it a broken capture makes every other assertion pass
  vacuously. It was verified to fail on a deliberately invented `[@@]` token.
- **`backups` became `view`/`remove`, and `view` verifies.** Three shapes were on the
  table: a separate `verify` row, keep both, or fold the check into the details. The check
  is not optional information about a backup, so a details screen that omitted it would be
  a trap; a dedicated row would have meant the details were still reachable without it.
  Hence `backups view <file>` prints the manifest record, runs the sha256 check
  (`[OK]` / `[FAIL]` with both hashes / `[MISSING]`), shows how the copy compares to the
  live DB and ends with the `--from-backup` line. `backups verify <file>` stays in the CLI
  for scripting, and both share `oc_backup_sha_state` so the two can never disagree.
- **`o_backup_aligned` took an optional file.** It previously answered "is the *last*
  backup aligned?", which is right for `status` and for the `snapshot: fresh` warning. The
  view of an *older* copy is only correct if the same helper can be pointed at that copy,
  so `[file] [-v]` was added: no argument keeps the old default, a file makes the
  comparison specific.
- **The rows a mode must not show are gone from that mode.** `[delete all]` /
  `[delete olds]` appear only in `remove`, mirroring exports and shrinks; a view-mode
  picker that offers a delete row is a picker one keystroke from a destructive action.
- **Verified** — `tests/export_smoke.sh` `257 OK` (17 new: the whole `backups view`
  record, the embedded check, the live-DB line, the restore hint, usage, an unknown file,
  a tampered copy → `MISMATCH` with both hashes and a deleted one → `MISSING`, plus
  `verify` agreeing with `view` on both), `tests/menu_flow.sh` `207 OK` (12 new: the
  view/remove matrix, the exact row copy of both modes, and the symbol guard).

## §24 The export plan is flat: no label, no bullets, no nesting (current)

**Decision.** `oc_export_confirm` renders the whole plan flush left. The header rows
(`Source:`/`Preset:`/`Sessions:`/`Menu adds:`/`Output:`, plus `Note:` when the menu has
one) stay as-is with a `%-10s` label; below them each product gets **one line at the left
margin** with its description and effective flags on the lines *below*, a blank line
between products, and no `Will produce:` label, no bullet and no indentation anywhere.

**Why.** §14 introduced the block to show the per-product descriptions and the sanitize
caveat. It grew a label, then a nested tree, then a bullet per flag — three layers of
chrome to express what is really a flat list of two or three things. The hierarchy
carried no extra meaning (a product never has children), and the bullets cost the
alignment that made the block scannable. The user read the result as a data dump. So the
structure was removed rather than restyled.

**Nothing is hidden to get there.** The full `PRODUCT_INTRO` and the complete `bits`
string are still printed — only folded by `_wrap()` into a fixed `PLAN_WIDTH = 72`, so
the block is deterministic across runs. In particular `bits` is emitted verbatim and is
never re-split on `" · "`: that was the old `replace(" · ", "\n  - ")`, which could only
prefix the 2nd..Nth bit, so the first one lost its marker and rendered one column off
(`" +faithful JSON…"` instead of `"  - faithful JSON…"`). Without bullets that bug class
cannot come back.

**Notes are not products.** The caveats (raw/unfiltered faithful JSON, sanitize) used to
sit inside the tree as a line that read like a third thing being produced.
`notes_text()` moves them to their own `-> Notes` block, derived from the plan's own
`has_json`/`has_sanitize` — never hand-written — and returns `""` when a plan has nothing
to warn about, so the menu prints no block at all. The CLI exposes both halves
(`plan <profile> [--width N]`, `notes <profile> [--width N]`) so `menu/export.sh` never
formats anything itself.

**Verified** — `tests/menu_flow.sh` `227 OK` (13 new guards: no `Will produce:`, product
name at the margin, flush left, no bullets/levels, every line ≤ 72, `OCED_PLAN_WIDTH` and
`plan.py PLAN_WIDTH` pinned to the literal 72, the intros/flags survive the rewrap, notes
present once when there is something to warn and absent when there is not, and the
standalone-subagent `Note:` row kept in the header). Each structural guard was mutation
checked: re-indenting `_product_block` or reinstating the `"  - "` bullets fails the
suite, and raising either width knob to 200 fails the two width guards — the width
assertion compares against the literal `72`, not against the same variable it is testing,
which would pass if both moved together.

## §25 metadata.json gains `session_records`: which sessions the run contains (current)

**Decision.** A new `session_records` array (one entry per written session: `id`, `title`,
`kind`, `parent_id`, `created`, `updated`) records WHICH sessions a run actually contains.
Never capped. Nothing was repurposed: `.sessions` stays the aggregate `{total, roots,
subagents}` and `.sessions_selected` stays the REQUESTED ids.

**Why.** The gap was real rather than cosmetic. `sessions_selected` is only populated when
`--sessions` was passed at all, and even then it records the request, not the result — so with
`filter`/`last`/`since`, or after `--no-subagents` dropped or cascaded subagents, `metadata.json`
held no record of the resulting set. That is why `exports view --json` could return metadata
records whose only hint of content was three counts. The user asked for the sessions to be
listable, and the honest answer was that the exporter had been throwing that information away.

**One source of truth, and no duplication.** Two worries were raised and both shaped the
design:

- *Is a new key redundant with `.sessions`?* No — it is the other direction. `.sessions` is the
  **summary** of `session_records`, derived from the same list, so the counts stay consistent
  by construction (`records == total`, and the root/subagent tallies match). The records add
  the identity that the counts could never carry.
- *Do per-session fields duplicate anything?* Only counts would have, and they were left out
  on purpose: `messages`/`compactions` already exist as totals at the top level, so a second
  copy would be a second number to keep in sync for nothing. Records are identity only.

**Built from `written`, never from a second query.** `_session_records()` walks the same list
of `(root, subagents, folder)` tuples that created the directories, so it cannot disagree with
what is on disk: a cascaded subagent is recorded as present, a dropped one as absent, and an
orphan (parent row gone) as `kind: root` while keeping its dangling `parent_id` verbatim —
the same rule the counts use, not a second opinion.

**Verified** — `tests/export_smoke.sh` `286 OK` (18 new). The guards were mutation-checked:
emitting only roots, classifying everything as `root`, `""` instead of `null`, a raw epoch
instead of an ISO date and id truncation each fail the suite. One guard is explicitly
non-vacuous (`the run really did include subagents`): the first version of this section
filtered on a root title, and a title filter like `%Project Alpha%` matches **no** subagent
at all, so every subagent assertion passed against a set that had none — the unfiltered run is
the only meaningful one. `exports view --json` asserts that *some* record carries the key
rather than reading `[0]`, because that command aggregates every run of the stamp and older
runs predate it.

## §26 The plan drops operator symbology: one thing per line, plain prose (current)

**Decision.** `annotate_flags()` returns a **list** of phrases and `_product_block()`
renders each on its own line. The `' · '` joiner and the leading `+` marker are gone, and
`PRODUCT_INTRO` lost its `—` and `+`. A bare product keyword prints
`Default options, no flags set` as its own caption. The notes were cleaned the same way
(`&` and the `!` prefix are gone; `SANITIZE_WARN` no longer opens with a bang or an em dash).

**Why.** The flat block from §24 was still cluttered. The line

```
+faithful JSON (raw, unfiltered) · full tool outputs
```

read as an *expression*: the `+` looked like an operator and the `·` like a multiplier, so
the line said "add A times B" instead of "this export adds A and adds B". Worse, the `+` was
an artefact, not a marker: it had been a bullet prefix that survived the loss of its
siblings, so it pointed at nothing while the second item lost its own marker entirely — the
same `replace(" · ", "\n  - ")` bug noted in §24, wearing a different hat.

**Why each item on its own line rather than a labelled list.** The remaining choices were
a `key: value` per flag (repeats the flag name as noise the user does not read) or an
`adds` prefix on every line. Plain prose wins because the block has no indentation to build
a hierarchy with anyway (§24 already removed it): the description is the first line under
the product name and everything after it is a thing the export adds. Distinguishing them by
*position* rather than by markup is what keeps the block free of symbols.

**Verified** — `tests/menu_flow.sh` `231 OK`. One guard rejects the whole class at once
(`^[+*-] `, `' · '` or `—` anywhere in the block) plus per-item `grep -qxF` checks that each
phrase is on a line of its own. Mutation-checked: restoring the `+`, restoring the
`" · ".join(...)`, and restoring the em-dash `PRODUCT_INTRO` each fail the suite.

## §27 The guide is removed; the pickers ARE the workflow (current)

The interactive `guide` (`opencode-db guide` + the root menu entry) is **deleted**: `modules/guide.sh`,
its dispatcher wiring and its menu row are gone from both paths, and a smoke assertion keeps it gone
(a silent alias would still leave the wizard on disk).

**Why.** Three failures, in order of how they hurt:

1. **It only reacted to Enter.** `run_oced_tool` (the menu's single entry point for any command) runs
   `out=$(bash "$OC_DISPATCHER" "$@" 2>&1)`, so every byte the wizard printed sat in a buffer and was
   flushed *after* it exited. `oc_guide_ask` printed its prompt into that buffer, then blocked on
   `read` from a terminal fzf had just left in a raw state: the user saw no prompt, typed nothing, and
   Enter alone "answered" it. Reproduced with a pipe, where the wizard printed
   `(non-interactive input: showing the plan only)` and did nothing at all.
2. **The prompt appeared out of order** — after `Cancelled.`, on the same line, because the buffered
   `printf` was flushed after the `read` had already returned. A pure buffer-ordering artefact of (1).
3. **It was redundant.** The three steps were already first-class fzf pickers: exports
   (`[>] create export`), shrinks (`__CREATE__`, and `__SWAP__` for the destructive swap, which already
   runs `o_shrink_stale` + `oc_confirm_typed`). The guide added no logic over them, only a narration
   of a workflow you can already walk — and it wrapped that narration around a *second* navigation
   model (`read`-from-stdin steps wrapping fzf sub-pickers), which is what made it fragile.

The one thing the guide claimed as its own — swapping **the copy you just built** — is not lost: the
shrinks picker makes you pick the copy explicitly and warns when it is stale or unverifiable, which is
strictly safer than trusting a stamp carried across three nested wizards.

**Kept:** `oc_confirm_typed` and `o_shrink_stale` were extracted from `guide.sh` and are now shared by
the shrinks picker's `__SWAP__` and remove modes, so deleting the wizard deletes no live behaviour.
The safety rationale moves to `docs/architecture.md` §6 and `docs/export-guide.md`, which are where a
reader asks that question.

## §28 Navigation: one list, one rule (current)

**The bug.** Enter after a report jumped to the **main menu** instead of the list you came from —
but only in `exports view`, `backups view` and `shrinks view`; `sessions` browse behaved, and so did
every *removal*. After a finished export it went to the main menu too.

**Why it is a bug and not a design.** `run_menu` calls a picker with `_oc_menu_call` and, when the
picker function **returns**, just `continue`s: the ROOT menu is rebuilt. There is no back-stack, so a
picker cannot "go back" to itself — it must not return. Two conventions had drifted apart:

| path | code | destination |
|---|---|---|
| `sessions` browse report (`core.sh`) | `continue` | stayed |
| remove paths (`confirm_action … \|\| continue`) | `continue` | stayed |
| `exports`/`backups`/`shrinks` view (`menu_pause …; return 0`) | `return 0` | **root** |
| export wizard after a run (`menu_pause "Export"; return 0` + `__CREATE__ → return 0`) | `return 0` | **root** |
| shrink create (`__CREATE__) oc_pick_shrink; continue`) | `continue` | already correct |

So the rule that shipped was "mutating actions stay, reports leave", which is the opposite of what a
menu should do and the opposite of what the sessions picker had been doing all along.

**The rule now.** One idiom everywhere:

```bash
menu_pause "<label>" || return 0   # ESC  -> close this submenu (main menu)
continue                          # Enter -> redraw THIS list
```

`menu_pause` returns 0 (Enter) or 2 (ESC), so the `|| return 0` is the ESC exit and it already
matched the advertised meaning ("exit this submenu"). The label was lying about the other half and
now says `Enter: back to the list · Esc: main menu`.

**Where the pause lives.** A deep wizard must not own the pause, because it does not know which list
to return to. The wizard reports only *did it run* through its rc (`0` = ran, `130` = ESC'd out) and
the frame that OWNS the list pauses and decides:

```bash
oc_export_picker
[ $? -eq 0 ] || continue          # ESC out of the wizard: no pause, stay in the list
menu_pause "Export" || return 0
continue
```

This is what fixed "after an export, Enter goes to the main menu": the wizard's `return 0` used to
mean "back to the root", and now it only means "I ran". The `__CREATE__` branch that called it is the
one that knows the destination. `n` at the confirm is unchanged — `oc_preset_run` fails, the preset
picker `continue`s, so declining still returns you to the presets.

Three paths had **no pause at all** and were flashing their result away before redrawing: a created
backup (`run_oced_tool backup; continue`) and a built shrink copy. They now pause too, each with a
label naming the action (`Export`, `New backup`, `Shrink copy`) instead of the list, so the pause can
never be read as "you are looking at a report".

`oc_shrinks_swap_pick` already owned its pause and swallowed it with `|| :`; it now **returns** the
pause rc so `__SWAP__` can propagate an ESC — the one place the rule needed a return value rather than
a `continue`.

**Guarded.** `tests/menu_flow.sh` gained 14 assertions. The discriminating one is structural: the fzf
stub pops ONE selection per render, so "the picker survived the pause" is proven by a *second queued
row being dispatched* (a picker that returns would dispatch only the first), and "ESC closed the
submenu" by exactly one render and rc 0. Each of the three reverts was checked to fail the suite.

## §29 The id column: short in the label, full in the key (current)

A menu row is `key<TAB>display` and fzf only ever shows `display`. The key was already the real
session id (marks, the `--sessions` CSV and every `run_oced_tool` call need it), but the display was
`${id#ses_}` — which on a real database is still 32 hex characters, so every row in the three
session pickers led with a 35-character id and the title/date columns were unreadable.

**The fix is one helper**, `oc_short_id`, because the three offending screens were never three
implementations: browse (details), shrink create (`mark the ROOT sessions that survive`) and export
create all render through the same loop in `oc_session_picker`. It strips `ses_`, cuts the rest to
`ID_LABEL_W - 1` characters and appends `_` as an explicit truncation marker — a real id reads
`f72115a_`, exactly the shape the row needs. The marker is the point: a truncated id that *looks*
complete is worse than one that admits it.

`ID_LABEL_W` is a variable rather than a literal because the point is the fixed width, not the number:
the title/date columns stay aligned across rows, which is what makes the rest of the row scannable.

**Nothing else changed.** The key is still the full id, so nothing downstream can be affected: a short
label that leaked into a CSV would silently export the wrong sessions, which is why the suite asserts
`export notes --sessions ses_A0001` (full) while the row it was picked from showed `A0001_`.

Deliberately NOT shortened: the `== Session (<id>) - <title> ==` banner of `info`, which is a detail
screen, not a list — that id is there to be copied, and it is a CLI contract the smoke suite pins.

## §30 The product is `digest`; a marker and a digest are two things (current)

The third product was called `compactions`, and the name was wrong in a way that leaked into every
artifact: the product has only ever written **digests**. What opencode stores is two different
things under the same word, and `docs/architecture.md` §2 already said so:

| | what it is | where it lives |
|---|---|---|
| **compaction (marker)** | the *event* opencode recorded — `auto`/`overflow`/`tail_start_id`, and **no text of its own** | `part.data.type = 'compaction'` |
| **digest** | the summary the model wrote *for* that event (Objective, Next Moves…) | the `text` part of the next message, whose `message.data.mode = 'compaction'` |

So `metadata.json` was counting markers under the same name the product used for digests, and
`export compactions` wrote digests. Nothing was *broken*, but every answer to "what is
`compactions` in this file?" needed a paragraph, and a transcript with more markers than digests (a
compaction interrupted before the model answered) made the number look wrong.

**Decided:** the product is **`digest`**; `metadata.json` records **both** counters —
`.compactions` (the markers) and `.digests` (the summary texts) — and they are never
interchangeable, which is why `db.py` selects them in two different subqueries instead of one.
A marker carries no text, so `compactions >= digests` always; both keys are present in *every*
product's metadata, so a consumer never has to guess which one it is reading. `docs/schemas.md`
§2 now carries that table, because it is a machine contract and not a detail.

**Old names are aliases, not errors.** `PRODUCT_ALIASES = {"compactions": "digest"}` in
`flags.py` (the SSoT) is normalised in `resolve_profile()`, so everything downstream — preset
lookup, rendering, `metadata.profile`, the plan — only ever sees the real name: `export
compactions` and `export digest` produce byte-identical runs, and the run records `"profile":
"digest"`. Same for the read-only command: `opencode-db digest <id> [show …]` with
`compactions` still dispatching to the same function, and `info <id> --no-digest` (the report
filter behind the browse screen's toggle) renamed from `--no-compactions`. `full` stays an alias
of `transcript`, which was already the alias-instead-of-a-second-product policy this tool
follows: a deprecated spelling costs one dict entry, a second name to remember costs everything.

**The generated artifacts followed** (`flags.py` → `scripts/generate_schema.py`):
`generated/presets.schema.json` and `generated/flags-table.md` now advertise `digest`, and the
anti-drift check in `tests/export_smoke.sh` fails if the committed pair ever diverges from what
the SSoT produces.

**What this did NOT fix on its own — the docs were the real drift.** After the rename, four
documentation files still taught `compactions` as the product (README, `docs/export-guide.md`,
`docs/architecture.md`, `docs/export-analysis.md`'s own historical entries) and, worse,
`docs/schemas.md` never documented the new `.digests` key at all — its `metadata.json` block
still showed only `"compactions": 2`, which would have been the *machine contract* disagreeing with
every run on disk. Nothing guarded that: the anti-drift check only compares `generated/`, and the
product table in `schemas.md` §1 is a hand-written summary of a generated one. All four were
re-synced, and `docs/export-analysis.md` keeps its old entries (a decision log records what was
decided then; §30 supersedes them) rather than rewriting history.

**Guarded by:** `tests/export_smoke.sh` — `run compactions ses_A0001` equals
`run digest ses_A0001` for the CLI alias, and `export compactions --filter …` writes the same run
with `.profile == "digest"` for the product keyword.

---

## §31 `verify` means every copy, and a list can say it all at once (current)

**The question behind the change.** With `status` deliberately being *the* check (§28) — read-only,
alignment of the **last** backup, schema probe, deps — the remaining gap was not "is my DB
healthy?" but "are my stored artifacts still worth anything?". Measured on the real install:
sha256 of a 163 MB `.gz` backup = 0.46 s (≈3 s for a full 1.1 GiB uncompressed copy), while
`exports view <run>` = ~0.2 s and `exports list` over 7 runs = 0.29 s. That single set of numbers
settled the whole design, because it splits the three managers by cost.

**`shrinks verify` was half a verification.** Its first two checks (orphan dirs, old `pre-shrink`
files) already walked *every* run directory, and the third one — freshness — asked
`o_shrink_stale "${runs[0]}/shrink.json"`, i.e. only the newest. So a shelf of three copies
reported the orphan living in the third directory and stayed silent about copies 1 and 2 being
stale: precisely the rows you would be choosing between. It now asks once **per copy**, keyed by
that copy's stamp in `--tsv` (`stale<TAB>20260927-162759<TAB>…`, was the literal `live_vs_shrink`),
and the clean verdict names the number it checked ("all 7 shrink copies are up to date"). An orphan
is reported **once**, as an orphan: `o_shrink_stale` on a missing `shrink.json` answers
"shrink.json missing", which would have counted the same broken directory twice.

**Why per-copy freshness and not "verify every copy when you open it".** The freshness of a shrink
copy only matters for the copy you are about to *swap*, and that path already asks about the one
picked copy (`o_shrink_stale` in `oc_shrinks_swap_pick`, plus the same check before a removal
warns). What was genuinely missing was the inventory question — "which of the copies I am keeping
are stale?" — which is cheaper to answer all at once than by opening N detail screens.

**Why backups did not get the same row.** `backups view` already folds its sha256 into the details
screen on purpose (§28: a details screen must not show an unvalidated backup), so the all-details
row would add nothing except the seconds per gigabyte above — a menu row that looks like a hang.
`backups verify <file>` stays the per-file CLI form; a whole-shelf hash belongs to a script. This
is also why no root `check`/`verify all` row appeared: `status` already covers health and deps, and
the only thing a global row would have added is the expensive half.

**`[>] details of all …`.** The sessions browse already had `[>] details of all sessions`; the
exports and shrinks pickers answered "what exactly do I have stored?" one screen at a time. Both
gained the same row (`__REPORT_ALL__`, view mode only, only when the list is non-empty, never
beside `[delete all]`), rendered by `oc_view_all` — one global header, then the *same*
`<manager> view <stamp>` the per-row branch runs, once per entry, and a single pause labelled after
the list. Using the per-row command is the point: a report assembled differently from the row it
summarises is how the two drift apart. The token stays `[>]` even though no flow opens, because it
prints the screens a row prints, all of them at once, and a fourth bracket token would have been
worse than the documented stretch; the symbol guard's allow-list admits `__REPORT_ALL__` explicitly.

**A trap found on the way, worth recording.** `tests/menu_flow.sh` (and `export_smoke.sh`) ended
with `trap 'rm -rf "$TMP"' EXIT`. bash runs an **inherited** EXIT trap in *every* subshell, so one
dying subshell — a single unbound variable under `set -u`, which is what a typo in a new assert
produced — fired `rm -rf "$TMP"` **mid-run**: the suite kept executing against a deleted fixture and
reported 100 failures that had nothing to do with the change. The trap is now guarded by
`[ "${BASH_SUBSHELL:-0}" -eq 0 ]`, so only the top-level shell can clean up. A test harness that
lets a subshell delete its own fixtures is not a harness, it is a coin flip.

**A flake that was the fixture's fault, not the code's.** Once `verify` asked about *every*
copy, an assert that had been green for months started failing about one run in three: "All
clean" after the `--swap` test. The cause is a plain fact about the suite — the copies left by
the selection tests are genuinely older than the DB the swap installed (`--keep 1` makes the
live DB newer than every copy that kept more), and the old one-copy check had simply never
noticed because it only ever asked about the newest dir. The `All clean` assert was therefore
never testing freshness; it was testing "the newest dir happens to be fresh". It now builds its
own backup dir with two aligned copies and asks about those, and the stamps are forced 1 s
apart because **the stamp is second-resolution**: two shrinks inside one second share a dir,
which silently halves the copy count. A green assert that leans on a shelf another test built is
not an assert, it is a coin flip.

**Guarded by:** `tests/export_smoke.sh` — one `stale` row per run dir, an orphan reported once and
never as stale, the stamp on each per-copy warning, and the "All clean" line naming the copy count.
`tests/menu_flow.sh` — the row in view mode and absent in remove mode for both pickers, one
dispatched `<manager> view` per entry, exactly one header, and the symbol guard with the sessions
browse **in the sample** (it was unsampled, so its existing `__REPORT_ALL__` had never passed
through the guard).

---

## §32 A captured command hides its own question (current)

**The report.** `[>] create backup` in the backups picker "froze, showing nothing": press the
row and the screen stays as it was until you press a key — and *then* the plan appears, followed
by `Backup cancelled.` Nothing had crashed; the backup simply never happened. This is the same
failure class as the guide wizard removed in §27 (a stdin prompt inside a menu), which is why it
is worth writing down twice: the first time we removed the culprit, the second time we removed
the *mechanism* that let it hide.

**Mechanism.** `run_oced_tool` ran `out=$(bash "$OC_DISPATCHER" "$@" 2>&1)` and printed `$out`
afterwards. The command substitution pointed the dispatcher's stdout at a **pipe**, so its plan
*and* its `Create this backup? [y/N]` went into the capture buffer instead of the screen; the
child then blocked in `read` waiting for a keypress the user could not see it was being asked
for. The keypress arrived (people press Enter when a UI looks stuck), reached the child's stdin,
and an empty line is not `y` — so the one thing that ended the freeze was the thing that
cancelled the work. A silent failure and a wrong answer, from one line of plumbing.

**Two blind spots, and that is why it survived.** `tests/menu_flow.sh` stubs `run_oced_tool` with
`call_log`, so the suite only ever sees the *call*, never the plumbing; and the real prompt is
behind `[ -t 0 ]`, false in every automated run. A bug in the interaction between a stub and a
TTY check cannot be caught by either. The second call site was worse than the reported one:
`oc_preset_run`'s `snapshot: fresh` offer already asked with `confirm_action`, then launched
`backup`, which asked a *second*, invisible question — and after pressing Enter it carried on and
exported **without** the fresh snapshot it had just been told to take.

**Fix, in the order the failure demanded.** First the mechanism: `run_oced_tool` now pipes the
dispatcher through `tee` (visible on the terminal, still captured in a log for the
`OCED_LAST_*_STAMP` extraction), so a command can never again hide a question. Then the contract:
**the frame that owns the list owns the gate.** `__CREATE__` became plan → our gate →
non-interactive run, which is exactly the shrink wizard's shape, and it needed a flag to exist —
`backup --dry-run` prints the plan and returns, the mirror of `shrink --dry-run`. No `[y/N]` of
the command's own is ever reached from the menu now, because the menu passes `--yes`.

**Why the pty test exists even though it is awkward.** The property is "output reaches the screen
before the process exits", which no stub can fake and no pipe can show. `script -t<file>` records
*when* each chunk arrived: with `tee` the plan lands at ~0.01 s, with `out=$(…)` it lands at
~2.0 s, together with the answer — 4 ms and 2 s apart, unambiguous. It is skipped loudly when
`script` is missing, and two structural guards back it up (`core.sh` may not contain
`out=$(bash "$OC_DISPATCHER"`, and no bare `run_oced_tool backup` may exist in `modules/menu/`),
because a guard that only runs where `script` exists would be a guard that silently does not.

**The general rule.** *A menu action is not done when the command returns; it is done when the
user has seen the answer and the menu has asked its own question.* If the frame cannot see the
output, it cannot own the gate — which is the deeper half of why `guide.sh` had to go.

**Guarded by:** `tests/menu_flow.sh` — create flow is exactly `backup --dry-run` then
`backup --yes` (order and count), a declined gate shows the plan and creates nothing, no bare
`backup` call survives anywhere in the menu, plus the structural and pty guards. `tests/export_smoke.sh`
— `--dry-run` prints the plan and writes no file, no manifest entry, asks nothing;
`--dry-run --yes` still writes nothing.

## §33 The user-facing guide had drifted from the code (current)

`docs/export-guide.md` is the doc a user reads *instead of* this file, so drift there is worse
than drift here: the design log can be old, the guide cannot lie. A pass comparing it against the
menu found four false statements, one of them a **safety** claim.

**`share` does not sanitize.** The guide (and a `presets.json` snippet in the README) still
listed `share` as `transcript (json + sanitize + no_reasoning)` — "sanitized, no reasoning", with
a decision-matrix row telling you to "verify output before sharing". §14 had already decided the
opposite and said the guide was updated: the redaction patterns were narrowed to high-confidence
prefixes only, so a plan that silently redacted *part* of the content would promise a safety it
cannot keep, and `sanitize` was dropped from the shipped example. The guide was never actually
rewritten. A user could have published secrets believing they were redacted — the exact failure
mode `--sanitize` exists to make obvious. `share` is now documented as `json + no_reasoning`, with
`--sanitize` as a per-run flag the reader must ask for on purpose, and the README snippet is on
the same list (still open at the time of writing).

**The menu's `Menu adds:` row never emits a flag.** The guide explained it as `--no-subagents`
"when the subagents switch is hidden" — the pre-§29 design. Since the hidden switch stopped
rendering those rows at all, the roots-only guarantee became *structural* and the cascade is
expanded into `--sessions` instead, so the row reads `nothing` or `subagents cascaded from
selected roots`. Documenting the old flag would have taught a user to grep for a flag that is never
written.

**There is no manual menu flow.** §2 claimed "the menu's manual flow (no presets file) uses exactly
these defaults" while §3 of the same file correctly said the picker prints setup guidance and falls
back to the CLI (§27 removed the flow). A document that contradicts itself is worse than one that
is merely old, so §2 now only describes what the CLI and an unconfigured plan do.

**The shipped example grew three plans the guide never mentioned.** `backup_then_full`
(`snapshot: fresh` + full tool outputs), `this_week` (pins a `filter`) and `one_session` (pins
`sessions`) shipped with §13's recency work; the guide's plan table still listed six. The two
pinned-selection plans are the interesting ones: they are precisely the cases §13's decision log
uses as the argument for why the confirmation had to become non-decorative, so a reader who met
them here would already know what `Sessions:` is for.

Added: a `## 3b. Managing your runs` section, because §3 documented *creating* a run and nothing
about the three lists that manage them — the `[*] view → remove` toggle, `[>] details of all …`,
`[?] verify` auditing every shrink copy, and the plan-before-gate backup create (§32).

**Removed dead code with the last caller.** `oc_selection_rows` (the `__ALL__` + session rows of
the deleted manual flow) had no production call site since §27; the only thing still invoking it
was a test asserting its own first row. The real `[mark all]` row is emitted by `oc_session_picker`
(`core.sh`), so the function, its test and its mention in `AGENTS.md` went together. A test that
only proves a dead function still returns what it always returned is not coverage — it is a
ratchet holding the corpse in place.

**Verified** — `bash -n` over every script, `tests/export_smoke.sh` `322 OK / 0 FAIL`,
`tests/menu_flow.sh` `295 OK / 0 FAIL` (one fewer: the deleted dead-code assertion), `git diff --check`.

**The recurrence guard: the README snippet is now compared, not trusted.** `export_smoke.sh`
grows a third anti-drift check next to the two `generate_schema.py` ones: it extracts the single
`json` block the README prints and asserts it **equals** `presets.json.example`. The reason is the
shape of the bug itself — nothing in the build could ever catch it, because a doc that misdescribes
the shipped example is perfectly valid JSON. A doc is only trustworthy about a flag when something
machine-checksable stands between it and the reader, and there are now three such things in a row:
the schema, the generated artifacts, and this snippet. It is the one assertion in the suite that
fails on prose, which is exactly the category that had been drifting.

## §34 One decision, one plan (the backup plan appeared twice)

§32 fixed the backup create flow so the user could see it: `backup --dry-run` printed the plan,
the menu asked its own y/N, and `backup --yes` ran it. It was reported as fixed because the
mechanism was right — and then the user came back with the obvious follow-up: **the plan appears
again after answering `y`.**

**Cause.** `oced_backup` printed `-> Backup plan` unconditionally, *before* both the dry-run early
return and the `--yes` check. The menu calls the command twice by design, so the one block that
was supposed to be shown exactly once was printed twice on one screen — and twice for the *same*
decision, which is why it read as a repeat rather than as two things.

**Why the suite was green.** `tests/export_smoke.sh` asserted that the output of `backup --yes`
contains `Backup plan`, `Est. size:` and `Target:`. The bug was not merely uncaught: it was
**pinned as a contract**. A test that requires the defect is worse than a missing test, because
the next reader treats the defect as a decision and defends it. (The same test now asserts the
opposite — `backup --yes` must NOT contain the plan, and must still report `[OK] Backup:` — and
the plan's fields moved to the `--dry-run` assertions, where they belong. Guard verified
non-vacuous: restoring the unconditional print fails it.)

**The rule, and the matrix.** The plan belongs to whoever owns the gate. `--yes` *means* "the
caller owns the gate", so it prints no plan; `--dry-run` always prints it, because that is its
entire job.

| call | plan | asks | writes |
|---|---|---|---|
| `backup` (tty) | yes | yes | after `y` |
| `backup` (no tty) | yes | no | yes |
| `backup --dry-run` | yes | no | no |
| `backup --dry-run --yes` | yes | no | no |
| `backup --yes` | **no** | no | yes |

The run still reports itself — `-> Consistent snapshot (sqlite .backup) …`, `[OK] Backup: <file>`,
Created / Size / Sessions / sha256 — so nothing is lost but the echo. The rejected alternative was
a `--no-plan` flag the menu passes: new public surface, for a meaning `--yes` already carried.

**The same confusion, one level down, fixed by renaming rather than suppressing.** The shrink
wizard prints its own read-only plan (`-> shrink plan (read-only counts — nothing is written yet)`,
`modules/menu/shrink.sh`) and then the engine printed `== shrink plan ==` — same name, same screen,
one decision. Here the two blocks carry *different* facts (live-DB counts and the effective command
vs. criteria / would-keep / would-delete / size on the real snapshot), so suppressing the engine's
would have thrown away evidence that the copy matched the plan. The header now names the mode:
`== shrink plan (read-only; nothing written) ==` on a dry run (it genuinely is a plan, and the CLI
prints no other), `== shrink run (criteria and counts of THIS copy) ==` on a real one. Same rule as
backup, opposite remedy: **a block that is not a plan should not be called one.**

## §35 The "safe order" that exported 2 of 7 (a root-vs-cascade mismatch)

The shrink wizard offers to export what it is about to drop before it builds the copy, and
labels that order SAFE. A real run of the wizard on a 21-session DB printed:

```
   Discard:    2 root(s) + 5 subagent(s) = 7 session(s) (cascade)
   This shrink WILL DISCARD the listed session(s) (and their subagents):
     ses_f746a22cbffeq1NXL5qQeLpmfT,ses_f72115a6affe0whavtOJSmHQwV
Export them first (opencode-db export archive --sessions)? ... [y/N] y
   Root sessions : 2
   Subagents     : 0
```

**Two of the seven sessions.** The export succeeded, printed plausible counts, and left
five conversations unreferenced — in a workflow whose entire purpose is that nothing is
lost. Two independent mismatches stacked up:

| side | input it got | what it meant |
|---|---|---|
| the engine's discard | the **roots** from the picker (`--discard-sessions`) | plus **every descendant** (`WITH RECURSIVE discard`, `shrink.sh`) |
| `export --sessions` | the same roots | **exactly those ids** (`WHERE s.id IN (…)`), and `children_of` is built only from selected sessions |

The picker works on roots *by design* (a subagent always follows its root), and the
engine closes the set itself — so every input that reached the offer was roots-only, while
every consumer that mattered was cascade-shaped. **Both** call sites printed the same
command, so the two halves disagreed about what "these sessions" meant.

**Why nothing caught it.** The engine hint was `grep_run "export archive --sessions
ses_A0001"` — a PREFIX of the correct answer, which also passed when only the root was
listed. A prefix assertion cannot distinguish "the root" from "the root and its
descendants", so the one fact under test was never actually tested. The offer itself had
**no assertion at all**.

**The fix is one helper that already existed.** The export wizard's hidden-subagent mode
hits the same shape (picker shows roots → `--sessions` needs the cascade) and already
solves it with `oc_export_expand_subs`. The shrink offer now calls it, so there is one
cascade expansion in the menu instead of two hand-written ones. `--sessions` stays exact
on purpose — that is its documented contract, and a test now pins it (`--sessions
ses_A0001` = 1 root, 0 subagents) so "the caller expands" cannot rot into "the engine
expands".

**An id is not a name.** The block above listed two 36-character ids for sessions the
user was about to lose, in a screen whose whole purpose is "this shrink WILL DISCARD…".
`oc_shrink_discard_rows` now answers id + title + descendant count in one read-only query
(the `o_q -separator $'\t'` idiom `oc_shrink_sub_counts` already used), capped at
`DISCARD_LIST_MAX` rows with `… N more` + the full csv. The cap is not decoration: the
whole point of a mass shrink is that the list is long, and a 500-line dump would push the
y/N gate off screen. Division of labour, same as the backup plan in §34: **the menu shows
names, the CLI keeps the command copy-pasteable** (the engine's hint stays ids — it is a
line you paste).

**The profile is config, not a fourth option.** Offering `archive` vs `memory` in the
prompt was rejected: `confirm_action` is a binary gate and a third option would mean a
new multi-way picker inside the plan screen for a preference that is per-user, not
per-decision. `OCED_SHRINK_DISCARD_EXPORT_PROFILE` was already the hook for it — and
already broken: it appeared in **no** other file (not the conf example, not the README,
not the docs) and was missing from `load_conf`'s env-snapshot list, so a value in the
conf file silently overrode an exported one, inverting the documented env > conf
precedence. It is now documented in `opencode-db.conf.example`, in the snapshot list, and
validated by `o_shrink_discard_profile` against `o_export_profiles` (products ∪ preset
names, asked from `exportlib/plan.py` so a new product or preset shows up for free). An
invalid name is reported **where the command is printed**, with the valid list, and falls
back — never discovered later inside an export the user had already confirmed. It is
deliberately NOT a shrink-recipe key: recipes are ops-only by contract (§17), and a
selection-adjacent preference in that file would smuggle a keep rule back in.

### §35b The profile has to be able to keep what the cascade contains

Handing the offer a closed set removed the *root* mismatch, but created a quieter one: the
cascade's whole value is its subagents, and the chosen profile could still throw them away.
Three shapes do it, and **every one of them is a silent success**:

| profile shape | what the run does | what it reports |
|---|---|---|
| `no_subagents: true` | drops the matched subagent sessions before any file is written | `.subagents_hidden` with a count |
| `no_orphan_subagents: true` | keeps the ones whose parent is exported, drops the rest | same |
| `sub: omit` | empties `children_of`, so a subagent is in `sessions` but no body is ever rendered | `.sessions.subagents: 0` |

`sub: omit` is the one worth naming. It is a *transcription* flag (`--sub separate|inline|omit`),
perfectly reasonable for a "one chat, no side quests" export — and it applies to a profile
whose job here is "keep what is about to die". The failure mode is the §35 failure mode with
an extra step: 2 of 7 exported, except now the missing 5 were selected, counted in the run,
and then never written. `metadata.json` cannot distinguish "no subagents were selected" from
"they were selected and dropped": `.sessions.subagents` is 0 either way.

The fix is one query, `plan.py subagent-gaps <profile>`, reading across every product of a
bundle (a bundle is one run decision — if ANY product drops them the user should know before
the gate, exactly like `preset_subagents` for the export wizard). It returns tokens, so the
bash side only formats the sentence and never parses flags:

```
no_subagents | no_orphan_subagents | sub_omit        (comma-separated; '' = it keeps them all)
```

A **warning, not a veto**, for the same reason the wizard's other notes are warnings:
`--discard-sessions` may be discarding a session because the user is deliberately dropping
its subagent conversations, and forcing `archive` over their `memory` choice would be the
tool overruling a decision it does not understand. So the resolver says what is true and
still prints the command. A product keyword can never gap, so the default stays silent and
there is no noise to tune.

The lesson from §35 applies to both halves: **the promise was "this export keeps what the
shrink drops"**, and only the first mismatch (roots vs cascade) was visible in the output.
What a contract claims has to be checked against the thing that enforces it — here the
`metadata.json` counters the engine writes, not the command string that suggested the
safety. So the suite now pins both ends: the cascade csv really writes 1 root + 2 subagents
(nested under `<root>/subagents/`, `index.md` reading `1 / 2 / 3`, `memory`'s corpus line
carrying both refs), and the resolver warns for each gap shape while `archive` stays silent.

---

### §36 The list is a column, the view is a detail screen

The `shrinks list` row used to paste the full criteria sentence (`keep everything except the
2 listed session(s) (their subagents are dropped too) + strip reasoning (drop the 'reasoning'
parts in the copy)`) into a table cell. At 100+ characters of parentheticals it pushed every
row to ~225 characters and buried the three numbers that actually matter:

```
before -> after  (freed, -pct%)  before -> after  (freed, -pct%)  before -> after  (freed, -pct%)
```

The fix splits the presentation into two screens with two widths:

1. **`shrinks list` — a COLUMN**  
   One compact row: `2026-10-05 19:52 UTC  discard 2 ids +strip   14/21 kept   1.2GiB -> 843MiB (-31%)`  
   The tag comes from `plan.py rule-tag` (the SSoT for the compact form), carrying the
   rule's own value (`keep 1` vs `keep 10` are the same rule, different facts — which is
   why the engine records `.selection.value`). One size delta instead of three. The
   copy's own state `(swapped/no copy)` only when anomalous. Width bounded (~80 chars).

2. **`shrinks view` — a DETAIL screen**  
   Banner + one fact per line, the FULL criteria sentence verbatim from `shrink.json`,
   the recorded `integrity_check`, `freshness` from the SAME `o_shrink_stale` helper that
   `verify` uses (including the unverifiable legacy case), selected IDs capped at 8 with
   `… N more` (the count stays), per-table removals, and the files.  
   `--json` returns `shrink.json` byte-for-byte, no banner.

Both formats are generated from the same `shrink.json` — the sentence and the tag are
two formats of ONE fact and live side by side in `plan.py` (`rule-line` / `rule-tag`).
The bash engine never builds these phrases itself; it delegates to the single source.

The test suite pins:
- Row width ≤ 100 columns
- The criteria sentence absent from the list (grep fails on its parentheticals)
- The tag carries the rule's own value (keep 1, not a default)
- View prints the criteria verbatim, the integrity_check, freshness always answered
- IDs capped at 8 + `… N more`, count intact
- `--json` is the file verbatim, no banner

The old recency rows (`__LAST__`/`__OLDEST__`/`__DAYS__`) were also removed from the
sessions picker (§19) — a row that re-computes "the N newest" at run time is a selection,
not a marking. Recency is `--last`/`--since` on the CLI.
