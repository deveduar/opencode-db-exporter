# Export plan API — the single Python place that answers "what will this export
# produce?" for any profile (product keyword OR named preset), plus the
# bash<->python JSON/text bridge used by menu.sh. This replaces the jq helpers
# (oc_preset_rows, oc_preset_descr, oc_preset_legend, oc_export_plan, ...) that
# used to live in menu.sh: product intros, shipped-plan purposes and the flag
# annotation bits are all resolved here and served over one CLI.
#
# CLI subcommands (each prints one artifact; exit 1 = nothing to produce):
#   rows                 TSV preset rows for the fzf picker (key<TAB>display)
#   names                preset names (sorted, one per line)
#   products             TSV product rows for the product picker (key<TAB>label)
#   products --legend    the product picker header legend (use-it-when lines)
#   products-list        the friendly `export --list-products` screen (no DB)
#   descr <preset>       one-line selection summary
#   purpose <name>       one-line purpose for the shipped plans (unknown -> 1)
#   legend               header lines explaining each shipped plan in the file
#   resolve <profile>    JSON plan for a product keyword or preset name
#   plan <profile> [--width N]   the confirm's product block (flat, no label)
#   notes <profile> [--width N]  the caveats of that plan ("" when there are none)
#   snapshot <name>      "fresh" when the preset pins snapshot: fresh, else ""
#   selection <name>     the selection the preset PINS, as a human phrase, or ""
#   subagents <name>     "no_subagents" | "no_orphan_subagents" | "both" | ""
#                        (the menu's confirmation needs both to state the
#                        effective selection instead of the intent)
from __future__ import annotations

import json
import os
import sys
import textwrap

MODULES_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if MODULES_DIR not in sys.path:
    sys.path.insert(0, MODULES_DIR)

try:
    from exportlib.presets import load_presets
    from exportlib.util import selection_phrase
    from exportlib.flags import (
        PRODUCT_ALIASES,
        PRODUCT_KEYWORDS,
        PRODUCT_INTRO,
        annotate_flags,
    )
except ImportError:
    # fallback for in-place execution
    from presets import load_presets
    from util import selection_phrase
    from flags import (
        PRODUCT_ALIASES,
        PRODUCT_KEYWORDS,
        PRODUCT_INTRO,
        annotate_flags,
    )

# The ONLY hand-written text of a shipped plan: blurb = one short line for the
# picker row, purpose = the full intent for `--list-presets` / the legend. Both
# live here so the two surfaces can never describe the same preset differently
# (the old picker taxonomy special-cased a couple of flag combos and let every
# other preset fall through to "transcript (defaults)" — which is how `prompts`
# and the snapshot plan got mislabelled). A user preset (a name not in this map)
# falls back to the factual `preset_descr`.
PLAN_TEXT = {
    "archive": {
        "blurb": "lossless everything (full + JSON + files)",
        "purpose": "lossless full backup: complete tool outputs + faithful JSON + memory with files (heavy)",
    },
    "quick": {
        "blurb": "light review (truncated + JSON + files)",
        "purpose": "light daily review: same backup, truncated tool outputs (fast, compact)",
    },
    "share": {
        "blurb": "shareable (no reasoning + JSON)",
        "purpose": "publish transcript: no reasoning, faithful JSON (add --sanitize for safe redaction)",
    },
    "notes": {
        "blurb": "plain transcript, default options",
        "purpose": "plain conversation read: the transcript product with default options",
    },
    "prompts": {
        "blurb": "only your prompts (role user)",
        "purpose": "just your asks: only user prompts, no answers/reasoning/tools (task log)",
    },
    "rag": {
        "blurb": "corpus for another AI (memory)",
        "purpose": "corpus for another AI: the memory product with default options",
    },
    "digest": {
        "blurb": "only the compaction summaries",
        "purpose": "knowledge arc: only the compaction summaries",
    },
    "audit_archive": {
        "blurb": "full transcript + fresh-backup guard",
        "purpose": "audit-grade full transcript: complete tool outputs; offers to align the reference backup when it diverged (heavy)",
    },
}


def plan_blurb(name: str) -> str:
    """The picker-row blurb of a shipped plan ("" when it is a user preset)."""
    return PLAN_TEXT.get(name, {}).get("blurb", "")


def plan_purpose(name: str) -> str:
    """The full purpose of a shipped plan ("" when it is a user preset)."""
    return PLAN_TEXT.get(name, {}).get("purpose", "")

# Product picker rows/labels (TSV key<TAB>label) and the header legend passed to
# the fzf picker. Served to menu.sh by the `products` subcommand. Rows stay SHORT;
# the "use it when / size / redundancy" legend lives in the header (see menu.sh).
PRODUCT_PICKER_LABEL = {
    "transcript": "READ / SHARE / AUDIT — the full conversation as Markdown (per session)",
    "memory": "FEED ANOTHER AI — machine-readable corpus (corpus.jsonl, one line per session)",
    "digest": "QUICK KNOWLEDGE REVIEW — only the compaction summaries",
}

PRODUCT_PICKER_LEGEND = [
    "Choose ONE product (runs with DEFAULT options; ESC: back):",
    "   transcript   HEAVY, human-readable: your asks, the answers, reasoning, every tool call + output",
    "                and the code patches, compaction digests inline. Add --json for a faithful machine archive.",
    "   memory       LIGHT, machine-readable: tokens/cost, todos, tools, first ask + last answer and ALL",
    "                compaction digests per session. For feeding another AI (RAG); streamed line by line.",
    "   digest       TINY extract: only the compaction summaries (the knowledge arc of a session). Already",
    "                inside transcript AND memory — standalone is just a fast skim.",
    "Tune flags via the presets file (plans) or the CLI.",
]


def product_listing() -> str:
    """The `export --list-products` screen: the document KINDS (raw CLI nouns),
    with the aliases named and a pointer at the named plans — so the two name
    spaces (product vs preset) are visible side by side instead of implied."""
    width = max((len(p) for p in PRODUCT_KEYWORDS), default=0)
    lines = [f"{p:<{width}}  {PRODUCT_PICKER_LABEL[p]}" for p in PRODUCT_KEYWORDS]
    # `full` is an accepted alias of transcript (cli.resolve_profile); PRODUCT_ALIASES
    # holds the deprecated product spellings. Both are shown so the row can't imply
    # that only three spellings exist.
    aliases = {"full": "transcript", **PRODUCT_ALIASES}
    alias_str = ", ".join(f"{a} = {real}" for a, real in aliases.items())
    if alias_str:
        lines.append(f"aliases: {alias_str}")
    lines.append("")
    lines.append("Named plans (presets) build on these: opencode-db export --list-presets")
    return "\n".join(lines)

NOTES_JSON = [
    "faithful JSON keeps everything: all messages, reasoning and full tool outputs",
    "the markdown display filters do not apply to it: tool_output, role, no_reasoning, tool_input_limit",
]

SANITIZE_WARN = "sanitize redacts high-confidence secrets only (sk-, ghp_, AKIA, JWT, PEM), so review the output anyway"


def _jq_tostring(v) -> str:
    """Mirror jq's `tostring` for preset flag values fed to annotate_flags."""
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        return str(v)
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def _flag_csv(cfg: dict) -> str:
    """dict -> "key=value,key=value" (insertion order, jq tostring values)."""
    return ",".join(f"{k}={_jq_tostring(v)}" for k, v in cfg.items())


def _preset_products(pdata: dict) -> list[str]:
    """Insertion-ordered products of a preset (bundle keys or single product)."""
    if isinstance(pdata.get("products"), dict):
        return list(pdata["products"].keys())
    p = pdata.get("product")
    return [p] if p else []


def _bundle_cfg(pdata: dict) -> dict:
    """Per-product flag map for a bundle; {} for a single preset."""
    prods = pdata.get("products")
    return prods if isinstance(prods, dict) else {}


def resolve(profile: str, presets: dict | None = None) -> dict:
    """Resolve any profile into its full plan (product keyword or preset name).

    Returns a dict with kind ("product" | "preset"), products, per-product items
    (product/intro/flags/bits), has_json/has_sanitize and (presets only) the
    name/purpose. Raises ValueError for unknown profiles.
    """
    if presets is None:
        presets = load_presets()
    if profile in presets:
        return _resolve_preset(profile, presets[profile])
    if profile in PRODUCT_KEYWORDS:
        return {
            "kind": "product",
            "name": profile,
            "products": [profile],
            "items": [
                {
                    "product": profile,
                    "intro": PRODUCT_INTRO[profile],
                    "flags": "",
                    "bits": [],
                }
            ],
            "has_json": False,
            "has_sanitize": False,
            "descr": "",
            "purpose": "",
        }
    raise ValueError(f"unknown profile '{profile}'")


def _resolve_preset(name: str, pdata: dict) -> dict:
    products = _preset_products(pdata)
    has_bundle = bool(_bundle_cfg(pdata))
    items = []
    for p in products:
        if has_bundle:
            cfg = _bundle_cfg(pdata).get(p, {})
            flags = _flag_csv(cfg)
        else:
            cfg = pdata
            # single preset: the old oc_preset_product_flags fed the WHOLE
            # preset (product/filter/sessions + flags) to annotate_flags.
            flags = _flag_csv(pdata)
        items.append(
            {
                "product": p,
                "intro": PRODUCT_INTRO.get(p, p),
                "flags": flags,
                "bits": annotate_flags(flags),
            }
        )
    if has_bundle:
        has_json = any(
            _bundle_cfg(pdata).get(p, {}).get("json") is True for p in products
        )
        has_sanitize = any(
            _bundle_cfg(pdata).get(p, {}).get("sanitize") is True for p in products
        )
    else:
        has_json = pdata.get("json") is True
        has_sanitize = pdata.get("sanitize") is True
    return {
        "kind": "preset",
        "name": name,
        "products": products,
        "items": items,
        "has_json": has_json,
        "has_sanitize": has_sanitize,
        "descr": preset_descr(name, pdata),
        "purpose": plan_purpose(name),
    }


# --- text artifacts served to the menu ------------------------------------

# The confirm screen is deliberately FLAT: no bullets, no nesting, no labels.
# A product name sits at the left margin and every line of its description goes
# BELOW it, wrapped. Nothing is truncated and nothing is summarised away — the
# intros are the product's real documentation, so they are wrapped, not cut.
# Fixed width (not `tput cols`): it keeps the layout deterministic across
# terminals and assertable in the smoke suite.
PLAN_WIDTH = 72


def _wrap(text: str, width: int) -> list[str]:
    """Greedy word wrap, one paragraph per line-group. Never splits a word, so
    a long session id or path stays whole. width <= 0 disables wrapping."""
    if not text:
        return []
    if width <= 0:
        return text.split("\n")
    out: list[str] = []
    for para in text.split("\n"):
        out += textwrap.wrap(
            para, width, break_long_words=False, break_on_hyphens=False
        ) or [""]
    return out


def _product_block(item: dict, intro: str, width: int) -> list[str]:
    lines = [item["product"]]
    lines += _wrap(intro, width)
    # `bits` is a LIST of standalone phrases, emitted one per line. There is no
    # separator and no bullet: the old `" · ".join(...)` plus a '+' marker read
    # like an expression (`+faithful JSON… · full tool outputs`) rather than a
    # list of things, and the '+' only survived because it happened to be first.
    for bit in item["bits"]:
        lines += _wrap(bit, width)
    return lines


def plan_text(
    profile: str, presets: dict | None = None, width: int = PLAN_WIDTH
) -> str:
    """The product block of the confirm (NO label, NO leading indentation: the
    caller owns the surrounding layout). One line per product name, its
    description and its effective flags BELOW it, wrapped at `width`."""
    plan = resolve(profile, presets)
    blocks: list[list[str]] = []
    if plan["kind"] == "preset":
        for item in plan["items"]:
            blocks.append(_product_block(item, item["intro"], width))
    else:
        item = plan["items"][0]
        block = _product_block(item, item["intro"], width)
        # A bare product keyword has no preset behind it. That used to ride on
        # the description as "(default options)", but the 72-column wrap pushed
        # the parenthetical onto its own line, where it read as a stray fragment.
        # It is a caption in its own right, like every other line here.
        block.append("Default options, no flags set")
        blocks.append(block)
    return "\n\n".join("\n".join(b) for b in blocks)


def notes_text(
    profile: str, presets: dict | None = None, width: int = PLAN_WIDTH
) -> str:
    """The caveats of a plan, wrapped and label-free; "" when there are none.

    A note is NEVER a recipe of its own — `has_json`/`has_sanitize` are read off
    the preset's own flags (per product for a bundle), so these lines can only
    ever describe THAT recipe, which is why the caller marks them as an
    annotation of the plan instead of another thing it will produce.
    """
    plan = resolve(profile, presets)
    notes: list[str] = []
    if plan["has_json"]:
        notes += list(NOTES_JSON)
    if plan["has_sanitize"]:
        notes.append(SANITIZE_WARN)
    return "\n".join(line for note in notes for line in _wrap(note, width))


def preset_descr(name: str, pdata: dict | None = None) -> str:
    """One-line selection summary ('<sel> · product(s) <p> · config <keys>').
    Replicates oc_preset_descr (jq `keys` = sorted, empty config stays empty).
    """
    if pdata is None:
        pdata = load_presets().get(name, {})
    prods = _preset_products(pdata)
    p = "+".join(prods) if prods else "?"
    pw = "product" if "product" in pdata else "products"
    if "filter" in pdata:
        sel = "filter:" + _jq_tostring(pdata["filter"])
    elif "sessions" in pdata:
        sel = "sessions: " + ", ".join(pdata["sessions"])
    else:
        sel = "ALL sessions"
    cfg_keys = sorted(
        k for k in pdata if k not in ("product", "products", "filter", "sessions")
    )
    config = ",".join(cfg_keys)
    return f"{sel} · {pw} {p} · config {config}"


def preset_selection(name: str, pdata: dict | None = None) -> str:
    """The selection this preset PINS, as a human phrase for the menu's
    confirmation: 'filter "x"' | 'its N pinned session ids' | '' (empty = it
    pins none). Empty output is the normal case and the reason the menu has to
    be explicit: with no selection pinned, "everything marked" really does
    export everything. `last`/`since` cannot appear here — they are CLI-only
    (CLI_ONLY_KEYS), so a preset can never be non-reproducible.
    """
    if pdata is None:
        pdata = load_presets().get(name, {})
    if "filter" in pdata:
        return 'filter "' + _jq_tostring(pdata["filter"]) + '"'
    if "sessions" in pdata:
        n = len(pdata["sessions"])
        return f"its {n} pinned session id{'s' if n != 1 else ''}"
    return ""


def preset_subagents(name: str, pdata: dict | None = None) -> str:
    """Which subagent-inclusion keys this preset sets, as a short token for the
    menu's confirmation: 'no_subagents' | 'no_orphan_subagents' | 'both' | ''.
    Read across every product of a bundle, because the menu's switch is a
    whole-run decision: if ANY product drops subagents, the user should know
    before the gate.
    """
    if pdata is None:
        pdata = load_presets().get(name, {})
    cfgs: list[dict] = []
    bundle = _bundle_cfg(pdata)
    if bundle:
        cfgs = [v for v in bundle.values() if isinstance(v, dict)]
    else:
        cfgs = [pdata]
    drops_all = any(c.get("no_subagents") is True for c in cfgs)
    drops_orphan = any(c.get("no_orphan_subagents") is True for c in cfgs)
    if drops_all and drops_orphan:
        return "both"
    if drops_all:
        return "no_subagents"
    if drops_orphan:
        return "no_orphan_subagents"
    return ""


def preset_subagent_gaps(name: str, pdata: dict | None = None) -> str:
    """Every way this profile would NOT preserve the subagents it is handed,
    comma-separated ('' = it keeps them all).

    The shrink discard offer passes a CLOSED set (the discarded roots plus every
    descendant) precisely so nothing that dies with the copy is lost. Two
    different flags can quietly break that promise while the export still
    succeeds with plausible counts: `no_subagents`/`no_orphan_subagents` drop
    the sessions themselves, and `sub: omit` empties `children_of`, so the
    subagents are counted as roots of nothing and no body is ever written. The
    offer warns on the tokens instead of printing a command that reads like a
    safety net. Read across every product of a bundle, like preset_subagents:
    the decision is about the whole run.
    """
    if pdata is None:
        pdata = load_presets().get(name, {})
    bundle = _bundle_cfg(pdata)
    cfgs: list[dict] = (
        [v for v in bundle.values() if isinstance(v, dict)] if bundle else [pdata]
    )
    gaps = []
    if any(c.get("no_subagents") is True for c in cfgs):
        gaps.append("no_subagents")
    if any(c.get("no_orphan_subagents") is True for c in cfgs):
        gaps.append("no_orphan_subagents")
    if any(c.get("sub") == "omit" for c in cfgs):
        gaps.append("sub_omit")
    return ",".join(gaps)


def preset_rows(presets: dict | None = None) -> list[str]:
    """TSV picker rows for every preset, replicating oc_preset_rows (jq logic:
    purpose tag from product combo / transcript tool_output / sel + selection)."""
    if presets is None:
        presets = load_presets()
    rows: list[str] = []
    for key, pdata in presets.items():
        rows.append(_preset_row(key, pdata))
    return rows


def _row_fallback(pdata: dict) -> str:
    """Factual one-line fallback for a USER preset (no PLAN_TEXT blurb). The
    product is already the `[products]` column and a pinned selection is prefixed
    separately, so this is only the config keys — sorted, comma-joined, no ' · '
    (the picker-row symbology guard forbids it). "defaults" when it configures
    nothing."""
    bundle = _bundle_cfg(pdata)
    if bundle:
        keys = sorted(
            k for cfg in bundle.values() if isinstance(cfg, dict) for k in cfg
        )
    else:
        keys = sorted(
            k for k in pdata if k not in ("product", "products", "filter", "sessions")
        )
    return "config " + ",".join(keys) if keys else "defaults"


def _preset_row(key: str, pdata: dict) -> str:
    has_bundle = bool(_bundle_cfg(pdata))
    if has_bundle:
        products = list(pdata["products"].keys())
    else:
        products = [pdata.get("product", "")]
    # Three columns: name | [products] | description, exactly like the session
    # rows. The description is the hand-written `PLAN_TEXT` blurb for a shipped
    # plan and a factual config summary (`_row_fallback`) for a user preset —
    # never derived from the flag combo (that taxonomy let `prompts` and the
    # snapshot plan fall through to "transcript (defaults)"). A pinned selection
    # is still prefixed when the (possibly user-edited) preset carries one, so
    # the row can't hide it.
    if "filter" in pdata:
        sel = "filter " + _jq_tostring(pdata["filter"])
    elif "sessions" in pdata:
        n = len(pdata["sessions"])
        sel = f"{n} session id{'s' if n != 1 else ''}"
    else:
        sel = ""
    desc = plan_blurb(key) or _row_fallback(pdata)
    col3 = "  ".join(x for x in (sel, desc) if x)
    disp = "+".join(x for x in products if x)
    # Padding ONLY (name at 10, products at 22): a long name or product list
    # pushes the description right; fzf truncates the row's end, never the name.
    name = f"{key:<10}"
    row = f"{name} [{disp}]" if not col3 else f"{name} {f'[{disp}]':<22} {col3}"
    return f"__PRESET_{key}\t{row}"


def preset_names(presets: dict | None = None) -> list[str]:
    if presets is None:
        presets = load_presets()
    return sorted(presets.keys())


def legend_text(presets: dict | None = None) -> str:
    """Header lines ('   %-6s %s') for each shipped plan present in the file."""
    if presets is None:
        presets = load_presets()
    lines = []
    names = [n for n in preset_names(presets) if plan_purpose(n)]
    width = max((len(n) for n in names), default=0)
    for name in names:
        lines.append(f"   {name:<{width}} {plan_purpose(name)}")
    return "\n".join(lines)


# --- CLI bridge -----------------------------------------------------------

def _cli() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__ or __file__)
        return 1
    cmd = args[0]
    presets = None
    try:
        if cmd == "products":
            if len(args) > 1 and args[1] == "--legend":
                print("\n".join(PRODUCT_PICKER_LEGEND))
            else:
                for p in PRODUCT_KEYWORDS:
                    print(f"{p}\t{PRODUCT_PICKER_LABEL[p]}")
            return 0
        if cmd == "products-list":
            # Friendly screen for `export --list-products` (no DB).
            print(product_listing())
            return 0
        if cmd in ("rows", "names", "legend"):
            presets = load_presets()
        if cmd == "rows":
            for r in preset_rows(presets):
                print(r)
            return 0
        if cmd == "names":
            for n in preset_names(presets):
                print(n)
            return 0
        if cmd == "legend":
            print(legend_text(presets))
            return 0
        if cmd == "descr":
            if len(args) < 2:
                return 1
            presets = load_presets()
            if args[1] not in presets:
                return 1
            print(preset_descr(args[1], presets[args[1]]))
            return 0
        if cmd == "purpose":
            if len(args) < 2:
                return 1
            purpose = plan_purpose(args[1])
            if not purpose:
                return 1
            print(purpose)
            return 0
        if cmd == "snapshot":
            if len(args) < 2:
                return 1
            presets = load_presets()
            pdata = presets.get(args[1])
            if pdata is None:
                return 1
            print("fresh" if pdata.get("snapshot") == "fresh" else "")
            return 0
        if cmd == "selection":
            if len(args) < 2:
                return 1
            presets = load_presets()
            if args[1] not in presets:
                return 1
            print(preset_selection(args[1], presets[args[1]]))
            return 0
        if cmd == "selection-meta":
            # selection-meta <metadata.json> -> the human phrase for a stored
            # run's `.selection`. Bash (exports.sh) asks python for it so the
            # rules live in exactly one place: reading `.filter` there would
            # mis-report a `--last`/`--since` run as "sessions: all".
            if len(args) < 2:
                return 1
            try:
                with open(args[1], encoding="utf-8") as fh:
                    meta = json.load(fh)
            except (OSError, ValueError):
                return 1
            print(selection_phrase(meta))
            return 0
        if cmd == "subagents":
            if len(args) < 2:
                return 1
            presets = load_presets()
            if args[1] not in presets:
                return 1
            print(preset_subagents(args[1], presets[args[1]]))
            return 0
        if cmd == "subagent-gaps":
            # subagent-gaps <preset> -> the tokens of every subagent-preserving
            # gap ('' when it keeps them all). The shrink discard offer asks
            # this so a profile that would drop them warns BEFORE its y/N gate,
            # where the command still reads like a safety net.
            if len(args) < 2:
                return 1
            presets = load_presets()
            if args[1] not in presets:
                return 1
            gaps = preset_subagent_gaps(args[1], presets[args[1]])
            if gaps:
                print(gaps)
            return 0
        if cmd == "resolve":
            if len(args) < 2:
                return 1
            plan = resolve(args[1])
            print(json.dumps(plan, ensure_ascii=False, indent=2))
            return 0
        if cmd in ("plan", "notes"):
            if len(args) < 2:
                return 1
            # `plan <profile> [--width N]` / `notes <profile> [--width N]`
            width = PLAN_WIDTH
            if len(args) > 3 and args[2] == "--width" and args[3].isdigit():
                width = int(args[3])
            text = (
                plan_text(args[1], width=width)
                if cmd == "plan"
                else notes_text(args[1], width=width)
            )
            # No trailing newline when empty: an empty `$(...)` is how the
            # caller tells "this plan has no notes" from "it printed nothing".
            if text:
                print(text)
            return 0
    except ValueError:
        return 1
    except Exception as e:  # presets.load_presets dies on invalid files
        print(f"plan: {e}", file=sys.stderr)
        return 1
    print(f"plan: unknown command '{cmd}'", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(_cli())