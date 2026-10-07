# Single Source of Truth for all export flags.
# This module is the authoritative definition of every flag:
#   - name, type, choices, default, products it applies to, description
#   - CLI argparse spec
#   - JSON Schema for presets.schema.json
#   - presets.py validation
#   - menu.sh annotation/legend
#   - generated/flags-table.md table
#
# To add a new flag: add it here, then run the generator script (or update
# dependents manually until generator exists).
# To add a new product: add to PRODUCTS list and register its flags.

from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any, Literal

FlagType = Literal["bool", "choice", "int", "string"]


@dataclass(frozen=True)
class Flag:
    name: str                    # underscore form (e.g., "tool_output")
    flag_type: FlagType
    products: List[str]          # which products this applies to (or ["*"] for all)
    default: Any
    choices: Optional[List[str]] = None
    min_value: Optional[int] = None
    description: str = ""
    cli_help: str = ""

    @property
    def cli_name(self) -> str:
        return self.name.replace("_", "-")

    @property
    def json_schema(self) -> dict:
        """Generate JSON Schema fragment for this flag."""
        if self.flag_type == "bool":
            return {"type": "boolean", "description": self.description}
        elif self.flag_type == "choice":
            return {
                "type": "string",
                "enum": self.choices,
                "description": self.description
            }
        elif self.flag_type == "int":
            schema = {"type": "integer", "description": self.description}
            if self.min_value is not None:
                schema["minimum"] = self.min_value
            return schema
        elif self.flag_type == "string":
            return {"type": "string", "description": self.description}
        return {"type": "string", "description": self.description}

    def argparse_args(self) -> dict:
        """Return kwargs for argparse.add_argument()."""
        args = {"help": self.cli_help or self.description}
        if self.flag_type == "bool":
            args["action"] = "store_true"
        elif self.flag_type == "choice":
            args["choices"] = self.choices
            args["default"] = self.default
        elif self.flag_type == "int":
            args["type"] = int
            args["default"] = self.default
        elif self.flag_type == "string":
            args["default"] = self.default
        return args


# ---- Product registry ----
PRODUCTS = ["transcript", "memory", "digest", "full"]
PRODUCT_KEYWORDS = ["transcript", "memory", "digest"]  # 'full' is alias
# Accepted spelling of a product keyword that is NOT its real name. `compactions`
# was the original name of the `digest` product and is kept working as a deprecated
# alias. Two things are deliberately NOT renamed: the marker/event (opencode writes
# part.data.type='compaction', counted as `compactions` in the metadata) and the
# `digest` text itself. The product only writes the digests, so it is `digest`.
PRODUCT_ALIASES = {"compactions": "digest"}

# Product keyword -> one-line description for the plan confirm / index.
PRODUCT_INTRO: Dict[str, str] = {
    "transcript": "Markdown conversation per session, with reasoning and tool calls",
    "memory": "RAG corpus in corpus.jsonl, one line per root session: tokens, todos, tools and digests",
    "digest": "Markdown digests only: the compacted knowledge arc",
}

# ---- Flag registry ----
# Order = display order in help / schema / docs
FLAGS: list[Flag] = [
    # Global flags (apply to all products)
    Flag(
        name="filter",
        flag_type="string",
        products=["*"],
        default=None,
        description="SQL LIKE pattern on session id/title (e.g., ses_f7%%)",
        cli_help="SQL LIKE on session id/title, e.g. ses_f7%%"
    ),
    Flag(
        name="sessions",
        flag_type="string",  # handled specially as append
        products=["*"],
        default=None,
        description="Exact session ids to export (repeatable)",
        cli_help="Exact session ids to export (repeatable)"
    ),
    # Recency selection rules. CLI-ONLY (never a preset key, like `out`): a
    # recency rule is not reproducible — the same command tomorrow yields a
    # different set — so it does not belong in a plan, which is meant to be a
    # repeatable recipe (see snapshot: fresh for the archive counterpart).
    # One selection rule per run: filter | sessions | last | since.
    Flag(
        name="last",
        flag_type="int",
        products=["*"],
        default=None,
        min_value=1,
        description=("Keep the N most recently updated ROOT sessions, with every session that "
                     "follows them (CLI-only, not a preset key)"),
        cli_help="N most recently updated root sessions, with their subagents (CLI-only)",
    ),
    Flag(
        name="since",
        flag_type="string",
        products=["*"],
        default=None,
        description=("Keep every session updated on or after DATE (YYYY-MM-DD, UTC), subagents "
                     "included as they match (CLI-only, not a preset key)"),
        cli_help="every session updated on or after DATE, subagents included (CLI-only)",
    ),
    Flag(
        name="out",
        flag_type="string",
        products=["*"],
        default=None,
        description="Output root directory",
        cli_help="Output root directory"
    ),

    # Subagent inclusion (all products): these two decide WHETHER a subagent is
    # part of the export at all; `sub` (below, transcript only) decides only WHERE
    # an included subagent is rendered.
    Flag(
        name="no_subagents",
        flag_type="bool",
        products=["*"],
        default=False,
        description="Exclude every subagent session from the export (all products); a session whose parent row is gone is kept (it is a root)",
        cli_help="Exclude every subagent session (all products)"
    ),
    Flag(
        name="no_orphan_subagents",
        flag_type="bool",
        products=["*"],
        default=False,
        description="Drop a selected subagent whose parent session is not exported (default: keep it, exported standalone as a root)",
        cli_help="Drop a selected subagent whose parent session is not exported"
    ),

    # Transcript flags
    Flag(
        name="sub",
        flag_type="choice",
        products=["transcript"],
        default="separate",
        choices=["separate", "inline", "omit"],
        description="How to render subagent sessions",
        cli_help="Subagent rendering mode"
    ),
    Flag(
        name="tool_output",
        flag_type="choice",
        products=["transcript"],
        default="truncated",
        choices=["full", "truncated", "omit"],
        description="Tool output verbosity in transcript",
        cli_help="Tool output verbosity"
    ),
    Flag(
        name="tool_input_limit",
        flag_type="int",
        products=["transcript"],
        default=800,
        min_value=0,
        description="Max chars of tool input to show (0 = unlimited)",
        cli_help="Tool input char limit (0 = unlimited)"
    ),
    Flag(
        name="tool_output_limit",
        flag_type="int",
        products=["transcript"],
        default=500,
        min_value=0,
        description="Max chars of tool output to show (0 = unlimited)",
        cli_help="Tool output char limit (0 = unlimited)"
    ),
    Flag(
        name="patch",
        flag_type="choice",
        products=["transcript"],
        default="full",
        choices=["full", "omit"],
        description="Whether to include patch/diff output",
        cli_help="Patch rendering mode"
    ),
    Flag(
        name="no_reasoning",
        flag_type="bool",
        products=["transcript", "digest"],
        default=False,
        description="Omit reasoning parts from output",
        cli_help="Omit reasoning parts"
    ),
    Flag(
        name="mark_compactions",
        flag_type="bool",
        products=["transcript", "digest"],
        default=False,
        description="Mark compaction boundaries in output",
        cli_help="Mark compaction boundaries"
    ),
    Flag(
        name="summary_diffs",
        flag_type="bool",
        products=["transcript", "digest"],
        default=False,
        description="Include per-message change summaries",
        cli_help="Include summary diffs"
    ),
    Flag(
        name="role",
        flag_type="choice",
        products=["transcript", "digest"],
        default="all",
        choices=["all", "user", "assistant"],
        description="Filter messages by role",
        cli_help="Filter messages by role"
    ),
    Flag(
        name="json",
        flag_type="bool",
        products=["transcript", "digest"],
        default=False,
        description="Write faithful JSON archive per session",
        cli_help="Write faithful JSON archive"
    ),

    # Global / shared
    Flag(
        name="sanitize",
        flag_type="bool",
        products=["*"],
        default=False,
        description="Redact safe secret prefixes (sk-, ghp_, AKIA, JWT, PEM) — best effort",
        cli_help="Redact secret-like values (best effort)"
    ),
    # Workflow flag: snapshot coordination (single-preset-only; never per-product
    # in a bundle, never part of the product flag groups).
    Flag(
        name="snapshot",
        flag_type="choice",
        products=["*"],
        default=None,
        choices=["fresh"],
        description="Snapshot freshness coordination: 'fresh' warns unless the live DB matches the last backup",
        cli_help="Before exporting, require a fresh backup aligned with the live DB (warns if out of sync)"
    ),

    # Memory flags
    Flag(
        name="cap",
        flag_type="int",
        products=["memory"],
        default=0,
        min_value=0,
        description="Truncate each text value to N chars (0 = unlimited)",
        cli_help="Truncate text values to N chars (0 = unlimited)"
    ),
    Flag(
        name="files",
        flag_type="bool",
        products=["memory"],
        default=False,
        description="Include touched files per session",
        cli_help="Include touched files per session"
    ),
]


# ---- `opencode-db help` export block (served by `--help-exports`) ---------
# The exact text shown under "export products:"/"export flags:" in `opencode-db
# help`. Single source: edit here, never in opencode-db.sh.
# Long per-product descriptions (the products lines of the help block).
PRODUCT_HELP: Dict[str, str] = {
    "transcript": (
        "the conversation in markdown: text + reasoning + tool calls +\n"
        "               patches + step markers (tool output is truncated by default:\n"
        "               use --tool-output full for the complete output). Optional\n"
        "               --json writes a faithful archive per session (native shape.)"
    ),
    "memory": (
        "RAG/memory corpus: corpus.jsonl with one JSON per root session\n"
        "               (metadata + first user text + last assistant text + all\n"
        "               compaction digests) - ready for embeddings, not a transcript"
    ),
    "digest": "only the compacted-context digests (mode=compaction messages)",
}

# Flag name -> exact line(s) of the `export flags:` block (emitted verbatim in
# FLAGS order). The sync guard (tests) checks that every visible `--<cli_name>`
# from FLAGS appears here; hidden flags (limits, combined cap+files) are handled
# by the generator below.
FLAG_HELP: Dict[str, str] = {
    "filter": "  --filter PATTERN   SQL LIKE on session id/title, e.g. 'ses_f7%'",
    "sessions": (
        "  --sessions ID[,ID]   exact session id(s) to export (repeatable);\n"
        "                     overrides --filter / the preset selection"
    ),
    "out": "  --out DIR          output root (default $OCED_OUT)",
    "last": (
        "  --last N           the N most recently updated ROOT sessions, with every\n"
        "                     session that follows them (like shrink --keep N). CLI-only:\n"
        "                     the set is recomputed at run time, so it is not a preset key"
    ),
    "since": (
        "  --since DATE       sessions updated on or after DATE, YYYY-MM-DD UTC (CLI-only,\n"
        "                     same caveat as --last). One selection rule per run: this,\n"
        "                     --last, --filter or --sessions"
    ),
    "no_subagents": (
        "  --no-subagents     exclude every subagent session (all products): only root\n"
        "                     sessions are exported. A session whose parent is gone\n"
        "                     stays (it has no parent to hide behind)"
    ),
    "no_orphan_subagents": (
        "  --no-orphan-subagents   drop a selected subagent whose parent session is NOT\n"
        "                          part of the export (a closed parent+subagents set).\n"
        "                          Default: it IS exported, standalone, as a root"
    ),
    "sub": (
        "  --sub separate|inline|omit   how to place subagent sessions (default separate:\n"
        "                       folder per root session with subagents/ inside)"
    ),
    "tool_output": (
        "  --tool-output full|truncated|omit   tool output verbosity (default truncated;\n"
        "                       applies to transcripts/digest)"
    ),
    "patch": "  --patch full|omit   include patch parts (default full; transcripts only)",
    "mark_compactions": "  --mark-compactions   include compaction marker paragraphs (transcripts only)",
    "no_reasoning": "  --no-reasoning       omit the reasoning parts (transcripts only)",
    "summary_diffs": "  --summary-diffs    render user-message summary.diffs (files+additions/deletions)",
    "role": (
        "  --role all|user|assistant   transcripts/digest: render only one role's\n"
        "                       messages (--role user = prompts only, --role assistant =\n"
        "                       answers only; memory ignores it)"
    ),
    "json": (
        "  --json             also write a faithful JSON archive per session (transcripts\n"
        "                     and digest)"
    ),
    "sanitize": (
        "  --sanitize         redact secret-looking values (API keys, bearer tokens,\n"
        "                     private keys, key=... pairs) in the exported output"
    ),
    "snapshot": (
        "  --snapshot fresh   snapshot coordination: warn if the live DB is NOT aligned\n"
        "                     with the last backup (the export itself reads the LIVE DB,\n"
        "                     so a reference archive is only sound when they agree)"
    ),
    "cap": (
        "  --cap N  --files   memory tuning: truncate each text value to N chars\n"
        "                     (0 = unlimited, default) and/or include touched files"
    ),
}


def help_main_exports() -> str:
    """The 'export products:' + 'export flags:' block served to `opencode-db help`."""
    lines = ["export products (default: transcript):"]
    for name in PRODUCT_KEYWORDS:
        first, *rest = PRODUCT_HELP[name].split("\n")
        lines.append(f"  {name:<13}{first}")
        lines.extend(rest)
    lines.append("")
    lines.append("export flags:")
    for name, text in FLAG_HELP.items():
        if name not in (f.name for f in FLAGS):
            continue  # stale entry (flag removed) — don't surface it
        lines.append(text)
    for f in FLAGS:
        if f.name in FLAG_HELP:
            continue  # already emitted above (dict insertion order = help order)
        if f.name in ("tool_input_limit", "tool_output_limit"):
            continue  # not surfaced in the top-level help (only `export --help`)
        if f.name == "files":
            continue  # combined into the --cap N  --files row above
        # any future flag not listed yet: generated fallback row
        lines.append(f"  --{f.cli_name}   {f.cli_help}")
    return "\n".join(lines)


# ---- Helper functions ----

def get_flags_for_product(product: str) -> list[Flag]:
    """Return flags that apply to a specific product."""
    if product == "full":
        return [f for f in FLAGS if "transcript" in f.products or f.products == ["*"]]
    return [f for f in FLAGS if product in f.products or f.products == ["*"]]


# ---- Product-specific flag groups for validation ----
# `snapshot` is a workflow flag: valid at the SINGLE preset's top level but NEVER
# per-product (bundle) — a snapshot decision is one decision, not per product.
SINGLE_ONLY_KEYS: tuple[str, ...] = ("snapshot",)

# Selection rules that exist ONLY on the CLI. They are deliberately not preset
# keys: `out` is an environment/output concern a plan must never pin, and
# `last`/`since` are recency rules, whose set changes every time they run (a plan
# is a repeatable recipe). Mirrors shrink's KEEP_RULE_KEYS split.
CLI_ONLY_KEYS: tuple[str, ...] = ("out", "last", "since")

PRODUCT_FLAG_KEYS: Dict[str, list[str]] = {
    p: [
        f.name
        for f in FLAGS
        if (p in f.products or f.products == ["*"])
        and f.name not in SINGLE_ONLY_KEYS
        and f.name not in CLI_ONLY_KEYS
    ]
    for p in ("transcript", "memory", "digest")
}

# For bundle presets: per-product allowed keys
BUNDLE_PRODUCT_KEYS = {k: v for k, v in PRODUCT_FLAG_KEYS.items() if k != "full"}

# Selection keys (shared across all products in a bundle)
SELECTION_KEYS = ["filter", "sessions"]

# Single preset keys (product + all flags + selection).
SINGLE_PRESET_KEYS = sorted(set(
    ["product"] + [f.name for f in FLAGS if f.name not in CLI_ONLY_KEYS]
    + ["filter", "sessions", "products"]
))

# Bundle preset keys. `out` is CLI-only for a bundle too.
BUNDLE_PRESET_KEYS = ["products", "filter", "sessions"]


# ---- Human-readable annotation hints (menu.confirm/annotate) ----
# value-aware phrases per key=value pair (CSV "key=value,key=value").
ANNOTATE_HINTS: Dict[str, str] = {
    "json=true": "faithful JSON, raw and unfiltered",
    "tool_output=full": "full tool outputs",
    "tool_output=truncated": "truncated tool outputs",
    "tool_output=omit": "no tool outputs",
    "no_reasoning=true": "reasoning omitted",
    "sanitize=true": "sanitize ON (safe prefixes: sk-, ghp_, AKIA, JWT, PEM…)",
    "files=true": "touched files",
    "sub=inline": "subagents inline",
    "sub=omit": "subagents omitted",
    "no_subagents=true": "subagents hidden (roots only)",
    "no_orphan_subagents=true": "orphan subagents dropped",
    "summary_diffs=true": "per-message diff summaries",
    "mark_compactions=true": "compaction markers",
    "role=user": "role 'user'",
    "role=assistant": "role 'assistant'",
    "patch=omit": "patches omitted",
}


def annotate_flags(csv: str) -> list[str]:
    """Map a presets CSV ("key=value,key=value") to human phrases, ONE PER LINE.

    The caller renders the list as standalone lines: there is no separator
    between items and no bullet marker, because a ' · ' or a '+' read like an
    operator rather than a caption (and the old leading '+' survived the loss of
    its sibling bullets, so it pointed at nothing). Unknown key=value pairs
    (sub=separate, role=all, patch=full, …) are skipped unless a hint exists.
    """
    if not csv:
        return []
    bits: list[str] = []
    for kv in csv.split(","):
        kv = kv.strip()
        if not kv or "=" not in kv:
            continue
        key, _, val = kv.partition("=")
        if key == "cap" and val.isdigit() and int(val) != 0:
            bits.append(f"cap {val} chars")
            continue
        hint = ANNOTATE_HINTS.get(kv)
        if hint:
            bits.append(hint)
    return bits


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "--annotate":
        # one phrase per line (never a ' · '-joined line): the menu renders each
        # as its own caption, and a joined string would re-appear as one blob.
        print("\n".join(annotate_flags(sys.argv[2])))
        sys.exit(0)
    if len(sys.argv) == 2 and sys.argv[1] == "--help-exports":
        print(help_main_exports())
        sys.exit(0)
    print(__doc__ or __file__)
    sys.exit(1)