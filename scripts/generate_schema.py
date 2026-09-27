#!/usr/bin/env python3
"""Generate the versioned artifacts under generated/ from FLAGS (+ SHRINK_FLAGS).

Single source of truth: modules/exportlib/flags.py (presets) and
modules/shrinklib/flags.py (shrink). Whenever FLAGS/SHRINK_FLAGS change, run
this script and commit the generated artifacts:
    python3 scripts/generate_schema.py            # rewrites the schema .json files
    python3 scripts/generate_schema.py --docs     # rewrites the flags-table .md files (also prints them)
"""
import argparse
import json
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "modules"))
from exportlib.flags import (
    CLI_ONLY_KEYS,
    FLAGS,
    PRODUCT_KEYWORDS,
    get_flags_for_product,
)
from shrinklib.flags import SHRINK_FLAGS, OPERATION_KEYS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATED = os.path.join(ROOT, "generated")
SCHEMA_PATH = os.path.join(GENERATED, "presets.schema.json")
FLAGS_TABLE_PATH = os.path.join(GENERATED, "flags-table.md")
SHRINK_SCHEMA_PATH = os.path.join(GENERATED, "shrink.schema.json")
SHRINK_FLAGS_TABLE_PATH = os.path.join(GENERATED, "shrink-flags-table.md")

# Flags present at a single preset's top level but NEVER per-product (bundle) nor
# in the product flag groups. Kept in sync with exportlib.flags.SINGLE_ONLY_KEYS.
_SINGLE_ONLY = ("snapshot",)
_PRESET_EXCLUDED = ("filter", "sessions") + CLI_ONLY_KEYS


def generate_schema() -> dict:
    """Generate the full presets.schema.json from FLAGS."""
    # Build flag definitions
    flag_defs = {}
    for f in FLAGS:
        if f.flag_type == "bool":
            flag_defs[f"flag{f.name.capitalize()}"] = {"type": "boolean", "description": f.description}
        elif f.flag_type == "choice":
            flag_defs[f"flag{f.name.capitalize()}"] = {"type": "string", "enum": f.choices, "description": f.description}
        elif f.flag_type == "int":
            schema = {"type": "integer", "description": f.description}
            if f.min_value is not None:
                schema["minimum"] = f.min_value
            flag_defs[f"flag{f.name.capitalize()}"] = schema
        elif f.flag_type == "string":
            flag_defs[f"flag{f.name.capitalize()}"] = {"type": "string", "description": f.description}

    # Product flag groups (for single-product presets)
    product_flag_props = {}
    for prod in PRODUCT_KEYWORDS:
        product_flag_props[prod] = {}
        for f in get_flags_for_product(prod):
            if f.name not in _PRESET_EXCLUDED + _SINGLE_ONLY:
                product_flag_props[prod][f.name] = {"$ref": f"#/definitions/flag{f.name.capitalize()}"}

    # Bundle product flag groups
    bundle_product_props = {}
    for prod in PRODUCT_KEYWORDS:
        bundle_product_props[prod] = {}
        for f in get_flags_for_product(prod):
            if f.name not in list(_SINGLE_ONLY):
                bundle_product_props[prod][f.name] = {"$ref": f"#/definitions/flag{f.name.capitalize()}"}

    # Selection properties
    selection_props = {
        "filter": {"type": "string", "minLength": 1, "description": "SQL LIKE pattern on session id/title"},
        "sessions": {"type": "array", "minItems": 1, "items": {"type": "string", "minLength": 1}, "description": "Exact session ids"}
    }

    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "$id": "https://opencode-db-exporter.local/schemas/presets.schema.json",
        "title": "opencode-db presets.json",
        "description": "Contract for the OCED_PRESETS file, the source of truth for `opencode-db export <name>` and the export menu. A preset is either a single product (key `product`) or a bundle of products under one stamp (key `products`). Full schema notes and the other contracts live in docs/schemas.md.",
        "type": "object",
        "additionalProperties": False,
        "required": ["presets"],
        "properties": {
            "presets": {
                "type": "object",
                "description": "Name -> preset. Names conflict with product keywords (transcript|memory|compactions|full) are allowed as data, but `export <name>` always resolves a keyword first.",
                "additionalProperties": {"$ref": "#/definitions/preset"}
            }
        },
        "definitions": {
            "nonNegInt": {"type": "integer", "minimum": 0},
            "bool": {"type": "boolean"},
            "filter": {"type": "string", "minLength": 1, "description": "SQL LIKE pattern on session id/title (session selection)."},
            "sessions": {
                "type": "array",
                "minItems": 1,
                "description": "Exact session ids (session selection; exclusive with a preset 'filter').",
                "items": {"type": "string", "minLength": 1}
            },
            **flag_defs,
            "flagProps": {
                "description": "Config flags accepted (single: at the preset's top level; bundle: per product). Product-flags that do not affect a product (e.g. cap/files on transcript, json on memory) are ignored.",
                "type": "object",
                "properties": {
                    **{f.name: {"$ref": f"#/definitions/flag{f.name.capitalize()}"} for f in FLAGS}
                }
            },
            "selectionProps": {
                "description": "Shared session selection (filter LIKE or exact sessions, never both; a CLI --filter/--sessions voids it).",
                "type": "object",
                "properties": selection_props,
                "not": {"required": ["filter", "sessions"]}
            },
            "preset": {
                "oneOf": [
                    {
                        "title": "single-product preset",
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["product"],
                        "properties": {
                            "product": {"type": "string", "enum": list(PRODUCT_KEYWORDS), "description": "full is a CLI alias, not a preset product."},
                            **{f.name: {"$ref": f"#/definitions/flag{f.name.capitalize()}"} for f in FLAGS if f.name not in _PRESET_EXCLUDED},
                            "filter": {"$ref": "#/definitions/filter"},
                            "sessions": {"$ref": "#/definitions/sessions"}
                        },
                        "not": {"required": ["filter", "sessions"]}
                    },
                    {
                        "title": "bundle preset",
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["products"],
                        "properties": {
                            "products": {
                                "type": "object",
                                "minProperties": 1,
                                "additionalProperties": False,
                                "patternProperties": {
                                    f"^({'|'.join(PRODUCT_KEYWORDS)})$": {
                                        "type": "object",
                                        "description": "Per-product flags; the selection (top level) is shared by every product.",
                                        "additionalProperties": False,
                                        "properties": {
                                            **{f.name: {"$ref": f"#/definitions/flag{f.name.capitalize()}"} for f in FLAGS if f.name not in _PRESET_EXCLUDED + _SINGLE_ONLY}
                                        }
                                    }
                                }
                            },
                            "filter": {"$ref": "#/definitions/filter"},
                            "sessions": {"$ref": "#/definitions/sessions"}
                        },
                        "not": {"required": ["filter", "sessions"]}
                    }
                ]
            }
        }
    }


def _flag_type(allowed: str, f) -> tuple[str, str]:
    """Return (type-col, allowed-col) for a flag row."""
    if f.flag_type == "bool":
        return "bool", "—"
    if f.flag_type == "choice":
        return "string", " \\| ".join(f"`{c}`" for c in (f.choices or []))
    if f.flag_type == "int":
        if f.name == "cap":
            return "int", "0 = unlimited (≥ 0)"
        return "int", ("≥ 0" if f.min_value == 0 else "—")
    return "string", "—"


def _flag_applies(f) -> str:
    if f.products == ["*"]:
        return "any"
    if f.name == "json":
        return "transcript/compactions (faithful archive)"
    if f.name == "files":
        return "memory (touched files)"
    return ", ".join(f.products)


def flags_table() -> str:
    """Render the docs/schemas.md §1 per-key table from FLAGS (also written to generated/flags-table.md)."""
    rows = [
        "| `product` | string | `transcript` \\| `memory` \\| `compactions` | "
        "single only (`full` is a CLI alias, **not** a preset product) |",
        "| `products` | object | keys restricted to the 3 products | "
        "bundle only (exclusive with `product`) |",
        "| Product flags (top level for single, per product for bundle): | | | |",
    ]
    for f in FLAGS:
        name = f"`{f.name}`"
        typ, allowed = _flag_type("", f)
        if f.name == "filter":
            name = "`filter` / `sessions`"
            typ = "string / string[]"
            allowed = "—"
            applies = "selection (shared; exclusive, `not` both)"
        elif f.name == "sessions":
            continue  # rendered together with `filter`
        elif f.name in CLI_ONLY_KEYS:
            continue  # rendered on its own rows below (CLI-only)
        else:
            applies = _flag_applies(f)
        rows.append(f"| {name} | {typ} | {allowed} | {applies} |")
    for name, typ in (("out", "string"), ("last", "int ≥ 1"), ("since", "date YYYY-MM-DD")):
        rows.append(
            f"| `{name}` | {typ} | — | any — CLI-only (never a preset key: "
            f"{'output root' if name == 'out' else 'a recency rule, recomputed at run time'}) |"
        )
    return "\n".join(rows)


# ---- Shrink (OCED_SHRINK_PRESETS) ------------------------------------------

def generate_shrink_schema() -> dict:
    """Shrink-presets schema from the OPERATION keys of SHRINK_FLAGS. A recipe
    carries only operations (what is done to the copy besides the pruning); the
    session selection is NOT a preset key — it is the CLI selection flags or the
    menu's sessions picker (see the selection flags in the flags table)."""
    defs: dict = {}
    for f in SHRINK_FLAGS:
        if f.name not in OPERATION_KEYS:
            continue
        if f.flag_type == "bool":
            defs[f"flag{f.name.capitalize()}"] = {"type": "boolean", "description": f.description}
        elif f.flag_type == "int":
            defs[f"flag{f.name.capitalize()}"] = {
                "type": "integer", "minimum": f.min_value or 1, "description": f.description,
            }
        else:
            defs[f"flag{f.name.capitalize()}"] = {"type": "string", "minLength": 1, "description": f.description}

    op_props = {k: {"$ref": f"#/definitions/flag{k.capitalize()}"} for k in OPERATION_KEYS}
    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "$id": "https://opencode-db-exporter.local/schemas/shrink.schema.json",
        "title": "opencode-db shrink-presets.json",
        "description": "Contract for the OCED_SHRINK_PRESETS file, the source of truth for `opencode-db shrink <name>` and the shrink menu's operations step. A recipe carries ONLY operations (e.g. strip_reasoning); the session selection is a separate concern (CLI selection flags, or the menu's sessions picker). A user file may override or extend the built-in recipes (lean/quiet).",
        "type": "object",
        "additionalProperties": False,
        "required": ["presets"],
        "properties": {
            "presets": {
                "type": "object",
                "description": "Name -> recipe (operations only). Built-in recipes (lean/quiet) are always available; a file entry with the same name overrides them.",
                "additionalProperties": {"$ref": "#/definitions/shrinkPreset"},
            }
        },
        "definitions": {
            **defs,
            "shrinkPreset": {
                "type": "object",
                "description": "Operations applied to the copy besides the session pruning. An empty object = prune + vacuum only.",
                "additionalProperties": False,
                "properties": op_props,
            },
        },
    }


def _shrink_flag_cell(name: str) -> str:
    """Allowed-values cell of one shrink flag row."""
    if name in ("keep", "older_than"):
        return "int ≥ 1"
    if name == "since":
        return "date string `YYYY-MM-DD` (UTC)"
    if name in ("keep_sessions", "discard_sessions"):
        return "string[] (session ids, ≥ 1 item)"
    return "true/false"


def shrink_flags_table() -> str:
    """Render the docs/schemas.md shrink tables (also written to
    generated/shrink-flags-table.md): the CLI selection flags and the operation
    keys a recipe may carry."""
    rows = [
        "## Session selection — CLI only (the menu asks you with its picker)",
        "",
        "| Key | Allowed | Meaning |",
        "|---|---|---|",
        "| `keep` | int ≥ 1 | keep the N most recent sessions (by last update) |",
        "| `older_than` | int ≥ 1 | keep sessions updated within the last N days |",
        "| `since` | string | keep sessions updated on or after DATE (YYYY-MM-DD, UTC) |",
        "| `keep_all` | true/false | keep ALL sessions (just prune orphans + vacuum) |",
        "| `keep_sessions` | string[] | keep ONLY the listed session ids (+ their parents/subagents) |",
        "| `discard_sessions` | string[] | keep everything EXCEPT the listed session ids (+ their subagents) |",
        "",
        "Exactly ONE selection rule (`keep` \\| `older_than` \\| `since` \\| `keep_all` \\| `keep_sessions` \\| `discard_sessions`) per invocation — they are mutually exclusive (`keep` = 10 is the default).",
        "",
        "## Operations — the only keys a recipe/preset may carry",
        "",
        "| Key | Allowed | Meaning |",
        "|---|---|---|",
    ]
    for f in SHRINK_FLAGS:
        if f.name in OPERATION_KEYS:
            rows.append(f"| `{f.name}` | {_shrink_flag_cell(f.name)} | {f.description} |")
    rows += [
        "",
        "A recipe is a named combination of operations; the session selection never lives in a recipe (a keep rule inside a preset is rejected, pointing at the flags above).",
    ]
    return "\n".join(rows)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--docs", action="store_true",
                    help="rewrite generated/flags-table.md + shrink-flags-table.md and print them (backwards-compatible)")
    args = ap.parse_args()
    os.makedirs(GENERATED, exist_ok=True)
    if args.docs:
        table = flags_table() + "\n"
        with open(FLAGS_TABLE_PATH, "w", encoding="utf-8") as f:
            f.write(table)
        print(f"Generated {os.path.relpath(FLAGS_TABLE_PATH, ROOT)}")
        print(table, end="")
        shrink_table = shrink_flags_table() + "\n"
        with open(SHRINK_FLAGS_TABLE_PATH, "w", encoding="utf-8") as f:
            f.write(shrink_table)
        print(f"Generated {os.path.relpath(SHRINK_FLAGS_TABLE_PATH, ROOT)}")
        print(shrink_table, end="")
        sys.exit(0)
    schema = generate_schema()
    with open(SCHEMA_PATH, "w", encoding="utf-8") as f:
        json.dump(schema, f, indent=2, ensure_ascii=False)
    print(f"Generated {os.path.relpath(SCHEMA_PATH, ROOT)}")
    shrink_schema = generate_shrink_schema()
    with open(SHRINK_SCHEMA_PATH, "w", encoding="utf-8") as f:
        json.dump(shrink_schema, f, indent=2, ensure_ascii=False)
    print(f"Generated {os.path.relpath(SHRINK_SCHEMA_PATH, ROOT)}")