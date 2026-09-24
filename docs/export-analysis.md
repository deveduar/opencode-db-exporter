# Export system analysis — opencode-db-exporter

Design document: how the exporter works today, what the `all` mode ("4-in-1") actually
does, what the rest of the community does, and proposals to simplify the conceptual
model. This document **changes no code**; it is the basis for deciding.

---

## 1. How it works today (real state of the code)

### 1.1 Entry point

- `modules/export.sh` → `oced_export [profile|all] [flags]` which runs
  `modules/export.py` with `OPENCODE_DB`/`OCED_OUT`/`OCED_BACKUP_DIR` already resolved
  (honoring `--from-backup`).
- `export.py` opens the DB **read-only** (`file:...?mode=ro`), reads the
  root/subagent hierarchy from `session.parent_id`, and writes a tree:
  `OCED_OUT/<stamp>/<profile>/` + `index.md` + `metadata.json`.

### 1.2 The 5 profiles + 1 meta-profile

| Profile | What it emits | Part types included (export.py:83-97) |
|---|---|---|
| `full` | full transcript | `text`, `reasoning`, `tool` (per `--tool-output`), `patch` (per `--patch`), `file`, `step-*`, `compaction` (only with `--mark-compactions`) |
| `no-calls` | no tools/patches | `text`, `reasoning` |
| `text-only` | message text only | `text` |
| `compactions` | **compaction digests** | only messages with `mode=compaction`, `text` part (the "digest") |
| `memory` | **RAG corpus** (JSONL + index.md) | first prompt, last response, all digests, `--files` |
| `all` (meta) | **4 runs in 1 folder** (`full`, `no-calls`, `text-only`, `compactions`), each with "max flags" | application of export.py:27-34 |

The 4 folders of `all` share a single `--stamp` (`export.sh:21-32`).

### 1.3 The flags (configuration dimensions)

- `--sub separate|inline|omit` — how to place subagents (default `separate`, a `subagents/`
  folder per root).
- `--tool-output full|truncated|omit` + limits `--tool-input-limit` (800) /
  `--tool-output-limit` (500) — tool verbosity.
- `--patch full|omit` — include/omit the code diffs.
- `--mark-compactions` — annotates in the transcript where compaction happened.
- `--summary-diffs` — includes `message.data.summary.diffs` (per-message change summary).
- `--role all|user|assistant` — **transcript**: prompts only / answers only.
- `memory`: `--cap N` (0=unlimited) and `--files`.

### 1.4 What each part is in the DB (schema)

`part.data.type` ∈ `text | file | step-start | reasoning | tool | step-finish | patch | compaction`.
A compaction digest is not in the marker part `type=compaction` but in the following
message with `data.mode='compaction'` (helper `digests_for`, export.py:228-236, shared by
`compactions`, `memory` and `view.sh`).

---

## 2. Question 1: does the "4-in-1" mode (`all`) do ALL possible exports?

**No.** It does 4 of the 5 profiles, with ONE setting per dimension (the maximum). It is a
very small subset of the total space and —more importantly— most of that space is
**redundant** (see §3.2).

What `all` does **NOT** include:

1. `memory` — excluded on purpose (it is a corpus, not a transcript), but for "everything",
   it's missing.
2. Filtered roles (`--role user/assistant`) — `all` only emits `--role all`.
3. Verbosity variants (`--tool-output omit/truncated`, `--patch omit`).
4. `--sub inline|omit`.
5. `--mark-compactions` off, `--summary-diffs`, etc.

If **all** combinations were joined (5 profiles × 3 tools × 2 patch × 3 sub × 3 role × …)
you would get hundreds of folders per session, almost all redundant. That `all` emits
`full` + `no-calls` + `text-only` + `compactions` is an arbitrary compromise without a
product logic to justify it.

---

## 3. Question 2: if you choose `full`, what sense does "prompts only" make?

The user is right that the current approach mixes axes. Let's see what is a **subset** of
what:

- `no-calls` = `full` − tools − patches → **subset**.
- `text-only` = `no-calls` − reasoning → **subset**.
- `--role user` = `full` ∩ user messages only → **subset**.
- `compactions` = **not a subset**: it is a meta-log (what opencode summarized), with a
  different format and purpose.
- `memory` = **not a subset**: it is another format (JSONL for RAG) and another consumer
  (machine, not human reading).

In other words: today things that are **verbosity variants of the same product** (the
transcript) are sold as "profiles" (distinct products), and mixed with two genuinely
distinct products (compaction digests and memory corpus). That is why "profile full +
preset 'prompts only'" sounds contradictory: it is taking the complete product and removing
97% of its content — a legitimate preset (e.g. a summary of your intentions), but NOT a
sibling product of `full`.

Research (see §5): no community exporter does this. They all emit **ONE** well-made
markdown per session (with verbosity options), and the advanced ones add a **faithful JSON**
(losslessness) and/or HTML. Nobody publishes 4 markdowns of the same conversation.

---

## 4. The root problem: two mixed axes

Current model: `profile` = "which document", `variant` = "how it is configured". But in
reality you must separate the **product** from the **level of detail**, because the
transcript is one single thing:

```
PRODUCT (what you get)              LEVEL OF DETAIL (for the transcript)
─────────────────────────          ─────────────────────────────────────
1. Transcript (markdown)      ⇐    tools: full|truncated|omit
2. Memory corpus (jsonl)            patches: full|omit
3. Compactions digests (md)         subagents: separate|inline|omit
                                    role: all|user|assistant
                                    (reasoning: yes/no)
```

- `full` vs `no-calls` vs `text-only` are NOT products: they are **three levels of detail
  of the same product** (Transcript).
- The average citizen commit wants: "1 transcription of the conversation, with tools and
  without reasoning" → that is ONE Transcript export with certain options.
- `all` as "everything" would naturally mean **all sessions** (its colloquial meaning), not
  "4 verbose duplicates of each session".

### 4.1 Proposal (to debate)

1. **Refactor the menu/CLI entry around PRODUCT + options**, not "profile → variant":
   - `Transcript` (md): options tools/patches/sub/role/reasoning → 1 tree per run.
   - `Memory` (jsonl): options cap/files → 1 corpus per run.
   - `Compactions` (md): digests → 1 index per run (or left only in `info`/`status`,
     which already show them).
   - A "everything" preset = `Transcript` + `Memory` under the same `--stamp` (the
   `__FULLMEM__` bundle the menu had already did this), dropping the 3 redundant markdowns.
2. **Add faithful JSON export** (native opencode format, `{"info", "messages"}`) as an
   "archive" companion to Transcript — the lossless way to lose nothing, complementing the
   readable markdown. opencode already offers it out of the box (`opencode export <id>
   --sanitize`).
3. **Sanitization/redaction** when sharing (pattern of opencode `--sanitize` and of
   `opencode-export` with 18 secret patterns) — so far the exporter redacts nothing.
4. **`--role user|assistant`** stays a Transcript toggle (valid), but is no longer
   duplicated as a "profile"; **`compactions`** as a markdown "profile" would disappear or
   stay as a convenience under Transcript (digests section at the footer) — removes the
   third redundant product of the menu.

### 4.2 What we gain

- A menu with 3 entries instead of 6 with cross combinations.
- `all` stops being "4 duplicates" and becomes "everything useful in one run".
- The user no longer asks "if full has everything, why prompts only?" — the answer ("it is
  a transcript toggle to keep only your prompts") is clear in the UI (a checkbox), not as a
  parallel product.

---

## 5. What the rest of the world does (research, sep 2026)

| Project | Format | Approach | Lessons |
|---|---|---|---|
| **opencode official** (`opencode export <id>`) | **JSON** `{"info", "messages":[{info, parts}]}` + `--sanitize` | faithful/lossless + redaction for sharing | the house standard is JSON; markdown is an extra |
| **opencode-export** (ZelinZhou-THU) | HTML + `data/sessions.json` | navigable offline archive, recursive redaction, inline subagents, token backfill from `step-finish` | redaction + inline subagents + token backfill for old sessions |
| **opencode_session_exporter** (weshu) | Markdown | uses `opencode export --format json` as source; reasoning in `<details>`, tools summarized | back to classic markdown: one format, collapsible reasoning, summarized tools |
| **opencode-db** (VasilevNStas / PyPI) | Markdown + Obsidian | metadata header + messages; `--full` (untruncated); note in `log.md` | official PyPI Obsidian export; `--full` is the equivalent of `--tool-output full` |
| **opencode-session-extractor** (PyPI) | JSON + Markdown + HTML | 3 formats per call | cross-platform formats, but always the SAME content |
| **opencode-session-toolkit** (skill) | queries + MD export | reads the DB read-only, exports sessions | confirms the direct read-only SQLite pattern |

**Cross-cutting observations:**

- Everybody's markdown is **one format with options**, never N markdowns of the same event.
- The ones that "do everything" add **formats** (JSON/HTML) over the SAME content, not
  content cut-downs.
- The most requested community option: **secret redaction** on export (official opencode
  `--sanitize`, opencode-export redaction engine).
- The opencode contract (parts/formats) includes types we currently ignore: `snapshot`,
  `event`, `retry`, `subtask` (we treat subagents by `parent_id`, not by `subtask`), and
  per-`step-finish` tokens. Truly "exporting everything" should include the **faithful
  JSON** so those are not lost.

---

## 6. Open questions to decide

1. Does `all` become "all sessions" (each session = 1 transcript) instead of "4 profiles"?
   (My recommendation, but it breaks the current semantics.)
2. Does markdown remain the main format and faithful JSON an option (`--json`)?
3. Do we implement secret redaction (opencode's `--sanitize` pattern)?
4. Does `--role` stay a Transcript toggle (surely yes) and "prompts only" get removed as a
   menu preset?
5. Does `compactions` as markdown stay, or does it only live in `info`/`memory`?
6. Do we add token backfill from `step-finish` for old sessions with 0 tokens (a real gap in
   our DB: `tokens_*` can be empty in old sessions)?

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
  entry points for the same products.
- **Confirm plan shows "Will produce:"** — `oc_export_confirm` now builds a dynamic
  block listing each product with its short description and effective flags
  ("full tool outputs", "+faithful JSON (raw)", "reasoning omitted", "sanitize ON
  (best-effort redaction)", etc.). The faithful JSON note clarifies that markdown
  display filters (`tool_output`, `role`, `no_reasoning`, `tool_input_limit`) do NOT
  apply to the JSON archive, which is always raw/unfiltered (except `sanitize`).
- **Sanitize caveat** — when `sanitize` is active, the plan prints a bold warning:
  "sanitize redacts known secret patterns (sk-, ghp_, Bearer, JWT, PEM, key=value…)
  — best-effort, NOT a guarantee; verify output before sharing." The README and guide
  were updated accordingly; the term "public-safe" was softened to "publish transcript
  (best-effort redaction)".
- **Tests** — menu_flow grew with assertions for the new helpers
  (`oc_annotate_flags`, `oc_export_plan`) and the absence of `Manual` in presets mode
  (75 OK).
