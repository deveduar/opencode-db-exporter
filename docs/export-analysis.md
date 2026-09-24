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
`export.sh` still calls `modules/export.py`, which now only forwards to
`exportlib.cli.main()`. This document keeps §1 as the historical state of the code before
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
`modules/export.py <product> --stamp <shared> --preset-name <name>` per product, so each
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
