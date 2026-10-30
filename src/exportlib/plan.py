# Export plan API — the single Python place that answers "what will this export
# produce?" for any profile (product keyword OR named preset), plus the
# bash<->python JSON/text bridge used by menu.sh. This replaces the jq helpers
# (oc_preset_rows, oc_preset_legend, oc_export_plan, ...) that used to live in
# menu.sh: product intros and the flag annotation bits are all resolved here and
# served over one CLI. A preset's own prose (`description`) is read from the
# presets file, never kept in code.
#
# CLI subcommands (each prints one artifact; exit 1 = nothing to produce):
#   rows                 TSV preset rows for the fzf picker (key<TAB>display)
#   names                preset names (sorted, one per line)
#   legend               header lines for the presets that carry a description
#   products             TSV product rows for the product picker (key<TAB>label)
#   products --legend    the product picker header legend (use-it-when lines)
#   products-list        the friendly `export --list-products` screen (no DB)
#   resolve <profile>    JSON plan for a product keyword or preset name
#   plan <profile> [--width N]   the plan block shared by the confirm, --show and
#                        --dry-run: a preset's card (name (products), description,
#                        flags, fidelity, example tree); a keyword gets its intro,
#                        caption, fidelity + tree
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
        PRESET_DESCRIPTION_KEY,
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
        PRESET_DESCRIPTION_KEY,
        PRODUCT_ALIASES,
        PRODUCT_KEYWORDS,
        PRODUCT_INTRO,
        annotate_flags,
    )

# The one-line human description of a preset lives IN the presets file (key
# `description`), so the prose travels with the recipe and can never drift from
# it. A preset without one simply shows no prose: there is no text catalog to
# fall back to and no flag-combo taxonomy to guess a label from (that derivation
# is how `prompts` and the snapshot plan once got mislabelled "transcript
# (defaults)").

# Product picker rows/labels (TSV key<TAB>label) and the header legend passed to
# the fzf picker. Served to menu.sh by the `products` subcommand. Rows stay SHORT;
# the "use it when / size / redundancy" legend lives in the header (see menu.sh).
PRODUCT_PICKER_LABEL = {
    "transcript": "READ / SHARE / AUDIT — the conversation as Markdown (per session, display-filtered)",
    "memory": "FEED ANOTHER AI — machine-readable corpus (corpus.jsonl, one line per session)",
    "digest": "QUICK KNOWLEDGE REVIEW — only the compaction summaries",
    "faithful": "LOSSLESS MACHINE ARCHIVE — the complete session as native JSON (info + messages)",
}

PRODUCT_PICKER_LEGEND = [
    "Choose ONE product (runs with DEFAULT options; ESC: back):",
    "   transcript   HEAVY, human-readable: your asks, the answers, reasoning, every tool call + output",
    "                and the code patches, compaction digests inline (display-filtered).",
    "   memory       LIGHT, machine-readable: tokens/cost, todos, tools, first ask + last answer and ALL",
    "                compaction digests per session. For feeding another AI (RAG); streamed line by line.",
    "   digest       TINY extract: only the compaction summaries (the knowledge arc of a session). Already",
    "                inside transcript AND memory — standalone is just a fast skim.",
    "   faithful     LOSSLESS: the native opencode JSON, one file per session, unfiltered (only --sanitize",
    "                redacts). The raw copy a filtered product cannot promise; pair it to be lossless.",
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
    """dict -> "key=value,key=value" (insertion order, jq tostring values).

    The `description` meta key is skipped: it is free text (may contain a comma
    or even a "key=value" substring) and configures nothing, so it must never
    reach annotate_flags' parse."""
    return ",".join(
        f"{k}={_jq_tostring(v)}"
        for k, v in cfg.items()
        if k != PRESET_DESCRIPTION_KEY
    )


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


def fidelity_parts(
    products: list[str], has_sanitize: bool, configs: list[dict]
) -> tuple[str, str]:
    """The data fidelity of a plan as `(verdict, reason)`, derived from the
    resolved flags. `lossless` means the raw data is fully recoverable: the
    `faithful` product is part of the plan AND nothing drops data — no
    subagent-dropping flag (`no_subagents`/`no_orphan_subagents`) and no
    `sanitize` (redaction is best-effort and not reviewable, so the raw data is
    not guaranteed). Every other case is `lossy` with the reasons.

    The reason depends on WHICH product carries the data: a content product
    (`transcript`/`digest`) without `faithful` loses what its Markdown filters
    out; `memory` is not a transcript but a distilled RAG corpus, so its reason
    is the corpus shape, not a missing copy. `sub: omit` only affects the
    Markdown layout (the subagents are still in the set), so it is a loss only
    when no `faithful` copy carries them.

    This is the ONE fidelity computation: the `fidelity:` card line
    (`fidelity_label`) and the picker row's verdict column both read it, so the
    two can never disagree.
    """
    reasons: list[str] = []
    content = any(p in ("transcript", "digest") for p in products)
    has_faithful = "faithful" in products
    if not has_faithful:
        if content:
            reasons.append("no faithful JSON: the Markdown is filtered")
        elif products:
            reasons.append("the RAG corpus is a summary, not the full session")
    if has_sanitize:
        reasons.append("sanitized (best-effort)")
    if any(c.get("no_subagents") is True for c in configs):
        reasons.append("all subagents dropped")
    if any(c.get("no_orphan_subagents") is True for c in configs):
        reasons.append("orphan subagents dropped")
    if not has_faithful and any(c.get("sub") == "omit" for c in configs):
        reasons.append("subagents omitted")
    if reasons:
        return "lossy", "(" + ", ".join(reasons) + ")"
    return "lossless", "(the faithful JSON keeps the full data)"


def fidelity_label(
    products: list[str], has_sanitize: bool, configs: list[dict]
) -> str:
    """The full `fidelity:` phrase (verdict + reason) of a plan's card."""
    verdict, reason = fidelity_parts(products, has_sanitize, configs)
    return f"{verdict} {reason}"


def resolve(profile: str, presets: dict | None = None) -> dict:
    """Resolve any profile into its full plan (product keyword or preset name).

    Returns a dict with kind ("product" | "preset"), products, per-product items
    (product/intro/flags/bits), has_sanitize, the derived `fidelity` phrase and
    (presets only) the name/purpose. Raises ValueError for unknown profiles.
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
                    "config": {},
                }
            ],
            "has_sanitize": False,
            "fidelity": fidelity_label([profile], False, []),
            "description": "",
            "bundle": False,
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
                "config": cfg,
            }
        )
    if has_bundle:
        has_sanitize = any(
            _bundle_cfg(pdata).get(p, {}).get("sanitize") is True for p in products
        )
    else:
        has_sanitize = pdata.get("sanitize") is True
    configs = [item["config"] for item in items]
    return {
        "kind": "preset",
        "name": name,
        "products": products,
        "items": items,
        "has_sanitize": has_sanitize,
        "fidelity": fidelity_label(products, has_sanitize, configs),
        "description": pdata.get(PRESET_DESCRIPTION_KEY, ""),
        "bundle": has_bundle,
    }


# --- text artifacts served to the menu ------------------------------------

# The plan block is deliberately compact and cannot drift from `--explain`: the
# card (name/products, description, flags and the file tree) is built ONCE, by
# `card_lines()`, and used both by the per-preset catalog and by `plan_text()`.
# A preset emits the card alone: the products are named in its `name (products)`
# header, so their generic intros are already covered. A bare product keyword has
# no recipe, so it shows its intro, the `Default options, no flags set` caption
# and the same tree. Fixed width (not `tput cols`): it keeps the layout
# deterministic and assertable in the suite.
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


def plan_text(
    profile: str, presets: dict | None = None, width: int = PLAN_WIDTH
) -> str:
    """The plan block shared by the confirm, `--show` and `--dry-run`.

    A preset renders as its card alone, from `card_lines()` (name/products,
    description, the flags it sets, its derived `fidelity:` line and an example
    file tree): the card names its products in the `name (products)` header, so
    repeating their generic intros above it would be a redundant legend. A bare
    product keyword has no recipe and therefore no card, so it prints its intro,
    the `Default options, no flags set` caption, its `fidelity:` line and the
    same tree."""
    plan = resolve(profile, presets)
    if plan["kind"] == "preset":
        return "\n".join(card_lines(profile, presets, width))
    item = plan["items"][0]
    lines = [item["product"]] + _wrap(item["intro"], width)
    # A bare product keyword has no preset behind it. That used to ride on the
    # description as "(default options)"; it is a caption in its own right.
    lines.append("Default options, no flags set")
    lines += _wrap("fidelity: " + plan["fidelity"], width)
    lines += example_tree(profile, presets)
    return "\n".join(lines)


# --- example file tree + the shared card (the plan and `--explain`) -------
# `--explain` is a STATIC catalog: it never reads the DB. The card below is the
# ONE place a preset's output is described (description + flags + fidelity +
# tree), reused by `plan_text()` so the runtime plan and the catalog cannot drift.

def _session_tree(product: str, cfg: dict) -> dict:
    """The nested tree of ONE product's output dir (dict = dir, None = file)."""
    if product == "memory":
        return {"corpus.jsonl": None, "index.md": None, "metadata.json": None}
    if product == "faithful":
        # JSON only, always one folder per session with subagents/ inside (there
        # is no `sub` layout: inline/omit only make sense for Markdown).
        return {
            "01-<title>_<id>": {
                "<title>.json": None,
                "subagents": {"<sub>_<id>.json": None},
            },
            "index.md": None,
            "metadata.json": None,
        }
    # transcript and digest share the writer (and therefore the layout).
    session: dict = {"<title>.md": None}
    if product == "transcript" and cfg.get("chunk_mb", 1) > 0:
        session["<title>.parts (only when over limit)"] = {
            "part-NNN.md": None,
            "index.md": None,
        }
    if cfg.get("sub", "separate") == "separate":
        session["subagents"] = {"<sub>_<id>.md": None}
    return {"01-<title>_<id>": session, "index.md": None, "metadata.json": None}


def _tree_lines(children: dict, prefix: str = "") -> list[str]:
    """Render a nested dict as an indented tree (classic box-drawing)."""
    out: list[str] = []
    items = list(children.items())
    for i, (name, sub) in enumerate(items):
        last = i == len(items) - 1
        out.append(prefix + ("└── " if last else "├── ") + name + ("/" if sub is not None else ""))
        if sub is not None:
            out += _tree_lines(sub, prefix + ("    " if last else "│   "))
    return out


def example_tree(profile: str, presets: dict | None = None) -> list[str]:
    """An example of the files a profile writes, as tree lines (no indentation:
    the caller decides where it sits). Derived from the resolved plan."""
    plan = resolve(profile, presets)
    root: dict = {}
    if plan["bundle"]:
        root["index.md"] = None
    for item in plan["items"]:
        root[item["product"]] = _session_tree(item["product"], item.get("config", {}))
    return ["<stamp>/"] + _tree_lines(root)


def card_lines(
    profile: str, presets: dict | None = None, width: int = PLAN_WIDTH
) -> list[str]:
    """The card of ONE preset: `name (products)`, its description, the flags it
    sets (one `flags:` line, only when it sets some), its derived `fidelity:` line
    and an example file tree indented under it. This is the ONE place a preset's
    output is described — `explain_text()` prints it for every preset and
    `plan_text()` for the chosen one, so the catalog and the runtime plan cannot
    drift apart."""
    plan = resolve(profile, presets)
    prod = " + ".join(plan["products"])
    lines = [f"{profile} ({prod})"]
    desc = plan["description"]
    if desc:
        for ln in _wrap(desc, width - 2):
            lines.append("  " + ln)
    bits = [b for item in plan["items"] for b in item["bits"]]
    if bits:
        for ln in _wrap("flags: " + " · ".join(bits), width - 2):
            lines.append("  " + ln)
    for ln in _wrap("fidelity: " + plan["fidelity"], width - 2):
        lines.append("  " + ln)
    for ln in example_tree(profile, presets):
        lines.append("  " + ln)
    return lines


def explain_text(presets: dict | None = None) -> str:
    """The `export --explain` catalog: products once, then one card per preset
    (description + set flags + fidelity + an example file tree). Static, no DB."""
    if presets is None:
        presets = load_presets()
    names = preset_names(presets)
    lines = ["== What each preset produces ==", ""]
    lines.append("Products (what a document is):")
    w = max(len(p) for p in PRODUCT_INTRO)
    for p, intro in PRODUCT_INTRO.items():
        lines.append(f"  {p:<{w}}  {intro}")
    lines.append("")
    for n in names:
        lines += card_lines(n, presets)
        lines.append("")
    return "\n".join(lines)


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
    """TSV picker rows for every preset (name | [products] | description + sel)."""
    if presets is None:
        presets = load_presets()
    rows: list[str] = []
    for key, pdata in presets.items():
        rows.append(_preset_row(key, pdata))
    return rows


def _preset_row(key: str, pdata: dict) -> str:
    # Four columns: name | [products] | verdict | description, exactly like the
    # session rows. The verdict is DERIVED (fidelity_parts) — never a word in the
    # description, so the two cannot duplicate. The description is the preset's
    # OWN `description` key (empty when it has none) — never derived from the flag
    # combo (that taxonomy let `prompts` and the snapshot plan fall through to
    # "transcript (defaults)"). A pinned selection is still prefixed when the
    # (possibly user-edited) preset carries one, so the row can't hide it.
    plan = _resolve_preset(key, pdata)
    products = plan["products"]
    verdict = fidelity_parts(
        products, plan["has_sanitize"], [item["config"] for item in plan["items"]]
    )[0]
    if "filter" in pdata:
        sel = "filter " + _jq_tostring(pdata["filter"])
    elif "sessions" in pdata:
        n = len(pdata["sessions"])
        sel = f"{n} session id{'s' if n != 1 else ''}"
    else:
        sel = ""
    desc = pdata.get(PRESET_DESCRIPTION_KEY, "")
    col3 = "  ".join(x for x in (sel, desc) if x)
    disp = "+".join(x for x in products if x)
    # Padding ONLY (name at 15, products at 22, verdict at 9): a long name or
    # product list pushes the rest right; fzf truncates the row's end, never the
    # name.
    name = f"{key:<15}"
    prods = f"{f'[{disp}]':<22}"
    row = f"{name} {prods} {verdict}" if not col3 else f"{name} {prods} {verdict:<9} {col3}"
    return f"__PRESET_{key}\t{row}"


def preset_names(presets: dict | None = None) -> list[str]:
    if presets is None:
        presets = load_presets()
    return sorted(presets.keys())


def legend_text(presets: dict | None = None) -> str:
    """Header lines (`   %-6s %s`) for each preset that carries a description.

    The derived verdict is a column too (same source as the picker row), so the
    legend and the rows can never disagree.
    """
    if presets is None:
        presets = load_presets()
    names = [n for n in preset_names(presets) if presets[n].get(PRESET_DESCRIPTION_KEY)]
    width = max((len(n) for n in names), default=0)
    lines = []
    for name in names:
        plan = _resolve_preset(name, presets[name])
        verdict = fidelity_parts(
            plan["products"],
            plan["has_sanitize"],
            [item["config"] for item in plan["items"]],
        )[0]
        lines.append(
            f"   {name:<{width}} {verdict:<9} {presets[name][PRESET_DESCRIPTION_KEY]}"
        )
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
        if cmd == "selection-phrase":
            # selection-phrase < {"selection": {...}} -> the human phrase for an
            # arbitrary stored selection object already lifted onto stdin. Used
            # by `exports view` to render `.scope` with the SAME rules that name
            # `.selection`, so scope and selection can never disagree.
            try:
                meta = json.load(sys.stdin)
            except ValueError:
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
        if cmd == "plan":
            if len(args) < 2:
                return 1
            # `plan <profile> [--width N]`
            width = PLAN_WIDTH
            if len(args) > 3 and args[2] == "--width" and args[3].isdigit():
                width = int(args[3])
            text = plan_text(args[1], width=width)
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
