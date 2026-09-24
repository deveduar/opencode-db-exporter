#!/usr/bin/env python3
"""Generate presets.schema.json + the docs/schemas.md §1 flags table from FLAGS.

Single source of truth: modules/exportlib/flags.py. Whenever FLAGS changes, run
this script and commit both generated artifacts:
    python3 scripts/generate_schema.py            # rewrites presets.schema.json
    python3 scripts/generate_schema.py --docs     # prints the markdown flags table
"""
import argparse
import json
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "modules"))
from exportlib.flags import FLAGS, PRODUCT_KEYWORDS, BUNDLE_PRODUCT_KEYS, SELECTION_KEYS, get_flags_for_product


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
            if f.name not in ["filter", "sessions", "out"]:
                product_flag_props[prod][f.name] = {"$ref": f"#/definitions/flag{f.name.capitalize()}"}

    # Bundle product flag groups
    bundle_product_props = {}
    for prod in PRODUCT_KEYWORDS:
        bundle_product_props[prod] = {}
        for f in get_flags_for_product(prod):
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
                            **{f.name: {"$ref": f"#/definitions/flag{f.name.capitalize()}"} for f in FLAGS if f.name not in ["filter", "sessions", "out"]},
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
                                            **{f.name: {"$ref": f"#/definitions/flag{f.name.capitalize()}"} for f in FLAGS if f.name not in ["filter", "sessions", "out"]}
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
    """Render the docs/schemas.md §1 per-key table from FLAGS."""
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
        elif f.name == "out":
            continue  # rendered on its own row below (CLI-only)
        else:
            applies = _flag_applies(f)
        rows.append(f"| {name} | {typ} | {allowed} | {applies} |")
    rows.append(
        "| `out` | string | — | any — CLI-only (never a preset key) |"
    )
    return "\n".join(rows)
    return "\n".join(rows)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--docs", action="store_true",
                    help="print the docs/schemas.md §1 flags table and exit")
    args = ap.parse_args()
    if args.docs:
        print(flags_table())
        sys.exit(0)
    schema = generate_schema()
    with open("presets.schema.json", "w", encoding="utf-8") as f:
        json.dump(schema, f, indent=2, ensure_ascii=False)
    print("Generated presets.schema.json")