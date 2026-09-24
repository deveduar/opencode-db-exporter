# Export system analysis — opencode-db-exporter (archived)

> **ARCHIVED (sep 2026).** Pre-redesign analysis (§§1–6 of the original
> `docs/export-analysis.md`): how the exporter worked *before* the redesign, what the
> `all` mode ("4-in-1") actually did, community research, and the open questions that
> led to the decisions. The `full`/`no-calls`/`text-only`/`all` model it describes
> **no longer exists** (products today are `transcript|memory|compactions`). Kept for
> historical context only; the live decision log is `docs/export-analysis.md` (§7+),
> and `docs/architecture.md` describes the current design.

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
