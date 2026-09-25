# Single Source of Truth for all shrink presets.
# This module is the authoritative definition of every shrink keep-rule flag:
#   - name, type, default, description
#   - the built-in recipes (DEFAULT_SHRINK_PRESETS: lean/recent/full/bare)
#   - shrink-presets.json schema generation (scripts/generate_schema.py)
#   - shrinklib/presets.py validation
#   - menu.sh rows/plan/bake (shrinklib/plan.py CLI bridge)
#   - generated/shrink-flags-table.md table
#   - the `opencode-db shrink` / `shrink flags:` help block (--help-shrinks)
#
# The build engine stays in modules/shrink.sh (SQL/VACUUM/swap); the PYTHON here
# owns the config contract: preset resolution, validation, schema, rows and the
# "what will this shrink produce?" plan — mirroring exportlib for exports.
from dataclasses import dataclass

from exportlib.flags import Flag

# ---- Shrink flag registry ----
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
        description="Also drop the 'reasoning' parts (the bulk of the size) on the copy",
        cli_help="Also drop the 'reasoning' parts (the bulk of the size) on the copy",
    ),
]

# Preset keys accepted under one preset of shrink-presets.json (all 7).
SHRINK_PRESET_KEYS: list[str] = sorted(f.name for f in SHRINK_FLAGS)

# The keep-rule keys: exactly ONE per preset (mutually exclusive). strip_reasoning
# is the only optional companion key.
KEEP_RULE_KEYS: list[str] = [
    "keep",
    "older_than",
    "since",
    "keep_all",
    "keep_sessions",
    "discard_sessions",
]

# Built-in recipes (always available, even without a shrink-presets file). A user
# file can override a name and/or add new ones; `shrink <name>` resolves the
# snapshot of defaults+file, so `shrink lean --keep 3` works without any file.
DEFAULT_SHRINK_PRESETS: dict[str, dict] = {
    "lean": {"keep": 10, "strip_reasoning": True},
    "recent": {"older_than": 90},
    "full": {"keep_all": True, "strip_reasoning": True},
    "bare": {"keep": 10},
}

# Built-in recipes -> one-line purpose (menu picker header / --list-presets).
SHRINK_PRESET_PURPOSE: dict[str, str] = {
    "lean": "keep the 10 most recent sessions + strip reasoning (recommended)",
    "recent": "keep sessions updated in the last 90 days",
    "full": "keep ALL sessions, strip reasoning + vacuum (just reclaims space)",
    "bare": "keep the 10 most recent sessions, keep reasoning",
}


def help_main_shrinks() -> str:
    """The 'shrink presets:' + 'shrink flags:' block served to `opencode-db help`
    and `opencode-db shrink --help` (via the same text). Single source for the
    recipe/flags help: edit here, never in opencode-db.sh/o shrink.sh."""
    lines = ["shrink presets (default: keep the 10 most recent sessions):"]
    for name in DEFAULT_SHRINK_PRESETS:
        lines.append(f"  {name:<7} {SHRINK_PRESET_PURPOSE[name]}")
    lines.append("")
    lines.append("shrink flags:")
    lines.append("  --keep N           keep the N most recent sessions (by last update); default 10")
    lines.append("  --older-than DAYS  keep sessions updated within the last DAYS days")
    lines.append("  --since DATE       keep sessions updated on or after DATE (YYYY-MM-DD, UTC)")
    lines.append("  --keep-all         keep ALL sessions (just prune orphans + vacuum)")
    lines.append("  --keep-sessions ID[,ID]   keep ONLY the listed sessions (+ their parents/subagents)")
    lines.append("  --discard-sessions ID[,ID]  keep everything EXCEPT the listed sessions (+ their subagents)")
    lines.append("  --strip-reasoning  also drop the 'reasoning' parts (the bulk of the size) on the copy")
    lines.append("  --dry-run          only report what would be pruned (no output written)")
    lines.append("  --out DIR          where to write the shrink/<stamp>/ output (default $OCED_BACKUP_DIR)")
    lines.append("  --swap             build the copy AND replace the live DB with it (requires")
    lines.append("                     confirmation, or --yes). Safe: aborts if opencode is running,")
    lines.append("                     snapshots a .pre-shrink safety copy (sqlite .backup, WAL-safe),")
    lines.append("                     swaps atomically and rolls back if the new DB does not open.")
    lines.append("  --yes              skip the confirmation prompt of --swap")
    lines.append("  --list-presets     list the known shrink presets (built-ins + shrink-presets file)")
    lines.append("")
    lines.append("The kept set is closed: every parent and subagent of a kept session is kept too")
    lines.append("(no orphans). The result is written as a pruned + VACUUMed copy; the live DB is")
    lines.append("never modified unless --swap is given. `shrink <name>` resolves a named preset;")
    lines.append("explicit flags win over the preset (e.g. `shrink lean --keep 3` keeps 3 and still")
    lines.append("strips reasoning).")
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 2 and sys.argv[1] == "--help-shrinks":
        print(help_main_shrinks())
        sys.exit(0)
    print(__doc__ or __file__)
    sys.exit(1)