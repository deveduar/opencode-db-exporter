# Shrink plan API — the single Python place that answers "what will this shrink
# produce?", plus the bash<->python bridge used by menu.sh and shrink.sh.
#
# TWO families (mirroring exportlib's product/preset split):
#   * SESSION SELECTION — WHICH sessions survive. The menu asks for it with its
#     sessions picker and passes the CLI selection flags; the CLI takes the flags.
#     NOT a recipe key (see shrinklib/presets.py validate_preset).
#   * OPERATIONS — WHAT is done to the copy besides the pruning (today:
#     strip_reasoning). These are the only keys a recipe/preset may carry, so a
#     recipe is just a named combination of operations (lean/quiet built-ins +
#     whatever OCED_SHRINK_PRESETS adds).
#
# The row/description/flag BAKING lives here (pure config, no DB). The live
# NUMBERS of the confirm block are counted by menu.sh with read-only queries.
#
# CLI subcommands:
#   rows                 TSV operation-recipe rows for the fzf picker (key<TAB>display)
#   names                recipe/preset names (merged, one per line)
#   descr <name>         one-line summary of a recipe (its operations)
#   purpose <name>       one-line purpose for the shipped recipes (unknown -> 1)
#   plan <name>          multi-line "Will produce:" block for a recipe
#   bake <name>          raw flags for the bash parser (operations; last-wins)
#   ops-flags <strip>    raw flags for a TOGGLED operation set (menu: 0|1)
#   op-lines <strip>     human operation lines for a TOGGLED operation set
#   list-presets         <name>\t<summary> rows for `shrink --list-presets`
#   rule-line <rule> [value] [strip 0|1]   human criteria line for the bash
#                                      engine's final resolved rule
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
        op_lines,
        rule_lines,
    )
    from shrinklib.flags import SHRINK_PRESET_PURPOSE
except ImportError:
    # fallback for in-place execution (python3 modules/shrinklib/plan.py ...)
    from presets import bake_args, load_shrink_presets, merged_presets, op_lines, rule_lines
    from flags import SHRINK_PRESET_PURPOSE


def _cfg(name: str) -> dict:
    presets = merged_presets()
    if name not in presets:
        known = ", ".join(sorted(presets))
        raise ValueError(f"unknown shrink recipe/preset '{name}' — known: {known}")
    return presets[name]


def _short(cfg: dict) -> str:
    return " + ".join(op_lines(cfg)) or "no operation (just prune + vacuum)"


def ops_cfg(strip: bool) -> dict:
    """The operation set built from the menu's toggles."""
    return {"strip_reasoning": True} if strip else {}


def preset_rows() -> list[str]:
    """TSV rows: __PRESET_<name>\t<name>  <operations>. Built-ins first (in their
    natural order), then file recipes that are not shipped."""
    merged = merged_presets()
    rows: list[str] = []
    for name in merged:
        rows.append(f"__PRESET_{name}\t{name}  {_short(merged[name])}")
    return rows


def preset_names() -> list[str]:
    return list(merged_presets().keys())


def plan_text(name: str) -> str:
    """Multi-line 'Will produce:' block of a recipe (its operations; no leading
    indentation — the caller adds uniform indentation)."""
    cfg = _cfg(name)
    lines = [f"{name}:"]
    for line in op_lines(cfg):
        lines.append(f"  - {line}")
    return "\n".join(lines)


def ops_flags(strip: bool) -> str:
    """Raw flags for a toggled operation set (the space to forward to `shrink`)."""
    return " ".join(bake_args_from_cfg(ops_cfg(strip)))


def ops_text(strip: bool) -> str:
    """Human lines for a toggled operation set (empty = no operation)."""
    return " + ".join(op_lines(ops_cfg(strip)))


def bake_args_from_cfg(cfg: dict) -> list[str]:
    args: list[str] = []
    if cfg.get("strip_reasoning"):
        args.append("--strip-reasoning")
    return args


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
        if cmd in ("descr", "plan", "bake", "purpose"):
            if len(args) < 2:
                return 1
            name = args[1]
        if cmd == "descr":
            print(_short(_cfg(name)))
            return 0
        if cmd == "plan":
            print(plan_text(name))
            return 0
        if cmd == "bake":
            print(" ".join(bake_args(name)))
            return 0
        if cmd == "purpose":
            purpose = SHRINK_PRESET_PURPOSE.get(name)
            if not purpose:
                return 1
            print(purpose)
            return 0
        if cmd in ("ops-flags", "op-lines"):
            # Args: <strip 0|1> — the menu's operation toggles.
            if len(args) < 2:
                return 1
            strip = args[1] == "1"
            print(ops_flags(strip) if cmd == "ops-flags" else ops_text(strip))
            return 0
        if cmd == "list-presets":
            for name in preset_names():
                cfg = merged_presets()[name]
                tag = ""
                if name in SHRINK_PRESET_PURPOSE:
                    tag = f"  → {SHRINK_PRESET_PURPOSE[name]}"
                print(f"{name}\t{_short(cfg)}{tag}")
            return 0
        if cmd == "rule-line":
            # Human criteria line for a resolved rule (the bash engine's final rule
            # after last-wins). Args: <rule> [value] [strip 0|1]. Single source with
            # rule_lines() — shrink.sh never builds these phrases itself.
            if len(args) < 2:
                return 1
            rule = args[1]
            value = args[2] if len(args) > 2 else None
            strip = len(args) > 3 and args[3] == "1"
            cfg: dict = {}
            if rule == "keep" or rule == "older_than":
                cfg[rule] = int(value)
            elif rule == "since":
                cfg["since"] = value
            elif rule == "keep_all":
                cfg["keep_all"] = True
            elif rule in ("keep_sessions", "discard_sessions"):
                cfg[rule] = [""] * int(value)
            else:
                return 1
            if strip:
                cfg["strip_reasoning"] = True
            print(" + ".join(rule_lines(cfg)))
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
