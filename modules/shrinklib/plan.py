# Shrink plan API — the single Python place that answers "what will this shrink
# produce?" for any named recipe/preset, plus the bash<->python bridge used by
# menu.sh and shrink.sh. Built-in recipes (lean/recent/full/bare) always resolve;
# presets from OCED_SHRINK_PRESETS extend/override them. Flag/rule validation and
# the baked raw args live in shrinklib/presets.py (single source of truth).
#
# CLI subcommands:
#   rows                 TSV preset rows for the fzf picker (key<TAB>display)
#   names                recipe/preset names (merged, one per line)
#   descr <name>         one-line summary of a recipe/preset
#   purpose <name>       one-line purpose for the shipped recipes (unknown -> 1)
#   plan <name>          multi-line "Will produce:" block for the confirm
#   bake <name>          raw flags for the bash parser (last-wins on the CLI)
#   selection <name>     JSON {"rule": ..., "ids": [...]} for keep/discard offer
#   list-presets         <name>\t<summary> rows for `shrink --list-presets`
from __future__ import annotations

import json
import os
import sys

MODULES_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if MODULES_DIR not in sys.path:
    sys.path.insert(0, MODULES_DIR)

try:
    from shrinklib.presets import (
        bake_args,
        load_shrink_presets,
        merged_presets,
        rule_lines,
    )
    from shrinklib.flags import SHRINK_PRESET_PURPOSE
except ImportError:
    # fallback for in-place execution (python3 modules/shrinklib/plan.py ...)
    from presets import bake_args, load_shrink_presets, merged_presets, rule_lines
    from flags import SHRINK_PRESET_PURPOSE


def _cfg(name: str) -> dict:
    presets = merged_presets()
    if name not in presets:
        known = ", ".join(sorted(presets))
        raise ValueError(f"unknown shrink recipe/preset '{name}' — known: {known}")
    return presets[name]


def _short(cfg: dict) -> str:
    return " + ".join(rule_lines(cfg))


def preset_rows() -> list[str]:
    """TSV rows: __PRESET_<name>\t<name>  <summary>. Built-ins first (in their
    natural order), then file presets that are not shipped recipes."""
    merged = merged_presets()
    rows: list[str] = []
    for name in merged:
        rows.append(f"__PRESET_{name}\t{name}  {_short(merged[name])}")
    return rows


def preset_names() -> list[str]:
    return list(merged_presets().keys())


def plan_text(name: str) -> str:
    """Multi-line 'Will produce:' block (no leading indentation; the caller adds
    uniform indentation)."""
    cfg = _cfg(name)
    lines = [f"{name}:"]
    for line in rule_lines(cfg):
        lines.append(f"  - {line}")
    return "\n".join(lines)


def selection_json(name: str) -> str:
    """Selection metadata for the menu: the keep rule and the exact session ids
    (meaningful for keep_sessions/discard_sessions)."""
    cfg = _cfg(name)
    for k in ("keep_sessions", "discard_sessions"):
        if k in cfg:
            return json.dumps({"rule": k, "ids": cfg[k]})
    if "keep" in cfg:
        return json.dumps({"rule": "keep"})
    if "older_than" in cfg:
        return json.dumps({"rule": "older_than"})
    if "since" in cfg:
        return json.dumps({"rule": "since"})
    return json.dumps({"rule": "keep_all"})


def _cli() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__ or __file__)
        return 1
    cmd = args[0]
    try:
        if cmd == "rows":
            for r in preset_rows():
                print(r)
            return 0
        if cmd == "names":
            for n in preset_names():
                print(n)
            return 0
        if cmd in ("descr", "plan", "bake", "selection", "purpose"):
            if len(args) < 2:
                return 1
            name = args[1]
        else:
            name = ""
        if cmd == "descr":
            print(_short(_cfg(name)))
            return 0
        if cmd == "plan":
            print(plan_text(name))
            return 0
        if cmd == "bake":
            print(" ".join(bake_args(name)))
            return 0
        if cmd == "selection":
            print(selection_json(name))
            return 0
        if cmd == "purpose":
            purpose = SHRINK_PRESET_PURPOSE.get(name)
            if not purpose:
                return 1
            print(purpose)
            return 0
        if cmd == "list-presets":
            for name in preset_names():
                cfg = merged_presets()[name]
                tag = ""
                if name in SHRINK_PRESET_PURPOSE:
                    tag = f"  → {SHRINK_PRESET_PURPOSE[name]}"
                print(f"{name}\t{_short(cfg)}{tag}")
            return 0
    except ValueError:
        return 1
    except Exception as e:
        print(f"shrink-plan: {e}", file=sys.stderr)
        return 1
    print(f"shrink-plan: unknown command '{cmd}'", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(_cli())