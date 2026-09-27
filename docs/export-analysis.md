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
  `o_shrink_stale <shrink.json>` used by `shrinks verify`, `guide.sh` Step 3 and the menu's
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
  `oc_confirm_typed "confirm"` (extracted from guide.sh, now reused by both) hands the
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
