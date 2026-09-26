# Single Source of Truth for all shrink presets.
# This module is the authoritative definition of every shrink keep-rule flag:
#   - name, type, default, description
#   - the built-in recipes (DEFAULT_SHRINK_PRESETS: lean/quiet)
#   - shrink-presets.json schema generation (scripts/generate_schema.py)
#   - shrinklib/presets.py validation
#   - menu.sh rows/plan/bake (shrinklib/plan.py CLI bridge)
#   - generated/shrink-flags-table.md table
#   - the `opencode-db shrink` / `shrink flags:` help block (--help-shrinks)
#
# Two disjoint families (see SHRINK_FLAGS): SESSION SELECTION (CLI flags, the
# menu asks you with its picker) and OPERATIONS (the only preset keys).
#
# The build engine stays in modules/shrink.sh (SQL/VACUUM/swap); the PYTHON here
# owns the config contract: preset resolution, validation, schema, rows and the
# "what will this shrink produce?" plan — mirroring exportlib for exports.
import os
import sys
from dataclasses import dataclass

# Self-bootstrapping entry (like plan.py): running this file directly
# (`python3 flags.py --help-shrinks`, `--usage`) needs `exportlib` resolvable.
MODULES_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if MODULES_DIR not in sys.path:
    sys.path.insert(0, MODULES_DIR)

from exportlib.flags import Flag

# ---- Shrink flag registry ----
# TWO families, deliberately separated:
#
#   * SELECTION flags (CLI only) — WHICH sessions survive the shrink. Mutually
#     exclusive (exactly ONE; `keep` is the default when none is given). In the
#     MENU this is never a preset key: the sessions picker asks you, session by
#     session, and the engine gets --keep-sessions/--discard-sessions/--keep-all.
#   * OPERATION keys (the only valid keys of a shrink-presets.json preset) — WHAT
#     is done to the DB besides the pruning (today: strip_reasoning). A named
#     recipe is just a convenient combination of operations.
#
# Order = display order in help / schema / docs. `keep_sessions` /
# `discard_sessions` are "string" Flags handled specially (comma-separated ids).
SHRINK_FLAGS: list[Flag] = [
    Flag(
        name="keep",
        flag_type="int",
        products=["*"],
        default=None,
        min_value=1,
        description="Keep the N most recent sessions (by last update)",
        cli_help="Keep the N most recent sessions (by last update); default 10",
    ),
    Flag(
        name="older_than",
        flag_type="int",
        products=["*"],
        default=None,
        min_value=1,
        description="Keep sessions updated within the last N days",
        cli_help="Keep sessions updated within the last DAYS days",
    ),
    Flag(
        name="since",
        flag_type="string",
        products=["*"],
        default=None,
        description="Keep sessions updated on or after DATE (YYYY-MM-DD, UTC)",
        cli_help="Keep sessions updated on or after DATE (YYYY-MM-DD, UTC)",
    ),
    Flag(
        name="keep_all",
        flag_type="bool",
        products=["*"],
        default=False,
        description="Keep ALL sessions (just prune orphans + vacuum)",
        cli_help="Keep all sessions (just prune orphans + vacuum)",
    ),
    Flag(
        name="keep_sessions",
        flag_type="string",  # handled specially: comma-separated exact session ids
        products=["*"],
        default=None,
        description="Keep ONLY the listed session ids (+ their parents and subagents)",
        cli_help="Keep only the listed session ids (comma-separated; parents/subagents kept)",
    ),
    Flag(
        name="discard_sessions",
        flag_type="string",  # handled specially: comma-separated exact session ids
        products=["*"],
        default=None,
        description="Keep everything EXCEPT the listed session ids (+ their subagents)",
        cli_help="Keep everything except the listed session ids (comma-separated; subagents dropped)",
    ),
    Flag(
        name="strip_reasoning",
        flag_type="bool",
        products=["*"],
        default=False,
        description="Drop the 'reasoning' parts on the copy (the bulk of the text)",
        cli_help="Drop the 'reasoning' parts on the copy (the bulk of the text)",
    ),
]

# The keep-rule keys: the SESSION SELECTION, CLI-only. Mutually exclusive: exactly
# ONE per invocation, `keep` is the implicit default.
KEEP_RULE_KEYS: list[str] = [
    "keep",
    "older_than",
    "since",
    "keep_all",
    "keep_sessions",
    "discard_sessions",
]

# The OPERATION keys: the only keys a shrink-presets.json preset may carry.
OPERATION_KEYS: list[str] = [f.name for f in SHRINK_FLAGS if f.name not in KEEP_RULE_KEYS]

# Preset keys accepted under one preset of shrink-presets.json (operations only).
SHRINK_PRESET_KEYS: list[str] = list(OPERATION_KEYS)

# Built-in recipes (always available, even without a shrink-presets file): named
# combinations of OPERATIONS. The session selection is NOT part of a recipe — the
# menu asks for it (sessions picker) and the CLI takes the selection flags, so
# `shrink lean` = default selection (--keep 10) + strip reasoning.
DEFAULT_SHRINK_PRESETS: dict[str, dict] = {
    "lean": {"strip_reasoning": True},
    "quiet": {},
}

# Built-in recipes -> one-line purpose (menu picker header / --list-presets).
SHRINK_PRESET_PURPOSE: dict[str, str] = {
    "lean": "strip the reasoning parts (smallest text; reasoning is not displayed anyway)",
    "quiet": "prune + vacuum only: keep the full text of the sessions you keep",
}


def help_main_shrinks() -> str:
    """The 'shrink presets:' + 'shrink flags:' block served to `opencode-db help`
    and `opencode-db shrink --help` (via the same text). Single source for the
    recipe/flags help: edit here, never in opencode-db.sh/o shrink.sh."""
    lines = ["shrink presets (named OPERATIONS; the sessions are chosen separately):"]
    for name in DEFAULT_SHRINK_PRESETS:
        lines.append(f"  {name:<7} {SHRINK_PRESET_PURPOSE[name]}")
    lines.append("")
    lines.append("session selection flags (CLI only — the menu asks you with its picker):")
    lines.append("  --keep N           keep the N most recent sessions (by last update); default 10")
    lines.append("  --older-than DAYS  keep sessions updated within the last DAYS days")
    lines.append("  --since DATE       keep sessions updated on or after DATE (YYYY-MM-DD, UTC)")
    lines.append("  --keep-all         keep ALL sessions (just prune orphans + vacuum)")
    lines.append("  --keep-sessions ID[,ID]   keep ONLY the listed sessions (+ their parents/subagents)")
    lines.append("  --discard-sessions ID[,ID]  keep everything EXCEPT the listed sessions (+ their subagents)")
    lines.append("")
    lines.append("shrink flags:")
    lines.append("  --strip-reasoning  drop the 'reasoning' parts on the copy (the bulk of the text)")
    lines.append("  --dry-run          only report what would be pruned (no output written)")
    lines.append("  --out DIR          where to write the shrink/<stamp>/ output (default $OCED_BACKUP_DIR)")
    lines.append("  --swap             build the copy AND replace the live DB with it (requires")
    lines.append("                     confirmation, or --yes). Safe: aborts if opencode is running,")
    lines.append("                     snapshots a .pre-shrink safety copy (sqlite .backup, WAL-safe),")
    lines.append("                     swaps atomically and rolls back if the new DB does not open.")
    lines.append("  --yes              skip the confirmation prompt of --swap")
    lines.append("  --list-presets     list the known shrink recipes (built-ins + shrink-presets file)")
    lines.append("")
    lines.append("A recipe carries only operations; the session selection is always separate")
    lines.append("(a recipe key like 'keep' is rejected: use the selection flags above).")
    lines.append("The kept set is closed: every parent and subagent of a kept session is kept too")
    lines.append("(no orphans); discarding a session drops its subagents too. The result is a")
    lines.append("pruned + VACUUMed copy; the live DB is never modified unless --swap is given.")
    lines.append("Explicit flags win over a recipe (e.g. `shrink lean --keep 3` keeps 3 and still")
    lines.append("strips reasoning).")
    return "\n".join(lines)


def usage_main_shrinks() -> str:
    """The full `opencode-db shrink --help` text (single source: served by
    shrink.sh --help via `flags.py --usage`). Recipes + the reusable flags/notes
    section, plus the usage line and the OCED_SHRINK_PRESETS mention."""
    lines = [
        "Usage: opencode-db shrink [recipe|preset] [--keep N | --older-than DAYS | --since DATE |",
        "           --keep-all | --keep-sessions ID[,ID] | --discard-sessions ID[,ID]]",
        "           [--strip-reasoning] [--dry-run] [--out DIR] [--swap] [--yes] [--list-presets]",
        "",
        "Recipes (named OPERATIONS; no recipe = default selection + no operation):",
    ]
    for name in DEFAULT_SHRINK_PRESETS:
        lines.append(f"  {name:<7} {SHRINK_PRESET_PURPOSE[name]}")
    lines.append("")
    lines.append("Named recipes also come from the OCED_SHRINK_PRESETS file (see")
    lines.append("`opencode-db shrink --list-presets`); they only carry operations — the session")
    lines.append("selection is a separate concern (the CLI flags below, or the menu's picker).")
    lines.append("Explicit flags win over a recipe (e.g. `shrink lean --keep 3` keeps 3 and still")
    lines.append("strips reasoning).")
    lines.append("")
    # the flags + notes section of the main help (skip its recipes header: the
    # usage already lists them above)
    hlines = help_main_shrinks().splitlines()
    for i, line in enumerate(hlines):
        if line.startswith("session selection flags"):
            lines.extend(hlines[i:])
            break
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 2 and sys.argv[1] == "--help-shrinks":
        print(help_main_shrinks())
        sys.exit(0)
    if len(sys.argv) == 2 and sys.argv[1] == "--usage":
        print(usage_main_shrinks())
        sys.exit(0)
    print(__doc__ or __file__)
    sys.exit(1)